package ngam

// The Buffers area at the bottom of the Explorer: the files open in nvim, as
// with `:ls`, each with its buffer number. A click shows the buffer in
// nvim's current window; the right-click menu can close it. The buffer in
// that window is highlighted, and a buffer with unsaved changes has a dot
// at the right.
//
// nvim keeps the list up to date: BUFFERS_LUA, run in nvim when a session
// starts, sends ('ngam', 'buffers', cwd, list, terminals) whenever a buffer
// is added, deleted, renamed, entered, changed or written. Terminals are
// left out of the list; the editor strip's terminal button lists them.
//
// A single click in the Explorer only peeks at a file: the buffer is
// read-only, and the next peek replaces it, so browsing does not pile up
// buffers. A double click, an edit, a save or :set noreadonly keeps it.

import "core:path/filepath"
import "core:strings"
import mu "vendor:microui"
import mp "msgpack"

Buffer :: struct {
	nr:       int,
	path:     string, // "" for an unnamed buffer
	modified: bool,
	current:  bool, // shown in nvim's current window
	peek:     bool, // opened by a single click: the next one replaces it
}

// A terminal buffer in nvim.
Term_Buf :: struct {
	nr:      int,
	title:   string, // the shell's title, or the command it runs
	current: bool,
	running: bool, // false once its command has exited
}

Buffers :: struct {
	list:   [dynamic]Buffer,
	terms:  [dynamic]Term_Buf,
	cwd:    string, // nvim's current folder, for showing paths under it
	closed: bool, // the area is folded to its heading
}

// Most rows the area shows before it scrolls.
BUFFERS_MAX_ROWS :: 8

@(private = "file")
BUFFERS_LUA :: `
local old = rawget(_G, '__ngam_buffers')
if old then pcall(vim.api.nvim_del_augroup_by_id, old.group) end
local B = {pending = false, last = ''}
_G.__ngam_buffers = B

local function ngam_chan()
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    if ui.chan and ui.chan > 0 then
      local info = vim.api.nvim_get_chan_info(ui.chan)
      if info.client and info.client.name == 'ngam' then return ui.chan end
    end
  end
end

local function send()
  B.pending = false
  local chan = ngam_chan()
  if not chan then return end
  local cur = vim.api.nvim_get_current_buf()
  local out, terms, sig = {}, {}, {vim.fn.getcwd()}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    -- An empty unnamed buffer (like nvim's start buffer) shows only while it is current.
    local empty = name == '' and not vim.bo[b].modified and b ~= cur
    if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buflisted and vim.bo[b].buftype == '' and not empty then
      local row = {b, name, vim.bo[b].modified, b == cur, vim.b[b].ngam_peek ~= nil}
      out[#out + 1] = row
      sig[#sig + 1] = table.concat({row[1], row[2], tostring(row[3]), tostring(row[4]), tostring(row[5])}, '\t')
    elseif vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == 'terminal' then
      -- term_title starts as the buffer's name, term://{cwd}//{pid}:{cmd},
      -- until the shell sets a title; show just the command then.
      local title = vim.b[b].term_title or name
      if title:sub(1, 7) == 'term://' then title = title:match('//%d+:(.*)$') or title end
      local ch = vim.bo[b].channel
      local running = ch > 0 and vim.fn.jobwait({ch}, 0)[1] == -1
      local row = {b, title, b == cur, running}
      terms[#terms + 1] = row
      sig[#sig + 1] = table.concat({'T', row[1], row[2], tostring(row[3]), tostring(row[4])}, '\t')
    end
  end
  -- Typing fires many events; send only when the list changed.
  local s = table.concat(sig, '\n')
  if s == B.last then return end
  B.last = s
  vim.rpcnotify(chan, 'ngam', 'buffers', vim.fn.getcwd(), out, terms)
end

-- Gather a burst of events (:bufdo, a session load) into one message.
local function soon()
  if not B.pending then
    B.pending = true
    vim.defer_fn(send, 30)
  end
end

B.group = vim.api.nvim_create_augroup('ngam_buffers', {clear = true})
-- BufModifiedSet is missing from some nvim builds; TextChanged then
-- catches the first change, and BufWritePost the save.
local events = {}
for _, e in ipairs({'BufAdd', 'BufDelete', 'BufWipeout', 'BufEnter', 'BufFilePost',
    'BufModifiedSet', 'BufWritePost', 'DirChanged', 'TermOpen', 'TermClose', 'TermLeave'}) do
  if vim.fn.exists('##' .. e) == 1 then events[#events + 1] = e end
end
if vim.fn.exists('##BufModifiedSet') == 0 then
  vim.list_extend(events, {'TextChanged', 'TextChangedI', 'InsertLeave'})
end
vim.api.nvim_create_autocmd(events, {group = B.group, callback = soon})
vim.api.nvim_create_autocmd('OptionSet', {group = B.group, pattern = {'buflisted', 'buftype'}, callback = soon})

-- B.keep turns a peeked buffer into a normal one. ngam_peek is 'ro' when
-- the peek made the buffer read-only, so keeping it makes it writable again.
function B.keep(b)
  local p = vim.b[b].ngam_peek
  if p == nil then return end
  vim.b[b].ngam_peek = nil
  if p == 'ro' then vim.bo[b].readonly = false end
  if B.peek == b then B.peek = nil end
  soon()
end

-- B.open edits path. With peek, a file that was not open yet becomes the
-- peeked buffer, and the last peeked one closes if it is unchanged and
-- shown nowhere else.
function B.open(path, peek)
  -- Names, since :edit can reuse an empty unnamed buffer for the file.
  local had = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buflisted then had[b] = vim.api.nvim_buf_get_name(b) end
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  local b = vim.api.nvim_get_current_buf()
  if not peek then
    B.keep(b)
    return
  end
  if had[b] == vim.api.nvim_buf_get_name(b) then return end
  vim.b[b].ngam_peek = vim.bo[b].readonly and true or 'ro'
  vim.bo[b].readonly = true
  local old = B.peek
  B.peek = b
  if old then B.drop(old) end
  soon()
end

-- B.drop closes b if it is an older peek, unchanged and shown nowhere.
function B.drop(b)
  if b ~= B.peek and vim.api.nvim_buf_is_valid(b) and vim.b[b].ngam_peek ~= nil
      and not vim.bo[b].modified and #vim.fn.win_findbuf(b) == 0 then
    pcall(vim.cmd, 'bdelete ' .. b)
  end
end

-- The first change to a peeked buffer keeps it. Clearing readonly here
-- also stops nvim's "changing a readonly file" warning.
vim.api.nvim_create_autocmd('FileChangedRO', {group = B.group, callback = function(a) B.keep(a.buf) end})
vim.api.nvim_create_autocmd('BufWritePost', {group = B.group, callback = function(a) B.keep(a.buf) end})
-- An older peek still shown in another window closes once that window
-- moves on. Scheduled, as a buffer cannot be deleted while it is hidden.
vim.api.nvim_create_autocmd('BufHidden', {group = B.group, callback = function(a)
  vim.schedule(function() B.drop(a.buf) end)
end})
vim.api.nvim_create_autocmd('OptionSet', {group = B.group, pattern = 'readonly', callback = function()
  local v = vim.v.option_new
  if v == false or v == 0 then B.keep(vim.api.nvim_get_current_buf()) end
end})
send()
`

// buffers_session_started has nvim send its buffer list now and after
// each change.
buffers_session_started :: proc(app: ^App) {
	exec_lua(app, BUFFERS_LUA, {})
}

buffers_reset :: proc(b: ^Buffers) {
	for x in b.list {
		delete(x.path)
	}
	clear(&b.list)
	for t in b.terms {
		delete(t.title)
	}
	clear(&b.terms)
	delete(b.cwd)
	b.cwd = ""
}

// buffers_changed takes nvim's new list.
buffers_changed :: proc(app: ^App, cwd: string, list, terms: []mp.Value) {
	b := &app.explorer.bufs
	old := ""
	old_mod := make([]bool, len(b.list), context.temp_allocator)
	for x, i in b.list {
		if x.current {
			old = strings.clone(x.path, context.temp_allocator)
		}
		old_mod[i] = x.modified
	}
	closed := b.closed
	buffers_reset(b)
	b.closed = closed
	b.cwd = strings.clone(cwd)
	for v in list {
		e := mp.as_array(v)
		append(&b.list, Buffer{
			nr = int(mp.as_int(mp.at(e, 0))),
			path = strings.clone(mp.as_str(mp.at(e, 1))),
			modified = mp.as_bool(mp.at(e, 2)),
			current = mp.as_bool(mp.at(e, 3)),
			peek = mp.as_bool(mp.at(e, 4)),
		})
	}
	for v in terms {
		e := mp.as_array(v)
		append(&b.terms, Term_Buf{
			nr = int(mp.as_int(mp.at(e, 0))),
			title = strings.clone(mp.as_str(mp.at(e, 1))),
			current = mp.as_bool(mp.at(e, 2)),
			running = mp.as_bool(mp.at(e, 3)),
		})
	}
	// A save, or a buffer just changed, may change git's letters.
	if len(old_mod) != len(b.list) || saved(old_mod, b.list[:]) {
		git_refresh(app)
	}
	// Follow the buffer nvim shows: open the tree down to its file.
	for x in b.list {
		if x.current && x.path != "" && x.path != old {
			explorer_reveal(app, x.path)
		}
	}
	app.need_draw = true
}

// saved says whether a buffer went from modified to saved.
@(private = "file")
saved :: proc(old_mod: []bool, list: []Buffer) -> bool {
	for x, i in list {
		if old_mod[i] && !x.modified {
			return true
		}
	}
	return false
}

// buffers_height is the height of the whole area, heading included, so
// the tree above it can take the rest.
buffers_height :: proc(app: ^App) -> i32 {
	b := &app.explorer.bufs
	ctx := &app.ui.ctx
	h := app.ui.small.cell_h + ctx.style.padding * 2 + ctx.style.spacing
	if !b.closed && len(b.list) > 0 {
		h += buffers_list_height(app) + ctx.style.spacing
	}
	return h
}

// buffers_list_height fits up to BUFFERS_MAX_ROWS rows; any more scroll.
@(private = "file")
buffers_list_height :: proc(app: ^App) -> i32 {
	ctx := &app.ui.ctx
	row_h := app.ui.font.cell_h + ctx.style.padding
	n := i32(min(len(app.explorer.bufs.list), BUFFERS_MAX_ROWS))
	return n * (row_h + ctx.style.spacing) - ctx.style.spacing + ctx.style.padding * 2
}

// buffers_draw draws the area's heading and rows. A clicked row is added
// to rows as {node = -1, buf = index}, and its index in rows returned.
buffers_draw :: proc(app: ^App, rows: ^[dynamic]Ex_Row) -> int {
	b := &app.explorer.bufs
	ui := &app.ui
	ctx := &ui.ctx
	clicked := -1
	if section_heading(ui, "buffers", "Buffers", !b.closed, len(b.list), rule = true) {
		b.closed = !b.closed
	}
	if b.closed || len(b.list) == 0 {
		return -1
	}
	mu.layout_row(ctx, {-1}, buffers_list_height(app))
	mu.begin_panel(ctx, "!buffers", {.NO_FRAME})
	// The buffer numbers, as :ls shows them, right-aligned in a column.
	widest := 0
	for x in b.list {
		widest = max(widest, x.nr)
	}
	num_w := text_width(&ui.font, fmt_key("", widest))
	for x, i in b.list {
		name := x.path == "" ? "[No Name]" : filepath.base(x.path)
		detail := buffer_folder(b.cwd, x.path)
		row := len(rows)
		append(rows, Ex_Row{node = -1, buf = i})
		key := fmt_key("buf", x.nr)
		// A peeked buffer's name is dimmed: the next peek replaces it.
		label_color := x.peek ? ui.colors.dim : mu.Color{}
		if list_row(ui, key, 0, name, detail = detail, tag = x.modified ? "●" : "", tag_color = ui.colors.modified, selected = x.current, icon = .File, label_color = label_color, number = fmt_key("", x.nr), number_w = num_w) {
			clicked = row
		}
	}
	mu.end_panel(ctx)
	return clicked
}

// buffer_folder is the folder a buffer's file is in, under cwd if it is
// there: "" for cwd itself.
@(private = "file")
buffer_folder :: proc(cwd, path: string) -> string {
	if path == "" {
		return ""
	}
	dir, _ := filepath.split(path)
	dir = strings.trim_right(dir, "/")
	if dir == cwd {
		return ""
	}
	if cwd != "" && strings.has_prefix(dir, cwd) && len(dir) > len(cwd) && dir[len(cwd)] == '/' {
		return dir[len(cwd) + 1:]
	}
	return dir
}

// buffer_close closes buffer nr in nvim. With unsaved changes it asks
// first (Save, Discard or Cancel). Each window showing the buffer is given
// another one, so the window layout stays as it is.
buffer_close :: proc(app: ^App, nr: int) {
	exec_lua(app, CLOSE_LUA, {i64(nr)})
}

@(private = "file")
CLOSE_LUA :: `
local nr = ...
-- Scheduled, so the request returns before confirm() waits for an answer.
vim.schedule(function()
  if not vim.api.nvim_buf_is_valid(nr) then return end
  if vim.bo[nr].modified then
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(nr), ':~:.')
    if name == '' then name = '[No Name]' end
    local c = vim.fn.confirm('Save changes to ' .. name .. '?', '&Save\n&Discard\n&Cancel', 1)
    if c == 1 then
      local ok, err = pcall(vim.api.nvim_buf_call, nr, function() vim.cmd('write') end)
      if not ok then
        vim.notify(tostring(err), vim.log.levels.ERROR)
        return
      end
    elseif c ~= 2 then
      return
    end
  end
  -- Another buffer for its windows: the alternate one, else any listed.
  local other = vim.fn.bufnr('#')
  if other == nr or other < 1 or not vim.bo[other].buflisted then
    other = nil
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= nr and vim.bo[b].buflisted and vim.bo[b].buftype == '' then
        other = b
        break
      end
    end
  end
  for _, w in ipairs(vim.fn.win_findbuf(nr)) do
    if other then
      vim.api.nvim_win_set_buf(w, other)
    else
      vim.api.nvim_win_call(w, function() vim.cmd('enew') end)
      other = vim.api.nvim_win_get_buf(w)
    end
  end
  pcall(vim.cmd, 'bdelete! ' .. nr)
end)
`

// buffer_show shows buffer nr in nvim's current window, leaving a diff
// tab whole as edit_file does.
buffer_show :: proc(app: ^App, nr: int) {
	exec_lua(app, EDIT_LUA, {"", i64(nr), false})
}

// section_heading draws a foldable heading such as "▾ BUFFERS 3" and
// returns whether it was clicked.
// The small font shows title in capitals; another font shows it as it is.
// rule draws a hairline above it, to part it from the area above.
section_heading :: proc(ui: ^Ui, key, title: string, open: bool, count := -1, font: ^Font = nil, rule := false) -> bool {
	f := font != nil ? font : &ui.small
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1}, f.cell_h + ctx.style.padding * 2)
	r := mu.layout_next(ctx)
	id := mu.get_id(ctx, key)
	mu.update_control(ctx, id, r)
	if ctx.hover_id == id {
		mu.draw_rect(ctx, r, ui.colors.hover)
	}
	if rule {
		mu.draw_rect(ctx, {r.x, r.y, r.w, max(i32(ui.density), 1)}, ctx.style.colors[.BORDER])
	}
	y := r.y + (r.h - f.cell_h) / 2
	x := r.x + ctx.style.padding
	// The arrow in the row font, so both headings' arrows line up.
	ay := r.y + (r.h - ui.font.cell_h) / 2
	mu.draw_text(ctx, mu.Font(&ui.font), open ? "▾" : "▸", {x, ay}, ui.colors.dim)
	x += text_width(&ui.font, "▸ ")
	label := f == &ui.small ? upper(title) : title
	color := ctx.style.colors[.TEXT]
	mu.draw_text(ctx, mu.Font(f), label, {x, y}, color)
	mu.draw_text(ctx, mu.Font(f), label, {x + 1, y}, color)
	if count >= 0 {
		cx := x + text_width(f, label) + ctx.style.padding * 2
		mu.draw_text(ctx, mu.Font(f), fmt_key("", count), {cx, y}, ui.colors.dim)
	}
	return .LEFT in ctx.mouse_pressed_bits && ctx.focus_id == id
}

@(private = "file")
fmt_key :: proc(prefix: string, n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, prefix)
	strings.write_int(&b, n)
	return strings.to_string(b)
}
