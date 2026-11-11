package ngam

// A test hook: when $NGAM_TEST_SCRIPT names a file, a thread reads it and
// plays its lines into the main loop as if they were window events, so a
// script can drive ngam. Lines are:
//
//   wait <ms>               sleep before the next line
//   key <name> [mods...]    a key press; name is SDL's key name (W, Return,
//                           Escape, Up); mods are ctrl, shift, alt, cmd
//   text <text>             typed text, to the end of the line
//   resize <w> <h>          resize the window, in points
//   click <x> <y> [mods...] a left click at x, y in points
//   move <x> <y>            move the mouse to x, y in points
//   drag <x> <y>            press at the mouse, move to x, y and release
//   wheel <x> <y> <dy> [mods...]  a wheel turn at x, y; dy > 0 is up
//   rclick <x> <y>          a right click at x, y in points
//   quit                    the same as closing the window

import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import sdl "vendor:sdl3"

@(private = "file")
script_event: u32

test_script_start :: proc() {
	path := os.get_env("NGAM_TEST_SCRIPT", context.allocator)
	if path == "" {
		return
	}
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return
	}
	script_event = sdl.RegisterEvents(1)
	script := strings.clone_to_cstring(string(data))
	thread.run_with_data(rawptr(script), proc(p: rawptr) {
		text := string(cstring(p))
		for line in strings.split_lines_iterator(&text) {
			if strings.has_prefix(line, "wait ") {
				n, _ := strconv.parse_int(line[len("wait "):])
				time.sleep(time.Duration(n) * time.Millisecond)
				continue
			}
			if strings.trim_space(line) == "" {
				continue
			}
			ev: sdl.Event
			ev.type = sdl.EventType(script_event)
			ev.user.data1 = rawptr(strings.clone_to_cstring(line))
			_ = sdl.PushEvent(&ev)
		}
	})
}

// test_script_event handles one script line on the main thread. It says
// whether ev was a script event.
test_script_event :: proc(app: ^App, ev: ^sdl.Event) -> bool {
	if script_event == 0 || u32(ev.type) != script_event {
		return false
	}
	line := string(cstring(ev.user.data1))
	defer delete(cstring(ev.user.data1))
	words := strings.fields(line, context.temp_allocator)
	switch words[0] {
	case "key":
		k := sdl.GetKeyFromName(strings.clone_to_cstring(words[1], context.temp_allocator))
		mod: sdl.Keymod
		for m in words[2:] {
			switch m {
			case "ctrl":
				mod += {.LCTRL}
			case "shift":
				mod += {.LSHIFT}
			case "alt":
				mod += {.LALT}
			case "cmd":
				mod += {.LGUI}
			}
		}
		fake: sdl.Event
		fake.type = .KEY_DOWN
		fake.key.key = k
		fake.key.scancode = sdl.GetScancodeFromKey(k, nil)
		fake.key.mod = mod
		fake.key.down = true
		handle_event(app, &fake)
	case "text":
		// Real typed text follows its own key press, which clears this.
		app.input.suppress_text = false
		fake: sdl.Event
		fake.type = .TEXT_INPUT
		fake.text.text = strings.clone_to_cstring(line[len("text "):], context.temp_allocator)
		handle_event(app, &fake)
	case "click", "move", "drag":
		x, _ := strconv.parse_f32(words[1])
		y, _ := strconv.parse_f32(words[2])
		mod: sdl.Keymod
		clicks: u8 = 1
		for m in words[3:] {
			switch m {
			case "double":
				clicks = 2
			case "ctrl":
				mod += {.LCTRL}
			case "shift":
				mod += {.LSHIFT}
			case "cmd":
				mod += {.LGUI}
			}
		}
		// The handlers read the modifiers from SDL, so set them there.
		sdl.SetModState(mod)
		defer sdl.SetModState({})
		fake: sdl.Event
		if words[0] == "drag" {
			fake.type = .MOUSE_BUTTON_DOWN
			fake.button.button = sdl.BUTTON_LEFT
			fake.button.x, fake.button.y = f32(app.mouse.x) / app.density, f32(app.mouse.y) / app.density
			handle_event(app, &fake)
		}
		fake = {}
		fake.type = .MOUSE_MOTION
		fake.motion.x, fake.motion.y = x, y
		handle_event(app, &fake)
		// microui needs a frame with the mouse over a control first.
		app.need_draw = true
		pump(app)
		if words[0] == "move" {
			break
		}
		if words[0] == "click" {
			fake = {}
			fake.type = .MOUSE_BUTTON_DOWN
			fake.button.button = sdl.BUTTON_LEFT
			fake.button.x, fake.button.y = x, y
			fake.button.clicks = clicks
			handle_event(app, &fake)
			// microui sees a click over two frames: draw one between.
			pump(app)
		}
		fake = {}
		fake.type = .MOUSE_BUTTON_UP
		fake.button.button = sdl.BUTTON_LEFT
		fake.button.x, fake.button.y = x, y
		handle_event(app, &fake)
		pump(app)
	case "rclick":
		x, _ := strconv.parse_f32(words[1])
		y, _ := strconv.parse_f32(words[2])
		fake: sdl.Event
		fake.type = .MOUSE_MOTION
		fake.motion.x, fake.motion.y = x, y
		handle_event(app, &fake)
		app.need_draw = true
		pump(app)
		fake = {}
		fake.type = .MOUSE_BUTTON_DOWN
		fake.button.button = sdl.BUTTON_RIGHT
		fake.button.x, fake.button.y = x, y
		handle_event(app, &fake)
		pump(app)
		fake = {}
		fake.type = .MOUSE_BUTTON_UP
		fake.button.button = sdl.BUTTON_RIGHT
		fake.button.x, fake.button.y = x, y
		handle_event(app, &fake)
		pump(app)
	case "wheel":
		x, _ := strconv.parse_f32(words[1])
		y, _ := strconv.parse_f32(words[2])
		dy, _ := strconv.parse_f32(words[3])
		mod: sdl.Keymod
		for m in words[4:] {
			switch m {
			case "ctrl":
				mod += {.LCTRL}
			case "shift":
				mod += {.LSHIFT}
			case "cmd":
				mod += {.LGUI}
			}
		}
		sdl.SetModState(mod)
		defer sdl.SetModState({})
		fake: sdl.Event
		fake.type = .MOUSE_WHEEL
		fake.wheel.mouse_x, fake.wheel.mouse_y = x, y
		fake.wheel.y = dy
		handle_event(app, &fake)
	case "resize":
		w, _ := strconv.parse_int(words[1])
		h, _ := strconv.parse_int(words[2])
		_ = sdl.SetWindowSize(app.window, i32(w), i32(h))
	case "reconnect":
		reconnect(app)
	case "quit":
		app.quit = true
	}
	return true
}
