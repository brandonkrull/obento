# shellcheck shell=bash
# Module shell: run by install.sh (helpers from install.sh and scripts/lib.sh; MODULE_DIR is this folder).
log "Shell: Starship prompt and command-line tools"
# fzf: Ctrl-R searches history, Ctrl-T finds files. zoxide: 'z <part of a name>' jumps to a folder you've
# been to. eza: ls with colours and git status. bat: cat with syntax highlighting (Ubuntu calls it batcat).
dpkg -s fzf zoxide eza bat >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y fzf zoxide eza bat
[[ -r /usr/share/doc/fzf/examples/key-bindings.bash ]] \
  || warn "fzf's Ctrl-R and Ctrl-T need /usr/share/doc, which this minimized Ubuntu leaves out ('unminimize' restores it)."

# Starship isn't packaged for Ubuntu 24.04: the release from GitHub, checked against the checksum pinned here.
STARSHIP_VERSION=1.26.0
STARSHIP_SHA256=b7c232b0e8249d8e55a40beb79c5c43a7d370f3f9408bd215deb0170daeaadf3  # x86_64-unknown-linux-musl
if [[ "$(uname -m)" != x86_64 ]]; then
  warn "Starship is only set up on x86-64 here; install it yourself (starship.rs). The tools still work."
elif [[ "$(starship --version 2>/dev/null | head -1)" != "starship $STARSHIP_VERSION" ]]; then
  starship_tmp="$(mktemp -d)"
  curl -fsSL -o "$starship_tmp/starship.tar.gz" \
    "https://github.com/starship/starship/releases/download/v$STARSHIP_VERSION/starship-x86_64-unknown-linux-musl.tar.gz"
  echo "$STARSHIP_SHA256  $starship_tmp/starship.tar.gz" | sha256sum -c --quiet \
    || die "Starship download doesn't match its checksum; not installed."
  tar -xzf "$starship_tmp/starship.tar.gz" -C "$starship_tmp" starship
  install -m 755 "$starship_tmp/starship" /usr/local/bin/starship
  rm -rf "$starship_tmp"
fi

# One line at the end of each person's ~/.bashrc (after Ubuntu's own aliases and prompt, so these win) and in
# /etc/skel for accounts made later. bashrc does nothing when the module is off, so the line can stay.
SHELL_LINE='[ -r /opt/obento/modules/shell/bashrc ] && . /opt/obento/modules/shell/bashrc  # obento shell module'
while IFS=: read -r name _ uid _ _ home shell; do
  [[ $uid -eq 0 || ( $uid -ge 1000 && $uid -lt 60000 ) ]] || continue
  [[ $shell == */bash && -f "$home/.bashrc" ]] || continue
  grep -qF '# obento shell module' "$home/.bashrc" && continue
  printf '\n%s\n' "$SHELL_LINE" >> "$home/.bashrc"
  log "  prompt and tools on for $name (from their next login)"
done < /etc/passwd
grep -qF '# obento shell module' /etc/skel/.bashrc || printf '\n%s\n' "$SHELL_LINE" >> /etc/skel/.bashrc
