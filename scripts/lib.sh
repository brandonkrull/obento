#!/usr/bin/env bash
# Shared helpers. Source this file; don't run it.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-/etc/homeserver/.env}"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$REPO_DIR/.env"

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Missing $ENV_FILE (copy .env.example to .env and fill it in)" >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

# notify <priority: low|default|high|urgent> <title> <message>
notify() {
  local prio="$1" title="$2" msg="$3"
  logger -t homeserver "[$prio] $title: $msg" || true
  [[ -n "${NTFY_TOPIC:-}" ]] || return 0
  local auth=()
  [[ -n "${NTFY_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl -fsS -m 15 "${auth[@]}" \
    -H "Title: [$(hostname)] $title" -H "Priority: $prio" \
    -d "$msg" "${NTFY_URL%/}/$NTFY_TOPIC" >/dev/null || true
}

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
