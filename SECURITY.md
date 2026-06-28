# Security Policy

## Security Contact

If you discover a security vulnerability in lancache-ng, please report it privately to the repository owner:

- **Email**: dominik.lepiorz@aunetic.com
- **GitHub**: Please open a private security advisory via [GitHub Security Advisories](https://github.com/wiki-mod/lancache-ng/security/advisories)

Do **not** open a public GitHub issue for security vulnerabilities. Private disclosure helps us address issues before they are publicly known.

## Supported Versions

| Version | Status | Support Until |
|---------|--------|----------------|
| 1.x     | Current | Ongoing |

We aim to provide security updates for the current major version. Older versions are not actively maintained.

## Reporting a Vulnerability

1. **Contact**: Send a detailed report to the security contact above, or use GitHub's private advisory feature.
2. **Information to include**:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if you have one)
3. **Response**: We will acknowledge receipt within 48 hours and work to address the issue.
4. **Disclosure**: Once a fix is released, the vulnerability will be disclosed responsibly.

## Known Security Tradeoffs and Design Decisions

This section documents intentional security design decisions and known tradeoffs. lancache-ng is **LAN-only software** and is not designed for internet-facing deployment.

### 1. TLS Interception (MITM) via Custom CA

**Design**: lancache-ng can intercept and cache HTTPS traffic by acting as a man-in-the-middle (MITM). Clients must install a custom CA certificate once.

**Tradeoff**: Clients must trust a self-signed CA certificate on the LAN. This is **intentional** — without client trust of the CA, HTTPS caching cannot work.

**Mitigation**:
- The CA certificate is auto-generated and stored locally; clients import it explicitly
- The CA key is kept private and should never be shared beyond the LAN
- Use only in trusted network environments
- Document the CA installation process for clients

**When to use**: 
- SSL mode (`192.168.1.11` DNS) is designed for maximum caching benefit
- Clients that cannot or will not trust the CA can use standard mode instead

### 2. DNS Spoofing of CDN Domains

**Design**: PowerDNS authoritative zone redirects known CDN domains to the cache proxy's IP via zone files compiled from `cdn-domains.txt`.

**Tradeoff**: All traffic for whitelisted CDN domains is intercepted. This is **intentional** — without DNS spoofing, clients would bypass the cache.

**Mitigation**:
- Only known CDN domains are spoofed; see `services/dns/cdn-domains.txt`
- Gaming consoles (PS5, Xbox) are explicitly excluded to prevent breakage
- The spoofing scope is limited to a curated list; arbitrary domains are not affected
- Clients can opt out by using standard mode (passthrough HTTPS) or external DNS

**What is spoofed**: Game CDNs (Steam, Epic, Blizzard, etc.) and software distributors.

**What is not spoofed**: Web browsers, corporate networks, banking, or other general-purpose traffic.

### 3. Docker Socket Mount in UI Container

**Design**: The Admin UI container mounts the Docker daemon socket (`/var/run/docker.sock`) to allow container management.

**Known Risk**: The Docker socket is a privileged interface — any process with access can run arbitrary containers with full host privileges.

**Mitigation**:
- Enable authentication for the Admin UI before production deployment
- Configure Docker rootless mode on the host if available
- Restrict network access to the Admin UI (do not expose to untrusted networks)
- Use network policies or firewall rules to limit Admin UI access to trusted IPs

### 4. Admin UI Authentication Must Be Explicit

**Design**: The setup flow now requires either UI credentials or an explicit `ALLOW_INSECURE_UI=true` opt-in before the Admin UI can start without authentication.

**Status**: Unauthenticated access is still possible, but only after an explicit operator decision.

**Required before production**:
- Configure authentication for the Admin UI
- Avoid `ALLOW_INSECURE_UI=true` on untrusted or shared networks
- Restrict Admin UI access to trusted network segments
- Do not expose the Admin UI directly to the internet

### 5. NATS Event Bus (Port 4222) Exposed

**Design**: NATS broker is used for inter-service communication and is exposed on port 4222.

**Risk**: If exposed to the internet, untrusted clients could publish or subscribe to internal events.

**Mitigation**:
- NATS should only be accessible from within the LAN (not internet-facing)
- Configure firewall rules to restrict port 4222 to LAN traffic only
- Enable NATS authentication (username/password or client certificates) in production
- Use network policies (e.g., `UFW`, `iptables`) to limit access

### 6. Upstream TLS Verification in nginx

**Design**: nginx proxies cached HTTP and SSL-mode requests to the real CDN over HTTPS and validates the upstream certificate chain (`proxy_ssl_verify on`).

**Reason**: The proxy resolves upstream CDN hostnames with public DNS resolvers configured in nginx, not the local DNS-spoofing recursor, so certificate verification can validate the real origin.

**Risk**: If certificate validation is disabled or the trusted CA bundle is misconfigured, a network attacker could impersonate an upstream CDN and poison cached content.

**Mitigation**:
- Keep `proxy_ssl_verify on` and `proxy_ssl_trusted_certificate` pointed at the system CA bundle
- Network isolation: keep the cache host on a trusted, restricted network
- Monitor proxy logs for upstream certificate validation failures
- Keep the proxy image updated so CA certificates receive security updates

## Deployment Scope

**Supported**: lancache-ng is designed for trusted LAN environments (home, office, datacenter networks with controlled access).

**Not supported**:
- Internet-facing deployment without additional security hardening
- Untrusted networks
- Multi-tenant environments without proper isolation
- Public or open networks

## Security Best Practices for Deployment

1. **Network Isolation**: Run on a trusted, isolated LAN; do not expose to the internet without additional security.
2. **Access Control**: Restrict Admin UI access to authorized users and network segments.
3. **Firewall Rules**: Use network policies to limit service access (DNS, cache, Admin UI) to trusted IPs.
4. **NATS Authentication**: Enable authentication in production deployments.
5. **Logging and Monitoring**: Regularly review logs for suspicious activity.
6. **Regular Updates**: Keep the software and dependencies up to date.

## Responsible Disclosure

We take security seriously and appreciate responsible disclosure. If you discover a vulnerability:

1. Do not publicly disclose it until a fix is available
2. Provide clear, actionable information
3. Allow time for a response and patch release
4. Work with us to coordinate disclosure timing

Thank you for helping keep lancache-ng secure.
