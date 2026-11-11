package main

import (
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
)

// The holder is one process per session. It owns the PTY master, keeps the
// agent running after every client leaves, and replays recent output to new
// clients. It holds an exclusive flock on holder.lock for its whole life, so
// at most one holder runs per session.

const ringSize = 1 << 20

type holder struct {
	s    *Session
	ptmx *os.File
	cmd  *exec.Cmd
	ide  *ideServer

	mu      sync.Mutex
	ring    []byte
	clients map[*client]bool
	rows    uint16
	cols    uint16
}

type client struct {
	conn net.Conn
	out  chan []byte
}

func runHolder(id string) error {
	s, err := loadSession(id)
	if err != nil {
		return err
	}
	if err := ensureSocketDir(); err != nil {
		return err
	}
	lock, err := os.OpenFile(s.Path("holder.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("holder already running")
	}

	argv, resumed, err := agentArgv(s)
	if err != nil {
		return err
	}
	cfg, err := agentConfig(s.Agent)
	if err != nil {
		return err
	}
	log.Printf("starting agent: %s", strings.Join(argv, " "))
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = s.Cwd
	cmd.Env = agentEnv(s)
	h := &holder{s: s, cmd: cmd, clients: map[*client]bool{}, rows: 40, cols: 120}
	if cfg.IDE != "" {
		removeStaleIDELock(s)
		if h.ide, err = startIDE(s, cfg.IDE); err != nil {
			log.Printf("ide: %v (continuing without editor integration)", err)
		} else {
			defer h.ide.close()
			cmd.Env = append(cmd.Env, h.ide.env()...)
		}
	}
	// pty.Start puts the agent in its own session with the PTY as its
	// controlling terminal, so its process group is its pid.
	h.ptmx, err = pty.StartWithSize(cmd, &pty.Winsize{Rows: h.rows, Cols: h.cols})
	if err != nil {
		return err
	}
	s.Started = true
	if err := s.Save(); err != nil {
		log.Printf("save meta: %v", err)
	}
	_ = writePid(s.Path("holder.pid"), os.Getpid())
	_ = writePid(s.Path("agent.pid"), cmd.Process.Pid)

	sock := s.Sock("holder")
	_ = os.Remove(sock)
	ln, err := net.Listen("unix", sock)
	if err != nil {
		h.stopAgent()
		os.Remove(s.Path("holder.pid"))
		os.Remove(s.Path("agent.pid"))
		return err
	}

	signal.Ignore(syscall.SIGHUP, syscall.SIGPIPE)
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sigs
		h.stopAgent()
	}()

	go h.trackProcs()
	go h.readPTY()
	go h.accept(ln)

	started := time.Now()
	err = cmd.Wait()
	status := "exited"
	if err != nil {
		status = err.Error()
	}
	log.Printf("agent %s", status)
	if resumed && err != nil && time.Since(started) < 5*time.Second {
		// The resume failed right away (for example, the conversation was
		// deleted). Start a new conversation next time.
		log.Printf("resume failed; the next start begins a new conversation")
		s.AgentSessionID, s.Started = newUUID(), false
		if err := s.Save(); err != nil {
			log.Printf("save meta: %v", err)
		}
		status = "could not be resumed (" + status + "); :AgentRestart starts a new conversation"
	}
	// Catch anything the agent left behind in its process group.
	killAll(loadProcs(s.Path("procs.json")), 2*time.Second, true)

	ln.Close()
	h.mu.Lock()
	for c := range h.clients {
		select {
		case c.out <- framed(frameExit, []byte(status)):
		default:
		}
		close(c.out)
	}
	h.clients = nil
	h.mu.Unlock()
	time.Sleep(100 * time.Millisecond) // let writers flush the exit frame
	_ = os.Remove(sock)
	for _, f := range []string{"holder.pid", "agent.pid", "procs.json"} {
		_ = os.Remove(s.Path(f))
	}
	return nil
}

// trackProcs keeps a record of the agent's process tree, so that delete can
// still find children after the agent (or this holder) has exited.
func (h *holder) trackProcs() {
	for {
		if table, err := processTable(); err == nil {
			if _, ok := table[h.cmd.Process.Pid]; !ok {
				return
			}
			known := map[int]proc{}
			for _, p := range alive(loadProcs(h.s.Path("procs.json"))) {
				known[p.Pid] = p
			}
			for _, p := range descendants(table, h.cmd.Process.Pid, true) {
				known[p.Pid] = p
			}
			var ps []proc
			for _, p := range known {
				ps = append(ps, p)
			}
			recordProcs(h.s.Path("procs.json"), ps)
		}
		time.Sleep(5 * time.Second)
	}
}

func (h *holder) stopAgent() {
	table, err := processTable()
	var ps []proc
	if err == nil {
		ps = descendants(table, h.cmd.Process.Pid, true)
	}
	ps = append(ps, loadProcs(h.s.Path("procs.json"))...)
	killAll(ps, 3*time.Second, true)
}

func (h *holder) readPTY() {
	buf := make([]byte, 32<<10)
	for {
		n, err := h.ptmx.Read(buf)
		if n > 0 {
			chunk := append([]byte(nil), buf[:n]...)
			h.mu.Lock()
			h.ring = append(h.ring, chunk...)
			if len(h.ring) > ringSize {
				h.ring = append([]byte(nil), h.ring[len(h.ring)-ringSize:]...)
			}
			frame := framed(frameData, chunk)
			for c := range h.clients {
				select {
				case c.out <- frame:
				default:
					// Drop a client that falls behind, so the agent keeps
					// going.
					delete(h.clients, c)
					close(c.out)
				}
			}
			h.mu.Unlock()
		}
		if err != nil {
			return
		}
	}
}

func (h *holder) accept(ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		go h.serve(conn)
	}
}

func (h *holder) serve(conn net.Conn) {
	defer conn.Close()
	typ, payload, err := readFrame(conn)
	if err != nil || typ != frameHello {
		return
	}
	if string(payload) == "editor" {
		if h.ide != nil {
			h.ide.serveEditor(conn)
		}
		return
	}
	attach := string(payload) == "attach"
	var c *client
	if attach {
		c = &client{conn: conn, out: make(chan []byte, 1024)}
		h.mu.Lock()
		if h.clients == nil {
			h.mu.Unlock()
			return
		}
		c.out <- framed(frameData, append([]byte(nil), h.ring...))
		h.clients[c] = true
		h.mu.Unlock()
		go func() {
			for b := range c.out {
				if _, err := conn.Write(b); err != nil {
					conn.Close()
					return
				}
			}
			conn.Close()
		}()
		defer h.drop(c)
	}

	first := true
	var myRows, myCols uint16 // this client's size, from its last resize
	for {
		typ, payload, err := readFrame(conn)
		if err != nil {
			return
		}
		switch typ {
		case frameData:
			// Clients may have different sizes (a GUI's agent pane and a
			// terminal's): the one typing gets the agent drawn for it.
			h.mu.Lock()
			other := myRows != 0 && (h.rows != myRows || h.cols != myCols)
			h.mu.Unlock()
			if other {
				h.resize(myRows, myCols, false)
			}
			if _, err := h.ptmx.Write(payload); err != nil {
				return
			}
		case frameResize:
			rows, cols, ok := parseResize(payload)
			if !ok {
				continue
			}
			h.resize(rows, cols, first && attach)
			myRows, myCols = rows, cols
			first = false
		case frameKill:
			log.Printf("kill requested")
			h.stopAgent()
			return
		}
	}
}

// resize sets the PTY size. On a fresh attach it wiggles the size so the
// agent gets SIGWINCH and redraws its whole screen for the new client.
func (h *holder) resize(rows, cols uint16, redraw bool) {
	if rows == 0 || cols == 0 {
		return
	}
	h.mu.Lock()
	h.rows, h.cols = rows, cols
	h.mu.Unlock()
	if redraw && cols > 1 {
		_ = pty.Setsize(h.ptmx, &pty.Winsize{Rows: rows, Cols: cols - 1})
		time.Sleep(50 * time.Millisecond)
	}
	_ = pty.Setsize(h.ptmx, &pty.Winsize{Rows: rows, Cols: cols})
}

func (h *holder) drop(c *client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.clients != nil && h.clients[c] {
		delete(h.clients, c)
		close(c.out)
	}
}

// agentEnv is the caller's environment minus anything that leaked in from
// an agentmux-managed nvim, plus the session markers. The nvim launcher
// records the user's own XDG_STATE_HOME in AGENTMUX_ORIG_XDG_STATE_HOME
// ("-" when it was unset) so it can be put back here.
func agentEnv(s *Session) []string {
	drop := map[string]bool{
		"NVIM": true, "NVIM_LISTEN_ADDRESS": true, "VIMRUNTIME": true, "MYVIMRC": true,
		"AGENTMUX_SESSION": true, "AGENTMUX_ORIG_XDG_STATE_HOME": true, "TERM": true,
		// Set when agentmux itself runs inside an IDE's terminal. The agent
		// must talk to the agentmux editor.
		"CLAUDE_CODE_SSE_PORT": true, "ENABLE_IDE_INTEGRATION": true, "PI_IDE_LOCK_DIR": true,
	}
	// A Claude Code session sets these for the commands it runs (for
	// example when an agent runs `agentmux new`), and they belong to that
	// session. A Claude agent that inherits them thinks it is that
	// session's child and, among other things, stops saving its transcript.
	// Settings a user exports, such as CLAUDE_CODE_USE_BEDROCK or
	// ANTHROPIC_BASE_URL, still pass through.
	for _, k := range []string{
		"CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_CHILD_SESSION",
		"CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_HOST_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED",
		"CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_EXECPATH",
		"CLAUDE_PID", "CLAUDE_AGENT_SDK_VERSION", "CLAUDE_AGENT_SDK_MCP_NO_PREFIX",
		"CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH", "CLAUDE_CODE_DESKTOP_APP_VERSION",
		"CLAUDE_CODE_TERMINAL_MCP_TOOLS", "CLAUDE_CODE_STARTUP_FAILURE_RESULTS",
		"CLAUDE_CODE_HOST_SHORT_TEMP_DIRS", "CLAUDE_CODE_OAUTH_SCOPES",
		"CLAUDE_CODE_ACCOUNT_UUID", "CLAUDE_CODE_ORGANIZATION_UUID", "CLAUDE_CODE_USER_EMAIL",
		"AI_AGENT",
	} {
		drop[k] = true
	}
	orig, fromNvim := os.LookupEnv("AGENTMUX_ORIG_XDG_STATE_HOME")
	var env []string
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		if drop[k] || (fromNvim && k == "XDG_STATE_HOME") {
			continue
		}
		env = append(env, kv)
	}
	if fromNvim && orig != "-" {
		env = append(env, "XDG_STATE_HOME="+orig)
	}
	exe, _ := os.Executable()
	env = append(env,
		"TERM=xterm-256color",
		"AGENTMUX_SESSION="+s.ID,
		"AGENTMUX_HOME="+home(),
		"PATH="+filepath.Dir(exe)+string(os.PathListSeparator)+os.Getenv("PATH"),
	)
	if os.Getenv("COLORTERM") == "" {
		env = append(env, "COLORTERM=truecolor")
	}
	return env
}

// lastLogLine returns the last line of the holder's log, for use in error
// messages about the holder.
func lastLogLine(s *Session, err error) string {
	b, _ := os.ReadFile(s.Path("holder.log"))
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if last := lines[len(lines)-1]; last != "" {
		if _, msg, ok := strings.Cut(last, " "); ok {
			if _, msg, ok = strings.Cut(msg, " "); ok {
				return msg // drop the date and time
			}
		}
		return last
	}
	if err != nil {
		return err.Error()
	}
	return "no log"
}

// ensureHolder starts the session's holder if needed and waits for its
// socket.
func ensureHolder(s *Session) error {
	if c, err := dialHolder(s); err == nil {
		c.Close()
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	logf, err := os.OpenFile(s.Path("holder.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer logf.Close()
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		return err
	}
	defer devnull.Close()
	cmd := exec.Command(exe, "holder", s.ID)
	cmd.Dir = s.Cwd
	cmd.Stdin, cmd.Stdout, cmd.Stderr = devnull, logf, logf
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	var exited error
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if c, err := dialHolder(s); err == nil {
			c.Close()
			return nil
		}
		select {
		case err := <-done:
			// It may have lost a race with another starter, whose socket
			// should appear soon. Wait one more second for it, then report
			// the failure.
			exited = fmt.Errorf("the agent exited right away (%s)", lastLogLine(s, err))
			if d := time.Now().Add(time.Second); d.Before(deadline) {
				deadline = d
			}
		case <-time.After(50 * time.Millisecond):
		}
	}
	if exited != nil {
		return fmt.Errorf("%v; see %s", exited, s.Path("holder.log"))
	}
	return fmt.Errorf("holder did not start; see %s", s.Path("holder.log"))
}
