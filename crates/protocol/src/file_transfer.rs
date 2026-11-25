//! One bounded upload format for CLI, desktop and mobile terminal attachments.
use serde::{Deserialize, Serialize};

pub const MAX_BYTES: usize = 32 * 1024 * 1024;
pub const MAX_CHUNK_BYTES: usize = 1024 * 1024;
// Upload RPCs are text messages. Reserve the normal command budget for metadata.
pub const MAX_UPLOAD_MESSAGE: usize = MAX_CHUNK_BYTES.div_ceil(3) * 4 + crate::MAX_COMMAND_PACKET;

/// Only the encoded data field of an upload may exceed the ordinary command budget.
pub fn fits_command(message: &serde_json::Value, length: usize) -> bool {
    if length <= crate::MAX_COMMAND_PACKET { return true; }
    let call = match message["type"].as_str() {
        Some("rpc") => message,
        Some("controller_rpc") => &message["call"],
        _ => return false,
    };
    call["method"] == "terminal.put" && call["params"]["upload"]["data"].as_str().is_some_and(|data|
        data.len() <= MAX_CHUNK_BYTES.div_ceil(3) * 4 && length.saturating_sub(data.len()) <= crate::MAX_COMMAND_PACKET)
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Chunk {
    pub id: String,
    pub name: String,
    pub size: usize,
    pub offset: usize,
    pub data: String,
    /// Paste the completed, quoted server path once, without pressing Enter.
    pub paste: bool,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Receipt {
    pub id: String,
    pub pane: String,
    pub received: usize,
    pub path: Option<String>,
}

/// Server-confirmed attachment progress, carried by the pane notification stream.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Progress {
    pub id: String,
    pub name: String,
    pub received: usize,
    pub total: usize,
    pub state: TransferState,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TransferState { Receiving, Complete, Failed }

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn only_upload_bytes_get_the_larger_network_budget() {
        let data = "A".repeat(MAX_CHUNK_BYTES.div_ceil(3) * 4);
        let mut request = json!({"type":"rpc","method":"terminal.put","params":{"upload":{"data":data}}});
        let fits = |value: &serde_json::Value| fits_command(value, value.to_string().len());
        assert!(fits(&request));
        assert!(fits(&json!({"type":"controller_rpc","call":request})));
        request["method"] = json!("graph.emit");
        assert!(!fits(&request));
        request["method"] = json!("terminal.put");
        request["padding"] = json!("x".repeat(crate::MAX_COMMAND_PACKET));
        assert!(!fits(&request));
    }
}
