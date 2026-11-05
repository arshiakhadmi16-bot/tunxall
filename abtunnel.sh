#!/usr/bin/env bash
# abtunnel.sh — Standard encrypted tunnels between two servers you own.
#
# Three independent, standard transports you pick from a menu (no obfuscation,
# no auto protocol-switching — you choose one and it connects):
#
#   1) stunnel  — forward a TCP service over real TLS 1.3 (cert-pinned).
#   2) ssh      — persistent port-forward over SSH (autossh + systemd).
#   3) ipsec    — host-to-host encrypted link via strongSwan (PSK, transport mode).
#
# Each runs under systemd with auto-restart so it survives drops and reboots.
#
# Quick start:   sudo bash abtunnel.sh menu
# Direct use:    sudo bash abtunnel.sh <stunnel|ssh|ipsec> <server|client> [flags]
# Teardown:      sudo bash abtunnel.sh down <stunnel|ssh|ipsec>
# Status:        sudo bash abtunnel.sh status
set -euo pipefail

DIR=/etc/abtunnel
PEER=""; ACCEPT_PORT=443; SERVICE_PORT=""; LOCAL_PORT=""; SSH_PORT=22
THOST=127.0.0.1; RPORT=""; PSK=""; PUBKEY=""; CERT=""

c_g="\e[32m"; c_r="\e[31m"; c_y="\e[33m"; c_0="\e[0m"
log()  { echo -e "${c_g}[+]${c_0} $*"; }
warn() { echo -e "${c_y}[!]${c_0} $*"; }
die()  { echo -e "${c_r}[x]${c_0} $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || warn "apt update had warnings"
  apt-get install -y -qq "$@" >/dev/null || die "Failed to install: $*"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --peer)         PEER="$2"; shift 2;;
      --accept-port)  ACCEPT_PORT="$2"; shift 2;;
      --service-port) SERVICE_PORT="$2"; shift 2;;
      --local-port)   LOCAL_PORT="$2"; shift 2;;
      --ssh-port)     SSH_PORT="$2"; shift 2;;
      --target-host)  THOST="$2"; shift 2;;
      --remote-port)  RPORT="$2"; shift 2;;
      --psk)          PSK="$2"; shift 2;;
      --pubkey)       PUBKEY="$2"; shift 2;;
      --cert)         CERT="$2"; shift 2;;
      *) die "Unknown flag: $1";;
    esac
  done
}

mkunit() { # name execstart
  local name="$1"; shift
  cat > "/etc/systemd/system/$name.service" <<EOF
[Unit]
Description=abtunnel $name
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$*
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$name.service"
  systemctl restart "$name.service"
}

stunnel_bin() { command -v stunnel4 || command -v stunnel || die "stunnel not found"; }

# ----------------------------------------------------------------- stunnel
stunnel_server() {
  need_root; apt_install stunnel4 openssl
  mkdir -p $DIR && chmod 700 $DIR
  [[ -n $SERVICE_PORT ]] || die "stunnel server needs --service-port (the local TCP service on B to expose)"
  if [[ ! -f $DIR/server.pem ]]; then
    openssl req -new -x509 -days 3650 -nodes -newkey rsa:2048 \
      -keyout $DIR/server.pem -out $DIR/server.pem -subj "/CN=abtunnel" >/dev/null 2>&1
    openssl x509 -in $DIR/server.pem -out $DIR/server-cert.pem >/dev/null 2>&1
    chmod 600 $DIR/server.pem
  fi
  cat > $DIR/stunnel.conf <<EOF
foreground = yes
pid =
[tunnel]
accept = 0.0.0.0:$ACCEPT_PORT
connect = 127.0.0.1:$SERVICE_PORT
cert = $DIR/server.pem
EOF
  mkunit abtunnel-stunnel "$(stunnel_bin) $DIR/stunnel.conf"
  log "stunnel server up: TLS on :$ACCEPT_PORT -> 127.0.0.1:$SERVICE_PORT"
  echo -e "${c_y}Copy this cert to A as /etc/abtunnel/server-cert.pem, then run the client:${c_0}"
  echo "----8<---- $DIR/server-cert.pem ----8<----"
  cat $DIR/server-cert.pem
  echo "----8<-------------------------------------8<----"
  echo "On A:  sudo bash abtunnel.sh stunnel client --peer <B_IP> --accept-port $ACCEPT_PORT --local-port <LPORT> --cert /etc/abtunnel/server-cert.pem"
}

stunnel_client() {
  need_root; apt_install stunnel4
  mkdir -p $DIR && chmod 700 $DIR
  [[ -n $PEER ]] || die "need --peer <B_IP>"
  [[ -n $LOCAL_PORT ]] || die "need --local-port (where the tunneled service appears on A)"
  [[ -n $CERT && -f $CERT ]] || die "need --cert <path to server-cert.pem copied from B>"
  cp "$CERT" $DIR/server-cert.pem
  cat > $DIR/stunnel.conf <<EOF
foreground = yes
pid =
client = yes
verify = 4
CAfile = $DIR/server-cert.pem
[tunnel]
accept = 127.0.0.1:$LOCAL_PORT
connect = $PEER:$ACCEPT_PORT
EOF
  mkunit abtunnel-stunnel "$(stunnel_bin) $DIR/stunnel.conf"
  log "stunnel client up: 127.0.0.1:$LOCAL_PORT -> TLS -> $PEER:$ACCEPT_PORT"
  log "Point your app on A at 127.0.0.1:$LOCAL_PORT"
}

# --------------------------------------------------------------------- ssh
ssh_server() {
  need_root
  if [[ -n $PUBKEY ]]; then
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    grep -qxF "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$PUBKEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    log "Added A's public key to /root/.ssh/authorized_keys"
  else
    log "SSH server side just needs sshd (already running) and A's key."
    warn "Re-run with --pubkey \"<A_PUBLIC_KEY>\" once A prints it, or paste it into /root/.ssh/authorized_keys."
  fi
  log "Ensure sshd listens on port $SSH_PORT and that port is open."
}

ssh_client() {
  need_root; apt_install autossh openssh-client
  mkdir -p $DIR && chmod 700 $DIR
  [[ -n $PEER ]] || die "need --peer <B_IP>"
  [[ -n $LOCAL_PORT ]] || die "need --local-port (local port on A)"
  [[ -n $RPORT ]] || die "need --remote-port (service port reachable from B, e.g. a DB port)"
  if [[ ! -f $DIR/id_ed25519 ]]; then
    ssh-keygen -t ed25519 -N "" -f $DIR/id_ed25519 >/dev/null
  fi
  mkunit abtunnel-ssh \
    "/usr/bin/autossh -M 0 -N -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
-o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
-i $DIR/id_ed25519 -p $SSH_PORT -L $LOCAL_PORT:$THOST:$RPORT root@$PEER"
  log "ssh tunnel up: 127.0.0.1:$LOCAL_PORT -> (via $PEER:$SSH_PORT) -> $THOST:$RPORT"
  echo -e "${c_y}Give B this public key so it accepts the tunnel:${c_0}"
  echo "----8<----"
  cat $DIR/id_ed25519.pub
  echo "----8<----"
  echo "On B:  sudo bash abtunnel.sh ssh server --pubkey \"$(cat $DIR/id_ed25519.pub)\""
}

# ------------------------------------------------------------------- ipsec
ipsec_setup() {
  local role="$1"
  need_root; apt_install strongswan
  [[ -n $PEER ]] || die "need --peer <other server's public IP>"
  local myip
  myip=$(ip -4 route get "$PEER" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
  [[ -n $myip ]] || die "could not determine local IP toward $PEER"
  if [[ $role == server ]]; then
    PSK=${PSK:-$(openssl rand -hex 24)}
    log "Generated PSK (give this to A):  $PSK"
  else
    [[ -n $PSK ]] || die "client needs --psk <value printed by B>"
  fi
  cat > /etc/ipsec.conf <<EOF
config setup
  charondebug="ike 1, knl 1"

conn abtunnel
  authby=secret
  auto=start
  type=transport
  keyexchange=ikev2
  left=$myip
  right=$PEER
  ike=aes256-sha256-modp2048!
  esp=aes256gcm16!
  dpdaction=restart
  closeaction=restart
EOF
  cat > /etc/ipsec.secrets <<EOF
$myip $PEER : PSK "$PSK"
EOF
  chmod 600 /etc/ipsec.secrets
  systemctl enable strongswan-starter >/dev/null 2>&1 || systemctl enable strongswan >/dev/null 2>&1 || true
  (ipsec restart || systemctl restart strongswan-starter || systemctl restart strongswan) >/dev/null 2>&1 || true
  sleep 2
  log "IPsec transport-mode link configured between $myip and $PEER."
  log "All IP traffic between the two servers is now encrypted. Check: sudo ipsec status"
}

# -------------------------------------------------------------------- misc
cmd_status() {
  echo "== systemd units =="; systemctl --no-pager --type=service 2>/dev/null | grep -E 'abtunnel|strongswan|ipsec' || echo "  (none)"
  echo "== ipsec =="; ipsec status 2>/dev/null || echo "  (strongSwan not active)"
}

cmd_down() {
  local what="${1:-}"
  case "$what" in
    stunnel) systemctl disable --now abtunnel-stunnel.service 2>/dev/null || true;;
    ssh)     systemctl disable --now abtunnel-ssh.service 2>/dev/null || true;;
    ipsec)   ipsec stop 2>/dev/null || systemctl stop strongswan-starter 2>/dev/null || systemctl stop strongswan 2>/dev/null || true;;
    *) die "Usage: down <stunnel|ssh|ipsec>";;
  esac
  log "stopped: $what"
}

# -------------------------------------------------------------------- menu
menu() {
  need_root
  echo "=============================================="
  echo " abtunnel — standard encrypted tunnel setup"
  echo "=============================================="
  echo "Role:"; echo "  1) server (the side with a public IP that receives)"; echo "  2) client (the side that connects out)"
  read -rp "Choose role [1-2]: " r
  echo "Tunnel type:"; echo "  1) stunnel (TLS TCP forward)"; echo "  2) ssh (port-forward)"; echo "  3) ipsec (host-to-host)"
  read -rp "Choose type [1-3]: " t
  case "$r-$t" in
    1-1) read -rp "Public TLS port [443]: " ACCEPT_PORT; ACCEPT_PORT=${ACCEPT_PORT:-443}
         read -rp "Local service port to expose (e.g. 3306): " SERVICE_PORT; stunnel_server;;
    2-1) read -rp "B public IP: " PEER; read -rp "Public TLS port [443]: " ACCEPT_PORT; ACCEPT_PORT=${ACCEPT_PORT:-443}
         read -rp "Local port on A: " LOCAL_PORT; read -rp "Path to server-cert.pem from B: " CERT; stunnel_client;;
    2-2) read -rp "SSH port on B [22]: " SSH_PORT; SSH_PORT=${SSH_PORT:-22}
         read -rp "B public IP: " PEER; read -rp "Local port on A: " LOCAL_PORT
         read -rp "Remote service host [127.0.0.1]: " THOST; THOST=${THOST:-127.0.0.1}
         read -rp "Remote service port: " RPORT; ssh_client;;
    1-2) read -rp "Paste A's public key (or leave blank to add later): " PUBKEY; ssh_server;;
    1-3) read -rp "Other server (A) public IP: " PEER; ipsec_setup server;;
    2-3) read -rp "Other server (B) public IP: " PEER; read -rp "PSK from B: " PSK; ipsec_setup client;;
    *) die "invalid selection";;
  esac
}

main() {
  local a="${1:-}"; shift || true
  case "$a" in
    menu) menu;;
    status) cmd_status;;
    down) cmd_down "${1:-}";;
    stunnel) local role="${1:-}"; shift || true; parse_args "$@"; [[ $role == server ]] && stunnel_server || stunnel_client;;
    ssh)     local role="${1:-}"; shift || true; parse_args "$@"; [[ $role == server ]] && ssh_server || ssh_client;;
    ipsec)   local role="${1:-}"; shift || true; parse_args "$@"; ipsec_setup "$role";;
    *) echo "Usage: $0 {menu|stunnel|ssh|ipsec|status|down} ..."; echo "Easiest:  sudo bash $0 menu"; exit 1;;
  esac
}
main "$@"
