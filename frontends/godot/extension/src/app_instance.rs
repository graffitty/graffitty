//! Godot adapter for the single-app gate in `graffitty_graph_protocol::application`.
//!
//! The process keeps the primary lock in a static until it exits.
use godot::{classes::{IRefCounted, RefCounted}, prelude::*};
use graffitty_graph_protocol::application::{self, Instance, Launch, Primary};
use serde_json::Value;
use std::{path::Path, sync::Mutex, time::Duration};

/// A second launch waits this long for a starting app to publish its socket.
const WAIT: Duration = Duration::from_secs(30);

static PRIMARY: Mutex<Option<Primary>> = Mutex::new(None);

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct AppInstance {
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for AppInstance {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base }
    }
}

fn outcome(role: &str, message: &str, result: &Value) -> VarDictionary {
    let mut value = VarDictionary::new();
    value.set("role", role);
    value.set("message", message);
    value.set("result", &crate::graph_client::to_variant(result));
    value
}

#[godot_api]
impl AppInstance {
    /// Become the app for the server at `server_descriptor` (empty: the
    /// default server), or forward `request` (`{method, params}`) to the app
    /// already running there.
    ///
    /// Returns `{role, message, result}`; role is `primary`, `forwarded`,
    /// `rejected` or `unanswered`.
    #[func]
    fn launch(server_descriptor: GString, name: GString, request: GString) -> VarDictionary {
        let descriptor = server_descriptor.to_string();
        let directory = match application::directory((!descriptor.is_empty()).then_some(Path::new(&descriptor))) {
            Ok(directory) => directory,
            Err(error) => return outcome("unanswered", &error.to_string(), &Value::Null),
        };
        let request: Value = match serde_json::from_str(&request.to_string()) {
            Ok(value) => value,
            Err(error) => return outcome("rejected", &error.to_string(), &Value::Null),
        };
        let mut params = request["params"].clone();
        // A forwarded window opens where this launch was started.
        if params.get("cwd").is_some_and(|cwd| cwd == "") {
            let cwd = std::env::var("GRAFFITTY_INITIAL_PWD").ok().filter(|v| !v.is_empty())
                .or_else(|| std::env::current_dir().ok().map(|p| p.to_string_lossy().into_owned()))
                .unwrap_or_default();
            params["cwd"] = cwd.into();
        }
        let method = request["method"].as_str().unwrap_or_default();
        match Instance::new(directory, &name.to_string()).launch(method, &params, WAIT) {
            Ok(Launch::Primary(primary)) => {
                *PRIMARY.lock().unwrap() = Some(primary);
                outcome("primary", "", &Value::Null)
            }
            Ok(Launch::Forwarded(result)) => outcome("forwarded", "", &result),
            Ok(Launch::Rejected(message)) => outcome("rejected", &message, &Value::Null),
            Ok(Launch::Unanswered(message)) => outcome("unanswered", &message, &Value::Null),
            Err(error) => outcome("unanswered", &error.to_string(), &Value::Null),
        }
    }

    /// Publish this primary app's API socket. False when this process is not primary.
    #[func]
    fn publish(socket: GString, token: GString) -> bool {
        let primary = PRIMARY.lock().unwrap();
        let Some(primary) = primary.as_ref() else { return false };
        match primary.publish(&socket.to_string(), &token.to_string()) {
            Ok(()) => true,
            Err(error) => {
                godot_error!("Cannot publish the app descriptor: {error}");
                false
            }
        }
    }

    /// Remove the published descriptor if it is still this app's.
    #[func]
    fn withdraw(token: GString) {
        if let Some(primary) = PRIMARY.lock().unwrap().as_ref() {
            primary.withdraw(&token.to_string());
        }
    }

    /// Give up the app role now, so a relaunch can take it before this
    /// process has finished exiting.
    #[func]
    fn release(token: GString) {
        if let Some(primary) = PRIMARY.lock().unwrap().take() {
            primary.withdraw(&token.to_string());
        }
    }
}
