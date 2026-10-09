# proxy — secure VLESS/REALITY relay (x-ui edge -> Turkey exit)

Monorepo holding **both** sides of a two-hop censorship-resistant proxy:

```
clients (v2rayN / v2rayNG / Nekoray, TUN mode)
   | VLESS + TCP + TLS + XTLS-Vision   -> conn.yedamanebemabededige.ir:443
   v
EDGE  x-ui 1.10.2 in Docker            <- this repo: edge/
   | split routing: geosite:ir / geoip:ir / private  => direct
   |                everything else                  => outbound "tr-exit"
   | VLESS + TCP + REALITY + XTLS-Vision (no certificate required)
   v
EXIT  Debian 13 VM in Turkey, Xray-core systemd unit   <- this repo: exit/
   | nftables: 443+8443 only from the edge IP, 22 only from admin CIDRs
   v
Internet
```

## Layout

| Path | Purpose |
| --- | --- |
| `shared/endpoints.yml` | Non-secret facts both sides need (IPs, ports, SNI, shortIds). **Single source of truth.** |
| `shared/vault.yml` | ansible-vault ciphertext: REALITY x25519 keypair + client UUID. Committed encrypted. |
| `edge/` | x-ui side: compose file, Xray template, apply/verify/backup scripts. |
| `exit/` | Turkey side: Ansible inventory, playbooks, roles (`base`, `hardening`, `xray`). |
| `docs/` | Architecture, runbook (rotation/failover/rollback), client setup. |
| `scripts/check-consistency.py` | CI guard: asserts the edge template and `shared/` agree. |

## Why one repo

The REALITY keypair, client UUID, port, SNI and shortId must be **identical on both ends** or the
tunnel silently dies. Keeping both sides here means a rotation is one commit, and CI can verify the
two halves still agree (`make lint`). Split repos make that agreement manual and silently breakable.

## Quick start

```bash
# 0. one-time: vault password + secrets
echo 'a-long-random-passphrase' > ~/.ansible/vault-pass-proxy && chmod 600 ~/.ansible/vault-pass-proxy
make secrets-init          # generates x25519 keypair + UUID, writes encrypted shared/vault.yml

# 1. fill in the REPLACE_ME values
$EDITOR shared/endpoints.yml
make doctor                # fails while any REPLACE_ME remains

# 2. Turkey exit VM
make exit-check            # dry run
make exit-apply            # real run  (keep a provider console open!)
make exit-verify

# 3. edge (x-ui) host
make edge-render           # shared/ -> edge/.env  (runs on YOUR workstation, vault pass stays here)
make edge-sync             # rsync edge/ + .env to the edge host
make edge-apply            # writes the Xray template into the panel DB, restarts x-ui
make edge-verify
```

Secrets never reach the edge host: `edge/.env` is rendered locally and pushed. See
`docs/runbook.md` for rotation, failover and rollback.
