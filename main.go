// Command agentmux keeps coding-agent CLIs running, each in its own session
// with a holder process that owns its PTY. Each session also gets an nvim
// whose layout and unsaved edits are saved in the session, so the editor
// can quit and come back as it was.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"golang.org/x/term"
)

const usage = `usage: agentmux <command> [args]

  n, new [-agent claude] [-name N] [-cwd DIR] [-detached]
                          create a session (and open it, when interactive)
  l, ls [-json]           list sessions
  c, cli [-detach-key ^X|none] <session>
                          attach this terminal to the session's agent
  a, attach <session>     open the session's editor and agent, or join it
                          if it is already open in another terminal
  serve <session>         run the session for a GUI over stdin and stdout
                          (ssh host agentmux serve <s>)
  s, send [-s <session>] [-enter] [text...]
                          type text (or stdin) into the agent
  g, goto [<session>] <file[:line[:col]]>
                          show a location in the session's editor
  r, restart <session>    stop the agent; it resumes on next cli or attach
  d, delete [-force] <session>...
                          stop everything and remove the session

<session> is an id, an id prefix, or a name. Inside a session (the agent or
its editor), it defaults to that session.
`

// aliases maps short command names to the commands they stand for.
var aliases = map[string]string{
	"n": "new", "l": "ls", "list": "ls", "c": "cli", "a": "attach", "o": "attach",
	"s": "send", "g": "goto", "r": "restart", "d": "delete", "rm": "delete",
}

func main() {
	log.SetFlags(log.LstdFlags)
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	cmd, args := os.Args[1], os.Args[2:]
	if full, ok := aliases[cmd]; ok {
		cmd = full
	}
	var err error
	switch cmd {
	case "new":
		err = cmdNew(args)
	case "ls":
		err = cmdList(args)
	case "attach":
		err = withSession(args, 1, func(s *Session, _ []string) error { return openLoop(s) })
	case "cli":
		err = cmdAttach(args)
	case "serve":
		err = cmdServe(args)
	case "send":
		err = cmdSend(args)
	case "goto":
		err = cmdGoto(args)
	case "restart":
		err = withSession(args, 1, func(s *Session, _ []string) error { killHolder(s); return nil })
	case "delete":
		err = cmdDelete(args)
	case "holder":
		err = runHolder(strings.Join(args, ""))
	case "-h", "--help", "help":
		fmt.Print(usage)
	default:
		err = fmt.Errorf("unknown command %q\n\n%s", cmd, usage)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "agentmux: %v\n", err)
		os.Exit(1)
	}
}

// withSession uses args[0] as the session when there are at least want
// arguments. Otherwise it uses the session this command runs inside.
func withSession(args []string, want int, f func(*Session, []string) error) error {
	ref := ""
	if len(args) >= want {
		ref, args = args[0], args[1:]
	}
	s, err := findSession(ref)
	if err != nil {
		return err
	}
	return f(s, args)
}

func cmdNew(args []string) error {
	fl := flag.NewFlagSet("new", flag.ExitOnError)
	agent := fl.String("agent", "claude", "agent to run")
	name := fl.String("name", "", "session name")
	cwd := fl.String("cwd", "", "working directory (default: current)")
	detached := fl.Bool("detached", false, "only create it; do not open the editor")
	fl.Parse(args)
	dir := *cwd
	if dir == "" {
		dir, _ = os.Getwd()
	}
	s, err := createSession(*agent, dir, *name)
	if err != nil {
		return err
	}
	if err := ensureHolder(s); err != nil {
		return err
	}
	if *detached || !term.IsTerminal(int(os.Stdin.Fd())) || os.Getenv("AGENTMUX_SESSION") != "" {
		fmt.Println(s.ID)
		return nil
	}
	return openLoop(s)
}

// sessionInfo is one row of `agentmux ls` and of its -json form. GUIs read
// the JSON (over ssh) to show a list of sessions.
type sessionInfo struct {
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	Agent      string    `json:"agent"`
	AgentState string    `json:"agent_state"` // running or stopped
	Editor     string    `json:"editor"`      // terminal, gui, or "" when closed
	Stashed    int       `json:"stashed"`     // buffers with unsaved changes
	Created    time.Time `json:"created"`
	Cwd        string    `json:"cwd"`
}

func cmdList(args []string) error {
	fl := flag.NewFlagSet("ls", flag.ExitOnError)
	asJSON := fl.Bool("json", false, "print a JSON array")
	fl.Parse(args)
	all, err := listSessions()
	if err != nil {
		return err
	}
	rows := []sessionInfo{}
	for _, s := range all {
		state := "stopped"
		if readPid(s.Path("holder.pid")) != 0 {
			state = "running"
		}
		dirty, _ := s.stashCount()
		rows = append(rows, sessionInfo{s.ID, s.Name, s.Agent, state, editorUI(s), len(dirty), s.Created, s.Cwd})
	}
	if *asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(rows)
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tNAME\tAGENT\tAGENT STATE\tEDITOR\tSTASHED\tAGE\tCWD")
	for _, r := range rows {
		editor := "-"
		if r.Editor != "" {
			editor = strings.ReplaceAll(strings.ReplaceAll(r.Editor, "terminal", "attach"), ",", "+")
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\n", r.ID, orDash(r.Name), r.Agent, r.AgentState, editor,
			r.Stashed, time.Since(r.Created).Round(time.Minute), r.Cwd)
	}
	return w.Flush()
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func cmdAttach(args []string) error {
	fl := flag.NewFlagSet("cli", flag.ExitOnError)
	key := fl.String("detach-key", "^]", "key that detaches (^X notation, or none)")
	fl.Parse(args)
	var dk byte
	switch {
	case *key == "none":
	case len(*key) == 2 && (*key)[0] == '^':
		dk = (*key)[1] & 0x1f
	default:
		return fmt.Errorf("bad -detach-key %q", *key)
	}
	return withSession(fl.Args(), 1, func(s *Session, _ []string) error { return attach(s, dk) })
}

func cmdSend(args []string) error {
	fl := flag.NewFlagSet("send", flag.ExitOnError)
	ref := fl.String("s", "", "session (default: the one we are inside)")
	enter := fl.Bool("enter", false, "press Enter after the text")
	fl.Parse(args)
	s, err := findSession(*ref)
	if err != nil {
		return err
	}
	text := strings.Join(fl.Args(), " ")
	if fl.NArg() == 0 {
		b, err := io.ReadAll(os.Stdin)
		if err != nil {
			return err
		}
		text = string(b)
	}
	if *enter {
		text += "\r"
	}
	return sendText(s, text)
}

func cmdGoto(args []string) error {
	if len(args) == 0 || len(args) > 2 {
		return fmt.Errorf("usage: agentmux goto [<session>] <file[:line[:col]]>")
	}
	return withSession(args, 2, func(s *Session, rest []string) error {
		path, line, col, err := parseLoc(rest[0])
		if err != nil {
			return err
		}
		out, err := nvimCall(s, "goto", map[string]any{"path": path, "line": line, "col": col})
		if out != "" && out != "0" {
			fmt.Println(out)
		}
		return err
	})
}

func cmdDelete(args []string) error {
	fl := flag.NewFlagSet("delete", flag.ExitOnError)
	force := fl.Bool("force", false, "delete even with an open editor or stashed edits")
	fl.Parse(args)
	if fl.NArg() == 0 {
		return fmt.Errorf("usage: agentmux delete [-force] <session>...")
	}
	var failed []string
	for _, ref := range fl.Args() {
		s, err := findSession(ref)
		if err == nil {
			err = deleteSession(s, *force)
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "agentmux: %s: %v\n", ref, err)
			failed = append(failed, ref)
		}
	}
	if len(failed) > 0 {
		return fmt.Errorf("not deleted: %s", strings.Join(failed, ", "))
	}
	return nil
}

// parseLoc splits "path[:line[:col]]" and makes path absolute against the
// caller's working directory.
func parseLoc(arg string) (string, int, int, error) {
	path, line, col := arg, 0, 0
	if m := locRe.FindStringSubmatch(arg); m != nil {
		path = m[1]
		line, _ = strconv.Atoi(m[2])
		col, _ = strconv.Atoi(m[3])
	}
	if path == "" {
		return "", 0, 0, errors.New("empty path")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", 0, 0, err
	}
	return abs, line, col, nil
}

var locRe = regexp.MustCompile(`^(.+?):(\d+)(?::(\d+))?$`)
