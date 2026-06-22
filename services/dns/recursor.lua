-- RPZ: CDN-Domains → Proxy-IP
rpzFile("/var/lib/powerdns/rpz.zone", { policyName="lancache-rpz" })

-- Root-Zone Mirror: keep root zone cached locally
-- Enable with ROOT_ZONE_MIRROR=1 (default: 1, disable with 0)
if os.getenv("ROOT_ZONE_MIRROR") ~= "0" then
  zonetocaches({
    {
      zone=".",
      method="axfr",
      sources={
        "192.228.79.201",
        "192.33.4.12",
        "192.5.5.241",
        "192.112.36.4",
        "193.0.14.129",
        "192.0.47.132",
        "192.0.32.132",
      },
      refreshPeriod=3600,
      retryOnError=3600,
      maxReceivedMBytes=20,
    }
  })
end
