#!/usr/bin/env bash
# Validate the committed Xray template, snapshot the panel DB, install the template into
# x-ui's settings table, restart the container. Run ON THE EDGE HOST.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> edge/

CONTAINER="${XUI_CONTAINER:-x-ui}"
TMPL=config/xray-template.json
SETTINGS_KEY="${XUI_SETTINGS_KEY:-xrayTemplateConfig}"

[[ -f .env ]] || { echo "ERROR: edge/.env missing - render it on your workstation and sync it" >&2; exit 1; }
set -a; . ./.env; set +a
command -v jq >/dev/null || { echo "ERROR: jq not installed" >&2; exit 1; }
docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "ERROR: container '$CONTAINER' not found" >&2; exit 1; }

OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT

# 1. Substitute. Quoted port placeholders lose their quotes so they stay JSON numbers.
sed -e "s|\"__TR_PORT__\"|${TR_PORT}|g" \
    -e "s|\"__EDGE_SOCKS_PORT__\"|${EDGE_SOCKS_PORT}|g" \
    -e "s|\"__EDGE_HTTP_PORT__\"|${EDGE_HTTP_PORT}|g" \
    -e "s|__TR_IP__|${TR_IP}|g" \
    -e "s|__TR_UUID__|${TR_UUID}|g" \
    -e "s|__REALITY_PUBLIC_KEY__|${REALITY_PUBLIC_KEY}|g" \
    -e "s|__REALITY_SHORT_ID__|${REALITY_SHORT_ID}|g" \
    -e "s|__REALITY_SNI__|${REALITY_SNI}|g" \
    -e "s|__REALITY_FINGERPRINT__|${REALITY_FINGERPRINT}|g" \
    "$TMPL" > "$OUT"

# 2. No placeholder may survive.
if grep -q '__[A-Z_]\+__' "$OUT"; then
  echo "ERROR: unsubstituted placeholders remain:" >&2
  grep -o '__[A-Z_]\+__' "$OUT" | sort -u >&2
  exit 1
fi

# 3. Structural + semantic validation.
jq -e . "$OUT" >/dev/null || { echo "ERROR: rendered template is not valid JSON" >&2; exit 1; }
echo "JSON ok"
if docker run --rm -v "$OUT":/c.json:ro teddysun/xray xray -test -config /c.json; then
  echo "xray -test ok"
else
  echo "ERROR: xray rejected the rendered config - not applying" >&2
  exit 1
fi

# 4. Snapshot the panel DB. This is the rollback point.
STAMP="$(date +%F_%H%M%S)"
docker exec "$CONTAINER" sqlite3 /etc/x-ui/x-ui.db ".backup /etc/x-ui/x-ui.db.bak-${STAMP}"
echo "DB snapshot: /etc/x-ui/x-ui.db.bak-${STAMP}"

# 5. Confirm the schema matches what we are about to write.
if ! docker exec "$CONTAINER" sqlite3 /etc/x-ui/x-ui.db \
      "select name from sqlite_master where type='table' and name='settings';" | grep -q settings; then
  echo "ERROR: no 'settings' table - inspect the schema, fall back to the panel UI" >&2
  exit 1
fi

# 6. Write the template.
docker cp "$OUT" "$CONTAINER":/tmp/tmpl.json
docker exec "$CONTAINER" sqlite3 /etc/x-ui/x-ui.db \
  "INSERT INTO settings (key,value) VALUES ('${SETTINGS_KEY}', readfile('/tmp/tmpl.json'))
   ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
docker exec "$CONTAINER" rm -f /tmp/tmpl.json

# 7. Restart and confirm xray came back.
docker restart "$CONTAINER" >/dev/null
for _ in $(seq 1 15); do
  sleep 2
  if docker exec "$CONTAINER" pgrep xray >/dev/null 2>&1; then
    echo "applied: xray running after restart"
    exit 0
  fi
done
echo "ERROR: xray did not come back. Restore: scripts/restore-db.sh x-ui.db.bak-${STAMP}" >&2
docker logs --tail 40 "$CONTAINER" >&2 || true
exit 1
