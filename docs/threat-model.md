# lancache-ng Threat Model

This document outlines the security threats that lancache-ng is designed to protect against, and identifies risks that are out of scope.

## Assets Protected

1. **Network bandwidth**: Caching downloads locally reduces WAN bandwidth consumption
2. **Download speed**: Clients receive faster downloads from the local cache vs. remote CDNs
3. **Cache integrity**: Downloaded content should not be modified or poisoned
4. **Client privacy (HTTP)**: HTTP traffic should be cached without unencrypted content being logged externally
5. **Deployment confidentiality**: The cache itself should not be exposed to untrusted networks

## Threat Model Overview

### Trust Boundaries

```
┌─────────────────────────────────┐
│   TRUSTED: LAN Boundary         │
├─────────────────────────────────┤
│  lancache-ng                    │
│  - Proxy (nginx)                │
│  - DNS (BIND9)                  │
│  - Admin UI                     │
│  - NATS event bus               │
├─────────────────────────────────┤
│  UNTRUSTED: Internet (WAN)      │
│  - CDN servers                  │
│  - External DNS                 │
│  - Potential attackers          │
└─────────────────────────────────┘
```

**Key assumption**: All clients and services on the LAN are considered trusted. Attackers are assumed to be:
- External (attempting to exploit the cache from the internet)
- LAN-based (compromised client or internal attacker)

---

## Threat Analysis

### Threat 1: Cache Poisoning from CDN

**Threat**: An attacker compromises a CDN or intercepts traffic to a CDN, injecting malicious content that gets cached.

**Likelihood**: Low (CDNs use HTTPS; would require CDN compromise or network-level interception)

**Impact**: High (all clients would receive poisoned content)

**Mitigation**:
- nginx validates upstream TLS certificates via `proxy_ssl_verify` (enabled for real CDN connections)
- Use real DNS (`NGINX_UPSTREAM_RESOLVER`, default `8.8.8.8 8.8.4.4`) for upstream resolution, not the spoofed DNS
- Monitor cache hit rates for anomalies

**Residual Risk**: Medium (requires external compromise, not a local design flaw)

---

### Threat 2: LAN Attacker Poisoning the Cache

**Threat**: A compromised LAN client or rogue device sends crafted requests to the cache proxy, attempting to inject malicious content into the cache.

**Likelihood**: Medium (depends on LAN security)

**Impact**: High (poisoned content served to other clients)

**Mitigation**:
- Cache key includes the request Host header (`$host$uri`)
- nginx validates upstream responses before caching
- Implement rate limiting and request validation if needed

**Residual Risk**: Medium (mitigated by proper LAN isolation)

---

### Threat 3: Unauthorized Access to Admin UI

**Threat**: An attacker gains access to the Admin UI and modifies cache settings, purges cache, or stops services.

**Likelihood**: High (no authentication by default)

**Impact**: High (service disruption, cache poisoning)

**Mitigation**:
- Enable authentication before production (reverse proxy auth, or UI-level auth)
- Restrict Admin UI access to trusted IPs via firewall
- Use network policies to limit Admin UI exposure

**Residual Risk**: High (default: unauthenticated; requires user configuration)

---

### Threat 4: DNS Spoofing Bypass or Failure

**Threat**: An attacker tricks the cache or client into using a malicious DNS server, bypassing the cache.

**Likelihood**: Low (clients are pre-configured to use the cache's DNS)

**Impact**: Medium (clients bypass cache but no local compromise)

**Mitigation**:
- Document DNS configuration for clients
- Use static IP binding for the cache's DNS servers
- Monitor DNS query patterns for anomalies

**Residual Risk**: Low (user responsibility to configure DNS correctly)

---

### Threat 5: NATS Event Bus Exposure

**Threat**: An untrusted external client connects to the NATS event bus (port 4222) and publishes malicious events or retrieves cache metadata.

**Likelihood**: High (if exposed to internet)

**Impact**: Medium (service disruption, information disclosure)

**Mitigation**:
- Production Compose does not publish NATS port `4222` by default; it is exposed only on the internal Docker network.
- Remote secondary deployments must opt in with `deploy/prod/docker-compose.nats-secondary.yml` and set `NATS_BIND_IP` to a trusted LAN/VPN interface.
- NATS must be restricted to LAN-only via firewall rules when the optional secondary binding is enabled.
- Enable NATS authentication (username/password) in production.
- Use network policies to prevent internet-facing access.

**Residual Risk**: Medium (requires user to configure firewall correctly)

---

### Threat 6: Docker Socket Exposure

**Threat**: An attacker gains access to the Docker socket and uses it to spawn privileged containers or escape the sandbox.

**Likelihood**: Medium (socket is mounted in UI container)

**Impact**: Critical (full host compromise)

**Mitigation**:
- Restrict Docker socket access via file permissions
- Use Docker rootless mode if available
- Enable Admin UI authentication (prevents unauthorized access to socket)
- Do not run untrusted containers on the same host

**Residual Risk**: Medium (documented in SECURITY.md; requires user awareness)

---

### Threat 7: TLS Certificate Spoofing (SSL Mode)

**Threat**: An attacker intercepts client-to-proxy traffic and presents their own certificate, impersonating the cache.

**Likelihood**: Low (requires MitM on LAN or compromised network)

**Impact**: High (client data interception)

**Mitigation**:
- Clients validate the cache's certificate (signed by the trusted LAN CA)
- The CA certificate is installed explicitly on each client
- Standard mode (SNI passthrough) does not use local TLS, avoiding this vector

**Residual Risk**: Low (mitigated by client trust of CA certificate)

---

### Threat 8: Upstream TLS Verification Bypass

**Threat**: If upstream TLS verification is disabled or misconfigured, an attacker who can intercept proxy-to-CDN traffic could impersonate the CDN and poison cached content.

**Likelihood**: Low (requires network-level interception between the proxy and CDN)

**Impact**: High (malicious content could be cached and served to multiple clients)

**Mitigation**:
- nginx enables `proxy_ssl_verify on` for origin connections
- nginx uses public upstream DNS resolvers, not the local spoofing DNS, to avoid resolving CDN origins back to the cache
- The proxy container includes the Debian CA bundle and configures it with `proxy_ssl_trusted_certificate`
- Monitor proxy logs for upstream certificate validation failures

**Residual Risk**: Medium (certificate validation reduces MitM risk, but CDN compromise or trusted-CA misissuance remains possible)

---

### Threat 9: Cache Size Exhaustion (DoS)

**Threat**: An attacker requests many unique large files, filling the cache disk and causing a denial of service.

**Likelihood**: Medium (if LAN access is available)

**Impact**: Medium (service degradation, cache eviction)

**Mitigation**:
- nginx `proxy_cache_use_stale` serves stale content if disk is full
- Configure reasonable cache size limits in production
- Monitor disk usage and alerts

**Residual Risk**: Medium (no rate limiting by default; user must configure)

---

### Threat 10: Client TLS Certificate Validation (SSL Mode)

**Threat**: A client connects to SSL mode without installing the CA certificate.

**Likelihood**: High (user error)

**Impact**: Low (connection fails gracefully)

**Mitigation**:
- Provide clear documentation on CA certificate installation
- Offer standard mode as an alternative (no CA cert required)
- Client error is expected and intentional

**Residual Risk**: Low (expected behavior; user must follow setup docs)

---

## Out of Scope Threats

The following threats are **not addressed** by lancache-ng:

1. **Internet-facing deployment attacks**: lancache-ng is not hardened for exposure to the internet. External DDoS, zero-day exploits, and advanced persistent threats are not addressed.

2. **Multi-tenant isolation**: lancache-ng does not provide isolation between different users or organizations on the same LAN. A compromised client can see all cached content.

3. **Encrypted client-to-CDN replay attacks**: Encrypted content is cached as-is. If a signature is valid only for the original requestor, the cached response may be used by others (this is a feature, not a bug, but may have privacy implications).

4. **Hardware-level attacks**: Side-channel attacks (Spectre, Meltdown) on the host CPU are not mitigated.

5. **Physical security**: Physical access to the cache host is not protected against. An attacker with physical access can compromise the system.

6. **Supply chain attacks**: Compromised Docker images or dependencies from package repositories are not mitigated (rely on upstream security practices).

---

## Deployment Risk Assessment

### Low-Risk Deployment
- Private LAN (home, office, datacenter)
- Controlled network access
- Admin UI behind firewall
- NATS restricted to LAN
- Authentication enabled on Admin UI

### Medium-Risk Deployment
- Same LAN but with many untrusted clients
- No rate limiting configured
- Weak firewall rules
- NATS accessible to some untrusted segments

### High-Risk Deployment
- Internet-facing Admin UI (without reverse proxy auth)
- NATS exposed to untrusted networks
- Docker socket accessible to untrusted containers
- No authentication on Admin UI
- No firewall protection

---

## Security Roadmap

Potential future improvements:

1. **Built-in Admin UI authentication**: Reduce reliance on external auth proxies
2. **NATS authentication hardening**: Stronger token-based auth by default
3. **Rate limiting and DDoS protection**: Configurable limits per IP
4. **Audit logging**: Track Admin UI and cache operations for forensics
5. **Content signature verification**: Optional GPG/HMAC validation of cached files
6. **Prometheus metrics for security events**: Alert on anomalies

---

## Conclusion

lancache-ng is designed for **trusted LAN environments only**. The architecture intentionally trades off some security guarantees (e.g., upstream TLS verification, default unauthenticated Admin UI) in favor of simplicity and performance.

Users are responsible for:
1. Deploying on a trusted, isolated LAN
2. Configuring firewall rules to restrict service access
3. Enabling authentication before production
4. Monitoring for suspicious activity
5. Keeping dependencies up to date

For questions or security concerns, contact dominik.lepiorz@aunetic.com.
