# Korean input

The macOS extension preserves committed Korean text and the command key that follows it.
The investigation below concerns Godot 4.7.2 and the project's native shim.
Linux, Windows and iOS have their own fixes, described after it.

## Current input path

1. Let AppKit process composition and commit text.
2. Record whether AppKit requested a command such as Enter or cursor movement.
3. Forward the physical command after the commit only when the input method left it unconsumed.

Candidate-confirmation Enter must stay with the input method. Replaying every key
that ends composition would submit Japanese input unexpectedly.

## Shell suggestions

Committed Unicode ends a Rust output batch. Later keys wait for terminal feedback
or a bounded 150 ms timeout. This gives zsh autosuggestions a chance to refresh;
feedback is not a formal shell acknowledgement.

## Verify the right boundary

`tests/platform/macos/test_macos_terminal_alt.py` checks native callback ordering.
A simulated callback pass does not establish live Korean IME acceptance.
The shared world kit also projects the cursor anchor for the native candidate window.

## Linux

Linux packages patch Godot 4.8 (`packaging/linux/godot-linux-ime.patch`):

- X11: the input context follows the window manager's focus changes, and
  commits made while the next syllable starts are kept.
- Wayland: text input is enabled again after each focus change, per window, and
  window focus follows the keyboard instead of the pointer.

Verified against xterm and a GTK terminal with ibus-hangul, libpinyin and Mozc
on GNOME (X11 and Wayland).

## Windows

Godot 4.7.2 drops each syllable the Microsoft IME commits when the next one
starts. Windows packages use Godot 4.8, which fixes that without a patch. The
IME also commits a syllable while Ctrl is held for the next chord, so the
encoder sends that text without Ctrl on Windows. See
[Windows testing](../build-and-run/windows-testing.md#known-runtime-issues).

## iOS and iPadOS

Godot diffs one hidden `UITextView` into Backspace and character keys, which
sends every jamo the Korean keyboard rewrites. While a terminal owns input,
`frontends/godot/extension/src/ios_terminal_ime.m` takes over that view:

- the Hangul syllable before the caret and marked text are drawn as preedit and
  sent once final;
- padding keeps Backspace working on empty input;
- hardware navigation keys and chords reach the terminal in order, except
  while text is marked, when they stay with the candidate list.

Software keyboards are verified in the iPad simulator. Hardware keyboards
without the on-screen keyboard still use Godot's path and do not compose.
Set `GRAFFITTY_IME_TRACE=1` to log each text change.

## Detailed evidence

[Korean input — source notes and results](korean-input-evidence.md).

The linked record retains the original measurements, failed attempts, commands,
and coverage limits. It is historical evidence, not a new test run.
