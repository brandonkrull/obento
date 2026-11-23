#!/usr/bin/env bash
# Monthly scrub: reads every block and verifies checksums, catching a silently failing drive
# BEFORE a rebuild depends on it (the root cause in the article). Reports the result.
source "$(dirname "$(readlink -f "$0")")/lib.sh"
load_env
zpool list "$POOL_NAME" >/dev/null 2>&1 || exit 0
zpool scrub -w "$POOL_NAME"
status="$(zpool status "$POOL_NAME")"
errs="$(zpool status -x "$POOL_NAME")"
scan="$(echo "$status" | grep -m1 'scan:' | sed 's/^ *//')"
if echo "$errs" | grep -q "is healthy"; then
  notify low "Scrub OK" "$scan"
else
  notify urgent "Scrub found problems" "$status"
fi
