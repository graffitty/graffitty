# Resource Monitor

Open **View → Resource Monitor** to compare panes. Use **View → Pane Status**
for only the focused pane. Click a pane row to focus it.

## Arrange the list

| Task | Control |
| --- | --- |
| Sort | Click a column heading; unknown values sort last |
| Reorder columns | Drag a heading; hold at an edge to scroll |
| Resize a column | Drag its right edge |
| Filter | Choose Server and Session values |

Changing the server filter clears the session filter. Column and filter choices
are saved across windows.

## Fold connected panes

The **Connections** column groups related panes within each server/session.
Graph links, spawned panes, filetrees, and browsers establish these groups.
Muted graph links still count as relationships.

Click a group's unnamed summary row to fold or expand it. The row shows a pane
count rather than a parent agent. Its PID and pane key stay blank.
Sorting keeps each group together; individual rows still focus their panes.

## Read totals

- Each pane counts once, even when visible in several windows.
- Group CPU, RAM, and process counts sum their members. A missing measurement
  makes that group metric unknown.
- Footer totals cover the filtered rows; folding does not change them.
- Footer CPU averages the server totals, because 100% represents all CPUs on
  one server. RAM and process counts add together.

Unknown or stale measurements are not measured zero usage.

## Linux setup

CPU and RAM accounting needs a delegated cgroup v2 with CPU and memory
controllers enabled. A plain SSH shell often lacks this setup. Terminals
still work when accounting is unavailable.

For a **new server**, run the following from a systemd user session. It moves
the launcher into its own child group before enabling controllers for the
terminal groups:

```sh
systemd-run --user --scope -p Delegate=yes sh -eu <<'SH'
parent="/sys/fs/cgroup$(sed -n "s/^0:://p" /proc/self/cgroup)"
mkdir "$parent/launcher"
printf "%s\n" "$$" > "$parent/launcher/cgroup.procs"
printf "+cpu +memory\n" > "$parent/cgroup.subtree_control"
export GODOT_RESOURCE_CGROUP_PARENT="$parent"
exec gft server --listen 127.0.0.1:0
SH
```

Keep an existing server running until its work is finished; this command does
not move live terminals into new accounting groups. `gft server restart`
preserves terminals, but resource monitoring of adopted Linux terminals is
currently unavailable after restart.

If `systemd-run --user` cannot reach the user bus, the SSH login needs a
working systemd user session. If writing `cgroup.subtree_control` fails, check
that `cgroup.controllers` in the delegated parent lists `cpu` and `memory`;
the host administrator must make missing controllers available above it.

`memory.peak` is optional. Kernels without it still report current memory,
CPU, and the peak observed by Graffitty's sampler.

See [systemd's delegation rules](https://systemd.io/CGROUP_DELEGATION/) for
controller availability and the requirement that an inner cgroup be empty.
