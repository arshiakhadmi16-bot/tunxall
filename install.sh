#!/usr/bin/env bash
# install.sh — one-command installer for tunxall.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/arshiakhadmi16-bot/tunxall/main/install.sh)
#
# Downloads the scripts into /opt/tunxall and creates global commands:
#   abtunnel   -> tunnel setup (stunnel / ssh / ipsec, menu-driven)
#   netcheck   -> path & firewall diagnostics
#   wg-tunnel  -> WireGuard link
set -euo pipefail

REPO="${TUNXALL_REPO:-arshiakhadmi16-bot/tunxall}"
BRANCH="${TUNXALL_BRANCH:-main}"
BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
DEST=/opt/tunxall
BIN=/usr/local/bin

c_g="\e[32m"; c_r="\e[31m"; c_y="\e[33m"; c_0="\e[0m"
log()  { echo -e "${c_g}[+]${c_0} $*"; }
warn() { echo -e "${c_y}[!]${c_0} $*"; }
die()  { echo -e "${c_r}[x]${c_0} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root:  curl -fsSL $BASE/install.sh | sudo bash"
command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl; }

mkdir -p "$DEST"
for f in abtunnel.sh netcheck.sh wg-tunnel.sh; do
  log "Downloading $f"
  curl -fsSL "$BASE/$f" -o "$DEST/$f" || die "download failed: $f"
  chmod +x "$DEST/$f"
done

# global command wrappers
declare -A MAP=( [abtunnel]=abtunnel.sh [netcheck]=netcheck.sh [wg-tunnel]=wg-tunnel.sh )
for name in "${!MAP[@]}"; do
  cat > "$BIN/$name" <<EOF
#!/usr/bin/env bash
exec bash $DEST/${MAP[$name]} "\$@"
EOF
  chmod +x "$BIN/$name"
done

log "Installed to $DEST and linked into $BIN"
echo
echo -e "${c_y}To set up a tunnel, just run:   sudo abtunnel${c_0}"
echo "  - On the SERVER  (public IP): choose 1 — it prints a TOKEN."
echo "  - On the CLIENT:              choose 2 and paste that token. Done."
echo
echo "Diagnostics (optional):  netcheck server  /  netcheck probe --target <IP>"
