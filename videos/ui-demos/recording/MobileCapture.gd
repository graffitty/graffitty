extends SceneTree
## Run the production mobile client with the same touch profile as the main demo.
func _initialize() -> void:
	TranslationServer.set_locale("en")
	OS.set_environment("GRAFFITTY_TOUCH_CONTROLS", "1")
	root.size = Vector2i(1200,1200)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 1.6
	root.unfocusable = true
	root.add_child.call_deferred(preload("res://tests/client_scenarios/android_ui.gd").PointerGuard.new())
	var scenario := preload("AdaptiveZoom.gd").new()
	# Movie Maker can announce low disk space at startup. Dismiss only this
	# advisory before filming; encoding and every other diagnostic remain checked.
	node_added.connect(func(node):
		if node.has_signal("diagnostics_shown"):
			node.diagnostics_shown.connect(func(entries):
				if entries.size() != 1: return
				var entry: Dictionary = entries[0]
				if entry.warning and str(entry.file).ends_with("movie_writer.cpp") and str(entry.message).begins_with("Current available space on disk is low"):
					scenario.diagnostic_guard.allow(entry.message, entry.file, entry.line, true)
					node.dismiss_messages.call_deferred()))
	scenario.desktop_capture = true
	scenario.settings = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("GRAFFITTY_SERVER_DESCRIPTOR")))
	scenario.output = OS.get_environment("TAKE").path_join("camera.json")
	scenario.completed.connect(func(code): quit(code))
	root.add_child.call_deferred(scenario)
