//! Agent list and attention sounds, adapted from herdr-app's model.rs and
//! defaults/mods/agents/main.js at e77f112 (Apache-2.0).
//! Changes: Graffitty status/provider adapter, no spaces, client-local pins,
//! stable server/epoch/terminal identities and a frontend-neutral snapshot.
use graffitty_protocol::agent_attention::{AgentAttention, AttentionKind};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};

#[derive(Clone, Debug, Deserialize)]
pub struct Input {
    pub id: String,
    pub key: String,
    pub title: String,
    pub provider: String,
    pub status: String,
    /// Optional OSC 7501 root report. Presentation only; never grants a graph identity.
    pub program: Option<graffitty_terminal_core::program_status::Status>,
    /// Server attention, with any pending local receipt already projected by the caller.
    pub attention: Option<AgentAttention>,
    /// Server-recorded transitions for durations only, never unread inference.
    #[serde(default)]
    pub status_history: Vec<StatusChange>,
    /// Stable id of the leading agent when this pane is a connected child.
    #[serde(default)]
    pub group: Option<String>,
    pub looking: bool,
    pub focused: bool,
}
#[derive(Clone, Debug, Deserialize)]
pub struct StatusChange { pub status: String, pub at: String }
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Stamp { pub state: String, pub at: u64 }
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Saved {
    pub version: u32,
    pub pins: HashSet<String>,
    pub changed: BTreeMap<String, Stamp>,
}
impl Default for Saved {
    fn default() -> Self { Self { version: 1, pins: HashSet::new(), changed: BTreeMap::new() } }
}
#[derive(Clone, Debug, Serialize)]
pub struct Row {
    pub id: String, pub key: String, pub title: String, pub provider: String,
    pub status: String, pub section: String, pub at: u64,
    pub focused: bool, pub pinned: bool,
}
#[derive(Default)]
struct Agent { word: String, status: String, event: Option<String>, seq: u64 }
#[derive(Default)]
pub struct Agents {
    saved: Saved,
    agents: HashMap<String, Agent>,
    held: Option<(String, u8)>,
    seq: u64,
}
fn word(s: &str) -> &str {
    match s { "busy" => "working", "waiting" | "error" => "blocked", _ => "idle" }
}
fn rank(s: &str) -> u8 {
    match s { "blocked" => 4, "done" => 3, "working" => 2, _ => 1 }
}
fn section(r: u8) -> &'static str {
    match r { 4 => "Needs you", 3 => "Done", 2 => "Working", _ => "Idle" }
}
fn app_name(provider: &str) -> &str {
    match provider { "pi" => "Pi", "claude" => "Claude Code", "codex" => "Codex", "opencode" => "OpenCode", other => other }
}
/// Sounds stay local. A new completion token can alert across a missed busy
/// snapshot, but startup and repeated snapshots of that event stay quiet.
fn alert(previous: Option<&Agent>, next: &str, event: Option<&str>, looking: bool) -> Option<&'static str> {
    if next == "blocked" && previous.is_none_or(|a| a.status != "blocked") { Some("blocked") }
    else if next == "done" && !looking && previous.is_some_and(|a| a.event.as_deref() != event) { Some("done") }
    else { None }
}
impl Agents {
    pub fn restore(&mut self, json: &str) -> Result<(), String> {
        let saved: Saved = serde_json::from_str(json).map_err(|e| e.to_string())?;
        if saved.version != 1 { return Err("unsupported agents state version".into()); }
        self.saved = saved;
        Ok(())
    }
    pub fn save(&self) -> String { serde_json::to_string(&self.saved).unwrap() }
    pub fn pin(&mut self, id: String, pinned: bool) {
        if pinned { self.saved.pins.insert(id); } else { self.saved.pins.remove(&id); }
    }
    /// Missing agents retain only local sound/group ordering history. Unread
    /// state always comes from the current input, including after reconnect.
    pub fn observe(&mut self, input: Vec<Input>, now: u64) -> (Vec<Row>, Vec<String>) {
        let mut rows = Vec::new();
        let mut alerts = Vec::new();
        let mut leaders = HashMap::new();
        let mut groups = HashMap::new();
        let mut order = HashMap::new();
        for mut item in input {
            let supported = |app: &str| ["pi", "claude", "codex", "opencode"].contains(&app);
            // A shell/SSH/tmux pane can report an agent through OSC without
            // registering provider hooks. Use its explicit app for this list,
            // without changing the server's graph provider or permissions.
            if !supported(&item.provider) {
                let Some(program) = item.program.as_ref().filter(|p| supported(&p.app)) else { continue; };
                item.provider = program.app.clone();
                item.status = match program.state.as_str() {
                    "working" => "busy", "blocked" | "error" => "waiting",
                    "idle" | "done" => "idle", _ => continue,
                }.into();
                if !program.title.is_empty() { item.title = program.title.clone(); }
            }
            // Herdr: a row is never blank; without a title it reads as its program.
            if item.title.trim().is_empty() { item.title = app_name(&item.provider).into(); }
            if let Some(group) = item.group.take() { groups.insert(item.id.clone(), group); }
            if !["busy", "waiting", "idle", "error"].contains(&item.status.as_str()) {
                leaders.insert(item.id.clone(), item);
                continue;
            }
            let next = word(&item.status);
            let status = if next == "idle" && item.attention.as_ref()
                .is_some_and(|attention| attention.kind == AttentionKind::Completed && !attention.seen)
                { "done" } else { next };
            let old = self.agents.get(&item.id);
            let observed_change = old.is_some_and(|a| a.word != next);
            let event = item.attention.as_ref().map(|attention| attention.event.as_str());
            if let Some(sound) = alert(old, status, event, item.looking) {
                alerts.push(sound.to_owned());
            }
            // The caller may project the receipt before the focus update.
            // Retain the previous group for focus hold only, never unread state.
            let hold_status = if status == "idle" && old.is_some_and(|a| a.status == "done") { "done" } else { status };
            if item.focused && (self.held.as_ref().is_none_or(|h| h.0 != item.id) || hold_status != "idle") {
                self.held = Some((item.id.clone(), rank(hold_status)));
            }
            let seq = if let Some(a) = old.filter(|a| a.word == next) { a.seq }
                else { self.seq += 1; self.seq };
            self.agents.insert(item.id.clone(), Agent { word: next.into(), status: status.into(), event: event.map(str::to_owned), seq });
            let shown_rank = if status == "idle" && item.focused && self.held.as_ref().is_some_and(|h| h.0 == item.id && h.1 == 3) { 3 } else { rank(status) };
            // Looking isn't work: Done and Idle share one duration.
            let stamp = self.saved.changed.entry(item.id.clone()).or_default();
            // The server observed the transition even if the phone was asleep.
            // Discovery time is not the time the server changed status.
            let recorded = item.status_history.last()
                .filter(|change| change.status == item.status)
                .and_then(|change| chrono::DateTime::parse_from_rfc3339(&change.at).ok())
                .and_then(|time| u64::try_from(time.timestamp_millis()).ok());
            if let Some(millis) = recorded {
                *stamp = Stamp { state: next.into(), at: millis / 1000 };
            } else if stamp.state != next {
                *stamp = Stamp { state: next.into(), at: if observed_change { now } else { 0 } };
            }
            let pinned = self.saved.pins.contains(&item.id);
            let sort_millis = recorded.unwrap_or_else(|| stamp.at.saturating_mul(1000));
            order.insert(item.id.clone(), (if pinned { rank(status) } else { shown_rank }, sort_millis, seq));
            rows.push(Row { id: item.id, key: item.key, title: item.title, provider: item.provider,
                status: status.into(), section: if pinned { "Pinned" } else { section(shown_rank) }.into(),
                at: stamp.at, focused: item.focused, pinned });
        }
        if !rows.iter().any(|r| r.focused) { self.held = None; }
        // Each descendant names its tree root, including through intermediate tools.
        // A completion and a pin belong to the individual agent.
        let mut child_ranks = BTreeMap::new();
        for row in &rows {
            if let Some(root) = groups.get(&row.id) {
                let urgency = match row.status.as_str() { "blocked" => 4, "working" => 2, _ => 1 };
                let (_, millis, seq) = order[&row.id];
                let priority = (urgency, millis, seq);
                let highest = child_ranks.entry(root.clone()).or_default();
                *highest = priority.max(*highest);
            }
        }
        for root in child_ranks.keys() {
            if let Some(leader) = leaders.remove(root) {
                let pinned = self.saved.pins.contains(root);
                rows.push(Row {
                    id: leader.id, key: leader.key, title: leader.title, provider: leader.provider,
                    status: leader.status, section: if pinned { "Pinned" } else { "Idle" }.into(),
                    at: 0, focused: leader.focused, pinned,
                });
            }
        }
        for row in &mut rows {
            let own = order.entry(row.id.clone()).or_insert((0, 0, 0));
            if let Some(&child) = child_ranks.get(&row.id) {
                if child.0 > own.0 {
                    *own = child;
                    if !row.pinned { row.section = section(child.0).into(); }
                }
            }
        }
        // The tree sorts with the activity which promoted it. The leader's
        // displayed age and state still come from its own transition.
        rows.sort_by(|a,b| b.pinned.cmp(&a.pinned)
            .then_with(|| order[&b.id].cmp(&order[&a.id]))
            .then_with(|| child_ranks.contains_key(&b.id).cmp(&child_ranks.contains_key(&a.id)))
            .then_with(|| a.id.cmp(&b.id)));
        let listed: HashSet<_> = rows.iter().map(|r| r.id.clone()).collect();
        self.saved.changed.retain(|id, stamp| listed.contains(id) || now.saturating_sub(stamp.at) <= 30 * 86400);
        (rows, alerts)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const FIRST: &str = "00000000-0000-4000-8000-000000000001";
    const SECOND: &str = "00000000-0000-4000-8000-000000000002";
    fn input(status: &str, looking: bool, focused: bool) -> Vec<Input> {
        vec![Input { id: "server/epoch/1".into(), key: "t1".into(), title: "task".into(), provider: "pi".into(), status: status.into(), program: None, attention: None, status_history: vec![], group: None, looking, focused }]
    }
    fn completed(event: &str, seen: bool, looking: bool, focused: bool) -> Vec<Input> {
        let mut items = input("idle", looking, focused);
        items[0].attention = Some(AgentAttention { event: event.into(), kind: AttentionKind::Completed, seen });
        items
    }
    #[test] fn done_holds_until_leaving_without_resetting_duration() {
        let mut a = Agents::default();
        a.observe(input("busy", false, false), 1);
        let (rows, alerts) = a.observe(completed(FIRST, false, false, false), 2);
        assert_eq!(rows[0].section, "Done"); assert_eq!(alerts, ["done"]);
        let (rows, alerts) = a.observe(completed(FIRST, true, true, true), 3);
        assert!(alerts.is_empty()); assert_eq!(rows[0].section, "Done"); assert_eq!(rows[0].status, "idle"); assert_eq!(rows[0].at, 2);
        assert_eq!(a.observe(completed(FIRST, true, true, true), 4).0[0].section, "Done");
        let (rows, _) = a.observe(completed(FIRST, true, false, false), 5);
        assert_eq!(rows[0].section, "Idle");
    }
    #[test] fn fresh_and_reconnecting_clients_agree_on_unseen_completion_and_shared_receipt() {
        let (mut existing, mut fresh) = (Agents::default(), Agents::default());
        existing.observe(input("busy", false, false), 1);
        existing.observe(vec![], 2);
        let unseen = completed(FIRST, false, false, false);
        let (existing_rows, existing_sounds) = existing.observe(unseen.clone(), 3);
        let (fresh_rows, fresh_sounds) = fresh.observe(unseen.clone(), 3);
        for rows in [&existing_rows, &fresh_rows] {
            assert_eq!(rows[0].status, "done");
            assert_eq!(rows[0].section, "Done");
        }
        assert_eq!(existing_sounds, ["done"]);
        assert!(fresh_sounds.is_empty(), "joining a server must not sound its old completions");
        for client in [&mut existing, &mut fresh] {
            client.observe(vec![], 4);
            assert!(client.observe(unseen.clone(), 5).1.is_empty());
            let (rows, sounds) = client.observe(completed(FIRST, true, false, false), 6);
            assert_eq!(rows[0].status, "idle");
            assert_eq!(rows[0].section, "Idle");
            assert!(sounds.is_empty());
        }
    }
    #[test] fn new_completion_tokens_alert_without_a_busy_snapshot_but_never_repeat() {
        let mut a = Agents::default();
        a.observe(input("idle", false, false), 1);
        let first = completed(FIRST, false, false, false);
        assert_eq!(a.observe(first.clone(), 2).1, ["done"]);
        assert!(a.observe(first.clone(), 3).1.is_empty());
        a.observe(vec![], 4);
        assert!(a.observe(first, 5).1.is_empty());
        let second = completed(SECOND, false, false, false);
        assert_eq!(a.observe(second.clone(), 6).1, ["done"], "idle-to-idle replacement is a new completion");
        assert!(a.observe(second, 7).1.is_empty());
    }
    #[test] fn read_completions_and_absent_attention_never_alert_or_infer_done() {
        for result in [completed(FIRST, true, false, false), input("idle", false, false)] {
            let mut a = Agents::default();
            a.observe(input("busy", false, false), 1);
            let (rows, sounds) = a.observe(result.clone(), 2);
            assert_eq!(rows[0].status, "idle");
            assert_eq!(rows[0].section, "Idle");
            assert!(sounds.is_empty());
            let (rows, sounds) = Agents::default().observe(result, 3);
            assert_eq!(rows[0].status, "idle");
            assert!(sounds.is_empty());
        }
        let mut history_only = input("idle", false, false);
        history_only[0].status_history = vec![
            StatusChange { status: "busy".into(), at: "2030-01-01T00:00:01Z".into() },
            StatusChange { status: "idle".into(), at: "2030-01-01T00:00:02Z".into() },
        ];
        let mut a = Agents::default();
        a.observe(input("busy", false, false), 1);
        let (rows, sounds) = a.observe(history_only, 2);
        assert_eq!(rows[0].status, "idle");
        assert!(sounds.is_empty());
    }
    #[test] fn looking_does_not_replace_server_receipts_and_active_status_wins() {
        let mut a = Agents::default();
        a.observe(input("busy", false, false), 1);
        let (rows, sounds) = a.observe(completed(FIRST, false, true, false), 2);
        assert_eq!(rows[0].status, "done", "the caller owns optimistic read projection");
        assert!(sounds.is_empty());
        assert!(a.observe(completed(FIRST, false, false, false), 3).1.is_empty(), "looking away does not replay sound");
        for (status, expected) in [("busy", "working"), ("waiting", "blocked"), ("error", "blocked")] {
            let mut items = completed(FIRST, false, false, false);
            items[0].status = status.into();
            assert_eq!(a.observe(items, 4).0[0].status, expected);
        }
        let mut waiting = input("idle", false, false);
        waiting[0].attention = Some(AgentAttention { event: SECOND.into(), kind: AttentionKind::Waiting, seen: false });
        let (rows, sounds) = a.observe(waiting, 5);
        assert_eq!(rows[0].status, "idle");
        assert!(sounds.is_empty(), "waiting attention is not completion");
    }
    #[test] fn typed_attention_is_optional_but_rejects_obsolete_or_malformed_forms() {
        let mut value = serde_json::json!({"id":"agent", "key":"t1", "title":"task", "provider":"pi", "status":"idle",
            "program":null, "looking":false, "focused":false});
        assert!(serde_json::from_value::<Input>(value.clone()).unwrap().attention.is_none());
        value["attention"] = serde_json::Value::Null;
        assert!(serde_json::from_value::<Input>(value.clone()).unwrap().attention.is_none());
        value["attention"] = serde_json::json!({"event":FIRST, "kind":"completed", "seen":false});
        assert_eq!(serde_json::from_value::<Input>(value.clone()).unwrap().attention.unwrap().event, FIRST);
        value["attention"] = serde_json::json!({"event":FIRST, "kind":"completed"});
        assert!(serde_json::from_value::<Input>(value.clone()).is_err());
        value["attention"] = serde_json::json!({"event":FIRST, "kind":"done", "seen":false});
        assert!(serde_json::from_value::<Input>(value).is_err());
    }
    #[test] fn tab_projection_and_list_share_optimistic_receipts_without_a_second_seen_flag() {
        let mut tabs = crate::agent_attention::AgentAttention::default();
        let mut list = Agents::default();
        let live: HashSet<String> = ["t1".into()].into();
        let mut nodes = serde_json::json!({"t1":{"attention":{"event":FIRST, "kind":"completed", "seen":false}}});
        let mut rows = completed(FIRST, false, false, false);
        tabs.observe(&nodes, &HashSet::new(), &live);
        rows[0].attention = serde_json::from_value(tabs.attention("t1")).unwrap();
        assert_eq!(list.observe(rows.clone(), 1).0[0].status, "done");
        tabs.observe(&nodes, &live, &live);
        rows[0].attention = serde_json::from_value(tabs.attention("t1")).unwrap();
        rows[0].focused = true;
        rows[0].looking = true;
        let (shown, sounds) = list.observe(rows.clone(), 2);
        assert_eq!(shown[0].status, "idle");
        assert_eq!(shown[0].section, "Done", "focusing the result holds its group");
        assert!(sounds.is_empty());
        assert_eq!(tabs.acknowledgements(), serde_json::json!([{"key":"t1", "event":FIRST}]));
        nodes["t1"]["attention"]["event"] = SECOND.into();
        tabs.observe(&nodes, &HashSet::new(), &live);
        rows[0].attention = serde_json::from_value(tabs.attention("t1")).unwrap();
        rows[0].focused = false;
        rows[0].looking = false;
        let (shown, sounds) = list.observe(rows, 3);
        assert_eq!(shown[0].status, "done");
        assert_eq!(sounds, ["done"]);
        assert_eq!(tabs.acknowledgements(), serde_json::json!([]));
    }
    #[test] fn osc_only_agent_is_listed_and_alerts_without_inventing_graph_identity() {
        let mut model = Agents::default();
        let mut snapshot = input("busy", false, false);
        snapshot[0].provider = "shell".into();
        snapshot[0].program = Some(serde_json::from_value(serde_json::json!({
            "state":"working", "app":"pi", "title":"OSC task"
        })).unwrap());
        let (rows, sounds) = model.observe(snapshot.clone(), 10);
        assert_eq!(rows[0].provider, "pi");
        assert_eq!(rows[0].title, "OSC task");
        assert_eq!(rows[0].status, "working");
        assert!(sounds.is_empty());
        snapshot[0].program.as_mut().unwrap().state = "blocked".into();
        let (rows, sounds) = model.observe(snapshot.clone(), 11);
        assert_eq!(rows[0].section, "Needs you");
        assert_eq!(sounds, ["blocked"]);
        assert_eq!(snapshot[0].provider, "shell");
        snapshot[0].program.as_mut().unwrap().state = "done".into();
        snapshot[0].attention = completed(FIRST, false, false, false).remove(0).attention;
        let (rows, sounds) = model.observe(snapshot.clone(), 12);
        assert_eq!(rows[0].status, "done");
        assert_eq!(sounds, ["done"]);
        snapshot[0].attention.as_mut().unwrap().seen = true;
        let (rows, sounds) = model.observe(snapshot.clone(), 13);
        assert_eq!(rows[0].status, "idle");
        assert!(sounds.is_empty());
        snapshot[0].program = None;
        assert!(model.observe(snapshot, 14).0.is_empty());
    }

    #[test]
    fn unavailable_leader_keeps_its_identity_and_pin_only_with_listed_descendants() {
        let mut state = Agents::default();
        let mut leader = input("unknown", false, false).remove(0);
        leader.title.clear();
        let mut child = input("waiting", false, false).remove(0);
        child.id = "child".into();
        child.key = "t2".into();
        child.group = Some(leader.id.clone());
        assert!(state.observe(vec![leader.clone()], 10).0.is_empty());
        let (rows, sounds) = state.observe(vec![child.clone(), leader.clone()], 11);
        assert_eq!(rows.iter().map(|row| row.id.as_str()).collect::<Vec<_>>(), [leader.id.as_str(), "child"]);
        assert_eq!((&*rows[0].title, &*rows[0].status, &*rows[0].section, rows[0].at), ("Pi", "unknown", "Needs you", 0));
        assert_eq!(sounds, ["blocked"]);
        state.pin(leader.id.clone(), true);
        leader.status = "offline".into();
        let (rows, sounds) = state.observe(vec![leader.clone(), child.clone()], 12);
        assert!(rows[0].pinned && rows[0].section == "Pinned" && sounds.is_empty());
        child.status = "offline".into();
        assert!(state.observe(vec![leader, child], 13).0.is_empty());
    }

    #[test]
    fn group_section_uses_descendants_but_preserves_individual_activity() {
        let mut model = Agents::default();
        let mut root = input("idle", false, false).remove(0);
        let mut worker = input("busy", false, false).remove(0);
        worker.id = "grandchild".into();
        worker.group = Some(root.id.clone());
        let mut finished = completed(FIRST, false, false, false).remove(0);
        finished.id = "finished".into();
        finished.group = Some(root.id.clone());
        model.pin(finished.id.clone(),true);
        for (leader_state, child_state, unread, expected, expected_status) in [
            ("idle","busy",false,"Working","idle"),
            ("idle","idle",false,"Idle","idle"),
            ("idle","busy",true,"Done","done"),
            ("idle","waiting",true,"Needs you","done"),
            ("offline","busy",false,"Working","offline"),
            ("unknown","idle",false,"Idle","unknown"),
        ] {
            root.status = leader_state.into();
            root.attention = unread.then(|| finished.attention.clone().unwrap());
            worker.status = child_state.into();
            let (rows, _) = model.observe(vec![root.clone(),worker.clone(),finished.clone()],20);
            assert_eq!(rows.len(),3);
            let parent = rows.iter().find(|r|r.id==root.id).unwrap();
            assert_eq!((parent.section.as_str(),parent.status.as_str(),parent.at),(expected,expected_status,0));
            let pinned = rows.iter().find(|r|r.id==finished.id).unwrap();
            assert_eq!((pinned.section.as_str(),pinned.status.as_str()),("Pinned","done"));
        }
        model.pin(root.id.clone(),true);
        worker.status = "waiting".into();
        let (rows,sounds) = model.observe(vec![root.clone(),worker],21);
        assert_eq!(sounds,["blocked"]);
        assert_eq!(rows.iter().find(|r|r.id==root.id).unwrap().section,"Pinned");
    }

    #[test]
    fn promoted_trees_sort_by_the_newest_child_contributing_their_section() {
        for (root_status, child_status) in [("unknown", "waiting"), ("idle", "busy"), ("offline", "idle")] {
            let mut model = Agents::default();
            let mut root = input(root_status, false, false).remove(0);
            root.id = "root".into();
            let mut older = input(child_status, false, false).remove(0);
            older.id = "older".into();
            older.group = Some(root.id.clone());
            let mut newest = older.clone();
            newest.id = "newest".into();
            let mut standalone = older.clone();
            standalone.id = "standalone".into();
            standalone.group = None;
            let mut unrelated = older.clone();
            unrelated.id = "idle-child".into();
            unrelated.status = "idle".into();
            for (item,second) in [(&mut older,5),(&mut newest,50),(&mut standalone,10),(&mut unrelated,59)] {
                item.status_history.push(StatusChange { status:item.status.clone(), at:format!("2030-01-01T00:00:{second:02}Z") });
            }
            let mut items = vec![root,older,newest,standalone,unrelated];
            let visible = |rows: Vec<Row>| rows.into_iter().filter(|r| r.id == "root" || r.id == "standalone").collect::<Vec<_>>();
            let rows = visible(model.observe(items.clone(),100).0);
            assert_eq!((rows[0].id.as_str(),rows[0].at),("root",0));
            items.reverse();
            assert_eq!(visible(model.observe(items.clone(),101).0)[0].id,"root");
            for item in &mut items {
                if item.id == "newest" || (child_status == "idle" && item.id == "idle-child") { item.status_history[0].at = "2030-01-01T00:00:08Z".into(); }
            }
            assert_eq!(visible(model.observe(items,102).0)[0].id,"standalone");
        }
    }

    #[test]
    fn pinned_focus_hold_sorts_by_current_status() {
        let mut model = Agents::default();
        let mut held = completed(FIRST,false,true,true).remove(0);
        let mut worker = input("busy",false,false).remove(0);
        worker.id = "worker".into();
        model.pin(held.id.clone(),true);
        model.pin(worker.id.clone(),true);
        assert_eq!(model.observe(vec![held.clone(),worker.clone()],10).0[0].id,held.id);
        held.attention.as_mut().unwrap().seen = true;
        let rows = model.observe(vec![held,worker.clone()],11).0;
        assert_eq!((rows[0].id.as_str(),rows[1].status.as_str()),(worker.id.as_str(),"idle"));
    }

    #[test]
    fn fresh_clients_sort_same_second_requests_by_server_milliseconds() {
        for newest_is_child in [false,true] {
            let root = input("unknown",false,false).remove(0);
            let mut child = input("waiting",false,false).remove(0);
            child.id = "child".into();
            child.group = Some(root.id.clone());
            let mut standalone = child.clone();
            standalone.id = "standalone".into();
            standalone.group = None;
            for (item,newest) in [(&mut child,newest_is_child),(&mut standalone,!newest_is_child)] {
                let millis = if newest { 900 } else { 100 };
                item.status_history.push(StatusChange {status:"waiting".into(),at:format!("2030-01-01T00:00:10.{millis}Z")});
            }
            let expected = if newest_is_child { &root.id } else { &standalone.id };
            for items in [vec![root.clone(),child.clone(),standalone.clone()],vec![standalone.clone(),child.clone(),root.clone()]] {
                let (rows,_) = Agents::default().observe(items,0);
                assert_eq!(&rows[0].id,expected);
                assert_eq!(rows.iter().find(|r|r.id==child.id).unwrap().at,1893456010);
                assert_eq!(rows.iter().find(|r|r.id==root.id).unwrap().at,0);
            }
        }
    }

    #[test]
    fn equal_timestamp_promotions_keep_the_contributing_childs_sequence() {
        let mut model = Agents::default();
        let root = input("idle",false,false).remove(0);
        let mut child = input("idle",false,false).remove(0);
        child.id = "child".into();
        child.group = Some(root.id.clone());
        let mut other = input("idle",false,false).remove(0);
        other.id = "other".into();
        model.observe(vec![root.clone(),child.clone(),other.clone()],0);
        other.status = "waiting".into();
        model.observe(vec![root.clone(),child.clone(),other.clone()],10);
        child.status = "waiting".into();
        for items in [vec![root.clone(),other.clone(),child.clone()],vec![child,other,root.clone()]] {
            let rows = model.observe(items,10).0;
            assert_eq!((rows[0].id.as_str(),rows[0].at),(root.id.as_str(),0));
        }
    }

    #[test] fn sorting_pins_recent_changes_and_provider_filtering() {
        let mut a = Agents::default();
        let mut idle = input("idle", false, false).remove(0);
        idle.id = "idle".into();
        let mut working = input("busy", false, false).remove(0);
        working.id = "working".into();
        let mut waiting = input("waiting", false, false).remove(0);
        waiting.id = "waiting".into();
        let mut shell = input("waiting", false, false).remove(0);
        shell.provider = "shell".into();
        a.pin(idle.id.clone(), true);
        let (rows, sounds) = a.observe(vec![working, idle, waiting, shell], 20);
        assert_eq!(rows.iter().map(|r| r.section.as_str()).collect::<Vec<_>>(), ["Pinned", "Needs you", "Working"]);
        assert_eq!(sounds, ["blocked"]);
    }
    #[test] fn reconnect_does_not_repeat_wait_and_visible_completion_is_idle() {
        let mut a = Agents::default();
        assert_eq!(a.observe(input("waiting", true, true), 1).1, ["blocked"]);
        a.observe(Vec::new(), 2);
        assert!(a.observe(input("waiting", true, true), 3).1.is_empty());
        let (rows, sounds) = a.observe(completed(FIRST, true, true, true), 4);
        assert_eq!(rows[0].section, "Idle"); assert!(sounds.is_empty());
    }
    #[test] fn pin_and_clock_survive_restart_and_schemas_are_strict() {
        let mut a = Agents::default();
        a.observe(input("idle", false, false), 10);
        a.observe(input("busy", false, false), 20);
        a.pin("server/epoch/1".into(), true);
        let mut b = Agents::default(); b.restore(&a.save()).unwrap();
        let (rows, _) = b.observe(input("busy", false, false), 99);
        assert_eq!(rows[0].section, "Pinned"); assert_eq!(rows[0].at, 20);
        assert!(b.restore(r#"{"version":0,"pins":[],"changed":{}}"#).is_err());
    }
    #[test] fn untitled_rows_read_as_their_program() {
        let mut a = Agents::default();
        let mut items = input("idle", false, false);
        items[0].title = " ".into();
        let (rows, _) = a.observe(items, 1);
        assert_eq!(rows[0].title, "Pi");
    }
    #[test] fn server_transition_time_wins_over_discovery_reconnect_and_saved_client_time() {
        let mut a = Agents::default();
        let mut items = input("idle", false, false);
        let stopped = 1_800_000_000;
        let first_seen = stopped + 10 * 3600;
        assert_eq!(a.observe(items.clone(), first_seen).0[0].at, 0, "Unknown age must not pretend to be a fresh finish");
        a.restore(&format!(r#"{{"version":1,"pins":[],"changed":{{"server/epoch/1":{{"state":"idle","at":{first_seen}}}}}}}"#)).unwrap();
        items[0].status_history = vec![StatusChange { status: "idle".into(), at: "2027-01-15T08:00:00.000Z".into() }];
        let rows = a.observe(items.clone(), first_seen).0;
        assert_eq!(rows[0].at, stopped);
        a.observe(vec![], first_seen + 60);
        assert_eq!(a.observe(items.clone(), first_seen + 120).0[0].at, stopped);
        // A whole busy/idle cycle while disconnected must advance the clock,
        // even though the displayed status is idle before and after the gap.
        items[0].status_history[0].at = "2027-01-15T08:05:00.000Z".into();
        items[0].looking = true;
        assert_eq!(a.observe(items, first_seen + 180).0[0].at, stopped + 300);
    }
}
