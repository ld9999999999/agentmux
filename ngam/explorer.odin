package ngam

// The Explorer view, in two areas. Below, Buffers lists the files open in
// nvim (buffers.odin). Above it, the files under nvim's current folder, as
// a tree that loads each folder when it is first opened. nvim reads the
// folders with vim.uv.fs_scandir, so this works the same for a session on
// an ssh host.
// Clicking a file edits it; Cmd-click (Ctrl-click off macOS) previews it
// in the browser.
//
// The folders on screen are watched in nvim (watch.lua). When a file is
// made, deleted or renamed in one, nvim says dir_changed and that folder is
// read again.

import "core:path/filepath"
import "core:strings"
import mu "vendor:microui"
import sdl "vendor:sdl3"
import mp "msgpack"

Ex_Node :: struct {
	name, path: string,
	dir:        bool,
	depth:      int,
	loaded:     bool, // the folder's entries are known
	loading:    bool,
	children:   [dynamic]int, // indices into Explorer.nodes
}

// A row on screen: a node of the tree, or a buffer (node -1).
Ex_Row :: struct {
	node: int,
	buf:  int,
}

Explorer :: struct {
	bufs:     Buffers, // the Buffers area
	tree_closed: bool, // the tree is folded to its heading
	gen:      int, // bumped by each refresh, so answers for an old tree are dropped
	nodes:    [dynamic]Ex_Node, // nodes[0] is the root once it is loaded
	// The folders the user opened, by path. They stay open across
	// refreshes.
	expanded: map[string]bool,
	rows:     [dynamic]Ex_Row, // the rows drawn last frame
	selected: string, // the file highlighted: nvim's current buffer, or the last clicked
	reveal:   string, // a file or folder to scroll into view once its row is drawn
	reveal_open: bool, // reveal is a folder, to be opened too
	error:    string,
	watched:  string, // the folders last sent to nvim to watch, one per line
	// A refresh empties the tree and reads the open folders again, one
	// answer at a time. The tree is short until then, which would scroll
	// it to the top, so its scroll is put back each frame until all the
	// answers are in.
	pending:  int, // scans of this gen still waiting for an answer
	scroll:   i32, // the tree's scroll, saved each frame
	restore:  i32, // the scroll to put back
	restoring: bool,
	settled:  int, // frames drawn since the last answer came in
}

// Lua run in nvim: list a folder ("" for the current folder). Returns
// {folder, {{name, is_folder}, ...}}, folders first, sorted by name.
@(private = "file")
SCAN_LUA :: `
local dir = ...
if dir == '' then dir = vim.fn.getcwd() end
local out = {}
local h = vim.uv.fs_scandir(dir)
if not h then return {dir, out, 'cannot read ' .. dir} end
while true do
  local name, kind = vim.uv.fs_scandir_next(h)
  if not name then break end
  if kind == 'link' then
    local st = vim.uv.fs_stat(dir .. '/' .. name)
    kind = st and st.type or 'file'
  end
  if name ~= '.git' and name ~= '.DS_Store' then
    out[#out + 1] = {name, kind == 'directory'}
  end
end
table.sort(out, function(a, b)
  if a[2] ~= b[2] then return a[2] end
  return a[1]:lower() < b[1]:lower()
end)
return {dir, out, ''}
`

// What a scan was for, passed through exec_lua.
@(private = "file")
Scan_Req :: struct {
	gen:     int,
	node:    int, // -1 for the root
	replace: bool, // the folder is read again, so its old entries are dropped
}

// explorer_reset forgets everything, for a new session.
explorer_reset :: proc(e: ^Explorer) {
	clear_nodes(e)
	buffers_reset(&e.bufs)
	for k in e.expanded {
		delete(k)
	}
	clear(&e.expanded)
	delete(e.selected)
	e.selected = ""
	delete(e.reveal)
	e.reveal = ""
	delete(e.watched)
	e.watched = ""
	e.gen += 1
	e.pending = 0
	e.restoring = false
}

@(private = "file")
clear_nodes :: proc(e: ^Explorer) {
	for &n in e.nodes {
		delete(n.name)
		delete(n.path)
		delete(n.children)
	}
	clear(&e.nodes)
	clear(&e.rows)
	delete(e.error)
	e.error = ""
}

// explorer_refresh reads the tree again from the root, opening the same
// folders as before.
explorer_refresh :: proc(app: ^App) {
	e := &app.explorer
	e.gen += 1
	e.pending = 0
	keep_scroll(e)
	scan(app, "", -1)
	git_refresh(app) // the files' git letters
}

@(private = "file")
scan :: proc(app: ^App, path: string, node: int, replace := false) {
	e := &app.explorer
	req := new(Scan_Req)
	req^ = {e.gen, node, replace}
	if exec_lua(app, SCAN_LUA, {path}, scan_done, req) {
		e.pending += 1
	} else {
		free(req)
	}
}

// keep_scroll holds the tree's scroll where it is while folders are read
// again.
@(private = "file")
keep_scroll :: proc(e: ^Explorer) {
	if !e.restoring && len(e.nodes) > 0 {
		e.restoring = true
		e.restore = e.scroll
	}
	e.settled = 0
}

@(private = "file")
scan_done :: proc(app: ^App, result: mp.Value, failed: bool, user: rawptr) {
	req := (^Scan_Req)(user)
	defer free(req)
	e := &app.explorer
	if req.gen != e.gen {
		return
	}
	e.pending -= 1
	e.settled = 0
	if failed {
		return
	}
	r := mp.as_array(result)
	dir := mp.as_str(mp.at(r, 0))
	if msg := mp.as_str(mp.at(r, 2)); msg != "" {
		delete(e.error)
		e.error = strings.clone(msg)
	}
	parent := req.node
	if parent < 0 {
		// A new root: the old tree goes, the open folders stay known.
		clear_nodes(e)
		append(&e.nodes, Ex_Node{name = strings.clone(filepath.base(dir)), path = strings.clone(dir), dir = true, depth = -1})
		parent = 0
	}
	if parent >= len(e.nodes) {
		return
	}
	if req.replace {
		// The old child nodes stay in e.nodes, unused, until the next full
		// refresh.
		clear(&e.nodes[parent].children)
	}
	for v in mp.as_array(mp.at(r, 1)) {
		entry := mp.as_array(v)
		name := mp.as_str(mp.at(entry, 0))
		child := Ex_Node {
			name  = strings.clone(name),
			path  = strings.concatenate({dir, "/", name}),
			dir   = mp.as_bool(mp.at(entry, 1)),
			depth = e.nodes[parent].depth + 1,
		}
		append(&e.nodes, child)
		idx := len(e.nodes) - 1
		append(&e.nodes[parent].children, idx)
		if child.dir && e.expanded[child.path] {
			e.nodes[idx].loading = true
			scan(app, child.path, idx)
		}
	}
	e.nodes[parent].loaded = true
	e.nodes[parent].loading = false
	app.need_draw = true
	if e.reveal != "" {
		expand_to(app, e.reveal) // the next folder down may be read now
	}
	explorer_watch(app)
}

// explorer_watch tells nvim which folders are on screen: the root and the
// open folders that are read. It sends the list only when it changed.
@(private = "file")
explorer_watch :: proc(app: ^App) {
	e := &app.explorer
	dirs := make([dynamic]mp.Value, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	for n, i in e.nodes {
		if n.dir && n.loaded && (i == 0 || e.expanded[n.path]) {
			append(&dirs, n.path)
			strings.write_string(&b, n.path)
			strings.write_byte(&b, '\n')
		}
	}
	list := strings.to_string(b)
	if list == e.watched {
		return
	}
	if exec_lua(app, "local W = rawget(_G, '__ngam_watch')\nif W then W.explorer((...)) end", {dirs[:]}) {
		delete(e.watched)
		e.watched = strings.clone(list)
	}
}

// explorer_dir_changed reads a folder again after nvim said that files
// were made, deleted or renamed in it.
explorer_dir_changed :: proc(app: ^App, dir: string) {
	e := &app.explorer
	// From the end: a folder read again leaves its old nodes earlier in
	// the array, so the last node with a path is the one on screen.
	#reverse for &n, i in e.nodes {
		if n.dir && n.loaded && n.path == dir && (i == 0 || e.expanded[n.path]) {
			n.loading = true
			keep_scroll(e)
			scan(app, n.path, i, replace = true)
			git_refresh(app) // a new file is untracked
			return
		}
	}
}

explorer_header :: proc(app: ^App) {
	if icon_button(&app.ui, "find", "⌕", &app.ui.icons) {
		quick_open_show(app)
	}
	if icon_button(&app.ui, "refresh", "↻") {
		explorer_refresh(app)
	}
}

explorer_draw :: proc(app: ^App) -> int {
	e := &app.explorer
	ui := &app.ui
	ctx := &ui.ctx
	clear(&e.rows)
	clicked := -1
	if len(e.nodes) == 0 {
		mu.layout_row(ctx, {-1}, 0)
		mu.text(ctx, app.rpc.attached ? "Loading…" : "")
	} else {
		if section_heading(ui, "tree", e.nodes[0].name, !e.tree_closed, font = &ui.font) {
			e.tree_closed = !e.tree_closed
		}
		if !e.tree_closed {
			// The tree takes the panel's height less the Buffers area
			// below it, and each scrolls on its own. (microui counts a
			// negative height back from the bottom, less 1.)
			mu.layout_row(ctx, {-1}, -buffers_height(app) - 1)
			if e.restoring {
				// Before begin_panel, which lays the rows out at this scroll.
				if cnt := mu.get_container(ctx, "!tree"); cnt != nil {
					cnt.scroll.y = e.restore
				}
				// Stop two frames after the last answer: the first of them
				// still measures the short tree.
				if e.pending <= 0 {
					e.settled += 1
					e.restoring = e.settled < 3
				}
				app.need_draw = true
			}
			mu.begin_panel(ctx, "!tree", {.NO_FRAME})
			if e.error != "" {
				mu.layout_row(ctx, {-1}, 0)
				mu.text(ctx, e.error)
			}
			walk(app, 0, &clicked)
			if cnt := mu.get_current_container(ctx); cnt != nil {
				e.scroll = cnt.scroll.y
			}
			mu.end_panel(ctx)
		}
	}
	if row := buffers_draw(app, &e.rows); row >= 0 {
		clicked = row
	}
	return clicked
}

// walk draws node's children, and the children of open folders under it.
@(private = "file")
walk :: proc(app: ^App, node: int, clicked: ^int) {
	e := &app.explorer
	for c in e.nodes[node].children {
		n := &e.nodes[c]
		open := n.dir && e.expanded[n.path]
		indent := i32(n.depth) * app.ui.ctx.style.indent
		icon := Row_Icon.File
		if n.dir {
			icon = open ? .Folder_Open : .Folder
		} else {
			// Files line up with the folder names, after the arrows.
			indent += text_width(&app.ui.font, "▸ ")
		}
		row := len(e.rows)
		append(&e.rows, Ex_Row{node = c, buf = -1})
		// git's letter at the right; a folder gets a dot for what is
		// under it, or U when the whole folder is untracked.
		mark, mark_color := git_mark(app, n.path, n.dir)
		if list_row(&app.ui, n.path, indent, n.name, tag = mark, tag_color = mark_color, label_color = mark_color, selected = !n.dir && n.path == e.selected, icon = icon, arrow = n.dir ? (open ? "▾" : "▸") : "") {
			clicked^ = row
		}
		// A folder waits for its files, so the scroll leaves room for them.
		if n.path == e.reveal && n.dir == e.reveal_open && (!n.dir || n.loaded) {
			scroll_into_view(app)
		}
		if n.dir && e.expanded[n.path] && n.loaded {
			walk(app, c, clicked)
		}
	}
}

// explorer_reveal highlights path in the tree, opens the folders down to
// it (reading any that are still unread) and scrolls it into view. A file
// outside the tree's folder is only highlighted, if it is ever shown.
explorer_reveal :: proc(app: ^App, path: string) {
	e := &app.explorer
	delete(e.selected)
	e.selected = strings.clone(path)
	delete(e.reveal)
	e.reveal = strings.clone(path)
	e.reveal_open = false
	expand_to(app, path)
	app.need_draw = true
}

// explorer_open_folder opens the folder at path in the tree, with the
// folders above it, and scrolls it into view.
explorer_open_folder :: proc(app: ^App, path: string) {
	e := &app.explorer
	delete(e.reveal)
	e.reveal = strings.clone(path)
	e.reveal_open = true
	expand_to(app, path)
	app.need_draw = true
}

// expand_to opens the folders between the root and path. At an unread
// folder it starts reading it and stops; scan_done calls again when the
// folder is in.
@(private = "file")
expand_to :: proc(app: ^App, path: string) {
	e := &app.explorer
	if len(e.nodes) == 0 {
		return // the root is still loading; scan_done comes back here
	}
	root := e.nodes[0].path
	if !strings.has_prefix(path, root) || len(path) <= len(root) || path[len(root)] != '/' {
		delete(e.reveal)
		e.reveal = "" // outside the tree's folder
		return
	}
	node := 0
	changed := false
	parts := strings.split(path[len(root) + 1:], "/", context.temp_allocator)
	for part, i in parts {
		if !e.nodes[node].loaded {
			if !e.nodes[node].loading {
				e.nodes[node].loading = true
				scan(app, e.nodes[node].path, node)
			}
			break
		}
		next := -1
		for c in e.nodes[node].children {
			if e.nodes[c].name == part {
				next = c
				break
			}
		}
		if next < 0 {
			break // missing from the tree for now; the folder's watcher will add it
		}
		node = next
		last := i == len(parts) - 1
		if (!last || e.reveal_open) && e.nodes[node].dir && !e.expanded[e.nodes[node].path] {
			e.expanded[strings.clone(e.nodes[node].path)] = true
			changed = true
		}
		if last && e.reveal_open && e.nodes[node].dir && !e.nodes[node].loaded && !e.nodes[node].loading {
			e.nodes[node].loading = true
			scan(app, e.nodes[node].path, node)
		}
	}
	if changed {
		explorer_watch(app)
	}
}

// scroll_into_view scrolls the tree so the row just drawn shows, then
// forgets the file to reveal.
@(private = "file")
scroll_into_view :: proc(app: ^App) {
	e := &app.explorer
	ctx := &app.ui.ctx
	if cnt := mu.get_current_container(ctx); cnt != nil {
		r, body := ctx.last_rect, cnt.body
		if r.y < body.y || r.y + r.h > body.y + body.h {
			// Out of view: bring it to the middle. microui keeps the
			// scroll within the content.
			cnt.scroll.y += r.y + r.h / 2 - (body.y + body.h / 2)
			app.need_draw = true
			e.restoring = false // the file to show wins
		}
	}
	delete(e.reveal)
	e.reveal = ""
}

// explorer_target is the file or folder on a row, and for a Buffers row
// its buffer number, for its menu.
explorer_target :: proc(app: ^App, row: int) -> (path: string, dir: bool, buf: int, ok: bool) {
	e := &app.explorer
	if row >= len(e.rows) {
		return
	}
	r := e.rows[row]
	if r.node < 0 {
		b := e.bufs.list[r.buf]
		return b.path, false, b.nr, true
	}
	n := &e.nodes[r.node]
	return n.path, n.dir, 0, true
}

explorer_click :: proc(app: ^App, row: int, mods: sdl.Keymod) {
	e := &app.explorer
	if row >= len(e.rows) {
		return
	}
	if r := e.rows[row]; r.node < 0 {
		b := e.bufs.list[r.buf]
		if preview_mods(mods) && b.path != "" {
			preview_open(app, b.path, false)
		} else {
			buffer_show(app, b.nr)
		}
		return
	}
	idx := e.rows[row].node
	n := &e.nodes[idx]
	if preview_mods(mods) {
		preview_open(app, n.path, n.dir)
		return
	}
	if n.dir {
		if e.expanded[n.path] {
			key, _ := delete_key(&e.expanded, n.path)
			delete(key)
			explorer_watch(app)
		} else {
			e.expanded[strings.clone(n.path)] = true
			if !n.loaded && !n.loading {
				n.loading = true
				scan(app, n.path, idx)
			}
		}
		return
	}
	delete(e.selected)
	e.selected = strings.clone(n.path)
	// A single click peeks; the second click of a double click keeps it.
	edit_file(app, n.path, peek = app.click_count < 2)
}

// preview_mods says whether a click with mods previews the file in the browser.
preview_mods :: proc(mods: sdl.Keymod) -> bool {
	when ODIN_OS == .Darwin {
		return mods & sdl.KMOD_GUI != {}
	} else {
		return mods & sdl.KMOD_CTRL != {}
	}
}

// edit_file opens path in nvim's current window. In a diff tab (the
// agentmux plugin's git or agent diffs) it goes to another tab first, so
// the diff stays whole. With peek the file opens as a peeked buffer (see
// buffers.odin).
edit_file :: proc(app: ^App, path: string, peek := false) {
	exec_lua(app, EDIT_LUA, {path, i64(0), peek})
}

// EDIT_LUA opens a path, or shows buffer nr when nr is non-zero.
EDIT_LUA :: `
local path, nr, peek = ...
local function is_diff(t) return vim.t[t].agentmux_git_diff or vim.t[t].agentmux_diff end
if is_diff(0) then
  local other
  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
    if not is_diff(t) then other = t break end
  end
  if other then vim.api.nvim_set_current_tabpage(other) else vim.cmd('tabnew') end
end
if nr ~= 0 then
  vim.api.nvim_set_current_buf(nr)
else
  local B = rawget(_G, '__ngam_buffers')
  if B and B.open then
    B.open(path, peek)
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
  end
end
`
