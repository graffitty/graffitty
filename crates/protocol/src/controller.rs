//! Explicit server control over an already authenticated connection. Pane-token
//! RPC keeps its own scope; this capability is held by the attached client.
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const METHODS: &[&str] = &[
    "agent.seen",
    "internal.terminal.demo_type",
    "terminal.press",
    "terminal.put",
    "terminal.get_text",
    "terminal.pid",
    "pane.list",
    "pane.send",
];

pub fn valid_alias(alias: &str) -> bool {
    !alias.is_empty()
        && alias.len() <= 64
        && alias.as_bytes()[0].is_ascii_alphanumeric()
        && alias
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
}

/// A slash always denotes an explicit server. Never fall back to a local pane
/// when the prefix is malformed or cannot be resolved.
pub fn split_target(target: &str) -> Result<Option<(&str, &str)>, &'static str> {
    let Some((alias, pane)) = target.split_once('/') else {
        return Ok(None);
    };
    if !valid_alias(alias) || pane.contains('/') {
        return Err("Use server-alias/tN or server-alias/session:tab.pane");
    }
    Ok(Some((alias, pane)))
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub version: u64,
    pub method: String,
    pub params: Value,
}
impl Request {
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.version != super::VERSION {
            return Err("Unsupported controller protocol");
        }
        if !METHODS.contains(&self.method.as_str()) {
            return Err("Method is not available through server control");
        }
        if !self.params.is_object() {
            return Err("Expected object params");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn agent_receipts_use_the_current_controller_envelope() {
        let value = serde_json::json!({"version":1,"method":"agent.seen",
            "params":{"target":"t2","event":"23b9956a-0448-4c23-89ac-d7238491b608"}});
        let request: Request = serde_json::from_value(value.clone()).unwrap();
        request.validate().unwrap();
        for (field, invalid) in [("version", serde_json::json!(2)),
            ("method", serde_json::json!("agent.mark_seen")), ("params", serde_json::json!([]))] {
            let mut bad = value.clone();
            bad[field] = invalid;
            let request: Request = serde_json::from_value(bad).unwrap();
            assert!(request.validate().is_err());
        }
    }
    #[test]
    fn remote_prefix_is_explicit_and_exact() {
        assert_eq!(split_target("t12"), Ok(None));
        assert_eq!(split_target("project:1.2"), Ok(None));
        assert_eq!(split_target("Build/t12"), Ok(Some(("Build", "t12"))));
        assert_eq!(
            split_target("build/project:1.2"),
            Ok(Some(("build", "project:1.2")))
        );
        assert_eq!(split_target("build/"), Ok(Some(("build", ""))));
        for target in [
            "/t12",
            "../t12",
            "host:7183/t12",
            "build/a/t12",
            "-build/t12",
        ] {
            assert!(split_target(target).is_err(), "{target}");
        }
    }
}
