package main

import (
	"bufio"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

//go:embed nvim
var nvimRuntime embed.FS

func nvimBin() string {
	if b := os.Getenv("AGENTMUX_NVIM"); b != "" {
		return b
	}
	h, _ := os.UserHomeDir()
	if b := filepath.Join(h, "neovim", "bin", "nvim"); fileExists(b) {
		return b
	}
	return "nvim"
}

// checkNvim makes sure bin is nvim 0.11 or newer, the first version
// whose jobstart() can open a terminal (term = true).
func checkNvim(bin string) error {
	out, err := exec.Command(bin, "--version").Output()
	if err != nil {
		return fmt.Errorf("cannot run %s (%v); set AGENTMUX_NVIM to nvim 0.11 or newer", bin, err)
	}
	first, _, _ := strings.Cut(string(out), "\n")
	if !nvimVersionOK(first) {
		return fmt.Errorf("agentmux needs nvim 0.11 or newer, but %s is %q; set AGENTMUX_NVIM to a newer one", bin, first)
	}
	return nil
}

// nvimVersionOK reports whether a `nvim --version` first line, such as
// "NVIM v0.11.2", is version 0.11 or newer.
func nvimVersionOK(line string) bool {
	var major, minor int
	if _, err := fmt.Sscanf(line, "NVIM v%d.%d", &major, &minor); err != nil {
		return false
	}
	return major > 0 || minor >= 11
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// extractRuntime writes the embedded Lua plugin to <home>/runtime so nvim
// can load it, and returns that directory.
func extractRuntime() (string, error) {
	dst := filepath.Join(home(), "runtime")
	err := fs.WalkDir(nvimRuntime, "nvim", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		target := filepath.Join(dst, strings.TrimPrefix(p, "nvim"))
		if d.IsDir() {
			return os.MkdirAll(target, 0o700)
		}
		b, err := nvimRuntime.ReadFile(p)
		if err != nil {
			return err
		}
		return writeFileAtomic(target, b)
	})
	return dst, err
}

// openLoop runs nvim for a session in the foreground. When the user
// switches or deletes sessions from inside nvim, the plugin writes a
// handoff file and quits. The loop then carries out the request and opens
// the next session in the same terminal.
func openLoop(s *Session) error {
	handoff := handoffPath()
	defer os.Remove(handoff)
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGQUIT)
	defer signal.Stop(sigs)
	go func() {
		for range sigs {
		}
	}()

	for s != nil {
		if err := runEditor(s, handoff); err != nil {
			return err
		}
		next, err := readHandoff(handoff)
		if err != nil {
			return err
		}
		s = next
	}
	return nil
}

// handoffPath returns this process's handoff file. The plugin writes to
// it to ask this process to open or delete sessions after nvim quits.
func handoffPath() string {
	return filepath.Join(home(), fmt.Sprintf("handoff-%d", os.Getpid()))
}

func readHandoff(path string) (*Session, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	os.Remove(path)
	if err != nil {
		return nil, err
	}
	var next *Session
	sc := bufio.NewScanner(strings.NewReader(string(b)))
	for sc.Scan() {
		verb, ref, _ := strings.Cut(strings.TrimSpace(sc.Text()), " ")
		if verb == "" || ref == "" {
			continue
		}
		s, err := findSession(ref)
		if err != nil {
			fmt.Fprintf(os.Stderr, "agentmux: %v\n", err)
			continue
		}
		switch verb {
		case "delete":
			// The plugin asked for this from inside the session and has
			// already asked the user to confirm.
			if err := deleteSession(s, true); err != nil {
				fmt.Fprintf(os.Stderr, "agentmux: delete %s: %v\n", s.ID, err)
			} else {
				fmt.Fprintf(os.Stderr, "agentmux: deleted %s\n", s.ID)
			}
		case "open":
			next = s
		}
	}
	return next, nil
}

func runEditor(s *Session, handoff string) error {
	bin := nvimBin()
	if err := checkNvim(bin); err != nil {
		return err
	}
	// The plugin checks for this file to learn that the launcher is
	// still running and will act on a handoff.
	if err := os.WriteFile(handoff, nil, 0o600); err != nil {
		return err
	}
	if legacyGUI(s) {
		return fmt.Errorf("its editor is open in a GUI run by an older agentmux; close it there first")
	}
	if editorPid(s, uiTerminal) != 0 {
		return joinEditor(s, bin, handoff)
	}
	if err := ensureHolder(s); err != nil {
		return err
	}
	// A GUI may have the session open with its own nvim. Ask it to save,
	// so this nvim starts with the same files and cursors.
	saveEditor(s, uiGUI, 2*time.Second)
	cmd, err := editorCmd(s, bin, handoff, "")
	if err != nil {
		return err
	}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	markEditor(s, cmd.Process.Pid, uiTerminal)
	err = cmd.Wait()
	if pid := serverPid(s); pid != 0 {
		// This terminal ran :detach while other UIs are still attached.
		// The server keeps running, so its pid marks the open editor.
		_ = writePid(editorPidPath(s, uiTerminal), pid)
	} else {
		unmarkEditor(s, uiTerminal)
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		// A nonzero exit from nvim itself (for example :cq) is the
		// user's choice, so the launcher still succeeds.
		return nil
	}
	return err
}

// A session can have two editors at once, each its own nvim with its own
// windows and buffers: one for terminals (agentmux attach, shared by every
// terminal attached) and one for a GUI (agentmux serve). Both show the same
// agent. Each saves its own snapshot (editor.json, editor-gui.json), and
// one that starts takes the newer of the two, so it opens on the files and
// cursors the other had last.
const (
	uiTerminal = "terminal"
	uiGUI      = "gui"
)

// openEditors lists the session's editors that are running, terminal first.
func openEditors(s *Session) []string {
	var open []string
	for _, ui := range []string{uiTerminal, uiGUI} {
		if editorPid(s, ui) != 0 {
			open = append(open, ui)
		}
	}
	return open
}

func editorPidPath(s *Session, ui string) string {
	if ui == uiGUI {
		return s.Path("nvim-gui.pid")
	}
	return s.Path("nvim.pid")
}

func editorSock(s *Session, ui string) string {
	if ui == uiGUI {
		return s.Sock("nvim-gui")
	}
	return s.Sock("nvim")
}

// legacyGUI reports a GUI editor started by an older agentmux, which kept
// its pid in nvim.pid and wrote "gui" to editor-ui.
func legacyGUI(s *Session) bool {
	if readPid(s.Path("nvim.pid")) == 0 {
		return false
	}
	b, _ := os.ReadFile(s.Path("editor-ui"))
	return strings.TrimSpace(string(b)) == uiGUI
}

// editorPid returns the pid of the session's editor for ui, or 0 when it
// is closed.
func editorPid(s *Session, ui string) int {
	if ui == uiGUI && legacyGUI(s) {
		return readPid(s.Path("nvim.pid"))
	}
	if ui == uiTerminal && legacyGUI(s) {
		return 0
	}
	return readPid(editorPidPath(s, ui))
}

// activeEditor returns the open editor the user last used, or "" when
// both are closed. The plugin writes editor-active when its nvim gains
// focus.
func activeEditor(s *Session) string {
	b, _ := os.ReadFile(s.Path("editor-active"))
	if ui := strings.TrimSpace(string(b)); (ui == uiTerminal || ui == uiGUI) && editorPid(s, ui) != 0 {
		return ui
	}
	if open := openEditors(s); len(open) > 0 {
		return open[0]
	}
	return ""
}

// saveEditor asks ui's editor, if it is open, to write its snapshot now,
// and waits for it for up to timeout.
func saveEditor(s *Session, ui string, timeout time.Duration) {
	if editorPid(s, ui) == 0 {
		return
	}
	done := make(chan struct{})
	go func() { _, _ = nvimCallOn(s, ui, "save", nil); close(done) }()
	select {
	case <-done:
	case <-time.After(timeout):
	}
}

// editorUI says where the session's editor is open: "terminal" (agentmux
// attach), "gui" (agentmux serve), "terminal,gui" for both, or "" when
// both are closed.
func editorUI(s *Session) string {
	return strings.Join(openEditors(s), ",")
}

func markEditor(s *Session, pid int, ui string) {
	_ = writePid(editorPidPath(s, ui), pid)
}

func unmarkEditor(s *Session, ui string) {
	os.Remove(editorSock(s, ui))
	if fileExists(s.Dir()) {
		os.Remove(editorPidPath(s, ui))
	}
}

// editorCmd returns the nvim command for a session, with args after the
// agentmux ones. ui "gui" puts the plugin in GUI mode, where the GUI draws
// the agent pane itself.
func editorCmd(s *Session, bin, handoff, ui string, args ...string) (*exec.Cmd, error) {
	rt, err := extractRuntime()
	if err != nil {
		return nil, err
	}
	if err := ensureSocketDir(); err != nil {
		return nil, err
	}
	sock := editorSock(s, ui) // ui "" is the terminals' editor
	_ = os.Remove(sock)

	exe, _ := os.Executable()
	origState, ok := os.LookupEnv("XDG_STATE_HOME")
	if v, inside := os.LookupEnv("AGENTMUX_ORIG_XDG_STATE_HOME"); inside {
		origState, ok = v, v != "-"
	}
	if !ok {
		origState = "-"
	}
	env := []string{}
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		switch k {
		case "XDG_STATE_HOME", "AGENTMUX_ORIG_XDG_STATE_HOME", "AGENTMUX_SESSION", "AGENTMUX_HANDOFF", "AGENTMUX_BIN",
			"AGENTMUX_HOLDER_SOCK", "AGENTMUX_UI", "NVIM":
			continue
		}
		env = append(env, kv)
	}
	env = append(env,
		// All of nvim's own state (shada, swap, undo, logs) goes in the
		// session directory, so deleting the session removes all of it.
		"XDG_STATE_HOME="+s.Path("state"),
		"AGENTMUX_ORIG_XDG_STATE_HOME="+origState,
		"AGENTMUX_SESSION="+s.ID,
		"AGENTMUX_HOME="+home(),
		"AGENTMUX_HANDOFF="+handoff,
		"AGENTMUX_BIN="+exe,
		"AGENTMUX_HOLDER_SOCK="+s.Sock("holder"),
	)
	if ui != "" {
		env = append(env, "AGENTMUX_UI="+ui)
	}

	// Load the plugin from --cmd, before the user's config runs. Plugin
	// managers such as lazy.nvim reset 'runtimepath' and turn off
	// 'loadplugins', which would silently drop it.
	cmd := exec.Command(bin, append([]string{
		"--listen", sock,
		"--cmd", "set runtimepath^=" + escapeRtp(rt),
		"--cmd", "runtime plugin/agentmux.lua",
	}, args...)...)
	cmd.Dir = s.Cwd
	cmd.Env = env
	return cmd, nil
}

// joinEditor attaches this terminal as another UI of the session's running
// nvim, so it can be open in several terminals at once, as in tmux. It
// registers this launcher's handoff file first, so this launcher handles
// :AgentSession when it runs from this terminal.
func joinEditor(s *Session, bin, handoff string) error {
	if _, err := nvimCallOn(s, uiTerminal, "add_handoff", map[string]string{"path": handoff}); err != nil {
		return err
	}
	cmd := exec.Command(bin, "--server", editorSock(s, uiTerminal), "--remote-ui")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	err := cmd.Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return nil
	}
	return err
}

// serverPid returns the pid of the terminals' nvim server still answering
// on the session's socket, or 0.
func serverPid(s *Session) int {
	sock := editorSock(s, uiTerminal)
	if !fileExists(sock) {
		return 0
	}
	out, err := exec.Command(nvimBin(), "--server", sock, "--remote-expr", "getpid()").Output()
	if err != nil {
		return 0
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(out)))
	return pid
}

func escapeRtp(p string) string {
	return strings.NewReplacer(`\`, `\\`, ",", `\,`, " ", `\ `).Replace(p)
}

// stopEditor stops the session's running editors.
func stopEditor(s *Session) {
	ps := []proc{}
	table, err := processTable()
	for _, ui := range openEditors(s) {
		// The pid is nvim's TUI (or the GUI's embedded nvim). Its --embed
		// server and terminal jobs are its children.
		if err == nil {
			ps = append(ps, descendants(table, editorPid(s, ui), false)...)
		}
	}
	if len(ps) > 0 {
		killAll(ps, 3*time.Second, false)
	}
}

// nvimCall evaluates a call to the agentmux Lua module inside the session's
// editor the user last used, and returns its result as text.
func nvimCall(s *Session, fn string, arg any) (string, error) {
	ui := activeEditor(s)
	if ui == "" {
		return "", errors.New("the session's editor is not open")
	}
	return nvimCallOn(s, ui, fn, arg)
}

// nvimCallOn is nvimCall on the editor for ui ("terminal" or "gui").
func nvimCallOn(s *Session, ui string, fn string, arg any) (string, error) {
	if editorPid(s, ui) == 0 {
		return "", errors.New("the session's editor is not open")
	}
	b, err := json.Marshal(arg)
	if err != nil {
		return "", err
	}
	// _A is passed as a vimscript string literal. A JSON-encoded string is
	// also a valid double-quoted vimscript string, since vimscript reads the
	// same escapes.
	lit, _ := json.Marshal(string(b))
	expr := fmt.Sprintf(`luaeval("require'agentmux'.%s(_A)", %s)`, fn, lit)
	out, err := exec.Command(nvimBin(), "--server", editorSock(s, ui), "--remote-expr", expr).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("nvim: %v: %s", err, out)
	}
	return strings.TrimSpace(string(out)), nil
}
