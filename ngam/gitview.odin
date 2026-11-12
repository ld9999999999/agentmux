package ngam

// The Git view: `git status` for the repository around nvim's current
// folder, in three groups: Staged, Changes and Untracked. git runs in nvim
// through vim.system, so this works the same for a session on an ssh host.
// It refreshes when shown, when the window gains focus, and every two
// seconds while it is on screen.
//
// Clicking a changed file opens its changes in an nvim diff tab, through
// the agentmux plugin's git_diff: a Changes row shows the index against the
// working file (which can be edited and saved), and a Staged row shows HEAD
// against the index. Untracked files and conflicts open as plain files.

import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import mu "vendor:microui"
import sdl "vendor:sdl3"
import mp "msgpack"

Git_Group :: enum {
	Staged,
	Changes,
	Untracked,
}

GROUP_TITLES := [Git_Group]string {
	.Staged    = "Staged Changes",
	.Changes   = "Changes",
	.Untracked = "Untracked",
}

Git_Entry :: struct {
	path:   string, // relative to the repository's root
	old:    string, // for a rename or copy, the path it had in HEAD; else ""
	letter: string, // M, A, D, R, U or ?
	group:  Git_Group,
}

Git_View :: struct {
	gen:       int,
	busy:      bool, // a status request is on its way
	root:      string, // the repository's top folder
	entries:   [dynamic]Git_Entry,
	error:     string, // "not a git repository" and the like
	collapsed: [Git_Group]bool,
	rows:      [dynamic]int, // drawn rows: an entry index, or -1-group for a group's title
	selected:  string, // the last clicked row, as row_key gives it
	// The Explorer's letters, by absolute path: a file's own (M, A, U for
	// untracked, C for a conflict), and for a folder the strongest of
	// those under it.
	marks:     map[string]Git_Mark,
	last:      string, // the last porcelain output, to notice a change
}

Git_Mark :: struct {
	letter: string,
	own:    bool, // git lists this path itself
}

// Lua run in nvim. Returns {true, root, porcelain output} or {false, message}.
@(private = "file")
STATUS_LUA :: `
local cwd = vim.fn.getcwd()
local top = vim.system({'git', 'rev-parse', '--show-toplevel'}, {cwd = cwd, text = true}):wait()
if top.code ~= 0 then
  return {false, ((top.stderr or ''):gsub('%s+$', ''))}
end
local root = (top.stdout:gsub('%s+$', ''))
local st = vim.system({'git', 'status', '--porcelain=v1', '-z'}, {cwd = root}):wait()
if st.code ~= 0 then
  return {false, ((st.stderr or ''):gsub('%s+$', ''))}
end
return {true, root, st.stdout or ''}
`

git_reset :: proc(g: ^Git_View) {
	clear_entries(g)
	delete(g.root)
	g.root = ""
	delete(g.error)
	g.error = ""
	g.busy = false
	g.gen += 1
}

@(private = "file")
clear_entries :: proc(g: ^Git_View) {
	for en in g.entries {
		delete(en.path)
		delete(en.old)
	}
	clear(&g.entries)
	for k in g.marks {
		delete(k)
	}
	clear(&g.marks)
}

// make_marks fills g.marks from the entries.
@(private = "file")
make_marks :: proc(g: ^Git_View) {
	rank :: proc(l: string) -> int {
		switch l {
		case "C":
			return 3
		case "M":
			return 2
		}
		return 1 // A, U
	}
	put :: proc(g: ^Git_View, path, l: string, own: bool) {
		if old, ok := g.marks[path]; ok {
			if rank(l) > rank(old.letter) {
				old.letter = l
			}
			old.own ||= own
			g.marks[path] = old
			return
		}
		g.marks[strings.clone(path)] = {l, own}
	}
	for en in g.entries {
		l: string
		switch {
		case en.group == .Untracked:
			l = "U"
		case en.letter == "U":
			l = "C"
		case en.letter == "D":
			continue // gone from the tree
		case en.letter == "A" && en.group == .Staged:
			l = "A"
		case:
			l = "M"
		}
		// An untracked folder is listed as "dir/".
		path := strings.trim_right(en.path, "/")
		abs := strings.concatenate({g.root, "/", path}, context.temp_allocator)
		put(g, abs, l, true)
		// Each folder above it, up to the repository's root.
		for {
			i := strings.last_index_byte(abs, '/')
			if i <= len(g.root) {
				break
			}
			abs = abs[:i]
			put(g, abs, l, false)
		}
	}
}

// git_mark is the Explorer's letter for path, and its colour. A folder
// with changes under it gets a dot. A folder that git lists itself (an
// untracked folder) gets its letter.
git_mark :: proc(app: ^App, path: string, dir: bool) -> (letter: string, color: mu.Color) {
	m, ok := app.git.marks[path]
	if !ok {
		return "", {}
	}
	l := m.letter
	c := &app.ui.colors
	color = l == "C" ? c.conflict : l == "M" ? c.modified : c.added
	if dir && !m.own {
		return "●", color
	}
	return l, color
}

git_refresh :: proc(app: ^App) {
	g := &app.git
	if g.busy {
		return // the answer to the last request is still coming
	}
	gen := new(int)
	gen^ = g.gen
	if exec_lua(app, STATUS_LUA, {}, status_done, gen) {
		g.busy = true
	} else {
		free(gen)
	}
}

@(private = "file")
status_done :: proc(app: ^App, result: mp.Value, failed: bool, user: rawptr) {
	gen := (^int)(user)
	defer free(gen)
	g := &app.git
	if gen^ != g.gen {
		return
	}
	g.busy = false
	if failed {
		return
	}
	r := mp.as_array(result)
	delete(g.error)
	g.error = ""
	if !mp.as_bool(mp.at(r, 0)) {
		clear_entries(g)
		msg := mp.as_str(mp.at(r, 1))
		g.error = strings.clone(strings.has_prefix(msg, "fatal: not a git repository") ? "Not a git repository." : msg)
		app.need_draw = true
		return
	}
	delete(g.root)
	g.root = strings.clone(mp.as_str(mp.at(r, 1)))
	clear_entries(g)
	out := mp.as_str(mp.at(r, 2))
	parse_status(g, out)
	make_marks(g)
	if out != g.last {
		// A commit, a `git add` or a new edit: the change bars compare
		// with git's index, which may have moved.
		if g.last != "" || out != "" {
			editbar_git_changed(app)
		}
		delete(g.last)
		g.last = strings.clone(out)
	}
	app.need_draw = true
}

// parse_status reads `git status --porcelain=v1 -z`: entries "XY path",
// each ended by a NUL, where a rename or copy is followed by its old path
// as a field of its own. X is the staged state and Y the working tree's.
@(private = "file")
parse_status :: proc(g: ^Git_View, out: string) {
	parts := strings.split(out, "\x00", context.temp_allocator)
	for i := 0; i < len(parts); i += 1 {
		p := parts[i]
		if len(p) < 4 {
			continue
		}
		x, y, path := p[0], p[1], p[3:]
		old := ""
		if x == 'R' || x == 'C' {
			i += 1 // the next field is the old path
			if i < len(parts) {
				old = parts[i]
			}
		}
		switch {
		case x == '?':
			add(g, path, "", "?", .Untracked)
		case x == '!':
		// skip ignored files
		case x == 'U' || y == 'U' || (x == y && (x == 'A' || x == 'D')):
			add(g, path, "", "U", .Changes) // a merge conflict
		case:
			// A file with staged and unstaged changes gets a row in each
			// group, and each row opens its own side.
			if x != ' ' {
				add(g, path, old, letter(x), .Staged)
			}
			if y != ' ' {
				add(g, path, "", letter(y), .Changes)
			}
		}
	}
	slice.sort_by(g.entries[:], proc(a, b: Git_Entry) -> bool {
		if a.group != b.group {
			return a.group < b.group
		}
		return a.path < b.path
	})
}

@(private = "file")
letter :: proc(c: u8) -> string {
	switch c {
	case 'A':
		return "A"
	case 'D':
		return "D"
	case 'R', 'C':
		return "R"
	}
	return "M" // M, and T (a type change)
}

@(private = "file")
add :: proc(g: ^Git_View, path, old, l: string, group: Git_Group) {
	append(&g.entries, Git_Entry{strings.clone(path), strings.clone(old), l, group})
}

// row_key names a row, so a file in two groups is two rows.
@(private = "file")
row_key :: proc(en: Git_Entry) -> string {
	return strings.concatenate({GROUP_TITLES[en.group], "/", en.path}, context.temp_allocator)
}

git_header :: proc(app: ^App) {
	if icon_button(&app.ui, "refresh", "↻") {
		git_refresh(app)
	}
	if icon_button(&app.ui, "preview", "▶") {
		preview_current_buffer(app)
	}
}

git_draw :: proc(app: ^App) -> int {
	g := &app.git
	ui := &app.ui
	ctx := &ui.ctx
	clear(&g.rows)
	mu.layout_row(ctx, {-1}, 0)
	if g.error != "" {
		mu.text(ctx, g.error)
		return -1
	}
	if g.root == "" {
		mu.text(ctx, app.rpc.attached ? "Loading…" : "")
		return -1
	}
	mu.text(ctx, filepath.base(g.root))
	if len(g.entries) == 0 {
		mu.text(ctx, "No changes.")
		return -1
	}
	clicked := -1
	for group in Git_Group {
		count := 0
		for en in g.entries {
			if en.group == group {
				count += 1
			}
		}
		if count == 0 {
			continue
		}
		title := strings.concatenate({g.collapsed[group] ? "▸ " : "▾ ", upper(GROUP_TITLES[group])}, context.temp_allocator)
		append(&g.rows, -1 - int(group))
		if list_row(ui, GROUP_TITLES[group], 0, title, detail = fmt.tprint(count)) {
			clicked = len(g.rows) - 1
		}
		if g.collapsed[group] {
			continue
		}
		for en, i in g.entries {
			if en.group != group {
				continue
			}
			dir := filepath.dir(en.path)
			if dir == "." {
				dir = ""
			}
			append(&g.rows, i)
			key := row_key(en)
			if list_row(ui, key, ctx.style.indent, filepath.base(en.path), detail = dir, tag = en.letter, tag_color = letter_color(ui, en.letter), selected = key == g.selected) {
				clicked = len(g.rows) - 1
			}
		}
	}
	return clicked
}

@(private = "file")
letter_color :: proc(ui: ^Ui, l: string) -> mu.Color {
	switch l {
	case "A", "?":
		return ui.colors.added
	case "D":
		return ui.colors.deleted
	case "U":
		return ui.colors.conflict
	}
	return ui.colors.modified
}

// git_target is a file row's file, for its menu.
git_target :: proc(app: ^App, row: int) -> (path: string, dir: bool, buf: int, ok: bool) {
	g := &app.git
	if row >= len(g.rows) || g.rows[row] < 0 {
		return
	}
	en := g.entries[g.rows[row]]
	return strings.concatenate({g.root, "/", en.path}, context.temp_allocator), false, 0, true
}

git_click :: proc(app: ^App, row: int, mods: sdl.Keymod) {
	g := &app.git
	if row >= len(g.rows) {
		return
	}
	i := g.rows[row]
	if i < 0 {
		group := Git_Group(-1 - i)
		g.collapsed[group] = !g.collapsed[group]
		return
	}
	en := g.entries[i]
	path := strings.concatenate({g.root, "/", en.path}, context.temp_allocator)
	if preview_mods(mods) {
		preview_open(app, path)
		return
	}
	delete(g.selected)
	g.selected = strings.clone(row_key(en))
	switch {
	case strings.has_suffix(en.path, "/"):
		// A whole untracked folder. nvim would open it with a folder
		// plugin, which may change nvim's current folder, so it is shown
		// in the Explorer instead.
		// The view change reads the tree again, which finishes the job.
		explorer_open_folder(app, strings.trim_right(path, "/"))
		panel_set(app, true, 0)
	case en.group == .Untracked || en.letter == "U":
		// An untracked file has nothing to compare with; a conflict is
		// edited by hand.
		edit_file(app, path, peek = app.click_count < 2)
	case en.group == .Staged:
		// HEAD against the index. A rename compares with its old path.
		git_diff(app, path, true, en.old)
	case:
		// The index against the working file, or a deleted file.
		git_diff(app, path, false, "")
	}
}

// git_diff opens a file's changes in an nvim diff tab, with the agentmux
// plugin's git_diff. The arguments go as Lua values, so any path works.
@(private = "file")
git_diff :: proc(app: ^App, path: string, staged: bool, old: string) {
	old_v: mp.Value
	if old != "" {
		old_v = old
	}
	// A msgpack nil arrives as vim.NIL, which Lua takes as true.
	exec_lua(app, "local path, staged, old = ...\nif old == vim.NIL then old = nil end\nrequire('agentmux').git_diff(path, staged, old)", {path, staged, old_v}, proc(app: ^App, _: mp.Value, failed: bool, _: rawptr) {
		if failed {
			show_toast(app, "Could not open the diff; see nvim's messages (:messages).")
		}
	})
}
