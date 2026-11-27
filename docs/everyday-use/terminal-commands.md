# Read and send terminal text

Any terminal on this server can be read or typed into, in any session, like
`tmux send-keys`. Commands leave frontend focus unchanged.

`gft pane list` lists every session's panes; `-t work` lists only session `work`.

| Target | Pane |
| --- | --- |
| `t3` | Pane `t3`, in any session |
| `work:1.2` | Tab 1, pane 2 of session `work` (name or `$N`) |
| `:1.2` | Tab 1, pane 2 of your own session |

To message an agent with permissions and turn tracking, use a
[graph wire](../agents/connect-agents.md) instead.

## Capture and send

Save the current screen or include scrollback:

```sh
gft terminal get-text
gft terminal get-text --scrollback > terminal.txt
gft terminal get-text -t t3 --json
```

Capture leaves focus and scroll position unchanged. Full-screen programs expose
their current screen, without the shell's earlier scrollback.

Paste into another pane, then send a key:

```sh
gft terminal send-text -t t3 --text 'hello'
gft terminal press -t t3 Enter
```

Replace `t3` with an ID from `gft pane list`. Pasting does not press Enter.
Keys can include modifiers, such as `Ctrl+h`; add `--no-effects` to `press`
to suppress typing effects.

## Control a remote terminal

Connect using an SSH host from your configuration and choose a CLI alias:

```sh
gft remote connect build-server --alias build
gft pane list -t build/
```

Use a qualified target from the listing for input or capture:

```sh
gft terminal send-text -t 'build/t12' --text 'hello'
gft terminal press -t 'build/t12' Enter
gft terminal get-text -t 'build/t12'
```

The connection must stay open. Add `--no-gui` to connect without opening a window;
Telegram verification requires the GUI. See [remote access](../remote-access/index.md).

## Upload a file

`gft terminal put --target t3 image.png` uploads a file to that terminal's
server. Add `--paste` to paste the completed path without pressing Enter.
With an attached Graffitty window, its existing notification shows the filename,
received/total size, percentage and a progress bar. The same notification stays
visible throughout the transfer, then uses the normal eight-second lifetime
after completion. Failures are shown as errors; history retains one entry per
upload. A CLI-only upload still works without a frontend.

## Drop files and paste from the clipboard

Local file drops and copied files paste their original paths in one operation;
file contents are not read or copied. Remote drops and copied files upload
sequentially, then paste the successful destination paths together with a
trailing space. Files that cannot be read or exceed 32 MiB fail without blocking
other files. Folders can be pasted locally; remote folder upload is unsupported.

Text paste stays a normal bracketed paste. On a local desktop, an image-only
clipboard sends Ctrl+V so the foreground program can read the clipboard.
Remote clipboard images and mobile native image content are uploaded first.
A macOS screenshot thumbnail is staged even locally because its source is
short-lived and may be inaccessible to the terminal process.

Typing during upload waits behind the completed path paste; a failed batch
discards queued input so Enter cannot submit a draft with missing attachments.
An ordinary `ssh` command inside a local terminal does not change the app's
local/remote file routing.

Text is pasted in one batch without a typing delay. With bracketed paste enabled,
newlines stay inside the paste; add `--enter` to submit it. An omitted target means
the calling terminal. Neovim explicitly uses `connected` to send to its selected pane.
`send-text` uses the same `pane.send` RPC as the Neovim plugin.

For recordings only, use `gft internal terminal demo-type --text 'hello' --interval-ms 60`.
The interval is required. Demo typing emits individual keys and typing effects;
it is not a text-paste API. Use `gft terminal press Escape` for actual control keys.
