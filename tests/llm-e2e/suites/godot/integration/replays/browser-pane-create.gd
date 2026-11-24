extends "font-controls.gd"

# See shared/integration/workspace-terminal.md for the source-pane scenario.
func process_alive(pid: int) -> bool:
	if OS.get_name() == "Windows":
		var rows: Array = []
		var result := OS.execute("tasklist", ["/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"], rows)
		return result == 0 and ('"%d"' % pid) in "".join(rows)
	return OS.execute("/bin/kill", ["-0", str(pid)]) == 0


func play() -> void:
	var owner: int = host.active_session_id
	var owner_pid: int = host.active_terminal().get_shell_pid()
	var browser: Node = await host.create_chromium_session("about:blank")
	if not check(browser != null, "Owner allocates browser surface"): return
	if not await until(func(): return browser.pid > 0, "Browser process starts", 20): return
	var browser_id: int = browser.session_id
	var browser_pid: int = browser.pid
	var browser_key := PaneAddress.key(browser_id)
	var owner_tab: int = host.workspace_layout.containing(PaneAddress.key(owner))
	if not check(host.workspace_layout.containing(browser_key) == owner_tab, "Browser shares its owner's tab"): return

	host.create_session()
	if not await until(func(): return host.sessions.size() == 2 and host.active_session_id != owner and host.active_terminal() != null and host.active_terminal().get_shell_pid() > 0, "Unrelated terminal starts and receives focus"): return
	var unrelated: int = host.active_session_id
	var unrelated_pid: int = host.active_terminal().get_shell_pid()
	var unrelated_tab: int = host.workspace_layout.containing(PaneAddress.key(unrelated))
	if not check(unrelated_tab != owner_tab and host.workspace_layout.active == unrelated_tab, "Unrelated tab is selected"): return

	host.create_terminal_window(browser_key)
	if not await until(func(): return host.sessions.size() == 3, "Browser source creates one terminal"): return
	var temporary: int = host.sessions.keys().filter(func(id): return id != owner and id != unrelated)[0]
	if not await until(func(): return host.sessions[temporary].term.get_shell_pid() > 0, "Temporary shell starts"): return
	var temporary_pid: int = host.sessions[temporary].term.get_shell_pid()
	check(host.workspace_layout.containing(PaneAddress.key(temporary)) == owner_tab, "New terminal joins the browser's tab")
	check(temporary_pid not in [owner_pid, unrelated_pid], "New terminal owns an independent shell")
	host._close_terminal_pane(temporary)
	if not await until(func(): return not host.sessions.has(temporary) and not process_alive(temporary_pid), "Temporary terminal closes and its shell exits"): return
	check(host.chromiums.get(browser_id) == browser and browser.pid == browser_pid and process_alive(browser_pid) and host.workspace_layout.containing(browser_key) == owner_tab, "Original browser process survives in its owner's tab")
	check(host.sessions[owner].term.get_shell_pid() == owner_pid and process_alive(owner_pid), "Original owner shell survives")
	check(host.sessions[unrelated].term.get_shell_pid() == unrelated_pid and process_alive(unrelated_pid) and host.workspace_layout.containing(PaneAddress.key(unrelated)) == unrelated_tab, "Unrelated shell survives in its tab")
