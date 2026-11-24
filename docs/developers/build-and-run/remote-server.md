# SSH server deployment

Run `gft remote connect user@computer` from the client. OpenSSH handles
authentication and host-key checks. For user setup, see [remote access](../../remote-access/index.md).

## Release installations

Graffitty reuses a running Graffitty server that holds the SSH connection descriptor’s lock. To start a server, it looks for
the client’s exact `gft --version` in the standard installer locations.

| Remote platform | Installer location |
| --- | --- |
| Linux | `~/.local/bin/gft` or `$XDG_DATA_HOME/graffitty/installs/current/tools/gft` (the data directory defaults to `~/.local/share`) |
| macOS | `~/.local/bin/gft` or `/Applications/Graffitty.app/Contents/Resources/graffitty/tools/gft` |
| Windows | `%LOCALAPPDATA%\Programs\Graffitty\tools\gft.exe` |

The Unix lookup also honors the remote account’s `GRAFFITTY_BIN_DIR`,
`GRAFFITTY_INSTALL_DIR` (Linux), and `GRAFFITTY_APP_DIR` (macOS).

On a fresh host or a version mismatch, the client runs the current
`install.sh` or `install.ps1` from graffitty.com over SSH. It sets
`GRAFFITTY_VERSION` to the client’s release tag and `GRAFFITTY_NO_DESKTOP=1`.
The remote downloads the archive for its own OS and CPU. If it cannot
download, the client reads the same release listing, verifies the archive’s
SHA-256, and uploads the archive, installer, and a one-entry listing. The
installer verifies the uploaded archive again. The client removes the staging
files after installation.

Set `GRAFFITTY_RELEASES` on the client to use a release mirror. An HTTPS base
URL is used on both computers. An absolute local directory is read on the
client and selects the upload path directly. The installer itself comes from
graffitty.com in either case.

## Development builds

To use a custom build, point the client at the executable built for the remote
platform. An adjacent filetree or macOS Chromium runtime archive from
`mise run server:bundle` is uploaded with it.

```sh
gft remote connect build-server --server-binary /path/to/gft
```

If the client version has no published release and its OS and CPU match the
destination, the client can upload its own executable. For other development
targets, supply `--server-binary`.

The Graffitty server descriptor and log for SSH connections on Linux and macOS are under
`~/.local/state/graffitty/`. Windows keeps the descriptor under
`%LOCALAPPDATA%\graffitty\state`. Hosts that terminate user processes on
logout need a service or session policy that allows persistence.

## One server per user

`gft server` without `--connection` and the app use the same descriptor:
`server.json` in the state directory (`$XDG_STATE_HOME/graffitty`, else
`~/.local/state/graffitty`, or `%LOCALAPPDATA%\graffitty` on Windows).

- The app attaches to a server already running there; it starts one only when none answers.
- A second `gft server` for the same descriptor is refused.
- If the `[remote]` address in `server.toml` is taken, the server still runs for this computer with remote access off. Its log and the app name what holds the address: another Graffitty server, or the program and its process number.
- An address given with `--listen` is the reason that server was started, so a taken one is fatal, with the same explanation.
- If a reused server exposes only local IPC, `remote connect` reports that it
  has no remote listener. Enable **Remote Access** in Graffitty on that computer
  before retrying; this preserves its running terminals. For a new headless
  server, start it with `gft server --listen 127.0.0.1:0`.

Opening an empty remote workspace creates its first shell automatically. The
frontend sends `session_new` with `if_empty: true`; the server attaches it to an
existing session if another client created one first. The check and creation
run together on the owner thread. Ordinary `session_new` still creates a new
session. A failed automatic spawn exposes Retry/Cancel instead of retrying on
every inventory update. Deliberately closing the last session does not respawn it.

## Keep a tunnel without opening a GUI

Complete any required Telegram code through a GUI connection first.

```sh
gft remote connect build-server --no-gui
```

- Keep the command running.
- Open its printed connection file with `gft-gui -- --remote-connections=PATH`.
- Ctrl+C closes the tunnel without stopping the remote server.
- Treat temporary connection files as secrets.

## Headless authentication

These commands save settings and exit; they do not start a listener:

```sh
gft server --set-password
gft server --temporary-password-length 8
gft server --telegram-credential graffitty-2fa --telegram-chat-id 123
gft server --telegram-credential off
gft server --clear-password
```

- `--set-password` uses a hidden local prompt.
- `--clear-password` returns to temporary passwords.
- Use `--auth-file PATH` for independent server credentials.
- Restart an already-running server to apply changes.
- Authentication state stores a password verifier, not the password. See [encryption and its limits](../../remote-access/connection-settings.md#understand-encryption) for transport protection.
