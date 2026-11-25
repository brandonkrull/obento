# shellcheck shell=bash
# Module opencloud: run by install.sh (helpers from install.sh and scripts/lib.sh; MODULE_DIR is this folder).
# Its address (OC_URL) is written into the compose override by install.sh, with the other addresses.
# OpenCloud runs as 1000:1000 (see compose.yml); its config holds generated secrets.
install -d -m 700 -o 1000 -g 1000 "$SSD_DATA/opencloud" "$SSD_DATA/opencloud/config" "${OPENCLOUD_DATA:-$SSD_DATA/opencloud/data}"
case "${OPENCLOUD_ADMIN_PASSWORD:-}" in
  ""|change-me*) warn "Set OPENCLOUD_ADMIN_PASSWORD in .env before OpenCloud's first start." ;;
esac
