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
source "$REPO_DIR/scripts/modules.sh"
modules_check
[[ -n "${MODULES+set}" ]] || warn "MODULES isn't in .env; using the settings from before modules: $(modules_on | tr '\n' ' ')(see .env.example)."
log "Modules: $(modules_on | tr '\n' ' ')"

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
  zfsutils-linux smartmontools sanoid restic \
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

log "Updates automatic (Ubuntu, Docker, Tailscale, Node.js for pi); kernel updates held (lesson: kernel regressions)"
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
# Start clean, so files removed or moved in the repo don't linger here (compose/ keeps .env and the override).
rm -rf /opt/obento/scripts /opt/obento/config /opt/obento/docs /opt/obento/modules
cp -a "$REPO_DIR/scripts" "$REPO_DIR/config" "$REPO_DIR/compose" "$REPO_DIR/docs" "$REPO_DIR/modules" /opt/obento/
# Root runs these from systemd, so only root may change them (cp -a keeps the repo owner).
chown -R root:root /opt/obento
chmod 755 /opt/obento/scripts/* /opt/obento/modules/*/*.sh /opt/obento/modules/*/*.py 2>/dev/null || true
# 'obento update' pulls and re-installs from here.
printf '%s\n' "$REPO_DIR" > /opt/obento/repo-path
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

log "Timers: backup, capacity check, scrub, drive health report, weekly cleanup"
for u in "$REPO_DIR"/config/systemd/*; do install -m 644 "$u" /etc/systemd/system/; done
systemctl daemon-reload
systemctl enable --now obento-capacity.timer obento-scrub.timer obento-health.timer \
  obento-maintenance.timer
# Backup timer is enabled by scripts/backup.sh --init once B2 is configured.
# Stops the apps cleanly at shutdown (live-restore would leave them to be killed). Only ever enabled
# here, never restarted: stopping it stops every app.
systemctl enable --now obento-apps-stop.service
# Ubuntu's built-in monthly scrub cron is replaced by our timer (which also alerts):
[[ -f /etc/cron.d/zfsutils-linux ]] && sed -i 's/^\([^#].*zfs.*scrub.*\)$/# \1  # replaced by obento-scrub.timer/' /etc/cron.d/zfsutils-linux

log "Free port 53 for AdGuard (disable systemd-resolved stub listener)"
install -d /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListener=no\nDNS=1.1.1.1 9.9.9.9\n' > /etc/systemd/resolved.conf.d/adguard.conf
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
# libnss-resolve keeps name lookups going through systemd-resolved without the stub, so the names of other
# machines on the tailnet still resolve.
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

log "Modules"
for m in $(modules_on); do
  [[ -f "$REPO_DIR/modules/$m/install.sh" ]] || continue
  # shellcheck disable=SC2034  # used by the module's install.sh
  MODULE_DIR="/opt/obento/modules/$m"
  # shellcheck disable=SC1090
  source "$REPO_DIR/modules/$m/install.sh"
done

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

log "Web addresses for the apps (Tailscale serve, or Traefik with the domain module)"
TS_DOMAIN="$(tailscale status --json 2>/dev/null | jq -r '.CertDomains[0] // empty' || true)"
# Every port any module ever publishes through Tailscale serve; the ones not wanted now are turned off.
ALL_SERVE="$(for m in "$REPO_DIR"/modules/*/; do module_conf "$(basename "$m")" SERVE; printf ' '; done)"
if module_on domain; then
  # Traefik answers every app on 443 (routes from each module's HOSTS), so Tailscale serves nothing.
  read -ra SERVE_PORTS <<<""
  OC_URL="https://$(host_name files).$APPS_DOMAIN" OC_HOST="$(host_name files).$APPS_DOMAIN" OC_IP=127.0.0.1
  VW_URL="https://$(host_name passwords).$APPS_DOMAIN"
else
  [[ -z "${APPS_DOMAIN:-}" ]] || warn "APPS_DOMAIN is set but the domain module is off: add domain to MODULES to use it."
  # https port : local app port, from each module's SERVE.
  read -ra SERVE_PORTS <<<"$(serve_ports)"
  OC_URL="https://$TS_DOMAIN:9200" OC_HOST="$TS_DOMAIN" OC_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  VW_URL=""
fi
SERVE_OFF=()
for m in $ALL_SERVE; do
  [[ " ${SERVE_PORTS[*]} " == *" $m "* ]] || SERVE_OFF+=("${m%%:*}")
done

if ! tailscale status >/dev/null 2>&1; then
  warn "Tailscale addresses not set up: run 'sudo tailscale up --ssh', then re-run install.sh."
elif [[ -z "$TS_DOMAIN" ]]; then
  warn "Tailscale addresses not set up: turn on HTTPS Certificates in the Tailscale admin console (DNS page), then re-run install.sh."
else
  for port in "${SERVE_OFF[@]}"; do
    url="https://$TS_DOMAIN"; [[ $port == 443 ]] || url+=":$port"
    if tailscale serve status 2>/dev/null | grep -qxF "$url (tailnet only)"; then
      timeout 60 tailscale serve --https="$port" off >/dev/null || warn "Couldn't stop $url (tailscale serve)."
    fi
  done
  for m in "${SERVE_PORTS[@]}"; do
    timeout 60 tailscale serve --bg --yes --https="${m%%:*}" "http://localhost:${m##*:}" >/dev/null \
      || warn "Couldn't set up https://$TS_DOMAIN:${m%%:*} (tailscale serve failed)."
  done
fi

if module_on domain; then
  while read -r name app _port _m; do
    if [[ $name == @ ]]; then log "  $app https://$APPS_DOMAIN"; else log "  $app https://$name.$APPS_DOMAIN"; fi
  done < <(hosts_table)
elif [[ -n "$TS_DOMAIN" ]]; then
  log "Immich https://$TS_DOMAIN  Vaultwarden https://$TS_DOMAIN:8443  Jellyfin https://$TS_DOMAIN:8920"
  module_on opencloud && log "OpenCloud $OC_URL"
fi

if module_on domain || [[ -n "$TS_DOMAIN" ]]; then
  # OpenCloud needs its public address, and must reach it itself to check sign-ins (see compose).
  # App tokens let tools such as rclone sign in without the browser (Google Drive import, RUNBOOK step 8).
  APP_TOKEN_ENV=""
  [[ "${OPENCLOUD_APP_TOKENS:-}" == true ]] && APP_TOKEN_ENV=$'\n      OC_ADD_RUN_SERVICES: auth-app\n      PROXY_ENABLE_APP_AUTH: "true"'
  VW_ENV=""
  [[ -n "$VW_URL" ]] && VW_ENV=$'\n  vaultwarden:\n    environment:\n      DOMAIN: '"$VW_URL"
  OC_ENV=""
  module_on opencloud && OC_ENV=$'\n  opencloud:\n    environment:\n      OC_URL: '"$OC_URL$APP_TOKEN_ENV"$'\n    extra_hosts:\n      - "'"$OC_HOST:$OC_IP"'"'
  [[ -n "$OC_ENV$VW_ENV" ]] || OC_ENV=" {}"
  cat > /opt/obento/compose/docker-compose.override.yml <<EOF
# Written by install.sh from APPS_DOMAIN or this machine's Tailscale name; don't edit.
services:$OC_ENV$VW_ENV
EOF
  # OpenCloud writes its web sign-in addresses once; when OC_URL changes, remove them so it writes new ones.
  IDP_CLIENTS="${OPENCLOUD_DATA:-/srv/opencloud/data}/idp/tmp/identifier-registration.yaml"
  if module_on opencloud && [[ -f "$IDP_CLIENTS" ]] && ! grep -qF -- "- $OC_URL/" "$IDP_CLIENTS"; then
    log "OpenCloud address changed to $OC_URL: everyone signs in to OpenCloud again once"
    rm -f "$IDP_CLIENTS"
  fi
  rm -f /etc/obento/opencloud.env
fi

# The compose files obento uses: the core apps, each module's, then the override above.
{
  compose_files /opt/obento/compose | sed "s#^$REPO_DIR/modules#/opt/obento/modules#"
  [[ -f /opt/obento/compose/docker-compose.override.yml ]] && echo /opt/obento/compose/docker-compose.override.yml
} > /opt/obento/compose/files
modules_on > /opt/obento/modules.on

obento-notify default "Bootstrap complete" "install.sh finished on $(hostname)"
log "Done. Next: 'obento up' to start the apps (see docs/RUNBOOK.md)."
