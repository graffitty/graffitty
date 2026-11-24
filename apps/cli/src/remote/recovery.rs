//! A headless attachment outlives the SSH link. Each login publishes a fresh
//! bridge so a later connection cannot replay an earlier connection's input.
use super::Error;
use graffitty_transport::{Authentication, ClientTransport, authenticate, client, controller};
use std::{
    path::PathBuf,
    thread::{self, JoinHandle},
    time::Instant,
};

enum DialError {
    Interrupted(String),
    Rejected(String),
}

enum Link {
    Online(controller::Attached),
    Waiting(Instant),
    Dialing(JoinHandle<Result<ClientTransport, DialError>>),
}

pub(super) struct Controller {
    url: String,
    password: String,
    alias: String,
    identity: String,
    state: PathBuf,
    link: Link,
    failures: u32,
}

impl Controller {
    pub fn new(
        transport: ClientTransport,
        url: String,
        password: String,
        alias: &str,
        identity: &str,
    ) -> Result<Self, Error> {
        let state = controller::state_directory()?;
        let attachment = controller::Attached::new(transport, &state, alias, identity)?;
        Ok(Self {
            url,
            password,
            alias: alias.into(),
            identity: identity.into(),
            state,
            link: Link::Online(attachment),
            failures: 0,
        })
    }

    pub fn poll(&mut self) -> Result<(), Error> {
        match &mut self.link {
            Link::Online(attachment) => {
                if let Err(error) = attachment.poll() {
                    eprintln!(
                        "Lost remote controller {} ({error}). Reconnecting…",
                        self.alias
                    );
                    self.link = Link::Waiting(Instant::now());
                }
            }
            Link::Waiting(at) if Instant::now() >= *at => {
                let url = self.url.clone();
                let password = self.password.clone();
                // Login can block on the network. Keep servicing SSH and Ctrl+C.
                let worker = thread::Builder::new().name("remote-redial".into()).spawn(
                    move || match authenticate(&url, &password, None) {
                        Ok(Authentication::Connected(transport)) => Ok(transport),
                        Ok(Authentication::CodeRequired(_)) => Err(DialError::Rejected(
                            "This server requires Telegram verification; connect through the GUI"
                                .into(),
                        )),
                        Err(error) if client::interrupted_login(&error) => {
                            Err(DialError::Interrupted(format!("{error:#}")))
                        }
                        Err(error) => Err(DialError::Rejected(format!("{error:#}"))),
                    },
                )?;
                self.link = Link::Dialing(worker);
            }
            Link::Dialing(worker) if worker.is_finished() => {
                let Link::Dialing(worker) =
                    std::mem::replace(&mut self.link, Link::Waiting(Instant::now()))
                else {
                    unreachable!()
                };
                match worker.join().map_err(|_| "Remote redial worker stopped")? {
                    Ok(transport) => {
                        self.link = Link::Online(controller::Attached::new(
                            transport,
                            &self.state,
                            &self.alias,
                            &self.identity,
                        )?);
                        self.failures = 0;
                        eprintln!("Remote controller {} reconnected.", self.alias);
                    }
                    Err(DialError::Interrupted(reason)) => {
                        let delay = client::reconnect_delay(self.failures);
                        self.failures = self.failures.saturating_add(1);
                        eprintln!(
                            "Remote controller {} offline ({reason}). Retrying in {delay:?}.",
                            self.alias
                        );
                        self.link = Link::Waiting(Instant::now() + delay);
                    }
                    Err(DialError::Rejected(reason)) => return Err(reason.into()),
                }
            }
            _ => {}
        }
        Ok(())
    }
}
