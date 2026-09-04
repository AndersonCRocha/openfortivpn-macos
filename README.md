# openfortivpn-macos

Multi-profile Fortinet SSL VPN manager for macOS — a lightweight CLI wrapper around [`openfortivpn`](https://github.com/adrienverge/openfortivpn) with a native SwiftBar tray, MFA support, macOS Keychain integration, and zsh completions.

Replaces the FortiClient GUI for people who juggle several Fortinet VPNs and want a fast, scriptable CLI + a menu-bar indicator instead.

## Features

- **Multiple profiles** — one command drives all your gateways
- **macOS Keychain** — passwords never touch disk
- **MFA prompt on the tray** — click a menu item, type the token, done
- **Auto-updates certificate hash** when Fortinet rotates it
- **SwiftBar tray plugin** with per-profile connect / password / clone / disconnect actions
- **Zsh completion** — `vpn <Tab>` suggests commands, profiles, actions dynamically
- **Detects auth / network failures** and surfaces them as native macOS notifications
- **Zero cloud dependency** — all state stays local

## Requirements

- macOS (tested on Apple Silicon, Ventura+)
- [`openfortivpn`](https://github.com/adrienverge/openfortivpn) — `brew install openfortivpn`
- `screen` (comes with macOS)
- [SwiftBar](https://swiftbar.app/) — optional, for the tray plugin: `brew install --cask swiftbar`
- Passwordless `sudo` for `openfortivpn` (see below)

### `/etc/sudoers.d/vpn`

The script runs `openfortivpn` via `sudo` (needed to create the `ppp0` tunnel). To avoid a password prompt every time, add a sudoers rule:

```
sudo visudo -f /etc/sudoers.d/vpn
```

```
%admin ALL=(root) NOPASSWD: /opt/homebrew/bin/openfortivpn *
%admin ALL=(root) NOPASSWD: /usr/bin/pkill openfortivpn
%admin ALL=(root) NOPASSWD: /usr/bin/pkill -9 openfortivpn
```

Adjust the binary path if `openfortivpn` is somewhere else (`which openfortivpn`).

## Install

```bash
# 1. Clone
git clone https://github.com/AndersonCRocha/openfortivpn-macos.git ~/vpn

# 2. Install the CLI to your PATH
sudo ln -s ~/vpn/bin/vpn /usr/local/bin/vpn
# or without sudo, on Apple Silicon:
ln -s ~/vpn/bin/vpn /opt/homebrew/bin/vpn

# 3. Install the zsh completion (already in $fpath on Homebrew)
ln -s ~/vpn/completions/_vpn /opt/homebrew/share/zsh/site-functions/_vpn
rm -f ~/.zcompdump*

# 4. Install the SwiftBar plugin (optional)
ln -s ~/vpn/swiftbar/vpn.5s.sh "$HOME/Library/Application Support/SwiftBar/Plugins/vpn.5s.sh"
```

Open a new terminal tab, then `vpn help`.

## Usage

```
vpn list                         # list profiles + status
vpn add <name>                   # create/edit profile (asks host, port, user)
vpn clone <src> <new>            # duplicate a profile, change only user
vpn remove <name>                # delete profile + keychain entry

vpn start <name>                 # connect
vpn token <name> <code>          # send MFA token
vpn stop [name]                  # disconnect (auto-detects if no name given)
vpn status <name>                # profile diagnostic
vpn log <name>                   # tail -f the openfortivpn log
vpn passwd <name>                # change the keychain password
vpn reset <name>                 # factory reset a profile
```

Full example:

```
$ vpn add work
Host: vpn.company.com
Port: 443
Username: 123456

$ vpn start work
🔐 Validating credentials for: 123456 (work)
🚀 Connecting to vpn.company.com:443...
⏳ Waiting for server.....
✅ Server responded!
📩 Type: vpn token work <code>

$ vpn token work 987654
📨 Sending to 12345.vpn-work...
```

## Layout of state

- Profiles live in `~/Library/Application Support/vpn/profiles/<name>/`
  - `config` — `HOST=…`, `PORT=…`
  - `user` — the username
  - `cert` — trusted certificate SHA-256 (auto-managed)
- Passwords live in the macOS Keychain under service `vpn-<name>`
- Logs go to `/tmp/vpn-<name>.log`
- Screen sessions are named `vpn-<name>`

Nothing outside `~/Library/Application Support/vpn/` and Keychain is persisted.

## SwiftBar tray

Once the plugin is installed and SwiftBar is running:

- **🔓 vpn** — offline
- **🟡 `<profile>`** — connecting
- **🟡 `<profile>` MFA** — waiting for token
- **🟢 `<profile>`** — connected

The dropdown lists every profile with per-item submenu:

- Click a profile → connects silently (password dialog if not in Keychain yet)
- Hover → **🔑 Change password…** or **📋 Clone…**
- Active profile shows disconnect + log + change-password directly

A watchdog fires a native notification if the connection fails within ~25 seconds.

## Corporate gateways with host-check (PREAUTH)

Some FortiGate gateways require an extra `/remote/hostcheck_install` step after
the login POST (typical of setups that use FortiToken Mobile Push + endpoint
compliance). `openfortivpn` doesn't follow that redirect on its own and hangs
after `Connected to gateway`.

Workaround: mark the profile as `PREAUTH=1` in its config file. The script then:

1. Sends a `POST /remote/logincheck` via `curl` — the gateway pushes an MFA
   notification to your device, you approve it.
2. Follows the hostcheck redirect and captures the `SVPNCOOKIE`.
3. Hands the cookie to `openfortivpn --cookie=SVPNCOOKIE=...`, which skips the
   auth step and goes straight to the tunnel.

Edit the profile config manually:

```
$ cat ~/Library/Application\ Support/vpn/profiles/<name>/config
HOST=vpn.example.com
PORT=443
PREAUTH=1
```

Then `vpn start <name>` shows `🔔 Sending push notification — approve it on your device`,
you tap approve, and the tunnel comes up.

## Notes / limitations

- `openfortivpn` supports only ONE tunnel at a time on macOS (limitation of `ppp0`). Switching profiles requires disconnecting first — the script handles that gracefully.
- FortiSASE / SAML SSO tunnels are NOT supported (they need the FortiClient GUI).
- Tested against FortiGate SSL VPN gateways with TOTP MFA and with FortiToken Mobile Push via the PREAUTH flow. Other MFA schemes may work if `openfortivpn` supports them.

## License

MIT
