#!/usr/bin/env bash
# Called by upsmon with the event text in $1 and NOTIFYTYPE in env.
source /opt/homeserver/scripts/lib.sh
load_env
case "${NOTIFYTYPE:-}" in
  ONLINE) prio=default ;;
  ONBATT|COMMBAD) prio=high ;;
  *) prio=urgent ;;
esac
notify "$prio" "UPS ${NOTIFYTYPE:-event}" "$*"
