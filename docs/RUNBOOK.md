# Runbook

Commands assume you're in the repo (`~/obento`) unless they say `/opt/obento`.

## 0. Hardware and BIOS (once)

- Power the drive backplane from **Molex only** (Ultrastar PWDIS — see DRIVE-PLAN.md).
- Rear fans: fan switch SATA plug → power supply SATA power; fans' 2-pin plug → the switch harness.
- BIOS (ASUS, F7 for Advanced Mode):
  - **Ai Tweaker → power limits: PL1 = PL2 = 65 W** (required with a low-profile cooler; quieter and plenty for a NAS either way).
  - Advanced → Onboard Devices: leave the iGPU **enabled** (Quick Sync for Immich/Jellyfin).
  - Boot → **Restore AC Power Loss: Power On** (comes back after an outage).
  - Q-Fan: CPU fan "Standard"; chassis headers unused (fans run off the case switch).
- Ethernet plugged in if you can (more reliable for a NAS). The onboard 2.5 GbE port only works after the
  newer kernel in step 1; until then use Wi-Fi.

## 1. Install Ubuntu Server 24.04 LTS

- Use the latest 24.04 point release (24.04.5 or newer).
- Make the USB stick from a Mac (≥ 4 GB; **everything on it is erased**):

  ```bash
  cd ~/Downloads
  curl -fLO https://releases.ubuntu.com/24.04/ubuntu-24.04.5-live-server-amd64.iso
  curl -fsSL https://releases.ubuntu.com/24.04/SHA256SUMS | grep live-server | shasum -a 256 -c --ignore-missing
  diskutil list external physical              # find the stick by size/name, e.g. /dev/disk5
  diskutil unmountDisk /dev/diskN               # N = the stick; double-check it's not another drive
  sudo dd if=ubuntu-24.04.5-live-server-amd64.iso of=/dev/rdiskN bs=4m status=progress
  diskutil eject /dev/diskN
  ```

  macOS may say the disk is unreadable afterwards; click **Ignore** (that's expected).
- Boot the server from the stick (F8 on ASUS for the boot menu, pick the **UEFI** USB entry); install to the
  **NVMe**, default layout, enable OpenSSH.
- **Skip the network** in the installer ("Continue without network"). Its installed kernel (6.8) can't see this
  board's Ethernet (RTL8125 rev 0c), and Wi-Fi tends to fail during the installer's update downloads.
  After the first boot, `systemd-networkd-wait-online` waits ~2 minutes; that's expected.
- Don't install anything onto the hard drives.

### After the first boot: network, kernel, SSH

On the server's own keyboard:

```bash
ip -br link                                   # Wi-Fi is wl… (e.g. wlp131s0); Ethernet appears as eno1 after the kernel step
sudo tee /etc/netplan/02-wifi.yaml >/dev/null <<'EOF'
network:
  version: 2
  wifis:
    wlp131s0:
      dhcp4: true
      access-points:
        "YOUR_NETWORK_NAME":
          password: "YOUR_WIFI_PASSWORD"
EOF
sudo chmod 600 /etc/netplan/02-wifi.yaml      # it holds the Wi-Fi password
sudo netplan apply
ping -c 3 ubuntu.com
```

Turn off Wi-Fi power saving. With it on (the MT7922 default), the server can reach the network but other
devices can't reach it. It's re-applied every time the Wi-Fi connects, because the driver turns it back on:

```bash
sudo apt update && sudo apt install -y iw
sudo tee /etc/networkd-dispatcher/routable.d/50-wifi-powersave-off >/dev/null <<'EOF'
#!/bin/sh
# Wi-Fi power saving makes the server unreachable from other devices on the network
case "$IFACE" in wl*) /usr/sbin/iw dev "$IFACE" set power_save off ;; esac
EOF
sudo chmod 755 /etc/networkd-dispatcher/routable.d/50-wifi-powersave-off
sudo systemctl enable --now networkd-dispatcher
```

Install the newer (HWE) kernel: it adds the Ethernet port and better Arrow Lake graphics support for Quick Sync.
The 6.8 kernel stays in the boot menu as a fallback. This is a deliberate manual kernel upgrade (see "Kernel updates").

```bash
sudo apt install -y linux-generic-hwe-24.04 && sudo reboot
uname -r                                      # after the reboot: 7.x
iw dev wlp131s0 get power_save                # "off"
```

Ethernet, once a cable is in: add `/etc/netplan/01-ethernet.yaml` with `ethernets: eno1: dhcp4: true`
(same shape as the Wi-Fi file), `chmod 600`, `sudo netplan apply`.

SSH from your Mac, then reserve the server's address in your router (Google Home app) so it doesn't change:

```bash
ip -br addr                                   # on the server: note the address
ssh-copy-id -i ~/.ssh/id_ed25519.pub brandon@<server-ip>   # on the Mac; asks for the server password once
ssh brandon@<server-ip>                       # should log in without the password
```

## 2. Bootstrap

Get the repo onto the server. The repo is private, so either give the server a read-only **deploy key**
(recommended: it can pull updates itself, but can't push or see your other repos), or copy it from your Mac
with `rsync -a ~/path/to/obento/ <server>:obento/`.

Deploy key (optional):

```bash
# on the server
ssh-keygen -t ed25519 -N "" -C "tamago deploy key (read-only)" -f ~/.ssh/github_obento
cat ~/.ssh/github_obento.pub
cat >> ~/.ssh/config <<'EOF'
Host github.com
  IdentityFile ~/.ssh/github_obento
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config

# on your Mac (or paste the .pub into GitHub → repo Settings → Deploy keys, leave "Allow write access" off)
ssh tamago cat .ssh/github_obento.pub > /tmp/tamago.pub
gh repo deploy-key add /tmp/tamago.pub -R brandonkrull/obento --title "tamago (read-only)"

# on the server: check GitHub's key fingerprint against
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
# when asked, then clone
git clone git@github.com:brandonkrull/obento.git ~/obento
```

Then, either way:

```bash
cd ~/obento
cp .env.example .env && chmod 600 .env && nano .env   # fill in every "change-me"
sudo ./install.sh
sudo tailscale up --ssh
sudo ./install.sh                          # again, now that Tailscale is up: sets up HTTPS for the apps
sudo systemctl status smartmontools        # you should get a "test" ntfy alert per drive
```

Install the **ntfy** app on your phone and subscribe to your `NTFY_TOPIC`.

Email too (optional): ntfy.sh only emails for signed-in accounts. Create a free account at https://ntfy.sh/account,
verify your email address there, and create an access token (**Account → Access tokens**). Put the address in
`NTFY_EMAIL` and the token in `NTFY_TOKEN` in `.env`, then re-run `sudo ./install.sh`. Free accounts get 5 emails a day. High and urgent alerts (drive,
backup, pool, UPS problems) and Scrutiny's warnings are then also emailed; routine ones stay notification-only.
Test it with `sudo obento-notify high "Email test" "If this arrived by email, alerts will too."`

Later changes: edit and push from your Mac, then on the server `obento update` (it runs `git pull` and `sudo ./install.sh`)
(the deploy key is read-only, so don't edit on the server).

`install.sh` also installs **pi** (the coding agent) for your account, set up to use `qwen36-moe` on
spark-e2ca (`config/pi/`, copied to `~/.pi/agent/`; an existing file there is kept). It reaches spark by its
Tailscale name, so `tailscale up` must be done first. Check it:

```bash
getent hosts spark-e2ca                       # a 100.x address (via libnss-resolve + Tailscale)
curl -s http://spark-e2ca:11437/health        # {"status":"ok"}
pi --list-models qwen
pi -p "Say hello"
```

## 3. Apps (on the SSD until the drives arrive)

To set up devices to use them, see `docs/MAC-SETUP.md` (Tailscale, `ssh tamago`, OpenCloud, Bitwarden, Jellyfin)
and `docs/IOS-SETUP.md` (iPhone and iPad, for the whole family).

```bash
obento up        # starts every app (asks for your password); 'obento help' lists the other commands
obento status
```

Where to find them (on any device signed into Tailscale; at home you can also use the server's LAN IP):

| App | Address |
|---|---|
| Immich | https://tamago.<tailnet>.ts.net |
| Vaultwarden | https://tamago.<tailnet>.ts.net:8443 (HTTPS only) |
| OpenCloud | https://tamago.<tailnet>.ts.net:9200 (HTTPS only) |
| Jellyfin | https://tamago.<tailnet>.ts.net:8920 or http://tamago:8096 |
| AdGuard Home | http://tamago:3000 |
| Scrutiny | http://tamago:8080 |

With a domain of your own these become `photos.`, `passwords.`, `files.`, `media.`, `adblock.` and `drives.`
under it: see [Your own web addresses](#your-own-web-addresses-optional).

`install.sh` sets up the HTTPS addresses with `tailscale serve` once Tailscale is connected (it prints them at
the end). It needs **HTTPS Certificates** turned on in the Tailscale admin console (DNS page); if they're off,
`install.sh` says so. They're only reachable inside your tailnet, never from the internet.

- Immich: create the admin account, then **Account Settings → API Keys** → put it in `.env` as `IMMICH_API_KEY`
  and re-run `sudo ./install.sh` (copies .env). Administration → Settings → Machine Learning: OpenVINO is used automatically.
  Video transcoding → hardware acceleration: **Quick Sync**.
- AdGuard (network ad blocking), see "Ad blocking for the whole network" below.
- OpenCloud: set `OPENCLOUD_ADMIN_PASSWORD` in `.env` **before** its first start (it's only used then), sign in
  as `admin`, then create an account per person under **Admin settings → Users**. Install the OpenCloud desktop
  and phone apps and point them at https://tamago.<tailnet>.ts.net:9200. It needs the HTTPS address, so it only
  works once Tailscale is up and `install.sh` has run since.
- Vaultwarden: sign-ups are off by default. To create the family's accounts, run `obento signups on`,
  create them at https://tamago.<tailnet>.ts.net:8443, then `obento signups off` (any `obento up` also turns them off).
- Jellyfin: copy files into `Movies`, `Shows` and `Music` under `MEDIA_LOCATION` (`install.sh` makes them yours,
  so no sudo: `rsync -a --progress "Film (2008)" tamago:/srv/media/Movies/`). Name them like
  `Movies/Film (2008)/Film (2008).mkv` and `Shows/Show/Season 01/Show S01E01.mkv`, then add one library per
  folder in **Dashboard → Libraries** (Jellyfin sees them under `/media`).
- Scrutiny: `install.sh` points its alerts at your ntfy topic (early drive warnings, and a drive that stops
  reporting). Send a test alert with `curl -X POST http://tamago:8080/api/health/notify`.
- Test with a few hundred photos (phone app → backup).

**Start the Google Takeout now** (Google Photos only, .zip, 50 GB parts). It can take a day+ to prepare.

### Ad blocking for the whole network

1. Setup wizard at http://tamago:3000:
   - **Admin web interface: All interfaces, port 3000.** The wizard suggests 80, but only 3000 is published
     (compose), so 80 leaves the dashboard unreachable.
   - **DNS server: All interfaces, port 53.**
   - Create the admin login and save it in Vaultwarden.
2. **Settings → DNS settings**: upstream e.g. `https://dns.cloudflare.com/dns-query` and
   `https://dns.quad9.net/dns-query`. **Filters → DNS blocklists**: the AdGuard DNS filter is on by default.
3. Test from another machine: `dig @<server LAN IP> doubleclick.net +short` prints `0.0.0.0`.
4. Whole home network, in the Google Home app (Google/Nest Wifi; search the app's settings for "DNS" if the
   menus have moved):
   1. Reserve the server's address so it never changes: **Devices → Wi-Fi → Settings (gear) → Advanced
      networking → DHCP IP reservations → +** → pick the server → its current LAN IP → **Save**.
   2. **Same Advanced networking → DNS → Custom** → **Primary server**: the server's LAN IP. Leave
      **Secondary** empty (devices would sometimes use it and skip blocking) → **Save**.
   3. Devices pick it up within minutes (toggle Wi-Fi to hurry one). Check AdGuard's **Query log** while browsing.
   Google Wifi answers its devices' DNS itself and forwards to AdGuard, so the query log may show every request
   as coming from the router (`192.168.86.1`); blocking still covers every device. If the server is down,
   devices at home can't look up websites until it's back; to undo, set DNS back to **Automatic**.
5. Optional, away from home (wait until the server is reliably up): Tailscale admin console → **DNS** → add
   nameserver = the server's Tailscale IP, turn on **Override DNS servers** (older consoles: **Override local
   DNS**). If the server is down, tailnet devices can't look up websites while Tailscale is on. Turning the
   override off disables it again; the nameserver entry can stay.

If ads still get through, **Query log** shows which device asked for what (often a device using the router's IPv6 DNS).

If the dashboard doesn't load after the wizard (it picked port 80):

```bash
sudo sed -i '/^http:/,/^[a-z]/ s/^\(  address: \).*/\10.0.0.0:3000/' /srv/adguard/conf/AdGuardHome.yaml
obento restart adguard
```

Forgot the admin password: from a Mac (it asks for the new password, then the server's sudo password):

```bash
HASH=$(htpasswd -nB -C 10 <user> | cut -d: -f2-) && ssh -t tamago "sudo sed -i '/^users:/,/^[a-z]/ s|^\(    password: \).*|\1$HASH|' /srv/adguard/conf/AdGuardHome.yaml && obento restart adguard"
```

### Your own web addresses (optional)

With a domain you own, apps get addresses like `photos.home.example.com` instead of
`tamago.<tailnet>.ts.net` ports. Nothing becomes reachable from the internet: the names point at the server's
Tailscale address, so they only work on devices signed into your tailnet.

| App | Address | Old address afterwards |
|---|---|---|
| Immich | `https://photos.home.example.com` | stops (Traefik takes port 443) |
| Vaultwarden | `https://passwords.home.example.com` | keeps working while devices move over |
| OpenCloud | `https://files.home.example.com` | stops (it signs in at one address only) |
| Jellyfin | `https://media.home.example.com` | keeps working |
| AdGuard Home | `https://adblock.home.example.com` | `http://tamago:3000` keeps working |
| Scrutiny | `https://drives.home.example.com` | `http://tamago:8080` keeps working |

The names and the apps they lead to are in `config/traefik/dynamic.yml`.

How it works: Traefik (the `traefik` app) answers those names on port 443 with one Let's Encrypt certificate
for `*.home.example.com`. To get it, the server proves it owns the name through **deSEC**, a free DNS host with
an API. Only the `home` part is handed to deSEC; the rest of your domain (website, email) stays where it is.
Below, `home.example.com` stands for whatever you choose; it becomes `APPS_DOMAIN`.

1. **deSEC**: sign up at desec.io → **Domains → +** → enter `home.example.com` (the full name) → in that
   domain, add a record: Subname `*`, Type `A`, value the server's Tailscale IP (`tailscale ip -4` on the
   server) → **Token Management → +** → copy the token (shown once).
2. **Hand `home` to deSEC** at your domain's DNS host (Squarespace: **Domains** → your domain → **DNS** →
   **Custom records**), two records:

   | Host | Type | Data |
   |---|---|---|
   | `home` | NS | `ns1.desec.io` |
   | `home` | NS | `ns2.desec.org` |

   This needs DNSSEC off for the domain at Squarespace (check: `dig +short DS example.com` prints nothing).
   Check from the Mac after a few minutes: `dig +short photos.home.example.com` prints the Tailscale IP.
3. **Settings** in `~/obento/.env` on the server, then install and start:

   ```bash
   APPS_DOMAIN=home.example.com
   DESEC_TOKEN=<the deSEC token>
   COMPOSE_PROFILES=domain
   ```

   ```bash
   cd ~/obento && sudo ./install.sh && obento up
   ```

   From here Immich's and OpenCloud's old addresses stop working (see the table above).
4. **Check**: open `https://photos.home.example.com`. The certificate takes a minute or two the first time;
   if it doesn't load, `obento logs traefik | grep -i -E "acme|error"` says why.
5. **Move each app over**, on every device (docs/MAC-SETUP.md and docs/IOS-SETUP.md list the apps):
   - **Immich**: **Administration → Settings → Server → External Domain** → `https://photos.home.example.com`
     (used in shared links). On every phone, log out of the Immich app and log back in with the new address.
   - **OpenCloud**: everyone signs in again once (`install.sh` resets OpenCloud's sign-in addresses when its
     address changes). In the desktop app, remove the account and add it again with the new address; on
     phones, log out and back in.
   - **Bitwarden**: log out, change the self-hosted server URL to `https://passwords.home.example.com`, log in.
     The vault is kept on each device, so nothing is lost meanwhile.
   - **Jellyfin**: add the new address as a server in the app and sign in.

The certificate renews itself. If the server's Tailscale IP ever changes, update the `*` record at deSEC.

## 4. Drives arrive → burn-in (~3 days)

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL            # both 18 TB drives visible? If not: PWDIS / Molex
ls -l /dev/disk/by-id/ | grep -v part | grep ata-
sudo tmux new -s burnA 'sudo /opt/obento/scripts/burnin.sh /dev/disk/by-id/ata-WDC_WUH721818ALE604_AAAA'
# detach: Ctrl-b d
sudo tmux new -s burnB 'sudo /opt/obento/scripts/burnin.sh /dev/disk/by-id/ata-WDC_WUH721818ALE604_BBBB'
```

You'll get ntfy alerts on start, PASS or FAIL. A FAIL → warranty claim with ServerPartDeals.

## 5. Create the pool

```bash
sudo /opt/obento/scripts/create-pool.sh /dev/disk/by-id/ata-..._AAAA /dev/disk/by-id/ata-..._BBBB
/opt/obento/scripts/print-scrutiny-devices.sh   # paste into ~/obento/compose scrutiny devices:, sudo ./install.sh, obento up scrutiny
```

## 6. Move Immich, Vaultwarden, OpenCloud and media onto the pool

```bash
obento stop immich-server immich-machine-learning vaultwarden opencloud jellyfin
sudo rsync -aHAX --info=progress2 /srv/immich/library/ /tank/photos/
sudo rsync -aHAX /srv/vaultwarden/ /tank/vaultwarden/
sudo rsync -aHAX --info=progress2 /srv/opencloud/data/ /tank/opencloud/
sudo rsync -aHAX --info=progress2 /srv/media/ /tank/media/
# verify BEFORE switching (lesson: never trust a silent copy)
sudo rsync -aHAXn --checksum --itemize-changes /srv/immich/library/ /tank/photos/ | head   # must print nothing
sudo rsync -aHAXn --checksum --itemize-changes /srv/vaultwarden/ /tank/vaultwarden/ | head
sudo rsync -aHAXn --checksum --itemize-changes /srv/opencloud/data/ /tank/opencloud/ | head
sudo rsync -aHAXn --checksum --itemize-changes /srv/media/ /tank/media/ | head
```

Edit `.env`: `IMMICH_UPLOAD_LOCATION=/tank/photos`, `VAULTWARDEN_DATA=/tank/vaultwarden`,
`OPENCLOUD_DATA=/tank/opencloud`, `MEDIA_LOCATION=/tank/media` → `sudo ./install.sh` → `obento up`.
Check photos, files and media load, then delete the old copies on the SSD a week later.
`install.sh` gives you the `Movies`, `Shows` and `Music` folders on `/tank/media` too, so copying in stays sudo-free.
OpenCloud's config (`/srv/opencloud/config`, small, holds its keys) stays on the SSD and is backed up nightly.

## 7. Import Google Photos and verify

```bash
# immich-go (github.com/simulot/immich-go) — check its README for the current syntax
immich-go upload from-google-photos --server=http://localhost:2283 --api-key=$IMMICH_API_KEY /path/to/takeout-*.zip
# extract the Takeout zips to a folder, then compare independently:
python3 -I /opt/obento/scripts/verify-takeout.py /path/to/extracted/Takeout --env /etc/obento/.env
```

`missing.txt` must be empty (or every line explained) before moving on.

## 8. Import Google Drive into OpenCloud

Do this after step 6, so files land on the pool instead of the SSD (and don't have to be moved again). Steps
1–3 below only need the SSD, so they can be done before the drives arrive, and step 2 tells you how big your
Drive is.

How it works: `rclone` on the server copies Drive to a folder on the pool (Google Docs, Sheets and Slides become
.docx, .xlsx and .pptx), checks the copy, then uploads that folder into your OpenCloud account. Files can't be
copied into OpenCloud's data folder directly: OpenCloud only knows about files uploaded through it.

1. **Google sign-in for rclone.** rclone's built-in Google key is shared by every rclone user and gets throttled.
   Make your own (once, ~10 minutes) at console.cloud.google.com:
   - New project (e.g. `tamago`) → **APIs & Services → Library** → enable **Google Drive API**.
   - **Google Auth Platform** (older consoles: **OAuth consent screen**) → set up as **External**.
   - **Audience → Test users → Add users**: every Google account whose Drive you'll copy. Without this, sign-in
     fails with "tamago has not completed the Google verification process".
   - **Clients** (or **Credentials → Create credentials → OAuth client ID**) → **Desktop app**. Keep the client ID
     and secret for the next step.

   While the app is in "Testing", sign-ins last 7 days; enough for the import (re-connect with
   `rclone config reconnect gdrive:` if it expires).
2. **Connect Drive** (on the server; the browser sign-in happens on the Mac):
   ```bash
   # rclone is installed by install.sh; on the Mac: brew install rclone
   rclone config     # n (new remote) → name: gdrive → storage: drive → paste client ID and secret
                     # scope: drive.readonly (read everything, change nothing; drive.file and
                     #   drive.appfolder can't see your existing files)
                     # service_account_file: blank → advanced config: n
                     # "Use web browser to automatically authenticate?" → n
                     # → run the 'rclone authorize "drive" "…"' command it prints on the Mac, sign in
                     #   (click Continue at "Google hasn't verified this app"), paste the token back
                     # "Configure this as a Shared Drive?" → n → keep the remote
   rclone size gdrive:                # how much there is (Google Docs aren't counted)
   ```
3. **Try a small folder first**: `rclone copy "gdrive:Some Folder" /tmp/gdrive-test --progress`, open a few
   files (including a Google Doc, now a .docx), then `rm -rf /tmp/gdrive-test`.
4. **Copy Drive to the pool** (in `tmux`; it resumes if you re-run it):
   ```bash
   sudo zfs create tank/import && sudo chown "$USER:" /tank/import
   rclone copy gdrive: /tank/import/gdrive-$USER --progress --transfers 8 \
     --log-file ~/gdrive-copy.log --log-level INFO
   rclone check gdrive: /tank/import/gdrive-$USER --one-way    # must end with "0 differences found"
   grep -c ERROR ~/gdrive-copy.log                             # must be 0
   ```
   - Google Docs exports have no checksum to compare, so `check` skips them; open a few to confirm.
   - Not included: **Shared with me** (add `--drive-shared-with-me` in a separate run into another folder), shared
     drives (`rclone config` a second remote and choose the shared drive), Google Forms, Sites and Maps (no export
     format; save them by hand).
   - A file Google marked as malware stops with "cannotDownloadAbusiveFile"; add `--drive-acknowledge-abuse` if
     you're sure you want it.
5. **Let rclone sign in to OpenCloud.** Set `OPENCLOUD_APP_TOKENS=true` in `~/obento/.env`, then
   `sudo ./install.sh && obento up opencloud`. Create a token for your OpenCloud account (valid 3 days) and give it
   to rclone without saving it anywhere:
   ```bash
   sudo docker exec opencloud opencloud auth-app create --user-name=<your OpenCloud user> --expiration=72h
   read -rs TOKEN                     # paste the token, then Enter (nothing is shown)
   export RCLONE_CONFIG_OPENCLOUD_TYPE=webdav RCLONE_CONFIG_OPENCLOUD_VENDOR=owncloud \
     RCLONE_CONFIG_OPENCLOUD_URL=<OpenCloud's address>/remote.php/webdav \
     RCLONE_CONFIG_OPENCLOUD_USER=<your OpenCloud user> \
     RCLONE_CONFIG_OPENCLOUD_PASS="$(printf %s "$TOKEN" | rclone obscure -)"
   unset TOKEN
   rclone lsd opencloud:              # lists your OpenCloud folders
   ```
   OpenCloud's address is `https://files.<APPS_DOMAIN>` with your own web addresses, otherwise
   `https://tamago.<tailnet>.ts.net:9200`.
6. **Upload into OpenCloud** (same shell, so the settings above still apply), then check:
   ```bash
   rclone copy /tank/import/gdrive-$USER "opencloud:Google Drive" --progress --transfers 4 \
     --log-file ~/opencloud-upload.log --log-level INFO
   rclone check /tank/import/gdrive-$USER "opencloud:Google Drive" --one-way   # "0 differences found"
   ```
   Then open **Google Drive** in OpenCloud on the web and in the desktop app, and spot-check a few files.
7. **Family members**: repeat 4–6 per person, with their own remote (`rclone config` → name `gdrive-<name>`,
   signing in to *their* Google account), folder (`/tank/import/gdrive-<name>`) and OpenCloud user.
8. **Clean up**: set `OPENCLOUD_APP_TOKENS=false` again, `sudo ./install.sh && obento up opencloud`. Once every
   check passed, delete the copy (`sudo zfs destroy tank/import`). Remove rclone's access in your Google account
   (myaccount.google.com → **Security** → **Third-party apps**) and delete the Google Cloud project.

Keep Google Drive as it is until step 9 (off-site backup) has finished and been verified.

## 9. Off-site backup

1. Backblaze: create a **private** bucket + an application key limited to that bucket. Fill the restic vars in `.env`.
2. Save `RESTIC_PASSWORD` in Vaultwarden **and** on paper in a drawer.
3. `sudo ./install.sh && sudo /opt/obento/scripts/backup.sh --init`
4. First run: `sudo systemctl start obento-backup` (1.6 TB upload takes days on home upload speeds; it resumes).
5. When it finishes: `sudo /opt/obento/scripts/backup.sh --verify`.

**Only now cancel Google One.**

## Routine (automatic)

| What | When | Alert |
|---|---|---|
| SMART short / long self-tests | daily 2 am / 1st Saturday 3 am | on any change |
| ZFS events (errors, degraded) | instantly | urgent |
| Scrub | 1st Sunday monthly | result either way |
| Capacity ≥ 80% / pool not ONLINE | hourly check | high / urgent |
| Drive health + latency report | Mondays 8 am | weekly |
| Snapshots (sanoid) | hourly, kept 24h/30d/12m | — |
| B2 backup | nightly 3:30 am | OK / FAILED |
| B2 read-back check (5%) | monthly | result |
| UPS on battery / low battery | instantly | auto-shutdown on low battery |
| Updates: Ubuntu, Docker, Tailscale, Node.js (not the kernel) | nightly, ~6 am | — (log: `/var/log/unattended-upgrades/`) |
| Docker cleanup (old image layers, build cache) + reboot check | Sundays 4:30 am | "Reboot needed" when an update asks for one |

## Quarterly restore test

```bash
sudo bash -c 'source /opt/obento/scripts/lib.sh; load_env; export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
restic restore latest --target /tmp/restore-test --include "/tank/photos/library" --verify 2>&1 | tail -5'
# open a few random photos from /tmp/restore-test, then rm -rf /tmp/restore-test
```

## Replacing a drive (the article's failure mode — follow in order)

1. `zpool status -v tank` and `sudo smartctl -a` on **every** drive; check Scrutiny history.
2. If more than one drive shows errors: **stop.** Make sure last night's B2 backup succeeded (or run one) before touching anything.
3. Replace the **weakest** drive first. Burn in the new drive (step 4) unless the pool is degraded and urgent.
4. `sudo zpool replace tank <old-by-id> /dev/disk/by-id/<new>` and watch `zpool status` until the resilver finishes.
5. Scrub afterwards: `sudo /opt/obento/scripts/scrub.sh`.

Container logs are capped at 3 × 10 MB per app (`/etc/docker/daemon.json`). Docker upgrades don't stop the
apps (live-restore). Nothing reboots on its own: when you get "Reboot needed", run `sudo reboot` at a quiet
time. To see what ran: `journalctl -u obento-maintenance` and `sudo unattended-upgrade --dry-run -d`.

## Kernel updates (manual)

```bash
KERNEL_PKGS="linux-image-generic-hwe-24.04 linux-headers-generic-hwe-24.04 linux-generic-hwe-24.04"
sudo apt-mark unhold $KERNEL_PKGS
sudo apt update && sudo apt full-upgrade
sudo apt-mark hold $KERNEL_PKGS
sudo reboot
```

If something breaks (NVMe, ZFS, network): reboot, choose **Advanced options for Ubuntu** in GRUB and boot the
previous kernel. Ubuntu keeps it installed.
