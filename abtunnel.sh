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
#   backhaul — high-performance reverse tunnel (tcp/tcpmux/ws/wss/grpc/grpcs) with multi-server auto-select.
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

# Load backhaul helper if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/backhaul-helper.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/backhaul-helper.sh"
elif [[ -f /usr/local/lib/tunxall/backhaul-helper.sh ]]; then
  # shellcheck source=/dev/null
  source /usr/local/lib/tunxall/backhaul-helper.sh
fi

DIR=/etc/abtunnel
PEER=""; ACCEPT_PORT=443; SERVICE_PORT=""; LOCAL_PORT=""; SSH_PORT=22
THOST=127.0.0.1; RPORT=""; PSK=""; PUBKEY=""; CERT=""; OVPN_PORT=1194
WATCH_IP=""; WATCH_PORT=""; UNIT=""
PROTO=tcp; IN_PORT=""; TO=""; TO_PORT=""

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
      --proto)        PROTO="$2"; shift 2;;
      --in-port)      IN_PORT="$2"; shift 2;;
      --to)           TO="$2"; shift 2;;
      --to-port)      TO_PORT="$2"; shift 2;;
      --transport)    TRANSPORT="$2"; shift 2;;
      --ports)        PORTS="$2"; shift 2;;
      --peers)        PEERS="$2"; shift 2;;
      *) die "Unknown flag: $1";;
    esac
  done
}

ip_family() { case "$1" in *:*) echo 6;; *) echo 4;; esac; }
local_ip_to() { local f; f=$(ip_family "$1"); ip -"$f" route get "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}'; }
detect_pubip() {
  local ip
  ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  [[ -z $ip ]] && ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
  echo "$ip"
}

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

enable_forwarding() {
  cat > /etc/sysctl.d/99-abtunnel-fwd.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
  sysctl -q --system >/dev/null 2>&1 || true
  log "Kernel IP forwarding enabled (IPv4 + IPv6)."
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
  [[ "$CERT" -ef "$DIR/server-cert.pem" ]] || cp "$CERT" "$DIR/server-cert.pem"
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

  mkdir -p $DIR && chmod 700 $DIR
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
  chmod +x $DIR/$ifn-up.sh $DIR/$ifn-down.sh
  mkoneshot "abtunnel-$kind" "$DIR/$ifn-up.sh" "$DIR/$ifn-down.sh"
  enable_forwarding
  log "$kind tunnel up: this side ${myaddr%/*} <-> peer $peeraddr (iface $ifn, endpoints over IPv$fam)"
  log "Forward a service into the tunnel:  sudo bash abtunnel.sh forward --proto tcp --in-port <PORT> --to $peeraddr --to-port <PORT>"
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
  enable_forwarding
  log "OpenVPN server up on udp/$OVPN_PORT, private IP 10.30.0.1"
  local pub token
  pub=$(detect_pubip)
  token=$(printf 'T=openvpn;PEER=%s;PORT=%s;KEY=%s' "$pub" "$OVPN_PORT" "$(base64 -w0 $DIR/ovpn.key)" | base64 -w0)
  echo
  echo -e "${c_y}==================== CONNECTION TOKEN ====================${c_0}"
  echo "$token"
  echo -e "${c_y}==========================================================${c_0}"
  echo "On the CLIENT machine run:   sudo abtunnel connect <paste-token-here>"
  echo "or just run 'sudo abtunnel' on the client and choose option 2."
}

openvpn_client() {
  need_root; apt_install openvpn; mkdir -p $DIR && chmod 700 $DIR
  [[ -n $PEER ]] || die "need --peer <B_IP>"
  [[ -n $CERT && -f $CERT ]] || die "need --cert <ovpn.key copied from B>"
  [[ "$CERT" -ef "$DIR/ovpn.key" ]] || cp "$CERT" "$DIR/ovpn.key"
  chmod 600 "$DIR/ovpn.key"
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
  enable_forwarding
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

# ----------------------------------------------------- port forwarding
# DNAT a port on THIS server into the tunnel toward the peer's tunnel IP.
# Example: expose a DB that runs on the peer, reachable on this server's :3306.
cmd_forward() {
  need_root; apt_install iptables
  [[ -n $IN_PORT ]] || die "need --in-port <port to accept on this server>"
  [[ -n $TO ]] || die "need --to <peer tunnel IP>"
  [[ -n $TO_PORT ]] || die "need --to-port <service port on the peer>"
  case "$PROTO" in tcp|udp) :;; *) die "--proto must be tcp or udp";; esac
  mkdir -p $DIR
  local fam; fam=$(ip_family "$TO")
  cat > "$DIR/forward-$PROTO-$IN_PORT.rule" <<EOF
PROTO=$PROTO
IN_PORT=$IN_PORT
TO=$TO
TO_PORT=$TO_PORT
FAM=$fam
EOF
  cat > $DIR/forward-apply.sh <<'EOF'
#!/usr/bin/env bash
sysctl -q -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
sysctl -q -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
for f in /etc/abtunnel/forward-*.rule; do
  [[ -e $f ]] || continue
  PROTO=; IN_PORT=; TO=; TO_PORT=; FAM=; . "$f"
  if [[ $FAM == 6 ]]; then IPT=ip6tables; DEST="[$TO]:$TO_PORT"; else IPT=iptables; DEST="$TO:$TO_PORT"; fi
  $IPT -t nat -C PREROUTING -p "$PROTO" --dport "$IN_PORT" -j DNAT --to-destination "$DEST" 2>/dev/null \
    || $IPT -t nat -A PREROUTING -p "$PROTO" --dport "$IN_PORT" -j DNAT --to-destination "$DEST"
  $IPT -t nat -C POSTROUTING -p "$PROTO" -d "$TO" --dport "$TO_PORT" -j MASQUERADE 2>/dev/null \
    || $IPT -t nat -A POSTROUTING -p "$PROTO" -d "$TO" --dport "$TO_PORT" -j MASQUERADE
  $IPT -C FORWARD -p "$PROTO" -d "$TO" --dport "$TO_PORT" -j ACCEPT 2>/dev/null \
    || $IPT -A FORWARD -p "$PROTO" -d "$TO" --dport "$TO_PORT" -j ACCEPT
done
EOF
  chmod +x $DIR/forward-apply.sh
  cat > /etc/systemd/system/abtunnel-forward.service <<EOF
[Unit]
Description=abtunnel port forwarding
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$DIR/forward-apply.sh
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now abtunnel-forward.service
  systemctl restart abtunnel-forward.service
  log "Forwarding active: ${PROTO}/${IN_PORT} on this server -> tunnel -> ${TO}:${TO_PORT}"
  log "Persisted; re-applied on boot. Remove with:  sudo bash abtunnel.sh down forward"
}

# ----------------------------------------------------- full uninstall
cmd_uninstall() {
  need_root
  cmd_down forward 2>/dev/null || true
  systemctl disable --now abtunnel-stunnel abtunnel-ssh abtunnel-openvpn \
    abtunnel-gre abtunnel-ipip abtunnel-sit abtunnel-gre6 abtunnel-ip6ip6 \
    abtunnel-forward abtunnel-health.timer abtunnel-health abtunnel-backhaul 2>/dev/null || true
  ipsec stop 2>/dev/null || true
  systemctl stop strongswan-starter strongswan 2>/dev/null || true
  wg-quick down wg0 2>/dev/null || true
  local i; for i in tun0 gre1 ipip1 sit1 gre6 ip6t1 wg0; do ip link del "$i" 2>/dev/null || true; done
  rm -f /etc/systemd/system/abtunnel-*.service /etc/systemd/system/abtunnel-health.timer
  systemctl daemon-reload
  rm -rf /etc/abtunnel /opt/tunxall
  rm -f /etc/sysctl.d/99-abtunnel-fwd.conf /etc/wireguard/wg0.conf /etc/ipsec.conf /etc/ipsec.secrets
  rm -f /usr/local/bin/abtunnel /usr/local/bin/netcheck /usr/local/bin/wg-tunnel
  rm -rf /usr/local/lib/tunxall
  log "Fully removed: all tunnels, services, configs, and commands."
}

# -------------------------------------------------------------------- misc
cmd_status() {
  echo "== abtunnel units =="; systemctl --no-pager --type=service 2>/dev/null | grep -E 'abtunnel|strongswan|ipsec|openvpn|backhaul' || echo "  (none)"
  if command -v backhaul_status &>/dev/null || type backhaul_status &>/dev/null; then
    echo "== backhaul =="; backhaul_status || true
  fi
  echo "== watchdog =="; systemctl --no-pager list-timers abtunnel-health.timer 2>/dev/null | head -2 || true
  echo "== ipsec =="; ipsec status 2>/dev/null || echo "  (strongSwan not active)"
  echo "== tunnel interfaces =="; ip -brief addr show 2>/dev/null | grep -E 'gre1|ipip1|sit1|gre6|ip6t1|tun|wg0' || echo "  (none)"
  echo "== port forwards =="; ls $DIR/forward-*.rule >/dev/null 2>&1 && grep -H '' $DIR/forward-*.rule 2>/dev/null | sed 's/^/  /' || echo "  (none)"
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
    forward)
      for f in $DIR/forward-*.rule; do
        [[ -e $f ]] || continue
        PROTO=; IN_PORT=; TO=; TO_PORT=; FAM=; . "$f"
        if [[ $FAM == 6 ]]; then IPT=ip6tables; DEST="[$TO]:$TO_PORT"; else IPT=iptables; DEST="$TO:$TO_PORT"; fi
        $IPT -t nat -D PREROUTING -p "$PROTO" --dport "$IN_PORT" -j DNAT --to-destination "$DEST" 2>/dev/null || true
        $IPT -t nat -D POSTROUTING -p "$PROTO" -d "$TO" --dport "$TO_PORT" -j MASQUERADE 2>/dev/null || true
        $IPT -D FORWARD -p "$PROTO" -d "$TO" --dport "$TO_PORT" -j ACCEPT 2>/dev/null || true
        rm -f "$f"
      done
      systemctl disable --now abtunnel-forward.service 2>/dev/null || true;;
    backhaul) type backhaul_down >/dev/null 2>&1 || die "backhaul helper not installed"; backhaul_down;;
    *) die "Usage: down <stunnel|ssh|ipsec|gre|ipip|sit|gre6|ip6ip6|openvpn|backhaul|forward>";;
  esac
  log "stopped: ${1:-}"
}

# ------------------------------------------------- connect from token (client)
cmd_connect() {
  need_root; apt_install openvpn coreutils
  local tok="${1:-}"; [[ -n $tok ]] || die "usage: abtunnel connect <TOKEN>"
  local dec; dec=$(printf '%s' "$tok" | base64 -d 2>/dev/null) || die "invalid token"
  local T="" P_PEER="" P_PORT="" P_KEY="" kv
  local IFS=';'; read -ra parts <<< "$dec"; unset IFS
  for kv in "${parts[@]}"; do
    case "$kv" in
      T=*)    T="${kv#T=}";;
      PEER=*) P_PEER="${kv#PEER=}";;
      PORT=*) P_PORT="${kv#PORT=}";;
      KEY=*)  P_KEY="${kv#KEY=}";;
    esac
  done
  [[ $T == openvpn ]] || die "unsupported token type: ${T:-?}"
  [[ -n $P_PEER && -n $P_PORT && -n $P_KEY ]] || die "token is missing fields"
  mkdir -p $DIR && chmod 700 $DIR
  printf '%s' "$P_KEY" | base64 -d > $DIR/ovpn.key; chmod 600 $DIR/ovpn.key
  PEER=$P_PEER; OVPN_PORT=$P_PORT; CERT=$DIR/ovpn.key
  openvpn_client
  echo; log "Testing the tunnel..."; sleep 2
  if ip -br addr show 2>/dev/null | grep -q '^tun' && ping -c3 -W2 10.30.0.1 >/dev/null 2>&1; then
    log "SUCCESS — tunnel is up. Peer reachable at 10.30.0.1 (this side 10.30.0.2)."
    ip route get 10.30.0.1 2>/dev/null | grep -q 'dev tun' && log "Traffic to 10.30.0.1 goes through the tunnel." || warn "Note: 10.30.0.1 may also be reachable via your LAN; tunnel interface is up regardless."
  else
    warn "Tunnel not confirmed yet. Check:  sudo systemctl status abtunnel-openvpn"
  fi
}

# -------------------------------------------------------- guided setup wizard
client_test_ip() { # proto -> tunnel IP to ping (empty = none)
  case "$1" in
    openvpn) echo 10.30.0.1;; wireguard) echo 10.10.0.1;;
    gre) echo 10.20.0.1;; ipip) echo 10.40.0.1;;
    sit) echo fd60::1;; gre6) echo fd20::1;; ip6ip6) echo fd40::1;;
    *) echo "";;
  esac
}

report_client() { # proto — test reachability and report
  local proto="$1" t p6=""
  echo; log "در حال تست تانل..."
  sleep 2
  case "$proto" in
    stunnel|ssh)
      if [[ -n ${LOCAL_PORT:-} ]] && timeout 3 bash -c "echo >/dev/tcp/127.0.0.1/$LOCAL_PORT" 2>/dev/null; then
        log "موفق — پورت محلی $LOCAL_PORT باز است؛ تانل کار می‌کند."
        return 0
      else
        warn "تانل تأیید نشد (پورت محلی باز نیست)."
        return 1
      fi
      ;;
    backhaul)
      local i since; since=$(date '+%Y-%m-%d %H:%M:%S' -d '-30 sec' 2>/dev/null || echo "-1min")
      for i in $(seq 1 10); do
        if journalctl -u abtunnel-backhaul --since "$since" --no-pager 2>/dev/null | grep -q 'control channel established'; then
          log "موفق — کانال کنترل backhaul به سرور وصل شد."
          return 0
        fi
        sleep 2
      done
      warn "تانل backhaul تأیید نشد. لاگ:  journalctl -u abtunnel-backhaul -n 30"
      return 1
      ;;
  esac
  t=$(client_test_ip "$proto")
  [[ -z $t ]] && { log "پیکربندی شد. (تست خودکار برای $proto تعریف نشده)"; return 0; }
  [[ $t == *:* ]] && p6="-6"
  if ping $p6 -c3 -W2 "$t" >/dev/null 2>&1; then
    log "موفق — تانل بالا آمد (پیر $t در دسترس است)."
    return 0
  else
    warn "تانل بالا نیامد (پاسخی از $t نرسید)."
    return 1
  fi
}

# ---------- helpers for simple auto mode ----------
wait_minutes() {
  local mins="${1:-3}"
  local secs=$((mins * 60))
  echo -e "${c_y}[!]${c_0} صبر به مدت ${mins} دقیقه قبل از تست تانل بعدی..."
  local left=$secs
  while (( left > 0 )); do
    printf "\r   باقی‌مانده: %02d:%02d " $((left/60)) $((left%60))
    sleep 1
    left=$((left-1))
  done
  echo
}

# Try bring a tunnel down quietly before trying next
quiet_down() {
  local kind="$1"
  cmd_down "$kind" >/dev/null 2>&1 || true
  systemctl disable --now "abtunnel-${kind}" 2>/dev/null || true
}

# ---------- AUTOMATIC mode ----------
# Server side: prepare protocols in order so client can try them
auto_server() {
  local peer_ip="$1"
  PEER="$peer_ip"

  echo
  log "حالت خودکار — سمت سرور"
  log "IP طرف مقابل: $peer_ip"
  echo
  echo "تانل‌ها به ترتیب آماده می‌شوند. روی سرور دیگر حالت خودکار (کلاینت) را بزنید."
  echo

  # 1) Backhaul (easiest token-based reverse tunnel)
  echo "────────────────────────────────────"
  log "۱/۴ آماده‌سازی Backhaul..."
  ACCEPT_PORT=3080
  PSK="$(openssl rand -hex 12 2>/dev/null || echo "tunxall$(date +%s)")"
  TRANSPORT=tcp
  PORTS="443,8080"
  if ( backhaul_server ); then
    log "Backhaul آماده است (پورت 3080)."
  else
    warn "Backhaul آماده نشد — ادامه می‌دهیم."
  fi

  # 2) OpenVPN
  echo "────────────────────────────────────"
  log "۲/۴ آماده‌سازی OpenVPN..."
  OVPN_PORT=51820
  if ( openvpn_server ); then
    log "OpenVPN آماده است."
  else
    warn "OpenVPN آماده نشد — ادامه می‌دهیم."
  fi

  # 3) GRE
  echo "────────────────────────────────────"
  log "۳/۴ آماده‌سازی GRE..."
  PSK=""
  if ( iface_tunnel_setup gre server ); then
    log "GRE آماده است."
  else
    warn "GRE آماده نشد — ادامه می‌دهیم."
  fi

  # 4) IPIP
  echo "────────────────────────────────────"
  log "۴/۴ آماده‌سازی IPIP..."
  PSK=""
  if ( iface_tunnel_setup ipip server ); then
    log "IPIP آماده است."
  else
    warn "IPIP آماده نشد."
  fi

  echo
  log "سمت سرور آماده است. حالا روی سرور دیگر همین منو را باز کنید و نقش کلاینت + حالت خودکار را بزنید."
  echo "توکن‌ها / اطلاعات لازم در خروجی بالا چاپ شده‌اند."
}

# Client side: try each tunnel in order, wait 3 min on failure
auto_client() {
  local peer_ip="$1"
  PEER="$peer_ip"

  echo
  log "حالت خودکار — سمت کلاینت"
  log "IP سرور: $peer_ip"
  echo
  echo "به ترتیب تانل‌ها را امتحان می‌کنیم."
  echo "اگر وصل نشد، ۳ دقیقه صبر و بعد تانل بعدی."
  echo

  local ok=0

  # --- 1) Backhaul ---
  echo "════════════════════════════════════"
  log "تست ۱/۴ — Backhaul"
  echo "اگر روی سرور توکن Backhaul چاپ شده، اینجا Paste کنید."
  echo "اگر ندارید Enter بزنید تا رد شود."
  read -rp "توکن Backhaul (یا Enter): " tok
  if [[ -n $tok ]]; then
    if ( backhaul_connect_token "$tok" ) && report_client backhaul; then
      log "اتصال با Backhaul برقرار شد. تمام."
      return 0
    fi
    warn "Backhaul وصل نشد."
    quiet_down backhaul
    wait_minutes 3
  else
    # try with default port + ask token
    read -rp "توکن ساده (اگر دارید): " PSK
    if [[ -n $PSK ]]; then
      ACCEPT_PORT=3080
      TRANSPORT=tcp
      if ( PEER="$peer_ip" PSK="$PSK" TRANSPORT=tcp backhaul_client ) && report_client backhaul; then
        log "اتصال با Backhaul برقرار شد. تمام."
        return 0
      fi
      warn "Backhaul وصل نشد."
      quiet_down backhaul
      wait_minutes 3
    else
      warn "توکن نبود — Backhaul رد شد."
    fi
  fi

  # --- 2) OpenVPN ---
  echo "════════════════════════════════════"
  log "تست ۲/۴ — OpenVPN"
  echo "توکن OpenVPN سرور را Paste کنید (یا Enter برای رد)."
  read -rp "توکن OpenVPN: " tok
  if [[ -n $tok ]]; then
    if ( cmd_connect "$tok" ) && report_client openvpn; then
      log "اتصال با OpenVPN برقرار شد. تمام."
      return 0
    fi
    warn "OpenVPN وصل نشد."
    quiet_down openvpn
    wait_minutes 3
  else
    warn "توکن نبود — OpenVPN رد شد."
  fi

  # --- 3) GRE ---
  echo "════════════════════════════════════"
  log "تست ۳/۴ — GRE"
  PSK=""
  if ( iface_tunnel_setup gre client ) && report_client gre; then
    log "اتصال با GRE برقرار شد. تمام."
    return 0
  fi
  warn "GRE وصل نشد."
  quiet_down gre
  wait_minutes 3

  # --- 4) IPIP ---
  echo "════════════════════════════════════"
  log "تست ۴/۴ — IPIP"
  PSK=""
  if ( iface_tunnel_setup ipip client ) && report_client ipip; then
    log "اتصال با IPIP برقرار شد. تمام."
    return 0
  fi
  warn "IPIP وصل نشد."
  quiet_down ipip

  echo
  warn "هیچ‌کدام از تانل‌های خودکار وصل نشدند."
  echo "پیشنهاد:"
  echo "  • فایروال دو طرف را چک کنید (sudo netcheck ...)"
  echo "  • حالت دستی را امتحان کنید و پروتکل دیگری انتخاب کنید"
  return 1
}

# ---------- MANUAL mode (simple) ----------
manual_setup() {
  local role="$1" peer_ip="$2"
  PEER="$peer_ip"

  echo
  echo "پروتکل را انتخاب کنید:"
  echo "  1) Backhaul   (پیشنهادی — reverse tunnel)"
  echo "  2) OpenVPN"
  echo "  3) WireGuard"
  echo "  4) GRE"
  echo "  5) IPIP"
  echo "  6) SSH"
  echo "  7) Stunnel (TLS)"
  echo "  8) IPsec"
  read -rp "شماره پروتکل: " p

  local proto=""
  case "$p" in
    1) proto=backhaul;;
    2) proto=openvpn;;
    3) proto=wireguard;;
    4) proto=gre;;
    5) proto=ipip;;
    6) proto=ssh;;
    7) proto=stunnel;;
    8) proto=ipsec;;
    *) warn "انتخاب نامعتبر"; return 0;;
  esac

  if [[ $role == server ]]; then
    case "$proto" in
      backhaul)
        read -rp "پورت گوش‌دادن [3080]: " ACCEPT_PORT; ACCEPT_PORT=${ACCEPT_PORT:-3080}
        read -rp "توکن (خالی = ساخت خودکار): " PSK
        read -rp "نوع حمل (tcp/tcpmux/ws/wss/grpc/grpcs) [tcp]: " TRANSPORT; TRANSPORT=${TRANSPORT:-tcp}
        PORTS="443,8080"
        ( backhaul_server ) || warn "ناموفق"
        ;;
      openvpn)
        read -rp "پورت UDP [51820]: " OVPN_PORT; OVPN_PORT=${OVPN_PORT:-51820}
        ( openvpn_server ) || warn "ناموفق"
        ;;
      wireguard)
        read -rp "پورت UDP [51820]: " WGP; WGP=${WGP:-51820}
        wg-tunnel server --port "$WGP" || warn "ناموفق"
        ;;
      gre|ipip)
        read -rp "PSK مشترک (خالی = بدون رمز): " PSK
        ( iface_tunnel_setup "$proto" server ) || warn "ناموفق"
        ;;
      ssh)
        read -rp "کلید عمومی کلاینت (خالی = بعداً): " PUBKEY
        ( ssh_server ) || warn "ناموفق"
        ;;
      stunnel)
        read -rp "پورت TLS عمومی [443]: " ACCEPT_PORT; ACCEPT_PORT=${ACCEPT_PORT:-443}
        read -rp "پورت سرویس محلی برای expose: " SERVICE_PORT
        ( stunnel_server ) || warn "ناموفق"
        ;;
      ipsec)
        ( ipsec_setup server ) || warn "ناموفق"
        ;;
    esac
  else
    case "$proto" in
      backhaul)
        echo "توکن سرور را Paste کنید (یا Enter برای ورود دستی):"
        read -r tok
        if [[ -n $tok ]]; then
          ( backhaul_connect_token "$tok" ) || warn "ناموفق"
        else
          read -rp "آدرس سرور (ip یا ip:port): " PEERS
          read -rp "توکن: " PSK
          read -rp "نوع حمل (همان سرور: tcp/tcpmux/ws/wss/grpc/grpcs) [tcp]: " TRANSPORT; TRANSPORT=${TRANSPORT:-tcp}
          ACCEPT_PORT=3080
          if [[ "$PEERS" != *:* ]]; then PEERS="${PEERS}:3080"; fi
          ( PEERS="$PEERS" PSK="$PSK" TRANSPORT="$TRANSPORT" backhaul_client ) || warn "ناموفق"
        fi
        report_client backhaul || true
        ;;
      openvpn)
        echo "توکن OpenVPN سرور را Paste کنید:"
        read -r tok
        ( cmd_connect "$tok" ) || warn "ناموفق"
        report_client openvpn || true
        ;;
      wireguard)
        read -rp "کلید عمومی سرور: " PUBKEY
        read -rp "پورت UDP [51820]: " WGP; WGP=${WGP:-51820}
        wg-tunnel client --endpoint "$peer_ip" --port "$WGP" --pubkey "$PUBKEY" || warn "ناموفق"
        report_client wireguard || true
        ;;
      gre|ipip)
        read -rp "PSK مشترک (همان سرور؛ خالی = بدون رمز): " PSK
        ( iface_tunnel_setup "$proto" client ) || warn "ناموفق"
        report_client "$proto" || true
        ;;
      ssh)
        read -rp "پورت SSH [22]: " SSH_PORT; SSH_PORT=${SSH_PORT:-22}
        read -rp "پورت محلی روی این ماشین: " LOCAL_PORT
        read -rp "هاست مقصد داخل سرور [127.0.0.1]: " THOST; THOST=${THOST:-127.0.0.1}
        read -rp "پورت مقصد داخل سرور: " RPORT
        ( ssh_client ) || warn "ناموفق"
        report_client ssh || true
        ;;
      stunnel)
        read -rp "پورت TLS [443]: " ACCEPT_PORT; ACCEPT_PORT=${ACCEPT_PORT:-443}
        read -rp "پورت محلی روی این ماشین: " LOCAL_PORT
        read -rp "مسیر server-cert.pem: " CERT
        ( stunnel_client ) || warn "ناموفق"
        report_client stunnel || true
        ;;
      ipsec)
        read -rp "PSK از سرور: " PSK
        ( ipsec_setup client ) || warn "ناموفق"
        report_client ipsec || true
        ;;
    esac
  fi
}

# ---------- main simple guided flow ----------
wizard_guided() {
  local role mode peer_ip

  clear 2>/dev/null || true
  echo
  echo "╔════════════════════════════════════════╗"
  echo "║     راه‌اندازی ساده تانل (tunxall)      ║"
  echo "╚════════════════════════════════════════╝"
  echo

  # Step 1: role
  echo "۱) نقش این سرور چیست؟"
  echo "   1) سرور   (IP عمومی دارد؛ طرف مقابل به آن وصل می‌شود)"
  echo "   2) کلاینت (به سرور وصل می‌شود)"
  read -rp "انتخاب [1/2]: " role
  case "$role" in
    1) role=server;;
    2) role=client;;
    *) warn "انتخاب نامعتبر"; return 0;;
  esac

  # Step 2: peer IP
  echo
  echo "۲) IP سرور مقابل را وارد کنید:"
  read -rp "IP: " peer_ip
  peer_ip=$(echo "$peer_ip" | xargs)
  [[ -n $peer_ip ]] || { warn "IP خالی است"; return 0; }
  PEER="$peer_ip"

  # Step 3: auto or manual
  echo
  echo "۳) نحوه راه‌اندازی:"
  echo "   1) خودکار  — خودش به ترتیب تانل‌ها را امتحان می‌کند"
  echo "               (اگر وصل نشد ۳ دقیقه صبر و تانل بعدی)"
  echo "   2) دستی    — خودتان پروتکل را انتخاب می‌کنید"
  read -rp "انتخاب [1/2]: " mode
  case "$mode" in
    1) mode=auto;;
    2) mode=manual;;
    *) warn "انتخاب نامعتبر"; return 0;;
  esac

  echo
  if [[ $mode == auto ]]; then
    if [[ $role == server ]]; then
      auto_server "$peer_ip"
    else
      auto_client "$peer_ip"
    fi
  else
    manual_setup "$role" "$peer_ip"
  fi
}

# -------------------------------------------------------- main interactive menu
wizard() {
  need_root
  while true; do
    echo
    echo "════════════════ tunxall ════════════════"
    echo "  1) راه‌اندازی تانل (ساده)"
    echo "  2) وضعیت"
    echo "  3) افزودن پورت‌فوروارد"
    echo "  4) نگهبان ری‌استارت خودکار"
    echo "  5) حذف یک تانل"
    echo "  6) حذف کامل"
    echo "  7) منوی پیشرفته (قبلی)"
    echo "  0) خروج"
    echo "═════════════════════════════════════════"
    read -rp "انتخاب: " c
    case "$c" in
      1) wizard_guided || true;;
      2) cmd_status;;
      3) read -rp "پورت ورودی روی این ماشین: " IN_PORT
         read -rp "IP تانل طرف مقابل [10.30.0.1]: " TO; TO=${TO:-10.30.0.1}
         read -rp "پورت سرویس روی طرف مقابل: " TO_PORT
         read -rp "پروتکل tcp/udp [tcp]: " PROTO; PROTO=${PROTO:-tcp}
         ( cmd_forward ) || warn "ناموفق"
         ;;
      4) read -rp "Unit [abtunnel-openvpn]: " UNIT; UNIT=${UNIT:-abtunnel-openvpn}
         read -rp "IP تانل برای ping [10.30.0.1]: " WATCH_IP; WATCH_IP=${WATCH_IP:-10.30.0.1}
         ( health_install ) || warn "ناموفق"
         ;;
      5) read -rp "کدام (stunnel/ssh/ipsec/gre/ipip/openvpn/backhaul/forward): " d
         ( cmd_down "$d" ) || warn "ناموفق"
         ;;
      6) read -rp "همه چیز حذف شود؟ yes بنویسید: " yn
         [[ $yn == yes ]] && cmd_uninstall || warn "لغو شد"
         ;;
      7) ( menu_advanced ) || true;;
      0) exit 0;;
      *) warn "انتخاب نامعتبر";;
    esac
  done
}

# ------------------------------------------------------ advanced menu (by type)
menu_advanced() {
  need_root
  echo "=============================================="
  echo " abtunnel — advanced setup (all tunnel types)"
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
    *) warn "invalid selection"; return 1;;
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
    ""|menu|wizard) wizard;;
    advanced) menu_advanced;;
    connect) cmd_connect "${1:-}";;
    status) cmd_status;;
    uninstall) cmd_uninstall;;
    down) cmd_down "${1:-}";;
    health) parse_args "$@"; health_install;;
    forward) parse_args "$@"; cmd_forward;;
    stunnel) local role="${1:-}"; shift || true; parse_args "$@"; if [[ $role == server ]]; then stunnel_server; else stunnel_client; fi;;
    ssh)     local role="${1:-}"; shift || true; parse_args "$@"; if [[ $role == server ]]; then ssh_server; else ssh_client; fi;;
    ipsec)   local role="${1:-}"; shift || true; parse_args "$@"; ipsec_setup "$role";;
    gre)     local role="${1:-}"; shift || true; parse_args "$@"; iface_tunnel_setup gre "$role";;
    ipip)    local role="${1:-}"; shift || true; parse_args "$@"; iface_tunnel_setup ipip "$role";;
    sit)     local role="${1:-}"; shift || true; parse_args "$@"; iface_tunnel_setup sit "$role";;
    gre6)    local role="${1:-}"; shift || true; parse_args "$@"; iface_tunnel_setup gre6 "$role";;
    ip6ip6)  local role="${1:-}"; shift || true; parse_args "$@"; iface_tunnel_setup ip6ip6 "$role";;
    openvpn) local role="${1:-}"; shift || true; parse_args "$@"; if [[ $role == server ]]; then openvpn_server; else openvpn_client; fi;;
    backhaul) local role="${1:-}"; shift || true; parse_args "$@"; if [[ $role == server ]]; then backhaul_server; else backhaul_client; fi;;
    *) echo "Usage: $0 {menu|connect <token>|advanced|stunnel|ssh|ipsec|gre|ipip|sit|gre6|ip6ip6|openvpn|backhaul|forward|health|status|down|uninstall} ..."; echo "Easiest:  sudo $0   (opens the menu)"; exit 1;;
  esac
}
main "$@"
