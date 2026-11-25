# Remote access

Use another computer's terminals, browsers, and agents from desktop or Android.
Programs keep running there when you disconnect.

## Connect to a Graffitty server (recommended)

On the computer that will run your sessions, install Graffitty and choose one of the three setup methods below. For a direct connection, use the host’s LAN address on trusted Wi-Fi or its Tailscale address. [Network settings](connection-settings.md#listen-on-the-right-network)

### Use the desktop GUI

1. Open **Sessions → Remote Access Settings…** and turn on **Enable remote access**.
2. Set **Listen IP address** to the host’s LAN or Tailscale IP and **Listen port** to `7183`.
3. Choose **Temporary password** or **Manual password only**, then select **Save**. The running server applies the settings immediately and remembers them for its next launch.

### Edit server.toml

On the host, edit `~/.config/graffitty/server.toml` (or `$XDG_CONFIG_HOME/graffitty/server.toml`). Replace the example address with the host’s actual LAN or Tailscale IP.

```toml
[remote]
enabled = true
bind_address = "192.0.2.10" # Example address. Replace before starting the server.
port = 7183
```

To use a permanent password, run `gft server --set-password`. If the server is already running, reload the file while keeping terminals alive:

```sh
gft checkpoint save
gft server restart
```

### Start the listener from the CLI

```sh
curl -fsSL https://graffitty.com/install.sh | sh
gft server --set-password
gft server --listen 0.0.0.0:7183
```

`0.0.0.0` listens on every IPv4 interface. To listen on just one network, substitute the host’s address on that network.

### Connect from the other device

1. Open **Sessions → Servers… → Add server**, or **Add server** on Android.
2. Enter the host’s LAN or Tailscale address, port, and password.
3. Leave the session name blank to resume the previous session.

Sharing is off by default. Android requires a server and has no local terminal mode.

### Or set it up over SSH

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
