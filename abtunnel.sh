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
#   tunlink — high-performance reverse tunnel (tcp/tcpmux/ws/wss/grpc/grpcs) with multi-server auto-select.
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

# Load tunlink helper if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/tunlink-helper.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/tunlink-helper.sh"
elif [[ -f /usr/local/lib/tunxall/tunlink-helper.sh ]]; then
  # shellcheck source=/dev/null
  source /usr/local/lib/tunxall/tunlink-helper.sh
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

LOGFILE=/var/log/abtunnel.log

# spin "message" cmd... — run cmd quietly (output goes to $LOGFILE) with a spinner.
spin() {
  local msg="$1"; shift
  if [[ ! -t 1 ]]; then "$@" >>"$LOGFILE" 2>&1; return; fi
  "$@" >>"$LOGFILE" 2>&1 &
  local pid=$! i=0 frames='-\|/'
  [[ $(locale charmap 2>/dev/null) == UTF-8 ]] && frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  \e[36m%s\e[0m %s " "${frames:i++%${#frames}:1}" "$msg"
    sleep 0.1
  done
  if wait "$pid"; then printf "\r  \e[32m✔\e[0m %s \n" "$msg"; return 0
  else printf "\r  \e[31m✘\e[0m %s \n" "$msg"; return 1; fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  local missing=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  command -v apt-get >/dev/null 2>&1 || die "Please install manually: ${missing[*]} (only apt-based systems are automated)"
  spin "Installing ${missing[*]}" bash -c 'apt-get update -qq; apt-get install -y -qq "$@"' _ "${missing[@]}" \
    || die "Failed to install: ${missing[*]} (details: $LOGFILE)"
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

# detect_path_mtu <peer> — largest unfragmented packet size to peer (bytes),
# found with a DF ping sweep. Echoes 0 when ICMP is blocked.
detect_path_mtu() {
  local peer="$1" f sz hdr=28 p6=""
  f=$(ip_family "$peer"); [[ $f == 6 ]] && { hdr=48; p6="-6"; }
  for sz in 1472 1452 1432 1412 1400 1372 1300 1240 1172; do
    if ping $p6 -c1 -W2 -M do -s "$sz" "$peer" >/dev/null 2>&1; then echo $((sz + hdr)); return; fi
  done
  echo 0
}

# tunnel_overhead <kind> — bytes of encapsulation for an interface tunnel.
tunnel_overhead() {
  case "$1" in
    gre)    echo 24;;  # 20 (outer IPv4) + 4 (GRE)
    ipip)   echo 20;;  # 20 (outer IPv4)
    sit)    echo 20;;  # 20 (outer IPv4), inner IPv6
    gre6)   echo 44;;  # 40 (outer IPv6) + 4 (GRE)
    ip6ip6) echo 40;;  # 40 (outer IPv6)
    *)      echo 24;;
  esac
}

# inner_mtu <kind> <peer> — MTU to set on the tunnel interface. Uses the measured
# path MTU minus encapsulation (and IPsec overhead when a PSK is set); falls back
# to a safe 1400 when the path MTU can't be measured. Floored at 1280.
inner_mtu() {
  local kind="$1" peer="$2" pmtu ov mtu
  pmtu=$(detect_path_mtu "$peer")
  [[ $pmtu -gt 0 ]] || { echo 1400; return; }
  ov=$(tunnel_overhead "$kind")
  [[ -n ${PSK:-} ]] && ov=$((ov + 73))   # ESP/AES-GCM overhead when IPsec-encrypted
  mtu=$((pmtu - ov))
  (( mtu < 1280 )) && mtu=1280
  echo "$mtu"
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
  local kind="$1" role="$2"; need_root; apt_install iproute2 iptables
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

  # Auto-size the tunnel MTU from the measured path MTU to avoid the classic
  # "tunnel up but large packets stall" problem.
  mtu=$(inner_mtu "$kind" "$PEER")
  log "Path MTU to $PEER → tunnel MTU set to $mtu"

  # TCP MSS clamp so forwarded TCP never exceeds the tunnel MTU (IPT = ip/ip6tables).
  local IPT=iptables; [[ $inner == 6 ]] && IPT=ip6tables
  mkdir -p $DIR && chmod 700 $DIR
  cat > $DIR/$ifn-up.sh <<EOF
#!/usr/bin/env bash
modprobe $mod 2>/dev/null || true
ip link del $ifn 2>/dev/null || true
ip link add $ifn type $linkargs local $myip remote $PEER
ip addr add $myaddr dev $ifn
ip link set $ifn mtu $mtu up
$IPT -t mangle -C FORWARD -o $ifn -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \\
  || $IPT -t mangle -A FORWARD -o $ifn -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
$IPT -t mangle -C FORWARD -i $ifn -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \\
  || $IPT -t mangle -A FORWARD -i $ifn -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
EOF
  cat > $DIR/$ifn-down.sh <<EOF
#!/usr/bin/env bash
$IPT -t mangle -D FORWARD -o $ifn -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
$IPT -t mangle -D FORWARD -i $ifn -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
ip link set $ifn down 2>/dev/null || true
ip link del $ifn 2>/dev/null || true
EOF
  chmod +x $DIR/$ifn-up.sh $DIR/$ifn-down.sh
  mkoneshot "abtunnel-$kind" "$DIR/$ifn-up.sh" "$DIR/$ifn-down.sh"
  enable_forwarding
  log "$kind tunnel up: this side ${myaddr%/*} <-> peer $peeraddr (iface $ifn, endpoints over IPv$fam, MTU $mtu)"
  log "Forward a service into the tunnel:  sudo bash abtunnel.sh forward --proto tcp --in-port <PORT> --to $peeraddr --to-port <PORT>"
  log "Test:  ping$([[ $inner == 6 ]] && echo ' -6') -c3 $peeraddr"
  log "Watchdog:  sudo bash abtunnel.sh health --unit abtunnel-$kind --watch-ip $peeraddr"
}

# ----------------------------------------------------------------- openvpn
# ovpn_mssfix <peer> — mssfix value (TCP MSS clamp) from the path MTU, so TCP
# inside the tunnel never fragments. Each side clamps its own; values may differ.
ovpn_mssfix() {
  local pmtu m
  pmtu=$(detect_path_mtu "${1:-1.1.1.1}")
  if [[ $pmtu -gt 0 ]]; then m=$((pmtu - 80)); else m=1300; fi
  (( m < 1000 )) && m=1000; (( m > 1400 )) && m=1400
  echo "$m"
}

openvpn_server() {
  need_root; apt_install openvpn; mkdir -p $DIR && chmod 700 $DIR
  [[ -f $DIR/ovpn.key ]] || openvpn --genkey secret $DIR/ovpn.key 2>/dev/null || openvpn --genkey --secret $DIR/ovpn.key
  local mssfix; mssfix=$(ovpn_mssfix)
  cat > $DIR/ovpn.conf <<EOF
dev tun
proto udp
port $OVPN_PORT
ifconfig 10.30.0.1 10.30.0.2
secret $DIR/ovpn.key
cipher AES-256-CBC
auth SHA256
keepalive 10 60
mssfix $mssfix
persist-key
persist-tun
EOF
  mkunit abtunnel-openvpn "$(command -v openvpn) --config $DIR/ovpn.conf"
  enable_forwarding
  local pub token
  pub="${PUBLIC_IP:-}"; [[ -n $pub ]] || pub=$(detect_pubip)
  token=$(printf 'T=openvpn;PEER=%s;PORT=%s;KEY=%s' "$pub" "$OVPN_PORT" "$(base64 -w0 $DIR/ovpn.key)" | base64 -w0)
  printf '%s\n' "$token" > $DIR/ovpn-connect.token; chmod 600 $DIR/ovpn-connect.token
  [[ -n ${BH_QUIET:-} ]] && return 0
  log "OpenVPN server up on udp/$OVPN_PORT, private IP 10.30.0.1"
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
  local mssfix; mssfix=$(ovpn_mssfix "$PEER")
  cat > $DIR/ovpn.conf <<EOF
dev tun
proto udp
remote $PEER $OVPN_PORT
ifconfig 10.30.0.2 10.30.0.1
secret $DIR/ovpn.key
cipher AES-256-CBC
auth SHA256
keepalive 10 60
mssfix $mssfix
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
    abtunnel-forward abtunnel-health.timer abtunnel-health abtunnel-tunlink abtunnel-backhaul 2>/dev/null || true
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
  echo "== abtunnel units =="; systemctl --no-pager --type=service 2>/dev/null | grep -E 'abtunnel|strongswan|ipsec|openvpn|tunlink' || echo "  (none)"
  if command -v tunlink_status &>/dev/null || type tunlink_status &>/dev/null; then
    echo "== reverse تانل =="; tunlink_status || true
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
    tunlink) type tunlink_down >/dev/null 2>&1 || die "tunlink helper not installed"; tunlink_down;;
    *) die "Usage: down <stunnel|ssh|ipsec|gre|ipip|sit|gre6|ip6ip6|openvpn|tunlink|forward>";;
  esac
  log "stopped: ${1:-}"
}

# ------------------------------------------------- connect from token (client)
token_type() { # print the T= field of a connection token (empty if invalid)
  # Tokens from older "backhaul" servers use the same protocol, so treat them as tunlink.
  { printf '%s' "${1:-}" | tr -d ' \r\n' | base64 -d 2>/dev/null | tr ';' '\n' | sed -n 's/^T=//p' | head -1 | sed 's/^backhaul$/tunlink/'; } || true
}

cmd_connect() {
  need_root
  local tok="${1:-}"; [[ -n $tok ]] || die "usage: abtunnel connect <TOKEN>"
  tok=$(printf '%s' "$tok" | tr -d ' \r\n')
  if [[ $(token_type "$tok") == tunlink ]]; then
    type tunlink_connect_token >/dev/null 2>&1 || die "tunlink helper not installed (re-run install.sh)"
    tunlink_connect_token "$tok"
    return
  fi
  apt_install openvpn coreutils
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
    tunlink)
      local i since; since=$(date '+%Y-%m-%d %H:%M:%S' -d '-30 sec' 2>/dev/null || echo "-1min")
      for i in $(seq 1 10); do
        if journalctl -u abtunnel-tunlink --since "$since" --no-pager 2>/dev/null | grep -q 'control channel established'; then
          log "موفق — کانال کنترل tunlink به سرور وصل شد."
          return 0
        fi
        sleep 2
      done
      warn "تانل tunlink تأیید نشد. لاگ:  journalctl -u abtunnel-tunlink -n 30"
      return 1
      ;;
  esac
  t=$(client_test_ip "$proto")
  [[ -z $t ]] && { log "پیکربندی شد. (تست خودکار برای $proto تعریف نشده)"; return 0; }
  [[ $t == *:* ]] && p6="-6"
  # 1) TCP probes first — works when ICMP ping is blocked
  local p
  for p in 22 80 443 8080; do
    if timeout 2 bash -c "echo >/dev/tcp/$t/$p" 2>/dev/null; then
      log "موفق — تانل بالا آمد (TCP به $t:$p برقرار است؛ پینگ لازم نیست)."
      return 0
    fi
  done
  # 2) Optional ping — only a bonus signal
  if ping $p6 -c2 -W2 "$t" >/dev/null 2>&1; then
    log "موفق — تانل بالا آمد (پینگ $t پاسخ داد)."
    return 0
  fi
  # 3) Interface present?
  if ip -br addr 2>/dev/null | grep -Eq 'tun|tap|wg|gre'; then
    log "موفق‌نما — اینترفیس تانل بالا است (پینگ بین سرورها ممکن است بسته باشد)."
    return 0
  fi
  warn "تانل تأیید نشد (نه TCP و نه پینگ به $t)."
  return 1
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

  # 1) تانل (easiest token-based reverse tunnel)
  echo "────────────────────────────────────"
  log "۱/۴ آماده‌سازی تانل TCP (بدون نیاز به پینگ)..."
  ACCEPT_PORT=3080
  PSK="$(openssl rand -hex 12 2>/dev/null || echo "tunxall$(date +%s)")"
  TRANSPORT=tcp
  PORTS="443,8080"
  if ( tunlink_server ); then
    log "تانل آماده است (پورت 3080)."
  else
    warn "تانل آماده نشد — ادامه می‌دهیم."
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

  # --- 1) تانل ---
  echo "════════════════════════════════════"
  log "تست ۱/۴ — تانل"
  echo "اگر روی سرور توکن اتصال چاپ شده، اینجا Paste کنید."
  echo "اگر ندارید Enter بزنید تا رد شود."
  read -rp "توکن اتصال (یا Enter): " tok
  if [[ -n $tok ]]; then
    if ( tunlink_connect_token "$tok" ) && report_client tunlink; then
      log "اتصال با تانل برقرار شد. تمام."
      return 0
    fi
    warn "تانل وصل نشد."
    quiet_down tunlink
    wait_minutes 3
  else
    # try with default port + ask token
    read -rp "توکن ساده (اگر دارید): " PSK
    if [[ -n $PSK ]]; then
      ACCEPT_PORT=3080
      TRANSPORT=tcp
      if ( PEER="$peer_ip" PSK="$PSK" TRANSPORT=tcp tunlink_client ) && report_client tunlink; then
        log "اتصال با تانل برقرار شد. تمام."
        return 0
      fi
      warn "تانل وصل نشد."
      quiet_down tunlink
      wait_minutes 3
    else
      warn "توکن نبود — تانل رد شد."
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
  echo "  1) TCP تانل  (پیشنهادی — reverse tunnel)"
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
    1) proto=tunlink;;
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
      tunlink)
        read -rp "پورت گوش‌دادن [3080]: " ACCEPT_PORT; ACCEPT_PORT=${ACCEPT_PORT:-3080}
        read -rp "توکن (خالی = ساخت خودکار): " PSK
        read -rp "نوع حمل (tcp/tcpmux/ws/wss/grpc/grpcs) [tcp]: " TRANSPORT; TRANSPORT=${TRANSPORT:-tcp}
        PORTS="443,8080"
        ( tunlink_server ) || warn "ناموفق"
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
      tunlink)
        echo "توکن سرور را Paste کنید (یا Enter برای ورود دستی):"
        read -r tok
        if [[ -n $tok ]]; then
          ( tunlink_connect_token "$tok" ) || warn "ناموفق"
        else
          read -rp "آدرس سرور (ip یا ip:port): " PEERS
          read -rp "توکن: " PSK
          read -rp "نوع حمل (همان سرور: tcp/tcpmux/ws/wss/grpc/grpcs) [tcp]: " TRANSPORT; TRANSPORT=${TRANSPORT:-tcp}
          ACCEPT_PORT=3080
          if [[ "$PEERS" != *:* ]]; then PEERS="${PEERS}:3080"; fi
          ( PEERS="$PEERS" PSK="$PSK" TRANSPORT="$TRANSPORT" tunlink_client ) || warn "ناموفق"
        fi
        report_client tunlink || true
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

# ===================================================== friendly interactive UI
# Everything below is the menu a non-technical user sees: two steps — create a
# tunnel on the first server (prints a token), paste the token on the second.
U_B=$'\e[1m'; U_D=$'\e[2m'; U_CY=$'\e[36m'; U_G=$'\e[32m'; U_R=$'\e[31m'; U_Y=$'\e[33m'; U_M=$'\e[35m'; U_0=$'\e[0m'

ui_clear() { [[ -t 1 ]] && clear 2>/dev/null || true; }
ui_line()  { echo -e "  ${U_D}────────────────────────────────────────────${U_0}"; }
ui_title() { echo; echo -e "  ${U_B}${U_CY}▍ $*${U_0}"; ui_line; }
ui_step()  { echo; echo -e "  ${U_M}مرحله $1 از $2${U_0}  ${U_B}$3${U_0}"; }
ui_opt()   { printf "   ${U_B}${U_CY}[%s]${U_0}  %s" "$1" "$2"; [[ -n ${3:-} ]] && printf "  ${U_D}%s${U_0}" "$3"; echo; }
ui_ok()    { echo -e "  ${U_G}✔${U_0} $*"; }
ui_err()   { echo -e "  ${U_R}✘${U_0} $*"; }
ui_info()  { echo -e "  ${U_Y}●${U_0} $*"; }
ui_pause() { echo; read -rp "  ↵  برای برگشت به منو Enter بزنید " _ || true; }

ui_banner() {
  ui_clear
  echo
  echo -e "${U_CY}${U_B}    ╔══════════════════════════════╗${U_0}"
  echo -e "${U_CY}${U_B}    ║     ✦  T U N X A L L  ✦      ║${U_0}"
  echo -e "${U_CY}${U_B}    ╚══════════════════════════════╝${U_0}"
  echo -e "    ${U_D}تانل امن • اسپوف هوشمند • سوئیچ خودکار${U_0}"
  echo
}

# Persian/Arabic digits typed by the user count as normal digits.
norm_digits() {
  sed 's/۰/0/g;s/۱/1/g;s/۲/2/g;s/۳/3/g;s/۴/4/g;s/۵/5/g;s/۶/6/g;s/۷/7/g;s/۸/8/g;s/۹/9/g;s/٠/0/g;s/١/1/g;s/٢/2/g;s/٣/3/g;s/٤/4/g;s/٥/5/g;s/٦/6/g;s/٧/7/g;s/٨/8/g;s/٩/9/g' <<< "$1" | xargs
}

# ask VAR "question" "default" "regex" "error message"
ask() {
  local __var="$1" q="$2" def="${3:-}" re="${4:-.*}" err="${5:-مقدار نامعتبر است، دوباره وارد کنید}" ans
  while true; do
    if [[ -n $def ]]; then read -rp "  ➜ $q ${U_D}[$def]${U_0}: " ans || return 1
    else read -rp "  ➜ $q: " ans || return 1; fi
    ans=$(norm_digits "$ans"); ans=${ans:-$def}
    if [[ -n $ans && $ans =~ $re ]]; then printf -v "$__var" '%s' "$ans"; return 0; fi
    ui_err "$err"
  done
}

# choose VAR max default — read a menu number between 0..max
choose() {
  local __var="$1" max="$2" def="${3:-}" ans
  while true; do
    if [[ -n $def ]]; then read -rp "  ➜ انتخاب شما ${U_D}[$def]${U_0}: " ans || return 1
    else read -rp "  ➜ انتخاب شما: " ans || return 1; fi
    ans=$(norm_digits "$ans"); ans=${ans:-$def}
    if [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 0 && ans <= max )); then printf -v "$__var" '%s' "$ans"; return 0; fi
    ui_err "یک عدد بین 0 تا $max وارد کنید"
  done
}

confirm() { # confirm "question" — default yes
  local ans
  read -rp "  ➜ $1 ${U_D}[Y/n]${U_0}: " ans || return 1
  [[ -z $ans || $ans =~ ^([Yy]|[Yy][Ee][Ss]|بله|ب|آره)$ ]]
}

ui_token_box() { # title token
  echo
  echo -e "  ${U_Y}┌─ $1 ${U_0}"
  echo -e "  ${U_Y}│${U_0}"
  echo -e "  ${U_Y}│${U_0}  ${U_B}$2${U_0}"
  echo -e "  ${U_Y}│${U_0}"
  echo -e "  ${U_Y}└────────────────────────────────────────────${U_0}"
}

port_in_use() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q . || ss -Hlun "sport = :$1" 2>/dev/null | grep -q .; }

# Open ports on the local firewall if one is active (ufw / firewalld), so users
# don't have to know about it.
open_firewall() { # proto port...
  local proto="$1"; shift; local p
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in "$@"; do ufw allow "${p/-/:}/$proto" >/dev/null 2>&1 || true; done
    ui_ok "پورت‌ها در فایروال ufw باز شدند: $*"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in "$@"; do firewall-cmd --permanent --add-port="$p/$proto" >/dev/null 2>&1 || true; done
    firewall-cmd --reload >/dev/null 2>&1 || true
    ui_ok "پورت‌ها در firewalld باز شدند: $*"
  fi
}

tunnel_units() { # list installed abtunnel tunnel units (without .service)
  local f
  for f in /etc/systemd/system/abtunnel-*.service; do
    [[ -e $f ]] || continue
    f=${f##*/}; f=${f%.service}
    [[ $f == abtunnel-health || $f == abtunnel-forward ]] && continue
    echo "$f"
  done
}

unit_label() { # friendly name of a unit
  local kind=${1#abtunnel-} extra=""
  if [[ $kind == tunlink ]]; then
    if [[ -f $DIR/tunlink/server.toml ]]; then extra="سرور اول، $(sed -n 's/^transport = "\(.*\)"/\1/p' $DIR/tunlink/server.toml | head -1)"
    elif [[ -f $DIR/tunlink/client.toml ]]; then extra="سرور دوم، $(sed -n 's/^transport = "\(.*\)"/\1/p' $DIR/tunlink/client.toml | head -1)"; fi
  fi
  case "$kind" in
    tunlink|noping) echo "تانل${extra:+ ($extra)}";;
    openvpn)  echo "OpenVPN";;
    stunnel)  echo "Stunnel (TLS)";;
    ssh)      echo "SSH";;
    *)        echo "${kind^^}";;
  esac
}

# ---------------------------------------------------------------- screens
easy_server() {
  ui_banner
  ui_title "ساخت تانل جدید (روی سرور اول)"
  echo -e "  ${U_D}این سرور تانل را می‌سازد و یک «توکن» به شما می‌دهد.${U_0}"
  echo -e "  ${U_D}بعد همان توکن را روی سرور دوم Paste می‌کنید. تمام!${U_0}"

  ui_step 1 3 "نوع اتصال را انتخاب کنید"
  ui_opt 1 "TCP سریع"                      "سریع و ساده — پیشنهادی"
  ui_opt 2 "TCP مالتی‌پلکس"                 "چند کاربر روی یک اتصال"
  ui_opt 3 "📡 بدون پینگ (No-Ping)"         "حتی اگر پینگ بین دو سرور بسته باشد کار می‌کند"
  ui_opt 4 "🛡️  HTTPS Camouflage"           "صفحه فریب + تانل مخفی — مقاوم به DPI"
  ui_opt 5 "🎭 Spoof / WebSocket / gRPC"   "شبیه ترافیک وب"
  ui_opt 6 "OpenVPN"                       "شبکه‌ی خصوصی کامل"
  ui_opt 0 "برگشت"
  local c; choose c 6 1 || return 0
  [[ $c == 0 ]] && return 0
  local kind=tunlink transport=tcp
  case "$c" in
    1) transport=tcp;;
    2) transport=tcpmux;;
    3) transport=tcp; ui_info "حالت No-Ping + Shape: TCP بدون پینگ؛ اندازه پکت‌ها تصادفی می‌شود تا الگوی VPN دیده نشود.";;
    4) transport=https; ui_info "HTTPS Camouflage + Shape: ظاهر HTTPS + پدینگ تصادفی اندازه پکت (ضد انگشت‌نگاری VPN)";;
    5)
      echo
      ui_opt 1 "gRPC+TLS (شبیه HTTPS)"
      ui_opt 2 "WebSocket"
      ui_opt 3 "gRPC ساده"
      local c2; choose c2 3 1 || return 0
      case "$c2" in 1) transport=grpcs;; 2) transport=ws;; 3) transport=grpc;; esac
      ;;
    6) kind=openvpn;;
  esac

  # Suggest the best open port if a recent netcheck probe saved one.
  local sug_port="" sug_src=""
  if [[ -f $DIR/netcheck.env ]]; then
    ( . "$DIR/netcheck.env" 2>/dev/null; echo "${BEST_PORT:-}" ) > /tmp/.abt_sug 2>/dev/null || true
    sug_port=$(cat /tmp/.abt_sug 2>/dev/null); rm -f /tmp/.abt_sug
    [[ -n $sug_port ]] && sug_src="(از نتیجه‌ی netcheck)"
  fi
  # HTTPS-looking transports work best on 443; plain TCP uses a high port.
  local def_tport=3080
  case "$transport" in grpc|grpcs|ws|wss|https) def_tport=443;; esac
  [[ -n $sug_port ]] && def_tport=$sug_port

  local users_ports="" svc_port="" tport mapping=""
  ui_step 2 3 "پورت‌ها (تانل جدا از پنل)"
  if [[ $kind == tunlink ]]; then
    echo -e "  ${U_B}الف) پورت تانل${U_0} ${U_D}— فقط بین دو سرور شما؛ لازم نیست با پورت پنل یکی باشد${U_0}"
    case "$transport" in https|grpcs|wss|ws) def_tport=443;; *) def_tport=3080;; esac
    [[ -n $sug_port ]] && def_tport=$sug_port
    [[ -n $sug_src ]] && ui_info "پیشنهاد از netcheck: ${U_B}$def_tport${U_0} $sug_src"
    while true; do
      ask tport "پورت ارتباط بین دو سرور (تانل)" "$def_tport" '^[0-9]{1,5}$' || return 0
      port_in_use "$tport" && ! systemctl is-active --quiet abtunnel-tunlink 2>/dev/null \
        && { ui_err "پورت $tport اشغال است؛ پورت دیگری انتخاب کنید"; continue; }
      break
    done
    echo
    echo -e "  ${U_B}ب) پورت‌های پنل / inbound${U_0} ${U_D}— کاربرها و پنل به این پورت‌ها روی سرور اول وصل می‌شوند${U_0}"
    echo -e "  ${U_D}می‌توانید هر پورتی بگذارید؛ لازم نیست با پورت تانل یکی باشد.${U_0}"
    echo -e "  ${U_D}چند پورت: 443,8080,2096   |   مپ به مقصد: 443=127.0.0.1:8443${U_0}"
    ask users_ports "پورت پنل/inbound روی سرور اول" "443,8080" '^[0-9A-Za-z.:=_,/-]+$' "مثال: 443 یا 443,8080 یا 443=127.0.0.1:8443" || return 0
    # If user gave plain ports without mapping, optionally ask backend port
    if [[ "$users_ports" =~ ^[0-9]+$ ]]; then
      echo -e "  ${U_D}سرویس واقعی روی سرور دوم (کلاینت) کدام پورت است؟${U_0}"
      ask svc_port "پورت سرویس روی سرور دوم" "$users_ports" '^[0-9]{1,5}$' || return 0
      if [[ -n $svc_port && $svc_port != "$users_ports" ]]; then
        mapping="${users_ports}=${svc_port}"
      else
        mapping="$users_ports"
      fi
    else
      mapping="$users_ports"
    fi
    # Safety: tunnel port must not collide with a panel listen port on same host
    local first_panel
    first_panel=$(echo "$mapping" | tr ',' '\n' | head -1 | sed 's/=.*//;s/.*://;s/[^0-9]//g')
    if [[ -n $first_panel && $first_panel == "$tport" ]]; then
      ui_info "توجه: پورت تانل و پورت پنل هر دو $tport است. اگر پنل و تانل روی یک IP گوش بدهند تداخل پیش می‌آید. در صورت امکان پورت تانل را عوض کنید."
      if ! confirm "ادامه با پورت یکسان؟"; then
        ask tport "پورت تانل جدید" "3080" '^[0-9]{1,5}$' || return 0
      fi
    fi
  else
    ask tport "پورت UDP برای OpenVPN" "1194" '^[0-9]{1,5}$' || return 0
  fi

  ui_step 3 3 "آدرس این سرور"
  local pub; pub=$(detect_pubip)
  if [[ -n $pub ]] && { echo -e "  IP عمومی این سرور: ${U_B}$pub${U_0}"; confirm "درست است؟"; }; then :
  else ask pub "IP عمومی این سرور" "" '^[0-9A-Fa-f.:]+$' "یک IP معتبر وارد کنید" || return 0; fi

  echo; ui_line
  ui_info "اولین بار ممکن است یکی دو دقیقه طول بکشد..."
  local ok=0 token_file
  if [[ $kind == tunlink ]]; then
    ask TOKEN_LABEL "نام این توکن (برای صندوق چندتوکنی)" "default" '^[A-Za-z0-9._-]*$' || true
    TOKEN_LABEL=${TOKEN_LABEL:-default}
    [[ -z $mapping ]] && mapping="$users_ports"
    if type normalize_ports >/dev/null 2>&1; then mapping=$(normalize_ports "$mapping"); fi
    _mk() { BH_QUIET=1 TOKEN_LABEL="${TOKEN_LABEL:-default}" PUBLIC_IP="$1" ACCEPT_PORT="$2" PSK="" TRANSPORT="$3" PORTS="$4" tunlink_server; }
    spin "ساخت تانل ($transport)" _mk "$pub" "$tport" "$transport" "$mapping" && ok=1
    token_file=$DIR/tunlink/connect.token
    [[ $ok == 1 ]] && open_firewall tcp "$tport" ${users_ports//,/ }
  else
    _mk() { BH_QUIET=1 PUBLIC_IP="$1" OVPN_PORT="$2" openvpn_server; }
    spin "ساخت تانل OpenVPN" _mk "$pub" "$tport" && ok=1
    token_file=$DIR/ovpn-connect.token
    [[ $ok == 1 ]] && open_firewall udp "$tport"
  fi

  if [[ $ok == 1 && -s $token_file ]]; then
    echo; ui_ok "${U_B}سرور اول آماده است!${U_0}"
    ui_token_box "توکن اتصال — این را کپی کنید" "$(cat "$token_file")"
    echo
    echo -e "  ${U_B}قدم بعد روی سرور دوم:${U_0}"
    echo -e "   ۱) نصب:   ${U_CY}curl -fsSL https://raw.githubusercontent.com/${TUNXALL_REPO:-arshiakhadmi16-bot/tunxall}/main/install.sh | sudo bash${U_0}"
    echo -e "   ۲) در منو گزینه‌ی ${U_B}[2] وصل شدن با توکن${U_0} را بزنید و توکن را Paste کنید."
    echo -e "  ${U_D}(هر وقت خواستید از منوی اصلی «نمایش دوباره توکن» را بزنید.)${U_0}"
  else
    echo; ui_err "${U_B}ساخت تانل ناموفق بود.${U_0}"
    ui_info "جزئیات خطا در بالا و در فایل $LOGFILE است."
  fi
  ui_pause
}

easy_client() {
  ui_banner
  ui_title "وصل شدن با توکن (روی سرور دوم)"
  echo -e "  ${U_D}توکنی را که سرور اول نشان داد کپی کنید، اینجا Paste کنید و Enter بزنید.${U_0}"
  echo -e "  ${U_D}(برای برگشت، خالی Enter بزنید)${U_0}"
  echo
  local tok t
  while true; do
    read -rp "  ➜ توکن: " tok || return 0
    tok=$(printf '%s' "$tok" | tr -d ' \r\n')
    [[ -z $tok ]] && return 0
    t=$(token_type "$tok")
    [[ $t == tunlink || $t == openvpn ]] && break
    ui_err "این توکن معتبر نیست — مطمئن شوید کامل کپی شده است."
  done

  local dec peer port tr=""
  dec=$(printf '%s' "$tok" | base64 -d 2>/dev/null | tr ';' '\n' || true)
  peer=$(sed -n 's/^PEER=//p' <<< "$dec"); port=$(sed -n 's/^PORT=//p' <<< "$dec"); tr=$(sed -n 's/^TRANSPORT=//p' <<< "$dec")
  echo
  ui_line
  echo -e "   نوع تانل:   ${U_B}${t^}${tr:+ ($tr)}${U_0}"
  echo -e "   سرور اول:   ${U_B}$peer${U_0}  پورت ${U_B}$port${U_0}"
  ui_line
  confirm "وصل شویم؟" || return 0

  echo
  local ok=0
  _conn() { BH_QUIET=1 cmd_connect "$1"; }
  if spin "اتصال به سرور اول" _conn "$tok" && spin "بررسی اینکه تانل واقعاً کار می‌کند" report_client "$t"; then ok=1; fi

  echo
  if [[ $ok == 1 ]]; then
    ui_ok "${U_B}تانل وصل شد!${U_0} 🎉"
    if [[ $t == tunlink ]]; then
      ui_info "کاربرها حالا می‌توانند به $peer روی پورت‌هایی که روی سرور اول تعیین کردید وصل شوند."
    else
      ui_info "شبکه‌ی خصوصی برقرار است: این سرور 10.30.0.2 و سرور اول 10.30.0.1"
    fi
    ui_info "اگر سرور یا اینترنت قطع و وصل شود، تانل خودش دوباره وصل می‌شود."
  else
    ui_err "${U_B}اتصال برقرار نشد.${U_0}"
    echo -e "  ${U_B}این موارد را بررسی کنید:${U_0}"
    echo -e "   • پورت ${U_B}$port${U_0} روی سرور اول (و فایروال دیتاسنتر) باز باشد"
    echo -e "   • توکن کامل و بدون تغییر کپی شده باشد"
    echo -e "   • روی سرور اول تانل فعال باشد (منو ← وضعیت تانل‌ها)"
    echo -e "  ${U_D}جزئیات: $LOGFILE${U_0}"
  fi
  ui_pause
}

status_screen() {
  ui_banner
  ui_title "وضعیت تانل‌ها"
  local u any=0
  while read -r u; do
    [[ -n $u ]] || continue; any=1
    if systemctl is-active --quiet "$u" 2>/dev/null; then
      echo -e "   ${U_G}● فعال   ${U_0} $(unit_label "$u")"
    else
      echo -e "   ${U_R}● متوقف  ${U_0} $(unit_label "$u")  ${U_D}(لاگ: journalctl -u $u -n 30)${U_0}"
    fi
  done < <(tunnel_units)
  [[ $any == 0 ]] && ui_info "هنوز هیچ تانلی ساخته نشده است."
  if ls $DIR/forward-*.rule >/dev/null 2>&1; then
    echo; echo -e "  ${U_B}پورت‌فورواردها:${U_0}"
    local f; for f in $DIR/forward-*.rule; do ( . "$f"; echo "   • $PROTO/$IN_PORT → $TO:$TO_PORT" ); done
  fi
  # Failover panel
  echo
  ui_line
  if systemctl is-active --quiet abtunnel-failover 2>/dev/null; then
    echo -e "  ${U_G}⚡ سوئیچ خودکار: روشن${U_0}"
    if [[ -f /etc/abtunnel/failover/active ]]; then
      echo -e "  ${U_D}تانل فعلی: $(cat /etc/abtunnel/failover/active 2>/dev/null)${U_0}"
    fi
    if [[ -f /etc/abtunnel/failover/tunnels.list ]]; then
      echo -e "  ${U_D}ترتیب: $(grep -v '^#' /etc/abtunnel/failover/tunnels.list | tr '\n' ' ')${U_0}"
    fi
  else
    echo -e "  ${U_D}⚡ سوئیچ خودکار: خاموش${U_0}  ${U_D}(از منو فعال کنید)${U_0}"
  fi
  ui_pause
}

token_screen() {
  ui_banner
  ui_title "نمایش دوباره توکن"
  local shown=0
  [[ -s $DIR/tunlink/connect.token ]] && { ui_token_box "توکن فعال" "$(cat $DIR/tunlink/connect.token)"; shown=1; }
  [[ -s $DIR/ovpn-connect.token ]] && { ui_token_box "توکن OpenVPN" "$(cat $DIR/ovpn-connect.token)"; shown=1; }
  local n=0
  n=$(ls "$DIR"/tokens/*.token 2>/dev/null | wc -l | tr -d ' ')
  if [[ ${n:-0} -gt 0 ]]; then
    echo; ui_info "صندوق توکن‌ها: $n مورد — از منو «صندوق توکن‌ها» ببینید."
    shown=1
  fi
  [[ $shown == 0 ]] && ui_info "توکنی پیدا نشد. توکن فقط روی «سرور اول» و بعد از ساخت تانل ساخته می‌شود."
  ui_pause
}



failover_screen() {
  ui_banner
  ui_title "سوئیچ خودکار تانل (Failover)"
  echo -e "  ${U_D}اگر تانل فعلی قطع شود، خودکار به تانل بعدی می‌رود.${U_0}"
  echo -e "  ${U_D}لیست بدون تکرار است؛ سلامت tunlink سخت‌گیرانه‌تر چک می‌شود.${U_0}"
  echo
  ui_opt 1 "فعال‌سازی سوئیچ خودکار"    "نظارت + تعویض هوشمند"
  ui_opt 2 "وضعیت Failover"
  ui_opt 3 "ویرایش ترتیب تانل‌ها"       "اولویت سوئیچ"
  ui_opt 4 "خاموش کردن"
  ui_opt 0 "برگشت"
  local c; choose c 4 || return 0

  local helper=""
  for pth in "$SCRIPT_DIR/failover.sh" /opt/tunxall/failover.sh /usr/local/lib/tunxall/failover.sh; do
    [[ -x $pth ]] && helper=$pth && break
  done

  case "$c" in
    1)
      if [[ -z $helper ]]; then ui_err "فایل failover.sh پیدا نشد"; ui_pause; return 0; fi
      ui_info "در حال نصب ناظر سوئیچ خودکار..."
      if bash "$helper" install >>"$LOGFILE" 2>&1; then
        ui_ok "سوئیچ خودکار فعال شد."
        echo -e "  ${U_D}هر ۲۰ ثانیه سلامت چک می‌شود؛ بعد از ۳ بار شکست → تانل بعدی${U_0}"
        echo -e "  ${U_D}نام‌های تکراری (noping/https/tunlink) در یک هدف ادغام شدند.${U_0}"
      else
        ui_err "نصب ناموفق — جزئیات: $LOGFILE"
      fi
      ui_pause
      ;;
    2)
      if [[ -z $helper ]]; then ui_info "failover پیکربندی نشده"; ui_pause; return 0; fi
      bash "$helper" status
      ui_pause
      ;;
    3)
      if [[ -z $helper ]]; then ui_err "failover.sh نیست"; ui_pause; return 0; fi
      echo
      echo -e "  ${U_B}ترتیب فعلی:${U_0}"
      bash "$helper" status || true
      echo
      echo -e "  ${U_D}نام‌های مجاز: tunlink openvpn gre ipip wireguard ssh stunnel${U_0}"
      echo -e "  ${U_D}با فاصله بنویسید؛ اول = اولویت بالاتر. تکراری‌ها حذف می‌شوند.${U_0}"
      local line
      read -rp "  ➜ ترتیب جدید: " line || return 0
      line=$(echo "$line" | xargs)
      [[ -z $line ]] && { ui_info "خالی بود — بدون تغییر."; ui_pause; return 0; }
      # shellcheck disable=SC2086
      if bash "$helper" set-list $line >>"$LOGFILE" 2>&1; then
        ui_ok "ترتیب ذخیره شد."
        systemctl restart abtunnel-failover 2>/dev/null || true
        bash "$helper" status || true
      else
        ui_err "ذخیره ناموفق"
      fi
      ui_pause
      ;;
    4)
      [[ -n $helper ]] && bash "$helper" stop
      ui_ok "سوئیچ خودکار خاموش شد."
      ui_pause
      ;;
    0) return 0;;
  esac
}


remove_screen() {
  ui_banner
  ui_title "حذف تانل"
  local units=() u i=1
  while read -r u; do [[ -n $u ]] && units+=("$u"); done < <(tunnel_units)
  if [[ ${#units[@]} -eq 0 ]]; then ui_info "تانلی برای حذف وجود ندارد."; ui_pause; return 0; fi
  for u in "${units[@]}"; do ui_opt "$i" "$(unit_label "$u")"; i=$((i+1)); done
  ui_opt 0 "برگشت"
  local c; choose c "${#units[@]}" || return 0
  [[ $c == 0 ]] && return 0
  u=${units[$((c-1))]}
  confirm "«$(unit_label "$u")» حذف شود؟" || return 0
  if ( cmd_down "${u#abtunnel-}" ) >>"$LOGFILE" 2>&1; then
    rm -f "/etc/systemd/system/$u.service"; systemctl daemon-reload 2>/dev/null || true
    ui_ok "حذف شد."
  else
    ui_err "حذف ناموفق بود (جزئیات: $LOGFILE)"
  fi
  ui_pause
}

advanced_screen() {
  while true; do
    ui_banner
    ui_title "تنظیمات پیشرفته"
    ui_opt 1 "راه‌اندازی با انتخاب دستی پروتکل" "GRE، IPIP، WireGuard، SSH، Stunnel، IPsec و ..."
    ui_opt 2 "افزودن پورت‌فوروارد"             "هدایت یک پورت به داخل تانل"
    ui_opt 3 "نگهبان ری‌استارت خودکار"          "اگر تانل قطع شد خودش ری‌استارت شود"
    ui_opt 4 "منوی کامل همه‌ی انواع تانل"       "(انگلیسی)"
    ui_opt 5 "حذف کامل برنامه و همه‌ی تانل‌ها"
    ui_opt 0 "برگشت"
    local c; choose c 5 0 || return 0
    case "$c" in
      0) return 0;;
      1) ( wizard_guided ) || true; ui_pause;;
      2) ui_title "پورت‌فوروارد"
         ask IN_PORT "پورت ورودی روی این سرور" "" '^[0-9]{1,5}$' || continue
         ask TO "IP طرف مقابل داخل تانل" "10.30.0.1" '^[0-9A-Fa-f.:]+$' || continue
         ask TO_PORT "پورت سرویس روی طرف مقابل" "$IN_PORT" '^[0-9]{1,5}$' || continue
         ask PROTO "پروتکل (tcp/udp)" "tcp" '^(tcp|udp)$' || continue
         ( cmd_forward ) && ui_ok "فوروارد فعال شد." || ui_err "ناموفق"
         ui_pause;;
      3) ui_title "نگهبان ری‌استارت خودکار"
         local units=() u i=1
         while read -r u; do [[ -n $u ]] && units+=("$u"); done < <(tunnel_units)
         [[ ${#units[@]} -gt 0 ]] || { ui_info "اول یک تانل بسازید."; ui_pause; continue; }
         for u in "${units[@]}"; do ui_opt "$i" "$(unit_label "$u")"; i=$((i+1)); done
         choose c "${#units[@]}" 1 || continue
         [[ $c == 0 ]] && continue
         UNIT=${units[$((c-1))]}
         echo -e "  ${U_D}اگر پینگ بسته است، به‌جای IP یک پورت محلی باز بدهید (مثلاً 443).${U_0}"
         ask WATCH_IP "IP برای ping (یا خالی)" "10.30.0.1" '^[0-9A-Fa-f.:]*$' || true
         ask WATCH_PORT "یا پورت TCP محلی برای چک (اختیاری)" "" '^[0-9]{0,5}$' || true
         ( health_install ) && ui_ok "نگهبان فعال شد." || ui_err "ناموفق"
         ui_pause;;
      4) ( menu_advanced ) || true; ui_pause;;
      5) echo; ui_err "${U_B}همه‌ی تانل‌ها، تنظیمات و خود برنامه پاک می‌شوند.${U_0}"
         local yn; read -rp "  ➜ برای تأیید کلمه‌ی yes را بنویسید: " yn || continue
         if [[ $yn == yes ]]; then cmd_uninstall; exit 0; else ui_info "لغو شد."; ui_pause; fi;;
    esac
  done
}


# -------------------------------------------------------- doctor / self-test
doctor_screen() {
  ui_banner
  ui_title "عیب‌یابی سریع (Doctor)"
  echo -e "  ${U_D}بدون وابستگی به پینگ — TCP و وضعیت سرویس چک می‌شود${U_0}"
  echo

  local ok=0 warn=0

  # 1) units
  echo -e "  ${U_B}۱) سرویس‌ها${U_0}"
  local u any=0
  while read -r u; do
    [[ -n $u ]] || continue; any=1
    if systemctl is-active --quiet "$u" 2>/dev/null; then
      echo -e "     ${U_G}✔${U_0} $u فعال"
      ok=$((ok+1))
    else
      echo -e "     ${U_R}✘${U_0} $u متوقف"
      warn=$((warn+1))
    fi
  done < <(tunnel_units)
  [[ $any == 0 ]] && echo -e "     ${U_Y}●${U_0} هیچ تانلی نصب نشده"

  # 2) tunlink configs
  echo
  echo -e "  ${U_B}۲) تنظیمات TunLink${U_0}"
  if [[ -f $DIR/tunlink/server.toml ]]; then
    echo -e "     ${U_G}✔${U_0} server.toml"
    grep -E 'bind_addr|transport|obfuscate|ports' "$DIR/tunlink/server.toml" 2>/dev/null | sed 's/^/       /'
  elif [[ -f $DIR/tunlink/client.toml ]]; then
    echo -e "     ${U_G}✔${U_0} client.toml"
    grep -E 'remote_addr|remote_addrs|transport|obfuscate' "$DIR/tunlink/client.toml" 2>/dev/null | sed 's/^/       /'
  else
    echo -e "     ${U_Y}●${U_0} فایل تنظیمات tunlink پیدا نشد"
  fi

  # 3) TCP to peer (client side)
  echo
  echo -e "  ${U_B}۳) تست TCP تا سرور مقابل (بدون پینگ)${U_0}"
  local peer port
  if [[ -f $DIR/tunlink/client.toml ]]; then
    local line
    line=$(grep -E 'remote_addr\s*=' "$DIR/tunlink/client.toml" 2>/dev/null | head -1 || true)
    if [[ $line =~ \"([^:\"]+):([0-9]+)\" ]]; then
      peer="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
    else
      line=$(grep -oE '"[^"]+:[0-9]+"' "$DIR/tunlink/client.toml" 2>/dev/null | head -1 | tr -d '"')
      peer="${line%%:*}"; port="${line##*:}"
    fi
    if [[ -n $peer && -n $port ]]; then
      if timeout 3 bash -c "echo >/dev/tcp/${peer}/${port}" 2>/dev/null; then
        echo -e "     ${U_G}✔${U_0} TCP به ${peer}:${port} برقرار است"
        ok=$((ok+1))
      else
        echo -e "     ${U_R}✘${U_0} TCP به ${peer}:${port} برقرار نشد (فایروال/پورت/آدرس را چک کنید)"
        warn=$((warn+1))
      fi
    else
      echo -e "     ${U_Y}●${U_0} آدرس peer از config خوانده نشد"
    fi
  else
    echo -e "     ${U_D}(فقط روی سمت کلاینت معنی دارد)${U_0}"
  fi

  # 4) control channel recent logs
  echo
  echo -e "  ${U_B}۴) کانال کنترل (لاگ ۲ دقیقه اخیر)${U_0}"
  if systemctl list-units --type=service --all 2>/dev/null | grep -q abtunnel-tunlink; then
    if journalctl -u abtunnel-tunlink --since "2 min ago" --no-pager 2>/dev/null | grep -qi 'control channel established'; then
      echo -e "     ${U_G}✔${U_0} control channel اخیراً برقرار شده"
      ok=$((ok+1))
    elif journalctl -u abtunnel-tunlink --since "2 min ago" --no-pager 2>/dev/null | grep -Eqi 'error|failed|timeout|refused'; then
      echo -e "     ${U_R}✘${U_0} خطا در لاگ اخیر:"
      journalctl -u abtunnel-tunlink --since "2 min ago" --no-pager 2>/dev/null | grep -Ei 'error|failed|timeout|refused' | tail -5 | sed 's/^/       /'
      warn=$((warn+1))
    else
      echo -e "     ${U_Y}●${U_0} پیام واضحی در ۲ دقیقه اخیر نیست — سرویس را یک‌بار ری‌استارت کنید"
    fi
  else
    echo -e "     ${U_D}سرویس abtunnel-tunlink ثبت نشده${U_0}"
  fi

  # 5) failover
  echo
  echo -e "  ${U_B}۵) سوئیچ خودکار${U_0}"
  if systemctl is-active --quiet abtunnel-failover 2>/dev/null; then
    echo -e "     ${U_G}✔${U_0} failover فعال — تانل فعلی: $(cat $DIR/failover/active 2>/dev/null || echo '?')"
  else
    echo -e "     ${U_D}○ خاموش (از منو می‌توانید روشن کنید)${U_0}"
  fi

  echo
  ui_line
  if (( warn == 0 )); then
    ui_ok "جمع‌بندی: وضعیت خوب به نظر می‌رسد ($ok مورد مثبت)."
  else
    ui_err "جمع‌بندی: $warn مورد نیاز به بررسی دارد، $ok مورد مثبت."
  fi
  ui_pause
}

restart_tunnel_screen() {
  ui_banner
  ui_title "ری‌استارت تانل"
  local units=() u i=1
  while read -r u; do [[ -n $u ]] && units+=("$u"); done < <(tunnel_units)
  if [[ ${#units[@]} -eq 0 ]]; then ui_info "تانلی نیست."; ui_pause; return 0; fi
  for u in "${units[@]}"; do
    local st="متوقف"; systemctl is-active --quiet "$u" 2>/dev/null && st="فعال"
    ui_opt "$i" "$(unit_label "$u")" "$st"
    i=$((i+1))
  done
  ui_opt 0 "برگشت"
  local c; choose c "${#units[@]}" || return 0
  [[ $c == 0 ]] && return 0
  u=${units[$((c-1))]}
  ui_info "در حال ری‌استارت $u ..."
  if systemctl restart "$u" 2>/dev/null; then
    sleep 1
    systemctl is-active --quiet "$u" && ui_ok "ری‌استارت شد و فعال است." || ui_err "ری‌استارت شد ولی هنوز فعال نیست."
  else
    ui_err "ری‌استارت ناموفق"
  fi
  ui_pause
}

hard_network_hint() {
  # kept as alias
  hard_network_profile
}

# One-click hard-network profile: HTTPS camouflage + shape + failover
hard_network_profile() {
  ui_banner
  ui_title "پروفایل یک‌کلیکی شبکه سخت"
  echo -e "  ${U_D}HTTPS Camouflage + پدینگ پکت + پورت جدا + Failover${U_0}"
  echo

  if ! confirm "روی این سرور به‌عنوان سرور اول ساخته شود؟"; then
    ui_info "لغو شد. اگر کلاینت هستید فقط توکن را Paste کنید."; ui_pause; return 0
  fi

  local pub tport users_ports
  pub=$(detect_pubip)
  if [[ -z $pub ]] || ! confirm "IP عمومی: ${pub:-?} — درست است؟"; then
    ask pub "IP عمومی این سرور" "" '^[0-9A-Fa-f.:]+$' || return 0
  fi

  tport=443
  users_ports="2096,8080"
  echo -e "  ${U_D}پیش‌فرض‌ها:${U_0}"
  echo -e "   • transport: ${U_B}https${U_0} (Camouflage)"
  echo -e "   • پورت تانل: ${U_B}${tport}${U_0}"
  echo -e "   • پورت پنل: ${U_B}${users_ports}${U_0}"
  echo -e "   • obfuscate/shape: ${U_B}روشن${U_0}"
  if ! confirm "با همین پیش‌فرض‌ها ادامه؟"; then
    ask tport "پورت تانل" "443" '^[0-9]{1,5}$' || return 0
    ask users_ports "پورت پنل (کاما جدا)" "2096,8080" '^[0-9A-Za-z.:=_,/-]+$' || return 0
  fi

  ui_info "در حال ساخت..."
  local ok=0
  TOKEN_LABEL="hardnet" BH_QUIET=1 PUBLIC_IP="$pub" ACCEPT_PORT="$tport" PSK="" TRANSPORT="https" PORTS="$users_ports" \
    tunlink_server >>"$LOGFILE" 2>&1 && ok=1 || ok=0

  if [[ $ok == 1 ]]; then
    open_firewall tcp "$tport" 2096 8080 2>/dev/null || true
    # enable failover
    local helper=""
    for p in "$SCRIPT_DIR/failover.sh" /opt/tunxall/failover.sh /usr/local/lib/tunxall/failover.sh; do
      [[ -x $p ]] && helper=$p && break
    done
    [[ -n $helper ]] && bash "$helper" install >>"$LOGFILE" 2>&1 || true

    ui_ok "پروفایل شبکه سخت آماده است."
    if [[ -s $DIR/tunlink/connect.token ]]; then
      ui_token_box "توکن — روی سرور دوم Paste کنید" "$(cat $DIR/tunlink/connect.token)"
    fi
    echo -e "  ${U_D}Failover هم فعال شد. وضعیت: منو ← عیب‌یابی${U_0}"
  else
    ui_err "ساخت ناموفق بود — جزئیات: $LOGFILE"
  fi
  ui_pause
}

webpanel_screen() {
  ui_banner
  ui_title "پنل وب وضعیت"
  echo -e "  ${U_D}صفحه وضعیت محلی (سرویس‌ها، توکن‌ها، failover)${U_0}"
  echo
  ui_opt 1 "نصب و روشن کردن پنل" "پورت 9090"
  ui_opt 2 "وضعیت پنل"
  ui_opt 3 "خاموش کردن"
  ui_opt 0 "برگشت"
  local c; choose c 3 || return 0
  local helper=""
  for p in "$SCRIPT_DIR/webpanel.sh" /opt/tunxall/webpanel.sh /usr/local/lib/tunxall/webpanel.sh; do
    [[ -x $p ]] && helper=$p && break
  done
  case "$c" in
    1)
      [[ -n $helper ]] || { ui_err "webpanel.sh پیدا نشد"; ui_pause; return 0; }
      ask WEB_PORT "پورت پنل وب" "9090" '^[0-9]{1,5}$' || return 0
      if WEB_PORT="$WEB_PORT" bash "$helper" install >>"$LOGFILE" 2>&1; then
        local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        ui_ok "پنل فعال شد:  http://${ip:-0.0.0.0}:${WEB_PORT}/"
        open_firewall tcp "$WEB_PORT" 2>/dev/null || true
      else
        ui_err "نصب ناموفق — $LOGFILE"
      fi
      ui_pause
      ;;
    2)
      [[ -n $helper ]] && bash "$helper" status || ui_info "نصب نشده"
      ui_pause
      ;;
    3)
      [[ -n $helper ]] && bash "$helper" stop
      ui_ok "خاموش شد."
      ui_pause
      ;;
    0) return 0;;
  esac
}

token_vault_screen() {
  ui_banner
  ui_title "صندوق توکن‌ها (چند توکن همزمان)"
  mkdir -p "$DIR/tokens"
  local files=() f i=1
  # include legacy single tokens
  [[ -s $DIR/tunlink/connect.token ]] && files+=("$DIR/tunlink/connect.token")
  [[ -s $DIR/ovpn-connect.token ]] && files+=("$DIR/ovpn-connect.token")
  for f in "$DIR"/tokens/*.token; do [[ -f $f ]] && files+=("$f"); done

  if [[ ${#files[@]} -eq 0 ]]; then
    ui_info "هنوز توکنی ذخیره نشده. با «ساخت تانل» توکن ساخته می‌شود."
    ui_pause; return 0
  fi

  echo -e "  ${U_D}همه توکن‌های ذخیره‌شده:${U_0}"
  for f in "${files[@]}"; do
    local label trn
    label=$(basename "$f")
    trn=""
    [[ -f ${f%.token}.meta ]] && trn=$(grep '^transport=' "${f%.token}.meta" 2>/dev/null | cut -d= -f2-)
    ui_opt "$i" "$label" "${trn}"
    i=$((i+1))
  done
  ui_opt 0 "برگشت"
  local c; choose c "${#files[@]}" || return 0
  [[ $c == 0 ]] && return 0
  f=${files[$((c-1))]}
  ui_token_box "توکن: $(basename "$f")" "$(cat "$f")"
  echo
  if confirm "این توکن را به‌عنوان توکن فعال (connect.token) کپی کنم؟"; then
    mkdir -p "$DIR/tunlink"
    cp -f "$f" "$DIR/tunlink/connect.token"
    chmod 600 "$DIR/tunlink/connect.token"
    ui_ok "به‌عنوان توکن فعال ذخیره شد."
  fi
  ui_pause
}




proxy_settings_screen() {
  ui_banner
  ui_title "تنظیمات پروکسی تانل"
  echo -e "  ${U_D}پروکسی بالادستی فقط برای سمت کلاینت: اتصال به سرور از داخل SOCKS/HTTP${U_0}"
  echo
  echo -e "  ${U_B}الان:${U_0}"
  if [[ -f $DIR/tunlink/client.toml ]] && grep -q '^proxy' "$DIR/tunlink/client.toml" 2>/dev/null; then
    grep '^proxy' "$DIR/tunlink/client.toml" | sed 's/^/   /'
  else
    echo -e "   ${U_D}پروکسی تنظیم نشده (اتصال مستقیم)${U_0}"
  fi
  if [[ -f $DIR/tunlink/client.toml ]] && grep -q '^edge_ip' "$DIR/tunlink/client.toml" 2>/dev/null; then
    grep '^edge_ip' "$DIR/tunlink/client.toml" | sed 's/^/   /'
  fi
  echo
  ui_opt 1 "تنظیم SOCKS5"           "مثال: socks5://127.0.0.1:1080"
  ui_opt 2 "تنظیم HTTP CONNECT"     "مثال: http://proxy:8080"
  ui_opt 3 "تنظیم Edge IP (CDN)"    "TCP به IP لبه، SNI همان دامنه"
  ui_opt 4 "حذف پروکسی (مستقیم)"
  ui_opt 5 "اعمال و ری‌استارت کلاینت"
  ui_opt 0 "برگشت"
  local c; choose c 5 || return 0
  case "$c" in
    1)
      ask PROXY "آدرس SOCKS5" "socks5://127.0.0.1:1080" '.*' || return 0
      [[ $PROXY != socks5://* && $PROXY != socks5h://* ]] && PROXY="socks5://$PROXY"
      ;;
    2)
      ask PROXY "آدرس HTTP پروکسی" "http://127.0.0.1:8080" '.*' || return 0
      [[ $PROXY != http://* && $PROXY != https://* ]] && PROXY="http://$PROXY"
      ;;
    3)
      ask EDGE_IP "Edge IP" "" '^[0-9A-Fa-f.:]+$' || return 0
      if [[ -f $DIR/tunlink/client.toml ]]; then
        if grep -q '^edge_ip' "$DIR/tunlink/client.toml"; then
          sed -i "s|^edge_ip.*|edge_ip = \"$EDGE_IP\"|" "$DIR/tunlink/client.toml"
        else
          echo "edge_ip = \"$EDGE_IP\"" >> "$DIR/tunlink/client.toml"
        fi
        ui_ok "edge_ip ذخیره شد."
      else
        ui_err "client.toml نیست — اول با توکن وصل شوید."
      fi
      ui_pause; return 0
      ;;
    4)
      if [[ -f $DIR/tunlink/client.toml ]]; then
        sed -i '/^proxy\s*=/d' "$DIR/tunlink/client.toml"
        ui_ok "پروکسی حذف شد."
      fi
      ui_pause; return 0
      ;;
    5)
      if systemctl restart abtunnel-tunlink 2>/dev/null; then ui_ok "ری‌استارت شد."; else ui_err "سرویس نیست"; fi
      ui_pause; return 0
      ;;
    0) return 0;;
  esac
  # write proxy into client.toml for options 1/2
  if [[ -n ${PROXY:-} ]]; then
    if [[ ! -f $DIR/tunlink/client.toml ]]; then
      ui_err "اول کلاینت را با توکن وصل کنید، بعد پروکسی بگذارید."
      ui_pause; return 0
    fi
    if grep -q '^proxy' "$DIR/tunlink/client.toml"; then
      sed -i "s|^proxy.*|proxy = \"$PROXY\"|" "$DIR/tunlink/client.toml"
    else
      # insert after [client]
      sed -i "/^\[client\]/a proxy = \"$PROXY\"" "$DIR/tunlink/client.toml"
    fi
    ui_ok "پروکسی ذخیره شد: $PROXY"
    if confirm "الان کلاینت ری‌استارت شود؟"; then
      systemctl restart abtunnel-tunlink 2>/dev/null && ui_ok "ری‌استارت شد." || ui_err "ری‌استارت ناموفق"
    fi
  fi
  ui_pause
}


# -------------------------------------------------------- main interactive menu
wizard() {
  [[ $EUID -eq 0 ]] || die "لطفاً با sudo اجرا کنید:  sudo abtunnel"
  touch "$LOGFILE" 2>/dev/null || LOGFILE=/tmp/abtunnel.log
  while true; do
    ui_banner
    local n=0 active=0 u
    while read -r u; do [[ -n $u ]] || continue; n=$((n+1)); systemctl is-active --quiet "$u" 2>/dev/null && active=$((active+1)); done < <(tunnel_units)
    if (( n == 0 )); then echo -e "    ${U_D}○ هنوز تانلی ساخته نشده${U_0}"
    elif (( active == n )); then echo -e "    ${U_G}● $active تانل فعال${U_0}"
    else echo -e "    ${U_Y}● $active از $n تانل فعال${U_0}"; fi
    ui_line
    ui_opt 1 "ساخت تانل جدید"               "روی سرور اول — یک توکن می‌دهد"
    ui_opt 2 "وصل شدن با توکن"              "روی سرور دوم — توکن را Paste کنید"
    ui_opt 3 "وضعیت تانل‌ها"                 "سلامت + سوئیچ خودکار"
    ui_opt 4 "عیب‌یابی سریع (Doctor)"        "تست TCP بدون پینگ"
    ui_opt 5 "ری‌استارت تانل"
    ui_opt 6 "صندوق توکن‌ها"                "چند توکن همزمان"
    ui_opt 7 "سوئیچ خودکار (Failover)"      "اگر قطع شد → تانل بعدی"
    ui_opt 8 "پروفایل شبکه سخت (یک‌کلیکی)"  "HTTPS + Shape + Failover"
    ui_opt 9 "پنل وب وضعیت"                 "صفحه وضعیت روی مرورگر"
    ui_opt 10 "تنظیمات پروکسی تانل"         "SOCKS5 / HTTP / Edge IP"
    ui_opt 11 "تنظیمات پیشرفته"
    ui_opt 0 "خروج"
    ui_line
    local c; choose c 11 || exit 0
    case "$c" in
      1) easy_server;;
      2) easy_client;;
      3) status_screen;;
      4) doctor_screen;;
      5) restart_tunnel_screen;;
      6) token_vault_screen;;
      7) failover_screen;;
      8) hard_network_profile;;
      9) webpanel_screen;;
      10) proxy_settings_screen;;
      11) advanced_screen;;
      0) ui_clear; exit 0;;
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
    doctor) doctor_screen;;
    hardnet) hard_network_profile;;
    proxy) proxy_settings_screen;;
    webpanel) webpanel_screen;;
    tokens) token_vault_screen;;
    restart)
      # non-interactive restart of tunlink if present
      if systemctl list-units --type=service --all 2>/dev/null | grep -q abtunnel-tunlink; then
        systemctl restart abtunnel-tunlink && echo "tunlink restarted" || echo "restart failed"
      else
        restart_tunnel_screen
      fi
      ;;
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
    tunlink) local role="${1:-}"; shift || true; parse_args "$@"; if [[ $role == server ]]; then tunlink_server; else tunlink_client; fi;;
    *) echo "Usage: $0 {menu|connect <token>|doctor|restart|advanced|stunnel|ssh|ipsec|gre|ipip|sit|gre6|ip6ip6|openvpn|tunlink|forward|health|status|down|uninstall} ..."; echo "Easiest:  sudo $0   (opens the menu)"; exit 1;;
  esac
}
main "$@"
