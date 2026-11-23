//! Resolve the executable to start without making the SSH user's login PATH
//! part of the installation contract.
use super::{Error, install_unix_binary, install_windows_binary, output, powershell, release, ssh};
use crate::installer;
use std::{
    fs, io,
    path::Path,
    process::{Command, Stdio},
};

pub(super) struct Platform {
    os: &'static str,
    arch: String,
}

pub(super) enum Resolved {
    Executable(String),
    Running(String),
}

fn sh_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn ps_quote(value: &str) -> String {
    // PowerShell also recognizes typographic quotation marks as delimiters.
    let mut quoted = String::from("'");
    for c in value.chars() {
        if matches!(c, '\'' | '‘' | '’' | '‚' | '‛') {
            quoted.push('\'');
        }
        quoted.push(c);
    }
    quoted.push('\'');
    quoted
}

impl Platform {
    pub fn detect(host: &str) -> Result<Self, Error> {
        let probe = "uname -s; uname -m";
        let (os, arch) = match output(host, probe).ok().and_then(|s| {
            let (os, arch) = s.split_once('\n')?;
            Some((
                match os {
                    "Darwin" => "macos",
                    "Linux" => "linux",
                    _ => return None,
                },
                arch.to_owned(),
            ))
        }) {
            Some(("macos", arch))
                if arch == "x86_64"
                    && output(host, "sysctl -n hw.optional.arm64").as_deref().ok() == Some("1") =>
            {
                ("macos", "arm64".into())
            }
            Some(platform) => platform,
            None => (
                "windows",
                output(
                    host,
                    &powershell(
                        "if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }",
                    ),
                )?,
            ),
        };
        let arch = match arch.as_str() {
            "aarch64" | "arm64" | "ARM64" => "aarch64".into(),
            "amd64" | "AMD64" => "x86_64".into(),
            _ => arch,
        };
        Ok(Self { os, arch })
    }

    fn windows(&self) -> bool {
        self.os == "windows"
    }

    fn asset(&self) -> Result<&'static str, Error> {
        match (self.os, self.arch.as_str()) {
            ("linux", "aarch64") => Ok("graffitty-linux-arm64.tar.gz"),
            ("linux", "x86_64") => Ok("graffitty-linux-x86_64.tar.gz"),
            ("macos", "aarch64") => Ok("graffitty-macos-arm64.tar.gz"),
            ("windows", "x86_64") => Ok("graffitty-windows-x64.zip"),
            _ => Err(format!(
                "No published platform for {}/{}; use --server-binary PATH",
                self.os, self.arch
            )
            .into()),
        }
    }

    fn script_name(&self) -> &'static str {
        if self.windows() {
            "install.ps1"
        } else {
            "install.sh"
        }
    }

    fn probe_command(&self, version: &str) -> String {
        let expected = format!("gft {version}");
        if self.windows() {
            powershell(&format!(
                "$expected={}\n{}",
                ps_quote(&expected),
                include_str!("windows-probe.ps1")
            ))
        } else {
            let other = if self.os == "macos" {
                r#""${GRAFFITTY_APP_DIR:-/Applications}/Graffitty.app/Contents/Resources/graffitty/tools/gft""#
            } else {
                r#""${GRAFFITTY_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/graffitty/installs}/current/tools/gft""#
            };
            let script = format!(
                "expected={}\nset -- \"${{GRAFFITTY_BIN_DIR:-$HOME/.local/bin}}/gft\" {other}\n{}",
                sh_quote(&expected),
                include_str!("unix-probe.sh")
            );
            format!("sh -c {}", sh_quote(&script))
        }
    }

    fn probe(&self, host: &str, version: &str) -> Result<Option<Resolved>, Error> {
        let response = output(host, &self.probe_command(version))?;
        if response.is_empty() {
            return Ok(None);
        }
        match response.split_once('\n') {
            Some((kind, value)) if kind.trim_end() == "installed" => {
                Ok(Some(Resolved::Executable(value.into())))
            }
            Some((kind, value)) if kind.trim_end() == "running" => {
                Ok(Some(Resolved::Running(value.into())))
            }
            _ => Err("Unexpected response probing the Graffitty installation".into()),
        }
    }

    pub fn start_command(&self, path: &str) -> String {
        if self.windows() {
            powershell(&format!(
                "$server={}\n{}",
                ps_quote(path),
                include_str!("windows-start.ps1")
            ))
        } else {
            let script = format!(
                "server={}\n{}",
                sh_quote(path),
                include_str!("unix-start.sh")
            );
            format!("sh -c {}", sh_quote(&script))
        }
    }

    fn upload_binary(&self, host: &str, artifact: &Path) -> Result<Resolved, Error> {
        eprintln!(
            "Uploading {} for {}/{} on {host}…",
            artifact.display(),
            self.os,
            self.arch
        );
        let path = if self.windows() {
            install_windows_binary(host, artifact)?
        } else {
            install_unix_binary(host, artifact, self.os == "macos")?
        };
        Ok(Resolved::Executable(path))
    }

    fn development_binary(&self, tag: &str) -> Result<std::path::PathBuf, Error> {
        if self.os != std::env::consts::OS || self.arch != std::env::consts::ARCH {
            return Err(format!("No published release for {tag}. For {}/{}, pass --server-binary PATH to gft remote connect.", self.os, self.arch).into());
        }
        Ok(std::env::current_exe()?)
    }

    fn development(&self, host: &str, tag: &str) -> Result<Resolved, Error> {
        let binary = self.development_binary(tag)?;
        eprintln!("No published release for {tag}; using this development executable.");
        self.upload_binary(host, &binary)
    }

    /// Staging directories are fresh, private children of the SSH account's
    /// home. SFTP and the remote shell refer to the same generated name.
    fn directory_command(&self, name: &str, create: bool) -> String {
        if self.windows() {
            let operation = if create {
                "New-Item -ItemType Directory -Path $dir | Out-Null"
            } else {
                "Remove-Item -LiteralPath $dir -Recurse -Force"
            };
            powershell(&format!(
                "$ErrorActionPreference='Stop'; $dir=Join-Path $HOME '{}'; {operation}",
                name
            ))
        } else {
            let operation = if create {
                "umask 077 && mkdir"
            } else {
                "rm -rf"
            };
            format!("{operation} \"$HOME/{name}\"")
        }
    }

    fn install_command(&self, tag: &str, source: &str) -> String {
        let url = installer::script_url(self.windows());
        if self.windows() {
            powershell(&format!(
                "$env:GRAFFITTY_VERSION={}\n$scriptUrl={}\n$source={}\n{}",
                ps_quote(tag),
                ps_quote(url),
                ps_quote(source),
                include_str!("windows-install.ps1")
            ))
        } else {
            format!(
                "sh -c {} sh {} {} {}",
                sh_quote(include_str!("unix-install.sh")),
                sh_quote(tag),
                sh_quote(url),
                sh_quote(source)
            )
        }
    }
}

/// Keep stdout exclusively for the connection-file path in --no-gui mode.
fn run_installer(host: &str, command: &str) -> Result<bool, Error> {
    let status = ssh(host)
        .arg(command)
        .stdin(Stdio::null())
        .stdout(Stdio::from(io::stderr()))
        .status()?;
    match status.code() {
        Some(0) => Ok(true),
        Some(75) => Ok(false),
        _ => Err(format!("Installer on {host} failed ({status})").into()),
    }
}

fn upload_release(
    host: &str,
    platform: &Platform,
    dir: &Path,
    tag: &str,
    asset: &str,
) -> Result<(), Error> {
    let name = format!(".graffitty-install-{}", uuid::Uuid::new_v4().simple());
    output(host, &platform.directory_command(&name, true))?;
    let installed = (|| -> Result<(), Error> {
        let status = Command::new("scp")
            .args(["-o", "ConnectTimeout=15"])
            .arg(dir.join(platform.script_name()))
            .arg(dir.join(format!("{tag}.txt")))
            .arg(dir.join(asset))
            .arg(format!("{host}:{name}/"))
            .status()?;
        if !status.success() {
            return Err(format!("Could not upload the release to {host} ({status})").into());
        }
        if !run_installer(host, &platform.install_command(tag, &name))? {
            return Err(format!("The installer on {host} failed with the uploaded {asset}").into());
        }
        Ok(())
    })();
    let cleanup = output(host, &platform.directory_command(&name, false));
    installed?;
    cleanup?;
    Ok(())
}

pub(super) fn resolve(
    host: &str,
    platform: &Platform,
    binary: Option<&Path>,
) -> Result<Resolved, Error> {
    if let Some(artifact) = binary {
        return platform.upload_binary(host, artifact);
    }
    let version = env!("GRAFFITTY_VERSION");
    if let Some(found) = platform.probe(host, version)? {
        eprintln!("Reusing Graffitty on {host}.");
        return Ok(found);
    }
    let tag = format!("v{version}");
    if !installer::valid_tag(&tag) {
        return platform.development(host, &tag);
    }

    let installed = || {
        platform
            .probe(host, version)?
            .ok_or_else(|| format!("The installer on {host} did not provide gft {version}").into())
    };
    let releases = release::Releases::configured()?;
    if let release::Releases::Https(url) = &releases
        && platform.asset().is_ok()
    {
        eprintln!(
            "Installing Graffitty {tag} on {host} ({}/{})…",
            platform.os, platform.arch
        );
        if run_installer(
            host,
            &platform.install_command(&tag, url.as_str().trim_end_matches('/')),
        )? {
            return installed();
        }
        eprintln!("Remote install failed; checking the {tag} release on this computer…");
    }
    let client = installer::client()?;
    let Some(listing) = releases.listing(&client, &tag)? else {
        return platform.development(host, &tag);
    };
    let asset = platform.asset()?;
    let staging = tempfile::tempdir()?;
    eprintln!("Preparing and verifying {asset} for {host}…");
    release::stage(&releases, &client, &listing, &tag, asset, staging.path())?;
    fs::write(
        staging.path().join(platform.script_name()),
        installer::fetch(installer::script_url(platform.windows()))?,
    )?;
    eprintln!("Uploading {asset} and the installer to {host}…");
    upload_release(host, platform, staging.path(), &tag, asset)?;
    installed()
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    fn platform(os: &'static str, arch: &str) -> Platform {
        Platform {
            os,
            arch: arch.into(),
        }
    }

    fn decode_powershell(cmd: &str) -> String {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(cmd.split_whitespace().last().unwrap())
            .unwrap();
        String::from_utf16(
            &bytes
                .chunks_exact(2)
                .map(|b| u16::from_le_bytes([b[0], b[1]]))
                .collect::<Vec<_>>(),
        )
        .unwrap()
    }

    #[test]
    fn windows_probes_the_installed_cli_and_starts_the_resolved_path() {
        let win = platform("windows", "x86_64");
        let probe = decode_powershell(&win.probe_command("1.2.3"));
        assert!(probe.contains("$expected='gft 1.2.3'"));
        assert!(probe.contains(r"Programs\Graffitty\tools\gft.exe"));
        assert!(probe.contains("& $candidate --version"));
        assert!(probe.contains("$actual -ceq $expected"));
        let online =
            decode_powershell(&win.install_command("v1.2.3", "https://example.invalid/releases"));
        assert!(online.contains("$env:GRAFFITTY_VERSION='v1.2.3'"));
        assert!(online.contains("$env:GRAFFITTY_NO_DESKTOP = '1'"));
        assert!(online.contains("https://graffitty.com/install.ps1"));
        assert!(online.contains("Invoke-WebRequest -UseBasicParsing -Uri $scriptUrl"));
        let offline = decode_powershell(&win.install_command("v1.2.3", ".graffitty-install-test"));
        assert!(offline.contains("$source='.graffitty-install-test'"));
        assert!(offline.contains("Join-Path $HOME $source"));
        assert!(offline.contains("Join-Path $env:GRAFFITTY_RELEASES 'install.ps1'"));
        let start = decode_powershell(&win.start_command(r"C:\O'Brien\tools\gft.exe"));
        assert!(start.contains(r"$server='C:\O''Brien\tools\gft.exe'"));
        assert!(start.contains("$info.FileName = $server"));
        assert!(start.contains(" server --listen "));
        assert_eq!(win.asset().unwrap(), "graffitty-windows-x64.zip");
        assert!(platform("windows", "aarch64").asset().is_err());
    }

    #[test]
    fn unpublished_version_uses_only_a_matching_client_executable() {
        let same = platform(std::env::consts::OS, std::env::consts::ARCH);
        assert_eq!(
            same.development_binary("v1.2.3-dev").unwrap(),
            std::env::current_exe().unwrap()
        );
        for remote in [
            platform("different-os", &same.arch),
            platform(same.os, "different-cpu"),
        ] {
            assert!(
                remote
                    .development_binary("v1.2.3-dev")
                    .unwrap_err()
                    .to_string()
                    .contains("--server-binary")
            );
        }
    }

    #[cfg(unix)]
    mod unix {
        use super::*;
        use std::os::unix::fs::{PermissionsExt, symlink};
        use std::process::Output;

        fn executable(path: &Path, script: &str) {
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, script).unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
        }

        fn shell(home: &Path, cmd: &str, path: &Path) -> Output {
            Command::new("/bin/sh")
                .args(["-c", cmd])
                .env_clear()
                .env("HOME", home)
                .env("GRAFFITTY_APP_DIR", home.join("Apps' folder"))
                .env("PATH", path)
                .output()
                .unwrap()
        }

        #[test]
        fn probes_installer_locations_without_a_login_path_and_checks_exact_version() {
            for (os, relative) in [
                ("linux", ".local/bin/gft"),
                ("linux", ".local/share/graffitty/installs/current/tools/gft"),
                (
                    "macos",
                    "Apps' folder/Graffitty.app/Contents/Resources/graffitty/tools/gft",
                ),
            ] {
                let home = tempfile::tempdir().unwrap();
                let exe = home.path().join(relative);
                executable(
                    &exe,
                    "#!/bin/sh\n[ \"$1\" = --version ] || exit 1\necho 'gft 1.2.3'\n",
                );
                let platform = platform(os, "aarch64");
                let probe = |version| {
                    shell(
                        home.path(),
                        &platform.probe_command(version),
                        Path::new("/bin"),
                    )
                };
                let result = probe("1.2.3");
                assert!(result.status.success());
                assert_eq!(
                    String::from_utf8(result.stdout).unwrap(),
                    format!("installed\n{}\n", exe.display())
                );
                let mismatch = probe("1.2.30");
                assert!(mismatch.status.success() && mismatch.stdout.is_empty());
            }
        }

        #[test]
        fn a_live_descriptor_survives_an_absent_binary_and_a_stale_descriptor_is_ignored() {
            let home = tempfile::tempdir().unwrap();
            let state = home.path().join(".local/state/graffitty");
            fs::create_dir_all(&state).unwrap();
            fs::write(state.join("server.json"), "{}").unwrap();
            let lock = fs::File::create(state.join("server.lock")).unwrap();
            let cmd = platform("linux", "aarch64").probe_command("1.2.3");
            let probe = || shell(home.path(), &cmd, Path::new("/usr/bin:/bin"));
            fs2::FileExt::lock_exclusive(&lock).unwrap();
            assert_eq!(probe().stdout, b"running\n{}");
            drop(lock);
            let stale = probe();
            assert!(stale.status.success() && stale.stdout.is_empty());
        }

        #[test]
        fn fresh_start_waits_for_the_descriptor_before_probing_the_lock() {
            let home = tempfile::tempdir().unwrap();
            let bin = home.path().join("custom gft");
            executable(
                &bin,
                r#"#!/bin/sh
case "$2" in
    --listen)
        sleep 0.2
        printf '{}\n' > "$5"
        ;;
    --connection)
        if [ ! -s "$3" ]; then touch "$HOME/early-status"; exit 1; fi
        cat "$3"
        ;;
esac"#,
            );
            let cmd = platform("linux", "aarch64").start_command(bin.to_str().unwrap());
            let result = shell(home.path(), &cmd, Path::new("/usr/bin:/bin"));
            assert!(result.status.success());
            assert_eq!(result.stdout, b"{}\n");
            assert!(!home.path().join("early-status").exists());
        }

        #[test]
        fn online_install_uses_curl_or_wget_and_offline_install_uses_the_uploaded_script() {
            let home = tempfile::tempdir().unwrap();
            let bin = home.path().join("bin");
            fs::create_dir(&bin).unwrap();
            for tool in ["sh", "mktemp", "rm", "tee", "grep"] {
                symlink(
                    if Path::new("/usr/bin").join(tool).is_file() {
                        Path::new("/usr/bin").join(tool)
                    } else {
                        Path::new("/bin").join(tool)
                    },
                    bin.join(tool),
                )
                .unwrap();
            }
            let script = "#!/bin/sh\nprintf '%s\\n' \"$GRAFFITTY_VERSION\" \"$GRAFFITTY_NO_DESKTOP\" \"$GRAFFITTY_RELEASES\"";
            let stage = home.path().join(".graffitty-install-test");
            executable(&stage.join("install.sh"), script);
            let linux = platform("linux", "x86_64");
            let mirror = "https://example.invalid/release's";
            let online = linux.install_command("v1.2.3", mirror);
            let offline = linux.install_command("v1.2.3", ".graffitty-install-test");
            let run = |cmd: &str| shell(home.path(), cmd, &bin);
            assert_eq!(run(&online).status.code(), Some(75));
            assert_eq!(
                String::from_utf8(run(&offline).stdout).unwrap(),
                format!("v1.2.3\n1\n{}\n", stage.display())
            );
            for downloader in ["wget", "curl"] {
                executable(
                    &bin.join(downloader),
                    "#!/bin/sh\nwhile [ \"$1\" != -o ] && [ \"$1\" != -O ]; do shift; done\n[ \"$3\" = 'https://graffitty.com/install.sh' ] || exit 1\n/bin/cp \"$HOME/.graffitty-install-test/install.sh\" \"$2\"",
                );
                let result = run(&online);
                assert!(result.status.success());
                assert_eq!(
                    String::from_utf8(result.stdout).unwrap(),
                    format!("v1.2.3\n1\n{mirror}\n")
                );
            }
            for (error, code) in [
                ("could not download archive", 75),
                ("checksum mismatch for archive", 1),
            ] {
                executable(
                    &stage.join("install.sh"),
                    &format!("#!/bin/sh\necho 'graffitty: error: {error}' >&2\nexit 1\n"),
                );
                assert_eq!(run(&online).status.code(), Some(code));
            }
        }
    }
}
