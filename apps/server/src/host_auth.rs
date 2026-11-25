//! Local host controls reload authentication without replacing session owners.
use crate::{Error, Server, auth};
use serde_json::{Value, json};
use std::{
    io::Write,
    net::{IpAddr, SocketAddr, TcpListener},
    path::Path,
};

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct RemoteSettings {
    enabled: bool,
    bind_address: IpAddr,
    port: u16,
}

impl RemoteSettings {
    fn stage(&self, path: &Path) -> Result<tempfile::NamedTempFile, Error> {
        if self.port == 0 {
            return Err("Remote port must be between 1 and 65535".into());
        }
        let mut doc: toml_edit::DocumentMut = match std::fs::read_to_string(path) {
            Ok(text) => text.parse()?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Default::default(),
            Err(error) => return Err(error.into()),
        };
        let table = doc
            .entry("remote")
            .or_insert(toml_edit::Item::Table(Default::default()))
            .as_table_like_mut()
            .ok_or("Invalid remote configuration table")?;
        table.insert("enabled", toml_edit::value(self.enabled));
        table.insert(
            "bind_address",
            toml_edit::value(self.bind_address.to_string()),
        );
        table.insert("port", toml_edit::value(i64::from(self.port)));
        let directory = path.parent().unwrap_or(Path::new("."));
        std::fs::create_dir_all(directory)?;
        let mut staged = tempfile::NamedTempFile::new_in(directory)?;
        if let Ok(metadata) = path.metadata() {
            staged.as_file().set_permissions(metadata.permissions())?;
        }
        staged.write_all(doc.to_string().as_bytes())?;
        staged.as_file().sync_all()?;
        Ok(staged)
    }
}

/// Retain the old socket until commit unless overlapping bindings require releasing it.
struct PreviousListener {
    socket: Option<TcpListener>,
    address: Option<SocketAddr>,
}

impl PreviousListener {
    fn restore(self, server: &mut Server) -> Result<(), Error> {
        server.remote_listener = None;
        server.remote_listener = match (self.socket, self.address) {
            (Some(socket), _) => Some(socket),
            (_, Some(address)) => Some(crate::network_listener(&address.to_string())?),
            _ => None,
        };
        Ok(())
    }
}

fn replace_listener(
    server: &mut Server,
    target: Option<SocketAddr>,
) -> Result<Option<PreviousListener>, Error> {
    let address = server
        .remote_listener
        .as_ref()
        .map(TcpListener::local_addr)
        .transpose()?;
    if target == address {
        return Ok(None);
    }
    let mut previous = PreviousListener {
        socket: server.remote_listener.take(),
        address,
    };
    if let Some(target) = target {
        if address.is_some_and(|old| {
            old.port() == target.port()
                && (old.ip().is_unspecified() || target.ip().is_unspecified())
        }) {
            drop(previous.socket.take());
        }
        match crate::network_listener(&target.to_string()) {
            Ok(listener) => server.remote_listener = Some(listener),
            Err(error) => {
                previous.restore(server)?;
                return Err(error.into());
            }
        }
    }
    Ok(Some(previous))
}

pub fn remote_access(
    server: &mut Server,
    enabled: bool,
    address: Option<&str>,
) -> Result<Value, Error> {
    let target = if enabled {
        Some(match address {
            Some(address) => address.parse()?,
            None => SocketAddr::new(
                server.settings.remote.bind_address.parse()?,
                server.settings.remote.port,
            ),
        })
    } else {
        None
    };
    let previous = replace_listener(server, target)?;
    if previous.is_none() && server.remote_error.is_none() {
        return Ok(server.remote_descriptor());
    }
    let previous_error = server.remote_error.take();
    if let Err(error) = server.publish_descriptor() {
        if let Some(previous) = previous {
            previous.restore(server)?;
        }
        server.remote_error = previous_error;
        return Err(error);
    }
    server.network_generation += 1;
    server.pending_handshakes.revoke();
    Ok(server.remote_descriptor())
}

pub fn settings(server: &Server) -> Result<Value, Error> {
    let config = &server.auth_config;
    Ok(json!({
        "auth_path":std::path::absolute(&server.auth_path)?,
        "connection_file":std::path::absolute(&server.descriptor)?,
        "manual":config.password.is_some(),
        "mode":if config.password.is_some() {"manual"}else{"temporary"},
        "temporary_enabled":config.password.is_none(),
        "credential":config.telegram_credential.as_deref().unwrap_or("graffitty-2fa"),
        "temporary_password_length":config.temporary_password_length,
        "telegram_credential":config.telegram_credential,
        "chat_id":config.telegram_chat_id,
        "temporary_password":if config.password.is_some() {""}else{&server.remote_token},
        "bind_address":server.remote_listener.as_ref().and_then(|socket| socket.local_addr().ok()).map(|addr|addr.ip().to_string()).unwrap_or_else(||server.settings.remote.bind_address.clone()),
        "port":server.remote_listener.as_ref().and_then(|socket| socket.local_addr().ok()).map(|addr|addr.port()).unwrap_or(server.settings.remote.port),
        "remote":server.remote_descriptor(),
        "remote_error":server.remote_error
    }))
}

pub fn reload(
    server: &mut Server,
    rotate: bool,
    remote: Option<&Value>,
    auth: Option<&Value>,
) -> Result<Value, Error> {
    let remote: Option<RemoteSettings> = remote.cloned().map(serde_json::from_value).transpose()?;
    let config_path =
        std::fs::canonicalize(&server.config_path).unwrap_or_else(|_| server.config_path.clone());
    let staged = remote
        .as_ref()
        .filter(|settings| {
            settings.enabled != server.settings.remote.enabled
                || settings.port != server.settings.remote.port
                || settings.bind_address.to_string() != server.settings.remote.bind_address
        })
        .map(|settings| settings.stage(&config_path))
        .transpose()?;
    let config = match auth {
        Some(value) => serde_json::from_value(value.clone())?,
        None => auth::Config::load(&server.auth_path)?,
    };
    config.validate()?;
    let starting = remote
        .as_ref()
        .is_some_and(|choice| choice.enabled && server.remote_listener.is_none());
    let temporary = if config.password.is_some() {
        if rotate {
            return Err("Temporary passwords are disabled in manual mode".into());
        }
        String::new()
    } else if !rotate && !starting && server.remote_token.len() == config.temporary_password_length
    {
        server.remote_token.clone()
    } else {
        auth::temporary_password(config.temporary_password_length)?
    };
    // Construct everything before touching the running authenticator. Existing
    // remote connections are revoked by the ordinary network-generation check;
    // local frontends and every PTY remain attached to the same process.
    let changed_auth = config != server.auth_config || temporary != server.remote_token;
    let authentication = changed_auth
        .then(|| auth::Server::new(config.clone(), &temporary))
        .transpose()?;
    let previous_listener = if let Some(settings) = &remote {
        replace_listener(
            server,
            settings
                .enabled
                .then_some(SocketAddr::new(settings.bind_address, settings.port)),
        )?
    } else {
        None
    };
    let previous_error = server.remote_error.clone();
    if remote.is_some() {
        server.remote_error = None;
    }
    let changed_network = previous_listener.is_some() || changed_auth;
    let previous_auth = authentication.map(|next| std::mem::replace(&mut server.auth, next));
    let previous_token = std::mem::replace(&mut server.remote_token, temporary);
    let persist_auth = auth.is_some() && config != server.auth_config;
    let mut auth_saved = false;
    let published = (|| -> Result<(), Error> {
        if changed_network {
            server.publish_descriptor()?;
        }
        if persist_auth {
            config.save(&server.auth_path)?;
            auth_saved = true;
        }
        if let Some(file) = staged {
            file.persist(&config_path)?;
        }
        Ok(())
    })();
    if let Err(error) = published {
        if let Some(listener) = previous_listener {
            listener.restore(server)?;
        }
        server.remote_error = previous_error;
        if let Some(authenticator) = previous_auth {
            server.auth = authenticator;
        }
        server.remote_token = previous_token;
        if auth_saved {
            server.auth_config.save(&server.auth_path)?;
        }
        if changed_network {
            server.publish_descriptor()?;
        }
        return Err(error);
    }
    if let Some(remote) = remote {
        server.settings.remote.enabled = remote.enabled;
        server.settings.remote.bind_address = remote.bind_address.to_string();
        server.settings.remote.port = remote.port;
    }
    server.auth_config = config;
    if changed_network {
        server.network_generation += 1;
        server.pending_handshakes.revoke();
    }
    settings(server)
}
