#!/usr/bin/env bash
# Encrypted daily backup of the x-ui panel database. Keeps 14 days locally.
# Cron:  15 3 * * *  /opt/proxy/edge/scripts/backup-db.sh >> /var/log/xui-backup.log 2>&1
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Requires sqlite3 inside the container - provided by edge/Dockerfile, NOT by
# upstream alireza7/x-ui. If this fails with "sqlite3: not found" you are running
# the upstream image; rebuild with: docker compose up -d --build

CONTAINER="${XUI_CONTAINER:-x-ui}"
DEST=backups
RETAIN_DAYS=14
STAMP="$(date +%F_%H%M%S)"
mkdir -p "$DEST"; chmod 700 "$DEST"

docker exec "$CONTAINER" sqlite3 /etc/x-ui/x-ui.db ".backup /tmp/x-ui-${STAMP}.db"
docker cp "$CONTAINER":/tmp/x-ui-${STAMP}.db "$DEST/x-ui-${STAMP}.db"
docker exec "$CONTAINER" rm -f "/tmp/x-ui-${STAMP}.db"

RAW="$DEST/x-ui-${STAMP}.db"
if command -v age >/dev/null && [[ -n "${BACKUP_AGE_RECIPIENT:-}" ]]; then
  age -r "$BACKUP_AGE_RECIPIENT" -o "${RAW}.age" "$RAW" && rm -f "$RAW"
  echo "backup: ${RAW}.age"
elif command -v gpg >/dev/null && [[ -n "${BACKUP_GPG_RECIPIENT:-}" ]]; then
  gpg --yes --batch --encrypt --recipient "$BACKUP_GPG_RECIPIENT" "$RAW" && rm -f "$RAW"
  echo "backup: ${RAW}.gpg"
else
  chmod 600 "$RAW"
  echo "WARNING: no age/gpg recipient set - backup stored UNENCRYPTED at $RAW" >&2
  echo "         export BACKUP_AGE_RECIPIENT or BACKUP_GPG_RECIPIENT" >&2
fi

find "$DEST" -type f -name 'x-ui-*' -mtime +"$RETAIN_DAYS" -print -delete
