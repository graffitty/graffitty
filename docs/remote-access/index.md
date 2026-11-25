# Remote access

The **Graffitty server** runs your terminals, browsers, and agents on the remote computer. Your Graffitty client connects to that server either directly by IP address or through an SSH tunnel. Choose one connection method. Your programs keep running when you disconnect.

## Connect directly to the Graffitty server

On the remote computer, enable sharing using **one** of these methods.

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

## Connect to the Graffitty server through an SSH tunnel

If you have SSH access to the remote computer, run this on your **client computer**:

```sh
gft remote connect user@remote-host
```

**Which port?** Only the SSH port (usually `22`) needs to be reachable from your client. When this command starts a Graffitty server, it opens a port on the remote computer’s loopback address (`127.0.0.1`). SSH carries your client’s traffic to the remote computer and forwards it to that local port. You can leave port `7183` closed in the firewall.

**Which password?** Sign in to SSH as usual with your SSH key or account password. In temporary-password mode, `gft` retrieves the Graffitty password over SSH and supplies it to the server for you. A manually configured Graffitty password or a required verification code still applies. [SSH setup details](connection-settings.md#set-up-the-server-over-ssh)

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
- [Terminal setup for a regular SSH shell](connection-settings.md#plain-ssh-from-a-graffitty-terminal).
- [Encryption details](connection-settings.md#understand-encryption).
