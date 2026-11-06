#!/usr/bin/env bash
# backhaul-helper.sh — Reverse tunnel (Backhaul) integration for tunxall
# Supports multi-server auto-selection based on health/stability.
set -euo pipefail

DIR=/etc/abtunnel
BH_DIR="$DIR/backhaul"
BH_BIN="$BH_DIR/backhaul"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_g="\e[32m"; c_r="\e[31m"; c_y="\e[33m"; c_0="\e[0m"
log()  { echo -e "${c_g}[+]${c_0} $*"; }
warn() { echo -e "${c_y}[!]${c_0} $*"; }
die()  { echo -e "${c_r}[x]${c_0} $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }

# Values below are written into TOML, so keep them to safe characters.
check_token()     { [[ $1 =~ ^[A-Za-z0-9_.-]+$ ]] || die "token may only contain letters, digits, '_', '.', '-'"; }
check_transport() { [[ $1 =~ ^(tcp|tcpmux|ws|wss|grpc|grpcs)$ ]] || die "transport must be tcp, tcpmux, ws, wss, grpc or grpcs"; }
check_addr()      { [[ $1 =~ ^[A-Za-z0-9.:\[\]-]+$ ]] || die "invalid address: $1"; }

# ---------- ensure binary ----------
ensure_backhaul_bin() {
  if [[ -x $BH_BIN ]]; then
    return 0
  fi
  mkdir -p "$BH_DIR"
  # Try to build from bundled source (next to this script, or where install.sh put it)
  local src
  for src in "$SCRIPT_DIR/backhaul" /opt/tunxall/backhaul; do
    [[ -f $src/go.mod ]] || continue
    command -v go >/dev/null 2>&1 || die "Go is needed to build backhaul (Go >= 1.22): https://go.dev/doc/install"
    log "Building backhaul from source ($src)..."
    (cd "$src" && go build -o "$BH_BIN" .) || die "go build failed (Go >= 1.22 required; you have: $(go version 2>/dev/null))"
    chmod +x "$BH_BIN"
    log "Backhaul binary ready: $BH_BIN"
    return 0
  done
  die "backhaul binary not found and no source to build it (re-run install.sh, or place the binary at $BH_BIN)"
}

# ---------- server ----------
backhaul_server() {
  need_root
  ensure_backhaul_bin
  mkdir -p "$BH_DIR" && chmod 700 "$BH_DIR"

  local bind_port="${ACCEPT_PORT:-3080}"
  local token="${PSK:-$(openssl rand -hex 16)}"
  local transport="${TRANSPORT:-tcp}"
  local ports_list="${PORTS:-443,8080}"
  check_token "$token"; check_transport "$transport"
  [[ $bind_port =~ ^[0-9]+$ ]] || die "invalid port: $bind_port"

  # TLS transports (wss / grpcs) need a certificate; create a self-signed one once.
  local tls_toml=""
  if [[ $transport == wss || $transport == grpcs ]]; then
    if [[ ! -f $BH_DIR/server.crt || ! -f $BH_DIR/server.key ]]; then
      log "Generating self-signed TLS certificate for $transport"
      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=tunxall"         -keyout "$BH_DIR/server.key" -out "$BH_DIR/server.crt" >/dev/null 2>&1         || die "openssl failed to create a certificate"
      chmod 600 "$BH_DIR/server.key"
    fi
    tls_toml="tls_cert = \"$BH_DIR/server.crt\""$'
'"tls_key = \"$BH_DIR/server.key\""
  fi

  # Build ports array for toml
  local ports_toml=""
  IFS=',' read -ra parr <<< "$ports_list"
  for p in "${parr[@]}"; do
    p=$(echo "$p" | xargs)
    [[ $p =~ ^[0-9A-Za-z.:=-]+$ ]] || die "invalid port mapping: $p"
    ports_toml+="  \"$p\","$'\n'
  done

  cat > "$BH_DIR/server.toml" <<EOF
[server]
bind_addr = "0.0.0.0:${bind_port}"
transport = "${transport}"
token = "${token}"
keepalive_period = 75
channel_size = 2048
heartbeat = 40
mux_con = 8
mux_version = 1
log_level = "info"
${tls_toml}
ports = [
${ports_toml}]
EOF

  # systemd unit
  cat > /etc/systemd/system/abtunnel-backhaul.service <<EOF
[Unit]
Description=abtunnel backhaul reverse tunnel (server)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BH_BIN -c $BH_DIR/server.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable abtunnel-backhaul.service >/dev/null 2>&1 || true
  systemctl restart abtunnel-backhaul.service   # pick up the new config even if it was already running
  log "Backhaul SERVER up on 0.0.0.0:${bind_port}  transport=${transport}"
  echo
  echo -e "${c_y}========== CLIENT TOKEN (copy this) ==========${c_0}"
  # Token format for easy client setup
  local pub
  pub=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || curl -4 -s --max-time 3 icanhazip.com 2>/dev/null || echo "YOUR_PUBLIC_IP")
  local client_token
  client_token=$(printf 'T=backhaul;PEER=%s;PORT=%s;TOKEN=%s;TRANSPORT=%s' "$pub" "$bind_port" "$token" "$transport" | base64 -w0 2>/dev/null || printf 'T=backhaul;PEER=%s;PORT=%s;TOKEN=%s;TRANSPORT=%s' "$pub" "$bind_port" "$token" "$transport" | base64)
  echo "$client_token"
  echo -e "${c_y}================================================${c_0}"
  echo
  log "Or configure client manually with token: ${token}"
  log "Server config: $BH_DIR/server.toml"
}

# ---------- client (single or multi) ----------
backhaul_client() {
  need_root
  ensure_backhaul_bin
  mkdir -p "$BH_DIR" && chmod 700 "$BH_DIR"

  local transport="${TRANSPORT:-tcp}"
  local token="${PSK:-}"
  local pool="${CONNECTION_POOL:-8}"

  # Support multiple peers: PEER can be "ip1:port,ip2:port" or single
  local addrs=()
  if [[ -n "${PEERS:-}" ]]; then
    IFS=',' read -ra addrs <<< "$PEERS"
  elif [[ -n "${PEER:-}" ]]; then
    # PEER may already contain :port
    if [[ "$PEER" == *:* ]]; then
      addrs=("$PEER")
    else
      addrs=("${PEER}:${ACCEPT_PORT:-3080}")
    fi
  else
    die "backhaul client needs --peer or PEERS"
  fi

  [[ -n $token ]] || die "backhaul client needs token (--psk)"
  check_token "$token"; check_transport "$transport"
  [[ $pool =~ ^[0-9]+$ ]] || die "invalid connection pool size: $pool"

  # Build toml
  local remote_block=""
  if [[ ${#addrs[@]} -gt 1 ]]; then
    remote_block="remote_addrs = ["$'\n'
    for a in "${addrs[@]}"; do
      a=$(echo "$a" | xargs)
      check_addr "$a"
      remote_block+="  \"$a\","$'\n'
    done
    remote_block+="]"
    log "Multi-server mode: ${addrs[*]}"
  else
    addrs[0]=$(echo "${addrs[0]}" | xargs); check_addr "${addrs[0]}"
    remote_block="remote_addr = \"${addrs[0]}\""
    log "Single-server mode: ${addrs[0]}"
  fi

  cat > "$BH_DIR/client.toml" <<EOF
[client]
${remote_block}
transport = "${transport}"
token = "${token}"
connection_pool = ${pool}
aggressive_pool = false
keepalive_period = 75
retry_interval = 3
dial_timeout = 10
log_level = "info"
health_check_interval = 30
health_check_timeout  = 3
min_success_rate      = 70
switch_threshold_ms   = 50
EOF

  cat > /etc/systemd/system/abtunnel-backhaul.service <<EOF
[Unit]
Description=abtunnel backhaul reverse tunnel (client)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BH_BIN -c $BH_DIR/client.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable abtunnel-backhaul.service >/dev/null 2>&1 || true
  systemctl restart abtunnel-backhaul.service   # pick up the new config even if it was already running
  log "Backhaul CLIENT started"
  log "Config: $BH_DIR/client.toml"
  if [[ ${#addrs[@]} -gt 1 ]]; then
    log "Auto-selection enabled — will pick the most stable server every 30s"
  fi
  log "Status:  systemctl status abtunnel-backhaul"
}

# ---------- connect from token ----------
backhaul_connect_token() {
  local tok="$1"
  local decoded
  decoded=$(echo "$tok" | base64 -d 2>/dev/null || true)
  [[ -n $decoded ]] || die "invalid token"

  # Parse KEY=VALUE pairs explicitly — never eval data pasted by the user.
  local T="" PEER="" PORT="" TOKEN="" TRANSPORT="" kv
  local -a parts
  IFS=';' read -ra parts <<< "$decoded"
  for kv in "${parts[@]}"; do
    case "$kv" in
      T=*)         T="${kv#T=}";;
      PEER=*)      PEER="${kv#PEER=}";;
      PORT=*)      PORT="${kv#PORT=}";;
      TOKEN=*)     TOKEN="${kv#TOKEN=}";;
      TRANSPORT=*) TRANSPORT="${kv#TRANSPORT=}";;
    esac
  done
  [[ $PORT =~ ^[0-9]+$ ]] || die "invalid port in token"
  [[ $TOKEN =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid secret in token"
  [[ -z $TRANSPORT || $TRANSPORT =~ ^(tcp|tcpmux|ws|wss|grpc|grpcs)$ ]] || die "invalid transport in token"

  [[ ${T:-} == backhaul ]] || die "not a backhaul token"
  [[ -n ${PEER:-} && -n ${PORT:-} && -n ${TOKEN:-} ]] || die "incomplete backhaul token"

  PEER="$PEER" ACCEPT_PORT="$PORT" PSK="$TOKEN" TRANSPORT="${TRANSPORT:-tcp}" backhaul_client
}

# ---------- status / down helpers (called from abtunnel) ----------
backhaul_status() {
  systemctl --no-pager status abtunnel-backhaul.service 2>/dev/null || echo "  (backhaul not running)"
  if [[ -f $BH_DIR/client.toml ]]; then
    echo "--- client config ---"
    grep -E 'remote_|token|transport|health_' "$BH_DIR/client.toml" || true
  fi
  if [[ -f $BH_DIR/server.toml ]]; then
    echo "--- server config ---"
    grep -E 'bind_addr|token|transport|ports' "$BH_DIR/server.toml" || true
  fi
}

backhaul_down() {
  systemctl disable --now abtunnel-backhaul.service 2>/dev/null || true
  rm -f /etc/systemd/system/abtunnel-backhaul.service
  systemctl daemon-reload 2>/dev/null || true
  log "Backhaul stopped and unit removed"
}
