#!/usr/bin/env bash
# Nightly off-site backup to Backblaze B2 with restic.
#   sudo scripts/backup.sh --init     # first time: create the repo + enable the nightly timer
#   sudo scripts/backup.sh            # run a backup now
#   sudo scripts/backup.sh --verify   # deep check: read 5% of the repo's data back from B2
#
# What gets backed up: Immich originals + a fresh Postgres dump, Vaultwarden, OpenCloud, the repo config.
# Thumbnails/transcodes are skipped (Immich regenerates them).
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_env
export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

DUMP_DIR="${SSD_DATA}/immich/db-dumps"
if zfs list "$POOL_NAME/backups" >/dev/null 2>&1; then DUMP_DIR="/$POOL_NAME/backups/immich-db"; fi
install -d -m 700 "$DUMP_DIR"

trap 'notify urgent "Backup FAILED" "restic backup failed at line $LINENO — journalctl -u obento-backup"' ERR

case "${1:-}" in
  --init)
    restic snapshots >/dev/null 2>&1 || restic init
    systemctl enable --now obento-backup.timer obento-verify.timer
    log "Repository ready and nightly timer enabled."
    warn "Store RESTIC_PASSWORD in Vaultwarden AND on paper. Without it the backup is unreadable."
    exit 0 ;;
  --verify)
    restic check --read-data-subset=5%
    notify low "Backup verify OK" "Read back 5% of B2 data successfully"
    exit 0 ;;
esac

log "Dumping Immich database"
docker exec immich_postgres pg_dumpall --clean --if-exists --username=postgres \
  | gzip > "$DUMP_DIR/immich-$(date +%F).sql.gz"
find "$DUMP_DIR" -name 'immich-*.sql.gz' -mtime +14 -delete

PATHS=("$IMMICH_UPLOAD_LOCATION/library" "$IMMICH_UPLOAD_LOCATION/upload" "$IMMICH_UPLOAD_LOCATION/profile"
       "$DUMP_DIR" /etc/obento /opt/obento)
for p in "$SSD_DATA/vaultwarden" "/$POOL_NAME/vaultwarden" "$SSD_DATA/opencloud/config" "${OPENCLOUD_DATA:-}"; do
  [[ -n "$p" && -d "$p" ]] && PATHS+=("$p")
done
EXISTING=(); for p in "${PATHS[@]}"; do [[ -e "$p" ]] && EXISTING+=("$p"); done

log "restic backup"
restic backup --one-file-system=false --exclude-caches --tag nightly "${EXISTING[@]}"
restic forget --tag nightly --keep-daily 14 --keep-weekly 8 --keep-monthly 24 --prune
# Light integrity check every night; deep read-back check monthly via --verify.
restic check

summary="$(restic snapshots --latest 1 --compact | tail -3 | head -1)"
notify low "Backup OK" "$summary"
