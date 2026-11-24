//! Named sessions use stable IDs; workspace keys remain private routing tokens.
use crate::{Error, Server, api, spawn};
use serde_json::{Value, json};

pub fn fresh_key() -> String {
    uuid::Uuid::new_v4().to_string()
}

pub fn handles(method: &str) -> bool {
    matches!(
        method,
        "session.list"
            | "session.new"
            | "session.rename"
            | "session.has"
            | "session.kill"
            | "session.checkpoint"
            | "server.restart"
            | "server.status"
    )
}

pub fn description(server: &Server, key: &str) -> Value {
    let info = server.workspaces.info(key);
    let panes: Vec<_> = server
        .sessions
        .values()
        .filter(|s| s.workspace == key)
        .collect();
    // Process cwd queries are bounded to twice a second, shared by every viewer.
    let automatic = {
        let mut cache = server.session_name_cache.borrow_mut();
        cache.retain(|key, _| server.workspaces.contains(key));
        let entry = cache.entry(key.to_owned()).or_insert_with(|| {
            (
                std::time::Instant::now() - std::time::Duration::from_secs(1),
                None,
            )
        });
        if entry.0.elapsed() >= std::time::Duration::from_millis(500) {
            // Filetree Neovim is a helper, not a workspace directory vote:
            // its process cwd may be `/` while its displayed root is elsewhere.
            let directories: Vec<_> = panes.iter()
                .filter(|s| !server.filetrees.active.contains_key(&s.id))
                .filter_map(|s| s.cwd()).collect();
            let home = panes
                .first()
                .and_then(|p| p.home_directory())
                .filter(|home| panes.iter().all(|p| p.home_directory() == Some(*home)));
            entry.1 = graffitty_workspace_core::session::automatic_name(
                directories.iter().map(|p| p.as_path()),
                home,
            );
            entry.0 = std::time::Instant::now();
        }
        entry.1.clone()
    };
    let tabs: std::collections::HashSet<_> = panes
        .iter()
        .map(|s| s.tab)
        .chain(
            server
                .chromiums
                .values()
                .filter(|b| b.workspace == key)
                .map(|b| b.tab),
        )
        .collect();
    let agents = agents(server, key);
    let tree = agent_tree(server, key, &agents);
    json!({"id":info.id.to_string(), "name":info.name, "automatic_name":automatic,
        "windows":tabs.len(), "panes":panes.len(), "attached":server.frontend.has_owner(key),
        "agents":agents, "agent_tree":tree})
}

const AGENT_APPS: [&str; 4] = ["pi", "claude", "codex", "opencode"];

/// Every agent in a session, so clients list agents of sessions they do not
/// show.
///
/// Session descriptors are structural topology: only fields that change at
/// turn boundaries belong here, never animated pane titles or progress.
///
/// An agent's title is therefore sampled when its status changes, without its
/// leading spinner glyphs, so other sessions' rows are never blank.
fn agents(server: &Server, key: &str) -> Vec<Value> {
    let Some(graph) = server.graphs.get(key) else { return vec![] };
    let mut titles = server.agent_title_cache.borrow_mut();
    titles.retain(|pane, _| server.sessions.get(pane).is_some_and(|s| !s.exited));
    let mut result: Vec<Value> = graph.nodes.iter().filter_map(|(node, value)| {
        let pane: u64 = node.strip_prefix('t')?.parse().ok()?;
        let session = server.sessions.get(&pane).filter(|s| s.workspace == key && !s.exited)?;
        let status = value["status"].as_str().unwrap_or("");
        let entry = titles.entry(pane).or_default();
        if entry.0 != status || entry.1.is_empty() || !session.pinned_title.is_empty() {
            *entry = (status.to_owned(), turn_title(&session.title(), pane));
        }
        agent_summary(pane, value, &entry.1)
    }).collect();
    result.sort_by_key(|agent| agent["pane"].as_u64());
    result
}

/// Keep the previous label while a terminal or webpage animates its automatic title.
pub(crate) struct CatalogTitle {
    published: String,
    candidate: String,
    since: std::time::Instant,
}

impl CatalogTitle {
    fn sample<'a>(
        cache: &'a mut std::collections::HashMap<u64, Self>,
        pane: u64,
        title: String,
        pinned: bool,
        now: std::time::Instant,
    ) -> &'a str {
        let entry = cache.entry(pane).or_insert_with(|| Self {
            published: title.clone(), candidate: title.clone(), since: now,
        });
        if entry.candidate != title {
            entry.candidate = title;
            entry.since = now;
        }
        if entry.candidate != entry.published
            && (pinned || now.duration_since(entry.since) >= std::time::Duration::from_secs(1))
        {
            entry.published.clone_from(&entry.candidate);
        }
        &entry.published
    }
}

/// Only connected panes contribute to a background session's agent tree.
fn agent_tree(server: &Server, workspace: &str, agents: &[Value]) -> Value {
    use graffitty_protocol::pane_id::address;
    use std::collections::{BTreeMap, BTreeSet};
    let mut links = BTreeSet::new();
    let mut nodes = BTreeMap::new();
    if agents.is_empty() { return json!({"nodes":[],"edges":[]}); }
    if let Some(graph) = server.graphs.get(workspace) {
        for edge in graph.edges.values() {
            if let (Some(from), Some(to)) = (edge["from"].as_str(), edge["to"].as_str()) {
                links.insert((from.to_owned(), to.to_owned()));
            }
        }
    }
    for pane in server.sessions.values().filter(|p| p.workspace == workspace && !p.exited) {
        if let Some(parent) = pane.spawned_by {
            links.insert((address(parent), address(pane.id)));
        }
    }
    for pane in server.chromiums.values().filter(|p| p.workspace == workspace && p.id != p.owner) {
        links.insert((address(pane.owner), address(pane.id)));
    }
    if !links.is_empty() {
        let mut titles = server.pane_catalog_titles.borrow_mut();
        let now = std::time::Instant::now();
        let keys: BTreeSet<_> = links.iter().flat_map(|(a,b)| [a.as_str(), b.as_str()]).collect();
        let summaries: BTreeMap<_,_> = agents.iter().filter_map(|a| Some((a["pane"].as_u64()?, a))).collect();
        for pane in server.sessions.values().filter(|p| p.workspace == workspace && !p.exited) {
            let key = address(pane.id);
            if !keys.contains(key.as_str()) || server.filetrees.active.contains_key(&pane.id) { continue; }
            let rect = server.workspace_state.pane_rect(workspace, pane.tab, &key).unwrap_or(pane.rect);
            let node = if let Some(agent) = summaries.get(&pane.id) {
                let provider = if AGENT_APPS.contains(&agent["provider"].as_str().unwrap_or("")) {
                    &agent["provider"]
                } else { &agent["program"]["app"] };
                json!({"key":key,"kind":"agent","provider":provider,"title":agent["title"],"rect":rect})
            } else {
                let title = CatalogTitle::sample(&mut titles, pane.id, pane.title(), !pane.pinned_title.is_empty(), now);
                json!({"key":key,"kind":"terminal","title":title,
                    "app":server.foreground_apps.get(&pane.id).and_then(|app| app["id"].as_str()).unwrap_or(""),"rect":rect})
            };
            nodes.insert(key, node);
        }
        for pane in server.chromiums.values().filter(|p| p.workspace == workspace) {
            let key = address(pane.id);
            if keys.contains(key.as_str()) {
                let rect = server.workspace_state.pane_rect(workspace, pane.tab, &key).unwrap_or_default();
                let title = CatalogTitle::sample(&mut titles, pane.id, pane.title(), !pane.pinned_title.is_empty(), now);
                nodes.insert(key.clone(), json!({"key":key,"kind":"chromium","title":title,"rect":rect}));
            }
        }
    }
    let edges: Vec<_> = links.into_iter().filter(|(a,b)| nodes.contains_key(a) && nodes.contains_key(b))
        .map(|(from,to)| json!({"from":from,"to":to})).collect();
    json!({"nodes":nodes.into_values().collect::<Vec<_>>(),"edges":edges})
}

fn agent_summary(pane: u64, value: &Value, title: &str) -> Option<Value> {
    if graffitty_workspace_core::graph::is_custom_node(value) { return None; }
    let provider = value["provider"].as_str().unwrap_or("");
    let program = value.get("program_status").filter(|p| p.is_object()).map(|p| json!({
        "state": p["state"], "app": p.get("app").cloned().unwrap_or(json!("")),
        "title": p.get("title").cloned().unwrap_or(json!("")), "msg": p.get("msg").cloned().unwrap_or(json!("")),
    }));
    let app = program.as_ref().and_then(|p| p["app"].as_str()).unwrap_or("");
    if !AGENT_APPS.contains(&provider) && !AGENT_APPS.contains(&app) { return None; }
    Some(json!({"pane": pane, "provider": provider, "status": value["status"],
        "attention": value["attention"], "activity_revision": value["activity_revision"].as_u64().unwrap_or(0),
        "status_history": value["status_history"].as_array().and_then(|h| h.last()).into_iter().collect::<Vec<_>>(),
        "title": title, "program": program}))
}

/// A title without animated leading glyphs (spinners, stars); its `tN`
/// fallback means "no title".
fn turn_title(title: &str, pane: u64) -> String {
    if title == format!("t{pane}") { return String::new(); }
    title.trim_start_matches(|c: char| !c.is_alphanumeric()).trim().to_owned()
}

pub fn descriptions(server: &Server) -> Vec<Value> {
    server.pane_catalog_titles.borrow_mut().retain(|id, _| server.sessions.contains_key(id) || server.chromiums.contains_key(id));
    let mut keys: Vec<_> = server.workspaces.iter().collect();
    keys.sort_by_key(|key| server.workspaces.info(key).id);
    keys.into_iter()
        .map(|key| description(server, key))
        .collect()
}

/// The successor starts with this server's environment, not with whoever
/// asked for the restart. Otherwise an agent or a pane's shell that runs
/// `gft server restart` becomes every later terminal's environment: its
/// session identity, messaging socket and account.
///
/// A private file beside the descriptor, never the reply: callers may be
/// remote, and the environment can hold credentials.
fn save_environment(server: &Server) -> Result<(), Error> {
    use std::io::Write;
    let environment: std::collections::BTreeMap<String, String> = std::env::vars_os()
        .filter_map(|(key, value)| Some((key.into_string().ok()?, value.into_string().ok()?)))
        .collect();
    let path = crate::handover_environment_path(&server.descriptor);
    let temporary = path.with_extension(format!("{}.tmp", std::process::id()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    file.write_all(&serde_json::to_vec(&environment)?)?;
    file.sync_all()?;
    std::fs::rename(&temporary, &path)?;
    Ok(())
}

pub fn dispatch(server: &mut Server, request: &Value) -> Result<Value, Error> {
    let params = &request["params"];
    if request["version"] != 1 || !params.is_object() {
        return Err(api::error(
            "invalid_request",
            "Expected version 1 and object params",
        ));
    }
    let method = request["method"].as_str().unwrap_or("");
    if method == "server.restart" {
        if server.holders.is_none() {
            return Err(api::error(
                "unsupported",
                "Terminals on this platform end with the server; restart is unavailable",
            ));
        }
        server.handover = true;
        // `park` is for an installer that must replace locked files. Holders keep
        // the terminals and do not start a new server. Local frontends close.
        server.park = params["park"] == true;
        // `relaunch` is for after an upgrade. Local frontends reopen as the new
        // version. Without it they reconnect and stay on the old version.
        server.frontend_notice = if server.park { Some(false) } else { (params["relaunch"] == true).then_some(true) };
        let held = server
            .sessions
            .values()
            .filter(|s| s.is_held() && !s.exited)
            .count();
        let command = server.holders.as_ref().map(|holders| holders.restart_command());
        save_environment(server)?;
        return Ok(json!({"restarting":true,"terminals":held,"command":command}));
    }
    if method == "server.status" {
        // Terminals started under an earlier build stay with that build's
        // holder after a restart; it exits once they all end.
        let (holders, terminals) = server.holders.as_ref().map_or((0, 0), |h| h.draining());
        return Ok(json!({"draining_holders":holders,"draining_terminals":terminals,"build":crate::build_id()}));
    }
    if method == "session.checkpoint" {
        let mut keys: Vec<_> = server.workspaces.iter().cloned().collect();
        keys.sort();
        return crate::session_checkpoints::capture(server, &keys);
    }
    if method == "session.list" {
        return Ok(json!({"sessions":descriptions(server)}));
    }
    if method == "session.new" {
        let name = params["name"].as_str();
        server.workspaces.check_name(name)?;
        if server.workspaces.len() >= 64 {
            return Err(api::error("session_limit", "Session limit reached"));
        }
        let options: spawn::SpawnOptions =
            serde_json::from_value(params.get("spawn").cloned().unwrap_or(json!({})))?;
        let key = fresh_key();
        let saved = crate::SavedIdentity::parse(params.get("saved").unwrap_or(&Value::Null))?;
        let pane = server.create_with_environment(&key, None, None, Some(options), &[], saved)?;
        server.workspaces.rename(&key, name)?;
        let mut result = description(server, &key);
        result["pane"] = json!(pane);
        return Ok(result);
    }
    let target = params["name"]
        .as_str()
        .ok_or_else(|| api::error("invalid_session", "Expected a session name or $id"))?;
    let key = server.workspaces.resolve(target)?;
    if method == "session.rename" {
        let name = params["new_name"].as_str().filter(|s| !s.is_empty());
        if !params
            .get("new_name")
            .is_some_and(|v| v.is_string() || v.is_null())
        {
            return Err(api::error(
                "invalid_params",
                "Expected new_name (string or null for automatic)",
            ));
        }
        server.workspaces.rename(&key, name)?;
    }
    let result = description(server, &key);
    if method == "session.kill" {
        close_workspace(server, &key)?;
    }
    Ok(result)
}

/// The local window-close action includes attached and detached sessions.
pub fn close_all(server: &mut Server) -> Result<(), Error> {
    let keys: Vec<_> = server.workspaces.iter().cloned().collect();
    for key in keys {
        close_workspace(server, &key)?;
    }
    Ok(())
}

fn close_workspace(server: &mut Server, key: &str) -> Result<(), Error> {
    server.workspace_state.remove(key)?;
    let panes: Vec<_> = server
        .sessions
        .values()
        .filter(|s| s.workspace == key)
        .map(|s| s.id)
        .collect();
    for id in panes {
        server.close(id);
    }
    let chromiums: Vec<_> = server
        .chromiums
        .values()
        .filter(|b| b.workspace == key)
        .map(|b| b.id)
        .collect();
    for id in chromiums {
        server.retire_chromium(id);
    }
    server.graphs.remove(key);
    server.workspaces.remove(key);
    server.workspace_incarnations.remove(key);
    Ok(())
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    #[test]
    fn catalog_uses_stable_automatic_titles_and_immediate_pins() {
        use std::time::{Duration, Instant};
        let mut cache = std::collections::HashMap::new();
        let start = Instant::now();
        let mut sample = |title: &str, pinned, ms| {
            super::CatalogTitle::sample(&mut cache, 1, title.to_owned(), pinned, start + Duration::from_millis(ms)).to_owned()
        };
        assert_eq!(sample("Build logs", false, 0), "Build logs");
        for n in 1..30 {
            assert_eq!(sample(&format!("Progress {n}"), false, n * 100), "Build logs");
        }
        assert_eq!(sample("Done", false, 3000), "Build logs");
        assert_eq!(sample("Done", false, 4000), "Done");
        assert_eq!(sample("Pinned", true, 4020), "Pinned");
    }

    #[test]
    fn agent_summary_matches_graph_receipts_for_hooks_and_osc_only_agents() {
        for osc in [false, true] {
            let mut graph = graffitty_workspace_core::graph::Graph::default();
            graph.add(7, "Task".into());
            if osc {
                for state in ["working", "idle"] {
                    graph.observe_program_status(7, Some(&json!({"app":"pi","state":state})));
                }
            } else {
                for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
                    graph.dispatch(7, "agent.event", &json!({"provider":"pi","event":event})).unwrap();
                }
            }
            let first = super::agent_summary(7, &graph.nodes["t7"], "Task").unwrap();
            assert_eq!(first["attention"], graph.snapshot()["nodes"][0]["attention"]);
            assert_eq!(first["attention"]["kind"], "completed");
            assert_eq!(first["activity_revision"], graph.snapshot()["nodes"][0]["activity_revision"]);
            graph.dispatch(7, "agent.seen", &json!({"event":first["attention"]["event"]})).unwrap();
            let seen = super::agent_summary(7, &graph.nodes["t7"], "Task").unwrap();
            assert_eq!(seen["attention"]["seen"], true);
            assert!(seen["activity_revision"].as_u64().unwrap() > first["activity_revision"].as_u64().unwrap());
            assert_eq!(seen["attention"]["event"], first["attention"]["event"]);
            assert_eq!(seen["attention"], graph.snapshot()["nodes"][0]["attention"]);
        }
        assert!(super::agent_summary(1, &json!({"provider":"shell","status":"idle"}), "Shell").is_none());
        assert!(super::agent_summary(1, &json!({"kind":"custom","provider":"custom","status":"waiting"}), "Node").is_none());
    }

    #[test]
    fn turn_titles_drop_spinners_and_fallbacks() {
        assert_eq!(super::turn_title("⠐ Fix the build", 3), "Fix the build");
        assert_eq!(super::turn_title("✳ Claude Code", 3), "Claude Code");
        assert_eq!(super::turn_title("π Fix black", 3), "π Fix black");
        assert_eq!(super::turn_title("t3", 3), "");
    }
}
