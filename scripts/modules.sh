# shellcheck shell=bash
# Modules: optional parts of the setup, one folder each under modules/ (see modules/README.md).
# Source after lib.sh and load_env. Nothing here needs root, so it can be tried out anywhere.
MODULES_DIR="${MODULES_DIR:-$REPO_DIR/modules}"

# The modules that are on: core always, then what MODULES in .env lists (in alphabetical order, so the portal
# and the app list come out the same however MODULES is written). Without MODULES, the setup from before
# modules existed: OpenCloud, the UPS and pi, plus domain and downloads if COMPOSE_PROFILES named them.
modules_on() {
  local list m on=()
  if [[ -n "${MODULES+set}" ]]; then
    list="${MODULES//,/ }"
  else
    list="opencloud pi ups ${COMPOSE_PROFILES//,/ }"
  fi
  for m in $list; do
    [[ $m == core ]] && continue
    [[ -f "$MODULES_DIR/$m/module.conf" ]] || die "Unknown module '$m' in MODULES (see $MODULES_DIR)."
    on+=("$m")
  done
  printf 'core\n'
  (( ${#on[@]} )) && printf '%s\n' "${on[@]}" | sort -u
  return 0
}

module_on() { modules_on | grep -qx "$1"; }

# module_conf <module> <VAR>: a setting from modules/<module>/module.conf.
module_conf() {
  # shellcheck disable=SC2034  # defaults for what module.conf may set
  ( HOSTS="" NEEDS="" SERVE="" PORTAL_LAYOUT=""
    # shellcheck disable=SC1090
    source "$MODULES_DIR/$1/module.conf"
    printf '%s' "${!2:-}" )
}

# Stop early when a module needs another that's off, or two addresses collide.
modules_check() {
  local m need
  for m in $(modules_on); do
    for need in $(module_conf "$m" NEEDS); do
      module_on "$need" || die "Module $m needs module $need: add it to MODULES in .env."
    done
  done
  module_on domain && [[ -z "${APPS_DOMAIN:-}" ]] && die "Module domain needs APPS_DOMAIN in .env."
  local dup
  dup="$(hosts_table | awk '{print $1}' | sort | uniq -d)"
  [[ -z "$dup" ]] || die "Two apps want the address '$dup': set a different HOST_... in .env."
  return 0
}

# host_name <key>: the first label of an app's address: the key itself (photos, files, ...) unless .env
# renames it with HOST_<KEY>=<name>, e.g. HOST_REQUESTS=ask for ask.<APPS_DOMAIN>.
host_name() {
  local var="HOST_${1^^}" name
  var="${var//-/_}"
  name="${!var:-$1}"
  [[ "$name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "$var='$name' isn't a valid address name (a-z, 0-9, -)."
  printf '%s' "$name"
}

# hosts_table: one line per address of the modules that are on: "<name> <app> <port> <module>". HOSTS in
# module.conf lists "<key>:<app>:<port>"; key @ is APPS_DOMAIN itself (and any name nobody else answers).
hosts_table() {
  local m entry key app port name
  for m in $(modules_on); do
    for entry in $(module_conf "$m" HOSTS); do
      IFS=: read -r key app port <<<"$entry"
      name="@"; [[ $key == @ ]] || name="$(host_name "$key")"
      printf '%s %s %s %s\n' "$name" "$app" "$port" "$m"
    done
  done
}

# write_routes <file>: Traefik's routes for every address. Rules match the first label only, so the same
# routes work for any APPS_DOMAIN.
write_routes() {
  local name app port _m
  {
    printf '# Written by install.sh from the HOSTS of each module that is on; edits are overwritten.\nhttp:\n  routers:\n'
    while read -r name app port _m; do
      # shellcheck disable=SC2016  # the backticks are Traefik's, not the shell's
      if [[ $name == @ ]]; then
        printf '    %s:\n      rule: '\''HostRegexp(`.+`)'\''\n      priority: 1\n      service: %s\n' "$app" "$app"
      else
        printf '    %s:\n      rule: '\''HostRegexp(`^%s\\.`)'\''\n      service: %s\n' "$app" "$name" "$app"
      fi
    done < <(hosts_table)
    printf '  services:\n'
    while read -r name app port _m; do
      printf '    %s:\n      loadBalancer:\n        servers:\n          - url: http://127.0.0.1:%s\n' "$app" "$port"
    done < <(hosts_table)
  } > "$1"
}

# write_portal_services <file>: the portal's tiles from each module's portal.yaml, merged by group in module
# order (core first). In hrefs, @<key>@ becomes that address's name.
write_portal_services() {
  local m files=() key
  for m in $(modules_on); do
    [[ -f "$MODULES_DIR/$m/portal.yaml" ]] && files+=("$MODULES_DIR/$m/portal.yaml")
  done
  {
    printf '# Written by install.sh from the portal.yaml of each module that is on; edits are overwritten.\n'
    awk '
      /^#/ || /^[[:space:]]*$/ { next }
      /^- [^ ].*:[[:space:]]*$/ { group = $0; if (!(group in seen)) { seen[group] = 1; order[++n] = group }; next }
      { body[group] = body[group] $0 "\n" }
      END { for (i = 1; i <= n; i++) printf "%s\n%s", order[i], body[order[i]] }
    ' "${files[@]}"
  } > "$1"
  for key in $(grep -o '@[a-z0-9-]*@' "$1" | sort -u | tr -d @); do
    sed -i.bak "s/@$key@/$(host_name "$key")/g" "$1" && rm -f "$1.bak"
  done
}

# portal_layout: the layout lines modules add to the portal's settings.yaml (PORTAL_LAYOUT="Group:columns").
portal_layout() {
  local m entry
  for m in $(modules_on); do
    for entry in $(module_conf "$m" PORTAL_LAYOUT); do
      printf '  %s:\n    style: row\n    columns: %s\n' "${entry%%:*}" "${entry##*:}"
    done
  done
}

# compose_files <compose dir>: the compose files of the modules that are on, after the core one.
compose_files() {
  local m
  printf '%s\n' "$1/docker-compose.yml"
  for m in $(modules_on); do
    [[ -f "$MODULES_DIR/$m/compose.yml" ]] && printf '%s\n' "$MODULES_DIR/$m/compose.yml"
  done
  return 0
}

# serve_ports: Tailscale serve mappings (https port:local port) without the domain module.
serve_ports() {
  local m
  for m in $(modules_on); do module_conf "$m" SERVE; printf ' '; done
}
