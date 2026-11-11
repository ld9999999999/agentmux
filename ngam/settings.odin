package ngam

// Settings, kept as JSON in the per-user config folder:
// ~/Library/Application Support/ngam/settings.json on macOS, and
// $XDG_CONFIG_HOME/ngam/settings.json (~/.config/ngam) on Linux. The
// HTTPS preview certificate lives in the same folder. $NGAM_CONFIG_DIR
// replaces the folder.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Settings :: struct {
	// Connection. host "" is this machine; anything else is an ssh host.
	host:            string,
	recent_hosts:    [dynamic]string,
	agentmux:        string, // the agentmux command on this machine
	remote_agentmux: string, // agentmux on ssh hosts, whose non-interactive PATH often lacks it
	new_agent:       string, // the agent last used for a new session

	// Editor font. faces is filled in from the font list when a family is
	// picked, so startup can skip the font scan. An empty family is the default.
	font_family:     string,
	font_faces:      [4]Face_Ref, // Regular, Bold, Italic, Bold_Italic
	font_size:       f32,

	theme:           string, // "system", "light" or "dark"

	preview:         string, // "off", "http" or "https"
	preview_port:    int, // 0 picks a free port

	// The side panel.
	panel_open:      bool,
	panel_view:      string, // a View's name
	panel_width:     int, // points

	// The agent pane.
	agent_open:      bool,
	agent_width:     int, // points; 0 is 40% of the window
	agent_focus_key: string, // switches the keyboard between the panes, e.g. "cmd+shift+a"

	// The editor. native_ui has ngam draw windows, the command line, the
	// popup menu, messages and tabs; off, nvim draws them in its grid.
	native_ui:       bool,
	smooth_scroll:   bool, // animate scrolling (with native_ui)
	change_bars:     bool, // git change bars beside changed lines

	// When ngam starts with no session, reopen the windows (sessions,
	// places and sizes) that were open when ngam last quit. See windows.odin.
	restore_sessions: bool,
}

settings_default :: proc() -> Settings {
	return {
		agentmux = "agentmux",
		remote_agentmux = "agentmux",
		new_agent = "claude",
		font_size = DEFAULT_SIZE,
		theme = "system",
		preview = "http",
		panel_open = false,
		panel_view = "Explorer",
		panel_width = 260,
		agent_open = true,
		agent_focus_key = ODIN_OS == .Darwin ? "cmd+shift+a" : "ctrl+shift+a",
		native_ui = true,
		smooth_scroll = true,
		change_bars = true,
	}
}

// config_dir is ngam's folder in the per-user config folder, made if
// missing.
config_dir :: proc(allocator := context.allocator) -> string {
	// $NGAM_CONFIG_DIR replaces the folder, for tests.
	if dir := os.get_env("NGAM_CONFIG_DIR", allocator); dir != "" {
		_ = os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User})
		return dir
	}
	base, err := os.user_config_dir(context.temp_allocator)
	if err != nil {
		home, _ := os.user_home_dir(context.temp_allocator)
		base, _ = filepath.join({home, ".config"}, context.temp_allocator)
	}
	dir, _ := filepath.join({base, "ngam"}, allocator)
	_ = os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User})
	return dir
}

settings_path :: proc() -> string {
	p, _ := filepath.join({config_dir(context.temp_allocator), "settings.json"}, context.temp_allocator)
	return p
}

// settings_load reads the settings file over the defaults. A missing or
// broken file leaves the defaults.
settings_load :: proc() -> Settings {
	s := settings_default()
	data, err := os.read_entire_file(settings_path(), context.temp_allocator)
	if err != nil {
		return s
	}
	if uerr := json.unmarshal(data, &s); uerr != nil {
		fmt.eprintln("ngam: ignoring a broken settings file:", uerr)
		return settings_default()
	}
	if s.agentmux == "" {s.agentmux = "agentmux"}
	if s.remote_agentmux == "" {s.remote_agentmux = "agentmux"}
	if s.font_size < 6 || s.font_size > 72 {s.font_size = DEFAULT_SIZE}
	if s.panel_width < 120 {s.panel_width = 260}
	if s.agent_width < 0 {s.agent_width = 0}
	return s
}

settings_save :: proc(s: ^Settings) {
	data, err := json.marshal(s^, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil {
		fmt.eprintln("ngam: cannot save settings:", err)
		return
	}
	if werr := write_atomic(settings_path(), data); werr != nil {
		fmt.eprintln("ngam: cannot save settings:", werr)
	}
}

// write_atomic replaces the file at path with data, through a temporary
// file of this process's own, so a reader always sees a whole file and two
// ngam processes writing at once keep their writes apart.
write_atomic :: proc(path: string, data: []byte) -> os.Error {
	tmp := fmt.tprintf("%s.%d.tmp", path, os.get_pid())
	if err := os.write_entire_file(tmp, data); err != nil {
		return err
	}
	if err := os.rename(tmp, path); err != nil {
		_ = os.remove(tmp)
		return err
	}
	return nil
}

// settings_font_spec is the editor font the settings name.
settings_font_spec :: proc(s: ^Settings) -> Font_Spec {
	if s.font_faces[0].path != "" {
		spec: Font_Spec
		for ref, i in s.font_faces {
			spec.faces[Style(i)] = ref
		}
		return spec
	}
	spec, ok := font_spec_from_file(DEFAULT_FONT)
	if !ok {
		spec.faces[.Regular] = {DEFAULT_FONT, 0}
	}
	return spec
}

// remember_host puts host first in the recent hosts, keeping eight.
remember_host :: proc(s: ^Settings, host: string) {
	if host == "" {
		return
	}
	for h, i in s.recent_hosts {
		if h == host {
			ordered_remove(&s.recent_hosts, i)
			break
		}
	}
	inject_at(&s.recent_hosts, 0, strings.clone(host))
	if len(s.recent_hosts) > 8 {
		resize(&s.recent_hosts, 8)
	}
}
