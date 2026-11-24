#!/usr/bin/env bash
# Weekly cleanup: remove image layers left behind by 'tamago update' and old build cache, and say when
# automatic updates are waiting for a reboot. Never touches volumes, containers or images in use.
source "$(dirname "$(readlink -f "$0")")/lib.sh"
load_env

before="$(df --output=avail -B1 /var/lib/docker | tail -1)"
if ! out="$(docker image prune -f 2>&1 && docker builder prune -f --filter until=168h 2>&1)"; then
  notify high "Docker cleanup failed" "$out"
  exit 1
fi
after="$(df --output=avail -B1 /var/lib/docker | tail -1)"
logger -t homeserver-maintenance "docker prune freed $(numfmt --to=iec $(( after > before ? after - before : 0 )))"

if [[ -f /var/run/reboot-required ]]; then
  pkgs="$(sort -u /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')"
  notify default "Reboot needed" "Automatic updates are waiting for a reboot (${pkgs:-see /var/run/reboot-required}). Run 'sudo reboot' when nobody is using the server."
fi
exit 0
