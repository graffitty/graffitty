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

When you run this on your client computer, `gft` does the following:

1. **Log in over SSH.** OpenSSH checks the remote host key and authenticates your account using your usual SSH settings.
2. **Find Graffitty on the remote computer.** `gft` detects the OS and CPU and checks the installation. If it needs to install Graffitty, it selects the release matching your client. If the host cannot download it, the client verifies the archive and uploads it over SSH.
3. **Find or start the Graffitty server.** For a new server, `gft` requests `127.0.0.1:0`. The remote OS picks an available port on loopback. If the existing server only has a local IPC socket, setup stops here. Enable a loopback listener in **Remote Access Settings…** to keep using that server.
4. **Read the connection details over SSH.** The remote server reports its listening port and, in temporary-password mode, its generated password. A manually configured password is omitted.
5. **Open the tunnel.** `gft` picks a free port on your client and runs `ssh -N -T -L 127.0.0.1:CLIENT_PORT:127.0.0.1:SERVER_PORT user@computer` with the actual port numbers. SSH listens on the client port. For each connection there, the SSH service on the remote computer opens a connection to its own server port. Only the SSH port needs to be reachable across the network.
6. **Launch the Graffitty client and sign in.** The app connects to `ws://127.0.0.1:CLIENT_PORT` and performs Graffitty login through the tunnel. It uses the temporary password from step 4 when available. A manual password or required verification code still applies.

`gft` monitors the tunnel and retries if it drops. Closing the client closes the tunnel and leaves remote shells running. A remote reboot ends those programs.

For a custom build, pass `--server-binary PATH` with a `gft` executable built for the destination. [SSH server deployment](../developers/build-and-run/remote-server.md)

For several hosts, pass their SSH aliases together:

```sh
gft remote connect build-server home-pc laptop
```

## Plain `ssh` from a Graffitty terminal

If you run `ssh user@remote-host` inside a terminal pane, install the Ghostty terminfo once on that host so shell programs recognize the terminal. This command writes to `~/.terminfo` on the remote host:

```sh
infocmp -x xterm-ghostty | ssh user@remote-host -- tic -x -
```
