package main

import "testing"

func TestDetachIndex(t *testing.T) {
	const ctrlBracket = 0x1d
	cases := []struct {
		in   string
		want int
	}{
		{"abc\x1ddef", 3},
		{"abc", -1},
		{"x\x1b[93;5u", 1},     // kitty keyboard protocol
		{"\x1b[93;5:1u", 0},    // with the press event type
		{"\x1b[93;5:3u", -1},   // a release
		{"\x1b[93;6u", -1},     // Ctrl-Shift
		{"\x1b[97;5u", -1},     // Ctrl-a
		{"ab\x1b[27;5;93~", 2}, // xterm modifyOtherKeys
		{"\x1b[93;5u\x1d", 0},
	}
	for _, c := range cases {
		if got := detachIndex([]byte(c.in), ctrlBracket); got != c.want {
			t.Errorf("detachIndex(%q) = %d, want %d", c.in, got, c.want)
		}
	}
	if got := detachIndex([]byte("\x1b[113;5u"), 'q'&0x1f); got != 0 {
		t.Errorf("Ctrl-Q in kitty form: %d, want 0", got)
	}
	if keyName(ctrlBracket) != "Ctrl-]" || keyName('q'&0x1f) != "Ctrl-Q" {
		t.Errorf("keyName: %q %q", keyName(ctrlBracket), keyName('q'&0x1f))
	}
}
