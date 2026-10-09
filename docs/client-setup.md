# Client setup

## Human clients (v2rayN, v2rayNG, Nekoray)

1. Get the VLESS link from the panel (or `make client-link` for the expected shape):

```
vless://<uuid>@conn.yedamanebemabededige.ir:443?encryption=none&security=tls\
&sni=conn.yedamanebemabededige.ir&alpn=h2%2Chttp%2F1.1&fp=chrome&type=tcp\
&flow=xtls-rprx-vision#tr-relay
```

2. Import it: v2rayN `Servers -> Import from clipboard`; v2rayNG `+ -> Import from clipboard`.
3. **Enable TUN / VPN mode** for whole-device tunnelling:
   - v2rayN (Windows): `Enable Tun Mode` in the tray menu. Needs admin once to install the adapter.
   - v2rayNG (Android): it is a VpnService already — just connect.
   - Nekoray: `Preferences -> Enable TUN`.
4. **Leave client-side routing empty.** The edge already split-routes domestic traffic
   server-side. Adding client rules on top causes confusing double-routing.

### Verify a client is working

- `https://ifconfig.co` shows a **Turkish** IP and ASN.
- A domestic site loads at normal direct-connection speed (not Turkey-latency).
- `https://dnsleaktest.com` shows no domestic resolver for foreign lookups.
- A WebRTC/UDP app (voice call) works — confirms UDP is being relayed.

## Servers, CLI tools, containers

The edge exposes loopback-only proxies. Nothing extra to install:

```bash
# one-off
curl --socks5-hostname 127.0.0.1:10808 https://ifconfig.co/json

# whole shell
export http_proxy=http://127.0.0.1:10809
export https_proxy=http://127.0.0.1:10809
export no_proxy=localhost,127.0.0.1,.ir

# git
git config --global http.proxy socks5h://127.0.0.1:10808

# docker build (BuildKit)
docker build --build-arg https_proxy=http://127.0.0.1:10809 .

# docker daemon pulls — /etc/systemd/system/docker.service.d/proxy.conf
[Service]
Environment="HTTPS_PROXY=http://127.0.0.1:10809"
Environment="NO_PROXY=localhost,127.0.0.1,.ir"
```

Use `socks5h://` (not `socks5://`) so DNS resolves through the tunnel; otherwise the local
resolver leaks and may be poisoned.

### From another machine on your LAN

The SOCKS/HTTP inbounds bind `127.0.0.1` deliberately — an open proxy on a public interface will
be found and abused within hours. To use them from elsewhere, tunnel over SSH:

```bash
ssh -N -L 10808:127.0.0.1:10808 root@<edge_ip>
```

Or give that machine its own VLESS client inbound in the panel — the better option for anything
permanent, since it gets its own credentials and quota.
