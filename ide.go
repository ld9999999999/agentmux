package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// ideServer serves Claude Code's IDE protocol (MCP over WebSocket, the one
// its VS Code and JetBrains extensions use) for the session's nvim. It runs
// in the holder, so the agent stays connected while nvim starts and quits.
// nvim talks to it over the holder socket (the "editor" link). pi's pi-ide
// extension uses the same protocol with small differences, which
// ideDialect covers.
type ideServer struct {
	s        *Session
	d        ideDialect
	token    string
	port     int
	lockPath string
	srv      *http.Server

	mu        sync.Mutex
	clients   map[*websocket.Conn]bool
	selection json.RawMessage // params of the last selection_changed
	// The links of the session's editors (one for terminals, one for a
	// GUI), with the one the user last used at the end. Calls go to that
	// one.
	editors   []net.Conn
	pending   map[int]chan editorMsg
	pendingOn map[int]net.Conn // the editor link each pending call went to
	nextID    int
}

// editorMsg is one JSON message on the editor link, in either direction.
type editorMsg struct {
	Type   string          `json:"type"`
	ID     int             `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  string          `json:"error,omitempty"`
	// For type "ide": whether the agent is connected, and whether it
	// accepts at_mentioned. When Mentions is false, the editor types @file
	// references instead.
	Connected *bool `json:"connected,omitempty"`
	Mentions  bool  `json:"mentions,omitempty"`
	// For type "ide": which agent's protocol the server uses.
	IDE string `json:"ide,omitempty"`
}

type rpcMsg struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// ideDialect holds what differs between the agents that use the protocol.
type ideDialect struct {
	name       string
	authHeader string
	// lockDir is where the agent looks for <port>.lock files.
	lockDir func(*Session) string
	// env tells the agent how to find this server.
	env func(ide *ideServer) []string
	// mentions: the agent acts on at_mentioned notifications.
	mentions bool
	// initialized: the client sends notifications/initialized, and the
	// selection is replayed then. When false, the selection is replayed
	// right after initialize.
	initialized bool
	// zeroColumnEnd: the client reads a selection ending at column 0 of a
	// line as ending at the line before, as VS Code reports whole lines.
	zeroColumnEnd bool
}

var ideDialects = map[string]ideDialect{
	// Claude finds the server through CLAUDE_CODE_SSE_PORT and the lock
	// file <claude config dir>/ide/<port>.lock.
	"claude": {
		name:       "claude",
		authHeader: "X-Claude-Code-Ide-Authorization",
		lockDir:    func(*Session) string { return filepath.Join(claudeConfigDir(), "ide") },
		env: func(ide *ideServer) []string {
			return []string{fmt.Sprintf("CLAUDE_CODE_SSE_PORT=%d", ide.port), "ENABLE_IDE_INTEGRATION=true"}
		},
		mentions: true, initialized: true, zeroColumnEnd: true,
	},
	// pi-ide (pi install npm:@ldelossa/pi-ide) connects on its own only
	// when exactly one lock file matches its directory, so each session
	// gets its own lock directory.
	"pi": {
		name:       "pi",
		authHeader: "X-Pi-Ide-Authorization",
		lockDir:    func(s *Session) string { return s.Path("pi-ide") },
		env:        func(ide *ideServer) []string { return []string{"PI_IDE_LOCK_DIR=" + ide.d.lockDir(ide.s)} },
	},
}

func claudeConfigDir() string {
	if d := os.Getenv("CLAUDE_CONFIG_DIR"); d != "" {
		return d
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".claude")
}

func startIDE(s *Session, kind string) (*ideServer, error) {
	d, ok := ideDialects[kind]
	if !ok {
		return nil, fmt.Errorf("unknown ide %q", kind)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	ide := &ideServer{
		s:         s,
		d:         d,
		token:     newUUID(),
		port:      ln.Addr().(*net.TCPAddr).Port,
		clients:   map[*websocket.Conn]bool{},
		pending:   map[int]chan editorMsg{},
		pendingOn: map[int]net.Conn{},
	}
	ide.srv = &http.Server{Handler: http.HandlerFunc(ide.serveWS)}
	go ide.srv.Serve(ln)

	dir := d.lockDir(s)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		ln.Close()
		return nil, err
	}
	// pi-ide compares folders with its working directory as plain strings,
	// so list the resolved path too when the session's has symlinks in it.
	folders := []string{s.Cwd}
	if real, err := filepath.EvalSymlinks(s.Cwd); err == nil && real != s.Cwd {
		folders = append(folders, real)
	}
	lock, _ := json.Marshal(map[string]any{
		"pid":              os.Getpid(),
		"workspaceFolders": folders,
		"ideName":          "Neovim (agentmux)",
		"transport":        "ws",
		"authToken":        ide.token,
	})
	ide.lockPath = filepath.Join(dir, fmt.Sprintf("%d.lock", ide.port))
	if err := writeFileAtomic(ide.lockPath, lock); err != nil {
		ln.Close()
		return nil, err
	}
	// Save the path so delete can remove the lock file if the holder dies.
	_ = writeFileAtomic(s.Path("ide.lock"), []byte(ide.lockPath))
	log.Printf("ide: listening on 127.0.0.1:%d for %s", ide.port, d.name)
	return ide, nil
}

func (ide *ideServer) env() []string { return ide.d.env(ide) }

func (ide *ideServer) close() {
	os.Remove(ide.lockPath)
	os.Remove(ide.s.Path("ide.lock"))
	ide.srv.Close()
}

func removeStaleIDELock(s *Session) {
	if b, err := os.ReadFile(s.Path("ide.lock")); err == nil {
		os.Remove(string(b))
	}
}

func (ide *ideServer) serveWS(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get(ide.d.authHeader) != ide.token {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{"mcp"}})
	if err != nil {
		return
	}
	c.SetReadLimit(maxFrame)
	defer c.CloseNow()
	ide.mu.Lock()
	ide.clients[c] = true
	ide.mu.Unlock()
	log.Printf("ide: %s connected", ide.d.name)
	ide.tellEditor(true)
	defer func() {
		ide.mu.Lock()
		delete(ide.clients, c)
		n := len(ide.clients)
		ide.mu.Unlock()
		log.Printf("ide: %s disconnected", ide.d.name)
		if n == 0 {
			ide.tellEditor(false)
		}
	}()

	// ctx ends when the agent disconnects, which also ends any diff it is
	// waiting on.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	for {
		_, b, err := c.Read(ctx)
		if err != nil {
			return
		}
		var m rpcMsg
		if json.Unmarshal(b, &m) != nil {
			continue
		}
		go ide.handle(ctx, c, m)
	}
}

func (ide *ideServer) handle(ctx context.Context, c *websocket.Conn, m rpcMsg) {
	if len(m.ID) == 0 {
		// A message without an ID is a notification from the agent. Only
		// requests get a reply.
		if m.Method == "notifications/initialized" && ide.d.initialized {
			ide.replaySelection(c)
		}
		return
	}
	reply := rpcMsg{JSONRPC: "2.0", ID: m.ID}
	switch m.Method {
	case "initialize":
		var p struct {
			ProtocolVersion string `json:"protocolVersion"`
		}
		_ = json.Unmarshal(m.Params, &p)
		if p.ProtocolVersion == "" {
			p.ProtocolVersion = "2024-11-05"
		}
		reply.Result = map[string]any{
			"protocolVersion": p.ProtocolVersion,
			"capabilities":    map[string]any{"tools": map[string]any{"listChanged": false}},
			"serverInfo":      map[string]any{"name": "agentmux", "version": "0.1.0"},
		}
	case "ping":
		reply.Result = map[string]any{}
	case "tools/list":
		reply.Result = map[string]any{"tools": ideTools}
	case "tools/call":
		var p struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		_ = json.Unmarshal(m.Params, &p)
		reply.Result, reply.Error = ide.callTool(ctx, p.Name, p.Arguments)
	default:
		reply.Error = &rpcError{Code: -32601, Message: "method not found: " + m.Method}
	}
	b, _ := json.Marshal(reply)
	_ = c.Write(ctx, websocket.MessageText, b)
	if m.Method == "initialize" && !ide.d.initialized {
		ide.replaySelection(c)
	}
}

func (ide *ideServer) replaySelection(c *websocket.Conn) {
	ide.mu.Lock()
	sel := ide.selection
	ide.mu.Unlock()
	if sel != nil {
		ide.notify(c, "selection_changed", ide.forClient(sel))
	}
}

// forClient fixes selection params from nvim for clients that would count
// one line too many. nvim reports whole lines the VS Code way, ending at
// column 0 of the next line.
func (ide *ideServer) forClient(sel json.RawMessage) json.RawMessage {
	if ide.d.zeroColumnEnd {
		return sel
	}
	var v map[string]any
	if json.Unmarshal(sel, &v) != nil {
		return sel
	}
	r, _ := v["selection"].(map[string]any)
	start, _ := r["start"].(map[string]any)
	end, _ := r["end"].(map[string]any)
	if start == nil || end == nil || r["isEmpty"] == true {
		return sel
	}
	sl, _ := start["line"].(float64)
	el, _ := end["line"].(float64)
	if ch, _ := end["character"].(float64); ch == 0 && el > sl {
		end["line"] = el - 1
		b, _ := json.Marshal(v)
		return b
	}
	return sel
}

func (ide *ideServer) notify(c *websocket.Conn, method string, params json.RawMessage) {
	b, _ := json.Marshal(rpcMsg{JSONRPC: "2.0", Method: method, Params: params})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = c.Write(ctx, websocket.MessageText, b)
}

func (ide *ideServer) broadcast(method string, params json.RawMessage) {
	ide.mu.Lock()
	var cs []*websocket.Conn
	for c := range ide.clients {
		cs = append(cs, c)
	}
	ide.mu.Unlock()
	for _, c := range cs {
		ide.notify(c, method, params)
	}
}

func schema(props map[string]any, required ...string) map[string]any {
	s := map[string]any{"type": "object", "properties": props}
	if len(required) > 0 {
		s["required"] = required
	}
	return s
}

// ideTools lists only the tools nvim implements. Listing openDiff makes
// Claude show each edit it asks permission for as a diff in nvim (its
// terminal prompt also still works). pi-ide calls it before every edit in
// any case.
var ideTools = []map[string]any{
	{
		"name":        "openDiff",
		"description": "Show a proposed change as a diff and wait for the user to accept or reject it",
		"inputSchema": schema(map[string]any{
			"old_file_path":     map[string]any{"type": "string"},
			"new_file_path":     map[string]any{"type": "string"},
			"new_file_contents": map[string]any{"type": "string"},
			"tab_name":          map[string]any{"type": "string"},
		}, "old_file_path", "new_file_path", "new_file_contents", "tab_name"),
	},
	{
		"name":        "close_tab",
		"description": "Close a diff opened with openDiff",
		"inputSchema": schema(map[string]any{"tab_name": map[string]any{"type": "string"}}, "tab_name"),
	},
	{
		"name":        "closeAllDiffTabs",
		"description": "Close every diff opened with openDiff",
		"inputSchema": schema(map[string]any{}),
	},
	{
		"name":        "getDiagnostics",
		"description": "Get language diagnostics from the editor",
		"inputSchema": schema(map[string]any{
			"uri": map[string]any{"type": "string", "description": "Optional file URI; all files if omitted"},
		}),
	},
	{
		"name":        "getCurrentSelection",
		"description": "Get the current text selection in the editor",
		"inputSchema": schema(map[string]any{}),
	},
	{
		"name":        "getWorkspaceFolders",
		"description": "Get the workspace folders open in the editor",
		"inputSchema": schema(map[string]any{}),
	},
	{
		"name":        "openFile",
		"description": "Open a file in the editor, optionally at a line range",
		"inputSchema": schema(map[string]any{
			"filePath":  map[string]any{"type": "string"},
			"startLine": map[string]any{"type": "integer"},
			"endLine":   map[string]any{"type": "integer"},
		}, "filePath"),
	},
}

func textResult(v any) map[string]any {
	b, _ := json.Marshal(v)
	return map[string]any{"content": []map[string]any{{"type": "text", "text": string(b)}}}
}

func textItems(texts ...string) map[string]any {
	items := make([]map[string]any, len(texts))
	for i, t := range texts {
		items[i] = map[string]any{"type": "text", "text": t}
	}
	return map[string]any{"content": items}
}

// callTool runs a tool. It returns a JSON-RPC error when the call has no
// result to give: an unknown tool, or a diff with no editor to show it.
func (ide *ideServer) callTool(ctx context.Context, name string, args json.RawMessage) (map[string]any, *rpcError) {
	switch name {
	case "openDiff":
		// Waits for as long as the user takes. Without an editor this is
		// an error: Claude then asks in its terminal UI, and pi-ide lets
		// the edit through.
		res, err := ide.editorCall(ctx, name, args, 0)
		if err != nil {
			if ctx.Err() == nil {
				log.Printf("ide: openDiff: %v", err)
			}
			return nil, &rpcError{Code: -32603, Message: "cannot show the diff: " + err.Error()}
		}
		var d struct {
			Outcome  string `json:"outcome"`
			Contents string `json:"contents"`
		}
		_ = json.Unmarshal(res, &d)
		var p struct {
			TabName string `json:"tab_name"`
		}
		_ = json.Unmarshal(args, &p)
		switch d.Outcome {
		case "accepted":
			// The agent writes these contents, including any changes the
			// user made to the proposal.
			return textItems("FILE_SAVED", d.Contents), nil
		case "rejected":
			return textItems("DIFF_REJECTED", p.TabName), nil
		default:
			return textItems("TAB_CLOSED"), nil
		}
	case "close_tab", "closeAllDiffTabs":
		// The agent made the decision itself (or gave up), so the reply
		// is always TAB_CLOSED.
		_, _ = ide.editorCall(ctx, name, args, 5*time.Second)
		return textItems("TAB_CLOSED"), nil
	case "getWorkspaceFolders":
		return textResult(map[string]any{
			"success":  true,
			"folders":  []map[string]any{{"name": filepath.Base(ide.s.Cwd), "uri": "file://" + ide.s.Cwd, "path": ide.s.Cwd}},
			"rootPath": ide.s.Cwd,
		}), nil
	case "getCurrentSelection":
		ide.mu.Lock()
		sel := ide.selection
		ide.mu.Unlock()
		if sel == nil {
			return textResult(map[string]any{"success": false, "message": "No active editor found"}), nil
		}
		var v map[string]any
		_ = json.Unmarshal(sel, &v)
		v["success"] = true
		return textResult(v), nil
	case "getDiagnostics", "openFile":
		res, err := ide.editorCall(ctx, name, args, 5*time.Second)
		if err != nil {
			if name == "getDiagnostics" {
				// With the editor closed, report an empty list.
				return textResult([]any{}), nil
			}
			return map[string]any{"isError": true, "content": []map[string]any{{"type": "text", "text": err.Error()}}}, nil
		}
		var v any
		_ = json.Unmarshal(res, &v)
		return textResult(v), nil
	}
	// MCP uses this error for unknown tools.
	return nil, &rpcError{Code: -32602, Message: "unknown tool: " + name}
}

// --- the editor link ----------------------------------------------------

// editorCall asks nvim to run method and waits for its answer. It stops
// waiting after timeout (0 waits forever), when ctx ends, or when that nvim
// quits.
func (ide *ideServer) editorCall(ctx context.Context, method string, params json.RawMessage, timeout time.Duration) (json.RawMessage, error) {
	ide.mu.Lock()
	conn := ide.activeEditor()
	if conn == nil {
		ide.mu.Unlock()
		return nil, errors.New("the session's editor is not open")
	}
	ide.nextID++
	id := ide.nextID
	ch := make(chan editorMsg, 1)
	ide.pending[id], ide.pendingOn[id] = ch, conn
	ide.mu.Unlock()
	defer func() {
		ide.mu.Lock()
		delete(ide.pending, id)
		delete(ide.pendingOn, id)
		ide.mu.Unlock()
	}()

	b, _ := json.Marshal(editorMsg{Type: "request", ID: id, Method: method, Params: params})
	if err := writeFrame(conn, frameEditor, b); err != nil {
		return nil, err
	}
	var expired <-chan time.Time
	if timeout > 0 {
		t := time.NewTimer(timeout)
		defer t.Stop()
		expired = t.C
	}
	select {
	case r := <-ch:
		if r.Error != "" {
			return nil, errors.New(r.Error)
		}
		return r.Result, nil
	case <-expired:
		return nil, errors.New("the editor did not answer")
	case <-ctx.Done():
		if method == "openDiff" {
			// The agent left before the user answered, so close the diff.
			b, _ := json.Marshal(editorMsg{Type: "request", Method: "close_tab", Params: params})
			_ = writeFrame(conn, frameEditor, b)
		}
		return nil, ctx.Err()
	}
}

// activeEditor returns the link of the editor the user last used, or nil.
// ide.mu must be held.
func (ide *ideServer) activeEditor() net.Conn {
	if len(ide.editors) == 0 {
		return nil
	}
	return ide.editors[len(ide.editors)-1]
}

// useEditor marks conn's editor as the one the user last used.
func (ide *ideServer) useEditor(conn net.Conn) {
	ide.mu.Lock()
	defer ide.mu.Unlock()
	ide.removeEditor(conn)
	ide.editors = append(ide.editors, conn)
}

// removeEditor takes conn out of the list. ide.mu must be held.
func (ide *ideServer) removeEditor(conn net.Conn) {
	for i, c := range ide.editors {
		if c == conn {
			ide.editors = append(ide.editors[:i], ide.editors[i+1:]...)
			return
		}
	}
}

// status returns the "ide" message that tells an editor whether the agent
// is connected.
func (ide *ideServer) status(connected bool) []byte {
	b, _ := json.Marshal(editorMsg{Type: "ide", Connected: &connected, Mentions: ide.d.mentions, IDE: ide.d.name})
	return b
}

// tellEditor sends every editor the agent's new state.
func (ide *ideServer) tellEditor(connected bool) {
	ide.mu.Lock()
	conns := append([]net.Conn(nil), ide.editors...)
	ide.mu.Unlock()
	b := ide.status(connected)
	for _, conn := range conns {
		_ = writeFrame(conn, frameEditor, b)
	}
}

// serveEditor runs one nvim's link. A session can have two editors open
// (a terminal one and a GUI one), each with its own link. The newest one
// counts as in use until the user turns to the other.
func (ide *ideServer) serveEditor(conn net.Conn) {
	ide.useEditor(conn)
	ide.mu.Lock()
	connected := len(ide.clients) > 0
	ide.mu.Unlock()
	_ = writeFrame(conn, frameEditor, ide.status(connected))
	defer func() {
		ide.mu.Lock()
		ide.removeEditor(conn)
		// Fail the calls sent over this link. Only this nvim knew about
		// them.
		for id, on := range ide.pendingOn {
			if on == conn {
				select {
				case ide.pending[id] <- editorMsg{ID: id, Error: "the editor closed"}:
				default:
				}
			}
		}
		ide.mu.Unlock()
	}()
	for {
		typ, payload, err := readFrame(conn)
		if err != nil {
			return
		}
		if typ != frameEditor {
			continue
		}
		var m editorMsg
		if json.Unmarshal(payload, &m) != nil {
			continue
		}
		switch m.Type {
		case "focus":
			// The user turned to this editor.
			ide.useEditor(conn)
		case "selection":
			ide.useEditor(conn)
			ide.mu.Lock()
			ide.selection = m.Params
			ide.mu.Unlock()
			ide.broadcast("selection_changed", ide.forClient(m.Params))
		case "at_mentioned":
			if ide.d.mentions {
				ide.broadcast("at_mentioned", m.Params)
			}
		case "response":
			ide.mu.Lock()
			ch := ide.pending[m.ID]
			ide.mu.Unlock()
			if ch != nil {
				ch <- m
			}
		}
	}
}
