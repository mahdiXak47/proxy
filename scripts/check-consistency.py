#!/usr/bin/env python3
"""Cross-side consistency guard.

The whole point of this monorepo: the edge and the exit must agree on the REALITY
hop. This asserts that the committed edge template, the Ansible exit template and
shared/endpoints.yml describe the same tunnel. A rotation applied to only one half
fails here instead of silently killing the tunnel.
"""
from __future__ import annotations
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
errors: list[str] = []
checks = 0


def load_flat_yaml(text: str) -> dict:
    """Minimal flat YAML reader: scalars and '- item' lists. Matches render-env.sh."""
    data: dict = {}
    key = None
    for raw in text.splitlines():
        line = "" if raw.strip().startswith("#") else raw.split("#", 1)[0].rstrip()
        if not line.strip() or line.strip() == "---":
            continue
        m = re.match(r"^(\S[^:]*):\s*(.*)$", line)
        if m:
            key, val = m.group(1).strip(), m.group(2).strip()
            data[key] = [] if val == "" else val.strip('"').strip("'")
        elif line.lstrip().startswith("- ") and key:
            item = line.lstrip()[2:].strip().strip('"').strip("'")
            if isinstance(data.get(key), list):
                data[key].append(item)
    return data


def check(label: str, condition: bool, detail: str = "") -> None:
    global checks
    checks += 1
    if condition:
        print(f"  ok    {label}")
    else:
        print(f"  FAIL  {label}" + (f" -- {detail}" if detail else ""))
        errors.append(label)


ep = load_flat_yaml((ROOT / "shared" / "endpoints.yml").read_text())
edge_raw = (ROOT / "edge" / "config" / "xray-template.json").read_text()
exit_raw = (ROOT / "exit" / "roles" / "xray" / "templates" / "config.json.j2").read_text()

print("endpoints.yml ->")
for k in ("tr_ip", "edge_ip", "panel_domain", "reality_port", "reality_alt_port",
          "reality_dest", "reality_fingerprint", "edge_socks_port", "edge_http_port"):
    check(f"endpoints.yml defines {k}", k in ep, "missing key")
for k in ("reality_server_names", "reality_short_ids", "reality_alt_short_ids"):
    check(f"endpoints.yml defines non-empty {k}",
          isinstance(ep.get(k), list) and len(ep[k]) > 0, "missing or empty list")

print("\nedge template ->")
edge = json.loads(
    edge_raw.replace('"__TR_PORT__"', "0")
    .replace('"__EDGE_SOCKS_PORT__"', "0")
    .replace('"__EDGE_HTTP_PORT__"', "0")
)
check("edge template is valid JSON once ports are substituted", True)

out_by_tag = {o["tag"]: o for o in edge["outbounds"]}
check("edge has a 'tr-exit' outbound", "tr-exit" in out_by_tag)
check("edge has a 'direct' outbound", "direct" in out_by_tag)
check("edge has a 'blocked' outbound", "blocked" in out_by_tag)

if "tr-exit" in out_by_tag:
    o = out_by_tag["tr-exit"]
    ss = o["streamSettings"]
    rs = ss["realitySettings"]
    user = o["settings"]["vnext"][0]["users"][0]
    check("tr-exit uses vless", o["protocol"] == "vless")
    check("tr-exit uses reality security", ss["security"] == "reality")
    check("tr-exit uses tcp network", ss["network"] == "tcp")
    check("tr-exit uses xtls-rprx-vision flow", user.get("flow") == "xtls-rprx-vision")
    check("tr-exit disables mux (mux + Vision conflict)",
          o.get("mux", {}).get("enabled") is False)
    check("tr-exit address is a placeholder, not a hardcoded IP",
          o["settings"]["vnext"][0]["address"] == "__TR_IP__")
    check("tr-exit publicKey is a placeholder (no secret committed)",
          rs["publicKey"] == "__REALITY_PUBLIC_KEY__")
    check("tr-exit uuid is a placeholder (no secret committed)",
          user["id"] == "__TR_UUID__")

in_by_tag = {i["tag"]: i for i in edge["inbounds"]}
check("edge exposes a local socks inbound", "socks-local" in in_by_tag)
check("edge exposes a local http inbound", "http-local" in in_by_tag)
for tag in ("socks-local", "http-local"):
    if tag in in_by_tag:
        check(f"{tag} binds loopback only", in_by_tag[tag]["listen"] == "127.0.0.1",
              "must not be reachable off-host")
check("edge keeps the api inbound (panel stats/expiry depend on it)", "api" in in_by_tag)
check("edge keeps stats enabled", "stats" in edge)

rules = edge["routing"]["rules"]
tags = [r.get("outboundTag") for r in rules]
check("last routing rule is the catch-all to tr-exit", tags[-1] == "tr-exit")
check("domestic domains routed direct via the real geosite code",
      any(r.get("outboundTag") == "direct" and
          "geosite:category-ir" in r.get("domain", []) for r in rules),
      "geosite:ir does not exist in geosite.dat; the code is category-ir")
check("no non-existent geosite codes referenced",
      "geosite:ir\"" not in edge_raw and "geolocation-!ir" not in edge_raw,
      "xray refuses to start on an unknown geosite code")
check("domestic DNS is scoped and guarded by expectIPs",
      any(isinstance(s, dict) and "geoip:ir" in s.get("expectIPs", [])
          for s in edge["dns"]["servers"]),
      "prevents DNS poisoning dragging domestic domains into the tunnel")
check("domestic IPs routed direct",
      any(r.get("outboundTag") == "direct" and "geoip:ir" in r.get("ip", []) for r in rules))
check("private IPs blocked on the edge",
      any(r.get("outboundTag") == "blocked" and "geoip:private" in r.get("ip", [])
          for r in rules))
check("bittorrent blocked on the edge",
      any(r.get("outboundTag") == "blocked" and "bittorrent" in r.get("protocol", [])
          for r in rules))

print("\nexit template ->")
check("exit binds the primary REALITY port from shared/",
      "port: {{ reality_port }}".replace("port: ", "port: ") and
      "{{ reality_port }}" in exit_raw, "must not hardcode the port")
check("exit binds the failover REALITY port from shared/",
      "{{ reality_alt_port }}" in exit_raw)
check("exit reads serverNames from shared/", "{{ reality_server_names | to_json }}" in exit_raw)
check("exit reads dest from shared/", "{{ reality_dest }}" in exit_raw)
check("exit reads the private key from the vault",
      "{{ vault_reality_private_key }}" in exit_raw)
check("exit reads the client uuid from the vault",
      "{{ vault_xray_client_uuid }}" in exit_raw)
check("exit uses xtls-rprx-vision on both inbounds",
      exit_raw.count('"flow": "xtls-rprx-vision"') == 2)
check("exit never logs access (privacy)", '"access": "none"' in exit_raw)
check("exit blocks private IPs", '"ip": ["geoip:private"]' in exit_raw)
check("exit blocks bittorrent", '"bittorrent"' in exit_raw)
check("exit template has no literal private key",
      not re.search(r'"privateKey":\s*"[A-Za-z0-9_-]{20,}"', exit_raw))

print("\nno secrets committed ->")
for rel in ("edge/config/xray-template.json",
            "exit/roles/xray/templates/config.json.j2",
            "shared/endpoints.yml"):
    body = (ROOT / rel).read_text()
    check(f"{rel} contains no UUID literal",
          not re.search(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b",
                        body))

nft = (ROOT / "exit" / "roles" / "hardening" / "templates" / "nftables.conf.j2").read_text()
sshd = (ROOT / "exit" / "roles" / "hardening" / "templates" / "10-hardening.conf.j2").read_text()
evars = load_flat_yaml(
    (ROOT / "exit" / "inventories" / "prod" / "group_vars" / "exit" / "vars.yml").read_text())

print("\nfirewall ->")
check("input chain default-drops", "policy drop" in nft)
check("forward chain default-drops", nft.count("policy drop") >= 2)
check("REALITY ports allowlisted to the edge set", "ip saddr @edge_v4" in nft)
check("both REALITY ports opened",
      "{{ reality_port }}" in nft and "{{ reality_alt_port }}" in nft)
check("interval sets use auto-merge",
      nft.count("auto-merge") >= 2,
      "overlapping CIDRs otherwise fail with 'conflicting intervals specified'")

print("\nssh exposure ->")
mode = evars.get("ssh_exposure", "")
check("ssh_exposure is set to a known mode", mode in ("open", "allowlist"), f"got '{mode}'")
check("template implements both exposure modes",
      "ssh_exposure == 'allowlist'" in nft and "meter ssh_rate4" in nft)
check("REALITY ports stay edge-only regardless of ssh_exposure",
      "ip saddr @edge_v4" in nft.split("--- the proxy hop")[1]
      if "--- the proxy hop" in nft else False,
      "the proxy hop must never follow the ssh exposure mode")

if mode == "open":
    check("open mode rate-limits NEW ssh per source IP",
          "meter ssh_rate4" in nft and "ip saddr limit rate" in nft,
          "a global limit would let a flood lock the real admin out")
    check("open mode leaves established sessions untouched",
          "ct state established,related accept" in nft
          and nft.index("ct state established,related accept") < nft.index("meter ssh_rate4"),
          "the established rule must precede the meter or sessions could be throttled")
elif mode == "allowlist":
    check("allowlist mode has at least one admin CIDR",
          isinstance(evars.get("admin_ssh_cidrs"), list) and len(evars["admin_ssh_cidrs"]) > 0,
          "an empty allowlist locks you out completely")

print("\nssh daemon policy ->")
check("passwords disabled", "PasswordAuthentication no" in sshd)
check("keyboard-interactive disabled", "KbdInteractiveAuthentication no" in sshd)
check("publickey is the only accepted method", "AuthenticationMethods publickey" in sshd)
check("root may not use a password", "PermitRootLogin prohibit-password" in sshd)
check("unauthenticated connection flood capped", "MaxStartups" in sshd)
check("per-source penalties kept in a version-gated drop-in",
      (ROOT / "exit" / "roles" / "hardening" / "templates" / "20-penalties.conf.j2").exists()
      and "PerSourcePenalties" not in sshd,
      "PerSourcePenalties breaks sshd < 9.8, so it must not live in the base drop-in")

print(f"\n{checks - len(errors)}/{checks} checks passed")
if errors:
    print("FAILED:", ", ".join(errors), file=sys.stderr)
    sys.exit(1)
print("consistency: ok")
