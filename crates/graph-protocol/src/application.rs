//! One desktop app per session server.
//!
//! The first app to start holds `<name>.lock` for its whole life and
//! publishes `<name>.json` (`{socket, token, pid}`, mode 0600) beside the
//! server's `server.json`. A later launch finds that app and forwards its
//! request (a new window, a checkpoint restore) instead of running a second
//! app against the same server.
//!
//! - The lock, not the file, decides who is primary. The OS releases it when
//!   the app exits or crashes, so a stale descriptor never blocks a launch.
//! - A new primary deletes any descriptor left by a crashed one before it
//!   publishes its own.
//!
//! Release apps use [`RELEASE`]; development runs use [`DEVELOPMENT`], so a
//! development build never opens its windows in the installed app.
use graffitty_session_transport::local_json::Stream;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    fs,
    io::{self, BufReader, Write},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

pub const RELEASE: &str = "app";
pub const DEVELOPMENT: &str = "dev-app";

/// The published address of the running app's private API socket.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Descriptor {
    pub socket: String,
    pub token: String,
    pub pid: u32,
}

/// The primary role, held until this value is dropped.
#[derive(Debug)]
pub struct Primary {
    _lock: fs::File,
    descriptor: PathBuf,
}

#[derive(Debug)]
pub enum Launch {
    /// No app was running: this process is now the app.
    Primary(Primary),
    /// The running app accepted the request; this process should exit.
    Forwarded(Value),
    /// The running app refused the request.
    Rejected(String),
    /// An app holds the role but did not answer.
    Unanswered(String),
}

/// The state directory of the server at `server_descriptor` (or the default
/// one), where the app's lock and descriptor live.
pub fn directory(server_descriptor: Option<&Path>) -> crate::Result<PathBuf> {
    let descriptor = match server_descriptor {
        Some(path) => path.to_path_buf(),
        None => crate::local_server_descriptor()?,
    };
    Ok(descriptor.parent().ok_or("Server descriptor has no directory")?.to_path_buf())
}

#[derive(Clone, Debug)]
pub struct Instance {
    directory: PathBuf,
    name: String,
}

impl Instance {
    pub fn new(directory: impl Into<PathBuf>, name: &str) -> Self {
        Self { directory: directory.into(), name: name.into() }
    }

    pub fn descriptor_path(&self) -> PathBuf {
        self.directory.join(format!("{}.json", self.name))
    }

    /// Take the primary role unless a live app holds it.
    pub fn try_primary(&self) -> io::Result<Option<Primary>> {
        fs::create_dir_all(&self.directory)?;
        let mut options = fs::OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let lock = options.open(self.directory.join(format!("{}.lock", self.name)))?;
        match lock.try_lock() {
            Ok(()) => {}
            Err(fs::TryLockError::WouldBlock) => return Ok(None),
            Err(fs::TryLockError::Error(error)) => return Err(error),
        }
        // Whatever is published now belongs to an app that has exited.
        match fs::remove_file(self.descriptor_path()) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
            _ => {}
        }
        Ok(Some(Primary { _lock: lock, descriptor: self.descriptor_path() }))
    }

    /// The published descriptor, if any. Only meaningful while the lock is held.
    pub fn descriptor(&self) -> Option<Descriptor> {
        let bytes = fs::read(self.descriptor_path()).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    /// The running app, if one holds the role and has published its socket.
    pub fn running(&self) -> io::Result<Option<Descriptor>> {
        if self.try_primary()?.is_some() {
            return Ok(None);
        }
        Ok(self.descriptor())
    }

    /// Become the app, or hand `method` to the one already running.
    ///
    /// A starting app holds the role before it publishes its socket, and a
    /// busy one asks callers to retry; both are retried until `wait` ends.
    pub fn launch(&self, method: &str, params: &Value, wait: Duration) -> io::Result<Launch> {
        let deadline = Instant::now() + wait;
        let mut reason = "The running Graffitty did not publish its socket".to_string();
        loop {
            if let Some(primary) = self.try_primary()? {
                return Ok(Launch::Primary(primary));
            }
            if let Some(descriptor) = self.descriptor() {
                match call(&descriptor, method, params, Duration::from_secs(10)) {
                    Ok(result) => return Ok(Launch::Forwarded(result)),
                    Err(Failure::Retry(message)) => reason = message,
                    Err(Failure::Rejected(message)) => return Ok(Launch::Rejected(message)),
                    // The request may have run; sending it again could open two windows.
                    Err(Failure::Lost(message)) => return Ok(Launch::Unanswered(message)),
                }
            }
            if Instant::now() >= deadline {
                return Ok(Launch::Unanswered(reason));
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Primary {
    /// Publish this app's private API socket for later launches.
    pub fn publish(&self, socket: &str, token: &str) -> io::Result<()> {
        let bytes = serde_json::to_vec(&json!({"socket":socket,"token":token,"pid":std::process::id()}))?;
        let temporary = self.descriptor.with_extension(format!("json.{}.tmp", std::process::id()));
        let mut options = fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let result = (|| {
            let mut file = options.open(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            fs::rename(&temporary, &self.descriptor)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }

    /// Remove the descriptor if it is still the one published with `token`.
    pub fn withdraw(&self, token: &str) {
        let ours = fs::read(&self.descriptor).ok()
            .and_then(|bytes| serde_json::from_slice::<Descriptor>(&bytes).ok())
            .is_some_and(|descriptor| descriptor.token == token);
        if ours {
            let _ = fs::remove_file(&self.descriptor);
        }
    }
}

#[derive(Debug)]
enum Failure {
    /// Nothing ran: the socket is gone or the app asked to retry.
    Retry(String),
    Rejected(String),
    /// Sent, but no complete answer arrived.
    Lost(String),
}

/// One request on the app's private API socket.
fn call(descriptor: &Descriptor, method: &str, params: &Value, timeout: Duration) -> Result<Value, Failure> {
    let id = format!("launch-{}", std::process::id());
    let request = json!({"version":1,"id":id,"token":descriptor.token,"method":method,"params":params});
    let mut bytes = serde_json::to_vec(&request).map_err(|e| Failure::Rejected(e.to_string()))?;
    bytes.push(b'\n');
    let retry = |error: io::Error| Failure::Retry(format!("The running Graffitty is unreachable: {error}"));
    let mut socket = Stream::connect(&descriptor.socket).map_err(retry)?;
    socket.set_read_timeout(Some(timeout)).map_err(retry)?;
    socket.set_write_timeout(Some(timeout)).map_err(retry)?;
    // The app reads only complete lines, so an interrupted write runs nothing.
    socket.write_all(&bytes).map_err(retry)?;
    let lost = |error: String| Failure::Lost(format!("The running Graffitty did not answer: {error}"));
    let line = crate::read_message(&mut BufReader::new(socket))
        .map_err(|e| lost(e.to_string()))?
        .ok_or_else(|| lost("connection closed".into()))?;
    let reply: Value = serde_json::from_slice(&line).map_err(|e| lost(e.to_string()))?;
    if reply["id"] != json!(id) {
        return Err(lost("mismatched reply".into()));
    }
    if let Some(error) = reply.get("error") {
        let message = error["message"].as_str().unwrap_or("Request refused").to_string();
        return Err(if error["code"] == "busy" { Failure::Retry(message) } else { Failure::Rejected(message) });
    }
    reply.get("result").cloned().ok_or_else(|| lost("reply has no result".into()))
}

/// Send `method` to the running app described by `descriptor`.
pub fn forward(descriptor: &Descriptor, method: &str, params: &Value) -> crate::Result<Value> {
    call(descriptor, method, params, Duration::from_secs(10)).map_err(|failure| match failure {
        Failure::Retry(message) | Failure::Rejected(message) | Failure::Lost(message) => message.into(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use graffitty_session_transport::local_json::Listener;
    use std::io::{BufRead, Read};

    /// A stand-in app socket answering each request with `reply(request)`.
    fn serve(directory: &Path, replies: Vec<Value>) -> (String, std::thread::JoinHandle<Vec<Value>>) {
        let listener = Listener::bind(directory).unwrap();
        let endpoint = listener.endpoint(directory).unwrap();
        let handle = std::thread::spawn(move || {
            let mut seen = vec![];
            for mut reply in replies {
                let stream = listener.accept().unwrap();
                let mut reader = BufReader::new(stream);
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                reply["id"] = request["id"].clone();
                seen.push(request);
                let mut stream = reader.into_inner();
                stream.write_all(format!("{reply}\n").as_bytes()).unwrap();
                let _ = stream.read(&mut [0; 1]);
            }
            seen
        });
        (endpoint, handle)
    }

    #[test]
    fn first_launch_becomes_primary_and_removes_a_stale_descriptor() {
        let directory = tempfile::tempdir().unwrap();
        let instance = Instance::new(directory.path(), RELEASE);
        fs::write(instance.descriptor_path(), r#"{"socket":"/nonexistent","token":"old","pid":1}"#).unwrap();
        let Launch::Primary(primary) = instance.launch("application.open_window", &json!({}), Duration::ZERO).unwrap() else {
            panic!("No app holds the lock, so this launch is the app");
        };
        assert!(!instance.descriptor_path().exists(), "The crashed app's descriptor is removed");
        primary.publish("/tmp/socket", "secret").unwrap();
        assert_eq!(instance.descriptor().unwrap(), Descriptor { socket: "/tmp/socket".into(), token: "secret".into(), pid: std::process::id() });
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(instance.descriptor_path()).unwrap().permissions().mode() & 0o777, 0o600);
        }
        primary.withdraw("another token");
        assert!(instance.descriptor_path().exists(), "Only the publishing app withdraws its descriptor");
        primary.withdraw("secret");
        assert!(!instance.descriptor_path().exists());
    }

    #[test]
    fn a_held_lock_is_never_taken_and_an_exited_app_releases_it() {
        let directory = tempfile::tempdir().unwrap();
        let instance = Instance::new(directory.path(), RELEASE);
        let primary = instance.try_primary().unwrap().unwrap();
        assert!(instance.try_primary().unwrap().is_none(), "Lock contention keeps one primary");
        // Holding the role without a socket yet: later launches wait, then give up.
        let started = Instant::now();
        let Launch::Unanswered(_) = instance.launch("application.open_window", &json!({}), Duration::from_millis(200)).unwrap() else {
            panic!("A silent primary is not answered");
        };
        assert!(started.elapsed() >= Duration::from_millis(200));
        assert!(instance.running().unwrap().is_none(), "Nothing published yet");
        drop(primary);
        assert!(matches!(instance.launch("application.open_window", &json!({}), Duration::ZERO).unwrap(), Launch::Primary(_)));
        // Development and release apps never forward to each other.
        let _release = Instance::new(directory.path(), RELEASE).try_primary().unwrap().unwrap();
        assert!(Instance::new(directory.path(), DEVELOPMENT).try_primary().unwrap().is_some());
    }

    #[test]
    fn a_live_primary_receives_the_request_and_busy_is_retried() {
        let directory = tempfile::tempdir().unwrap();
        let instance = Instance::new(directory.path(), RELEASE);
        let primary = instance.try_primary().unwrap().unwrap();
        let socket_directory = directory.path().join("socket");
        fs::create_dir(&socket_directory).unwrap();
        let (endpoint, server) = serve(&socket_directory, vec![
            json!({"version":1,"error":{"code":"busy","message":"Not ready"}}),
            json!({"version":1,"result":{"opened":true}}),
        ]);
        primary.publish(&endpoint, "secret").unwrap();
        assert_eq!(instance.running().unwrap().unwrap().token, "secret");
        let params = json!({"fresh_session":true,"args":["--cwd=/tmp"],"cwd":"/tmp"});
        let Launch::Forwarded(result) = instance.launch("application.open_window", &params, Duration::from_secs(5)).unwrap() else {
            panic!("The running app answers");
        };
        assert_eq!(result, json!({"opened":true}));
        let seen = server.join().unwrap();
        assert_eq!(seen.len(), 2, "A busy app is asked again");
        assert_eq!(seen[1]["method"], "application.open_window");
        assert_eq!(seen[1]["token"], "secret");
        assert_eq!(seen[1]["params"], params);
    }

    #[test]
    fn a_refusal_is_reported_and_not_retried() {
        let directory = tempfile::tempdir().unwrap();
        let instance = Instance::new(directory.path(), RELEASE);
        let primary = instance.try_primary().unwrap().unwrap();
        let socket_directory = directory.path().join("socket");
        fs::create_dir(&socket_directory).unwrap();
        let (endpoint, server) = serve(&socket_directory, vec![
            json!({"version":1,"error":{"code":"invalid_params","message":"No checkpoint"}}),
        ]);
        primary.publish(&endpoint, "secret").unwrap();
        let Launch::Rejected(message) = instance.launch("application.restore_checkpoint", &json!({"path":"/missing"}), Duration::from_secs(5)).unwrap() else {
            panic!("The app's refusal is final");
        };
        assert_eq!(message, "No checkpoint");
        assert_eq!(server.join().unwrap().len(), 1);
    }
}
