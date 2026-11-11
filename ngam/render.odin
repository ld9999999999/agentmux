package ngam

// Drawing. Everything on screen is textured quads: cell backgrounds,
// lines and UI boxes sample the white corner of a font atlas, glyphs sample
// their place in it, and the vertex color tints both. Quads are batched
// and drawn with SDL_RenderGeometry, one call per run of quads that share
// a texture and clip rectangle. SDL's renderer runs it on the GPU (Metal on
// macOS).

import sdl "vendor:sdl3"

Renderer :: struct {
	r:        ^sdl.Renderer,
	vertices: [dynamic]sdl.Vertex,
	indices:  [dynamic]i32,
	tex:      ^sdl.Texture, // the texture of the batched quads
}

// RGB is a 0xRRGGBB color.
rgb_color :: proc(rgb: i32, alpha: f32 = 1) -> sdl.FColor {
	return {f32((rgb >> 16) & 0xff) / 255, f32((rgb >> 8) & 0xff) / 255, f32(rgb & 0xff) / 255, alpha}
}

// flush draws the batched quads.
flush :: proc(rd: ^Renderer) {
	if len(rd.indices) > 0 {
		_ = sdl.RenderGeometry(rd.r, rd.tex, raw_data(rd.vertices), i32(len(rd.vertices)), raw_data(rd.indices), i32(len(rd.indices)))
	}
	clear(&rd.vertices)
	clear(&rd.indices)
}

// set_clip draws what is batched, then limits drawing to r (in pixels),
// or to the whole window when r is nil.
set_clip :: proc(rd: ^Renderer, r: Maybe(sdl.Rect)) {
	flush(rd)
	if rect, ok := r.?; ok {
		_ = sdl.SetRenderClipRect(rd.r, &rect)
	} else {
		_ = sdl.SetRenderClipRect(rd.r, nil)
	}
}

// quad adds a w x h rectangle at x, y showing the atlas region u, v, uw, vh
// (in atlas pixels) of font f.
quad :: proc(rd: ^Renderer, f: ^Font, x, y, w, h: f32, c: sdl.FColor, u, v, uw, vh: f32) {
	if f.atlas != rd.tex {
		flush(rd)
		rd.tex = f.atlas
	}
	base := i32(len(rd.vertices))
	s := f32(f.atlas_size)
	u0, v0, u1, v1 := u / s, v / s, (u + uw) / s, (v + vh) / s
	append(
		&rd.vertices,
		sdl.Vertex{{x, y}, c, {u0, v0}},
		sdl.Vertex{{x + w, y}, c, {u1, v0}},
		sdl.Vertex{{x + w, y + h}, c, {u1, v1}},
		sdl.Vertex{{x, y + h}, c, {u0, v1}},
	)
	append(&rd.indices, base, base + 1, base + 2, base, base + 2, base + 3)
}

// fill adds a solid rectangle, sampling the middle of the atlas's white
// corner.
fill :: proc(rd: ^Renderer, f: ^Font, x, y, w, h: i32, c: sdl.FColor) {
	quad(rd, f, f32(x), f32(y), f32(w), f32(h), c, 1, 1, 2, 2)
}

rect :: proc(rd: ^Renderer, f: ^Font, x, y, w, h: i32, rgb: i32) {
	fill(rd, f, x, y, w, h, rgb_color(rgb))
}

// glyph draws r with its cell's top left at x, y.
glyph :: proc(rd: ^Renderer, f: ^Font, x, y: i32, r: rune, style: Style, c: sdl.FColor) {
	g := glyph_get(f, r, style)
	if g.w == 0 {
		return
	}
	quad(rd, f, f32(x + g.dx), f32(y + g.dy), f32(g.w), f32(g.h), c, f32(g.x), f32(g.y), f32(g.w), f32(g.h))
}

// text draws s with its top left at x, y, placing glyphs by their
// advances (for the proportional UI font). It returns the x after it.
text :: proc(rd: ^Renderer, f: ^Font, x, y: i32, s: string, c: sdl.FColor) -> i32 {
	pen := f32(x)
	for r in s {
		g := glyph_get(f, r, .Regular)
		if g.w > 0 {
			quad(rd, f, f32(i32(pen) + g.dx), f32(y + g.dy), f32(g.w), f32(g.h), c, f32(g.x), f32(g.y), f32(g.w), f32(g.h))
		}
		pen += g.adv
	}
	return i32(pen)
}

// text_width is how wide s is in f, in pixels.
text_width :: proc(f: ^Font, s: string) -> i32 {
	w: f32
	for r in s {
		w += glyph_get(f, r, .Regular).adv
	}
	return i32(w + 0.5)
}

// cell_colors returns a highlight's foreground, background and special
// colors with defaults filled in and reverse applied.
cell_colors :: proc(g: ^Grid, hl: Hl) -> (fg, bg, sp: i32) {
	fg = hl.fg >= 0 ? hl.fg : g.default_fg
	bg = hl.bg >= 0 ? hl.bg : g.default_bg
	if hl.reverse {
		fg, bg = bg, fg
	}
	sp = hl.sp >= 0 ? hl.sp : (g.default_sp >= 0 ? g.default_sp : fg)
	return
}

cell_style :: proc(hl: Hl) -> Style {
	switch {
	case hl.bold && hl.italic:
		return .Bold_Italic
	case hl.bold:
		return .Bold
	case hl.italic:
		return .Italic
	}
	return .Regular
}

// draw_screen draws grid 1 with its top left at ox, oy, then the grids
// placed on it (splits, then floats from the bottom up), then the cursor.
// Nothing is drawn outside clip, the editor's part of the window.
draw_screen :: proc(rd: ^Renderer, f: ^Font, g: ^Grid, focused: bool, ox, oy: i32, clip: sdl.Rect) {
	for w in grid_draw_order(g) {
		x, y, shown := win_origin(f, g, w, ox, oy)
		if shown {
			draw_win(rd, f, g, w, x, y, clip)
		}
	}
	if w := g.wins[g.cursor_grid]; w != nil {
		if x, y, shown := win_origin(f, g, w, ox, oy); shown {
			set_clip(rd, clip)
			// While the window scrolls smoothly, the cursor moves with
			// the text, and is hidden where the text rows end.
			top, bot := w.margin_top, w.rows - w.margin_bot
			if off := win_scroll_offset(w); off != 0 && g.cursor_row >= top && g.cursor_row < bot {
				text := sdl.Rect{x, y + i32(top) * f.cell_h, i32(w.cols) * f.cell_w, i32(bot - top) * f.cell_h}
				set_clip(rd, intersect(text, clip))
				y += i32(off * f32(f.cell_h))
			}
			draw_cursor(rd, f, g, w, focused, x, y)
		}
	}
	set_clip(rd, nil)
}

// win_origin is where a grid's top left is drawn, in window pixels.
win_origin :: proc(f: ^Font, g: ^Grid, w: ^Win, ox, oy: i32) -> (x, y: i32, shown: bool) {
	row, col: f32
	row, col, shown = win_screen_pos(g, w)
	return ox + i32(col * f32(f.cell_w)), oy + i32(row * f32(f.cell_h)), shown
}

// intersect is the part of a that is also in b.
intersect :: proc(a, b: sdl.Rect) -> sdl.Rect {
	x0, y0 := max(a.x, b.x), max(a.y, b.y)
	x1, y1 := min(a.x + a.w, b.x + b.w), min(a.y + a.h, b.y + b.h)
	return {x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
}

// draw_win draws one grid with its top left at x, y. While the window
// scrolls smoothly, its text rows slide from the old picture to the new.
@(private = "file")
draw_win :: proc(rd: ^Renderer, f: ^Font, g: ^Grid, w: ^Win, x, y: i32, clip: sdl.Rect) {
	cw, ch := f.cell_w, f.cell_h
	whole := intersect({x, y, i32(w.cols) * cw, i32(w.rows) * ch}, clip)
	set_clip(rd, whole)
	off := win_scroll_offset(w)
	if off == 0 {
		draw_rows(rd, f, g, w.cells, w.cols, 0, w.rows, x, y, 0)
		return
	}
	// The winbar and other margins stay; the text rows between slide.
	top, bot := w.margin_top, w.rows - w.margin_bot
	draw_rows(rd, f, g, w.cells, w.cols, 0, top, x, y, 0)
	draw_rows(rd, f, g, w.cells, w.cols, bot, w.rows, x, y, 0)
	set_clip(rd, intersect({x, y + i32(top) * ch, i32(w.cols) * cw, i32(bot - top) * ch}, clip))
	// New row k shows what old row k + d showed. Old rows fill the rest
	// until the new ones reach them.
	d := w.scroll_from
	draw_rows(rd, f, g, w.old, w.cols, top, bot, x, y, off - d)
	draw_rows(rd, f, g, w.cells, w.cols, top, bot, x, y, off)
}

// draw_rows draws rows from..to of a grid's cells, each moved down by
// shift rows (a fraction while scrolling).
@(private = "file")
draw_rows :: proc(rd: ^Renderer, f: ^Font, g: ^Grid, cells: []Cell, cols, from, to: int, ox, oy: i32, shift: f32) {
	cw, ch := f.cell_w, f.cell_h
	for row in from ..< to {
		y := oy + i32((f32(row) + shift) * f32(ch))
		line := cells[row * cols:(row + 1) * cols]
		// The default background under the whole row; runs of other
		// colors are merged into one rectangle each.
		rect(rd, f, ox, y, i32(cols) * cw, ch, g.default_bg)
		run_start, run_bg := 0, g.default_bg
		for col in 0 ..= cols {
			bg := g.default_bg
			if col < cols {
				_, bg, _ = cell_colors(g, grid_hl(g, line[col].hl))
			}
			if col == cols || bg != run_bg {
				if run_bg != g.default_bg && col > run_start {
					rect(rd, f, ox + i32(run_start) * cw, y, i32(col - run_start) * cw, ch, run_bg)
				}
				run_start, run_bg = col, bg
			}
		}
		// Glyphs, then underlines and strikethrough over them.
		for c, col in line {
			hl := grid_hl(g, c.hl)
			x := ox + i32(col) * cw
			fg, _, sp := cell_colors(g, hl)
			if c.r != 0 && c.r != ' ' {
				if !block_element(rd, f, x, y, c.r, fg) {
					glyph(rd, f, x, y, c.r, cell_style(hl), rgb_color(fg))
				}
			}
			if hl.underline || hl.undercurl {
				// undercurl is drawn as a plain line.
				rect(rd, f, x, y + f.underline_y, cw, f.line_px, hl.undercurl ? sp : (hl.sp >= 0 ? sp : fg))
			}
			if hl.strikethrough {
				rect(rd, f, x, y + (f.baseline * 2) / 3, cw, f.line_px, fg)
			}
		}
	}
}

// block_element draws the block characters U+2580..U+2595 (eighths and
// halves of a cell) as exact rectangles, and says whether r was one.
// A font's own glyphs for them rarely fill the cell to the pixel, which
// shows as gaps in bars that span several lines, such as git change bars.
block_element :: proc(rd: ^Renderer, f: ^Font, x, y: i32, r: rune, rgb: i32) -> bool {
	cw, ch := f.cell_w, f.cell_h
	switch r {
	case 0x2580: // upper half
		rect(rd, f, x, y, cw, ch / 2, rgb)
	case 0x2581 ..= 0x2588: // lower 1/8 .. full
		h := max(ch * i32(r - 0x2580) / 8, 1)
		rect(rd, f, x, y + ch - h, cw, h, rgb)
	case 0x2589 ..= 0x258F: // left 7/8 .. 1/8
		w := max(cw * i32(0x2590 - r) / 8, 1)
		rect(rd, f, x, y, w, ch, rgb)
	case 0x2590: // right half
		rect(rd, f, x + cw / 2, y, cw - cw / 2, ch, rgb)
	case 0x2594: // upper 1/8
		rect(rd, f, x, y, cw, max(ch / 8, 1), rgb)
	case 0x2595: // right 1/8
		w := max(cw / 8, 1)
		rect(rd, f, x + cw - w, y, w, ch, rgb)
	case:
		return false
	}
	return true
}

@(private = "file")
draw_cursor :: proc(rd: ^Renderer, f: ^Font, g: ^Grid, w: ^Win, focused: bool, ox, oy: i32) {
	if g.busy || g.cursor_row >= w.rows || g.cursor_col >= w.cols || g.cursor_row < 0 || g.cursor_col < 0 {
		return
	}
	cw, ch := f.cell_w, f.cell_h
	row, col := g.cursor_row, g.cursor_col
	c := win_cell(w, row, col)
	cell_hl := grid_hl(g, c.hl)
	cell_fg, cell_bg, _ := cell_colors(g, cell_hl)
	m := grid_mode(g)

	// The cursor's colors: its highlight's, or the cell's reversed when
	// it has none (attr_id 0, or a group that sets no colors).
	cur_fg, cur_bg := cell_bg, cell_fg
	if m.attr != 0 {
		hl := grid_hl(g, m.attr)
		if hl.fg >= 0 || hl.bg >= 0 || hl.reverse {
			cur_fg, cur_bg, _ = cell_colors(g, hl)
		}
	}

	x, y := ox + i32(col) * cw, oy + i32(row) * ch
	wd := cw
	if col + 1 < w.cols && win_cell(w, row, col + 1).r == 0 {
		wd *= 2 // a double-width character
	}
	if !focused {
		// An outline of the cell, whatever the shape.
		t := f.line_px
		rect(rd, f, x, y, wd, t, cur_bg)
		rect(rd, f, x, y + ch - t, wd, t, cur_bg)
		rect(rd, f, x, y, t, ch, cur_bg)
		rect(rd, f, x + wd - t, y, t, ch, cur_bg)
		return
	}
	switch m.shape {
	case .Block:
		rect(rd, f, x, y, wd, ch, cur_bg)
		if c.r != 0 && c.r != ' ' {
			glyph(rd, f, x, y, c.r, cell_style(cell_hl), rgb_color(cur_fg))
		}
	case .Vertical:
		rect(rd, f, x, y, max(f.line_px, cw * i32(m.percent) / 100), ch, cur_bg)
	case .Horizontal:
		h := max(f.line_px, ch * i32(m.percent) / 100)
		rect(rd, f, x, y + ch - h, wd, h, cur_bg)
	}
}
