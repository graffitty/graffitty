//! OpenSSH owns authentication and encryption. The server owns PTYs independently
//! of these tunnels and of the lifetime of the native frontend.
mod deploy;
mod release;

use crate::options::{RemoteCommand, RemoteConnect};
use serde_json::{Value, json};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    net::TcpListener,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};
type Error = Box<dyn std::error::Error>;
fn ssh(host: &str) -> Command {
    let mut cmd = Command::new("ssh");
    cmd.args([
        "-o",
        "ConnectTimeout=15",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ServerAliveCountMax=3",
        host,
    ]);
    cmd
}
/// Copy a file into the Windows account's home directory over SFTP.
///
/// A Windows OpenSSH DefaultShell of PowerShell 7 never forwards SSH stdin to
/// a child powershell.exe, so uploads cannot be piped through a command
/// there.
fn upload_windows(host: &str, local: &Path, name: &str) -> Result<(), Error> {
    let status = Command::new("scp")
        .args(["-q", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"])
        .arg(local)
        .arg(format!("{host}:{name}"))
        .status()?;
    if !status.success() {
        return Err(format!("Windows upload failed: {}", local.display()).into());
    }
    Ok(())
}
fn output(host: &str, script: &str) -> Result<String, Error> {
    let result = ssh(host).arg(script).output()?;
    if !result.status.success() {
        return Err(format!(
            "SSH {host}: {}",
            String::from_utf8_lossy(&result.stderr).trim()
        )
        .into());
    }
    Ok(String::from_utf8(result.stdout)?.trim().into())
}
fn validate_host(host: &str) -> Result<(), Error> {
    if host.is_empty()
        || host.starts_with('-')
        || host.chars().any(|c| c.is_whitespace() || c.is_control())
    {
        return Err("Use an SSH hostname, user@host, or ~/.ssh/config alias".into());
    }
    Ok(())
}
fn prepare(host: &str, binary: Option<&Path>) -> Result<Value, Error> {
    validate_host(host)?;
    let platform = deploy::Platform::detect(host)?;
    let result = match deploy::resolve(host, &platform, binary)? {
        deploy::Resolved::Running(descriptor) => descriptor,
        deploy::Resolved::Executable(path) => output(host, &platform.start_command(&path))?,
    };
    let descriptor: Value = serde_json::from_str(&result)?;
    if descriptor["protocol"] != graffitty_protocol::VERSION || descriptor["token"].as_str().is_none() {
        return Err("Unsupported server descriptor".into());
    }
    Ok(descriptor)
}

fn remote_port(descriptor: &Value) -> Result<u16, Error> {
    let url = descriptor["url"].as_str().ok_or("Missing server URL")?;
    if url.starts_with("ipc://") {
        return Err(concat!(
            "The running server has no remote listener. Enable Remote Access on the remote computer, ",
            "or start a new server with `gft server --listen 127.0.0.1:0`. ",
            "Existing sessions are still running; do not kill the server to reconnect."
        ).into());
    }
    let address: std::net::SocketAddr = url
        .strip_prefix("ws://")
        .ok_or("Expected a ws:// server listener URL")?
        .parse()
        .map_err(|_| "Invalid server listener address")?;
    if address.port() == 0 {
        return Err("Server descriptor has no assigned listener port".into());
    }
    Ok(address.port())
}

// Versioned chromium bundles preserve any host already serving a live session.
fn install_chromium(host: &str, archive: &Path) -> Result<(), Error> {
    let nonce = uuid::Uuid::new_v4().simple().to_string();
    let script = format!(
        r#"set -eu
umask 077
root="${{XDG_DATA_HOME:-$HOME/.local/share}}/graffitty/remote-build"
destination="$root/chromium-runtime-{nonce}"
mkdir -p "$destination"
tar -xzf - -C "$destination"
test -x "$destination/Chromium GPU Host.app/Contents/MacOS/probe"
printf '%s\n' 'chromium-runtime-{nonce}/Chromium GPU Host.app/Contents/MacOS/probe' > "$root/chromium-host-path.{nonce}"
mv "$root/chromium-host-path.{nonce}" "$root/chromium-host-path.txt"
"#
    );
    let mut child = ssh(host)
        .arg(script)
        .stdin(Stdio::from(File::open(archive)?))
        .spawn()?;
    if !child.wait()?.success() {
        return Err("Could not install the GPU chromium runtime".into());
    }
    Ok(())
}
// Versioned like the chromium runtime. A running server may still have trees on
// the previously current runtime; older ones are removed.
fn install_filetree(host: &str, archive: &Path) -> Result<(), Error> {
    let nonce = uuid::Uuid::new_v4().simple().to_string();
    let script = format!(
        r#"set -eu
umask 077
root="${{XDG_DATA_HOME:-$HOME/.local/share}}/graffitty/remote-build"
destination="$root/filetree-runtime-{nonce}"
previous=$(cut -d/ -f1 "$root/filetree-runtime-path.txt" 2>/dev/null || true)
mkdir -p "$destination"
tar -xzf - -C "$destination"
test -f "$destination/filetree/manifest.json"
printf '%s\n' 'filetree-runtime-{nonce}/filetree' > "$root/filetree-runtime-path.{nonce}"
mv "$root/filetree-runtime-path.{nonce}" "$root/filetree-runtime-path.txt"
for old in "$root"/filetree-runtime-*/; do
    name=$(basename "$old")
    if [ "$name" != "filetree-runtime-{nonce}" ] && [ "$name" != "$previous" ]; then rm -rf "$old"; fi
done
"#
    );
    let mut child = ssh(host)
        .arg(script)
        .stdin(Stdio::from(File::open(archive)?))
        .spawn()?;
    if !child.wait()?.success() {
        return Err("Could not install the bundled filetree runtime".into());
    }
    Ok(())
}
fn powershell(script: &str) -> String {
    use base64::Engine;
    let script = format!("[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)\n{script}");
    let bytes: Vec<u8> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
    format!(
        "powershell.exe -NoLogo -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand {}",
        base64::engine::general_purpose::STANDARD.encode(bytes)
    )
}
fn install_windows_binary(host: &str, artifact: &Path) -> Result<String, Error> {
    let nonce = uuid::Uuid::new_v4().simple().to_string();
    upload_windows(host, artifact, &format!(".graffitty-upload-{nonce}.exe"))?;
    let script = format!(
        r#"$ErrorActionPreference='Stop'
$upload=Join-Path $HOME '.graffitty-upload-{nonce}.exe'
try {{
    $directory=Join-Path $env:LOCALAPPDATA 'graffitty/bin/{nonce}'
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $file=Join-Path $directory 'gft.exe'
    [IO.File]::Move($upload, $file)
    & $file --version | Out-Null
    if ($LASTEXITCODE -ne 0) {{ throw 'Executable does not match the remote Windows host' }}
    [Console]::WriteLine($file)
}} finally {{ if (Test-Path -LiteralPath $upload) {{ Remove-Item -LiteralPath $upload -Force }} }}
"#
    );
    let path = output(host, &powershell(&script))
        .map_err(|error| format!("Windows install failed: {}: {error}", artifact.display()))?;
    let filetree = artifact.with_file_name("filetree-runtime.zip");
    if filetree.is_file() {
        install_windows_filetree(host, &filetree)?;
    }
    Ok(path)
}

// The Windows form of install_filetree. The server finds the pointer in
// %LOCALAPPDATA%\graffitty, an ancestor of bin\<nonce>\gft.exe. Runtimes that a
// running Neovim still holds open stay until a later install removes them.
fn install_windows_filetree(host: &str, archive: &Path) -> Result<(), Error> {
    let nonce = uuid::Uuid::new_v4().simple().to_string();
    upload_windows(host, archive, &format!(".graffitty-upload-{nonce}.zip"))?;
    let script = format!(
        r#"$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'graffitty'
$name='filetree-runtime-{nonce}'
$destination=Join-Path $root $name
$archive=Join-Path $HOME '.graffitty-upload-{nonce}.zip'
$pointer=Join-Path $root 'filetree-runtime-path.txt'
$previous=''
if (Test-Path -LiteralPath $pointer) {{ $previous=([IO.File]::ReadAllText($pointer).Trim() -split '/')[0] }}
[IO.Directory]::CreateDirectory($root) | Out-Null
try {{
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $destination)
}} finally {{ Remove-Item -LiteralPath $archive -Force }}
if (!(Test-Path -LiteralPath (Join-Path $destination 'filetree/manifest.json'))) {{ throw 'Incomplete filetree runtime' }}
$next=$pointer + '.{nonce}'
try {{
    [IO.File]::WriteAllText($next, $name + '/filetree', (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $pointer) {{ [IO.File]::Replace($next, $pointer, [NullString]::Value) }} else {{ [IO.File]::Move($next, $pointer) }}
}} finally {{ if (Test-Path -LiteralPath $next) {{ Remove-Item -LiteralPath $next -Force }} }}
Get-ChildItem -LiteralPath $root -Directory -Filter 'filetree-runtime-*' | Where-Object {{ $_.Name -ne $name -and $_.Name -ne $previous }} | ForEach-Object {{ Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }}
"#
    );
    output(host, &powershell(&script))
        .map_err(|error| format!("Could not install the bundled filetree runtime on Windows: {error}"))?;
    Ok(())
}

fn install_unix_binary(host: &str, artifact: &Path, macos: bool) -> Result<String, Error> {
    let script = r#"set -eu
umask 077
root="${XDG_DATA_HOME:-$HOME/.local/share}/graffitty/remote-build"
mkdir -p "$root"
tmp=$(mktemp "$root/.gft-XXXXXX")
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"
chmod 700 "$tmp"
"$tmp" --version >/dev/null
mv -f "$tmp" "$root/gft"
printf '%s\n' "$root/gft"
"#;
    let result = ssh(host).arg(script).stdin(File::open(artifact)?).output()?;
    if !result.status.success() {
        return Err(format!("Upload of {} failed (check the remote OS/CPU): {}",
            artifact.display(), String::from_utf8_lossy(&result.stderr).trim()).into());
    }
    let filetree = artifact.with_file_name("filetree-runtime.tar.gz");
    if filetree.is_file() {
        install_filetree(host, &filetree)?;
    }
    let chromium = artifact.with_file_name("chromium-runtime.tar.gz");
    if macos && chromium.is_file() {
        install_chromium(host, &chromium)?;
    }
    Ok(String::from_utf8(result.stdout)?.trim_end().into())
}
struct Tunnel {
    host: String,
    port: u16,
    remote: u16,
    child: Child,
    retry: Instant,
}
impl Tunnel {
    fn command(host: &str, port: u16, remote: u16) -> Command {
        let mut command = Command::new("ssh");
        command.args([
            "-N",
            "-T",
            "-o",
            "ExitOnForwardFailure=yes",
            "-o",
            "ConnectTimeout=15",
            "-o",
            "ServerAliveInterval=15",
            "-o",
            "ServerAliveCountMax=3",
            "-L",
            &format!("127.0.0.1:{port}:127.0.0.1:{remote}"),
            host,
        ]);
        command
    }
    fn new(host: &str, remote: u16) -> Result<Self, Error> {
        let reservation = TcpListener::bind("127.0.0.1:0")?;
        let port = reservation.local_addr()?.port();
        drop(reservation);
        let child = Self::command(host, port, remote).spawn()?;
        Ok(Self {
            host: host.into(),
            port,
            remote,
            child,
            retry: Instant::now(),
        })
    }
    fn poll(&mut self) -> Result<(), Error> {
        if self.child.try_wait()?.is_some() && self.retry.elapsed() > Duration::from_secs(2) {
            eprintln!("Reconnecting SSH tunnel to {}…", self.host);
            self.child = Self::command(&self.host, self.port, self.remote).spawn()?;
            self.retry = Instant::now();
        }
        Ok(())
    }
}
impl Drop for Tunnel {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
struct ConnectionFile(PathBuf);
impl Drop for ConnectionFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
fn launch_client(path: &Path) -> Result<Child, Error> {
    let exe = std::env::current_exe()?;
    let parent = exe.parent().ok_or("No executable parent")?;
    if parent.join("../../../MacOS/GraffittyRuntime").is_file() && parent.join("gft-gui").is_file() {
        return Ok(Command::new(parent.join("gft-gui"))
            .arg("--")
            .arg(format!("--remote-connections={}", path.display()))
            .spawn()?);
    }
    #[cfg(any(windows, target_os = "linux"))]
    {
        let launcher = parent.join("..").join(if cfg!(windows) { "Graffitty.exe" } else { "gft-gui" });
        if launcher.is_file() {
            return Ok(Command::new(launcher)
                .arg("--")
                .arg(format!("--remote-connections={}", path.display()))
                .spawn()?);
        }
    }
    let checkout = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let bundled = parent.join("GraffittyRuntime").is_file();
    let root = if bundled {
        parent.join("../Resources/graffitty")
    } else if checkout.join("frontends/godot/project/project.godot").is_file() {
        checkout.join("frontends/godot/project")
    } else {
        parent.join("..")
    };
    let runtime = std::env::var_os("GRAFFITTY_GODOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            if bundled {
                parent.join("GraffittyRuntime")
            } else {
                PathBuf::from("godot")
            }
        });
    let mut command = Command::new(runtime);
    command.arg("--path").arg(&root);
    if !root.join("project.godot").is_file() {
        command.arg("--main-pack").arg(root.join("terminal.pck"));
    }
    command
        .arg("res://scenes/terminal.tscn")
        .arg("--")
        .arg(format!("--remote-connections={}", path.display()));
    Ok(command.spawn()?)
}
pub fn run(command: RemoteCommand) -> Result<(), Error> {
    let RemoteCommand::Connect(RemoteConnect {
        hosts,
        alias,
        workspace,
        server_binary,
        no_gui,
    }) = command;
    let running = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
    let stop = running.clone();
    ctrlc::set_handler(move || stop.store(false, std::sync::atomic::Ordering::Relaxed))?;
    if hosts.is_empty() {
        return Err("Specify one or more SSH hosts".into());
    }
    if let Some(alias) = &alias {
        if hosts.len() != 1 || !graffitty_protocol::controller::valid_alias(alias) {
            return Err("--alias requires one host and 1–64 letters, numbers, dots, underscores or hyphens, starting with a letter or number".into());
        }
    }
    if workspace.len() > 64
        || !workspace
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
    {
        return Err(
            "Workspace must be empty or use 1–64 letters, numbers, dots, underscores or hyphens".into(),
        );
    }
    let mut tunnels = Vec::new();
    let mut connections = vec![];
    let mut controllers = Vec::new();
    for host in hosts {
        let descriptor = prepare(&host, server_binary.as_deref().map(Path::new))?;
        let remote = remote_port(&descriptor)?;
        let tunnel = Tunnel::new(&host, remote)?;
        let url = format!("ws://127.0.0.1:{}", tunnel.port);
        let identity = format!("ssh:{host}");
        if no_gui && let Some(alias) = &alias {
            let deadline = Instant::now() + Duration::from_secs(15);
            while std::net::TcpStream::connect(("127.0.0.1", tunnel.port)).is_err() {
                if Instant::now() >= deadline { return Err("SSH tunnel did not become ready".into()); }
                thread::sleep(Duration::from_millis(25));
            }
            let authenticated = graffitty_transport::authenticate(&url, descriptor["token"].as_str().ok_or("Missing server password")?, None)
                .map_err(|e| e.to_string())?;
            let graffitty_transport::Authentication::Connected(transport) = authenticated else {
                return Err("This server requires Telegram verification; connect through the GUI".into());
            };
            controllers.push(graffitty_transport::controller::Attached::new(transport,
                &graffitty_transport::controller::state_directory().map_err(|e| e.to_string())?, alias, &identity)
                .map_err(|e| e.to_string())?);
        }
        connections.push(json!({"name":host,"alias":alias.as_deref().unwrap_or(""),"credential_id":identity,"transient":true,"url":url,"token":descriptor["token"],"initial_session":workspace}));
        tunnels.push(tunnel);
    }
    let path = std::env::temp_dir().join(format!(
        "graffitty-connections-{}.json",
        uuid::Uuid::new_v4()
    ));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&path)?;
    file.write_all(json!({"connections":connections}).to_string().as_bytes())?;
    let connection_file = ConnectionFile(path);
    let mut gui = if no_gui {
        println!("{}", connection_file.0.display());
        None
    } else {
        Some(launch_client(&connection_file.0)?)
    };
    eprintln!("SSH tunnels are active. Closing the client detaches; server shells keep running.");
    while running.load(std::sync::atomic::Ordering::Relaxed) {
        if let Some(gui) = gui.as_mut() {
            if gui.try_wait()?.is_some() {
                return Ok(());
            }
        }
        for tunnel in &mut tunnels {
            tunnel.poll()?;
        }
        for controller in &mut controllers { controller.poll().map_err(|e| e.to_string())?; }
        thread::sleep(Duration::from_millis(if controllers.is_empty() { 100 } else { 5 }));
    }
    if let Some(gui) = gui.as_mut() {
        let _ = gui.kill();
        let _ = gui.wait();
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn local_only_server_explains_how_to_enable_remote_access() {
        let error = remote_port(&json!({"url":"ipc:///tmp/session.sock"}))
            .unwrap_err()
            .to_string();
        assert!(error.contains("no remote listener"));
        assert!(error.contains("Existing sessions are still running"));
    }

    #[test]
    fn listener_port_requires_a_valid_network_descriptor() {
        assert_eq!(
            remote_port(&json!({"url":"ws://127.0.0.1:7183"})).unwrap(),
            7183
        );
        assert_eq!(
            remote_port(&json!({"url":"ws://[::1]:7183"})).unwrap(),
            7183
        );
        for url in [
            "ws://127.0.0.1:0", "ws://127.0.0.1:65536", "ws://invalid:12", "ipc:12",
            "ws://127.0.0.1:12/path",
        ] {
            assert!(remote_port(&json!({"url":url})).is_err(), "{url}");
        }
        assert!(remote_port(&json!({})).is_err());
    }
    #[test]
    fn destinations_cannot_inject_ssh_options() {
        for s in ["-oProxyCommand=evil", "bad\nname", ""] {
            assert!(validate_host(s).is_err());
        }
        assert!(validate_host("user@build-server").is_ok());
    }
}
