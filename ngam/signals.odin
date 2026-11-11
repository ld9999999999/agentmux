package ngam

// Ctrl-C, SIGTERM and a hangup close ngam the same way closing the window
// does, so serve still saves the snapshot. SDL's own signal handlers leave
// a main loop that waits in SDL_WaitEvent asleep, so ngam turns them off
// and blocks these signals in every thread. One thread waits for them and
// posts SDL_EVENT_QUIT.

import "core:sys/posix"
import "core:thread"
import sdl "vendor:sdl3"

@(private = "file")
quit_signals: posix.sigset_t

// signals_block must run before SDL_Init and before any thread starts, so
// that every thread inherits the blocked mask.
signals_block :: proc() {
	_ = sdl.SetHint(sdl.HINT_NO_SIGNAL_HANDLERS, "1")
	posix.sigemptyset(&quit_signals)
	posix.sigaddset(&quit_signals, .SIGINT)
	posix.sigaddset(&quit_signals, .SIGTERM)
	posix.sigaddset(&quit_signals, .SIGHUP)
	posix.pthread_sigmask(.BLOCK, &quit_signals, nil)
	// Ignore SIGPIPE, so a write to serve after it exits returns an error
	// and ngam keeps running.
	posix.sigignore(.SIGPIPE)
}

// signals_watch starts the thread that turns those signals into a quit.
signals_watch :: proc() {
	thread.run(proc() {
		for {
			sig: posix.Signal
			if posix.sigwait(&quit_signals, &sig) == .NONE {
				ev: sdl.Event
				ev.type = .QUIT
				_ = sdl.PushEvent(&ev)
			}
		}
	})
}
