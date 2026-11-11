package ngam

// The preview server: a small web server inside ngam that shows the
// session's files in a browser. You can look at an agent's HTML, SVG or
// images where they are, even when the session is on an ssh host.
//
//   http(s)://127.0.0.1:<port>/<token>/<path relative to the session's folder>
//   http(s)://127.0.0.1:<port>/<token>/~abs/<absolute path>
//
// It listens on 127.0.0.1 only. The random token in each URL keeps other
// local programs and web pages from reading files. The server refuses any
// request whose Host header is something other than 127.0.0.1:<port> or
// localhost:<port>, which stops DNS rebinding. It sends no CORS headers.
//
// nvim reads the files (vim.uv.fs_open and fs_read, about 1 MB at a time)
// and sends them over the session's own connection. A connection thread
// queues a fetch, and the main thread sends it to nvim and posts the
// answer back.
//
// Live reload. Pages reload by themselves when a file they use changes:
//   * watch.lua, run in nvim, watches the files the server has served and
//     tells ngam when one changes (file_changed).
//   * The server notes which files each page uses. A page is a request the
//     browser makes as a document, or a request that lacks a Referer from
//     this server. A request whose Referer is a page (or a file a page
//     uses, such as a style sheet) is one of that page's files.
//   * HTML pages get <script src="/<token>/~live.js"> before </body>. The
//     script listens to /<token>/~events?page=<its path>, a stream of
//     Server-Sent Events, and reloads the page when a change comes.
//   * Other files (images, audio, video, PDF, text) are opened in a small
//     viewer page, /<token>/~view/<path>, that shows the file and reloads
//     only the file when it changes, so a video keeps its place.
//   * Markdown files are rendered as HTML pages (markdown/markdown.odin),
//     with the script, so they reload like HTML. ?raw gives the plain text.
// Every response has Cache-Control: no-store, so a reload gets fresh data.

import "core:c"
import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:net"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import sdl "vendor:sdl3"
import mp "msgpack"
import "markdown"
import "tls"

CHUNK :: 1 << 20 // bytes per fetch from nvim
MAX_HEADER :: 16 << 10

Preview_Server :: struct {
	running:    bool,
	scheme:     string, // "http" or "https"
	asked_port: int, // the port setting it was started with; 0 means any port
	port:       int, // the port it listens on
	token:      string, // made once per run of ngam
	listener:   net.TCP_Socket,
	acceptor:   ^thread.Thread,
	stop:       bool, // set to stop the accept loop (atomic)
	tls:        rawptr, // the SSL_CTX, for https
	cert_path:  string,
	error:      string, // why it failed to start
	wake_event: u32,

	mu:         sync.Mutex,
	root:       string, // the session's folder, "" with no session; guarded by mu
	queue:      [dynamic]^Fetch, // fetches for the main thread; guarded by mu
	touch:      [dynamic]string, // files to (re)watch in nvim; guarded by mu
	pages:      map[string]^Page, // by page key (see page_key); guarded by mu
	streams:    [dynamic]^Stream, // open ~events connections; guarded by mu
}

// Page is a page some browser loaded, and the files it uses.
@(private = "file")
Page :: struct {
	files: map[string]bool, // files on nvim's machine
	used:  time.Tick, // when the page was last loaded
}

// Stream is one open ~events connection, for one page.
@(private = "file")
Stream :: struct {
	page:    string, // the page key
	changed: [dynamic]string, // changed files not sent yet; guarded by mu
	wake:    sync.Sema, // posted when changed gets a file
}

PAGE_FORGET :: time.Hour // forget a page after this long without a load, unless a browser has it open
STREAM_PING :: 15 * time.Second // send a comment line this often to find closed connections
STREAM_TOUCH :: 60 * time.Second // ask nvim again this often to keep watching a page's files
MAX_INJECT :: 32 << 20 // the live reload script goes only into HTML pages up to this size
MAX_MARKDOWN :: 4 << 20 // larger Markdown files are sent as plain text

// Fetch is one read of a file through nvim.
Fetch :: struct {
	path:   string,
	offset: i64,
	length: i64,
	done:   sync.Sema, // posted by the main thread when the fields below are set
	kind:   string, // "file", "dir", "missing", "denied", "nosession" or "error"
	size:   i64, // the file's size
	data:   []byte,
}

// no_inherit keeps a socket out of the programs ngam starts (serve, and
// through it nvim). A program that inherited it would hold the port open.
@(private = "file")
no_inherit :: proc(sock: net.TCP_Socket) {
	_ = posix.fcntl(posix.FD(sock), .SETFD, c.int(posix.FD_CLOEXEC))
}

// One HTTP connection, handled on its own thread.
@(private = "file")
Conn :: struct {
	srv:  ^Preview_Server,
	sock: net.TCP_Socket,
	ssl:  rawptr,
	port: int,
}

// Lua run in nvim: read up to len bytes of path from offset off. It also
// watches each file it serves for changes (see watch.lua).
@(private = "file")
FETCH_LUA :: `
local path, off, len = ...
local st = vim.uv.fs_stat(path)
if not st then return {'missing'} end
if st.type == 'directory' then return {'dir'} end
if st.type ~= 'file' then return {'missing'} end
local W = rawget(_G, '__ngam_watch')
if W then W.watch_files({path}) end
local fd = vim.uv.fs_open(path, 'r', 0)
if not fd then return {'denied'} end
local data = ''
if len > 0 and off < st.size then data = vim.uv.fs_read(fd, len, off) or '' end
vim.uv.fs_close(fd)
return {'file', st.size, data}
`

// The file watchers, sent to nvim when a session starts.
@(private = "file")
WATCH_LUA :: #load("lua/watch.lua", string)

// preview_session_started sets up the file watchers in a new session's
// nvim.
preview_session_started :: proc(app: ^App) {
	exec_lua(app, WATCH_LUA, {})
}

// preview_file_changed is called when nvim says a watched file changed. It
// tells the open pages that use the file.
preview_file_changed :: proc(app: ^App, path: string) {
	srv := &app.preview
	sync.mutex_lock(&srv.mu)
	defer sync.mutex_unlock(&srv.mu)
	for s in srv.streams {
		p := srv.pages[s.page]
		if p != nil && p.files[path] {
			append(&s.changed, strings.clone(path))
			sync.sema_post(&s.wake)
		}
	}
}

// preview_apply starts, stops or restarts the server to match the
// settings.
preview_apply :: proc(app: ^App) {
	srv := &app.preview
	srv.wake_event = app.wake_event
	want := app.settings.preview
	if srv.running && (want != srv.scheme || app.settings.preview_port != srv.asked_port) {
		preview_stop(srv)
	}
	if want == "off" {
		delete(srv.error)
		srv.error = ""
		return
	}
	if !srv.running {
		preview_start(srv, want, app.settings.preview_port)
	}
	app.need_draw = true
}

@(private = "file")
preview_start :: proc(srv: ^Preview_Server, scheme: string, port: int) {
	delete(srv.error)
	srv.error = ""
	if srv.token == "" {
		raw: [16]u8
		crypto.rand_bytes(raw[:])
		srv.token = string(hex.encode(raw[:]))
	}
	if scheme == "https" {
		ctx, cert, err := tls.server_ctx(config_dir(context.temp_allocator))
		if ctx == nil {
			srv.error = strings.clone(err)
			return
		}
		srv.tls = ctx
		srv.cert_path = cert
	} else {
		srv.tls = nil
	}
	sock, err := net.listen_tcp({net.IP4_Loopback, port}, 64)
	if err != nil {
		srv.error = fmt.aprintf("Cannot listen on 127.0.0.1:%d: %v", port, err)
		return
	}
	no_inherit(sock)
	ep, _ := net.bound_endpoint(sock)
	srv.listener = sock
	srv.port = ep.port
	srv.asked_port = port
	srv.scheme = scheme
	sync.atomic_store(&srv.stop, false)
	srv.acceptor = thread.create_and_start_with_data(srv, accept_loop)
	srv.running = true
}

// preview_stop stops taking connections. Requests already being answered
// finish on their own threads.
preview_stop :: proc(srv: ^Preview_Server) {
	if !srv.running {
		return
	}
	sync.atomic_store(&srv.stop, true)
	thread.join(srv.acceptor)
	thread.destroy(srv.acceptor)
	net.close(srv.listener)
	// Keep the SSL_CTX, since a connection may still be using it.
	srv.running = false
}

preview_set_root :: proc(srv: ^Preview_Server, root: string) {
	sync.mutex_lock(&srv.mu)
	defer sync.mutex_unlock(&srv.mu)
	delete(srv.root)
	r := root
	for len(r) > 1 && strings.has_suffix(r, "/") {
		r = r[:len(r) - 1]
	}
	srv.root = strings.clone(r)
}

// preview_status describes the server for the setup screen.
preview_status :: proc(app: ^App) -> string {
	srv := &app.preview
	switch {
	case srv.error != "":
		return srv.error
	case !srv.running:
		return "Off. Turn it on to use :AgentPreview, the ▶ buttons and Cmd-click in the Explorer."
	case srv.scheme == "https":
		return fmt.tprintf("Serving https://127.0.0.1:%d/%s/ with the certificate in %s. Browsers warn about it until you trust it; see the README.", srv.port, srv.token, srv.cert_path)
	}
	return fmt.tprintf("Serving http://127.0.0.1:%d/%s/ (the session's folder).", srv.port, srv.token)
}

// preview_open shows path (absolute, on nvim's machine) in the browser.
// When dir is true, path is a folder and the browser shows its index.html.
preview_open :: proc(app: ^App, path: string, dir := false) {
	srv := &app.preview
	if app.settings.preview == "off" {
		show_toast(app, "The preview server is off. Turn it on in setup (Cmd-,).")
		return
	}
	// :AgentPreview gives folders a trailing slash.
	folder := dir || strings.has_suffix(path, "/")
	if !folder && path != app.session.cwd && !previewable(path) {
		show_toast(app, fmt.tprintf("%s is not a type browsers show (it would download). Previews are for HTML, images, audio, video, PDF and text.", filepath.base(path)))
		return
	}
	if !srv.running {
		preview_apply(app)
		if !srv.running {
			show_toast(app, srv.error)
			return
		}
	}
	root := app.session.cwd
	for len(root) > 1 && strings.has_suffix(root, "/") {
		root = root[:len(root) - 1]
	}
	rel: string
	switch {
	case root != "" && path == root:
		rel = ""
	case root != "" && strings.has_prefix(path, root) && len(path) > len(root) && path[len(root)] == '/':
		rel = path[len(root) + 1:]
	case:
		rel = strings.concatenate({"~abs", path}, context.temp_allocator)
	}
	// HTML pages, Markdown (rendered as a page) and folders open directly.
	// Other files open in the viewer, which reloads just the file when it
	// changes.
	if !folder && path != app.session.cwd && !strings.has_prefix(content_type(path), "text/html") && !is_markdown(path) {
		rel = strings.concatenate({"~view/", rel}, context.temp_allocator)
	}
	url := fmt.tprintf("%s://127.0.0.1:%d/%s/%s", srv.scheme, srv.port, srv.token, url_path(rel))
	open_url(url)
	show_toast(app, fmt.tprintf("Opening %s", url))
}

// preview_current_buffer previews the file in nvim's current buffer.
preview_current_buffer :: proc(app: ^App) {
	exec_lua(app, "return vim.api.nvim_buf_get_name(0)", {}, proc(app: ^App, result: mp.Value, failed: bool, _: rawptr) {
		name := mp.as_str(result)
		if failed || name == "" {
			show_toast(app, "The current buffer has no file to preview.")
			return
		}
		preview_open(app, name)
	})
}

// url_path percent-encodes each part of a path for a URL.
@(private = "file")
url_path :: proc(rel: string) -> string {
	parts := strings.split(rel, "/", context.temp_allocator)
	for &p in parts {
		p = net.percent_encode(p, context.temp_allocator)
	}
	return strings.join(parts, "/", context.temp_allocator)
}

// preview_pump sends the queued fetches, and files to watch, to nvim. It
// runs on the main thread.
preview_pump :: proc(app: ^App) {
	srv := &app.preview
	sync.mutex_lock(&srv.mu)
	if len(srv.queue) == 0 && len(srv.touch) == 0 {
		sync.mutex_unlock(&srv.mu)
		return
	}
	fetches := make([]^Fetch, len(srv.queue), context.temp_allocator)
	copy(fetches, srv.queue[:])
	clear(&srv.queue)
	touch := make([]mp.Value, len(srv.touch), context.temp_allocator)
	for t, i in srv.touch {
		touch[i] = strings.clone(t, context.temp_allocator)
		delete(t)
	}
	clear(&srv.touch)
	sync.mutex_unlock(&srv.mu)
	if len(touch) > 0 {
		exec_lua(app, "local W = rawget(_G, '__ngam_watch')\nif W then W.watch_files((...)) end", {touch})
	}
	for f in fetches {
		if !exec_lua(app, FETCH_LUA, {f.path, f.offset, f.length}, fetch_done, f) {
			f.kind = "nosession"
			sync.sema_post(&f.done)
		}
	}
}

@(private = "file")
fetch_done :: proc(app: ^App, result: mp.Value, failed: bool, user: rawptr) {
	f := (^Fetch)(user)
	defer sync.sema_post(&f.done)
	if failed {
		f.kind = "error"
		return
	}
	r := mp.as_array(result)
	f.kind = strings.clone(mp.as_str(mp.at(r, 0)))
	f.size = mp.as_int(mp.at(r, 1))
	// The answer lives only until this returns, so copy the bytes.
	#partial switch d in mp.at(r, 2) {
	case string:
		f.data = transmute([]byte)strings.clone(d)
	case mp.Bin:
		f.data = make([]byte, len(d))
		copy(f.data, ([]byte)(d))
	}
}

// fetch asks the main thread to read a file through nvim, and waits. It
// returns nil when nvim takes too long to answer.
@(private = "file")
fetch :: proc(srv: ^Preview_Server, path: string, offset, length: i64) -> ^Fetch {
	f := new(Fetch)
	f.path = strings.clone(path)
	f.offset = offset
	f.length = length
	sync.mutex_lock(&srv.mu)
	append(&srv.queue, f)
	sync.mutex_unlock(&srv.mu)
	ev: sdl.Event
	ev.type = sdl.EventType(srv.wake_event)
	_ = sdl.PushEvent(&ev)
	if !sync.sema_wait_with_timeout(&f.done, 30 * time.Second) {
		return nil // leave f to the main thread, which may still answer
	}
	return f
}

@(private = "file")
fetch_free :: proc(f: ^Fetch) {
	if f == nil {
		return
	}
	delete(f.path)
	if f.kind != "nosession" && f.kind != "error" {
		delete(f.kind)
	}
	delete(f.data)
	free(f)
}

// accept_loop takes connections until stop is set. It polls with a
// timeout because on macOS a blocked accept stays blocked when the socket
// closes.
@(private = "file")
accept_loop :: proc(data: rawptr) {
	srv := (^Preview_Server)(data)
	for !sync.atomic_load(&srv.stop) {
		pfd := posix.pollfd {
			fd     = posix.FD(srv.listener),
			events = {.IN},
		}
		if posix.poll(&pfd, 1, 250) <= 0 {
			continue
		}
		client, _, err := net.accept_tcp(srv.listener)
		if err != nil {
			continue
		}
		no_inherit(client)
		c := new(Conn)
		c^ = {srv = srv, sock = client, ssl = srv.tls, port = srv.port}
		thread.run_with_data(c, serve_conn)
	}
}

@(private = "file")
serve_conn :: proc(data: rawptr) {
	c := (^Conn)(data)
	defer free(c)
	defer net.close(c.sock)
	defer free_all(context.temp_allocator)
	// The timeouts free the thread when a client goes silent.
	_ = net.set_option(c.sock, .Receive_Timeout, 15 * time.Second)
	_ = net.set_option(c.sock, .Send_Timeout, 30 * time.Second)
	if c.ssl != nil {
		// Up to here c.ssl holds the SSL_CTX. From here on it holds the
		// connection's SSL.
		c.ssl = tls.accept(c.ssl, c.sock)
		if c.ssl == nil {
			return
		}
	}
	defer if c.ssl != nil {
		tls.close(c.ssl)
	}
	handle_request(c)
}

@(private = "file")
conn_recv :: proc(c: ^Conn, buf: []byte) -> int {
	if c.ssl != nil {
		return tls.read(c.ssl, buf)
	}
	n, err := net.recv_tcp(c.sock, buf)
	if err != nil {
		return -1
	}
	return n
}

@(private = "file")
conn_send :: proc(c: ^Conn, data: []byte) -> bool {
	sent := 0
	for sent < len(data) {
		n: int
		if c.ssl != nil {
			n = tls.write(c.ssl, data[sent:])
		} else {
			m, err := net.send_tcp(c.sock, data[sent:])
			n = err != nil ? -1 : m
		}
		if n <= 0 {
			return false
		}
		sent += n
	}
	return true
}

// respond sends a whole response with a short text body.
@(private = "file")
respond :: proc(c: ^Conn, status: string, body: string, extra := "") {
	head := fmt.tprintf(
		"HTTP/1.1 %s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n%s\r\n",
		status,
		len(body),
		extra,
	)
	if conn_send(c, transmute([]byte)head) {
		_ = conn_send(c, transmute([]byte)body)
	}
}

@(private = "file")
handle_request :: proc(c: ^Conn) {
	srv := c.srv
	// Read the request line and headers.
	buf := make([]byte, MAX_HEADER, context.temp_allocator)
	got := 0
	end := -1
	for end < 0 {
		if got == len(buf) {
			respond(c, "431 Request Header Fields Too Large", "Headers too large.\n")
			return
		}
		n := conn_recv(c, buf[got:])
		if n <= 0 {
			return
		}
		got += n
		end = strings.index(string(buf[:got]), "\r\n\r\n")
	}
	text := string(buf[:end])
	lines := strings.split(text, "\r\n", context.temp_allocator)
	first := strings.fields(lines[0], context.temp_allocator)
	if len(first) != 3 {
		respond(c, "400 Bad Request", "Bad request.\n")
		return
	}
	method, target := first[0], first[1]
	host, range_h, referer, dest := "", "", "", ""
	for line in lines[1:] {
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		name := strings.to_lower(strings.trim_space(line[:colon]), context.temp_allocator)
		value := strings.trim_space(line[colon + 1:])
		switch name {
		case "host":
			host = value
		case "range":
			range_h = value
		case "referer":
			referer = value
		case "sec-fetch-dest":
			dest = value
		}
	}

	// Accept only this server's own names. A page on another site can point
	// a DNS name at 127.0.0.1, but its requests then carry that other name.
	if host != fmt.tprintf("127.0.0.1:%d", c.port) && host != fmt.tprintf("localhost:%d", c.port) {
		respond(c, "403 Forbidden", "Wrong Host header.\n")
		return
	}
	if method != "GET" && method != "HEAD" {
		respond(c, "405 Method Not Allowed", "Only GET and HEAD.\n", "Allow: GET, HEAD\r\n")
		return
	}
	path, query := target, ""
	if i := strings.index_byte(path, '#'); i >= 0 {
		path = path[:i]
	}
	if i := strings.index_byte(path, '?'); i >= 0 {
		path, query = path[:i], path[i + 1:]
	}
	prefix := strings.concatenate({"/", srv.token}, context.temp_allocator)
	if path == prefix {
		respond(c, "301 Moved Permanently", "", fmt.tprintf("Location: %s/\r\n", prefix))
		return
	}
	rel, status := decode_path(srv, path)
	if status != "" {
		respond(c, status, status == "404 Not Found" ? "Not found.\n" : "Bad path.\n")
		return
	}

	// ngam's own paths start with ~.
	switch {
	case rel == "~live.js":
		send_whole(c, method, "200 OK", "text/javascript; charset=utf-8", transmute([]byte)live_js(srv))
		return
	case rel == "~events":
		serve_events(c, query_param(query, "page"))
		return
	case strings.has_prefix(rel, "~view/"):
		serve_viewer(c, method, rel[len("~view/"):])
		return
	}

	// The file on nvim's machine.
	file, have_root := resolve(srv, rel)
	if !have_root {
		respond(c, "503 Service Unavailable", "No session is open in ngam.\n")
		return
	}

	// Range: one range of bytes, "start-end", "start-" or "-suffix".
	// For any other form, send the whole file.
	has_range := false
	start, last, suffix: i64 = 0, -1, -1
	if strings.has_prefix(range_h, "bytes=") && !strings.contains_rune(range_h, ',') {
		spec := range_h[len("bytes="):]
		if dash := strings.index_byte(spec, '-'); dash >= 0 {
			a, b := strings.trim_space(spec[:dash]), strings.trim_space(spec[dash + 1:])
			av, aok := strconv.parse_i64(a)
			bv, bok := strconv.parse_i64(b)
			switch {
			case a == "" && bok && bv >= 0:
				has_range, suffix = true, bv
			case aok && av >= 0 && b == "":
				has_range, start = true, av
			case aok && bok && av >= 0 && bv >= av:
				has_range, start, last = true, av, bv
			}
		}
	}

	// The first fetch gives the file's size, and its first bytes when the
	// start is known.
	f := fetch(srv, file, suffix >= 0 ? 0 : start, suffix >= 0 ? 0 : CHUNK)
	defer fetch_free(f)
	if !fetch_ok(c, f, path) {
		return
	}

	// Note which page this file belongs to, for live reload.
	ref_key := ""
	if ref_path := same_origin_path(c, referer); ref_path != "" {
		ref_key = page_key(srv, ref_path)
	}
	note_file(srv, file, dest == "document" || ref_key == "", ref_key)

	size := f.size
	ctype := content_type(file)

	// An HTML page gets the live reload script, so read it whole first.
	if strings.has_prefix(ctype, "text/html") && !has_range && size <= MAX_INJECT {
		tag := live_tag(srv)
		if method == "HEAD" {
			send_head(c, "200 OK", ctype, size + i64(len(tag)))
			return
		}
		send_whole(c, method, "200 OK", ctype, inject(read_whole(srv, file, f, size, len(tag)), tag))
		return
	}

	// A Markdown file is rendered as a page with the live reload script,
	// unless ?raw asks for the text. HEAD renders it too, for the length.
	if is_markdown(file) && !has_range && size <= MAX_MARKDOWN && !has_param(query, "raw") {
		src := string(read_whole(srv, file, f, size))
		page := markdown.page(filepath.base(file), src, live_tag(srv))
		send_whole(c, method, "200 OK", "text/html; charset=utf-8", transmute([]byte)page)
		return
	}

	status_line := "200 OK"
	extra := ""
	if has_range {
		if suffix >= 0 {
			start = max(size - suffix, 0)
			last = size - 1
		}
		if last < 0 || last >= size {
			last = size - 1
		}
		if start >= size || start > last {
			respond(c, "416 Range Not Satisfiable", "", fmt.tprintf("Content-Range: bytes */%d\r\n", size))
			return
		}
		status_line = "206 Partial Content"
		extra = fmt.tprintf("Content-Range: bytes %d-%d/%d\r\n", start, last, size)
	} else {
		start, last = 0, size - 1
	}
	length := last - start + 1
	if !send_head(c, status_line, ctype, length, extra) || method == "HEAD" {
		return
	}

	// Send the body one chunk at a time.
	sent: i64 = 0
	chunk: []byte
	if suffix < 0 {
		chunk = f.data
	}
	cur: ^Fetch
	defer fetch_free(cur)
	for sent < length {
		if len(chunk) == 0 {
			fetch_free(cur)
			cur = fetch(srv, file, start + sent, min(CHUNK, length - sent))
			if cur == nil || cur.kind != "file" || len(cur.data) == 0 {
				return // the file changed or the session closed; the client gets a short body
			}
			chunk = cur.data
		}
		n := min(i64(len(chunk)), length - sent)
		if !conn_send(c, chunk[:n]) {
			return
		}
		sent += n
		chunk = nil
	}
}

// read_whole reads all of a file whose first fetch is f, so it can be
// changed before it is sent, with room for extra bytes more. It stops
// early if the file got shorter.
@(private = "file")
read_whole :: proc(srv: ^Preview_Server, file: string, f: ^Fetch, size: i64, extra := 0) -> []byte {
	data := make([dynamic]byte, 0, int(size) + extra, context.temp_allocator)
	append(&data, ..f.data)
	for i64(len(data)) < size {
		more := fetch(srv, file, i64(len(data)), min(CHUNK, size - i64(len(data))))
		done := more == nil || more.kind != "file" || len(more.data) == 0
		if !done {
			append(&data, ..more.data)
		}
		fetch_free(more)
		if done {
			break // the file got shorter; send what there is
		}
	}
	return data[:]
}

// fetch_ok returns true when the fetch found a file. Otherwise it answers
// the request with an error and returns false.
@(private = "file")
fetch_ok :: proc(c: ^Conn, f: ^Fetch, path: string) -> bool {
	if f == nil {
		respond(c, "504 Gateway Timeout", "nvim did not answer.\n")
		return false
	}
	switch f.kind {
	case "file":
		return true
	case "dir":
		respond(c, "301 Moved Permanently", "", fmt.tprintf("Location: %s/\r\n", path))
	case "missing":
		respond(c, "404 Not Found", "No such file.\n")
	case "denied":
		respond(c, "403 Forbidden", "Cannot read the file.\n")
	case "nosession":
		respond(c, "503 Service Unavailable", "No session is open in ngam.\n")
	case:
		respond(c, "502 Bad Gateway", "nvim could not read the file.\n")
	}
	return false
}

// send_head sends a response's status line and headers.
@(private = "file")
send_head :: proc(c: ^Conn, status, ctype: string, length: i64, extra := "") -> bool {
	head := fmt.tprintf(
		"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n%s\r\n",
		status,
		ctype,
		length,
		extra,
	)
	return conn_send(c, transmute([]byte)head)
}

// send_whole sends a response whose body is all in memory.
@(private = "file")
send_whole :: proc(c: ^Conn, method, status, ctype: string, body: []byte) {
	if send_head(c, status, ctype, i64(len(body))) && method != "HEAD" {
		_ = conn_send(c, body)
	}
}

// decode_path checks that a URL path starts with the token and decodes
// what follows it. status is "" when it is good, or an HTTP status.
@(private = "file")
decode_path :: proc(srv: ^Preview_Server, path: string) -> (rel: string, status: string) {
	prefix := strings.concatenate({"/", srv.token, "/"}, context.temp_allocator)
	if !strings.has_prefix(path, prefix) {
		return "", "404 Not Found"
	}
	ok: bool
	rel, ok = net.percent_decode(path[len(prefix):], context.temp_allocator)
	if !ok || strings.contains_rune(rel, 0) {
		return "", "400 Bad Request"
	}
	for seg in strings.split(rel, "/", context.temp_allocator) {
		if seg == ".." {
			return "", "403 Forbidden"
		}
	}
	return rel, ""
}

// resolve turns a decoded path after the token into the file on nvim's
// machine. have_root is true when a session is open.
@(private = "file")
resolve :: proc(srv: ^Preview_Server, rel: string) -> (file: string, have_root: bool) {
	if strings.has_prefix(rel, "~abs/") {
		file = rel[len("~abs"):]
	} else {
		sync.mutex_lock(&srv.mu)
		root := strings.clone(srv.root, context.temp_allocator)
		sync.mutex_unlock(&srv.mu)
		if root == "" {
			return "", false
		}
		file = strings.concatenate({root, "/", rel}, context.temp_allocator)
	}
	if rel == "" || strings.has_suffix(rel, "/") {
		file = strings.concatenate({file, "index.html"}, context.temp_allocator)
	}
	return file, true
}

// page_key names the page at a URL path: the file it shows, or
// "view:<file>" for a viewer page. It is "" for anything else.
@(private = "file")
page_key :: proc(srv: ^Preview_Server, url_path: string) -> string {
	rel, status := decode_path(srv, url_path)
	if status != "" {
		return ""
	}
	if strings.has_prefix(rel, "~view/") {
		file, ok := resolve(srv, rel[len("~view/"):])
		return ok ? strings.concatenate({"view:", file}, context.temp_allocator) : ""
	}
	if strings.has_prefix(rel, "~") && !strings.has_prefix(rel, "~abs/") {
		return ""
	}
	file, ok := resolve(srv, rel)
	return ok ? file : ""
}

// same_origin_path returns the path of a Referer from this server, minus
// its query. Any other Referer gives "".
@(private = "file")
same_origin_path :: proc(c: ^Conn, referer: string) -> string {
	scheme := c.ssl != nil ? "https" : "http"
	for host in ([]string{"127.0.0.1", "localhost"}) {
		origin := fmt.tprintf("%s://%s:%d/", scheme, host, c.port)
		if strings.has_prefix(referer, origin) {
			p := referer[len(origin) - 1:]
			if i := strings.index_any(p, "?#"); i >= 0 {
				p = p[:i]
			}
			return p
		}
	}
	return ""
}

// query_param returns the decoded value of name in a query string.
@(private = "file")
query_param :: proc(query, name: string) -> string {
	for part in strings.split(query, "&", context.temp_allocator) {
		eq := strings.index_byte(part, '=')
		if eq >= 0 && part[:eq] == name {
			v, ok := net.percent_decode(part[eq + 1:], context.temp_allocator)
			return ok ? v : ""
		}
	}
	return ""
}

// has_param reports whether a query string has name, with or without a
// value.
@(private = "file")
has_param :: proc(query, name: string) -> bool {
	for part in strings.split(query, "&", context.temp_allocator) {
		if part == name || (strings.has_prefix(part, name) && len(part) > len(name) && part[len(name)] == '=') {
			return true
		}
	}
	return false
}

// note_file records that file was served. As a page, it starts the page's
// list of files afresh. As a file of the page ref_key (or of the pages
// that use the file ref_key, such as a style sheet's font), it is added to
// their lists.
@(private = "file")
note_file :: proc(srv: ^Preview_Server, file: string, is_page: bool, ref_key: string) {
	sync.mutex_lock(&srv.mu)
	defer sync.mutex_unlock(&srv.mu)
	if is_page {
		set_page(srv, file, file)
		return
	}
	if p := srv.pages[ref_key]; p != nil {
		add_file(p, file)
	}
	for _, p in srv.pages {
		if p.files[ref_key] {
			add_file(p, file)
		}
	}
}

@(private = "file")
add_file :: proc(p: ^Page, file: string) {
	if !p.files[file] {
		p.files[strings.clone(file)] = true
	}
}

// set_page starts the page key's list of files afresh with own, the file it
// shows. srv.mu must be held.
@(private = "file")
set_page :: proc(srv: ^Preview_Server, key, own: string) -> ^Page {
	forget_old_pages(srv)
	p := srv.pages[key]
	if p == nil {
		p = new(Page)
		srv.pages[strings.clone(key)] = p
	}
	for f in p.files {
		delete(f)
	}
	clear(&p.files)
	add_file(p, own)
	p.used = time.tick_now()
	return p
}

// forget_old_pages drops pages that went PAGE_FORGET without a load and
// that no browser listens to. srv.mu must be held.
@(private = "file")
forget_old_pages :: proc(srv: ^Preview_Server) {
	old := make([dynamic]string, context.temp_allocator)
	outer: for key, p in srv.pages {
		if time.tick_since(p.used) < PAGE_FORGET {
			continue
		}
		for s in srv.streams {
			if s.page == key {
				continue outer
			}
		}
		append(&old, key)
	}
	for key in old {
		k, p := delete_key(&srv.pages, key)
		for f in p.files {
			delete(f)
		}
		delete(p.files)
		free(p)
		delete(k)
	}
}

// touch_page asks nvim (through the main thread) to keep watching a page's
// files. srv.mu must be held.
@(private = "file")
touch_page :: proc(srv: ^Preview_Server, key: string) {
	p := srv.pages[key]
	if p == nil {
		return
	}
	for f in p.files {
		append(&srv.touch, strings.clone(f))
	}
	ev: sdl.Event
	ev.type = sdl.EventType(srv.wake_event)
	_ = sdl.PushEvent(&ev)
}

// serve_events holds a ~events connection open and sends a "change" event
// each time a file the page uses changes. A comment line goes every
// STREAM_PING, so a closed connection is found and let go.
@(private = "file")
serve_events :: proc(c: ^Conn, page_path: string) {
	srv := c.srv
	key := page_key(srv, page_path)
	if key == "" {
		respond(c, "404 Not Found", "No such page.\n")
		return
	}
	s := new(Stream)
	s.page = strings.clone(key)
	sync.mutex_lock(&srv.mu)
	if srv.pages[key] == nil {
		// The browser loaded this page before ngam started, so the page
		// watches at least its own file.
		set_page(srv, key, strings.trim_prefix(key, "view:"))
	}
	append(&srv.streams, s)
	touch_page(srv, s.page)
	sync.mutex_unlock(&srv.mu)
	defer {
		sync.mutex_lock(&srv.mu)
		for x, i in srv.streams {
			if x == s {
				unordered_remove(&srv.streams, i)
				break
			}
		}
		for f in s.changed {
			delete(f)
		}
		delete(s.changed)
		sync.mutex_unlock(&srv.mu)
		delete(s.page)
		free(s)
	}

	head := "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\nretry: 2000\n: watching\n\n"
	if !conn_send(c, transmute([]byte)head) {
		return
	}
	last_touch := time.tick_now()
	for {
		_ = sync.sema_wait_with_timeout(&s.wake, STREAM_PING)
		sync.mutex_lock(&srv.mu)
		changed := s.changed
		s.changed = {}
		if time.tick_since(last_touch) >= STREAM_TOUCH {
			touch_page(srv, s.page) // s.page, since key lives in the temp allocator, freed below
			last_touch = time.tick_now()
		}
		sync.mutex_unlock(&srv.mu)
		b := strings.builder_make(context.temp_allocator)
		if len(changed) == 0 {
			strings.write_string(&b, ": ping\n\n")
		}
		for f in changed {
			line, _ := strings.replace_all(f, "\n", " ", context.temp_allocator)
			fmt.sbprintf(&b, "event: change\ndata: %s\n\n", line)
			delete(f)
		}
		delete(changed)
		if !conn_send(c, b.buf[:]) {
			return
		}
		free_all(context.temp_allocator)
	}
}

// serve_viewer sends the viewer page for a non-HTML file: the file in an
// <img>, <video>, <audio> or <iframe>, and the live reload script, which
// reloads only that element when the file changes.
@(private = "file")
serve_viewer :: proc(c: ^Conn, method, rel: string) {
	srv := c.srv
	file, have_root := resolve(srv, rel)
	if !have_root {
		respond(c, "503 Service Unavailable", "No session is open in ngam.\n")
		return
	}
	f := fetch(srv, file, 0, 0)
	defer fetch_free(f)
	if f != nil && f.kind == "dir" {
		respond(c, "404 Not Found", "That is a folder.\n")
		return
	}
	if !fetch_ok(c, f, "") {
		return
	}
	sync.mutex_lock(&srv.mu)
	set_page(srv, strings.concatenate({"view:", file}, context.temp_allocator), file)
	sync.mutex_unlock(&srv.mu)

	src := html_escape(fmt.tprintf("/%s/%s", srv.token, url_path(rel)))
	name := html_escape(filepath.base(file))
	ctype := content_type(file)
	elem: string
	switch {
	case strings.has_prefix(ctype, "image/"):
		elem = fmt.tprintf(`<img id="ngam-media" src="%s" data-src="%s" alt="%s">`, src, src, name)
	case strings.has_prefix(ctype, "video/"):
		elem = fmt.tprintf(`<video id="ngam-media" src="%s" data-src="%s" controls></video>`, src, src)
	case strings.has_prefix(ctype, "audio/"):
		elem = fmt.tprintf(`<audio id="ngam-media" src="%s" data-src="%s" controls></audio>`, src, src)
	case:
		elem = fmt.tprintf(`<iframe id="ngam-media" src="%s" data-src="%s" title="%s"></iframe>`, src, src, name)
	}
	// Join the parts with concatenate, since fmt would read the CSS braces
	// as its own.
	page := strings.concatenate(
		{
			`<!doctype html>
<html><head><meta charset="utf-8"><title>`,
			name,
			`</title>
<style>
html, body { margin: 0; height: 100%; background: #1e1e1e; }
body { display: flex; align-items: center; justify-content: center; }
img, video { max-width: 100%; max-height: 100vh; }
audio { width: 80%; }
iframe { border: 0; width: 100%; height: 100vh; background: #fff; }
</style></head>
<body>`,
			elem,
			"\n",
			live_tag(srv),
			"\n</body></html>\n",
		},
		context.temp_allocator,
	)
	send_whole(c, method, "200 OK", "text/html; charset=utf-8", transmute([]byte)page)
}

@(private = "file")
html_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		switch r {
		case '&':
			strings.write_string(&b, "&amp;")
		case '<':
			strings.write_string(&b, "&lt;")
		case '>':
			strings.write_string(&b, "&gt;")
		case '"':
			strings.write_string(&b, "&quot;")
		case '\'':
			strings.write_string(&b, "&#39;")
		case:
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

// live_tag is the script tag put into HTML pages.
@(private = "file")
live_tag :: proc(srv: ^Preview_Server) -> string {
	return fmt.tprintf(`<script src="/%s/~live.js"></script>`, srv.token)
}

// inject puts tag just before the page's last </body>, or at the end when
// the page lacks one.
@(private = "file")
inject :: proc(page: []byte, tag: string) -> []byte {
	lower := strings.to_lower(string(page), context.temp_allocator)
	pos := strings.last_index(lower, "</body")
	if pos < 0 {
		pos = len(page)
	}
	out := make([]byte, len(page) + len(tag), context.temp_allocator)
	copy(out, page[:pos])
	copy(out[pos:], tag)
	copy(out[pos + len(tag):], page[pos:])
	return out
}

// live_js is the script that reloads a page when a file it uses changes.
// In a viewer page it reloads only the shown file, with a new query so the
// browser fetches it again, and a video or audio file keeps its place.
@(private = "file")
live_js :: proc(srv: ^Preview_Server) -> string {
	// Join the parts with concatenate, since fmt would read the script's
	// braces as its own.
	return strings.concatenate(
		{
			`// ngam's live reload: reload when a file this page uses changes.
(function () {
  var events = new EventSource('/`,
			srv.token,
			`/~events?page=' + encodeURIComponent(location.pathname));
  var media = document.getElementById('ngam-media');
  var timer = null;
  events.addEventListener('change', function () {
    clearTimeout(timer);
    timer = setTimeout(media ? reloadMedia : function () { location.reload(); }, 50);
  });
  function reloadMedia() {
    var src = media.getAttribute('data-src') + '?v=' + Date.now();
    if (media.tagName !== 'VIDEO' && media.tagName !== 'AUDIO') {
      media.src = src;
      return;
    }
    var time = media.currentTime, playing = !media.paused;
    media.addEventListener('loadedmetadata', function seek() {
      media.removeEventListener('loadedmetadata', seek);
      try { media.currentTime = Math.min(time, media.duration || time); } catch (e) {}
      if (playing) { media.play().catch(function () {}); }
    });
    media.src = src;
  }
})();
`,
		},
		context.temp_allocator,
	)
}

// previewable reports whether a browser displays the file at path in the
// window, judged by its type: HTML, images, audio, video, PDF and text.
// The server still serves every file, since pages load fonts, scripts and
// the like.
previewable :: proc(path: string) -> bool {
	t := content_type(path)
	switch {
	case strings.has_prefix(t, "text/"),
	     strings.has_prefix(t, "image/"),
	     strings.has_prefix(t, "audio/"),
	     strings.has_prefix(t, "video/"):
		return true
	}
	switch t {
	case "application/pdf", "application/json", "application/xml", "application/xhtml+xml":
		return true
	}
	return false
}

// is_markdown reports whether path is a Markdown file, which the server
// renders as a page.
@(private = "file")
is_markdown :: proc(path: string) -> bool {
	switch strings.to_lower(filepath.ext(path), context.temp_allocator) {
	case ".md", ".markdown":
		return true
	}
	return false
}

// content_type returns the MIME type for a file's extension.
@(private = "file")
content_type :: proc(path: string) -> string {
	switch strings.to_lower(filepath.ext(path), context.temp_allocator) {
	case ".html", ".htm":
		return "text/html; charset=utf-8"
	case ".xhtml":
		return "application/xhtml+xml"
	case ".css":
		return "text/css; charset=utf-8"
	case ".js", ".mjs":
		return "text/javascript; charset=utf-8"
	case ".json", ".map":
		return "application/json"
	case ".svg":
		return "image/svg+xml"
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".avif":
		return "image/avif"
	case ".ico":
		return "image/x-icon"
	case ".bmp":
		return "image/bmp"
	case ".pdf":
		return "application/pdf"
	case ".wasm":
		return "application/wasm"
	case ".mp4", ".m4v":
		return "video/mp4"
	case ".webm":
		return "video/webm"
	case ".ogv":
		return "video/ogg"
	case ".mp3":
		return "audio/mpeg"
	case ".wav":
		return "audio/wav"
	case ".ogg", ".oga", ".opus":
		return "audio/ogg"
	case ".m4a", ".aac":
		return "audio/mp4"
	case ".flac":
		return "audio/flac"
	case ".woff":
		return "font/woff"
	case ".woff2":
		return "font/woff2"
	case ".ttf":
		return "font/ttf"
	case ".otf":
		return "font/otf"
	case ".xml":
		return "application/xml"
	case ".txt", ".md", ".markdown", ".log", ".csv", ".go", ".odin", ".lua", ".py", ".rs", ".c", ".h", ".ts", ".sh", ".toml", ".yaml", ".yml":
		return "text/plain; charset=utf-8"
	}
	return "application/octet-stream"
}
