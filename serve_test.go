package main

import (
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeNvim stands in for nvim --embed: it reports how it was started, echoes
// lines back, and on "switch <id>" hands off to that session the way the
// plugin does.
const fakeNvim = `#!/bin/sh
if [ "$1" = --version ]; then echo "NVIM v0.11.0"; exit 0; fi
embed=no
for a in "$@"; do [ "$a" = --embed ] && embed=yes; done
echo "ui=$AGENTMUX_UI session=$AGENTMUX_SESSION embed=$embed"
while IFS= read -r line; do
  case "$line" in
    switch\ *) echo "open ${line#switch }" >> "$AGENTMUX_HANDOFF"; exit 0 ;;
    *) echo "echo:$line" ;;
  esac
done
`

// fakeHolder serves a session's holder socket. It greets each attach,
// reports resizes, echoes keystrokes, and exits the agent on "exit".
type fakeHolder struct {
	ln      net.Listener
	resizes chan [2]uint16
	hellos  chan string
}

func newFakeHolder(t *testing.T, s *Session) *fakeHolder {
	t.Helper()
	if err := ensureSocketDir(); err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("unix", s.Sock("holder"))
	if err != nil {
		t.Fatal(err)
	}
	h := &fakeHolder{ln: ln, resizes: make(chan [2]uint16, 8), hellos: make(chan string, 8)}
	t.Cleanup(func() { ln.Close(); os.Remove(s.Sock("holder")) })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go h.serveConn(conn)
		}
	}()
	return h
}

func (h *fakeHolder) serveConn(conn net.Conn) {
	defer conn.Close()
	typ, payload, err := readFrame(conn)
	if err != nil || typ != frameHello {
		return // ensureHolder's probe
	}
	h.hellos <- string(payload)
	_ = writeFrame(conn, frameData, []byte("agent says hi"))
	for {
		typ, payload, err := readFrame(conn)
		if err != nil {
			return
		}
		switch typ {
		case frameResize:
			h.resizes <- [2]uint16{uint16(payload[0])<<8 | uint16(payload[1]), uint16(payload[2])<<8 | uint16(payload[3])}
		case frameData:
			if string(payload) == "exit" {
				_ = writeFrame(conn, frameExit, []byte("exited (0)"))
				return
			}
			_ = writeFrame(conn, frameData, append([]byte("got:"), payload...))
		}
	}
}

type muxFrame struct {
	typ     byte
	payload []byte
}

// guiClient is the GUI end of serve's stdio.
type guiClient struct {
	t       *testing.T
	w       io.WriteCloser
	frames  chan muxFrame
	pending []muxFrame
}

func (g *guiClient) send(typ byte, payload []byte) {
	g.t.Helper()
	if err := writeFrame(g.w, typ, payload); err != nil {
		g.t.Fatal(err)
	}
}

// expect returns the first frame match accepts, failing after a timeout.
// It keeps the frames it skips for later calls, since the streams arrive
// mixed together in any order.
func (g *guiClient) expect(what string, match func(muxFrame) bool) muxFrame {
	g.t.Helper()
	for i, f := range g.pending {
		if match(f) {
			g.pending = append(g.pending[:i], g.pending[i+1:]...)
			return f
		}
	}
	deadline := time.After(5 * time.Second)
	for {
		select {
		case f, ok := <-g.frames:
			if !ok {
				g.t.Fatalf("serve closed its output while waiting for %s", what)
			}
			if match(f) {
				return f
			}
			g.pending = append(g.pending, f)
		case <-deadline:
			g.t.Fatalf("timed out waiting for %s", what)
		}
	}
}

func (g *guiClient) expectControl(typ string, check func(map[string]any) bool) map[string]any {
	g.t.Helper()
	var m map[string]any
	g.expect("control "+typ, func(f muxFrame) bool {
		if f.typ != muxControl {
			return false
		}
		m = nil
		_ = json.Unmarshal(f.payload, &m)
		return m["type"] == typ && (check == nil || check(m))
	})
	return m
}

func (g *guiClient) expectData(typ byte, text string) {
	g.t.Helper()
	g.expect(string(typ)+" "+text, func(f muxFrame) bool {
		return f.typ == typ && strings.Contains(string(f.payload), text)
	})
}

func TestServe(t *testing.T) {
	t.Setenv("AGENTMUX_HOME", t.TempDir())
	bin := filepath.Join(t.TempDir(), "nvim")
	if err := os.WriteFile(bin, []byte(fakeNvim), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTMUX_NVIM", bin)
	s1, err := createSession("shell", t.TempDir(), "one")
	if err != nil {
		t.Fatal(err)
	}
	s2, err := createSession("shell", t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	h1, h2 := newFakeHolder(t, s1), newFakeHolder(t, s2)

	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	g := &guiClient{t: t, w: inW, frames: make(chan muxFrame, 64)}
	go func() {
		defer close(g.frames)
		for {
			typ, payload, err := readFrame(outR)
			if err != nil {
				return
			}
			g.frames <- muxFrame{typ, payload}
		}
	}()
	done := make(chan error, 1)
	go func() { done <- serve(s1, inR, outW); outW.Close() }()

	m := g.expectControl("session", nil)
	if m["id"] != s1.ID || m["name"] != "one" || m["protocol"] != float64(serveProtocol) {
		t.Fatalf("session message %v", m)
	}
	if editorUI(s1) != "gui" {
		t.Fatalf("editorUI = %q while serving, want gui", editorUI(s1))
	}
	if editorPid(s1, uiTerminal) != 0 || !fileExists(s1.Path("nvim-gui.pid")) {
		t.Fatal("the GUI's editor is not marked as its own")
	}
	g.expectData(muxEditor, "ui=gui session="+s1.ID+" embed=yes")
	g.expectControl("agent", func(m map[string]any) bool { return m["state"] == "attached" })
	if hello := <-h1.hellos; hello != "attach" {
		t.Fatalf("holder hello %q", hello)
	}
	g.expectData(muxAgent, "agent says hi")

	// The editor and agent streams pass through both ways.
	g.send(muxEditor, []byte("ping\n"))
	g.expectData(muxEditor, "echo:ping")
	g.send(muxResize, resizePayload(30, 100))
	if got := <-h1.resizes; got != [2]uint16{30, 100} {
		t.Fatalf("resize %v", got)
	}
	g.send(muxAgent, []byte("ls"))
	g.expectData(muxAgent, "got:ls")

	// A handoff moves the connection to the next session, whose agent
	// gets the pane's size straight away.
	g.send(muxEditor, []byte("switch "+s2.ID+"\n"))
	g.expectControl("editor_exit", nil)
	m = g.expectControl("session", nil)
	if m["id"] != s2.ID || m["name"] != "" {
		t.Fatalf("second session message %v", m)
	}
	if editorUI(s1) != "" {
		t.Fatalf("first session still marked open: %q", editorUI(s1))
	}
	g.expectData(muxEditor, "session="+s2.ID)
	g.expectControl("agent", func(m map[string]any) bool { return m["state"] == "attached" })
	if got := <-h2.resizes; got != [2]uint16{30, 100} {
		t.Fatalf("resize on attach %v", got)
	}

	// When the agent exits, the GUI hears it and can attach again.
	g.send(muxAgent, []byte("exit"))
	m = g.expectControl("agent", func(m map[string]any) bool { return m["state"] == "closed" })
	if m["exit"] != "exited (0)" {
		t.Fatalf("agent closed message %v", m)
	}
	g.send(muxControl, []byte(`{"type":"agent_attach"}`))
	g.expectControl("agent", func(m map[string]any) bool { return m["state"] == "attached" })
	g.expectData(muxAgent, "agent says hi")

	// A handoff to a session open in another GUI comes back to the one it
	// left, and the connection stays open.
	s3, err := createSession("shell", t.TempDir(), "busy")
	if err != nil {
		t.Fatal(err)
	}
	markEditor(s3, os.Getpid(), uiGUI)
	g.send(muxEditor, []byte("switch "+s3.ID+"\n"))
	g.expectControl("editor_exit", nil)
	m = g.expectControl("error", nil)
	if !strings.Contains(m["message"].(string), "another GUI") {
		t.Fatalf("error message %v", m)
	}
	m = g.expectControl("session", nil)
	if m["id"] != s2.ID {
		t.Fatalf("session after the refused handoff %v, want %s again", m, s2.ID)
	}
	g.expectData(muxEditor, "session="+s2.ID)

	// The GUI going away ends the editor.
	inW.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("serve did not return after the GUI went away")
	}
	if editorUI(s2) != "" || fileExists(s2.Path("nvim-gui.pid")) {
		t.Fatal("editor still marked open after serve returned")
	}
}

// serve refuses a session open in another GUI. A session open in a
// terminal is allowed (the GUI gets its own nvim), and TestServe's fake
// covers that case.
func TestServeRefusesAnotherGUI(t *testing.T) {
	t.Setenv("AGENTMUX_HOME", t.TempDir())
	bin := filepath.Join(t.TempDir(), "nvim")
	if err := os.WriteFile(bin, []byte(fakeNvim), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTMUX_NVIM", bin)
	s, err := createSession("shell", t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	markEditor(s, os.Getpid(), uiGUI)
	outR, outW := io.Pipe()
	inR, _ := io.Pipe()
	frames := make(chan muxFrame, 8)
	go func() {
		for {
			typ, payload, err := readFrame(outR)
			if err != nil {
				close(frames)
				return
			}
			frames <- muxFrame{typ, payload}
		}
	}()
	err = serve(s, inR, outW)
	outW.Close()
	if err == nil || !strings.Contains(err.Error(), "another GUI") {
		t.Fatalf("serve = %v, want a refusal", err)
	}
	var types []string
	for f := range frames {
		var m map[string]any
		_ = json.Unmarshal(f.payload, &m)
		types = append(types, m["type"].(string))
	}
	if strings.Join(types, ",") != "error,bye" {
		t.Fatalf("control messages %v, want error then bye", types)
	}
}
