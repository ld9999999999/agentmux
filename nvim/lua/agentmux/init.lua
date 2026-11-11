-- The editor side of agentmux. All of nvim's state lives in files: it
-- writes the window layout and every unsaved buffer to
-- <session>/editor.json (and <session>/stash/) as they change, and
-- rebuilds them from there on start.
--
-- A session can have two editors open at once, each its own nvim: one for
-- terminals and one for a GUI (agentmux serve). The GUI editor saves to
-- editor-gui.json and stash-gui/. An editor that starts takes the newer
-- snapshot of the two, so it opens the files and cursors the other had.

local api, uv = vim.api, vim.uv
local M = {}

local id = vim.env.AGENTMUX_SESSION
local bin = vim.env.AGENTMUX_BIN or 'agentmux'
-- True when `agentmux serve` started nvim. A GUI is then attached and
-- draws the agent pane itself, so nvim shows only the editor.
local gui = vim.env.AGENTMUX_UI == 'gui'
local dir = (vim.env.AGENTMUX_HOME or (vim.env.HOME .. '/.agentmux')) .. '/sessions/' .. (id or '')
local kind = gui and 'gui' or 'terminal'
local other_kind = gui and 'terminal' or 'gui'
local function snap_path_of(k)
  return dir .. (k == 'gui' and '/editor-gui.json' or '/editor.json')
end
local function stash_dir_of(k)
  return dir .. (k == 'gui' and '/stash-gui' or '/stash')
end
local function pid_path_of(k)
  return dir .. (k == 'gui' and '/nvim-gui.pid' or '/nvim.pid')
end
local snap_path = snap_path_of(kind)
local stash_dir = stash_dir_of(kind)

local restoring = false
local agent_buf ---@type integer?
local last_editor_win ---@type integer?
local written_tick = {} ---@type table<string, integer> stash key -> changedtick on disk
local last_stash = {} ---@type table<string, table> stash key -> entry from the last save
local ns = api.nvim_create_namespace('agentmux')
-- Highlights the selection Claude still holds after the editor leaves
-- visual mode.
local sel_ns = api.nvim_create_namespace('agentmux_selection')
local max_hash_bytes = 8 * 1024 * 1024

local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local s = f:read('*a')
  f:close()
  return s
end

local function write_atomic(path, data)
  -- Each nvim uses its own temporary file, because the session's other
  -- editor may write the same file at the same moment.
  local tmp = path .. '.' .. vim.fn.getpid() .. '.tmp'
  local f = assert(io.open(tmp, 'wb'))
  f:write(data)
  f:close()
  assert(os.rename(tmp, path))
end

local function file_hash(path)
  local st = uv.fs_stat(path)
  if not st or st.type ~= 'file' or st.size > max_hash_bytes then
    return nil
  end
  local s = read_file(path)
  return s and vim.fn.sha256(s)
end

local function is_agent(buf)
  return buf == agent_buf
end

local function is_file_buf(buf)
  return api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == '' and not is_agent(buf)
end

-- Unnamed buffers have no path, so they are stashed under their number.
local function stash_key(buf)
  local name = api.nvim_buf_get_name(buf)
  return name ~= '' and name or ('unnamed:' .. buf)
end

local function stash_file(key)
  return stash_dir .. '/' .. vim.fn.sha256(key):sub(1, 16) .. '.txt'
end

---------------------------------------------------------------------------
-- Snapshot
---------------------------------------------------------------------------

local function snap_layout(node, cur)
  if node[1] == 'leaf' then
    local win = node[2]
    local buf = api.nvim_win_get_buf(win)
    local leaf = {
      width = api.nvim_win_get_width(win),
      height = api.nvim_win_get_height(win),
      current = win == cur or nil,
    }
    if is_agent(buf) then
      return { 'agent', leaf }
    end
    if is_file_buf(buf) then
      leaf.key = stash_key(buf)
      leaf.path = api.nvim_buf_get_name(buf)
      leaf.view = api.nvim_win_call(win, vim.fn.winsaveview)
    end
    return { 'leaf', leaf }
  end
  local kids = {}
  for i, child in ipairs(node[2]) do
    kids[i] = snap_layout(child, cur)
  end
  return { node[1], kids }
end

local function snap_stash()
  local entries, keep, by_key = {}, {}, {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local key = is_file_buf(buf) and vim.bo[buf].modified and stash_key(buf)
    if key and not api.nvim_buf_is_loaded(buf) then
      -- The buffer is modified but its text is gone, because nvim unloads
      -- buffers when it exits after losing its UI. Keep the earlier stash.
      local prev = last_stash[key]
      if prev then
        keep[prev.file] = true
        entries[#entries + 1] = prev
        by_key[key] = prev
      end
    elseif key then
      local file = stash_file(key)
      local tick = api.nvim_buf_get_changedtick(buf)
      if written_tick[key] ~= tick then
        local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
        write_atomic(file, table.concat(lines, '\n'))
        written_tick[key] = tick
      end
      keep[vim.fs.basename(file)] = true
      entries[#entries + 1] = {
        key = key,
        path = api.nvim_buf_get_name(buf),
        file = vim.fs.basename(file),
        base = vim.b[buf].agentmux_base,
        filetype = vim.bo[buf].filetype,
      }
      by_key[key] = entries[#entries]
    end
  end
  last_stash = by_key
  -- Drop stash files for buffers that were written or discarded.
  for name in vim.fs.dir(stash_dir) do
    if not keep[name] then
      os.remove(stash_dir .. '/' .. name)
    end
  end
  for key in pairs(written_tick) do
    if not keep[vim.fs.basename(stash_file(key))] then
      written_tick[key] = nil
    end
  end
  return entries
end

local function save()
  if restoring or not id then
    return
  end
  if vim.fn.isdirectory(stash_dir) == 0 then
    vim.fn.mkdir(stash_dir, 'p') -- older sessions lack the GUI's stash folder
  end
  local cur = api.nvim_get_current_win()
  local tabs = {}
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    -- Skip diff tabs: an agent diff lasts only while the agent waits for
    -- it, and git can rebuild a git diff.
    if not vim.t[tab].agentmux_diff and not vim.t[tab].agentmux_git_diff then
      local nr = api.nvim_tabpage_get_number(tab)
      tabs[#tabs + 1] = {
        layout = snap_layout(vim.fn.winlayout(nr), cur),
        current = tab == api.nvim_get_current_tabpage() or nil,
      }
    end
  end
  local listed = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if is_file_buf(buf) and vim.bo[buf].buflisted and api.nvim_buf_get_name(buf) ~= '' then
      listed[#listed + 1] = api.nvim_buf_get_name(buf)
    end
  end
  local snap = {
    version = 1,
    cwd = vim.fn.getcwd(-1, -1),
    columns = vim.o.columns,
    lines = vim.o.lines,
    tabs = tabs,
    buffers = listed,
    stash = snap_stash(),
  }
  write_atomic(snap_path, vim.json.encode(snap))
end

function M.save()
  -- Stay quiet when the session folder is gone, which happens while the
  -- session is being deleted.
  local ok, err = pcall(save)
  if not ok and vim.fn.isdirectory(dir) == 1 then
    vim.notify('agentmux: could not save session: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

local save_timer = assert(uv.new_timer())
local function schedule_save()
  if restoring then
    return
  end
  save_timer:stop()
  save_timer:start(400, 0, vim.schedule_wrap(M.save))
end

---------------------------------------------------------------------------
-- Agent pane
---------------------------------------------------------------------------

-- The GUI's RPC channel in GUI mode (the one UI attached), or nil.
local function gui_chan()
  for _, ui in ipairs(api.nvim_list_uis()) do
    if (ui.chan or 0) > 0 then
      return ui.chan
    end
  end
end

-- Sends the GUI (in GUI mode) an rpcnotify 'agentmux' event on its
-- channel, with an optional table of arguments.
local function gui_notify(event, args)
  local chan = gui_chan()
  if chan then
    vim.rpcnotify(chan, 'agentmux', event, args)
  end
end

---------------------------------------------------------------------------
-- Clipboard (GUI mode): the + and * registers are the clipboard of the
-- machine the GUI runs on, wherever nvim runs. This starts only after the
-- GUI says (in nvim_set_client_info) that it answers
-- agentmux_clipboard_get, because a paste waits for that answer.
---------------------------------------------------------------------------

local function gui_answers_clipboard()
  local chan = gui_chan()
  local info = chan and api.nvim_get_chan_info(chan)
  local methods = info and info.client and info.client.methods
  return type(methods) == 'table' and methods.agentmux_clipboard_get ~= nil
end

local function clipboard_copy(reg)
  return function(lines)
    -- Linewise text ends with an empty line, so the joined text ends in a
    -- newline and a paste brings back whole lines.
    gui_notify('clipboard_set', { register = reg, text = table.concat(lines, '\n') })
  end
end

local function clipboard_paste(reg)
  return function()
    local chan = gui_chan()
    if not (chan and gui_answers_clipboard()) then
      return {}
    end
    local ok, text = pcall(vim.rpcrequest, chan, 'agentmux_clipboard_get', { register = reg })
    if not ok or type(text) ~= 'string' then
      return {}
    end
    text = text:gsub('\r\n', '\n')
    local linewise = text:sub(-1) == '\n'
    local lines = vim.split(linewise and text:sub(1, -2) or text, '\n', { plain = true })
    return { lines, linewise and 'V' or 'v' }
  end
end

local our_clipboard = false

-- Puts the GUI's clipboard in place, unless the user's config chose a
-- clipboard of its own. Runs whenever the GUI's client info changes.
local function use_gui_clipboard()
  if not gui or our_clipboard or not gui_answers_clipboard() then
    return
  end
  if vim.g.clipboard ~= nil then
    return
  end
  vim.g.clipboard = {
    name = 'agentmux-gui',
    copy = { ['+'] = clipboard_copy('+'), ['*'] = clipboard_copy('*') },
    paste = { ['+'] = clipboard_paste('+'), ['*'] = clipboard_paste('*') },
  }
  our_clipboard = true
  -- The provider reads g:clipboard once, when it is first used.
  vim.g.loaded_clipboard_provider = nil
  vim.cmd('runtime autoload/provider/clipboard.vim')
end

local function agent_window()
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if is_agent(api.nvim_win_get_buf(win)) then
      return win
    end
  end
end

-- Defined below.
local agent_exited

-- Shows the agent in win, starting the attach client if needed. The client
-- only connects to the session's holder, so the agent keeps running when
-- the client closes.
local function show_agent(win)
  if not (agent_buf and api.nvim_buf_is_valid(agent_buf) and vim.bo[agent_buf].buftype == 'terminal') then
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'hide'
    api.nvim_buf_call(buf, function()
      vim.fn.jobstart({ bin, 'cli', '-detach-key', 'none', id }, {
        term = true,
        on_exit = function(_, code)
          vim.schedule(function()
            agent_exited(buf, code)
          end)
        end,
      })
    end)
    vim.b[buf].agentmux_agent = true
    agent_buf = buf
  end
  api.nvim_win_set_buf(win, agent_buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].winfixwidth = true
end

-- When the agent exits, its pane stays open with a message. A finished
-- terminal closes its window on the first keypress, and the session would
-- then be saved and restored without an agent pane.
function agent_exited(term_buf, code)
  if term_buf ~= agent_buf or not api.nvim_buf_is_valid(term_buf) then
    return -- replaced by :AgentRestart
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'hide'
  api.nvim_buf_set_lines(buf, 0, -1, false, {
    '',
    ('  The agent exited (%d).'):format(code),
    '',
    '  Press Enter, or run :AgentRestart, to start it again.',
  })
  vim.bo[buf].modifiable = false
  vim.keymap.set('n', '<CR>', function()
    M.restart_agent()
  end, { buffer = buf, desc = 'Restart the agent' })
  agent_buf = buf
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == term_buf then
      api.nvim_win_set_buf(win, buf)
    end
  end
  if api.nvim_get_mode().mode == 't' then
    vim.cmd.stopinsert()
  end
  api.nvim_buf_delete(term_buf, { force = true })
end

local function open_agent_split()
  local win = agent_window()
  if win then
    return win
  end
  vim.cmd('botright vsplit')
  win = api.nvim_get_current_win()
  show_agent(win)
  api.nvim_win_set_width(win, math.max(60, math.floor(vim.o.columns * 0.4)))
  return win
end

function M.focus_agent()
  if gui then
    return gui_notify('focus_agent')
  end
  api.nvim_set_current_win(open_agent_split())
  if vim.bo.buftype == 'terminal' then
    vim.cmd.startinsert()
  end
end

function M.toggle_agent()
  if gui then
    return gui_notify('toggle_agent')
  end
  local win = agent_window()
  if win and #api.nvim_tabpage_list_wins(0) > 1 then
    api.nvim_win_close(win, false)
  else
    M.focus_agent()
  end
end

function M.restart_agent()
  if gui then
    return gui_notify('restart_agent')
  end
  local wins = {}
  for _, win in ipairs(api.nvim_list_wins()) do
    if is_agent(api.nvim_win_get_buf(win)) then
      wins[#wins + 1] = win
    end
  end
  local old = agent_buf
  agent_buf = nil
  if #wins == 0 then
    wins = { open_agent_split() }
  end
  for _, win in ipairs(wins) do
    show_agent(win)
  end
  if old and api.nvim_buf_is_valid(old) then
    api.nvim_buf_delete(old, { force = true })
  end
end

---------------------------------------------------------------------------
-- Restore
---------------------------------------------------------------------------

local conflicts = {}

local function restore_stash(entries)
  local by_key = {}
  for _, e in ipairs(entries or {}) do
    local text = read_file(stash_dir .. '/' .. e.file)
    if text then
      local buf
      if e.path ~= '' then
        buf = vim.fn.bufadd(e.path)
        vim.fn.bufload(buf)
        vim.bo[buf].buflisted = true
        local now = file_hash(e.path)
        if e.base and now ~= e.base then
          conflicts[#conflicts + 1] = e.path
        end
        vim.b[buf].agentmux_base = e.base
      else
        buf = api.nvim_create_buf(true, false)
        if e.filetype and e.filetype ~= '' then
          vim.bo[buf].filetype = e.filetype
        end
      end
      api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
      by_key[e.key] = buf
      if e.path ~= '' then
        last_stash[e.key] = e
      end
    end
  end
  return by_key
end

local function restore_layout(node, stash, sized)
  local kind, data = node[1], node[2]
  local win = api.nvim_get_current_win()
  if kind == 'agent' then
    show_agent(win)
  elseif kind == 'leaf' then
    local buf = data.key and stash[data.key]
    if buf then
      api.nvim_win_set_buf(win, buf)
    elseif data.path and data.path ~= '' then
      pcall(vim.cmd.edit, vim.fn.fnameescape(data.path))
    else
      vim.cmd.enew()
    end
    if data.view then
      pcall(vim.fn.winrestview, data.view)
    end
  else
    local split = kind == 'row' and 'rightbelow vsplit' or 'rightbelow split'
    local wins = { win }
    for i = 2, #data do
      vim.cmd(split)
      wins[i] = api.nvim_get_current_win()
    end
    for i, child in ipairs(data) do
      api.nvim_set_current_win(wins[i])
      restore_layout(child, stash, sized)
    end
    return
  end
  sized[#sized + 1] = { win = win, leaf = data }
end

-- Removes the agent window from a layout saved in a terminal, for GUI mode.
local function without_agent(node)
  if node[1] == 'agent' then
    return nil
  elseif node[1] == 'leaf' then
    return node
  end
  local kids = {}
  for _, child in ipairs(node[2]) do
    kids[#kids + 1] = without_agent(child)
  end
  if #kids <= 1 then
    return kids[1]
  end
  return { node[1], kids }
end

local function restore(snap)
  restoring = true
  if snap.cwd and vim.fn.isdirectory(snap.cwd) == 1 then
    vim.cmd.cd(vim.fn.fnameescape(snap.cwd))
  end
  local stash = restore_stash(snap.stash)
  for _, path in ipairs(snap.buffers or {}) do
    vim.fn.bufadd(path)
    vim.bo[vim.fn.bufnr(path)].buflisted = true
  end

  local sized, cur_win, cur_tab = {}, nil, nil
  for i, tab in ipairs(snap.tabs or {}) do
    if i > 1 then
      vim.cmd.tabnew()
    end
    local before = #sized
    local layout = tab.layout
    if gui then
      layout = without_agent(layout) or { 'leaf', {} }
    end
    restore_layout(layout, stash, sized)
    for j = before + 1, #sized do
      if sized[j].leaf.current then
        cur_win = sized[j].win
      end
    end
    if tab.current then
      cur_tab = api.nvim_get_current_tabpage()
    end
  end

  -- Scale the window sizes to the current terminal. Do it twice, because
  -- each resize moves the neighbours.
  local sx = vim.o.columns / (snap.columns or vim.o.columns)
  local sy = vim.o.lines / (snap.lines or vim.o.lines)
  for _ = 1, 2 do
    for _, s in ipairs(sized) do
      if api.nvim_win_is_valid(s.win) and s.leaf.width then
        pcall(api.nvim_win_set_width, s.win, math.max(1, math.floor(s.leaf.width * sx + 0.5)))
        pcall(api.nvim_win_set_height, s.win, math.max(1, math.floor(s.leaf.height * sy + 0.5)))
      end
    end
  end

  if cur_tab then
    api.nvim_set_current_tabpage(cur_tab)
  end
  if cur_win and api.nvim_win_is_valid(cur_win) then
    api.nvim_set_current_win(cur_win)
  end
  restoring = false

  local n = vim.tbl_count(stash)
  if n > 0 then
    local msg = ('agentmux: restored %d buffer(s) with unsaved changes.'):format(n)
    if #conflicts > 0 then
      msg = msg
        .. '\nChanged on disk since: '
        .. table.concat(vim.tbl_map(function(p)
          return vim.fn.fnamemodify(p, ':~:.')
        end, conflicts), ', ')
        .. '\nUse :AgentDiffDisk in those buffers to compare.'
    end
    vim.notify(msg, #conflicts > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
  end
end

-- The current tab's editor windows: every split except the agent's.
-- Floating windows (hovers, notifications) are left out.
local function editor_wins()
  return vim.tbl_filter(function(w)
    return api.nvim_win_get_config(w).relative == '' and not is_agent(api.nvim_win_get_buf(w))
  end, api.nvim_tabpage_list_wins(0))
end

-- Returns the current tab's editor window, adding one on the left if the
-- tab only shows the agent. A new one shows the most recently used file.
local function add_editor()
  local wins = editor_wins()
  if wins[1] then
    return wins[1]
  end
  vim.cmd('topleft vnew')
  local editor = api.nvim_get_current_win()
  local scratch = api.nvim_get_current_buf()
  local recent
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    if info.bufnr ~= scratch and is_file_buf(info.bufnr) and (not recent or info.lastused > recent.lastused) then
      recent = info
    end
  end
  if recent then
    api.nvim_win_set_buf(editor, recent.bufnr)
    api.nvim_buf_delete(scratch, {})
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if win ~= editor then
      api.nvim_win_set_width(win, math.max(60, math.floor(vim.o.columns * 0.4)))
    end
  end
  return editor
end

-- Every session shows an editor window and the agent. Put back whichever
-- one the saved layout lost, for example because the user closed it.
local function ensure_panes()
  local cur = api.nvim_get_current_win()
  local editor = add_editor()
  local has_agent = false
  for _, win in ipairs(api.nvim_list_wins()) do
    has_agent = has_agent or is_agent(api.nvim_win_get_buf(win))
  end
  if not has_agent and not gui then
    open_agent_split()
  end
  api.nvim_set_current_win(api.nvim_win_is_valid(cur) and cur or editor)
  return editor
end

-- Called from setup and again on VimEnter, because setup runs before the
-- user's config, which may change these.
local function set_options()
  -- The stash does the job of swap files, and an old swap file would stop
  -- the restore with a prompt.
  vim.o.swapfile = false
  vim.o.hidden = true
  -- The agent edits files on disk; pick those edits up.
  vim.o.autoread = true
  vim.o.title = true
  vim.o.titlestring = 'agentmux: ' .. id .. ' %t'
end

-- other_open reports whether the session's other editor is running.
local function other_open()
  local pid = tonumber(vim.trim(read_file(pid_path_of(other_kind)) or ''))
  return pid ~= nil and pid > 0 and uv.kill(pid, 0) == 0
end

local function mtime(path)
  local st = uv.fs_stat(path)
  return st and (st.mtime.sec + st.mtime.nsec / 1e9) or -1
end

-- pick_snapshot returns the snapshot to start from: this editor's own, or
-- the other's when that is newer. With the other editor still open, its
-- unsaved buffers stay its own and this one opens their files from disk.
-- With it closed, its unsaved buffers move here (their stash files are
-- copied over), and adopted tells start() to delete its snapshot after
-- this editor saves.
local adopted = false
local function pick_snapshot()
  local path = snap_path
  if mtime(snap_path_of(other_kind)) > mtime(snap_path) then
    path = snap_path_of(other_kind)
  end
  local ok, snap = pcall(vim.json.decode, read_file(path) or '')
  if not ok or type(snap) ~= 'table' then
    return nil
  end
  if path ~= snap_path then
    if other_open() then
      snap.stash = nil
    else
      vim.fn.mkdir(stash_dir, 'p')
      local from = stash_dir_of(other_kind)
      for _, e in ipairs(snap.stash or {}) do
        local text = read_file(from .. '/' .. e.file)
        if text then
          write_atomic(stash_dir .. '/' .. e.file, text)
        end
      end
      adopted = true
    end
  end
  return snap
end

-- Defined with the editor link below.
local mark_active

local function start()
  set_options()
  local snap = pick_snapshot()
  if snap and snap.tabs and #snap.tabs > 0 then
    restore(snap)
    ensure_panes()
  else
    api.nvim_set_current_win(ensure_panes())
  end
  M.save()
  if adopted then
    -- This editor's snapshot now holds what the other's did.
    os.remove(snap_path_of(other_kind))
    local from = stash_dir_of(other_kind)
    if vim.fn.isdirectory(from) == 1 then
      for name in vim.fs.dir(from) do
        os.remove(from .. '/' .. name)
      end
    end
  end
  mark_active()
  if gui then
    -- Requests the GUI made during startup ran before this plugin loaded
    -- and before the session's folders were restored, so tell the GUI
    -- that nvim is ready.
    gui_notify('ready')
  end
end

-- Jumps to the editor window, first bringing one back on the left if the
-- current tab only shows the agent.
function M.focus_editor()
  local had = #editor_wins() > 0
  local win = add_editor()
  if had and last_editor_win and api.nvim_win_is_valid(last_editor_win)
    and api.nvim_win_get_tabpage(last_editor_win) == api.nvim_get_current_tabpage() then
    win = last_editor_win
  end
  vim.cmd('stopinsert')
  api.nvim_set_current_win(win)
  if gui then
    gui_notify('focus_editor')
  end
end

-- Runs after a window closes: if that left the tab showing only the agent
-- (say, a :terminal in the editor window exited), the editor comes back.
local function keep_editor()
  if restoring or vim.v.exiting ~= vim.NIL or #editor_wins() > 0 or not agent_window() then
    return
  end
  local was_agent = is_agent(api.nvim_get_current_buf())
  local win = add_editor()
  if was_agent then
    vim.cmd('stopinsert')
    api.nvim_set_current_win(win)
  end
end

---------------------------------------------------------------------------
-- Called by `agentmux goto`
---------------------------------------------------------------------------

local function editor_window()
  if last_editor_win and api.nvim_win_is_valid(last_editor_win)
    and api.nvim_win_get_tabpage(last_editor_win) == api.nvim_get_current_tabpage() then
    return last_editor_win
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if is_file_buf(api.nvim_win_get_buf(win)) then
      return win
    end
  end
  vim.cmd('topleft vnew')
  return api.nvim_get_current_win()
end

--- Shows path:line:col in the editor window and leaves focus where the
--- user is (usually the agent pane).
function M.goto(json)
  local a = vim.json.decode(json)
  local win = editor_window()
  -- Use bufadd and bufload: :edit refuses to open a modified current
  -- buffer again.
  local buf = vim.fn.bufadd(a.path)
  local ok, err = pcall(vim.fn.bufload, buf)
  if not ok then
    return tostring(err)
  end
  vim.bo[buf].buflisted = true
  api.nvim_win_set_buf(win, buf)
  local line = math.max(1, math.min(a.line or 1, api.nvim_buf_line_count(buf)))
  if (a.line or 0) > 0 then
    api.nvim_win_set_cursor(win, { line, math.max(0, (a.col or 1) - 1) })
    api.nvim_win_call(win, function()
      vim.cmd('normal! zz')
    end)
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    api.nvim_buf_set_extmark(buf, ns, line - 1, 0, { line_hl_group = 'IncSearch' })
    vim.defer_fn(function()
      if api.nvim_buf_is_valid(buf) then
        api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      end
    end, 1200)
  end
  return ''
end

---------------------------------------------------------------------------
-- Editor link: the holder relays this to Claude Code as an IDE, so the
-- agent sees which file is open and what is selected.
---------------------------------------------------------------------------

local link = { pipe = nil, buf = '', ide = false, last_sel = nil, last_region = nil }
local link_timer = assert(uv.new_timer())
local sel_timer = assert(uv.new_timer())

local function frame(typ, payload)
  local n = #payload
  return typ
    .. string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
    .. payload
end

local function link_send(msg)
  if link.pipe then
    link.pipe:write(frame('E', vim.json.encode(msg)))
  end
end

-- Marks this editor as the one the user turned to, so `agentmux goto` and
-- the agent's IDE calls go to it.
mark_active = function()
  pcall(write_atomic, dir .. '/editor-active', kind .. '\n')
  if link.pipe then
    link_send({ type = 'focus' })
  end
end

-- Reloads unmodified buffers whose file changed on disk (the agent edits
-- files). It skips modified buffers, because reloading one raises a prompt.
local function reload_unmodified(only)
  for _, buf in ipairs(only and { only } or api.nvim_list_bufs()) do
    if is_file_buf(buf) and api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified
      and api.nvim_buf_get_name(buf) ~= '' then
      pcall(vim.cmd.checktime, buf)
    end
  end
end

local function utf16(line, bytecol)
  local ok, n = pcall(vim.str_utfindex, line, 'utf-16', math.min(bytecol, #line))
  return ok and n or bytecol
end

-- The selection in win, in the shape Claude Code's selection_changed takes
-- (0-based lines, UTF-16 characters, exclusive end).
local function selection(win)
  local buf = api.nvim_win_get_buf(win)
  local path = api.nvim_buf_get_name(buf)
  if not is_file_buf(buf) or path == '' then
    return nil
  end
  local function line_at(row)
    return api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ''
  end
  local sel = { filePath = path, fileUrl = vim.uri_from_fname(path), text = '' }
  local region -- the visual selection, for show_kept_selection
  local mode = win == api.nvim_get_current_win() and api.nvim_get_mode().mode or 'n'
  if mode == 'v' or mode == 'V' or mode == '\22' then
    local a, b = vim.fn.getpos('v'), vim.fn.getpos('.')
    local text = vim.fn.getregion(a, b, { type = mode })
    if a[2] > b[2] or (a[2] == b[2] and a[3] > b[3]) then
      a, b = b, a
    end
    local s, e
    if mode == 'V' then
      -- Whole lines end at column 0 of the next line, as in VS Code;
      -- Claude then leaves that next line out.
      s = { line = a[2] - 1, character = 0 }
      if b[2] < api.nvim_buf_line_count(buf) then
        e = { line = b[2], character = 0 }
      else
        e = { line = b[2] - 1, character = utf16(line_at(b[2]), #line_at(b[2])) }
      end
    else
      s = { line = a[2] - 1, character = utf16(line_at(a[2]), a[3] - 1) }
      e = { line = b[2] - 1, character = utf16(line_at(b[2]), b[3]) }
    end
    sel.text = table.concat(text, '\n')
    sel.selection = { start = s, ['end'] = e, isEmpty = false }
    region = { buf = buf, mode = mode, from = { a[2] - 1, a[3] - 1 }, to = { b[2] - 1, b[3] - 1 } }
  else
    local cur = api.nvim_win_get_cursor(win)
    local p = { line = cur[1] - 1, character = utf16(line_at(cur[1]), cur[2]) }
    sel.selection = { start = p, ['end'] = p, isEmpty = true }
  end
  return sel, region
end

-- Highlights the selection Claude was last sent, or clears it (nil).
local function show_kept_selection(region)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    api.nvim_buf_clear_namespace(buf, sel_ns, 0, -1)
  end
  if region and api.nvim_buf_is_valid(region.buf) then
    pcall(vim.hl.range, region.buf, sel_ns, 'Visual', region.from, region.to,
      { regtype = region.mode, inclusive = true })
  end
end

local function send_selection(force)
  if not link.pipe then
    return
  end
  local win = api.nvim_get_current_win()
  local away = not is_file_buf(api.nvim_win_get_buf(win))
  if away then
    -- In the agent pane (or a help window): keep reporting the editor
    -- window the user came from.
    if not (last_editor_win and api.nvim_win_is_valid(last_editor_win)) then
      return
    end
    win = last_editor_win
  end
  local sel, region = selection(win)
  if not sel then
    return
  end
  if away and link.last_sel then
    -- Leaving the editor ends visual mode, which turns the selection the
    -- user wants to talk about into a bare cursor. Keep what Claude has
    -- while the editor shows the same file (a goto can open another).
    local last = vim.json.decode(link.last_sel)
    if last.filePath == sel.filePath then
      if force then
        link_send({ type = 'selection', params = last })
      end
      show_kept_selection(link.last_region)
      return
    end
  end
  local encoded = vim.json.encode(sel)
  if force or encoded ~= link.last_sel then
    link.last_sel, link.last_region = encoded, region
    link_send({ type = 'selection', params = sel })
    show_kept_selection(nil)
  end
end

local function schedule_selection()
  sel_timer:stop()
  sel_timer:start(80, 0, vim.schedule_wrap(send_selection))
end

local severity_names = { 'Error', 'Warning', 'Info', 'Hint' }

local function file_diagnostics(buf)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    out[#out + 1] = {
      message = d.message,
      severity = severity_names[d.severity] or 'Hint',
      source = d.source,
      code = d.code and tostring(d.code) or nil,
      range = {
        start = { line = d.lnum, character = d.col },
        ['end'] = { line = d.end_lnum or d.lnum, character = d.end_col or d.col },
      },
    }
  end
  return out
end

local requests = {}

function requests.getDiagnostics(p)
  if p and p.uri and p.uri ~= '' then
    local path = vim.uri_to_fname(p.uri)
    local buf = vim.fn.bufnr(path)
    if buf > 0 then
      -- Claude asks right after it edits a file; pick up the edit first.
      reload_unmodified(buf)
    end
    return { { uri = p.uri, diagnostics = buf > 0 and file_diagnostics(buf) or {} } }
  end
  local out = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(buf)
    if is_file_buf(buf) and name ~= '' then
      local ds = file_diagnostics(buf)
      if #ds > 0 then
        out[#out + 1] = { uri = vim.uri_from_fname(name), diagnostics = ds }
      end
    end
  end
  return out
end

function requests.openFile(p)
  local err = M.goto(vim.json.encode({ path = p.filePath, line = p.startLine or 0 }))
  if err ~= '' then
    error(err, 0)
  end
  return { success = true, filePath = p.filePath }
end

---------------------------------------------------------------------------
-- Diff review: the agent's openDiff, answered by the user
---------------------------------------------------------------------------

-- Requests answered later, by calling reply(result) or reply(nil, err).
local async_requests = {}

-- Diffs waiting for the user, by the agent's tab_name.
local diffs = {}

-- Answers the diff's openDiff ('accepted', 'rejected' or 'closed') and
-- takes its tab down.
local function finish_diff(name, outcome)
  local d = diffs[name]
  if not d then
    return
  end
  diffs[name] = nil
  local result = { outcome = outcome }
  if outcome == 'accepted' and api.nvim_buf_is_valid(d.new_buf) then
    local lines = api.nvim_buf_get_lines(d.new_buf, 0, -1, false)
    result.contents = table.concat(lines, '\n') .. (d.eol and '\n' or '')
  end
  d.reply(result)
  -- Close the tab later, so the quit in :wq still applies to the diff
  -- window.
  vim.schedule(function()
    if api.nvim_tabpage_is_valid(d.tab) and #api.nvim_list_tabpages() > 1 then
      pcall(vim.cmd, 'tabclose! ' .. api.nvim_tabpage_get_number(d.tab))
    end
    for _, buf in ipairs({ d.new_buf, d.old_buf }) do
      if api.nvim_buf_is_valid(buf) then
        pcall(api.nvim_buf_delete, buf, { force = true })
      end
    end
    if api.nvim_win_is_valid(d.from_win) then
      api.nvim_set_current_win(d.from_win)
    end
  end)
end

-- Names a diff buffer agentmux://<side>/<file>, which the tab line shows,
-- falling back to one with the tab name if a diff for the file is open.
local function name_buf(buf, side, short, tab_name)
  if not pcall(api.nvim_buf_set_name, buf, ('agentmux://%s/%s'):format(side, short)) then
    pcall(api.nvim_buf_set_name, buf, ('agentmux://%s/%s/%s'):format(side, tab_name, short))
  end
end

-- Shows the agent's proposed contents for a file next to what is on disk
-- now, in a tab of its own. The user can edit the proposal before
-- accepting it. Only the agent writes the file.
function async_requests.openDiff(p, reply)
  local name = p.tab_name or p.new_file_path
  finish_diff(name, 'closed')
  local from_win = api.nvim_get_current_win()
  if api.nvim_get_mode().mode == 't' then
    vim.cmd('stopinsert')
  end
  local path = p.new_file_path or p.old_file_path
  local old_lines = {}
  if p.old_file_path and vim.fn.filereadable(p.old_file_path) == 1 then
    old_lines = vim.fn.readfile(p.old_file_path)
  end
  local text = p.new_file_contents or ''
  local new_lines = vim.split(text, '\n', { plain = true })
  local eol = #new_lines > 1 and new_lines[#new_lines] == ''
  if eol then
    table.remove(new_lines)
  end
  local ft = vim.filetype.match({ filename = path }) or ''
  local short = vim.fn.fnamemodify(path, ':~:.')

  vim.cmd('tabnew')
  local tab = api.nvim_get_current_tabpage()
  vim.t.agentmux_diff = name
  local old_win = api.nvim_get_current_win()
  local blank = api.nvim_get_current_buf()
  local old_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(old_buf, 0, -1, false, old_lines)
  vim.bo[old_buf].modifiable = false
  vim.bo[old_buf].bufhidden = 'wipe'
  vim.bo[old_buf].filetype = ft
  name_buf(old_buf, 'now', short, name)
  api.nvim_win_set_buf(old_win, old_buf)
  pcall(api.nvim_buf_delete, blank, { force = true })

  local new_buf = api.nvim_create_buf(false, false)
  vim.bo[new_buf].buftype = 'acwrite'
  vim.bo[new_buf].bufhidden = 'wipe'
  vim.bo[new_buf].swapfile = false
  api.nvim_buf_set_lines(new_buf, 0, -1, false, new_lines)
  vim.bo[new_buf].filetype = ft
  vim.bo[new_buf].modified = false
  name_buf(new_buf, 'proposed', short, name)
  vim.cmd('rightbelow vsplit')
  local new_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(new_win, new_buf)
  for _, win in ipairs({ old_win, new_win }) do
    api.nvim_win_call(win, function()
      vim.cmd('diffthis')
    end)
  end
  vim.wo[old_win].winbar = ' Now: ' .. short
  vim.wo[new_win].winbar = ' Proposed: ' .. short .. '%=%#Comment# :w accept  :q reject '

  diffs[name] = { tab = tab, new_buf = new_buf, old_buf = old_buf, eol = eol, from_win = from_win, reply = reply }
  api.nvim_create_autocmd('BufWriteCmd', {
    buffer = new_buf,
    callback = function()
      vim.bo[new_buf].modified = false
      finish_diff(name, 'accepted')
    end,
  })
  -- Quitting the proposal (or closing the tab) rejects it.
  api.nvim_create_autocmd('BufWipeout', {
    buffer = new_buf,
    callback = function()
      vim.schedule(function()
        finish_diff(name, 'rejected')
      end)
    end,
  })
end

---------------------------------------------------------------------------
-- :AgentGitDiff: a file's git changes in a tab of their own, in diff mode
-- (the GUI's Git view opens these). The session skips these tabs when it
-- saves, since git can rebuild them.
---------------------------------------------------------------------------

-- path's lines at rev ('' for the index, or 'HEAD'), or nil when the file
-- is missing there (a new or deleted file).
local function git_show(root, rev, rel)
  local r = vim.system({ 'git', '-C', root, 'show', rev .. ':' .. rel }, { text = true }):wait()
  if r.code ~= 0 then
    return nil
  end
  local lines = vim.split(r.stdout, '\n', { plain = true })
  if lines[#lines] == '' then
    table.remove(lines)
  end
  return lines
end

-- path with symlinks resolved in its folder (/tmp is /private/tmp on
-- macOS), so it can be matched against git's top level. The file itself
-- may be gone.
local function real_path(path)
  local dir = vim.fs.dirname(path)
  return (vim.uv.fs_realpath(dir) or dir) .. '/' .. vim.fs.basename(path)
end

local function git_scratch(lines, ft, name)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = ft
  -- Another diff tab may show the same side of the same file.
  local names = {}
  for _, b in ipairs(api.nvim_list_bufs()) do
    names[api.nvim_buf_get_name(b)] = true
  end
  local unique, n = name, 1
  while names[unique] do
    n = n + 1
    unique = ('%s (%d)'):format(name, n)
  end
  pcall(api.nvim_buf_set_name, buf, unique)
  return buf
end

--- Shows path's changes in a diff tab: the index against the working file,
--- which can be edited and saved (what `git diff` shows), or with staged,
--- HEAD against the index (`git diff --cached`). old is a renamed file's
--- path in HEAD, relative to the repository or absolute.
function M.git_diff(path, staged, old)
  -- Over RPC (nvim_exec_lua), a nil argument arrives as vim.NIL, which counts as true.
  staged = staged ~= vim.NIL and staged or false
  old = old ~= vim.NIL and old or nil
  path = real_path(vim.fn.fnamemodify(path, ':p'))
  local r = vim.system({ 'git', '-C', vim.fs.dirname(path), 'rev-parse', '--show-toplevel' }, { text = true }):wait()
  if r.code ~= 0 then
    return vim.notify('agentmux: ' .. path .. ' is not in a git repository', vim.log.levels.ERROR)
  end
  local root = vim.uv.fs_realpath(vim.trim(r.stdout)) or vim.trim(r.stdout)
  local function rel_of(p)
    if p:sub(1, 1) ~= '/' then
      return p
    end
    p = real_path(p)
    return p:sub(1, #root + 1) == root .. '/' and p:sub(#root + 2) or nil
  end
  local rel = rel_of(path)
  if not rel then
    return vim.notify('agentmux: ' .. path .. ' is outside ' .. root, vim.log.levels.ERROR)
  end
  local old_rel = old and old ~= '' and rel_of(old) or rel
  local ft = vim.filetype.match({ filename = path }) or ''
  local key = path .. (staged and ' staged' or '')

  -- One tab per file and side: opening it again starts afresh.
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    if vim.t[tab].agentmux_git_diff == key and #api.nvim_list_tabpages() > 1 then
      vim.cmd('tabclose ' .. api.nvim_tabpage_get_number(tab))
    end
  end
  if api.nvim_get_mode().mode == 't' then
    vim.cmd('stopinsert')
  end
  vim.cmd('tabnew')
  local tab = api.nvim_get_current_tabpage()
  vim.t.agentmux_git_diff = key
  local right_win = api.nvim_get_current_win()
  local blank = api.nvim_get_current_buf()
  local right_label
  if staged then
    api.nvim_win_set_buf(right_win, git_scratch(git_show(root, '', rel) or {}, ft, 'git://index/' .. rel))
    right_label = ' Index: ' .. rel
  elseif uv.fs_stat(path) then
    vim.cmd.edit(vim.fn.fnameescape(path))
    right_label = ' Working tree: ' .. rel .. '%=%#Comment# :w saves it  :q closes the diff '
  else
    api.nvim_win_set_buf(right_win, git_scratch({}, ft, 'git://deleted/' .. rel))
    right_label = ' Deleted: ' .. rel
  end
  if api.nvim_buf_is_valid(blank) and blank ~= api.nvim_win_get_buf(right_win) then
    pcall(api.nvim_buf_delete, blank, { force = true })
  end
  vim.cmd('leftabove vsplit')
  local left_win = api.nvim_get_current_win()
  local left_name = staged and 'HEAD' or 'index'
  api.nvim_win_set_buf(left_win, git_scratch(git_show(root, staged and 'HEAD' or '', old_rel) or {}, ft,
    ('git://%s/%s'):format(left_name, old_rel)))
  for _, win in ipairs({ left_win, right_win }) do
    api.nvim_win_call(win, function()
      vim.cmd('diffthis')
    end)
  end
  vim.wo[left_win].winbar = (staged and ' HEAD: ' or ' Index: ') .. old_rel
  vim.wo[right_win].winbar = right_label
  api.nvim_set_current_win(right_win)

  -- Closing either side closes the whole tab.
  api.nvim_create_autocmd('WinClosed', {
    pattern = { tostring(left_win), tostring(right_win) },
    once = true,
    callback = function()
      vim.schedule(function()
        if api.nvim_tabpage_is_valid(tab) and #api.nvim_list_tabpages() > 1 then
          vim.cmd('tabclose ' .. api.nvim_tabpage_get_number(tab))
        end
      end)
    end,
  })
end

-- The agent decided (in its own UI) or gave up: drop the diff.
function requests.close_tab(p)
  finish_diff(p.tab_name, 'closed')
  return {}
end

function requests.closeAllDiffTabs()
  for name in pairs(diffs) do
    finish_diff(name, 'closed')
  end
  return {}
end

-- :AgentAccept / :AgentReject in a diff tab.
function M.decide_diff(outcome)
  local name = vim.t.agentmux_diff
  if not (name and diffs[name]) then
    return vim.notify('agentmux: no agent diff in this tab', vim.log.levels.ERROR)
  end
  finish_diff(name, outcome)
end

local function on_message(msg)
  if msg.type == 'ide' then
    link.ide = msg.connected == true
    link.mentions = link.ide and msg.mentions == true
    if link.ide then
      send_selection(true)
    elseif msg.ide == 'pi' and not link.hinted then
      -- pi needs the pi-ide extension to connect, and users easily miss it.
      link.hinted = true
      vim.defer_fn(function()
        if not link.ide then
          vim.notify('agentmux: pi is not connected to the editor, so it does not see the open file. '
            .. 'Install pi-ide (pi install npm:@ldelossa/pi-ide), then :AgentRestart.', vim.log.levels.WARN)
        end
      end, 15000)
    end
  elseif msg.type == 'request' and async_requests[msg.method] then
    local done = false
    local function reply(res, err)
      if not done then
        done = true
        link_send({ type = 'response', id = msg.id, result = res, error = err })
      end
    end
    local ok, err = pcall(async_requests[msg.method], msg.params, reply)
    if not ok then
      reply(nil, tostring(err))
    end
  elseif msg.type == 'request' then
    local f = requests[msg.method]
    local ok, res = false, 'unknown request ' .. tostring(msg.method)
    if f then
      ok, res = pcall(f, msg.params)
    end
    if ok then
      link_send({ type = 'response', id = msg.id, result = res })
    else
      link_send({ type = 'response', id = msg.id, error = tostring(res) })
    end
  end
end

local function on_read(err, data)
  if err or not data then
    vim.schedule(function()
      if link.pipe then
        link.pipe:close()
      end
      link.pipe, link.buf, link.ide, link.mentions, link.last_sel = nil, '', false, false, nil
    end)
    return
  end
  link.buf = link.buf .. data
  while #link.buf >= 5 do
    local b1, b2, b3, b4 = link.buf:byte(2, 5)
    local n = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    if #link.buf < 5 + n then
      break
    end
    local typ, payload = link.buf:sub(1, 1), link.buf:sub(6, 5 + n)
    link.buf = link.buf:sub(6 + n)
    if typ == 'E' then
      vim.schedule(function()
        local ok, msg = pcall(vim.json.decode, payload)
        if ok then
          on_message(msg)
        end
      end)
    end
  end
end

-- Keeps a link to the holder open. The holder restarts with the agent, so
-- the link retries every couple of seconds while it is down.
local function link_connect()
  local path = vim.env.AGENTMUX_HOLDER_SOCK
  if link.pipe or link.connecting or not path then
    return
  end
  link.connecting = true
  local pipe = assert(uv.new_pipe(false))
  pipe:connect(path, function(err)
    vim.schedule(function()
      link.connecting = false
      if err then
        pipe:close()
        return
      end
      link.pipe = pipe
      pipe:write(frame('H', 'editor'))
      pipe:read_start(on_read)
      -- The holder takes the newest link as the editor in use; after it
      -- restarts, say which of the two the user had turned to.
      if vim.trim(read_file(dir .. '/editor-active') or '') == kind then
        link_send({ type = 'focus' })
      end
    end)
  end)
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function run(args, opts)
  local r = vim.system(vim.list_extend({ bin }, args), opts or { text = true }):wait()
  if r.code ~= 0 then
    error(vim.trim(r.stderr or ''), 0)
  end
  return vim.trim(r.stdout or '')
end

-- Sends an @file reference for the buffer (and line range) to the agent:
-- as an IDE at-mention when the agent is connected and takes them (Claude
-- takes them; pi-ide gets text), or else as typed text.
local function send(o)
  local name = api.nvim_buf_get_name(0)
  local parts = {}
  if link.mentions and is_file_buf(0) and name ~= '' then
    local params = { filePath = name }
    if o.range > 0 then
      params.lineStart, params.lineEnd = o.line1 - 1, o.line2 - 1
    end
    link_send({ type = 'at_mentioned', params = params })
    name = ''
  end
  if is_file_buf(0) and name ~= '' then
    local ref = '@' .. vim.fn.fnamemodify(name, ':.')
    if o.range > 0 then
      ref = ref .. (o.line1 == o.line2 and ('#L%d'):format(o.line1) or ('#L%d-%d'):format(o.line1, o.line2))
    end
    parts[#parts + 1] = ref
  end
  if o.args ~= '' then
    parts[#parts + 1] = o.args
  end
  if #parts > 0 or o.bang then
    local text = #parts > 0 and (table.concat(parts, ' ') .. ' ') or ''
    local args = o.bang and { 'send', '-s', id, '-enter' } or { 'send', '-s', id }
    local ok, err = pcall(run, args, { stdin = text, text = true })
    if not ok then
      vim.notify('agentmux: ' .. err, vim.log.levels.ERROR)
      return
    end
  end
  if not o.bang then
    M.focus_agent()
  end
end

-- Handoff files of launchers that joined this editor as extra UIs, on top
-- of AGENTMUX_HANDOFF from the one that started it.
local joined = {}

function M.add_handoff(json)
  local path = vim.json.decode(json).path
  if not vim.tbl_contains(joined, path) then
    table.insert(joined, path)
  end
  return 0
end

-- Asks the launcher to run line ('open <id>', 'delete <id>', or '' to just
-- leave) once this editor has quit.
local function handoff(line)
  if #api.nvim_list_uis() > 1 then
    -- Quitting would close the editor in the other terminals too.
    if line == '' then
      vim.cmd('detach')
      return
    end
    return vim.notify('agentmux: this editor is also open in another terminal; '
      .. 'run :AgentSession detach there first', vim.log.levels.ERROR)
  end
  -- The launcher of the one UI left is the one whose file still exists:
  -- launchers remove theirs when they exit.
  local path
  for _, p in ipairs({ vim.env.AGENTMUX_HANDOFF, unpack(joined) }) do
    if uv.fs_stat(p) then
      path = p
      break
    end
  end
  if line ~= '' and not path then
    return vim.notify('agentmux: no launcher to hand off to; :qa and run agentmux attach', vim.log.levels.ERROR)
  end
  M.save()
  if line ~= '' then
    local f = assert(io.open(path, 'a'))
    f:write(line .. '\n')
    f:close()
  end
  vim.cmd('qall!')
end

-- For GUIs: `agentmux ls -json` on this editor's machine, as a string.
-- Raises agentmux's error message when it fails.
function M.sessions()
  return run({ 'ls', '-json' })
end

local session_cmds = {}

function session_cmds.ls()
  local ok, out = pcall(run, { 'ls' })
  vim.notify(ok and out or ('agentmux: ' .. out))
end

function session_cmds.new(args)
  local cmd = { 'new', '-detached', '-cwd', vim.fn.getcwd(-1, -1) }
  if args[1] then
    vim.list_extend(cmd, { '-agent', args[1] })
  end
  if args[2] then
    vim.list_extend(cmd, { '-name', args[2] })
  end
  local ok, new_id = pcall(run, cmd)
  if not ok then
    return vim.notify('agentmux: ' .. new_id, vim.log.levels.ERROR)
  end
  handoff('open ' .. new_id)
end

function session_cmds.switch(args)
  if not args[1] then
    return vim.notify('usage: AgentSession switch <session>', vim.log.levels.ERROR)
  end
  handoff('open ' .. args[1])
end

function session_cmds.detach()
  handoff('')
end

function session_cmds.delete(args, bang)
  local ref = args[1]
  if ref and ref ~= id then
    local ok, err = pcall(run, bang and { 'delete', '-force', ref } or { 'delete', ref })
    vim.notify(ok and ('agentmux: deleted ' .. ref) or ('agentmux: ' .. err), ok and nil or vim.log.levels.ERROR)
    return
  end
  local dirty = 0
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if is_file_buf(buf) and vim.bo[buf].modified then
      dirty = dirty + 1
    end
  end
  local msg = ('Delete this session (%s)? This stops the agent'):format(id)
  if dirty > 0 then
    msg = msg .. (' and discards %d unsaved buffer(s)'):format(dirty)
  end
  if bang or vim.fn.confirm(msg .. '.', '&Delete\n&Cancel', 2) == 1 then
    handoff('delete ' .. id)
  end
end

function M.setup()
  set_options()
  vim.g.agentmux_session = id
  vim.g.agentmux_ui = gui and 'gui' or 'terminal'
  -- For statuslines: the session's name (its id if it has none) and agent.
  local ok, meta = pcall(vim.json.decode, read_file(dir .. '/meta.json') or '')
  meta = ok and type(meta) == 'table' and meta or {}
  vim.g.agentmux_name = (meta.name or '') ~= '' and meta.name or id
  vim.g.agentmux_agent = meta.agent

  local group = api.nvim_create_augroup('agentmux', {})
  api.nvim_create_autocmd('VimEnter', { group = group, nested = true, callback = start })
  if gui then
    api.nvim_create_autocmd({ 'ChanInfo', 'UIEnter' }, {
      group = group,
      callback = function()
        vim.schedule(use_gui_clipboard)
      end,
    })
  end
  api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      save_timer:stop()
      -- Save only while a UI is attached. Without one, nvim is exiting
      -- because its terminal went away, and it has already unloaded the
      -- buffers, so the last snapshot is the one to keep.
      if #api.nvim_list_uis() > 0 then
        M.save()
      end
    end,
  })
  api.nvim_create_autocmd({
    'WinNew', 'WinClosed', 'WinResized', 'TabNew', 'TabClosed', 'BufWinEnter', 'BufAdd',
    'BufDelete', 'BufWritePost', 'TextChanged', 'TextChangedI',
    'CursorHold', 'CursorHoldI', 'DirChanged', 'FocusLost',
  }, { group = group, callback = schedule_save })
  api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function()
      vim.schedule(keep_editor)
    end,
  })
  api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost', 'FileChangedShellPost' }, {
    group = group,
    callback = function(ev)
      if not restoring and is_file_buf(ev.buf) then
        vim.b[ev.buf].agentmux_base = file_hash(api.nvim_buf_get_name(ev.buf))
      end
    end,
  })
  -- Terminals (the agent's, and any :terminal) take typing as soon as you
  -- enter them. Skip a terminal whose job has exited, because there a key
  -- closes the window.
  local function live_terminal(buf)
    return vim.bo[buf].buftype == 'terminal' and vim.fn.jobwait({ vim.bo[buf].channel }, 0)[1] == -1
  end
  api.nvim_create_autocmd('TermOpen', {
    group = group,
    callback = function(ev)
      -- Only for a terminal opened in the current window. The agent's
      -- terminal starts in a hidden buffer.
      if api.nvim_get_current_buf() == ev.buf and api.nvim_win_get_config(0).relative == '' then
        vim.cmd.startinsert()
      end
    end,
  })
  api.nvim_create_autocmd({ 'WinEnter', 'BufEnter' }, {
    group = group,
    callback = function(ev)
      local buf = api.nvim_get_current_buf()
      if is_file_buf(buf) then
        last_editor_win = api.nvim_get_current_win()
      elseif (ev.event == 'WinEnter' or not is_agent(buf)) and live_terminal(buf) then
        vim.cmd.startinsert()
      end
    end,
  })
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'ModeChanged', 'BufEnter', 'WinEnter' }, {
    group = group,
    callback = schedule_selection,
  })
  api.nvim_create_autocmd('FocusGained', { group = group, callback = mark_active })
  api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold' }, {
    group = group,
    callback = function()
      reload_unmodified()
    end,
  })
  -- Keeps the link to the holder up, and picks up the agent's file edits
  -- even while the user is typing in the agent pane.
  link_timer:start(0, 2000, vim.schedule_wrap(function()
    link_connect()
    if api.nvim_get_mode().mode:sub(1, 1) ~= 'c' then
      reload_unmodified()
    end
  end))

  api.nvim_create_user_command('AgentSend', send, {
    range = true, bang = true, nargs = '*',
    desc = 'Send an @file reference (and text) to the agent; ! also presses Enter',
  })
  api.nvim_create_user_command('AgentFocus', M.focus_agent, { desc = 'Jump to the agent pane' })
  api.nvim_create_user_command('AgentGitDiff', function(o)
    local path = o.args ~= '' and vim.fn.expand(o.args) or api.nvim_buf_get_name(0)
    if path == '' then
      return vim.notify('agentmux: no file to diff', vim.log.levels.ERROR)
    end
    M.git_diff(path, o.bang)
  end, { nargs = '?', bang = true, complete = 'file', desc = "Show a file's git changes in a diff tab; ! for the staged ones" })
  api.nvim_create_user_command('AgentPreview', function(o)
    if not gui then
      return vim.notify('agentmux: :AgentPreview needs the GUI (agentmux serve)', vim.log.levels.ERROR)
    end
    local path = o.args ~= '' and vim.fn.fnamemodify(vim.fn.expand(o.args), ':p') or api.nvim_buf_get_name(0)
    if path == '' then
      return vim.notify('agentmux: no file to preview', vim.log.levels.ERROR)
    end
    gui_notify('preview', { path = path })
  end, { nargs = '?', complete = 'file', desc = 'Show a file (image, video, HTML) in the browser, through the GUI' })
  api.nvim_create_user_command('AgentAccept', function()
    M.decide_diff('accepted')
  end, { desc = "Accept the agent's proposed change shown in this tab (as edited here)" })
  api.nvim_create_user_command('AgentReject', function()
    M.decide_diff('rejected')
  end, { desc = "Reject the agent's proposed change shown in this tab" })
  -- For the user's own keys, e.g.
  --   vim.keymap.set({ 'n', 'x' }, '<leader>as', '<Plug>(agentmux-send)')
  vim.keymap.set('x', '<Plug>(agentmux-send)', ':AgentSend<CR>', { silent = true, desc = 'Send the selection to the agent' })
  vim.keymap.set('n', '<Plug>(agentmux-send)', '<Cmd>AgentSend<CR>', { desc = 'Send the current file to the agent' })
  vim.keymap.set('n', '<Plug>(agentmux-send-line)', '<Cmd>.AgentSend<CR>', { desc = 'Send the current line to the agent' })
  api.nvim_create_user_command('AgentEditor', M.focus_editor, {
    desc = 'Jump to the editor window, bringing one back if only the agent is showing',
  })
  api.nvim_create_user_command('AgentToggle', M.toggle_agent, { desc = 'Show or hide the agent pane' })
  api.nvim_create_user_command('AgentRestart', M.restart_agent, { desc = 'Reattach (and resume) the agent' })
  api.nvim_create_user_command('AgentDiffDisk', function()
    local path = api.nvim_buf_get_name(0)
    local ft = vim.bo.filetype
    vim.cmd('diffthis | vertical leftabove new')
    vim.bo.buftype, vim.bo.bufhidden, vim.bo.filetype = 'nofile', 'wipe', ft
    api.nvim_buf_set_lines(0, 0, -1, false, vim.fn.readfile(path))
    api.nvim_buf_set_name(0, 'disk://' .. vim.fn.fnamemodify(path, ':.'))
    vim.cmd('diffthis | wincmd p')
  end, { desc = 'Diff the buffer against the file on disk' })
  api.nvim_create_user_command('AgentSession', function(o)
    local sub = table.remove(o.fargs, 1) or 'ls'
    local f = session_cmds[sub]
    if not f then
      return vim.notify('agentmux: unknown subcommand ' .. sub, vim.log.levels.ERROR)
    end
    f(o.fargs, o.bang)
  end, {
    nargs = '*', bang = true,
    complete = function(lead, line)
      if #vim.split(line, '%s+') <= 2 then
        return vim.tbl_filter(function(c)
          return vim.startswith(c, lead)
        end, vim.tbl_keys(session_cmds))
      end
      return {}
    end,
    desc = 'agentmux sessions: ls | new [agent] [name] | switch <s> | delete[!] [s] | detach',
  })
end

return M
