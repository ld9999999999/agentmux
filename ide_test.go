package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// fakeClaude connects to the IDE server the way Claude Code does: it finds
// the port and token in the lock file.
func fakeClaude(t *testing.T, ctx context.Context, ide *ideServer) *websocket.Conn {
	return fakeAgent(t, ctx, ide, "X-Claude-Code-Ide-Authorization", []string{"mcp"})
}

func fakeAgent(t *testing.T, ctx context.Context, ide *ideServer, header string, protos []string) *websocket.Conn {
	t.Helper()
	b, err := os.ReadFile(ide.lockPath)
	if err != nil {
		t.Fatal(err)
	}
	var lock struct {
		Transport string `json:"transport"`
		AuthToken string `json:"authToken"`
	}
	if err := json.Unmarshal(b, &lock); err != nil || lock.Transport != "ws" {
		t.Fatalf("bad lock file %s: %v", b, err)
	}
	port := filepath.Base(ide.lockPath)
	url := "ws://127.0.0.1:" + port[:len(port)-len(".lock")]
	c, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{
		Subprotocols: protos,
		HTTPHeader:   http.Header{header: {lock.AuthToken}},
	})
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func rpc(t *testing.T, ctx context.Context, c *websocket.Conn, id int, method string, params any) map[string]any {
	t.Helper()
	p, _ := json.Marshal(params)
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": json.RawMessage(p)})
	if err := c.Write(ctx, websocket.MessageText, b); err != nil {
		t.Fatal(err)
	}
	for {
		m := readJSON(t, ctx, c)
		if m["id"] != nil && int(m["id"].(float64)) == id {
			return m
		}
	}
}

func readJSON(t *testing.T, ctx context.Context, c *websocket.Conn) map[string]any {
	t.Helper()
	_, b, err := c.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestIDEServer(t *testing.T) {
	t.Setenv("AGENTMUX_HOME", t.TempDir())
	t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
	s, err := createSession("claude", t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	ide, err := startIDE(s, "claude")
	if err != nil {
		t.Fatal(err)
	}
	defer ide.close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Wrong token is refused.
	_, _, err = websocket.Dial(ctx, "ws://127.0.0.1:"+itoa(ide.port), &websocket.DialOptions{
		HTTPHeader: http.Header{"X-Claude-Code-Ide-Authorization": {"nope"}},
	})
	if err == nil {
		t.Fatal("connected with a bad token")
	}

	// A fake editor on the other end of the link.
	editorSide, holderSide := net.Pipe()
	go ide.serveEditor(holderSide)
	editorMsgs := make(chan editorMsg, 16)
	go func() {
		for {
			_, payload, err := readFrame(editorSide)
			if err != nil {
				return
			}
			var m editorMsg
			_ = json.Unmarshal(payload, &m)
			editorMsgs <- m
		}
	}()
	sendEditor := func(m editorMsg) {
		b, _ := json.Marshal(m)
		if err := writeFrame(editorSide, frameEditor, b); err != nil {
			t.Fatal(err)
		}
	}
	nextEditorMsg := func(typ string) editorMsg {
		for {
			select {
			case m := <-editorMsgs:
				if m.Type == typ {
					return m
				}
			case <-ctx.Done():
				t.Fatalf("no %q message for the editor", typ)
			}
		}
	}
	if m := nextEditorMsg("ide"); *m.Connected {
		t.Fatal("editor told Claude is connected before it is")
	}
	sel := json.RawMessage(`{"filePath":"/work/proj/a.go","text":"","selection":{"start":{"line":3,"character":0},"end":{"line":3,"character":0},"isEmpty":true}}`)
	sendEditor(editorMsg{Type: "selection", Params: sel})
	time.Sleep(50 * time.Millisecond)

	c := fakeClaude(t, ctx, ide)
	defer c.CloseNow()
	if m := nextEditorMsg("ide"); !*m.Connected || !m.Mentions {
		t.Fatalf("editor not told that Claude connected and takes mentions: %+v", m)
	}

	init := rpc(t, ctx, c, 1, "initialize", map[string]any{"protocolVersion": "2025-06-18"})
	if got := init["result"].(map[string]any)["protocolVersion"]; got != "2025-06-18" {
		t.Fatalf("protocolVersion = %v", got)
	}
	// The latest selection is replayed when Claude says it is ready.
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})
	_ = c.Write(ctx, websocket.MessageText, b)
	if m := readJSON(t, ctx, c); m["method"] != "selection_changed" ||
		m["params"].(map[string]any)["filePath"] != "/work/proj/a.go" {
		t.Fatalf("expected replayed selection, got %v", m)
	}

	tools := rpc(t, ctx, c, 2, "tools/list", nil)["result"].(map[string]any)["tools"].([]any)
	if len(tools) != len(ideTools) {
		t.Fatalf("tools/list returned %d tools", len(tools))
	}

	// Live selection changes are forwarded.
	sendEditor(editorMsg{Type: "selection", Params: json.RawMessage(`{"filePath":"/work/proj/b.go","text":"x"}`)})
	if m := readJSON(t, ctx, c); m["params"].(map[string]any)["filePath"] != "/work/proj/b.go" {
		t.Fatalf("expected b.go selection, got %v", m)
	}

	// getDiagnostics goes to the editor and its answer comes back as MCP
	// text content.
	go func() {
		req := nextEditorMsg("request")
		sendEditor(editorMsg{Type: "response", ID: req.ID,
			Result: json.RawMessage(`[{"uri":"file:///work/proj/b.go","diagnostics":[{"message":"boom","severity":"Error"}]}]`)})
	}()
	res := rpc(t, ctx, c, 3, "tools/call", map[string]any{"name": "getDiagnostics", "arguments": map[string]any{"uri": "file:///work/proj/b.go"}})
	text := res["result"].(map[string]any)["content"].([]any)[0].(map[string]any)["text"].(string)
	var diags []map[string]any
	if err := json.Unmarshal([]byte(text), &diags); err != nil || diags[0]["uri"] != "file:///work/proj/b.go" {
		t.Fatalf("diagnostics = %s (%v)", text, err)
	}

	// With the editor gone, diagnostics come back as an empty list.
	editorSide.Close()
	time.Sleep(50 * time.Millisecond)
	res = rpc(t, ctx, c, 4, "tools/call", map[string]any{"name": "getDiagnostics", "arguments": map[string]any{}})
	if text := res["result"].(map[string]any)["content"].([]any)[0].(map[string]any)["text"]; text != "[]" {
		t.Fatalf("diagnostics without editor = %v", text)
	}

	ide.close()
	if _, err := os.Stat(ide.lockPath); !os.IsNotExist(err) {
		t.Fatal("lock file left behind")
	}
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

// pi-ide differs from Claude: its own lock directory and header, no
// notifications/initialized, no at-mentions, and openDiff before each edit.
func TestIDEServerPi(t *testing.T) {
	t.Setenv("AGENTMUX_HOME", t.TempDir())
	s, err := createSession("pi", t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	ide, err := startIDE(s, "pi")
	if err != nil {
		t.Fatal(err)
	}
	defer ide.close()
	if got, want := filepath.Dir(ide.lockPath), s.Path("pi-ide"); got != want {
		t.Fatalf("lock in %s, want %s", got, want)
	}
	if env := ide.env(); len(env) != 1 || env[0] != "PI_IDE_LOCK_DIR="+s.Path("pi-ide") {
		t.Fatalf("env = %v", env)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	editorSide, holderSide := net.Pipe()
	go ide.serveEditor(holderSide)
	editorMsgs := make(chan editorMsg, 16)
	go func() {
		for {
			_, payload, err := readFrame(editorSide)
			if err != nil {
				return
			}
			var m editorMsg
			_ = json.Unmarshal(payload, &m)
			editorMsgs <- m
		}
	}()
	sendEditor := func(m editorMsg) {
		b, _ := json.Marshal(m)
		if err := writeFrame(editorSide, frameEditor, b); err != nil {
			t.Fatal(err)
		}
	}
	// Lines 3-5 selected linewise: nvim ends it at column 0 of line 6.
	sendEditor(editorMsg{Type: "selection", Params: json.RawMessage(`{"filePath":"/work/a.go","text":"x","selection":{"start":{"line":2,"character":0},"end":{"line":5,"character":0},"isEmpty":false}}`)})
	time.Sleep(50 * time.Millisecond)

	nextEditorMsg := func(typ string) editorMsg {
		for {
			select {
			case m := <-editorMsgs:
				if m.Type == typ && (typ != "ide" || *m.Connected) {
					return m
				}
			case <-ctx.Done():
				t.Fatalf("no %q message for the editor", typ)
			}
		}
	}
	c := fakeAgent(t, ctx, ide, "x-pi-ide-authorization", nil)
	defer c.CloseNow()
	if m := nextEditorMsg("ide"); m.Mentions {
		t.Fatal("editor told pi takes at-mentions")
	}
	// The selection follows initialize, with no notifications/initialized.
	rpc(t, ctx, c, 1, "initialize", map[string]any{"protocolVersion": "2024-11-05"})
	m := readJSON(t, ctx, c)
	end := m["params"].(map[string]any)["selection"].(map[string]any)["end"].(map[string]any)
	if m["method"] != "selection_changed" || end["line"] != float64(4) {
		t.Fatalf("expected replayed selection ending on line index 4, got %v", m)
	}

	// openDiff waits for the user's answer in the editor. Accepting returns
	// the contents as the user left them; the agent writes those.
	texts := func(res map[string]any) []string {
		var out []string
		for _, it := range res["result"].(map[string]any)["content"].([]any) {
			out = append(out, it.(map[string]any)["text"].(string))
		}
		return out
	}
	diff := map[string]any{"name": "openDiff", "arguments": map[string]any{
		"old_file_path": "/work/a.go", "new_file_path": "/work/a.go", "new_file_contents": "new\n", "tab_name": "pi-edit:1"}}
	for _, tc := range []struct {
		answer string
		want   []string
	}{
		{`{"outcome":"accepted","contents":"new, edited\n"}`, []string{"FILE_SAVED", "new, edited\n"}},
		{`{"outcome":"rejected"}`, []string{"DIFF_REJECTED", "pi-edit:1"}},
		{`{"outcome":"closed"}`, []string{"TAB_CLOSED"}},
	} {
		go func() {
			req := nextEditorMsg("request")
			if req.Method != "openDiff" {
				t.Errorf("editor got %q", req.Method)
			}
			sendEditor(editorMsg{Type: "response", ID: req.ID, Result: json.RawMessage(tc.answer)})
		}()
		if got := texts(rpc(t, ctx, c, 2, "tools/call", diff)); strings.Join(got, "|") != strings.Join(tc.want, "|") {
			t.Fatalf("answer %s: got %q, want %q", tc.answer, got, tc.want)
		}
	}

	// The server drops at_mentioned for pi, so the next message is the new
	// selection.
	sendEditor(editorMsg{Type: "at_mentioned", Params: json.RawMessage(`{"filePath":"/work/a.go"}`)})
	sendEditor(editorMsg{Type: "selection", Params: json.RawMessage(`{"filePath":"/work/b.go","text":""}`)})
	if m := readJSON(t, ctx, c); m["method"] != "selection_changed" {
		t.Fatalf("expected only the selection, got %v", m)
	}

	// If nvim quits during a diff, the wait ends with a JSON-RPC error (so
	// pi-ide lets the edit through). Asking with no nvim linked gives the
	// same error.
	go func() {
		nextEditorMsg("request")
		editorSide.Close()
	}()
	if res := rpc(t, ctx, c, 3, "tools/call", diff); res["error"] == nil {
		t.Fatalf("openDiff with the editor gone = %v, want a JSON-RPC error", res)
	}
	if res := rpc(t, ctx, c, 4, "tools/call", diff); res["error"] == nil {
		t.Fatalf("openDiff without an editor = %v, want a JSON-RPC error", res)
	}
}

// With a terminal editor and a GUI editor both linked, calls go to the one
// the user last turned to, and to the other when that one closes.
func TestIDETwoEditors(t *testing.T) {
	t.Setenv("AGENTMUX_HOME", t.TempDir())
	t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
	s, err := createSession("claude", t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	ide, err := startIDE(s, "claude")
	if err != nil {
		t.Fatal(err)
	}
	defer ide.close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// fake links an editor that answers every request with its name.
	fake := func(name string) net.Conn {
		editorSide, holderSide := net.Pipe()
		go ide.serveEditor(holderSide)
		go func() {
			for {
				_, payload, err := readFrame(editorSide)
				if err != nil {
					return
				}
				var m editorMsg
				_ = json.Unmarshal(payload, &m)
				if m.Type == "request" {
					b, _ := json.Marshal(editorMsg{Type: "response", ID: m.ID, Result: json.RawMessage(`"` + name + `"`)})
					_ = writeFrame(editorSide, frameEditor, b)
				}
			}
		}()
		return editorSide
	}
	who := func() string {
		r, err := ide.editorCall(ctx, "openFile", json.RawMessage(`{}`), 5*time.Second)
		if err != nil {
			return "" // not linked yet
		}
		return strings.Trim(string(r), `"`)
	}
	waitFor := func(name string) {
		for i := 0; i < 100; i++ {
			if who() == name {
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatalf("calls never went to %s", name)
	}

	term := fake("terminal")
	waitFor("terminal")
	gui := fake("gui")
	waitFor("gui") // the newest link
	b, _ := json.Marshal(editorMsg{Type: "focus"})
	if err := writeFrame(term, frameEditor, b); err != nil {
		t.Fatal(err)
	}
	waitFor("terminal") // turned to
	term.Close()
	waitFor("gui") // the one left
	gui.Close()
}
