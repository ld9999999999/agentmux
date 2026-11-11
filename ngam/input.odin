package ngam

// Keyboard input, turned into nvim_input's notation. Typed text comes from
// SDL's text input events, which handle shift, dead keys and input
// methods. Key events cover the rest: special keys such as <Esc> and
// <Up>, and keys pressed with Ctrl, Alt (as Meta) or Cmd.

import "core:strings"
import sdl "vendor:sdl3"

// Shortcuts the GUI handles itself.
Key_Action :: enum {
	None,
	Paste, // Cmd-V (Ctrl-Shift-V off macOS): paste the host clipboard
	Copy, // Cmd-C (Ctrl-Shift-C off macOS): copy the visual selection
	Setup, // Cmd-, (Ctrl-, off macOS): the setup screen
	Toggle_Panel, // Cmd-B (Ctrl-Shift-B off macOS): show or hide the side panel
	View, // Cmd-Shift-<key> (Ctrl-Shift-<key>): show a panel view; see view_key
	Switch_Focus, // the agent_focus_key setting: move the keyboard to the other pane
	Quick_Open, // Cmd-P (Ctrl-Shift-P off macOS): find a file by name
	Font_Bigger, // Cmd-= or Cmd-+ (Ctrl-= off macOS)
	Font_Smaller, // Cmd-- (Ctrl--)
	Font_Reset, // Cmd-0 (Ctrl-0): the default size
}

// A shortcut from the settings, such as "cmd+shift+a".
Shortcut :: struct {
	key:                    rune, // 0 for none
	ctrl, shift, alt, cmd:  bool,
}

// parse_shortcut reads a shortcut such as "cmd+shift+a" or "ctrl+alt+;".
// The modifiers are cmd (or super), ctrl, shift and alt (or option); the
// last part is one character. A shortcut must use Cmd, Ctrl or Alt, so
// that typed characters stay free.
parse_shortcut :: proc(s: string) -> (sc: Shortcut, ok: bool) {
	parts := strings.split(strings.to_lower(s, context.temp_allocator), "+", context.temp_allocator)
	if len(parts) < 2 {
		return {}, false
	}
	for p in parts[:len(parts) - 1] {
		switch strings.trim_space(p) {
		case "cmd", "super", "command":
			sc.cmd = true
		case "ctrl", "control":
			sc.ctrl = true
		case "shift":
			sc.shift = true
		case "alt", "option", "opt":
			sc.alt = true
		case:
			return {}, false
		}
	}
	last := parts[len(parts) - 1]
	if strings.rune_count(last) != 1 || !(sc.cmd || sc.ctrl || sc.alt) {
		return {}, false
	}
	for r in last {
		sc.key = r
	}
	return sc, true
}

Input :: struct {
	// Alt sends <M-x>. On macOS Option types characters such as "å", and
	// sends <M-x> only with -option-as-meta.
	alt_is_meta:   bool,
	// A key event was sent as <C-x> or the like, so the text input
	// event that may follow it for the same key is dropped.
	suppress_text: bool,
	// The letter of the last .View shortcut, such as 'e' for Explorer.
	view_key:      rune,
	// The shortcut that switches the keyboard between the panes.
	focus_key:     Shortcut,
}

// key_down returns the nvim_input keys for a key press, or "" when text
// input will deliver it, or a shortcut for the GUI to handle.
key_down :: proc(in_: ^Input, ev: sdl.KeyboardEvent) -> (keys: string, action: Key_Action) {
	in_.suppress_text = false
	ctrl := ev.mod & sdl.KMOD_CTRL != {}
	shift := ev.mod & sdl.KMOD_SHIFT != {}
	alt := ev.mod & sdl.KMOD_ALT != {} && in_.alt_is_meta
	cmd := ev.mod & sdl.KMOD_GUI != {}

	b := strings.builder_make(context.temp_allocator)
	if name := special_key(ev.key); name != "" {
		strings.write_byte(&b, '<')
		write_mods(&b, ctrl, shift, alt, cmd)
		strings.write_string(&b, name)
		strings.write_byte(&b, '>')
		return strings.to_string(b), .None // special keys type no text
	}
	if !ctrl && !alt && !cmd {
		return "", .None // plain or shifted text: text input sends it
	}
	// The key's character on the current layout, without modifiers.
	base := sdl.GetKeyFromScancode(ev.scancode, sdl.KMOD_NONE, false)
	if base == 0 || base >= 0x4000_0000 {
		return "", .None // a modifier key on its own, or one with no character
	}
	r := rune(base)
	if fk := in_.focus_key; fk.key != 0 && r == fk.key && ctrl == fk.ctrl && shift == fk.shift && cmd == fk.cmd && (ev.mod & sdl.KMOD_ALT != {}) == fk.alt {
		in_.suppress_text = true
		return "", .Switch_Focus
	}
	// SDL's macOS app menu already handles Cmd+Q, W, H and M (quit,
	// close, hide, minimize). nvim runs an unmapped <D-q> as a plain "q",
	// which would start a macro recording just as the window closes and
	// hold up the snapshot, so ngam keeps these keys from nvim.
	when ODIN_OS == .Darwin {
		if cmd && !ctrl && !alt && !shift && (r == 'q' || r == 'w' || r == 'h' || r == 'm') {
			return "", .None
		}
		shortcut := cmd && !ctrl && !alt && !shift
	} else {
		shortcut := ctrl && shift && !alt && !cmd
	}
	if shortcut && (r == 'v' || r == 'c') {
		in_.suppress_text = true
		return "", r == 'v' ? .Paste : .Copy
	}
	// The GUI's own shortcuts: the setup screen, the side panel and its
	// views.
	when ODIN_OS == .Darwin {
		plain_cmd := cmd && !ctrl && !alt && !shift
		view_mods := cmd && shift && !ctrl && !alt
	} else {
		plain_cmd := ctrl && !cmd && !alt && !shift
		view_mods := ctrl && shift && !cmd && !alt
	}
	switch {
	case plain_cmd && r == ',':
		in_.suppress_text = true
		return "", .Setup
	case (ODIN_OS == .Darwin ? plain_cmd : view_mods) && r == 'b':
		in_.suppress_text = true
		return "", .Toggle_Panel
	case (ODIN_OS == .Darwin ? plain_cmd : view_mods) && r == 'p':
		in_.suppress_text = true
		return "", .Quick_Open
	case (plain_cmd || (ODIN_OS == .Darwin && cmd && shift && !ctrl && !alt)) && (r == '=' || r == '+'):
		in_.suppress_text = true
		return "", .Font_Bigger
	case plain_cmd && r == '-':
		in_.suppress_text = true
		return "", .Font_Smaller
	case plain_cmd && r == '0':
		in_.suppress_text = true
		return "", .Font_Reset
	case view_mods && (r == 'e' || r == 'g' || r == 's'):
		in_.suppress_text = true
		in_.view_key = r
		return "", .View
	}
	keep_shift := false
	if shift {
		if r >= 'a' && r <= 'z' {
			// <C-a> and <C-A> are the same key to nvim, so Ctrl and Cmd
			// keep S-. Alt sends <M-A>.
			if ctrl || cmd {
				keep_shift = true
			} else {
				r -= 'a' - 'A'
			}
		} else {
			// Shifted symbols use the shifted character: Ctrl+Shift+6 is
			// <C-^>.
			shifted := sdl.GetKeyFromScancode(ev.scancode, sdl.KMOD_LSHIFT, false)
			if shifted != 0 && shifted < 0x4000_0000 {
				r = rune(shifted)
			}
		}
	}
	strings.write_byte(&b, '<')
	write_mods(&b, ctrl, keep_shift, alt, cmd)
	switch r {
	case '<':
		strings.write_string(&b, "lt")
	case '\\':
		strings.write_string(&b, "Bslash")
	case '|':
		strings.write_string(&b, "Bar")
	case ' ':
		strings.write_string(&b, "Space")
	case:
		strings.write_rune(&b, r)
	}
	strings.write_byte(&b, '>')
	in_.suppress_text = true
	return strings.to_string(b), .None
}

// text_input returns the nvim_input keys for typed text.
text_input :: proc(in_: ^Input, text: string) -> string {
	if in_.suppress_text {
		in_.suppress_text = false
		return ""
	}
	s, _ := strings.replace_all(text, "<", "<lt>", context.temp_allocator)
	return s
}

@(private = "file")
write_mods :: proc(b: ^strings.Builder, ctrl, shift, alt, cmd: bool) {
	if ctrl {strings.write_string(b, "C-")}
	if shift {strings.write_string(b, "S-")}
	if alt {strings.write_string(b, "M-")}
	if cmd {strings.write_string(b, "D-")}
}

@(private = "file")
special_key :: proc(k: sdl.Keycode) -> string {
	switch k {
	case sdl.K_RETURN:
		return "CR"
	case sdl.K_ESCAPE:
		return "Esc"
	case sdl.K_BACKSPACE:
		return "BS"
	case sdl.K_TAB:
		return "Tab"
	case sdl.K_DELETE:
		return "Del"
	case sdl.K_INSERT:
		return "Insert"
	case sdl.K_HOME:
		return "Home"
	case sdl.K_END:
		return "End"
	case sdl.K_PAGEUP:
		return "PageUp"
	case sdl.K_PAGEDOWN:
		return "PageDown"
	case sdl.K_UP:
		return "Up"
	case sdl.K_DOWN:
		return "Down"
	case sdl.K_LEFT:
		return "Left"
	case sdl.K_RIGHT:
		return "Right"
	case sdl.K_KP_ENTER:
		return "kEnter"
	case sdl.K_F1:
		return "F1"
	case sdl.K_F2:
		return "F2"
	case sdl.K_F3:
		return "F3"
	case sdl.K_F4:
		return "F4"
	case sdl.K_F5:
		return "F5"
	case sdl.K_F6:
		return "F6"
	case sdl.K_F7:
		return "F7"
	case sdl.K_F8:
		return "F8"
	case sdl.K_F9:
		return "F9"
	case sdl.K_F10:
		return "F10"
	case sdl.K_F11:
		return "F11"
	case sdl.K_F12:
		return "F12"
	}
	return ""
}
