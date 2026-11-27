extends "res://tests/unit/test_case.gd"

class Insets extends "res://scenes/input/AndroidKeyboardInsets.gd":
	var hides := 0
	var height := 700
	var changes: Array[int] = []
	func _hide_keyboard() -> void: hides += 1
	func keyboard_height() -> int: return height

class Polled extends Insets:
	func _height_changed(value: int) -> void: changes.append(value)

## iOS has no height signal; each frame's poll reports a change once.
func test_ios_poll_reports_each_height_change_once() -> void:
	var insets := Polled.new()
	insets.height = 0
	insets._process(0.0)
	expect(insets.changes.is_empty(), "No report while the height stays at zero")
	insets.height = 320
	insets._process(0.0)
	insets._process(0.0)
	insets.height = 0
	insets._process(0.0)
	expect(insets.changes == [320, 0], "Shown and hidden are each reported once: %s" % [insets.changes])
	insets.free()

## A hardware keyboard leaves only iPadOS's shortcut bar: keep the terminal
## above it without the touch key row. Android never has that bar.
func test_ios_shortcut_bar_hides_only_the_key_row() -> void:
	var insets := Insets.new()
	insets.ios = true
	expect(insets.shortcut_bar_only(55.0) and insets.shortcut_bar_only(insets.SHORTCUT_BAR_MAX), "A shortcut-bar height hides the key row")
	expect(not insets.shortcut_bar_only(320.0), "The on-screen keyboard keeps the key row")
	insets.ios = false
	expect(not insets.shortcut_bar_only(55.0), "Android keeps the key row at any height")
	insets.free()

func test_background_zero_height_does_not_cancel_resume_dismissal() -> void:
	var insets := Insets.new()
	insets._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	insets.height = 0
	insets._height_changed(0)
	expect(insets.recovering, "Another activity hiding its keyboard does not release our editor")
	insets._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	insets._height_changed(0)
	expect(insets.recovering and insets.hides == 0, "Recovery still waits for native window focus")
	insets._notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	expect(insets.hides == 1, "Returning closes the old editor even before Android restores its height")
	insets.free()

func test_explicit_dismissal_releases_stale_keyboard_space_without_a_pause() -> void:
	var insets := Insets.new()
	expect(insets.keyboard_visible(), "Initially the keyboard occupies the lower screen")
	insets.prepare_keyboard_close()
	expect(not insets.keyboard_visible(), "Dismissed keyboard no longer traps the toggle in hide mode")
	for step in range(10):
		insets._retry_hide()
		expect(insets._recovered_inset(700) == 0.0, "A delayed height cannot squeeze the workspace or displace its controls")
	expect(insets.hides == 3, "Native dismissal retries stay bounded")
	insets.prepare_keyboard_open()
	expect(insets.keyboard_visible() and insets._recovered_inset(500) == 500, "Intentional reopen immediately accepts the new keyboard area")
	insets.free()

func test_resume_waits_for_window_focus_in_either_order() -> void:
	for focus_first in [false, true]:
		var insets := Insets.new()
		insets._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
		expect(insets._recovered_inset(700) == 0.0 and insets.hides == 0, "Background height is discarded without touching inactive editor")
		var first := Node.NOTIFICATION_APPLICATION_FOCUS_IN if focus_first else Node.NOTIFICATION_APPLICATION_RESUMED
		var second := Node.NOTIFICATION_APPLICATION_RESUMED if focus_first else Node.NOTIFICATION_APPLICATION_FOCUS_IN
		insets._notification(first)
		insets._recovered_inset(700)
		expect(insets.hides == 0, "Resume and focus are both required")
		insets._notification(second)
		expect(insets._recovered_inset(700) == 0.0 and insets.hides == 1, "Focused recovery dismisses stale keyboard and inset")
		for step in range(10): insets._retry_hide()
		expect(insets.hides == 3 and not insets.keyboard_visible(), "Retries are bounded and stale height cannot trap the toggle")
		insets.prepare_keyboard_open()
		expect(insets._recovered_inset(500) == 500 and insets.hides == 3, "Explicit reopen cancels recovery and respects new keyboard height")
		insets.free()

func test_zero_height_finishes_recovery() -> void:
	var insets := Insets.new()
	insets._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	insets._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	insets._notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	insets._recovered_inset(0)
	expect(not insets.recovering, "Confirmed dismissal ends recovery")
	expect(insets._recovered_inset(600) == 600 and insets.hides == 1, "A form opening its keyboard later is not hidden")
	insets.free()
