# shellcheck shell=bash
# Module ups: run by install.sh (helpers from install.sh and scripts/lib.sh; MODULE_DIR is this folder).
log "UPS over USB ($MODULE_DIR/nut) -> clean shutdown on low battery"
dpkg -s nut-server nut-client >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y nut-client nut-server
for f in ups.conf nut.conf upsd.users upsmon.conf; do
  install_conf 640 nut "$MODULE_DIR/nut/$f" "/etc/nut/$f"
done
if systemctl enable --now nut-server nut-monitor 2>/dev/null; then
  restart_if_stale nut-server /etc/nut/ups.conf /etc/nut/nut.conf /etc/nut/upsd.users
  restart_if_stale nut-monitor /etc/nut/nut.conf /etc/nut/upsmon.conf
else
  warn "NUT will start once the UPS USB cable is connected."
fi

# The portal's battery gauge reads the UPS from here (127.0.0.1:3011), so only with the domain module.
install_conf 644 root "$MODULE_DIR/obento-ups-status.service" /etc/systemd/system/obento-ups-status.service
systemctl daemon-reload
if module_on domain; then
  systemctl enable --now obento-ups-status.service
  restart_if_stale obento-ups-status.service "$MODULE_DIR/ups-status.py" /etc/systemd/system/obento-ups-status.service
else
  systemctl disable --now obento-ups-status.service 2>/dev/null || true
fi
