package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

// agentmux serve <session> runs a session for a GUI over its stdin and
// stdout, usually through ssh (`ssh host agentmux serve <s>`), so the remote
// side needs only agentmux. It starts the session's nvim with --embed in
// the plugin's GUI mode, where the GUI draws the agent pane, and passes the
// agent's terminal through. See docs/gui-protocol.md.
//
// Frames use the holder's framing (1 type byte, 4 byte big-endian length,
// payload), with these types:
const (
	muxControl = 'C' // both ways: one JSON message
	muxEditor  = 'N' // both ways: bytes of nvim's msgpack-RPC stream
	muxAgent   = 'A' // agent output to the GUI; keystrokes from it
	muxResize  = 'R' // GUI -> serve: agent pane rows u16, cols u16
)

const serveProtocol = 1

var errClientGone = errors.New("the GUI went away")

type serveConn struct {
	wmu sync.Mutex
	w   io.Writer

	mu         sync.Mutex
	s          *Session // the session being served, nil between sessions
	nvimIn     io.WriteCloser
	agent      net.Conn
	rows, cols uint16 // the agent pane's size, sent again on each attach
}

func (c *serveConn) send(typ byte, payload []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	return writeFrame(c.w, typ, payload)
}

func (c *serveConn) control(m map[string]any) {
	b, _ := json.Marshal(m)
	_ = c.send(muxControl, b)
}

func serve(s *Session, r io.Reader, w io.Writer) error {
	c := &serveConn{w: w}
	handoff := handoffPath()
	defer os.Remove(handoff)
	gone := make(chan error, 1)
	go func() { gone <- c.readClient(r) }()
	// Over ssh, a dropped connection shows up as a hangup or as EOF.
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGHUP, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(sigs)

	var prev *Session
	for s != nil {
		next, err := c.runSession(s, handoff, gone, sigs)
		if errors.Is(err, errClientGone) {
			return nil
		}
		var busy *openElsewhereError
		if errors.As(err, &busy) && prev != nil {
			// The plugin handed off to a session that is open somewhere
			// else. Go back to the session it came from.
			c.control(map[string]any{"type": "error", "message": err.Error()})
			s, prev = prev, nil
			continue
		}
		if err != nil {
			c.control(map[string]any{"type": "error", "message": err.Error()})
			c.control(map[string]any{"type": "bye"})
			return err
		}
		s, prev = next, s
	}
	c.control(map[string]any{"type": "bye"})
	return nil
}

// openElsewhereError is the error serve returns for a session that another
// GUI has open.
type openElsewhereError struct{ id string }

func (e *openElsewhereError) Error() string {
	return fmt.Sprintf("session %s is already open in another GUI", e.id)
}

// runSession runs one session's nvim until it quits, and returns the
// session the plugin handed off to, if any.
func (c *serveConn) runSession(s *Session, handoff string, gone <-chan error, sigs <-chan os.Signal) (*Session, error) {
	bin := nvimBin()
	if err := checkNvim(bin); err != nil {
		return nil, err
	}
	// A terminal may also have the session open with its own nvim. Only
	// another GUI blocks this one.
	if editorPid(s, uiGUI) != 0 {
		return nil, &openElsewhereError{s.ID}
	}
	if err := os.WriteFile(handoff, nil, 0o600); err != nil {
		return nil, err
	}
	// Start the editor even if the agent fails to start. The GUI learns
	// why when the agent pane fails to attach.
	holderErr := ensureHolder(s)

	// Start from the terminals' editor's files and cursors when it is open.
	saveEditor(s, uiTerminal, 2*time.Second)
	cmd, err := editorCmd(s, bin, handoff, uiGUI, "--embed")
	if err != nil {
		return nil, err
	}
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	markEditor(s, cmd.Process.Pid, uiGUI)
	c.mu.Lock()
	c.s, c.nvimIn = s, in
	c.mu.Unlock()
	c.control(map[string]any{
		"type": "session", "protocol": serveProtocol,
		"id": s.ID, "name": s.Name, "agent": s.Agent, "cwd": s.Cwd,
	})
	if holderErr != nil {
		c.control(map[string]any{"type": "agent", "state": "closed", "reason": holderErr.Error()})
	} else {
		go c.attachAgent()
	}

	exited := make(chan error, 1)
	go func() {
		buf := make([]byte, 32<<10)
		for {
			n, err := out.Read(buf)
			if n > 0 && c.send(muxEditor, buf[:n]) != nil {
				break
			}
			if err != nil {
				break
			}
		}
		exited <- cmd.Wait()
	}()
	var clientGone bool
	select {
	case <-exited:
	case <-gone:
		clientGone = true
	case <-sigs:
		clientGone = true
	}
	if clientGone {
		// A GUI session usually ends when the user closes the GUI. By the
		// time nvim exits, it has lost its UI and skips its last snapshot,
		// so ask for one first (nvim saves cursor moves only from time to
		// time).
		saveEditor(s, uiGUI, 3*time.Second)
		// An embedded nvim quits when its UI's channel closes.
		in.Close()
		select {
		case <-exited:
		case <-time.After(5 * time.Second):
			_ = cmd.Process.Kill()
			<-exited
		}
	}

	c.mu.Lock()
	agent := c.agent
	c.s, c.nvimIn, c.agent = nil, nil, nil
	c.mu.Unlock()
	if agent != nil {
		agent.Close()
	}
	unmarkEditor(s, uiGUI)
	if clientGone {
		return nil, errClientGone
	}
	c.control(map[string]any{"type": "editor_exit"})
	return readHandoff(handoff)
}

// readClient handles the GUI's frames until its side closes.
func (c *serveConn) readClient(r io.Reader) error {
	for {
		typ, payload, err := readFrame(r)
		if err != nil {
			return err
		}
		switch typ {
		case muxEditor:
			c.mu.Lock()
			in := c.nvimIn
			c.mu.Unlock()
			if in != nil {
				_, _ = in.Write(payload)
			}
		case muxAgent:
			c.mu.Lock()
			agent := c.agent
			c.mu.Unlock()
			if agent != nil {
				_ = writeFrame(agent, frameData, payload)
			}
		case muxResize:
			rows, cols, ok := parseResize(payload)
			if !ok {
				continue
			}
			c.mu.Lock()
			c.rows, c.cols = rows, cols
			agent := c.agent
			c.mu.Unlock()
			if agent != nil {
				_ = writeFrame(agent, frameResize, payload)
			}
		case muxControl:
			var m struct {
				Type string `json:"type"`
			}
			_ = json.Unmarshal(payload, &m)
			switch m.Type {
			case "agent_attach":
				go c.attachAgent()
			case "agent_detach":
				c.mu.Lock()
				agent := c.agent
				c.agent = nil
				c.mu.Unlock()
				if agent != nil {
					agent.Close()
					c.control(map[string]any{"type": "agent", "state": "closed", "reason": "detached"})
				}
			default:
				c.control(map[string]any{"type": "error", "message": fmt.Sprintf("unknown control message %q", m.Type)})
			}
		}
	}
}

// attachAgent connects the agent pane to the session's holder and replaces
// any earlier connection. It starts the holder if needed, which resumes the
// agent.
func (c *serveConn) attachAgent() {
	c.mu.Lock()
	s := c.s
	c.mu.Unlock()
	if s == nil {
		return
	}
	conn, err := func() (net.Conn, error) {
		if err := ensureHolder(s); err != nil {
			return nil, err
		}
		return holderLink(s, "attach")
	}()
	if err != nil {
		c.control(map[string]any{"type": "agent", "state": "closed", "reason": err.Error()})
		return
	}
	c.mu.Lock()
	if c.s != s {
		// The session ended while the holder was starting.
		c.mu.Unlock()
		conn.Close()
		return
	}
	old := c.agent
	c.agent = conn
	rows, cols := c.rows, c.cols
	c.mu.Unlock()
	if old != nil {
		old.Close()
	}
	c.control(map[string]any{"type": "agent", "state": "attached"})
	if rows > 0 && cols > 0 {
		// The holder redraws the agent for the first size it gets.
		_ = writeFrame(conn, frameResize, resizePayload(rows, cols))
	}
	go c.relayAgent(conn)
}

func (c *serveConn) relayAgent(conn net.Conn) {
	reason := "connection lost"
	exit := ""
	for {
		typ, payload, err := readFrame(conn)
		if err != nil {
			break
		}
		c.mu.Lock()
		current := c.agent == conn
		c.mu.Unlock()
		if !current {
			break
		}
		switch typ {
		case frameData:
			_ = c.send(muxAgent, payload)
		case frameExit:
			reason, exit = "agent "+string(payload), string(payload)
		}
	}
	c.mu.Lock()
	current := c.agent == conn
	if current {
		c.agent = nil
	}
	c.mu.Unlock()
	conn.Close()
	if current {
		m := map[string]any{"type": "agent", "state": "closed", "reason": reason}
		if exit != "" {
			m["exit"] = exit
		}
		c.control(m)
	}
}

func cmdServe(args []string) error {
	return withSession(args, 1, func(s *Session, _ []string) error {
		// Anything nvim or agentmux prints goes to stderr; stdout is the
		// protocol.
		return serve(s, os.Stdin, os.Stdout)
	})
}
