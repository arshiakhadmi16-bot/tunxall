#!/usr/bin/env bash
# netcheck.sh — Connectivity & firewall characterization between two hosts you own.
#
# Measures what your own firewall allows between server A and server B: which TCP/UDP
# ports pass, ICMP reachability, raw throughput on an open port, MTU/fragmentation,
# and whether established connections get cut mid-stream (stateful inspection).
#
# This is a DIAGNOSTIC tool. It only measures; it does not tunnel or bypass anything.
#
# Usage:
#   On B (listener):   sudo bash netcheck.sh server [--ports "22 80 443 8080 51820 2048"]
#   On A (prober):     sudo bash netcheck.sh probe --target <B_IP> [--ports "..."]
#   Stop listener:     sudo bash netcheck.sh stop
#
# Needs: nc (netcat), optionally iperf3 for accurate throughput (auto-detected).
set -euo pipefail

PORTS_DEFAULT="22 80 443 853 993 2048 2096 5201 8080 8443 51820"
PORTS="$PORTS_DEFAULT"
TARGET=""
IPERF_PORT=5201
PIDDIR=/tmp/netcheck
mkdir -p "$PIDDIR"

c_g="\e[32m"; c_r="\e[31m"; c_y="\e[33m"; c_0="\e[0m"
ok()   { echo -e "  ${c_g}OPEN${c_0}    $*"; }
bad()  { echo -e "  ${c_r}BLOCKED${c_0} $*"; }
filt() { echo -e "  ${c_y}FILTERED${c_0} $* (no response = silent drop)"; }
log()  { echo -e "${c_g}[+]${c_0} $*"; }
warn() { echo -e "${c_y}[!]${c_0} $*"; }
die()  { echo -e "${c_r}[x]${c_0} $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ports)  PORTS="$2"; shift 2;;
      --target) TARGET="$2"; shift 2;;
      *) die "Unknown arg: $1";;
    esac
  done
}

ensure_tools() {
  if ! need nc; then
    log "Installing netcat..."
    apt-get update -qq && apt-get install -y -qq netcat-openbsd >/dev/null 2>&1 || warn "install nc manually"
  fi
  need iperf3 || warn "iperf3 not found — throughput test will fall back to a rough nc transfer. Install with: apt-get install -y iperf3"
}

# ---------------------------------------------------------------- server (B)
cmd_server() {
  [[ $EUID -eq 0 ]] || die "Run as root."
  ensure_tools
  log "Starting listeners on B for ports: $PORTS"
  for p in $PORTS; do
    # TCP listener that echoes a banner then stays briefly open (for cut-detection)
    nohup bash -c "while true; do echo \"OPEN:$p\" | nc -l -p $p -q1 2>/dev/null || break; done" \
      >/dev/null 2>&1 &
    echo $! >> "$PIDDIR/tcp.pids"
    # UDP listener
    nohup bash -c "while true; do echo \"UOPEN:$p\" | nc -u -l -p $p -q1 2>/dev/null || break; done" \
      >/dev/null 2>&1 &
    echo $! >> "$PIDDIR/udp.pids"
  done
  if need iperf3; then
    nohup iperf3 -s -p $IPERF_PORT >/dev/null 2>&1 &
    echo $! >> "$PIDDIR/iperf.pids"
    log "iperf3 server up on $IPERF_PORT"
  fi
  log "Listeners running. Now run the probe on A. Stop later with: sudo bash netcheck.sh stop"
}

cmd_stop() {
  for f in "$PIDDIR"/*.pids; do
    [[ -e $f ]] || continue
    while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$f"
    rm -f "$f"
  done
  pkill -f "nc -l -p" 2>/dev/null || true
  pkill -f "iperf3 -s" 2>/dev/null || true
  log "Listeners stopped."
}

# ---------------------------------------------------------------- probe (A)
probe_tcp() {
  echo "== TCP ports =="
  for p in $PORTS; do
    # -w2 timeout; distinguish refused (BLOCKED) vs timeout (FILTERED/drop)
    out=$(timeout 3 bash -c "echo '' | nc -w2 $TARGET $p 2>&1" || true)
    rc=$?
    if echo "$out" | grep -q "OPEN:$p"; then ok "$p/tcp  (banner received)"
    elif echo "$out" | grep -qi "refused"; then bad "$p/tcp  (connection refused)"
    else filt "$p/tcp"
    fi
  done
}

probe_udp() {
  echo "== UDP ports =="
  for p in $PORTS; do
    out=$(timeout 3 bash -c "echo ping | nc -u -w2 $TARGET $p 2>&1" || true)
    if echo "$out" | grep -q "UOPEN:$p"; then ok "$p/udp  (reply received)"
    else filt "$p/udp  (UDP rarely replies; confirm with iperf/tcpdump on B)"
    fi
  done
}

probe_icmp() {
  echo "== ICMP (ping) =="
  if ping -c3 -W2 "$TARGET" >/dev/null 2>&1; then ok "ICMP echo reachable"
  else bad "ICMP blocked (common and harmless — does not affect TCP/UDP)"; fi
}

probe_mtu() {
  echo "== Path MTU (DF probe) =="
  local hi=1472 lo=1200 best=0
  for sz in 1472 1400 1300 1200; do
    if ping -c1 -W2 -M do -s $sz "$TARGET" >/dev/null 2>&1; then best=$((sz+28)); break; fi
  done
  if [[ $best -gt 0 ]]; then ok "largest unfragmented packet ~ ${best} bytes MTU"
  else warn "could not determine MTU via ICMP (ICMP may be blocked)"; fi
}

probe_throughput() {
  echo "== Throughput =="
  if need iperf3; then
    log "TCP throughput (10s)..."; iperf3 -c "$TARGET" -p $IPERF_PORT -t 10 2>/dev/null | tail -4 || warn "iperf3 TCP failed (port $IPERF_PORT may be blocked)"
    log "UDP throughput (10s, 50M target)..."; iperf3 -c "$TARGET" -p $IPERF_PORT -u -b 50M -t 10 2>/dev/null | tail -4 || warn "iperf3 UDP failed"
  else
    warn "iperf3 missing on A — skipping accurate throughput. Install it on both ends for real numbers."
  fi
}

probe_cut() {
  echo "== Long-lived connection stability =="
  # hold an open TCP connection ~15s and see if it survives (stateful inspection often cuts idle/long flows)
  local p; p=$(echo $PORTS | awk '{print $1}')
  if timeout 20 bash -c "exec 3<>/dev/tcp/$TARGET/$p && sleep 15 && echo alive >&3" 2>/dev/null; then
    ok "held a $p/tcp connection for 15s without reset"
  else
    warn "connection on $p/tcp dropped during the 15s hold (possible idle timeout or stateful cut)"
  fi
}

cmd_probe() {
  [[ $EUID -eq 0 ]] || die "Run as root (needed for raw ICMP/MTU)."
  [[ -n $TARGET ]] || die "Need --target <B_IP>"
  ensure_tools
  echo "================ netcheck: A -> $TARGET ================"
  probe_icmp
  probe_mtu
  probe_tcp
  probe_udp
  probe_throughput
  probe_cut
  echo "======================================================="
  log "Summary: OPEN ports are usable; FILTERED = silently dropped; BLOCKED = actively refused."
  log "Pick an OPEN high-throughput port and use a standard encrypted tunnel on it."
}

main() {
  local cmd="${1:-}"; shift || true
  parse_args "$@"
  case "$cmd" in
    server) cmd_server;;
    probe)  cmd_probe;;
    stop)   cmd_stop;;
    *) echo "Usage: $0 {server|probe|stop} [--target IP] [--ports \"22 80 443 ...\"]"; exit 1;;
  esac
}
main "$@"
