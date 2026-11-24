#!/usr/bin/env bash
# Create the mirrored ZFS pool from two burned-in drives.
#   sudo scripts/create-pool.sh /dev/disk/by-id/ata-...A /dev/disk/by-id/ata-...B
#
# Layout decisions (see docs/DRIVE-PLAN.md):
#  - 2-way mirror now. Grow later by adding more mirror pairs (zpool add tank mirror X Y),
#    or at ~6 drives build a RAIDZ2 pool and migrate. You cannot convert mirror -> RAIDZ2 in place.
#  - No quotas/reservations: they block snapshots (lesson from the article). Capacity alerts at 80%.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_env

A="${1:-}"; B="${2:-}"
[[ "$A" == /dev/disk/by-id/* && "$B" == /dev/disk/by-id/* ]] || die "Usage: $0 /dev/disk/by-id/A /dev/disk/by-id/B"
zpool list "$POOL_NAME" >/dev/null 2>&1 && die "Pool $POOL_NAME already exists."

for d in "$A" "$B"; do
  s="$(smartctl -i "$d" | awk -F': *' '/Serial Number/{print $2}')"
  [[ -f "/var/log/obento/burnin-$s.PASS" ]] || die "No burn-in PASS for $d ($s). Run scripts/burnin.sh first."
  smartctl -H "$d" | grep -q PASSED || die "SMART health not PASSED for $d"
done

log "Creating mirror pool '$POOL_NAME'"
zpool create -f \
  -o ashift=12 -o autoexpand=on \
  -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl \
  -O mountpoint="/$POOL_NAME" \
  "$POOL_NAME" mirror "$A" "$B"

log "Datasets"
zfs create -o recordsize=1M "$POOL_NAME/photos"      # Immich library (originals + thumbs)
zfs create                  "$POOL_NAME/vaultwarden"
zfs create                  "$POOL_NAME/opencloud"   # OpenCloud files (Drive replacement)
zfs create                  "$POOL_NAME/backups"     # DB dumps, laptop backups
zfs create -o recordsize=1M "$POOL_NAME/media"       # Jellyfin

zpool status "$POOL_NAME"
zfs list -r "$POOL_NAME"
notify default "Pool created" "$POOL_NAME mirror online: $(zpool list -Ho size "$POOL_NAME")"
log "Next: docs/RUNBOOK.md -> 'Move Immich onto the pool'."
