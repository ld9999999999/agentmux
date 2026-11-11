package ngam

// The msgpack-RPC session with nvim, carried in N frames. serve starts a
// new nvim for each session, so a "session" control message resets the
// stream and attaches again.

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import mp "msgpack"

// Rpc_Done is called with a request's result. failed is true when nvim
// returned an error or the session ended first; result is then nil. The
// result lives only until the callback returns.
Rpc_Done :: #type proc(app: ^App, result: mp.Value, failed: bool, user: rawptr)

Pending :: struct {
	method: string,
	done:   Rpc_Done,
	user:   rawptr,
}

Rpc :: struct {
	buf:      [dynamic]byte, // N bytes waiting to be decoded
	next_id:  i64,
	pending:  map[i64]Pending, // requests waiting for nvim's answer
	attached: bool, // nvim_ui_attach was sent and nvim is still running
	ui_rows:  int, // the size last asked of nvim
	ui_cols:  int,
}

// rpc_reset starts a new RPC session. Requests still waiting fail.
rpc_reset :: proc(app: ^App) {
	rpc := &app.rpc
	for _, p in rpc.pending {
		if p.done != nil {
			p.done(app, nil, true, p.user)
		}
	}
	clear(&rpc.buf)
	clear(&rpc.pending)
	rpc.next_id = 1
	rpc.attached = false
	rpc.ui_cols, rpc.ui_rows = 0, 0
}

// rpc_request starts a request [0, id, method, params] in out. The caller
// encodes nparams values after it. done, if given, gets the result.
@(private = "file")
rpc_request :: proc(rpc: ^Rpc, out: ^[dynamic]byte, method: string, nparams: int, done: Rpc_Done = nil, user: rawptr = nil) {
	id := rpc.next_id
	rpc.next_id += 1
	rpc.pending[id] = {method, done, user}
	mp.enc_array(out, 4)
	mp.enc_int(out, 0)
	mp.enc_int(out, id)
	mp.enc_str(out, method)
	mp.enc_array(out, nparams)
}

// exec_lua runs Lua code in nvim, with args as `...`, and passes what it
// returns to done. It reaches nvim's machine over the same connection, so
// remote sessions need only serve.
exec_lua :: proc(app: ^App, code: string, args: []mp.Value, done: Rpc_Done = nil, user: rawptr = nil) -> bool {
	if !app.rpc.attached {
		return false
	}
	out := make([dynamic]byte, context.temp_allocator)
	rpc_request(&app.rpc, &out, "nvim_exec_lua", 2, done, user)
	mp.enc_str(&out, code)
	mp.enc_value(&out, args)
	send_nvim(app, out)
	return true
}

// nvim_set_background sets 'background' so colorschemes follow ngam's
// theme. nvim answers with default_colors_set.
nvim_set_background :: proc(app: ^App, dark: bool) {
	if !app.rpc.attached {
		return
	}
	out := make([dynamic]byte, context.temp_allocator)
	rpc_request(&app.rpc, &out, "nvim_set_option_value", 3)
	mp.enc_str(&out, "background")
	mp.enc_str(&out, dark ? "dark" : "light")
	mp.enc_map(&out, 0)
	send_nvim(app, out)
}

@(private = "file")
send_nvim :: proc(app: ^App, out: [dynamic]byte) {
	if app.link != nil {
		link_send(app.link, FRAME_NVIM, out[:])
	}
}

// nvim_ui_attach attaches as nvim's UI. With the native_ui setting on, ngam
// draws windows, the command line, the popup menu, messages and the tab
// line itself (ext.odin); with it off, nvim draws them all on one grid.
nvim_ui_attach :: proc(app: ^App, cols, rows: int) {
	exts := ext_options(app.settings.native_ui)
	app.ext.on = app.settings.native_ui
	app.grid.smooth = app.settings.native_ui && app.settings.smooth_scroll
	out := make([dynamic]byte, context.temp_allocator)
	rpc_request(&app.rpc, &out, "nvim_ui_attach", 3)
	mp.enc_int(&out, i64(cols))
	mp.enc_int(&out, i64(rows))
	mp.enc_map(&out, 2 + len(exts))
	mp.enc_str(&out, "rgb")
	mp.enc_bool(&out, true)
	mp.enc_str(&out, "ext_linegrid")
	mp.enc_bool(&out, true)
	for name in exts {
		mp.enc_str(&out, name)
		mp.enc_bool(&out, true)
	}
	send_nvim(app, out)
	app.rpc.attached = true
	app.rpc.ui_cols, app.rpc.ui_rows = cols, rows
}

// nvim_set_client_info names ngam and lists the requests it answers. The
// agentmux plugin turns the + and * registers into the host's clipboard
// once it sees agentmux_clipboard_get here.
nvim_set_client_info :: proc(app: ^App) {
	out := make([dynamic]byte, context.temp_allocator)
	rpc_request(&app.rpc, &out, "nvim_set_client_info", 5)
	mp.enc_str(&out, "ngam")
	mp.enc_map(&out, 0) // version
	mp.enc_str(&out, "ui")
	mp.enc_map(&out, 1) // methods
	mp.enc_str(&out, "agentmux_clipboard_get")
	mp.enc_map(&out, 0)
	mp.enc_map(&out, 0) // attributes
	send_nvim(app, out)
}

// nvim_paste pastes text as if typed, in any mode (`:help nvim_paste()`).
nvim_paste :: proc(app: ^App, text: string) {
	if !app.rpc.attached || text == "" {
		return
	}
	out := make([dynamic]byte, context.temp_allocator)
	rpc_request(&app.rpc, &out, "nvim_paste", 3)
	mp.enc_str(&out, text)
	mp.enc_bool(&out, true) // crlf: let nvim fix line endings
	mp.enc_int(&out, -1) // the whole paste in one call
	send_nvim(app, out)
}

// nvim_ui_set_focus tells nvim whether ngam's window has focus, so it runs
// FocusGained and FocusLost (agentmux then sends the agent's requests to
// the editor last used, when a terminal has the session open too).
nvim_ui_set_focus :: proc(app: ^App, focused: bool) {
	if !app.rpc.attached {
		return
	}
	out := make([dynamic]byte, context.temp_allocator)
	rpc_request(&app.rpc, &out, "nvim_ui_set_focus", 1)
	mp.enc_bool(&out, focused)
	send_nvim(app, out)
}

nvim_ui_try_resize :: proc(app: ^App, cols, rows: int) {
	if !app.rpc.attached || (cols == app.rpc.ui_cols && rows == app.rpc.ui_rows) {
		return
	}
	out := make([dynamic]byte, context.temp_allocator)
	rpc_request(&app.rpc, &out, "nvim_ui_try_resize", 2)
	mp.enc_int(&out, i64(cols))
	mp.enc_int(&out, i64(rows))
	send_nvim(app, out)
	app.rpc.ui_cols, app.rpc.ui_rows = cols, rows
}

// nvim_ui_detach stops being nvim's UI, before attaching again with other
// options.
nvim_ui_detach :: proc(app: ^App) {
	out := make([dynamic]byte, context.temp_allocator)
	rpc_request(&app.rpc, &out, "nvim_ui_detach", 0)
	send_nvim(app, out)
	app.rpc.attached = false
}

// nvim_input_mouse sends a mouse event at a cell of a grid (0 when
// ext_multigrid is off). nvim acts on it as 'mouse' says.
nvim_input_mouse :: proc(app: ^App, button, action, mods: string, grid, row, col: int) {
	if !app.rpc.attached {
		return
	}
	out := make([dynamic]byte, context.temp_allocator)
	rpc_request(&app.rpc, &out, "nvim_input_mouse", 6)
	mp.enc_str(&out, button)
	mp.enc_str(&out, action)
	mp.enc_str(&out, mods)
	mp.enc_int(&out, i64(grid))
	mp.enc_int(&out, i64(row))
	mp.enc_int(&out, i64(col))
	send_nvim(app, out)
}

nvim_input :: proc(app: ^App, keys: string) {
	if !app.rpc.attached || keys == "" {
		return
	}
	out := make([dynamic]byte, context.temp_allocator)
	rpc_request(&app.rpc, &out, "nvim_input", 1)
	mp.enc_str(&out, keys)
	send_nvim(app, out)
}

// rpc_feed adds N bytes and handles every whole message they complete.
rpc_feed :: proc(app: ^App, data: []byte) {
	rpc := &app.rpc
	append(&rpc.buf, ..data)
	pos := 0
	for pos < len(rpc.buf) {
		// Check that a whole message is there before decoding it, so a
		// large redraw split over frames is decoded only once.
		end := pos
		err := mp.skip(rpc.buf[:], &end)
		if err == .Incomplete {
			break
		}
		if err == .Invalid {
			fmt.eprintln("ngam: bad msgpack from nvim; dropping", len(rpc.buf) - pos, "bytes")
			pos = len(rpc.buf)
			break
		}
		msg: mp.Value
		{
			// Decoded arrays and maps last until the end of the frame.
			context.allocator = context.temp_allocator
			p := pos
			msg, _ = mp.decode(rpc.buf[:end], &p)
		}
		pos = end
		rpc_handle(app, mp.as_array(msg))
	}
	remove_range(&rpc.buf, 0, pos)
}

@(private = "file")
rpc_handle :: proc(app: ^App, msg: []mp.Value) {
	switch mp.as_int(mp.at(msg, 0)) {
	case 0:
		// A request from nvim, which waits for the answer. ngam never
		// waits on nvim, so it can always answer at once.
		out := make([dynamic]byte, context.temp_allocator)
		mp.enc_array(&out, 4)
		mp.enc_int(&out, 1)
		mp.enc_int(&out, mp.as_int(mp.at(msg, 1)))
		switch mp.as_str(mp.at(msg, 2)) {
		case "agentmux_clipboard_get":
			// A paste from + or *: answer with the host's clipboard.
			mp.enc_nil(&out)
			mp.enc_str(&out, clipboard_get())
		case:
			mp.enc_str(&out, "ngam does not handle this request")
			mp.enc_nil(&out)
		}
		send_nvim(app, out)
	case 1:
		id := mp.as_int(mp.at(msg, 1))
		p, ok := app.rpc.pending[id]
		if !ok {
			return
		}
		delete_key(&app.rpc.pending, id)
		err := mp.at(msg, 2)
		if err != nil {
			// nvim's errors are [type, message].
			fmt.eprintfln("ngam: %s failed: %s", p.method, mp.as_str(mp.at(mp.as_array(err), 1)))
		}
		if p.done != nil {
			p.done(app, mp.at(msg, 3), err != nil, p.user)
		}
	case 2:
		switch mp.as_str(mp.at(msg, 1)) {
		case "redraw":
			handle_redraw(app, mp.as_array(mp.at(msg, 2)))
		case "ngam":
			// From ngam's own Lua in nvim (watch.lua).
			params := mp.as_array(mp.at(msg, 2))
			switch mp.as_str(mp.at(params, 0)) {
			case "file_changed":
				preview_file_changed(app, mp.as_str(mp.at(params, 1)))
			case "dir_changed":
				explorer_dir_changed(app, mp.as_str(mp.at(params, 1)))
			case "blame":
				blame_show(app, mp.as_map(mp.at(params, 1)))
			case "blame_hide":
				blame_clear(app)
			case "blame_detail":
				blame_detail_show(app, mp.as_map(mp.at(params, 1)))
			case "buffers":
				buffers_changed(app, mp.as_str(mp.at(params, 1)), mp.as_array(mp.at(params, 2)), mp.as_array(mp.at(params, 3)))
			}
		case "agentmux":
			params := mp.as_array(mp.at(msg, 2))
			switch event := mp.as_str(mp.at(params, 0)); event {
			case "clipboard_set":
				// A yank to + or *: {register, text}.
				for e in mp.as_map(mp.at(params, 1)) {
					if mp.as_str(e.key) == "text" {
						clipboard_set(mp.as_str(e.value))
					}
				}
			case "preview":
				// :AgentPreview: {path}, absolute on nvim's machine.
				path := mp.as_str(mp.map_get(mp.as_map(mp.at(params, 1)), "path"))
				if path != "" {
					preview_open(app, path)
				}
			case "focus_agent":
				// :AgentFocus, and :AgentSend without !
				agent_focus(app)
			case "toggle_agent":
				agent_toggle(app)
			case "focus_editor":
				app.focus = .Editor
				app.need_draw = true
			case "restart_agent":
				agent_restart(app)
			case "ready":
				// nvim's startup is over, and the session restored: the
				// panel's view may have asked too early, or for the
				// folder nvim started in.
				panel_session_started(app)
			case:
				fmt.eprintln("ngam: unknown agentmux event:", event)
			}
		}
	}
}

// clipboard_get returns the host clipboard's text, with Windows line
// endings made Unix ones, since the plugin splits it into lines on "\n".
clipboard_get :: proc() -> string {
	p := sdl.GetClipboardText()
	if p == nil {
		return ""
	}
	// Copy the text before freeing SDL's buffer: replace_all returns its
	// input unchanged when there is nothing to replace.
	text := strings.clone(string(cstring(p)), context.temp_allocator)
	sdl.free(p)
	text, _ = strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	return text
}

clipboard_set :: proc(text: string) {
	if !sdl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator)) {
		fmt.eprintln("ngam: cannot set the clipboard:", sdl.GetError())
	}
}
