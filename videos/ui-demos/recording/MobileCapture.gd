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
	scenario.desktop_capture = true
	scenario.settings = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("GRAFFITTY_SERVER_DESCRIPTOR")))
	scenario.output = OS.get_environment("TAKE").path_join("camera.json")
	scenario.completed.connect(func(code): quit(code))
	root.add_child.call_deferred(scenario)
