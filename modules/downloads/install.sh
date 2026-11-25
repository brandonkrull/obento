# shellcheck shell=bash
# Module downloads: run by install.sh (helpers from install.sh and scripts/lib.sh; MODULE_DIR is this folder).
log "Download apps: after 'obento up', 'sudo obento setup downloads' connects them (RUNBOOK)"
# Seerr, Sonarr, Radarr, Prowlarr, SABnzbd and Bazarr run as 1000:1000 (see compose.yml).
install -d -m 755 -o 1000 -g 1000 "$SSD_DATA"/{sabnzbd,prowlarr,sonarr,radarr,seerr,bazarr,downloads} \
  "$SSD_DATA/downloads/incomplete" "$MEDIA_DIR/Downloads"
# SABnzbd refuses requests for names it doesn't know (its own container name is how Sonarr and Radarr
# reach it), and from addresses it doesn't consider local: through Traefik it sees the visitor's Tailscale
# address (100.64.0.0/10), so that range is added to the usual private ones. Seeded before its first start;
# after that they're in SABnzbd's settings (Config > Special).
if [[ ! -f "$SSD_DATA/sabnzbd/sabnzbd.ini" ]]; then
  printf '[misc]\nhost_whitelist = sabnzbd, %s.%s\nlocal_ranges = %s\n' "$(host_name downloads)" "$APPS_DOMAIN" \
    "127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, ::1" > "$SSD_DATA/sabnzbd/sabnzbd.ini"
  chown 1000:1000 "$SSD_DATA/sabnzbd/sabnzbd.ini"
  chmod 600 "$SSD_DATA/sabnzbd/sabnzbd.ini"
fi
