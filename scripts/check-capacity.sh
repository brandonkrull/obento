#!/usr/bin/env bash
# Warn when the pool passes POOL_WARN_PCT (default 80%) or isn't ONLINE. Runs hourly via timer.
source "$(dirname "$(readlink -f "$0")")/lib.sh"
load_env
zpool list "$POOL_NAME" >/dev/null 2>&1 || exit 0   # pool not created yet
cap="$(zpool list -Ho capacity "$POOL_NAME" | tr -d '%')"
health="$(zpool list -Ho health "$POOL_NAME")"
[[ "$health" == "ONLINE" ]] || notify urgent "Pool $health" "$(zpool status -x "$POOL_NAME")"
if (( cap >= ${POOL_WARN_PCT:-80} )); then
  notify high "Pool ${cap}% full" "Free space or add a mirror pair. ZFS slows down and risks fragmentation past ~85%."
fi
# SSD (boot/OS/Immich DB)
ssd="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
(( ssd >= 85 )) && notify high "SSD ${ssd}% full" "Root filesystem is filling up."
exit 0
