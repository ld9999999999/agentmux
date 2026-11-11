package ngam

// The link to `agentmux serve`: a subprocess with pipes on its stdin and
// stdout, carrying the framed protocol in docs/gui-protocol.md. A reader
// thread splits stdout into frames and queues them for the main thread,
// which wakes up through an SDL user event. A writer thread sends the
// main thread's frames, so a stalled ssh connection never blocks the
// window.

import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import sdl "vendor:sdl3"

// Frame types.
FRAME_CONTROL :: 'C' // both ways: one JSON message
FRAME_NVIM :: 'N' // both ways: bytes of nvim's msgpack-RPC stream
FRAME_AGENT :: 'A' // agent terminal output; keystrokes for the agent
FRAME_RESIZE :: 'R' // GUI -> serve: agent pane rows u16, cols u16

MAX_PAYLOAD :: 4 << 20

Frame :: struct {
	type:    byte,
	payload: []byte, // heap allocated; the main thread frees it
	eof:     bool, // serve's stdout closed; this is the last frame
}

Link :: struct {
	process:  os.Process,
	to_serve: ^os.File, // our end of serve's stdin
	from:     ^os.File, // our end of serve's stdout
	reader:   ^thread.Thread,

	mu:       sync.Mutex,
	queue:    [dynamic]Frame,
	woken:    bool, // a wake event is pending, so the reader can skip sending another

	wake_event: u32, // the SDL user event type that wakes the main loop
	closed:     bool, // stdin is closing: send nothing more

	writer:     ^thread.Thread,
	out:        [dynamic]byte, // frames for the writer, guarded by mu
	out_cond:   sync.Cond, // signals the writer: more to send, or closing
	out_closed: bool, // guarded by mu: close stdin once out is sent
}

// link_start runs command (serve's command line, session included) with
// pipes on its stdin and stdout. Its stderr goes to ours.
link_start :: proc(l: ^Link, command: []string, wake_event: u32) -> bool {
	l.wake_event = wake_event
	in_r, in_w, err1 := os.pipe()
	if err1 != nil {
		fmt.eprintln("ngam: pipe:", err1)
		return false
	}
	out_r, out_w, err2 := os.pipe()
	if err2 != nil {
		fmt.eprintln("ngam: pipe:", err2)
		return false
	}
	env, _ := os.environ(context.allocator)
	p, err := os.process_start({command = command, env = env, stdin = in_r, stdout = out_w, stderr = os.stderr})
	// The child holds its own copies of these ends. Closing ours means
	// serve sees EOF when we close to_serve, and we see EOF when it exits.
	os.close(in_r)
	os.close(out_w)
	if err != nil {
		fmt.eprintfln("ngam: cannot start %v: %v", command, err)
		os.close(in_w)
		os.close(out_r)
		return false
	}
	l.process = p
	l.to_serve = in_w
	l.from = out_r
	l.reader = thread.create_and_start_with_data(l, link_read_loop)
	l.writer = thread.create_and_start_with_data(l, link_write_loop)
	return true
}

// link_write_loop runs on the writer thread. It sends what link_send
// queued, and closes serve's stdin after link_close. A write that fails
// (serve or ssh died) drops the rest.
@(private = "file")
link_write_loop :: proc(data: rawptr) {
	l := (^Link)(data)
	buf: [dynamic]byte
	defer delete(buf)
	failed := false
	for {
		sync.mutex_lock(&l.mu)
		for len(l.out) == 0 && !l.out_closed {
			sync.cond_wait(&l.out_cond, &l.mu)
		}
		buf, l.out = l.out, buf
		clear(&l.out)
		closing := l.out_closed
		sync.mutex_unlock(&l.mu)
		if len(buf) > 0 && !failed {
			if _, err := os.write(l.to_serve, buf[:]); err != nil {
				fmt.eprintln("ngam: write to serve:", err)
				failed = true
			}
		}
		clear(&buf)
		if closing {
			sync.mutex_lock(&l.mu)
			done := len(l.out) == 0
			sync.mutex_unlock(&l.mu)
			if done {
				break
			}
		}
	}
	os.close(l.to_serve)
}

// link_read_loop runs on the reader thread until serve's stdout closes.
@(private = "file")
link_read_loop :: proc(data: rawptr) {
	l := (^Link)(data)
	for {
		header: [5]byte
		if !read_full(l.from, header[:]) {
			break
		}
		n := int(header[1]) << 24 | int(header[2]) << 16 | int(header[3]) << 8 | int(header[4])
		if n > MAX_PAYLOAD {
			fmt.eprintln("ngam: frame too big:", n)
			break
		}
		payload := make([]byte, n)
		if !read_full(l.from, payload) {
			delete(payload)
			break
		}
		link_push(l, Frame{type = header[0], payload = payload})
	}
	link_push(l, Frame{eof = true})
}

@(private = "file")
read_full :: proc(f: ^os.File, buf: []byte) -> bool {
	got := 0
	for got < len(buf) {
		n, err := os.read(f, buf[got:])
		if n <= 0 || (err != nil && n == 0) {
			return false
		}
		got += n
	}
	return true
}

@(private = "file")
link_push :: proc(l: ^Link, f: Frame) {
	sync.mutex_lock(&l.mu)
	append(&l.queue, f)
	wake := !l.woken
	l.woken = true
	sync.mutex_unlock(&l.mu)
	if wake {
		ev: sdl.Event
		ev.type = sdl.EventType(l.wake_event)
		_ = sdl.PushEvent(&ev)
	}
}

// link_take moves the queued frames into out, which the caller then owns.
link_take :: proc(l: ^Link, out: ^[dynamic]Frame) {
	sync.mutex_lock(&l.mu)
	append(out, ..l.queue[:])
	clear(&l.queue)
	l.woken = false
	sync.mutex_unlock(&l.mu)
}

// link_send queues one frame for serve. Only the main thread sends.
link_send :: proc(l: ^Link, type: byte, payload: []byte) {
	if l.closed {
		return
	}
	n := len(payload)
	header := [5]byte{type, byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n)}
	sync.mutex_lock(&l.mu)
	append(&l.out, ..header[:])
	append(&l.out, ..payload)
	sync.mutex_unlock(&l.mu)
	sync.cond_signal(&l.out_cond)
}

// link_close closes serve's stdin once the queued frames are sent, which
// ends the session's editor: serve has nvim save its snapshot, then exits.
link_close :: proc(l: ^Link) {
	if l.closed {
		return
	}
	l.closed = true
	sync.mutex_lock(&l.mu)
	l.out_closed = true
	sync.mutex_unlock(&l.mu)
	sync.cond_signal(&l.out_cond)
}

// link_kill ends serve (or the ssh that runs it) at once, for a link that
// is stuck. The reader and writer threads then see their pipes close.
link_kill :: proc(l: ^Link) {
	link_close(l)
	_ = os.process_kill(l.process)
}

// link_wait waits for serve to exit, killing it if it takes longer than
// serve's own timeouts (3s to save, 5s for nvim to quit). It returns
// serve's exit code.
link_wait :: proc(l: ^Link) -> int {
	state, err := os.process_wait(l.process, 10 * time.Second)
	if err == nil && state.exited {
		return state.exit_code
	}
	fmt.eprintln("ngam: serve did not exit; killing it")
	_ = os.process_kill(l.process)
	_, _ = os.process_wait(l.process)
	return 1
}

// link_destroy frees what link_start made, once serve has exited (after
// link_close and link_wait): the reader thread has seen EOF and stops.
link_destroy :: proc(l: ^Link) {
	if l.writer != nil {
		thread.join(l.writer)
		thread.destroy(l.writer)
		l.writer = nil
	}
	delete(l.out)
	if l.reader != nil {
		thread.join(l.reader)
		thread.destroy(l.reader)
		l.reader = nil
	}
	os.close(l.from)
	for f in l.queue {
		delete(f.payload)
	}
	delete(l.queue)
}
