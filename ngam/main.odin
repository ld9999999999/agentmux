package ngam

// ngam ("endgame", neovim-graphical-agentmux) is a native GUI client for agentmux. It runs
// `agentmux serve <session>` (on this machine, or through ssh), shows the
// session's nvim in an SDL3 window with a side panel, and sends it the
// keyboard and mouse. With no session on the command line it opens the
// setup screen. See docs/gui-protocol.md in the agentmux repo for the
// protocol for how it is built and how it works.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import mu "vendor:microui"
import sdl "vendor:sdl3"

USAGE :: `usage: ngam [options] [session]

Without a session, ngam reopens the windows from its last run if the
settings ask for it, or else starts at the setup screen (Cmd-, opens it
later).

options:
  -new               start at the setup screen, to pick or create a session,
                     without reopening the last windows
  -host host         serve the session from this ssh host (default: the
                     host in the settings; "" or "local" for this machine)
  -serve "cmd ..."   the command that serves a session; the session name
                     is added at the end. Overrides -host and the settings.
  -font path         a .ttf or .ttc font for this run
  -size points       the font size for this run
  -option-as-meta    on macOS, Option+key sends <M-key> instead of typing
                     a character such as "å"
  -window x,y,w,h[,max]  the window's place and size in points, and
                     whether it is maximized (used to restore windows)
`

App :: struct {
	ctx:         runtime.Context, // for SDL's event watch callback
	window:      ^sdl.Window,
	rd:          Renderer,
	font:        Font, // the editor font
	font_spec:   Font_Spec,
	font_size:   f32,
	ui:          Ui,
	density:     f32, // pixels per point
	settings:    Settings,
	dark:        bool, // the theme in use
	wake_event:  u32, // serve's frames or a preview fetch are waiting
	settings_event: u32, // the macOS menu's Settings… was chosen

	// The open session. link is set only while a session is open.
	grid:        Grid,
	rpc:         Rpc,
	link:        ^Link,
	session:     Session,
	host:        string, // the host the session is served from; "" is this machine
	cli_session: bool, // opened from the command line: quit when it ends
	editor_up:   bool, // the session's editor started, so its end is a quit
	window_record: Window_Record, // this window's last saved record (windows.odin)
	serve_cmd:   string, // -serve or $NGAM_SERVE, if given

	input:       Input,
	frames:      [dynamic]Frame,
	focused:     bool,
	mouse:       [2]i32, // in window pixels
	click_mods:  sdl.Keymod, // modifiers at the last mouse press
	click_count: int, // 2 for the second press of a double click
	editor_btn:  string, // the mouse button held in the editor, or ""
	editor_cell: [3]int, // the cell it was last reported at (grid, row, col)
	drawing:     bool, // inside pump; the event watch must not re-enter
	need_draw:   bool,
	quit:        bool,
	toast:       string, // a short message at the bottom of the window
	toast_until: time.Tick,

	setup_open:  bool,
	setup:       Setup,
	panel:       Panel,
	explorer:    Explorer,
	git:         Git_View,
	sessions:    Sessions_View,
	menu:        Menu, // the side panel's right-click menu
	quick:       Quick_Open,
	preview:     Preview_Server,
	agent:       Agent,
	editbar:     Editbar, // the toolbar above the editor, and the blame card
	focus:       Focus, // which pane gets the keyboard
	ext:         Ext_Ui, // the natively drawn command line, messages, tabs
}

Session :: struct {
	id, name, cwd, agent: string,
}

Control :: struct {
	type:    string,
	id:      string,
	name:    string,
	cwd:     string,
	agent:   string, // session: the agent's kind, such as "claude"
	state:   string,
	reason:  string,
	message: string,
	exit:    string, // agent closed: how the agent exited, if it did
}

main :: proc() {
	// ssh runs ngam as its askpass helper; see askpass.odin.
	if sock := os.get_env(ASKPASS_ENV, context.temp_allocator); sock != "" {
		os.exit(askpass_client(sock))
	}
	app := new(App)
	app.ctx = context
	app.settings = settings_load()
	app.input.alt_is_meta = ODIN_OS != .Darwin
	app.serve_cmd = os.get_env("NGAM_SERVE", context.allocator)
	app.font_size = app.settings.font_size
	font_path := ""
	session := ""
	host := app.settings.host
	place: Window_Record
	has_place := false
	fresh := false // -new
	host_given := false
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		has_value := i + 1 < len(args)
		switch {
		case a == "-serve" && has_value:
			i += 1
			app.serve_cmd = args[i]
		case a == "-host" && has_value:
			i += 1
			host = args[i] == "local" ? "" : args[i]
			host_given = true
		case a == "-font" && has_value:
			i += 1
			font_path = args[i]
		case a == "-size" && has_value:
			i += 1
			size, ok := strconv.parse_f32(args[i])
			if !ok || size <= 0 {
				fmt.eprintln("ngam: bad -size", args[i])
				os.exit(2)
			}
			app.font_size = size
		case a == "-window" && has_value:
			i += 1
			p, ok := parse_window_spec(args[i])
			if !ok {
				fmt.eprintln("ngam: bad -window", args[i])
				os.exit(2)
			}
			place, has_place = p, true
		case a == "-new":
			fresh = true
		case a == "-option-as-meta":
			app.input.alt_is_meta = true
		case a == "-h" || a == "-help" || a == "--help":
			fmt.print(USAGE)
			os.exit(0)
		case strings.has_prefix(a, "-") || session != "":
			fmt.eprint(USAGE)
			os.exit(2)
		case:
			session = a
		}
	}
	if fresh && session != "" {
		fmt.eprintln("ngam: -new starts without a session; leave out", session)
		os.exit(2)
	}
	if font_path != "" {
		spec, ok := font_spec_from_file(font_path)
		if !ok {
			os.exit(2)
		}
		app.font_spec = spec
	} else {
		app.font_spec = settings_font_spec(&app.settings)
	}

	signals_block()
	if !sdl.Init({.VIDEO}) {
		fmt.eprintln("ngam: SDL_Init:", sdl.GetError())
		os.exit(1)
	}
	signals_watch()
	app.wake_event = sdl.RegisterEvents(1)
	jobs_init()
	askpass_init()
	if !sdl.CreateWindowAndRenderer("ngam", 1200, 760, {.RESIZABLE, .HIGH_PIXEL_DENSITY, .HIDDEN}, &app.window, &app.rd.r) {
		fmt.eprintln("ngam: cannot open a window:", sdl.GetError())
		os.exit(1)
	}
	set_app_icon(app.window)
	_ = sdl.SetRenderVSync(app.rd.r, 1)
	app.settings_event = sdl.RegisterEvents(1)
	mac_menu_init(app.settings_event)
	app.density = sdl.GetWindowPixelDensity(app.window)
	if !load_editor_font(app) {
		os.exit(1)
	}
	ui_init(&app.ui)
	ui_load_fonts(&app.ui, app.rd.r, app.density)
	apply_theme(app)
	grid_init(&app.grid)
	panel_init(app)
	agent_init(app)
	if sc, ok := parse_shortcut(app.settings.agent_focus_key); ok {
		app.input.focus_key = sc
	} else if app.settings.agent_focus_key != "" {
		fmt.eprintln("ngam: ignoring the agent_focus_key setting:", app.settings.agent_focus_key)
	}
	setup_init(app)
	preview_apply(app)
	// Started with no session: reopen the windows that were open when ngam
	// last quit, if the settings ask for it. This window takes the first.
	if session == "" && app.serve_cmd == "" && app.settings.restore_sessions && !fresh {
		if r, ok := windows_restore(app); ok {
			session, host = strings.clone(r.session), strings.clone(r.host)
			place, has_place = r, true
		}
	}
	if has_place {
		window_place(app, place)
	}
	_ = sdl.ShowWindow(app.window)
	if has_place && place.maximized {
		_ = sdl.MaximizeWindow(app.window)
	}
	_ = sdl.StartTextInput(app.window)
	app.focused = .INPUT_FOCUS in sdl.GetWindowFlags(app.window)
	_ = sdl.AddEventWatch(live_resize_watch, app)
	test_script_start()

	if session != "" {
		app.cli_session = true
		if !open_session(app, host, session) {
			setup_show(app) // with the reason in its status
		}
	} else {
		if host_given {
			// -new -host H: list H's sessions.
			field_set(&app.setup.host, host)
		}
		setup_show(app)
	}
	app.need_draw = true

	for !app.quit {
		ev: sdl.Event
		timeout := loop_timeout(app)
		got := timeout < 0 ? sdl.WaitEvent(&ev) : sdl.WaitEventTimeout(&ev, timeout)
		if got {
			handle_event(app, &ev)
			for !app.quit && sdl.PollEvent(&ev) {
				handle_event(app, &ev)
			}
		}
		panel_tick(app)
		if app.toast != "" && time.tick_since(app.toast_until) >= 0 {
			delete(app.toast)
			app.toast = ""
			app.need_draw = true
		}
		pump(app)
		free_all(context.temp_allocator)
	}

	// Record when this window closed, so a restore can bring it back with
	// the other windows that close at about the same time. Then closing
	// serve's stdin ends the session's editor: serve has nvim save its
	// snapshot, then nvim and serve exit. The agent keeps running in its
	// holder.
	window_record_save(app, force = true)
	_ = sdl.HideWindow(app.window)
	code := 0
	if app.link != nil {
		code = close_session(app)
	}
	preview_stop(&app.preview)
	sdl.RemoveEventWatch(live_resize_watch, app)
	sdl.Quit()
	askpass_stop()
	// If serve failed (for example, the session is missing), ngam exits
	// with its code.
	os.exit(code)
}

// load_editor_font loads the editor font at the current size and density.
// If that fails, it loads the default font.
load_editor_font :: proc(app: ^App) -> bool {
	font_destroy(&app.font)
	if !font_load(&app.font, app.font_spec, app.font_size, app.density) {
		font_destroy(&app.font)
		spec, _ := font_spec_from_file(DEFAULT_FONT)
		if !font_load(&app.font, spec, app.font_size, app.density) {
			return false
		}
	}
	atlas_reset(&app.font, app.rd.r)
	return true
}

// apply_theme sets ngam's colors from the settings, or from the system's
// theme, and nvim's 'background' to match.
apply_theme :: proc(app: ^App) {
	dark: bool
	switch app.settings.theme {
	case "light":
		dark = false
	case "dark":
		dark = true
	case:
		dark = sdl.GetSystemTheme() == .DARK
	}
	app.dark = dark
	ui_set_theme(&app.ui, dark)
	nvim_set_background(app, dark)
	app.need_draw = true
}

// show_toast shows msg at the bottom of the window for a few seconds.
show_toast :: proc(app: ^App, msg: string) {
	delete(app.toast)
	app.toast = strings.clone(msg)
	app.toast_until = time.tick_add(time.tick_now(), 4 * time.Second)
	app.need_draw = true
}

// ---- Sessions ----

// serve_command is the command that serves session from host.
serve_command :: proc(app: ^App, host, session: string) -> []string {
	cmd := make([dynamic]string, context.temp_allocator)
	switch {
	case app.serve_cmd != "":
		// Split on spaces only. Quote marks are plain characters here.
		append(&cmd, ..strings.fields(app.serve_cmd, context.temp_allocator))
	case host != "":
		append(&cmd, ..ssh_command(app, host))
		append(&cmd, "serve")
	case:
		append(&cmd, ..strings.fields(app.settings.agentmux, context.temp_allocator))
		append(&cmd, "serve")
	}
	append(&cmd, session)
	return cmd[:]
}

// ssh_command is the start of a command that runs agentmux on host. ssh
// asks for passphrases and passwords through ngam's own dialog.
ssh_command :: proc(app: ^App, host: string) -> []string {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, ..askpass_ssh_command())
	append(&cmd, "-o", "ConnectTimeout=10", host)
	append(&cmd, app.settings.remote_agentmux)
	return cmd[:]
}

// open_session ends the open session, if any, and serves session from
// host.
open_session :: proc(app: ^App, host, session: string) -> bool {
	if app.link != nil {
		close_session(app)
	}
	l := new(Link)
	if !link_start(l, serve_command(app, host, session), app.wake_event) {
		free(l)
		setup_set_status(app, fmt.tprintf("Cannot start agentmux serve for %s.", session))
		return false
	}
	app.link = l
	app.editor_up = false
	delete(app.host)
	app.host = strings.clone(host)
	grid_clear_all(&app.grid)
	_ = sdl.SetWindowTitle(app.window, fmt.ctprintf("ngam: %s", session))
	app.setup_open = false
	app.need_draw = true
	return true
}

// close_session closes serve's stdin and waits for it to exit, which
// saves the session's snapshot. It returns serve's exit code.
close_session :: proc(app: ^App) -> int {
	l := app.link
	app.link = nil
	link_close(l)
	code := link_wait(l)
	link_destroy(l)
	free(l)
	rpc_reset(app)
	grid_clear_all(&app.grid)
	delete(app.session.id)
	delete(app.session.name)
	delete(app.session.cwd)
	delete(app.session.agent)
	app.session = {}
	preview_set_root(&app.preview, "")
	explorer_reset(&app.explorer)
	git_reset(&app.git)
	agent_session_closed(app)
	app.editor_btn = ""
	_ = sdl.SetWindowTitle(app.window, "ngam")
	app.need_draw = true
	return code
}

// session_ended handles serve exiting by itself: after :qa, or a failure.
session_ended :: proc(app: ^App) {
	window_record_drop(app) // its session ended, so a restore skips this window
	code := close_session(app)
	// A session from the command line quits ngam when its editor closes.
	// If the editor never started (nvim is missing, say), ngam stays on the
	// setup screen to show why.
	if app.cli_session && app.editor_up {
		os.exit(code)
	}
	app.cli_session = false
	if app.setup.status == "" {
		setup_set_status(app, code == 0 ? "The session's editor closed." : "agentmux serve failed; its message is in ngam's terminal output.")
	}
	setup_show(app)
}

// settings_toggle opens the setup screen at its Settings tab. If that tab
// is already shown and a session is open, it closes the screen instead.
// Cmd-,, the macOS menu's Settings… and the activity bar's gear call it.
settings_toggle :: proc(app: ^App) {
	if app.setup_open && app.setup.tab == .Settings && app.link != nil {
		app.setup_open = false
	} else {
		app.quick.open = false
		app.menu.open = false
		setup_show(app, .Settings)
	}
	app.need_draw = true
}

// ---- Events ----

handle_event :: proc(app: ^App, ev: ^sdl.Event) {
	if u32(ev.type) == app.wake_event {
		return // frames or fetches are waiting; pump handles them
	}
	if u32(ev.type) == app.settings_event {
		settings_toggle(app)
		return
	}
	if u32(ev.type) == job_event {
		j := (^Job)(ev.user.data1)
		job_done(app, j)
		job_free(j)
		app.need_draw = true
		return
	}
	if askpass_handle_event(app, ev) {
		return
	}
	if test_script_event(app, ev) {
		return
	}
	ctx := &app.ui.ctx
	#partial switch ev.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		app.quit = true
	case .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_DISPLAY_SCALE_CHANGED:
		on_resize(app)
	case .WINDOW_EXPOSED:
		app.need_draw = true
	case .WINDOW_MOVED, .WINDOW_RESIZED, .WINDOW_MAXIMIZED, .WINDOW_RESTORED:
		window_record_save(app)
	case .SYSTEM_THEME_CHANGED:
		apply_theme(app)
	case .WINDOW_FOCUS_GAINED, .WINDOW_FOCUS_LOST:
		app.focused = ev.type == .WINDOW_FOCUS_GAINED
		nvim_ui_set_focus(app, app.focused)
		if app.focused {
			panel_focus_gained(app)
		}
		app.need_draw = true
	case .MOUSE_MOTION:
		app.mouse = {i32(ev.motion.x * app.density), i32(ev.motion.y * app.density)}
		mu.input_mouse_move(ctx, app.mouse.x, app.mouse.y)
		if agent_button_hover(app) {
			app.need_draw = true
		}
		if editbar_hover(app) {
			app.need_draw = true
		}
		if panel_mouse_move(app) || agent_mouse_move(app) {
			return
		}
		if app.editor_btn != "" {
			editor_mouse(app, app.editor_btn, "drag")
		} else if app.setup_open || app.mouse.x < editor_x(app) || ctx.mouse_down_bits != {} || ctx.hover_id != 0 {
			app.need_draw = true // hover effects
		}
	case .MOUSE_BUTTON_DOWN:
		app.mouse = {i32(ev.button.x * app.density), i32(ev.button.y * app.density)}
		app.click_mods = sdl.GetModState()
		app.click_count = int(ev.button.clicks)
		if askpass_open() || ((app.menu.open || app.quick.open) && !app.setup_open) {
			// The menu or quick open takes the click; one outside closes it.
			if b, ok := ui_mouse_button(ev.button.button); ok {
				ui_frame_now(app)
				mu.input_mouse_down(ctx, app.mouse.x, app.mouse.y, b)
			}
			app.need_draw = true
			return
		}
		if ev.button.button == sdl.BUTTON_LEFT && agent_button_click(app) {
			return
		}
		if editbar_mouse_down(app, ev.button.button == sdl.BUTTON_LEFT) {
			return
		}
		if panel_mouse_down(app) || agent_mouse_down(app, ev.button.button) {
			return
		}
		if !app.setup_open && app.link != nil && app.mouse.x >= editor_x(app) {
			app.focus = .Editor
			app.need_draw = true
			if ext_mouse_down(app, ev.button.button) {
				return
			}
			if name := mouse_button_name(ev.button.button); name != "" {
				app.editor_btn = name
				editor_mouse(app, name, "press")
			}
			return
		}
		if b, ok := ui_mouse_button(ev.button.button); ok {
			// microui works out what is under the mouse while it builds a
			// frame, so build one at the new position first.
			ui_frame_now(app)
			mu.input_mouse_down(ctx, app.mouse.x, app.mouse.y, b)
		}
		app.need_draw = true
	case .MOUSE_BUTTON_UP:
		app.mouse = {i32(ev.button.x * app.density), i32(ev.button.y * app.density)}
		if panel_mouse_up(app) || agent_mouse_up(app, ev.button.button) {
			return
		}
		if app.editor_btn != "" {
			editor_mouse(app, app.editor_btn, "release")
			app.editor_btn = ""
		}
		if b, ok := ui_mouse_button(ev.button.button); ok {
			mu.input_mouse_up(ctx, app.mouse.x, app.mouse.y, b)
		}
		app.need_draw = true
	case .MOUSE_WHEEL:
		mx := i32(ev.wheel.mouse_x * app.density)
		if askpass_open() {
			return
		}
		if app.quick.open && !app.setup_open {
			quick_open_wheel(app, ev.wheel.y)
			return
		}
		if blame_detail_wheel(app, {mx, i32(ev.wheel.mouse_y * app.density)}, ev.wheel.y) {
			return
		}
		if agent_over(app, mx) {
			app.mouse = {mx, i32(ev.wheel.mouse_y * app.density)}
			agent_wheel(app, ev.wheel.y)
			return
		}
		if !app.setup_open && app.link != nil && mx >= editor_x(app) {
			app.mouse = {mx, i32(ev.wheel.mouse_y * app.density)}
			if !ext_wheel(app, ev.wheel.y) {
				editor_wheel(app, ev.wheel.y)
			}
			return
		}
		// microui scrolls the area under the mouse, so it must know where
		// that is, even when the wheel turns before any mouse motion.
		mu.input_mouse_move(ctx, mx, i32(ev.wheel.mouse_y * app.density))
		mu.input_scroll(ctx, 0, i32(-ev.wheel.y * 30 * app.density))
		app.need_draw = true
	case .KEY_DOWN:
		keys, action := key_down(&app.input, ev.key)
		if askpass_open() {
			// The dialog takes every key while ssh waits for an answer.
			app.input.suppress_text = app.input.suppress_text || action != .None
			askpass_key(app, ev.key, action)
			return
		}
		switch action {
		case .Setup:
			settings_toggle(app)
			return
		case .Toggle_Panel:
			if !app.setup_open {
				panel_toggle(app)
			}
			return
		case .View:
			if !app.setup_open {
				panel_show_key(app, app.input.view_key)
			}
			return
		case .Switch_Focus:
			if !app.setup_open {
				agent_switch_focus(app)
			}
			return
		case .Font_Bigger, .Font_Smaller, .Font_Reset:
			font_size_step(app, action == .Font_Bigger ? 1 : action == .Font_Smaller ? -1 : 0)
			return
		case .Quick_Open:
			if app.quick.open {
				quick_open_close(app)
			} else {
				quick_open_show(app)
			}
			return
		case .None, .Paste, .Copy:
		}
		if !app.setup_open && !agent_has_focus(app) && blame_detail_key(app, ev.key.key) {
			app.input.suppress_text = true
			return
		}
		if app.quick.open && !app.setup_open {
			quick_open_key(app, ev.key, action)
			return
		}
		if app.menu.open && ev.key.key == sdl.K_ESCAPE {
			menu_close(app)
			return
		}
		if app.setup_open {
			if ev.key.key == sdl.K_ESCAPE && app.link != nil {
				app.setup_open = false
			} else if k, ok := ui_key(ev.key.key); ok {
				mu.input_key_down(ctx, k)
				// microui sees keys only while it builds a frame. Build
				// one now, before a quick key release (Cmd let go right
				// after Cmd-A) clears what is held.
				ui_frame_now(app)
			}
			app.need_draw = true
			return
		}
		if agent_has_focus(app) {
			#partial switch action {
			case .None:
				agent_key_down(app, ev.key)
			case .Paste:
				agent_paste(app, clipboard_get())
			case .Copy:
				agent_copy(app)
			}
			return
		}
		if ext_key_down(app, ev.key) {
			app.input.suppress_text = true // drop the text the key would type
			return
		}
		switch action {
		case .None:
			nvim_input(app, keys)
		case .Paste:
			nvim_paste(app, clipboard_get())
		case .Copy:
			// Copy only a visual selection. Do not send the key to nvim:
			// nvim runs an unmapped <D-c> as "c".
			if app.grid.visual {
				nvim_input(app, "\"+y")
			}
		case .Setup, .Toggle_Panel, .View, .Switch_Focus, .Quick_Open, .Font_Bigger, .Font_Smaller, .Font_Reset:
		}
	case .KEY_UP:
		if k, ok := ui_key(ev.key.key); ok {
			mu.input_key_up(ctx, k)
		}
	case .TEXT_INPUT:
		text := string(ev.text.text)
		if askpass_open() {
			if !app.input.suppress_text {
				askpass_type(text)
			}
			app.input.suppress_text = false
			app.need_draw = true
		} else if app.quick.open && !app.setup_open {
			if !app.input.suppress_text {
				quick_open_text(app, text)
			}
			app.input.suppress_text = false
		} else if app.setup_open {
			// A shortcut such as Cmd-V must not type its letter too.
			if !app.input.suppress_text {
				mu.input_text(ctx, text)
			}
			app.input.suppress_text = false
			app.need_draw = true
		} else if agent_has_focus(app) {
			agent_text(app, text)
		} else {
			nvim_input(app, text_input(&app.input, text))
		}
	}
}

// ui_frame_now builds and draws a frame at once. It does nothing while a
// frame is already being drawn.
ui_frame_now :: proc(app: ^App) {
	if !app.drawing {
		app.need_draw = true
		pump(app)
	}
}

mouse_button_name :: proc(b: u8) -> string {
	switch b {
	case sdl.BUTTON_LEFT:
		return "left"
	case sdl.BUTTON_RIGHT:
		return "right"
	case sdl.BUTTON_MIDDLE:
		return "middle"
	}
	return ""
}

// mouse_cell is the grid and cell under the mouse: the topmost shown grid
// there that takes the mouse (a float can turn the mouse off). For a drag
// that started on from_grid, the cell is on that grid, kept inside it.
mouse_cell :: proc(app: ^App, from_grid := -1) -> (grid, row, col: int) {
	area := app_editor_rect(app)
	cw, ch := max(app.font.cell_w, 1), max(app.font.cell_h, 1)
	p := app.mouse
	order := grid_draw_order(&app.grid)
	#reverse for w in order {
		if from_grid >= 0 ? w.id != from_grid : !w.mouse {
			continue
		}
		x, y, shown := win_origin(&app.font, &app.grid, w, area.x, area.y)
		if !shown {
			continue
		}
		inside := p.x >= x && p.y >= y && p.x < x + i32(w.cols) * cw && p.y < y + i32(w.rows) * ch
		if inside || from_grid >= 0 {
			row = clamp(int((p.y - y) / ch), 0, max(w.rows - 1, 0))
			col = clamp(int((p.x - x) / cw), 0, max(w.cols - 1, 0))
			// With ext_multigrid off, nvim expects grid 0 for the screen.
			return app.ext.on ? w.id : 0, row, col
		}
	}
	return 0, clamp(int((p.y - area.y) / ch), 0, 1 << 16), clamp(int((p.x - area.x) / cw), 0, 1 << 16)
}

// mouse_mods is the modifier string nvim_input_mouse takes, such as "CS".
mouse_mods :: proc() -> string {
	m := sdl.GetModState()
	b := strings.builder_make(context.temp_allocator)
	if m & sdl.KMOD_CTRL != {} {strings.write_byte(&b, 'C')}
	if m & sdl.KMOD_SHIFT != {} {strings.write_byte(&b, 'S')}
	if m & sdl.KMOD_ALT != {} {strings.write_byte(&b, 'A')}
	if m & sdl.KMOD_GUI != {} {strings.write_byte(&b, 'D')}
	return strings.to_string(b)
}

// editor_mouse sends a mouse press, drag or release in the editor. Drags
// are sent only when the mouse moves to another cell.
editor_mouse :: proc(app: ^App, button, action: string) {
	// A drag or release goes to the grid the press was on.
	from := action == "press" ? -1 : (app.ext.on ? app.editor_cell[0] : -1)
	grid, row, col := mouse_cell(app, from)
	if action == "drag" && app.editor_cell == {grid, row, col} {
		return
	}
	app.editor_cell = {grid, row, col}
	nvim_input_mouse(app, button, action, mouse_mods(), grid, row, col)
}

// editor_wheel scrolls the editor, one wheel event per notch.
editor_wheel :: proc(app: ^App, dy: f32) {
	grid, row, col := mouse_cell(app)
	n := clamp(int(abs(dy) + 0.5), 1, 10)
	for _ in 0 ..< n {
		nvim_input_mouse(app, "wheel", dy > 0 ? "up" : "down", mouse_mods(), grid, row, col)
	}
}

// loop_timeout is how long the main loop may sleep, in ms, or -1 for
// until the next event.
loop_timeout :: proc(app: ^App) -> i32 {
	if askpass_open() && app.need_draw {
		return 0 // the dialog fits itself to its text a frame late
	}
	if panel_animating(app) || grid_animating(&app.grid) {
		app.need_draw = true
		return 8
	}
	t := panel_poll_timeout(app)
	if app.toast != "" {
		left := i32(-time.duration_milliseconds(time.tick_since(app.toast_until))) + 1
		t = t < 0 ? max(left, 1) : min(t, max(left, 1))
	}
	if d := ext_deadline(app); d >= 0 {
		app.need_draw = true // a toast goes when its time is up
		t = t < 0 ? d : min(t, d)
	}
	return t
}

// pump handles the frames that arrived from serve and the preview
// server's fetches, then draws a frame if anything changed.
pump :: proc(app: ^App) {
	app.drawing = true
	defer app.drawing = false
	if app.link != nil {
		clear(&app.frames)
		link_take(app.link, &app.frames)
		ended := false
		for f in app.frames {
			if f.eof {
				ended = true // serve exited: after "bye", or because it failed
				continue
			}
			switch f.type {
			case FRAME_CONTROL:
				handle_control(app, f.payload)
			case FRAME_NVIM:
				if app.rpc.attached {
					rpc_feed(app, f.payload)
				}
			case FRAME_AGENT:
				agent_feed(app, f.payload)
			}
			delete(f.payload)
		}
		if ended {
			session_ended(app)
		}
	}
	preview_pump(app)
	if (app.grid.dirty || app.need_draw) && !app.quit {
		app.grid.dirty = false
		app.need_draw = false
		redraw(app)
	}
}

handle_control :: proc(app: ^App, payload: []byte) {
	c: Control
	if err := json.unmarshal(payload, &c, allocator = context.temp_allocator); err != nil {
		fmt.eprintln("ngam: bad control message:", string(payload))
		return
	}
	switch c.type {
	case "session":
		// A new nvim: start a new RPC session and attach to it. nvim runs
		// its startup only after a UI attaches.
		rpc_reset(app)
		grid_clear_all(&app.grid)
		delete(app.session.id)
		delete(app.session.name)
		delete(app.session.cwd)
		delete(app.session.agent)
		app.session = {strings.clone(c.id), strings.clone(c.name), strings.clone(c.cwd), strings.clone(c.agent)}
		ext_reset(app)
		preview_set_root(&app.preview, c.cwd)
		_ = sdl.SetWindowTitle(app.window, fmt.ctprintf("ngam: %s", c.name))
		cols, rows := grid_size(app)
		nvim_ui_attach(app, cols, rows)
		nvim_set_client_info(app)
		preview_session_started(app) // the file watchers
		nvim_set_background(app, app.dark)
		explorer_reset(&app.explorer)
		app.editor_up = true
		ext_session_started(app) // 'cmdheight' stays 0
		buffers_session_started(app) // after the reset, which empties the list
		editbar_session_started(app) // change bars and blame
		git_reset(&app.git)
		sessions_reset(&app.sessions)
		panel_session_started(app)
		agent_sync_size(app)
		setup_set_status(app, "")
		window_record_save(app, force = true)
	case "editor_exit":
		// nvim quit. Another session may follow, or bye.
		rpc_reset(app)
	case "agent":
		agent_control(app, c.state, c.reason, c.exit)
	case "error":
		fmt.eprintln("ngam: serve:", c.message)
		setup_set_status(app, c.message)
	case "bye":
	}
}

// ---- Layout and drawing ----

// editor_x is where the editor starts: right of the activity bar and the
// side panel.
editor_x :: proc(app: ^App) -> i32 {
	return bar_width(app) + panel_visible_width(app)
}

// grid_size is how many cells fit in the editor's part of the window once
// the panel is where it is heading.
grid_size :: proc(app: ^App) -> (cols, rows: int) {
	w, h: i32
	_ = sdl.GetWindowSizeInPixels(app.window, &w, &h)
	pad := editor_pad(app)
	w -= bar_width(app) + panel_target_width(app) + agent_pane_px(app) + 2 * pad
	h -= editbar_h(app) + ext_tabline_h(app) + ext_status_h(app) + 2 * pad
	cols = max(1, int(w / max(app.font.cell_w, 1)))
	rows = max(1, int(h / max(app.font.cell_h, 1)))
	return
}

EDITOR_PAD_PT :: 3 // space around nvim's grid, so text keeps clear of the edges

editor_pad :: proc(app: ^App) -> i32 {
	return i32(EDITOR_PAD_PT * app.density)
}

// app_editor_rect is where nvim's grid is drawn, in window pixels: right
// of the side panel, left of the agent pane, and between the tab strip and
// the status strip when ngam draws those, inside editor_pad. The pixels
// left over below a whole row go above the grid, where they show as
// nvim's background, so the status strip stays one line tall.
app_editor_rect :: proc(app: ^App) -> sdl.Rect {
	r := editor_frame_rect(app)
	pad := editor_pad(app)
	_, rows := grid_size(app)
	h := i32(rows) * app.font.cell_h
	return {r.x + pad, r.y + r.h - pad - h, r.w - 2 * pad, h}
}

// editor_frame_rect is the editor's part of the window between the tab
// strip and the status strip, padding included.
editor_frame_rect :: proc(app: ^App) -> sdl.Rect {
	x := editor_x(app)
	top := editbar_h(app) + ext_tabline_h(app)
	_, wh := window_pixels(app)
	return {x, top, agent_left(app) - x, max(wh - ext_status_h(app) - top, 0)}
}

// resize_editor asks nvim to fit the editor's part of the window.
resize_editor :: proc(app: ^App) {
	cols, rows := grid_size(app)
	nvim_ui_try_resize(app, cols, rows)
	agent_sync_size(app)
	app.need_draw = true
}

on_resize :: proc(app: ^App) {
	// On a display with another pixel density, the fonts must be drawn
	// again at the new size.
	if d := sdl.GetWindowPixelDensity(app.window); d != app.density && d > 0 {
		app.density = d
		_ = load_editor_font(app)
		ui_load_fonts(&app.ui, app.rd.r, d)
	}
	panel_clamp_width(app)
	resize_editor(app)
}

// fixed_window starts a microui window that ngam places itself each frame,
// above the windows with a lower z.
fixed_window :: proc(ctx: ^mu.Context, name: string, r: mu.Rect, opt: mu.Options, z: i32) -> bool {
	cnt := mu.get_container(ctx, name, opt)
	cnt.rect = r
	cnt.zindex = z
	return mu.begin_window(ctx, name, r, opt)
}

Z_BAR :: 1 << 20
Z_TOAST :: Z_BAR + 1
Z_OVERLAY :: Z_BAR + 2
Z_SETUP :: Z_BAR + 3
Z_ASK :: Z_BAR + 5 // ssh's questions, above everything; Z_ASK - 1 dims the rest

// redraw builds the UI for this frame and draws everything.
redraw :: proc(app: ^App) {
	w, h: i32
	_ = sdl.GetWindowSizeInPixels(app.window, &w, &h)
	ctx := &app.ui.ctx
	mu.begin(ctx)
	if app.link != nil {
		panel_frame(app)
		agent_header_frame(app)
		editbar_frame(app)
		menu_frame(app)
		quick_open_frame(app)
	}
	if app.toast != "" {
		toast_frame(app, w, h)
	}
	if app.setup_open {
		setup_frame(app)
	}
	askpass_frame(app)
	mu.end(ctx)

	rd := &app.rd
	// When a glyph finds its atlas full, start that atlas over and draw the
	// frame again.
	for _ in 0 ..< 2 {
		bg := app.link != nil ? rgb_color(app.grid.default_bg) : ui_color(app.ui.ctx.style.colors[.PANEL_BG])
		_ = sdl.SetRenderDrawColorFloat(rd.r, bg.r, bg.g, bg.b, 1)
		_ = sdl.RenderClear(rd.r)
		if app.link != nil {
			area := app_editor_rect(app)
			draw_screen(rd, &app.font, &app.grid, app.focused && !app.setup_open && !agent_has_focus(app) && cmdline_hidden(app), area.x, area.y, area)
			ext_draw(app, area)
			agent_draw(app)
		}
		ui_render(rd, &app.ui)
		flush(rd)
		if !app.font.full && !app.ui.font.full && !app.ui.icons.full && !app.ui.small.full {
			break
		}
		for f in ([]^Font{&app.font, &app.ui.font, &app.ui.icons, &app.ui.small}) {
			if f.full {
				atlas_reset(f, rd.r)
			}
		}
	}
	_ = sdl.RenderPresent(rd.r)
}

// toast_frame draws the toast message at the bottom right.
toast_frame :: proc(app: ^App, w, h: i32) {
	ctx := &app.ui.ctx
	pad := ctx.style.padding * 2
	tw := text_width(&app.ui.font, app.toast) + pad * 2
	th := app.ui.font.cell_h + pad * 2
	r := mu.Rect{w - tw - pad, h - th - pad, tw, th}
	if fixed_window(ctx, "!toast", r, {.NO_TITLE, .NO_RESIZE, .NO_SCROLL, .NO_CLOSE, .NO_INTERACT}, Z_TOAST) {
		mu.draw_rect(ctx, r, app.ui.colors.accent)
		mu.draw_text(ctx, mu.Font(&app.ui.font), app.toast, {r.x + pad, r.y + pad}, {255, 255, 255, 255})
		mu.end_window(ctx)
	}
}

window_pixels :: proc(app: ^App) -> (w, h: i32) {
	_ = sdl.GetWindowSizeInPixels(app.window, &w, &h)
	return
}

ui_color :: proc(c: mu.Color) -> sdl.FColor {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, f32(c.a) / 255}
}

// live_resize_watch keeps the window drawn while it is being resized. On
// macOS the main loop is stuck inside SDL_WaitEvent during a live resize,
// and SDL calls event watches directly instead.
live_resize_watch :: proc "c" (userdata: rawptr, ev: ^sdl.Event) -> bool {
	if ev.type != .WINDOW_EXPOSED && ev.type != .WINDOW_PIXEL_SIZE_CHANGED {
		return true
	}
	app := (^App)(userdata)
	if !sdl.IsMainThread() || app.drawing {
		return true
	}
	context = app.ctx
	if ev.type == .WINDOW_PIXEL_SIZE_CHANGED {
		on_resize(app)
	}
	app.need_draw = true
	pump(app)
	return true
}
