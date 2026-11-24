//! Attention transitions shared by lifecycle hooks, discovery and OSC 7501.
use super::*;
use graffitty_protocol::agent_attention::{AgentAttention, AttentionKind};

fn is_agent(node: &Value) -> bool {
    let agents = ["claude", "codex", "opencode", "pi"];
    !is_custom_node(node) && (agents.contains(&string(node, "provider"))
        || agents.contains(&string(&node["program_status"], "app")))
}

pub(super) fn identity_replaced(previous: &Value, incoming: &Value) -> bool {
    // A process exit keeps its last completion. Discovery may report the shell
    // here; it is not a new agent taking over the pane.
    if incoming["status"] == "offline" { return false; }
    ["provider", "pid", "started", "session_id"].iter().any(|field| {
        let old = &previous[*field];
        let new = &incoming[*field];
        !old.is_null() && !new.is_null() && old != new
            && !(old == "" || new == "")
            && !(*field == "provider" && old == "shell")
    })
}

/// Shared across workspaces for the lifetime of an owner epoch.
#[derive(Clone, Default)]
pub struct ActivityClock(std::sync::Arc<std::sync::atomic::AtomicU64>);

impl ActivityClock {
    pub fn current(&self) -> u64 { self.0.load(std::sync::atomic::Ordering::Relaxed) }

    pub fn resume_after(&self, revision: u64) {
        self.0.fetch_max(revision, std::sync::atomic::Ordering::Relaxed);
    }

    pub fn next(&self) -> u64 {
        self.0.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1
    }

    pub(super) fn advance(&self, node: &mut Value) {
        node["activity_revision"] = json!(self.next());
    }
}

pub(super) fn record_change(clock: &ActivityClock, node: &mut Value, previous: &Value) {
    if ["status", "provider", "attention"].iter().any(|key| node[*key] != previous[*key])
        || ["state", "app"].iter().any(|key| node["program_status"][*key] != previous["program_status"][*key]) {
        clock.advance(node);
    }
}

pub(super) fn update(node: &mut Value, previous_status: &str, replaced: bool) {
    let retained_completion = !replaced && matches!(string(node, "status"), "offline" | "unintegrated")
        && node["attention"]["kind"] == "completed";
    if is_custom_node(node) || (!retained_completion && !is_agent(node)) {
        node.as_object_mut().unwrap().remove("attention");
        return;
    }
    if replaced { node.as_object_mut().unwrap().remove("attention"); }
    let kind = match string(node, "status") {
        "busy" => {
            node.as_object_mut().unwrap().remove("attention");
            None
        }
        "waiting" if replaced || previous_status != "waiting" => Some(AttentionKind::Waiting),
        "idle" if !replaced && matches!(previous_status, "busy" | "waiting") => Some(AttentionKind::Completed),
        "offline" | "unintegrated" => {
            if node["attention"]["kind"] == "waiting" {
                node.as_object_mut().unwrap().remove("attention");
            }
            None
        }
        _ => None,
    };
    if let Some(kind) = kind {
        issue(node, kind);
    }
}

pub(super) fn issue(node: &mut Value, kind: AttentionKind) {
    node["attention"] = json!(AgentAttention {
        event: uuid::Uuid::new_v4().to_string(), kind, seen: false,
    });
}

pub(super) fn validate(value: &Value) -> Result<Option<AgentAttention>> {
    let attention: Option<AgentAttention> = serde_json::from_value(value.clone()).map_err(|e| e.to_string())?;
    if let Some(attention) = &attention {
        uuid::Uuid::parse_str(&attention.event).map_err(|_| "Attention event must be a UUID")?;
    }
    Ok(attention)
}

/// Only the attention baseline needed when the same live process is adopted.
/// This does not recover graph delivery queues or provider transcript access.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AttentionState {
    pub attention: Option<AgentAttention>,
    #[serde(skip_serializing_if = "Option::is_none")]
    activity_revision: Option<u64>,
    status: String,
    provider: Option<String>,
    kind: Option<String>,
    pid: Option<u64>,
    started: Option<String>,
    session_id: Option<String>,
    integrated: Option<bool>,
    transport: Option<String>,
    status_source: Option<String>,
    timed_out_status: Option<String>,
}

impl Graph {
    pub fn attention_state(&self, id: u64) -> Option<AttentionState> {
        let key = format!("t{id}");
        let node = self.nodes.get(&key)?;
        if is_custom_node(node) || (!is_agent(node) && node["attention"].is_null()) { return None; }
        let text = |field| node[field].as_str().map(str::to_owned);
        Some(AttentionState {
            attention: validate(&node["attention"]).expect("server-owned attention"),
            activity_revision: node["activity_revision"].as_u64(),
            status: string(node, "status").into(), provider: text("provider"), kind: text("kind"),
            pid: node["pid"].as_u64(), started: text("started"), session_id: text("session_id"),
            integrated: node["integrated"].as_bool(), transport: text("transport"),
            status_source: text("status_source"),
            timed_out_status: self.timed_out_status.get(&key).and_then(Value::as_str).map(str::to_owned),
        })
    }

    /// Restore before discovery or hooks run, and only for an adopted live pane.
    pub fn restore_attention_state(&mut self, id: u64, state: &AttentionState) -> Result<()> {
        validate(&json!(state.attention))?;
        let key = format!("t{id}");
        let node = self.nodes.get_mut(&key).ok_or("Unknown adopted pane")?;
        let mut fields = serde_json::to_value(state).map_err(|e| e.to_string())?;
        fields.as_object_mut().unwrap().remove("timed_out_status");
        node.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
        self.activity_clock.resume_after(state.activity_revision.unwrap_or_default());
        self.activity_clock.advance(node);
        if state.transport.as_deref() == Some("inbox") {
            node["heartbeat_at"] = json!(now());
        }
        if let Some(status) = &state.timed_out_status {
            self.timed_out_status.insert(key, json!(status));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn graph() -> Graph {
        let mut graph = Graph::default();
        graph.add(1, "Agent".into());
        graph.dispatch(1, "agent.event", &json!({"provider":"pi","event":"SessionStart",
            "pid":10,"session_id":"conversation","integrated":true})).unwrap();
        graph
    }
    fn hook(graph: &mut Graph, event: &str) {
        graph.dispatch(1, "agent.event", &json!({"event":event})).unwrap();
    }
    fn receipt(graph: &Graph) -> Value { graph.nodes["t1"]["attention"].clone() }
    fn ack(graph: &mut Graph, attention: &Value) -> Value {
        graph.dispatch(1, "agent.seen", &json!({"event":attention["event"]})).unwrap()
    }
    fn complete(graph: &mut Graph) -> Value {
        hook(graph, "UserPromptSubmit");
        assert!(receipt(graph).is_null());
        hook(graph, "Stop");
        let attention = receipt(graph);
        assert_eq!(attention["kind"], "completed");
        assert_eq!(attention["seen"], false);
        uuid::Uuid::parse_str(attention["event"].as_str().unwrap()).unwrap();
        attention
    }

    #[test]
    fn discovery_receipts_follow_each_verified_codex_turn() {
        let mut graph = Graph::default();
        graph.add(1, "Codex".into());
        let scan = |graph: &mut Graph, id, turn_status, status, checkpoint| {
            graph.observe_agent(1, &json!({"provider":"codex","pid":12,"session_id":"one",
                "status":status,"observed_turn":{"id":id,"status":turn_status},"completion_checkpoint":checkpoint}));
        };
        scan(&mut graph, "historical", "completed", "idle", 50);
        assert!(receipt(&graph).is_null());
        scan(&mut graph, "a", "running", "busy", 50);
        scan(&mut graph, "a", "completed", "idle", 100);
        let first = receipt(&graph);
        ack(&mut graph, &first);
        let revision = graph.nodes["t1"]["activity_revision"].as_u64().unwrap();
        scan(&mut graph, "b", "completed", "idle", 200);
        let second = receipt(&graph);
        assert_eq!(second["kind"], "completed");
        assert_eq!(second["seen"], false);
        assert_ne!(second["event"], first["event"]);
        assert!(graph.nodes["t1"]["activity_revision"].as_u64().unwrap() > revision);
        ack(&mut graph, &second);
        let seen = receipt(&graph);
        scan(&mut graph, "b", "completed", "idle", 201);
        assert_eq!(receipt(&graph), seen);
        for status in ["interrupted", "failed"] {
            scan(&mut graph, "retry", status, "idle", 202);
            assert!(receipt(&graph).is_null());
            scan(&mut graph, "retry", "completed", "idle", 203);
            assert_eq!(receipt(&graph)["kind"], "completed");
        }

        graph.dispatch(1, "agent.event", &json!({"provider":"codex","event":"UserPromptSubmit","integrated":true})).unwrap();
        hook(&mut graph, "Stop");
        let from_hook = receipt(&graph);
        ack(&mut graph, &from_hook);
        let seen = receipt(&graph);
        scan(&mut graph, "hook-turn", "completed", "idle", 300);
        assert_eq!(receipt(&graph), seen);
    }

    #[test]
    fn activity_orders_reused_ids_across_moves_and_owner_adoption() {
        let mut original = graph();
        complete(&mut original);
        let clock = original.activity_clock.clone();
        let saved = original.attention_state(1).unwrap();
        let revision = |graph: &Graph| graph.nodes["t1"]["activity_revision"].as_u64().unwrap();
        let completed = revision(&original);
        original.remove(1);
        let mut other = Graph::with_activity_clock(NodeSettings::default(), clock.clone());
        other.add(1, "Restored ID".into());
        let replacement = revision(&other);
        assert!(replacement > completed);
        other.dispatch(1, "agent.event", &json!({"provider":"claude","event":"UserPromptSubmit"})).unwrap();
        assert!(revision(&other) > replacement);
        assert_eq!(other.nodes["t1"]["status"], "busy");
        assert!(receipt(&other).is_null());
        let busy = revision(&other);
        other.transfer_nodes_to(&HashSet::from([1]), &mut original);
        assert!(revision(&original) > busy);
        let next_owner = ActivityClock::default();
        next_owner.resume_after(clock.current());
        let mut adopted = Graph::with_activity_clock(NodeSettings::default(), next_owner);
        adopted.add(1, "Adopted".into());
        let shell = revision(&adopted);
        assert!(shell > revision(&original));
        adopted.restore_attention_state(1, &saved).unwrap();
        assert!(revision(&adopted) > shell);
    }

    #[test]
    fn two_readers_share_one_receipt_and_stale_or_duplicate_acks_never_notify() {
        let mut graph = graph();
        assert!(receipt(&graph).is_null(), "Initial idle is not completion");
        let first = complete(&mut graph);
        let reader_one = graph.snapshot()["nodes"][0]["attention"].clone();
        let reader_two = graph.snapshot()["nodes"][0]["attention"].clone();
        let before = graph.notification_revision();
        let acknowledged = ack(&mut graph, &reader_one);
        assert_eq!(acknowledged["attention"]["seen"], true);
        assert_ne!(graph.notification_revision(), before);
        let before = graph.notification_revision();
        assert_eq!(ack(&mut graph, &reader_two), acknowledged);
        assert_eq!(graph.notification_revision(), before);
        assert_eq!(graph.snapshot()["nodes"][0]["attention"], acknowledged["attention"]);
        let next = complete(&mut graph);
        assert_ne!(next["event"], first["event"]);
        let before = graph.notification_revision();
        assert_eq!(ack(&mut graph, &first)["attention"], next);
        assert_eq!(graph.notification_revision(), before);
        hook(&mut graph, "UserPromptSubmit");
        let before = graph.notification_revision();
        assert!(ack(&mut graph, &next)["attention"].is_null());
        assert_eq!(graph.notification_revision(), before);
    }

    #[test]
    fn receipt_is_pane_scoped_and_rejects_malformed_params() {
        let mut graph = graph();
        let attention = complete(&mut graph);
        graph.add(2, "Another pane".into());
        assert!(graph.dispatch(2, "agent.seen", &json!({"event":attention["event"]})).unwrap()["attention"].is_null());
        assert_eq!(receipt(&graph), attention);
        for params in [json!(null), json!([]), json!({}), json!({"event":null}),
            json!({"event":7}), json!({"event":""}), json!({"event":"not-a-uuid"}),
            json!({"event":attention["event"],"pane":2}), json!({"event":attention["event"],"seen":true})] {
            let before = graph.notification_revision();
            assert!(graph.dispatch(1, "agent.seen", &params).is_err(), "{params}");
            assert_eq!(receipt(&graph), attention);
            assert_eq!(graph.notification_revision(), before);
        }
    }

    #[test]
    fn waiting_completion_and_offline_follow_current_event() {
        let mut graph = graph();
        hook(&mut graph, "AwaitingInput");
        let waiting = receipt(&graph);
        assert_eq!(waiting["kind"], "waiting");
        ack(&mut graph, &waiting);
        hook(&mut graph, "PermissionRequest");
        assert_eq!(receipt(&graph)["event"], waiting["event"]);
        assert_eq!(receipt(&graph)["seen"], true);
        hook(&mut graph, "Ready");
        let completed = receipt(&graph);
        assert_eq!(completed["kind"], "completed");
        assert_ne!(completed["event"], waiting["event"]);
        assert_eq!(ack(&mut graph, &waiting)["attention"], completed);
        hook(&mut graph, "SessionEnd");
        assert_eq!(receipt(&graph), completed);
        ack(&mut graph, &completed);
        graph.observe_agent(1, &json!({"status":"offline"}));
        assert_eq!(receipt(&graph)["seen"], true);
        hook(&mut graph, "AwaitingInput");
        hook(&mut graph, "SessionEnd");
        assert!(receipt(&graph).is_null());
    }

    #[test]
    fn discovery_deduplicates_observations_and_replaces_process_identities() {
        for replacement in [json!({"pid":11}), json!({"provider":"codex"}),
            json!({"session_id":"other"}), json!({"started":"second start"})] {
            let mut graph = Graph::default();
            graph.add(1, "Agent".into());
            let mut state = json!({"provider":"pi","pid":10,"started":"first start",
                "session_id":"conversation","status":"busy"});
            graph.observe_agent(1, &state);
            state["status"] = json!("waiting");
            graph.observe_agent(1, &state);
            let first = receipt(&graph);
            ack(&mut graph, &first);
            let before = graph.notification_revision();
            graph.observe_agent(1, &state);
            assert_eq!(graph.notification_revision(), before);
            assert_eq!(receipt(&graph)["seen"], true);
            state.as_object_mut().unwrap().extend(replacement.as_object().unwrap().clone());
            graph.observe_agent(1, &state);
            let next = receipt(&graph);
            assert_eq!(next["kind"], "waiting");
            assert_ne!(next["event"], first["event"]);
            assert_eq!(ack(&mut graph, &first)["attention"], next);
            state["status"] = json!("idle");
            graph.observe_agent(1, &state);
            let completed = receipt(&graph);
            assert_eq!(completed["kind"], "completed");
            let before = graph.notification_revision();
            graph.observe_agent(1, &state);
            assert_eq!(graph.notification_revision(), before);
        }
    }

    #[test]
    fn new_hook_identity_and_reused_pane_cannot_inherit_a_receipt() {
        let mut graph = graph();
        let old = complete(&mut graph);
        hook(&mut graph, "UserPromptSubmit");
        graph.dispatch(1, "agent.event", &json!({"provider":"codex","pid":11,
            "session_id":"new","event":"SessionStart"})).unwrap();
        assert!(receipt(&graph).is_null(), "A replacement's initial idle does not complete its predecessor's turn");
        let next = complete(&mut graph);
        assert_eq!(ack(&mut graph, &old)["attention"], next);
        graph.remove(1);
        graph.add(1, "Reused pane".into());
        graph.dispatch(1, "agent.event", &json!({"provider":"pi","event":"AwaitingInput"})).unwrap();
        let reused = receipt(&graph);
        assert_ne!(reused["event"], next["event"]);
        assert_eq!(ack(&mut graph, &next)["attention"], reused);
    }

    #[test]
    fn osc_only_agents_keep_seen_across_discovery_and_clear_waiting_on_exit() {
        let mut graph = Graph::default();
        graph.add(1, "OSC agent".into());
        let report = |state| json!({"app":"pi","state":state});
        graph.observe_program_status(1, Some(&report("working")));
        graph.observe_program_status(1, Some(&report("idle")));
        let completed = receipt(&graph);
        assert_eq!(completed["kind"], "completed");
        ack(&mut graph, &completed);
        // First discovery fills identity without replacing the OSC-only agent.
        let scan = json!({"provider":"pi","pid":10,"status":"unknown"});
        graph.observe_agent(1, &scan);
        let before = graph.notification_revision();
        for _ in 0..3 {
            graph.observe_agent(1, &scan);
            graph.observe_program_status(1, Some(&report("idle")));
        }
        assert_eq!(graph.notification_revision(), before);
        assert_eq!(receipt(&graph)["event"], completed["event"]);
        assert_eq!(receipt(&graph)["seen"], true);
        graph.observe_program_status(1, None);
        assert_eq!(receipt(&graph)["event"], completed["event"]);
        graph.observe_program_status(1, Some(&report("blocked")));
        let waiting = receipt(&graph);
        assert_eq!(waiting["kind"], "waiting");
        assert_eq!(ack(&mut graph, &completed)["attention"], waiting);
        graph.observe_program_status(1, None);
        assert!(receipt(&graph).is_null());
    }

    #[test]
    fn custom_nodes_and_ordinary_programs_never_gain_attention() {
        for provider in [json!({"kind":"custom"}), json!({"provider":"adapter"}),
            json!({"kind":"custom","provider":"my-integration"})] {
            let mut graph = Graph::default();
            graph.add(1, "Custom node".into());
            let mut params = provider;
            for event in ["SessionStart", "UserPromptSubmit", "Stop", "AwaitingInput", "Ready"] {
                params["event"] = json!(event);
                graph.dispatch(1, "agent.event", &params).unwrap();
                assert!(receipt(&graph).is_null());
                assert!(graph.attention_state(1).is_none(), "Custom registration recovery is outside attention persistence");
            }
        }
        let mut graph = Graph::default();
        graph.add(1, "Build".into());
        for state in ["working", "blocked", "idle"] {
            graph.observe_program_status(1, Some(&json!({"app":"cargo","state":state})));
            assert!(receipt(&graph).is_null());
        }
    }

    #[test]
    fn replacing_an_osc_app_cannot_reuse_its_waiting_receipt() {
        let mut graph = Graph::default();
        graph.add(1, "OSC agent".into());
        graph.observe_program_status(1, Some(&json!({"app":"pi","state":"blocked"})));
        let first = receipt(&graph);
        ack(&mut graph, &first);
        graph.observe_program_status(1, Some(&json!({"app":"codex","state":"blocked"})));
        let next = receipt(&graph);
        assert_ne!(next["event"], first["event"]);
        assert_eq!(next["seen"], false);
        assert_eq!(ack(&mut graph, &first)["attention"], next);
    }

    #[test]
    fn hooks_after_a_timeout_use_the_last_live_transition() {
        for waiting in [false, true] {
            for completed in ["Stop", "Ready"] {
                let mut graph = graph();
                graph.nodes.get_mut("t1").unwrap()["transport"] = json!("inbox");
                hook(&mut graph, if waiting { "AwaitingInput" } else { "UserPromptSubmit" });
                let previous = receipt(&graph);
                if waiting { ack(&mut graph, &previous); }
                let heartbeat = graph.nodes["t1"]["heartbeat_at"].as_f64().unwrap();
                graph.expire_at(heartbeat + 16.0);
                if waiting {
                    hook(&mut graph, "AwaitingInput");
                    assert_eq!(receipt(&graph)["event"], previous["event"]);
                    assert_eq!(receipt(&graph)["seen"], true);
                }
                hook(&mut graph, completed);
                assert_eq!(receipt(&graph)["kind"], "completed");
                assert_eq!(receipt(&graph)["seen"], false);
            }
        }
    }

    #[test]
    fn checkpoint_transfer_and_public_typed_snapshot_preserve_event_and_seen() {
        for seen in [false, true] {
            let mut source = graph();
            let attention = complete(&mut source);
            if seen { ack(&mut source, &attention); }
            let attention = receipt(&source);
            let public = source.snapshot()["nodes"][0].clone();
            let typed: graffitty_protocol::graph::Node = serde_json::from_value(public).unwrap();
            assert_eq!(serde_json::to_value(typed).unwrap()["attention"], attention);
            let saved: Value = serde_json::from_slice(&serde_json::to_vec(&source.checkpoint()).unwrap()).unwrap();
            let mut restored = Graph::default();
            restored.add(2, "Restored".into());
            let mapping = HashMap::from([("t1".into(), "t2".into())]);
            restored.restore_checkpoint(&saved, &mapping).unwrap();
            assert_eq!(restored.snapshot()["nodes"][0]["attention"], attention);
            let before = restored.snapshot();
            let mut malformed = saved.clone();
            malformed["nodes"][0]["attention"]["timestamp"] = json!(1);
            assert!(restored.restore_checkpoint(&malformed, &mapping).is_err());
            assert_eq!(restored.snapshot(), before);
            let mut target = Graph::default();
            source.transfer_nodes_to(&HashSet::from([1]), &mut target);
            assert_eq!(receipt(&target), attention);
        }
    }

    #[test]
    fn live_restart_retains_busy_baseline_and_current_seen_event() {
        for event in ["Stop", "AwaitingInput", "UserPromptSubmit"] {
            for seen in [false, true] {
                let mut source = graph();
                hook(&mut source, "UserPromptSubmit");
                hook(&mut source, event);
                let old = receipt(&source);
                if seen && !old.is_null() { ack(&mut source, &old); }
                let saved: AttentionState = serde_json::from_slice(&serde_json::to_vec(&source.attention_state(1).unwrap()).unwrap()).unwrap();
                let mut target = Graph::default();
                target.add(1, "Adopted pane".into());
                target.restore_attention_state(1, &saved).unwrap();
                let expected = receipt(&source);
                assert_eq!(receipt(&target), expected);
                target.observe_agent(1, &json!({"provider":"pi","pid":10,"status":"unknown"}));
                target.dispatch(1, "agent.event", &json!({"provider":"pi","event":"SessionStart",
                    "pid":10,"session_id":"conversation","integrated":true})).unwrap();
                assert_eq!(receipt(&target), expected, "{event}");
                if event == "UserPromptSubmit" {
                    hook(&mut target, "Stop");
                    assert_eq!(receipt(&target)["kind"], "completed");
                } else {
                    let next = complete(&mut target);
                    assert_eq!(ack(&mut target, &old)["attention"], next);
                }
            }
        }
    }

    #[test]
    fn offline_heartbeat_recovery_preserves_waiting_receipts_even_through_restart() {
        for seen_before in [false, true] {
            for registration in [false, true] {
                let mut source = graph();
                source.nodes.get_mut("t1").unwrap()["transport"] = json!("inbox");
                hook(&mut source, "AwaitingInput");
                let old = receipt(&source);
                if seen_before { ack(&mut source, &old); }
                let heartbeat = source.nodes["t1"]["heartbeat_at"].as_f64().unwrap();
                source.expire_at(heartbeat + 16.0);
                assert_eq!(receipt(&source)["event"], old["event"]);
                let state = source.attention_state(1).unwrap();
                let mut target = Graph::default();
                target.add(1, "Adopted".into());
                target.restore_attention_state(1, &state).unwrap();
                assert_eq!(target.nodes["t1"]["status"], "offline");
                // A pending receipt may arrive before heartbeat recovery.
                assert_eq!(ack(&mut target, &old)["attention"]["seen"], true);
                if registration {
                    target.dispatch(1, "agent.event", &json!({"event":"SessionStart","provider":"pi",
                        "pid":10,"session_id":"conversation","transport":"inbox"})).unwrap();
                } else {
                    target.dispatch(1, "agent.heartbeat", &json!({})).unwrap();
                }
                assert_eq!(target.nodes["t1"]["status"], "waiting");
                assert_eq!(receipt(&target)["event"], old["event"]);
                assert_eq!(receipt(&target)["seen"], true);
                hook(&mut target, "SessionEnd");
                assert!(receipt(&target).is_null(), "A real end still clears waiting");
            }
        }
    }
}
