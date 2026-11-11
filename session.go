package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Session is the saved record for one agent session. It lives in
// <home>/sessions/<id>/meta.json. Everything else for the session (holder
// socket, nvim socket, nvim state dir, editor snapshot, stash) sits next
// to it, so deleting the directory deletes the session.
type Session struct {
	ID             string    `json:"id"`
	Name           string    `json:"name,omitempty"`
	Agent          string    `json:"agent"`
	Cwd            string    `json:"cwd"`
	Created        time.Time `json:"created"`
	AgentSessionID string    `json:"agent_session_id"`
	// Started is set after the agent's first launch, so later launches use
	// the agent's resume command.
	Started bool `json:"started"`
}

func home() string {
	if h := os.Getenv("AGENTMUX_HOME"); h != "" {
		return h
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".agentmux")
}

func sessionsDir() string { return filepath.Join(home(), "sessions") }

// Sockets live under /tmp to keep their paths short, because macOS limits
// Unix socket paths to 104 bytes.
func socketDir() string {
	return filepath.Join("/tmp", fmt.Sprintf("agentmux-%d", os.Getuid()))
}

// Sock returns the path of one of the session's sockets ("holder" or "nvim").
func (s *Session) Sock(kind string) string {
	return filepath.Join(socketDir(), s.ID+"-"+kind+".sock")
}

func ensureSocketDir() error {
	d := socketDir()
	if err := os.MkdirAll(d, 0o700); err != nil {
		return err
	}
	st, err := os.Lstat(d)
	if err != nil {
		return err
	}
	if !st.IsDir() || st.Mode().Perm() != 0o700 || st.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) {
		return fmt.Errorf("%s must be a directory owned by you with mode 0700", d)
	}
	return nil
}

func (s *Session) Dir() string          { return filepath.Join(sessionsDir(), s.ID) }
func (s *Session) Path(p string) string { return filepath.Join(s.Dir(), p) }

func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func newUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}

// expandHome turns a leading "~" or "~/" into the home folder. agentmux
// does it, so a GUI's "~/src" means the home folder on the session's
// machine, which may be an ssh host.
func expandHome(p string) string {
	if p != "~" && !strings.HasPrefix(p, "~/") {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return p
	}
	return filepath.Join(home, p[1:])
}

func createSession(agent, cwd, name string) (*Session, error) {
	if _, err := agentConfig(agent); err != nil {
		return nil, err
	}
	cwd = expandHome(cwd)
	// Check here to give a clear message. Later, when the agent or editor
	// starts in it, the error would be a bare chdir error.
	if st, err := os.Stat(cwd); err != nil || !st.IsDir() {
		return nil, fmt.Errorf("%s is not a directory", cwd)
	}
	cwd, err := filepath.Abs(cwd)
	if err != nil {
		return nil, err
	}
	if name != "" {
		if _, err := findSession(name); err == nil {
			return nil, fmt.Errorf("a session named %q already exists", name)
		}
	}
	s := &Session{
		ID:             randHex(4),
		Name:           name,
		Agent:          agent,
		Cwd:            cwd,
		Created:        time.Now(),
		AgentSessionID: newUUID(),
	}
	for _, d := range []string{s.Dir(), s.Path("state"), s.Path("stash"), s.Path("stash-gui")} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return nil, err
		}
	}
	return s, s.Save()
}

func (s *Session) Save() error {
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(s.Path("meta.json"), b)
}

// writeFileAtomic writes path through a temporary file owned by this
// process, so several agentmux processes may write the same file at once
// (for example when restored GUI windows all start serve together). One of
// them wins, and the file is always whole.
func writeFileAtomic(path string, b []byte) error {
	tmp := fmt.Sprintf("%s.%d.tmp", path, os.Getpid())
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

func loadSession(id string) (*Session, error) {
	b, err := os.ReadFile(filepath.Join(sessionsDir(), id, "meta.json"))
	if err != nil {
		return nil, err
	}
	var s Session
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("session %s: %w", id, err)
	}
	return &s, nil
}

func listSessions() ([]*Session, error) {
	ents, err := os.ReadDir(sessionsDir())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []*Session
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		if s, err := loadSession(e.Name()); err == nil {
			out = append(out, s)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Created.Before(out[j].Created) })
	return out, nil
}

// findSession resolves an id, a unique id prefix, or a name. An empty ref
// means the session this process runs inside, if any.
func findSession(ref string) (*Session, error) {
	if ref == "" {
		ref = os.Getenv("AGENTMUX_SESSION")
		if ref == "" {
			return nil, errors.New("no session given and not inside one")
		}
	}
	all, err := listSessions()
	if err != nil {
		return nil, err
	}
	var hits []*Session
	for _, s := range all {
		if s.ID == ref || s.Name == ref {
			return s, nil
		}
		if strings.HasPrefix(s.ID, ref) {
			hits = append(hits, s)
		}
	}
	switch len(hits) {
	case 0:
		return nil, fmt.Errorf("no session %q", ref)
	case 1:
		return hits[0], nil
	}
	return nil, fmt.Errorf("session %q is ambiguous", ref)
}

// readPid returns the pid in a pid file if that process is still running,
// or 0.
func readPid(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || pid <= 0 {
		return 0
	}
	if syscall.Kill(pid, 0) != nil {
		return 0
	}
	return pid
}

func writePid(path string, pid int) error {
	return writeFileAtomic(path, []byte(strconv.Itoa(pid)+"\n"))
}

// stashCount returns the buffers with unsaved changes in both editor
// snapshots (the terminals' editor and the GUI's). Each file is listed
// once.
func (s *Session) stashCount() ([]string, error) {
	var names []string
	seen := map[string]bool{}
	for _, file := range []string{"editor.json", "editor-gui.json"} {
		b, err := os.ReadFile(s.Path(file))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		var snap struct {
			Stash []struct {
				Path string `json:"path"`
			} `json:"stash"`
		}
		if err := json.Unmarshal(b, &snap); err != nil {
			return nil, err
		}
		for _, e := range snap.Stash {
			name := e.Path
			if name == "" {
				name = "[No Name]"
			}
			if name == "[No Name]" || !seen[name] {
				seen[name] = true
				names = append(names, name)
			}
		}
	}
	return names, nil
}

// deleteSession stops the session's agent and editors and removes it.
// Without force, it returns an error while an editor is open or edits are
// stashed.
func deleteSession(s *Session, force bool) error {
	if !force {
		if open := openEditors(s); len(open) > 0 {
			return fmt.Errorf("its editor is open (pid %d); close it or use -force", editorPid(s, open[0]))
		}
		dirty, err := s.stashCount()
		if err != nil {
			return err
		}
		if len(dirty) > 0 {
			return fmt.Errorf("it has stashed unsaved changes in %s; use -force to discard them",
				strings.Join(dirty, ", "))
		}
	}
	stopEditor(s)
	killHolder(s)
	// Kill whatever the holder left running, including children that
	// outlived a crashed holder.
	ps := loadProcs(s.Path("procs.json"))
	if pid := readPid(s.Path("agent.pid")); pid != 0 {
		if table, err := processTable(); err == nil {
			ps = append(ps, descendants(table, pid, true)...)
		}
	}
	killAll(ps, 2*time.Second, true)
	for _, sock := range []string{s.Sock("holder"), editorSock(s, uiTerminal), editorSock(s, uiGUI)} {
		os.Remove(sock)
	}
	removeStaleIDELock(s)
	return os.RemoveAll(s.Dir())
}
