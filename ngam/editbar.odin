package ngam

// The editor's toolbar: a thin strip across the top of the nvim pane, the
// same height as the agent pane's header. At the left it shows the
// current buffer's path; at the right, toggles:
//   * change bars: green, blue and red bars beside added, changed and
//     removed lines, against git's index (changes.lua, run in nvim);
//   * blame: a small card under the cursor with the line's commit, author,
//     age and summary (blame.lua, run in nvim). A click on its hash opens
//     a bigger card with the whole commit message and the files changed,
//     with their added and removed line counts.
// Left of them, a terminal button shows how many terminals nvim has, and
// drops down a list of them to switch to (menu.odin).
// The change bars are remembered in the settings. Blame is for a quick
// look, so it starts off each time.

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import mu "vendor:microui"
import mp "msgpack"

EDITBAR_PT :: 22

@(private = "file")
CHANGES_LUA :: #load("lua/changes.lua", string)
@(private = "file")
BLAME_LUA :: #load("lua/blame.lua", string)

Editbar_Button :: enum {
	None,
	Changes,
	Blame,
	Terms,
}

Blame_Card :: struct {
	shown:     bool,
	sha:       string,
	author:    string,
	when_:     string,
	summary:   string,
	committed: bool,
}

Blame_File :: struct {
	status:   string, // git's letter: M, A, D, R, C, T
	path:     string,
	from:     string, // the old path of a rename or copy
	add, del: int, // -1 when unknown
	binary:   bool,
}

Blame_Detail :: struct {
	open:      bool,
	loading:   bool,
	sha:       string,
	author:    string,
	email:     string,
	when_:     string,
	date:      string,
	committer: string,
	message:   string,
	error:     string,
	files:     [dynamic]Blame_File,
	total:     int, // files in the commit; more than files when cut short
	anchor:    [2]i32, // where the small card was
	rect:      mu.Rect, // where it was last drawn
	scroll:    i32,
	content_h: i32,
}

Editbar :: struct {
	hover:     Editbar_Button,
	blame:     Blame_Card,
	blame_on:  bool, // starts off each time
	sha_rect:  mu.Rect, // the small card's hash, which opens the detail
	card_rect: mu.Rect,
	sha_hover: bool,
	detail:    Blame_Detail,
}

editbar_h :: proc(app: ^App) -> i32 {
	if app.link == nil {
		return 0
	}
	return i32(EDITBAR_PT * app.density)
}

// editbar_session_started sends the Lua for change bars and blame to the
// new session's nvim, and turns each on as the settings say.
editbar_session_started :: proc(app: ^App) {
	blame_clear(app)
	blame_detail_close(app)
	exec_lua(app, CHANGES_LUA, {})
	exec_lua(app, BLAME_LUA, {})
	set_changes(app, app.settings.change_bars)
	set_blame(app, app.editbar.blame_on)
}

// editbar_git_changed is called when the `git status` output changes:
// the index that the change bars compare with may have moved.
editbar_git_changed :: proc(app: ^App) {
	if app.settings.change_bars {
		exec_lua(app, "local M = rawget(_G, '__ngam_changes'); if M then M.refresh() end", {})
	}
}

@(private = "file")
set_changes :: proc(app: ^App, on: bool) {
	exec_lua(app, "local M = rawget(_G, '__ngam_changes'); if M then M.enable(...) end", {on})
}

@(private = "file")
set_blame :: proc(app: ^App, on: bool) {
	if !on {
		blame_clear(app)
		blame_detail_close(app)
	}
	exec_lua(app, "local M = rawget(_G, '__ngam_blame'); if M then M.enable(...) end", {on})
}

@(private = "file")
toggle :: proc(app: ^App, b: Editbar_Button) {
	st := &app.settings
	#partial switch b {
	case .Changes:
		st.change_bars = !st.change_bars
		set_changes(app, st.change_bars)
	case .Blame:
		app.editbar.blame_on = !app.editbar.blame_on
		set_blame(app, app.editbar.blame_on)
	}
	settings_save(st)
	app.need_draw = true
}

// button_rect is where button b sits: at the strip's right end, Blame
// rightmost, then Changes, then Terms.
@(private = "file")
button_rect :: proc(app: ^App, b: Editbar_Button) -> mu.Rect {
	h := editbar_h(app)
	d := app.density
	s := i32(26 * d)
	right := agent_left(app) - i32(4 * d)
	if !app.agent.open {
		right = agent_button_rect(app).x // the agent pane's show button is last
	}
	y := (h - s) / 2
	#partial switch b {
	case .Blame:
		return {right - s, y, s, min(s, h)}
	case .Changes:
		return {right - 2 * s, y, s, min(s, h)}
	}
	w := terms_button_w(app)
	return {right - 2 * s - w, y, w, min(s, h)}
}

// terms_button_w fits the terminal button's prompt sign and count.
@(private = "file")
terms_button_w :: proc(app: ^App) -> i32 {
	ui := &app.ui
	d := app.density
	w := text_width(&ui.small, ">_") + i32(12 * d)
	if n := len(app.explorer.bufs.terms); n > 0 {
		w += text_width(&ui.small, fmt.tprint(n)) + i32(4 * d)
	}
	return max(w, i32(26 * d))
}

@(private = "file")
button_at :: proc(app: ^App) -> Editbar_Button {
	m := app.mouse
	for b in ([]Editbar_Button{.Terms, .Changes, .Blame}) {
		r := button_rect(app, b)
		if m.x >= r.x && m.x < r.x + r.w && m.y >= r.y && m.y < r.y + r.h {
			return b
		}
	}
	return .None
}

// editbar_hover follows the mouse and says whether the hover changed.
editbar_hover :: proc(app: ^App) -> bool {
	b := Editbar_Button.None
	on_sha := false
	if app.link != nil && !app.setup_open {
		b = button_at(app)
		on_sha = over_sha(app)
	}
	if b == app.editbar.hover && on_sha == app.editbar.sha_hover {
		return false
	}
	app.editbar.hover = b
	app.editbar.sha_hover = on_sha
	return true
}

@(private = "file")
inside :: proc(r: mu.Rect, p: [2]i32) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

@(private = "file")
over_sha :: proc(app: ^App) -> bool {
	e := &app.editbar
	return e.blame.shown && e.blame.sha != "" && !e.detail.open && inside(e.sha_rect, app.mouse)
}

// editbar_mouse_down takes a press on the strip, and says whether it did.
editbar_mouse_down :: proc(app: ^App, left: bool) -> bool {
	if app.link == nil || app.setup_open {
		return false
	}
	m := app.mouse
	e := &app.editbar
	if e.detail.open {
		// A click outside the detail closes it; one inside is its own.
		if !inside(e.detail.rect, m) {
			blame_detail_close(app)
		}
		return true
	}
	if left && over_sha(app) {
		blame_detail_open(app)
		return true
	}
	if m.y >= editbar_h(app) || m.x < editor_x(app) || m.x >= agent_left(app) {
		return false
	}
	if b := button_at(app); b == .Terms && left {
		r := button_rect(app, .Terms)
		menu_open_terms(app, r.x + r.w, editbar_h(app))
	} else if b != .None && left {
		toggle(app, b)
	}
	return true
}

// editbar_frame draws the strip, and the blame card when there is one.
editbar_frame :: proc(app: ^App) {
	if app.link == nil {
		return
	}
	ctx := &app.ui.ctx
	ui := &app.ui
	d := app.density
	x0 := editor_x(app)
	r := mu.Rect{x0, 0, agent_left(app) - x0, editbar_h(app)}
	if r.w <= 0 {
		return
	}
	if fixed_window(ctx, "!editbar", r, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE, .NO_SCROLL, .NO_FRAME, .NO_INTERACT}, Z_BAR) {
		fg, bg := app.grid.default_fg, app.grid.default_bg
		mu.draw_rect(ctx, r, mix(bg, fg, 0.04))
		mu.draw_rect(ctx, {r.x, r.y + r.h - max(i32(d), 1), r.w, max(i32(d), 1)}, mix(bg, fg, 0.12))

		// The current buffer's path, relative to nvim's folder.
		path := ""
		modified := false
		for b in app.explorer.bufs.list {
			if b.current {
				path, modified = b.path, b.modified
				cwd := app.explorer.bufs.cwd
				if cwd != "" && strings.has_prefix(path, cwd) && len(path) > len(cwd) && path[len(cwd)] == '/' {
					path = path[len(cwd) + 1:]
				}
			}
		}
		left := button_rect(app, .Terms).x
		label := ""
		switch app.editbar.hover {
		case .Changes:
			label = app.settings.change_bars ? "Hide change bars" : "Show change bars"
		case .Blame:
			label = app.editbar.blame_on ? "Hide line blame" : "Show line blame"
		case .Terms:
			label = "Terminals"
		case .None:
		}
		pad := i32(10 * d)
		ty := r.y + (r.h - ui.small.cell_h) / 2
		mu.push_clip_rect(ctx, {r.x, r.y, left - r.x - pad, r.h})
		if path != "" {
			mu.draw_text(ctx, mu.Font(&ui.small), path, {r.x + pad, ty}, mix(bg, fg, 0.6))
			if modified {
				mu.draw_text(ctx, mu.Font(&ui.small), " ●", {r.x + pad + text_width(&ui.small, path), ty}, mix(bg, fg, 0.6))
			}
		}
		mu.pop_clip_rect(ctx)
		if label != "" {
			lw := text_width(&ui.small, label)
			mu.draw_rect(ctx, {left - lw - pad * 2, r.y, lw + pad * 2, r.h - max(i32(d), 1)}, mix(bg, fg, 0.04))
			mu.draw_text(ctx, mu.Font(&ui.small), label, {left - lw - pad, ty}, mix(bg, fg, 0.8))
		}
		draw_button(app, .Changes, app.settings.change_bars)
		draw_button(app, .Blame, app.editbar.blame_on)
		draw_button(app, .Terms, app.menu.open && app.menu.terms)
		mu.end_window(ctx)
	}
	blame_frame(app)
}

// draw_button draws a toggle: its icon in colour while on, faint while
// off; a background while the mouse is over it.
@(private = "file")
draw_button :: proc(app: ^App, b: Editbar_Button, on: bool) {
	ctx := &app.ui.ctx
	fg, bg := app.grid.default_fg, app.grid.default_bg
	r := button_rect(app, b)
	if app.editbar.hover == b {
		mu.draw_rect(ctx, r, mix(bg, fg, 0.12))
	} else if on {
		mu.draw_rect(ctx, r, mix(bg, fg, 0.07))
	}
	d := app.density
	t := max(i32(d), 1)
	faint := mix(bg, fg, 0.35)
	switch b {
	case .Changes:
		// Three short bars: green, blue, red.
		colors := [3]mu.Color{app.ui.colors.added, mu.Color{0x4c, 0x8d, 0xf6, 255}, app.ui.colors.conflict}
		bw, gap, bh := max(i32(2 * d), 2), i32(3 * d), i32(12 * d)
		x := r.x + (r.w - 3 * bw - 2 * gap) / 2
		y := r.y + (r.h - bh) / 2
		for c, i in colors {
			h := bh - i32(i % 2) * i32(4 * d) // the middle one shorter
			mu.draw_rect(ctx, {x + i32(i) * (bw + gap), y + (bh - h) / 2, bw, h}, on ? c : faint)
		}
	case .Blame:
		// A commit: a ring on a line.
		color := on ? mix(bg, fg, 0.9) : faint
		s := i32(8 * d)
		cx, cy := r.x + r.w / 2, r.y + r.h / 2
		lw := i32(16 * d)
		mu.draw_rect(ctx, {cx - lw / 2, cy - t / 2, (lw - s) / 2, t}, color)
		mu.draw_rect(ctx, {cx + s / 2, cy - t / 2, (lw - s) / 2, t}, color)
		x, y := cx - s / 2, cy - s / 2
		mu.draw_rect(ctx, {x, y, s, t + t / 2}, color)
		mu.draw_rect(ctx, {x, y + s - t - t / 2, s, t + t / 2}, color)
		mu.draw_rect(ctx, {x, y, t + t / 2, s}, color)
		mu.draw_rect(ctx, {x + s - t - t / 2, y, t + t / 2, s}, color)
	case .Terms:
		// A prompt sign and the count, dimmed when there are none.
		ui := &app.ui
		n := len(app.explorer.bufs.terms)
		color := n > 0 ? mix(bg, fg, 0.85) : faint
		x := r.x + i32(6 * d)
		y := r.y + (r.h - ui.small.cell_h) / 2
		mu.draw_text(ctx, mu.Font(&ui.small), ">_", {x, y}, color)
		if n > 0 {
			x += text_width(&ui.small, ">_") + i32(4 * d)
			mu.draw_text(ctx, mu.Font(&ui.small), fmt.tprint(n), {x, y}, color)
		}
	case .None:
	}
}

// ---- Blame ----

// blame_show takes nvim's blame for the cursor's line.
blame_show :: proc(app: ^App, info: []mp.Map_Entry) {
	blame_clear(app)
	c := &app.editbar.blame
	c.sha = strings.clone(mp.as_str(mp.map_get(info, "sha")))
	c.author = strings.clone(mp.as_str(mp.map_get(info, "author")))
	c.when_ = strings.clone(mp.as_str(mp.map_get(info, "when")))
	c.summary = strings.clone(mp.as_str(mp.map_get(info, "summary")))
	c.committed = mp.as_bool(mp.map_get(info, "committed"))
	c.shown = true
	app.need_draw = true
}

blame_clear :: proc(app: ^App) {
	c := &app.editbar.blame
	delete(c.sha)
	delete(c.author)
	delete(c.when_)
	delete(c.summary)
	c^ = {}
	app.need_draw = true
}

// blame_frame draws the card under the cursor's line (above it near the
// bottom). It may reach past the editor, over the agent pane: it is a
// quick look, so it is better to show it whole. The
// summary is in the editor's font, on a background at 90% opacity.
@(private = "file")
blame_frame :: proc(app: ^App) {
	blame_detail_frame(app)
	c := &app.editbar.blame
	if !c.shown || app.setup_open || app.editbar.detail.open {
		return
	}
	g := &app.grid
	w := g.wins[g.cursor_grid]
	if w == nil {
		return
	}
	area := app_editor_rect(app)
	f := &app.font
	wx, wy, shown := win_origin(f, g, w, area.x, area.y)
	if !shown {
		return
	}
	cx := wx + i32(g.cursor_col) * f.cell_w
	cy := wy + i32(g.cursor_row) * f.cell_h

	ctx := &app.ui.ctx
	ui := &app.ui
	d := app.density
	pad := i32(8 * d)
	gap := i32(4 * d)
	margin := i32(8 * d)
	win_w, win_h := window_pixels(app)
	head := c.sha != "" ? strings.concatenate({c.sha, "  ", c.author}, context.temp_allocator) : c.author
	if c.when_ != "" {
		head = strings.concatenate({head, " · ", c.when_}, context.temp_allocator)
	}
	tw := max(text_width(&ui.small, head), text_width(f, c.summary))
	cw := min(tw + 2 * pad, win_w - 2 * margin)
	ch := ui.small.cell_h + gap + f.cell_h + 2 * pad
	// Under the cursor's line, or above it near the bottom. It stays
	// inside the window and may reach past the editor.
	x := clamp(cx, margin, max(win_w - margin - cw, margin))
	y := cy + f.cell_h + gap
	if y + ch > win_h - margin {
		y = cy - ch - gap
	}
	r := mu.Rect{x, y, cw, ch}
	app.editbar.card_rect = r
	if !fixed_window(ctx, "!blame", r, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE, .NO_SCROLL, .NO_FRAME, .NO_INTERACT}, Z_TOAST) {
		return
	}
	defer mu.end_window(ctx)
	fg, bg := g.default_fg, g.default_bg
	t := max(i32(d), 1)
	border := mix(bg, fg, 0.25)
	back := mix(bg, fg, 0.06)
	border.a, back.a = 230, 230 // 90%
	mu.draw_rect(ctx, {r.x, r.y, r.w, t}, border)
	mu.draw_rect(ctx, {r.x, r.y + r.h - t, r.w, t}, border)
	mu.draw_rect(ctx, {r.x, r.y + t, t, r.h - 2 * t}, border)
	mu.draw_rect(ctx, {r.x + r.w - t, r.y + t, t, r.h - 2 * t}, border)
	mu.draw_rect(ctx, {r.x + t, r.y + t, r.w - 2 * t, r.h - 2 * t}, back)
	mu.push_clip_rect(ctx, r)
	hx, hy := r.x + pad, r.y + pad
	if c.sha != "" {
		mu.draw_text(ctx, mu.Font(&ui.small), c.sha, {hx, hy}, ui.colors.accent)
		sw := text_width(&ui.small, c.sha)
		app.editbar.sha_rect = {hx - gap, hy - gap, sw + 2 * gap, ui.small.cell_h + 2 * gap}
		if app.editbar.sha_hover {
			// Underlined under the mouse: a click shows the whole commit.
			mu.draw_rect(ctx, {hx, hy + ui.small.cell_h - t, sw, t}, ui.colors.accent)
		}
		rest := head[len(c.sha):]
		mu.draw_text(ctx, mu.Font(&ui.small), rest, {hx + text_width(&ui.small, c.sha), hy}, mix(bg, fg, 0.6))
	} else {
		mu.draw_text(ctx, mu.Font(&ui.small), head, {hx, hy}, mix(bg, fg, 0.6))
	}
	mu.draw_text(ctx, mu.Font(f), c.summary, {hx, hy + ui.small.cell_h + gap}, mix(bg, fg, c.committed ? 0.95 : 0.6))
	mu.pop_clip_rect(ctx)
}

// ---- The commit's detail ----

// blame_detail_open asks nvim for the commit on the small card.
@(private = "file")
blame_detail_open :: proc(app: ^App) {
	e := &app.editbar
	blame_detail_close(app)
	d := &e.detail
	d.open, d.loading = true, true
	d.sha = strings.clone(e.blame.sha)
	d.author = strings.clone(e.blame.author)
	d.when_ = strings.clone(e.blame.when_)
	d.message = strings.clone(e.blame.summary)
	d.anchor = {e.card_rect.x, e.card_rect.y}
	exec_lua(app, "local M = rawget(_G, '__ngam_blame'); if M then M.detail() end", {})
	app.need_draw = true
}

blame_detail_close :: proc(app: ^App) {
	d := &app.editbar.detail
	for f in d.files {
		delete(f.status)
		delete(f.path)
		delete(f.from)
	}
	delete(d.files)
	for s in ([]string{d.sha, d.author, d.email, d.when_, d.date, d.committer, d.message, d.error}) {
		delete(s)
	}
	d^ = {}
	app.need_draw = true
}

// blame_detail_show takes nvim's answer to M.detail().
blame_detail_show :: proc(app: ^App, info: []mp.Map_Entry) {
	d := &app.editbar.detail
	if !d.open || !d.loading {
		return
	}
	anchor := d.anchor
	short := strings.clone(d.sha, context.temp_allocator)
	blame_detail_close(app)
	d.open = true
	d.anchor = anchor
	d.sha = strings.clone(mp.as_str(mp.map_get(info, "sha")))
	if d.sha == "" {
		delete(d.sha)
		d.sha = strings.clone(short)
	}
	d.error = strings.clone(mp.as_str(mp.map_get(info, "error")))
	d.author = strings.clone(mp.as_str(mp.map_get(info, "author")))
	d.email = strings.clone(mp.as_str(mp.map_get(info, "email")))
	d.when_ = strings.clone(mp.as_str(mp.map_get(info, "when")))
	d.date = strings.clone(mp.as_str(mp.map_get(info, "date")))
	d.committer = strings.clone(mp.as_str(mp.map_get(info, "committer")))
	d.message = strings.clone(mp.as_str(mp.map_get(info, "message")))
	d.total = int(mp.as_int(mp.map_get(info, "total")))
	for v in mp.as_array(mp.map_get(info, "files")) {
		m := mp.as_map(v)
		append(&d.files, Blame_File{
			status = strings.clone(mp.as_str(mp.map_get(m, "status"))),
			path = strings.clone(mp.as_str(mp.map_get(m, "path"))),
			from = strings.clone(mp.as_str(mp.map_get(m, "from"))),
			add = int(mp.as_int(mp.map_get(m, "add"))),
			del = int(mp.as_int(mp.map_get(m, "del"))),
			binary = mp.as_bool(mp.map_get(m, "binary")),
		})
	}
	app.need_draw = true
}

// blame_detail_wheel scrolls the detail when the mouse is over it.
blame_detail_wheel :: proc(app: ^App, mouse: [2]i32, dy: f32) -> bool {
	d := &app.editbar.detail
	if !d.open || !inside(d.rect, mouse) {
		return false
	}
	detail_scroll(app, i32(-dy * 30 * app.density))
	return true
}

// blame_detail_key takes Escape (close) and the scrolling keys while the
// detail is open. Any other key closes it and goes on to nvim.
blame_detail_key :: proc(app: ^App, key: sdl.Keycode) -> bool {
	d := &app.editbar.detail
	if !d.open {
		return false
	}
	line := app.font.cell_h
	page := max(d.rect.h - 4 * line, line)
	switch key {
	case sdl.K_ESCAPE:
		blame_detail_close(app)
	case sdl.K_UP:
		detail_scroll(app, -line)
	case sdl.K_DOWN:
		detail_scroll(app, line)
	case sdl.K_PAGEUP:
		detail_scroll(app, -page)
	case sdl.K_PAGEDOWN:
		detail_scroll(app, page)
	case sdl.K_LSHIFT, sdl.K_RSHIFT, sdl.K_LCTRL, sdl.K_RCTRL, sdl.K_LALT, sdl.K_RALT, sdl.K_LGUI, sdl.K_RGUI:
		// A modifier alone: wait for the key it goes with.
	case:
		blame_detail_close(app)
		return false
	}
	return true
}

@(private = "file")
detail_scroll :: proc(app: ^App, by: i32) {
	d := &app.editbar.detail
	d.scroll = clamp(d.scroll + by, 0, max(d.content_h - d.rect.h, 0))
	app.need_draw = true
}

// Detail_Line is one line of the detail card, measured before drawing.
@(private = "file")
Detail_Line :: struct {
	kind: enum {
		Text,
		Bold,
		Rule,
		File,
		Gap,
	},
	text: string,
	font: ^Font,
	color: mu.Color,
	file: int, // for File
}

// blame_detail_frame draws the bigger card: the hash, author and date,
// the whole message, and the files changed with their line counts. It
// is opaque, and scrolls when it is taller than the window.
@(private = "file")
blame_detail_frame :: proc(app: ^App) {
	d := &app.editbar.detail
	if !d.open || app.setup_open {
		return
	}
	ctx := &app.ui.ctx
	ui := &app.ui
	g := &app.grid
	f := &app.font
	fg, bg := g.default_fg, g.default_bg
	dens := app.density
	pad := i32(12 * dens)
	margin := i32(8 * dens)
	t := max(i32(dens), 1)
	win_w, win_h := window_pixels(app)
	dim := mix(bg, fg, 0.6)
	text := mix(bg, fg, 0.95)

	// The width: the longest line up to 100 columns, at least 60, and
	// within the window.
	w := min(100 * f.cell_w, win_w - 2 * margin)
	w = max(w, min(60 * f.cell_w, win_w - 2 * margin))
	inner := w - 2 * pad

	lines := make([dynamic]Detail_Line, context.temp_allocator)
	add :: proc(lines: ^[dynamic]Detail_Line, l: Detail_Line) {append(lines, l)}
	who := d.author
	if d.email != "" {
		who = strings.concatenate({who, " <", d.email, ">"}, context.temp_allocator)
	}
	when_ := d.date
	if d.when_ != "" {
		when_ = when_ != "" ? strings.concatenate({when_, " (", d.when_, ")"}, context.temp_allocator) : d.when_
	}
	add(&lines, {kind = .Text, text = who, font = &ui.font, color = text})
	if when_ != "" {
		add(&lines, {kind = .Text, text = when_, font = &ui.small, color = dim})
	}
	if d.committer != "" && d.committer != d.author {
		add(&lines, {kind = .Text, text = strings.concatenate({"Committed by ", d.committer}, context.temp_allocator), font = &ui.small, color = dim})
	}
	add(&lines, {kind = .Rule})
	msg := strings.trim_space(d.message)
	subject, _, body := strings.partition(msg, "\n")
	for l in wrap_lines(f, subject, inner) {
		add(&lines, {kind = .Bold, text = l, font = f, color = text})
	}
	body = strings.trim_space(body)
	if body != "" {
		add(&lines, {kind = .Gap})
		for l in wrap_lines(f, body, inner) {
			add(&lines, {kind = .Text, text = l, font = f, color = mix(bg, fg, 0.85)})
		}
	}
	if d.error != "" {
		add(&lines, {kind = .Gap})
		for l in wrap_lines(&ui.font, d.error, inner) {
			add(&lines, {kind = .Text, text = l, font = &ui.font, color = ui.colors.conflict})
		}
	} else if d.loading {
		add(&lines, {kind = .Gap})
		add(&lines, {kind = .Text, text = "Loading…", font = &ui.small, color = dim})
	} else {
		add(&lines, {kind = .Rule})
		plus, minus := 0, 0
		for x in d.files {
			plus += max(x.add, 0)
			minus += max(x.del, 0)
		}
		n := max(d.total, len(d.files))
		sum := fmt.tprintf("%d file%s changed", n, n == 1 ? "" : "s")
		if len(d.files) == n {
			sum = fmt.tprintf("%s  +%d −%d", sum, plus, minus)
		}
		add(&lines, {kind = .Text, text = sum, font = &ui.small, color = dim})
		for _, i in d.files {
			add(&lines, {kind = .File, file = i, font = f})
		}
		if n > len(d.files) {
			add(&lines, {kind = .Text, text = fmt.tprintf("… and %d more", n - len(d.files)), font = &ui.small, color = dim})
		}
	}

	line_h :: proc(l: Detail_Line, gap: i32) -> i32 {
		switch l.kind {
		case .Rule, .Gap:
			return 2 * gap
		case .Text, .Bold, .File:
			return l.font.cell_h + gap / 2
		}
		return 0
	}
	gap := i32(5 * dens)
	head_h := ui.small.cell_h + gap
	content := head_h
	for l in lines {
		content += line_h(l, gap)
	}
	h := min(content + 2 * pad, win_h - 2 * margin)
	d.content_h = content + 2 * pad
	d.scroll = clamp(d.scroll, 0, max(d.content_h - h, 0))
	x := clamp(d.anchor.x, margin, max(win_w - margin - w, margin))
	y := clamp(d.anchor.y, margin, max(win_h - margin - h, margin))
	r := mu.Rect{x, y, w, h}
	d.rect = r
	if !fixed_window(ctx, "!blame_detail", r, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE, .NO_SCROLL, .NO_FRAME, .NO_INTERACT}, Z_TOAST) {
		return
	}
	defer mu.end_window(ctx)
	border := mix(bg, fg, 0.3)
	mu.draw_rect(ctx, r, border)
	mu.draw_rect(ctx, {r.x + t, r.y + t, r.w - 2 * t, r.h - 2 * t}, mix(bg, fg, 0.05))
	mu.push_clip_rect(ctx, {r.x + t, r.y + t, r.w - 2 * t, r.h - 2 * t})
	defer mu.pop_clip_rect(ctx)

	lx := r.x + pad
	ly := r.y + pad - d.scroll
	// The full hash; Escape closes the card.
	mu.draw_text(ctx, mu.Font(&ui.small), d.sha, {lx, ly}, ui.colors.accent)
	hint := "Esc to close"
	mu.draw_text(ctx, mu.Font(&ui.small), hint, {r.x + r.w - pad - text_width(&ui.small, hint), ly}, mix(bg, fg, 0.4))
	ly += head_h
	for l in lines {
		lh := line_h(l, gap)
		if ly + lh < r.y || ly > r.y + r.h {
			ly += lh
			continue
		}
		switch l.kind {
		case .Gap:
		case .Rule:
			mu.draw_rect(ctx, {lx, ly + gap, inner, t}, mix(bg, fg, 0.15))
		case .Text:
			mu.draw_text(ctx, mu.Font(l.font), l.text, {lx, ly}, l.color)
		case .Bold:
			mu.draw_text(ctx, mu.Font(l.font), l.text, {lx, ly}, l.color)
			mu.draw_text(ctx, mu.Font(l.font), l.text, {lx + t, ly}, l.color)
		case .File:
			file_row(app, d.files[l.file], {lx, ly, inner, f.cell_h})
		}
		ly += lh
	}
	// A thin bar shows where the view is when it scrolls.
	if d.content_h > h {
		bar_h := max(h * h / d.content_h, i32(20 * dens))
		bar_y := r.y + (h - bar_h) * d.scroll / max(d.content_h - h, 1)
		mu.draw_rect(ctx, {r.x + r.w - i32(5 * dens), bar_y, i32(3 * dens), bar_h}, mix(bg, fg, 0.3))
	}
}

// file_row draws one changed file: its letter in git's colours, its path
// (old → new for a rename), and its lines added and removed at the right.
@(private = "file")
file_row :: proc(app: ^App, x: Blame_File, r: mu.Rect) {
	ctx := &app.ui.ctx
	ui := &app.ui
	f := &app.font
	fg, bg := app.grid.default_fg, app.grid.default_bg
	color := ui.colors.modified
	switch x.status {
	case "A":
		color = ui.colors.added
	case "D":
		color = ui.colors.deleted
	case "R", "C":
		color = ui.colors.accent
	}
	mu.draw_text(ctx, mu.Font(f), x.status, {r.x, r.y}, color)
	px := r.x + 2 * f.cell_w

	// The counts first, so the path is cut short before them.
	right := r.x + r.w
	sy := r.y + (f.cell_h - ui.small.cell_h) / 2
	if x.binary {
		s := "binary"
		right -= text_width(&ui.small, s)
		mu.draw_text(ctx, mu.Font(&ui.small), s, {right, sy}, mix(bg, fg, 0.5))
	} else if x.add >= 0 || x.del >= 0 {
		del := fmt.tprintf("−%d", max(x.del, 0))
		addt := fmt.tprintf("+%d", max(x.add, 0))
		right -= text_width(&ui.small, del)
		mu.draw_text(ctx, mu.Font(&ui.small), del, {right, sy}, ui.colors.deleted)
		right -= text_width(&ui.small, addt) + i32(6 * app.density)
		mu.draw_text(ctx, mu.Font(&ui.small), addt, {right, sy}, ui.colors.added)
	}
	path := x.path
	if x.from != "" {
		path = strings.concatenate({x.from, " → ", x.path}, context.temp_allocator)
	}
	mu.push_clip_rect(ctx, {px, r.y, max(right - px - f.cell_w, 0), r.h})
	mu.draw_text(ctx, mu.Font(f), path, {px, r.y}, mix(bg, fg, 0.9))
	mu.pop_clip_rect(ctx)
}

// mix is a colour between the editor colours a and b.
@(private = "file")
mix :: proc(a, b: i32, t: f32) -> mu.Color {
	m :: proc(x, y: i32, t: f32) -> u8 {return u8(f32(x) + (f32(y) - f32(x)) * t)}
	return {m((a >> 16) & 0xff, (b >> 16) & 0xff, t), m((a >> 8) & 0xff, (b >> 8) & 0xff, t), m(a & 0xff, b & 0xff, t), 255}
}
