
-- LanCache-NG (https://github.com/wiki-mod/lancache-ng)
-- SPDX-License-Identifier: AGPL-3.0-or-later
-- PowerDNS recursor Lua hooks: RPZ policy loading, negative trust anchors,
-- and optional root zone caching.

-- RPZ: CDN-Domains → Proxy-IP
rpzFile("/var/lib/powerdns/rpz.zone", { policyName="lancache-rpz" })

-- Negative trust anchors: every zone forwarded to our local authoritative
-- server (recursor.conf.template's forward_zones) is intentionally unsigned
-- -- .lan is not a real TLD and the RFC1918 reverse zones have no real
-- delegation chain reaching our internal server. Without this, the
-- recursor's default DNSSEC processing treats a forwarded answer's missing
-- RRSIGs as Bogus and returns SERVFAIL for every query into these zones
-- (confirmed live while building issue #400's integration test -- nobody
-- had ever driven a real query into the "lan." zone before). This must be
-- set via addNTA(), not the YAML config's dnssec.negative_trustanchors: the
-- recursor refuses to start when YAML dnssec settings and a
-- recursor.lua_config_file (this file) are both present ("YAML settings
-- include values originally in Lua ... This is unsupported" -- confirmed
-- live too).
for _, zone in ipairs({
  "lan", "local.lan",
  "10.in-addr.arpa", "168.192.in-addr.arpa",
  "16.172.in-addr.arpa", "17.172.in-addr.arpa", "18.172.in-addr.arpa",
  "19.172.in-addr.arpa", "20.172.in-addr.arpa", "21.172.in-addr.arpa",
  "22.172.in-addr.arpa", "23.172.in-addr.arpa", "24.172.in-addr.arpa",
  "25.172.in-addr.arpa", "26.172.in-addr.arpa", "27.172.in-addr.arpa",
  "28.172.in-addr.arpa", "29.172.in-addr.arpa", "30.172.in-addr.arpa",
  "31.172.in-addr.arpa",
  "c.f.ip6.arpa", "d.f.ip6.arpa",
}) do
  addNTA(zone, "lancache-ng: locally forwarded, intentionally unsigned zone")
end

-- What: zones the operator marked as unsigned.
-- Why: their answers carry no DNSSEC and would be SERVFAIL.
-- From: Issue #1918
for zone in string.gmatch(os.getenv("DNS_UPSTREAM_UNSIGNED_ZONES") or "", "%S+") do
  addNTA(zone, "lancache-ng: unsigned zone of the upstream resolver")
end

-- What: note whether the entrypoint forwards ".".
-- Why: the root mirror is idle while every name is forwarded.
-- From: Issue #1918
local upstream_root = false
for zone in string.gmatch(os.getenv("DNS_UPSTREAM_ZONES") or "", "%S+") do
  if zone == "." then
    upstream_root = true
  end
end

-- Root-Zone Mirror: keep root zone cached locally (PowerDNS Recursor 5.x API)
-- Enable with ROOT_ZONE_MIRROR=1 (default: 1, disable with 0)
-- What: the root mirror stays off while "." is forwarded.
-- Why: no query reaches the root servers, so the copy is idle.
-- From: Issue #1918
if os.getenv("ROOT_ZONE_MIRROR") ~= "0" and not upstream_root then
  zoneToCache(".", "axfr", "199.9.14.201", { refreshPeriod=3600, retryOnError=3600 })
  zoneToCache(".", "axfr", "192.33.4.12",    { refreshPeriod=3600, retryOnError=3600 })
  zoneToCache(".", "axfr", "192.5.5.241",    { refreshPeriod=3600, retryOnError=3600 })
end
