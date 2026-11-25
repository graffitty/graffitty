# Remote access

Use another computer's terminals, browsers, and agents from desktop or Android.
Programs keep running there when you disconnect.

## Connect to a Graffitty server (recommended)

On the computer that will run your sessions, choose **one** way to enable sharing.

**Desktop GUI** — Open **Sessions → Remote Access Settings…** and turn on **Enable remote access**. Enter the host’s LAN or Tailscale IP, leave the port at `7183`, choose a password mode, and select **Save**.

**Configuration file** — Edit `~/.config/graffitty/server.toml` (or `$XDG_CONFIG_HOME/graffitty/server.toml`). Replace the example IP with the host’s LAN or Tailscale address.

```toml
[remote]
enabled = true
bind_address = "192.0.2.10"
port = 7183
```

For a permanent password, run `gft server --set-password`. If the server is already running, [reload its configuration](../customize/server-configuration.md#reload-server-configuration).

**Command line** — Set a password and start the listener. Replace `192.0.2.10` with the host’s LAN or Tailscale IP.

```sh
gft server --set-password
gft server --listen 192.0.2.10:7183
```

### Connect from the other device

1. Open **Sessions → Servers… → Add server**, or **Add server** on Android.
2. Enter the host’s LAN or Tailscale address, port, and password.
3. Leave the session name blank to resume the previous session.

Sharing is off by default. Android requires a server and has no local terminal mode.

## Connect over SSH instead

```sh
gft remote connect user@remote-host
```

`user@remote-host` is an SSH destination. Graffitty reuses the same version
if it is already installed there. Otherwise it runs the standard installer
for the remote OS and CPU. If the remote cannot download the release, your
computer uploads it over SSH. The connection uses an SSH tunnel, so you only
need SSH access to the remote. See [connection settings](connection-settings.md#set-up-the-server-over-ssh).

## Plain `ssh` from a Graffitty terminal

Graffitty uses Ghostty, so remote computers need its terminfo. Run this once
per remote; it installs to `~/.terminfo` there:

```sh
infocmp -x xterm-ghostty | ssh user@remote-host -- tic -x -
```

## Leave safely

**Disconnect** or **Detach** leaves programs running. To end one session and its
programs, right-click it in the **Sessions** list and choose **Kill Session**.
Other sessions keep running. A server with remote access enabled stays online
even after its last session ends. A private server exits when its last session ends.

Turning sharing off disconnects remote clients while local sessions continue.
Input typed during a network outage is discarded.

## Next steps

- [Passwords and optional login codes](authentication.md).
- [Saved servers and remote CLI targets](saved-servers.md).
- [Browsers, Android controls, and uploads](connected-workspace.md).
- [Encryption details](connection-settings.md#understand-encryption).
