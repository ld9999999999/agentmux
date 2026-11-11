package ngam

// The side panel, like VS Code's: an activity bar at the left edge with one
// icon per view, and the panel beside it that shows the chosen view. The
// panel slides in and pushes the editor to the right; nvim is resized once
// the slide ends. Its right edge drags to change its width.
//
// Views are the first extensions. Each is a table of procs in the VIEWS
// list below; a new view needs only a new entry and its procs.

import "core:time"
import mu "vendor:microui"
import sdl "vendor:sdl3"

View :: struct {
	name:    string,
	icon:    string, // one character, drawn in the activity bar
	key:     rune, // Cmd-Shift-<key> shows the view
	poll_ms: int, // refresh (or poll) this often while the view is shown; 0 turns it off
	// poll, if set, runs on that schedule in place of refresh, for a view
	// whose full refresh is too much to repeat.
	poll:    proc(app: ^App),
	// refresh asks nvim for the view's data again.
	refresh: proc(app: ^App),
	// draw draws the view's rows and returns the clicked row, or -1.
	draw:    proc(app: ^App) -> int,
	// click handles a click on a row; mods are the modifiers held.
	click:   proc(app: ^App, row: int, mods: sdl.Keymod),
	// header draws the view's buttons at the right of its title; buttons
	// is how many it draws.
	header:  proc(app: ^App),
	buttons: int,
	// target is the file or folder a row stands for, and its nvim buffer
	// number (or 0), for the row's right-click menu. A view with no menu
	// leaves it nil.
	target:  proc(app: ^App, row: int) -> (path: string, dir: bool, buf: int, ok: bool),
}

VIEWS := [?]View {
	{
		name = "Explorer",
		icon = "⧉",
		key = 'e',
		poll_ms = 2000,
		poll = git_refresh, // the files' git letters
		refresh = explorer_refresh,
		draw = explorer_draw,
		click = explorer_click,
		header = explorer_header,
		buttons = 2,
		target = explorer_target,
	},
	{
		name = "Git",
		icon = "⑂",
		key = 'g',
		poll_ms = 2000,
		refresh = git_refresh,
		draw = git_draw,
		click = git_click,
		header = git_header,
		buttons = 2,
		target = git_target,
	},
	{
		name = "Sessions",
		icon = "☰",
		key = 's',
		poll_ms = 3000,
		refresh = sessions_refresh,
		draw = sessions_draw,
		click = sessions_click,
		header = sessions_header,
		buttons = 2,
	},
}

BAR_PT :: 44 // the activity bar's width, and each icon's height, in points
ANIM :: 160 * time.Millisecond
MIN_PANEL_PT :: 150
MIN_EDITOR_PT :: 200

Panel :: struct {
	open:         bool, // where the panel is heading: shown or hidden
	view:         int, // the index in VIEWS of the view shown
	width:        f32, // points
	shown:        f32, // how much is on screen: 0 hidden .. 1 all
	anim_from:    f32,
	anim_start:   time.Tick, // set while sliding, else zero
	dragging:     bool, // the edge is being dragged
	over_edge:    bool, // the mouse is on the edge (for the cursor)
	last_refresh: time.Tick,
	cursor_ew:    ^sdl.Cursor,
	cursor_arrow: ^sdl.Cursor,
}

panel_init :: proc(app: ^App) {
	p := &app.panel
	p.open = app.settings.panel_open
	p.shown = p.open ? 1 : 0
	p.width = f32(app.settings.panel_width)
	for v, i in VIEWS {
		if v.name == app.settings.panel_view {
			p.view = i
		}
	}
	p.cursor_ew = sdl.CreateSystemCursor(.EW_RESIZE)
	p.cursor_arrow = sdl.CreateSystemCursor(.DEFAULT)
}

// bar_width is the activity bar's width in pixels. The bar shows only
// while there is a session.
bar_width :: proc(app: ^App) -> i32 {
	if app.link == nil {
		return 0
	}
	return i32(BAR_PT * app.density)
}

panel_full_width :: proc(app: ^App) -> i32 {
	return i32(app.panel.width * app.density)
}

// panel_visible_width is how much of the panel is on screen now, in
// pixels.
panel_visible_width :: proc(app: ^App) -> i32 {
	if app.link == nil {
		return 0
	}
	return i32(f32(panel_full_width(app)) * app.panel.shown)
}

// panel_target_width is the panel's width once it stops sliding.
panel_target_width :: proc(app: ^App) -> i32 {
	if app.link == nil || !app.panel.open {
		return 0
	}
	return panel_full_width(app)
}

// panel_clamp_width keeps the panel and the editor both usable after the
// window shrinks.
panel_clamp_width :: proc(app: ^App) {
	w, h: i32
	_ = sdl.GetWindowSize(app.window, &w, &h)
	most := max(f32(w) - BAR_PT - MIN_EDITOR_PT - f32(agent_pane_px(app)) / app.density, MIN_PANEL_PT)
	app.panel.width = clamp(app.panel.width, MIN_PANEL_PT, most)
}

// panel_set shows the view at index view, or hides the panel, and saves
// the choice.
panel_set :: proc(app: ^App, open: bool, view: int) {
	p := &app.panel
	changed_view := view != p.view
	if open != p.open {
		p.anim_from = p.shown
		p.anim_start = time.tick_now()
		p.open = open
	}
	p.view = view
	if open && (changed_view || p.anim_start != {}) {
		panel_refresh(app)
	}
	app.settings.panel_open = open
	app.settings.panel_view = VIEWS[view].name
	settings_save(&app.settings)
	app.need_draw = true
}

panel_toggle :: proc(app: ^App) {
	panel_set(app, !app.panel.open, app.panel.view)
}

// panel_show_key shows the view whose shortcut letter is key.
panel_show_key :: proc(app: ^App, key: rune) {
	for v, i in VIEWS {
		if v.key == key {
			panel_set(app, true, i)
		}
	}
}

// panel_click_icon handles a click on an activity bar icon: show its view,
// or hide the panel when that view is already shown.
panel_click_icon :: proc(app: ^App, i: int) {
	if app.panel.open && app.panel.view == i {
		panel_set(app, false, i)
	} else {
		panel_set(app, true, i)
	}
}

panel_refresh :: proc(app: ^App) {
	app.panel.last_refresh = time.tick_now()
	VIEWS[app.panel.view].refresh(app)
}

// panel_visible says whether a view is on screen.
panel_visible :: proc(app: ^App) -> bool {
	return app.link != nil && app.panel.open && !app.setup_open
}

panel_focus_gained :: proc(app: ^App) {
	if panel_visible(app) {
		panel_refresh(app)
	}
}

panel_session_started :: proc(app: ^App) {
	if app.link != nil && app.panel.open {
		panel_refresh(app)
	}
}

panel_animating :: proc(app: ^App) -> bool {
	return app.panel.anim_start != {}
}

// panel_tick moves the slide along, and polls the view when it is time.
panel_tick :: proc(app: ^App) {
	p := &app.panel
	if p.anim_start != {} {
		t := f32(time.tick_since(p.anim_start)) / f32(ANIM)
		target: f32 = p.open ? 1 : 0
		if t >= 1 {
			p.shown = target
			p.anim_start = {}
			resize_editor(app) // now that the slide is over
		} else {
			ease := 1 - (1 - t) * (1 - t) * (1 - t)
			p.shown = p.anim_from + (target - p.anim_from) * ease
		}
		app.need_draw = true
	}
	if panel_visible(app) && app.focused {
		v := &VIEWS[p.view]
		if v.poll_ms > 0 && time.tick_since(p.last_refresh) >= time.Duration(v.poll_ms) * time.Millisecond {
			if v.poll != nil {
				p.last_refresh = time.tick_now()
				v.poll(app)
			} else {
				panel_refresh(app)
			}
		}
	}
}

// panel_poll_timeout is how long until the next poll, in ms, or -1.
panel_poll_timeout :: proc(app: ^App) -> i32 {
	ms := VIEWS[app.panel.view].poll_ms
	if !panel_visible(app) || !app.focused || ms <= 0 {
		return -1
	}
	left := time.Duration(ms) * time.Millisecond - time.tick_since(app.panel.last_refresh)
	return max(i32(time.duration_milliseconds(left)) + 1, 1)
}

// on_edge says whether the mouse is on the panel's draggable right edge.
@(private = "file")
on_edge :: proc(app: ^App) -> bool {
	if !app.panel.open || app.panel.shown < 1 || app.setup_open {
		return false
	}
	edge := bar_width(app) + panel_visible_width(app)
	return abs(app.mouse.x - edge) <= i32(4 * app.density)
}

// panel_mouse_down handles a press on the activity bar or the panel's
// edge, and says whether it did.
panel_mouse_down :: proc(app: ^App) -> bool {
	if app.link == nil || app.setup_open {
		return false
	}
	if app.mouse.x < bar_width(app) {
		_, h := window_pixels(app)
		if app.mouse.y >= h - bar_width(app) {
			settings_toggle(app) // the gear at the bottom
			return true
		}
		i := int(app.mouse.y / i32(BAR_PT * app.density))
		if i < len(VIEWS) {
			panel_click_icon(app, i)
		}
		return true
	}
	if on_edge(app) {
		app.panel.dragging = true
		return true
	}
	return false
}

// panel_mouse_move drags the edge, and shows the resize cursor on it.
panel_mouse_move :: proc(app: ^App) -> bool {
	p := &app.panel
	if p.dragging {
		p.width = f32(app.mouse.x - bar_width(app)) / app.density
		panel_clamp_width(app)
		app.need_draw = true
		return true
	}
	if over := app.link != nil && on_edge(app); over != p.over_edge {
		p.over_edge = over
		_ = sdl.SetCursor(over ? p.cursor_ew : p.cursor_arrow)
	}
	return false
}

panel_mouse_up :: proc(app: ^App) -> bool {
	if !app.panel.dragging {
		return false
	}
	app.panel.dragging = false
	app.settings.panel_width = int(app.panel.width)
	settings_save(&app.settings)
	resize_editor(app)
	return true
}

// panel_frame builds the panel and the activity bar for this frame.
panel_frame :: proc(app: ^App) {
	ctx := &app.ui.ctx
	ui := &app.ui
	w, h: i32
	_ = sdl.GetWindowSizeInPixels(app.window, &w, &h)
	bar := bar_width(app)
	full := panel_full_width(app)
	vis := panel_visible_width(app)

	if vis > 0 {
		// The panel keeps its full width while it slides, so its rows stay
		// in place; the activity bar covers the hidden part.
		r := mu.Rect{bar + vis - full, 0, full, h}
		v := &VIEWS[app.panel.view]
		if fixed_window(ctx, "!panel", r, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE}, 1) {
			pad := ctx.style.padding
			bw := i32(26 * app.density)
			nb := i32(max(v.buttons, 1))
			row_h := ui.font.cell_h + pad * 2
			// The title, then the view's buttons, in one row.
			widths := make([]i32, nb + 1, context.temp_allocator)
			for &x in widths[1:] {
				x = bw
			}
			widths[0] = -(bw + ctx.style.spacing) * nb - 1 // microui adds 1 to a negative width
			mu.layout_row(ctx, widths, row_h)
			tr := mu.layout_next(ctx)
			mu.draw_text(ctx, mu.Font(&ui.small), upper(v.name), {tr.x, tr.y + (tr.h - ui.small.cell_h) / 2}, ui.colors.dim)
			v.header(app)
			ui.right_click = false
			row := v.draw(app)
			switch {
			case row < 0:
			case ui.right_click:
				if v.target != nil {
					if path, dir, buf, ok := v.target(app, row); ok {
						menu_open(app, path, dir, buf)
					}
				}
			case:
				v.click(app, row, app.click_mods)
			}
			ui.right_click = false
			// A hairline between the panel and the editor.
			mu.push_clip_rect(ctx, mu.unclipped_rect)
			mu.draw_rect(ctx, {r.x + r.w - max(i32(app.density), 1), r.y, max(i32(app.density), 1), r.h}, ctx.style.colors[.BORDER])
			mu.pop_clip_rect(ctx)
			mu.end_window(ctx)
		}
	}

	// The activity bar, above the panel.
	br := mu.Rect{0, 0, bar, h}
	if fixed_window(ctx, "!bar", br, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE, .NO_SCROLL, .NO_FRAME, .NO_INTERACT}, Z_BAR) {
		mu.draw_rect(ctx, br, ui.colors.bar)
		for v, i in VIEWS {
			ir := mu.Rect{0, i32(i) * bar, bar, bar}
			active := app.panel.open && app.panel.view == i
			color := active ? ui.colors.bar_active : ui.colors.bar_icon
			if !active && mu.mouse_over(ctx, ir) {
				color = ui.colors.bar_active
			}
			if active {
				mu.draw_rect(ctx, {0, ir.y, i32(2 * app.density), bar}, ui.colors.bar_active)
			}
			iw := text_width(&ui.icons, v.icon)
			mu.draw_text(ctx, mu.Font(&ui.icons), v.icon, {(bar - iw) / 2, ir.y + (bar - ui.icons.cell_h) / 2}, color)
		}
		// The settings gear, at the bottom like VS Code's.
		gr := mu.Rect{0, h - bar, bar, bar}
		gear := "⚙"
		gcolor := mu.mouse_over(ctx, gr) ? ui.colors.bar_active : ui.colors.bar_icon
		gw := text_width(&ui.icons, gear)
		mu.draw_text(ctx, mu.Font(&ui.icons), gear, {(bar - gw) / 2, gr.y + (bar - ui.icons.cell_h) / 2}, gcolor)
		mu.end_window(ctx)
	}
}
