# Runbook

Every procedure assumes you are at the repo root on your workstation, with
`~/.ansible/vault-pass-proxy` present.

> First-time setup? Use **[`setup-order.md`](setup-order.md)** instead — it is the same work in
> dependency order with the risk gates called out. This section is the terse version for someone
> who has done it before.

## Bootstrap from zero

```bash
# 1. vault password + generated secrets
openssl rand -base64 32 > ~/.ansible/vault-pass-proxy && chmod 600 ~/.ansible/vault-pass-proxy
make secrets-init

# 2. fill in the non-secret facts
$EDITOR shared/endpoints.yml                       # tr_ip, edge_ip, shortIds
$EDITOR exit/inventories/prod/group_vars/exit/vars.yml   # admin_ssh_cidrs
openssl rand -hex 4                                # generate each shortId

# 3. prove readiness
make doctor
make lint

# 4. the Turkish exit  (KEEP A PROVIDER CONSOLE/VNC SESSION OPEN)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_tr_exit -C tr-exit
ssh-copy-id -i ~/.ssh/id_ed25519_tr_exit root@<tr_ip>
make exit-check          # dry run; read the diff
make exit-apply
make exit-apply          # second run must report changed=0
make exit-verify

# 5. the edge
make edge-render         # renders edge/.env locally
make edge-sync           # pushes edge/ to <edge_ip>:/opt/proxy/edge
make edge-apply          # validates, snapshots the DB, installs the template
make edge-verify
```

## Panel first-run hardening (do this once, in the UI)

Reach the panel over an SSH tunnel rather than exposing it:

```bash
ssh -L 2053:127.0.0.1:<panel_port> root@<edge_ip>
# then browse http://127.0.0.1:2053/<webBasePath>
```

In the panel: strong admin password, random high panel port, random `webBasePath`, and bind the
panel to `127.0.0.1`. x-ui panels are actively scanned and fingerprinted; never leave the UI on
a public port.

## Certificates for the client-facing inbound

```bash
# on the edge host, port 80 must be briefly free
apt install -y certbot
certbot certonly --standalone -d conn.yedamanebemabededige.ir \
  --deploy-hook /opt/proxy/edge/scripts/deploy-cert.sh
```

If port 80 cannot be freed, use DNS-01 instead (`--preferred-challenges dns`) and keep the same
deploy hook. Verify:

```bash
openssl s_client -connect conn.yedamanebemabededige.ir:443 \
  -servername conn.yedamanebemabededige.ir </dev/null 2>/dev/null \
  | openssl x509 -noout -dates -subject
```

## Add a client

1. Panel -> the `clients-vless-tls` inbound -> add client, flow `xtls-rprx-vision`.
2. Set quota/expiry/`limitIp` per your policy.
3. Mirror the shape (no UUID) into `edge/config/inbounds.reference.json`, commit.
4. Give the user the VLESS link; `make client-link` prints the expected shape.

## Rotate the REALITY keypair and client UUID

The one operation that must touch both ends. **Apply the exit first.**

```bash
docker run --rm teddysun/xray xray x25519     # new keypair
docker run --rm teddysun/xray xray uuid       # new uuid
make secrets                                  # paste all three in
git commit -am "chore: rotate reality keypair and client uuid"

make exit-apply          # exit now accepts the NEW identity
make edge-render && make edge-sync && make edge-apply   # edge presents it
make exit-verify && make edge-verify
```

**Zero-downtime variant:** first add the new UUID as a *second* client on the exit inbound
(two entries in `settings.clients`), apply the exit, then cut the edge over, then remove the old
client in a follow-up commit. Otherwise expect a few seconds of interruption.

## Rotate the exit IP (new VM, or the old one got blocked)

```bash
$EDITOR shared/endpoints.yml      # tr_ip: <new ip>
git commit -am "chore: move exit to a new ip"
make exit-apply                   # provisions + firewalls the new host
make edge-render && make edge-sync && make edge-apply
```

One file changed both the exit's nftables allowlist and the edge's outbound address. That is the
reason both sides live in one repo.

## Failover to the alternate port

The exit always listens on `reality_port` **and** `reality_alt_port` with different shortIds.
If 443 gets throttled:

```bash
$EDITOR shared/endpoints.yml      # swap reality_port and reality_alt_port, and the shortId lists
git commit -am "chore: fail over to the alternate reality port"
make edge-render && make edge-sync && make edge-apply    # exit needs no change
```

## Rollback

```bash
git revert <sha>
make exit-apply                                      # if the exit was affected
make edge-render && make edge-sync && make edge-apply # if the edge was affected
```

If the **panel database** is the problem, every apply took a snapshot first:

```bash
ssh root@<edge_ip>
cd /opt/proxy/edge
ls data/x-ui/x-ui.db.bak-*
./scripts/restore-db.sh x-ui.db.bak-2026-10-09_151200
```

## Backups

```bash
# on the edge host, once
export BACKUP_AGE_RECIPIENT=age1...          # or BACKUP_GPG_RECIPIENT
crontab -e
15 3 * * * BACKUP_AGE_RECIPIENT=age1... /opt/proxy/edge/scripts/backup-db.sh >> /var/log/xui-backup.log 2>&1
```

Without a recipient the script still backs up but warns that the file is unencrypted. The panel
DB contains every client UUID — treat it as a secret and copy it offsite.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Clients connect, no traffic flows | `make edge-verify`. If egress is not TR, the REALITY handshake is failing: publicKey/shortId/SNI mismatch between ends. Run `make lint`. |
| `xray -test` fails after editing the template | A geosite/geoip code probably does not exist. Only `geosite:category-ir` is valid for Iran, **not** `geosite:ir`; there is no `geolocation-!ir`. |
| Exit unreachable right after `exit-apply` | nftables allowlist. Your admin IP changed, or `edge_ip` is wrong. Use the provider console: `nft list ruleset`. |
| `make exit-apply` hangs on the SSH task | You are already locked out. Provider console: `systemctl stop nftables`. |
| Panel reachable but no traffic stats | The `api` inbound or `stats` block was dropped from the template. `make lint` guards this. |
| Throughput poor | Confirm BBR: `sysctl net.ipv4.tcp_congestion_control`. Confirm Vision flow on both ends. Confirm `mux` is off. |
| Exit IP got blocked | `shared/endpoints.yml` -> new `tr_ip`, re-apply both sides. Keep a spare VM in the inventory. |
