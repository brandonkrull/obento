#!/usr/bin/env bash
# Shared helpers. Source this file; don't run it.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-/etc/homeserver/.env}"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$REPO_DIR/.env"

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    if [[ $EUID -ne 0 ]]; then
      echo "Run this with sudo: the settings are in /etc/homeserver/.env, which only root can read." >&2
    else
      echo "Missing $ENV_FILE (copy .env.example to .env, fill it in, and run sudo ./install.sh)" >&2
    fi
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
  local auth=() email=()
  [[ -n "${NTFY_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
  # Email only what needs action, to stay within ntfy's daily email limit.
  [[ -n "${NTFY_EMAIL:-}" && "$prio" =~ ^(high|urgent)$ ]] && email=(-H "Email: $NTFY_EMAIL")
  # Never fail the caller, but log why ntfy refused (e.g. email needs an account) instead of hiding it.
  local resp
  resp="$(curl -sS -m 15 -w '\n%{http_code}' "${auth[@]}" "${email[@]}" \
    -H "Title: [$(hostname)] $title" -H "Priority: $prio" \
    -d "$msg" "${NTFY_URL%/}/$NTFY_TOPIC" 2>&1)" || true
  [[ "${resp##*$'\n'}" == 2* ]] || logger -t homeserver "ntfy send failed: ${resp//$'\n'/ }" || true
}

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
