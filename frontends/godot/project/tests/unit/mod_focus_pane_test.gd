extends "res://tests/unit/test_case.gd"

class Agents extends Node:
	var focused: Array = []
	func focus_key(host_id: int, key: String) -> void: focused.append([host_id, key])

class Application extends Node:
	var agents := Agents.new()
	var hosts: Array = []


## Agents panel sub-rows and the resource monitor click with FocusPane. It must
## pan like prefix navigation, not only move keyboard focus to an offscreen pane.
func test_focus_pane_reveals_through_agent_selection() -> void:
	var app := Application.new()
	var service := preload("res://scenes/mods/ModService.gd").new()
	service.application = app
	service.run(null, "FocusPane", {"host": 42, "key": "t7"})
	expect(app.agents.focused == [[42, "t7"]], "FocusPane uses the same reveal as agent selection: %s" % [app.agents.focused])
	service.free()
	app.agents.free()
	app.free()
