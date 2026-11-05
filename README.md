# tunxall

Standard, encrypted point-to-point tunnels between two servers **you own**, plus a
network-diagnostics tool to see what your own firewall allows.

No obfuscation and no traffic disguising — these are plain, standard transports
(real TLS, SSH, IPsec, WireGuard) on a port that is actually open between the two hosts.

---

## ⚡ One-command install (on both servers)

```bash
curl -fsSL https://raw.githubusercontent.com/arshiakhadmi16-bot/tunxall/main/install.sh | sudo bash
```

This installs three global commands: `netcheck`, `abtunnel`, `wg-tunnel`.

---

## Components

| Command | Purpose |
|--------|---------|
| `netcheck`  | Measure which TCP/UDP ports, ICMP, MTU, throughput and connection stability pass between A and B. Measurement only. |
| `abtunnel`  | Bring up one of three standard tunnels you choose from a menu: **stunnel (TLS)**, **ssh**, or **ipsec**. |
| `wg-tunnel` | A standard WireGuard link, if you prefer that transport. |

All tunnels run under `systemd` with `Restart=always`, so a single transport
auto-reconnects after a drop or reboot. (Switching *between* transports is a manual
choice you make, not something the script does automatically.)

---

## 📘 Tutorial — راهنمای گام‌به‌گام

### گام ۰ — نصب روی هر دو سرور
دستور بالا (One-command install) رو روی **هر دو سرور A و B** اجرا کن.

### گام ۱ — تست مسیر (کدوم پورت بازه؟)
اول ببین چی بین دو سرور عبور می‌کنه.

```bash
# روی B (گوش‌دهنده)
sudo netcheck server
# روی A (تست‌کننده) — IP سرور B
sudo netcheck probe --target <B_IP>
# بعد از تست، روی B متوقف کن
sudo netcheck stop
```

یه پورت که **OPEN** گزارش شده و سرعت خوبی داره انتخاب کن.

### گام ۲ — بالا آوردن تانل (منوی ساده)
```bash
sudo abtunnel menu
```
منو ازت می‌پرسه: نقش (server/client)، نوع تانل، و چند مقدار لازم. تمام.

### گام ۳ — وضعیت و حذف
```bash
sudo abtunnel status
sudo abtunnel down <stunnel|ssh|ipsec>
```

---

## سه نوع تانل — چه موقع کدوم؟

- **stunnel (TLS):** یه سرویس TCP خاص (مثلاً دیتابیس) رو امن بین دو سرور رد کن. رمزنگاری واقعی TLS با cert پین‌شده.
- **ssh:** ساده‌ترین؛ یه پورت رو forward می‌کنه. پایدار با autossh.
- **ipsec:** کل ترافیک IP بین دو سرور رو رمز می‌کنه (host-to-host). شبیه VPN ولی بدون اینترفیس مجازی.

### اجرای مستقیم (بدون منو)

**stunnel — مثلاً دیتابیس :3306 روی B به A:**
```bash
# روی B
sudo abtunnel stunnel server --service-port 3306 --accept-port 443
# گواهی چاپ‌شده (server-cert.pem) رو به A کپی کن، بعد:
# روی A — سرویس روی 127.0.0.1:3306 ظاهر می‌شه
sudo abtunnel stunnel client --peer <B_IP> --accept-port 443 \
     --local-port 3306 --cert /etc/abtunnel/server-cert.pem
```

**ssh — port-forward:**
```bash
# روی A
sudo abtunnel ssh client --peer <B_IP> --ssh-port 22 \
     --local-port 5432 --target-host 127.0.0.1 --remote-port 5432
# کلید چاپ‌شده رو روی B اضافه کن:
sudo abtunnel ssh server --pubkey "<A_PUBLIC_KEY>"
```

**ipsec — رمزنگاری host-to-host:**
```bash
# روی B  (یه PSK چاپ می‌کنه)
sudo abtunnel ipsec server --peer <A_IP>
# روی A
sudo abtunnel ipsec client --peer <B_IP> --psk "<PSK_FROM_B>"
```

**wg-tunnel — WireGuard:**
```bash
# روی B
sudo wg-tunnel server --port 51820
# روی A (با مقادیری که B چاپ کرد)
sudo wg-tunnel client --endpoint <B_IP> --port 51820 --pubkey <B_PUBKEY>
```

---

## Scope / محدوده

این ابزارها فقط وقتی کار می‌کنن که یه پورت **واقعاً باز** بین دو سرور وجود داشته باشه. اگه مسیر از سمت شبکه/دیتاسنتر بسته‌ست، باید اونجا بازش کنی — این اسکریپت‌ها هیچ تلاشی برای دور زدن فیلترینگ شبکه نمی‌کنن و نخواهند کرد.
