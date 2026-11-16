#!/usr/bin/env bash
# tunlink-helper.sh — Reverse tunnel (TunLink) integration for tunxall
# Supports multi-server auto-selection based on health/stability.
set -euo pipefail

DIR=/etc/abtunnel
BH_DIR="$DIR/tunlink"
BH_BIN="$BH_DIR/tunlink"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_g="\e[32m"; c_r="\e[31m"; c_y="\e[33m"; c_0="\e[0m"
log()  { echo -e "${c_g}[+]${c_0} $*"; }
warn() { echo -e "${c_y}[!]${c_0} $*"; }
die()  { echo -e "${c_r}[x]${c_0} $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }

# Values below are written into TOML, so keep them to safe characters.
check_token()     { [[ $1 =~ ^[A-Za-z0-9_.-]+$ ]] || die "token may only contain letters, digits, '_', '.', '-'"; }
check_bool()      { [[ $1 == true || $1 == false ]] || die "expected true or false, got: $1"; }
check_proxy()     { [[ -z $1 || $1 =~ ^(socks5h?|socks|https?)://[A-Za-z0-9._~%:@-]+$ ]] || die "invalid proxy url (use socks5://host:port or http://host:port)"; }

# Older installs ran the same program as "abtunnel-backhaul". It would fight the
# new unit for the same ports, so stop it whenever tunlink is (re)configured.
bh_stop_legacy() {
  [[ -f /etc/systemd/system/abtunnel-backhaul.service ]] || return 0
  systemctl disable --now abtunnel-backhaul.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/abtunnel-backhaul.service
  systemctl daemon-reload 2>/dev/null || true
}

# normalize_ports LIST — accept almost any user input; never crash the menu
normalize_ports() {
  local raw="$1"
  raw=$(echo "$raw" | sed 's/۰/0/g;s/۱/1/g;s/۲/2/g;s/۳/3/g;s/۴/4/g;s/۵/5/g;s/۶/6/g;s/۷/7/g;s/۸/8/g;s/۹/9/g;s/٠/0/g;s/١/1/g;s/٢/2/g;s/٣/3/g;s/٤/4/g;s/٥/5/g;s/٦/6/g;s/٧/7/g;s/٨/8/g;s/٩/9/g')
  raw=$(echo "$raw" | tr ';|،' ',,,')
  raw=$(echo "$raw" | sed 's/[[:space:]]*,[[:space:]]*/,/g;s/[[:space:]]\+/,/g')
  raw=$(echo "$raw" | sed 's/^,\+//;s/,\+$//;s/,\+/,/g')
  [[ -z $raw ]] && { echo "443"; return 0; }

  local out=() item
  IFS=',' read -ra items <<< "$raw"
  for item in "${items[@]}"; do
    item=$(echo "$item" | xargs)
    [[ -z $item ]] && continue
    if [[ $item =~ ^[0-9]{1,5}$ ]]; then
      out+=("$item")
    elif [[ $item =~ ^[0-9]{1,5}-[0-9]{1,5}$ ]]; then
      out+=("$item")
    elif [[ $item =~ ^[0-9]{1,5}=[0-9]{1,5}$ ]]; then
      out+=("$item")
    elif [[ $item =~ ^[0-9]{1,5}=[0-9A-Fa-f.:]+$ ]]; then
      out+=("$item")
    elif [[ $item =~ ^[0-9]{1,5}-[0-9]{1,5}=[0-9A-Fa-f.:]+$ ]]; then
      out+=("$item")
    elif [[ $item =~ ^[0-9A-Fa-f.:]+=[0-9A-Fa-f.:]+$ ]]; then
      out+=("$item")
    elif [[ $item =~ ^[0-9]{1,5}:[0-9]{1,5}$ ]]; then
      out+=("${item%%:*}=${item##*:}")
    else
      local d
      d=$(echo "$item" | grep -oE '[0-9]{1,5}' | head -1 || true)
      [[ -n $d ]] && out+=("$d")
    fi
  done
  if [[ ${#out[@]} -eq 0 ]]; then
    echo "443"
  else
    local IFS=','
    echo "${out[*]}"
  fi
}

check_transport() { [[ $1 =~ ^(tcp|tcpmux|ws|wss|https|grpc|grpcs)$ ]] || die "transport must be tcp, tcpmux, ws, wss, https, grpc or grpcs"; }
check_addr()      { [[ $1 =~ ^[A-Za-z0-9.:\[\]-]+$ ]] || die "invalid address: $1"; }

# ---------- ensure binary ----------
TUNXALL_REPO="${TUNXALL_REPO:-arshiakhadmi16-bot/tunxall}"
GO_MIN_MINOR=22   # tunlink needs Go >= 1.22 when built from source

bh_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo amd64;;
    aarch64|arm64)  echo arm64;;
    armv7*|armv6*)  echo arm;;
    i?86)           echo 386;;
    *)              echo "";;
  esac
}

# 1) Prebuilt binary from the GitHub release (no Go needed).
bh_download_release() {
  local arch url tmp want got
  arch=$(bh_arch); [[ -n $arch ]] || return 1
  url="https://github.com/$TUNXALL_REPO/releases/download/tunlink-latest"
  tmp=$(mktemp -d)
  if curl -fsSL --retry 2 --max-time 120 -o "$tmp/tunlink" "$url/tunlink-linux-$arch" \
     && curl -fsSL --retry 2 --max-time 30 -o "$tmp/SHA256SUMS" "$url/SHA256SUMS"; then
    want=$(awk -v f="tunlink-linux-$arch" '$2==f {print $1}' "$tmp/SHA256SUMS")
    got=$(sha256sum "$tmp/tunlink" | awk '{print $1}')
    if [[ -n $want && $want == "$got" ]]; then
      install -m 755 "$tmp/tunlink" "$BH_BIN"
      rm -rf "$tmp"
      return 0
    fi
    warn "checksum mismatch for the downloaded tunlink binary — ignoring it"
  fi
  rm -rf "$tmp"
  return 1
}

go_ok() { # is a usable Go (>= 1.GO_MIN_MINOR) on PATH?
  command -v go >/dev/null 2>&1 || return 1
  local v; v=$(go env GOVERSION 2>/dev/null | sed -E 's/^go1\.([0-9]+).*/\1/')
  [[ $v =~ ^[0-9]+$ ]] && (( v >= GO_MIN_MINOR ))
}

# 2) Fallback: install a private Go toolchain (official tarball, or a mirror when
#    dl.google.com is unreachable) into /usr/local/lib/tunxall/go.
bh_install_go() {
  local arch ver file want got url tmp
  arch=$(bh_arch); [[ -n $arch ]] || return 1
  [[ $arch == arm ]] && arch=armv6l
  ver=$(curl -fsSL --max-time 15 "https://go.dev/VERSION?m=text" 2>/dev/null | head -1)
  [[ $ver =~ ^go1\.[0-9]+ ]] || ver=go1.23.4
  file="$ver.linux-$arch.tar.gz"
  want=$(curl -fsSL --max-time 15 "https://go.dev/dl/?mode=json" 2>/dev/null \
         | tr ',' '\n' | grep -A8 "\"filename\": *\"$file\"" | sed -nE 's/.*"sha256": *"([0-9a-f]{64})".*/\1/p' | head -1)
  tmp=$(mktemp -d)
  for url in "https://go.dev/dl/$file" "https://mirrors.aliyun.com/golang/$file" "https://golang.google.cn/dl/$file"; do
    curl -fsSL --retry 2 --max-time 600 -o "$tmp/go.tgz" "$url" 2>/dev/null || continue
    got=$(sha256sum "$tmp/go.tgz" | awk '{print $1}')
    # Without the official checksum, only trust the official download (over TLS).
    if [[ $want == "$got" || ( -z $want && $url == https://go.dev/* ) ]]; then
      rm -rf /usr/local/lib/tunxall/go && mkdir -p /usr/local/lib/tunxall
      tar -xzf "$tmp/go.tgz" -C /usr/local/lib/tunxall && rm -rf "$tmp"
      export PATH="/usr/local/lib/tunxall/go/bin:$PATH"
      return 0
    fi
  done
  rm -rf "$tmp"
  return 1
}

bh_build_from_source() {
  local src
  for src in "$SCRIPT_DIR/tunlink" /opt/tunxall/tunlink; do
    [[ -f $src/go.mod ]] || continue
    [[ -x /usr/local/lib/tunxall/go/bin/go ]] && export PATH="/usr/local/lib/tunxall/go/bin:$PATH"
    if ! go_ok; then
      log "Installing Go toolchain (one time, ~70MB)..."
      bh_install_go || return 1
    fi
    log "Building tunlink from source..."
    (cd "$src" && GOFLAGS=-mod=mod GOPROXY="https://proxy.golang.org,https://goproxy.cn,direct" \
       CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$BH_BIN" .) || return 1
    chmod +x "$BH_BIN"
    return 0
  done
  return 1
}

ensure_tunlink_bin() {
  [[ -x $BH_BIN ]] && return 0
  mkdir -p "$BH_DIR"
  log "Getting the tunlink program..."
  if bh_download_release; then
    log "TunLink ready (prebuilt)."
  elif bh_build_from_source; then
    log "TunLink ready (built from source)."
  else
    die "could not download or build tunlink — check this server's internet access and try again"
  fi
}

# ---------- server ----------
tunlink_server() {
  need_root
  ensure_tunlink_bin
  mkdir -p "$BH_DIR" && chmod 700 "$BH_DIR"

  local bind_port="${ACCEPT_PORT:-3080}"
  local token="${PSK:-$(openssl rand -hex 16)}"
  local transport="${TRANSPORT:-tcp}"
  local obfuscate="${OBFUSCATE:-true}"   # must match the client; carried in the token as OBF=
  local ports_list
  ports_list=$(normalize_ports "${PORTS:-443,8080}")
  check_token "$token"; check_transport "$transport"; check_bool "$obfuscate"
  # bind_port may come with spaces / persian digits
  bind_port=$(echo "$bind_port" | sed 's/۰/0/g;s/۱/1/g;s/۲/2/g;s/۳/3/g;s/۴/4/g;s/۵/5/g;s/۶/6/g;s/۷/7/g;s/۸/8/g;s/۹/9/g' | tr -dc '0-9')
  [[ $bind_port =~ ^[0-9]+$ ]] || die "invalid tunnel port: ${ACCEPT_PORT:-}"
  # If panel list accidentally equals only the tunnel port, keep it (user choice) but do not force collision fix here

  # TLS transports (wss / grpcs) need a certificate; create a self-signed one once.
  local tls_toml=""
  if [[ $transport == wss || $transport == https || $transport == grpcs ]]; then
    if [[ ! -f $BH_DIR/server.crt || ! -f $BH_DIR/server.key ]]; then
      log "Generating self-signed TLS certificate for $transport"
      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=tunxall" \
        -keyout "$BH_DIR/server.key" -out "$BH_DIR/server.crt" >/dev/null 2>&1 \
        || die "openssl failed to create a certificate"
      chmod 600 "$BH_DIR/server.key"
    fi
    tls_toml="tls_cert = \"$BH_DIR/server.crt\""$'\n'"tls_key = \"$BH_DIR/server.key\""
  fi

  # Build ports array for toml
  local ports_toml=""
  IFS=',' read -ra parr <<< "$ports_list"
  for p in "${parr[@]}"; do
    p=$(echo "$p" | xargs)
    [[ $p =~ ^[0-9A-Za-z.:=_-]+$ ]] || { warn "skipping odd port entry: $p"; continue; }
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
obfuscate = ${obfuscate}
${tls_toml}
ports = [
${ports_toml}]
EOF

  # systemd unit
  cat > /etc/systemd/system/abtunnel-tunlink.service <<EOF
[Unit]
Description=abtunnel tunlink reverse tunnel (server)
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

  bh_stop_legacy
  systemctl daemon-reload
  systemctl enable abtunnel-tunlink.service >/dev/null 2>&1 || true
  systemctl restart abtunnel-tunlink.service   # pick up the new config even if it was already running
  # Connection token for the other server (also saved so the menu can show it again)
  local pub="${PUBLIC_IP:-}"
  [[ -n $pub ]] || pub=$(curl -4 -fs --max-time 4 ifconfig.me 2>/dev/null || curl -4 -fs --max-time 4 icanhazip.com 2>/dev/null || echo "YOUR_PUBLIC_IP")
  local client_token obf=1
  [[ $obfuscate == true ]] || obf=0
  client_token=$(printf 'T=tunlink;PEER=%s;PORT=%s;TOKEN=%s;TRANSPORT=%s;OBF=%s' "$pub" "$bind_port" "$token" "$transport" "$obf" | base64 | tr -d '\n')
  printf '%s\n' "$client_token" > "$BH_DIR/connect.token"; chmod 600 "$BH_DIR/connect.token"
  # multi-token vault: keep every generated token with a label
  mkdir -p "$DIR/tokens" "$BH_DIR/tokens"
  local label="${TOKEN_LABEL:-default}"
  label=$(echo "$label" | tr -cd 'A-Za-z0-9._-' | head -c 40)
  [[ -z $label ]] && label=default
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  local vault="$DIR/tokens/${stamp}_${label}.token"
  printf '%s\n' "$client_token" > "$vault"
  chmod 600 "$vault"
  # also update "latest" pointer per label
  printf '%s\n' "$client_token" > "$DIR/tokens/latest_${label}.token"
  chmod 600 "$DIR/tokens/latest_${label}.token"
  # human metadata
  cat > "$DIR/tokens/${stamp}_${label}.meta" <<META
label=$label
transport=$transport
bind_port=$bind_port
peer=$pub
created=$(date -Iseconds)
file=$vault
META

  [[ -n ${BH_QUIET:-} ]] && return 0
  log "TunLink SERVER up on 0.0.0.0:${bind_port}  transport=${transport}"
  echo
  echo -e "${c_y}========== CLIENT TOKEN (copy this) ==========${c_0}"
  echo "$client_token"
  echo -e "${c_y}================================================${c_0}"
  echo
  log "On the other server:  sudo abtunnel connect <token>"
  log "Server config: $BH_DIR/server.toml"
}

# ---------- client (single or multi) ----------
tunlink_client() {
  need_root
  ensure_tunlink_bin
  mkdir -p "$BH_DIR" && chmod 700 "$BH_DIR"

  local transport="${TRANSPORT:-tcp}"
  local token="${PSK:-}"
  local pool="${CONNECTION_POOL:-8}"
  local obfuscate="${OBFUSCATE:-true}"   # must match the server (see OBF= in the token)

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
    die "tunlink client needs --peer or PEERS"
  fi

  [[ -n $token ]] || die "tunlink client needs token (--psk)"
  check_token "$token"; check_transport "$transport"
  [[ $pool =~ ^[0-9]+$ ]] || die "invalid connection pool size: $pool"
  check_bool "$obfuscate"; check_proxy "${PROXY:-}"
  [[ -z ${EDGE_IP:-} ]] || check_addr "$EDGE_IP"

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

  local proxy_toml=""
  if [[ -n ${PROXY:-} ]]; then
    proxy_toml="proxy = \"${PROXY}\""
  fi
  if [[ -n ${EDGE_IP:-} ]]; then
    proxy_toml="${proxy_toml}"$'\n'"edge_ip = \"${EDGE_IP}\""
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
obfuscate = ${obfuscate}
${proxy_toml}
health_check_interval = 30
health_check_timeout  = 3
min_success_rate      = 70
switch_threshold_ms   = 50
EOF

  cat > /etc/systemd/system/abtunnel-tunlink.service <<EOF
[Unit]
Description=abtunnel tunlink reverse tunnel (client)
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

  bh_stop_legacy
  systemctl daemon-reload
  systemctl enable abtunnel-tunlink.service >/dev/null 2>&1 || true
  systemctl restart abtunnel-tunlink.service   # pick up the new config even if it was already running
  [[ -n ${BH_QUIET:-} ]] && return 0
  log "TunLink CLIENT started"
  log "Config: $BH_DIR/client.toml"
  if [[ ${#addrs[@]} -gt 1 ]]; then
    log "Auto-selection enabled — will pick the most stable server every 30s"
  fi
  log "Status:  systemctl status abtunnel-tunlink"
}

# ---------- connect from token ----------
tunlink_connect_token() {
  local tok="$1"
  local decoded
  decoded=$(echo "$tok" | base64 -d 2>/dev/null || true)
  [[ -n $decoded ]] || die "invalid token"

  # Parse KEY=VALUE pairs explicitly — never eval data pasted by the user.
  local T="" PEER="" PORT="" TOKEN="" TRANSPORT="" OBF="" kv
  local -a parts
  IFS=';' read -ra parts <<< "$decoded"
  for kv in "${parts[@]}"; do
    case "$kv" in
      T=*)         T="${kv#T=}";;
      PEER=*)      PEER="${kv#PEER=}";;
      PORT=*)      PORT="${kv#PORT=}";;
      TOKEN=*)     TOKEN="${kv#TOKEN=}";;
      TRANSPORT=*) TRANSPORT="${kv#TRANSPORT=}";;
      OBF=*)       OBF="${kv#OBF=}";;
    esac
  done
  [[ $PORT =~ ^[0-9]+$ ]] || die "invalid port in token"
  [[ $TOKEN =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid secret in token"
  [[ -z $TRANSPORT || $TRANSPORT =~ ^(tcp|tcpmux|ws|wss|https|grpc|grpcs)$ ]] || die "invalid transport in token"

  # Padding must match the server. Tokens without OBF= come from tunlink servers
  # that always padded; "backhaul" tokens come from older servers that never did.
  local obfuscate=true
  case ${T:-} in
    tunlink)  [[ $OBF == 0 ]] && obfuscate=false;;
    backhaul) obfuscate=false;;
    *)        die "not a tunlink token";;
  esac
  [[ -n ${PEER:-} && -n ${PORT:-} && -n ${TOKEN:-} ]] || die "incomplete tunlink token"

  PEER="$PEER" ACCEPT_PORT="$PORT" PSK="$TOKEN" TRANSPORT="${TRANSPORT:-tcp}" OBFUSCATE="$obfuscate" tunlink_client
}

# ---------- status / down helpers (called from abtunnel) ----------
tunlink_status() {
  systemctl --no-pager status abtunnel-tunlink.service 2>/dev/null || echo "  (tunlink not running)"
  if [[ -f $BH_DIR/client.toml ]]; then
    echo "--- client config ---"
    grep -E 'remote_|token|transport|health_' "$BH_DIR/client.toml" || true
  fi
  if [[ -f $BH_DIR/server.toml ]]; then
    echo "--- server config ---"
    grep -E 'bind_addr|token|transport|ports' "$BH_DIR/server.toml" || true
  fi
}

tunlink_down() {
  systemctl disable --now abtunnel-tunlink.service 2>/dev/null || true
  rm -f /etc/systemd/system/abtunnel-tunlink.service
  bh_stop_legacy
  systemctl daemon-reload 2>/dev/null || true
  log "TunLink stopped and unit removed"
}


# ---------- multi-token vault ----------
tunlink_list_tokens() {
  mkdir -p "$DIR/tokens"
  local f
  if ! ls "$DIR/tokens"/*.token >/dev/null 2>&1; then
    echo "(empty)"
    return 0
  fi
  for f in "$DIR/tokens"/*.token; do
    [[ -f $f ]] || continue
    local base meta_label meta_tr
    base=$(basename "$f" .token)
    meta_label=""; meta_tr=""
    if [[ -f ${f%.token}.meta ]]; then
      meta_label=$(grep '^label=' "${f%.token}.meta" | cut -d= -f2-)
      meta_tr=$(grep '^transport=' "${f%.token}.meta" | cut -d= -f2-)
    fi
    printf '%s  label=%s  transport=%s\n' "$base" "${meta_label:-?}" "${meta_tr:-?}"
  done
}

tunlink_show_token() {
  local name="${1:-}"
  [[ -n $name ]] || die "token name required"
  local f
  if [[ -f $DIR/tokens/$name ]]; then f="$DIR/tokens/$name"
  elif [[ -f $DIR/tokens/$name.token ]]; then f="$DIR/tokens/$name.token"
  elif [[ -f $DIR/tokens/latest_${name}.token ]]; then f="$DIR/tokens/latest_${name}.token"
  else die "token not found: $name"
  fi
  cat "$f"
}
