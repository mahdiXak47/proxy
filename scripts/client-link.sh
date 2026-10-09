#!/usr/bin/env bash
# Print the client-facing VLESS URI for the panel inbound.
# The panel generates these itself; this exists so the expected shape is documented
# and reviewable, and so you can sanity-check what the panel produced.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DOMAIN="$(python3 -c "
import re
for l in open('shared/endpoints.yml'):
    m=re.match(r'^panel_domain:\s*(.+)$', l.split('#',1)[0].rstrip())
    if m: print(m.group(1).strip().strip('\"')); break
")"

UUID="${CLIENT_UUID:-<client-uuid-from-panel>}"
NAME="${CLIENT_NAME:-tr-relay}"

cat <<EOF
Client-facing inbound (edge -> clients), TLS on your real domain:

  vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&alpn=h2%2Chttp%2F1.1&fp=chrome&type=tcp&flow=xtls-rprx-vision#${NAME}

Import into v2rayN / v2rayNG / Nekoray, then:
  - enable TUN / "VPN mode" for whole-device tunnelling
  - leave routing to the server (the edge already split-routes domestic traffic)
  - verify: ifconfig.co shows a Turkish IP, domestic sites stay fast

For CLI / container use on the edge host itself, skip the client entirely:
  curl --socks5-hostname 127.0.0.1:10808 https://ifconfig.co/json
  export https_proxy=http://127.0.0.1:10809
EOF
