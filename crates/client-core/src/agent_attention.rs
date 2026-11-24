//! Tab markers project server-owned attention and pending read receipts.
//!
//! Only a current graph node can be read. Receipts survive looking away and
//! reconnect gaps and presentation remaps until server evidence settles them.
use graffitty_protocol::agent_attention::{AgentAttention as ServerAttention, AttentionKind};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Marker {
    Completed,
    Waiting,
}

#[derive(Default, Debug)]
struct Pane {
    attention: Option<ServerAttention>,
    /// A heartbeat timeout hides waiting presentation without changing the receipt.
    offline: bool,
    /// Missing or invalid nodes preserve the projection, but cannot authorize a receipt.
    current: bool,
}

#[derive(Default, Debug)]
pub struct AgentAttention {
    panes: BTreeMap<String, Pane>,
    /// Event UUIDs outlive presentation-local pane keys and session switches.
    pending: HashSet<String>,
}

impl AgentAttention {
    /// Apply one graph view. `nodes` maps pane keys to public graph nodes;
    /// `visible` panes are currently in front of the user; `live` lists every
    /// currently tracked pane, including away-session catalog nodes. Dropping
    /// a key removes its presentation, never its unconfirmed receipt.
    /// Returns whether a marker changed.
    pub fn observe(&mut self, nodes: &Value, visible: &HashSet<String>, live: &HashSet<String>) -> bool {
        let before = self.snapshot();
        self.panes.retain(|key, _| live.contains(key));
        // Inspect the whole view before replacing keys: an old event may have
        // moved to another local key in this same observation.
        let current: BTreeMap<_, _> = live.iter().filter_map(|key| {
            let node = nodes.get(key).filter(|node| node.is_object())?;
            let attention = serde_json::from_value::<Option<ServerAttention>>(node["attention"].clone()).ok()?;
            Some((key, attention))
        }).collect();
        let current_events: HashSet<_> = current.values().flatten().map(|attention| attention.event.as_str()).collect();
        for key in live {
            let pane = self.panes.entry(key.clone()).or_default();
            pane.current = false;
            // Absent/null means no event. Malformed data is not evidence to
            // read or acknowledge a remembered event during graph repair.
            let Some(attention) = current.get(key) else { continue; };
            if let Some(previous) = pane.attention.as_ref()
                && !current_events.contains(previous.event.as_str()) {
                // A current node replaced/removed this event; a missing
                // presentation or a key remap alone cannot settle a receipt.
                self.pending.remove(&previous.event);
            }
            pane.attention = attention.clone();
            pane.offline = nodes[key]["status"].as_str() == Some("offline");
            pane.current = true;
            if let Some(attention) = attention.as_ref()
                && !attention.seen && visible.contains(key)
                && !self.pending.contains(&attention.event) {
                self.pending.insert(attention.event.clone());
            }
        }
        for attention in current.values().flatten().filter(|attention| attention.seen) {
            self.confirm(&attention.event);
        }
        self.snapshot() != before
    }

    fn snapshot(&self) -> Vec<(String, Marker)> {
        self.panes.keys().filter_map(|key| self.pane(key).map(|marker| (key.clone(), marker))).collect()
    }

    /// Server attention with a matching pending local receipt applied.
    pub fn attention(&self, key: &str) -> Value {
        json!(self.panes.get(key).and_then(|pane| pane.attention.as_ref()).map(|attention| self.effective(attention)))
    }

    fn effective(&self, attention: &ServerAttention) -> ServerAttention {
        let mut attention = attention.clone();
        attention.seen |= self.pending.contains(&attention.event);
        attention
    }

    fn confirm(&mut self, event: &str) {
        self.pending.remove(event);
        // An away catalog receipt also settles any cached presentation of the
        // same event; removing pending must not revive that cached marker.
        for pane in self.panes.values_mut() {
            if let Some(attention) = pane.attention.as_mut()
                && attention.event == event {
                attention.seen = true;
            }
        }
    }

    /// Project an arbitrary server attention field, such as an away-session
    /// row. A server receipt settles its UUID; projection never creates a read.
    /// Null or malformed input returns null without discarding pending tokens.
    pub fn project_attention(&mut self, value: &Value) -> Value {
        let Ok(Some(attention)) = serde_json::from_value::<Option<ServerAttention>>(value.clone()) else { return Value::Null; };
        if attention.seen { self.confirm(&attention.event); }
        json!(self.effective(&attention))
    }

    /// Retryable receipts for current, matching, unread server events only.
    /// Reading this queue never consumes it; only server evidence settles it.
    pub fn acknowledgements(&self) -> Value {
        Value::Array(self.panes.iter().filter_map(|(key, pane)| {
            let attention = pane.attention.as_ref()?;
            (pane.current && !attention.seen && self.pending.contains(&attention.event))
                .then(|| json!({"key":key, "event":attention.event}))
        }).collect())
    }

    pub fn pane(&self, key: &str) -> Option<Marker> {
        let pane = self.panes.get(key)?;
        let attention = pane.attention.as_ref()?;
        if attention.seen || self.pending.contains(&attention.event)
            || (pane.offline && attention.kind == AttentionKind::Waiting) { return None; }
        Some(match attention.kind {
            AttentionKind::Completed => Marker::Completed,
            AttentionKind::Waiting => Marker::Waiting,
        })
    }

    /// A tab shows one marker: waiting wins over completed, and the count is
    /// how many of its panes are in that state.
    pub fn marker<'a>(&self, keys: impl IntoIterator<Item = &'a str>) -> Value {
        let (mut waiting, mut completed) = (0, 0);
        for key in keys {
            match self.pane(key) {
                Some(Marker::Waiting) => waiting += 1,
                Some(Marker::Completed) => completed += 1,
                None => {}
            }
        }
        if waiting > 0 { json!({"state":"waiting","count":waiting}) }
        else if completed > 0 { json!({"state":"completed","count":completed}) }
        else { json!({"state":"","count":0}) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIRST: &str = "00000000-0000-4000-8000-000000000001";
    const SECOND: &str = "00000000-0000-4000-8000-000000000002";
    const THIRD: &str = "00000000-0000-4000-8000-000000000003";
    const FOURTH: &str = "00000000-0000-4000-8000-000000000004";

    fn set(keys: &[&str]) -> HashSet<String> { keys.iter().map(|k| k.to_string()).collect() }
    fn event(event: &str, kind: &str, seen: bool) -> Value {
        json!({"event":event, "kind":kind, "seen":seen})
    }
    fn node(event: &str, kind: &str, seen: bool) -> Value {
        json!({"provider":"claude", "attention":self::event(event, kind, seen)})
    }
    fn view(panes: &[(&str, Value)]) -> Value {
        Value::Object(panes.iter().map(|(k, v)| (k.to_string(), v.clone())).collect())
    }

    #[test]
    fn two_clients_clear_after_a_shared_server_receipt() {
        let (mut a, mut b) = (AgentAttention::default(), AgentAttention::default());
        let live = set(&["t1"]);
        let nodes = view(&[("t1", node(FIRST, "completed", false))]);
        for client in [&mut a, &mut b] {
            assert!(client.observe(&nodes, &set(&[]), &live));
            assert_eq!(client.marker(["t1"]), json!({"state":"completed","count":1}));
        }
        assert!(a.observe(&nodes, &live, &live));
        assert_eq!(a.attention("t1"), event(FIRST, "completed", true));
        assert_eq!(a.acknowledgements(), json!([{"key":"t1","event":FIRST}]));
        assert_eq!(b.pane("t1"), Some(Marker::Completed));
        let seen = view(&[("t1", node(FIRST, "completed", true))]);
        assert!(!a.observe(&seen, &set(&[]), &live), "optimistic marker already cleared");
        assert!(b.observe(&seen, &set(&[]), &live));
        for client in [&a, &b] {
            assert_eq!(client.pane("t1"), None);
            assert_eq!(client.attention("t1"), event(FIRST, "completed", true));
            assert_eq!(client.acknowledgements(), json!([]));
        }
    }

    #[test]
    fn visible_event_is_read_on_first_observation_and_retries_after_looking_away() {
        let mut a = AgentAttention::default();
        let live = set(&["t1"]);
        let nodes = view(&[("t1", node(FIRST, "waiting", false))]);
        assert!(!a.observe(&nodes, &live, &live));
        assert_eq!(a.pane("t1"), None);
        let receipt = json!([{"key":"t1","event":FIRST}]);
        assert_eq!(a.acknowledgements(), receipt);
        assert!(!a.observe(&nodes, &set(&[]), &live));
        assert_eq!(a.acknowledgements(), receipt, "sending is not confirmation");
        assert_eq!(a.attention("t1"), event(FIRST, "waiting", true));
    }

    #[test]
    fn pending_survives_a_transport_gap_without_sending_until_matching_node_returns() {
        let mut a = AgentAttention::default();
        let live = set(&["t1"]);
        let nodes = view(&[("t1", node(FIRST, "completed", false))]);
        a.observe(&nodes, &live, &live);
        a.observe(&json!({}), &set(&[]), &live);
        assert_eq!(a.acknowledgements(), json!([]));
        assert_eq!(a.attention("t1"), event(FIRST, "completed", true));
        a.observe(&nodes, &set(&[]), &live);
        assert_eq!(a.acknowledgements(), json!([{"key":"t1","event":FIRST}]));
        assert_eq!(a.pane("t1"), None);
    }

    #[test]
    fn heartbeat_timeout_hides_waiting_but_preserves_pending_receipt_through_recovery() {
        let mut a = AgentAttention::default();
        let live = set(&["t1"]);
        let mut nodes = view(&[("t1", node(FIRST, "waiting", false))]);
        nodes["t1"]["status"] = "waiting".into();
        a.observe(&nodes, &set(&[]), &live);
        assert_eq!(a.pane("t1"), Some(Marker::Waiting));
        a.observe(&nodes, &live, &live);
        let receipt = json!([{"key":"t1","event":FIRST}]);
        assert_eq!(a.acknowledgements(), receipt);
        nodes["t1"]["status"] = "offline".into();
        assert!(!a.observe(&nodes, &set(&[]), &live));
        assert_eq!(a.pane("t1"), None);
        assert_eq!(a.attention("t1"), event(FIRST, "waiting", true));
        assert_eq!(a.acknowledgements(), receipt, "timeout still permits matching receipt retries");
        nodes["t1"]["status"] = "waiting".into();
        assert!(!a.observe(&nodes, &set(&[]), &live));
        assert_eq!(a.pane("t1"), None, "recovery cannot rearm a locally read event");
        assert_eq!(a.acknowledgements(), receipt);
        nodes["t1"]["attention"]["seen"] = true.into();
        a.observe(&nodes, &set(&[]), &live);
        assert_eq!(a.acknowledgements(), json!([]));
        for status in ["offline", "waiting"] {
            nodes["t1"]["status"] = status.into();
            assert!(!a.observe(&nodes, &set(&[]), &live));
            assert_eq!(a.pane("t1"), None, "server receipt also survives heartbeat recovery");
        }
    }

    #[test]
    fn offline_hides_only_waiting_presentation_and_still_allows_reading_current_events() {
        let mut a = AgentAttention::default();
        let live = set(&["t1", "t2"]);
        let mut nodes = view(&[("t1", node(FIRST, "waiting", false)), ("t2", node(SECOND, "completed", false))]);
        a.observe(&nodes, &set(&[]), &live);
        nodes["t1"]["status"] = "offline".into();
        nodes["t2"]["status"] = "offline".into();
        assert!(a.observe(&nodes, &set(&[]), &live));
        assert_eq!(a.marker(["t1", "t2"]), json!({"state":"completed","count":1}));
        assert_eq!(a.attention("t1"), event(FIRST, "waiting", false), "offline does not alter server attention");
        a.observe(&nodes, &set(&["t1"]), &live);
        assert_eq!(a.acknowledgements(), json!([{"key":"t1","event":FIRST}]));
        nodes["t1"]["status"] = "waiting".into();
        a.observe(&nodes, &set(&[]), &live);
        assert_eq!(a.pane("t1"), None);
    }

    #[test]
    fn visibility_without_current_node_evidence_cannot_read_a_remembered_event() {
        let mut a = AgentAttention::default();
        let live = set(&["t1"]);
        let nodes = view(&[("t1", node(FIRST, "completed", false))]);
        a.observe(&nodes, &set(&[]), &live);
        assert!(!a.observe(&json!({}), &live, &live));
        assert_eq!(a.pane("t1"), Some(Marker::Completed));
        assert_eq!(a.attention("t1"), event(FIRST, "completed", false));
        assert_eq!(a.acknowledgements(), json!([]));
        a.observe(&nodes, &set(&[]), &live);
        assert_eq!(a.pane("t1"), Some(Marker::Completed));
        assert_eq!(a.acknowledgements(), json!([]));
    }

    #[test]
    fn stale_pending_never_reads_or_acknowledges_a_newer_event() {
        let mut a = AgentAttention::default();
        let live = set(&["t1"]);
        a.observe(&view(&[("t1", node(FIRST, "completed", false))]), &live, &live);
        a.observe(&json!({}), &set(&[]), &live);
        let newer = view(&[("t1", node(SECOND, "completed", false))]);
        assert!(a.observe(&newer, &set(&[]), &live));
        assert_eq!(a.pane("t1"), Some(Marker::Completed));
        assert_eq!(a.attention("t1"), event(SECOND, "completed", false));
        assert_eq!(a.acknowledgements(), json!([]));
        a.observe(&newer, &live, &live);
        assert_eq!(a.acknowledgements(), json!([{"key":"t1","event":SECOND}]));
    }

    #[test]
    fn waiting_priority_and_counts_require_reading_each_pane() {
        let mut a = AgentAttention::default();
        let live = set(&["t1", "t2", "t3", "t4"]);
        let nodes = view(&[("t1", node(FIRST, "completed", false)),
            ("t2", node(SECOND, "completed", false)), ("t3", node(THIRD, "waiting", false)),
            ("t4", node(FOURTH, "waiting", false))]);
        let tab = ["t1", "t2", "t3", "t4"];
        a.observe(&nodes, &set(&[]), &live);
        assert_eq!(a.marker(tab), json!({"state":"waiting","count":2}));
        a.observe(&nodes, &set(&["t3", "t4"]), &live);
        assert_eq!(a.marker(tab), json!({"state":"completed","count":2}));
        assert_eq!(a.acknowledgements(), json!([{"key":"t3","event":THIRD}, {"key":"t4","event":FOURTH}]));
        a.observe(&nodes, &set(&["t1"]), &live);
        assert_eq!(a.marker(tab), json!({"state":"completed","count":1}));
        a.observe(&nodes, &set(&["t2"]), &live);
        assert_eq!(a.marker(tab), json!({"state":"","count":0}));
        assert_eq!(a.acknowledgements().as_array().unwrap().len(), 4);
    }

    #[test]
    fn dropping_presentation_preserves_pending_until_same_event_returns_at_a_new_key() {
        let mut a = AgentAttention::default();
        let nodes = view(&[("t1", node(FIRST, "completed", false)), ("t2", node(SECOND, "waiting", false))]);
        a.observe(&nodes, &set(&["t1"]), &set(&["t1", "t2"]));
        assert!(a.observe(&nodes, &set(&[]), &set(&[])));
        assert_eq!(a.acknowledgements(), json!([]));
        assert_eq!(a.attention("t1"), Value::Null);
        assert_eq!(a.attention("t2"), Value::Null);
        assert_eq!(a.project_attention(&event(FIRST, "completed", false)), event(FIRST, "completed", true));
        let remapped = view(&[("t9", node(FIRST, "completed", false))]);
        // A visible pane without current node evidence cannot send anything.
        a.observe(&json!({}), &set(&["t9"]), &set(&["t9"]));
        assert_eq!(a.acknowledgements(), json!([]));
        a.observe(&remapped, &set(&[]), &set(&["t9"]));
        assert_eq!(a.pane("t9"), None);
        assert_eq!(a.attention("t9"), event(FIRST, "completed", true));
        assert_eq!(a.acknowledgements(), json!([{"key":"t9","event":FIRST}]));
        let confirmed = view(&[("t9", node(FIRST, "completed", true))]);
        a.observe(&confirmed, &set(&[]), &set(&["t9"]));
        assert_eq!(a.acknowledgements(), json!([]));
        assert!(a.pending.is_empty(), "the server receipt settles the independent token");
    }

    #[test]
    fn simultaneous_remap_and_key_replacement_preserve_only_the_matching_read() {
        let mut a = AgentAttention::default();
        a.observe(&view(&[("t1", node(FIRST, "completed", false))]), &set(&["t1"]), &set(&["t1"]));
        let nodes = view(&[("t1", node(SECOND, "completed", false)), ("t2", node(FIRST, "completed", false))]);
        a.observe(&nodes, &set(&[]), &set(&["t1", "t2"]));
        assert_eq!(a.pane("t1"), Some(Marker::Completed));
        assert_eq!(a.attention("t1"), event(SECOND, "completed", false));
        assert_eq!(a.pane("t2"), None);
        assert_eq!(a.acknowledgements(), json!([{"key":"t2","event":FIRST}]));
        // A true replacement at the current key settles the old token.
        let replaced = view(&[("t1", node(SECOND, "completed", false)), ("t2", node(THIRD, "waiting", false))]);
        a.observe(&replaced, &set(&[]), &set(&["t1", "t2"]));
        assert_eq!(a.acknowledgements(), json!([]));
        assert_eq!(a.project_attention(&event(FIRST, "completed", false)), event(FIRST, "completed", false));
        assert_eq!(a.pane("t2"), Some(Marker::Waiting));
    }

    #[test]
    fn detached_old_token_and_its_confirmation_cannot_read_a_new_event() {
        let mut a = AgentAttention::default();
        a.observe(&view(&[("t1", node(FIRST, "completed", false))]), &set(&["t1"]), &set(&["t1"]));
        a.observe(&json!({}), &set(&[]), &set(&[]));
        let newer = view(&[("t9", node(SECOND, "completed", false))]);
        a.observe(&newer, &set(&[]), &set(&["t9"]));
        assert_eq!(a.pane("t9"), Some(Marker::Completed));
        assert_eq!(a.acknowledgements(), json!([]));
        a.project_attention(&event(FIRST, "completed", true));
        assert_eq!(a.attention("t9"), event(SECOND, "completed", false));
        assert_eq!(a.pane("t9"), Some(Marker::Completed));
        assert_eq!(a.acknowledgements(), json!([]));
    }

    #[test]
    fn away_projection_never_creates_receipts_and_confirms_matching_cached_presentations() {
        let mut a = AgentAttention::default();
        assert_eq!(a.project_attention(&event(FIRST, "waiting", false)), event(FIRST, "waiting", false));
        assert!(a.pending.is_empty());
        let nodes = view(&[("t1", node(FIRST, "waiting", false))]);
        for _ in 0..10 {
            a.observe(&nodes, &set(&["t1"]), &set(&["t1"]));
        }
        assert_eq!(a.pending.len(), 1, "one receipt per actual event, not per rendered frame");
        assert_eq!(a.project_attention(&event(FIRST, "waiting", false)), event(FIRST, "waiting", true));
        assert_eq!(a.project_attention(&event(SECOND, "completed", false)), event(SECOND, "completed", false));
        assert_eq!(a.project_attention(&Value::Null), Value::Null);
        assert_eq!(a.project_attention(&json!({"event":FIRST})), Value::Null);
        assert_eq!(a.pending.len(), 1, "absent/malformed away rows cannot erase pending reads");
        a.observe(&json!({}), &set(&[]), &set(&["t1"]));
        assert_eq!(a.acknowledgements(), json!([]));
        assert_eq!(a.project_attention(&event(FIRST, "waiting", true)), event(FIRST, "waiting", true));
        assert!(a.pending.is_empty());
        assert_eq!(a.attention("t1"), event(FIRST, "waiting", true));
        assert_eq!(a.pane("t1"), None, "confirming an away row cannot revive a cached marker");
    }

    #[test]
    fn explicit_no_event_discards_pending_and_history_never_creates_unread() {
        for absent in [json!({}), json!({"attention":null})] {
            let mut a = AgentAttention::default();
            let live = set(&["t1"]);
            let nodes = view(&[("t1", node(FIRST, "completed", false))]);
            a.observe(&nodes, &live, &live);
            a.observe(&view(&[("t1", absent)]), &set(&[]), &live);
            assert_eq!(a.attention("t1"), Value::Null);
            assert_eq!(a.acknowledgements(), json!([]));
            // A later event cannot inherit the discarded local receipt.
            a.observe(&nodes, &set(&[]), &live);
            assert_eq!(a.pane("t1"), Some(Marker::Completed));
        }
        let mut a = AgentAttention::default();
        for status in ["busy", "idle", "waiting", "idle"] {
            let nodes = json!({"t1":{"provider":"claude", "status":status, "status_history":[
                {"at":"2030-01-01T00:00:01Z","status":"busy"},
                {"at":"2030-01-01T00:00:02Z","status":"idle"}]}});
            a.observe(&nodes, &set(&[]), &set(&["t1"]));
            assert_eq!(a.pane("t1"), None);
            assert_eq!(a.attention("t1"), Value::Null);
            assert_eq!(a.acknowledgements(), json!([]));
        }
    }

    #[test]
    fn already_read_events_do_not_mark_or_queue_receipts() {
        let mut a = AgentAttention::default();
        let live = set(&["t1", "t2"]);
        let nodes = view(&[("t1", node(FIRST, "completed", true)), ("t2", node(SECOND, "waiting", true))]);
        for visible in [set(&[]), live.clone()] {
            assert!(!a.observe(&nodes, &visible, &live));
            assert_eq!(a.marker(["t1", "t2"]), json!({"state":"","count":0}));
            assert_eq!(a.acknowledgements(), json!([]));
        }
        assert_eq!(a.attention("%missing"), Value::Null);
    }

    #[test]
    fn osc_only_agents_project_the_server_field_without_provider_or_status_inference() {
        let mut a = AgentAttention::default();
        let nodes = json!({"t1":{"provider":"shell", "status":"unknown", "program":{"app":"pi", "state":"done"},
            "attention":event(FIRST, "completed", false)}});
        a.observe(&nodes, &set(&[]), &set(&["t1"]));
        assert_eq!(a.pane("t1"), Some(Marker::Completed));
        a.observe(&nodes, &set(&["t1"]), &set(&["t1"]));
        assert_eq!(a.acknowledgements(), json!([{"key":"t1","event":FIRST}]));
    }

    #[test]
    fn malformed_nodes_cannot_authorize_a_read_or_retry() {
        let live = set(&["t1"]);
        let valid = view(&[("t1", node(FIRST, "completed", false))]);
        for bad in [Value::Null, json!(7), json!({"attention":{"event":FIRST, "kind":"completed"}}),
            json!({"attention":{"event":FIRST, "kind":"idle", "seen":false}})] {
            let mut a = AgentAttention::default();
            a.observe(&valid, &set(&[]), &live);
            a.observe(&view(&[("t1", bad.clone())]), &live, &live);
            assert_eq!(a.pane("t1"), Some(Marker::Completed));
            assert_eq!(a.acknowledgements(), json!([]));
            a.observe(&valid, &live, &live);
            a.observe(&view(&[("t1", bad)]), &set(&[]), &live);
            assert_eq!(a.acknowledgements(), json!([]));
            a.observe(&valid, &set(&[]), &live);
            assert_eq!(a.acknowledgements(), json!([{"key":"t1","event":FIRST}]));
        }
    }
}
