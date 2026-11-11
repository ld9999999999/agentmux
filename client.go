package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"syscall"
	"time"

	"golang.org/x/term"
)

// attach connects the current terminal to the session's agent. detachKey
// is a single byte that ends the attach and leaves the agent running. 0
// turns it off (nvim uses 0, since it has its own way out).
func attach(s *Session, detachKey byte) error {
	if err := ensureHolder(s); err != nil {
		return err
	}
	conn, err := holderLink(s, "attach")
	if err != nil {
		return err
	}
	defer conn.Close()

	in, out := int(os.Stdin.Fd()), int(os.Stdout.Fd())
	if term.IsTerminal(in) {
		old, err := term.MakeRaw(in)
		if err != nil {
			return err
		}
		defer term.Restore(in, old)
	}
	sendSize := func() {
		if cols, rows, err := term.GetSize(out); err == nil {
			_ = writeFrame(conn, frameResize, resizePayload(uint16(rows), uint16(cols)))
		}
	}
	if detachKey != 0 && term.IsTerminal(in) {
		fmt.Fprintf(os.Stdout, "[agentmux: %s detaches; the agent keeps running]\r\n", keyName(detachKey))
	}
	sendSize()
	winch := make(chan os.Signal, 1)
	signal.Notify(winch, syscall.SIGWINCH)
	defer signal.Stop(winch)
	go func() {
		for range winch {
			sendSize()
		}
	}()

	done := make(chan string, 2)
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := os.Stdin.Read(buf)
			if n > 0 {
				b := buf[:n]
				if detachKey != 0 {
					if i := detachIndex(b, detachKey); i >= 0 {
						_ = writeFrame(conn, frameData, b[:i])
						done <- "detached"
						return
					}
				}
				if writeFrame(conn, frameData, b) != nil {
					done <- "connection lost"
					return
				}
			}
			if err != nil {
				done <- "input closed"
				return
			}
		}
	}()
	go func() {
		for {
			typ, payload, err := readFrame(conn)
			if err != nil {
				done <- "connection lost"
				return
			}
			switch typ {
			case frameData:
				os.Stdout.Write(payload)
			case frameExit:
				done <- "agent " + string(payload)
				return
			}
		}
	}()
	reason := <-done
	conn.Close()
	if term.IsTerminal(in) {
		fmt.Fprintf(os.Stdout, "\r\n[agentmux: %s]\r\n", reason)
	}
	return nil
}

// sendText types text into the agent's input as if the user had.
func sendText(s *Session, text string) error {
	if err := ensureHolder(s); err != nil {
		return err
	}
	conn, err := holderLink(s, "send")
	if err != nil {
		return err
	}
	defer conn.Close()
	return writeFrame(conn, frameData, []byte(text))
}

// killHolder asks a running holder to stop its agent. It returns once the
// holder has hung up.
func killHolder(s *Session) {
	conn, err := holderLink(s, "send")
	if err != nil {
		return
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if writeFrame(conn, frameKill, nil) != nil {
		return
	}
	_, _ = io.Copy(io.Discard, conn)
}

// detachIndex returns where the detach key (a control byte such as 0x1d
// for ^]) starts in b, or -1. Besides the plain byte it knows the forms a
// terminal sends after an agent turns on extended key reporting, as Claude
// Code does: the kitty keyboard protocol (ESC [ 93 ; 5 u, maybe with an
// event type, ESC [ 93 ; 5 : 1 u) and xterm's modifyOtherKeys
// (ESC [ 27 ; 5 ; 93 ~). Only key presses count; a key release has event
// type 3.
func detachIndex(b []byte, key byte) int {
	first := bytes.IndexByte(b, key)
	cp := int(key | 0x40) // ^] -> ']'
	if key >= 1 && key <= 26 {
		cp = int('a' + key - 1) // ^A -> 'a'
	}
	for _, m := range detachSeqRe.FindAllSubmatchIndex(b, -1) {
		var code, event string
		if m[2] >= 0 {
			code = string(b[m[2]:m[3]])
			if m[4] >= 0 {
				event = string(b[m[4]:m[5]])
			}
		} else {
			code = string(b[m[6]:m[7]])
		}
		if n, _ := strconv.Atoi(code); n == cp && event != "3" {
			if first < 0 || m[0] < first {
				return m[0]
			}
			break
		}
	}
	return first
}

// ESC [ code ; 5 [: event] u, or ESC [ 27 ; 5 ; code ~ (5: Ctrl alone).
var detachSeqRe = regexp.MustCompile(`\x1b\[(\d+);5(?::(\d+))?u|\x1b\[27;5;(\d+)~`)

// keyName returns a control byte as people write it: 0x1d is "Ctrl-]".
func keyName(key byte) string {
	if key >= 1 && key <= 26 {
		return "Ctrl-" + string(rune('A'+key-1))
	}
	return "Ctrl-" + string(rune(key|0x40))
}
