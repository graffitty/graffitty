use super::*;

fn fixture(provider: &str) -> Graph {
    let mut graph = Graph::default();
    for id in [1, 2] {
        graph.add(id, "Agent".into());
        graph.dispatch(id, "agent.event", &json!({"provider":provider,"event":"SessionStart","pid":id,"session_id":format!("session-{id}")})).unwrap();
    }
    for output in ["waiting", "error", "turn_completed"] {
        graph.dispatch(1, "graph.connect", &json!({"from":"t1","to":"t2","from_port":output})).unwrap();
    }
    graph
}

#[test]
fn every_provider_has_ordered_distinct_lifecycle_ports() {
    for provider in ["claude", "codex", "pi", "opencode"] {
        let graph = fixture(provider);
        let outputs = ports(&graph.nodes["t1"], true);
        assert_eq!(outputs.iter().map(|p| string(p, "id")).collect::<Vec<_>>(),
            ["read", "send", "turn_completed", "waiting", "error"]);
        assert_eq!(outputs[2]["color"], "#7bd88f");
        assert_eq!(outputs[3]["color"], "#ffd47a");
        assert_eq!(outputs[4]["color"], "#ff6b6b");
        assert!(outputs[..3].iter().all(|p| p["color"] != outputs[3]["color"]));
    }
}

#[test]
fn waiting_is_transition_triggered_and_errors_are_not_completions() {
    for provider in ["claude", "codex", "pi", "opencode"] {
        let mut graph = fixture(provider);
        for event in ["PermissionRequest", "AwaitingInput", "PreToolUse", "AwaitingInput"] {
            graph.dispatch(1, "agent.event", &json!({"provider":provider,"event":event})).unwrap();
        }
        assert_eq!(graph.queues["t2"].len(), 2);
        assert!(graph.queues["t2"].iter().all(|e| e["source_port"] == "waiting" && e["kind"] == "agent.waiting"));
        let failure = json!({"provider":provider,"event":"Stop","completion_id":"failed-turn","text":"API rate limit reached","outcome":"error"});
        graph.dispatch(1, "agent.event", &failure).unwrap();
        graph.dispatch(1, "agent.event", &failure).unwrap();
        assert_eq!(graph.queues["t2"].len(), 3);
        assert_eq!(graph.queues["t2"][2]["source_port"], "error");
        assert_eq!(graph.queues["t2"][2]["text"], "API rate limit reached");
        graph.dispatch(1, "agent.event", &json!({"provider":provider,"event":"Stop","outcome":"interrupted","completion_id":"interrupt","text":"partial answer"})).unwrap();
        assert_eq!(graph.queues["t2"].len(), 3, "a user interrupt notifies no output");
        assert_eq!(graph.nodes["t1"]["status"], "idle");
        assert!(graph.dispatch(1, "graph.emit", &json!({"output":"error","payload":"fake failure"})).is_err());
    }
}

#[test]
fn lifecycle_messages_obey_connection_permissions_and_revocation() {
    let mut graph = fixture("claude");
    graph.dispatch(1, "graph.disconnect", &json!({"from":"t1","to":"t2","from_port":"turn_completed","to_port":"in"})).unwrap();
    assert!(!graph.can_read("t1", "t2"));
    graph.dispatch(1, "agent.event", &json!({"provider":"claude","event":"AwaitingInput"})).unwrap();
    let event = graph.queues["t2"][0].clone();
    assert!(graph.allowed(&event));
    graph.dispatch(1, "graph.connect", &json!({"from":"t1","to":"t2","from_port":"waiting","muted":true})).unwrap();
    assert!(!graph.allowed(&event));
    assert!(graph.queues["t2"].is_empty());
    for name in ["PreToolUse", "AwaitingInput"] {
        graph.dispatch(1, "agent.event", &json!({"provider":"claude","event":name})).unwrap();
    }
    assert!(graph.queues["t2"].is_empty());
}

#[test]
fn first_codex_failure_after_empty_baseline_is_delivered() {
    let mut graph = fixture("codex");
    let mut state = json!({"provider":"codex","pid":1,"session_id":"session-1","status":"idle","observed_turn":null});
    graph.observe_agent(1, &state);
    state["observed_turn"] = json!({"id":"first","status":"failed","error":{"message":"API unavailable"}});
    graph.observe_agent(1, &state);
    assert_eq!(graph.queues["t2"].len(), 1);
    assert_eq!(graph.queues["t2"][0]["source_port"], "error");
}

#[test]
fn codex_discovery_uses_new_failed_turns_not_historical_errors_or_interrupts() {
    let mut graph = fixture("codex");
    let mut state = json!({"provider":"codex","pid":1,"session_id":"session-1","status":"idle",
        "observed_turn":{"id":"old","status":"failed","error":{"message":"Old error"}}});
    graph.observe_agent(1, &state);
    assert!(graph.queues.values().all(Vec::is_empty));
    state["observed_turn"] = json!({"id":"interrupted","status":"interrupted"});
    graph.observe_agent(1, &state);
    assert!(graph.queues.values().all(Vec::is_empty));
    state["observed_turn"] = json!({"id":"new","status":"failed","error":{"message":"Quota exceeded"}});
    graph.observe_agent(1, &state);
    graph.observe_agent(1, &state);
    assert_eq!(graph.queues["t2"].len(), 1);
    assert_eq!(graph.queues["t2"][0]["source_port"], "error");
    assert_eq!(graph.queues["t2"][0]["text"], "Quota exceeded");
    state["status"] = json!("waiting");
    graph.observe_agent(1, &state);
    graph.observe_agent(1, &state);
    assert_eq!(graph.queues["t2"].len(), 2);
    assert_eq!(graph.queues["t2"][1]["source_port"], "waiting");
}

#[test]
fn background_session_speaks_only_for_its_own_pane() {
    let mut graph = fixture("claude");
    // The daemon was started from pane 1, so pane 2's forked conversation
    // reports through pane 1 as well.
    let event = |name: &str, session: &str, parent: &str| json!({"provider":"claude","event":name,"session_id":session,"detached":true,"parent_session_id":parent});
    assert!(graph.dispatch(1, "agent.event", &event("UserPromptSubmit", "fork-of-2", "session-2")).is_err());
    assert_eq!(graph.nodes["t1"]["session_id"], "session-1");
    assert_eq!(graph.nodes["t1"]["status"], "idle", "Another pane's conversation leaves this agent's status alone");
    // Pane 1's own conversation moves to the daemon and keeps speaking for it.
    graph.dispatch(1, "agent.event", &event("SessionStart", "fork-of-1", "session-1")).unwrap();
    assert_eq!(graph.nodes["t1"]["session_id"], "fork-of-1");
    graph.dispatch(1, "agent.event", &event("UserPromptSubmit", "fork-of-1", "session-1")).unwrap();
    assert_eq!(graph.nodes["t1"]["status"], "busy");
    assert!(graph.dispatch(1, "agent.event", &event("Stop", "fork-of-2", "session-2")).is_err());
    assert_eq!(graph.nodes["t1"]["status"], "busy");
    // A pane with no conversation yet takes the first one that reports.
    graph.add(3, "Agent".into());
    graph.dispatch(3, "agent.event", &json!({"provider":"claude","event":"SessionStart","pid":3,"session_id":"fresh","detached":true,"parent_session_id":null})).unwrap();
    assert_eq!(graph.nodes["t3"]["session_id"], "fresh");
}


#[test]
fn integrated_codex_quota_failure_and_retry_update_status_and_wires_once() {
    let mut graph = fixture("codex");
    let prompt = json!({"provider":"codex","event":"UserPromptSubmit","integrated":true});
    let mut scan = json!({"provider":"codex","pid":1,"session_id":"session-1","status":"busy",
        "observed_turn":{"id":"turn-a","status":"inProgress"}});
    graph.dispatch(1, "agent.event", &prompt).unwrap();
    graph.observe_agent(1, &scan);
    scan["status"] = json!("idle");
    scan["observed_turn"] = json!({"id":"turn-a","status":"failed","error":{"message":"Quota exceeded"}});
    graph.observe_agent(1, &scan);
    assert_eq!(graph.nodes["t1"]["status"], "idle");
    assert!(graph.nodes["t1"]["attention"].is_null());
    graph.dispatch(1, "agent.event", &prompt).unwrap();
    graph.observe_agent(1, &scan);
    assert_eq!(graph.nodes["t1"]["status"], "busy", "a repeated failed poll cannot undo retry");
    scan["status"] = json!("busy");
    scan["observed_turn"] = json!({"id":"turn-c","status":"inProgress"});
    scan["failed_turns"] = json!([{"id":"turn-b","status":"failed","error":{"message":"Retry failed"}}]);
    graph.observe_agent(1, &scan);
    graph.observe_agent(1, &scan);
    assert_eq!(graph.nodes["t1"]["status"], "busy");
    graph.dispatch(1, "agent.event", &json!({"provider":"codex","event":"Stop","completion_id":"turn-c","text":"Done"})).unwrap();
    assert_eq!(graph.nodes["t1"]["attention"]["kind"], "completed");
    let events = &graph.queues["t2"];
    assert_eq!(events.iter().map(|e| string(e, "source_port")).collect::<Vec<_>>(), ["error","error","turn_completed"]);
    assert_eq!(events[0]["payload"]["turn_id"], "turn-a");
    assert_eq!(events[1]["payload"]["turn_id"], "turn-b");
}

#[test]
fn discovery_only_failure_clears_completion_and_retry_returns_to_work() {
    let mut graph = fixture("codex");
    let mut scan = json!({"provider":"codex","pid":1,"session_id":"session-1","status":"busy",
        "observed_turn":{"id":"first","status":"inProgress"}});
    graph.observe_agent(1, &scan);
    scan["status"] = json!("idle");
    scan["observed_turn"]["status"] = json!("failed");
    graph.observe_agent(1, &scan);
    assert!(graph.nodes["t1"]["attention"].is_null());
    scan["status"] = json!("busy");
    scan["observed_turn"] = json!({"id":"retry","status":"inProgress"});
    graph.observe_agent(1, &scan);
    assert_eq!(graph.nodes["t1"]["status"], "busy");
    scan["status"] = json!("idle");
    scan["observed_turn"]["status"] = json!("completed");
    graph.observe_agent(1, &scan);
    assert_eq!(graph.nodes["t1"]["attention"]["kind"], "completed");
    assert_eq!(graph.queues["t2"].len(), 1);
    assert_eq!(graph.queues["t2"][0]["source_port"], "error");
}

#[test]
fn claude_login_prompt_and_hook_emit_one_waiting_event_in_either_order() {
    let blocked = json!({"app":"claude-code","state":"blocked","msg":"Login expired"});
    let hook = json!({"provider":"claude","event":"AwaitingInput","outcome":"error","text":"Login expired"});
    for osc_first in [false, true] {
        let mut graph = fixture("claude");
        for turn in 1..=2 {
            graph.dispatch(1, "agent.event", &json!({"provider":"claude","event":"UserPromptSubmit","integrated":true})).unwrap();
            graph.observe_program_status(1, Some(&json!({"app":"claude-code","state":"working"})));
            if osc_first { graph.observe_program_status(1, Some(&blocked)); }
            graph.dispatch(1, "agent.event", &hook).unwrap();
            graph.observe_program_status(1, Some(&blocked));
            graph.observe_agent(1, &json!({"provider":"claude","pid":1,"session_id":"session-1","status":"busy"}));
            assert_eq!(graph.nodes["t1"]["status"], "waiting");
            assert_eq!(graph.queues["t2"].iter().filter(|e| e["source_port"] == "waiting").count(), turn);
            assert_eq!(graph.queues["t2"].iter().filter(|e| e["source_port"] == "error").count(), turn);
        }
    }
}


#[test]
fn codex_prompt_id_keeps_a_newer_hook_busy_during_an_older_failure_poll() {
    let mut graph = fixture("codex");
    let prompt = |id| json!({"provider":"codex","event":"UserPromptSubmit","integrated":true,"turn_id":id});
    graph.dispatch(1, "agent.event", &prompt("a")).unwrap();
    let mut scan = json!({"provider":"codex","session_id":"session-1","pid":1,"status":"busy",
        "observed_turn":{"id":"a","status":"inProgress"}});
    graph.observe_agent(1, &scan);
    graph.dispatch(1, "agent.event", &prompt("b")).unwrap();
    scan["status"] = json!("idle");
    scan["observed_turn"]["status"] = json!("failed");
    graph.observe_agent(1, &scan);
    assert_eq!(graph.nodes["t1"]["status"], "busy");
    assert_eq!(graph.queues["t2"][0]["payload"]["turn_id"], "a");
    scan["observed_turn"]["id"] = json!("b");
    graph.observe_agent(1, &scan);
    assert_eq!(graph.nodes["t1"]["status"], "idle");
    assert_eq!(graph.queues["t2"].len(), 2);
}
