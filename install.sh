#!/usr/bin/env bash
# install.sh — one-command installer for tunxall.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/arshiakhadmi16-bot/tunxall/main/install.sh)
#
# Downloads the scripts into /opt/tunxall and creates global commands:
#   abtunnel   -> tunnel setup (stunnel / ssh / ipsec / backhaul, menu-driven)
#   netcheck   -> path & firewall diagnostics
#   wg-tunnel  -> WireGuard link
set -euo pipefail

REPO="${TUNXALL_REPO:-arshiakhadmi16-bot/tunxall}"
BRANCH="${TUNXALL_BRANCH:-main}"
BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
DEST=/opt/tunxall
BIN=/usr/local/bin
LIB=/usr/local/lib/tunxall

c_g="\e[32m"; c_r="\e[31m"; c_y="\e[33m"; c_0="\e[0m"
log()  { echo -e "${c_g}[+]${c_0} $*"; }
warn() { echo -e "${c_y}[!]${c_0} $*"; }
die()  { echo -e "${c_r}[x]${c_0} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root:  curl -fsSL $BASE/install.sh | sudo bash"
command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl; }

mkdir -p "$DEST" "$LIB"

for f in abtunnel.sh netcheck.sh wg-tunnel.sh backhaul-helper.sh; do
  log "Downloading $f"
  curl -fsSL "$BASE/$f" -o "$DEST/$f" || die "download failed: $f"
  chmod +x "$DEST/$f"
done

# Install backhaul helper to lib path so abtunnel can source it
cp -f "$DEST/backhaul-helper.sh" "$LIB/backhaul-helper.sh"

# global command wrappers
declare -A MAP=( [abtunnel]=abtunnel.sh [netcheck]=netcheck.sh [wg-tunnel]=wg-tunnel.sh )
for name in "${!MAP[@]}"; do
  cat > "$BIN/$name" <<EOW
#!/usr/bin/env bash
exec bash $DEST/${MAP[$name]} "\$@"
EOW
  chmod +x "$BIN/$name"
done

# Backhaul (Go) source: the per-file downloads above don't include it, so fetch
# the backhaul/ directory from the repository tarball.
log "Downloading backhaul source"
rm -rf "$DEST/backhaul"
if curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$BRANCH"     | tar -xz -C "$DEST" --strip-components=1 --wildcards '*/backhaul/*'; then
  :
else
  warn "could not download backhaul source; the backhaul option will be unavailable"
fi

if [[ -f $DEST/backhaul/go.mod ]]; then
  if command -v go >/dev/null 2>&1; then
    log "Building backhaul binary..."
    mkdir -p /etc/abtunnel/backhaul
    if (cd "$DEST/backhaul" && go build -o /etc/abtunnel/backhaul/backhaul .); then
      log "Backhaul binary ready"
    else
      warn "backhaul build failed (needs Go >= 1.22; you have: $(go version)). It will be retried on first use."
    fi
  else
    warn "Go is not installed. Backhaul will be built on first use once Go (>= 1.22) is available."
    warn "Install it from https://go.dev/doc/install (distro packages are often too old)."
  fi
fi

log "Installed to $DEST and linked into $BIN"
echo
echo -e "${c_y}Installed. Opening the menu...${c_0}"
echo "  1) Set up a tunnel (guided): choose role -> IPv4/IPv6 -> protocol."
echo "     New: option 9 = backhaul (reverse tunnel + multi-server auto-select)"
echo "  Re-open anytime with:  sudo abtunnel"
echo "  Diagnostics (optional):  netcheck server  /  netcheck probe --target <IP>"

# auto-open the interactive menu
if [ -e /dev/tty ] && [ -r /dev/tty ]; then
  echo
  abtunnel < /dev/tty
fi
