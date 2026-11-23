#!/usr/bin/env bash
# Weekly drive report: health, key error counters, temperature and power-on hours per drive.
# Also flags a drive that is much slower than its mirror partner (the article's "SMART PASSED
# but the drive was dragging the array" lesson).
source "$(dirname "$(readlink -f "$0")")/lib.sh"
load_env
report=""
worst=low
for d in /dev/disk/by-id/ata-* /dev/disk/by-id/nvme-*; do
  [[ "$d" == *-part* || ! -e "$d" ]] && continue
  [[ "$d" == *nvme-eui* || "$d" == *nvme-nvme* ]] && continue
  out="$(smartctl -H -A "$d" 2>/dev/null)" || true
  h="$(echo "$out" | grep -oE 'PASSED|FAILED' | head -1)"
  val() { echo "$out" | awk -v id="$1" '$1==id{print $10}'; }
  realloc="$(val 5)"; pend="$(val 197)"; unc="$(val 198)"; crc="$(val 199)"; hrs="$(val 9)"
  temp="$(echo "$out" | awk '$1==194{print $10}')"
  [[ -z "$temp" ]] && temp="$(echo "$out" | awk -F': *' '/^Temperature:/{print $2}' | tr -dc '0-9')"
  line="$(basename "$d" | cut -c1-40): ${h:-?} realloc=${realloc:-–} pend=${pend:-–} unc=${unc:-–} crc=${crc:-–} temp=${temp:-?}C hrs=${hrs:-?}"
  report+="$line"$'\n'
  [[ "$h" == FAILED ]] && worst=urgent
  for v in "$realloc" "$pend" "$unc"; do [[ -n "$v" && "$v" != 0 ]] && worst=high; done
  [[ -n "$temp" && "$temp" -ge 50 ]] && worst=high
done

if zpool list "$POOL_NAME" >/dev/null 2>&1; then
  # Average per-disk wait latency over 30 s; flag a disk 3x slower than the fastest.
  lat="$(zpool iostat -vlH -p "$POOL_NAME" 30 2 | tail -n +2 | awk '$1 ~ /^(ata|wwn|scsi)/{print $1, $8}' | tail -n 2)"
  report+=$'\nlatency (total_wait read, ns):\n'"$lat"$'\n'
  fastest="$(echo "$lat" | awk '$2>0{print $2}' | sort -n | head -1)"
  slowest="$(echo "$lat" | awk '{print $2}' | sort -n | tail -1)"
  if [[ -n "$fastest" && -n "$slowest" && "$fastest" -gt 0 ]] && (( slowest > fastest * 3 )); then
    report+="WARNING: one drive is >3x slower than its partner — investigate before it fails."$'\n'
    [[ "$worst" == low ]] && worst=high
  fi
  report+=$'\n'"$(zpool list -Ho name,size,alloc,free,cap,health "$POOL_NAME")"
fi
notify "$worst" "Weekly drive report" "$report"
