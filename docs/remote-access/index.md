# Remote access

Use another computer's terminals, browsers, and agents from desktop or Android.
Programs keep running there when you disconnect.

## Connect to a Graffitty server (recommended)

Graffitty connects to its own server on the other computer. Set it up in either way.

### Install it on the remote computer

```sh
curl -fsSL https://graffitty.com/install.sh | sh
gft server --set-password
gft server --listen 0.0.0.0:7183   # or its Tailscale IP
```

Use a [trusted network or Tailscale](connection-settings.md#listen-on-the-right-network).
On a desktop, open **Sessions → Remote Access Settings…** to enable sharing, set the listening address and port, and choose a password.

Then, on your other device:

1. Open **Sessions → Servers… → Add server**, or **Add server** on Android.
2. Enter the server address and password.
3. Leave the session name blank to resume the previous session.

Sharing is off by default. Saving the settings also sets the startup preference.
Android requires a server; it has no local terminal mode.

### Or set it up from your computer

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
