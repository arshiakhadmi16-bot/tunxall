#!/usr/bin/env bash
# install.sh — one-command installer for tunxall.
#
#   curl -fsSL https://raw.githubusercontent.com/arshiakhadmi16-bot/tunxall/main/install.sh | sudo bash
#
# Installs into /opt/tunxall and creates the global commands:
#   abtunnel   -> tunnel setup menu (backhaul / openvpn / gre / wireguard / ...)
#   netcheck   -> path & firewall diagnostics
#   wg-tunnel  -> WireGuard link
# The backhaul program is downloaded prebuilt (no Go needed); building from
# source is only a fallback.
set -euo pipefail

REPO="${TUNXALL_REPO:-arshiakhadmi16-bot/tunxall}"
BRANCH="${TUNXALL_BRANCH:-main}"
BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
DEST=/opt/tunxall
BIN=/usr/local/bin
LIB=/usr/local/lib/tunxall
LOGFILE=/var/log/abtunnel.log

B=$'\e[1m'; D=$'\e[2m'; CY=$'\e[36m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'
ok()   { echo -e "  ${G}✔${N} $*"; }
warn() { echo -e "  ${Y}!${N} $*"; }
die()  { echo -e "  ${R}✘${N} $*" >&2; exit 1; }

echo
echo -e "${CY}${B}    ▀█▀ █ █ █▄ █ ▀▄▀ ▄▀█ █   █  ${N}"
echo -e "${CY}${B}     █  █▄█ █ ▀█ █ █ █▀█ █▄▄ █▄▄${N}"
echo -e "    ${D}installing...${N}"
echo

[[ $EUID -eq 0 ]] || die "Run as root:  curl -fsSL $BASE/install.sh | sudo bash"
: >>"$LOGFILE" 2>/dev/null || LOGFILE=/tmp/abtunnel.log

# --- base tools (curl, tar, openssl) on apt / dnf / yum systems
need=()
for t in curl tar openssl; do command -v "$t" >/dev/null 2>&1 || need+=("$t"); done
if [[ ${#need[@]} -gt 0 ]]; then
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOGFILE" 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" >>"$LOGFILE" 2>&1 || die "could not install: ${need[*]}"
  elif command -v dnf >/dev/null 2>&1; then dnf install -y -q "${need[@]}" >>"$LOGFILE" 2>&1 || die "could not install: ${need[*]}"
  elif command -v yum >/dev/null 2>&1; then yum install -y -q "${need[@]}" >>"$LOGFILE" 2>&1 || die "could not install: ${need[*]}"
  else die "please install: ${need[*]}"; fi
  ok "Installed ${need[*]}"
fi

# --- scripts
mkdir -p "$DEST" "$LIB"
for f in abtunnel.sh netcheck.sh wg-tunnel.sh backhaul-helper.sh; do
  curl -fsSL --retry 3 "$BASE/$f" -o "$DEST/$f.new" || die "download failed: $f (check this server's internet access)"
  mv -f "$DEST/$f.new" "$DEST/$f"; chmod +x "$DEST/$f"
done
cp -f "$DEST/backhaul-helper.sh" "$LIB/backhaul-helper.sh"
ok "Downloaded tunxall scripts"

declare -A MAP=( [abtunnel]=abtunnel.sh [netcheck]=netcheck.sh [wg-tunnel]=wg-tunnel.sh )
for name in "${!MAP[@]}"; do
  printf '#!/usr/bin/env bash\nexec bash %s/%s "$@"\n' "$DEST" "${MAP[$name]}" > "$BIN/$name"
  chmod +x "$BIN/$name"
done
ok "Created commands: abtunnel, netcheck, wg-tunnel"

# --- backhaul program: prebuilt binary first, build from source only as a fallback
# shellcheck source=/dev/null
source "$DEST/backhaul-helper.sh"
mkdir -p "$BH_DIR"
if [[ -x $BH_BIN ]] && [[ -z ${TUNXALL_REINSTALL:-} ]]; then
  ok "Backhaul already installed"
elif bh_download_release >>"$LOGFILE" 2>&1; then
  ok "Downloaded backhaul ($(bh_arch))"
else
  warn "No prebuilt backhaul for this server — building it from source (one time, a few minutes)..."
  rm -rf "$DEST/backhaul"
  if curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$BRANCH" \
      | tar -xz -C "$DEST" --strip-components=1 --wildcards '*/backhaul/*' \
     && bh_build_from_source >>"$LOGFILE" 2>&1; then
    ok "Built backhaul from source"
  else
    warn "Backhaul is not available yet (details: $LOGFILE). Other tunnel types still work."
  fi
fi

echo
echo -e "  ${G}${B}Installed!${N}  Open the menu any time with:  ${CY}${B}sudo abtunnel${N}"
echo

# auto-open the menu (read from the real terminal even when piped via curl)
if [[ -z ${TUNXALL_NO_MENU:-} ]] && [ -e /dev/tty ] && [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then
  sleep 1
  abtunnel </dev/tty
fi
