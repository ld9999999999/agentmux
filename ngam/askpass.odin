package ngam

// ssh asks ngam for passphrases and passwords. ngam runs ssh with
// SSH_ASKPASS set to its own binary. When a key needs a passphrase that
// ssh-agent lacks, or the host wants a password, ssh runs
// `ngam <prompt>`. That copy of ngam sees NGAM_ASKPASS, connects to the
// socket it names, and prints what the user typed into the dialog that
// the running ngam shows.
//
// ssh also shares one connection per host (ControlMaster), so the user
// types the passphrase once for every ssh that ngam runs: listing
// sessions, serving one, creating one.

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:unicode/utf8"
import mu "vendor:microui"
import sdl "vendor:sdl3"

ASKPASS_ENV :: "NGAM_ASKPASS"

// How long ssh keeps a shared connection open after its last use.
CONTROL_PERSIST :: "10m"

// Ask is one question from ssh, waiting for its answer.
Ask :: struct {
	fd:      posix.FD, // the helper's connection; the answer goes here
	hint:    string, // SSH_ASKPASS_PROMPT: "", "confirm" or "none"
	prompt:  string,
	echo:    bool, // a yes/no question: show what is typed
	confirm: bool, // only OK or Cancel
}

Askpass :: struct {
	dir:      string, // /tmp/ngam-<uid>: this socket and ssh's control sockets
	sock:     string, // "" when ssh has no way to ask ngam
	exe:      string, // this binary, for SSH_ASKPASS
	event:    u32, // the SDL event that says a question is waiting
	mutex:    sync.Mutex,
	queue:    [dynamic]^Ask, // guarded by mutex
	// Main thread only.
	current:  ^Ask,
	secret:   [1024]u8,
	len:      int,
	height:   i32, // the dialog's height, measured last frame
}

askpass: Askpass

// askpass_client runs when ssh starts this binary as its askpass helper.
// It returns the exit code: 0 with the answer printed, 1 if cancelled.
askpass_client :: proc(sock: string) -> int {
	prompt := len(os.args) > 1 ? os.args[1] : "Password:"
	hint := os.get_env("SSH_ASKPASS_PROMPT", context.temp_allocator)
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return 1
	}
	defer posix.close(fd)
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	if len(sock) >= len(addr.sun_path) {
		return 1
	}
	copy(addr.sun_path[:], sock)
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		fmt.eprintln("ngam: askpass: cannot reach ngam at", sock)
		return 1
	}
	msg := fmt.tprintf("%s\n%s", hint, prompt)
	if !write_all(fd, transmute([]u8)msg) {
		return 1
	}
	posix.shutdown(fd, .WR)
	reply := read_all(fd, 2048)
	defer delete(reply)
	defer mem.zero_explicit(raw_data(reply), len(reply))
	if len(reply) == 0 || reply[0] != '1' {
		return 1 // cancelled
	}
	_ = write_all(posix.STDOUT_FILENO, reply[1:])
	_ = write_all(posix.STDOUT_FILENO, {'\n'})
	return 0
}

// askpass_init makes the socket that ssh's helpers connect to, and starts
// the thread that takes their questions. If this fails, ssh runs in batch
// mode and cannot ask anything.
askpass_init :: proc() {
	a := &askpass
	a.event = sdl.RegisterEvents(1)
	a.dir = fmt.aprintf("/tmp/ngam-%d", posix.getuid())
	if !private_dir(a.dir) {
		fmt.eprintln("ngam: ssh cannot ask for passphrases: unsafe or missing", a.dir)
		delete(a.dir)
		a.dir = ""
		return
	}
	exe, err := os.get_executable_path(context.allocator)
	if err != nil {
		fmt.eprintln("ngam: ssh cannot ask for passphrases: cannot find ngam's path:", err)
		return
	}
	a.exe = exe
	sock := fmt.aprintf("%s/ask-%d", a.dir, posix.getpid())
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		delete(sock)
		return
	}
	close_on_exec(fd)
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:len(addr.sun_path) - 1], sock)
	csock := strings.clone_to_cstring(sock, context.temp_allocator)
	posix.unlink(csock)
	if posix.bind(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK || posix.listen(fd, 8) != .OK {
		fmt.eprintln("ngam: ssh cannot ask for passphrases: cannot listen on", sock)
		posix.close(fd)
		delete(sock)
		return
	}
	a.sock = sock
	thread.run_with_data(rawptr(uintptr(fd)), askpass_listen)
}

// askpass_stop removes the socket.
askpass_stop :: proc() {
	if askpass.sock != "" {
		posix.unlink(strings.clone_to_cstring(askpass.sock, context.temp_allocator))
	}
}

// askpass_ssh_command starts an ssh command line, with the options for
// asking through ngam and sharing connections. When ngam has no socket,
// ssh runs in batch mode, which fails at once when it needs to ask.
askpass_ssh_command :: proc() -> []string {
	a := &askpass
	cmd := make([dynamic]string, context.temp_allocator)
	if a.sock == "" {
		append(&cmd, "ssh", "-o", "BatchMode=yes")
		return cmd[:]
	}
	// Only ssh gets these variables, so an agent's own ssh or git still
	// asks on its terminal.
	append(&cmd, "env",
		fmt.tprintf("SSH_ASKPASS=%s", a.exe),
		"SSH_ASKPASS_REQUIRE=force",
		fmt.tprintf("%s=%s", ASKPASS_ENV, a.sock),
		"ssh",
		"-o", "ControlMaster=auto",
		"-o", fmt.tprintf("ControlPath=%s/%%C", a.dir),
		"-o", "ControlPersist=" + CONTROL_PERSIST)
	return cmd[:]
}

askpass_open :: proc() -> bool {
	return askpass.current != nil
}

// askpass_handle_event handles the event that says a question is waiting.
// It returns true when ev was that event.
askpass_handle_event :: proc(app: ^App, ev: ^sdl.Event) -> bool {
	if askpass.event == 0 || u32(ev.type) != askpass.event {
		return false
	}
	askpass_next(app)
	return true
}

// askpass_key handles a key press while the dialog is open.
askpass_key :: proc(app: ^App, ev: sdl.KeyboardEvent, action: Key_Action) {
	a := &askpass
	ctrl := ev.mod & sdl.KMOD_CTRL != {}
	cmd := ev.mod & sdl.KMOD_GUI != {}
	switch {
	case action == .Paste:
		askpass_type(clipboard_get())
	case ev.key == sdl.K_RETURN || ev.key == sdl.K_KP_ENTER:
		askpass_answer(app, true)
	case ev.key == sdl.K_ESCAPE:
		askpass_answer(app, false)
	case ev.key == sdl.K_BACKSPACE && (cmd || ctrl), ctrl && ev.key == sdl.K_U:
		mem.zero_explicit(&a.secret, len(a.secret))
		a.len = 0
	case ev.key == sdl.K_BACKSPACE:
		// Remove the whole last UTF-8 character.
		for a.len > 0 {
			a.len -= 1
			b := a.secret[a.len]
			a.secret[a.len] = 0
			if b & 0xC0 != 0x80 {
				break
			}
		}
	}
	app.need_draw = true
}

// askpass_type adds typed or pasted text to the answer.
askpass_type :: proc(text: string) {
	a := &askpass
	if a.current == nil || a.current.confirm {
		return
	}
	for r in text {
		if r == '\n' || r == '\r' {
			continue
		}
		buf, n := utf8.encode_rune(r)
		if a.len + n > len(a.secret) {
			return
		}
		copy(a.secret[a.len:], buf[:n])
		a.len += n
	}
}

// askpass_frame draws the dialog for the current question.
askpass_frame :: proc(app: ^App) {
	a := &askpass
	q := a.current
	if q == nil {
		return
	}
	ctx := &app.ui.ctx
	ui := &app.ui
	d := app.density
	w, h := window_pixels(app)
	if fixed_window(ctx, "!askdim", {0, 0, w, h}, {.NO_TITLE, .NO_RESIZE, .NO_SCROLL, .NO_CLOSE, .NO_FRAME, .NO_INTERACT}, Z_ASK - 1) {
		mu.draw_rect(ctx, {0, 0, w, h}, ui.colors.overlay)
		mu.end_window(ctx)
	}
	ww := min(i32(460 * d), w - i32(32 * d))
	wh := a.height > 0 ? a.height : i32(200 * d)
	r := mu.Rect{(w - ww) / 2, max((h - wh) / 3, i32(16 * d)), ww, wh}
	if !fixed_window(ctx, "!ask", r, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE, .NO_SCROLL}, Z_ASK) {
		return
	}
	defer mu.end_window(ctx)
	row_h := ui.font.cell_h + ctx.style.padding * 2
	btn_w := i32(96 * d)

	group_begin(ui, "ssh")
	mu.layout_row(ctx, {-1}, ui.font.cell_h)
	inner := mu.get_layout(ctx).body.w - ctx.style.padding * 2
	for line in wrap_lines(&ui.font, q.prompt, inner) {
		mu.label(ctx, line)
	}
	if !q.confirm {
		mu.layout_row(ctx, {-1}, row_h)
		fr := mu.layout_next(ctx)
		mu.draw_rect(ctx, fr, ctx.style.colors[.BASE])
		mu.draw_box(ctx, fr, ui.colors.accent)
		shown: string
		if q.echo {
			shown = string(a.secret[:a.len])
		} else {
			// One dot per character, up to the field's width.
			n := min(strings.rune_count(string(a.secret[:a.len])), 64)
			shown = strings.repeat("•", n, context.temp_allocator)
		}
		pad := ctx.style.padding
		at := mu.Vec2{fr.x + pad, fr.y + (fr.h - ui.font.cell_h) / 2}
		mu.push_clip_rect(ctx, fr)
		mu.draw_text(ctx, mu.Font(&ui.font), shown, at, ctx.style.colors[.TEXT])
		caret := at.x + text_width(&ui.font, shown) + 1
		mu.draw_rect(ctx, {caret, at.y, max(i32(d), 1), ui.font.cell_h}, ctx.style.colors[.TEXT])
		mu.pop_clip_rect(ctx)
	}
	group_end(ui)

	mu.layout_row(ctx, {-(btn_w * 2 + ctx.style.spacing), btn_w, -1}, row_h)
	_ = mu.layout_next(ctx)
	if .SUBMIT in mu.button(ctx, "Cancel (Esc)") {
		askpass_answer(app, false)
	}
	if .SUBMIT in mu.button(ctx, "OK") {
		askpass_answer(app, true)
	}
	// Fit the window to what it holds, from the next frame on.
	l := mu.get_layout(ctx)
	need := l.body.y + l.next_row - r.y + ctx.style.padding
	if need != a.height {
		a.height = need
		app.need_draw = true
	}
}

// askpass_answer sends the answer, or a refusal, to the helper and shows
// the next waiting question.
@(private = "file")
askpass_answer :: proc(app: ^App, ok: bool) {
	a := &askpass
	q := a.current
	if q == nil {
		return
	}
	if ok {
		_ = write_all(q.fd, {'1'})
		_ = write_all(q.fd, a.secret[:a.len])
	}
	mem.zero_explicit(&a.secret, len(a.secret))
	a.len = 0
	ask_free(q)
	a.current = nil
	askpass_next(app)
	app.need_draw = true
}

// askpass_next shows the next waiting question.
@(private = "file")
askpass_next :: proc(app: ^App) {
	a := &askpass
	for a.current == nil {
		sync.mutex_lock(&a.mutex)
		q: ^Ask
		if len(a.queue) > 0 {
			q = pop_front(&a.queue)
		}
		sync.mutex_unlock(&a.mutex)
		if q == nil {
			return
		}
		if q.hint == "none" {
			// A notice only, such as "Confirm user presence for key", so a
			// toast is enough.
			show_toast(app, strings.trim_space(q.prompt))
			ask_free(q)
			continue
		}
		a.current = q
		a.height = 0
		app.need_draw = true
		if !app.focused {
			_ = sdl.FlashWindow(app.window, .UNTIL_FOCUSED)
		}
	}
}

@(private = "file")
ask_free :: proc(q: ^Ask) {
	posix.close(q.fd)
	delete(q.hint)
	delete(q.prompt)
	free(q)
}

// askpass_listen takes connections from helpers on its own thread.
@(private = "file")
askpass_listen :: proc(data: rawptr) {
	listener := posix.FD(uintptr(data))
	for {
		fd := posix.accept(listener, nil, nil)
		if fd < 0 {
			if posix.errno() == .EINTR || posix.errno() == .ECONNABORTED {
				continue
			}
			return
		}
		close_on_exec(fd)
		// The folder belongs to this user alone, so only this user's
		// processes can reach the socket. Check anyway, as a second guard.
		if !peer_is_us(fd) {
			posix.close(fd)
			continue
		}
		msg := read_all(fd, 8192)
		text := string(msg)
		hint, _, prompt := strings.partition(text, "\n")
		q := new(Ask)
		q.fd = fd
		q.hint = strings.clone(hint)
		q.prompt = strings.clone(prompt)
		q.confirm = hint == "confirm"
		// ssh's "continue connecting (yes/no/[fingerprint])?" wants a
		// visible answer.
		q.echo = strings.contains(prompt, "(yes/no")
		delete(msg)
		sync.mutex_lock(&askpass.mutex)
		append(&askpass.queue, q)
		sync.mutex_unlock(&askpass.mutex)
		ev: sdl.Event
		ev.type = sdl.EventType(askpass.event)
		_ = sdl.PushEvent(&ev)
	}
}

// private_dir makes dir private to this user, or checks that it already
// is: a real folder (a link fails), owned by this user, mode 0700.
@(private = "file")
private_dir :: proc(dir: string) -> bool {
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	_ = posix.mkdir(cdir, posix.S_IRWXU)
	st: posix.stat_t
	if posix.lstat(cdir, &st) != .OK {
		return false
	}
	if !posix.S_ISDIR(st.st_mode) || st.st_uid != posix.getuid() {
		return false
	}
	perms := st.st_mode - posix.S_IFMT
	return perms == posix.S_IRWXU
}

// peer_is_us reports whether the process at the other end of fd runs as
// this user.
@(private = "file")
peer_is_us :: proc(fd: posix.FD) -> bool {
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
		uid: posix.uid_t
		gid: posix.gid_t
		if getpeereid(fd, &uid, &gid) != 0 {
			return false
		}
		return uid == posix.getuid()
	} else {
		return true // the folder's mode keeps others out
	}
}

when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
	foreign import libc "system:c"
	@(default_calling_convention = "c")
	foreign libc {
		getpeereid :: proc(fd: posix.FD, uid: ^posix.uid_t, gid: ^posix.gid_t) -> c.int ---
	}
}

// wrap_lines breaks text into lines that fit in width. It breaks at
// spaces where it can, and inside a word too long for a line (such as a
// key's path) where it must.
wrap_lines :: proc(f: ^Font, text: string, width: i32) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	clean, _ := strings.remove_all(strings.trim_space(text), "\r", context.temp_allocator)
	for para in strings.split_lines(clean, context.temp_allocator) {
		line := strings.builder_make(context.temp_allocator)
		for word in strings.fields(para, context.temp_allocator) {
			sep := strings.builder_len(line) > 0 ? " " : ""
			if text_width(f, fmt.tprintf("%s%s%s", strings.to_string(line), sep, word)) <= width {
				strings.write_string(&line, sep)
				strings.write_string(&line, word)
				continue
			}
			if strings.builder_len(line) > 0 {
				append(&lines, strings.clone(strings.to_string(line), context.temp_allocator))
				strings.builder_reset(&line)
			}
			for r in word {
				strings.write_rune(&line, r)
				if text_width(f, strings.to_string(line)) > width && strings.builder_len(line) > 1 {
					cur := strings.to_string(line)
					_, size := utf8.decode_last_rune_in_string(cur)
					append(&lines, strings.clone(cur[:len(cur) - size], context.temp_allocator))
					strings.builder_reset(&line)
					strings.write_rune(&line, r)
				}
			}
		}
		append(&lines, strings.clone(strings.to_string(line), context.temp_allocator))
	}
	return lines[:]
}

@(private = "file")
close_on_exec :: proc(fd: posix.FD) {
	_ = posix.fcntl(fd, .SETFD, c.int(posix.FD_CLOEXEC))
}

@(private = "file")
write_all :: proc(fd: posix.FD, b: []u8) -> bool {
	b := b
	for len(b) > 0 {
		n := posix.write(fd, raw_data(b), len(b))
		if n < 0 {
			if posix.errno() == .EINTR {
				continue
			}
			return false
		}
		b = b[n:]
	}
	return true
}

// read_all reads fd until EOF, up to limit bytes.
@(private = "file")
read_all :: proc(fd: posix.FD, limit: int) -> []u8 {
	// Make room for all of it up front. A growing buffer would leave old
	// copies of a secret behind in freed memory.
	buf := make([dynamic]u8, 0, limit)
	chunk: [512]u8
	for len(buf) < limit {
		n := posix.read(fd, &chunk[0], len(chunk))
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		if n <= 0 {
			break
		}
		append(&buf, ..chunk[:n])
	}
	mem.zero_explicit(&chunk, len(chunk))
	return buf[:]
}

