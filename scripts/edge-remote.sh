#!/usr/bin/env bash
# Run a command on the edge host with $REPO set to the remote checkout path.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
CMD="${1:?usage: edge-remote.sh '<command using $REPO>'}"

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

exec ssh -t "${USER}@${HOST}" "REPO='${REPO}' bash -lc $(printf '%q' "$CMD")"
