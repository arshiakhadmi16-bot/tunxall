# Backhaul Rewrite

پیاده‌سازی تمیز Reverse Tunnel با قابلیت **انتخاب خودکار پایدارترین سرور**.

## ویژگی‌ها

- Transportها: `tcp`, `tcpmux`, `ws`, `wss`, `grpc`, `grpcs`
  - `grpc`: هر اتصال تانل یه stream دوطرفه‌ی gRPC (`/tunxall.Tunnel/Stream`) روی یک اتصال HTTP/2 است؛
    پیام‌ها `google.protobuf.BytesValue` استاندارد هستن (بدون نیاز به protoc). `grpcs` همون روی TLS است
    و روی سرور `tls_cert` / `tls_key` لازم داره.
- Control Channel + Token Auth
- Connection Pool پویا
- Heartbeat و Restart خودکار
- **Multi-Server Auto Selection** (جدید)
  - تست دوره‌ای چند سرور
  - محاسبه Success Rate + RTT
  - سوییچ خودکار به سرور پایدارتر
- Hot Reload کانفیگ

## ساخت

```bash
cd backhaul
go build -o backhaul .   # Go >= 1.22
go test ./...            # تست end-to-end برای tcp / tcpmux / ws
```

> **پروتکل handshake:** هر اتصالی که کلاینت به سرور باز می‌کند با `token` + نوع اتصال شروع می‌شود
> (`SG_Chan` = کانال کنترل، `SG_TCP` = اتصال دیتا، `SG_Ping` = تست سلامت). یعنی اتصال‌های دیتا هم
> احراز هویت می‌شوند و تست سلامت کانال کنترل را اشغال نمی‌کند. **سرور و کلاینت باید هر دو همین نسخه باشند.**

## استفاده

### سرور

```bash
./backhaul -c examples/server.toml
```

### کلاینت تک‌سروره

```bash
./backhaul -c examples/client.toml
```

### کلاینت چندسروره (انتخاب خودکار)

```bash
./backhaul -c examples/client-multi.toml
```

## کانفیگ چند سرور

```toml
[client]
remote_addrs = [
  "1.2.3.4:3080",
  "5.6.7.8:3080",
]

transport = "tcp"
token = "my_secure_token_change_me"

# تنظیمات تست پایداری
health_check_interval = 30   # هر چند ثانیه یکبار تست
health_check_timeout  = 3    # تایم‌اوت هر تست
min_success_rate      = 70   # حداقل درصد موفقیت
switch_threshold_ms   = 50   # حداقل بهبود RTT برای سوییچ
```

## منطق انتخاب سرور

1. هر `health_check_interval` ثانیه به همه سرورها وصل می‌شود و Token Handshake انجام می‌دهد.
2. برای هر سرور محاسبه می‌کند:
   - Success Rate (درصد موفقیت)
   - Average RTT
   - Score = success_rate / (1 + rtt_ms/100)
3. اگر سرور فعلی ۳ بار پشت‌سرهم fail شود → فوری سوییچ.
4. در غیر این صورت فقط وقتی سوییچ می‌کند که سرور جدید Score بالاتر و RTT بهتر (حداقل `switch_threshold_ms`) داشته باشد.
5. هر ۶۰ ثانیه آمار سرورها لاگ می‌شود.

## ساختار پروژه

```
backhaul-rewrite/
├── main.go
├── config/
├── cmd/
├── internal/
│   ├── health/          ← سیستم تست و انتخاب سرور
│   ├── client/
│   ├── server/
│   ├── utils/
│   ├── network/
│   ├── handlers/
│   └── wsconn/
└── examples/
```
