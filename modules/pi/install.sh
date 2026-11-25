# shellcheck shell=bash
# Module pi: run by install.sh (helpers from install.sh and scripts/lib.sh; MODULE_DIR is this folder).
log "pi coding agent"
# pi needs Node >= 22.19; Ubuntu 24.04 ships 18, so use NodeSource's 22.x repo (kept updated automatically).
if ! node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a==22&&b>=19)?0:1)' 2>/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update
  apt-get install -y nodejs
fi
PI_VERSION=1.0.0
[[ "$(pi --version 2>/dev/null)" == "$PI_VERSION" ]] || npm install -g "@earendil-works/pi-coding-agent@$PI_VERSION"

# Settings for the account that ran 'sudo ./install.sh', written once from PI_URL and PI_MODEL; after that
# ~/.pi/agent is yours to change (install.sh never overwrites it).
PI_USER="${SUDO_USER:-}"
if [[ -z "$PI_USER" || "$PI_USER" == root ]]; then
  warn "pi settings not written: run install.sh with sudo from your own account."
elif [[ -z "${PI_URL:-}" || -z "${PI_MODEL:-}" ]]; then
  [[ -f "$(getent passwd "$PI_USER" | cut -d: -f6)/.pi/agent/models.json" ]] \
    || warn "pi is installed; set PI_URL and PI_MODEL in .env (or configure ~/.pi/agent yourself)."
else
  PI_DIR="$(getent passwd "$PI_USER" | cut -d: -f6)/.pi/agent"
  install -d -m 700 -o "$PI_USER" -g "$(id -gn "$PI_USER")" "$(dirname "$PI_DIR")" "$PI_DIR"
  pi_tmp="$(mktemp -d)"
  jq -n --arg url "$PI_URL" --arg model "$PI_MODEL" '{providers: {local: {api: "openai-completions",
    apiKey: "none", baseUrl: $url, models: [{id: $model, name: $model, input: ["text"]}]}}}' > "$pi_tmp/models.json"
  jq -n --arg model "$PI_MODEL" '{defaultProvider: "local", defaultModel: $model}' > "$pi_tmp/settings.json"
  for f in models.json settings.json; do
    [[ -f "$PI_DIR/$f" ]] || install -m 600 -o "$PI_USER" -g "$(id -gn "$PI_USER")" "$pi_tmp/$f" "$PI_DIR/$f"
  done
  rm -rf "$pi_tmp"
fi
