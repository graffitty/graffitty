# Saved servers

Manage connections after [setting up remote access](index.md).

On iPhone and iPad, tap **‹** immediately to the left of the tab strip’s **⌄** menu to return to the server list. Your sessions keep running.

## Remember an SSH host

Connect once with `gft remote connect user@computer`. In **Sessions → Servers…**, choose **Save SSH host** on its card.

The saved entry identifies the SSH destination, not the temporary tunnel port. It remembers your selected session. Clicking it opens a fresh tunnel; key-based SSH connections open in the current app. If SSH needs a password or host-key confirmation, an interactive terminal opens instead.

Local sessions stay under **This Computer**. Remote sessions appear under their server name, with an `ssh://` address on SSH server cards. Disconnect keeps the profile and live programs. Remove forgets the profile without stopping remote work.

## Stop remote work deliberately

Closing a client closes its tunnel and leaves remote programs running. To end one session, use **Kill Session**. A private server exits after its last session ends; a server with explicitly enabled remote access stays available for later connections.

On the remote computer, `gft server stop` stops an empty server. It refuses if sessions are still running. Use `gft server stop --kill-sessions` only when you intend to end all of that server's programs. An SSH-started private server that never receives a session exits after five idle minutes.

## Several computers at once

Use **Sessions (<img class="menu-icon" src="../images/menu/panels-top-left.svg" alt="" width="18" height="18">) → Servers…** to manage saved computers.

| Action | Result |
| --- | --- |
| Open in new window | Keep it beside the current workspace |
| Return to This Computer | Return to local programs without restarting them |
| Disconnect | Keep the saved server and its running sessions |
| Remove | Forget the bookmark and saved password; does not stop the server |

- Switching servers restores each view's selected session, tab, pane, and camera.
- Temporary network loss leaves the workspace visible with offline status while retrying.
- Input typed offline is discarded, not replayed later.
- Android can reconnect its last server when remembered credentials are available.
- **Detach** keeps programs running. **Kill Session** ends the selected session and its programs.

### Target a remote pane from the CLI

Saved servers have a stable CLI alias. Change it in **Server alias (CLI, optional)**.
With alias `build`:

```sh
gft pane list -t build/
gft terminal type -t 'build/t12' --text 'hello'
```

Use the pane IDs returned by `list-panes`. The target needs no network port.
