package main

import "testing"

func TestNvimVersionOK(t *testing.T) {
	for line, want := range map[string]bool{
		"NVIM v0.13.0-dev-1234+gabc": true,
		"NVIM v0.11.0":               true,
		"NVIM v1.0.0":                true,
		"NVIM v0.10.4":               false,
		"NVIM v0.6.1":                false,
		"VIM - Vi IMproved 9.1":      false,
	} {
		if got := nvimVersionOK(line); got != want {
			t.Errorf("nvimVersionOK(%q) = %v, want %v", line, got, want)
		}
	}
}
