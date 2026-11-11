-- ngam's line blame. This runs inside nvim: ngam sends it with
-- nvim_exec_lua each time it attaches to a session, so git runs on nvim's
-- machine, even over ssh. It keeps its state in _G.__ngam_blame.
--
-- While it is on, when the cursor rests on a line of a file for BLAME_MS,
-- it runs `git blame` for that line and sends the result to ngam as
-- ('ngam', 'blame', {line, sha, author, when, summary, committed}). ngam
-- shows it in a small card under the cursor. Moving the cursor, scrolling,
-- typing or leaving the buffer sends ('ngam', 'blame_hide').
--
-- It gives git the buffer's text (--contents -), so line numbers stay
-- right with unsaved edits. An uncommitted line says so.
--
-- A click on the card's hash calls __ngam_blame.detail(), which sends
-- ('ngam', 'blame_detail', {...}) with the whole commit message and the
-- files it changed, each with its lines added and removed. It leaves out
-- the diff, which can be huge. It lists at most MAX_FILES files.
--
-- ngam turns it on and off with __ngam_blame.enable(bool).

local old = rawget(_G, '__ngam_blame')
if old then
  old.stop()
end

local uv = vim.uv or vim.loop
local BLAME_MS = 400
local MAX_FILES = 300
local group = vim.api.nvim_create_augroup('ngam_blame', { clear = true })

local M = {
  on = false,
  shown = false, -- ngam is showing a card
  seq = 0, -- each move adds one, so a late answer for an old line gets dropped
  timer = uv.new_timer(),
}
_G.__ngam_blame = M

local function ngam_chan()
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    if ui.chan and ui.chan > 0 then
      local info = vim.api.nvim_get_chan_info(ui.chan)
      if info.client and info.client.name == 'ngam' then
        return ui.chan
      end
    end
  end
end

local function notify(...)
  local chan = ngam_chan()
  if chan then
    vim.rpcnotify(chan, 'ngam', ...)
  end
end

-- ago says how long ago t was, as "3 days ago".
local function ago(t)
  local s = os.time() - t
  local units = {
    { 365 * 86400, 'year' }, { 30 * 86400, 'month' }, { 7 * 86400, 'week' },
    { 86400, 'day' }, { 3600, 'hour' }, { 60, 'minute' },
  }
  for _, u in ipairs(units) do
    if s >= u[1] then
      local n = math.floor(s / u[1])
      return n .. ' ' .. u[2] .. (n == 1 and '' or 's') .. ' ago'
    end
  end
  return 'just now'
end

local function hide()
  M.seq = M.seq + 1
  M.timer:stop()
  if M.shown then
    M.shown = false
    notify('blame_hide')
  end
end

local function blame_now()
  if not M.on or vim.fn.mode() ~= 'n' then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= '' or path == '' then
    return
  end
  local dir, name = vim.fs.dirname(path), vim.fs.basename(path)
  if vim.fn.isdirectory(dir) == 0 then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n'
  local seq = M.seq
  vim.system({ 'git', 'blame', '--porcelain', '-L', lnum .. ',' .. lnum, '--contents', '-', '--', name },
    { cwd = dir, stdin = text, text = true }, function(r)
      vim.schedule(function()
        if seq ~= M.seq or not M.on or r.code ~= 0 then
          return -- the cursor moved on, or the file is untracked
        end
        local sha = r.stdout:match('^(%x+)')
        if not sha then
          return
        end
        local author = r.stdout:match('\nauthor ([^\n]*)') or ''
        local time = tonumber(r.stdout:match('\nauthor%-time (%d+)') or '')
        local summary = r.stdout:match('\nsummary ([^\n]*)') or ''
        local committed = not sha:match('^0+$')
        M.last = committed and { sha = sha, dir = dir } or nil
        M.shown = true
        notify('blame', {
          line = lnum,
          sha = committed and sha:sub(1, 8) or '',
          author = committed and author or 'You',
          when = (committed and time) and ago(time) or '',
          summary = committed and summary or 'Not committed yet',
          committed = committed,
        })
      end)
    end)
end

-- moved hides the card and starts the wait for the next one.
local function moved()
  hide()
  if M.on and vim.fn.mode() == 'n' then
    M.timer:start(BLAME_MS, 0, vim.schedule_wrap(blame_now))
  end
end

-- split_z splits git's -z output at its NULs.
local function split_z(s)
  local out = {}
  for part in (s or ''):gmatch('([^%z]*)%z') do
    out[#out + 1] = part
  end
  return out
end

-- detail sends the last blamed commit's message and the files it changed.
function M.detail()
  local last = M.last
  if not last then
    return
  end
  local function fail(msg)
    notify('blame_detail', { sha = last.sha, error = msg })
  end
  local fmt = '--format=%H%x00%an%x00%ae%x00%at%x00%ad%x00%cn%x00%B%x00'
  local cmd = { 'git', 'show', '--no-color', '-M', '-m', '--first-parent', '--name-status', '-z',
    '--date=format:%a %d %b %Y %H:%M', fmt, last.sha }
  vim.system(cmd, { cwd = last.dir, text = true }, function(r)
    if r.code ~= 0 then
      vim.schedule(function() fail(vim.trim(r.stderr or 'git show failed')) end)
      return
    end
    local f = split_z(r.stdout)
    -- The seven fields of the format, then the status and path(s) of each
    -- file: "M", path; or "R100", old, new.
    local info = {
      sha = f[1] or last.sha, author = f[2] or '', email = f[3] or '',
      when = tonumber(f[4] or '') and ago(tonumber(f[4])) or '', date = f[5] or '',
      committer = f[6] or '', message = vim.trim(f[7] or ''),
    }
    local files, i = {}, 8
    while i <= #f do
      local st = vim.trim(f[i])
      if st == '' then
        i = i + 1
      else
        local two = st:match('^[RC]')
        local path = two and f[i + 2] or f[i + 1]
        files[#files + 1] = { status = st:sub(1, 1), path = path or '', from = two and f[i + 1] or '', add = -1, del = -1, binary = false }
        i = i + (two and 3 or 2)
      end
    end
    -- A second, cheap git call gives the lines added and removed.
    vim.system({ 'git', 'show', '--no-color', '-M', '-m', '--first-parent', '--numstat', '-z', '--format=', last.sha },
      { cwd = last.dir, text = true }, function(r2)
        vim.schedule(function()
          if r2.code == 0 then
            local counts, n = {}, split_z(r2.stdout)
            local j = 1
            while j <= #n do
              local a, d, p = n[j]:match('^%s*(%S+)\t(%S+)\t(.*)$')
              if not a then
                j = j + 1
              else
                if p == '' then -- a rename: the old and new paths follow
                  p = n[j + 2] or ''
                  j = j + 3
                else
                  j = j + 1
                end
                counts[p] = { tonumber(a) or -1, tonumber(d) or -1, a == '-' } -- "-" for a binary file
              end
            end
            for _, x in ipairs(files) do
              local c = counts[x.path]
              if c then
                x.add, x.del, x.binary = c[1], c[2], c[3]
              end
            end
          end
          info.total = #files
          if #files > MAX_FILES then
            for k = #files, MAX_FILES + 1, -1 do
              files[k] = nil
            end
          end
          info.files = files
          notify('blame_detail', info)
        end)
      end)
  end)
end

function M.enable(on)
  M.on = on
  if on then
    moved()
  else
    hide()
  end
end

function M.stop()
  M.on = false
  M.timer:stop()
  M.timer:close()
  pcall(vim.api.nvim_del_augroup_by_id, group)
end

vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufEnter', 'WinScrolled', 'InsertLeave', 'TextChanged' }, {
  group = group,
  callback = moved,
})
vim.api.nvim_create_autocmd({ 'CursorMovedI', 'InsertEnter', 'BufLeave', 'WinLeave', 'FocusLost' }, {
  group = group,
  callback = hide,
})
