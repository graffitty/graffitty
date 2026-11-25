extends SceneTree
var errors := preload("res://tests/run.gd").ErrorCapture.new()
func _initialize() -> void:
	OS.add_logger(errors)
	run.call_deferred()
func run() -> void:
	var original := Node.get_orphan_node_ids()
	var case := preload("res://tests/unit/terminal_presentation_test.gd").new()
	case.check_flat_fly_away_retains_departing_projection_and_flight_axes()
	for id in Node.get_orphan_node_ids():
		if id in original or not is_instance_id_valid(id): continue
		var node := instance_from_id(id) as Node
		if node != null and node.get_parent() == null: node.free()
	case.failures.append_array(errors.take())
	for failure in case.failures: print("FAIL ", failure)
	print("FLAT_SESSION_PROJECTION failures=", case.failures.size())
	quit(0 if case.failures.is_empty() else 1)
