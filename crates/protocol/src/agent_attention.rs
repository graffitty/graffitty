//! Server-owned agent attention. Readers acknowledge the opaque event token;
//! neither pane identifiers nor client clocks identify an attention event.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttentionKind {
    Completed,
    Waiting,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentAttention {
    /// A fresh UUID for each event, preserved until that event is replaced.
    pub event: String,
    pub kind: AttentionKind,
    pub seen: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn attention_has_one_strict_wire_shape() {
        for kind in [AttentionKind::Completed, AttentionKind::Waiting] {
            let attention = AgentAttention {
                event: "23b9956a-0448-4c23-89ac-d7238491b608".into(), kind, seen: false,
            };
            let value = serde_json::to_value(&attention).unwrap();
            assert_eq!(value["kind"], if kind == AttentionKind::Completed { "completed" } else { "waiting" });
            assert_eq!(serde_json::from_value::<AgentAttention>(value.clone()).unwrap(), attention);
            for field in ["event", "kind", "seen"] {
                let mut missing = value.clone();
                missing.as_object_mut().unwrap().remove(field);
                assert!(serde_json::from_value::<AgentAttention>(missing).is_err());
            }
            for (field, invalid) in [("seen", json!(1)), ("event", json!(null)),
                ("kind", json!("Completed")), ("timestamp", json!(0))] {
                let mut malformed = value.clone();
                malformed[field] = invalid;
                assert!(serde_json::from_value::<AgentAttention>(malformed).is_err());
            }
        }
    }
}
