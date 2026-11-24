# 🍱 obento

Everything a family home server needs, packed into one box. obento turns a fresh **Ubuntu Server 24.04 LTS**
install into a home server for photos, passwords, files, media and network-wide ad blocking, with drive-health
alerts, snapshots and off-site backup. Nothing is published to the internet. Everyone reaches the apps through
**Tailscale**, a private network (a "tailnet") that joins your own devices wherever they are.

It was built by one person for one machine, whose hostname is `tamago`, so addresses in the docs say `tamago`;
the apps are managed with the `obento` command. The code works on other hardware, but some settings are
specific to that build; [Make it yours](#make-it-yours) lists each one.

> **Status:** in daily use on the author's server, with every app running from the SSD. The hard-drive stages
> (burn-in, creating the pool, moving data onto it: runbook steps 4–6) are written but haven't been run yet.

## What you get

| App | What it's for | Address | With [your own domain](#optional-your-own-web-addresses) |
|---|---|---|---|
| [Immich](https://immich.app) | Photo and video backup from phones (a Google Photos replacement) | `https://tamago.<tailnet>.ts.net` | `https://photos.<domain>` |
| [Vaultwarden](https://github.com/dani-garcia/vaultwarden) | Family password manager; works with the Bitwarden apps | `https://tamago.<tailnet>.ts.net:8443` | `https://passwords.<domain>` |
| [OpenCloud](https://opencloud.eu) | Files synced across devices (a Google Drive replacement) | `https://tamago.<tailnet>.ts.net:9200` | `https://files.<domain>` |
| [Jellyfin](https://jellyfin.org) | Movies, shows and music | `https://tamago.<tailnet>.ts.net:8920` | `https://media.<domain>` |
| [AdGuard Home](https://adguard.com/adguard-home/overview.html) | Blocks ads and trackers for every device on the home network (DNS on port 53) | `http://tamago:3000` | `https://adblock.<domain>` |
| [Scrutiny](https://github.com/AnalogJ/scrutiny) | Dashboard of drive health over time | `http://tamago:8080` | `https://drives.<domain>` |
| Portal ([Homepage](https://gethomepage.dev)) | One page with every app, whether it's up, and the server's CPU, memory and disk | — | `https://<domain>` |

Out of the box, the HTTPS addresses come from `tailscale serve` and work only inside your tailnet; AdGuard and
Scrutiny are plain HTTP on the tailnet or home network. `<tailnet>` is your tailnet's name from the Tailscale
admin console. With a domain of your own, every app gets a short HTTPS name instead (still tailnet-only).

In the background, without you doing anything:

- **Alerts** to your phone through [ntfy](https://ntfy.sh): drive SMART changes (smartd), ZFS errors (ZED),
  power events from the UPS, monthly scrub results, hourly pool-capacity checks, a weekly drive health and
  latency report, backup results, and "reboot needed" after updates. Optionally also by email.
- **Snapshots** of the pool (hourly for photos, passwords and files) with [sanoid](https://github.com/jimsalterjrs/sanoid), so a deleted or
  overwritten file can be recovered.
- **Off-site backup** every night with [restic](https://restic.net) to Backblaze B2, plus a monthly read-back
  check: photos, the Immich database, passwords, files and settings (not media).
- **Clean shutdown** when the UPS battery runs low, so the pool isn't cut off mid-write.
- **Automatic updates** for Ubuntu, Docker, Tailscale and Node.js every night. Kernels are held back and
  upgraded by hand, and nothing reboots on its own.

The full schedule is in [RUNBOOK: Routine](docs/RUNBOOK.md#routine-automatic). Why the storage works this way,
including the lessons from AkitaOnRails' near-loss of a 90 TB NAS, is in [docs/DRIVE-PLAN.md](docs/DRIVE-PLAN.md).

## What you need before you start

**Hardware.** Any x86-64 machine that runs Ubuntu Server 24.04, with:

- An **NVMe SSD** for Ubuntu, the apps and the Immich database. Everything runs from here until the hard drives
  are in.
- **Two hard drives of the same size** for the ZFS mirror (each holds a full copy). They can come later.
- An **Intel CPU with integrated graphics** is assumed: Immich and Jellyfin use Quick Sync for video, and
  Immich's face recognition uses the OpenVINO image. See [Make it yours](#make-it-yours) if yours differs.
- Wired Ethernet if you can, and plenty of RAM (ZFS and Immich both use it).
- Optional: a **UPS** with a USB data cable, so the server shuts down cleanly in an outage.

The author's build, as one example: Core Ultra 5 250K Plus, ASUS B860M-A, 32 GB DDR5, 512 GB NVMe, Jonsbo N6
case, 2× WD Ultrastar HC550 18 TB (recertified), APC BE600M1 UPS.

**Accounts and services.**

| | What | Why |
|---|---|---|
| Required | A [Tailscale](https://tailscale.com) account, with **HTTPS Certificates** turned on (admin console, DNS page) | Private access from every device, and HTTPS for the apps |
| Required | An ntfy topic: a long random name on ntfy.sh, or your own ntfy server | Where every alert goes; subscribe to it in the ntfy phone app |
| Optional | A [Backblaze B2](https://www.backblaze.com/cloud-storage) bucket and an application key for it | Off-site backup |
| Optional | A free ntfy.sh account and access token | Emailing high and urgent alerts |
| Optional | A domain you own and a free [deSEC](https://desec.io) account | Addresses like `photos.home.example.com` ([RUNBOOK](docs/RUNBOOK.md#your-own-web-addresses-optional)) |
| Optional | A Google Cloud OAuth client | Importing Google Drive into OpenCloud ([RUNBOOK step 8](docs/RUNBOOK.md#8-import-google-drive-into-opencloud)) |

**A computer to work from**, to write the USB installer, SSH into the server and keep your copy of this repo.
The guides assume a Mac.

## Quick start

The [runbook](docs/RUNBOOK.md) is the step-by-step guide; this is the shape of it.

1. **Install Ubuntu Server 24.04 LTS** on the SSD with OpenSSH enabled, then get it online and add your SSH key.
   Leave the hard drives alone. → [RUNBOOK step 1](docs/RUNBOOK.md#1-install-ubuntu-server-2404-lts)
2. **Get the repo onto the server** at `~/obento` (a clone of your fork, or `rsync` from your computer),
   then copy the settings file and fill it in. Every `change-me` value needs a real one; `.env.example`
   explains each setting. → [RUNBOOK step 2](docs/RUNBOOK.md#2-bootstrap)

   ```bash
   cd ~/obento
   cp .env.example .env && chmod 600 .env && nano .env
   ```

3. **Install, join your tailnet, and install again.** The second run sets up HTTPS, which needs Tailscale
   connected first. `install.sh` is safe to re-run and never touches the hard drives.

   ```bash
   sudo ./install.sh
   sudo tailscale up --ssh
   sudo ./install.sh
   ```

4. **Start the apps** and create the first accounts. → [RUNBOOK step 3](docs/RUNBOOK.md#3-apps-on-the-ssd-until-the-drives-arrive)

   ```bash
   obento up
   obento status
   ```

Set `OPENCLOUD_ADMIN_PASSWORD` before the first `obento up`: OpenCloud only reads it on its first start.
Then set up your devices with [docs/MAC-SETUP.md](docs/MAC-SETUP.md) and [docs/IOS-SETUP.md](docs/IOS-SETUP.md).

## Optional: your own web addresses

If you own a domain, the apps can live at names like `photos.home.example.com` instead of
`tamago.<tailnet>.ts.net:8443`-style ports. They're easier to remember and type into apps, and they don't
change if you rename your tailnet. They're still private: the names point at the server's Tailscale address, so
they only work on devices in your tailnet.

What it adds:

- **Traefik**, one more app, which answers every name on port 443 and sends it to the right app
  (`config/traefik/dynamic.yml`).
- **A portal** at `https://home.example.com` with a tile per app and a status light (`config/homepage/`).
- **One Let's Encrypt certificate** for `home.example.com` and `*.home.example.com`, renewed automatically. To get it, the server
  proves it owns the name through **[deSEC](https://desec.io)**, a free DNS host with an API.

What you need: a domain, a free deSEC account with two records (`*` and the name itself) pointing at the
server's Tailscale IP, and
two `NS` records at your domain's DNS host that hand just the `home` part to deSEC. Your website and email
records stay where they are. Then three settings in `.env`:

```bash
APPS_DOMAIN=home.example.com
DESEC_TOKEN=<your deSEC token>
COMPOSE_PROFILES=domain
```

and `sudo ./install.sh && obento up`. Step by step, including moving each device over:
[RUNBOOK: Your own web addresses](docs/RUNBOOK.md#your-own-web-addresses-optional). Once it's on, the
`tamago.<tailnet>.ts.net` addresses stop working, so move every device over the same day. Without these
settings nothing changes: Traefik doesn't run and the Tailscale addresses above are used.

## Make it yours

Things written for the author's setup, where to change them, and whether you need to:

| What | Where | What to do |
|---|---|---|
| Hostname `tamago` | Chosen in the Ubuntu installer | Pick your own. Read `tamago` in the docs' addresses as your hostname; `install.sh` finds the real Tailscale name itself. |
| Username `brandon` | `docs/MAC-SETUP.md` (ssh config), RUNBOOK step 1 (`ssh-copy-id`) | Use your own account on the server. |
| Repo address | RUNBOOK step 2 (deploy key, `git clone`) | Use your fork's address. |
| Hardware workarounds | RUNBOOK steps 0–1: ASUS BIOS, Realtek RTL8125 Ethernet (needs the HWE kernel), MediaTek MT7922 Wi-Fi power saving, interface names `wlp131s0`/`eno1`, Ultrastar PWDIS/Molex note | Only follow the ones that match your hardware. `install.sh` holds the HWE kernel packages either way. |
| UPS model (APC BE600M1) | `config/nut/ups.conf` | `usbhid-ups` with `port = auto` covers many USB UPSes; change `desc`, or the driver if yours needs another. No UPS: leave it; `install.sh` warns that NUT will start once a UPS is connected, and nothing else depends on it. |
| UPS monitor password | `config/nut/upsd.users` and `config/nut/upsmon.conf` (`change-me-local-only`) | Change both to the same value. It's only used on the server itself. |
| LAN ranges | `install.sh`, firewall: `ufw allow from 192.168.0.0/16` and `10.0.0.0/8` | Fine for most home routers. If your network uses `172.16.x.x`, add a line for it. |
| Time zone | `TZ=America/Los_Angeles` in `.env` | Set yours. `install.sh` sets the server's clock to it too, so the timers run at local times. |
| pi coding agent | `config/pi/` (points at the author's own model server, `spark-e2ca:11437`); the "pi coding agent" block in `install.sh` | A personal extra. `install.sh` always installs Node.js 22 (from NodeSource) and pi, and copies `config/pi/` to `~/.pi/agent/`. Point `config/pi/models.json` at your own OpenAI-compatible server, or remove that block from `install.sh` in your fork. Unused, it does no harm. |
| GPU and drives passed to containers | `compose/docker-compose.yml`: `/dev/dri` (Immich, Jellyfin), the `-openvino` image, `/dev/nvme0` (Scrutiny) | Without an Intel iGPU or an NVMe drive, remove or change those lines, or the containers won't start. |
| Pool name, paths, alert threshold | `POOL_NAME`, `SSD_DATA`, `POOL_WARN_PCT` in `.env` | Safe to leave as they are. |

Everything else in `.env` (passwords, ntfy, B2) is yours to fill in; nothing there is shared with the author.

## The setup in stages

The setup is staged so the family can use the apps before the hard drives arrive, and so no data goes onto a
drive that hasn't been tested.

| Stage | Runbook | What happens |
|---|---|---|
| Install | [0–2](docs/RUNBOOK.md#2-bootstrap) | Ubuntu on the SSD, network, `install.sh`, Tailscale |
| Apps on the SSD | [3](docs/RUNBOOK.md#3-apps-on-the-ssd-until-the-drives-arrive) | Everything runs from `/srv`; set up accounts, AdGuard, devices. Start the Google Takeout export now: it can take a day or more |
| Burn-in | [4](docs/RUNBOOK.md#4-drives-arrive--burn-in-3-days) | `burnin.sh` writes and reads every sector of each new drive and compares SMART before and after (~3 days for 18 TB) |
| Pool | [5](docs/RUNBOOK.md#5-create-the-pool) | `create-pool.sh` builds the ZFS mirror `tank` from two drives that passed burn-in |
| Move data | [6](docs/RUNBOOK.md#6-move-immich-vaultwarden-and-opencloud-onto-the-pool) | Copy photos, passwords and files to `/tank`, check the copy, point `.env` at the new paths |
| Imports | [7–8](docs/RUNBOOK.md#7-import-google-photos-and-verify) | Google Photos into Immich, checked independently by `verify-takeout.py`; Google Drive into OpenCloud with rclone |
| Off-site backup | [9](docs/RUNBOOK.md#9-off-site-backup) | `backup.sh --init`, the first upload, a read-back check. Only then cancel the Google subscription |

## Day to day

Manage the apps with `obento` (it asks for your password, because it runs Docker with `sudo`):

```bash
obento up [app...]        # start apps, or apply changes
obento stop [app...]      # stop apps;  obento down stops and removes all of them (data is kept)
obento restart [app...]
obento status
obento logs -f [app...]
obento upgrade [app...]   # download newer app versions, restart what changed
obento signups on|off     # let new Vaultwarden accounts be created, briefly
obento apps               # list app names;  obento help for everything
```

**Making changes.** Edit your copy of the repo (on your computer, then push), and on the server:

```bash
obento update             # git pull in ~/obento, then sudo ./install.sh
obento up                 # if you changed .env or the compose file
```

Don't run `docker compose` from `~/obento/compose`: it wouldn't see the live settings. Use `obento`.

### Where things live on the server

| Location | What it is | Edit it? |
|---|---|---|
| `~/obento` | this repo (source of truth) | **yes**, then re-run `sudo ./install.sh` |
| `/opt/obento` | installed copy that systemd timers and compose run from (root-owned) | no, overwritten by `install.sh` |
| `/etc/obento/.env` | live settings and secrets (root only, 600) | no, copied from `~/obento/.env` |

The scripts run as root from systemd, so they run from a root-owned copy that only root can change, and the
secrets live where only root can read them. `/opt/obento/compose/.env` links to `/etc/obento/.env`,
which is why `obento` runs compose from there. Keep `~/obento/.env` at `chmod 600`. App data lives under
`/srv` on the SSD, and under `/tank` once the pool exists.

Drive replacement, restore tests and manual kernel updates are in the
[runbook's operations sections](docs/RUNBOOK.md#quarterly-restore-test).

## Repository layout

```
AGENTS.md                  notes for coding agents changing this repo
install.sh                 bootstrap (idempotent; doesn't touch the hard drives)
.env.example               every setting and secret; copy to .env
compose/docker-compose.yml the apps
scripts/
  obento                   manage the apps: obento up|down|stop|restart|status|logs|update|signups|apps
  burnin.sh                SMART + badblocks burn-in for new/recertified drives (DESTRUCTIVE)
  create-pool.sh           ZFS mirror + datasets (refuses drives without a burn-in PASS)
  print-scrutiny-devices.sh  device lines for Scrutiny once the hard drives are in
  backup.sh                restic → Backblaze B2 (+ Immich DB dump); --init, --verify
  verify-takeout.py        independent Google Takeout vs Immich diff → missing.txt
  scrub.sh                 monthly scrub with report
  check-capacity.sh        pool fill (POOL_WARN_PCT) and pool-health alerts
  health-report.sh         weekly SMART + per-drive latency report
  maintenance.sh           weekly Docker cleanup + "reboot needed" alert
  ups-notify.sh            UPS events → ntfy
  notify / lib.sh          ntfy alerts and shared helpers used by everything
config/
  nut/                     UPS monitoring and low-battery shutdown
  systemd/                 timers: backup, verify, capacity, scrub, health, maintenance
  pi/                      the author's pi coding agent settings (optional)
  traefik/dynamic.yml      which own-domain address goes to which app (optional, see APPS_DOMAIN)
  homepage/                the portal's tiles at https://<APPS_DOMAIN> (optional)
  smartd.conf  sanoid.conf  52obento-unattended  docker-daemon.json  sshd-hardening.conf
docs/
  RUNBOOK.md               step by step: install → apps → burn-in → pool → migrate → imports → backup → ops
  DRIVE-PLAN.md            why the storage is set up this way (incl. the Akita NAS lessons)
  MAC-SETUP.md             a Mac: Tailscale, ssh, and the apps
  IOS-SETUP.md             iPhone and iPad: Tailscale and the apps, for the whole family
```

## Setting up devices

Each person needs Tailscale on their devices, then the apps. [docs/MAC-SETUP.md](docs/MAC-SETUP.md) covers a
Mac (including `ssh tamago`), and [docs/IOS-SETUP.md](docs/IOS-SETUP.md) covers iPhone and iPad. Ad blocking
away from home through Tailscale is optional and off by default
([RUNBOOK](docs/RUNBOOK.md#ad-blocking-for-the-whole-network), step 5).

## Safety notes

Read each script before you run it. In particular:

- **`burnin.sh` erases the drive you give it**, completely. It only accepts `/dev/disk/by-id/...` paths, so
  check the model and serial number in the name against the drive you mean.
- **`create-pool.sh` builds the pool on the two drives you name.** Point it only at the new, burned-in drives;
  it refuses drives without a burn-in PASS and won't touch an existing pool, but it can't know which drives you
  meant.
- **Don't forward ports on your router** to this server. The apps are meant for your tailnet and home network
  only.
- **Store `RESTIC_PASSWORD` somewhere other than the server** (the runbook suggests Vaultwarden and paper).
  Without it the off-site backup can't be read.
