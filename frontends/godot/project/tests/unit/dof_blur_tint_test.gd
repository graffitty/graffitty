extends "res://tests/unit/test_case.gd"
const Effects := preload("res://scenes/Effects.gd")


func test_scenery_lens_uses_circular_bokeh() -> void:
	expect(ProjectSettings.get_setting("rendering/camera/depth_of_field/depth_of_field_bokeh_shape") == RenderingServer.DOF_BOKEH_CIRCLE,
		"The native scenery lens samples a circular aperture")


func test_presets_use_camera_tint_without_changing_mild_strength() -> void:
	for path in ["flat", "theme-ice", "theme-ember", "theme-paper"]:
		var config := Effects.new()
		expect(config.load_config("res://presets/%s.conf" % path), "Preset loads")
		expect(config.warnings.is_empty(), "Preset has no unknown options")
		expect(not config.scene.lighting.has("shadow_color"), "Public color lives with DOF settings")
		if path == "flat":
			expect(config.scene.camera.dof_blur_tint == "#6f5fa8", "Mild retains its purple tint")
			expect(config.scene.camera.dof_blur_tint_strength == 0.85, "Mild retains its stronger tint")


func test_removed_config_names_are_reported() -> void:
	var config := Effects.new()
	config.set_option("scene.lighting", "shadow_color", "#112233")
	config.set_option("scene.camera", "dof_blur_radius", 16)
	expect(config.warnings.size() == 2, "Removed names are unknown options")


func test_blur_controls_keep_color_when_disabled() -> void:
	var dialog := preload("res://scenes/TerminalEffectsSettings.gd").new()
	var tint := Color("#6684c7")
	dialog._add_blur_controls(false, tint)
	expect(dialog.blur_color.disabled and dialog.blur_color.color == tint, "Opening with blur off keeps the color visible and disabled")
	dialog.depth_blur.button_pressed = true
	expect(not dialog.blur_color.disabled, "Enabling blur enables its color")
	dialog.blur_color.color = Color.CORAL
	dialog.depth_blur.button_pressed = false
	dialog.depth_blur.button_pressed = true
	expect(dialog.blur_color.color == Color.CORAL, "Toggling blur preserves the draft color")
	for child in [dialog.grid, dialog.zoom_mode, dialog.trail, dialog.particles, dialog.status]:
		child.free()
	dialog.free()
