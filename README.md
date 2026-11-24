# homeserver

One repo that turns a fresh **Ubuntu Server 24.04 LTS** install into the family NAS:
Immich (photos), Vaultwarden (passwords), AdGuard Home (DNS blocking), Jellyfin (media),
Scrutiny (drive dashboard), plus ZFS, monitoring, snapshots, off-site backup and UPS shutdown.

Hardware: Core Ultra 5 250K Plus · ASUS B860M-A · 32 GB DDR5 · 512 GB NVMe (OS, apps, Immich DB) ·
Jonsbo N6 · 2× WD Ultrastar HC550 18 TB recertified (ZFS mirror) · APC BE600M1.

```
install.sh                 bootstrap (idempotent; doesn't touch the hard drives)
.env.example               every setting and secret; copy to .env
compose/docker-compose.yml the apps
scripts/
  burnin.sh                SMART + badblocks burn-in for new/recertified drives (destructive)
  create-pool.sh           ZFS mirror + datasets (refuses drives without a burn-in PASS)
  backup.sh                restic → Backblaze B2 (+ Immich DB dump); --init, --verify
  verify-takeout.py        independent Google Takeout vs Immich diff → missing.txt
  scrub.sh                 monthly scrub with report
  check-capacity.sh        80% / pool-health alerts
  health-report.sh         weekly SMART + per-drive latency report
  tamago                   start/stop/check the apps: tamago up|down|stop|restart|status|logs|update
  notify / lib.sh          ntfy alerts used by everything (smartd, ZED, UPS, timers)
config/                    smartd, sanoid, NUT (UPS), unattended-upgrades, sshd, systemd timers, pi
docs/DRIVE-PLAN.md         why the storage is set up this way (incl. the Akita NAS lessons)
docs/RUNBOOK.md            step-by-step: install → apps → burn-in → pool → migrate → backup → ops
```

Start with **docs/RUNBOOK.md**.

## Where things live on the server

| Location | What it is | Edit it? |
|---|---|---|
| `~/homeserver` | this repo (source of truth) | **yes**, then re-run `sudo ./install.sh` |
| `/opt/homeserver` | installed copy that systemd timers and compose run from (root-owned) | no, overwritten by `install.sh` |
| `/etc/homeserver/.env` | live settings and secrets (root only, 600) | no, copied from `~/homeserver/.env` |

`/opt/homeserver/compose/.env` links to `/etc/homeserver/.env`, so manage the apps with `tamago` (it runs
compose from there with `sudo`), not from `~/homeserver/compose`. Keep `~/homeserver/.env` at `chmod 600`.

> Status: written for this exact build, not yet run on the hardware. Read each script before running it,
> especially `burnin.sh` (erases the drive you pass it) and `create-pool.sh`.
