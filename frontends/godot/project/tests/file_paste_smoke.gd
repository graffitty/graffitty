extends SceneTree
var failures := 0
func _initialize() -> void:
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func run() -> void:
	var terminal: Control = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.size = Vector2(640, 400)
	root.add_child(terminal)
	await process_frame
	terminal.set_attachment_context(true, false)
	var paths := PackedStringArray(["/fixture/한글 O'Brien.png", "/fixture/a directory"])
	var start := Time.get_ticks_usec()
	terminal.paste_files(paths)
	var bytes: PackedByteArray = terminal.remote_take_input()
	print("Local path queue latency: ", Time.get_ticks_usec() - start, " us")
	check(bytes.get_string_from_utf8() == "'/fixture/한글 O'\\''Brien.png' '/fixture/a directory' ", "Local files and directories produce one complete path paste")
	check(terminal.remote_take_attachment().is_empty(), "Local paths never read or stage the source files")
	check(terminal.remote_take_input().is_empty(), "No paced per-character remainder")
	terminal.set_attachment_context(true, true)
	terminal.paste_files(paths)
	check(terminal.remote_take_input().get_string_from_utf8() == "'/fixture/한글 O''Brien.png' '/fixture/a directory' ", "Destination PowerShell quoting")
	terminal.set_attachment_context(false, false)
	terminal.paste_files(paths)
	check(terminal.remote_take_input().is_empty(), "Remote drop never pastes the local path")
	var attachment: Dictionary = terminal.remote_take_attachment()
	check(attachment.paths == paths, "All files reach the remote batch in order")
	terminal.send_text("AFTER_FILES")
	check(terminal.remote_take_input().is_empty(), "Typing waits behind the entire batch")
	terminal.file_paste_finished(true)
	check(terminal.remote_take_input().get_string_from_utf8() == "AFTER_FILES", "Completion releases later typing once")
	terminal.paste_files(paths)
	terminal.remote_take_attachment()
	terminal.send_text("DO_NOT_SUBMIT")
	terminal.file_paste_finished(false)
	check(terminal.remote_take_input().is_empty(), "A failed batch discards queued submission")
	terminal.set_attachment_context(true, false)
	terminal.paste_files(PackedStringArray(["/fixture/unsafe\nfile"]))
	check(terminal.remote_take_input().is_empty() and terminal.remote_take_attachment().has("error"), "Unsafe file names cannot inject Enter")
	terminal.file_paste_finished(false)
	terminal.queue_free()
	await process_frame
	quit(1 if failures else 0)
