# TunLink

موتور reverse-tunnel داخلی tunxall.

```bash
cd tunlink
go build -o tunlink .
./tunlink -c examples/server.toml
./tunlink -c examples/client.toml
```

Transportها: `tcp`, `tcpmux`, `ws`, `wss`, `https`, `grpc`, `grpcs`

پورت‌های `ports` روی سرور کاملاً جدا از `bind_addr` (پورت تانل) هستند.
