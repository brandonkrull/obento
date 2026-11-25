# shellcheck shell=bash
# Module domain: run by install.sh (helpers from install.sh and scripts/lib.sh; MODULE_DIR is this folder).
[[ -n "${DESEC_TOKEN:-}" ]] || warn "DESEC_TOKEN isn't set: Traefik can't get its certificate."
install -d -m 700 "$SSD_DATA/traefik"

# Which address goes to which app, from every module's HOSTS. Traefik watches this folder.
install -d -m 755 /opt/obento/generated/routes
routes_tmp="$(mktemp)"
write_routes "$routes_tmp"
install_conf 644 root "$routes_tmp" /opt/obento/generated/routes/obento.yml
rm -f "$routes_tmp"

# The portal: its look (homepage/), each module's tiles (portal.yaml), and PORTAL_TITLE / PORTAL_LOGO from
# .env (your own name and image, kept out of the repo). Edits belong in the repo; these copies are overwritten.
install -d -m 755 "$SSD_DATA/portal"
portal_tmp="$(mktemp -d)"
cp "$MODULE_DIR"/homepage/* "$portal_tmp"/
write_portal_services "$portal_tmp/services.yaml"
portal_layout >> "$portal_tmp/settings.yaml"
if [[ -n "${PORTAL_TITLE:-}" ]]; then
  sed -i "s|^title: .*|title: \"${PORTAL_TITLE//\"/}\"|" "$portal_tmp/settings.yaml"
fi
if [[ -n "${PORTAL_LOGO:-}" ]]; then
  printf 'favicon: %s\n' "$PORTAL_LOGO" >> "$portal_tmp/settings.yaml"
fi
{
  if [[ -n "${PORTAL_LOGO:-}" ]]; then printf -- '- logo:\n    icon: %s\n' "$PORTAL_LOGO"; fi
  if [[ -n "${PORTAL_TITLE:-}" ]]; then printf -- '- greeting:\n    text_size: xl\n    text: "%s"\n' "${PORTAL_TITLE//\"/}"; fi
  cat "$MODULE_DIR/homepage/widgets.yaml"
} > "$portal_tmp/widgets.yaml"
for f in "$portal_tmp"/*; do install_conf 644 root "$f" "$SSD_DATA/portal/$(basename "$f")"; done
rm -rf "$portal_tmp"
