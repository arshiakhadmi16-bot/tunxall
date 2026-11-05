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

## انواع تانل استاندارد — چه موقع کدوم؟

- **stunnel (TLS):** یه سرویس TCP خاص (مثلاً دیتابیس) رو امن بین دو سرور رد کن. TLS واقعی با cert پین‌شده.
- **ssh:** ساده‌ترین؛ یه پورت رو forward می‌کنه. پایدار با autossh.
- **ipsec:** کل ترافیک IP بین دو سرور رو رمز می‌کنه (host-to-host، transport mode).
- **gre:** اینترفیس point-to-point روی IPv4 (IP داخلی `10.20.0.x`).
- **ipip:** مثل GRE ولی سبک‌تر، روی IPv4 (`10.40.0.x`).
- **sit (6in4):** IPv6 روی endpoint ‌ِ IPv4 (IP داخلی `fd60::x`).
- **gre6:** GRE روی endpoint ‌ِ IPv6 (IP داخلی `fd20::x`).
- **ip6ip6:** IPv6-in-IPv6 (IP داخلی `fd40::x`).
- **openvpn:** تانل point-to-point با static key و AES-256 روی UDP.
- **WireGuard:** توی `wg-tunnel` جداگانه.

> نکته‌ی مهم: `gre`/`ipip`/`sit`/`gre6`/`ip6ip6` بدون `--psk` **رمزنگاری نمی‌شن** (plain). با دادن یه `--psk` مشترک (یک مقدار روی هر دو طرف) با IPsec رمز می‌شن.

## 🔁 Health watchdog (ری‌استارت خودکار روی قطعی)

علاوه بر `Restart=always` که systemd می‌ده، می‌تونی یه نگهبان نصب کنی که هر ۳۰ ثانیه سلامت تانل رو چک کنه و اگه ترافیک رد نشد، همون تانل رو ری‌استارت کنه:

```bash
# برای تانل‌هایی که IP خصوصی دارن (gre/ipip/openvpn):
sudo abtunnel health --unit abtunnel-gre --watch-ip 10.20.0.1
# برای تانل‌های port-forward (stunnel/ssh):
sudo abtunnel health --unit abtunnel-stunnel --watch-port 3306
```

> این فقط همون تانل رو دوباره وصل می‌کنه (پایداری). بین نوع پروتکل‌ها سوییچ نمی‌کنه.

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

**gre / ipip (IPv4) — خالی یا رمزنگاری‌شده:**
```bash
# خالی (بدون رمز): روی B سپس A — بدون --psk
sudo abtunnel gre server --peer <A_IP>
sudo abtunnel gre client --peer <B_IP>
# رمزنگاری‌شده: یه PSK مشترک روی هر دو طرف بده
sudo abtunnel gre server --peer <A_IP> --psk "mysecret"
sudo abtunnel gre client --peer <B_IP> --psk "mysecret"
# تست:  ping 10.20.0.1    (ipip -> 10.40.0.1)
```

**پروتکل‌های IPv6:**
```bash
# sit (IPv6 روی endpoint IPv4)
sudo abtunnel sit server --peer <A_IPv4>
sudo abtunnel sit client --peer <B_IPv4>
# تست:  ping -6 fd60::1

# gre6 (GRE روی endpoint IPv6)
sudo abtunnel gre6 server --peer <A_IPv6>
sudo abtunnel gre6 client --peer <B_IPv6>
# تست:  ping -6 fd20::1

# ip6ip6 (IPv6-in-IPv6)
sudo abtunnel ip6ip6 server --peer <A_IPv6>
sudo abtunnel ip6ip6 client --peer <B_IPv6>
# تست:  ping -6 fd40::1
```
> برای رمزنگاری هر کدوم، `--psk "مقدار مشترک"` رو به هر دو طرف اضافه کن.

**openvpn — point-to-point:**
```bash
# روی B  (یه key چاپ می‌کنه)
sudo abtunnel openvpn server --ovpn-port 1194
# key رو به A کپی کن، بعد روی A:
sudo abtunnel openvpn client --peer <B_IP> --ovpn-port 1194 --cert /etc/abtunnel/ovpn.key
# تست:  ping 10.30.0.1
```

**wg-tunnel — WireGuard:**
```bash
# روی B
sudo wg-tunnel server --port 51820
# روی A (با مقادیری که B چاپ کرد)
sudo wg-tunnel client --endpoint <B_IP> --port 51820 --pubkey <B_PUBKEY>
```

---

## نکته‌ی فنی

این تانل‌ها روی یه پورتی که بین دو سرور **باز** باشه برقرار می‌شن. با `netcheck` اول ببین کدوم پورت بازه، بعد تانل رو روی همون پورت بالا بیار.
