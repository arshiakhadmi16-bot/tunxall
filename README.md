# tunxall

Standard, encrypted point-to-point tunnels between two servers **you own**, plus a
network-diagnostics tool to see what your own firewall allows.

No obfuscation and no traffic disguising — these are plain, standard transports
(real TLS, SSH, IPsec, WireGuard) on a port that is actually open between the two hosts.

---

## 🚀 شروع سریع — فقط ۲ قدم

### قدم ۱ — روی سرور اول (همون سروری که کاربرها بهش وصل می‌شن)

```bash
curl -fsSL https://raw.githubusercontent.com/arshiakhadmi16-bot/tunxall/main/install.sh | sudo bash
```

منو خودش باز می‌شه. گزینه‌ی **`[1] ساخت تانل جدید`** رو بزن و برای سؤال‌ها فقط **Enter** بزن (پیش‌فرض‌ها مناسب‌ان).
آخرش یه **توکن** نشون می‌ده؛ کپی‌اش کن.

### قدم ۲ — روی سرور دوم

همون دستور نصب رو بزن، بعد گزینه‌ی **`[2] وصل شدن با توکن`** و توکن رو **Paste** کن. تمام! ✅

```
   [1]  ساخت تانل جدید      روی سرور اول — یک توکن می‌دهد
   [2]  وصل شدن با توکن     روی سرور دوم — توکن را Paste کنید
   [3]  وضعیت تانل‌ها
   [4]  نمایش دوباره توکن
   [5]  حذف تانل
   [6]  تنظیمات پیشرفته
```

- هر وقت خواستی منو رو باز کنی: `sudo abtunnel`
- نیازی به نصب Go یا چیز دیگه‌ای نیست؛ همه‌چیز خودکار نصب می‌شه.
- اگه فایروال `ufw` یا `firewalld` روشن باشه، پورت‌ها خودکار باز می‌شن. (فایروال دیتاسنتر رو خودت باید باز کنی.)
- تانل‌ها با ریبوت یا قطعی اینترنت **خودشون دوباره وصل می‌شن** (keepalive و تشخیص قطعی سریع‌تر؛ قطعیِ کامل تا ~۲ دقیقه شناسایی می‌شه).
- انواع اتصال: Backhaul TCP (پیشنهادی)، **TCP مالتی‌پلکس** (چند کاربر روی یک اتصال)، gRPC، gRPC+TLS، WebSocket، OpenVPN — و در «تنظیمات پیشرفته»: GRE، IPIP، WireGuard، SSH، Stunnel، IPsec و …
- اتصال‌های شبیه‌HTTPS (gRPC+TLS / WebSocket) به‌صورت پیش‌فرض روی پورت **۴۴۳** تنظیم می‌شن.
- **MTU/MSS خودکار:** برای GRE/IPIP/OpenVPN اندازه‌ی پکت از روی مسیر واقعی تنظیم می‌شه تا تانل کند نشه یا نصفه‌کاره قطع نشه.

### پیدا کردن بهترین پورت (اختیاری)

اگه مطمئن نیستی کدوم پورت بین دو سرور بازه، اول این رو اجرا کن:

```bash
# روی سرور اول
sudo netcheck server
# روی سرور دوم
sudo netcheck probe --target <IP سرور اول>
```

نتیجه ذخیره می‌شه و منوی `abtunnel` خودش **بهترین پورت باز** رو پیشنهاد می‌ده.

بدون منو هم می‌شه:
```bash
sudo abtunnel connect <TOKEN>
```

---

## Components

| Command | Purpose |
|--------|---------|
| `netcheck`  | Measure which TCP/UDP ports, ICMP, MTU, throughput and connection stability pass between A and B. Measurement only. |
| `abtunnel`  | Friendly menu to create a tunnel (token-based, 2 steps) — backhaul, openvpn, gre, ipip, wireguard, ssh, stunnel, ipsec, … |
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
- **backhaul:** reverse tunnel با transportهای `tcp` / `tcpmux` / `ws` / `wss` / **`grpc`** / **`grpcs`**.
  - `grpc` = gRPC روی HTTP/2 بدون TLS (h2c)، `grpcs` = gRPC روی TLS (گواهی self-signed خودکار ساخته می‌شه).
  - همه‌ی اتصال‌ها (کنترل + دیتا) به‌صورت streamهای جدا روی **یک** اتصال HTTP/2 می‌رن.
  - مثال: `sudo abtunnel backhaul server --transport grpc --accept-port 3080 --ports "443,8080"`
    و روی کلاینت: `sudo abtunnel backhaul client --peer <SERVER_IP>:3080 --psk <TOKEN> --transport grpc`

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

## ➡️ فوروارد ترافیک به داخل تانل

**در منوی ساده، فوروارد خودکار انجام می‌شه:**
- **Backhaul:** همون پورت‌هایی که موقع ساخت تانل وارد می‌کنی، خودکار به سرویس سرور دوم می‌رسن (نیازی به کار اضافه نیست؛ سرویس می‌تونه روی `127.0.0.1` هم باشه).
- **OpenVPN:** موقع ساخت تانل می‌پرسه «یک سرویس از سرور دوم را باز کنم؟»؛ اگه بله بگی، پورت‌ها خودکار به داخل تانل فوروارد می‌شن. (سرویس سرور دوم باید روی `0.0.0.0` گوش بده، نه فقط `127.0.0.1`.)
- **GRE/IPIP (منوی پیشرفته):** موقع ساخت، پورت‌های فوروارد رو می‌پرسه و خودکار می‌سازه.

وقتی یه تانل اینترفیسی (gre/ipip/sit/gre6/ip6ip6/openvpn) بالا میاد، **فوروارد کرنل (IPv4+IPv6) هم خودکار فعال می‌شه**.

اگه خواستی دستی یه پورت دیگه اضافه کنی (DNAT + MASQUERADE، پایدار و خودکار روی ریبوت):

```bash
# مثال: هر چی روی این سرور به پورت 3306 بیاد، از تانل بره به دیتابیسِ سرور مقابل
sudo abtunnel forward --proto tcp --in-port 3306 --to 10.20.0.1 --to-port 3306
```

- `--to` = IP داخلیِ تانلِ سرور مقابل (مثلاً `10.20.0.1`، یا `fd20::1` برای IPv6)
- حذف همه‌ی فورواردها: `sudo abtunnel down forward`
- دیدن فورواردهای فعال: `sudo abtunnel status`

> این فقط یه **سرویس/پورت مشخص** رو به داخل تانل هدایت می‌کنه. روت کردن کل ترافیک اینترنت از سرور مقابل (default route / exit-node) جزو این ابزار نیست.

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

---

## 🚀 Backhaul Reverse Tunnel (جدید)

یک تانل reverse با عملکرد بالا که به tunxall اضافه شده:

- پشتیبانی از `tcp` / `tcpmux` / `ws` / `wss`
- **انتخاب خودکار پایدارترین سرور** بین چند سرور
- Connection Pool + Heartbeat + Auto Restart
- نصب و مدیریت از همان منوی `abtunnel`

### استفاده از منو

```bash
sudo abtunnel
# 1) Set up a tunnel (guided)
# → SERVER یا CLIENT
# → IPv4
# → 9) backhaul
```

### حالت چندسروره (Auto-Select)

روی **CLIENT** می‌توانی چند آدرس بدهی:

```
Server address(es): 1.2.3.4:3080,5.6.7.8:3080
Token: <token از سرور>
```

سیستم هر ۳۰ ثانیه هر دو سرور را تست می‌کند (RTT + Success Rate) و تانل را روی پایدارترین نگه می‌دارد.

### دستور مستقیم

```bash
# سرور
sudo abtunnel backhaul server --accept-port 3080 --psk mytoken

# کلاینت تکی
sudo abtunnel backhaul client --peer 1.2.3.4 --accept-port 3080 --psk mytoken

# کلاینت چندسروره (با متغیر محیطی)
PEERS="1.2.3.4:3080,5.6.7.8:3080" PSK=mytoken sudo abtunnel backhaul client
```

### مدیریت

```bash
sudo abtunnel status
sudo abtunnel down backhaul
systemctl status abtunnel-backhaul
```

کد منبع Backhaul داخل پوشه `backhaul/` قرار دارد و هنگام نصب (در صورت وجود Go) بیلد می‌شود.

---

## 🎭 Spoof هوشمند + سوئیچ خودکار

### Spoof (شبیه‌سازی HTTPS)
در منوی «ساخت تانل جدید» گزینه **🎭 Spoof هوشمند (HTTPS)** را انتخاب کنید.
ترافیک روی پورت ۴۴۳ با gRPC+TLS حمل می‌شود و شبیه ترافیک وب معمولی به نظر می‌رسد — مناسب محیط‌هایی که DPI دارند.

### سوئیچ خودکار (Failover)
اگر تانل فعلی قطع شود، ناظر خودکار به تانل بعدی در لیست می‌رود:

```
منو → [6] سوئیچ خودکار (Failover) → فعال‌سازی
```

ترتیب پیش‌فرض: `backhaul → openvpn → gre → ipip`

- چک سلامت هر ۲۰ ثانیه
- بعد از ۳ بار شکست متوالی → سوئیچ
- وضعیت در منوی «وضعیت تانل‌ها» هم نمایش داده می‌شود

دستور مستقیم:
```bash
sudo bash /opt/tunxall/failover.sh install   # فعال
sudo bash /opt/tunxall/failover.sh status   # وضعیت
sudo bash /opt/tunxall/failover.sh stop     # خاموش
```
