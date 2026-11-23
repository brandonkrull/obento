#!/usr/bin/env bash
# Burn-in a NEW or RECERTIFIED hard drive before trusting it with data.
# DESTRUCTIVE: overwrites the whole drive. Run one instance per drive, in tmux, in parallel.
#
#   sudo tmux new -s burnin-a 'scripts/burnin.sh /dev/disk/by-id/ata-WDC_WUH721818ALE604_XXXX'
#
# Steps (~3 days for 18 TB):
#   1. Record baseline SMART attributes
#   2. SMART short self-test
#   3. badblocks: one full random-pattern write + read-back pass (~40 h at 18 TB)
#   4. SMART long self-test (~25-30 h at 18 TB)
#   5. Compare attributes: any growth in reallocated / pending / uncorrectable = FAIL (RMA it)
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_env

DEV="${1:-}"
[[ "$DEV" == /dev/disk/by-id/* ]] || die "Pass the drive as /dev/disk/by-id/ata-... (never /dev/sdX)."
[[ -b "$DEV" ]] || die "$DEV is not a block device."
REAL="$(readlink -f "$DEV")"
[[ "$REAL" == /dev/nvme* ]] && die "Refusing: $DEV is an NVMe (your boot SSD?)."
lsblk -no MOUNTPOINT "$REAL" | grep -q . && die "Refusing: $REAL has mounted partitions."
zpool status 2>/dev/null | grep -q "$(basename "$DEV")" && die "Refusing: $DEV is part of a ZFS pool."

SERIAL="$(smartctl -i "$DEV" | awk -F': *' '/Serial Number/{print $2}')"
MODEL="$(smartctl -i "$DEV" | awk -F': *' '/Device Model|Product/{print $2; exit}')"
LOGDIR=/var/log/homeserver; install -d "$LOGDIR"
LOG="$LOGDIR/burnin-$SERIAL.log"
exec > >(tee -a "$LOG") 2>&1

echo "Drive:  $MODEL  serial $SERIAL  ($REAL)"
smartctl -i "$DEV" | grep -E 'Capacity|Rotation|SATA Version' || true
echo
echo "THIS WILL ERASE EVERYTHING ON $DEV."
read -r -p "Type the serial number ($SERIAL) to continue: " ans
[[ "$ans" == "$SERIAL" ]] || die "Aborted."

attrs() { smartctl -A "$DEV" | awk '$1~/^(5|187|188|197|198|199)$/{print $1, $2, $10}'; }
wait_selftest() {
  sleep 120
  while smartctl -c "$DEV" | grep -q "Self-test routine in progress"; do
    smartctl -c "$DEV" | grep -A1 "Self-test execution" | tail -1
    sleep 1800
  done
  smartctl -l selftest "$DEV" | sed -n '1,8p'
}

log "Baseline attributes"; attrs | tee "$LOGDIR/burnin-$SERIAL.before"
notify low "Burn-in started" "$MODEL $SERIAL"

log "SMART short self-test"
smartctl -t short "$DEV" >/dev/null; wait_selftest

log "badblocks write+verify (random pattern, one pass). Started $(date)"
# -b 8192 is required: drives >16 TB overflow badblocks' 32-bit block count at 4096.
badblocks -wsv -b 8192 -c 64 -t random "$DEV" 2>&1 | tee "$LOGDIR/burnin-$SERIAL.badblocks"
BAD="$(grep -oE '[0-9]+ bad blocks found' "$LOGDIR/burnin-$SERIAL.badblocks" | tail -1 | awk '{print $1}')"
BAD="${BAD:-unknown}"
echo "badblocks finished $(date): $BAD bad blocks"

log "SMART long self-test (many hours)"
smartctl -t long "$DEV" >/dev/null; wait_selftest

log "After attributes"; attrs | tee "$LOGDIR/burnin-$SERIAL.after"

FAIL=0
[[ "$BAD" == "0" ]] || { warn "badblocks reported: $BAD"; FAIL=1; }
smartctl -l selftest "$DEV" | grep -m1 '^# *1 ' | grep -q "Completed without error" || { warn "Long self-test did not pass"; FAIL=1; }
while read -r id name raw; do
  before="$(awk -v id="$id" '$1==id{print $3}' "$LOGDIR/burnin-$SERIAL.before")"
  if [[ "$id" =~ ^(5|197|198)$ ]] && [[ "$raw" != "0" ]]; then
    warn "$name ($id) = $raw (must be 0)"; FAIL=1
  elif [[ "$raw" != "$before" ]]; then
    warn "$name ($id) changed $before -> $raw"; [[ "$id" == 199 ]] && warn "(199 = cable/backplane CRC errors: reseat cables, not a drive fault)"
  fi
done < "$LOGDIR/burnin-$SERIAL.after"

if [[ $FAIL -eq 0 ]]; then
  echo "PASS: $MODEL $SERIAL" | tee "$LOGDIR/burnin-$SERIAL.PASS"
  notify default "Burn-in PASSED" "$MODEL $SERIAL"
else
  echo "FAIL: $MODEL $SERIAL — contact ServerPartDeals for warranty replacement" | tee "$LOGDIR/burnin-$SERIAL.FAIL"
  notify urgent "Burn-in FAILED" "$MODEL $SERIAL — see $LOG"
  exit 1
fi
