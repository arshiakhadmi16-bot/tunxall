#!/usr/bin/env bash
# failover.sh — Intelligent multi-tunnel failover + health watchdog for tunxall
#
# Monitors the active tunnel; on sustained failure it switches to the next
# tunnel that is actually installed AND comes up healthy. It never tears down a
# working tunnel to chase one that isn't set up, so enabling failover can't take
# a healthy link down.
set -uo pipefail

DIR=/etc/abtunnel
STATE="$DIR/failover"
LIST="$STATE/tunnels.list"          # ordered list of tunnel kinds
ACTIVE="$STATE/active"              # currently active kind
LOG="${LOGFILE:-/var/log/abtunnel-failover.log}"
CHECK_INTERVAL="${CHECK_INTERVAL:-20}"   # seconds between health checks
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"    # consecutive failures before switch
SWITCH_PROBES="${SWITCH_PROBES:-5}"      # health retries after starting a candidate

# every tunnel kind failover understands, in default priority order
ALL_KINDS=(backhaul openvpn gre ipip sit gre6 ip6ip6 wireguard ssh stunnel)

c_g="\e[32m"; c_r="\e[31m"; c_y="\e[33m"; c_c="\e[36m"; c_0="\e[0m"
log()  { echo -e "$(date '+%F %T') ${c_g}[+]${c_0} $*" | tee -a "$LOG"; }
warn() { echo -e "$(date '+%F %T') ${c_y}[!]${c_0} $*" | tee -a "$LOG"; }
err()  { echo -e "$(date '+%F %T') ${c_r}[x]${c_0} $*" | tee -a "$LOG"; }

need_root() { [[ $EUID -eq 0 ]] || { echo "need root"; exit 1; }; }

mkdir -p "$STATE" 2>/dev/null || true
touch "$LOG" 2>/dev/null || LOG=/tmp/abtunnel-failover.log

# ---------- unit / install mapping ----------
unit_for() {
  case "$1" in
    backhaul)     echo abtunnel-backhaul;;
    openvpn)      echo abtunnel-openvpn;;
    gre)          echo abtunnel-gre;;
    ipip)         echo abtunnel-ipip;;
    sit)          echo abtunnel-sit;;
    gre6)         echo abtunnel-gre6;;
    ip6ip6)       echo abtunnel-ip6ip6;;
    wireguard|wg) echo wg-quick@wg0;;
    ssh)          echo abtunnel-ssh;;
    stunnel)      echo abtunnel-stunnel;;
    *)            echo "abtunnel-$1";;
  esac
}

# is_installed <kind> — true only if this tunnel is actually configured on this
# host (its systemd unit / config exists). Used so failover never switches to a
# tunnel that was never set up.
is_installed() {
  local kind="$1" unit; unit=$(unit_for "$kind")
  case "$kind" in
    wireguard|wg) [[ -f /etc/wireguard/wg0.conf ]];;
    *)            [[ -f "/etc/systemd/system/$unit.service" ]];;
  esac
}

peer_ip_for() {
  case "$1" in
    openvpn)      echo 10.30.0.1;;
    gre)          echo 10.20.0.1;;
    ipip)         echo 10.40.0.1;;
    sit)          echo fd60::1;;
    gre6)         echo fd20::1;;
    ip6ip6)       echo fd40::1;;
    wireguard|wg) echo 10.10.0.1;;
    *)            echo "";;
  esac
}

is_healthy() {
  local kind="$1" unit; unit=$(unit_for "$kind")
  systemctl is-active --quiet "$unit" 2>/dev/null || return 1
  # For interface tunnels, ping the peer's inner IP (ICMP inside the tunnel is
  # virtually always allowed, even when it's blocked on the public path).
  local tip; tip=$(peer_ip_for "$kind")
  if [[ -n $tip ]]; then
    local p6=""; [[ $tip == *:* ]] && p6="-6"
    ping $p6 -c1 -W2 "$tip" >/dev/null 2>&1 || return 1
  fi
  return 0
}

start_tunnel() { systemctl start "$(unit_for "$1")" 2>/dev/null || true; }
stop_tunnel()  { systemctl stop  "$(unit_for "$1")" 2>/dev/null || true; }

# wait until a freshly started tunnel is healthy, or give up
wait_healthy() {
  local kind="$1" i
  for (( i = 0; i < SWITCH_PROBES; i++ )); do
    sleep 2
    is_healthy "$kind" && return 0
  done
  return 1
}

# ---------- list management ----------
TUNNELS=()
load_list() {
  [[ -f $LIST ]] || return 1
  mapfile -t TUNNELS < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$LIST" | grep -v '^$' || true)
  (( ${#TUNNELS[@]} > 0 ))
}

# installed tunnels, in the configured order
installed_list() {
  local k out=()
  for k in "${TUNNELS[@]}"; do is_installed "$k" && out+=("$k"); done
  printf '%s\n' "${out[@]}"
}

set_active() { echo "$1" > "$ACTIVE"; }
get_active() { [[ -f $ACTIVE ]] && cat "$ACTIVE" || echo ""; }

# ---------- core failover loop ----------
run_loop() {
  need_root
  load_list || { err "no tunnel list at $LIST — run: failover configure"; exit 1; }

  mapfile -t CAND < <(installed_list)
  if (( ${#CAND[@]} == 0 )); then
    err "none of the listed tunnels are installed on this host; nothing to supervise"
    err "set up at least one tunnel from the abtunnel menu, then re-enable failover"
    exit 1
  fi
  if (( ${#CAND[@]} == 1 )); then
    warn "only one tunnel installed (${CAND[0]}); will just keep it alive (no alternative to switch to)"
  fi

  # pick a starting tunnel: the saved one if still installed, else the first healthy, else the first
  local current; current=$(get_active)
  if [[ -z $current ]] || ! is_installed "$current"; then
    current=""
    local k
    for k in "${CAND[@]}"; do is_healthy "$k" && { current="$k"; break; }; done
    [[ -z $current ]] && current="${CAND[0]}"
  fi
  set_active "$current"
  is_healthy "$current" || start_tunnel "$current"
  log "failover supervisor started — candidates: ${CAND[*]}  active=$current"

  local fails=0
  while true; do
    # refresh the installed set each tick so newly-added tunnels join in
    mapfile -t CAND < <(installed_list)

    if is_healthy "$current"; then
      fails=0
      sleep "$CHECK_INTERVAL"
      continue
    fi

    fails=$((fails + 1))
    warn "health check failed for [$current] ($fails/$FAIL_THRESHOLD)"
    if (( fails < FAIL_THRESHOLD )); then
      sleep "$CHECK_INTERVAL"
      continue
    fi

    # Try each OTHER installed tunnel, starting right after current in the list.
    local n=${#CAND[@]} start=0 i k switched=0
    for i in "${!CAND[@]}"; do [[ ${CAND[$i]} == "$current" ]] && start=$(( (i + 1) % n )); done
    for (( i = 0; i < n; i++ )); do
      k="${CAND[$(( (start + i) % n ))]}"
      [[ $k == "$current" ]] && continue
      warn "trying failover: $current → $k"
      start_tunnel "$k"
      if wait_healthy "$k"; then
        stop_tunnel "$current"       # only drop the old one once the new one works
        current="$k"; set_active "$current"; fails=0; switched=1
        log "switched OK to $current"
        break
      fi
      warn "$k did not come up; leaving it and trying the next option"
      stop_tunnel "$k"
    done

    if (( ! switched )); then
      err "no healthy alternative found; restarting [$current] and staying on it"
      start_tunnel "$current"
      fails=0   # avoid hammering; re-evaluate next tick
    fi
    sleep "$CHECK_INTERVAL"
  done
}

# ---------- configure ----------
# Build the ordered list from tunnels actually installed on this host. Falls back
# to the default order (commented) when nothing is set up yet.
cmd_configure() {
  need_root
  mkdir -p "$STATE"
  {
    echo "# ordered tunnel list for failover (first = highest priority)"
    echo "# only installed tunnels are used at runtime; edit freely"
  } > "$LIST"
  local k found=0
  for k in "${ALL_KINDS[@]}"; do
    if is_installed "$k"; then echo "$k" >> "$LIST"; found=$((found+1)); fi
  done
  if (( found == 0 )); then
    { echo "backhaul"; echo "openvpn"; echo "gre"; echo "ipip"; } >> "$LIST"
    warn "no tunnels installed yet — wrote the default order; set tunnels up before relying on failover"
  else
    log "configured failover for $found installed tunnel(s)"
  fi
  grep -v '^#' "$LIST" || true
}

cmd_status() {
  echo -e "${c_c}══ Failover Status ══${c_0}"
  if load_list; then
    echo "Tunnel order (★ = installed):"
    local i=1 a t mark inst h
    a=$(get_active)
    for t in "${TUNNELS[@]}"; do
      mark=" "; [[ $t == "$a" ]] && mark="→"
      inst="  "; is_installed "$t" && inst="★ "
      if is_installed "$t"; then is_healthy "$t" && h="UP" || h="DOWN"; else h="not installed"; fi
      printf "  %s %s%d) %-10s %s\n" "$mark" "$inst" "$i" "$t" "$h"
      i=$((i+1))
    done
  else
    echo "  (not configured — run: failover configure)"
  fi
  echo
  if systemctl is-active --quiet abtunnel-failover 2>/dev/null; then
    echo -e "Supervisor: ${c_g}running${c_0}"
  else
    echo -e "Supervisor: ${c_r}stopped${c_0}"
  fi
}

cmd_install_unit() {
  need_root
  local self; self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  cat > /etc/systemd/system/abtunnel-failover.service <<UNIT
[Unit]
Description=tunxall intelligent tunnel failover
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env bash $self run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now abtunnel-failover.service
  log "failover supervisor installed and started"
}

cmd_stop() {
  systemctl disable --now abtunnel-failover.service 2>/dev/null || true
  log "failover supervisor stopped"
}

usage() { echo "Usage: $0 {run|configure|status|install|stop}"; }

case "${1:-}" in
  run)       run_loop;;
  configure) cmd_configure;;
  status)    cmd_status;;
  install)   cmd_configure; cmd_install_unit;;
  stop)      cmd_stop;;
  *)         usage; exit 1;;
esac
