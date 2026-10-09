#!/usr/bin/env bash
# End-to-end verification of the relay, run from the EDGE HOST.
# Non-zero exit means the tunnel is not actually carrying foreign traffic to Turkey.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[[ -f .env ]] && { set -a; . ./.env; set +a; }
SOCKS="127.0.0.1:${EDGE_SOCKS_PORT:-10808}"
HTTPP="127.0.0.1:${EDGE_HTTP_PORT:-10809}"
FAIL=0
ok()   { printf '  [ OK ]  %s\n' "$1"; }
bad()  { printf '  [FAIL]  %s\n' "$1"; FAIL=1; }
info() { printf '  [info]  %s\n' "$1"; }

echo "== 1. local inbounds listening =="
for p in "${EDGE_SOCKS_PORT:-10808}" "${EDGE_HTTP_PORT:-10809}"; do
  if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:${p}"; then ok "port $p listening on loopback"
  else bad "port $p not listening"; fi
done

echo "== 2. foreign traffic must exit via Turkey =="
GEO="$(curl -s -m 20 --socks5-hostname "$SOCKS" https://ifconfig.co/json || true)"
if [[ -n "$GEO" ]]; then
  CC="$(echo "$GEO" | jq -r '.country_iso // .country // empty')"
  IP="$(echo "$GEO" | jq -r '.ip // empty')"
  info "egress ip=$IP country=$CC"
  if [[ "$CC" == "TR" ]]; then ok "foreign egress is Turkish"; else bad "expected TR, got '$CC'"; fi
else
  bad "no response through SOCKS - tunnel down?"
fi

echo "== 3. HTTP inbound works =="
CC2="$(https_proxy="http://$HTTPP" curl -s -m 20 https://ifconfig.co/json | jq -r '.country_iso // empty' || true)"
if [[ "$CC2" == "TR" ]]; then ok "http inbound reaches TR"; else bad "http inbound returned '$CC2'"; fi

echo "== 4. DNS/UDP through the tunnel (needed for TUN-mode clients) =="
ST="$(curl -s -m 20 --socks5-hostname "$SOCKS" 'https://dns.google/resolve?name=example.com' | jq -r '.Status // empty' || true)"
if [[ "$ST" == "0" ]]; then ok "DoH resolve through tunnel ok"; else bad "DoH resolve returned '$ST'"; fi

echo "== 5. domestic split-routing should stay direct =="
DOM_T="$(curl -s -m 20 --socks5-hostname "$SOCKS" -o /dev/null -w '%{time_total}' https://www.aparat.com || echo 99)"
DIR_T="$(curl -s -m 20 -o /dev/null -w '%{time_total}' https://www.aparat.com || echo 99)"
info "aparat.com via proxy ${DOM_T}s vs direct ${DIR_T}s (should be comparable, not Turkey-latency)"

echo "== 6. throughput sanity =="
SPD="$(curl -s -m 60 --socks5-hostname "$SOCKS" -o /dev/null -w '%{speed_download}' \
       'https://speed.cloudflare.com/__down?bytes=50000000' || echo 0)"
info "download: $(awk -v b="$SPD" 'BEGIN{printf "%.2f MB/s", b/1048576}')"
if awk -v b="$SPD" 'BEGIN{exit !(b > 262144)}'; then ok "throughput > 0.25 MB/s"
else bad "throughput too low ($SPD B/s)"; fi

echo "== 7. panel container health =="
if docker inspect -f '{{.State.Health.Status}}' "${XUI_CONTAINER:-x-ui}" 2>/dev/null | grep -q healthy; then
  ok "x-ui healthy"
else
  info "healthcheck not reporting healthy yet"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "ALL CHECKS PASSED"; exit 0; else echo "SOME CHECKS FAILED"; exit 1; fi
