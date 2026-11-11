package ngam

// Quick open, like VS Code's Cmd-P: type part of a file's name, in any
// case, and pick from the files under nvim's current folder that match.
// The list of files comes from nvim each time it opens: `git ls-files`
// (tracked and untracked files, by git's ignore rules) in a repository,
// otherwise a walk of the folder that skips .git and node_modules.
//
// Matching is fuzzy: the typed characters must appear in order. Matches
// in the file's name beat matches in its folders, and runs of characters
// and word starts score higher. A query with a / matches the whole path.
//
// Up and Down (or Ctrl-N and Ctrl-P) choose, Enter edits the file,
// Cmd-Enter (Ctrl-Enter off macOS) previews it, Escape closes.

import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import mu "vendor:microui"
import sdl "vendor:sdl3"
import mp "msgpack"

QUICK_MAX_FILES :: 50000
QUICK_SHOWN :: 12 // rows on screen at once

Quick_Open :: struct {
	open:      bool,
	// The box has been built once since it opened. The click that opens
	// it (on the Explorer's ⌕) is outside the box, and microui still
	// reports that press in the frame that first builds it.
	shown:     bool,
	gen:       int,
	loading:   bool,
	root:      string, // the folder the paths are relative to
	files:     [dynamic]string,
	truncated: bool, // there were more than QUICK_MAX_FILES
	error:     string,
	query:     [dynamic]u8,
	matches:   [dynamic]int, // indices into files, best first
	sel:       int, // index into matches
	top:       int, // the first match on screen
}

// Lua run in nvim: {root, NUL-separated paths, truncated} or {nil, error}.
@(private = "file")
FILES_LUA :: `
local max = ...
local cwd = vim.fn.getcwd()
local git = vim.system({'git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'}, {cwd = cwd}):wait()
if git.code == 0 then
  return {cwd, git.stdout or '', false}
end
local out, n = {}, 0
local skip = function(d) return d ~= '.git' and d ~= 'node_modules' end
for name, kind in vim.fs.dir(cwd, {depth = 32, skip = skip}) do
  if kind == 'file' or kind == 'link' then
    n = n + 1
    out[n] = name
    if n >= max then return {cwd, table.concat(out, '\0'), true} end
  end
end
return {cwd, table.concat(out, '\0'), false}
`

quick_open_show :: proc(app: ^App) {
	q := &app.quick
	if app.link == nil || app.setup_open {
		return
	}
	q.open = true
	q.shown = false
	clear(&q.query)
	q.sel, q.top = 0, 0
	app.menu.open = false
	q.gen += 1
	gen := new(int)
	gen^ = q.gen
	if exec_lua(app, FILES_LUA, {i64(QUICK_MAX_FILES)}, files_done, gen) {
		q.loading = true
	} else {
		free(gen)
	}
	app.need_draw = true
}

quick_open_close :: proc(app: ^App) {
	app.quick.open = false
	app.need_draw = true
}

@(private = "file")
files_done :: proc(app: ^App, result: mp.Value, failed: bool, user: rawptr) {
	gen := (^int)(user)
	defer free(gen)
	q := &app.quick
	if gen^ != q.gen {
		return
	}
	q.loading = false
	for f in q.files {
		delete(f)
	}
	clear(&q.files)
	delete(q.error)
	q.error = ""
	r := mp.as_array(result)
	if failed || mp.at(r, 0) == nil {
		q.error = strings.clone("Cannot list the files.")
		app.need_draw = true
		return
	}
	delete(q.root)
	q.root = strings.clone(mp.as_str(mp.at(r, 0)))
	q.truncated = mp.as_bool(mp.at(r, 2))
	for p in strings.split(mp.as_str(mp.at(r, 1)), "\x00", context.temp_allocator) {
		if p != "" {
			append(&q.files, strings.clone(p))
		}
	}
	slice.sort(q.files[:])
	refilter(q)
	app.need_draw = true
}

// quick_open_key handles a key while quick open is shown.
quick_open_key :: proc(app: ^App, ev: sdl.KeyboardEvent, action: Key_Action) {
	q := &app.quick
	ctrl := ev.mod & sdl.KMOD_CTRL != {}
	cmd := ev.mod & sdl.KMOD_GUI != {}
	alt := ev.mod & sdl.KMOD_ALT != {}
	when ODIN_OS == .Darwin {
		alt_open := cmd
	} else {
		alt_open := ctrl
	}
	app.need_draw = true
	if action == .Paste {
		append(&q.query, ..transmute([]u8)first_text_line(clipboard_get()))
		refilter(q)
		return
	}
	switch ev.key {
	case sdl.K_ESCAPE:
		quick_open_close(app)
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		quick_open_pick(app, q.sel, alt_open)
	case sdl.K_UP:
		move(q, -1)
	case sdl.K_DOWN:
		move(q, 1)
	case sdl.K_PAGEUP:
		move(q, -QUICK_SHOWN)
	case sdl.K_PAGEDOWN:
		move(q, QUICK_SHOWN)
	case sdl.K_N:
		if ctrl {
			move(q, 1)
		}
	case sdl.K_P:
		if ctrl {
			move(q, -1)
		}
	case sdl.K_BACKSPACE:
		if cmd || ctrl {
			clear(&q.query)
		} else if alt {
			// Back to the last / or the start.
			for len(q.query) > 0 {
				c := pop(&q.query)
				if len(q.query) > 0 && (q.query[len(q.query) - 1] == '/' || c == '/') {
					break
				}
			}
		} else {
			// Drop a whole UTF-8 character.
			if len(q.query) > 0 {
				_, n := utf8.decode_last_rune(q.query[:])
				resize(&q.query, len(q.query) - max(n, 1))
			}
		}
		refilter(q)
	}
}

// quick_open_text adds typed text to the query.
quick_open_text :: proc(app: ^App, text: string) {
	q := &app.quick
	append(&q.query, ..transmute([]u8)text)
	refilter(q)
	app.need_draw = true
}

@(private = "file")
first_text_line :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if i := strings.index_any(t, "\r\n"); i >= 0 {
		t = t[:i]
	}
	return t
}

@(private = "file")
move :: proc(q: ^Quick_Open, by: int) {
	if len(q.matches) == 0 {
		return
	}
	q.sel = clamp(q.sel + by, 0, len(q.matches) - 1)
	if q.sel < q.top {
		q.top = q.sel
	} else if q.sel >= q.top + QUICK_SHOWN {
		q.top = q.sel - QUICK_SHOWN + 1
	}
}

quick_open_pick :: proc(app: ^App, i: int, preview: bool) {
	q := &app.quick
	if i < 0 || i >= len(q.matches) {
		return
	}
	path := strings.concatenate({q.root, "/", q.files[q.matches[i]]}, context.temp_allocator)
	quick_open_close(app)
	if preview {
		preview_open(app, path)
	} else {
		edit_file(app, path)
	}
}

// ---- Matching ----

@(private = "file")
Scored :: struct {
	file:  int,
	score: int,
}

@(private = "file")
refilter :: proc(q: ^Quick_Open) {
	clear(&q.matches)
	q.sel, q.top = 0, 0
	query := strings.to_lower(strings.trim_space(string(q.query[:])), context.temp_allocator)
	if query == "" {
		for _, i in q.files {
			append(&q.matches, i)
		}
		return
	}
	scored := make([dynamic]Scored, context.temp_allocator)
	for f, i in q.files {
		if s, ok := score(query, f); ok {
			append(&scored, Scored{i, s})
		}
	}
	files := q.files[:]
	context.user_ptr = &files
	slice.sort_by(scored[:], proc(a, b: Scored) -> bool {
		if a.score != b.score {
			return a.score > b.score
		}
		fs := (^[]string)(context.user_ptr)^
		if len(fs[a.file]) != len(fs[b.file]) {
			return len(fs[a.file]) < len(fs[b.file])
		}
		return fs[a.file] < fs[b.file]
	})
	for s in scored {
		append(&q.matches, s.file)
	}
}

// score matches query (lower case) against path, in any case. For a query
// with no /, it tries the file's name first, then falls back to the whole
// path.
@(private = "file")
score :: proc(query, path: string) -> (int, bool) {
	if !strings.contains_rune(query, '/') {
		base := filepath.base(path)
		if s, ok := fuzzy(query, base); ok {
			s += 1000 // a match in the name itself
			if strings.has_prefix(strings.to_lower(base, context.temp_allocator), query) {
				s += 500
			}
			return s, true
		}
	}
	return fuzzy(query, path)
}

// fuzzy finds query's characters in order in text, ignoring case, and
// scores the match: more for characters next to each other and for
// characters that start a word (after / . _ - or a space, or a capital
// after a small letter), less for a long text.
@(private = "file")
fuzzy :: proc(query, text: string) -> (int, bool) {
	s := 0
	qi := 0
	prev_match := -2
	prev: rune = '/'
	ti := 0
	for r in text {
		if qi >= len(query) {
			break
		}
		qr, qn := utf8.decode_rune_in_string(query[qi:])
		lr := lower(r)
		if lr == qr {
			s += 10
			if prev_match == ti - 1 {
				s += 15 // a run
			}
			if prev == '/' || prev == '.' || prev == '_' || prev == '-' || prev == ' ' || (is_upper(r) && !is_upper(prev)) {
				s += 20 // a word start
			}
			prev_match = ti
			qi += qn
		}
		prev = r
		ti += 1
	}
	if qi < len(query) {
		return 0, false
	}
	return s - utf8.rune_count_in_string(text) / 4, true
}

@(private = "file")
lower :: proc(r: rune) -> rune {
	if r >= 'A' && r <= 'Z' {
		return r + ('a' - 'A')
	}
	return r
}

@(private = "file")
is_upper :: proc(r: rune) -> bool {
	return r >= 'A' && r <= 'Z'
}

// ---- Drawing ----

// quick_open_frame builds the quick open box for this frame: a query line
// and the best matches, at the top of the editor.
quick_open_frame :: proc(app: ^App) {
	q := &app.quick
	if !q.open {
		return
	}
	ui := &app.ui
	ctx := &ui.ctx
	area := editor_frame_rect(app)
	pad := ctx.style.padding
	row_h := ui.font.cell_h + pad
	w := min(i32(600 * app.density), area.w - i32(24 * app.density))
	shown := min(len(q.matches), QUICK_SHOWN)
	lines := max(shown, 1)
	h := (row_h + pad) + i32(lines) * (row_h + ctx.style.spacing) + pad * 4
	r := mu.Rect{area.x + (area.w - w) / 2, area.y + i32(8 * app.density), w, h}

	// A press outside the box closes it, except the one that opened it.
	if !q.shown {
		q.shown = true
	} else if ctx.mouse_pressed_bits != {} && !(ctx.mouse_pos.x >= r.x && ctx.mouse_pos.y >= r.y && ctx.mouse_pos.x < r.x + r.w && ctx.mouse_pos.y < r.y + r.h) {
		quick_open_close(app)
		return
	}
	if !fixed_window(ctx, "!quick", r, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE, .NO_SCROLL}, Z_OVERLAY) {
		return
	}
	defer mu.end_window(ctx)

	// The query line, with a caret.
	mu.layout_row(ctx, {-1}, row_h + pad)
	qr := mu.layout_next(ctx)
	mu.draw_rect(ctx, qr, ctx.style.colors[.BASE])
	mu.draw_rect(ctx, {qr.x, qr.y + qr.h - max(i32(app.density), 1), qr.w, max(i32(app.density), 1)}, ui.colors.accent)
	ty := qr.y + (qr.h - ui.font.cell_h) / 2
	query := string(q.query[:])
	if query == "" {
		mu.draw_text(ctx, mu.Font(&ui.font), "Type part of a file name", {qr.x + pad, ty}, ui.colors.dim)
	} else {
		mu.draw_text(ctx, mu.Font(&ui.font), query, {qr.x + pad, ty}, ctx.style.colors[.TEXT])
	}
	cx := qr.x + pad + text_width(&ui.font, query)
	mu.draw_rect(ctx, {cx, ty, max(i32(app.density), 1), ui.font.cell_h}, ctx.style.colors[.TEXT])
	count := ""
	switch {
	case q.loading:
		count = "Loading…"
	case q.error != "":
		count = q.error
	case:
		count = fmt.tprintf("%d%s", len(q.matches), q.truncated ? "+" : "")
	}
	cw := text_width(&ui.font, count)
	mu.draw_text(ctx, mu.Font(&ui.font), count, {qr.x + qr.w - cw - pad, ty}, ui.colors.dim)

	if shown == 0 {
		mu.layout_row(ctx, {-1}, row_h)
		if !q.loading && q.error == "" {
			mu.text(ctx, len(q.files) == 0 ? "No files." : "No matching files.")
		}
		return
	}
	for i in q.top ..< min(q.top + QUICK_SHOWN, len(q.matches)) {
		f := q.files[q.matches[i]]
		dir := filepath.dir(f)
		if dir == "." {
			dir = ""
		}
		if list_row(ui, f, 0, filepath.base(f), detail = dir, selected = i == q.sel, icon = .File) {
			right := ui.right_click
			ui.right_click = false
			if !right {
				quick_open_pick(app, i, preview_mods(app.click_mods))
				return
			}
		}
	}
}

// quick_open_wheel scrolls the matches.
quick_open_wheel :: proc(app: ^App, dy: f32) {
	q := &app.quick
	n := len(q.matches)
	if n <= QUICK_SHOWN {
		return
	}
	step := dy > 0 ? -1 : 1
	q.top = clamp(q.top + step, 0, n - QUICK_SHOWN)
	q.sel = clamp(q.sel, q.top, q.top + QUICK_SHOWN - 1)
	app.need_draw = true
}
