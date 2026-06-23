-- RPZ: CDN-Domains → Proxy-IP
rpzFile("/var/lib/powerdns/rpz.zone", { policyName="lancache-rpz" })

-- Root-Zone Mirror: keep root zone cached locally (PowerDNS Recursor 5.x API)
-- Enable with ROOT_ZONE_MIRROR=1 (default: 1, disable with 0)
if os.getenv("ROOT_ZONE_MIRROR") ~= "0" then
  zoneToCache(".", "axfr", "192.228.79.201", { refreshPeriod=3600, retryOnError=3600 })
  zoneToCache(".", "axfr", "192.33.4.12",    { refreshPeriod=3600, retryOnError=3600 })
  zoneToCache(".", "axfr", "192.5.5.241",    { refreshPeriod=3600, retryOnError=3600 })
end
