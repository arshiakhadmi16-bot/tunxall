#!/usr/bin/env bash
# wg-tunnel.sh — Standard encrypted WireGuard link between two servers you own.
#
# Creates a private network (10.10.0.0/24) between server B (endpoint, public IP)
# and server A (client). After it is up, any service can talk over the private IPs:
#   B = 10.10.0.1    A = 10.10.0.2
#
# This is a plain, standard WireGuard tunnel on a port you choose (one that netcheck.sh
# reported OPEN). No obfuscation, no evasion — just an encrypted point-to-point link.
#
# Usage:
#   On B (run first): sudo bash wg-tunnel.sh server [--port 51820]
#       -> prints a ready-to-paste command to run on A, including B's public key.
#   On A:             sudo bash wg-tunnel.sh client --endpoint <B_IP> --port <PORT> --pubkey <B_PUBKEY>
#   Status / stop:    sudo bash wg-tunnel.sh status   |   sudo bash wg-tunnel.sh down
set -euo pipefail

WG_IF=wg0
WG_DIR=/etc/wireguard
CONF=$WG_DIR/$WG_IF.conf
NET=10.10.0
PORT=51820
ENDPOINT=""
PEER_PUB=""

c_g="\e[32m"; c_r="\e[31m"; c_y="\e[33m"; c_0="\e[0m"
log()  { echo -e "${c_g}[+]${c_0} $*"; }
warn() { echo -e "${c_y}[!]${c_0} $*"; }
die()  { echo -e "${c_r}[x]${c_0} $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)     PORT="$2"; shift 2;;
      --endpoint) ENDPOINT="$2"; shift 2;;
      --pubkey)   PEER_PUB="$2"; shift 2;;
      *) die "Unknown arg: $1";;
    esac
  done
}

install_wg() {
  command -v wg >/dev/null 2>&1 && return
  log "Installing WireGuard..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq wireguard wireguard-tools >/dev/null \
    || die "WireGuard install failed. Install manually: apt install wireguard"
}

gen_keys() {
  mkdir -p $WG_DIR && chmod 700 $WG_DIR
  if [[ ! -f $WG_DIR/privatekey ]]; then
    umask 077
    wg genkey | tee $WG_DIR/privatekey | wg pubkey > $WG_DIR/publickey
  fi
  PRIV=$(cat $WG_DIR/privatekey)
  PUB=$(cat $WG_DIR/publickey)
}

# ---------------------------------------------------------------- server (B)
cmd_server() {
  need_root; install_wg; gen_keys
  local ip; ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
  cat > $CONF <<EOF
[Interface]
Address = $NET.1/24
ListenPort = $PORT
PrivateKey = $PRIV

# Peer A is added automatically after A sends its public key (see note below).
EOF
  chmod 600 $CONF
  # enable IPv4 forwarding so services can route over the link if needed
  sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  sysctl -q -p >/dev/null 2>&1 || true

  systemctl enable --now "wg-quick@$WG_IF" >/dev/null 2>&1 || wg-quick up $WG_IF || true
  wg-quick down $WG_IF >/dev/null 2>&1 || true
  wg-quick up $WG_IF

  echo
  log "Server B is up. Private IP: $NET.1"
  echo -e "${c_y}Run this on server A:${c_0}"
  echo
  echo "  sudo bash wg-tunnel.sh client --endpoint ${ip:-<B_PUBLIC_IP>} --port $PORT --pubkey $PUB"
  echo
  warn "After A connects it will print ITS public key. Add A as a peer on B with:"
  echo "  sudo wg set $WG_IF peer <A_PUBKEY> allowed-ips $NET.2/32"
  echo "  (then it persists on reboot if you append the [Peer] block to $CONF)"
}

# ---------------------------------------------------------------- client (A)
cmd_client() {
  need_root
  [[ -n $ENDPOINT ]] || die "Need --endpoint <B_IP>"
  [[ -n $PEER_PUB ]] || die "Need --pubkey <B_PUBKEY>"
  install_wg; gen_keys
  cat > $CONF <<EOF
[Interface]
Address = $NET.2/24
PrivateKey = $PRIV

[Peer]
PublicKey = $PEER_PUB
Endpoint = $ENDPOINT:$PORT
AllowedIPs = $NET.0/24
PersistentKeepalive = 25
EOF
  chmod 600 $CONF
  wg-quick down $WG_IF >/dev/null 2>&1 || true
  wg-quick up $WG_IF
  echo
  log "Client A is up. Private IP: $NET.2"
  echo -e "${c_y}Give B this public key so it accepts you:${c_0}"
  echo "  sudo wg set $WG_IF peer $PUB allowed-ips $NET.2/32    # run on B"
  echo
  log "Then test the link from A:  ping -c3 $NET.1"
}

cmd_status() { wg show "$WG_IF" 2>/dev/null || warn "tunnel not up"; ip -4 addr show "$WG_IF" 2>/dev/null || true; }
cmd_down()   { wg-quick down $WG_IF 2>/dev/null && log "tunnel down" || warn "already down"; }

main() {
  local cmd="${1:-}"; shift || true
  parse_args "$@"
  case "$cmd" in
    server) cmd_server;;
    client) cmd_client;;
    status) cmd_status;;
    down)   cmd_down;;
    *) echo "Usage: $0 {server|client|status|down} [--endpoint IP] [--port N] [--pubkey KEY]"; exit 1;;
  esac
}
main "$@"
