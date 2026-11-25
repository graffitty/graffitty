//! Launch the tunnel owner in a desktop terminal so OpenSSH can use its TTY.
use super::{Error, RemoteConnect};
use std::path::Path;
use std::process::Command;

fn child_args(options: &RemoteConnect) -> Result<Vec<String>, Error> {
    let mut args = vec!["remote".into(), "connect".into()];
    if let Some(alias) = &options.alias {
        args.extend(["--alias".into(), alias.clone()]);
    }
    if !options.workspace.is_empty() {
        args.extend(["--workspace".into(), options.workspace.clone()]);
    }
    if let Some(binary) = &options.server_binary {
        // Terminal emulators can start the child in a different working directory.
        args.extend([
            "--server-binary".into(),
            std::path::absolute(binary)?
                .into_os_string()
                .into_string()
                .map_err(|_| "Invalid server binary path")?,
        ]);
    }
    if options.no_gui {
        args.push("--no-gui".into());
    }
    args.extend(options.hosts.iter().cloned());
    Ok(args)
}

pub(super) fn launch(options: &RemoteConnect) -> Result<(), Error> {
    open(&std::env::current_exe()?, &child_args(options)?)
}

#[cfg(unix)]
const RUN: &str = r#""$@"
status=$?
if [ "$status" -ne 0 ]; then
    printf '\nPress Enter to close...'
    read -r unused
fi
exit "$status""#;

#[cfg(target_os = "macos")]
fn open(executable: &Path, args: &[String]) -> Result<(), Error> {
    use std::{io::Write, os::unix::fs::PermissionsExt};
    // Opening a .command file uses Terminal's normal Launch Services route
    // without asking for permission to automate Terminal via Apple Events.
    let mut script = tempfile::Builder::new()
        .prefix("Graffitty-SSH-")
        .suffix(".command")
        .tempfile()?;
    writeln!(script, "#!/bin/sh\nrm -f -- \"$0\"")?;
    write!(
        script,
        "set -- {}",
        super::deploy::sh_quote(executable.to_str().ok_or("Invalid gft executable path")?)
    )?;
    for arg in args {
        write!(script, " {}", super::deploy::sh_quote(arg))?;
    }
    writeln!(script, "\n{RUN}")?;
    script
        .as_file()
        .set_permissions(std::fs::Permissions::from_mode(0o700))?;
    let path = script.into_temp_path().keep()?;
    let result = Command::new("/usr/bin/open")
        .args(["-a", "Terminal"])
        .arg(&path)
        .status();
    if !result.as_ref().is_ok_and(|status| status.success()) {
        let _ = std::fs::remove_file(path);
        return Err(format!("Could not open Terminal ({})", result?).into());
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn open(executable: &Path, args: &[String]) -> Result<(), Error> {
    for (terminal, flags) in [
        ("xdg-terminal-exec", &[][..]),
        ("x-terminal-emulator", &["-e"][..]),
        ("gnome-terminal", &["--"][..]),
        ("konsole", &["-e"][..]),
        ("xterm", &["-e"][..]),
    ] {
        match Command::new(terminal)
            .args(flags)
            .args(["sh", "-c", RUN, "gft"])
            .arg(executable)
            .args(args)
            .spawn()
        {
            Ok(_) => return Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
        }
    }
    Err("Could not find a terminal emulator to open SSH".into())
}

#[cfg(windows)]
fn open(executable: &Path, args: &[String]) -> Result<(), Error> {
    use std::os::windows::process::CommandExt;
    // Keep profile values outside the PowerShell program. Array splatting
    // forwards literal arguments (including $ID) to the CLI in its new console.
    let command = r#"$a = @(ConvertFrom-Json $env:GFT_SSH_TERMINAL_ARGS)
& $env:GFT_SSH_TERMINAL_EXE @a
if ($LASTEXITCODE -ne 0) { Read-Host 'Press Enter to close' }"#;
    Command::new("powershell.exe")
        .args(["-NoLogo", "-NoProfile", "-Command", command])
        .env("GFT_SSH_TERMINAL_EXE", executable)
        .env("GFT_SSH_TERMINAL_ARGS", serde_json::to_string(args)?)
        .creation_flags(0x00000010) // CREATE_NEW_CONSOLE
        .spawn()?;
    Ok(())
}

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
fn open(_: &Path, _: &[String]) -> Result<(), Error> {
    Err("Opening SSH in a terminal requires a desktop".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "opens a macOS Terminal window"]
    fn terminal_runs_child_with_a_tty_and_literal_profile_fields() {
        let dir = tempfile::tempdir().unwrap();
        let output = dir.path().join("received");
        let args = [
            "-c",
            r#"test -t 0 && test -t 1 && test -t 2 && printf '%s' "$2" > "$1""#,
            "gft-test",
            output.to_str().unwrap(),
            "file with 'quotes' and $2",
        ]
        .map(String::from);
        open(Path::new("/bin/sh"), &args).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        while !output.exists() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        assert_eq!(std::fs::read_to_string(output).unwrap(), args[4]);
    }

    #[test]
    fn forwards_connection_options_without_reopening_a_terminal() {
        let options = RemoteConnect {
            hosts: vec!["user@Build".into()],
            alias: Some("desk".into()),
            workspace: "$2".into(),
            server_binary: Some("binary with spaces".into()),
            no_gui: true,
            terminal: true,
        };
        let args = child_args(&options).unwrap();
        assert_eq!(
            &args[..7],
            [
                "remote",
                "connect",
                "--alias",
                "desk",
                "--workspace",
                "$2",
                "--server-binary"
            ]
        );
        assert!(Path::new(&args[7]).is_absolute());
        assert_eq!(&args[8..], ["--no-gui", "user@Build"]);
    }
}
