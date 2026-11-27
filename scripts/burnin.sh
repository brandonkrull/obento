#!/usr/bin/env bash
# Burn-in a NEW or RECERTIFIED hard drive before trusting it with data.
# DESTRUCTIVE: overwrites the whole drive. Run one instance per drive, in tmux, in parallel.
#
#   sudo tmux new -s burnin-a 'scripts/burnin.sh /dev/disk/by-id/ata-WDC_WUH721818ALE604_XXXX'
#   sudo tmux new -s burnin-a 'scripts/burnin.sh --resume /dev/disk/by-id/ata-WDC_WUH721818ALE604_XXXX'
#
# Steps (~3 days for 18 TB):
#   1. Record baseline SMART attributes
#   2. SMART short self-test
#   3. badblocks: one full random-pattern write + read-back pass (~40 h at 18 TB)
#   4. SMART long self-test (~25-30 h at 18 TB)
#   5. Compare attributes: any growth in reallocated / pending / uncorrectable = FAIL (RMA it)
#
# --resume continues a burn-in that stopped after badblocks finished (reboot, power cut, a failed step): it
# keeps the baseline and the badblocks result and runs steps 4-5. It never writes to the drive, so it doesn't
# ask for the serial number.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"
require_root
load_env

RESUME=0
[[ "${1:-}" == --resume ]] && { RESUME=1; shift; }
DEV="${1:-}"
[[ "$DEV" == /dev/disk/by-id/* ]] || die "Pass the drive as /dev/disk/by-id/ata-... (never /dev/sdX)."
[[ -b "$DEV" ]] || die "$DEV is not a block device."
REAL="$(readlink -f "$DEV")"
[[ "$REAL" == /dev/nvme* ]] && die "Refusing: $DEV is an NVMe (your boot SSD?)."
lsblk -no MOUNTPOINT "$REAL" | grep -q . && die "Refusing: $REAL has mounted partitions."
zpool status 2>/dev/null | grep -q "$(basename "$DEV")" && die "Refusing: $DEV is part of a ZFS pool."

# smartctl's exit status is a bit mask that is also nonzero for things that don't matter here (old entries
# in the drive's error log, for example). Under set -e and pipefail that would stop the script, so read its
# output and judge that instead.
smart() { smartctl "$@" 2>&1 || true; }

SERIAL="$(smart -i "$DEV" | awk -F': *' '/Serial Number/{print $2}')"
MODEL="$(smart -i "$DEV" | awk -F': *' '/Device Model|Product/{print $2; exit}')"
[[ -n "$SERIAL" ]] || die "Couldn't read the serial number of $DEV."
LOGDIR=/var/log/obento; install -d "$LOGDIR"
LOG="$LOGDIR/burnin-$SERIAL.log"
BEFORE="$LOGDIR/burnin-$SERIAL.before"
BADLOG="$LOGDIR/burnin-$SERIAL.badblocks"
exec > >(tee -a "$LOG") 2>&1

echo "Drive:  $MODEL  serial $SERIAL  ($REAL)"
smart -i "$DEV" | grep -E 'Capacity|Rotation|SATA Version' || true
echo
if [[ $RESUME -eq 1 ]]; then
  [[ -s "$BEFORE" ]] || die "No baseline ($BEFORE): run a full burn-in instead of --resume."
  grep -q "Pass completed" "$BADLOG" 2>/dev/null \
    || die "badblocks never finished on this drive ($BADLOG): run a full burn-in instead of --resume."
  log "Resuming at the SMART long self-test. $(date)"
else
  echo "THIS WILL ERASE EVERYTHING ON $DEV."
  read -r -p "Type the serial number ($SERIAL) to continue: " ans
  [[ "$ans" == "$SERIAL" ]] || die "Aborted."
fi

# From here on, any unexpected stop sends an alert instead of ending silently.
STEP="setup"
RESULT=""
on_exit() {
  local rc=$?
  [[ $rc -eq 0 || -n "$RESULT" ]] && return
  warn "Burn-in stopped during: $STEP (exit $rc). Fix the cause, then run again with --resume if badblocks had finished."
  notify high "Burn-in stopped" "$MODEL $SERIAL stopped during $STEP — see $LOG"
}
trap on_exit EXIT

attrs() { smart -A "$DEV" | awk '$1~/^(5|187|188|197|198|199)$/{print $1, $2, $10}'; }
# wait_selftest [poll seconds]: wait while a self-test runs. smartd starts its own short test every night
# (config/smartd.conf); under badblocks' load such a test can stall for a day and then finish within minutes
# once the drive is idle, and no new test can start until it does.
wait_selftest() {
  local out
  while out="$(smart -c "$DEV")"; grep -q "Self-test routine in progress" <<<"$out"; do
    grep -A1 "Self-test execution" <<<"$out" | tail -1 || true
    sleep "${1:-1800}"
  done
}
# run_selftest <short|long>: start the test once the drive is free, wait for it, show the log.
run_selftest() {
  local out try
  for try in 1 2 3; do
    wait_selftest 300
    out="$(smart -t "$1" "$DEV")"
    grep -q "has begun" <<<"$out" && break
    printf '%s\n' "$out"
    [[ $try -lt 3 ]] || die "The SMART $1 self-test didn't start (see above)."
  done
  sleep 120
  wait_selftest
  smart -l selftest "$DEV" | sed -n '1,8p'
}

if [[ $RESUME -eq 0 ]]; then
  STEP="baseline"
  log "Baseline attributes"; attrs | tee "$BEFORE"
  notify low "Burn-in started" "$MODEL $SERIAL"

  STEP="short self-test"
  log "SMART short self-test"
  run_selftest short

  STEP="badblocks"
  log "badblocks write+verify (random pattern, one pass). Started $(date)"
  # -b 8192 is required: drives >16 TB overflow badblocks' 32-bit block count at 4096.
  badblocks -wsv -b 8192 -c 64 -t random "$DEV" 2>&1 | tee "$BADLOG"
fi
BAD="$(grep -oE '[0-9]+ bad blocks found' "$BADLOG" | tail -1 | awk '{print $1}' || true)"
BAD="${BAD:-unknown}"
echo "badblocks: $BAD bad blocks"

STEP="long self-test"
log "SMART long self-test (many hours)"
run_selftest long

STEP="comparison"
log "After attributes"; attrs | tee "$LOGDIR/burnin-$SERIAL.after"

FAIL=0
[[ "$BAD" == "0" ]] || { warn "badblocks reported: $BAD"; FAIL=1; }
# The newest log entry must be this long test: a short test that passed doesn't count.
grep -m1 '^# *1 ' <<<"$(smart -l selftest "$DEV")" | grep -q "Extended offline.*Completed without error" \
  || { warn "Long self-test did not pass"; FAIL=1; }
while read -r id name raw; do
  before="$(awk -v id="$id" '$1==id{print $3}' "$BEFORE")"
  if [[ "$id" =~ ^(5|197|198)$ ]] && [[ "$raw" != "0" ]]; then
    warn "$name ($id) = $raw (must be 0)"; FAIL=1
  elif [[ "$raw" != "$before" ]]; then
    warn "$name ($id) changed $before -> $raw"; [[ "$id" == 199 ]] && warn "(199 = cable/backplane CRC errors: reseat cables, not a drive fault)"
  fi
done < "$LOGDIR/burnin-$SERIAL.after"

rm -f "$LOGDIR/burnin-$SERIAL.PASS" "$LOGDIR/burnin-$SERIAL.FAIL"
if [[ $FAIL -eq 0 ]]; then
  RESULT=pass
  echo "PASS: $MODEL $SERIAL" | tee "$LOGDIR/burnin-$SERIAL.PASS"
  notify default "Burn-in PASSED" "$MODEL $SERIAL"
else
  RESULT=fail
  echo "FAIL: $MODEL $SERIAL — contact ServerPartDeals for warranty replacement" | tee "$LOGDIR/burnin-$SERIAL.FAIL"
  notify urgent "Burn-in FAILED" "$MODEL $SERIAL — see $LOG"
  exit 1
fi
