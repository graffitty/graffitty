# Remote connection settings

Configure these on the computer running your sessions.

## Listen on the right network

Open **Sessions → Remote Access Settings…** on the host. Choose **Enable remote access**, enter the **Listen IP address** and **Listen port**, then select **Save**.

You can also configure startup in `~/.config/graffitty/server.toml`.

```toml
[remote]
enabled = true
bind_address = "127.0.0.1"
port = 7183
```

- `127.0.0.1` accepts local connections and SSH tunnels only.
- For a phone or tablet on the same Wi-Fi, use the host computer’s LAN IP for both the bind address and the server address on the mobile device.
- For Tailscale, run `tailscale ip -4` and use that computer's address.
- `enabled = true` starts sharing automatically.

Apply direct file edits with a [server restart](../customize/server-configuration.md#reload-server-configuration).
An unavailable address prevents sharing. Update the setting if its Tailscale address changes.

## Enter a server address

A bare hostname uses `ws://` on port **7183**. An explicit `wss://` address uses
TLS and defaults to **443**.

Leave the session name blank to resume the remembered or server-selected session.
A name selects or creates a session; it does not restrict access to that session.
Saved passwords enter the device credential store after successful login.

## Understand encryption

Terminal data and verification codes are encrypted after login, including over
`ws://`. OPAQUE verifies the password without sending the password itself.

On `ws://`, setup metadata and framing remain visible. Use trusted TLS,
Tailscale, or SSH for additional protection. Addresses, timing, and traffic sizes
can still be observable.

## Set up the server over SSH

```sh
gft remote connect user@computer
```

Graffitty checks the remote installation with `gft --version`. If it needs to
install Graffitty, it runs the standard installer pinned to your client’s
version. The installer selects the release for the remote OS and CPU. If that
computer cannot download it, the client verifies the archive’s SHA-256 and
uploads it with the installer over SSH.

Graffitty starts or reuses the remote server and connects through an SSH tunnel.
OpenSSH handles authentication, host-key checks, and SSH aliases. For a custom
build, pass `--server-binary PATH` with a `gft` executable built for the
destination. See [SSH server deployment](../developers/build-and-run/remote-server.md).

The client keeps the tunnel open and retries dropped connections. Closing it
closes tunnels while remote shells continue. A remote reboot ends the programs;
the server is not installed as a boot service.

For several hosts, pass their SSH aliases together:

```sh
gft remote connect build-server home-pc laptop
```

## Plain `ssh` from a Graffitty terminal

If you run `ssh user@remote-host` inside a terminal pane, install the Ghostty terminfo once on that host so shell programs recognize the terminal. This command writes to `~/.terminfo` on the remote host:

```sh
infocmp -x xterm-ghostty | ssh user@remote-host -- tic -x -
```
