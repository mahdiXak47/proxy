# Setup Order — Step by Step

**Read this once before touching anything.** The order is not arbitrary: each phase produces
something the next phase needs. Doing the edge before the exit leaves you with a panel pointing
at a dead address; doing either before the secrets exist leaves you with placeholder configs.

```
PHASE 0  workstation prep      (local, ~10 min, no risk)
PHASE 1  generate secrets      (local, ~5 min, no risk)
PHASE 2  TURKEY EXIT VM        (remote, ~20 min, LOCKOUT RISK — console open)
PHASE 3  EDGE x-ui host        (remote, ~25 min, panel downtime while restarting)
PHASE 4  client inbound + TLS  (panel UI + certbot, ~15 min)
PHASE 5  verify + hand out     (~10 min)
PHASE 6  backups + hygiene     (~10 min)
```

**Which application first? The Turkey exit VM.** It is the destination. The edge's entire
configuration references the exit's IP, port, public key and UUID, so the exit must exist and be
listening before the edge has anything valid to point at. The exit, in turn, needs the edge's
public IP for its firewall allowlist — so you need to *know* both IPs up front, but you *apply*
the exit first.

---

## PHASE 0 — Workstation prep

Everything here runs on your Mac. Nothing touches production.

### 0.1 Collect four facts

Write these down; every later phase consumes them.

| Fact | How to get it | Goes into |
| --- | --- | --- |
| Turkey VM public IPv4 | provider panel | `shared/endpoints.yml` → `tr_ip` |
| Edge host public IPv4 | `curl -4 ifconfig.co` **on the edge host** | `shared/endpoints.yml` → `edge_ip` |
| Your admin IP/CIDR | `curl -4 ifconfig.co` on your Mac | `exit/.../vars.yml` → `admin_ssh_cidrs` |
| Domain | already decided | `conn.yedamanebemabededige.ir` (pre-filled) |

**If your home IP is dynamic**, do not use it for `admin_ssh_cidrs`. Use a static jump host, or
your ISP's /24 as a compromise, or widen it temporarily and tighten later. A wrong value here
locks you out of the Turkey VM and recovery is console-only.

### 0.2 Clone and check tooling

```bash
cd ~/SourceCodes            # already cloned; otherwise: git clone git@github.com:mahdiXak47/proxy.git
cd proxy
make doctor                 # expect: MISSING vault password + REPLACE_ME values — that is correct now
```

`make doctor` is your readiness gate for the whole setup. It should fail at this point.

### 0.3 SSH key for the Turkey VM

A dedicated key, not your general-purpose one:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_tr_exit -C "tr-exit"
ssh-copy-id -i ~/.ssh/id_ed25519_tr_exit.pub root@<tr_ip>
ssh -i ~/.ssh/id_ed25519_tr_exit root@<tr_ip> 'cat /etc/os-release | head -2; echo OK'
```

**Must print `OK` before you continue.** Ansible uses exactly this key; if the key does not work
now, every later playbook fails.

---

## PHASE 1 — Generate secrets

### 1.1 Vault password

```bash
mkdir -p ~/.ansible
openssl rand -base64 32 > ~/.ansible/vault-pass-proxy
chmod 600 ~/.ansible/vault-pass-proxy
```

**Back this up to your password manager now.** Lose it and `shared/vault.yml` is unrecoverable —
you would have to regenerate every key and reconfigure both ends.

### 1.2 REALITY keypair + client UUID

```bash
# Docker must be running
make secrets-init
```

This generates an x25519 keypair and a UUID, writes them to `shared/vault.yml`, and encrypts it.
It prints the **public** key and UUID (safe to see); the private key stays encrypted.

It refuses to overwrite an existing vault — rotation is deliberate, see `docs/runbook.md`.

### 1.3 Fill in the non-secret facts

```bash
$EDITOR shared/endpoints.yml
```

Set `tr_ip`, `edge_ip`. Generate two shortIds and paste them:

```bash
openssl rand -hex 4     # -> reality_short_ids
openssl rand -hex 4     # -> reality_alt_short_ids
```

Then the admin allowlist:

```bash
$EDITOR exit/inventories/prod/group_vars/exit/vars.yml   # admin_ssh_cidrs
```

### 1.4 Gate

```bash
make doctor     # must print "doctor: ok"
make lint       # must print "consistency: ok"  (56/56 checks)
```

**Do not proceed until both pass.** `make lint` is what catches a value set on one side but not
the other.

### 1.5 Commit

```bash
git add shared/ exit/inventories/
git commit -m "chore: configure production endpoints and secrets"
git push
```

`shared/vault.yml` is committed **encrypted** — that is intended. `make lint` in CI fails if it
is ever not encrypted.

---

## PHASE 2 — Turkey exit VM  ← **the first application you set up**

> **LOCKOUT RISK.** This phase restricts SSH to `admin_ssh_cidrs` and sets a default-drop
> firewall. **Open your provider's web console / VNC in a browser tab before you start** and keep
> it open until Phase 2 is verified. If you lock yourself out, the only recovery is that console.

### 2.1 Dry run — read the diff, do not skip

```bash
make exit-check
```

Read the output. Confirm, specifically:
- the nftables diff shows **your** admin CIDR and **your** edge IP
- the SSH drop-in is what you expect
- nothing references `REPLACE_ME`

### 2.2 Apply

```bash
make exit-apply
```

Takes a few minutes (apt upgrade, Xray download + checksum verification).

### 2.3 Confirm you still have SSH — immediately, in a new terminal

```bash
ssh -i ~/.ssh/id_ed25519_tr_exit root@<tr_ip> 'echo STILL_IN'
```

**If this fails, go to the provider console now** and run `systemctl stop nftables` to restore
access, then fix `admin_ssh_cidrs` and re-apply.

### 2.4 Idempotency check

```bash
make exit-apply     # second run must report changed=0
```

A non-zero `changed` count on the second run means something in the roles is not idempotent —
worth understanding before you build on it.

### 2.5 Verify

```bash
make exit-verify
```

Asserts: config valid, service active+enabled, both REALITY ports listening, **xray not running
as root**, egress IP is Turkish, nftables default-drops with the edge allowlisted.

### 2.6 Prove the firewall actually blocks you

```bash
nc -zv -w 5 <tr_ip> 443      # from your Mac: MUST time out or be refused
```

**A successful connection here means the allowlist is not working** — only the edge IP may reach
443. Stop and fix it before continuing; an exposed REALITY port invites active probing.

Phase 2 done. The exit is listening and only your edge can talk to it.

---

## PHASE 3 — Edge x-ui host

### 3.1 Snapshot the existing panel before anything

```bash
ssh root@<edge_ip>
docker ps --filter name=x-ui --format '{{.Names}}\t{{.Image}}'
docker inspect x-ui --format '{{json .Mounts}}' | python3 -m json.tool
docker exec x-ui sqlite3 /etc/x-ui/x-ui.db ".backup /etc/x-ui/x-ui.db.bak-manual-$(date +%F_%H%M%S)" \
  || echo "no sqlite3 in the running image — expected on the stock image"
```

Note where `/etc/x-ui` is bind-mounted. **If you have existing clients you care about, copy that
DB off the host now.** This is your pre-migration rollback point.

### 3.2 Install Docker prerequisites on the edge

```bash
# on the edge host
apt update && apt install -y git jq rsync certbot
docker compose version || apt install -y docker-compose-plugin
```

### 3.3 Render and push the edge config

Back on your Mac:

```bash
make edge-render     # builds edge/.env from shared/ — the vault password never leaves your Mac
make edge-sync       # rsyncs edge/ to <edge_ip>:/opt/proxy/edge
```

### 3.4 Migrate existing panel data into the compose layout

On the edge host, only if you had a pre-existing x-ui:

```bash
cd /opt/proxy/edge
mkdir -p data/x-ui certs
docker stop x-ui
rsync -a /etc/x-ui/ data/x-ui/        # or wherever step 3.1 showed the mount
docker rm x-ui
```

### 3.5 Build the custom image and start

```bash
cd /opt/proxy/edge
docker compose up -d --build
docker compose ps
docker exec x-ui sqlite3 --version    # MUST print a version
```

The custom image exists because **upstream `alireza7/x-ui:1.10.2` has no `sqlite3`**, and every
config-apply and backup script here drives the panel DB through it. On the stock image this setup
cannot work.

### 3.6 Install the reviewed Xray template

```bash
cd /opt/proxy/edge
./scripts/apply-xray-template.sh
```

The script will not apply a broken config: it refuses on any unsubstituted placeholder, runs
`jq` and `xray -test`, and snapshots the DB before writing. Expect it to end with
`applied: xray running after restart`.

Confirm the panel actually consumed it:

```bash
docker exec x-ui jq -c '[.outbounds[].tag]' /app/bin/config.json
# expect: ["tr-exit","direct","blocked"]
```

---

## PHASE 4 — Client-facing inbound and TLS

### 4.1 Certificate for your domain

DNS for `conn.yedamanebemabededige.ir` must already point at the edge host.

```bash
# on the edge host; port 80 must be briefly free
certbot certonly --standalone -d conn.yedamanebemabededige.ir \
  --deploy-hook /opt/proxy/edge/scripts/deploy-cert.sh
ls -l /opt/proxy/edge/certs/      # fullchain.pem + privkey.pem
```

If port 80 cannot be freed, use `--preferred-challenges dns` with the same deploy hook.

### 4.2 Harden the panel — do this before exposing anything

Reach the panel over SSH rather than the internet:

```bash
ssh -L 2053:127.0.0.1:2053 root@<edge_ip>
# browse http://127.0.0.1:2053
```

In the panel, change: admin username+password (strong), panel port (random high), `webBasePath`
(random string). Then **bind the panel to `127.0.0.1`**. x-ui panels are continuously scanned and
fingerprinted; a public panel is the weakest point in this design.

### 4.3 Create the client inbound

Panel → Inbounds → Add:

| Field | Value |
| --- | --- |
| Remark | `clients-vless-tls` |
| Protocol | `vless` |
| Port | `443` |
| Flow | `xtls-rprx-vision` |
| Transport | `tcp` |
| Security | `tls` |
| SNI / domain | `conn.yedamanebemabededige.ir` |
| Cert path | `/root/cert/fullchain.pem` |
| Key path | `/root/cert/privkey.pem` |
| ALPN | `h2,http/1.1` |
| Sniffing | on (http, tls, quic) |

Add one client per person, with `limitIp` / quota / expiry per your policy.
Reference shape: `edge/config/inbounds.reference.json`.

### 4.4 Record it in git

Mirror the inbound JSON (UUIDs stripped) into `edge/config/inbounds.reference.json`, commit.

---

## PHASE 5 — Verify end to end

### 5.1 From the edge host

```bash
cd /opt/proxy/edge && ./scripts/verify.sh
```

Checks loopback inbounds, **foreign egress is Turkish**, HTTP inbound, DNS/UDP through the
tunnel, domestic split-routing, throughput, container health. Expect `ALL CHECKS PASSED`.

### 5.2 From a real client

Import the panel's VLESS link into v2rayN / v2rayNG / Nekoray, **enable TUN mode**, then confirm:

- `https://ifconfig.co` → Turkish IP and ASN
- a domestic site loads at direct speed (not Turkey-latency) ← proves split routing
- `https://dnsleaktest.com` → no domestic resolver for foreign lookups
- a voice call works ← proves UDP relay

Details in `docs/client-setup.md`.

### 5.3 Re-run the exit check

```bash
make exit-verify
```

---

## PHASE 6 — Backups and hygiene

### 6.1 Encrypted daily DB backups

```bash
# on the edge host
age-keygen -o ~/.age-backup.key          # note the public key it prints
crontab -e
```

```cron
15 3 * * * BACKUP_AGE_RECIPIENT=age1... /opt/proxy/edge/scripts/backup-db.sh >> /var/log/xui-backup.log 2>&1
```

Without a recipient the script still backs up but warns it is unencrypted. **The panel DB
contains every client UUID — treat it as a secret and copy it offsite.**

### 6.2 Confirm certificate auto-renewal

```bash
certbot renew --dry-run
systemctl list-timers | grep certbot
```

### 6.3 Final state check

```bash
make lint
git status          # clean
git log --oneline -5
```

---

## Quick reference — day-to-day

| Task | Command |
| --- | --- |
| Change routing/DNS/outbounds | edit `edge/config/xray-template.json` → `make lint` → commit → `make edge-sync && make edge-apply` |
| Change exit OS/firewall/Xray | edit `exit/roles/...` → `make exit-check` → `make exit-apply` |
| Add a client | panel UI, then mirror into `inbounds.reference.json` |
| Rotate keys | `docs/runbook.md` → "Rotate the REALITY keypair" (**exit first**) |
| Move the exit IP | `shared/endpoints.yml` → `make exit-apply` → `make edge-apply` |
| Something broke | `docs/runbook.md` → troubleshooting table |
| Roll back config | `git revert <sha>` → re-apply the affected side |
| Roll back panel DB | `edge/scripts/restore-db.sh <snapshot>` |

## Ordering rules worth remembering

1. **Exit before edge.** The edge's config references the exit; the reverse is not true.
2. **Secrets before both.** Both sides read `shared/`.
3. **On rotation, exit first.** The exit must accept the new identity before the edge presents it.
4. **Provider console open during Phase 2.** Non-negotiable.
5. **`make lint` before every apply.** It catches half-applied cross-side changes.
