#!/usr/bin/env bash
# webpanel.sh — lightweight local status web UI for tunxall
set -euo pipefail

DIR=/etc/abtunnel
WEB_DIR="$DIR/webpanel"
PORT="${WEB_PORT:-9090}"

need_root() { [[ $EUID -eq 0 ]] || { echo "need root"; exit 1; }; }

generate_html() {
  mkdir -p "$WEB_DIR"
  local now units_html="" tokens_html="" failover_html=""
  now=$(date '+%Y-%m-%d %H:%M:%S %Z')

  # units
  local u st color
  while read -r u; do
    [[ -z $u ]] && continue
    if systemctl is-active --quiet "$u" 2>/dev/null; then st="ACTIVE"; color="#16a34a"; else st="DOWN"; color="#dc2626"; fi
    units_html+="<tr><td>${u}</td><td style=\"color:${color};font-weight:700\">${st}</td></tr>"
  done < <(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '/abtunnel|wg-quick@wg0|strongswan/{print $1}' | sed 's/\.service$//' | sort -u)

  [[ -z $units_html ]] && units_html='<tr><td colspan="2" class="muted">No tunnel units</td></tr>'

  # tokens vault
  local f name
  if ls "$DIR"/tokens/*.token >/dev/null 2>&1 || ls "$DIR"/tunlink/tokens/*.token >/dev/null 2>&1 || [[ -f $DIR/tunlink/connect.token ]] || [[ -f $DIR/ovpn-connect.token ]]; then
    for f in "$DIR"/tokens/*.token "$DIR"/tunlink/tokens/*.token "$DIR"/tunlink/connect.token "$DIR"/ovpn-connect.token; do
      [[ -f $f ]] || continue
      name=$(basename "$f")
      local preview
      preview=$(head -c 24 "$f" 2>/dev/null | tr -d '\n')
      tokens_html+="<tr><td>${name}</td><td class=\"mono\">${preview}…</td><td>$(stat -c '%y' "$f" 2>/dev/null | cut -d. -f1)</td></tr>"
    done
  fi
  [[ -z $tokens_html ]] && tokens_html='<tr><td colspan="3" class="muted">No tokens saved</td></tr>'

  # failover
  if systemctl is-active --quiet abtunnel-failover 2>/dev/null; then
    failover_html="<span class=\"ok\">RUNNING</span> — active: <b>$(cat $DIR/failover/active 2>/dev/null || echo '?')</b>"
    if [[ -f $DIR/failover/tunnels.list ]]; then
      failover_html+="<br><span class=\"muted\">order: $(grep -v '^#' $DIR/failover/tunnels.list | tr '\n' ' ')</span>"
    fi
  else
    failover_html='<span class="muted">stopped</span>'
  fi

  # tunlink config snapshot
  local cfg_html=""
  if [[ -f $DIR/tunlink/server.toml ]]; then
    cfg_html="<h3>server.toml</h3><pre>$(grep -E 'bind_addr|transport|obfuscate|ports|token' $DIR/tunlink/server.toml 2>/dev/null | sed 's/token = .*/token = \"***\"/')</pre>"
  elif [[ -f $DIR/tunlink/client.toml ]]; then
    cfg_html="<h3>client.toml</h3><pre>$(grep -E 'remote_addr|remote_addrs|transport|obfuscate|token' $DIR/tunlink/client.toml 2>/dev/null | sed 's/token = .*/token = \"***\"/')</pre>"
  fi

  cat > "$WEB_DIR/index.html" <<HTML
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="15">
<title>tunxall status</title>
<style>
  :root { --bg:#0b1220; --card:#111827; --line:#1f2937; --txt:#e5e7eb; --muted:#9ca3af; --acc:#38bdf8; }
  * { box-sizing:border-box; }
  body { margin:0; font-family: system-ui, Tahoma, sans-serif; background:linear-gradient(180deg,#0b1220,#0f172a); color:var(--txt); }
  header { padding:1.25rem 1.5rem; border-bottom:1px solid var(--line); display:flex; justify-content:space-between; align-items:center; }
  header h1 { margin:0; font-size:1.25rem; letter-spacing:.04em; }
  header span { color:var(--muted); font-size:.85rem; }
  main { max-width:960px; margin:0 auto; padding:1.25rem; display:grid; gap:1rem; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:1rem 1.1rem; }
  .card h2 { margin:0 0 .75rem; font-size:1rem; color:var(--acc); }
  table { width:100%; border-collapse:collapse; }
  td,th { padding:.45rem .3rem; border-bottom:1px solid var(--line); text-align:right; font-size:.92rem; }
  th { color:var(--muted); font-weight:600; }
  .ok { color:#16a34a; font-weight:700; }
  .muted { color:var(--muted); }
  .mono { font-family: ui-monospace, monospace; font-size:.8rem; direction:ltr; text-align:left; }
  pre { background:#0b1220; border-radius:10px; padding:.75rem; overflow:auto; direction:ltr; text-align:left; font-size:.8rem; }
  footer { text-align:center; color:var(--muted); font-size:.8rem; padding:1rem; }
</style>
</head>
<body>
<header>
  <h1>✦ TUNXALL STATUS</h1>
  <span>بروزرسانی: ${now} — هر ۱۵ ثانیه</span>
</header>
<main>
  <div class="card">
    <h2>سرویس‌های تانل</h2>
    <table><tr><th>Unit</th><th>وضعیت</th></tr>${units_html}</table>
  </div>
  <div class="card">
    <h2>سوئیچ خودکار (Failover)</h2>
    <div>${failover_html}</div>
  </div>
  <div class="card">
    <h2>صندوق توکن‌ها</h2>
    <table><tr><th>نام</th><th>پیش‌نمایش</th><th>زمان</th></tr>${tokens_html}</table>
  </div>
  <div class="card">
    <h2>پیکربندی</h2>
    ${cfg_html:-<span class="muted">تنظیماتی نیست</span>}
  </div>
</main>
<footer>tunxall web panel — local only · port ${PORT}</footer>
</body>
</html>
HTML
}

cmd_install() {
  need_root
  command -v python3 >/dev/null 2>&1 || { echo "[x] python3 is required for the web panel (apt install python3)"; exit 1; }
  mkdir -p "$WEB_DIR" /usr/local/lib/tunxall
  generate_html

  # regenerator loop + static server
  cat > /usr/local/lib/tunxall/webpanel-run.sh <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
DIR=/etc/abtunnel
WEB_DIR="$DIR/webpanel"
PORT="${WEB_PORT:-9090}"
HELPER="/opt/tunxall/webpanel.sh"
[[ -x $HELPER ]] || HELPER="/usr/local/lib/tunxall/webpanel.sh"

# refresh HTML every 15s in background
(
  while true; do
    bash "$HELPER" generate >/dev/null 2>&1 || true
    sleep 15
  done
) &

cd "$WEB_DIR"
exec python3 -m http.server "$PORT" --bind 0.0.0.0
RUN
  chmod +x /usr/local/lib/tunxall/webpanel-run.sh
  cp -f "$(readlink -f "$0" 2>/dev/null || echo "$0")" /usr/local/lib/tunxall/webpanel.sh 2>/dev/null || true
  chmod +x /usr/local/lib/tunxall/webpanel.sh 2>/dev/null || true

  cat > /etc/systemd/system/abtunnel-webpanel.service <<UNIT
[Unit]
Description=tunxall web status panel
After=network.target

[Service]
Type=simple
Environment=WEB_PORT=$PORT
ExecStart=/usr/bin/env bash /usr/local/lib/tunxall/webpanel-run.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now abtunnel-webpanel.service
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "[+] web panel: http://${ip:-0.0.0.0}:${PORT}/"
}

cmd_stop() {
  systemctl disable --now abtunnel-webpanel.service 2>/dev/null || true
  echo "[+] web panel stopped"
}

cmd_status() {
  systemctl is-active --quiet abtunnel-webpanel 2>/dev/null && echo "running on port ${PORT}" || echo "stopped"
}

case "${1:-}" in
  generate) generate_html;;
  install)  cmd_install;;
  stop)     cmd_stop;;
  status)   cmd_status;;
  *) echo "Usage: $0 {generate|install|stop|status}";;
esac
