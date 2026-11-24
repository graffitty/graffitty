# Agents and attention sounds

Open **View (<img class="menu-icon" src="../images/menu/eye.svg" alt="" width="18" height="18">) → Agents**, or run `:Agents` from the prefix command line.

See Claude, Codex, Pi and OpenCode across connected servers and sessions.

## Priority and connected panes

| Group | Meaning |
| --- | --- |
| Pinned | Agents you want to keep at the top |
| Needs you | Waiting for input or reporting an error |
| Done | Completed work you have not viewed |
| Working | Running a turn |
| Idle | Ready for more work |

- The highlight follows the selected agent pane in each window. Clicking the Agents panel leaves that row highlighted, including when the selected agent is a child. Switching servers in that window moves the highlight to the new server’s selected agent.
- Hover an agent to pin it.
- Connected browsers, terminals and agents stay grouped when you switch tabs or sessions. Select a child row to open its session and focus that pane. A leader with unknown or offline status stays at the top of its group while any connected agent has a listed status.
- An idle leader appears under **Working** while a descendant is working, or **Needs you** if a descendant needs input. This also applies when the tree is folded. Each row keeps its own status icon. A finished child keeps its blue dot without moving the tree to **Done**.
- `NextAgent` and `PreviousAgent` step through connected agents in panel order.
- Drag the panel title to move or dock it.

The elapsed time starts at the server-recorded status change, including time
while this client was disconnected. Viewing a finished agent changes Done to Idle
without resetting its age. If no transition time is known, the age stays blank.
Read receipts are shared by the session server: viewing a completion on your
phone also clears its unread dot and tab badge on your other connected clients.
Each receipt identifies the event you viewed, so a delayed acknowledgement
cannot clear a newer completion. Receipts retry after a connection interruption.
Codex discovery reads the latest complete lifecycle record even when a long turn
has pushed it outside the transcript preview. Its original timestamp survives a
server restart; partial trailing records do not change the displayed state.

## Client-only sound configuration

In `client.toml`:

```toml
[sounds]
enabled = true
blocked = "" # Needs input or reports an error.
done = ""    # Finished outside the focused view.
```

- Empty paths use the bundled sound.
- Custom sounds: Ogg Vorbis, MP3 or WAV, up to ten seconds.
- Relative paths start in this client's configuration directory.
- Missing or unsupported files fall back to the bundled sound.
- Restart the client after changing the file.

**View (<img class="menu-icon" src="../images/menu/eye.svg" alt="" width="18" height="18">) → Agent sounds** toggles playback until restart. Android uses media volume.
