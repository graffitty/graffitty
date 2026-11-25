# Switch between live sessions

Use a private server and two named live sessions. Record the original terminal
IDs, PIDs, text, focus, camera and tab membership. Split a pane and open a second
native window, then create another session and switch back through the native
session picker or `$session` completion. The original shells, environment,
scrollback and each window's presentation must survive.

Give the two sessions different manual pans and zoom levels. Switch immediately
after navigating, before any autosave delay, through the CLI, Sessions panel and
`$session` picker. Each return must restore its own viewport without refitting
Main View or inheriting the other session's camera. Repeat with several tabs and
with a second client displaying a different view of the same session. A session
left in Main View stays fitted; a newly created session starts fitted. Failed
switches leave the current viewport intact. Repeat in Android's managed workspace
and record simulated and physical-device results separately.

On a second server, open session P. From the Sessions panel, return to A on
the first server, then select B on that same server. The row should highlight
immediately. The outgoing transition must show A throughout departure, with
no frame of P. Repeat for a previously visited B and a first visit. Fast
switches stay quiet. Hold a switch past 400 ms to see its opening status.

Run `gft session attach -t <name>` in the original real PTY. It must redirect the client
that supplied that input. Keep another client attached throughout and verify
that it remains authorized to view its original session's terminals.

Attempt an unknown session and a duplicate new-session name. Display the owner
error and keep the current terminal usable. Create a detached session and
verify that it appears in the live menu without switching the current view.
Keep the owner and client binaries frozen and retain screenshots and transcripts.

Repeat with **Fly away** and **Fly away and in** in Flat 2D, Flat 3D, and an
authored scenery world. In both Flat renderers, switch from Main View to a
zoomed-out session and back: outgoing letters must keep the departing screen's
scale while flying, without first shrinking or enlarging to the incoming view.
Incoming pieces use their own session's framing. Repeat during an unfinished
flight; retiring pieces must remain independent of the new camera. Authored
worlds such as Bistro and Edinburgh Castle keep their camera-driven travel.
Camera travel must end at the restored session view. After both sessions have
been running for two seconds, CPU and RAM must appear with the destination
panes, including a session never viewed before. Inactive terminal sessions keep
sampling; switching must not reset their CPU baseline or wait for a periodic
resource update. Check that displayed PIDs and metrics belong to the destination.
