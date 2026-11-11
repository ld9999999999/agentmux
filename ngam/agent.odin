package ngam

// The agent pane: a terminal for the session's agent, at the right of the
// editor. serve sends the agent's output in A frames. libghostty-vt (see
// ghostty/ghostty.odin) turns it into a screen with scrollback, and ngam
// draws that screen with the editor's font and cell renderer. ngam sends
// keys and pasted text back to the agent in A frames, and the pane's size
// in R frames.

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import mu "vendor:microui"
import sdl "vendor:sdl3"
import "ghostty"

AGENT_MIN_COLS :: 60
AGENT_SHARE :: 0.4 // the share of the window's width, until the user drags the divider
DIVIDER_PT :: 1
AGENT_PAD_PT :: 4 // space around the agent's cells
AGENT_HEADER_PT :: 22 // the strip at the pane's top
SCROLL_LINES :: 3 // lines per wheel notch

// Which pane gets the keyboard.
Focus :: enum {
	Editor,
	Agent,
}

Agent_State :: enum {
	Waiting, // waiting for serve to attach the agent
	Attached,
	Closed, // see exit and reason
}

Agent :: struct {
	term:         ghostty.Terminal,
	rs:           ghostty.Render_State,
	rows_it:      ghostty.Row_Iterator,
	cells:        ghostty.Row_Cells,
	enc:          ghostty.Key_Encoder,
	key:          ghostty.Key_Event,
	menc:         ghostty.Mouse_Encoder,
	mev:          ghostty.Mouse_Event,

	open:         bool, // the pane is shown
	btn_hover:    bool, // the mouse is over the show/hide button
	width:        f32, // points; 0 means AGENT_SHARE of the window
	cols, rows:   int, // the terminal's size
	cell:         [2]i32, // the cell size the terminal was last given
	sent:         [2]int, // the size last sent on R (cols, rows); zero before the first send

	state:        Agent_State,
	exit:         string, // how the agent exited, when it did
	reason:       string, // why the pane closed

	// The first A frame after "attached" is serve's replay of recent
	// output. Its queries were answered long ago, so ngam drops the
	// terminal's replies to them and any clipboard writes in it.
	replay_next:  bool,
	replaying:    bool,

	dragging:     bool, // the divider is being dragged
	over_divider: bool,
	selecting:    bool, // the left button is held in the pane
	sel_from:     ghostty.Point_Coord, // where the selection started, in screen rows
	sel_cell:     [2]int, // the cell the selection last reached
	reporting:    u8, // the held SDL button whose events go to the agent
	scroll_acc:   f32, // wheel movement left over from the last scroll (trackpads send fractions)
	colors:       [2]i32, // the default fg and bg the terminal was given
}

// Per-cell data for one row, gathered before drawing it.
@(private = "file")
Cell_Draw :: struct {
	r:         rune, // 0 for an empty cell
	fg, bg:    ghostty.Rgb,
	has_bg:    bool, // bg differs from the default
	style:     Style,
	underline: int,
	ul_color:  ghostty.Rgb,
	strike:    bool,
	overline:  bool,
	wide:      bool, // the first half of a double-width character
}

agent_init :: proc(app: ^App) {
	a := &app.agent
	a.open = app.settings.agent_open
	a.width = f32(app.settings.agent_width)
	a.cols, a.rows = 80, 24
	ok := ghostty.terminal_new(nil, &a.term, 80, 24) == .Success
	ok = ok && ghostty.render_state_new(nil, &a.rs) == .Success
	ok = ok && ghostty.render_state_row_iterator_new(nil, &a.rows_it) == .Success
	ok = ok && ghostty.render_state_row_cells_new(nil, &a.cells) == .Success
	ok = ok && ghostty.key_encoder_new(nil, &a.enc) == .Success
	ok = ok && ghostty.key_event_new(nil, &a.key) == .Success
	ok = ok && ghostty.mouse_encoder_new(nil, &a.menc) == .Success
	ok = ok && ghostty.mouse_event_new(nil, &a.mev) == .Success
	if !ok {
		fmt.eprintln("ngam: cannot start libghostty-vt's terminal")
		os.exit(1)
	}
	ghostty.terminal_set(a.term, .Userdata, app)
	ghostty.terminal_set(a.term, .Write_Pty, rawptr(on_write_pty))
	ghostty.terminal_set(a.term, .Clipboard_Write, rawptr(on_clipboard_write))
	a.colors = {-1, -1}
}

// on_write_pty sends the terminal's replies (to cursor position and
// device queries, say) to the agent, as if typed.
@(private = "file")
on_write_pty :: proc "c" (t: ghostty.Terminal, userdata: rawptr, data: [^]u8, n: c.size_t) {
	app := (^App)(userdata)
	context = app.ctx
	if app.agent.replaying || app.link == nil || n == 0 {
		return
	}
	link_send(app.link, FRAME_AGENT, data[:n])
}

// on_clipboard_write puts an agent's OSC 52 copy on the host clipboard.
@(private = "file")
on_clipboard_write :: proc "c" (t: ghostty.Terminal, userdata: rawptr, w: ^ghostty.Clipboard_Write) {
	app := (^App)(userdata)
	context = app.ctx
	reply := ghostty.Clipboard_Write_Reply {
		size   = size_of(ghostty.Clipboard_Write_Reply),
		result = 0, // success
	}
	if app.agent.replaying {
		reply.result = 1 // denied: an old copy from the replay
	} else {
		text := ""
		for i in 0 ..< int(w.contents_len) {
			cont := w.contents[i]
			mime := string(cont.mime.ptr[:cont.mime.len])
			if mime == "" || strings.has_prefix(mime, "text/plain") {
				text = string(cont.data.ptr[:cont.data.len])
				break
			}
		}
		// Empty contents clear the clipboard.
		clipboard_set(text)
	}
	if w.reply != nil {
		w.reply(w, &reply)
	}
}

// agent_visible reports whether the pane is on screen.
agent_visible :: proc(app: ^App) -> bool {
	return app.link != nil && app.agent.open
}

agent_has_focus :: proc(app: ^App) -> bool {
	return agent_visible(app) && app.focus == .Agent
}

// agent_want_px is the pane's width in pixels, divider included, even
// while the pane is hidden.
agent_want_px :: proc(app: ^App) -> i32 {
	w, _ := window_pixels(app)
	d := app.density
	least := i32(AGENT_MIN_COLS) * app.font.cell_w + i32((2 * AGENT_PAD_PT + DIVIDER_PT) * d)
	want := app.agent.width > 0 ? i32(app.agent.width * d) : i32(f32(w) * AGENT_SHARE)
	want = max(want, least)
	// Leave the editor room, even if the pane gets fewer columns.
	most := w - bar_width(app) - panel_target_width(app) - i32(MIN_EDITOR_PT * d)
	return max(min(want, most), i32(100 * d))
}

// agent_pane_px is the pane's width on screen: 0 when it is hidden.
agent_pane_px :: proc(app: ^App) -> i32 {
	if !agent_visible(app) {
		return 0
	}
	return agent_want_px(app)
}

// agent_left is the x of the divider, the pane's left edge.
agent_left :: proc(app: ^App) -> i32 {
	w, _ := window_pixels(app)
	return w - agent_pane_px(app)
}

// agent_origin is where the agent's first cell is drawn.
@(private = "file")
agent_origin :: proc(app: ^App) -> (x, y: i32) {
	pad := i32(AGENT_PAD_PT * app.density)
	return agent_left(app) + i32(DIVIDER_PT * app.density) + pad, agent_header_h(app) + pad
}

// agent_header_h is the height of the strip at the top of the pane that
// names the agent and holds the hide button.
agent_header_h :: proc(app: ^App) -> i32 {
	return i32(AGENT_HEADER_PT * app.density)
}

// agent_grid_size returns how many cells fit in the pane.
@(private = "file")
agent_grid_size :: proc(app: ^App) -> (cols, rows: int) {
	_, h := window_pixels(app)
	d := app.density
	inner := agent_want_px(app) - i32((2 * AGENT_PAD_PT + DIVIDER_PT) * d)
	cols = max(1, int(inner / max(app.font.cell_w, 1)))
	rows = max(1, int((h - agent_header_h(app) - i32(2 * AGENT_PAD_PT * d)) / max(app.font.cell_h, 1)))
	return
}

// agent_sync_size fits the terminal to the pane and tells serve the size.
// The size stays the same while the pane is hidden, so the agent skips a
// redraw.
agent_sync_size :: proc(app: ^App) {
	a := &app.agent
	cols, rows := agent_grid_size(app)
	cell := [2]i32{app.font.cell_w, app.font.cell_h}
	if cols != a.cols || rows != a.rows || cell != a.cell {
		ghostty.terminal_resize(a.term, u16(cols), u16(rows), u32(cell.x), u32(cell.y))
		a.cols, a.rows, a.cell = cols, rows, cell
		app.need_draw = true
	}
	if app.link != nil && a.sent != {cols, rows} {
		// R: rows u16, cols u16, big-endian.
		p := [4]byte{byte(rows >> 8), byte(rows), byte(cols >> 8), byte(cols)}
		link_send(app.link, FRAME_RESIZE, p[:])
		a.sent = {cols, rows}
	}
}

// agent_session_closed forgets the agent of a session that ended.
agent_session_closed :: proc(app: ^App) {
	a := &app.agent
	ghostty.terminal_reset(a.term)
	a.colors = {-1, -1}
	a.sent = {}
	a.state = .Waiting
	set_string(&a.exit, "")
	set_string(&a.reason, "")
	a.selecting = false
	a.dragging = false
	app.focus = .Editor
}

// agent_control handles serve's {"type":"agent"} messages.
agent_control :: proc(app: ^App, state, reason, exit: string) {
	a := &app.agent
	switch state {
	case "attached":
		// serve replays the agent's recent output next, onto a clean
		// screen.
		ghostty.terminal_reset(a.term)
		a.colors = {-1, -1}
		a.state = .Attached
		a.replay_next = true
		set_string(&a.exit, "")
		set_string(&a.reason, "")
		agent_sync_size(app)
	case "closed":
		a.state = .Closed
		set_string(&a.exit, exit)
		set_string(&a.reason, reason)
	}
	app.need_draw = true
}

// agent_feed parses the agent's output.
agent_feed :: proc(app: ^App, data: []byte) {
	a := &app.agent
	a.replaying = a.replay_next
	a.replay_next = false
	if len(data) > 0 {
		ghostty.terminal_vt_write(a.term, raw_data(data), c.size_t(len(data)))
	}
	a.replaying = false
	app.need_draw = true
}

// agent_restart asks serve to attach the agent again, starting it if it
// exited.
agent_restart :: proc(app: ^App) {
	if app.link == nil {
		return
	}
	link_send(app.link, FRAME_CONTROL, transmute([]byte)string(`{"type":"agent_attach"}`))
	app.agent.state = .Waiting
	app.need_draw = true
}

// agent_set_open shows or hides the pane, and resizes the editor to match.
agent_set_open :: proc(app: ^App, open: bool) {
	app.agent.open = open
	if !open && app.focus == .Agent {
		app.focus = .Editor
	}
	app.settings.agent_open = open
	settings_save(&app.settings)
	resize_editor(app)
}

// agent_toggle is nvim's :AgentToggle: hide the pane, or show and focus it.
agent_toggle :: proc(app: ^App) {
	if app.agent.open {
		agent_set_open(app, false)
	} else {
		agent_focus(app)
	}
}

// ---- The show/hide button ----

// agent_button_rect is the button that hides the pane, at the right of
// its header. While the pane is hidden, the button that shows it again is
// in the same place, at the right end of the editor's toolbar.
agent_button_rect :: proc(app: ^App) -> mu.Rect {
	w, _ := window_pixels(app)
	s := agent_header_h(app)
	m := i32(3 * app.density)
	return {w - s - m, 0, s, s}
}

agent_button_shown :: proc(app: ^App) -> bool {
	return app.link != nil && !app.setup_open
}

// agent_button_hover records whether the mouse is over the button. It
// returns true when that changed.
agent_button_hover :: proc(app: ^App) -> bool {
	r := agent_button_rect(app)
	m := app.mouse
	over := agent_button_shown(app) && m.x >= r.x && m.y >= r.y && m.x < r.x + r.w && m.y < r.y + r.h
	changed := over != app.agent.btn_hover
	app.agent.btn_hover = over
	return changed
}

// agent_button_click handles a press on the button. It returns true when
// the press was on the button.
agent_button_click :: proc(app: ^App) -> bool {
	agent_button_hover(app)
	if !app.agent.btn_hover {
		return false
	}
	if app.agent.open {
		agent_set_open(app, false)
	} else {
		agent_focus(app)
	}
	agent_button_hover(app)
	app.need_draw = true
	return true
}

// agent_header_frame draws the pane's header (the agent's name, its state
// and the hide button), or, while the pane is hidden, the show button.
agent_header_frame :: proc(app: ^App) {
	if !agent_button_shown(app) {
		return
	}
	ctx := &app.ui.ctx
	ui := &app.ui
	a := &app.agent
	fg, bg := app.grid.default_fg, app.grid.default_bg
	if !a.open {
		r := agent_button_rect(app)
		if fixed_window(ctx, "!agentbtn", r, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE, .NO_SCROLL, .NO_FRAME, .NO_INTERACT}, Z_BAR) {
			draw_agent_button(app, r)
			mu.end_window(ctx)
		}
		return
	}
	w, _ := window_pixels(app)
	d := app.density
	div := max(i32(DIVIDER_PT * d), 1)
	left := agent_left(app) + div
	hr := mu.Rect{left, 0, w - left, agent_header_h(app)}
	if !fixed_window(ctx, "!agenthead", hr, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE, .NO_SCROLL, .NO_FRAME, .NO_INTERACT}, Z_BAR) {
		return
	}
	defer mu.end_window(ctx)
	mu.draw_rect(ctx, hr, blend(bg, fg, 0.04))
	mu.draw_rect(ctx, {hr.x, hr.y + hr.h - max(i32(d), 1), hr.w, max(i32(d), 1)}, blend(bg, fg, 0.12))
	if app.focused && app.focus == .Agent {
		// A line along the top says the pane has the keyboard.
		mu.draw_rect(ctx, {hr.x, 0, hr.w, max(i32(2 * d), 1)}, ui.colors.accent)
	}
	title := strings.to_upper(app.session.agent != "" ? app.session.agent : "agent", context.temp_allocator)
	switch a.state {
	case .Waiting:
		title = fmt.tprintf("%s · STARTING", title)
	case .Closed:
		title = fmt.tprintf("%s · %s", title, a.exit != "" ? "EXITED" : "CLOSED")
	case .Attached:
	}
	ty := hr.y + (hr.h - ui.small.cell_h) / 2
	tx := hr.x + i32(AGENT_PAD_PT * d) + i32(4 * d)
	color := blend(bg, fg, 0.6)
	mu.draw_text(ctx, mu.Font(&ui.small), title, {tx, ty}, color)
	mu.draw_text(ctx, mu.Font(&ui.small), title, {tx + 1, ty}, color)
	draw_agent_button(app, agent_button_rect(app))
}

@(private = "file")
blend :: proc(a, b: i32, t: f32) -> mu.Color {
	m :: proc(x, y: i32, t: f32) -> u8 {return u8(f32(x) + (f32(y) - f32(x)) * t)}
	return {m((a >> 16) & 0xff, (b >> 16) & 0xff, t), m((a >> 8) & 0xff, (b >> 8) & 0xff, t), m(a & 0xff, b & 0xff, t), 255}
}

// draw_agent_button draws the show/hide button in r: a small window
// outline whose right part is filled while the pane is shown, in the
// editor's colors. It is faint until the mouse is over it.
@(private = "file")
draw_agent_button :: proc(app: ^App, r: mu.Rect) {
	ctx := &app.ui.ctx
	fg, bg := app.grid.default_fg, app.grid.default_bg
	color := blend(bg, fg, 0.45)
	if app.agent.btn_hover {
		mu.draw_rect(ctx, r, blend(bg, fg, 0.12))
		color = blend(bg, fg, 0.9)
	}
	d := app.density
	t := max(i32(d), 1)
	iw, ih := i32(14 * d), i32(11 * d)
	x, y := r.x + (r.w - iw) / 2, r.y + (r.h - ih) / 2
	mu.draw_rect(ctx, {x, y, iw, t}, color)
	mu.draw_rect(ctx, {x, y + ih - t, iw, t}, color)
	mu.draw_rect(ctx, {x, y, t, ih}, color)
	mu.draw_rect(ctx, {x + iw - t, y, t, ih}, color)
	split := x + iw * 3 / 5
	if app.agent.open {
		mu.draw_rect(ctx, {split, y, x + iw - split, ih}, color)
	} else {
		mu.draw_rect(ctx, {split, y, t, ih}, color)
	}
}

// agent_focus shows the pane if it is hidden and gives it the keyboard.
agent_focus :: proc(app: ^App) {
	if !app.agent.open {
		agent_set_open(app, true)
	}
	app.focus = .Agent
	app.need_draw = true
}

// agent_switch_focus moves the keyboard to the other pane.
agent_switch_focus :: proc(app: ^App) {
	if agent_has_focus(app) {
		app.focus = .Editor
		app.need_draw = true
	} else if app.link != nil {
		agent_focus(app)
	}
}

// ---- Input ----

// agent_send sends bytes to the agent as typed input, and scrolls back to
// the bottom, as terminals do.
@(private = "file")
agent_send :: proc(app: ^App, data: []byte) {
	if app.link == nil || len(data) == 0 {
		return
	}
	link_send(app.link, FRAME_AGENT, data)
	if app.agent.state == .Attached {
		s := ghostty.Scroll_Viewport {
			tag = .Bottom,
		}
		ghostty.terminal_scroll_viewport(app.agent.term, s)
		app.need_draw = true
	}
}

// agent_key_down sends the key presses that text input misses (special
// keys, and keys with Ctrl or Alt). libghostty encodes them for the modes
// the agent has set: cursor and keypad modes, and the kitty keyboard
// protocol.
agent_key_down :: proc(app: ^App, ev: sdl.KeyboardEvent) {
	a := &app.agent
	ctrl := ev.mod & sdl.KMOD_CTRL != {}
	shift := ev.mod & sdl.KMOD_SHIFT != {}
	alt := ev.mod & sdl.KMOD_ALT != {}
	cmd := ev.mod & sdl.KMOD_GUI != {}
	if cmd {
		return // Cmd keys are the GUI's
	}
	key := g_key(ev.scancode)
	if key == .Unidentified {
		return
	}
	special := is_special(key)
	alt_meta := alt && app.input.alt_is_meta
	if !special && !ctrl && !alt_meta {
		return // plain or shifted text: text input sends it
	}
	if a.state == .Closed && key == .Enter && !ctrl && !alt && !shift {
		// "Press Enter to start it again."
		agent_restart(app)
		return
	}

	mods: u16
	if shift {mods |= ghostty.MODS_SHIFT}
	if ctrl {mods |= ghostty.MODS_CTRL}
	if alt {mods |= ghostty.MODS_ALT}

	// The key's character without modifiers, and with Shift.
	base := sdl.GetKeyFromScancode(ev.scancode, sdl.KMOD_NONE, false)
	unshifted: u32 = base < 0x4000_0000 ? u32(base) : 0
	text_buf: [4]u8
	text: ghostty.String
	consumed: u16
	if !special && unshifted != 0 {
		ch := unshifted
		if shift {
			shifted := sdl.GetKeyFromScancode(ev.scancode, sdl.KMOD_LSHIFT, false)
			if shifted != 0 && shifted < 0x4000_0000 && u32(shifted) != unshifted {
				ch = u32(shifted)
				consumed = ghostty.MODS_SHIFT
			}
		}
		bytes, n := utf8_encode(rune(ch))
		text_buf = bytes
		text = {raw_data(text_buf[:]), c.size_t(n)}
	}

	ghostty.key_encoder_set_from_terminal(a.enc, a.term)
	// On macOS, Option types characters unless -option-as-meta is given.
	opt: c.int = app.input.alt_is_meta ? 1 : 0
	ghostty.key_encoder_set(a.enc, .Macos_Option_As_Alt, &opt)

	ev_ := a.key
	ghostty.key_event_set_action(ev_, ev.repeat ? .Repeat : .Press)
	ghostty.key_event_set_key(ev_, key)
	ghostty.key_event_set_mods(ev_, mods)
	ghostty.key_event_set_consumed_mods(ev_, consumed)
	ghostty.key_event_set_utf8(ev_, text)
	ghostty.key_event_set_unshifted_codepoint(ev_, unshifted)
	buf: [128]u8
	written: c.size_t
	if ghostty.key_encoder_encode(a.enc, ev_, &buf[0], len(buf), &written) == .Success && written > 0 {
		agent_send(app, buf[:written])
	}
	// The key is sent; drop the text input that may follow it.
	app.input.suppress_text = true
}

// agent_text sends typed text as UTF-8.
agent_text :: proc(app: ^App, text: string) {
	if app.input.suppress_text {
		app.input.suppress_text = false
		return
	}
	if app.agent.state == .Closed {
		return
	}
	agent_send(app, transmute([]byte)text)
}

// agent_paste sends the clipboard's text, inside ESC[200~ ... ESC[201~
// when the agent has turned on bracketed paste (mode 2004).
agent_paste :: proc(app: ^App, text: string) {
	if text == "" || app.agent.state == .Closed {
		return
	}
	mode := ghostty.Mode_Config {
		mode = ghostty.MODE_BRACKETED_PASTE,
	}
	bracketed := ghostty.terminal_get(app.agent.term, .Mode, &mode) == .Success && mode.value
	// Strip the end marker from the text, so the paste ends only where
	// ngam ends it.
	clean, _ := strings.replace_all(text, "\x1b[201~", "", context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	if bracketed {
		strings.write_string(&b, "\x1b[200~")
		strings.write_string(&b, clean)
		strings.write_string(&b, "\x1b[201~")
	} else {
		// Without bracketed paste, line breaks are typed as Return.
		clean, _ = strings.replace_all(clean, "\r\n", "\r", context.temp_allocator)
		clean, _ = strings.replace_all(clean, "\n", "\r", context.temp_allocator)
		strings.write_string(&b, clean)
	}
	agent_send(app, b.buf[:])
}

// agent_copy puts the selection on the clipboard. It returns true when
// there was a selection.
agent_copy :: proc(app: ^App) -> bool {
	a := &app.agent
	sel: ghostty.Selection
	if ghostty.terminal_get(a.term, .Selection, &sel) != .Success {
		return false
	}
	f: ghostty.Formatter
	if ghostty.formatter_terminal_new(nil, &f, a.term) != .Success {
		return false
	}
	defer ghostty.formatter_free(f)
	yes := true
	ghostty.formatter_set(f, .Selection, &sel)
	ghostty.formatter_set(f, .Unwrap, &yes) // join lines the terminal wrapped
	ghostty.formatter_set(f, .Trim, &yes) // drop trailing spaces
	out: [^]u8
	n: c.size_t
	if ghostty.formatter_format_alloc(f, nil, &out, &n) != .Success {
		return false
	}
	clipboard_set(string(out[:n]))
	ghostty.free(nil, out, n)
	return true
}

// ---- Mouse ----

@(private = "file")
on_divider :: proc(app: ^App) -> bool {
	return agent_visible(app) && !app.setup_open && abs(app.mouse.x - agent_left(app)) <= i32(4 * app.density)
}

// agent_cell returns the agent cell under the mouse, in viewport rows.
@(private = "file")
agent_cell :: proc(app: ^App) -> (col, row: int) {
	ox, oy := agent_origin(app)
	col = clamp(int((app.mouse.x - ox) / max(app.font.cell_w, 1)), 0, app.agent.cols - 1)
	row = clamp(int((app.mouse.y - oy) / max(app.font.cell_h, 1)), 0, app.agent.rows - 1)
	return
}

// agent_mouse_down handles a press on the divider or in the pane. It
// returns true when it handled the press. A press in the pane focuses it
// and starts a selection.
agent_mouse_down :: proc(app: ^App, button: u8) -> bool {
	a := &app.agent
	if !agent_visible(app) || app.setup_open {
		return false
	}
	if on_divider(app) {
		a.dragging = true
		return true
	}
	if app.mouse.x < agent_left(app) {
		return false
	}
	app.focus = .Agent
	app.need_draw = true
	if app.mouse.y < agent_header_h(app) {
		return true // the header: focus only
	}
	if mb, ok := g_mouse_button(button); ok && agent_reports_mouse(app) {
		a.reporting = button
		agent_mouse_send(app, .Press, mb)
		return true
	}
	if button == sdl.BUTTON_LEFT {
		col, row := agent_cell(app)
		ghostty.terminal_set(a.term, .Selection, nil)
		ref: ghostty.Grid_Ref
		if ghostty.terminal_grid_ref(a.term, ghostty.point(.Viewport, col, row), &ref) == .Success {
			ghostty.terminal_point_from_grid_ref(a.term, &ref, .Screen, &a.sel_from)
			a.selecting = true
			a.sel_cell = {col, row}
		}
	}
	return true
}

// agent_mouse_move drags the divider or the selection, and shows the
// resize cursor on the divider.
agent_mouse_move :: proc(app: ^App) -> bool {
	a := &app.agent
	if a.dragging {
		w, _ := window_pixels(app)
		a.width = f32(w - app.mouse.x) / app.density
		app.need_draw = true
		return true
	}
	if a.selecting {
		col, row := agent_cell(app)
		cell := [2]int{col, row}
		if cell != a.sel_cell {
			a.sel_cell = cell
			sel: ghostty.Selection
			ok := ghostty.terminal_grid_ref(a.term, ghostty.point(.Screen, int(a.sel_from.x), int(a.sel_from.y)), &sel.start) == .Success
			ok = ok && ghostty.terminal_grid_ref(a.term, ghostty.point(.Viewport, col, row), &sel.end) == .Success
			if ok {
				ghostty.terminal_set(a.term, .Selection, &sel)
			}
			app.need_draw = true
		}
		return true
	}
	if a.reporting != 0 {
		mb, _ := g_mouse_button(a.reporting)
		agent_mouse_send(app, .Motion, mb)
		return true
	}
	over := on_divider(app)
	if !over && agent_over(app, app.mouse.x) && agent_reports_mouse(app) {
		// Agents that track every move (mode 1003) show hover effects.
		agent_mouse_send(app, .Motion, nil)
	}
	if over != a.over_divider {
		a.over_divider = over
		_ = sdl.SetCursor(over ? app.panel.cursor_ew : app.panel.cursor_arrow)
	}
	return false
}

agent_mouse_up :: proc(app: ^App, button: u8) -> bool {
	a := &app.agent
	if a.reporting != 0 && a.reporting == button {
		a.reporting = 0
		mb, _ := g_mouse_button(button)
		agent_mouse_send(app, .Release, mb)
		return true
	}
	if a.dragging {
		a.dragging = false
		// Keep the width the pane really got.
		a.width = f32(agent_want_px(app)) / app.density
		app.settings.agent_width = int(a.width)
		settings_save(&app.settings)
		resize_editor(app)
		return true
	}
	if a.selecting {
		a.selecting = false
		return true
	}
	return false
}

// agent_reports_mouse reports whether mouse events in the pane go to the
// agent: true when the agent turned on mouse reporting and Shift is up.
// Holding Shift keeps ngam's own selection and scrollback, as in other
// terminals.
@(private = "file")
agent_reports_mouse :: proc(app: ^App) -> bool {
	on: bool
	if ghostty.terminal_get(app.agent.term, .Mouse_Tracking, &on) != .Success || !on {
		return false
	}
	return sdl.GetModState() & sdl.KMOD_SHIFT == {}
}

@(private = "file")
g_mouse_button :: proc(b: u8) -> (ghostty.Mouse_Button, bool) {
	switch b {
	case sdl.BUTTON_LEFT:
		return .Left, true
	case sdl.BUTTON_MIDDLE:
		return .Middle, true
	case sdl.BUTTON_RIGHT:
		return .Right, true
	}
	return .Unknown, false
}

// agent_mouse_send sends the agent a mouse event at the mouse's position,
// encoded the way its modes ask for (SGR, say). Without a button, a motion
// event reports a plain move. The encoder sends only what the agent asked
// for, so it drops moves in mode 1000, for example.
@(private = "file")
agent_mouse_send :: proc(app: ^App, action: ghostty.Mouse_Action, button: Maybe(ghostty.Mouse_Button)) {
	a := &app.agent
	if app.link == nil {
		return
	}
	cw, ch := max(app.font.cell_w, 1), max(app.font.cell_h, 1)
	size := ghostty.Mouse_Encoder_Size {
		size          = size_of(ghostty.Mouse_Encoder_Size),
		screen_width  = u32(a.cols) * u32(cw),
		screen_height = u32(a.rows) * u32(ch),
		cell_width    = u32(cw),
		cell_height   = u32(ch),
	}
	ghostty.mouse_encoder_set_from_terminal(a.menc, a.term)
	ghostty.mouse_encoder_set(a.menc, .Size, &size)
	pressed := a.reporting != 0
	ghostty.mouse_encoder_set(a.menc, .Any_Button_Pressed, &pressed)
	track := true
	ghostty.mouse_encoder_set(a.menc, .Track_Last_Cell, &track)

	ox, oy := agent_origin(app)
	x := clamp(f32(app.mouse.x - ox), 0, f32(size.screen_width - 1))
	y := clamp(f32(app.mouse.y - oy), 0, f32(size.screen_height - 1))
	ghostty.mouse_event_set_action(a.mev, action)
	if b, ok := button.?; ok {
		ghostty.mouse_event_set_button(a.mev, b)
	} else {
		ghostty.mouse_event_clear_button(a.mev)
	}
	m := sdl.GetModState()
	mods: u16
	if m & sdl.KMOD_SHIFT != {} {mods |= ghostty.MODS_SHIFT}
	if m & sdl.KMOD_CTRL != {} {mods |= ghostty.MODS_CTRL}
	if m & sdl.KMOD_ALT != {} {mods |= ghostty.MODS_ALT}
	ghostty.mouse_event_set_mods(a.mev, mods)
	ghostty.mouse_event_set_position(a.mev, {x, y})

	buf: [64]u8
	written: c.size_t
	if ghostty.mouse_encoder_encode(a.menc, a.mev, &buf[0], len(buf), &written) == .Success && written > 0 {
		link_send(app.link, FRAME_AGENT, buf[:written])
	}
}

// agent_over reports whether the mouse is over the pane.
agent_over :: proc(app: ^App, x: i32) -> bool {
	return agent_visible(app) && !app.setup_open && x >= agent_left(app)
}

// agent_wheel sends wheel events to an agent that asked for mouse events
// (as Claude Code's fullscreen mode and pi do), so the agent scrolls its
// own history. Otherwise, on the alternate screen (less, top), which lacks
// scrollback, it sends arrow keys, as terminals do; on the main screen it
// scrolls the scrollback. With Shift held it always scrolls the
// scrollback.
agent_wheel :: proc(app: ^App, dy: f32) {
	a := &app.agent
	if agent_reports_mouse(app) {
		// One event per notch: the agent picks how far a notch scrolls.
		a.scroll_acc += dy
		n := int(a.scroll_acc)
		a.scroll_acc -= f32(n)
		for _ in 0 ..< abs(n) {
			agent_mouse_send(app, .Press, n > 0 ? .Four : .Five)
		}
		return
	}
	a.scroll_acc += dy * SCROLL_LINES
	n := int(a.scroll_acc)
	if n == 0 {
		return
	}
	a.scroll_acc -= f32(n)
	screen: c.int
	ghostty.terminal_get(a.term, .Active_Screen, &screen)
	if screen == 1 && sdl.GetModState() & sdl.KMOD_SHIFT == {} {
		ghostty.key_encoder_set_from_terminal(a.enc, a.term)
		ghostty.key_event_set_action(a.key, .Press)
		ghostty.key_event_set_key(a.key, n > 0 ? .Arrow_Up : .Arrow_Down)
		ghostty.key_event_set_mods(a.key, 0)
		ghostty.key_event_set_consumed_mods(a.key, 0)
		ghostty.key_event_set_utf8(a.key, {})
		ghostty.key_event_set_unshifted_codepoint(a.key, 0)
		buf: [16]u8
		written: c.size_t
		if ghostty.key_encoder_encode(a.enc, a.key, &buf[0], len(buf), &written) == .Success {
			for _ in 0 ..< abs(n) {
				if app.link != nil {
					link_send(app.link, FRAME_AGENT, buf[:written])
				}
			}
		}
		return
	}
	s := ghostty.Scroll_Viewport {
		tag = .Delta,
	}
	s.value.delta = -n // up is negative
	ghostty.terminal_scroll_viewport(a.term, s)
	app.need_draw = true
}

// ---- Drawing ----

@(private = "file")
fcol :: proc(c: ghostty.Rgb, alpha: f32 = 1) -> sdl.FColor {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, alpha}
}

@(private = "file")
mix :: proc(a, b: ghostty.Rgb, t: f32) -> ghostty.Rgb {
	m :: proc(x, y: u8, t: f32) -> u8 {return u8(f32(x) * (1 - t) + f32(y) * t)}
	return {m(a.r, b.r, t), m(a.g, b.g, t), m(a.b, b.b, t)}
}

@(private = "file")
rgb_of :: proc(v: i32) -> ghostty.Rgb {
	return {u8(v >> 16), u8(v >> 8), u8(v)}
}

// agent_draw draws the divider and the pane.
agent_draw :: proc(app: ^App) {
	a := &app.agent
	px := agent_pane_px(app)
	if px == 0 {
		return
	}
	rd := &app.rd
	f := &app.font
	w, h := window_pixels(app)
	left := w - px
	d := app.density
	div := max(i32(DIVIDER_PT * d), 1)
	focused := app.focused && !app.setup_open && app.focus == .Agent

	// The agent's default colors follow the editor's, so the two panes
	// match.
	want := [2]i32{app.grid.default_fg, app.grid.default_bg}
	if want != a.colors {
		fg, bg := rgb_of(want.x), rgb_of(want.y)
		ghostty.terminal_set(a.term, .Color_Foreground, &fg)
		ghostty.terminal_set(a.term, .Color_Background, &bg)
		a.colors = want
	}

	set_clip(rd, sdl.Rect{left, 0, px, h})
	defer set_clip(rd, nil)

	ghostty.render_state_update(a.rs, a.term)
	colors := ghostty.Render_Colors {
		size = size_of(ghostty.Render_Colors),
	}
	ghostty.render_state_get(a.rs, .Colors, &colors)
	cursor := ghostty.Render_Cursor {
		size = size_of(ghostty.Render_Cursor),
	}
	ghostty.render_state_get(a.rs, .Cursor, &cursor)

	fill(rd, f, left, 0, px, h, fcol(colors.background))
	fill(rd, f, left, 0, div, h, ui_color(app.ui.colors.bar))

	ox, oy := agent_origin(app)
	cw, ch := f.cell_w, f.cell_h
	row_cells := make([]Cell_Draw, max(a.cols, 1), context.temp_allocator)
	cursor_cell: Cell_Draw
	ghostty.render_state_get(a.rs, .Row_Iterator, &a.rows_it)
	y := 0
	for ghostty.render_state_row_iterator_next(a.rows_it) {
		ghostty.render_state_row_get(a.rows_it, .Cells, &a.cells)
		n := 0
		for ghostty.render_state_row_cells_next(a.cells) && n < len(row_cells) {
			row_cells[n] = read_cell(a.cells, &colors)
			n += 1
		}
		py := oy + i32(y) * ch
		// Draw backgrounds first, so they stay under a glyph's overhang.
		for cd, x in row_cells[:n] {
			if cd.has_bg {
				fill(rd, f, ox + i32(x) * cw, py, cw, ch, fcol(cd.bg))
			}
		}
		for cd, x in row_cells[:n] {
			cx := ox + i32(x) * cw
			if cd.r != 0 && cd.r != ' ' {
				glyph(rd, f, cx, py, cd.r, cd.style, fcol(cd.fg))
			}
			width := cd.wide ? cw * 2 : cw
			switch cd.underline {
			case 0:
			case 2:
				// double
				fill(rd, f, cx, py + f.underline_y, width, f.line_px, fcol(cd.ul_color))
				fill(rd, f, cx, py + f.underline_y + f.line_px * 2, width, f.line_px, fcol(cd.ul_color))
			case:
				// single; curly, dotted and dashed are drawn as single too
				fill(rd, f, cx, py + f.underline_y, width, f.line_px, fcol(cd.ul_color))
			}
			if cd.strike {
				fill(rd, f, cx, py + (f.baseline * 2) / 3, width, f.line_px, fcol(cd.fg))
			}
			if cd.overline {
				fill(rd, f, cx, py, width, f.line_px, fcol(cd.fg))
			}
		}
		if cursor.viewport_has_value && int(cursor.viewport_y) == y {
			cx := int(cursor.viewport_x)
			if cursor.wide_tail && cx > 0 {
				cx -= 1
			}
			if cx < n {
				cursor_cell = row_cells[cx]
			}
		}
		y += 1
	}
	ghostty.render_state_clean(a.rs)

	if cursor.visible && cursor.viewport_has_value && a.state != .Closed {
		draw_agent_cursor(app, &cursor, &cursor_cell, &colors, focused, ox, oy)
	}

	// Show a scroll thumb while scrolled back.
	sb: ghostty.Scrollbar
	if ghostty.terminal_get(a.term, .Scrollbar, &sb) == .Success && sb.total > sb.len && sb.offset + sb.len < sb.total {
		tw := max(i32(3 * d), 2)
		th := max(i32(f64(h) * f64(sb.len) / f64(sb.total)), i32(20 * d))
		ty := i32(f64(h - th) * f64(sb.offset) / f64(sb.total - sb.len))
		fill(rd, f, w - tw - i32(2 * d), ty, tw, th, fcol(colors.foreground, 0.4))
	}

	// Tell the user what to do after the agent exits or the pane
	// disconnects.
	if a.state == .Closed {
		msg: string
		if a.exit != "" {
			// exit is serve's wording, such as "exited" or "exited (1)".
			msg = fmt.tprintf("The agent %s. Press Enter to start it again.", a.exit)
		} else {
			msg = fmt.tprintf("The agent pane is disconnected (%s). Press Enter to reconnect.", a.reason)
		}
		uf := &app.ui.font
		pad := i32(8 * d)
		bh := uf.cell_h + pad * 2
		fill(rd, uf, left + div, h - bh, px - div, bh, ui_color(app.ui.colors.accent))
		text(rd, uf, left + div + pad, h - bh + pad, msg, {1, 1, 1, 1})
	}
}

// read_cell reads the current cell of the row's cells into a Cell_Draw,
// with defaults, inverse and faint applied.
@(private = "file")
read_cell :: proc(cells: ghostty.Row_Cells, colors: ^ghostty.Render_Colors) -> (cd: Cell_Draw) {
	raw: ghostty.Cell
	ghostty.render_state_row_cells_get(cells, .Raw, &raw)
	wide: ghostty.Wide
	ghostty.cell_get(raw, ghostty.Cell_Data_Wide, &wide)
	cd.wide = wide == .Wide

	glen: u32
	ghostty.render_state_row_cells_get(cells, .Graphemes_Len, &glen)
	if glen > 0 {
		// Draw only the first codepoint and drop the combining marks after
		// it, as the editor does.
		cps: [16]u32
		buf := ghostty.Codepoint_Buffer{&cps[0], len(cps), 0}
		ghostty.render_state_row_cells_get(cells, .Graphemes_Buf, &buf)
		if buf.len > 0 {
			cd.r = rune(cps[0])
		}
	}

	style: ghostty.Style
	ghostty.render_state_row_cells_get(cells, .Style, &style)
	fg, bg := colors.foreground, colors.background
	has_fg := ghostty.render_state_row_cells_get(cells, .Fg_Color, &fg) == .Success
	cd.has_bg = ghostty.render_state_row_cells_get(cells, .Bg_Color, &bg) == .Success
	if !has_fg {
		fg = colors.foreground
	}
	if !cd.has_bg {
		bg = colors.background
	}
	if style.flags & ghostty.STYLE_INVERSE != 0 {
		fg, bg = bg, fg
		cd.has_bg = true
	}
	selected: bool
	if ghostty.render_state_row_cells_get(cells, .Selected, &selected) == .Success && selected {
		fg, bg = bg, fg
		cd.has_bg = true
	}
	if style.flags & ghostty.STYLE_FAINT != 0 {
		fg = mix(fg, bg, 0.5)
	}
	if style.flags & ghostty.STYLE_INVISIBLE != 0 {
		cd.r = 0
	}
	cd.fg, cd.bg = fg, bg

	bold := style.flags & ghostty.STYLE_BOLD != 0
	italic := style.flags & ghostty.STYLE_ITALIC != 0
	switch {
	case bold && italic:
		cd.style = .Bold_Italic
	case bold:
		cd.style = .Bold
	case italic:
		cd.style = .Italic
	case:
		cd.style = .Regular
	}
	cd.underline = ghostty.style_underline(style)
	switch style.underline.tag {
	case 1:
		cd.ul_color = colors.palette[style.underline.value.palette]
	case 2:
		cd.ul_color = style.underline.value.rgb
	case:
		cd.ul_color = fg
	}
	cd.strike = style.flags & ghostty.STYLE_STRIKETHROUGH != 0
	cd.overline = style.flags & ghostty.STYLE_OVERLINE != 0
	return
}

@(private = "file")
draw_agent_cursor :: proc(app: ^App, cur: ^ghostty.Render_Cursor, cell: ^Cell_Draw, colors: ^ghostty.Render_Colors, focused: bool, ox, oy: i32) {
	rd := &app.rd
	f := &app.font
	cw, ch := f.cell_w, f.cell_h
	cx := i32(cur.viewport_x)
	if cur.wide_tail && cx > 0 {
		cx -= 1
	}
	x, y := ox + cx * cw, oy + i32(cur.viewport_y) * ch
	w := cell.wide ? cw * 2 : cw
	color := colors.cursor_has_value ? colors.cursor : colors.foreground
	t := f.line_px
	style := cur.visual_style
	if !focused {
		style = .Block_Hollow // the other pane has the keyboard
	}
	switch style {
	case .Block:
		fill(rd, f, x, y, w, ch, fcol(color))
		if cell.r != 0 && cell.r != ' ' {
			glyph(rd, f, x, y, cell.r, cell.style, fcol(colors.background))
		}
	case .Bar:
		fill(rd, f, x, y, max(t * 2, cw / 8), ch, fcol(color))
	case .Underline:
		fill(rd, f, x, y + ch - t * 2, w, t * 2, fcol(color))
	case .Block_Hollow:
		fill(rd, f, x, y, w, t, fcol(color))
		fill(rd, f, x, y + ch - t, w, t, fcol(color))
		fill(rd, f, x, y, t, ch, fcol(color))
		fill(rd, f, x + w - t, y, t, ch, fcol(color))
	}
}

// ---- Helpers ----

@(private = "file")
set_string :: proc(s: ^string, v: string) {
	delete(s^)
	s^ = strings.clone(v)
}

@(private = "file")
utf8_encode :: proc(r: rune) -> (b: [4]u8, n: int) {
	sb := strings.builder_from_bytes(b[:])
	strings.write_rune(&sb, r)
	return b, strings.builder_len(sb)
}

// is_special reports whether a key types no text of its own. Such a key
// always goes out from its key press.
@(private = "file")
is_special :: proc(k: ghostty.Key) -> bool {
	#partial switch k {
	case .Enter, .Escape, .Backspace, .Tab, .Insert, .Delete, .Home, .End, .Page_Up, .Page_Down, .Arrow_Up, .Arrow_Down, .Arrow_Left, .Arrow_Right, .Numpad_Enter:
		return true
	}
	return int(k) >= int(ghostty.Key.F1) && int(k) <= int(ghostty.Key.F1) + 23
}

// g_key maps SDL's scancode (the key's place on the keyboard) to
// libghostty's key.
@(private = "file")
g_key :: proc(sc: sdl.Scancode) -> ghostty.Key {
	s := int(sc)
	switch {
	case s >= 4 && s <= 29:
		return ghostty.Key(int(ghostty.Key.A) + s - 4) // A .. Z
	case s >= 30 && s <= 38:
		return ghostty.Key(int(ghostty.Key.Digit_0) + 1 + s - 30) // 1 .. 9
	case s >= 58 && s <= 69:
		return ghostty.Key(int(ghostty.Key.F1) + s - 58) // F1 .. F12
	case s >= 104 && s <= 115:
		return ghostty.Key(int(ghostty.Key.F1) + 12 + s - 104) // F13 .. F24
	case s >= 89 && s <= 97:
		return ghostty.Key(int(ghostty.Key.Numpad_0) + 1 + s - 89) // keypad 1 .. 9
	}
	switch s {
	case 39:
		return .Digit_0
	case 40:
		return .Enter
	case 41:
		return .Escape
	case 42:
		return .Backspace
	case 43:
		return .Tab
	case 44:
		return .Space
	case 45:
		return .Minus
	case 46:
		return .Equal
	case 47:
		return .Bracket_Left
	case 48:
		return .Bracket_Right
	case 49:
		return .Backslash
	case 51:
		return .Semicolon
	case 52:
		return .Quote
	case 53:
		return .Backquote
	case 54:
		return .Comma
	case 55:
		return .Period
	case 56:
		return .Slash
	case 73:
		return .Insert
	case 74:
		return .Home
	case 75:
		return .Page_Up
	case 76:
		return .Delete
	case 77:
		return .End
	case 78:
		return .Page_Down
	case 79:
		return .Arrow_Right
	case 80:
		return .Arrow_Left
	case 81:
		return .Arrow_Down
	case 82:
		return .Arrow_Up
	case 84:
		return .Numpad_Divide
	case 85:
		return .Numpad_Multiply
	case 86:
		return .Numpad_Subtract
	case 87:
		return .Numpad_Add
	case 88:
		return .Numpad_Enter
	case 98:
		return .Numpad_0
	case 99:
		return .Numpad_Decimal
	case 100:
		return .Intl_Backslash
	case 103:
		return .Numpad_Equal
	}
	return .Unidentified
}

