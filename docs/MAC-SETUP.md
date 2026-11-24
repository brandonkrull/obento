# Mac setup

Everything a Mac needs to use the home server (tamago): getting on the tailnet, signing in to the server, and the
apps for files, passwords, media, photos and alerts. Do it once per Mac; it doesn't change anything on the server.

Addresses below use `tamago.<tailnet>.ts.net`. Find your tailnet name in the Tailscale admin console (DNS page)
or with `tailscale status --json | jq -r .MagicDNSSuffix` once step 1 is done.

## Quick version

```bash
brew install --cask tailscale-app bitwarden opencloud jellyfin-media-player
brew install immich-go            # only needed for the Google Takeout import (RUNBOOK step 7)
```

Then do steps 1–2 and sign in to each app as described in step 3.

## 1. Tailscale (required)

Every app is reachable only inside your tailnet, so start here.

1. Install Tailscale: `brew install --cask tailscale-app` (or the Mac App Store version).
2. Open it, sign in with the same account as the server, and approve the system prompts.
3. Leave **Use Tailscale DNS** on (menu bar icon → Settings), so names like `tamago` work.
4. Check: `ping -c 3 tamago` should get replies.

### Ad blocking, everywhere

Nothing to set up on the Mac: while Tailscale is connected and **Use Tailscale DNS** is on, every app and browser
looks up addresses through the server's ad blocker (AdGuard), on any network. At home the Wi-Fi does the same
even with Tailscale off.

- Check it: `dig +short doubleclick.net` prints `0.0.0.0`, and `tailscale dns status` lists the server's
  Tailscale IP under **Resolvers**. Or open https://d3ward.github.io/toolz/adblock in a browser.
- If a site or app breaks because something it needs is blocked, the admin can allow it in AdGuard
  (http://tamago:3000 → **Query log** → **Unblock**).
- Macs you only *shared* tamago with (instead of inviting to the tailnet) don't get this: ad blocking comes with
  the tailnet's DNS settings, which shared devices don't use.
- If the server is off, websites won't load while Tailscale is on: quit Tailscale until it's back.

## 2. Command line access to the server

The server runs Tailscale SSH, so any Mac on your tailnet can sign in without copying a key. Add a shortcut so
`ssh tamago` works:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat >> ~/.ssh/config <<'EOF'
Host tamago
  HostName tamago
  User brandon
EOF
chmod 600 ~/.ssh/config
ssh tamago
```

- The first time, check the host key fingerprint matches the server's (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`
  on the server) before typing `yes`.
- Every so often Tailscale prints a `login.tailscale.com` link before letting you in; open it and sign in.
- `scp file.txt tamago:` and `rsync -a folder/ tamago:folder/` use the same shortcut.

## 3. Apps

| What | Mac app | Server address to enter |
|---|---|---|
| Files (Google Drive replacement) | **OpenCloud**: `brew install --cask opencloud` | `https://tamago.<tailnet>.ts.net:9200` |
| Passwords | **Bitwarden**: `brew install --cask bitwarden`, plus the Bitwarden browser extension | `https://tamago.<tailnet>.ts.net:8443` |
| Media | **Jellyfin Media Player**: `brew install --cask jellyfin-media-player` | `https://tamago.<tailnet>.ts.net:8920` |
| Photos | Immich has no Mac app: use the browser (phones use the Immich app) | `https://tamago.<tailnet>.ts.net` |
| Alerts | ntfy in the browser (allow notifications), or the phone app | `<NTFY_URL>/<NTFY_TOPIC>` from `.env`, e.g. `https://ntfy.sh/your-topic` |
| Ad blocking admin | browser | `http://tamago:3000` |
| Drive health | browser | `http://tamago:8080` |

### OpenCloud

1. Open **OpenCloud**, enter the server address, and sign in in the browser window it opens.
2. Pick a folder on the Mac to sync (e.g. `~/OpenCloud`). Files there sync to the server and your other devices.

Accounts are created by the admin in OpenCloud (**Admin settings → Users**), not by signing up.

### Bitwarden (Vaultwarden)

1. Open **Bitwarden**, and before logging in choose **Self-hosted** (the region selector on the login screen).
2. Server URL: `https://tamago.<tailnet>.ts.net:8443`, then log in with your Vaultwarden account.
3. Do the same in the browser extension.

New accounts need sign-ups switched on for a moment: `tamago signups on` on the server, create the account,
then `tamago signups off`.

### Jellyfin

Open **Jellyfin Media Player**, enter the server address when it asks for one, and sign in with your Jellyfin account.

### Google Photos import

`immich-go` uploads a Google Takeout export into Immich. RUNBOOK step 7 runs it on the server; to run it from
the Mac instead, use the same command with `--server=https://tamago.<tailnet>.ts.net` (it needs an Immich
API key from **Account Settings → API Keys**).

## When something doesn't load

- Check Tailscale is connected (menu bar icon) and `ping tamago` works.
- No websites load at all with Tailscale on, but they do with it off: the server (and its ad blocker) is down.
  Quit Tailscale until it's back.
- On the server: `tamago status` shows which apps are running, `tamago logs <app>` shows why one isn't.
- HTTPS addresses are set up by `sudo ./install.sh` on the server; it prints them at the end.
