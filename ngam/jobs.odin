package ngam

// Jobs: slow work done on a thread, so the window keeps drawing. A job
// runs a command (agentmux ls -json, new, open) or scans the font folders,
// then posts an SDL event; the main thread handles the result in
// job_done.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import sdl "vendor:sdl3"

Job_Kind :: enum {
	List_Sessions,
	New_Session,
	Open_Url,
	Font_Scan,
	Pick_Folder, // stdout is the folder, or "" when the dialog was cancelled
}

Job :: struct {
	kind:    Job_Kind,
	command: []string,
	host:    string, // the host the command runs on, for New_Session
	ok:      bool, // the command exited 0
	stdout:  string,
	stderr:  string,
	fonts:   []Font_Family,
}

job_event: u32 // the SDL event type that carries a finished ^Job in data1

jobs_init :: proc() {
	job_event = sdl.RegisterEvents(1)
}

// job_start runs command on a new thread. Everything the job keeps is
// heap allocated and freed in job_free.
job_start :: proc(kind: Job_Kind, command: []string, host := "") {
	j := new(Job)
	j.kind = kind
	j.host = strings.clone(host)
	cmd := make([]string, len(command))
	for s, i in command {
		cmd[i] = strings.clone(s)
	}
	j.command = cmd
	thread.run_with_data(j, proc(p: rawptr) {
		j := (^Job)(p)
		if j.kind == .Font_Scan {
			j.fonts = list_mono_fonts()
			j.ok = true
		} else {
			env, _ := os.environ(context.temp_allocator)
			state, out, errout, err := os.process_exec({command = j.command, env = env}, context.allocator)
			j.ok = err == nil && state.exited && state.exit_code == 0
			j.stdout = string(out)
			j.stderr = string(errout)
			if err != nil {
				j.stderr = fmt.aprintf("cannot run %s: %v", j.command[0], err)
			}
		}
		free_all(context.temp_allocator)
		ev: sdl.Event
		ev.type = sdl.EventType(job_event)
		ev.user.data1 = j
		_ = sdl.PushEvent(&ev)
	})
}

// pick_folder shows the system's folder dialog, starting at start. The
// choice comes back as a Pick_Folder job.
pick_folder :: proc(window: ^sdl.Window, start: string) {
	sdl.ShowOpenFolderDialog(folder_picked, nil, window, strings.clone_to_cstring(start, context.temp_allocator), false)
}

// folder_picked is SDL's callback for the folder dialog, which may come on
// another thread.
@(private = "file")
folder_picked :: proc "c" (userdata: rawptr, list: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	j := new(Job)
	j.kind = .Pick_Folder
	switch {
	case list == nil:
		j.stderr = fmt.aprintf("Cannot show the folder dialog: %s", sdl.GetError())
	case list[0] != nil:
		j.stdout = strings.clone(string(list[0]))
		j.ok = true
	case:
		j.ok = true // cancelled
	}
	ev: sdl.Event
	ev.type = sdl.EventType(job_event)
	ev.user.data1 = j
	_ = sdl.PushEvent(&ev)
}

job_free :: proc(j: ^Job) {
	for s in j.command {
		delete(s)
	}
	delete(j.command)
	delete(j.host)
	delete(j.stdout)
	delete(j.stderr)
	// Font families stay: the setup screen keeps them.
	free(j)
}

// open_url opens url in the default browser, or with the command in
// $NGAM_OPEN (the URL is added at the end).
open_url :: proc(url: string) {
	if opener := os.get_env("NGAM_OPEN", context.temp_allocator); opener != "" {
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, ..strings.fields(opener, context.temp_allocator))
		append(&cmd, url)
		job_start(.Open_Url, cmd[:])
		return
	}
	when ODIN_OS == .Darwin {
		job_start(.Open_Url, {"open", url})
	} else {
		job_start(.Open_Url, {"xdg-open", url})
	}
}

// shell_quote quotes s for a POSIX shell, for arguments that go through
// ssh, which hands the remote shell one joined string.
shell_quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '\'')
	for c in transmute([]u8)s {
		if c == '\'' {
			strings.write_string(&b, `'\''`)
		} else {
			strings.write_byte(&b, c)
		}
	}
	strings.write_byte(&b, '\'')
	return strings.to_string(b)
}
