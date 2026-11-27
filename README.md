# 🍱 obento

Everything a family home server needs, packed into one box. obento turns a fresh **Ubuntu Server 24.04 LTS**
install into a home server for photos, passwords, files, media and network-wide ad blocking, with drive-health
alerts, snapshots and off-site backup. Nothing is published to the internet: everyone reaches the apps through
**Tailscale**, a private network (a "tailnet") that joins your own devices wherever they are.

It's a set of Bash scripts, Docker Compose files and configuration, not a product: you run one install script
on a machine you own, then manage the apps with the `obento` command. Expect to be comfortable with SSH and a
Linux terminal; the [runbook](docs/RUNBOOK.md) walks through every step, and the family only ever sees the
apps.

> **Status:** in daily use on the author's server, with every app running from the SSD. The hard-drive stages
> (burn-in, creating the pool, moving data onto it: runbook steps 4–6) are written but haven't been run yet.

**Reading the docs:** they were written for one machine, whose hostname is **`tamago`**. Wherever you see
`tamago` (`ssh tamago`, `https://tamago.<tailnet>.ts.net`), read your own server's hostname. `<tailnet>` is your
tailnet's name from the Tailscale admin console, and `home.example.com` stands for a domain of yours.
[Make it yours](#make-it-yours) lists every other setting that came from the author's build.

## What you get

**The core apps**, always installed:

| App | What it's for | Address | With [your own domain](#domain-your-own-web-addresses-and-a-portal) |
|---|---|---|---|
| [Immich](https://immich.app) | Photo and video backup from phones (a Google Photos replacement) | `https://tamago.<tailnet>.ts.net` | `https://photos.<domain>` |
| [Vaultwarden](https://github.com/dani-garcia/vaultwarden) | Family password manager; works with the Bitwarden apps | `https://tamago.<tailnet>.ts.net:8443` | `https://passwords.<domain>` |
| [Jellyfin](https://jellyfin.org) | Movies, shows and music | `https://tamago.<tailnet>.ts.net:8920` | `https://media.<domain>` |
| [AdGuard Home](https://adguard.com/adguard-home/overview.html) | Blocks ads and trackers for every device on the home network (DNS on port 53) | `http://tamago:3000` | `https://adblock.<domain>` |
| [Scrutiny](https://github.com/AnalogJ/scrutiny) | Dashboard of drive health over time | `http://tamago:8080` | `https://drives.<domain>` |

**Modules**, the parts you choose (see [Modules](#modules)):

| Module | What it adds | Address |
|---|---|---|
| `opencloud` | Files synced across devices ([OpenCloud](https://opencloud.eu), a Google Drive replacement) | `https://tamago.<tailnet>.ts.net:9200`, or `https://files.<domain>` |
| `ups` | Clean shutdown when a USB-connected UPS runs low, and power alerts | |
| `domain` | Your own short addresses for every app, and a portal: one page with every app, whether it's up, and the server's CPU, memory, SSD, free space on the hard drives and UPS battery ([Homepage](https://gethomepage.dev)) | `https://<domain>` |
| `downloads` | A request page for shows and films, which are then downloaded from Usenet into Jellyfin's library with subtitles (Seerr, Sonarr, Radarr, Prowlarr, SABnzbd, Bazarr); needs `domain` | `https://requests.<domain>` and friends |
| `pi` | The [pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) coding agent on the server (and Node.js 22), using a model server of your own | |
| `shell` | A nicer terminal on the server: the [Starship](https://starship.rs) prompt with the server's name in red, fuzzy history search (Ctrl-R), `z` to jump to folders, `ls` and `cat` with colours | |

Without `domain`, the HTTPS addresses come from `tailscale serve` and work only inside your tailnet; AdGuard and
Scrutiny are plain HTTP on the tailnet or home network. With `domain`, every app gets a short HTTPS name instead
(still reachable only from your tailnet, and optionally your home network).

In the background, without you doing anything:

- **Alerts** to your phone through [ntfy](https://ntfy.sh): drive SMART changes (smartd), ZFS errors (ZED),
  UPS power events, monthly scrub results, hourly pool-capacity checks, a weekly drive health and latency
  report, backup results, and "reboot needed" after updates. Optionally also by email.
- **Snapshots** of the pool with [sanoid](https://github.com/jimsalterjrs/sanoid) (hourly for photos,
  passwords and files), so a deleted or overwritten file can be recovered.
- **Off-site backup** every night with [restic](https://restic.net) to Backblaze B2, plus a monthly read-back
  check: photos, the Immich database, passwords, files and settings (not media).
- **Clean shutdowns**: every app is stopped in order whenever the server shuts down or reboots, and with the
  `ups` module the server shuts itself down before the UPS battery runs out.
- **Automatic updates** for Ubuntu, Docker and Tailscale every night. Kernels are held back and upgraded by
  hand, and nothing reboots on its own.

The full schedule is in [RUNBOOK: Routine](docs/RUNBOOK.md#routine-automatic). Why the storage works this way,
including the lessons from AkitaOnRails' near-loss of a 90 TB NAS, is in [docs/DRIVE-PLAN.md](docs/DRIVE-PLAN.md).

## What you need

**Hardware.** Any x86-64 machine that runs Ubuntu Server 24.04, with:

- An **NVMe SSD** for Ubuntu, the apps and the Immich database. Everything runs from here until the hard drives
  are in.
- **Two hard drives of the same size** for the ZFS mirror (each holds a full copy). They can come later.
- An **Intel CPU with integrated graphics** is assumed: Immich and Jellyfin use Quick Sync for video, and
  Immich's face recognition uses the OpenVINO image. See [Make it yours](#make-it-yours) if yours differs.
- Wired Ethernet if you can, and plenty of RAM (ZFS and Immich both use it; 32 GB is comfortable).
- Optional: a **UPS** with a USB data cable (`ups` module).

The author's build, as one example: Core Ultra 5 250K Plus, ASUS B860M-A, 32 GB DDR5, 512 GB NVMe, Jonsbo N6
case, 2× WD Ultrastar HC550 18 TB (recertified), APC BE600M1 UPS.

**Accounts and services.**

| For | What | Why |
|---|---|---|
| Required | A [Tailscale](https://tailscale.com) account (the free plan is enough), with **HTTPS Certificates** turned on (admin console, DNS page) | Private access from every device, and HTTPS for the apps |
| Required | An ntfy topic: a long random name on ntfy.sh, or your own ntfy server | Where every alert goes; subscribe to it in the ntfy phone app |
| Recommended | A [Backblaze B2](https://www.backblaze.com/cloud-storage) bucket and an application key for it | Off-site backup |
| Optional | A free ntfy.sh account and access token | Emailing high and urgent alerts |
| `domain` module | A domain you own and a free [deSEC](https://desec.io) account | Addresses like `photos.home.example.com` |
| `downloads` module | A Usenet provider and an indexer (both paid) | Where shows and films come from |
| Optional | A Google Cloud OAuth client | Importing Google Drive into OpenCloud ([RUNBOOK step 8](docs/RUNBOOK.md#8-import-google-drive-into-opencloud)) |

**A computer to work from**, to write the USB installer, SSH into the server and keep your copy of this repo.
The guides assume a Mac; any computer with SSH works.

## What install.sh changes on the server

`install.sh` is meant for a machine that does nothing else. Run it on a fresh Ubuntu install, not on a computer
you already use for other things. It runs as root and:

- **Installs** Docker (from Docker's own repository), Tailscale, ZFS, smartmontools, sanoid, restic, rclone and
  a few tools, plus what each module needs (NUT for `ups`).
- **Locks down access**: SSH by key only (once a key is present), and a firewall (ufw) that allows only the
  home network (`192.168.0.0/16`, `10.0.0.0/8`) and the tailnet.
- **Turns on automatic updates** (Ubuntu, Docker, Tailscale) and holds the kernel packages, so kernels are
  only upgraded by hand.
- **Frees port 53** for AdGuard by turning off systemd-resolved's local DNS listener, and sets the server's time
  zone from `TZ`.
- **Configures Docker** to keep apps running while Docker itself updates, and caps container log sizes.
- **Copies the repo** to `/opt/obento` and the settings to `/etc/obento/.env` (readable only by root), and
  links the `obento` command into `/usr/local/bin`.
- **Adds systemd timers and alerts**: drive health (smartd), ZFS events (ZED), scrubs, capacity checks, a
  weekly report and cleanup, backups once you set them up, and clean app shutdown.
- **Publishes the apps on your tailnet** with `tailscale serve`, or through Traefik with the `domain` module.

It never touches the hard drives: wiping and pooling them are separate scripts you run yourself. It's safe to
run again; it only changes what differs.

## Quick start

The [runbook](docs/RUNBOOK.md) is the step-by-step guide; this is the shape of it.

1. **Fork this repo** on GitHub, so your settings changes have somewhere to live, and clone your fork on your
   computer.
2. **Install Ubuntu Server 24.04 LTS** on the SSD with OpenSSH enabled, get it online and add your SSH key.
   Leave the hard drives alone. → [RUNBOOK step 1](docs/RUNBOOK.md#1-install-ubuntu-server-2404-lts)
3. **Get your fork onto the server** at `~/obento` (`git clone`, or `rsync` from your computer), then copy the
   settings file and fill it in. Every `change-me` value needs a real one; `.env.example` explains each setting.
   Choose your [modules](#modules) in `MODULES`; it starts as `opencloud,ups`. → [RUNBOOK step 2](docs/RUNBOOK.md#2-bootstrap)

   ```bash
   cd ~/obento
   cp .env.example .env && chmod 600 .env && nano .env
   ```

4. **Install, join your tailnet, and install again.** The second run sets up HTTPS, which needs Tailscale
   connected first.

   ```bash
   sudo ./install.sh
   sudo tailscale up --ssh
   sudo ./install.sh
   ```

5. **Start the apps** and create the first accounts. → [RUNBOOK step 3](docs/RUNBOOK.md#3-apps-on-the-ssd-until-the-drives-arrive)

   ```bash
   obento up
   obento status
   ```

With the `opencloud` module, set `OPENCLOUD_ADMIN_PASSWORD` before the first `obento up`: OpenCloud only reads
it on its first start. Then set up everyone's devices ([Setting up devices](#setting-up-devices)). When the
hard drives arrive, continue with [the later stages](#the-setup-in-stages).

## Modules

The core apps are always there; everything else is a module you switch on in `.env`:

```bash
MODULES=domain,opencloud,ups,downloads,pi    # the author's setup
```

then `obento update && obento up`. Taking one out and doing the same removes its apps, addresses and portal
tiles; its data stays, so switching it back on picks up where it left off. `obento modules` shows which are
on. Each module is one folder under [modules/](modules/README.md), which also explains how to add your own.

| Module | Needs | Turning it on |
|---|---|---|
| `opencloud` | | Set `OPENCLOUD_ADMIN_PASSWORD` first ([RUNBOOK step 3](docs/RUNBOOK.md#3-apps-on-the-ssd-until-the-drives-arrive)) |
| `ups` | A UPS on USB | Check your model in `modules/ups/nut/ups.conf` ([Make it yours](#make-it-yours)) |
| `domain` | A domain, deSEC | [Below](#domain-your-own-web-addresses-and-a-portal) |
| `downloads` | `domain`, a Usenet provider and indexer | [Below](#downloads-automatic-tv-and-films) |
| `pi` | An OpenAI-compatible model server | Set `PI_URL` and `PI_MODEL` in `.env`; `sudo ./install.sh` writes `~/.pi/agent` for you once |
| `shell` | | Adds one line to the end of each account's `~/.bashrc`; open a new terminal to see it |

### domain: your own web addresses and a portal

If you own a domain, the apps can live at names like `photos.home.example.com` instead of
`tamago.<tailnet>.ts.net:8443`-style ports. They're easier to remember and type into apps, and they don't
change if you rename your tailnet. They're still private: the names point at the server's Tailscale address, so
they only work on devices in your tailnet (and, if you like, on your home network for devices such as a smart
TV that can't run Tailscale).

What it adds:

- **Traefik**, one more app, which answers every name on port 443 and sends it to the right app. Each
  module declares its names (`HOSTS` in its `module.conf`); rename one in `.env` with `HOST_<NAME>`, for
  example `HOST_REQUESTS=ask` for `ask.home.example.com`.
- **A portal** at `https://home.example.com` with a tile per app and a status light, plus the hard drives' free space and the UPS battery
  (`modules/domain/homepage/`; `PORTAL_TITLE` and `PORTAL_LOGO` in `.env` add your own name and image).
- **One Let's Encrypt certificate** for `home.example.com` and `*.home.example.com`, renewed automatically. To
  get it, the server proves it owns the name through **[deSEC](https://desec.io)**, a free DNS host with an API.

What you need: a domain, a free deSEC account with two records (`*` and the name itself) pointing at the
server's Tailscale IP, and two `NS` records at your domain's DNS host that hand just the `home` part to deSEC.
Your website and email records stay where they are. Then three settings in `.env`:

```bash
APPS_DOMAIN=home.example.com
DESEC_TOKEN=<your deSEC token>
MODULES=domain,opencloud,ups       # domain added to the modules you use
```

and `obento update && obento up`. Step by step, including moving each device over:
[RUNBOOK: Your own web addresses](docs/RUNBOOK.md#your-own-web-addresses-optional). Once it's on, the
`tamago.<tailnet>.ts.net` addresses stop working, so move every device over the same day.

### downloads: automatic TV and films

Someone asks for a show or film on a request page (Seerr, which the family signs into with their Jellyfin
accounts); Sonarr (TV) or Radarr (films) finds it through your indexer, SABnzbd downloads it from your Usenet
provider (encrypted, nothing uploaded, so no VPN), and it appears in Jellyfin. Bazarr then fetches subtitles
in your languages. Addresses: `requests.`, `tv.`, `movies.`, `downloads.`, `indexers.`, `subtitles.`. Put the
provider and indexer in `.env` (`USENET_*`, `NZB_INDEXER*`), optionally `SUBTITLE_LANGUAGES` and a free
OpenSubtitles.com login (`OPENSUBTITLES_*`), add `downloads` to `MODULES`, then:

```bash
obento update && obento up
sudo obento setup downloads    # connects the six apps and Jellyfin to each other; safe to re-run
```

Step by step, and what the setup does by hand:
[RUNBOOK: Automatic TV and film downloads](docs/RUNBOOK.md#automatic-tv-and-film-downloads-optional-after-step-6).
Best switched on after the hard drives are in (step 6): films are 5–15 GB each. What you download is your
responsibility; make sure you have the right to it where you live.

## Make it yours

Settings that came from the author's build, where they are, and whether you need to change them:

| What | Where | What to do |
|---|---|---|
| Hostname `tamago` | Chosen in the Ubuntu installer | Pick your own. `install.sh` finds the real Tailscale name itself; only the docs say `tamago`. |
| Your account and fork | `<you>` and `<your-github>/obento` in the RUNBOOK and `docs/MAC-SETUP.md` | Your account on the server and your fork's address. A deploy key is only needed if your fork is private. |
| Which optional parts you want | `MODULES` in `.env` ([modules/README.md](modules/README.md)) | `opencloud` (files), `ups`, `domain` (own addresses and the portal), `downloads`. |
| Hardware workarounds | RUNBOOK steps 0–1: ASUS BIOS, Realtek RTL8125 Ethernet (needs the HWE kernel), MediaTek MT7922 Wi-Fi power saving (first boot only; the server then switches to Ethernet), interface names `wlp131s0`/`eno1`, Ultrastar PWDIS/Molex note | Only follow the ones that match your hardware. `install.sh` holds the HWE kernel packages either way. |
| GPU and drives passed to containers | `compose/docker-compose.yml`: `/dev/dri` (Immich, Jellyfin), the `-openvino` image, `/dev/nvme0` (Scrutiny) | Without an Intel iGPU or an NVMe drive, remove or change those lines, or the containers won't start. |
| UPS model (APC BE600M1) | `modules/ups/nut/ups.conf` | `usbhid-ups` with `port = auto` covers many USB UPSes; change `desc`, or the driver if yours needs another. No UPS: leave `ups` out of `MODULES`. |
| UPS monitor password | `modules/ups/nut/upsd.users` and `upsmon.conf` (`change-me-local-only`) | Change both to the same value. It's only used on the server itself. |
| Home network ranges | `install.sh`, firewall: `ufw allow from 192.168.0.0/16` and `10.0.0.0/8` | Fine for most home routers. If your network uses `172.16.x.x`, add a line for it. |
| Time zone | `TZ=America/Los_Angeles` in `.env` | Set yours. `install.sh` sets the server's clock to it too, so the timers run at local times. |
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
| Move data | [6](docs/RUNBOOK.md#6-move-immich-vaultwarden-opencloud-and-media-onto-the-pool) | Copy photos, passwords, files and media to `/tank`, check the copy, point `.env` at the new paths |
| Imports | [7–8](docs/RUNBOOK.md#7-import-google-photos-and-verify) | Google Photos into Immich, checked independently by `verify-takeout.py`; Google Drive into OpenCloud with rclone |
| Off-site backup | [9](docs/RUNBOOK.md#9-off-site-backup) | `backup.sh --init`, the first upload, a read-back check. Only then cancel the Google subscription |

## Setting up devices

Each person needs Tailscale on their devices, then the apps. [docs/MAC-SETUP.md](docs/MAC-SETUP.md) covers a
Mac (including `ssh tamago`), and [docs/IOS-SETUP.md](docs/IOS-SETUP.md) covers iPhone and iPad; both are
written for family members, not admins. Ad blocking away from home through Tailscale is optional and off by
default ([RUNBOOK](docs/RUNBOOK.md#ad-blocking-for-the-whole-network), step 5).

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
obento modules            # which modules are on
obento setup <module>     # connect a module's apps to each other (downloads)
obento apps               # list app names;  obento help for everything
```

**Making changes.** Change your fork (on your computer, then push), and on the server:

```bash
obento update             # git pull in ~/obento, then sudo ./install.sh
obento up                 # if you changed .env (MODULES too) or a compose file
```

The same two commands bring in changes from this repo once you've merged them into your fork. Don't run
`docker compose` from `~/obento/compose`: it wouldn't see the live settings. Use `obento`.

### Where things live on the server

| Location | What it is | Edit it? |
|---|---|---|
| `~/obento` | your fork (source of truth), including `.env` | **yes**, then `obento update` |
| `/opt/obento` | installed copy that systemd timers and compose run from (root-owned) | no, overwritten by `install.sh` |
| `/etc/obento/.env` | live settings and secrets (root only, 600) | no, copied from `~/obento/.env` |
| `/opt/obento/compose/files`, `/opt/obento/generated/` | which compose files are in use, Traefik's routes: written by `install.sh` from `MODULES` | no |
| `/srv`, later `/tank` | app data: on the SSD, then on the pool once it exists | through the apps |

The scripts run as root from systemd, so they run from a root-owned copy that only root can change, and the
secrets live where only root can read them. Keep `~/obento/.env` at `chmod 600`; it's listed in `.gitignore`,
so it never ends up in your fork.

Drive replacement, restore tests and manual kernel updates are in the
[runbook's operations sections](docs/RUNBOOK.md#quarterly-restore-test).

## Repository layout

```
AGENTS.md                  notes for coding agents changing this repo
CONTRIBUTING.md, LICENSE   how to contribute; MIT
install.sh                 bootstrap (idempotent; doesn't touch the hard drives)
.env.example               every setting and secret; copy to .env
compose/docker-compose.yml the core apps
modules/                   the optional parts, one folder each (README.md: what a module holds)
  core/                    always on: the core apps' addresses and portal tiles
  domain/                  Traefik, the portal (homepage/: its look)
  opencloud/               OpenCloud
  ups/                     NUT config, UPS alerts, the battery gauge's source
  downloads/               Seerr, Sonarr, Radarr, Prowlarr, SABnzbd, Bazarr; setup.sh connects them
  pi/                      the pi coding agent and Node.js
  shell/                   the shell prompt (starship.toml) and tools (bashrc)
scripts/
  obento                   manage the apps: obento up|down|stop|restart|status|logs|update|upgrade|modules|setup|...
  modules.sh               which modules are on, their addresses, routes, portal tiles and compose files
  burnin.sh                SMART + badblocks burn-in for new/recertified drives (DESTRUCTIVE)
  create-pool.sh           ZFS mirror + datasets (refuses drives without a burn-in PASS)
  print-scrutiny-devices.sh  device lines for Scrutiny once the hard drives are in
  backup.sh                restic → Backblaze B2 (+ Immich DB dump); --init, --verify
  verify-takeout.py        independent Google Takeout vs Immich diff → missing.txt
  scrub.sh                 monthly scrub with report
  check-capacity.sh        pool fill (POOL_WARN_PCT) and pool-health alerts
  health-report.sh         weekly SMART + per-drive latency report
  maintenance.sh           weekly Docker cleanup + "reboot needed" alert
  notify / lib.sh          ntfy alerts and shared helpers used by everything
config/
  systemd/                 timers: backup, verify, capacity, scrub, health, maintenance; clean app shutdown
  smartd.conf  sanoid.conf  52obento-unattended  docker-daemon.json  sshd-hardening.conf
docs/
  RUNBOOK.md               step by step: install → apps → burn-in → pool → migrate → imports → backup → ops
  DRIVE-PLAN.md            why the storage is set up this way (incl. the Akita NAS lessons)
  MAC-SETUP.md             a Mac: Tailscale, ssh, and the apps
  IOS-SETUP.md             iPhone and iPad: Tailscale and the apps, for the whole family
```

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
- **Keep a copy of your photos elsewhere until the off-site backup has run and been checked** (step 9). A home
  server is one building; the runbook's order exists so nothing is ever only on it.

## Contributing and license

Fixes, clearer docs and new modules are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md). Coding agents working
on this repo should read [AGENTS.md](AGENTS.md) first.

obento is released under the [MIT License](LICENSE). The apps it installs (Immich, Vaultwarden, Jellyfin and
the rest) are separate projects with their own licenses.
