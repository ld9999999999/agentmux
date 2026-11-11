package ngam

// Restoring windows. Each ngam window is its own process showing one
// session. While it shows one, it keeps a record of the session, its host
// and the window's place and size in <config>/windows/<pid>.json, written
// again whenever the window moves or is resized, and once more when it
// closes.
//
// With the restore_sessions setting on, ngam started with no session
// reopens the windows that were open when ngam last quit: the records of
// processes that have exited whose last write is within RESTORE_SPAN of
// the newest one. Quitting several windows at once (or logging out) puts
// all of them back; a window closed long before the last one stays closed.
// This process opens the first; each other gets an ngam process of its
// own, started with -window for its place and size.
//
// Ending a session with :qa, or leaving it for the setup screen, drops
// its window's record, so a restore skips that window.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import sdl "vendor:sdl3"

RESTORE_SPAN :: 10 // seconds

Window_Record :: struct {
	host:      string, // "" for this machine
	session:   string,
	x, y:      i32, // points
	w, h:      i32,
	maximized: bool,
	saved:     i64, // unix seconds of the last write
}

@(private = "file")
windows_dir :: proc() -> string {
	dir, _ := filepath.join({config_dir(context.temp_allocator), "windows"}, context.temp_allocator)
	_ = os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User})
	return dir
}

@(private = "file")
record_path :: proc(pid: int) -> string {
	p, _ := filepath.join({windows_dir(), fmt.tprintf("%d.json", pid)}, context.temp_allocator)
	return p
}

// window_record_save writes this window's record, if it shows a session.
// force writes it even when nothing changed, to mark when it closed.
window_record_save :: proc(app: ^App, force := false) {
	if app.link == nil || app.session.id == "" {
		return
	}
	r := Window_Record {
		host    = app.host,
		session = app.session.id,
	}
	flags := sdl.GetWindowFlags(app.window)
	r.maximized = .MAXIMIZED in flags
	if r.maximized || .FULLSCREEN in flags {
		// Keep the size it had before, for when it is restored again.
		old := app.window_record
		r.x, r.y, r.w, r.h = old.x, old.y, old.w, old.h
	} else {
		_ = sdl.GetWindowPosition(app.window, &r.x, &r.y)
		_ = sdl.GetWindowSize(app.window, &r.w, &r.h)
	}
	old := app.window_record
	if !force && old.session == r.session && old.host == r.host && old.x == r.x && old.y == r.y &&
	   old.w == r.w && old.h == r.h && old.maximized == r.maximized {
		return
	}
	r.saved = time.to_unix_seconds(time.now())
	data, err := json.marshal(r, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	_ = write_atomic(record_path(os.get_pid()), data)
	delete(app.window_record.host)
	delete(app.window_record.session)
	app.window_record = r
	app.window_record.host = strings.clone(r.host)
	app.window_record.session = strings.clone(r.session)
}

// window_record_drop removes this window's record: its session ended.
window_record_drop :: proc(app: ^App) {
	_ = os.remove(record_path(os.get_pid()))
	delete(app.window_record.host)
	delete(app.window_record.session)
	app.window_record = {}
}

// windows_restore takes the records of the windows open when ngam last
// quit and removes every record of a process that has exited. It starts an
// ngam for each window but the first, and returns the first for this
// process to open.
windows_restore :: proc(app: ^App) -> (first: Window_Record, ok: bool) {
	dir := windows_dir()
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	found := make([dynamic]Window_Record, context.temp_allocator)
	newest: i64 = 0
	for fi in infos {
		name := fi.name
		if !strings.has_suffix(name, ".json") {
			continue
		}
		pid, is_num := strconv.parse_int(strings.trim_suffix(name, ".json"))
		if !is_num || pid == os.get_pid() {
			continue
		}
		if pid > 0 && posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK {
			continue // a window still open
		}
		path, _ := filepath.join({dir, name}, context.temp_allocator)
		data, rerr := os.read_entire_file(path, context.temp_allocator)
		_ = os.remove(path)
		if rerr != nil {
			continue
		}
		r: Window_Record
		if json.unmarshal(data, &r, allocator = context.temp_allocator) != nil || r.session == "" {
			continue
		}
		append(&found, r)
		newest = max(newest, r.saved)
	}
	exe, _ := os.get_executable_path(context.temp_allocator)
	for r in found {
		if r.saved < newest - RESTORE_SPAN {
			continue // closed well before the rest
		}
		if !ok {
			first, ok = r, true
			continue
		}
		// Through sh, which starts it in the background and exits: the new
		// ngam is detached from this one, and this one can move on at once.
		cmd := []string {
			"/bin/sh", "-c", `"$0" "$@" &`,
			exe,
			"-host", r.host == "" ? "local" : r.host,
			"-window", window_spec(r),
			r.session,
		}
		p, perr := os.process_start({command = cmd, stdout = os.stdout, stderr = os.stderr})
		if perr != nil {
			fmt.eprintfln("ngam: cannot reopen %s: %v", r.session, perr)
			continue
		}
		_, _ = os.process_wait(p)
	}
	return
}

// window_spec is -window's argument: "x,y,w,h", with ",max" when the
// window was maximized.
window_spec :: proc(r: Window_Record) -> string {
	s := fmt.tprintf("%d,%d,%d,%d", r.x, r.y, r.w, r.h)
	return r.maximized ? strings.concatenate({s, ",max"}, context.temp_allocator) : s
}

// parse_window_spec reads -window's argument.
parse_window_spec :: proc(s: string) -> (r: Window_Record, ok: bool) {
	parts := strings.split(s, ",", context.temp_allocator)
	if len(parts) != 4 && len(parts) != 5 {
		return
	}
	v: [4]i32
	for i in 0 ..< 4 {
		n, is_num := strconv.parse_int(parts[i])
		if !is_num {
			return
		}
		v[i] = i32(n)
	}
	if len(parts) == 5 && parts[4] != "max" {
		return
	}
	r.x, r.y, r.w, r.h = v[0], v[1], v[2], v[3]
	r.maximized = len(parts) == 5
	return r, v[2] > 0 && v[3] > 0
}

// window_place puts the window where r says, before it is shown. When the
// place is off every display (say, a display was unplugged), the system
// picks the place.
window_place :: proc(app: ^App, r: Window_Record) {
	if r.w >= 200 && r.h >= 150 {
		_ = sdl.SetWindowSize(app.window, r.w, r.h)
	}
	if sdl.GetDisplayForPoint(sdl.Point{r.x + 20, r.y + 20}) != 0 {
		_ = sdl.SetWindowPosition(app.window, r.x, r.y)
	}
	app.window_record.x, app.window_record.y, app.window_record.w, app.window_record.h = r.x, r.y, r.w, r.h
}
