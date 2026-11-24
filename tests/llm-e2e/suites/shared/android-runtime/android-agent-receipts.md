# Shared agent read receipts

Run with `tests/android/test_android_runtime.py android-agent-receipts` and a
selected physical Android device. The runner uses the separately labelled
**Graffitty E2E** APK and a disposable server. It verifies the APK's package ID
and launcher name before installation; it does not change the installed
Graffitty app or connect to user sessions.

1. Register a live fixture Pi process through `gft rpc agent.event`, then focus a
   different terminal on Android. Open the production Agents panel.
2. Attach an independent desktop Godot process. Complete the agent's turn and
   verify both clients show the same unread event and completed row. Check the
   tab marker in the host displaying the agent’s server session on each client.
3. Tap the rendered Android agent row using native ADB input. Verify the pane
   opens, the server confirms that exact event as seen, and both clients clear
   their completed row and tab marker.
4. Look away on Android and complete another turn. Verify a new unread event on
   both clients. View the agent on the desktop; Android must clear its markers
   while preserving focus on the other terminal.
5. Attach a fresh desktop process; it must immediately see the server's read
   state without recreating an unread marker.

Retain screenshots, Android logcat, desktop logs, phase snapshots in
`receipts.json`, and the original server PTY survival check. Desktop clients are
headless with an explicit viewed-host fixture; Android uses actual window focus
and a native ADB tap. This establishes automated physical-device behavior, not
human touch acceptance, rotation coverage, or transport-loss/stale-receipt
coverage (the latter has separate desktop integration tests).
