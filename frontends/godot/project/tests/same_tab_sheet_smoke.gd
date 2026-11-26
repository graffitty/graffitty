extends "../../../../tests/llm-e2e/replay/replay.gd"

## Isolated server required. Selecting a pane of the tab on screen never plays
## a tab transition, even after the sheet stayed bound to a pane that is no
## longer the tab's first terminal.

func play() -> void:
	await camera_at_rest()
	var t1: String = host.pane_focus
	host.create_terminal_window(t1)
	await hold(1.0)
	var t2: String = host.pane_focus
	host.create_terminal_window(t2)
	await hold(1.0)
	var t3: String = host.pane_focus
	var world: Node = host.world
	host.focus_pane(t3)
	await hold(.5)
	# Closing the first pane while another is selected keeps the sheet on t3;
	# the tab's first terminal, which carries its sheet, is now t2.
	host.session_backend.close_pane(host, PaneAddress.id(t1))
	await hold(1.5)
	var first: int = world._first_terminal(host.workspace_layout.tab(host.workspace_layout.active))
	check(first == PaneAddress.id(t2) and int(world.surfaces[world.active].session_id) == PaneAddress.id(t3),
		"Fixture leaves the sheet on a pane other than the tab's first terminal")
	host.focus_pane(t2)
	await process_frame
	check(int(world.surfaces[world.active].session_id) == PaneAddress.id(t2), "The sheet rebinds to the tab's first terminal")
	check(world.tab_fx_t < 0.0, "Selecting a pane of the same tab plays no tab transition")
	host.focus_pane(t3)
	await process_frame
	check(world.tab_fx_t < 0.0, "Selecting another pane of that tab plays none either")
