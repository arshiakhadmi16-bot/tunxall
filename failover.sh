#!/usr/bin/env bash
# failover.sh — Intelligent multi-tunnel failover (TCP health, no ICMP required)
set -euo pipefail

DIR=/etc/abtunnel
STATE="$DIR/failover"
LIST="$STATE/tunnels.list"
ACTIVE="$STATE/active"
LOG="${LOGFILE:-/var/log/abtunnel-failover.log}"
CHECK_INTERVAL="${CHECK_INTERVAL:-20}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"

c_g="\e[32m"; c_r="\e[31m"; c_y="\e[33m"; c_c="\e[36m"; c_0="\e[0m"
log()  { echo -e "$(date '+%F %T') ${c_g}[+]${c_0} $*" | tee -a "$LOG"; }
warn() { echo -e "$(date '+%F %T') ${c_y}[!]${c_0} $*" | tee -a "$LOG"; }
err()  { echo -e "$(date '+%F %T') ${c_r}[x]${c_0} $*" | tee -a "$LOG"; }

need_root() { [[ $EUID -eq 0 ]] || { echo "need root"; exit 1; }; }
mkdir -p "$STATE"
touch "$LOG" 2>/dev/null || LOG=/tmp/abtunnel-failover.log

# Canonical kind → systemd unit (one unit per real tunnel stack)
unit_for() {
  case "$1" in
    tunlink|noping|https) echo abtunnel-tunlink;;
    openvpn)              echo abtunnel-openvpn;;
    gre)                  echo abtunnel-gre;;
    ipip)                 echo abtunnel-ipip;;
    wireguard|wg)         echo wg-quick@wg0;;
    ssh)                  echo abtunnel-ssh;;
    stunnel)              echo abtunnel-stunnel;;
    ipsec)                echo strongswan-starter;;
    *)                    echo "abtunnel-$1";;
  esac
}

# Collapse aliases that share the same unit so the list has unique targets
canonical_kind() {
  case "$1" in
    noping|https|tunlink) echo tunlink;;
    wireguard|wg)         echo wireguard;;
    *)                    echo "$1";;
  esac
}

peer_ip_for() {
  case "$(canonical_kind "$1")" in
    openvpn)   echo 10.30.0.1;;
    gre)       echo 10.20.0.1;;
    ipip)      echo 10.40.0.1;;
    wireguard) echo 10.10.0.1;;
    *)         echo "";;
  esac
}

tcp_open() {
  local host="$1" port="$2" timeout="${3:-3}"
  timeout "$timeout" bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
}

tunlink_remote_port() {
  local cfg line
  cfg="$DIR/tunlink/client.toml"
  if [[ -f $cfg ]]; then
    line=$(grep -E 'remote_addr\s*=' "$cfg" 2>/dev/null | head -1 || true)
    if [[ $line =~ :([0-9]+)\" ]]; then echo "${BASH_REMATCH[1]}"; return; fi
    line=$(grep -oE '"[^"]+:[0-9]+"' "$cfg" 2>/dev/null | head -1 || true)
    if [[ $line =~ :([0-9]+)\" ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  fi
  cfg="$DIR/tunlink/server.toml"
  if [[ -f $cfg ]]; then
    line=$(grep -E 'bind_addr\s*=' "$cfg" 2>/dev/null | head -1 || true)
    if [[ $line =~ :([0-9]+)\" ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  fi
  echo ""
}

tunlink_peer_host() {
  local cfg="$DIR/tunlink/client.toml" line
  [[ -f $cfg ]] || { echo ""; return; }
  line=$(grep -E 'remote_addr\s*=' "$cfg" 2>/dev/null | head -1 || true)
  if [[ $line =~ \"([^:\"]+): ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  line=$(grep -oE '"[^"]+:[0-9]+"' "$cfg" 2>/dev/null | head -1 | tr -d '"' || true)
  echo "${line%%:*}"
}

# Strict health for tunlink: unit UP + (recent control channel OR working TCP to peer)
# Soft "no errors in log" alone is NOT enough anymore.
is_healthy_tunlink() {
  local unit="abtunnel-tunlink"
  systemctl is-active --quiet "$unit" 2>/dev/null || return 1

  # Hard fail on recent critical errors
  if journalctl -u "$unit" --since "90 sec ago" --no-pager 2>/dev/null \
      | grep -Eqi 'failed to (dial|connect|handshake)|connection refused|i/o timeout|no such host|authentication failed|invalid token'; then
    return 1
  fi

  # Strong positive: control channel established recently
  if journalctl -u "$unit" --since "3 min ago" --no-pager 2>/dev/null \
      | grep -Eqi 'control channel established'; then
    return 0
  fi

  # Client side: TCP reachability to peer tunnel port
  local host port
  host=$(tunlink_peer_host)
  port=$(tunlink_remote_port)
  if [[ -n $host && -n $port ]]; then
    if tcp_open "$host" "$port" 3; then
      # TCP open is necessary but not sufficient alone — require either
      # control-channel evidence in last 10 min OR service active > 30s without errors
      if journalctl -u "$unit" --since "10 min ago" --no-pager 2>/dev/null \
          | grep -Eqi 'control channel established|session|Connected'; then
        return 0
      fi
      # If just restarted, give a brief grace only when ActiveEnterTimestamp is fresh
      local active_sec
      active_sec=$(systemctl show -p ActiveEnterTimestamp --value "$unit" 2>/dev/null || true)
      if [[ -n $active_sec && $active_sec != "n/a" ]]; then
        local epoch now age
        epoch=$(date -d "$active_sec" +%s 2>/dev/null || echo 0)
        now=$(date +%s)
        age=$((now - epoch))
        # grace window 45s after start while TCP works
        (( age < 45 )) && return 0
      fi
      return 1
    fi
    return 1
  fi

  # Server side (no client.toml peer): require recent control-channel OR listener evidence
  if [[ -f $DIR/tunlink/server.toml ]]; then
    if journalctl -u "$unit" --since "10 min ago" --no-pager 2>/dev/null \
        | grep -Eqi 'control channel established|server starting|listening|WebSocket server|TCP server'; then
      return 0
    fi
    # listener port open locally?
    port=$(tunlink_remote_port)
    if [[ -n $port ]] && tcp_open "127.0.0.1" "$port" 1; then
      return 0
    fi
    return 1
  fi

  return 1
}

is_healthy() {
  local kind raw
  raw="$1"
  kind=$(canonical_kind "$raw")
  local unit; unit=$(unit_for "$kind")

  systemctl is-active --quiet "$unit" 2>/dev/null || return 1

  case "$kind" in
    tunlink)
      is_healthy_tunlink
      return $?
      ;;
    ssh|stunnel)
      return 0
      ;;
    openvpn|gre|ipip|wireguard)
      local tip; tip=$(peer_ip_for "$kind")
      [[ -z $tip ]] && return 0
      local p
      for p in 22 80 443 8080; do
        tcp_open "$tip" "$p" 1 && return 0
      done
      local p6=""; [[ $tip == *:* ]] && p6="-6"
      if ping $p6 -c1 -W1 "$tip" >/dev/null 2>&1; then
        return 0
      fi
      if ip -br addr 2>/dev/null | grep -Eq 'tun|tap|wg|gre|ipip'; then
        return 0
      fi
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

start_tunnel() {
  local kind unit
  kind=$(canonical_kind "$1")
  unit=$(unit_for "$kind")
  systemctl start "$unit" 2>/dev/null || true
  sleep 2
}

stop_tunnel() {
  local kind unit
  kind=$(canonical_kind "$1")
  unit=$(unit_for "$kind")
  systemctl stop "$unit" 2>/dev/null || true
}

# Load list, de-duplicate by canonical kind, preserve order
load_list() {
  [[ -f $LIST ]] || return 1
  TUNNELS=()
  local seen="|" t c
  while read -r t; do
    [[ -z $t || $t == \#* ]] && continue
    c=$(canonical_kind "$t")
    [[ $seen == *"|$c|"* ]] && continue
    TUNNELS+=("$c")
    seen+="${c}|"
  done < "$LIST"
  (( ${#TUNNELS[@]} > 0 ))
}

set_active() { echo "$(canonical_kind "$1")" > "$ACTIVE"; }
get_active() { [[ -f $ACTIVE ]] && canonical_kind "$(cat "$ACTIVE")" || echo ""; }

run_loop() {
  need_root
  load_list || { err "no tunnel list at $LIST — run: failover configure"; exit 1; }

  local fails=0 current
  current=$(get_active)
  if [[ -z $current ]] || ! printf '%s\n' "${TUNNELS[@]}" | grep -qx "$current"; then
    current="${TUNNELS[0]}"
    set_active "$current"
    start_tunnel "$current"
  fi

  log "failover started — unique tunnels: [${TUNNELS[*]}]  active=$current  interval=${CHECK_INTERVAL}s threshold=$FAIL_THRESHOLD"

  while true; do
    # reload list each loop so UI edits apply without full restart
    load_list || true
    if [[ ${#TUNNELS[@]} -eq 0 ]]; then
      warn "tunnel list empty"; sleep "$CHECK_INTERVAL"; continue
    fi
    # if active removed from list, jump to first
    if ! printf '%s\n' "${TUNNELS[@]}" | grep -qx "$current"; then
      current="${TUNNELS[0]}"
      set_active "$current"
      start_tunnel "$current"
      fails=0
    fi

    if is_healthy "$current"; then
      fails=0
    else
      fails=$((fails + 1))
      warn "health failed [$current] ($fails/$FAIL_THRESHOLD)"
      if (( fails >= FAIL_THRESHOLD )); then
        local idx next found=0 i
        for i in "${!TUNNELS[@]}"; do
          if [[ ${TUNNELS[$i]} == "$current" ]]; then idx=$i; found=1; break; fi
        done
        if (( found )); then
          next="${TUNNELS[$(( (idx + 1) % ${#TUNNELS[@]} ))]}"
        else
          next="${TUNNELS[0]}"
        fi
        # skip if only one unique tunnel
        if [[ $next == "$current" ]]; then
          warn "only one tunnel in list — restarting $current"
          stop_tunnel "$current"
          start_tunnel "$current"
          fails=0
        else
          warn "switching: $current → $next"
          stop_tunnel "$current"
          start_tunnel "$next"
          current=$next
          set_active "$current"
          fails=0
          if is_healthy "$next"; then log "switched OK to $next"; else warn "next $next not confirmed yet"; fi
        fi
      fi
    fi
    sleep "$CHECK_INTERVAL"
  done
}

# Default list: unique real stacks only
cmd_configure() {
  need_root
  mkdir -p "$STATE"
  # Prefer stacks that actually have a unit installed
  local candidates=(tunlink openvpn gre ipip wireguard) out=() c unit
  for c in "${candidates[@]}"; do
    unit=$(unit_for "$c")
    if systemctl list-unit-files 2>/dev/null | grep -q "^${unit}"; then
      out+=("$c")
    elif [[ -f /etc/systemd/system/${unit}.service ]] || [[ -f /lib/systemd/system/${unit}.service ]]; then
      out+=("$c")
    fi
  done
  # Always include tunlink first as primary reverse tunnel even if unit not yet created
  if [[ ${#out[@]} -eq 0 ]] || ! printf '%s\n' "${out[@]}" | grep -qx tunlink; then
    out=(tunlink "${out[@]}")
  fi
  # de-dup
  local seen="|" final=()
  for c in "${out[@]}"; do
    c=$(canonical_kind "$c")
    [[ $seen == *"|$c|"* ]] && continue
    final+=("$c"); seen+="${c}|"
  done

  {
    echo "# ordered unique tunnel list (first = highest priority)"
    echo "# edited by: sudo abtunnel → Failover → ویرایش ترتیب"
    printf '%s\n' "${final[@]}"
  } > "$LIST"
  log "list written to $LIST"
  cat "$LIST"
}

# Write list from args or stdin lines
cmd_set_list() {
  need_root
  mkdir -p "$STATE"
  local items=() x c seen="|"
  if [[ $# -gt 0 ]]; then
    items=("$@")
  else
    while read -r x; do
      [[ -z $x || $x == \#* ]] && continue
      items+=("$x")
    done
  fi
  {
    echo "# ordered unique tunnel list (first = highest priority)"
    for x in "${items[@]}"; do
      c=$(canonical_kind "$x")
      [[ $seen == *"|$c|"* ]] && continue
      echo "$c"
      seen+="${c}|"
    done
  } > "$LIST"
  log "list updated:"
  grep -v '^#' "$LIST" || true
}

cmd_status() {
  echo -e "${c_c}══ Failover Status ══${c_0}"
  echo "interval=${CHECK_INTERVAL}s  threshold=${FAIL_THRESHOLD}  (no ICMP required)"
  if [[ -f $LIST ]]; then
    local i=1 a t h mark seen="|"
    a=$(get_active)
    while read -r t; do
      [[ -z $t || $t == \#* ]] && continue
      t=$(canonical_kind "$t")
      [[ $seen == *"|$t|"* ]] && continue
      seen+="${t}|"
      mark=" "; [[ $t == "$a" ]] && mark="→"
      h="DOWN"; is_healthy "$t" && h="UP" || true
      printf "  %s %d) %-12s  %s  (%s)\n" "$mark" "$i" "$t" "$h" "$(unit_for "$t")"
      i=$((i+1))
    done < "$LIST"
    (( i == 1 )) && echo "  (list empty)"
  else
    echo "  (not configured — run: install or configure)"
  fi
  echo
  systemctl is-active --quiet abtunnel-failover 2>/dev/null \
    && echo -e "Supervisor: ${c_g}running${c_0}" \
    || echo -e "Supervisor: ${c_r}stopped${c_0}"
}

cmd_install_unit() {
  need_root
  local self; self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  cat > /etc/systemd/system/abtunnel-failover.service <<UNIT
[Unit]
Description=tunxall tunnel failover (TCP health, unique targets)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=CHECK_INTERVAL=${CHECK_INTERVAL}
Environment=FAIL_THRESHOLD=${FAIL_THRESHOLD}
ExecStart=/usr/bin/env bash $self run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now abtunnel-failover.service
  log "failover supervisor installed"
}

cmd_stop() {
  systemctl disable --now abtunnel-failover.service 2>/dev/null || true
  log "failover stopped"
}

case "${1:-}" in
  run)       run_loop;;
  configure) cmd_configure;;
  set-list)  shift; cmd_set_list "$@";;
  status)    cmd_status;;
  install)   cmd_configure; cmd_install_unit;;
  stop)      cmd_stop;;
  *)         echo "Usage: $0 {run|configure|set-list|status|install|stop}"; exit 1;;
esac
