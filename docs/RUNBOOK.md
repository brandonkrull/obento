# Runbook

Commands assume you're in the repo (`~/homeserver`) unless they say `/opt/homeserver`.

## 0. Hardware and BIOS (once)

- Power the drive backplane from **Molex only** (Ultrastar PWDIS — see DRIVE-PLAN.md).
- Rear fans: fan switch SATA plug → power supply SATA power; fans' 2-pin plug → the switch harness.
- BIOS (ASUS, F7 for Advanced Mode):
  - **Ai Tweaker → power limits: PL1 = PL2 = 65 W** (required with a low-profile cooler; quieter and plenty for a NAS either way).
  - Advanced → Onboard Devices: leave the iGPU **enabled** (Quick Sync for Immich/Jellyfin).
  - Boot → **Restore AC Power Loss: Power On** (comes back after an outage).
  - Q-Fan: CPU fan "Standard"; chassis headers unused (fans run off the case switch).
- Ethernet plugged in. Leave Wi-Fi off.

## 1. Install Ubuntu Server 24.04 LTS

- Flash the ISO to a USB stick (balenaEtcher or Rufus); install to the **NVMe**, default layout, enable OpenSSH,
  import your SSH key from GitHub when asked.
- Don't install anything onto the hard drives.

## 2. Bootstrap

```bash
git clone <your repo> ~/homeserver && cd ~/homeserver
cp .env.example .env && nano .env          # fill in every "change-me"
sudo ./install.sh
sudo tailscale up --ssh
sudo systemctl status smartmontools        # you should get a "test" ntfy alert per drive
```

Install the **ntfy** app on your phone and subscribe to your `NTFY_TOPIC`.

## 3. Apps (on the SSD until the drives arrive)

```bash
cd /opt/homeserver/compose
sudo docker compose up -d
sudo docker compose ps
```

HTTPS inside your tailnet (needed for Vaultwarden, nicer everywhere):

```bash
sudo tailscale serve --bg --https=443  http://localhost:2283   # Immich   -> https://nas.<tailnet>.ts.net
sudo tailscale serve --bg --https=8443 http://localhost:8222   # Vaultwarden
sudo tailscale serve --bg --https=8920 http://localhost:8096   # Jellyfin
```

- Immich: create the admin account, then **Account Settings → API Keys** → put it in `.env` as `IMMICH_API_KEY`
  and re-run `sudo ./install.sh` (copies .env). Administration → Settings → Machine Learning: OpenVINO is used automatically.
  Video transcoding → hardware acceleration: **Quick Sync**.
- AdGuard: http://nas:3000 setup wizard. Later point your router's DNS at the NAS's LAN IP.
- Vaultwarden: signups are disabled by default. To create the family's accounts,
  temporarily set `SIGNUPS_ALLOWED: "true"`, create accounts for the family, set it back, `docker compose up -d`.
- Test with a few hundred photos (phone app → backup).

**Start the Google Takeout now** (Google Photos only, .zip, 50 GB parts). It can take a day+ to prepare.

## 4. Drives arrive → burn-in (~3 days)

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL            # both 18 TB drives visible? If not: PWDIS / Molex
ls -l /dev/disk/by-id/ | grep -v part | grep ata-
sudo tmux new -s burnA 'sudo /opt/homeserver/scripts/burnin.sh /dev/disk/by-id/ata-WDC_WUH721818ALE604_AAAA'
# detach: Ctrl-b d
sudo tmux new -s burnB 'sudo /opt/homeserver/scripts/burnin.sh /dev/disk/by-id/ata-WDC_WUH721818ALE604_BBBB'
```

You'll get ntfy alerts on start, PASS or FAIL. A FAIL → warranty claim with ServerPartDeals.

## 5. Create the pool

```bash
sudo /opt/homeserver/scripts/create-pool.sh /dev/disk/by-id/ata-..._AAAA /dev/disk/by-id/ata-..._BBBB
/opt/homeserver/scripts/print-scrutiny-devices.sh   # paste into compose scrutiny devices:, then docker compose up -d
```

## 6. Move Immich (and Vaultwarden) onto the pool

```bash
cd /opt/homeserver/compose && sudo docker compose stop immich-server immich-machine-learning vaultwarden
sudo rsync -aHAX --info=progress2 /srv/immich/library/ /tank/photos/
sudo rsync -aHAX /srv/vaultwarden/ /tank/vaultwarden/
# verify BEFORE switching (lesson: never trust a silent copy)
sudo rsync -aHAXn --checksum --itemize-changes /srv/immich/library/ /tank/photos/ | head   # must print nothing
sudo rsync -aHAXn --checksum --itemize-changes /srv/vaultwarden/ /tank/vaultwarden/ | head
```

Edit `.env`: `IMMICH_UPLOAD_LOCATION=/tank/photos`, `VAULTWARDEN_DATA=/tank/vaultwarden`,
`MEDIA_LOCATION=/tank/media` → `sudo ./install.sh` → `cd /opt/homeserver/compose && sudo docker compose up -d`.
Check photos load, then delete the old copies on the SSD a week later.

## 7. Import Google Photos and verify

```bash
# immich-go (github.com/simulot/immich-go) — check its README for the current syntax
immich-go upload from-google-photos --server=http://localhost:2283 --api-key=$IMMICH_API_KEY /path/to/takeout-*.zip
# extract the Takeout zips to a folder, then compare independently:
python3 -I /opt/homeserver/scripts/verify-takeout.py /path/to/extracted/Takeout --env /etc/homeserver/.env
```

`missing.txt` must be empty (or every line explained) before moving on.

## 8. Off-site backup

1. Backblaze: create a **private** bucket + an application key limited to that bucket. Fill the restic vars in `.env`.
2. Save `RESTIC_PASSWORD` in Vaultwarden **and** on paper in a drawer.
3. `sudo ./install.sh && sudo /opt/homeserver/scripts/backup.sh --init`
4. First run: `sudo systemctl start homeserver-backup` (1.6 TB upload takes days on home upload speeds; it resumes).
5. When it finishes: `sudo /opt/homeserver/scripts/backup.sh --verify`.

**Only now cancel Google One.**

## Routine (automatic)

| What | When | Alert |
|---|---|---|
| SMART short / long self-tests | daily / monthly | on any change |
| ZFS events (errors, degraded) | instantly | urgent |
| Scrub | 1st Sunday monthly | result either way |
| Capacity ≥ 80% / pool not ONLINE | hourly check | high / urgent |
| Drive health + latency report | Mondays 8 am | weekly |
| Snapshots (sanoid) | hourly, kept 24h/30d/12m | — |
| B2 backup | nightly 3:30 am | OK / FAILED |
| B2 read-back check (5%) | monthly | result |
| UPS on battery / low battery | instantly | auto-shutdown on low battery |

## Quarterly restore test

```bash
sudo bash -c 'source /opt/homeserver/scripts/lib.sh; load_env; export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
restic restore latest --target /tmp/restore-test --include "/tank/photos/library" --verify 2>&1 | tail -5'
# open a few random photos from /tmp/restore-test, then rm -rf /tmp/restore-test
```

## Replacing a drive (the article's failure mode — follow in order)

1. `zpool status -v tank` and `sudo smartctl -a` on **every** drive; check Scrutiny history.
2. If more than one drive shows errors: **stop.** Make sure last night's B2 backup succeeded (or run one) before touching anything.
3. Replace the **weakest** drive first. Burn in the new drive (step 4) unless the pool is degraded and urgent.
4. `sudo zpool replace tank <old-by-id> /dev/disk/by-id/<new>` and watch `zpool status` until the resilver finishes.
5. Scrub afterwards: `sudo /opt/homeserver/scripts/scrub.sh`.

## Kernel updates (manual)

```bash
sudo apt-mark unhold linux-image-generic linux-headers-generic linux-generic
sudo apt update && sudo apt full-upgrade
sudo apt-mark hold linux-image-generic linux-headers-generic linux-generic
sudo reboot
```

If something breaks (NVMe, ZFS, network): reboot, choose **Advanced options for Ubuntu** in GRUB and boot the
previous kernel. Ubuntu keeps it installed.
