package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAgentArgvResumesOnlySavedConversations(t *testing.T) {
	t.Setenv("AGENTMUX_HOME", t.TempDir())
	claudeDir := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", claudeDir)
	s, err := createSession("claude", t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	argv := func() string {
		a, _, err := agentArgv(s)
		if err != nil {
			t.Fatal(err)
		}
		return strings.Join(a, " ")
	}
	if got, want := argv(), "claude --session-id "+s.AgentSessionID; got != want {
		t.Fatalf("first launch: %q, want %q", got, want)
	}
	// Launched before, but the user sent zero messages: nothing to resume.
	s.Started = true
	if got, want := argv(), "claude --session-id "+s.AgentSessionID; got != want {
		t.Fatalf("no transcript: %q, want %q", got, want)
	}
	dir := filepath.Join(claudeDir, "projects", "-work-proj")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, s.AgentSessionID+".jsonl"), []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, want := argv(), "claude --resume "+s.AgentSessionID; got != want {
		t.Fatalf("with transcript: %q, want %q", got, want)
	}
}

func TestAgentArgvPiUsesTheSessionID(t *testing.T) {
	t.Setenv("AGENTMUX_HOME", t.TempDir())
	s, err := createSession("pi", t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	for _, started := range []bool{false, true} {
		s.Started = started
		a, _, err := agentArgv(s)
		if err != nil {
			t.Fatal(err)
		}
		if got, want := strings.Join(a, " "), "pi --session-id "+s.AgentSessionID; got != want {
			t.Fatalf("started=%v: %q, want %q", started, got, want)
		}
	}
}

func TestCreateSessionChecksTheDirectory(t *testing.T) {
	t.Setenv("AGENTMUX_HOME", t.TempDir())
	dir := t.TempDir()
	if _, err := createSession("shell", filepath.Join(dir, "missing"), ""); err == nil {
		t.Fatal("created a session in a directory that does not exist")
	}
	file := filepath.Join(dir, "file")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := createSession("shell", file, ""); err == nil {
		t.Fatal("created a session in a file")
	}
	t.Chdir(dir)
	s, err := createSession("shell", ".", "")
	if err != nil {
		t.Fatal(err)
	}
	if !filepath.IsAbs(s.Cwd) {
		t.Fatalf("cwd %q is not absolute", s.Cwd)
	}
}

func TestCreateSessionExpandsHome(t *testing.T) {
	t.Setenv("AGENTMUX_HOME", t.TempDir())
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.Mkdir(filepath.Join(home, "src"), 0o700); err != nil {
		t.Fatal(err)
	}
	for in, want := range map[string]string{"~": home, "~/src": filepath.Join(home, "src")} {
		s, err := createSession("shell", in, "")
		if err != nil {
			t.Fatal(err)
		}
		if s.Cwd != want {
			t.Fatalf("%q: cwd %q, want %q", in, s.Cwd, want)
		}
	}
	if got := expandHome("~other/x"); got != "~other/x" {
		t.Fatalf("expandHome(~other/x) = %q", got)
	}
}

func TestAgentEnvDropsTheLaunchingClaudeSession(t *testing.T) {
	t.Setenv("AGENTMUX_HOME", t.TempDir())
	s, err := createSession("claude", t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("CLAUDECODE", "1")
	t.Setenv("CLAUDE_CODE_CHILD_SESSION", "1")
	t.Setenv("CLAUDE_CODE_SESSION_ID", "parent")
	t.Setenv("CLAUDE_CODE_USE_BEDROCK", "1")
	env := strings.Join(agentEnv(s), "\n") + "\n"
	for _, k := range []string{"CLAUDECODE=", "CLAUDE_CODE_CHILD_SESSION=", "CLAUDE_CODE_SESSION_ID="} {
		if strings.Contains(env, "\n"+k) || strings.HasPrefix(env, k) {
			t.Errorf("agent environment still has %s", k)
		}
	}
	if !strings.Contains(env, "CLAUDE_CODE_USE_BEDROCK=1\n") {
		t.Error("agent environment lost the user's CLAUDE_CODE_USE_BEDROCK")
	}
}
