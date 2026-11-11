package ngam

// ngam's own drawing of the parts of nvim's screen that the UI extensions
// hand over (`:help ui-cmdline`, `ui-popupmenu`, `ui-messages`,
// `ui-tabline`):
//
//   * the command line, as a box like a command palette, just under the
//     cursor's line (one line above it when the space below is too
//     small), with its completion menu next to it
//   * the insert-mode completion menu, at the text being completed
//   * messages as toasts at the top right; errors in error colors and kept
//     longer; long output (:ls, :!cmd, :messages) in a panel that Escape or
//     q closes; confirm() and other prompts in a dialog with buttons
//   * the mode, showcmd, ruler and search count in a strip at the bottom
//   * the tab line as a strip of tabs at the top, with close buttons
//
// Colors come from nvim's highlight groups (Pmenu, NormalFloat, ErrorMsg,
// TabLineSel, ...), read with nvim_get_hl when the colors change.

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import mp "msgpack"

// Chunk is a piece of text with one highlight (an hl_attr_define id).
Chunk :: struct {
	hl:   i32,
	text: string, // owned
}

Cmdline :: struct {
	content:     [dynamic]Chunk,
	pos:         int, // the cursor, as a byte offset into the content's text
	firstc:      string, // ":", "/", "?", "=" ... or ""
	prompt:      string, // an input() prompt, or ""
	indent:      int,
	special:     string, // a pending special character (after Ctrl-V), or ""
	shown:       bool,
}

Pum_Item :: struct {
	word, kind, menu: string, // owned
}

Popupmenu :: struct {
	shown:    bool,
	items:    [dynamic]Pum_Item,
	selected: int, // -1 for none
	row, col: int, // the anchor: where the completed word starts
	grid:     int, // the anchor's grid; -1 for the command line
	top:      int, // the first item shown, when there are more than fit
	rect:     sdl.Rect, // where it was drawn, for clicks
}

Message :: struct {
	kind:   string, // owned
	id:     string, // owned; "" when nvim gave none
	chunks: [dynamic]Chunk,
	until:  time.Tick, // when the toast goes away
	error:  bool,
	rect:   sdl.Rect, // where it was drawn, for clicks
}

// Msg_Panel shows long output: :ls, :!cmd, :messages.
Msg_Panel :: struct {
	open:   bool,
	title:  string, // borrowed: a constant
	lines:  [dynamic][dynamic]Chunk,
	scroll: int, // the first line shown
	fresh:  bool, // opened in this batch of events: more output is added
	rect:   sdl.Rect,
	rows:   int, // lines that fit, as last drawn
}

// Button is a choice in a dialog, such as [Y]es.
Button :: struct {
	label: string, // owned
	key:   string, // owned; what pressing it types
	def:   bool, // the default choice
	rect:  sdl.Rect,
}

Tab :: struct {
	handle: i64,
	name:   string, // owned: the current buffer's name in the tab
	label:  string, // owned: what the tab shows
	rect:   sdl.Rect,
	close:  sdl.Rect,
}

Ext_Ui :: struct {
	on:         bool, // attached with the extensions
	cmdlines:   [dynamic]Cmdline, // by level; the last shown one is drawn
	block:      [dynamic][dynamic]Chunk, // cmdline_block lines
	cmd_rect:   sdl.Rect, // the command line box as last drawn
	cmd_text_x: i32, // where its text starts
	cmd_prefix: int, // cells before the text (firstc, prompt, indent)
	cmd_above:  bool, // the box is above the cursor, as the space below is too small
	// The editor's cursor (grid, row, col) as it was before the command
	// line opened; the box is drawn by it.
	anchor:     [3]int,
	pum:        Popupmenu,
	toasts:     [dynamic]Message,
	panel:      Msg_Panel,
	dialog:     Message, // a confirm or return prompt; kind "" when none
	buttons:    [dynamic]Button,
	// The buttons came from the command line's prompt. nvim 0.13 puts
	// confirm()'s choices there ("(D)elete, [C]ancel: "), so the prompt box
	// is hidden while the dialog shows them.
	prompt_choices: bool,
	showmode:   [dynamic]Chunk,
	showcmd:    [dynamic]Chunk,
	ruler:      [dynamic]Chunk,
	search:     string, // owned: the last search count, such as "[3/7]"
	search_at:  time.Tick,
	tabs:       [dynamic]Tab,
	curtab:     i64,
	groups:     map[string]Hl, // highlight groups' colors, from nvim
	colors_gen: int, // the Grid.colors_gen the groups were read for
}

TOAST_TIME :: 4 * time.Second
ERROR_TIME :: 8 * time.Second
SEARCH_TIME :: 6 * time.Second
MAX_TOASTS :: 6
PUM_ROWS :: 12 // completion items shown at once
CMDLINE_BORDER :: i32(0x7ab8f5) // the command line box's border: light blue

// The groups whose colors the drawing uses.
@(private = "file")
GROUPS_LUA :: `
local out = {}
for _, n in ipairs({'Normal', 'NormalFloat', 'FloatBorder', 'Pmenu', 'PmenuSel', 'PmenuKind', 'PmenuExtra', 'ErrorMsg', 'WarningMsg', 'MoreMsg', 'Question', 'TabLine', 'TabLineSel', 'TabLineFill', 'StatusLine', 'Title', 'Search'}) do
  local ok, h = pcall(vim.api.nvim_get_hl, 0, {name = n, link = false})
  if ok then
    out[n] = {h.fg or -1, h.bg or -1, h.reverse or false, h.bold or false}
  end
end
return out
`

// ext_attach_options are the UI options ngam attaches with: all the
// extensions when native is on, and none when it is off.
EXT_OPTIONS := []string{"ext_multigrid", "ext_cmdline", "ext_popupmenu", "ext_messages", "ext_tabline"}

ext_options :: proc(native: bool) -> []string {
	return native ? EXT_OPTIONS : nil
}

// ext_reset forgets everything, for a new session or attach.
ext_reset :: proc(app: ^App) {
	e := &app.ext
	// Set before the grid's size is worked out: the strips take room.
	e.on = app.settings.native_ui
	for i in 0 ..< len(e.cmdlines) {
		cmdline_clear(&e.cmdlines[i])
	}
	clear(&e.cmdlines)
	block_clear(e)
	pum_clear(&e.pum)
	e.pum.shown = false
	for &t in e.toasts {
		message_free(&t)
	}
	clear(&e.toasts)
	panel_clear(&e.panel)
	e.panel.open = false
	dialog_close(e)
	chunks_clear(&e.showmode)
	chunks_clear(&e.showcmd)
	chunks_clear(&e.ruler)
	delete(e.search)
	e.search = ""
	tabs_clear(e)
	e.colors_gen = -1
}

// ---- Events ----

// ext_event handles one UI extension event. It returns false for an
// unknown event, which is then ignored.
ext_event :: proc(app: ^App, name: string, args: []mp.Value) -> bool {
	e := &app.ext
	switch name {
	case "cmdline_show":
		// [content, pos, firstc, prompt, indent, level, hl_id]
		cl := cmdline_level(e, int(mp.as_int(mp.at(args, 5))))
		cmdline_clear(cl)
		chunks_set(&cl.content, mp.as_array(mp.at(args, 0)))
		cl.pos = int(mp.as_int(mp.at(args, 1)))
		cl.firstc = strings.clone(mp.as_str(mp.at(args, 2)))
		cl.prompt = strings.clone(mp.as_str(mp.at(args, 3)))
		cl.indent = int(mp.as_int(mp.at(args, 4)))
		cl.shown = true
		if e.dialog.kind != "" && len(e.buttons) == 0 && cl.prompt != "" {
			parse_buttons(e, cl.prompt)
			e.prompt_choices = len(e.buttons) > 0
		}
	case "cmdline_pos":
		cl := cmdline_level(e, int(mp.as_int(mp.at(args, 1))))
		cl.pos = int(mp.as_int(mp.at(args, 0)))
	case "cmdline_special_char":
		cl := cmdline_level(e, int(mp.as_int(mp.at(args, 2))))
		delete(cl.special)
		cl.special = strings.clone(mp.as_str(mp.at(args, 0)))
	case "cmdline_hide":
		if e.prompt_choices {
			dialog_close(e) // the choice was made
		}
		level := max(int(mp.as_int(mp.at(args, 0))), 1)
		for len(e.cmdlines) >= level {
			cmdline_clear(&e.cmdlines[len(e.cmdlines) - 1])
			pop(&e.cmdlines)
		}
	case "cmdline_block_show":
		block_clear(e)
		for line in mp.as_array(mp.at(args, 0)) {
			append(&e.block, [dynamic]Chunk{})
			chunks_set(&e.block[len(e.block) - 1], mp.as_array(line))
		}
	case "cmdline_block_append":
		append(&e.block, [dynamic]Chunk{})
		chunks_set(&e.block[len(e.block) - 1], mp.as_array(mp.at(args, 0)))
	case "cmdline_block_hide":
		block_clear(e)
	case "popupmenu_show":
		// [items, selected, row, col, grid]
		p := &e.pum
		pum_clear(p)
		for v in mp.as_array(mp.at(args, 0)) {
			it := mp.as_array(v)
			append(&p.items, Pum_Item{strings.clone(mp.as_str(mp.at(it, 0))), strings.clone(mp.as_str(mp.at(it, 1))), strings.clone(mp.as_str(mp.at(it, 2)))})
		}
		p.selected = int(mp.as_int(mp.at(args, 1)))
		p.row = int(mp.as_int(mp.at(args, 2)))
		p.col = int(mp.as_int(mp.at(args, 3)))
		p.grid = len(args) > 4 ? int(mp.as_int(mp.at(args, 4))) : 1
		p.top = 0
		p.shown = true
		pum_keep_selected_shown(p)
	case "popupmenu_select":
		e.pum.selected = int(mp.as_int(mp.at(args, 0)))
		pum_keep_selected_shown(&e.pum)
	case "popupmenu_hide":
		e.pum.shown = false
	case "msg_show":
		msg_show(app, args)
	case "msg_clear":
		// Toasts go by themselves; a prompt that was answered goes at once.
		dialog_close(e)
	case "msg_showmode":
		chunks_set(&e.showmode, mp.as_array(mp.at(args, 0)))
	case "msg_showcmd":
		chunks_set(&e.showcmd, mp.as_array(mp.at(args, 0)))
	case "msg_ruler":
		chunks_set(&e.ruler, mp.as_array(mp.at(args, 0)))
	case "msg_history_show":
		// [entries, prev_cmd]: each entry is [kind, content, append].
		panel_clear(&e.panel)
		e.panel.title = "Messages"
		for entry in mp.as_array(mp.at(args, 0)) {
			en := mp.as_array(entry)
			panel_add(&e.panel, mp.as_array(mp.at(en, 1)), mp.as_bool(mp.at(en, 2)))
		}
		if len(e.panel.lines) == 0 {
			toast_text(app, "No messages.", false)
		} else {
			e.panel.open = true
			e.panel.scroll = max(len(e.panel.lines) - 1, 0) // the newest at the bottom
		}
	case "tabline_update":
		tabline_update(app, args)
	case:
		return false
	}
	return true
}

// ext_flush runs at the end of each batch of events.
ext_flush :: proc(app: ^App) {
	e := &app.ext
	e.panel.fresh = false
	if cmdline_shown(e) == nil {
		g := &app.grid
		e.anchor = {g.cursor_grid, g.cursor_row, g.cursor_col}
	}
	if app.grid.colors_gen != e.colors_gen && app.rpc.attached && e.on {
		e.colors_gen = app.grid.colors_gen
		exec_lua(app, GROUPS_LUA, {}, groups_done)
	}
}

@(private = "file")
groups_done :: proc(app: ^App, result: mp.Value, failed: bool, _: rawptr) {
	if failed {
		return
	}
	e := &app.ext
	for k in e.groups {
		delete(k)
	}
	clear(&e.groups)
	for entry in mp.as_map(result) {
		v := mp.as_array(entry.value)
		hl := HL_DEFAULT
		hl.fg = i32(mp.as_int(mp.at(v, 0)))
		hl.bg = i32(mp.as_int(mp.at(v, 1)))
		hl.reverse = mp.as_bool(mp.at(v, 2))
		hl.bold = mp.as_bool(mp.at(v, 3))
		e.groups[strings.clone(mp.as_str(entry.key))] = hl
	}
	app.need_draw = true
}

@(private = "file")
msg_show :: proc(app: ^App, args: []mp.Value) {
	// [kind, content, replace_last, history, append, id, trigger]
	e := &app.ext
	kind := mp.as_str(mp.at(args, 0))
	content := mp.as_array(mp.at(args, 1))
	replace_last := mp.as_bool(mp.at(args, 2))
	appending := mp.as_bool(mp.at(args, 4))
	id := value_key(mp.at(args, 5))

	switch kind {
	case "confirm", "confirm_sub", "return_prompt":
		// nvim waits for a key: show a dialog with the choices.
		dialog_open(app, kind, content)
		return
	case "search_count":
		delete(e.search)
		// nvim pads it ("/al            [1/3]"); keep one space between words.
		words := strings.fields(chunks_text(content), context.temp_allocator)
		e.search = strings.join(words, " ")
		e.search_at = time.tick_now()
		return
	case "search_cmd":
		return // the typed search; the command line already showed it
	case "empty":
		for &t in e.toasts {
			message_free(&t)
		}
		clear(&e.toasts)
		return
	}

	lines := strings.count(chunks_text(content), "\n") + 1
	long := kind == "list_cmd" || kind == "shell_out" || kind == "shell_err" || kind == "shell_ret" || kind == "shell_cmd" || lines > 4
	// A message that continues the open panel's output (shell output after
	// its command) joins it, as do messages in the same batch.
	joins := e.panel.open && (e.panel.fresh || appending)
	if long || joins {
		// Output for the panel.
		if !joins {
			panel_clear(&e.panel)
			e.panel.title = kind == "list_cmd" ? "Output" : (strings.has_prefix(kind, "shell") ? "Shell" : "Message")
			e.panel.open = true
			e.panel.fresh = true
			e.panel.scroll = 0
		}
		panel_add(&e.panel, content, appending)
		return
	}

	error := kind == "emsg" || kind == "echoerr" || kind == "lua_error" || kind == "rpc_error"
	// Which toast this message goes into: one with the same id, the last
	// one (replace_last, append), or a new one.
	t: ^Message
	if id != "" {
		for &old in e.toasts {
			if old.id == id {
				t = &old
			}
		}
	}
	if t == nil && (replace_last || appending) && len(e.toasts) > 0 {
		t = &e.toasts[len(e.toasts) - 1]
	}
	// The same text as the newest toast (nvim sends "match in file" twice,
	// for example): show it once, for longer.
	if t == nil && !appending && len(e.toasts) > 0 {
		last := &e.toasts[len(e.toasts) - 1]
		if last.kind == kind && chunks_text_d(last.chunks[:]) == chunks_text(content) {
			t = last
		}
	}
	if t == nil {
		if len(e.toasts) >= MAX_TOASTS {
			message_free(&e.toasts[0])
			ordered_remove(&e.toasts, 0)
		}
		append(&e.toasts, Message{})
		t = &e.toasts[len(e.toasts) - 1]
	}
	if !appending {
		chunks_clear(&t.chunks)
	}
	chunks_add(&t.chunks, content)
	delete(t.kind)
	t.kind = strings.clone(kind)
	delete(t.id)
	t.id = strings.clone(id)
	t.error = t.error && appending || error
	t.until = time.tick_add(time.tick_now(), t.error ? ERROR_TIME : TOAST_TIME)
}

// toast_text shows a toast of ngam's own.
@(private = "file")
toast_text :: proc(app: ^App, text: string, error: bool) {
	e := &app.ext
	m := Message{kind = strings.clone("ngam"), error = error}
	append(&m.chunks, Chunk{0, strings.clone(text)})
	m.until = time.tick_add(time.tick_now(), error ? ERROR_TIME : TOAST_TIME)
	append(&e.toasts, m)
}

// value_key turns a message id (a number or a string) into a string.
@(private = "file")
value_key :: proc(v: mp.Value) -> string {
	#partial switch x in v {
	case i64:
		return fmt.tprint(x)
	case string:
		return x
	}
	return ""
}

@(private = "file")
cmdline_level :: proc(e: ^Ext_Ui, level: int) -> ^Cmdline {
	l := max(level, 1)
	for len(e.cmdlines) < l {
		append(&e.cmdlines, Cmdline{})
	}
	return &e.cmdlines[l - 1]
}

@(private = "file")
cmdline_clear :: proc(cl: ^Cmdline) {
	chunks_clear(&cl.content)
	delete(cl.firstc)
	delete(cl.prompt)
	delete(cl.special)
	cl.firstc, cl.prompt, cl.special = "", "", ""
	cl.shown = false
}

// The command line drawn: the last level that is shown.
@(private = "file")
cmdline_shown :: proc(e: ^Ext_Ui) -> ^Cmdline {
	#reverse for &cl in e.cmdlines {
		if cl.shown {
			return &cl
		}
	}
	return nil
}

@(private = "file")
block_clear :: proc(e: ^Ext_Ui) {
	for &line in e.block {
		chunks_clear(&line)
		delete(line)
	}
	clear(&e.block)
}

@(private = "file")
pum_clear :: proc(p: ^Popupmenu) {
	for it in p.items {
		delete(it.word)
		delete(it.kind)
		delete(it.menu)
	}
	clear(&p.items)
}

@(private = "file")
pum_keep_selected_shown :: proc(p: ^Popupmenu) {
	if p.selected < 0 {
		return
	}
	if p.selected < p.top {
		p.top = p.selected
	} else if p.selected >= p.top + PUM_ROWS {
		p.top = p.selected - PUM_ROWS + 1
	}
}

@(private = "file")
panel_clear :: proc(p: ^Msg_Panel) {
	for &line in p.lines {
		chunks_clear(&line)
		delete(line)
	}
	clear(&p.lines)
}

// panel_add adds a message's text to the panel, split into lines. With
// appending, its first line continues the panel's last line.
@(private = "file")
panel_add :: proc(p: ^Msg_Panel, content: []mp.Value, appending: bool) {
	if !appending || len(p.lines) == 0 {
		append(&p.lines, [dynamic]Chunk{})
	}
	for v in content {
		c := mp.as_array(v)
		hl := i32(mp.as_int(mp.at(c, 0)))
		parts := strings.split(mp.as_str(mp.at(c, 1)), "\n", context.temp_allocator)
		for raw, i in parts {
			if i > 0 {
				append(&p.lines, [dynamic]Chunk{})
			}
			part := strings.trim_suffix(raw, "\r")
			if part != "" {
				append(&p.lines[len(p.lines) - 1], Chunk{hl, strings.clone(part)})
			}
		}
	}
}

@(private = "file")
message_free :: proc(m: ^Message) {
	delete(m.kind)
	delete(m.id)
	chunks_clear(&m.chunks)
	delete(m.chunks)
	m^ = {}
}

@(private = "file")
dialog_open :: proc(app: ^App, kind: string, content: []mp.Value) {
	e := &app.ext
	if e.dialog.kind != "" && kind != "return_prompt" {
		// A confirm after other text in the same prompt: keep adding.
		chunks_add(&e.dialog.chunks, content)
	} else {
		dialog_close(e)
		e.dialog.kind = strings.clone(kind)
		chunks_add(&e.dialog.chunks, content)
	}
	if kind == "return_prompt" && chunks_text_d(e.dialog.chunks[:]) == "" {
		append(&e.dialog.chunks, Chunk{0, strings.clone("Press Enter to continue")})
	}
	parse_buttons(e, chunks_text_d(e.dialog.chunks[:]))
	// If the message has no choices, look for them in the prompt that is
	// already shown.
	if len(e.buttons) == 0 {
		if cl := cmdline_shown(e); cl != nil && cl.prompt != "" {
			parse_buttons(e, cl.prompt)
			e.prompt_choices = len(e.buttons) > 0
		}
	}
}

@(private = "file")
dialog_close :: proc(e: ^Ext_Ui) {
	message_free(&e.dialog)
	for b in e.buttons {
		delete(b.label)
		delete(b.key)
	}
	clear(&e.buttons)
	e.prompt_choices = false
}

// parse_buttons finds the choices in the last line of text, such as
// "[Y]es, (N)o, (C)ancel: ": a letter in brackets is the default.
@(private = "file")
parse_buttons :: proc(e: ^Ext_Ui, text: string) {
	for b in e.buttons {
		delete(b.label)
		delete(b.key)
	}
	clear(&e.buttons)
	if e.dialog.kind == "return_prompt" {
		append(&e.buttons, Button{label = strings.clone("Continue"), key = strings.clone("<CR>"), def = true})
		return
	}
	last := strings.trim_space(text[strings.last_index_byte(text, '\n') + 1:])
	last = strings.trim_suffix(last, ":")
	for part in strings.split(last, ", ", context.temp_allocator) {
		p := strings.trim_space(part)
		open := strings.index_any(p, "[(")
		if open < 0 || open + 2 >= len(p) || (p[open + 2] != ']' && p[open + 2] != ')') {
			continue
		}
		key := p[open + 1:open + 2]
		label := strings.concatenate({p[:open], key, p[open + 3:]}, context.temp_allocator)
		append(&e.buttons, Button{label = strings.clone(label), key = strings.to_lower(key), def = p[open] == '['})
	}
}

@(private = "file")
tabline_update :: proc(app: ^App, args: []mp.Value) {
	// [curtab, tabs, curbuf, buffers]; tabs is [{tab, name}, ...].
	e := &app.ext
	before := len(e.tabs)
	tabs_clear(e)
	e.curtab = handle_of(mp.at(args, 0))
	for v in mp.as_array(mp.at(args, 1)) {
		m := mp.as_map(v)
		name := mp.as_str(mp.map_get(m, "name"))
		append(&e.tabs, Tab{handle = handle_of(mp.map_get(m, "tab")), name = strings.clone(name), label = strings.clone(tab_label(name))})
	}
	if (before > 1) != (len(e.tabs) > 1) {
		resize_editor(app) // the strip comes or goes
	}
	// The agentmux plugin's diff tabs get labels of their own.
	handles := make([]mp.Value, len(e.tabs), context.temp_allocator)
	for t, i in e.tabs {
		handles[i] = t.handle
	}
	exec_lua(app, TAB_LABELS_LUA, {handles}, tab_labels_done)
}

@(private = "file")
TAB_LABELS_LUA :: `
local out = {}
for i, h in ipairs((...)) do
  local ok, git = pcall(function() return vim.t[h].agentmux_git_diff end)
  local ok2, review = pcall(function() return vim.t[h].agentmux_diff end)
  local label = ''
  if ok and type(git) == 'string' then
    local staged = git:match(' staged$')
    local path = staged and git:sub(1, -8) or git
    label = '± ' .. vim.fs.basename(path) .. (staged and ' (staged)' or '')
  elseif ok2 and type(review) == 'string' then
    label = 'Review: ' .. vim.fs.basename(review)
  end
  out[i] = label
end
return out
`

@(private = "file")
tab_labels_done :: proc(app: ^App, result: mp.Value, failed: bool, _: rawptr) {
	if failed {
		return
	}
	e := &app.ext
	for v, i in mp.as_array(result) {
		if l := mp.as_str(v); l != "" && i < len(e.tabs) {
			delete(e.tabs[i].label)
			e.tabs[i].label = strings.clone(l)
		}
	}
	app.need_draw = true
}

@(private = "file")
tab_label :: proc(name: string) -> string {
	if name == "" {
		return "[No Name]"
	}
	return filepath.base(name)
}

@(private = "file")
tabs_clear :: proc(e: ^Ext_Ui) {
	for t in e.tabs {
		delete(t.name)
		delete(t.label)
	}
	clear(&e.tabs)
}

// handle_of reads a buffer, window or tab handle: a msgpack ext whose data
// is the number, or a plain number.
handle_of :: proc(v: mp.Value) -> i64 {
	#partial switch x in v {
	case mp.Ext:
		p := 0
		n, _ := mp.decode(x.data, &p)
		return mp.as_int(n)
	case i64:
		return x
	}
	return 0
}

// ---- Chunks ----

@(private = "file")
chunks_clear :: proc(cs: ^[dynamic]Chunk) {
	for c in cs {
		delete(c.text)
	}
	clear(cs)
}

// chunks_set replaces cs with content: [[attr_id, text, hl_id], ...].
@(private = "file")
chunks_set :: proc(cs: ^[dynamic]Chunk, content: []mp.Value) {
	chunks_clear(cs)
	chunks_add(cs, content)
}

@(private = "file")
chunks_add :: proc(cs: ^[dynamic]Chunk, content: []mp.Value) {
	for v in content {
		c := mp.as_array(v)
		append(cs, Chunk{i32(mp.as_int(mp.at(c, 0))), strings.clone(mp.as_str(mp.at(c, 1)))})
	}
}

// chunks_text is the text of content, in the temp allocator.
@(private = "file")
chunks_text :: proc(content: []mp.Value) -> string {
	b := strings.builder_make(context.temp_allocator)
	for v in content {
		strings.write_string(&b, mp.as_str(mp.at(mp.as_array(v), 1)))
	}
	return strings.to_string(b)
}

@(private = "file")
chunks_text_d :: proc(cs: []Chunk) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in cs {
		strings.write_string(&b, c.text)
	}
	return strings.to_string(b)
}

// chunks_before_last_line is chunks without their last line of text, in
// the temp allocator.
@(private = "file")
chunks_before_last_line :: proc(chunks: []Chunk) -> []Chunk {
	out := make([dynamic]Chunk, context.temp_allocator)
	text := chunks_text_d(chunks)
	cut := strings.last_index_byte(strings.trim_right_space(text), '\n')
	if cut < 0 {
		return out[:]
	}
	at := 0 // where the chunk starts in text
	for c in chunks {
		if at >= cut {
			break
		}
		append(&out, Chunk{c.hl, c.text[:min(len(c.text), cut - at)]})
		at += len(c.text)
	}
	return out[:]
}

// layout_cells lays out chunks as rows of cells at most width wide,
// breaking at "\n" and wrapping long lines. Tabs become spaces.
@(private = "file")
layout_cells :: proc(chunks: []Chunk, width: int, first_indent := 0, words := false) -> [dynamic][dynamic]Cell {
	rows := make([dynamic][dynamic]Cell, context.temp_allocator)
	append(&rows, make([dynamic]Cell, context.temp_allocator))
	for _ in 0 ..< first_indent {
		append(&rows[0], Cell{' ', 0})
	}
	w := max(width, 1)
	for c in chunks {
		for r in c.text {
			if r == '\n' {
				append(&rows, make([dynamic]Cell, context.temp_allocator))
				continue
			}
			n := 1
			ch := r
			if r == '\t' {
				ch = ' '
				n = 8 - len(rows[len(rows) - 1]) % 8
			} else if r < ' ' {
				continue // other control characters
			}
			for _ in 0 ..< n {
				if len(rows[len(rows) - 1]) >= w {
					next := make([dynamic]Cell, context.temp_allocator)
					if words {
						// Move a word that runs past the row's end to the
						// next row, if the row has a space to break at.
						cur := &rows[len(rows) - 1]
						for i := len(cur) - 1; i > 0; i -= 1 {
							if cur[i].r == ' ' {
								append(&next, ..cur[i + 1:])
								resize(cur, i)
								break
							}
						}
					}
					append(&rows, next)
					if words && ch == ' ' && len(next) == 0 {
						continue // drop the space at the start of a wrapped row
					}
				}
				append(&rows[len(rows) - 1], Cell{ch, c.hl})
			}
		}
	}
	return rows
}

// ---- Colors ----

// group gives a highlight group's colors with defaults filled in: from
// the group, else from fallback, else from Normal.
@(private = "file")
group :: proc(app: ^App, name: string, fallback := "") -> (fg, bg: i32) {
	g := &app.grid
	fg, bg = g.default_fg, g.default_bg
	found := false
	for n in ([]string{fallback, name}) {
		if n == "" {
			continue
		}
		if h, ok := app.ext.groups[n]; ok {
			found = true
			if h.fg >= 0 {fg = h.fg}
			if h.bg >= 0 {bg = h.bg}
			if h.reverse {
				fg, bg = bg, fg
			}
		}
	}
	if !found && name == "PmenuSel" {
		fg, bg = g.default_bg, g.default_fg
	}
	return
}

// shade moves a color a little toward the foreground, for boxes on a
// theme whose floats lack a color of their own.
@(private = "file")
shade :: proc(bg, fg: i32, amount: f32) -> i32 {
	mix :: proc(a, b: i32, t: f32) -> i32 {
		return i32(f32(a) + (f32(b) - f32(a)) * t)
	}
	r := mix((bg >> 16) & 0xff, (fg >> 16) & 0xff, amount)
	gr := mix((bg >> 8) & 0xff, (fg >> 8) & 0xff, amount)
	b := mix(bg & 0xff, fg & 0xff, amount)
	return r << 16 | gr << 8 | b
}

// box_colors are a floating box's background and border.
@(private = "file")
box_colors :: proc(app: ^App) -> (fg, bg, border: i32) {
	fg, bg = group(app, "NormalFloat", "Pmenu")
	if bg == app.grid.default_bg {
		bg = shade(bg, fg, 0.06)
	}
	border, _ = group(app, "FloatBorder")
	if border == app.grid.default_fg {
		border = shade(bg, fg, 0.35)
	}
	return
}

// ---- Layout ----

// ext_tabline_h is the height of the tab strip, or 0 when it is hidden
// (with one tab, as 'showtabline' 1 does).
ext_tabline_h :: proc(app: ^App) -> i32 {
	if !app.ext.on || len(app.ext.tabs) < 2 {
		return 0
	}
	return app.ui.font.cell_h + 2 * tab_pad(app)
}

// ext_status_h is the height of the status strip at the bottom.
ext_status_h :: proc(app: ^App) -> i32 {
	return app.ext.on ? app.font.cell_h : 0
}

@(private = "file")
tab_pad :: proc(app: ^App) -> i32 {
	return max(app.ui.font.cell_h / 3, 2)
}

// ---- Drawing ----

// ext_draw draws the native elements over the editor area r (in pixels)
// and the strips above and below it.
ext_draw :: proc(app: ^App, r: sdl.Rect) {
	e := &app.ext
	if !e.on {
		return
	}
	rd := &app.rd
	set_clip(rd, nil)
	// The strips go edge to edge, outside the editor's padding.
	frame := editor_frame_rect(app)
	draw_tabline(app, frame)
	draw_status(app, frame)
	draw_toasts(app, r)
	draw_cmdline(app, r)
	draw_pum(app, r)
	draw_panel(app, r)
	draw_dialog(app, r)
	set_clip(rd, nil)
}

// draw_cells draws a row of cells at x, y in fg on the box's color: a
// cell's highlight colors win where it has them.
@(private = "file")
draw_cells :: proc(app: ^App, cells: []Cell, x, y: i32, fg: i32) {
	rd, f, g := &app.rd, &app.font, &app.grid
	for c, i in cells {
		hl := grid_hl(g, c.hl)
		cx := x + i32(i) * f.cell_w
		cfg := hl.fg >= 0 ? hl.fg : fg
		if hl.bg >= 0 || hl.reverse {
			cfg2, cbg, _ := cell_colors(g, hl)
			if hl.fg < 0 && !hl.reverse {
				cfg2 = fg
			}
			rect(rd, f, cx, y, f.cell_w, f.cell_h, cbg)
			cfg = cfg2
		}
		if c.r != ' ' && c.r != 0 {
			glyph(rd, f, cx, y, c.r, cell_style(hl), rgb_color(cfg))
		}
		if hl.underline || hl.undercurl {
			rect(rd, f, cx, y + f.underline_y, f.cell_w, f.line_px, cfg)
		}
	}
}

// draw_box draws a box with a border and returns its inner rectangle.
@(private = "file")
draw_box :: proc(app: ^App, r: sdl.Rect, bg, border: i32) {
	rd, f := &app.rd, &app.font
	t := f.line_px
	rect(rd, f, r.x, r.y, r.w, r.h, border)
	rect(rd, f, r.x + t, r.y + t, r.w - 2 * t, r.h - 2 * t, bg)
}

@(private = "file")
draw_tabline :: proc(app: ^App, area: sdl.Rect) {
	e := &app.ext
	h := ext_tabline_h(app)
	if h == 0 {
		return
	}
	rd, uf := &app.rd, &app.ui.font
	fill_fg, fill_bg := group(app, "TabLineFill", "TabLine")
	_ = fill_fg
	y := area.y - h
	set_clip(rd, sdl.Rect{area.x, y, area.w, h})
	rect(rd, &app.font, area.x, y, area.w, h, fill_bg)
	pad := tab_pad(app)
	x := area.x
	close_w := text_width(uf, "×") + pad
	max_w := max(area.w / i32(len(e.tabs)), close_w * 4)
	for &t in e.tabs {
		cur := t.handle == e.curtab
		fg, bg := group(app, cur ? "TabLineSel" : "TabLine")
		label := t.label
		w := min(text_width(uf, label) + 3 * pad + close_w, max_w)
		t.rect = {x, y, w, h}
		rect(rd, &app.font, x, y, w, h, bg)
		if cur {
			// The current tab has a line in ngam's accent color on top.
			acc := app.ui.colors.accent
			rect(rd, &app.font, x, y, w, max(app.font.line_px * 2, 2), i32(acc.r) << 16 | i32(acc.g) << 8 | i32(acc.b))
		}
		set_clip(rd, sdl.Rect{x, y, w - close_w - pad, h})
		text(rd, uf, x + pad, y + pad, label, rgb_color(fg))
		set_clip(rd, sdl.Rect{area.x, y, area.w, h})
		t.close = {x + w - close_w - pad / 2, y, close_w, h}
		text(rd, uf, t.close.x + pad / 2, y + pad, "×", rgb_color(fg, cur ? 1 : 0.6))
		// A line between tabs.
		rect(rd, &app.font, x + w - 1, y + pad, 1, h - 2 * pad, shade(bg, fg, 0.3))
		x += w
	}
	set_clip(rd, nil)
}

@(private = "file")
draw_status :: proc(app: ^App, area: sdl.Rect) {
	e := &app.ext
	rd, f := &app.rd, &app.font
	// The strip is the last line of the window, below the editor's frame.
	strip_y := area.y + area.h
	h := ext_status_h(app)
	y := strip_y + (h - f.cell_h) / 2
	fg, bg := group(app, "Normal")
	bg = shade(bg, fg, 0.04)
	set_clip(rd, sdl.Rect{area.x, strip_y, area.w, h})
	rect(rd, f, area.x, strip_y, area.w, h, bg)
	cols := int(area.w / f.cell_w)
	// The mode on the left; showcmd, the search count and the ruler on
	// the right.
	left := layout_cells(e.showmode[:], cols)
	draw_cells(app, left[0][:], area.x + f.cell_w, y, fg)
	right := make([dynamic]Chunk, context.temp_allocator)
	append(&right, ..e.showcmd[:])
	if e.search != "" && time.tick_since(e.search_at) < SEARCH_TIME {
		append(&right, Chunk{0, "   "}, Chunk{0, e.search})
	}
	if len(e.ruler) > 0 {
		append(&right, Chunk{0, "   "})
		append(&right, ..e.ruler[:])
	}
	rcells := layout_cells(right[:], cols)
	n := i32(len(rcells[0]))
	draw_cells(app, rcells[0][:], area.x + area.w - (n + 1) * f.cell_w, y, shade(fg, bg, 0.25))
	set_clip(rd, nil)
}

@(private = "file")
draw_toasts :: proc(app: ^App, area: sdl.Rect) {
	e := &app.ext
	rd, f := &app.rd, &app.font
	// Drop the toasts whose time is up.
	for i := 0; i < len(e.toasts); {
		if time.tick_since(e.toasts[i].until) >= 0 {
			message_free(&e.toasts[i])
			ordered_remove(&e.toasts, i)
		} else {
			i += 1
		}
	}
	fg, bg, border := box_colors(app)
	pad := f.cell_w / 2 + f.line_px
	max_cols := clamp(int(area.w / f.cell_w) - 4, 10, 80)
	y := area.y + pad
	for &t in e.toasts {
		tfg, tbg, tborder := fg, bg, border
		if t.error {
			efg, ebg := group(app, "ErrorMsg")
			tfg = efg
			tborder = efg
			if ebg != app.grid.default_bg {
				tbg = ebg
			}
		}
		rows := layout_cells(t.chunks[:], max_cols)
		if len(rows) > 10 {
			resize(&rows, 10)
		}
		w := 0
		for row in rows {
			w = max(w, len(row))
		}
		if w == 0 {
			continue
		}
		bw := i32(w) * f.cell_w + 2 * pad
		bh := i32(len(rows)) * f.cell_h + 2 * pad
		t.rect = {area.x + area.w - bw - pad, y, bw, bh}
		set_clip(rd, area)
		draw_box(app, t.rect, tbg, tborder)
		for row, i in rows {
			draw_cells(app, row[:], t.rect.x + pad, t.rect.y + pad + i32(i) * f.cell_h, tfg)
		}
		y += bh + pad
	}
	set_clip(rd, nil)
}

@(private = "file")
draw_cmdline :: proc(app: ^App, area: sdl.Rect) {
	e := &app.ext
	cl := cmdline_shown(e)
	if cl == nil || (e.prompt_choices && e.dialog.kind != "") {
		e.cmd_rect = {}
		return
	}
	rd, f := &app.rd, &app.font
	fg, bg, _ := box_colors(app)
	border := CMDLINE_BORDER
	pad := f.cell_w / 2 + f.line_px
	cols := int(min(area.w - 4 * f.cell_w, max(area.w * 6 / 10, 60 * f.cell_w)) / f.cell_w)
	cols = max(cols, 10)

	// The text: firstc or the prompt, the indent, then the content.
	head := make([dynamic]Chunk, context.temp_allocator)
	if cl.prompt != "" {
		append(&head, Chunk{0, cl.prompt})
	} else if cl.firstc != "" {
		append(&head, Chunk{0, cl.firstc})
	}
	prefix := 0
	for c in head {
		prefix += utf8.rune_count(c.text)
	}
	prefix += cl.indent
	for _ in 0 ..< cl.indent {
		append(&head, Chunk{0, " "})
	}
	append(&head, ..cl.content[:])
	lines := layout_cells(head[:], cols)
	block := make([dynamic][dynamic]Cell, context.temp_allocator)
	for bl in e.block {
		for row in layout_cells(bl[:], cols) {
			append(&block, row)
		}
	}
	// The cursor's cell: the runes before pos, after the prefix.
	text := chunks_text_d(cl.content[:])
	before := utf8.rune_count(text[:clamp(cl.pos, 0, len(text))])
	cur := prefix + before
	cur_row, cur_col := cur / cols, cur % cols
	for cur_row >= len(lines) {
		append(&lines, make([dynamic]Cell, context.temp_allocator))
	}

	n := len(block) + len(lines)
	r := sdl.Rect{area.x + (area.w - i32(cols) * f.cell_w) / 2 - pad, 0, i32(cols) * f.cell_w + 2 * pad, i32(n) * f.cell_h + 2 * pad}
	r.y, e.cmd_above = cmdline_y(app, area, r.h)
	e.cmd_rect = r
	e.cmd_text_x = r.x + pad
	e.cmd_prefix = prefix
	set_clip(rd, area)
	draw_box(app, r, bg, border)
	y := r.y + pad
	for row in block {
		draw_cells(app, row[:], r.x + pad, y, shade(fg, bg, 0.3))
		y += f.cell_h
	}
	first_line_y := y
	for row in lines {
		draw_cells(app, row[:], r.x + pad, y, fg)
		y += f.cell_h
	}
	// The prompt or firstc in the title color.
	if prefix > 0 {
		tfg, _ := group(app, "Title")
		p := lines[0][:min(prefix - cl.indent, len(lines[0]))]
		for &c in p {
			c.hl = 0
		}
		draw_cells(app, p, r.x + pad, first_line_y, tfg)
	}
	// The cursor, a bar, and a pending special character.
	cx := r.x + pad + i32(cur_col) * f.cell_w
	cy := first_line_y + i32(cur_row) * f.cell_h
	if cl.special != "" {
		sr, _ := utf8.decode_rune_in_string(cl.special)
		rect(rd, f, cx, cy, f.cell_w, f.cell_h, bg)
		glyph(rd, f, cx, cy, sr, .Regular, rgb_color(fg))
	}
	if app.focused && !agent_has_focus(app) {
		rect(rd, f, cx, cy, max(f.line_px * 2, 2), f.cell_h, fg)
	}
	set_clip(rd, nil)
}

// cmdline_y places the command line box, h tall: just under the line the
// editor's cursor was on, or one line above it when the space below is too
// small.
@(private = "file")
cmdline_y :: proc(app: ^App, area: sdl.Rect, h: i32) -> (y: i32, above: bool) {
	f, e := &app.font, &app.ext
	oy := area.y
	if win := app.grid.wins[e.anchor[0]]; win != nil {
		_, oy, _ = win_origin(f, &app.grid, win, area.x, area.y)
	}
	top := oy + i32(e.anchor[1]) * f.cell_h
	bottom := area.y + area.h
	if y = top + f.cell_h + f.cell_h / 2; y + h <= bottom {
		return y, false
	}
	if y = top - f.cell_h - h; y >= area.y {
		return y, true
	}
	return clamp(top - h - f.cell_h / 2, area.y, max(bottom - h, area.y)), true
}

@(private = "file")
draw_pum :: proc(app: ^App, area: sdl.Rect) {
	p := &app.ext.pum
	if !p.shown || len(p.items) == 0 {
		p.rect = {}
		return
	}
	rd, f := &app.rd, &app.font
	word_w, kind_w, menu_w := 0, 0, 0
	for it in p.items {
		word_w = max(word_w, utf8.rune_count(it.word))
		kind_w = max(kind_w, utf8.rune_count(it.kind))
		menu_w = max(menu_w, utf8.rune_count(it.menu))
	}
	cols := 1 + word_w + 1 + (kind_w > 0 ? kind_w + 1 : 0) + (menu_w > 0 ? menu_w + 1 : 0)
	cols = min(cols, int(area.w / f.cell_w) - 2)
	n := min(len(p.items), PUM_ROWS)
	w, h := i32(cols) * f.cell_w, i32(n) * f.cell_h

	// The anchor: under the command line box, or at the cell on its grid.
	x, y, above_y: i32
	if p.grid == -1 && app.ext.cmd_rect.w > 0 {
		x = app.ext.cmd_text_x + i32(app.ext.cmd_prefix + p.col) * f.cell_w - f.cell_w
		y = app.ext.cmd_rect.y + app.ext.cmd_rect.h
		above_y = app.ext.cmd_rect.y
	} else {
		win := app.grid.wins[p.grid == -1 ? 1 : p.grid]
		ox, oy: i32 = area.x, area.y
		if win != nil {
			ox, oy, _ = win_origin(f, &app.grid, win, area.x, area.y)
		}
		x = ox + i32(p.col) * f.cell_w - f.cell_w
		y = oy + i32(p.row + 1) * f.cell_h
		above_y = oy + i32(p.row) * f.cell_h
	}
	// Above the anchor when the space below is too small, and above a
	// command line box that sits above the cursor, so the cursor's line
	// stays in view.
	prefer_above := p.grid == -1 && app.ext.cmd_rect.w > 0 && app.ext.cmd_above
	if (prefer_above || y + h > area.y + area.h) && above_y - h >= area.y {
		y = above_y - h
	}
	x = clamp(x, area.x, max(area.x + area.w - w, area.x))
	p.rect = {x, y, w, h}

	fg, bg := group(app, "Pmenu")
	if bg == app.grid.default_bg {
		_, bg, _ = box_colors(app)
	}
	sfg, sbg := group(app, "PmenuSel")
	kfg, _ := group(app, "PmenuKind", "Pmenu")
	mfg, _ := group(app, "PmenuExtra", "Pmenu")
	set_clip(rd, area)
	rect(rd, f, x, y, w, h, bg)
	for i in 0 ..< n {
		idx := p.top + i
		if idx >= len(p.items) {
			break
		}
		it := p.items[idx]
		iy := y + i32(i) * f.cell_h
		ifg := fg
		if idx == p.selected {
			rect(rd, f, x, iy, w, f.cell_h, sbg)
			ifg = sfg
		}
		cx := x + f.cell_w
		set_clip(rd, intersect({x, iy, w, f.cell_h}, area))
		draw_plain(app, it.word, cx, iy, ifg)
		cx += i32(word_w + 1) * f.cell_w
		if kind_w > 0 {
			draw_plain(app, it.kind, cx, iy, idx == p.selected ? ifg : kfg)
			cx += i32(kind_w + 1) * f.cell_w
		}
		if menu_w > 0 {
			draw_plain(app, it.menu, cx, iy, idx == p.selected ? ifg : mfg)
		}
		set_clip(rd, area)
	}
	// A scroll bar when there are more items than fit.
	if len(p.items) > n {
		th := max(h * i32(n) / i32(len(p.items)), f.cell_h / 2)
		ty := y + (h - th) * i32(p.top) / i32(max(len(p.items) - n, 1))
		rect(rd, f, x + w - f.line_px * 3, ty, f.line_px * 3, th, shade(bg, fg, 0.4))
	}
	set_clip(rd, nil)
}

// draw_plain draws text in the editor font, one cell per character.
@(private = "file")
draw_plain :: proc(app: ^App, s: string, x, y: i32, fg: i32) {
	i: i32 = 0
	for r in s {
		if r != ' ' {
			glyph(&app.rd, &app.font, x + i * app.font.cell_w, y, r, .Regular, rgb_color(fg))
		}
		i += 1
	}
}

@(private = "file")
draw_panel :: proc(app: ^App, area: sdl.Rect) {
	p := &app.ext.panel
	if !p.open {
		p.rect = {}
		return
	}
	rd, f := &app.rd, &app.font
	fg, bg, border := box_colors(app)
	pad := f.cell_w / 2 + f.line_px
	w := area.w * 9 / 10
	cols := int((w - 2 * pad) / f.cell_w)
	// Wrapped lines, each a row of cells.
	rows := make([dynamic][dynamic]Cell, context.temp_allocator)
	for line in p.lines {
		for row in layout_cells(line[:], cols) {
			append(&rows, row)
		}
	}
	// Output usually ends with a newline: skip the empty line after it.
	for len(rows) > 1 && len(rows[len(rows) - 1]) == 0 {
		pop(&rows)
	}
	max_rows := int((area.h * 8 / 10 - 2 * pad) / f.cell_h) - 2
	shown := clamp(len(rows), 1, max(max_rows, 1))
	p.rows = shown
	p.scroll = clamp(p.scroll, 0, max(len(rows) - shown, 0))
	h := i32(shown + 2) * f.cell_h + 2 * pad
	r := sdl.Rect{area.x + (area.w - w) / 2, area.y + (area.h - h) / 2, w, h}
	p.rect = r
	set_clip(rd, area)
	draw_box(app, r, bg, border)
	tfg, _ := group(app, "Title")
	draw_plain(app, p.title, r.x + pad, r.y + pad, tfg)
	hint := len(rows) > shown ? fmt.tprintf("%d-%d of %d   j/k scroll   q or Esc closes", p.scroll + 1, p.scroll + shown, len(rows)) : "q or Esc closes"
	hfg := shade(fg, bg, 0.4)
	draw_plain(app, hint, r.x + r.w - pad - i32(utf8.rune_count(hint)) * f.cell_w, r.y + pad, hfg)
	set_clip(rd, intersect({r.x, r.y + pad + f.cell_h, r.w, i32(shown + 1) * f.cell_h}, area))
	for i in 0 ..< shown {
		idx := p.scroll + i
		if idx >= len(rows) {
			break
		}
		draw_cells(app, rows[idx][:], r.x + pad, r.y + pad + i32(i + 1) * f.cell_h + f.cell_h / 2, fg)
	}
	set_clip(rd, nil)
}

@(private = "file")
draw_dialog :: proc(app: ^App, area: sdl.Rect) {
	e := &app.ext
	if e.dialog.kind == "" {
		return
	}
	rd, f := &app.rd, &app.font
	fg, bg, _ := box_colors(app)
	qfg, _ := group(app, "Question", "MoreMsg")
	pad := f.cell_w + f.line_px
	cols := clamp(int(area.w / f.cell_w) - 8, 20, 72)
	text_chunks := e.dialog.chunks[:]
	// When the choices came from the message's last line, that line is
	// shown as buttons instead, so leave it out of the text.
	if len(e.buttons) > 0 && !e.prompt_choices && e.dialog.kind != "return_prompt" {
		text_chunks = chunks_before_last_line(e.dialog.chunks[:])
	}
	rows := layout_cells(text_chunks, cols, words = true)
	w := 0
	for row in rows {
		w = max(w, len(row))
	}
	// The buttons, in one row under the text.
	bw_total: i32 = 0
	for b in e.buttons {
		bw_total += i32(utf8.rune_count(b.label) + 4) * f.cell_w
	}
	bw := max(i32(w) * f.cell_w, bw_total)
	bh := i32(len(rows)) * f.cell_h + f.cell_h * 3 / 2 + f.cell_h + 2 * pad
	r := sdl.Rect{area.x + (area.w - bw - 2 * pad) / 2, area.y + area.h / 4, bw + 2 * pad, bh}
	set_clip(rd, nil)
	// Dim the editor behind it.
	fill(rd, f, area.x, area.y, area.w, area.h, {0, 0, 0, 0.35})
	draw_box(app, r, bg, qfg)
	for row, i in rows {
		draw_cells(app, row[:], r.x + pad, r.y + pad + i32(i) * f.cell_h, fg)
	}
	bx := r.x + r.w - pad - bw_total
	by := r.y + r.h - pad - f.cell_h - f.cell_h / 4
	sfg, sbg := group(app, "PmenuSel")
	for &b in e.buttons {
		w := i32(utf8.rune_count(b.label) + 3) * f.cell_w
		b.rect = {bx, by - f.cell_h / 4, w, f.cell_h * 3 / 2}
		if b.def {
			rect(rd, f, b.rect.x, b.rect.y, b.rect.w, b.rect.h, sbg)
			draw_plain(app, b.label, bx + f.cell_w * 3 / 2, by, sfg)
		} else {
			draw_box(app, b.rect, bg, shade(bg, fg, 0.4))
			draw_plain(app, b.label, bx + f.cell_w * 3 / 2, by, fg)
		}
		bx += w + f.cell_w
	}
}

// ext_deadline is how long until a toast or the search count goes, in
// ms, or -1.
ext_deadline :: proc(app: ^App) -> i32 {
	e := &app.ext
	best: i32 = -1
	consider :: proc(best: ^i32, until: time.Tick) {
		left := i32(time.duration_milliseconds(time.tick_diff(time.tick_now(), until))) + 1
		left = max(left, 1)
		if best^ < 0 || left < best^ {
			best^ = left
		}
	}
	for t in e.toasts {
		consider(&best, t.until)
	}
	if e.search != "" && time.tick_since(e.search_at) < SEARCH_TIME {
		consider(&best, time.tick_add(e.search_at, SEARCH_TIME))
	}
	return best
}

// ---- Mouse and keys ----

// cmdline_hidden says whether the editor has the cursor. That is true
// while the command line box is hidden.
cmdline_hidden :: proc(app: ^App) -> bool {
	return !app.ext.on || cmdline_shown(&app.ext) == nil
}

// ext_reattach attaches to nvim again after the native_ui setting changed.
// nvim then sends the whole screen again, in the new form.
ext_reattach :: proc(app: ^App) {
	if !app.rpc.attached {
		return
	}
	nvim_ui_detach(app)
	grid_clear_all(&app.grid)
	ext_reset(app)
	app.ext.on = app.settings.native_ui
	cols, rows := grid_size(app)
	nvim_ui_attach(app, cols, rows)
	ext_session_started(app)
	if !app.settings.native_ui {
		// nvim's own command line needs a row again.
		exec_lua(app, "if vim.o.cmdheight == 0 then vim.o.cmdheight = 1 end", {})
	}
	app.need_draw = true
}

// ext_session_started keeps 'cmdheight' at 0 while ngam draws the command
// line and messages. nvim would keep that row empty, so it shows as a
// blank line under the status line. A config sets it after ngam attaches
// (nvim --embed runs the config then), so it is set back each time.
ext_session_started :: proc(app: ^App) {
	exec_lua(app, CMDHEIGHT_LUA, {app.ext.on})
}

@(private = "file")
CMDHEIGHT_LUA :: `
local on = ...
local g = vim.api.nvim_create_augroup('ngam_cmdheight', {clear = true})
if not on then return end
local function zero()
  if vim.o.cmdheight ~= 0 then vim.o.cmdheight = 0 end
end
vim.api.nvim_create_autocmd({'VimEnter', 'SessionLoadPost', 'TabEnter'}, {group = g, callback = zero})
vim.api.nvim_create_autocmd('OptionSet', {group = g, pattern = 'cmdheight', callback = function() vim.schedule(zero) end})
zero()
`

// ext_mouse_down handles a press on a native element. It returns true when
// the press was taken.
ext_mouse_down :: proc(app: ^App, button: u8) -> bool {
	e := &app.ext
	if !e.on {
		return false
	}
	m := app.mouse
	inside :: proc(r: sdl.Rect, p: [2]i32) -> bool {
		return r.w > 0 && p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
	}
	if e.dialog.kind != "" {
		for b in e.buttons {
			if inside(b.rect, m) {
				nvim_input(app, b.key)
			}
		}
		return true // the dialog takes every click
	}
	if e.panel.open {
		if !inside(e.panel.rect, m) {
			e.panel.open = false // a click outside closes it
		}
		app.need_draw = true
		return true
	}
	for t in e.tabs {
		if inside(t.close, m) {
			exec_lua(app, "local n = vim.api.nvim_tabpage_get_number(...)\nvim.cmd('tabclose ' .. n)", {t.handle})
			return true
		}
		if inside(t.rect, m) {
			exec_lua(app, "vim.api.nvim_set_current_tabpage(...)", {t.handle})
			return true
		}
	}
	if h := ext_tabline_h(app); h > 0 && m.y >= editbar_h(app) && m.y < editbar_h(app) + h {
		return true // the strip's empty end
	}
	if inside(e.pum.rect, m) && e.pum.shown {
		i := e.pum.top + int((m.y - e.pum.rect.y) / app.font.cell_h)
		if i >= 0 && i < len(e.pum.items) {
			// Select and insert the item, and leave the menu open.
			exec_lua(app, "vim.api.nvim_select_popupmenu_item(..., true, false, {})", {i64(i)})
		}
		return true
	}
	#reverse for &t, i in e.toasts {
		if inside(t.rect, m) {
			message_free(&t)
			ordered_remove(&e.toasts, i)
			app.need_draw = true
			return true
		}
	}
	if inside(e.cmd_rect, m) {
		return true
	}
	if status_y := editor_frame_rect(app); m.y >= status_y.y + status_y.h {
		return true // the status strip
	}
	return false
}

// ext_wheel scrolls the panel when the mouse is over it.
ext_wheel :: proc(app: ^App, dy: f32) -> bool {
	p := &app.ext.panel
	if !p.open {
		return false
	}
	p.scroll -= int(dy * 3)
	app.need_draw = true
	return true
}

// ext_key_down handles keys while the output panel is open: Escape, q
// and Return close it, j, k and the arrows scroll it. Any other key closes
// it and goes on to nvim. It returns true when the key was taken.
ext_key_down :: proc(app: ^App, ev: sdl.KeyboardEvent) -> bool {
	p := &app.ext.panel
	if !app.ext.on || !p.open {
		return false
	}
	mods := ev.mod & (sdl.KMOD_CTRL | sdl.KMOD_ALT | sdl.KMOD_GUI)
	take := true
	switch {
	case mods != {}:
		take = false
	case ev.key == sdl.K_ESCAPE || ev.key == sdl.K_Q || ev.key == sdl.K_RETURN || ev.key == sdl.K_SPACE:
		p.open = false
	case ev.key == sdl.K_J || ev.key == sdl.K_DOWN:
		p.scroll += 1
	case ev.key == sdl.K_K || ev.key == sdl.K_UP:
		p.scroll -= 1
	case ev.key == sdl.K_PAGEDOWN || ev.key == sdl.K_D:
		p.scroll += max(p.rows - 1, 1)
	case ev.key == sdl.K_PAGEUP || ev.key == sdl.K_U:
		p.scroll -= max(p.rows - 1, 1)
	case ev.key == sdl.K_G:
		p.scroll = ev.mod & sdl.KMOD_SHIFT != {} ? 1 << 30 : 0
	case ev.key == sdl.K_LSHIFT || ev.key == sdl.K_RSHIFT:
	// Shift alone, on its way to G.
	case:
		take = false
	}
	if !take {
		p.open = false
	}
	app.need_draw = true
	return take
}
