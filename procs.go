package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// proc identifies a process by pid and start time, so agentmux kills only
// the process it recorded, even if the system later reuses the pid.
type proc struct {
	Pid   int    `json:"pid"`
	Ppid  int    `json:"ppid"`
	Pgid  int    `json:"pgid"`
	Start string `json:"start"`
}

func processTable() (map[int]proc, error) {
	out, err := exec.Command("ps", "-A", "-o", "pid=,ppid=,pgid=,lstart=").Output()
	if err != nil {
		return nil, err
	}
	table := map[int]proc{}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 4 {
			continue
		}
		pid, _ := strconv.Atoi(f[0])
		ppid, _ := strconv.Atoi(f[1])
		pgid, _ := strconv.Atoi(f[2])
		table[pid] = proc{pid, ppid, pgid, strings.Join(f[3:], " ")}
	}
	return table, nil
}

// descendants returns root and every process below it. With byGroup, it
// also takes every process that shares a process group with any of them.
// This catches children whose parent exited, so launchd took them over.
// Use byGroup only when root leads its own session, as agents do.
func descendants(table map[int]proc, root int, byGroup bool) []proc {
	kids := map[int][]int{}
	for _, p := range table {
		kids[p.Ppid] = append(kids[p.Ppid], p.Pid)
	}
	seen := map[int]bool{}
	groups := map[int]bool{}
	var walk func(int)
	walk = func(pid int) {
		p, ok := table[pid]
		if !ok || seen[pid] {
			return
		}
		seen[pid] = true
		groups[p.Pgid] = true
		for _, k := range kids[pid] {
			walk(k)
		}
	}
	walk(root)
	for byGroup {
		n := len(seen)
		for _, p := range table {
			if groups[p.Pgid] && p.Pgid > 1 {
				walk(p.Pid)
			}
		}
		if len(seen) == n {
			break
		}
	}
	var out []proc
	for pid := range seen {
		out = append(out, table[pid])
	}
	return out
}

func recordProcs(path string, ps []proc) {
	b, _ := json.Marshal(ps)
	_ = writeFileAtomic(path, b)
}

func loadProcs(path string) []proc {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var ps []proc
	_ = json.Unmarshal(b, &ps)
	return ps
}

// alive returns the processes in ps that are still running, matched by pid
// and start time.
func alive(ps []proc) []proc {
	table, err := processTable()
	if err != nil {
		return nil
	}
	self := os.Getpid()
	var out []proc
	for _, p := range ps {
		if p.Pid == self {
			continue
		}
		if cur, ok := table[p.Pid]; ok && cur.Start == p.Start {
			out = append(out, p)
		}
	}
	return out
}

// killAll sends SIGHUP and SIGTERM to every process (and, with byGroup, its
// process group), waits up to grace for them to exit, then sends SIGKILL to
// any that are left. A closed terminal sends SIGHUP. Interactive shells
// ignore SIGTERM but exit on SIGHUP.
func killAll(ps []proc, grace time.Duration, byGroup bool) {
	signalAll := func(sig syscall.Signal) {
		groups := map[int]bool{}
		for _, p := range ps {
			if byGroup && p.Pgid > 1 && p.Pgid != syscall.Getpgrp() && !groups[p.Pgid] {
				groups[p.Pgid] = true
				_ = syscall.Kill(-p.Pgid, sig)
			}
			_ = syscall.Kill(p.Pid, sig)
		}
	}
	ps = alive(ps)
	if len(ps) == 0 {
		return
	}
	signalAll(syscall.SIGHUP)
	signalAll(syscall.SIGTERM)
	deadline := time.Now().Add(grace)
	for time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
		if ps = alive(ps); len(ps) == 0 {
			return
		}
	}
	signalAll(syscall.SIGKILL)
}
