#!/usr/bin/env bash
# certbot --deploy-hook: copy renewed certs where the x-ui container can read them.
# Install:
#   certbot certonly --standalone -d conn.yedamanebemabededige.ir \
#     --deploy-hook /opt/proxy/edge/scripts/deploy-cert.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DOMAIN="${PANEL_DOMAIN:-conn.yedamanebemabededige.ir}"
LIVE="/etc/letsencrypt/live/${DOMAIN}"
[[ -d "$LIVE" ]] || { echo "ERROR: $LIVE not found" >&2; exit 1; }

mkdir -p certs
install -m 0644 "$LIVE/fullchain.pem" certs/fullchain.pem
install -m 0600 "$LIVE/privkey.pem"   certs/privkey.pem

docker restart "${XUI_CONTAINER:-x-ui}" >/dev/null
echo "certs deployed for $DOMAIN; x-ui restarted"
