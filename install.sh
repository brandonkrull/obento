#!/usr/bin/env bash
# One-command bootstrap for a fresh Ubuntu Server 24.04 LTS install.
# Safe to re-run. Does NOT touch the hard drives (see scripts/burnin.sh and scripts/create-pool.sh).
set -euo pipefail
source "$(dirname "$0")/scripts/lib.sh"
require_root

[[ -f "$REPO_DIR/.env" ]] || die "Copy .env.example to .env and fill it in first."
install -d -m 700 /etc/obento
install -m 600 "$REPO_DIR/.env" /etc/obento/.env
load_env

# install_conf <mode> <group> <src> <dest>: copy only when the content differs, so the file's
# modification time says when its settings last changed.
install_conf() {
  cmp -s "$3" "$4" || install -m "$1" -g "$2" "$3" "$4"
}

# restart_if_stale <unit> <config...>: 'systemctl enable --now' leaves a running service on its old
# settings, so restart it when any of its config files changed after it started.
restart_if_stale() {
  local unit="$1" started f; shift
  started="$(systemctl show "$unit" -p ActiveEnterTimestamp --value)"
  [[ -n "$started" ]] || return 0
  for f in "$@"; do
    if (( $(stat -c %Y "$f") > $(date -d "$started" +%s) )); then
      log "Restarting $unit (settings changed)"
      systemctl restart "$unit"
      return
    fi
  done
}

# apt-get that waits (up to ~15 minutes) for the automatic updates instead of failing on apt's lock.
apt-get() {
  local i
  for i in {1..60}; do
    pgrep -x apt.systemd.dai >/dev/null || break
    (( i > 1 )) || log "Waiting for automatic updates to finish"
    sleep 10
  done
  command apt-get -o DPkg::Lock::Timeout=300 "$@"
}

# The timers (backup 03:30, health report Monday 08:00, ...) follow the server's clock; TZ alone only reaches the apps.
if [[ -n "${TZ:-}" && -f "/usr/share/zoneinfo/$TZ" ]]; then
  timedatectl set-timezone "$TZ"
else
  warn "TZ '${TZ:-}' in .env isn't a known time zone; the server clock stays on $(timedatectl show -p Timezone --value)."
fi

log "Base packages"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  zfsutils-linux smartmontools sanoid restic nut-client nut-server \
  curl jq unattended-upgrades ufw lm-sensors e2fsprogs python3 ca-certificates \
  libnss-resolve neovim rclone
# Installing libnss-resolve restarts systemd-resolved; wait for DNS before downloading anything else.
for _ in {1..30}; do getent hosts download.docker.com >/dev/null && break; sleep 1; done

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
install -m 644 "$REPO_DIR/config/sshd-hardening.conf" /etc/ssh/sshd_config.d/10-obento.conf
if ls /home/*/.ssh/authorized_keys >/dev/null 2>&1; then
  systemctl reload ssh
else
  warn "No authorized_keys found; password SSH left enabled until you add a key, then re-run."
  rm -f /etc/ssh/sshd_config.d/10-obento.conf
fi

log "Firewall (LAN + tailnet only)"
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
ufw allow from 192.168.0.0/16
ufw allow from 10.0.0.0/8
ufw --force enable

log "Updates automatic (Ubuntu, Docker, Tailscale, Node.js); kernel updates held (lesson: kernel regressions)"
install -m 644 "$REPO_DIR/config/52obento-unattended" /etc/apt/apt.conf.d/52obento-unattended
apt-mark hold linux-image-generic linux-headers-generic linux-generic \
  linux-image-generic-hwe-24.04 linux-headers-generic-hwe-24.04 linux-generic-hwe-24.04 >/dev/null 2>&1 || true

log "Docker: keep apps running through Docker upgrades, cap container log size"
install -d /etc/docker
install_conf 644 root "$REPO_DIR/config/docker-daemon.json" /etc/docker/daemon.json
# Restarts the apps once, the first time; after that live-restore keeps them running.
restart_if_stale docker /etc/docker/daemon.json

log "Install repo to /opt/obento (systemd units run scripts from here)"
install -d /opt/obento
cp -a "$REPO_DIR/scripts" "$REPO_DIR/config" "$REPO_DIR/compose" "$REPO_DIR/docs" /opt/obento/
# Root runs these from systemd, so only root may change them (cp -a keeps the repo owner).
chown -R root:root /opt/obento
chmod 755 /opt/obento/scripts/*
ln -sf /opt/obento/scripts/notify /usr/local/bin/obento-notify
ln -sf /opt/obento/scripts/obento /usr/local/bin/obento

log "Drive health monitoring (smartd)"
install_conf 644 root "$REPO_DIR/config/smartd.conf" /etc/smartd.conf
systemctl enable --now smartmontools
# A restart sends one test alert per drive (-M test), so it only happens when the settings change.
restart_if_stale smartmontools /etc/smartd.conf

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

log "UPS over USB (config/nut) -> clean shutdown on low battery"
for f in ups.conf nut.conf upsd.users upsmon.conf; do
  install_conf 640 nut "$REPO_DIR/config/nut/$f" "/etc/nut/$f"
done
if systemctl enable --now nut-server nut-monitor 2>/dev/null; then
  restart_if_stale nut-server /etc/nut/ups.conf /etc/nut/nut.conf /etc/nut/upsd.users
  restart_if_stale nut-monitor /etc/nut/nut.conf /etc/nut/upsmon.conf
else
  warn "NUT will start once the UPS USB cable is connected."
fi

log "Timers: backup, capacity check, scrub, drive health report, weekly cleanup"
for u in "$REPO_DIR"/config/systemd/*; do install -m 644 "$u" /etc/systemd/system/; done
systemctl daemon-reload
systemctl enable --now obento-capacity.timer obento-scrub.timer obento-health.timer \
  obento-maintenance.timer
# Backup timer is enabled by scripts/backup.sh --init once B2 is configured.
# Ubuntu's built-in monthly scrub cron is replaced by our timer (which also alerts):
[[ -f /etc/cron.d/zfsutils-linux ]] && sed -i 's/^\([^#].*zfs.*scrub.*\)$/# \1  # replaced by obento-scrub.timer/' /etc/cron.d/zfsutils-linux

log "Free port 53 for AdGuard (disable systemd-resolved stub listener)"
install -d /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListener=no\nDNS=1.1.1.1 9.9.9.9\n' > /etc/systemd/resolved.conf.d/adguard.conf
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
# libnss-resolve keeps name lookups going through systemd-resolved without the stub, so Tailscale
# names (e.g. spark-e2ca) still resolve.
systemctl restart systemd-resolved
for _ in {1..30}; do getent hosts deb.nodesource.com >/dev/null && break; sleep 1; done

log "Directories on the SSD"
install -d -m 755 "$SSD_DATA"/{immich,vaultwarden,adguard,jellyfin,scrutiny,media}
ln -sf /etc/obento/.env /opt/obento/compose/.env
install -d -m 755 "$IMMICH_UPLOAD_LOCATION" "$IMMICH_DB_LOCATION"
# Media folders belong to whoever runs install.sh, so files can be copied in without sudo (Jellyfin only reads).
MEDIA_DIR="${MEDIA_LOCATION:-$SSD_DATA/media}"
MEDIA_USER="${SUDO_USER:-root}"
install -d -m 755 "$MEDIA_DIR"
install -d -m 755 -o "$MEDIA_USER" -g "$(id -gn "$MEDIA_USER")" "$MEDIA_DIR"/{Movies,Shows,Music}
# OpenCloud runs as 1000:1000 (see compose); its config holds generated secrets.
install -d -m 700 -o 1000 -g 1000 "$SSD_DATA/opencloud" "$SSD_DATA/opencloud/config" "${OPENCLOUD_DATA:-$SSD_DATA/opencloud/data}"
case "${OPENCLOUD_ADMIN_PASSWORD:-}" in
  ""|change-me*) warn "Set OPENCLOUD_ADMIN_PASSWORD in .env before OpenCloud's first start." ;;
esac

log "Scrutiny alerts (-> ntfy)"
SCRUTINY_CONF="$SSD_DATA/scrutiny/config/scrutiny.yaml"
SCRUTINY_MARK="# Written by obento install.sh from NTFY_* in .env; edits are overwritten."
install -d -m 755 "$SSD_DATA/scrutiny/config"
if [[ -f "$SCRUTINY_CONF" ]] && ! head -1 "$SCRUTINY_CONF" | grep -qxF "$SCRUTINY_MARK"; then
  warn "Kept your own $SCRUTINY_CONF; add an ntfy URL under notify.urls yourself."
else
  tmp="$(mktemp)"
  # Shoutrrr ntfy URL: host and topic, HTTPS by default. A token goes in as the password with an empty
  # username (ntfy accepts that); email= also emails it (see NTFY_EMAIL).
  auth_opt="" email_opt=""
  [[ -n "${NTFY_TOKEN:-}" ]] && auth_opt=":${NTFY_TOKEN}@"
  [[ -n "${NTFY_EMAIL:-}" ]] && email_opt="&email=${NTFY_EMAIL//@/%40}"
  printf '%s\nnotify:\n  urls:\n    - "ntfy://%s%s/%s?title=%s%s"\n' \
    "$SCRUTINY_MARK" "$auth_opt" "$(sed -E 's#^https?://##; s#/+$##' <<<"$NTFY_URL")" "$NTFY_TOPIC" \
    "Scrutiny%20on%20$(hostname)" "$email_opt" > "$tmp"
  if ! cmp -s "$tmp" "$SCRUTINY_CONF"; then
    install -m 600 "$tmp" "$SCRUTINY_CONF"
    # Scrutiny reads its config at start; restart it if it's already running.
    if docker ps --format '{{.Names}}' | grep -qx scrutiny; then
      docker restart scrutiny >/dev/null
      log "Restarted scrutiny"
    fi
  fi
  rm -f "$tmp"
fi

log "Snapshots config (applies once the pool exists)"
install -m 644 "$REPO_DIR/config/sanoid.conf" /etc/sanoid/sanoid.conf 2>/dev/null || {
  install -d /etc/sanoid; install -m 644 "$REPO_DIR/config/sanoid.conf" /etc/sanoid/sanoid.conf; }
systemctl enable --now sanoid.timer 2>/dev/null || true

log "pi coding agent (uses qwen36-moe on spark-e2ca over Tailscale)"
# pi needs Node >= 22.19; Ubuntu 24.04 ships 18, so use NodeSource's 22.x repo.
if ! node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a==22&&b>=19)?0:1)' 2>/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update
  apt-get install -y nodejs
fi
PI_VERSION=1.0.0
[[ "$(pi --version 2>/dev/null)" == "$PI_VERSION" ]] || npm install -g "@earendil-works/pi-coding-agent@$PI_VERSION"
PI_USER="${SUDO_USER:-}"
if [[ -z "$PI_USER" || "$PI_USER" == root ]]; then
  warn "pi config not installed: run install.sh with sudo from your own account."
else
  PI_DIR="$(getent passwd "$PI_USER" | cut -d: -f6)/.pi/agent"
  install -d -m 700 -o "$PI_USER" -g "$(id -gn "$PI_USER")" "$(dirname "$PI_DIR")" "$PI_DIR"
  for f in models.json settings.json; do
    if [[ -f "$PI_DIR/$f" ]] && ! cmp -s "$REPO_DIR/config/pi/$f" "$PI_DIR/$f"; then
      warn "Kept your existing $PI_DIR/$f (differs from config/pi/$f)."
      continue
    fi
    install -m 600 -o "$PI_USER" -g "$(id -gn "$PI_USER")" "$REPO_DIR/config/pi/$f" "$PI_DIR/$f"
  done
fi

log "HTTPS for the apps inside your tailnet (Tailscale serve)"
# https port : local app port. Vaultwarden needs HTTPS; the others are nicer with it.
SERVE_PORTS=(443:2283 8443:8222 8920:8096 9200:9201)   # Immich, Vaultwarden, Jellyfin, OpenCloud
TS_DOMAIN="$(tailscale status --json 2>/dev/null | jq -r '.CertDomains[0] // empty' || true)"
if ! tailscale status >/dev/null 2>&1; then
  warn "HTTPS not set up: run 'sudo tailscale up --ssh', then re-run install.sh."
elif [[ -z "$TS_DOMAIN" ]]; then
  warn "HTTPS not set up: turn on HTTPS Certificates in the Tailscale admin console (DNS page), then re-run install.sh."
else
  for m in "${SERVE_PORTS[@]}"; do
    timeout 60 tailscale serve --bg --yes --https="${m%%:*}" "http://localhost:${m##*:}" >/dev/null \
      || warn "Couldn't set up https://$TS_DOMAIN:${m%%:*} (tailscale serve failed)."
  done
  log "Immich https://$TS_DOMAIN  Vaultwarden https://$TS_DOMAIN:8443  Jellyfin https://$TS_DOMAIN:8920"
  log "OpenCloud https://$TS_DOMAIN:9200"
  # OpenCloud needs its public address, and must resolve it itself to check sign-ins (see compose).
  TS_IP="$(tailscale ip -4 | head -1)"
  # App tokens let tools such as rclone sign in without the browser (Google Drive import, RUNBOOK step 8).
  APP_TOKEN_ENV=""
  [[ "${OPENCLOUD_APP_TOKENS:-}" == true ]] && APP_TOKEN_ENV=$'\n      OC_ADD_RUN_SERVICES: auth-app\n      PROXY_ENABLE_APP_AUTH: "true"'
  cat > /opt/obento/compose/docker-compose.override.yml <<EOF
# Written by install.sh from this machine's Tailscale name and IP; don't edit.
services:
  opencloud:
    environment:
      OC_URL: https://$TS_DOMAIN:9200$APP_TOKEN_ENV
    extra_hosts:
      - "$TS_DOMAIN:$TS_IP"
EOF
  rm -f /etc/obento/opencloud.env
fi

obento-notify default "Bootstrap complete" "install.sh finished on $(hostname)"
log "Done. Next: 'obento up' to start the apps (see docs/RUNBOOK.md)."
