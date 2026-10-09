# Architecture

## Traffic path

```
[v2rayN / v2rayNG / Nekoray, TUN mode]        [CLI tools, containers, CI]
            |                                             |
            | VLESS + TCP + TLS + XTLS-Vision             | SOCKS5 127.0.0.1:10808
            | conn.yedamanebemabededige.ir:443            | HTTP   127.0.0.1:10809
            | (real Let's Encrypt certificate)            |
            v                                             v
+---------------------------------------------------------------------------+
| EDGE HOST  (inside the restricted country)                                |
|   docker: alireza7/x-ui:1.10.2, network_mode host                         |
|   panel owns INBOUNDS (sqlite);  this repo owns dns/routing/outbounds     |
|                                                                           |
|   routing:  geosite:category-ir, domain:ir, geoip:ir  -> direct           |
|             geoip:private, bittorrent, ads            -> blocked         |
|             everything else                           -> "tr-exit"       |
+---------------------------------------------------------------------------+
            |
            | VLESS + TCP + REALITY + XTLS-Vision   (no certificate needed)
            | <tr_ip>:443   SNI borrowed from www.wikipedia.org
            | authenticated by x25519 keypair + shortId
            v
+---------------------------------------------------------------------------+
| TURKEY EXIT VM  (Debian 13, Xray-core 26.3.27, systemd, non-root)        |
|   nftables: default drop                                                  |
|     tcp 443,8443  <- ONLY the edge host's IP                              |
|     tcp 22        <- ONLY admin CIDRs                                     |
|   routing: geoip:private -> block, bittorrent -> block, rest -> freedom  |
+---------------------------------------------------------------------------+
            |
            v  Internet (egress appears Turkish)
```

## Why these choices

### REALITY on the edge->exit hop
The Turkish VM has no domain (yours is bound to the panel), so there is no certificate to
obtain. REALITY solves this: it completes a TLS handshake **borrowed from a real third-party
site** (`reality_dest`). An unauthenticated prober that connects to `tr_ip:443` is transparently
proxied to the genuine site and sees that site's valid certificate chain. There is no
self-signed certificate, no unusual JA3, and nothing to fingerprint as a proxy.

Alternatives rejected:
- **WireGuard** — UDP on this path is throttled and its handshake is trivially fingerprinted.
- **VMess + WS + TLS** — needs a certificate on the Turkish IP, and the WS upgrade is detectable.
- **Shadowsocks** — no TLS camouflage; active probing distinguishes it.

### XTLS-Vision on both legs
Without Vision you get TLS-in-TLS: the inner record lengths leak a recognisable pattern even
though the payload is encrypted, and you pay double encryption. Vision splices the inner stream
so the outer connection looks like ordinary HTTPS and the CPU cost drops.

`mux` is explicitly **disabled** — multiplexing and Vision degrade each other.

### nftables allowlisting (the single biggest hardening win)
Only one host on earth ever dials the exit: the edge. So the exit's REALITY ports accept
`ip saddr @edge_v4` only. Scanners, censors' active-probing infrastructure and opportunistic
attackers cannot even open a TCP connection. This is far stronger than any obfuscation.

### Split routing on the edge
Domestic traffic must not take a 2-hop detour through Turkey — it would be slow and would make
the user's traffic pattern anomalous. `geosite:category-ir` + `geoip:ir` go direct.

The domestic DNS resolver is **scoped to Iranian domains and guarded by `expectIPs: geoip:ir`**.
Without that guard, a poisoned domestic answer for a foreign domain would route that domain
direct (i.e. into the censor's hands) instead of through the tunnel.

### `geoip:private -> block` on both ends
Prevents a tunnel user from reaching either host's LAN, link-local addresses or cloud metadata
endpoints (169.254.169.254). This is a real SSRF-style pivot if left open.

### bittorrent blocked on both ends
Abuse complaints are the most common reason a Turkish VPS gets terminated. Blocking torrents
protects the exit's continuity, which is the whole asset.

### Xray runs as a non-root user on the exit
`User=xray` plus `AmbientCapabilities=CAP_NET_BIND_SERVICE` lets it bind 443 without root, and
`ProtectSystem=strict` + `NoNewPrivileges` limit what a hypothetical RCE could touch.

## What lives where

| Concern | Owner | Why |
| --- | --- | --- |
| Client inbounds, users, quotas, expiry | x-ui panel (SQLite) | the panel's reason for existing |
| DNS, routing, outbounds, policy | `edge/config/xray-template.json` | reviewable, diffable, reverted by git |
| Exit inbounds, firewall, OS baseline | `exit/roles/*` | idempotent, reproducible from scratch |
| REALITY identity, ports, SNI | `shared/` | must match on both ends or the tunnel dies |

## Threat model

Handles: passive DPI, active probing of the exit, TLS fingerprinting, domestic DNS poisoning,
IP scanning of the exit, panel discovery by scanners.

Does **not** handle: a global adversary correlating traffic volume/timing across both hops,
compromise of the edge host itself (it holds the client UUIDs by design), legal compulsion of
the Turkish provider, or an adversary who blocks the panel's domain by name.
