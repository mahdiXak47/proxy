#!/usr/bin/env bash
# Push the edge/ tree (including the locally rendered .env) to the edge host.
# The vault password never leaves your workstation.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

read_ep() { python3 -c "
import re,sys
k=sys.argv[1]
for l in open('shared/endpoints.yml'):
    l=l.split('#',1)[0].rstrip()
    m=re.match(r'^'+k+r':\s*(.+)$', l)
    if m: print(m.group(1).strip().strip('\"').strip(\"'\")); break
" "$1"; }

HOST="$(read_ep edge_ip)"
USER="$(read_ep edge_ssh_user)"
REPO="$(read_ep edge_repo_path)"
[[ -n "$HOST" && "$HOST" != *REPLACE_ME* ]] || { echo "ERROR: set edge_ip in shared/endpoints.yml" >&2; exit 1; }
[[ -f edge/.env ]] || { echo "ERROR: edge/.env not rendered — run 'make edge-render'" >&2; exit 1; }

echo "syncing edge/ -> ${USER}@${HOST}:${REPO}/edge"
ssh "${USER}@${HOST}" "mkdir -p '${REPO}/edge'"

# Only the edge needs to exist on that host. Data/certs/backups stay server-side.
rsync -az --delete \
  --exclude 'data/' --exclude 'certs/' --exclude 'backups/' \
  -e ssh edge/ "${USER}@${HOST}:${REPO}/edge/"

ssh "${USER}@${HOST}" "chmod 600 '${REPO}/edge/.env'; chmod +x '${REPO}/edge/scripts/'*.sh"
echo "synced. apply with: make edge-apply"
