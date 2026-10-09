#!/usr/bin/env bash
# Restore the x-ui panel DB from a snapshot.
#   scripts/restore-db.sh x-ui.db.bak-2026-10-09_151200     (snapshot inside /etc/x-ui)
#   scripts/restore-db.sh backups/x-ui-2026-10-09_031500.db (local backup file)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
CONTAINER="${XUI_CONTAINER:-x-ui}"
SRC="${1:?usage: restore-db.sh <snapshot-name-or-path>}"

echo "This REPLACES the live panel database. The current DB is snapshotted first."
read -r -p "Type 'restore' to continue: " a
[[ "$a" == "restore" ]] || { echo "aborted"; exit 1; }

docker exec "$CONTAINER" sqlite3 /etc/x-ui/x-ui.db \
  ".backup /etc/x-ui/x-ui.db.pre-restore-$(date +%F_%H%M%S)"

docker stop "$CONTAINER" >/dev/null
if [[ -f "$SRC" ]]; then
  cp "$SRC" data/x-ui/x-ui.db
else
  cp "data/x-ui/${SRC}" data/x-ui/x-ui.db
fi
docker start "$CONTAINER" >/dev/null

for _ in $(seq 1 15); do
  sleep 2
  docker exec "$CONTAINER" pgrep xray >/dev/null 2>&1 && { echo "restored; xray running"; exit 0; }
done
echo "ERROR: xray did not start after restore" >&2
docker logs --tail 40 "$CONTAINER" >&2 || true
exit 1
