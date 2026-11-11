package ngam

// The editor's screen as nvim's UI events describe it (`:help ui-linegrid`
// and `:help ui-multigrid`). With ext_multigrid each nvim window has a grid
// of its own, which nvim places on grid 1, the global grid: splits with
// win_pos, floats with win_float_pos. With it off, everything is on grid 1.
//
// The events of the other UI extensions (command line, popup menu,
// messages, tab line) are handled in ext.odin.

import "core:slice"
import "core:time"
import "core:unicode/utf8"
import mp "msgpack"

Cell :: struct {
	// The cell's first codepoint. 0 is the right half of a double-width
	// character, which draws nothing. Combining characters after the
	// first codepoint are dropped.
	r:  rune,
	hl: i32,
}

// Highlight attributes from hl_attr_define. Colors are 0xRRGGBB, or -1 to
// use the default color.
Hl :: struct {
	fg, bg, sp:    i32,
	reverse:       bool,
	bold:          bool,
	italic:        bool,
	underline:     bool,
	undercurl:     bool,
	strikethrough: bool,
}

HL_DEFAULT :: Hl{fg = -1, bg = -1, sp = -1}

Cursor_Shape :: enum {
	Block,
	Horizontal,
	Vertical,
}

Mode_Info :: struct {
	shape:   Cursor_Shape,
	percent: int, // the cell's width or height the cursor covers, 1..100
	attr:    i32, // the cursor's highlight, 0 for the cell's colors reversed
}

// Where a grid is shown on grid 1.
Place :: enum {
	None, // unplaced, or closed
	Split, // a window in the layout (win_pos)
	Float, // a floating window (win_float_pos, win_external_pos)
	Msg, // the message area, when ext_messages is off (msg_set_pos)
}

SCROLL_ANIM :: 120 * time.Millisecond // how long a smooth scroll takes

// Win is one grid: a window's, or grid 1.
Win :: struct {
	id:           int,
	rows, cols:   int,
	cells:        []Cell,
	place:        Place,
	hidden:       bool,
	row, col:     f32, // the top left on grid 1, in cells
	zindex:       int,
	compindex:    int,
	mouse:        bool, // takes mouse clicks (a float can turn this off)
	// A float placed by its anchor, for nvim versions that lack screen_row
	// and screen_col: anchor is "NW", "NE", "SW" or "SE".
	anchor:       string,
	anchor_grid:  int,
	anchor_row:   f32,
	anchor_col:   f32,
	by_anchor:    bool,
	// win_viewport_margins: rows at the top (a winbar) and bottom that stay
	// in place while the text scrolls.
	margin_top:   int,
	margin_bot:   int,
	// Smooth scrolling. prev is the grid as it was last drawn; when the
	// window scrolls, old keeps that picture while the new text slides in
	// over scroll_from rows.
	prev:         []Cell,
	old:          []Cell,
	scroll_from:  f32,
	scroll_start: time.Tick,
}

Grid :: struct {
	wins:        map[int]^Win, // by grid id; grid 1 is the global grid
	cursor_grid: int,
	cursor_row:  int,
	cursor_col:  int,
	hls:         [dynamic]Hl, // indexed by highlight id; 0 is the default
	default_fg:  i32,
	default_bg:  i32,
	default_sp:  i32,
	modes:       [dynamic]Mode_Info,
	mode:        int,
	mode_name:   string, // "normal", "insert", "cmdline_normal", ...; borrowed
	visual:      bool, // in visual mode, where Cmd-C copies
	busy:        bool, // nvim hides the cursor while busy
	dirty:       bool, // a flush arrived: draw a new frame
	smooth:      bool, // animate scrolling (the smooth_scroll setting)
	colors_gen:  int, // goes up by one when the default colors change
}

grid_init :: proc(g: ^Grid) {
	g.default_fg = 0xffffff
	g.default_bg = 0x000000
	g.default_sp = 0xff0000
	g.cursor_grid = 1
	append(&g.hls, HL_DEFAULT)
}

grid_hl :: proc(g: ^Grid, id: i32) -> Hl {
	if id > 0 && int(id) < len(g.hls) {
		return g.hls[id]
	}
	return HL_DEFAULT
}

win_cell :: proc(w: ^Win, row, col: int) -> ^Cell {
	return &w.cells[row * w.cols + col]
}

// grid_win returns grid id, made empty if it is new.
grid_win :: proc(g: ^Grid, id: int) -> ^Win {
	w := g.wins[id]
	if w == nil {
		w = new(Win)
		w.id = id
		w.mouse = true
		g.wins[id] = w
	}
	return w
}

grid_mode :: proc(g: ^Grid) -> Mode_Info {
	if g.mode >= 0 && g.mode < len(g.modes) {
		return g.modes[g.mode]
	}
	return {shape = .Block, percent = 100}
}

// handle_redraw applies one "redraw" notification: a list of events, each
// an array of the event's name followed by one or more argument tuples.
// Events from older or newer nvim versions may have fewer or more
// arguments; missing ones read as nil (0, "" or false). Unknown events are
// ignored.
handle_redraw :: proc(app: ^App, params: []mp.Value) {
	g := &app.grid
	for ev_value in params {
		ev := mp.as_array(ev_value)
		if len(ev) == 0 {
			continue
		}
		name := mp.as_str(ev[0])
		for args_value in ev[1:] {
			args := mp.as_array(args_value)
			id := int(mp.as_int(mp.at(args, 0)))
			switch name {
			case "grid_resize":
				win_resize(grid_win(g, id), int(mp.as_int(mp.at(args, 2))), int(mp.as_int(mp.at(args, 1))))
			case "grid_line":
				win_line(grid_win(g, id), int(mp.as_int(mp.at(args, 1))), int(mp.as_int(mp.at(args, 2))), mp.as_array(mp.at(args, 3)))
			case "grid_clear":
				if w := g.wins[id]; w != nil {
					for &c in w.cells {
						c = {' ', 0}
					}
				}
			case "grid_destroy":
				win_free(g, id)
			case "grid_cursor_goto":
				g.cursor_grid = id
				g.cursor_row = int(mp.as_int(mp.at(args, 1)))
				g.cursor_col = int(mp.as_int(mp.at(args, 2)))
			case "grid_scroll":
				if w := g.wins[id]; w != nil {
					win_scroll(w, int(mp.as_int(mp.at(args, 1))), int(mp.as_int(mp.at(args, 2))), int(mp.as_int(mp.at(args, 3))), int(mp.as_int(mp.at(args, 4))), int(mp.as_int(mp.at(args, 5))))
				}
			case "win_pos":
				// [grid, win, start_row, start_col, width, height]
				w := grid_win(g, id)
				w.place = .Split
				w.hidden = false
				w.row = f32(mp.as_int(mp.at(args, 2)))
				w.col = f32(mp.as_int(mp.at(args, 3)))
			case "win_float_pos":
				win_float_pos(g, args)
			case "win_external_pos":
				// ngam has only its own window: show an external window as
				// a float in the middle of the screen.
				w := grid_win(g, id)
				w.place = .Float
				w.hidden = false
				w.by_anchor = false
				w.zindex = 300
				if g1 := g.wins[1]; g1 != nil {
					w.row = f32(max((g1.rows - w.rows) / 2, 0))
					w.col = f32(max((g1.cols - w.cols) / 2, 0))
				}
			case "win_hide":
				if w := g.wins[id]; w != nil {
					w.hidden = true
				}
			case "win_close":
				if w := g.wins[id]; w != nil {
					w.place = .None
					w.hidden = true
				}
			case "msg_set_pos":
				// [grid, row, scrolled, sep_char, zindex, compindex]
				w := grid_win(g, id)
				w.place = .Msg
				w.hidden = false
				w.by_anchor = false
				w.row = f32(mp.as_int(mp.at(args, 1)))
				w.col = 0
				w.zindex = len(args) > 4 ? int(mp.as_int(mp.at(args, 4))) : 200
				w.compindex = int(mp.as_int(mp.at(args, 5)))
			case "win_viewport":
				win_viewport(g, args)
			case "win_viewport_margins":
				// [grid, win, top, bottom, left, right]
				w := grid_win(g, id)
				w.margin_top = int(mp.as_int(mp.at(args, 2)))
				w.margin_bot = int(mp.as_int(mp.at(args, 3)))
			case "hl_attr_define":
				hl_attr_define(g, i32(mp.as_int(mp.at(args, 0))), mp.as_map(mp.at(args, 1)))
			case "default_colors_set":
				// -1 means unset. nvim sends real colors in rgb mode, but
				// keep the old value for -1 to be safe.
				if fg := i32(mp.as_int(mp.at(args, 0))); fg >= 0 {g.default_fg = fg}
				if bg := i32(mp.as_int(mp.at(args, 1))); bg >= 0 {g.default_bg = bg}
				if sp := i32(mp.as_int(mp.at(args, 2))); sp >= 0 {g.default_sp = sp}
				g.colors_gen += 1
			case "mode_info_set":
				mode_info_set(g, mp.as_array(mp.at(args, 1)))
			case "mode_change":
				switch mp.as_str(mp.at(args, 0)) {
				// Keep a constant string: the event's lives only for this frame.
				case "insert":
					g.mode_name = "insert"
				case "cmdline_normal", "cmdline_insert", "cmdline_replace":
					g.mode_name = "cmdline"
				case:
					g.mode_name = "other"
				}
				g.visual = mp.as_str(mp.at(args, 0)) == "visual"
				g.mode = int(mp.as_int(mp.at(args, 1)))
			case "busy_start":
				g.busy = true
			case "busy_stop":
				g.busy = false
			case "flush":
				g.dirty = true
				ext_flush(app)
				if g.smooth {
					for _, w in g.wins {
						win_keep_prev(w)
					}
				}
			case:
				ext_event(app, name, args)
			}
		}
	}
}

// win_float_pos places a float: [grid, win, anchor, anchor_grid,
// anchor_row, anchor_col, mouse_enabled, zindex, compindex, screen_row,
// screen_col]. nvim 0.10 and later give the position on the screen; older
// versions give only the anchor.
@(private = "file")
win_float_pos :: proc(g: ^Grid, args: []mp.Value) {
	w := grid_win(g, int(mp.as_int(mp.at(args, 0))))
	w.place = .Float
	w.hidden = false
	w.anchor = anchor_name(mp.as_str(mp.at(args, 2)))
	w.anchor_grid = int(mp.as_int(mp.at(args, 3)))
	w.anchor_row = as_f32(mp.at(args, 4))
	w.anchor_col = as_f32(mp.at(args, 5))
	w.mouse = len(args) <= 6 || mp.as_bool(mp.at(args, 6))
	w.zindex = int(mp.as_int(mp.at(args, 7)))
	w.compindex = int(mp.as_int(mp.at(args, 8)))
	if len(args) > 10 {
		w.by_anchor = false
		w.row = as_f32(mp.at(args, 9))
		w.col = as_f32(mp.at(args, 10))
	} else {
		w.by_anchor = true
	}
}

// anchor_name keeps a constant copy of an anchor: the event's string lives
// only for this frame.
@(private = "file")
anchor_name :: proc(s: string) -> string {
	switch s {
	case "NE":
		return "NE"
	case "SW":
		return "SW"
	case "SE":
		return "SE"
	}
	return "NW"
}

as_f32 :: proc(v: mp.Value) -> f32 {
	#partial switch x in v {
	case f64:
		return f32(x)
	case i64:
		return f32(x)
	}
	return 0
}

// win_viewport starts a smooth scroll when a window's text moved:
// [grid, win, topline, botline, curline, curcol, line_count, scroll_delta].
@(private = "file")
win_viewport :: proc(g: ^Grid, args: []mp.Value) {
	w := g.wins[int(mp.as_int(mp.at(args, 0)))]
	if w == nil || !g.smooth || len(args) < 8 {
		return
	}
	delta := int(mp.as_int(mp.at(args, 7)))
	text_rows := w.rows - w.margin_top - w.margin_bot
	// A jump of a screenful or more is shown at once.
	if delta == 0 || abs(delta) >= text_rows || len(w.prev) != len(w.cells) {
		return
	}
	delete(w.old)
	w.old = slice.clone(w.prev)
	w.scroll_from = f32(delta)
	w.scroll_start = time.tick_now()
}

// win_keep_prev remembers the grid as it is at a flush, the picture a
// smooth scroll starts from.
@(private = "file")
win_keep_prev :: proc(w: ^Win) {
	if len(w.prev) != len(w.cells) {
		delete(w.prev)
		w.prev = make([]Cell, len(w.cells))
	}
	copy(w.prev, w.cells)
}

// win_scroll_offset is how many rows the text is still drawn away from its
// place, easing to 0. It is 0 when the window is still.
win_scroll_offset :: proc(w: ^Win) -> f32 {
	if w.old == nil {
		return 0
	}
	t := f32(time.tick_since(w.scroll_start)) / f32(SCROLL_ANIM)
	if t >= 1 || len(w.old) != len(w.cells) {
		delete(w.old)
		w.old = nil
		return 0
	}
	ease := (1 - t) * (1 - t) * (1 - t)
	return w.scroll_from * ease
}

// grid_animating says whether a smooth scroll is going on.
grid_animating :: proc(g: ^Grid) -> bool {
	for _, w in g.wins {
		if w.old != nil {
			return true
		}
	}
	return false
}

// win_resize keeps what fits of the old contents; nvim redraws the rest.
win_resize :: proc(w: ^Win, rows, cols: int) {
	if rows == w.rows && cols == w.cols {
		return
	}
	cells := make([]Cell, rows * cols)
	for &c in cells {
		c = {' ', 0}
	}
	for r in 0 ..< min(rows, w.rows) {
		for c in 0 ..< min(cols, w.cols) {
			cells[r * cols + c] = w.cells[r * w.cols + c]
		}
	}
	delete(w.cells)
	w.cells, w.rows, w.cols = cells, rows, cols
	delete(w.old)
	w.old = nil
}

@(private = "file")
win_free :: proc(g: ^Grid, id: int) {
	w := g.wins[id]
	if w == nil {
		return
	}
	delete_key(&g.wins, id)
	delete(w.cells)
	delete(w.prev)
	delete(w.old)
	free(w)
}

// win_line sets cells from col onwards. Each cell is [text, hl_id?,
// repeat?]; a missing hl_id means the previous cell's.
win_line :: proc(w: ^Win, row, col: int, cells: []mp.Value) {
	if row < 0 || row >= w.rows {
		return
	}
	c := col
	hl: i32 = 0
	for cell_value in cells {
		cell := mp.as_array(cell_value)
		text := mp.as_str(mp.at(cell, 0))
		if len(cell) > 1 {
			hl = i32(mp.as_int(cell[1]))
		}
		repeat := 1
		if len(cell) > 2 {
			repeat = int(mp.as_int(cell[2]))
		}
		r: rune = 0
		if len(text) > 0 {
			r, _ = utf8.decode_rune_in_string(text)
		}
		for _ in 0 ..< repeat {
			if c >= 0 && c < w.cols {
				win_cell(w, row, c)^ = {r, hl}
			}
			c += 1
		}
	}
}

// win_scroll moves the region top..bot, left..right (ends exclusive) up by
// rows, or down when rows is negative. nvim fills the rows it leaves.
win_scroll :: proc(w: ^Win, top_, bot_, left_, right_, rows: int) {
	top, bot := max(top_, 0), min(bot_, w.rows)
	left, right := max(left_, 0), min(right_, w.cols)
	if left >= right {
		return
	}
	if rows > 0 {
		for r in top ..< bot - rows {
			copy(w.cells[r * w.cols + left:r * w.cols + right], w.cells[(r + rows) * w.cols + left:(r + rows) * w.cols + right])
		}
	} else if rows < 0 {
		for r := bot - 1; r >= top - rows; r -= 1 {
			copy(w.cells[r * w.cols + left:r * w.cols + right], w.cells[(r + rows) * w.cols + left:(r + rows) * w.cols + right])
		}
	}
}

// win_screen_pos is where a grid's top left is on grid 1, in cells, and
// whether it is shown at all.
win_screen_pos :: proc(g: ^Grid, w: ^Win) -> (row, col: f32, shown: bool) {
	if w.id == 1 {
		return 0, 0, true
	}
	if w.hidden || w.place == .None {
		return 0, 0, false
	}
	if w.place != .Float || !w.by_anchor {
		return w.row, w.col, true
	}
	// Placed by its anchor on another grid (nvim before 0.10).
	base := g.wins[w.anchor_grid]
	br, bc: f32
	if base != nil && base.id != w.id {
		br, bc, _ = win_screen_pos(g, base)
	}
	row, col = br + w.anchor_row, bc + w.anchor_col
	if w.anchor == "SW" || w.anchor == "SE" {
		row -= f32(w.rows)
	}
	if w.anchor == "NE" || w.anchor == "SE" {
		col -= f32(w.cols)
	}
	// Keep it on the screen.
	if g1 := g.wins[1]; g1 != nil {
		row = clamp(row, 0, max(f32(g1.rows - w.rows), 0))
		col = clamp(col, 0, max(f32(g1.cols - w.cols), 0))
	}
	return row, col, true
}

// grid_draw_order lists the shown grids bottom to top: grid 1, the
// splits, then floats and the message area by zindex and compindex.
grid_draw_order :: proc(g: ^Grid) -> []^Win {
	out := make([dynamic]^Win, context.temp_allocator)
	if g1 := g.wins[1]; g1 != nil {
		append(&out, g1)
	}
	for _, w in g.wins {
		if w.id != 1 && w.place == .Split && !w.hidden {
			append(&out, w)
		}
	}
	first_float := len(out)
	for _, w in g.wins {
		if w.id != 1 && (w.place == .Float || w.place == .Msg) && !w.hidden {
			append(&out, w)
		}
	}
	slice.sort_by(out[first_float:], proc(a, b: ^Win) -> bool {
		if a.zindex != b.zindex {
			return a.zindex < b.zindex
		}
		if a.compindex != b.compindex {
			return a.compindex < b.compindex
		}
		return a.id < b.id
	})
	return out[:]
}

hl_attr_define :: proc(g: ^Grid, id: i32, attrs: []mp.Map_Entry) {
	if id <= 0 {
		return
	}
	hl := HL_DEFAULT
	for e in attrs {
		switch mp.as_str(e.key) {
		case "foreground":
			hl.fg = i32(mp.as_int(e.value))
		case "background":
			hl.bg = i32(mp.as_int(e.value))
		case "special":
			hl.sp = i32(mp.as_int(e.value))
		case "reverse":
			hl.reverse = mp.as_bool(e.value)
		case "bold":
			hl.bold = mp.as_bool(e.value)
		case "italic":
			hl.italic = mp.as_bool(e.value)
		case "underline", "underdouble", "underdotted", "underdashed":
			hl.underline = hl.underline || mp.as_bool(e.value)
		case "undercurl":
			hl.undercurl = mp.as_bool(e.value)
		case "strikethrough":
			hl.strikethrough = mp.as_bool(e.value)
		}
	}
	for len(g.hls) <= int(id) {
		append(&g.hls, HL_DEFAULT)
	}
	g.hls[id] = hl
}

mode_info_set :: proc(g: ^Grid, infos: []mp.Value) {
	clear(&g.modes)
	for info_value in infos {
		m := Mode_Info{shape = .Block, percent = 100}
		for e in mp.as_map(info_value) {
			switch mp.as_str(e.key) {
			case "cursor_shape":
				switch mp.as_str(e.value) {
				case "horizontal":
					m.shape = .Horizontal
				case "vertical":
					m.shape = .Vertical
				case:
					m.shape = .Block
				}
			case "cell_percentage":
				m.percent = int(mp.as_int(e.value))
			case "attr_id":
				m.attr = i32(mp.as_int(e.value))
			}
		}
		if m.percent <= 0 || m.percent > 100 {
			m.percent = 100
		}
		append(&g.modes, m)
	}
}

// grid_clear_all forgets every grid and highlight, for when a session ends
// or another one starts, or the UI extensions change.
grid_clear_all :: proc(g: ^Grid) {
	ids := make([dynamic]int, context.temp_allocator)
	for id in g.wins {
		append(&ids, id)
	}
	for id in ids {
		win_free(g, id)
	}
	clear(&g.hls)
	append(&g.hls, HL_DEFAULT)
	g.cursor_grid = 1
	g.dirty = true
}
