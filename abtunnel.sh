#!/usr/bin/env bash
# abtunnel.sh — Standard encrypted tunnels between two servers you own.
#
# Pick ONE standard transport (no obfuscation, no auto protocol-switching):
#
#   stunnel  — forward a TCP service over real TLS (cert-pinned).
#   ssh      — persistent port-forward over SSH (autossh + systemd).
#   ipsec    — host-to-host encrypted link via strongSwan (PSK, transport mode).
#   gre      — GRE point-to-point interface over IPv4 (inner IPv4).
#   ipip     — IPIP point-to-point interface over IPv4 (inner IPv4).
#   sit      — 6in4: IPv6 over an IPv4 endpoint.
#   gre6     — GRE over an IPv6 endpoint (inner IPv6).
#   ip6ip6   — IPv6-in-IPv6.
#   openvpn  — point-to-point OpenVPN tunnel (static key, AES-256).
#   (WireGuard lives in wg-tunnel.sh.)
# For gre/ipip/sit/gre6/ip6ip6: add --psk to encrypt with IPsec, or omit for plain.
#
# Every tunnel runs under systemd with aggressive auto-restart, and an optional
# health watchdog restarts it if the link stops passing traffic.
#
# Quick start:   sudo bash abtunnel.sh menu
# Direct:        sudo bash abtunnel.sh <type> <server|client> [flags]
# Watchdog:      sudo bash abtunnel.sh health --unit <unit> --watch-ip <ip>|--watch-port <port>
# Status/down:   sudo bash abtunnel.sh status | down <type>
set -euo pipefail

DIR=/etc/abtunnel
PEER=""; ACCEPT_PORT=443; SERVICE_PORT=""; LOCAL_PORT=""; SSH_PORT=22
THOST=127.0.0.1; RPORT=""; PSK=""; PUBKEY=""; CERT=""; OVPN_PORT=1194
WATCH_IP=""; WATCH_PORT=""; UNIT=""

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
      --ovpn-port)    OVPN_PORT="$2"; shift 2;;
      --watch-ip)     WATCH_IP="$2"; shift 2;;
      --watch-port)   WATCH_PORT="$2"; shift 2;;
      --unit)         UNIT="$2"; shift 2;;
      *) die "Unknown flag: $1";;
    esac
  done
}

ip_family() { case "$1" in *:*) echo 6;; *) echo 4;; esac; }
local_ip_to() { local f; f=$(ip_family "$1"); ip -"$f" route get "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}'; }

mkunit() { # name execstart...
  local name="$1"; shift
  cat > "/etc/systemd/system/$name.service" <<EOF
[Unit]
Description=abtunnel $name
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

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

mkoneshot() { # name upscript downscript
  local name="$1" up="$2" down="$3"
  cat > "/etc/systemd/system/$name.service" <<EOF
[Unit]
Description=abtunnel $name
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$up
ExecStop=$down
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$name.service" >/dev/null 2>&1 || true
  systemctl restart "$name.service"
}

stunnel_bin() { command -v stunnel4 || command -v stunnel || die "stunnel not found"; }

# ----------------------------------------------------------------- stunnel
stunnel_server() {
  need_root; apt_install stunnel4 openssl; mkdir -p $DIR && chmod 700 $DIR
  [[ -n $SERVICE_PORT ]] || die "stunnel server needs --service-port (local TCP service on B to expose)"
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
  log "stunnel server up: TLS :$ACCEPT_PORT -> 127.0.0.1:$SERVICE_PORT"
  echo -e "${c_y}Copy this cert to A as /etc/abtunnel/server-cert.pem:${c_0}"
  echo "----8<----"; cat $DIR/server-cert.pem; echo "----8<----"
  echo "On A:  sudo bash abtunnel.sh stunnel client --peer <B_IP> --accept-port $ACCEPT_PORT --local-port <LPORT> --cert /etc/abtunnel/server-cert.pem"
}

stunnel_client() {
  need_root; apt_install stunnel4; mkdir -p $DIR && chmod 700 $DIR
  [[ -n $PEER ]] || die "need --peer <B_IP>"
  [[ -n $LOCAL_PORT ]] || die "need --local-port"
  [[ -n $CERT && -f $CERT ]] || die "need --cert <server-cert.pem copied from B>"
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
  log "Health watchdog:  sudo bash abtunnel.sh health --unit abtunnel-stunnel --watch-port $LOCAL_PORT"
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
    warn "Re-run with --pubkey \"<A_PUBLIC_KEY>\" once A prints it."
  fi
}

ssh_client() {
  need_root; apt_install autossh openssh-client; mkdir -p $DIR && chmod 700 $DIR
  [[ -n $PEER ]] || die "need --peer <B_IP>"
  [[ -n $LOCAL_PORT ]] || die "need --local-port"
  [[ -n $RPORT ]] || die "need --remote-port"
  [[ -f $DIR/id_ed25519 ]] || ssh-keygen -t ed25519 -N "" -f $DIR/id_ed25519 >/dev/null
  mkunit abtunnel-ssh \
    "/usr/bin/autossh -M 0 -N -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
-o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
-i $DIR/id_ed25519 -p $SSH_PORT -L $LOCAL_PORT:$THOST:$RPORT root@$PEER"
  log "ssh tunnel up: 127.0.0.1:$LOCAL_PORT -> ($PEER:$SSH_PORT) -> $THOST:$RPORT"
  echo -e "${c_y}Give B this key:${c_0}"; echo "----8<----"; cat $DIR/id_ed25519.pub; echo "----8<----"
  echo "On B:  sudo bash abtunnel.sh ssh server --pubkey \"$(cat $DIR/id_ed25519.pub)\""
}

# ------------------------------------------------------------------- ipsec
ipsec_setup() {
  local role="$1"; need_root; apt_install strongswan openssl
  [[ -n $PEER ]] || die "need --peer <other server's public IP>"
  local myip; myip=$(local_ip_to "$PEER"); [[ -n $myip ]] || die "cannot find local IP toward $PEER"
  if [[ $role == server ]]; then PSK=${PSK:-$(openssl rand -hex 24)}; log "IPsec PSK (give to the other side):  $PSK"
  else [[ -n $PSK ]] || die "client needs --psk <value from server>"; fi
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
  echo "$myip $PEER : PSK \"$PSK\"" > /etc/ipsec.secrets; chmod 600 /etc/ipsec.secrets
  systemctl enable strongswan-starter >/dev/null 2>&1 || systemctl enable strongswan >/dev/null 2>&1 || true
  (ipsec restart || systemctl restart strongswan-starter || systemctl restart strongswan) >/dev/null 2>&1 || true
  sleep 2
  log "IPsec transport link configured between $myip and $PEER. Check: sudo ipsec status"
}

# ----------------------------------------- gre / ipip / sit / gre6 / ip6ip6
# Point-to-point interface tunnels. Endpoints may be IPv4 (gre/ipip/sit) or
# IPv6 (gre6/ip6ip6); inner address is IPv4 (gre/ipip) or IPv6 (sit/gre6/ip6ip6).
# Encrypted with IPsec when --psk is given, otherwise plain (unencrypted).
iface_tunnel_setup() { # kind role
  local kind="$1" role="$2"; need_root; apt_install iproute2
  [[ -n $PEER ]] || die "need --peer <other server's endpoint IP>"
  local fam myip ifn linkargs mod inner mtu=1400 myaddr peeraddr NET="" NET6=""
  fam=$(ip_family "$PEER"); myip=$(local_ip_to "$PEER"); [[ -n $myip ]] || die "cannot find local IP toward $PEER"
  case "$kind" in
    gre)    ifn=gre1;  linkargs="gre";                mod=ip_gre;     inner=4; NET=10.20.0;;
    ipip)   ifn=ipip1; linkargs="ipip";               mod=ipip;       inner=4; NET=10.40.0;;
    sit)    ifn=sit1;  linkargs="sit";                 mod=sit;        inner=6; NET6=fd60::;;
    gre6)   ifn=gre6;  linkargs="ip6gre";              mod=ip6_gre;    inner=6; NET6=fd20::;;
    ip6ip6) ifn=ip6t1; linkargs="ip6tnl mode ip6ip6";  mod=ip6_tunnel; inner=6; NET6=fd40::;;
    *) die "unknown tunnel kind: $kind";;
  esac
  if [[ $inner == 4 ]]; then
    if [[ $role == server ]]; then myaddr="$NET.1/30"; peeraddr="$NET.2"; else myaddr="$NET.2/30"; peeraddr="$NET.1"; fi
  else
    if [[ $role == server ]]; then myaddr="${NET6}1/126"; peeraddr="${NET6}2"; else myaddr="${NET6}2/126"; peeraddr="${NET6}1"; fi
  fi

  if [[ -n $PSK ]]; then
    log "Encrypting the $kind link with IPsec first..."
    ipsec_setup "$role"
  else
    warn "No --psk: the $kind tunnel is UNENCRYPTED (plain). Add --psk to protect it with IPsec."
  fi

  cat > $DIR/$ifn-up.sh <<EOF
#!/usr/bin/env bash
modprobe $mod 2>/dev/null || true
ip link del $ifn 2>/dev/null || true
ip link add $ifn type $linkargs local $myip remote $PEER
ip addr add $myaddr dev $ifn
ip link set $ifn mtu $mtu up
EOF
  cat > $DIR/$ifn-down.sh <<EOF
#!/usr/bin/env bash
ip link set $ifn down 2>/dev/null || true
ip link del $ifn 2>/dev/null || true
EOF
  mkdir -p $DIR; chmod +x $DIR/$ifn-up.sh $DIR/$ifn-down.sh
  mkoneshot "abtunnel-$kind" "$DIR/$ifn-up.sh" "$DIR/$ifn-down.sh"
  log "$kind tunnel up: this side ${myaddr%/*} <-> peer $peeraddr (iface $ifn, endpoints over IPv$fam)"
  log "Test:  ping$([[ $inner == 6 ]] && echo ' -6') -c3 $peeraddr"
  log "Watchdog:  sudo bash abtunnel.sh health --unit abtunnel-$kind --watch-ip $peeraddr"
}

# ----------------------------------------------------------------- openvpn
openvpn_server() {
  need_root; apt_install openvpn; mkdir -p $DIR && chmod 700 $DIR
  [[ -f $DIR/ovpn.key ]] || openvpn --genkey secret $DIR/ovpn.key 2>/dev/null || openvpn --genkey --secret $DIR/ovpn.key
  cat > $DIR/ovpn.conf <<EOF
dev tun
proto udp
port $OVPN_PORT
ifconfig 10.30.0.1 10.30.0.2
secret $DIR/ovpn.key
cipher AES-256-CBC
auth SHA256
keepalive 10 60
persist-key
persist-tun
EOF
  mkunit abtunnel-openvpn "$(command -v openvpn) --config $DIR/ovpn.conf"
  log "OpenVPN server up on udp/$OVPN_PORT, private IP 10.30.0.1"
  echo -e "${c_y}Copy this key to A as /etc/abtunnel/ovpn.key:${c_0}"
  echo "----8<----"; cat $DIR/ovpn.key; echo "----8<----"
  echo "On A:  sudo bash abtunnel.sh openvpn client --peer <B_IP> --ovpn-port $OVPN_PORT --cert /etc/abtunnel/ovpn.key"
}

openvpn_client() {
  need_root; apt_install openvpn; mkdir -p $DIR && chmod 700 $DIR
  [[ -n $PEER ]] || die "need --peer <B_IP>"
  [[ -n $CERT && -f $CERT ]] || die "need --cert <ovpn.key copied from B>"
  cp "$CERT" $DIR/ovpn.key; chmod 600 $DIR/ovpn.key
  cat > $DIR/ovpn.conf <<EOF
dev tun
proto udp
remote $PEER $OVPN_PORT
ifconfig 10.30.0.2 10.30.0.1
secret $DIR/ovpn.key
cipher AES-256-CBC
auth SHA256
keepalive 10 60
persist-key
persist-tun
EOF
  mkunit abtunnel-openvpn "$(command -v openvpn) --config $DIR/ovpn.conf"
  log "OpenVPN client up, private IP 10.30.0.2 (peer 10.30.0.1)"
  log "Test:  ping -c3 10.30.0.1"
  log "Health watchdog:  sudo bash abtunnel.sh health --unit abtunnel-openvpn --watch-ip 10.30.0.1"
}

# ----------------------------------------------------- health watchdog
health_install() {
  need_root; mkdir -p $DIR
  [[ -n $UNIT ]] || die "need --unit <systemd unit, e.g. abtunnel-gre>"
  [[ -n $WATCH_IP || -n $WATCH_PORT ]] || die "need --watch-ip <ip> or --watch-port <local tcp port>"
  local mode target
  if [[ -n $WATCH_IP ]]; then mode=ip; target=$WATCH_IP; else mode=port; target=$WATCH_PORT; fi
  cat > "$DIR/health-$UNIT.env" <<EOF
UNIT=$UNIT
MODE=$mode
TARGET=$target
EOF
  cat > $DIR/healthcheck.sh <<'EOF'
#!/usr/bin/env bash
for f in /etc/abtunnel/health-*.env; do
  [[ -e $f ]] || continue
  UNIT=""; MODE=""; TARGET=""; . "$f"
  ok=1
  if [[ $MODE == ip ]]; then
    ping -c2 -W2 "$TARGET" >/dev/null 2>&1 || ok=0
  else
    timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/$TARGET" 2>/dev/null || ok=0
  fi
  if [[ $ok -eq 0 ]]; then
    logger -t abtunnel-health "restarting $UNIT (health check to $TARGET failed)"
    systemctl restart "$UNIT"
  fi
done
EOF
  chmod +x $DIR/healthcheck.sh
  cat > /etc/systemd/system/abtunnel-health.service <<EOF
[Unit]
Description=abtunnel health watchdog
[Service]
Type=oneshot
ExecStart=$DIR/healthcheck.sh
EOF
  cat > /etc/systemd/system/abtunnel-health.timer <<EOF
[Unit]
Description=abtunnel health watchdog timer
[Timer]
OnBootSec=30
OnUnitActiveSec=30
AccuracySec=5
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now abtunnel-health.timer
  log "Watchdog active: every 30s it checks $target ($mode) and restarts $UNIT if the link is down."
}

# -------------------------------------------------------------------- misc
cmd_status() {
  echo "== abtunnel units =="; systemctl --no-pager --type=service 2>/dev/null | grep -E 'abtunnel|strongswan|ipsec|openvpn' || echo "  (none)"
  echo "== watchdog =="; systemctl --no-pager list-timers abtunnel-health.timer 2>/dev/null | head -2 || true
  echo "== ipsec =="; ipsec status 2>/dev/null || echo "  (strongSwan not active)"
  echo "== tunnel interfaces =="; ip -brief addr show 2>/dev/null | grep -E 'gre1|ipip1|sit1|gre6|ip6t1|tun|wg0' || echo "  (none)"
}

cmd_down() {
  case "${1:-}" in
    stunnel) systemctl disable --now abtunnel-stunnel.service 2>/dev/null || true;;
    ssh)     systemctl disable --now abtunnel-ssh.service 2>/dev/null || true;;
    openvpn) systemctl disable --now abtunnel-openvpn.service 2>/dev/null || true;;
    gre)     systemctl disable --now abtunnel-gre.service 2>/dev/null || true;;
    ipip)    systemctl disable --now abtunnel-ipip.service 2>/dev/null || true;;
    sit)     systemctl disable --now abtunnel-sit.service 2>/dev/null || true;;
    gre6)    systemctl disable --now abtunnel-gre6.service 2>/dev/null || true;;
    ip6ip6)  systemctl disable --now abtunnel-ip6ip6.service 2>/dev/null || true;;
    ipsec)   ipsec stop 2>/dev/null || systemctl stop strongswan-starter 2>/dev/null || systemctl stop strongswan 2>/dev/null || true;;
    *) die "Usage: down <stunnel|ssh|ipsec|gre|ipip|sit|gre6|ip6ip6|openvpn>";;
  esac
  log "stopped: ${1:-}"
}

# -------------------------------------------------------------------- menu
menu() {
  need_root
  echo "=============================================="
  echo " abtunnel — standard encrypted tunnel setup"
  echo "=============================================="
  echo "Role:  1) server (public IP, receives)   2) client (connects out)"
  read -rp "Role [1-2]: " r
  echo "Type:"
  echo "  1) stunnel (TLS)      2) ssh            3) ipsec          6) openvpn"
  echo "  4) gre  5) ipip  7) sit (6in4)  8) gre6 (GRE/IPv6)  9) ip6ip6"
  echo "     (for 4/5/7/8/9: enter a shared PSK to encrypt with IPsec, or leave blank for plain)"
  read -rp "Type [1-9]: " t
  local kmap_s="" kmap_c=""
  case "$r-$t" in
    1-1) read -rp "Public TLS port [443]: " ACCEPT_PORT; ACCEPT_PORT=${ACCEPT_PORT:-443}; read -rp "Local service port to expose: " SERVICE_PORT; stunnel_server;;
    2-1) read -rp "B public IP: " PEER; read -rp "Public TLS port [443]: " ACCEPT_PORT; ACCEPT_PORT=${ACCEPT_PORT:-443}; read -rp "Local port on A: " LOCAL_PORT; read -rp "server-cert.pem path: " CERT; stunnel_client;;
    1-2) read -rp "A's public key (blank to add later): " PUBKEY; ssh_server;;
    2-2) read -rp "SSH port on B [22]: " SSH_PORT; SSH_PORT=${SSH_PORT:-22}; read -rp "B public IP: " PEER; read -rp "Local port on A: " LOCAL_PORT; read -rp "Remote host [127.0.0.1]: " THOST; THOST=${THOST:-127.0.0.1}; read -rp "Remote port: " RPORT; ssh_client;;
    1-3) read -rp "A public IP: " PEER; ipsec_setup server;;
    2-3) read -rp "B public IP: " PEER; read -rp "PSK from B: " PSK; ipsec_setup client;;
    1-4|1-5|1-7|1-8|1-9) kmap_s=1;;
    2-4|2-5|2-7|2-8|2-9) kmap_c=1;;
    1-6) read -rp "OpenVPN udp port [1194]: " OVPN_PORT; OVPN_PORT=${OVPN_PORT:-1194}; openvpn_server;;
    2-6) read -rp "B public IP: " PEER; read -rp "OpenVPN udp port [1194]: " OVPN_PORT; OVPN_PORT=${OVPN_PORT:-1194}; read -rp "ovpn.key path: " CERT; openvpn_client;;
    *) die "invalid selection";;
  esac
  if [[ -n $kmap_s$kmap_c ]]; then
    local kind
    case "$t" in 4) kind=gre;; 5) kind=ipip;; 7) kind=sit;; 8) kind=gre6;; 9) kind=ip6ip6;; esac
    if [[ -n $kmap_s ]]; then
      read -rp "Other server (peer) endpoint IP: " PEER
      read -rp "Shared PSK (blank = unencrypted/plain): " PSK; iface_tunnel_setup "$kind" server
    else
      read -rp "Other server (peer) endpoint IP: " PEER
      read -rp "Shared PSK (same value as the other side; blank = plain): " PSK; iface_tunnel_setup "$kind" client
    fi
  fi
}

main() {
  local a="${1:-}"; shift || true
  case "$a" in
    menu) menu;;
    status) cmd_status;;
    down) cmd_down "${1:-}";;
    health) parse_args "$@"; health_install;;
    stunnel) local role="${1:-}"; shift || true; parse_args "$@"; [[ $role == server ]] && stunnel_server || stunnel_client;;
    ssh)     local role="${1:-}"; shift || true; parse_args "$@"; [[ $role == server ]] && ssh_server || ssh_client;;
    ipsec)   local role="${1:-}"; shift || true; parse_args "$@"; ipsec_setup "$role";;
    gre)     local role="${1:-}"; shift || true; parse_args "$@"; iface_tunnel_setup gre "$role";;
    ipip)    local role="${1:-}"; shift || true; parse_args "$@"; iface_tunnel_setup ipip "$role";;
    sit)     local role="${1:-}"; shift || true; parse_args "$@"; iface_tunnel_setup sit "$role";;
    gre6)    local role="${1:-}"; shift || true; parse_args "$@"; iface_tunnel_setup gre6 "$role";;
    ip6ip6)  local role="${1:-}"; shift || true; parse_args "$@"; iface_tunnel_setup ip6ip6 "$role";;
    openvpn) local role="${1:-}"; shift || true; parse_args "$@"; [[ $role == server ]] && openvpn_server || openvpn_client;;
    *) echo "Usage: $0 {menu|stunnel|ssh|ipsec|gre|ipip|sit|gre6|ip6ip6|openvpn|health|status|down} ..."; echo "Easiest:  sudo bash $0 menu"; exit 1;;
  esac
}
main "$@"
