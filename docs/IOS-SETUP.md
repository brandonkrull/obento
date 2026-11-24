# iPhone and iPad setup

Everything an iPhone or iPad needs to use the home server (tamago): getting on the tailnet, then the apps for
photos, files, passwords, media and alerts. Do it once per device; it doesn't change anything on the server.
Use it for the whole family: each person signs in with their own accounts.

Addresses below use `tamago.<tailnet>.ts.net`. Find your tailnet name in the Tailscale admin console (DNS page).

## 1. Tailscale (required)

Every app is reachable only inside your tailnet, at home and away, so start here.

1. Install **Tailscale** from the App Store.
2. Open it, sign in, and allow it to add a VPN configuration.
   Family members sign in with their own account once they've been invited to the tailnet
   (Tailscale admin console → **Users** → **Invite**), or you share tamago with them (**Machines** → tamago → **Share**).
3. In Tailscale's settings, leave **Use Tailscale DNS** on so `tamago` addresses work.
4. Check: open `https://tamago.<tailnet>.ts.net` in Safari. You should see Immich's sign-in page.

Tailscale needs to be connected for the apps below to work. Turning on **VPN On Demand** (Settings → VPN →
Tailscale → ⓘ) keeps it connected automatically.

### Ad blocking, everywhere

At home, the Wi-Fi already sends every device through the server's ad blocker (AdGuard).

Away from home it's optional and set for the whole tailnet by the admin (RUNBOOK, "Ad blocking for the whole
network", step 5; it's off until the server is reliably up). When it's on, there's nothing to set up on the
phone: while Tailscale is connected and **Use Tailscale DNS** is on, websites and apps go through AdGuard on any
Wi-Fi or mobile data.

- Check it: open https://d3ward.github.io/toolz/adblock in Safari; most tests should show as blocked.
- If a site or app breaks because something it needs is blocked, the admin can allow it in AdGuard
  (http://tamago:3000 → **Query log** → **Unblock**).
- Family members you only *shared* tamago with (instead of inviting them to the tailnet) don't get this: ad
  blocking comes with the tailnet's DNS settings, which shared devices don't use.
- With away-from-home blocking on, websites won't load while Tailscale is on and the server is off: turn
  Tailscale off until it's back.

## 2. Apps

| What | App Store app | Server address to enter |
|---|---|---|
| Photos | **Immich** | `https://tamago.<tailnet>.ts.net` |
| Files (Google Drive replacement) | **OpenCloud** | `https://tamago.<tailnet>.ts.net:9200` |
| Passwords | **Bitwarden** | `https://tamago.<tailnet>.ts.net:8443` |
| Media | **Jellyfin** (or **Swiftfin**, a native player) | `https://tamago.<tailnet>.ts.net:8920` |
| Alerts (admins only) | **ntfy** | your `NTFY_URL` and `NTFY_TOPIC` from `.env` |

### Immich (photo backup)

1. Open **Immich**, enter the server address, and sign in. The admin creates accounts in Immich
   (**Administration → Users**).
2. Allow access to **All Photos** when asked (limited access only backs up the photos you pick).
3. Tap the cloud icon → choose the albums to back up (usually **Recents**) → turn on backup.
4. For the first big backup, keep the app open and the phone plugged in on Wi-Fi: iOS pauses apps in the
   background, so it goes much faster in the foreground. After that, background backup keeps up.

### OpenCloud (files)

1. Open **OpenCloud**, enter the server address, and sign in in the page it opens. Accounts are created by the
   admin in OpenCloud (**Admin settings → Users**).
2. Your files show up in the app and in the **Files** app under **Locations → OpenCloud**
   (turn it on under **Browse → ⋯ → Edit** if it isn't listed).
3. Turn on **Auto upload** in OpenCloud's settings only if you want photos in OpenCloud too; Immich already
   backs them up.

### Bitwarden (passwords)

1. Open **Bitwarden** and, before logging in, change **Logging in on** to **Self-hosted**.
2. Server URL: `https://tamago.<tailnet>.ts.net:8443`, then log in with your Vaultwarden account.
3. Let it fill passwords: Settings → General → **AutoFill** (or **Passwords → Password Options** on older iOS)
   → turn on **Bitwarden**.

New accounts need sign-ups switched on for a moment: `tamago signups on` on the server, create the account
(easiest from a computer), then `tamago signups off`.

Your vault is stored on the phone too, so saved passwords still fill in when Tailscale is off; new changes sync
the next time it's connected.

### Jellyfin (movies and shows)

Open **Jellyfin** or **Swiftfin**, add a server with the address above, and sign in with your Jellyfin account.
Either works; try the other if a video won't play.

### ntfy (server alerts, for whoever looks after the server)

1. Open **ntfy** and allow notifications.
2. Tap **+**, enter your `NTFY_TOPIC`. If `NTFY_URL` is not `https://ntfy.sh`, turn on **Use another server**
   and enter it.
3. Alerts from the server (drive problems, failed backups, power cuts) now arrive as notifications.

## When something doesn't load

- Check Tailscale is connected (the VPN icon at the top of the screen, or open the Tailscale app).
- No websites load at all with Tailscale on, but they do with it off: the server (and its ad blocker) is down
  and away-from-home blocking is on. Leave Tailscale off until it's back.
- Try the address in Safari: if Safari can't reach it either, the problem is Tailscale or the server, not the app.
- On the server: `tamago status` shows which apps are running, `tamago logs <app>` shows why one isn't.
