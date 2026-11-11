-- ngam's file watchers. This runs inside nvim: ngam sends it with
-- nvim_exec_lua each time it attaches to a session, so it watches the files
-- on nvim's machine, even over ssh. It keeps its state in _G.__ngam_watch.
--
-- It watches folders. Many editors and agents save a file by writing a
-- new file and renaming it over the old one. That ends a watch on the old
-- file, but a watch on its folder sees the rename and keeps going.
--
-- Two kinds of folders are watched:
--   * the folders of files the preview server served. A change to one of
--     those files is sent to ngam as the notification
--     ('ngam', 'file_changed', path), with the path as ngam gave it.
--   * the folders the Explorer shows. A file made, deleted or renamed in
--     one is sent as ('ngam', 'dir_changed', folder).
-- Changes are gathered for 100 ms and then sent, once per path.
--
-- A file stops being watched 3 minutes after the last request for it, and
-- a folder with nothing left to watch is dropped. The preview server asks
-- again each minute for the files of pages that are open in a browser.

local uv = vim.uv or vim.loop

local old = rawget(_G, '__ngam_watch')
if old then
  old.stop_all()
end

local W = {
  files = {}, -- path -> {dir = folder, name = file name, used = ms}
  dirs = {}, -- folder -> {handle = fs_event or nil, names = {name -> {path -> true}}, explorer = bool}
  pending_files = {},
  pending_dirs = {},
}
_G.__ngam_watch = W

local FORGET_MS = 180 * 1000 -- forget a file not asked for in this long
local SWEEP_MS = 60 * 1000
local GATHER_MS = 100

local flush_timer = uv.new_timer()
local sweep_timer = uv.new_timer()

-- ngam's channel: the UI whose client calls itself ngam.
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

local function flush()
  local files, dirs = W.pending_files, W.pending_dirs
  W.pending_files, W.pending_dirs = {}, {}
  local chan = ngam_chan()
  if not chan then
    return
  end
  for path in pairs(files) do
    vim.rpcnotify(chan, 'ngam', 'file_changed', path)
  end
  for dir in pairs(dirs) do
    vim.rpcnotify(chan, 'ngam', 'dir_changed', dir)
  end
end

-- Sends what has gathered after GATHER_MS. Later changes leave the running
-- timer alone, so a file that changes all the time still gets sent.
local function soon()
  if not flush_timer:is_active() then
    flush_timer:start(GATHER_MS, 0, vim.schedule_wrap(flush))
  end
end

-- on_event runs for each change in a watched folder. name is the file's
-- name in the folder; libuv may leave it empty when it cannot tell.
local function on_event(dir, name, events)
  local d = W.dirs[dir]
  if not d then
    return
  end
  if name and name ~= '' then
    name = name:match('[^/]+$') or name
    for path in pairs(d.names[name] or {}) do
      W.pending_files[path] = true
    end
  else
    for _, paths in pairs(d.names) do
      for path in pairs(paths) do
        W.pending_files[path] = true
      end
    end
  end
  -- Writing to a file is a 'change'; making, deleting or renaming one is a
  -- 'rename'. Only the second changes what the Explorer lists.
  if d.explorer and (events.rename or not name or name == '') then
    W.pending_dirs[dir] = true
  end
  soon()
end

-- arm starts watching a folder if it exists and has no watch yet. A
-- folder that was deleted and made again is a new folder (a new inode),
-- which the old watch misses, so arm watches it again.
local function arm(dir, d)
  local st = uv.fs_stat(dir)
  if d.handle and (not st or st.ino ~= d.ino) then
    d.handle:stop()
    d.handle:close()
    d.handle = nil
  end
  if d.handle or not st or st.type ~= 'directory' then
    return
  end
  local h = uv.new_fs_event()
  local ok = h:start(dir, {}, function(err, name, events)
    if not err then
      on_event(dir, name, events or {})
    end
  end)
  if ok then
    d.handle = h
    d.ino = st.ino
  else
    h:close()
  end
end

local function get_dir(dir)
  local d = W.dirs[dir]
  if not d then
    d = { names = {}, explorer = false }
    W.dirs[dir] = d
  end
  arm(dir, d)
  return d
end

local function drop_dir_if_unused(dir)
  local d = W.dirs[dir]
  if d and not d.explorer and next(d.names) == nil then
    if d.handle then
      d.handle:stop()
      d.handle:close()
    end
    W.dirs[dir] = nil
  end
end

-- W.watch_files(paths): watch these files, or note that they are still
-- wanted. Paths are absolute.
function W.watch_files(paths)
  local now = uv.now()
  for _, path in ipairs(paths) do
    local f = W.files[path]
    if f then
      f.used = now
      get_dir(f.dir) -- watches the folder again if it was made again
    else
      local norm = vim.fs.normalize(path)
      local dir, name = vim.fs.dirname(norm), vim.fs.basename(norm)
      local d = get_dir(dir)
      d.names[name] = d.names[name] or {}
      d.names[name][path] = true
      W.files[path] = { dir = dir, name = name, used = now }
    end
  end
end

-- W.explorer(dirs) sets the folders the Explorer shows. Folders it has
-- dropped stop being watched for it.
function W.explorer(dirs)
  local want = {}
  for _, dir in ipairs(dirs) do
    want[dir] = true
  end
  for dir, d in pairs(W.dirs) do
    if d.explorer and not want[dir] then
      d.explorer = false
      drop_dir_if_unused(dir)
    end
  end
  for dir in pairs(want) do
    get_dir(dir).explorer = true
  end
end

-- sweep forgets files not asked for in a while, and watches again folders
-- that did not exist before or were made again.
local function sweep()
  local now = uv.now()
  for path, f in pairs(W.files) do
    if now - f.used > FORGET_MS then
      local d = W.dirs[f.dir]
      if d and d.names[f.name] then
        d.names[f.name][path] = nil
        if next(d.names[f.name]) == nil then
          d.names[f.name] = nil
        end
      end
      W.files[path] = nil
      drop_dir_if_unused(f.dir)
    end
  end
  for dir, d in pairs(W.dirs) do
    arm(dir, d)
  end
end

function W.stop_all()
  flush_timer:stop()
  sweep_timer:stop()
  for _, d in pairs(W.dirs) do
    if d.handle then
      d.handle:stop()
      d.handle:close()
    end
  end
  W.dirs, W.files = {}, {}
end

sweep_timer:start(SWEEP_MS, SWEEP_MS, vim.schedule_wrap(sweep))
