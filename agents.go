package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// AgentConfig says how to launch an agent CLI. In Start, Resume and
// ResumeIf, {session_id} is replaced with the session's agent session id,
// {session_dir} with the agentmux session's directory (removed along with
// the session) and {claude_dir} with Claude Code's config directory.
type AgentConfig struct {
	Start  []string `json:"start"`
	Resume []string `json:"resume,omitempty"`
	// ResumeIf is a glob. When set, Resume is used only if it matches a
	// file, which shows the agent saved a conversation to resume.
	ResumeIf string `json:"resume_if,omitempty"`
	// IDE names the editor protocol the agent uses, if any: "claude"
	// (Claude Code's IDE protocol) or "pi" (the pi-ide extension).
	IDE string `json:"ide,omitempty"`
}

var builtinAgents = map[string]AgentConfig{
	"claude": {
		Start:  []string{"claude", "--session-id", "{session_id}"},
		Resume: []string{"claude", "--resume", "{session_id}"},
		// Claude writes the transcript when the first message is sent.
		// Resume needs that file.
		ResumeIf: "{claude_dir}/projects/*/{session_id}.jsonl",
		IDE:      "claude",
	},
	// codex and gemini pick their own session ids, so resume picks the
	// most recent conversation in this directory.
	"codex":  {Start: []string{"codex"}, Resume: []string{"codex", "resume", "--last"}},
	"gemini": {Start: []string{"gemini"}},
	// pi --session-id opens that conversation and creates it if needed, so
	// one command both starts and resumes (pi 1.4 and later).
	// With the pi-ide extension installed, pi also sees the editor.
	"pi":    {Start: []string{"pi", "--session-id", "{session_id}"}, IDE: "pi"},
	"shell": {Start: []string{"/bin/sh", "-c", "exec ${SHELL:-/bin/sh} -l"}},
}

// agents merges <home>/agents.json over the built-in table.
func agents() (map[string]AgentConfig, error) {
	out := map[string]AgentConfig{}
	for k, v := range builtinAgents {
		out[k] = v
	}
	b, err := os.ReadFile(filepath.Join(home(), "agents.json"))
	if errors.Is(err, os.ErrNotExist) {
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	var user map[string]AgentConfig
	if err := json.Unmarshal(b, &user); err != nil {
		return nil, fmt.Errorf("agents.json: %w", err)
	}
	for k, v := range user {
		out[k] = v
	}
	return out, nil
}

func agentConfig(name string) (AgentConfig, error) {
	all, err := agents()
	if err != nil {
		return AgentConfig{}, err
	}
	c, ok := all[name]
	if !ok || len(c.Start) == 0 {
		var names []string
		for k := range all {
			names = append(names, k)
		}
		sort.Strings(names)
		return AgentConfig{}, fmt.Errorf("unknown agent %q (have: %s)", name, strings.Join(names, ", "))
	}
	return c, nil
}

func expand(s *Session, a string) string {
	return strings.NewReplacer("{session_id}", s.AgentSessionID, "{session_dir}", s.Dir(),
		"{claude_dir}", claudeConfigDir()).Replace(a)
}

// agentArgv returns the command to run for the session, and whether it is
// the resume command. It picks resume when the agent has run before, can
// resume, and (if its config says how to check) has something to resume.
func agentArgv(s *Session) ([]string, bool, error) {
	c, err := agentConfig(s.Agent)
	if err != nil {
		return nil, false, err
	}
	argv, resume := c.Start, false
	if s.Started && len(c.Resume) > 0 {
		resume = true
		if c.ResumeIf != "" {
			m, _ := filepath.Glob(expand(s, c.ResumeIf))
			resume = len(m) > 0
		}
		if resume {
			argv = c.Resume
		}
	}
	out := make([]string, len(argv))
	for i, a := range argv {
		out[i] = expand(s, a)
	}
	return out, resume, nil
}
