package ngam

// The UI layer: vendor:microui for the side panel and the setup screen,
// drawn with the same quad renderer as the grid. The UI uses its own
// proportional font, and a larger one for the activity bar's icons. All UI
// coordinates are window pixels.

import "core:strings"
import mu "vendor:microui"
import sdl "vendor:sdl3"

// Colors ngam draws itself, beyond microui's style colors.
Ui_Colors :: struct {
	bar:        mu.Color, // the activity bar
	bar_icon:   mu.Color,
	bar_active: mu.Color,
	dim:        mu.Color, // secondary text
	hover:      mu.Color, // a list row under the mouse
	selected:   mu.Color, // the selected list row
	accent:     mu.Color, // the chosen option among buttons
	overlay:    mu.Color, // dims the editor behind the setup screen
	folder:     mu.Color, // the folder icon
	file:       mu.Color, // the file icon's outline
	modified:   mu.Color, // git status letters
	added:      mu.Color,
	deleted:    mu.Color,
	conflict:   mu.Color,
	frame:      mu.Color, // the frame around a group of settings
}

Ui :: struct {
	ctx:         mu.Context,
	font:        Font, // proportional, for labels
	icons:       Font, // the same faces, larger, for the activity bar
	small:       Font, // the same faces, smaller, for the panel's title
	density:     f32,
	group:       Group, // the group being built, between group_begin and group_end
	dark:        bool,
	colors:      Ui_Colors,
	// list_row sets this when the row it draws gets a right click, and
	// returns true as for a left click; the panel then opens a menu.
	right_click: bool,
}

// Row_Icon is the small drawn icon at the start of a list row.
Row_Icon :: enum {
	None,
	Folder,
	Folder_Open,
	File,
}

@(private = "file")
hex :: proc(rgb: u32) -> mu.Color {
	return {u8(rgb >> 16), u8(rgb >> 8), u8(rgb), 255}
}

// ui_init sets up microui. The fonts are loaded by ui_load_fonts.
ui_init :: proc(ui: ^Ui) {
	mu.init(&ui.ctx, ui_set_clipboard, ui_get_clipboard)
	ui.ctx.text_width = proc(font: mu.Font, s: string) -> i32 {
		return text_width((^Font)(font), s)
	}
	ui.ctx.text_height = proc(font: mu.Font) -> i32 {
		return (^Font)(font).cell_h
	}
}

@(private = "file")
ui_set_clipboard :: proc(_: rawptr, text: string) -> bool {
	clipboard_set(text)
	return true
}

@(private = "file")
ui_get_clipboard :: proc(_: rawptr) -> (string, bool) {
	return clipboard_get(), true
}

// ui_load_fonts loads the UI fonts for density, and sizes microui's
// spacing to match.
ui_load_fonts :: proc(ui: ^Ui, r: ^sdl.Renderer, density: f32) {
	font_destroy(&ui.font)
	font_destroy(&ui.icons)
	font_destroy(&ui.small)
	ui.density = density
	spec: Font_Spec
	for path in UI_FONTS {
		if s, ok := font_spec_from_file(path, context.temp_allocator); ok {
			spec = s
			break
		}
	}
	if spec.faces[.Regular].path == "" {
		spec, _ = font_spec_from_file(DEFAULT_FONT, context.temp_allocator)
	}
	_ = font_load(&ui.font, spec, UI_SIZE, density)
	ui.font.atlas_size = 1024 // the UI uses few glyphs; full resets it
	atlas_reset(&ui.font, r)
	_ = font_load(&ui.icons, spec, 22, density)
	ui.icons.atlas_size = 512
	atlas_reset(&ui.icons, r)
	_ = font_load(&ui.small, spec, 11, density)
	ui.small.atlas_size = 512
	atlas_reset(&ui.small, r)

	st := ui.ctx.style
	st.font = mu.Font(&ui.font)
	d := density
	st.size = {i32(60 * d), i32(ui.font.cell_h)}
	st.padding = i32(5 * d)
	st.spacing = i32(4 * d)
	st.indent = i32(14 * d)
	st.title_height = ui.font.cell_h + i32(10 * d)
	st.footer_height = i32(20 * d)
	st.scrollbar_size = i32(10 * d)
	st.thumb_size = i32(8 * d)
}

// ui_set_theme picks the light or dark palette.
ui_set_theme :: proc(ui: ^Ui, dark: bool) {
	ui.dark = dark
	c := &ui.ctx.style.colors
	if dark {
		c^ = {
			.TEXT         = hex(0xcccccc),
			.SELECTION_BG = hex(0x264f78),
			.BORDER       = hex(0x3c3c3c),
			.WINDOW_BG    = hex(0x252526),
			.TITLE_BG     = hex(0x333333),
			.TITLE_TEXT   = hex(0xcccccc),
			.PANEL_BG     = hex(0x1e1e1e),
			.BUTTON       = hex(0x3a3d41),
			.BUTTON_HOVER = hex(0x45494e),
			.BUTTON_FOCUS = hex(0x505357),
			.BASE         = hex(0x3c3c3c),
			.BASE_HOVER   = hex(0x464646),
			.BASE_FOCUS   = hex(0x4a4a4a),
			.SCROLL_BASE  = hex(0x2a2a2a),
			.SCROLL_THUMB = hex(0x4f4f4f),
		}
		ui.colors = {
			bar        = hex(0x333333),
			bar_icon   = hex(0x858585),
			bar_active = hex(0xffffff),
			dim        = hex(0x8b8b8b),
			hover      = hex(0x2a2d2e),
			selected   = hex(0x37373d),
			accent     = hex(0x0e639c),
			overlay    = {0, 0, 0, 140},
			folder     = hex(0xdcb67a),
			file       = hex(0x9d9d9d),
			modified   = hex(0xe2c08d),
			added      = hex(0x73c991),
			deleted    = hex(0xc74e39),
			conflict   = hex(0xe4676b),
			frame      = hex(0x4a4a4a),
		}
	} else {
		c^ = {
			.TEXT         = hex(0x333333),
			.SELECTION_BG = hex(0xadd6ff),
			.BORDER       = hex(0xcecece),
			.WINDOW_BG    = hex(0xf3f3f3),
			.TITLE_BG     = hex(0xdddddd),
			.TITLE_TEXT   = hex(0x333333),
			.PANEL_BG     = hex(0xffffff),
			.BUTTON       = hex(0xdcdcdc),
			.BUTTON_HOVER = hex(0xcacaca),
			.BUTTON_FOCUS = hex(0xbababa),
			.BASE         = hex(0xffffff),
			.BASE_HOVER   = hex(0xf5f5f5),
			.BASE_FOCUS   = hex(0xeeeeee),
			.SCROLL_BASE  = hex(0xeaeaea),
			.SCROLL_THUMB = hex(0xc1c1c1),
		}
		ui.colors = {
			bar        = hex(0x2c2c2c),
			bar_icon   = hex(0x8a8a8a),
			bar_active = hex(0xffffff),
			dim        = hex(0x717171),
			hover      = hex(0xe8e8e8),
			selected   = hex(0xd6ebff),
			accent     = hex(0x007acc),
			overlay    = {0, 0, 0, 90},
			folder     = hex(0xc09553),
			file       = hex(0x8a8a8a),
			modified   = hex(0x895503),
			added      = hex(0x587c0c),
			deleted    = hex(0xad0707),
			conflict   = hex(0xad0707),
			frame      = hex(0xc4c4c4),
		}
	}
}

// ---- Input ----

ui_mouse_button :: proc(b: u8) -> (mu.Mouse, bool) {
	switch b {
	case sdl.BUTTON_LEFT:
		return .LEFT, true
	case sdl.BUTTON_RIGHT:
		return .RIGHT, true
	case sdl.BUTTON_MIDDLE:
		return .MIDDLE, true
	}
	return .LEFT, false
}

// ui_key maps an SDL key to microui's, for text boxes. On macOS Cmd acts
// as microui's Ctrl, so Cmd-C, Cmd-V and Cmd-A work in text boxes.
ui_key :: proc(k: sdl.Keycode) -> (mu.Key, bool) {
	switch k {
	case sdl.K_LSHIFT, sdl.K_RSHIFT:
		return .SHIFT, true
	case sdl.K_LCTRL, sdl.K_RCTRL:
		return .CTRL, true
	case sdl.K_LGUI, sdl.K_RGUI:
		when ODIN_OS == .Darwin {
			return .CTRL, true
		}
	case sdl.K_LALT, sdl.K_RALT:
		return .ALT, true
	case sdl.K_BACKSPACE:
		return .BACKSPACE, true
	case sdl.K_DELETE:
		return .DELETE, true
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		return .RETURN, true
	case sdl.K_LEFT:
		return .LEFT, true
	case sdl.K_RIGHT:
		return .RIGHT, true
	case sdl.K_HOME:
		return .HOME, true
	case sdl.K_END:
		return .END, true
	case sdl.K_A:
		return .A, true
	case sdl.K_X:
		return .X, true
	case sdl.K_C:
		return .C, true
	case sdl.K_V:
		return .V, true
	}
	return .SHIFT, false
}

// ---- Drawing ----

@(private = "file")
fcolor :: proc(c: mu.Color) -> sdl.FColor {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, f32(c.a) / 255}
}

// ui_render draws microui's commands for this frame.
ui_render :: proc(rd: ^Renderer, ui: ^Ui) {
	pcmd: ^mu.Command
	for variant in mu.next_command_iterator(&ui.ctx, &pcmd) {
		switch c in variant {
		case ^mu.Command_Rect:
			fill(rd, &ui.font, c.rect.x, c.rect.y, c.rect.w, c.rect.h, fcolor(c.color))
		case ^mu.Command_Text:
			f := (^Font)(c.font)
			if f == nil {
				f = &ui.font
			}
			_ = text(rd, f, c.pos.x, c.pos.y, c.str, fcolor(c.color))
		case ^mu.Command_Icon:
			icon: string
			#partial switch c.id {
			case .CLOSE:
				icon = "×"
			case .CHECK:
				icon = "✓"
			case .COLLAPSED:
				icon = "▸"
			case .EXPANDED:
				icon = "▾"
			}
			if icon != "" {
				w := text_width(&ui.font, icon)
				_ = text(rd, &ui.font, c.rect.x + (c.rect.w - w) / 2, c.rect.y + (c.rect.h - ui.font.cell_h) / 2, icon, fcolor(c.color))
			}
		case ^mu.Command_Clip:
			// microui's "no clip" is a huge rectangle.
			if c.rect.w >= 0x100000 {
				set_clip(rd, nil)
			} else {
				set_clip(rd, sdl.Rect{c.rect.x, c.rect.y, c.rect.w, c.rect.h})
			}
		case ^mu.Command_Jump:
		}
	}
	set_clip(rd, nil)
}

// ---- Widgets ----

// list_row draws one clickable row of a list: indent, an optional folder
// arrow and icon, then label, then a short tag at the right edge (a git
// status letter). It returns whether the row was clicked.
// label_color, if set, colours the label (a file git marks).
list_row :: proc(ui: ^Ui, key: string, indent: i32, label: string, detail := "", tag := "", tag_color := mu.Color{}, selected := false, icon := Row_Icon.None, arrow := "", label_color := mu.Color{}, number := "", number_w: i32 = 0) -> bool {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1}, ui.font.cell_h + ctx.style.padding)
	r := mu.layout_next(ctx)
	id := mu.get_id(ctx, key)
	mu.update_control(ctx, id, r)
	clicked := .LEFT in ctx.mouse_pressed_bits && ctx.focus_id == id
	if .RIGHT in ctx.mouse_pressed_bits && ctx.hover_id == id {
		clicked = true
		ui.right_click = true
	}
	if selected {
		mu.draw_rect(ctx, r, ui.colors.selected)
	} else if ctx.hover_id == id {
		mu.draw_rect(ctx, r, ui.colors.hover)
	}
	y := r.y + (r.h - ui.font.cell_h) / 2
	x := r.x + ctx.style.padding + indent
	if number != "" {
		// A number, dimmed and right-aligned in a column number_w wide.
		mu.draw_text(ctx, mu.Font(&ui.font), number, {x + number_w - text_width(&ui.font, number), y}, ui.colors.dim)
		x += number_w + ctx.style.padding
	}
	if arrow != "" {
		// A folder's ▸ or ▾, dimmed, before its icon.
		mu.draw_text(ctx, mu.Font(&ui.font), arrow, {x, y}, ui.colors.dim)
		x += text_width(&ui.font, "▸ ")
	}
	if icon != .None {
		size := ui.font.cell_h * 3 / 4
		draw_row_icon(ui, icon, {x, r.y + (r.h - size) / 2}, size)
		x += size + ctx.style.padding
	}
	// The tag sits at the right edge; a long label is cut off before it.
	tw: i32 = 0
	if tag != "" {
		tw = text_width(&ui.font, tag) + ctx.style.padding * 3
	}
	mu.push_clip_rect(ctx, {r.x, r.y, r.w - tw, r.h})
	mu.draw_text(ctx, mu.Font(&ui.font), label, {x, y}, label_color.a > 0 ? label_color : ctx.style.colors[.TEXT])
	if detail != "" {
		dx := x + text_width(&ui.font, label) + ctx.style.padding * 2
		mu.draw_text(ctx, mu.Font(&ui.font), detail, {dx, y}, ui.colors.dim)
	}
	mu.pop_clip_rect(ctx)
	if tag != "" {
		tx := r.x + r.w - tw + ctx.style.padding
		mu.draw_text(ctx, mu.Font(&ui.font), tag, {tx, y}, tag_color)
	}
	return clicked
}

// choice draws a row of buttons for exclusive options and returns the
// chosen index, changed when one is clicked.
choice :: proc(ui: ^Ui, key: string, labels: []string, current: int) -> int {
	ctx := &ui.ctx
	chosen := current
	mu.push_id(ctx, key)
	defer mu.pop_id(ctx)
	for label, i in labels {
		// The chosen option keeps the accent color, even under the mouse.
		saved := ctx.style.colors
		if i == current {
			ctx.style.colors[.BUTTON] = ui.colors.accent
			ctx.style.colors[.BUTTON_HOVER] = ui.colors.accent
			ctx.style.colors[.BUTTON_FOCUS] = ui.colors.accent
			ctx.style.colors[.TEXT] = {255, 255, 255, 255}
		}
		if .SUBMIT in mu.button(ctx, label) {
			chosen = i
		}
		ctx.style.colors = saved
	}
	return chosen
}

// heading draws a section title.
// Group is a group of settings drawn in a frame, with its title in a tab
// on the frame's top edge:
//
//    ─[ THEME ]──────────────
//   │ rows…                  │
//    ────────────────────────
//
// group_begin starts it; the rows that follow go in a column inside the
// frame; group_end closes the column and draws the frame around it.
Group :: struct {
	title: string,
	outer: mu.Rect, // the frame's left and right, and the tab's row
	body:  mu.Rect, // the column the rows go in
}

group_begin :: proc(ui: ^Ui, title: string) {
	ctx := &ui.ctx
	g := &ui.group
	pad := ctx.style.padding
	tab_h := ui.small.cell_h + pad
	mu.layout_row(ctx, {-1}, tab_h)
	g.title = title
	g.outer = mu.layout_next(ctx)
	inset := group_inset(ui)
	mu.layout_row(ctx, {inset, -inset}, 0)
	_ = mu.layout_next(ctx)
	mu.layout_begin_column(ctx)
	g.body = mu.get_layout(ctx).body
}

group_end :: proc(ui: ^Ui) {
	ctx := &ui.ctx
	g := &ui.group
	pad := ctx.style.padding
	l := mu.get_layout(ctx)
	bottom := l.body.y + l.next_row - ctx.style.spacing + pad * 2
	mu.layout_end_column(ctx)
	// Room for the bottom edge, and a gap before the next group.
	mu.layout_row(ctx, {-1}, pad * 4)
	_ = mu.layout_next(ctx)

	c := ui.colors.frame
	t := max(i32(ui.density), 1) // a point
	o := g.outer
	x0, x1 := o.x + pad / 2, o.x + o.w - pad / 2
	top := o.y + o.h / 2
	// The tab: the title in a small box that breaks the top edge.
	title := strings.to_upper(g.title, context.temp_allocator)
	tw := text_width(&ui.small, title) + pad * 3
	tx := x0 + group_inset(ui) - pad
	tab := mu.Rect{tx, o.y, tw, o.h}
	mu.draw_rect(ctx, {x0, top, tx - x0, t}, c)
	mu.draw_rect(ctx, {tx + tw, top, x1 - tx - tw, t}, c)
	mu.draw_rect(ctx, {tab.x, tab.y, tab.w, t}, c)
	mu.draw_rect(ctx, {tab.x, tab.y + tab.h - t, tab.w, t}, c)
	mu.draw_rect(ctx, {tab.x, tab.y, t, tab.h}, c)
	mu.draw_rect(ctx, {tab.x + tab.w - t, tab.y, t, tab.h}, c)
	ty := tab.y + (tab.h - ui.small.cell_h) / 2
	mu.draw_text(ctx, mu.Font(&ui.small), title, {tab.x + pad * 3 / 2, ty}, ui.colors.dim)
	mu.draw_text(ctx, mu.Font(&ui.small), title, {tab.x + pad * 3 / 2 + 1, ty}, ui.colors.dim)
	// The sides and the bottom.
	mu.draw_rect(ctx, {x0, top, t, bottom - top}, c)
	mu.draw_rect(ctx, {x1 - t, top, t, bottom - top}, c)
	mu.draw_rect(ctx, {x0, bottom - t, x1 - x0, t}, c)
}

// group_inset is how far a group's rows sit inside its frame.
@(private = "file")
group_inset :: proc(ui: ^Ui) -> i32 {
	return ui.ctx.style.padding * 3
}

// Text_Field keeps a text box's bytes for microui.
Text_Field :: struct {
	buf: [512]u8,
	len: int,
}

field_set :: proc(f: ^Text_Field, s: string) {
	f.len = copy(f.buf[:], s)
}

field_text :: proc(f: ^Text_Field) -> string {
	return string(f.buf[:f.len])
}

// textbox draws f and reports whether its text changed.
textbox :: proc(ui: ^Ui, f: ^Text_Field) -> bool {
	return .CHANGE in mu.textbox(&ui.ctx, f.buf[:], &f.len)
}

// upper is s in capitals, for headings.
upper :: proc(s: string) -> string {
	return strings.to_upper(s, context.temp_allocator)
}

// icon_button is a small flat button with a symbol, such as ↻: just the
// symbol, with a background only under the mouse.
icon_button :: proc(ui: ^Ui, key, symbol: string, font: ^Font = nil) -> bool {
	ctx := &ui.ctx
	mu.push_id(ctx, key)
	defer mu.pop_id(ctx)
	id := mu.get_id(ctx, symbol)
	r := mu.layout_next(ctx)
	mu.update_control(ctx, id, r)
	clicked := .LEFT in ctx.mouse_pressed_bits && ctx.focus_id == id
	color := ui.colors.dim
	if ctx.hover_id == id {
		mu.draw_rect(ctx, r, ui.colors.hover)
		color = ctx.style.colors[.TEXT]
	}
	f := font != nil ? font : &ui.font
	w := text_width(f, symbol)
	// Centre the symbol's ink: symbols such as ⌕ sit low in the line, so
	// centring the line would put them below their neighbours.
	y := r.y + (r.h - f.cell_h) / 2
	for c in symbol {
		if g := glyph_get(f, c, .Regular); g.h > 0 {
			y = r.y + (r.h - g.h) / 2 - g.dy
		}
		break
	}
	mu.draw_text(ctx, mu.Font(f), symbol, {r.x + (r.w - w) / 2, y}, color)
	return clicked
}

// draw_row_icon draws a small folder or file shape with rectangles, so it
// works with any font and follows the theme.
draw_row_icon :: proc(ui: ^Ui, icon: Row_Icon, at: mu.Vec2, size: i32) {
	ctx := &ui.ctx
	x, y, s := at.x, at.y, size
	t := max(s / 10, 1) // line width
	switch icon {
	case .None:
	case .Folder, .Folder_Open:
		c := ui.colors.folder
		tab_w := s * 2 / 5
		body_y := y + s / 5
		mu.draw_rect(ctx, {x, y + s / 10, tab_w, s / 5}, c) // the tab
		mu.draw_rect(ctx, {x, body_y, s, s - s / 5 - s / 10}, c)
		if icon == .Folder_Open {
			// A darker band where the open folder's front leans out.
			mu.draw_rect(ctx, {x, body_y, s, t}, ctx.style.colors[.WINDOW_BG])
		}
	case .File:
		c := ui.colors.file
		w := s * 3 / 4
		fx := x + (s - w) / 2
		mu.draw_rect(ctx, {fx, y, w, t}, c)
		mu.draw_rect(ctx, {fx, y + s - t, w, t}, c)
		mu.draw_rect(ctx, {fx, y, t, s}, c)
		mu.draw_rect(ctx, {fx + w - t, y, t, s}, c)
		// Lines of text.
		for i in i32(1) ..= 3 {
			ly := y + s * i / 4
			mu.draw_rect(ctx, {fx + 2 * t, ly, w - 4 * t, t}, c)
		}
	}
}
