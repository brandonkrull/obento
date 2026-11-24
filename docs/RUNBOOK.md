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
with `rsync -a ~/path/to/homeserver/ <server>:homeserver/`.

Deploy key (optional):

```bash
# on the server
ssh-keygen -t ed25519 -N "" -C "tamago deploy key (read-only)" -f ~/.ssh/github_homeserver
cat ~/.ssh/github_homeserver.pub
cat >> ~/.ssh/config <<'EOF'
Host github.com
  IdentityFile ~/.ssh/github_homeserver
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config

# on your Mac (or paste the .pub into GitHub → repo Settings → Deploy keys, leave "Allow write access" off)
ssh tamago cat .ssh/github_homeserver.pub > /tmp/tamago.pub
gh repo deploy-key add /tmp/tamago.pub -R brandonkrull/homeserver --title "tamago (read-only)"

# on the server: check GitHub's key fingerprint against
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
# when asked, then clone
git clone git@github.com:brandonkrull/homeserver.git ~/homeserver
```

Then, either way:

```bash
cd ~/homeserver
cp .env.example .env && chmod 600 .env && nano .env   # fill in every "change-me"
sudo ./install.sh
sudo tailscale up --ssh
sudo ./install.sh                          # again, now that Tailscale is up: sets up HTTPS for the apps
sudo systemctl status smartmontools        # you should get a "test" ntfy alert per drive
```

Install the **ntfy** app on your phone and subscribe to your `NTFY_TOPIC`.

Later changes: edit and push from your Mac, then on the server `cd ~/homeserver && git pull && sudo ./install.sh`
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

```bash
tamago up        # starts every app (asks for your password); 'tamago help' lists the other commands
tamago status
```

Where to find them (on any device signed into Tailscale; at home you can also use the server's LAN IP):

| App | Address |
|---|---|
| Immich | https://tamago.<tailnet>.ts.net |
| Vaultwarden | https://tamago.<tailnet>.ts.net:8443 (HTTPS only) |
| Jellyfin | https://tamago.<tailnet>.ts.net:8920 or http://tamago:8096 |
| AdGuard Home | http://tamago:3000 (first-run setup) |
| Scrutiny | http://tamago:8080 |

`install.sh` sets up the HTTPS addresses with `tailscale serve` once Tailscale is connected (it prints them at
the end). It needs **HTTPS Certificates** turned on in the Tailscale admin console (DNS page); if they're off,
`install.sh` says so. They're only reachable inside your tailnet, never from the internet.

- Immich: create the admin account, then **Account Settings → API Keys** → put it in `.env` as `IMMICH_API_KEY`
  and re-run `sudo ./install.sh` (copies .env). Administration → Settings → Machine Learning: OpenVINO is used automatically.
  Video transcoding → hardware acceleration: **Quick Sync**.
- AdGuard: http://tamago:3000 setup wizard. Later point your router's DNS at the server's LAN IP.
- Vaultwarden: sign-ups are off by default. To create the family's accounts, run `tamago signups on`,
  create them at https://tamago.<tailnet>.ts.net:8443, then `tamago signups off` (any `tamago up` also turns them off).
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
/opt/homeserver/scripts/print-scrutiny-devices.sh   # paste into ~/homeserver/compose scrutiny devices:, sudo ./install.sh, tamago up scrutiny
```

## 6. Move Immich (and Vaultwarden) onto the pool

```bash
tamago stop immich-server immich-machine-learning vaultwarden
sudo rsync -aHAX --info=progress2 /srv/immich/library/ /tank/photos/
sudo rsync -aHAX /srv/vaultwarden/ /tank/vaultwarden/
# verify BEFORE switching (lesson: never trust a silent copy)
sudo rsync -aHAXn --checksum --itemize-changes /srv/immich/library/ /tank/photos/ | head   # must print nothing
sudo rsync -aHAXn --checksum --itemize-changes /srv/vaultwarden/ /tank/vaultwarden/ | head
```

Edit `.env`: `IMMICH_UPLOAD_LOCATION=/tank/photos`, `VAULTWARDEN_DATA=/tank/vaultwarden`,
`MEDIA_LOCATION=/tank/media` → `sudo ./install.sh` → `tamago up`.
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
KERNEL_PKGS="linux-image-generic-hwe-24.04 linux-headers-generic-hwe-24.04 linux-generic-hwe-24.04"
sudo apt-mark unhold $KERNEL_PKGS
sudo apt update && sudo apt full-upgrade
sudo apt-mark hold $KERNEL_PKGS
sudo reboot
```

If something breaks (NVMe, ZFS, network): reboot, choose **Advanced options for Ubuntu** in GRUB and boot the
previous kernel. Ubuntu keeps it installed.
