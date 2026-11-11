-- ngam's change bars. This runs inside nvim: ngam sends it with
-- nvim_exec_lua each time it attaches to a session, so git runs on nvim's
-- machine, even over ssh. It keeps its state in _G.__ngam_changes.
--
-- For each file buffer it asks git for the file as it is in the index
-- (`git show :./name`), compares that with the buffer's lines using nvim's
-- own diff, and puts a sign beside each changed line:
--   * ▎ in NgamChangeAdd (green) on added lines,
--   * ▎ in NgamChangeChange (blue) on changed lines,
--   * ▁ in NgamChangeDelete (red) on the line above removed lines, or ▔
--     on the first line when lines were removed from the top.
-- It compares the buffer, so the bars follow unsaved edits. Only files
-- that git tracks get bars.
--
-- The highlight groups are set with default = true, so a colour scheme or
-- the user's config can change them. ngam draws the block characters as
-- exact rectangles.
--
-- ngam turns the bars on and off with __ngam_changes.enable(bool), and
-- calls __ngam_changes.refresh() when `git status` changes (a commit or
-- `git add` changes the index the buffers are compared with).

local old = rawget(_G, '__ngam_changes')
if old then
  old.stop()
end

local uv = vim.uv or vim.loop
local diff = (vim.text and vim.text.diff) or vim.diff
local ns = vim.api.nvim_create_namespace('ngam_changes')
local group = vim.api.nvim_create_augroup('ngam_changes', { clear = true })

local M = {
  on = false,
  bases = {}, -- buffer -> the file's text in git's index
  timers = {}, -- buffer -> the timer that delays a redraw while typing
}
_G.__ngam_changes = M

local function set_hl()
  vim.api.nvim_set_hl(0, 'NgamChangeAdd', { fg = '#3fb950', default = true })
  vim.api.nvim_set_hl(0, 'NgamChangeChange', { fg = '#4c8df6', default = true })
  vim.api.nvim_set_hl(0, 'NgamChangeDelete', { fg = '#f85149', default = true })
end

local function is_file(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == '' and vim.api.nvim_buf_get_name(buf) ~= ''
end

local function place(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local base = M.bases[buf]
  if not M.on or not base then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, '\n') .. '\n'
  local ok, hunks = pcall(diff, base, text, { result_type = 'indices' })
  if not ok then
    return
  end
  local n = #lines
  local function sign(lnum, char, hl)
    if lnum >= 1 and lnum <= n then
      vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0,
        { sign_text = char, sign_hl_group = hl, priority = 6 })
    end
  end
  for _, h in ipairs(hunks) do
    local count_a, start_b, count_b = h[2], h[3], h[4]
    if count_a == 0 then
      for l = start_b, start_b + count_b - 1 do
        sign(l, '▎', 'NgamChangeAdd')
      end
    elseif count_b == 0 then
      -- start_b is the line above the removed ones.
      if start_b == 0 then
        sign(1, '▔', 'NgamChangeDelete')
      else
        sign(start_b, '▁', 'NgamChangeDelete')
      end
    else
      for l = start_b, start_b + count_b - 1 do
        sign(l, '▎', 'NgamChangeChange')
      end
    end
  end
end

-- load_base asks git for buf's file as it is in the index, then places
-- the signs.
local function load_base(buf)
  if not M.on or not is_file(buf) then
    return
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local dir, name = vim.fs.dirname(path), vim.fs.basename(path)
  if vim.fn.isdirectory(dir) == 0 then
    return
  end
  vim.system({ 'git', 'show', ':./' .. name }, { cwd = dir, text = true }, function(r)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      M.bases[buf] = r.code == 0 and r.stdout or nil
      place(buf)
    end)
  end)
end

-- soon places the signs a moment after the last edit.
local function soon(buf)
  local t = M.timers[buf]
  if not t then
    t = uv.new_timer()
    M.timers[buf] = t
  end
  t:stop()
  t:start(150, 0, vim.schedule_wrap(function()
    place(buf)
  end))
end

-- With 'signcolumn' set to "auto", the text jumps sideways when the first
-- change appears, so it is "yes" while the bars are on.
local function fix_signcolumn(win)
  if vim.api.nvim_win_is_valid(win) and vim.wo[win].signcolumn == 'auto' then
    vim.w[win].ngam_signcolumn = 'auto'
    vim.wo[win].signcolumn = 'yes'
  end
end

local function restore_signcolumns()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win].ngam_signcolumn then
      vim.wo[win].signcolumn = vim.w[win].ngam_signcolumn
      vim.w[win].ngam_signcolumn = nil
    end
  end
end

-- refresh reads every file buffer's base again.
function M.refresh()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    load_base(buf)
  end
end

function M.enable(on)
  M.on = on
  if on then
    set_hl()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if is_file(vim.api.nvim_win_get_buf(win)) then
        fix_signcolumn(win)
      end
    end
    M.refresh()
  else
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      end
    end
    M.bases = {}
    restore_signcolumns()
  end
end

function M.stop()
  M.on = false
  for _, t in pairs(M.timers) do
    t:stop()
    t:close()
  end
  M.timers = {}
  pcall(vim.api.nvim_del_augroup_by_id, group)
end

vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost', 'BufFilePost' }, {
  group = group,
  callback = function(ev)
    load_base(ev.buf)
  end,
})
vim.api.nvim_create_autocmd('BufEnter', {
  group = group,
  callback = function(ev)
    if M.on and M.bases[ev.buf] == nil then
      load_base(ev.buf)
    end
  end,
})
vim.api.nvim_create_autocmd('BufWinEnter', {
  group = group,
  callback = function(ev)
    if M.on and is_file(ev.buf) then
      fix_signcolumn(vim.api.nvim_get_current_win())
    end
  end,
})
vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
  group = group,
  callback = function(ev)
    if M.on and M.bases[ev.buf] then
      soon(ev.buf)
    end
  end,
})
vim.api.nvim_create_autocmd('FocusGained', {
  group = group,
  callback = function()
    if M.on then
      M.refresh()
    end
  end,
})
vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_hl })
vim.api.nvim_create_autocmd('BufWipeout', {
  group = group,
  callback = function(ev)
    M.bases[ev.buf] = nil
    local t = M.timers[ev.buf]
    if t then
      t:stop()
      t:close()
      M.timers[ev.buf] = nil
    end
  end,
})
