package ghostty

// Bindings for the parts of libghostty-vt that the agent pane uses: the
// terminal (it parses the agent's output), its render state (what to
// draw), the key encoder (keys as the agent expects them), the formatter
// (the selection as text) and selections. They follow the C headers in
// include/ghostty/vt/ of the Ghostty checkout.
//
// The library is linked statically from ngam/lib. ghostty-lib.sh copies
// it there from a Ghostty checkout and strips out Zig's compiler runtime
// (see that script). Build with -define:GHOSTTY_LIB=path to use another
// copy; the path is relative to ngam/.

import "core:c"

GHOSTTY_LIB :: #config(GHOSTTY_LIB, "lib/libghostty-vt.a")

foreign import lib {"../" + GHOSTTY_LIB}

// Every enum in the C API is a C int.
Result :: enum c.int {
	Success       = 0,
	Out_Of_Memory = -1,
	Invalid_Value = -2,
	Out_Of_Space  = -3,
	No_Value      = -4,
	IO_Error      = -5,
	Limit         = -6,
	Rejected      = -7,
	Unsupported   = -8,
}

// Handles are pointers to the library's own structs.
Terminal :: distinct rawptr
Render_State :: distinct rawptr
Row_Iterator :: distinct rawptr
Row_Cells :: distinct rawptr
Key_Encoder :: distinct rawptr
Key_Event :: distinct rawptr
Formatter :: distinct rawptr

Cell :: u64

String :: struct {
	ptr: [^]u8,
	len: c.size_t,
}

Rgb :: struct {
	r, g, b: u8,
}

// A cell's color in its style: none (the default), a palette index, or RGB.
Style_Color :: struct {
	tag:   u8, // 0 none, 1 palette, 2 rgb
	value: struct #raw_union {
		palette: u8,
		rgb:     Rgb,
	},
}

Style :: struct {
	fg, bg, underline: Style_Color,
	flags:             u16,
	reserved:          u16,
}

STYLE_BOLD :: 1 << 0
STYLE_ITALIC :: 1 << 1
STYLE_FAINT :: 1 << 2
STYLE_INVERSE :: 1 << 4
STYLE_INVISIBLE :: 1 << 5
STYLE_STRIKETHROUGH :: 1 << 6
STYLE_OVERLINE :: 1 << 7

// style_underline is the underline kind: 0 none, 1 single, 2 double,
// 3 curly, 4 dotted, 5 dashed.
style_underline :: proc(s: Style) -> int {
	return int((s.flags >> 8) & 7)
}

Codepoint_Buffer :: struct {
	ptr: [^]u32,
	cap: c.size_t,
	len: c.size_t,
}

// ---- Points and selections ----

Point_Tag :: enum c.int {
	Active   = 0, // the active area: the bottom rows, where the cursor is
	Viewport = 1, // what is on screen, which may be scrolled back
	Screen   = 2, // the whole screen with its scrollback, from the top
	History  = 3,
}

Point_Coord :: struct {
	x: u16,
	y: u32,
}

Point :: struct {
	tag:   Point_Tag,
	value: struct #raw_union {
		coord:    Point_Coord,
		_padding: [2]u64,
	},
}

point :: proc(tag: Point_Tag, x: int, y: int) -> Point {
	p := Point{tag = tag}
	p.value.coord = {u16(x), u32(y)}
	return p
}

Grid_Ref :: struct {
	node: rawptr,
	x, y: u16,
}

Selection :: struct {
	start, end: Grid_Ref,
	rectangle:  bool,
}

// ---- Terminal ----

Terminal_Option :: enum c.int {
	Userdata             = 1,
	Write_Pty            = 2,
	Bell                 = 3,
	Color_Foreground     = 12,
	Color_Background     = 13,
	Color_Cursor         = 14,
	Selection            = 22,
	Clipboard_Write      = 27,
	Scrollback_Max_Lines = 29,
	Mode                 = 35,
}

Terminal_Data :: enum c.int {
	Cols                 = 1,
	Rows                 = 2,
	Active_Screen        = 6, // 0 primary, 1 alternate
	Kitty_Keyboard_Flags = 8,
	Scrollbar            = 9,
	Mouse_Tracking       = 11,
	Selection            = 31,
	Viewport_Active      = 32, // bool: the viewport shows the bottom
	Mode                 = 37,
}

Scrollbar :: struct {
	total, offset, len: u64,
}

Scroll_Tag :: enum c.int {
	Top    = 0,
	Bottom = 1,
	Delta  = 2,
	Row    = 3,
}

Scroll_Viewport :: struct {
	tag:   Scroll_Tag,
	value: struct #raw_union {
		delta:    int,
		row:      uint,
		_padding: [2]u64,
	},
}

// A terminal mode: the mode number, with the top bit set for ANSI modes
// (clear for DEC private modes such as ?2004).
Mode_Config :: struct {
	mode:  u16,
	value: bool,
}

MODE_BRACKETED_PASTE :: 2004 // DEC private

Clipboard_Content :: struct {
	mime: String,
	data: String,
}

Clipboard_Write_Reply :: struct {
	size:     c.size_t,
	result:   c.int, // 0 success, 1 denied
	remember: bool,
}

Clipboard_Write :: struct {
	location:     c.int, // 0 the standard clipboard, 1 selection, 2 primary
	contents:     [^]Clipboard_Content,
	contents_len: c.size_t,
	name:         String,
	granted:      bool,
	can_remember: bool,
	ctx:          rawptr,
	reply:        proc "c" (write: ^Clipboard_Write, reply: ^Clipboard_Write_Reply),
}

Write_Pty_Fn :: #type proc "c" (t: Terminal, userdata: rawptr, data: [^]u8, len: c.size_t)
Bell_Fn :: #type proc "c" (t: Terminal, userdata: rawptr)
Clipboard_Write_Fn :: #type proc "c" (t: Terminal, userdata: rawptr, write: ^Clipboard_Write)

// ---- Render state ----

Render_Data :: enum c.int {
	Cols         = 1,
	Rows         = 2,
	Dirty        = 3,
	Row_Iterator = 4,
	Cursor       = 18,
	Colors       = 19,
}

Cursor_Style :: enum c.int {
	Bar          = 0,
	Block        = 1,
	Underline    = 2,
	Block_Hollow = 3,
}

Render_Cursor :: struct {
	size:               c.size_t,
	viewport_has_value: bool,
	viewport_x:         u16,
	viewport_y:         u16,
	wide_tail:          bool,
	visible:            bool,
	blinking:           bool,
	password_input:     bool,
	visual_style:       Cursor_Style,
}

Render_Colors :: struct {
	size:             c.size_t,
	background:       Rgb,
	foreground:       Rgb,
	cursor:           Rgb,
	cursor_has_value: bool,
	palette:          [256]Rgb,
}

Row_Data :: enum c.int {
	Dirty     = 1,
	Cells     = 3,
	Selection = 4,
}

Row_Selection :: struct {
	size:           c.size_t,
	start_x, end_x: u16, // inclusive
}

Cells_Data :: enum c.int {
	Raw           = 1,
	Style         = 2,
	Graphemes_Len = 3, // 0 means the cell is empty
	Graphemes_Buf = 4,
	Bg_Color      = 5, // the resolved background; No_Value means the default
	Fg_Color      = 6, // the resolved foreground; No_Value means the default
	Selected      = 7,
}

Cell_Data_Wide :: 3 // with ghostty_cell_get

Wide :: enum c.int {
	Narrow      = 0,
	Wide        = 1, // the first half of a double-width character
	Spacer_Tail = 2, // the second half
	Spacer_Head = 3, // the end of a line that wrapped a wide character
}

// ---- Keys ----

Key_Action :: enum c.int {
	Release = 0,
	Press   = 1,
	Repeat  = 2,
}

MODS_SHIFT :: 1 << 0
MODS_CTRL :: 1 << 1
MODS_ALT :: 1 << 2
MODS_SUPER :: 1 << 3

Encoder_Option :: enum c.int {
	Kitty_Flags          = 6,
	Macos_Option_As_Alt = 7, // 0 false, 1 true, 2 left, 3 right
}

KITTY_REPORT_ALL :: 1 << 3 // every key as an escape code, text keys too

// Key is the physical key, with W3C "code" names, as in Ghostty.
Key :: enum c.int {
	Unidentified = 0,
	Backquote    = 1,
	Backslash    = 2,
	Bracket_Left = 3,
	Bracket_Right = 4,
	Comma        = 5,
	Digit_0      = 6, // through Digit_9 = 15
	Equal        = 16,
	Intl_Backslash = 17,
	A            = 20, // through Z = 45
	Minus        = 46,
	Period       = 47,
	Quote        = 48,
	Semicolon    = 49,
	Slash        = 50,
	Backspace    = 53,
	Enter        = 58,
	Space        = 63,
	Tab          = 64,
	Delete       = 68,
	End          = 69,
	Home         = 71,
	Insert       = 72,
	Page_Down    = 73,
	Page_Up      = 74,
	Arrow_Down   = 75,
	Arrow_Left   = 76,
	Arrow_Right  = 77,
	Arrow_Up     = 78,
	Numpad_0     = 80, // through Numpad_9 = 89
	Numpad_Add   = 90,
	Numpad_Decimal = 95,
	Numpad_Divide = 96,
	Numpad_Enter = 97,
	Numpad_Equal = 98,
	Numpad_Multiply = 104,
	Numpad_Subtract = 107,
	Escape       = 120,
	F1           = 121, // through F24 = 144
}

// ---- Mouse ----

Mouse_Encoder :: distinct rawptr
Mouse_Event :: distinct rawptr

Mouse_Action :: enum c.int {
	Press   = 0,
	Release = 1,
	Motion  = 2,
}

Mouse_Button :: enum c.int {
	Unknown = 0,
	Left    = 1,
	Right   = 2,
	Middle  = 3,
	Four    = 4, // wheel up
	Five    = 5, // wheel down
	Six     = 6, // wheel left
	Seven   = 7, // wheel right
}

Mouse_Position :: struct {
	x, y: f32, // pixels, from the surface's top left
}

Mouse_Encoder_Option :: enum c.int {
	Size               = 3, // Mouse_Encoder_Size
	Any_Button_Pressed = 4, // bool
	Track_Last_Cell    = 5, // bool
}

Mouse_Encoder_Size :: struct {
	size:                     c.size_t, // size_of(Mouse_Encoder_Size)
	screen_width:             u32,
	screen_height:            u32,
	cell_width, cell_height:  u32,
	padding_top:              u32,
	padding_bottom:           u32,
	padding_right:            u32,
	padding_left:             u32,
}

// ---- Formatter ----

Formatter_Option :: enum c.int {
	Emit      = 1, // 0 plain text
	Unwrap    = 2,
	Trim      = 3,
	Selection = 4,
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	terminal_new :: proc(alloc: rawptr, t: ^Terminal, cols, rows: u16) -> Result ---
	terminal_free :: proc(t: Terminal) ---
	terminal_reset :: proc(t: Terminal) ---
	terminal_resize :: proc(t: Terminal, cols, rows: u16, cell_w, cell_h: u32) -> Result ---
	terminal_set :: proc(t: Terminal, opt: Terminal_Option, value: rawptr) -> Result ---
	terminal_get :: proc(t: Terminal, data: Terminal_Data, out: rawptr) -> Result ---
	terminal_vt_write :: proc(t: Terminal, data: [^]u8, len: c.size_t) ---
	terminal_scroll_viewport :: proc(t: Terminal, s: Scroll_Viewport) -> Result ---
	terminal_grid_ref :: proc(t: Terminal, p: Point, out: ^Grid_Ref) -> Result ---
	terminal_point_from_grid_ref :: proc(t: Terminal, ref: ^Grid_Ref, tag: Point_Tag, out: ^Point_Coord) -> Result ---

	render_state_new :: proc(alloc: rawptr, s: ^Render_State) -> Result ---
	render_state_free :: proc(s: Render_State) ---
	render_state_update :: proc(s: Render_State, t: Terminal) -> Result ---
	render_state_get :: proc(s: Render_State, data: Render_Data, out: rawptr) -> Result ---
	render_state_clean :: proc(s: Render_State) -> Result ---
	render_state_row_iterator_new :: proc(alloc: rawptr, it: ^Row_Iterator) -> Result ---
	render_state_row_iterator_free :: proc(it: Row_Iterator) ---
	render_state_row_iterator_next :: proc(it: Row_Iterator) -> bool ---
	render_state_row_get :: proc(it: Row_Iterator, data: Row_Data, out: rawptr) -> Result ---
	render_state_row_cells_new :: proc(alloc: rawptr, cells: ^Row_Cells) -> Result ---
	render_state_row_cells_free :: proc(cells: Row_Cells) ---
	render_state_row_cells_next :: proc(cells: Row_Cells) -> bool ---
	render_state_row_cells_get :: proc(cells: Row_Cells, data: Cells_Data, out: rawptr) -> Result ---
	cell_get :: proc(cell: Cell, data: c.int, out: rawptr) -> Result ---

	key_encoder_new :: proc(alloc: rawptr, enc: ^Key_Encoder) -> Result ---
	key_encoder_free :: proc(enc: Key_Encoder) ---
	key_encoder_set :: proc(enc: Key_Encoder, opt: Encoder_Option, value: rawptr) -> Result ---
	key_encoder_set_from_terminal :: proc(enc: Key_Encoder, t: Terminal) -> Result ---
	key_encoder_encode :: proc(enc: Key_Encoder, ev: Key_Event, buf: [^]u8, cap: c.size_t, written: ^c.size_t) -> Result ---
	key_event_new :: proc(alloc: rawptr, ev: ^Key_Event) -> Result ---
	key_event_free :: proc(ev: Key_Event) ---
	key_event_set_action :: proc(ev: Key_Event, action: Key_Action) -> Result ---
	key_event_set_key :: proc(ev: Key_Event, key: Key) -> Result ---
	key_event_set_mods :: proc(ev: Key_Event, mods: u16) -> Result ---
	key_event_set_consumed_mods :: proc(ev: Key_Event, mods: u16) -> Result ---
	key_event_set_utf8 :: proc(ev: Key_Event, utf8: String) -> Result ---
	key_event_set_unshifted_codepoint :: proc(ev: Key_Event, cp: u32) -> Result ---

	mouse_encoder_new :: proc(alloc: rawptr, enc: ^Mouse_Encoder) -> Result ---
	mouse_encoder_free :: proc(enc: Mouse_Encoder) ---
	mouse_encoder_set :: proc(enc: Mouse_Encoder, opt: Mouse_Encoder_Option, value: rawptr) -> Result ---
	mouse_encoder_set_from_terminal :: proc(enc: Mouse_Encoder, t: Terminal) -> Result ---
	mouse_encoder_encode :: proc(enc: Mouse_Encoder, ev: Mouse_Event, buf: [^]u8, cap: c.size_t, written: ^c.size_t) -> Result ---
	mouse_event_new :: proc(alloc: rawptr, ev: ^Mouse_Event) -> Result ---
	mouse_event_free :: proc(ev: Mouse_Event) ---
	mouse_event_set_action :: proc(ev: Mouse_Event, action: Mouse_Action) -> Result ---
	mouse_event_set_button :: proc(ev: Mouse_Event, button: Mouse_Button) -> Result ---
	mouse_event_clear_button :: proc(ev: Mouse_Event) -> Result ---
	mouse_event_set_mods :: proc(ev: Mouse_Event, mods: u16) -> Result ---
	mouse_event_set_position :: proc(ev: Mouse_Event, pos: Mouse_Position) -> Result ---

	formatter_terminal_new :: proc(alloc: rawptr, f: ^Formatter, t: Terminal) -> Result ---
	formatter_set :: proc(f: Formatter, opt: Formatter_Option, value: rawptr) -> Result ---
	formatter_format_alloc :: proc(f: Formatter, alloc: rawptr, out: ^[^]u8, len: ^c.size_t) -> Result ---
	formatter_free :: proc(f: Formatter) ---
	free :: proc(alloc: rawptr, ptr: [^]u8, len: c.size_t) ---
}

// ghostty-lib.sh drops Zig's compiler runtime from the archive, because
// Odin's runtime defines some of the same helpers. libSystem and Odin's
// runtime provide what libghostty-vt needs, apart from these two f128
// conversions. Only Zig's code for printing 128-bit and 80-bit floats
// uses them.
@(export, private, link_name = "__extenddftf2")
ghostty_extenddftf2 :: proc "c" (a: f64) -> u128 {
	// f64 to IEEE binary128, as raw bits.
	bits := transmute(u64)a
	sign := u128(bits >> 63) << 127
	exp := (bits >> 52) & 0x7ff
	frac := bits & (1 << 52 - 1)
	switch {
	case exp == 0x7ff:
		// Infinity or NaN.
		return sign | u128(0x7fff) << 112 | u128(frac) << 60
	case exp == 0 && frac == 0:
		return sign
	case exp == 0:
		// A subnormal f64 is a normal f128.
		shift := u64(0)
		for frac & (1 << 52) == 0 {
			frac <<= 1
			shift += 1
		}
		frac &= 1 << 52 - 1
		e := u128(15360 - 1023 + 1 - shift + 1023 - 1)
		return sign | e << 112 | u128(frac) << 60
	}
	return sign | u128(exp + 15360) << 112 | u128(frac) << 60
}

@(export, private, link_name = "__extendxftf2")
ghostty_extendxftf2 :: proc "c" (a: [2]u64) -> u128 {
	// arm64 has no 80-bit floats, and ngam's use of libghostty-vt never
	// prints one, so a stub is enough.
	return 0
}
