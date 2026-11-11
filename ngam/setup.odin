package ngam

// The setup screen: pick or create a session on this machine or an ssh
// host, and set the editor font, the theme and the preview server. It
// shows when ngam starts without a session, and Cmd-, opens it at any
// time. Changes apply at once and are saved in the settings.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import mu "vendor:microui"

// One session from `agentmux ls -json`.
Session_Info :: struct {
	id:          string,
	name:        string,
	agent:       string,
	agent_state: string, // running or stopped
	editor:      string, // where its editors are open: "terminal", "gui", "terminal,gui" or ""
	stashed:     int, // buffers with unsaved changes
	created:     string,
	cwd:         string,
}

Setup :: struct {
	host:        Text_Field,
	listed_host: string, // the host the session list came from
	sessions:    []Session_Info,
	listing:     bool, // agentmux ls is running
	list_error:  string,
	agent:       Text_Field,
	name:        Text_Field,
	cwd:         Text_Field,
	cwd_auto:    string, // what ngam put in the folder field, until it is edited
	creating:    bool,
	agentmux:    Text_Field, // the setting of the same name
	remote:      Text_Field, // remote_agentmux
	port:        Text_Field,
	fonts:       []Font_Family,
	scanning:    bool,
	ssh_hosts:   []string, // Host entries in ~/.ssh/config
	tab:         Setup_Tab,
	status:      string, // the last message, at the bottom
}

// The setup screen's two tabs: picking a session, and ngam's settings.
Setup_Tab :: enum {
	Sessions,
	Settings,
}

PREVIEW_TEXT :: [?]string {
	"func main() { x := []int{0, 1} } // 0O il1| <= != =>",
	"The quick brown fox jumps over the lazy dog. ~@#$%^&*",
}

setup_init :: proc(app: ^App) {
	s := &app.setup
	st := &app.settings
	field_set(&s.host, st.host)
	field_set(&s.agent, st.new_agent)
	field_set(&s.agentmux, st.agentmux)
	field_set(&s.remote, st.remote_agentmux)
	field_set(&s.port, fmt.tprint(st.preview_port))
	setup_fill_cwd(s, st.host)
	s.ssh_hosts = read_ssh_hosts()
}

// setup_fill_cwd puts host's start folder in the New session folder field:
// the local one for this machine, and blank for an ssh host. A folder typed
// or picked by hand stays.
@(private = "file")
setup_fill_cwd :: proc(s: ^Setup, host: string) {
	if text := field_text(&s.cwd); text != "" && text != s.cwd_auto {
		return
	}
	dir := host == "" ? local_start_dir() : ""
	field_set(&s.cwd, dir)
	delete(s.cwd_auto)
	s.cwd_auto = strings.clone(dir)
}

// local_start_dir is the New session folder for this machine: the folder
// ngam was started in, or the home folder when that is / (as when it is
// started from Finder or the Dock).
local_start_dir :: proc() -> string {
	if dir, err := os.get_working_directory(context.temp_allocator); err == nil && dir != "" && dir != "/" {
		return dir
	}
	home, _ := os.user_home_dir(context.temp_allocator)
	return home
}

// setup_show opens the setup screen at tab and refreshes what it lists.
setup_show :: proc(app: ^App, tab := Setup_Tab.Sessions) {
	app.setup_open = true
	app.setup.tab = tab
	// Start at the top, where the status message is.
	// (.CLOSED fetches the window only if it exists already: microui makes
	// a window in its first frame.)
	if cnt := mu.get_container(&app.ui.ctx, "!setup", {.CLOSED}); cnt != nil {
		cnt.scroll = {}
	}
	app.need_draw = true
	list_sessions(app)
	if app.setup.fonts == nil && !app.setup.scanning {
		app.setup.scanning = true
		job_start(.Font_Scan, {})
	}
}

setup_set_status :: proc(app: ^App, msg: string) {
	delete(app.setup.status)
	app.setup.status = strings.clone(msg)
	app.need_draw = true
}

// agentmux_command is the start of a command that runs agentmux on host.
agentmux_command :: proc(app: ^App, host: string) -> [dynamic]string {
	cmd := make([dynamic]string, context.temp_allocator)
	if host != "" {
		append(&cmd, ..ssh_command(app, host))
	} else {
		append(&cmd, ..strings.fields(app.settings.agentmux, context.temp_allocator))
	}
	return cmd
}

// list_sessions runs `agentmux ls -json` on the host in the host field.
list_sessions :: proc(app: ^App) {
	s := &app.setup
	if s.listing {
		return
	}
	host := strings.trim_space(field_text(&s.host))
	if host != app.settings.host {
		app.settings.host = strings.clone(host)
		remember_host(&app.settings, host)
		settings_save(&app.settings)
	}
	setup_fill_cwd(s, host)
	cmd := agentmux_command(app, host)
	append(&cmd, "ls", "-json")
	s.listing = true
	job_start(.List_Sessions, cmd[:], host)
}

// job_done handles a finished job on the main thread.
job_done :: proc(app: ^App, j: ^Job) {
	s := &app.setup
	switch j.kind {
	case .List_Sessions:
		s.listing = false
		delete(s.listed_host)
		s.listed_host = strings.clone(j.host)
		free_sessions(s)
		delete(s.list_error)
		s.list_error = ""
		if !j.ok {
			s.list_error = strings.clone(first_line(j.stderr, "agentmux ls failed."))
			return
		}
		if err := json.unmarshal(transmute([]u8)j.stdout, &s.sessions); err != nil {
			s.list_error = fmt.aprintf("Cannot read agentmux ls -json: %v", err)
		}
	case .New_Session:
		s.creating = false
		id := strings.trim_space(j.stdout)
		if !j.ok || id == "" {
			setup_set_status(app, first_line(j.stderr, "agentmux new failed."))
			return
		}
		open_session(app, j.host, id)
	case .Font_Scan:
		s.scanning = false
		s.fonts = j.fonts
	case .Pick_Folder:
		switch {
		case !j.ok:
			setup_set_status(app, j.stderr)
		case j.stdout != "":
			field_set(&s.cwd, j.stdout)
		}
	case .Open_Url:
		if !j.ok {
			show_toast(app, first_line(j.stderr, "Cannot open the browser."))
		}
	}
}

@(private = "file")
free_sessions :: proc(s: ^Setup) {
	free_session_infos(s.sessions)
	s.sessions = nil
}

free_session_infos :: proc(list: []Session_Info) {
	for x in list {
		delete(x.id)
		delete(x.name)
		delete(x.agent)
		delete(x.agent_state)
		delete(x.editor)
		delete(x.created)
		delete(x.cwd)
	}
	delete(list)
}

// first_line is text's first line, or otherwise when text is blank.
first_line :: proc(text, otherwise: string) -> string {
	t := strings.trim_space(text)
	if i := strings.index_byte(t, '\n'); i >= 0 {
		t = t[:i]
	}
	return t == "" ? otherwise : t
}

// read_ssh_hosts lists the Host names in ~/.ssh/config, skipping
// patterns such as "*".
read_ssh_hosts :: proc() -> []string {
	home, _ := os.user_home_dir(context.temp_allocator)
	path, _ := filepath.join({home, ".ssh", "config"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil
	}
	hosts := make([dynamic]string)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		words := strings.fields(line, context.temp_allocator)
		if len(words) < 2 || strings.to_lower(words[0], context.temp_allocator) != "host" {
			continue
		}
		for w in words[1:] {
			if !strings.contains_any(w, "*?!") {
				append(&hosts, strings.clone(w))
			}
		}
	}
	return hosts[:]
}

// create_session runs `agentmux new -detached` with the fields' values.
@(private = "file")
create_session :: proc(app: ^App) {
	s := &app.setup
	agent := strings.trim_space(field_text(&s.agent))
	name := strings.trim_space(field_text(&s.name))
	cwd := strings.trim_space(field_text(&s.cwd))
	// agentmux expands "~" on the session's machine, so it is passed on as it is.
	if !strings.has_prefix(cwd, "/") && cwd != "~" && !strings.has_prefix(cwd, "~/") {
		setup_set_status(app, "The folder must be an absolute path, or start with ~/, on the session's machine.")
		return
	}
	host := strings.trim_space(field_text(&s.host))
	// ssh hands the remote shell one joined string, so quote each value.
	q :: proc(host, v: string) -> string {
		return host != "" ? shell_quote(v) : v
	}
	cmd := agentmux_command(app, host)
	append(&cmd, "new", "-detached", "-cwd", q(host, cwd))
	if agent != "" {
		append(&cmd, "-agent", q(host, agent))
		app.settings.new_agent = strings.clone(agent)
		settings_save(&app.settings)
	}
	if name != "" {
		append(&cmd, "-name", q(host, name))
	}
	s.creating = true
	setup_set_status(app, "Creating the session…")
	job_start(.New_Session, cmd[:], host)
}

// pick_font makes fam the editor font.
@(private = "file")
pick_font :: proc(app: ^App, fam: ^Font_Family) {
	st := &app.settings
	if fam == nil {
		st.font_family = ""
		st.font_faces = {}
	} else {
		st.font_family = strings.clone(fam.name)
		for ref, style in fam.faces {
			st.font_faces[int(style)] = {strings.clone(ref.path), ref.index}
		}
	}
	app.font_spec = settings_font_spec(st)
	font_changed(app)
}

// font_size_step makes the editor font by points bigger (or smaller),
// within 6 to 72 points; 0 goes back to the default size.
font_size_step :: proc(app: ^App, by: f32) {
	size := by == 0 ? DEFAULT_SIZE : clamp(app.font_size + by, 6, 72)
	if size == app.font_size {
		return
	}
	app.font_size = size
	font_changed(app)
	show_toast(app, fmt.tprintf("Font size %.0f pt", size))
}

@(private = "file")
font_changed :: proc(app: ^App) {
	app.settings.font_size = app.font_size
	settings_save(&app.settings)
	_ = load_editor_font(app)
	resize_editor(app)
}

// setup_frame builds the setup screen for this frame.
setup_frame :: proc(app: ^App) {
	ctx := &app.ui.ctx
	ui := &app.ui
	s := &app.setup
	st := &app.settings
	d := app.density
	w, h := window_pixels(app)

	if app.link != nil {
		// Dim the editor behind the setup screen, and keep its clicks.
		if fixed_window(ctx, "!overlay", {0, 0, w, h}, {.NO_TITLE, .NO_RESIZE, .NO_SCROLL, .NO_CLOSE, .NO_FRAME, .NO_INTERACT}, Z_OVERLAY) {
			mu.draw_rect(ctx, {0, 0, w, h}, ui.colors.overlay)
			mu.end_window(ctx)
		}
	}
	ww := min(i32(780 * d), w - i32(32 * d))
	r := mu.Rect{(w - ww) / 2, i32(16 * d), ww, h - i32(32 * d)}
	if !fixed_window(ctx, "!setup", r, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE}, Z_SETUP) {
		return
	}
	defer mu.end_window(ctx)
	label_w := i32(120 * d)
	btn_w := i32(96 * d)
	row_h := ui.font.cell_h + ctx.style.padding * 2

	// The tabs, and the way back to the session.
	mu.layout_row(ctx, {btn_w, btn_w, -btn_w * 2, -1}, row_h)
	if pick := choice(ui, "tab", {"Sessions", "Settings"}, int(s.tab)); pick != int(s.tab) {
		s.tab = Setup_Tab(pick)
		if cnt := mu.get_current_container(ctx); cnt != nil {
			cnt.scroll = {}
		}
	}
	mu.label(ctx, "")
	if app.link != nil {
		if .SUBMIT in mu.button(ctx, "Back (Esc)") {
			app.setup_open = false
		}
	} else if app.last_session != "" {
		// After a dropped connection: open the last session again.
		if .SUBMIT in mu.button(ctx, "Reconnect") {
			reconnect(app)
		}
	} else {
		mu.label(ctx, "")
	}

	if s.status != "" {
		mu.layout_row(ctx, {-1}, 0)
		mu.text(ctx, s.status)
	}

	switch s.tab {
	case .Sessions:
		// ---- Connection ----
		group_begin(ui, "Connection")
		mu.layout_row(ctx, {label_w, -btn_w, -1}, row_h)
		mu.label(ctx, "Host")
		if .SUBMIT in mu.textbox(ctx, s.host.buf[:], &s.host.len) {
			list_sessions(app)
		}
		if .SUBMIT in mu.button(ctx, s.listing ? "Loading…" : "Connect") {
			list_sessions(app)
		}
		host_list(app, label_w)
		mu.layout_row(ctx, {label_w, -1}, 0)
		mu.label(ctx, "")
		mu.text(ctx, "Pick a host or type one, then Connect. A blank host is this machine; others are reached with ssh. If ssh needs a passphrase or password, ngam asks for it.")

		group_end(ui)

		place := s.listed_host == "" ? "this machine" : s.listed_host
		group_begin(ui, fmt.tprintf("Sessions on %s", place))
		switch {
		case s.list_error != "":
			mu.layout_row(ctx, {-1}, 0)
			mu.text(ctx, s.list_error)
		case len(s.sessions) == 0 && !s.listing:
			mu.layout_row(ctx, {-1}, 0)
			mu.text(ctx, "No sessions yet. Create one below.")
		}
		for &x in s.sessions {
			detail := fmt.tprintf("%s · %s · %s", x.agent, x.agent_state, x.cwd)
			tag := ""
			if x.editor != "" {
				tag = fmt.tprintf("open in %s", editor_places(x.editor))
			} else if x.stashed > 0 {
				tag = fmt.tprintf("%d unsaved", x.stashed)
			}
			current := app.link != nil && x.id == app.session.id && s.listed_host == app.host
			if list_row(ui, x.id, 0, x.name, detail = detail, tag = tag, tag_color = ui.colors.dim, selected = current) {
				switch {
				case current:
					app.setup_open = false
				case gui_has_it(x.editor):
					setup_set_status(app, fmt.tprintf("%s is open in another GUI. Close it there first.", x.name))
				case:
					open_session(app, s.listed_host, x.id)
				}
			}
		}

		group_end(ui)

		group_begin(ui, "New session")
		mu.layout_row(ctx, {label_w, -1}, row_h)
		mu.label(ctx, "Agent")
		mu.textbox(ctx, s.agent.buf[:], &s.agent.len)
		mu.label(ctx, "Name")
		mu.textbox(ctx, s.name.buf[:], &s.name.len)
		// The folder dialog shows this machine's folders, so it is only
		// offered when the host is blank.
		local := strings.trim_space(field_text(&s.host)) == ""
		mu.layout_row(ctx, local ? {label_w, -btn_w, -1} : {label_w, -1}, row_h)
		mu.label(ctx, "Folder")
		mu.textbox(ctx, s.cwd.buf[:], &s.cwd.len)
		if local && .SUBMIT in mu.button(ctx, "Choose…") {
			start := strings.trim_space(field_text(&s.cwd))
			if start == "~" || strings.has_prefix(start, "~/") {
				home, _ := os.user_home_dir(context.temp_allocator)
				start = strings.concatenate({home, start[1:]}, context.temp_allocator)
			}
			pick_folder(app.window, start != "" ? start : local_start_dir())
		}
		mu.layout_row(ctx, {label_w, btn_w * 2}, row_h)
		mu.label(ctx, "")
		if .SUBMIT in mu.button(ctx, s.creating ? "Creating…" : "Create and open") && !s.creating {
			create_session(app)
		}
		group_end(ui)
	case .Settings:
		// ---- Theme ----
		group_begin(ui, "Theme")
		themes := []string{"system", "light", "dark"}
		current := 0
		for t, i in themes {
			if t == st.theme {
				current = i
			}
		}
		mu.layout_row(ctx, {label_w, btn_w, btn_w, btn_w}, row_h)
		mu.label(ctx, "Colors")
		if pick := choice(ui, "theme", {"System", "Light", "Dark"}, current); pick != current {
			st.theme = themes[pick]
			settings_save(st)
			apply_theme(app)
		}

		group_end(ui)

		// ---- Editor font ----
		group_begin(ui, "Editor font")
		{
			small := i32(32 * d)
			mu.layout_row(ctx, {label_w, small, small * 2, small, -1}, row_h)
			mu.label(ctx, "Size")
			if .SUBMIT in mu.button(ctx, "−") {
				font_size_step(app, -1)
			}
			mu.draw_control_text(ctx, fmt.tprintf("%.0f pt", app.font_size), mu.layout_next(ctx), .TEXT, {.ALIGN_CENTER})
			if .SUBMIT in mu.button(ctx, "+") {
				font_size_step(app, 1)
			}
			mu.draw_control_text(ctx, ODIN_OS == .Darwin ? "  Cmd-= and Cmd-- anywhere, Cmd-0 for 13 pt" : "  Ctrl-= and Ctrl-- anywhere, Ctrl-0 for 13 pt", mu.layout_next(ctx), .TEXT, {})
		}
		list_h := i32(200 * d)
		mu.layout_row(ctx, {mu.get_layout(ctx).body.w / 2 - ctx.style.padding * 2, -1}, list_h)
		mu.begin_panel(ctx, "!fonts")
		if s.scanning {
			mu.layout_row(ctx, {-1}, 0)
			mu.text(ctx, "Reading the font folders…")
		}
		if list_row(ui, "!default", 0, "Default (Menlo)", selected = st.font_family == "") {
			pick_font(app, nil)
		}
		for &fam in s.fonts {
			if list_row(ui, fam.name, 0, fam.name, selected = fam.name == st.font_family) {
				pick_font(app, &fam)
			}
		}
		mu.end_panel(ctx)
		mu.layout_begin_column(ctx)
		{
			// The preview, in the editor's own font and colors.
			lines := len(PREVIEW_TEXT)
			mu.layout_row(ctx, {-1}, i32(lines + 1) * app.font.cell_h)
			pr := mu.layout_next(ctx)
			bg, fg := app.grid.default_bg, app.grid.default_fg
			if app.link == nil {
				bg, fg = app.dark ? 0x1e1e1e : 0xffffff, app.dark ? 0xd4d4d4 : 0x1e1e1e
			}
			mu.draw_rect(ctx, pr, rgb_mu(bg))
			mu.push_clip_rect(ctx, pr)
			for line, i in PREVIEW_TEXT {
				mu.draw_text(ctx, mu.Font(&app.font), line, {pr.x + app.font.cell_w / 2, pr.y + app.font.cell_h / 2 + i32(i) * app.font.cell_h}, rgb_mu(fg))
			}
			mu.pop_clip_rect(ctx)
			mu.layout_row(ctx, {-1}, 0)
			mu.text(ctx, st.font_family == "" ? "Menlo" : st.font_family)
		}
		mu.layout_end_column(ctx)

		group_end(ui)

		// ---- Editor ----
		group_begin(ui, "Editor")
		mu.layout_row(ctx, {label_w, btn_w, btn_w}, row_h)
		mu.label(ctx, "Drawn by")
		native := st.native_ui ? 0 : 1
		if pick := choice(ui, "native", {"ngam", "nvim"}, native); pick != native {
			st.native_ui = pick == 0
			settings_save(st)
			ext_reattach(app)
		}
		mu.layout_row(ctx, {label_w, btn_w, btn_w}, row_h)
		mu.label(ctx, "Scrolling")
		smooth := st.smooth_scroll ? 0 : 1
		if pick := choice(ui, "smooth", {"Smooth", "Instant"}, smooth); pick != smooth {
			st.smooth_scroll = pick == 0
			settings_save(st)
			app.grid.smooth = st.native_ui && st.smooth_scroll
		}
		mu.layout_row(ctx, {label_w, -1}, 0)
		mu.label(ctx, "")
		mu.text(ctx, "ngam: windows, floats, the command line, completion, messages and tabs are drawn by ngam. nvim: nvim draws them all in its grid, as in a terminal. Smooth scrolling needs ngam.")

		group_end(ui)

		// ---- Windows ----
		group_begin(ui, "Windows")
		mu.layout_row(ctx, {label_w, btn_w, btn_w}, row_h)
		mu.label(ctx, "On start")
		restore := st.restore_sessions ? 0 : 1
		if pick := choice(ui, "restore", {"Restore", "Setup"}, restore); pick != restore {
			st.restore_sessions = pick == 0
			settings_save(st)
		}
		mu.layout_row(ctx, {label_w, -1}, 0)
		mu.label(ctx, "")
		mu.text(ctx, "Restore: ngam started without a session reopens the sessions whose windows were open when it last quit, each in its own window at its old place and size. Setup: it starts at this screen.")

		group_end(ui)

		// ---- Preview server ----
		group_begin(ui, "Preview server")
		modes := []string{"off", "http", "https"}
		mode := 0
		for m, i in modes {
			if m == st.preview {
				mode = i
			}
		}
		mu.layout_row(ctx, {label_w, btn_w, btn_w, btn_w}, row_h)
		mu.label(ctx, "Serve")
		if pick := choice(ui, "preview", {"Off", "HTTP", "HTTPS"}, mode); pick != mode {
			st.preview = modes[pick]
			settings_save(st)
			preview_apply(app)
		}
		mu.layout_row(ctx, {label_w, btn_w, -1}, row_h)
		mu.label(ctx, "Port")
		if .SUBMIT in mu.textbox(ctx, s.port.buf[:], &s.port.len) {
			port, ok := strconv.parse_int(strings.trim_space(field_text(&s.port)))
			if !ok || port < 0 || port > 65535 {
				setup_set_status(app, "The port must be a number from 0 to 65535.")
			} else {
				st.preview_port = port
				settings_save(st)
				preview_apply(app)
			}
		}
		mu.label(ctx, "0 picks a free port. Press Return to apply.")
		mu.layout_row(ctx, {label_w, -1}, 0)
		mu.label(ctx, "")
		mu.text(ctx, preview_status(app))

		group_end(ui)

		// ---- Commands ----
		group_begin(ui, "Commands")
		mu.layout_row(ctx, {label_w, -1}, row_h)
		mu.label(ctx, "agentmux")
		if .CHANGE in mu.textbox(ctx, s.agentmux.buf[:], &s.agentmux.len) {
			if v := strings.trim_space(field_text(&s.agentmux)); v != "" {
				st.agentmux = strings.clone(v)
				settings_save(st)
			}
		}
		mu.label(ctx, "Remote agentmux")
		if .CHANGE in mu.textbox(ctx, s.remote.buf[:], &s.remote.len) {
			if v := strings.trim_space(field_text(&s.remote)); v != "" {
				st.remote_agentmux = strings.clone(v)
				settings_save(st)
			}
		}
		group_end(ui)
	}
}

// HOST_ROWS is how many hosts the host list shows before it scrolls.
@(private = "file")
HOST_ROWS :: 6

// host_list draws this machine, the recent hosts and the Host entries in
// ~/.ssh/config as a scrolling list. A click only fills in the Host field;
// Connect lists that host's sessions.
@(private = "file")
host_list :: proc(app: ^App, indent: i32) {
	ui := &app.ui
	ctx := &ui.ctx
	s := &app.setup
	Entry :: struct {
		name, detail: string,
	}
	entries := make([dynamic]Entry, context.temp_allocator)
	append(&entries, Entry{"This machine", ""})
	add :: proc(entries: ^[dynamic]Entry, h, detail: string) {
		for e in entries {
			if e.name == h {
				return
			}
		}
		append(entries, Entry{h, detail})
	}
	for h in app.settings.recent_hosts {
		add(&entries, h, "recent")
	}
	for h in s.ssh_hosts {
		add(&entries, h, "ssh config")
	}
	row_h := ui.font.cell_h + ctx.style.padding
	n := i32(min(len(entries), HOST_ROWS))
	mu.layout_row(ctx, {indent, -1}, n * (row_h + ctx.style.spacing) - ctx.style.spacing + ctx.style.padding * 2)
	mu.label(ctx, "")
	mu.begin_panel(ctx, "!hosts")
	host := strings.trim_space(field_text(&s.host))
	for e, i in entries {
		value := i == 0 ? "" : e.name
		if list_row(ui, fmt.tprintf("host:%s", e.name), 0, e.name, detail = e.detail, selected = host == value) {
			field_set(&s.host, value)
		}
	}
	mu.end_panel(ctx)
}

rgb_mu :: proc(rgb: i32) -> mu.Color {
	return {u8(rgb >> 16), u8(rgb >> 8), u8(rgb), 255}
}

// gui_has_it says whether a session's editor list (agentmux ls) has a GUI
// in it. A GUI's editor keeps other GUIs out. A GUI can still open a
// session open in a terminal, because it runs its own nvim beside it.
gui_has_it :: proc(editor: string) -> bool {
	for part in strings.split(editor, ",", context.temp_allocator) {
		if part == "gui" {
			return true
		}
	}
	return false
}

// editor_places is the editor list for people: "a terminal and a GUI".
editor_places :: proc(editor: string) -> string {
	t := strings.contains(editor, "terminal")
	g := gui_has_it(editor)
	switch {
	case t && g:
		return "a terminal and a GUI"
	case g:
		return "a GUI"
	case t:
		return "a terminal"
	}
	return editor
}
