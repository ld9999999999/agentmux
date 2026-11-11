# GUI protocol (`agentmux serve`)

`agentmux serve <session>` runs a session for a GUI over its stdin and
stdout. The usual way to reach a remote session is

```
ssh host agentmux serve <session>
```

ssh handles authentication, and the GUI needs nothing on the remote side but
agentmux and nvim 0.11 or newer. Anything agentmux or nvim print goes to
stderr; stdout carries only the protocol.

To offer a list of sessions first, run `ssh host agentmux ls -json`. It
prints a JSON array with one object per session: `id`, `name`, `agent`,
`agent_state` (`running` or `stopped`), `editor` (where its editors are
open: `terminal`, `gui`, `terminal,gui`, or `""`), `stashed` (buffers with
unsaved changes), `created` and `cwd`. serve refuses a session whose
`editor` has `gui` in it: another GUI has it open. `agentmux new -detached [-agent A] [-name N] [-cwd D]` creates
one without opening it and prints its id. Pass `-cwd` as an absolute path:
over ssh, nothing expands `~` in it.

serve starts the session's nvim with `--embed`, in the plugin's GUI mode,
and connects to the session's agent. The GUI is an ordinary nvim UI client
for the editor and a terminal for the agent pane, which nvim does not show.
The holder still owns the agent, so the agent keeps running whatever
happens to the GUI or to nvim.

## Frames

Both directions use the same framing: 1 type byte, a 4 byte big-endian
payload length, then the payload. A payload is at most 4 MiB.

| Type | Direction | Payload |
|---|---|---|
| `C` | both | one JSON control message |
| `N` | both | bytes of nvim's msgpack-RPC stream |
| `A` | serve → GUI | the agent's terminal output |
| `A` | GUI → serve | keystrokes for the agent, as terminal input bytes |
| `R` | GUI → serve | the agent pane's size: rows u16, cols u16, big-endian |

`N` and `A` are byte streams split at arbitrary points: a msgpack message
can span frames, and one frame can carry several.

## Control messages

From serve:

| Message | Meaning |
|---|---|
| `{"type":"session","protocol":1,"id","name","agent","cwd"}` | A session's nvim has started. Start a new msgpack-RPC session on `N` (reset the decoder and request ids) and call `nvim_ui_attach`; nvim does not run its startup until a UI attaches. |
| `{"type":"agent","state":"attached"}` | The agent pane is connected. The agent's recent output (up to 1 MiB) is replayed first, then live output follows. |
| `{"type":"agent","state":"closed","reason":"…","exit":"…"}` | The agent pane is disconnected. `exit` is there when the agent itself exited; send `agent_attach` to start it again (it resumes where the agent supports that). |
| `{"type":"editor_exit"}` | nvim quit. Stop sending `N`. Either a `session` message follows (the user switched sessions from inside nvim) or `bye`. |
| `{"type":"error","message":"…"}` | Something failed. |
| `{"type":"bye"}` | serve is about to exit. |

From the GUI:

| Message | Meaning |
|---|---|
| `{"type":"agent_attach"}` | Connect the agent pane, starting (resuming) the agent if it is not running. |
| `{"type":"agent_detach"}` | Disconnect the agent pane. The agent keeps running. |

serve attaches the agent pane on its own when a session starts. Send `R`
once you know the pane's size, and again when it changes; serve remembers
the size and passes it on whenever the pane reattaches. The agent redraws
its whole screen for the first size it gets after an attach.

## Events from nvim

In GUI mode the plugin's agent-pane commands ask the GUI instead of opening
a window. They arrive as msgpack-RPC notifications on the UI's channel,
method `agentmux`, with the event name and, for some, a map of arguments:

| Event | Sent by |
|---|---|
| `focus_agent` | `:AgentFocus`, and `:AgentSend` without `!` |
| `toggle_agent` | `:AgentToggle` |
| `restart_agent` | `:AgentRestart` (send `agent_attach`) |
| `focus_editor` | `:AgentEditor` |
| `clipboard_set` `{register, text}` | a yank to `+` or `*` (see below) |
| `preview` `{path}` | `:AgentPreview [file]`: show the file (an absolute path on nvim's machine) in a browser |
| `ready` | nvim's startup is over and the session's tabs and folders are restored |

nvim answers requests while it starts, before it has loaded the plugin or
restored the session, and a session's first start can take seconds. Wait
for `ready` before calling the plugin, and ask again then for anything
that depends on nvim's current folder.

## Clipboard

In GUI mode the `+` and `*` registers are the clipboard of the machine the
GUI runs on, not of the one nvim runs on, so copy and paste work as in any
desktop app even over ssh.

1. Say the GUI answers clipboard requests: call
   `nvim_set_client_info(name, version, "ui", {agentmux_clipboard_get = {}}, {})`.
   Until then the plugin leaves nvim's clipboard alone, because a paste
   waits for the GUI's answer. (A clipboard set in the user's own config,
   `g:clipboard`, also wins.)
2. A yank to `+` or `*` sends `clipboard_set` with `register` (`"+"` or
   `"*"`) and `text`. Put the text on the host clipboard. Linewise text ends
   in a newline.
3. A paste from `+` or `*` sends the request `agentmux_clipboard_get` with
   `{register}`. Answer with the host clipboard's text as a string (or nil).
   Text ending in a newline pastes as whole lines.

nvim waits for that answer, so the GUI must keep answering requests from
nvim even while it is itself waiting on a response from nvim.

For the GUI's own shortcuts:

- **Paste into the editor**: send the host clipboard with
  `nvim_paste(text, true, -1)`, which does the right thing in every mode,
  the command line included.
- **Copy from the editor**: in visual mode, `nvim_input('"+y')`; the text
  comes back as `clipboard_set`.
- **Paste into the agent pane**: send the text on `A`, wrapped in
  `ESC[200~` … `ESC[201~` when the agent has turned on bracketed paste
  (mode 2004), as agents with a prompt editor do.
- **Copy from the agent pane**: copy the selection from the GUI's own
  terminal screen. An agent that copies by itself does so with OSC 52
  (`ESC]52;c;<base64>BEL`) in its output; put that on the host clipboard.

The GUI can also call the plugin with `nvim_exec_lua`. For a Git view,
`require('agentmux').git_diff(path, staged, old)` opens a file's changes
in a diff tab: `path` absolute, `staged` true for HEAD against the index
(false: the index against the working file), and `old` a renamed file's
path in HEAD, relative to the repository. `:AgentGitDiff[!]` does the same
from the command line.

For a session list, `require('agentmux').sessions()` returns what
`agentmux ls -json` prints on nvim's machine, as a string; it raises
agentmux's error when that fails. To switch sessions, run
`:AgentSession switch <id>` (or `new`) from a `vim.schedule` callback, so
that the request is answered before nvim quits for the handoff.

nvim's `g:agentmux_ui` is `"gui"` in this mode (`"terminal"` otherwise),
for config that should differ between the two.

## Ending

- Closing the connection (or stdin reaching EOF) ends the session's editor.
  serve has nvim save its snapshot first, so the next open, in a GUI or a
  terminal, restores the same files, cursors and unsaved changes.
- `:AgentSession detach` or `:qa` in nvim ends it from the other side:
  `editor_exit`, then `bye`.
- `:AgentSession switch`, `new` and `delete` hand off: `editor_exit`, then
  `session` for the next session on the same connection. When the next
  session is open in another GUI, serve sends `error` and opens the
  session it came from again.

A session can be open in terminals (`agentmux attach`) and in one GUI at
the same time, each with its own nvim: the GUI never joins the terminals'
nvim. A separate nvim lets the GUI use UI extensions such as
`ext_multigrid`, which nvim only enables when every attached UI supports
them, and keeps a small terminal from shrinking the GUI's grid. The two
share the agent. The editor opened second starts from the snapshot of the
one already open (layout, files and cursors, not its unsaved edits), and
serve has the terminals' nvim save first so that snapshot is current.
serve refuses a session open in another GUI. The GUI should call
`nvim_ui_set_focus` as its window gains and loses focus: the plugin then
marks its editor as the one the agent's requests and `agentmux goto` go
to.
