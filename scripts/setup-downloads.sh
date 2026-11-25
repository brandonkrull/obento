#!/usr/bin/env bash
# Connects the download apps to each other, the steps of RUNBOOK "Automatic TV and film downloads":
#   SABnzbd   Usenet server, folders, categories, login
#   Jellyfin  Shows and Movies libraries, an API key for Sonarr and Radarr
#   Sonarr    /data/Shows, SABnzbd, tell Jellyfin about imports, login      (Radarr: the same for films)
#   Prowlarr  your indexer, handed to Sonarr and Radarr, login
#   Seerr     first-time setup with your Jellyfin admin, both libraries, Sonarr and Radarr
# Safe to re-run: every step checks first and leaves what's already set up alone.
#
# Usage: sudo obento setup-downloads   (after 'obento up' with COMPOSE_PROFILES including downloads)
# Reads USENET_* and NZB_INDEXER* from .env; asks for logins only when a step needs them, and keeps none.
source "$(dirname "$0")/lib.sh"
[[ -n "${OBENTO_TEST:-}" ]] || require_root
load_env

[[ ",${COMPOSE_PROFILES:-}," == *,downloads,* ]] || die "Add downloads to COMPOSE_PROFILES in .env first (RUNBOOK)."
SSD="${SSD_DATA:-/srv}"
JELLYFIN_URL="https://media.${APPS_DOMAIN:?APPS_DOMAIN is not set}"
FAILED=0
fail() { warn "$*"; FAILED=1; }

# api <app> <method> <path> [json body]: calls an app on its localhost port and prints the reply. On an
# error it prints the app's own explanation and fails.
declare -A PORT=([sabnzbd]=8085 [prowlarr]=9696 [sonarr]=8989 [radarr]=7878 [seerr]=5055 [jellyfin]=8096)
declare -A KEY=()
api() {
  local app="$1" method="$2" path="$3" body="${4:-}" hdr=()
  case "$app" in
    jellyfin) hdr=(-H "Authorization: MediaBrowser Client=\"obento\", Device=\"obento\", DeviceId=\"obento-setup\", Version=\"1\", Token=\"${JF_TOKEN:-}\"") ;;
    seerr)    hdr=(-b "$COOKIES" -c "$COOKIES") ;;  # the session from signing in (setup_seerr)
    *)        hdr=(-H "X-Api-Key: ${KEY[$app]}") ;;
  esac
  local reply
  reply="$(curl -sS -m 60 -X "$method" "${hdr[@]}" -H "Content-Type: application/json" \
    ${body:+--data "$body"} -w '\n%{http_code}' "http://127.0.0.1:${PORT[$app]}$path")" || return 1
  if [[ "${reply##*$'\n'}" != 2* ]]; then
    warn "  $app said (${reply##*$'\n'}): $(head -c 400 <<<"${reply%$'\n'*}")"
    return 1
  fi
  printf '%s' "${reply%$'\n'*}"
}
COOKIES="$(mktemp)"
trap 'rm -f "$COOKIES"' EXIT

wait_for() {  # wait_for <app> <path>: first starts take a minute to write their settings
  for _ in {1..60}; do
    curl -fs -m 5 -o /dev/null "http://127.0.0.1:${PORT[$1]}$2" && return 0
    sleep 2
  done
  die "$1 isn't answering on port ${PORT[$1]}; check 'obento logs $1'."
}

ask() {  # ask <var> <prompt> [secret]: prompt once, keep the answer for the rest of the run
  [[ -n "${!1:-}" ]] && return 0
  local reply
  if [[ -n "${3:-}" ]]; then read -rsp "$2: " reply || true; echo; else read -rp "$2: " reply || true; fi
  [[ -n "$reply" ]] || die "Nothing entered."
  printf -v "$1" '%s' "$reply"
}

# The login for Sonarr, Radarr, Prowlarr and SABnzbd, asked for only if one of them has none yet.
app_login() {
  ask APP_USER "Username for Sonarr, Radarr, Prowlarr and SABnzbd (save it in Vaultwarden)"
  ask APP_PASS "Password for them" secret
}

# Jellyfin admin session, for its libraries and API key and for Seerr's first setup.
JF_TOKEN=""
jellyfin_login() {
  [[ -n "$JF_TOKEN" ]] && return 0
  ask JF_USER "Jellyfin admin username"
  ask JF_PASS "Jellyfin admin password" secret
  JF_TOKEN="$(api jellyfin POST /Users/AuthenticateByName \
    "$(jq -n --arg u "$JF_USER" --arg p "$JF_PASS" '{Username: $u, Pw: $p}')" | jq -r .AccessToken)" \
    || die "Jellyfin didn't accept that login."
}

xml_value() { sed -nE "s#.*<$2>([^<]*)</$2>.*#\1#p" "$SSD/$1/config.xml" | head -1; }

# ------------------------------------------------------------------------------------------- SABnzbd
setup_sabnzbd() {
  log "SABnzbd: Usenet server, folders, categories"
  wait_for sabnzbd /
  for _ in {1..30}; do KEY[sabnzbd]="$(sed -nE 's/^api_key = (.+)$/\1/p' "$SSD/sabnzbd/sabnzbd.ini")"; [[ -n "${KEY[sabnzbd]}" ]] && break; sleep 2; done
  [[ -n "${KEY[sabnzbd]}" ]] || die "SABnzbd hasn't written its API key yet; try again in a minute."
  sab() { api sabnzbd GET "/api?output=json&apikey=${KEY[sabnzbd]}&$1"; }
  local cfg; cfg="$(sab mode=get_config)"

  if jq -e '.config.servers | length > 0' <<<"$cfg" >/dev/null; then
    log "  Usenet server already set"
  elif [[ -z "${USENET_HOST:-}" ]]; then
    fail "  USENET_HOST etc. aren't in .env: add your Usenet provider there, or in SABnzbd (Config > Servers)."
  else
    sab "mode=set_config&section=servers&keyword=$(jq -rn --arg v "$USENET_HOST" '$v|@uri')&host=$(jq -rn --arg v "$USENET_HOST" '$v|@uri')&port=${USENET_PORT:-563}&ssl=1&username=$(jq -rn --arg v "${USENET_USERNAME:-}" '$v|@uri')&password=$(jq -rn --arg v "${USENET_PASSWORD:-}" '$v|@uri')&connections=${USENET_CONNECTIONS:-20}&enable=1" >/dev/null
    log "  Usenet server $USENET_HOST added"
  fi
  sab "mode=set_config&section=misc&keyword=download_dir&value=/incomplete" >/dev/null
  sab "mode=set_config&section=misc&keyword=complete_dir&value=/data/Downloads" >/dev/null
  local cat
  for cat in tv movies; do
    jq -e --arg c "$cat" '.config.categories // [] | any(.name == $c)' <<<"$cfg" >/dev/null \
      || { sab "mode=set_config&section=categories&keyword=$cat&dir=" >/dev/null; log "  category $cat added"; }
  done
  if [[ -z "$(jq -r '.config.misc.username' <<<"$cfg")" ]]; then
    app_login
    sab "mode=set_config&section=misc&keyword=username&value=$(jq -rn --arg v "$APP_USER" '$v|@uri')" >/dev/null
    sab "mode=set_config&section=misc&keyword=password&value=$(jq -rn --arg v "$APP_PASS" '$v|@uri')" >/dev/null
    log "  login set"
  fi
}

# -------------------------------------------------------------------------------- Sonarr, Radarr, Prowlarr
arr_key() {  # API key from config.xml, written on first start
  for _ in {1..30}; do
    [[ -f "$SSD/$1/config.xml" ]] && KEY[$1]="$(xml_value "$1" ApiKey)"
    [[ -n "${KEY[$1]:-}" ]] && return 0
    sleep 2
  done
  die "$1 hasn't written its API key yet; try again in a minute."
}

arr_login() {  # arr_login <app> <api version>: Forms login, required for everyone (through Traefik all look local)
  local host
  host="$(api "$1" GET "/api/$2/config/host")"
  [[ "$(jq -r .authenticationMethod <<<"$host")" == forms ]] && return 0
  app_login
  api "$1" PUT "/api/$2/config/host" "$(jq --arg u "$APP_USER" --arg p "$APP_PASS" \
    '.authenticationMethod = "forms" | .authenticationRequired = "enabled" | .username = $u
     | .password = $p | .passwordConfirmation = $p' <<<"$host")" >/dev/null
  log "  login set"
}

# fill <schema item> <field=value>...: sets fields in an *arr schema object (values as JSON).
fill() {
  local obj="$1" kv; shift
  for kv in "$@"; do
    obj="$(jq --arg k "${kv%%=*}" --argjson v "${kv#*=}" '.fields |= map(if .name == $k then .value = $v else . end)' <<<"$obj")"
  done
  printf '%s' "$obj"
}

setup_arr() {  # setup_arr <sonarr|radarr> <root folder> <SABnzbd category field> <category>
  local app="$1" root="$2" catfield="$3" cat="$4" schema item
  log "${app^}: $root, SABnzbd, Jellyfin"
  wait_for "$app" /ping
  arr_key "$app"
  arr_login "$app" v3

  if api "$app" GET /api/v3/rootfolder | jq -e --arg p "$root" 'any(.path | rtrimstr("/") == $p)' >/dev/null; then
    log "  $root already there"
  else
    api "$app" POST /api/v3/rootfolder "$(jq -n --arg p "$root" '{path: $p}')" >/dev/null && log "  $root added"
  fi

  if api "$app" GET /api/v3/downloadclient | jq -e 'any(.implementation == "Sabnzbd")' >/dev/null; then
    log "  SABnzbd already connected"
  else
    schema="$(api "$app" GET /api/v3/downloadclient/schema | jq '.[] | select(.implementation == "Sabnzbd")')"
    item="$(fill "$schema" 'host="sabnzbd"' 'port=8080' "apiKey=\"${KEY[sabnzbd]}\"" "$catfield=\"$cat\"")"
    item="$(jq '.name = "SABnzbd" | .enable = true' <<<"$item")"
    if api "$app" POST /api/v3/downloadclient "$item" >/dev/null; then
      log "  SABnzbd connected"
    else
      fail "  couldn't connect $app to SABnzbd (add it in $app: Settings > Download Clients)"
    fi
  fi

  if api "$app" GET /api/v3/notification | jq -e 'any(.implementation == "MediaBrowser")' >/dev/null; then
    log "  Jellyfin updates already on"
  else
    jellyfin_api_key
    schema="$(api "$app" GET /api/v3/notification/schema | jq '.[] | select(.implementation == "MediaBrowser")')"
    item="$(fill "$schema" 'host="jellyfin"' 'port=8096' "apiKey=\"$JF_KEY\"" 'updateLibrary=true')"
    # Every event this notification supports (imports, upgrades, renames, deletes).
    item="$(jq '.name = "Jellyfin" | . as $o | reduce (keys[] | select(startswith("supportsOn"))) as $s
             (.; if $o[$s] then .["on" + ($s | ltrimstr("supportsOn"))] = true else . end)' <<<"$item")"
    if api "$app" POST /api/v3/notification "$item" >/dev/null; then
      log "  Jellyfin updates on"
    else
      fail "  couldn't add Jellyfin to $app (Settings > Connect > Emby / Jellyfin)"
    fi
  fi

  # Disc copies (Remux) are 20-40 GB for no visible gain; HD-1080p is what Seerr requests.
  local profile
  profile="$(api "$app" GET /api/v3/qualityprofile | jq '.[] | select(.name == "HD-1080p")')"
  if [[ -n "$profile" ]] && jq -e '[.. | objects | select(.quality? and .allowed and (.quality.name | test("Remux")))] | length > 0' <<<"$profile" >/dev/null; then
    api "$app" PUT "/api/v3/qualityprofile/$(jq .id <<<"$profile")" "$(jq '(.. | objects | select(.quality? and (.quality.name | test("Remux")))).allowed = false' <<<"$profile")" >/dev/null \
      && log "  HD-1080p no longer takes Remux copies"
  fi
}

setup_prowlarr() {
  local schema item app
  log "Prowlarr: indexer, Sonarr, Radarr"
  wait_for prowlarr /ping
  arr_key prowlarr
  arr_login prowlarr v1

  if api prowlarr GET /api/v1/indexer | jq -e 'length > 0' >/dev/null; then
    log "  indexer already there"
  elif [[ -z "${NZB_INDEXER_API_KEY:-}" ]]; then
    fail "  NZB_INDEXER_API_KEY isn't in .env: add your indexer there, or in Prowlarr (Indexers > Add Indexer)."
  else
    # Usenet indexers are presets of the Newznab definition, so match the preset's name.
    schema="$(api prowlarr GET /api/v1/indexer/schema | jq --arg n "${NZB_INDEXER:-NZBgeek}" \
      'first(.[] | select((.name | ascii_downcase) == ($n | ascii_downcase))) // empty')"
    if [[ -z "$schema" ]]; then
      fail "  Prowlarr doesn't know an indexer called '${NZB_INDEXER:-NZBgeek}' (NZB_INDEXER in .env)."
    else
      item="$(fill "$schema" "apiKey=$(jq -n --arg k "$NZB_INDEXER_API_KEY" '$k')")"
      item="$(jq '.enable = true | .appProfileId = 1' <<<"$item")"
      # Prowlarr tests the key while saving; a wrong key fails here instead of saving a broken indexer.
      if api prowlarr POST /api/v1/indexer "$item" >/dev/null; then
        log "  ${NZB_INDEXER:-NZBgeek} added"
      else
        fail "  Prowlarr couldn't use the indexer: check NZB_INDEXER_API_KEY."
      fi
    fi
  fi

  for app in Sonarr Radarr; do
    local lower="${app,,}"
    if api prowlarr GET /api/v1/applications | jq -e --arg a "$app" 'any(.implementation == $a)' >/dev/null; then
      log "  $app already linked"
      continue
    fi
    schema="$(api prowlarr GET /api/v1/applications/schema | jq --arg a "$app" '.[] | select(.implementation == $a)')"
    item="$(fill "$schema" 'prowlarrUrl="http://prowlarr:9696"' "baseUrl=\"http://$lower:${PORT[$lower]}\"" \
      "apiKey=\"${KEY[$lower]}\"")"
    item="$(jq --arg a "$app" '.name = $a | .syncLevel = "fullSync"' <<<"$item")"
    if api prowlarr POST /api/v1/applications "$item" >/dev/null; then
      log "  $app linked"
    else
      fail "  couldn't link $app in Prowlarr (Settings > Apps)"
    fi
  done
}

# -------------------------------------------------------------------------------------------- Jellyfin
JF_KEY=""
jellyfin_api_key() {  # one key, named obento-downloads, shared by Sonarr and Radarr
  [[ -n "$JF_KEY" ]] && return 0
  jellyfin_login
  JF_KEY="$(api jellyfin GET /Auth/Keys | jq -r 'first(.Items[] | select(.AppName == "obento-downloads") | .AccessToken) // empty')"
  if [[ -z "$JF_KEY" ]]; then
    api jellyfin POST "/Auth/Keys?app=obento-downloads" >/dev/null
    JF_KEY="$(api jellyfin GET /Auth/Keys | jq -r 'first(.Items[] | select(.AppName == "obento-downloads") | .AccessToken)')"
  fi
}

setup_jellyfin_libraries() {
  local folders name type
  folders="$(api jellyfin GET /Library/VirtualFolders)"
  for name in Shows Movies; do
    type=tvshows; [[ $name == Movies ]] && type=movies
    if jq -e --arg t "$type" 'any(.CollectionType == $t)' <<<"$folders" >/dev/null; then
      log "  Jellyfin $name library already there"
    else
      api jellyfin POST "/Library/VirtualFolders?name=$name&collectionType=$type&paths=/media/$name&refreshLibrary=true" \
        '{"LibraryOptions":{}}' >/dev/null && log "  Jellyfin $name library added (/media/$name)"
    fi
  done
}

# ------------------------------------------------------------------------------------------------ Seerr
setup_seerr() {
  log "Seerr: Jellyfin, libraries, Sonarr, Radarr"
  wait_for seerr /api/v1/status
  if [[ "$(api seerr GET /api/v1/settings/public | jq -r .initialized)" == true ]]; then
    log "  already set up"
    return 0
  fi
  log "Jellyfin: libraries for Seerr"
  wait_for jellyfin /health
  jellyfin_login
  setup_jellyfin_libraries
  # Signing in with the Jellyfin admin creates Seerr's owner account and connects Jellyfin. On a re-run after a
  # half-finished setup, Jellyfin is already connected and the same sign-in just logs in.
  local body reply
  body="$(jq -n --arg u "$JF_USER" --arg p "$JF_PASS" \
    '{username: $u, password: $p, hostname: "jellyfin", port: 8096, useSsl: false, urlBase: "", serverType: 2}')"
  reply="$(curl -sS -m 60 -b "$COOKIES" -c "$COOKIES" -H "Content-Type: application/json" --data "$body" \
    -w '\n%{http_code}' "http://127.0.0.1:5055/api/v1/auth/jellyfin")"
  if [[ "${reply##*$'\n'}" != 200 ]] && [[ "$reply" == *"already configured"* ]]; then
    reply="$(curl -sS -m 60 -b "$COOKIES" -c "$COOKIES" -H "Content-Type: application/json" -w '\n%{http_code}' \
      --data "$(jq '{username, password}' <<<"$body")" "http://127.0.0.1:5055/api/v1/auth/jellyfin")"
  fi
  [[ "${reply##*$'\n'}" == 200 ]] || die "Seerr couldn't sign in to Jellyfin as $JF_USER: ${reply%$'\n'*}"
  # Only the editable fields; Seerr refuses the read-only ones (name, serverId, libraries).
  api seerr POST /api/v1/settings/jellyfin "$(api seerr GET /api/v1/settings/jellyfin | jq --arg u "$JELLYFIN_URL" \
    '{ip, port, useSsl, urlBase, jellyfinForgotPasswordUrl, apiKey, externalHostname: $u}')" >/dev/null
  log "  Jellyfin connected, links go to $JELLYFIN_URL"
  local libs id
  libs="$(api seerr POST /api/v1/settings/jellyfin/library/sync)"
  for id in $(jq -r '.[] | select(.type == "show" or .type == "movie") | .id' <<<"$libs"); do
    api seerr PUT "/api/v1/settings/jellyfin/library/$id" '{"enabled": true}' >/dev/null
  done
  [[ -n "$(jq -r '.[] | select(.type == "show" or .type == "movie") | .id' <<<"$libs")" ]] \
    || fail "  Seerr found no Shows or Movies library in Jellyfin."
  log "  libraries: $(jq -r '[.[] | select(.type == "show" or .type == "movie") | .name] | join(", ")' <<<"$libs")"

  local app root test profile body
  for app in sonarr radarr; do
    root=/data/Shows; [[ $app == radarr ]] && root=/data/Movies
    test="$(api seerr POST "/api/v1/settings/$app/test" "$(jq -n --arg h "$app" --argjson p "${PORT[$app]}" --arg k "${KEY[$app]}" \
      '{hostname: $h, port: $p, apiKey: $k, useSsl: false, baseUrl: ""}')")" || { fail "  Seerr can't reach $app"; continue; }
    profile="$(jq -c 'first(.profiles[] | select(.name == "HD-1080p")) // .profiles[0]' <<<"$test")"
    body="$(jq -n --arg app "$app" --argjson port "${PORT[$app]}" --arg key "${KEY[$app]}" --arg root "$root" --argjson pr "$profile" \
      --arg ext "https://$([[ $app == sonarr ]] && echo tv || echo movies).$APPS_DOMAIN" \
      '{name: ($app | ascii_upcase[0:1] + $app[1:]), hostname: $app, port: $port, apiKey: $key, useSsl: false, baseUrl: "",
        activeProfileId: $pr.id, activeProfileName: $pr.name, activeDirectory: $root, is4k: false, isDefault: true,
        externalUrl: $ext, syncEnabled: false, preventSearch: false}
       + if $app == "sonarr" then {enableSeasonFolders: true} else {minimumAvailability: "released"} end')"
    if api seerr POST "/api/v1/settings/$app" "$body" >/dev/null; then
      log "  ${app^} added ($root, ${profile:+$(jq -r .name <<<"$profile")})"
    else
      fail "  couldn't add $app to Seerr"
    fi
  done
  api seerr POST /api/v1/settings/initialize >/dev/null && log "  setup finished"
}

setup_sabnzbd
setup_arr sonarr /data/Shows tvCategory tv
setup_arr radarr /data/Movies movieCategory movies
setup_prowlarr
setup_seerr

if (( FAILED )); then
  warn "Done, with the problems above; fix them and run 'sudo obento setup-downloads' again."
  exit 1
fi
log "Done. Try it: request something at https://requests.$APPS_DOMAIN"
