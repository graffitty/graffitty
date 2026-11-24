//! The session actor submits bounded work and consumes completed observations.
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::mpsc::{self, Receiver, Sender},
    thread,
    time::{Duration, Instant},
};

struct Request {
    cli: String,
    key: String,
    body: Value,
}

struct Job {
    child: Child,
    input: PathBuf,
    output: PathBuf,
    started: Instant,
}

impl Job {
    fn launch(cli: &str, body: Value, directory: &Path) -> io::Result<Self> {
        let input = directory.join(format!("{}.json", uuid::Uuid::new_v4().simple()));
        let output = input.with_extension("out");
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let launch = || {
            options
                .open(&input)?
                .write_all(body.to_string().as_bytes())?;
            Command::new(cli)
                .args(["internal", "agent-worker", "--request"])
                .arg(&input)
                .stdin(Stdio::null())
                .stdout(options.open(&output)?)
                .stderr(Stdio::null())
                .spawn()
        };
        match launch() {
            Ok(child) => Ok(Self {
                child,
                input,
                output,
                started: Instant::now(),
            }),
            Err(e) => {
                let _ = fs::remove_file(&input);
                let _ = fs::remove_file(&output);
                Err(e)
            }
        }
    }

    fn result(&mut self, settings: &crate::settings::Workers) -> io::Result<Option<Value>> {
        match self.child.try_wait()? {
            // The CLI also returns a structured error on a nonzero exit.
            Some(_) => (),
            None if self.started.elapsed() < Duration::from_secs(settings.timeout_seconds) => {
                return Ok(None);
            }
            None => {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "Agent helper timed out",
                ));
            }
        }
        let mut bytes = vec![];
        fs::File::open(&self.output)?
            .take(settings.output_bytes as u64 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > settings.output_bytes {
            return Err(io::Error::other("Agent helper output exceeded limit"));
        }
        Ok(Some(serde_json::from_slice(&bytes)?))
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        if !matches!(self.child.try_wait(), Ok(Some(_))) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
        let _ = fs::remove_file(&self.input);
        let _ = fs::remove_file(&self.output);
    }
}

fn error(e: io::Error) -> Value {
    json!({"error":{"message":e.to_string()}})
}

fn manage(
    directory: PathBuf,
    settings: crate::settings::Workers,
    requests: Receiver<Request>,
    replies: Sender<(String, Value)>,
) {
    let mut jobs: HashMap<String, Job> = HashMap::new();
    loop {
        let next = if jobs.is_empty() {
            requests
                .recv()
                .map_err(|_| mpsc::RecvTimeoutError::Disconnected)
        } else {
            requests.recv_timeout(Duration::from_millis(10))
        };
        match next {
            Ok(r) => match Job::launch(&r.cli, r.body, &directory) {
                Ok(job) => {
                    jobs.insert(r.key, job);
                }
                Err(e) => {
                    let _ = replies.send((r.key, error(e)));
                }
            },
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => (),
        }
        jobs.retain(|key, job| {
            let result = match job.result(&settings) {
                Ok(None) => return true,
                Ok(Some(value)) => value,
                Err(e) => error(e),
            };
            let _ = replies.send((key.clone(), result));
            false
        });
    }
    drop(jobs);
    let _ = fs::remove_dir(&directory);
}

pub struct Workers {
    capacity: usize,
    active: HashMap<String, Value>,
    requests: Option<Sender<Request>>,
    apps: Option<Sender<Value>>,
    replies: Receiver<(String, Value)>,
    threads: Vec<thread::JoinHandle<()>>,
}

impl Workers {
    pub fn new(
        parent: &Path,
        settings: crate::settings::Workers,
        foreground: fn(&Value) -> Value,
    ) -> io::Result<Self> {
        let directory = parent.join(format!("workers-{}", uuid::Uuid::new_v4().simple()));
        fs::create_dir_all(&directory)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        }
        let (requests, rx) = mpsc::channel();
        let (apps, roots) = mpsc::channel();
        let (tx, replies) = mpsc::channel();
        let app_replies = tx.clone();
        let capacity = settings.concurrency;
        let manager = thread::Builder::new()
            .name("agent-workers".into())
            .spawn(move || manage(directory, settings, rx, tx))?;
        // Provider I/O and timeouts proceed even during a large foreground sample.
        let reader = thread::Builder::new()
            .name("foreground-apps".into())
            .spawn(move || {
                for roots in roots {
                    let _ = app_replies.send(("foreground_apps".into(), foreground(&roots)));
                }
            })?;
        Ok(Self {
            capacity,
            active: HashMap::new(),
            requests: Some(requests),
            apps: Some(apps),
            replies,
            threads: vec![manager, reader],
        })
    }

    pub fn busy(&self, key: &str) -> bool {
        self.active.contains_key(key)
    }

    fn available(&self, key: &str) -> bool {
        self.active.len() < self.capacity && !self.busy(key)
    }

    pub fn start(&mut self, cli: &str, key: String, body: Value, context: Value) -> bool {
        if !self.available(&key) {
            return false;
        }
        let request = Request {
            cli: cli.into(),
            key: key.clone(),
            body,
        };
        if self.requests.as_ref().unwrap().send(request).is_err() {
            return false;
        }
        self.active.insert(key, context);
        true
    }

    pub fn foreground(&mut self, roots: Value) -> bool {
        let key = "foreground_apps";
        if !self.available(key) || self.apps.as_ref().unwrap().send(roots.clone()).is_err() {
            return false;
        }
        self.active.insert(key.into(), roots);
        true
    }

    pub fn transfer_deliveries(&mut self, source: &str, target: &str, moved: &std::collections::HashSet<u64>) {
        for (key, context) in &mut self.active {
            if key.starts_with("deliver:") || key.starts_with("cancel:") {
                crate::native_delivery::move_record(context, source, target, moved);
            }
        }
    }

    pub fn poll(&mut self) -> Vec<(String, Value, Value)> {
        self.replies
            .try_iter()
            .filter_map(|(key, result)| {
                let context = self.active.remove(&key)?;
                Some((key, context, result))
            })
            .collect()
    }
}

impl Drop for Workers {
    fn drop(&mut self) {
        self.requests.take();
        self.apps.take();
        for thread in self.threads.drain(..) {
            let _ = thread.join();
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn reply(workers: &mut Workers) -> (String, Value, Value) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(reply) = workers.poll().pop() {
                return reply;
            }
            assert!(Instant::now() < deadline, "worker did not finish");
            thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn slots_preserve_context_and_return_after_success_failure_or_timeout() {
        let root = std::env::temp_dir().join(format!("worker-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        let cli = root.join("helper");
        let mut workers = Workers::new(
            &root,
            crate::settings::Workers {
                concurrency: 1,
                timeout_seconds: 1,
                output_bytes: 100,
            },
            Value::clone,
        )
        .unwrap();
        // Results carry the frontend-owned context even when the subprocess
        // had already started before a tab transfer.
        for key in ["deliver:2", "cancel:event"] {
            workers.active.insert(key.into(), json!({"id":2,"workspace":"one","target":{"session_id":"original"}}));
        }
        workers.transfer_deliveries("one", "two", &std::collections::HashSet::from([2]));
        for key in ["deliver:2", "cancel:event"] {
            assert_eq!(workers.active.remove(key).unwrap(), json!({"id":2,"workspace":"two","target":{"session_id":"original"}}));
        }
        assert!(workers.foreground(json!(["pane"])));
        assert!(!workers.foreground(Value::Null));
        assert!(!workers.start("", "scan".into(), Value::Null, Value::Null));
        assert_eq!(
            reply(&mut workers),
            ("foreground_apps".into(), json!(["pane"]), json!(["pane"]))
        );

        let run = |w: &mut Workers| {
            assert!(w.start(cli.to_str().unwrap(), "scan".into(), Value::Null, json!(42)));
            let (key, context, result) = reply(w);
            assert_eq!((key.as_str(), context), ("scan", json!(42)));
            result
        };
        assert!(run(&mut workers)["error"].is_object(), "missing executable");
        fs::write(
            &cli,
            "#!/bin/sh\necho '{\"error\":{\"message\":\"provider error\"}}'\nexit 1\n",
        )
        .unwrap();
        fs::set_permissions(&cli, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(run(&mut workers)["error"]["message"], "provider error");
        fs::write(&cli, "#!/bin/sh\necho $$ > \"$0.pid\"\nexec sleep 30\n").unwrap();
        assert_eq!(
            run(&mut workers)["error"]["message"],
            "Agent helper timed out"
        );
        drop(workers);
        let pid: i32 = fs::read_to_string(cli.with_extension("pid"))
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
        assert!(
            !fs::read_dir(&root)
                .unwrap()
                .any(|e| e.unwrap().path().is_dir())
        );
        fs::remove_dir_all(root).unwrap();
    }
}
