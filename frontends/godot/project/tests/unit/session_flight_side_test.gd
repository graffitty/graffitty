extends "res://tests/unit/test_case.gd"
## Session switches fly right to an earlier session and left to a later one.
const Connection := preload("res://scenes/remote/RemoteConnection.gd")
const Pieces := preload("res://scenes/CellShatter.gd")

func _switch(connection: Node, target: String) -> float:
	connection._receive({"type": "session_switched", "workspace": target})
	return connection.session_switch_side

func test_side_follows_server_session_order() -> void:
	var connection := Connection.new()
	connection.connected = true
	connection.available_sessions = [{"id": "$2"}, {"id": "$0"}, {"id": "$5"}]
	connection.workspace = "$0"
	expect(_switch(connection, "$5") == 1.0, "A later session flies left")
	expect(_switch(connection, "$0") == -1.0, "An earlier session flies right")
	expect(_switch(connection, "$2") == -1.0, "Server order decides, not the ID text")
	expect(_switch(connection, "$9") == 1.0, "An unlisted session keeps the default left flight")
	connection.free()

func test_first_release_comes_from_the_half_the_wind_leaves() -> void:
	var positions := PackedFloat32Array()
	for i in 100: positions.append(float(i))
	var left := Pieces.release_ranks(positions, 7)
	var right := Pieces.release_ranks(positions, 7, -1.0)
	var first_left := 0
	var first_right := 0
	for i in positions.size():
		if left[i] < 0.2:
			first_left += 1
			expect(positions[i] >= 49.5, "A leftward flight releases the right half first")
		if right[i] < 0.2:
			first_right += 1
			expect(positions[i] <= 49.5, "A rightward flight releases the left half first")
	expect(first_left == 20 and first_right == 20, "Both sides keep the 20% first cohort")
