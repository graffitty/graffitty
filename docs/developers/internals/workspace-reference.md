# Workspace implementation

Use [Tabs and panes](../../everyday-use/workspaces.md) for controls or [Command line](../../everyday-use/cli.md)
for everyday commands. This page covers layout, identity, and state ownership.

## Window and pane geometry

Layout changes affect grids; view-only operations do not.

| Area | Rule |
| --- | --- |
| Display scaling | Logical UI size; backing-pixel terminal composition |
| Main area | New tabs tile within the last chosen Main View size |
| Stashes | Stay outside Main and do not participate in tiling |
| Chromium viewport | Follows its content area; native visible windows keep their own bounds |
| Terminal grid | Changes with content-area size or font settings |

A fitting window publishes its visible tab and focused pane to that session’s server.
Attachment, input and window resizing can fit that tab while all windows displaying
it share the same focused pane in Main. Inspecting a different pane or using
Overview keeps the tab’s current area. The server checks again when a queued edit arrives.

The `main_view` message carries the wire tab ID and pane address. An empty pane
marks an overview, and a null tab clears the presentation when the workspace
is hidden. Each topology tab lists the other viewers’ distinct pane addresses
in `other_main_panes`. Disconnecting or switching sessions clears the report.

Focusing, raising, moving, or renaming a pane does not resize its terminal.
Camera zoom changes the preview. World switches preserve shells, panes, and focus.

## Tiling and dragging

Splits preserve the source mode: a tiled pane splits its branch; a floating pane
gets a floating neighbor. A stashed pane's neighbor stays outside Main.
Divider proportions belong to the tab.

| Drag | Result |
| --- | --- |
| Shared border or gap | Resize adjacent tiled branches |
| Shared corner | Resize both dividers |
| Pane over a tiled edge | Preview a split; commit on release |
| Pane outside Main | Stash without closing |
| Pane over another tab | Hover to open it, then drop into its content |

Escape restores the pre-drag position. Cross-tab merges preview their layout.
Edge dragging scrolls without zooming.

### Floating physics

Floating physics moves contacted neighbors while keeping the newly placed pane
fixed. Main tiles stay fixed; stashes stay outside. Physics never resizes terminals.

## Client state and shared state

| State | Owner |
| --- | --- |
| Pane rectangles, split tree, names, connections | Shared session layout |
| Selected tab, focused pane, pan and zoom | Each device |
| Shells and browser processes | Session server |
| Rendering and camera effects | Client/world |

Reconnecting restores device preferences against the live layout. Closed targets
fall back to available panes. Hidden clients stop rendering while processes continue.

## World author opt-in

`TerminalSpace.tscn` supplies tiling, Main framing, stashes, and drag previews.
Basic kits do not install it automatically; a world opts in by including it.
Other worlds return `unsupported_layout`.

See [World UI API](../worlds-and-plugins/world-controls-api.md#optional-complete-terminal-space).
Configure spacing under [tiling defaults](../../customize/configuration-workspace.md#adjust-pane-spacing).

## Starting directories

Use the first available directory:

1. Explicit per-create directory, including checkpoint restore.
2. Source pane's current directory.
3. Original GUI launch directory.
4. Home directory.

`gft-gui --cwd /path/to/project` sets the launch directory. The server checks
its own filesystem; remote directories belong to the remote server.

## CLI pane and tab targets

| Target | Meaning |
| --- | --- |
| `t12` | Stable pane ID |
| `@7` | Stable tab ID |
| `:2.1` | First pane of the second tab in the caller's window |
| `@7.1` | First pane of stable tab `@7` |

On a fresh server, session IDs start at `$1` and pane IDs start at `t1`.
Stable tab and pane IDs survive moves. Positional targets start at 1 and change with layout.
Main panes come first in reading order; stashed and hidden panes follow in stored
order. Camera movement and physics do not renumber them.

`list-panes` returns stable and positional targets. Graph permissions and browser
ownership still apply after resolution. `GRAFFITTY_PANE` is the terminal address (for example, `t1`).
Chromium panes use an independent sequence starting at `c1`.
`GRAFFITTY_SURFACE_ID` is an internal integer. Agent-created terminals
receive the next terminal address and record their creator in `spawned_by`.
Letter suffixes such as `t1a` are reserved.

During the first month after 0.0.4 ships, the server adopts live terminals
from 0.0.3 holders. A running process keeps its PID, pane capability, and
inherited environment. Its old self-address works for pane-scoped calls.
New terminals receive typed addresses immediately.

## CLI

```sh
gft tiling layout h_tiles
gft tiling split vertical
gft tiling new-window
gft tiling focus up
gft tiling balance-sizes
gft tiling status
```

| Operation | Meaning |
| --- | --- |
| `layout` | Change the tab's root mode/orientation; multiple choices toggle |
| `split` | Choose the next insertion direction; does not create a pane |
| `focus`, `move` | Select a geometric tiled neighbor, or reinsert beside it |
| `join-with` | Group the focused tile and neighbor with opposite orientation |
| `balance-sizes` | Reset nested sibling proportions |

Mutations require an active tab and no drag in progress. Hidden and stashed panes
are excluded. Read-only `status` works for inactive tabs.
Directions return `no_neighbor` at an edge.

This AeroSpace-inspired subset has no move-out, accordion, or monitor commands.
Use `gft pane select` to include floating panes.


## Terminal PID lookup

```sh
gft pane pid
gft pane pid t12
gft pane pid :2.1 --details
gft pane pid @7 --details
```

`terminal.pid` returns `result.terminals` with addresses and `root_pid`.
Details add sampled process identities, memory, and monitor status.
Chromium targets are omitted or rejected.

This reuses monitor snapshots without starting monitoring. PIDs can exit or be
reused; revalidate before acting. Arguments, environments, and credentials are
not returned. See [Resource monitor API](resource-monitor-api.md).
