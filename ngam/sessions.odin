package ngam

// The Sessions view: the agentmux sessions on nvim's machine, from
// `agentmux ls -json` run in nvim (so a session on an ssh host lists that
// host's sessions), with the current one marked. Clicking another session
// switches to it on the same connection: the plugin's `:AgentSession
// switch` saves this session's editor and hands off to serve, which starts
// the other session's nvim and agent pane. Its "+" makes a new session in
// nvim's current folder and switches to it.

import "core:encoding/json"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import mu "vendor:microui"
import sdl "vendor:sdl3"
import mp "msgpack"

Sessions_View :: struct {
	gen:    int,
	busy:   bool, // a list request is on its way
	loaded: bool, // list holds an answer
	list:   []Session_Info,
	error:  string,
}

// Lua run in nvim: {true, json} or {false, message}, or {false} while
// nvim is still starting, because the plugin loads only after that. nvim
// answers requests during its startup, and a session's first start can
// take seconds. The plugin's "ready" event refreshes the view after.
@(private = "file")
LIST_LUA :: `
if vim.v.vim_did_enter == 0 then return {false} end
local ok, out = pcall(function() return require('agentmux').sessions() end)
return {ok, out}
`

// sessions_reset forgets a request that a quitting nvim will leave
// unanswered. The list stays, so it keeps showing while the next session
// starts.
sessions_reset :: proc(v: ^Sessions_View) {
	v.busy = false
	v.gen += 1
}

sessions_refresh :: proc(app: ^App) {
	v := &app.sessions
	if v.busy {
		return
	}
	gen := new(int)
	gen^ = v.gen
	if exec_lua(app, LIST_LUA, {}, list_done, gen) {
		v.busy = true
	} else {
		free(gen)
	}
}

@(private = "file")
list_done :: proc(app: ^App, result: mp.Value, failed: bool, user: rawptr) {
	gen := (^int)(user)
	defer free(gen)
	v := &app.sessions
	if gen^ != v.gen {
		return
	}
	v.busy = false
	if failed {
		return
	}
	r := mp.as_array(result)
	delete(v.error)
	v.error = ""
	if !mp.as_bool(mp.at(r, 0)) {
		if mp.at(r, 1) == nil {
			return // nvim is still starting
		}
		v.error = strings.clone(first_line(mp.as_str(mp.at(r, 1)), "agentmux ls failed."))
		app.need_draw = true
		return
	}
	list: []Session_Info
	if err := json.unmarshal(transmute([]u8)mp.as_str(mp.at(r, 1)), &list); err != nil {
		v.error = fmt.aprintf("Cannot read agentmux ls -json: %v", err)
		app.need_draw = true
		return
	}
	free_session_infos(v.list)
	v.list = list
	v.loaded = true
	app.need_draw = true
}

sessions_header :: proc(app: ^App) {
	if icon_button(&app.ui, "refresh", "↻") {
		sessions_refresh(app)
	}
	if icon_button(&app.ui, "new", "+") {
		// In nvim's current folder, with the default agent.
		session_command(app, "new")
	}
}

sessions_draw :: proc(app: ^App) -> int {
	v := &app.sessions
	ui := &app.ui
	if v.error != "" {
		mu_text_row(app, v.error)
		return -1
	}
	if !v.loaded {
		mu_text_row(app, app.rpc.attached ? "Loading…" : "")
		return -1
	}
	clicked := -1
	for x, i in v.list {
		current := x.id == app.session.id
		label := x.name != "" ? x.name : x.id
		detail := fmt.tprintf("%s · %s", x.agent, filepath.base(x.cwd))
		tag, color := "", ui.colors.dim
		switch {
		case current:
			tag, color = "here", ui.colors.accent
		case gui_has_it(x.editor):
			// Another GUI has it open, so serve would refuse it.
			tag, color = "in a GUI", ui.colors.conflict
		case x.editor != "":
			// Open in a terminal: this GUI can open it beside that.
			tag, color = "in a terminal", ui.colors.dim
		case x.stashed > 0:
			tag, color = fmt.tprintf("%d unsaved", x.stashed), ui.colors.modified
		case x.agent_state == "running":
			tag, color = "running", ui.colors.added
		case:
			tag = "stopped"
		}
		if list_row(ui, x.id, 0, label, detail = detail, tag = tag, tag_color = color, selected = current) {
			clicked = i
		}
	}
	if len(v.list) == 0 {
		mu_text_row(app, "No sessions.")
	}
	return clicked
}

sessions_click :: proc(app: ^App, row: int, mods: sdl.Keymod) {
	v := &app.sessions
	if row >= len(v.list) {
		return
	}
	x := v.list[row]
	label := x.name != "" ? x.name : x.id
	switch {
	case x.id == app.session.id:
	// Already here.
	case gui_has_it(x.editor):
		show_toast(app, fmt.tprintf("%s is open in another GUI; close it there first.", label))
	case:
		show_toast(app, fmt.tprintf("Switching to %s…", label))
		session_command(app, "switch", x.id)
	}
}

// session_command runs `:AgentSession <args>` in nvim. It runs once the
// request has been answered, because the command quits nvim.
@(private = "file")
session_command :: proc(app: ^App, args: ..string) {
	vals := make([]mp.Value, len(args), context.temp_allocator)
	for a, i in args {
		vals[i] = a
	}
	exec_lua(app, "local args = {...}\nvim.schedule(function() vim.cmd.AgentSession(args) end)", vals)
}

// mu_text_row is a line of text across the panel.
@(private = "file")
mu_text_row :: proc(app: ^App, text: string) {
	ctx := &app.ui.ctx
	mu.layout_row(ctx, {-1}, 0)
	mu.text(ctx, text)
}
