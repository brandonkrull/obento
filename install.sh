#!/usr/bin/env bash
# One-command bootstrap for a fresh Ubuntu Server 24.04 LTS install.
# Safe to re-run. Does NOT touch the hard drives (see scripts/burnin.sh and scripts/create-pool.sh).
set -euo pipefail
source "$(dirname "$0")/scripts/lib.sh"
require_root

[[ -f "$REPO_DIR/.env" ]] || die "Copy .env.example to .env and fill it in first."
install -d -m 700 /etc/homeserver
install -m 600 "$REPO_DIR/.env" /etc/homeserver/.env
load_env

log "Base packages"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  zfsutils-linux smartmontools sanoid restic nut-client nut-server \
  curl jq unattended-upgrades ufw lm-sensors e2fsprogs python3 ca-certificates

log "Docker (official repo)"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

log "Tailscale"
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
tailscale status >/dev/null 2>&1 || warn "Run 'sudo tailscale up --ssh' to join your tailnet."

log "SSH hardening (keys only)"
install -m 644 "$REPO_DIR/config/sshd-hardening.conf" /etc/ssh/sshd_config.d/10-homeserver.conf
if ls /home/*/.ssh/authorized_keys >/dev/null 2>&1; then
  systemctl reload ssh
else
  warn "No authorized_keys found; password SSH left enabled until you add a key, then re-run."
  rm -f /etc/ssh/sshd_config.d/10-homeserver.conf
fi

log "Firewall (LAN + tailnet only)"
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
ufw allow from 192.168.0.0/16
ufw allow from 10.0.0.0/8
ufw --force enable

log "Security updates automatic; kernel updates held (lesson: kernel regressions)"
install -m 644 "$REPO_DIR/config/52homeserver-unattended" /etc/apt/apt.conf.d/52homeserver-unattended
apt-mark hold linux-image-generic linux-headers-generic linux-generic >/dev/null 2>&1 || true

log "Install repo to /opt/homeserver (systemd units run scripts from here)"
install -d /opt/homeserver
cp -a "$REPO_DIR/scripts" "$REPO_DIR/config" "$REPO_DIR/compose" "$REPO_DIR/docs" /opt/homeserver/
chmod 755 /opt/homeserver/scripts/*
ln -sf /opt/homeserver/scripts/notify /usr/local/bin/homeserver-notify

log "Drive health monitoring (smartd)"
install -m 644 "$REPO_DIR/config/smartd.conf" /etc/smartd.conf
systemctl enable --now smartmontools 2>/dev/null || systemctl enable --now smartd

log "ZFS event alerts (ZED -> ntfy)"
ZEDRC=/etc/zfs/zed.d/zed.rc
if [[ -f $ZEDRC ]]; then
  sed -i '/^ZED_NTFY_/d;/^ZED_NOTIFY_VERBOSE/d' "$ZEDRC"
  {
    echo "ZED_NTFY_TOPIC=\"$NTFY_TOPIC\""
    echo "ZED_NTFY_URL=\"$NTFY_URL\""
    [[ -n "${NTFY_TOKEN:-}" ]] && echo "ZED_NTFY_ACCESS_TOKEN=\"$NTFY_TOKEN\""
    echo "ZED_NOTIFY_VERBOSE=1"
  } >> "$ZEDRC"
  systemctl restart zfs-zed
fi

log "UPS (APC BE600M1 over USB) -> clean shutdown on low battery"
install -m 640 -g nut "$REPO_DIR/config/nut/ups.conf"   /etc/nut/ups.conf
install -m 640 -g nut "$REPO_DIR/config/nut/nut.conf"   /etc/nut/nut.conf
install -m 640 -g nut "$REPO_DIR/config/nut/upsd.users" /etc/nut/upsd.users
install -m 640 -g nut "$REPO_DIR/config/nut/upsmon.conf" /etc/nut/upsmon.conf
systemctl enable --now nut-server nut-monitor 2>/dev/null || warn "NUT will start once the UPS USB cable is connected."

log "Timers: backup, capacity check, scrub, drive health report"
for u in "$REPO_DIR"/config/systemd/*; do install -m 644 "$u" /etc/systemd/system/; done
systemctl daemon-reload
systemctl enable --now homeserver-capacity.timer homeserver-scrub.timer homeserver-health.timer
# Backup timer is enabled by scripts/backup.sh --init once B2 is configured.
# Ubuntu's built-in monthly scrub cron is replaced by our timer (which also alerts):
[[ -f /etc/cron.d/zfsutils-linux ]] && sed -i 's/^\([^#].*zfs.*scrub.*\)$/# \1  # replaced by homeserver-scrub.timer/' /etc/cron.d/zfsutils-linux

log "Free port 53 for AdGuard (disable systemd-resolved stub listener)"
install -d /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListener=no\nDNS=1.1.1.1 9.9.9.9\n' > /etc/systemd/resolved.conf.d/adguard.conf
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
systemctl restart systemd-resolved

log "Directories on the SSD"
install -d -m 755 "$SSD_DATA"/{immich,vaultwarden,adguard,jellyfin,scrutiny,media}
ln -sf /etc/homeserver/.env /opt/homeserver/compose/.env
install -d -m 755 "$IMMICH_UPLOAD_LOCATION" "$IMMICH_DB_LOCATION"

log "Snapshots config (applies once the pool exists)"
install -m 644 "$REPO_DIR/config/sanoid.conf" /etc/sanoid/sanoid.conf 2>/dev/null || {
  install -d /etc/sanoid; install -m 644 "$REPO_DIR/config/sanoid.conf" /etc/sanoid/sanoid.conf; }
systemctl enable --now sanoid.timer 2>/dev/null || true

homeserver-notify default "Bootstrap complete" "install.sh finished on $(hostname)"
log "Done. Next: 'cd compose && docker compose up -d' (see docs/RUNBOOK.md)."
