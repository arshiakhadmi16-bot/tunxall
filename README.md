# abtunnel

Standard, encrypted point-to-point tunnels between two servers **you own**, plus a
network-diagnostics tool to see what your own firewall allows.

No obfuscation and no traffic disguising — these are plain, standard transports
(real TLS, SSH, IPsec, WireGuard) on a port that is actually open between the two hosts.

## Components

| Script | Purpose |
|--------|---------|
| `netcheck.sh`  | Measure which TCP/UDP ports, ICMP, MTU, throughput and connection stability pass between A and B. Measurement only. |
| `abtunnel.sh`  | Bring up one of three standard tunnels you choose from a menu: **stunnel (TLS)**, **ssh**, or **ipsec**. |
| `wg-tunnel.sh` | A standard WireGuard link, if you prefer that transport. |

All tunnels run under `systemd` with `Restart=always`, so a single transport
auto-reconnects after a drop or reboot. (Switching *between* transports is a manual
choice you make, not something the script does automatically.)

## 1. Diagnose the path first

```bash
# On B (listener)
sudo bash netcheck.sh server
# On A (prober)
sudo bash netcheck.sh probe --target <B_IP>
# Stop listeners on B
sudo bash netcheck.sh stop
```

Pick a port reported **OPEN** with good throughput, then set up a tunnel on it.

## 2. Bring up a tunnel (easy menu)

```bash
sudo bash abtunnel.sh menu
```

The menu asks for the role (server/client), the tunnel type, and the few values each needs.

### Or run a type directly

**stunnel (TLS forward — e.g. expose a DB on B to A):**
```bash
# On B — expose local service :3306 over TLS :443
sudo bash abtunnel.sh stunnel server --service-port 3306 --accept-port 443
# copy the printed server-cert.pem to A, then:
# On A — service appears locally on 127.0.0.1:3306
sudo bash abtunnel.sh stunnel client --peer <B_IP> --accept-port 443 \
     --local-port 3306 --cert /etc/abtunnel/server-cert.pem
```

**ssh (port-forward):**
```bash
# On A
sudo bash abtunnel.sh ssh client --peer <B_IP> --ssh-port 22 \
     --local-port 5432 --target-host 127.0.0.1 --remote-port 5432
# then add the printed key on B:
sudo bash abtunnel.sh ssh server --pubkey "<A_PUBLIC_KEY>"
```

**ipsec (host-to-host encryption):**
```bash
# On B
sudo bash abtunnel.sh ipsec server --peer <A_IP>     # prints a PSK
# On A
sudo bash abtunnel.sh ipsec client --peer <B_IP> --psk "<PSK_FROM_B>"
```

## 3. Status / teardown

```bash
sudo bash abtunnel.sh status
sudo bash abtunnel.sh down <stunnel|ssh|ipsec>
```

## Scope

These tools work only when a port is genuinely open between the two hosts. If the path
is blocked upstream, open it at the network/provider level — these scripts do not and
will not attempt to defeat network filtering.
