# Security Policy

## Security Contact

If you discover a security vulnerability in lancache-ng, please report it privately to the repository owner:

- **GitHub**: Please open a private security advisory via [GitHub Security Advisories](https://github.com/wiki-mod/lancache-ng/security/advisories)

Do **not** open a public GitHub issue for security vulnerabilities. Private disclosure helps us address issues before they are publicly known.

## Supported Versions

| Version | Status | Support Until |
|---------|--------|----------------|
| 0.x (pre-1.0) | Current | Ongoing |

lancache-ng has not reached a `1.0.0` release yet (see `docs/release-versioning.md`
for the full channel/tagging model); the current stable release line is `v0.x`.
We aim to provide security updates for the current stable release. Older
releases are not actively maintained.

### Scope and duration of support (per release)

- **What is supported**: only the most recently published stable `vX.Y.Z`
  release tag (the one `latest` currently points at) receives bug fixes and
  security updates. Every `vX.Y.Z` release is a full stack release (see
  `docs/release-versioning.md`'s "Core Rule") -- support is per stack release,
  not per individual service image.
- **What kind of support**: security fixes and correctness bug fixes, applied
  by publishing a new stable release. There is no separate long-term-support
  (LTS) branch and no backported point releases for a release once a newer
  stable release has superseded it.
- **Duration**: a stable release stops receiving security updates the moment
  the next stable `vX.Y.Z` release is published -- there is no fixed
  post-supersession grace window today. Operators should update to the current
  stable release (or an audited `edge`/release-candidate build) promptly after
  a new stable release ships, especially when the release notes mention a
  security fix. This reflects this project's actual current maintenance
  capacity (a single primary maintainer); it may be revisited if that changes.
- **Pre-1.0 caveat**: as a pre-1.0 project, breaking changes and security-
  relevant behavior changes can still land between minor versions; the
  `CHANGELOG.md` and each release's notes call these out explicitly.

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

## Secrets and Credentials Management

This project's own secrets/credentials fall into two distinct groups with
different handling:

**CI/CD secrets** (used to build, scan, and publish the project itself):
- Stored exclusively as GitHub Actions Secrets (values) or Variables
  (non-secret configuration) at the repository level -- never hardcoded in
  workflow files, Dockerfiles, or source (`AGENTS.md` `AG-SEC-004`/`AG-SEC-005`).
  Examples: the GHCR publish token, `SCCACHE_REDIS_URL`, `SCCACHE_DIST_AUTH_TOKEN`.
- Access is scoped per-job via each workflow job's own `permissions:` block
  (least privilege; see `.github/workflows/*.yml`), not a blanket
  workflow-wide grant.
- Rotation of a CI secret is a manual GitHub Settings action by the repository
  owner; there is no automated rotation schedule today.

**Runtime/deployment secrets** (generated for and used by a running
lancache-ng install -- the local CA key, `PDNS_API_KEY`, `KEA_CTRL_TOKEN`,
`DDNS_TSIG_KEY`, the four NATS role passwords, `UI_AUTH_PASSWORD`,
`SECONDARY_REGISTRATION_TOKEN`, and per-secondary NATS credentials):
- **Storing**: written to the operator's own `.env` file (gitignored) or, for
  values shared across containers, a shared-secrets Docker volume (see
  `docs/threat-model.md` T4/T5/T12 for the exact mechanism per secret).
  `ca.key` lives under `<install>/certs/` and is gitignored (`AGENTS.md`
  `AG-KD-002`).
- **Accessing**: each service's entrypoint resolves only the specific
  secret(s) it needs from `.env`/the shared-secrets volume at startup; no
  service is handed a shared "all secrets" credential set.
- **Generating**: a missing or known-placeholder (`CHANGE_ME_*`) value is
  generated automatically on first start (fail-safe generation, not a
  fail-closed rejection, for values that are safe to auto-generate); an
  existing non-placeholder operator-supplied value is always preserved
  (`AGENTS.md` `AG-OP-006`/`AG-OP-009`). `setup.sh update`/`setup.sh
  auto-update` never rotates an already-set secret.
- **Rotating**: the Admin UI exposes explicit rotation for
  per-secondary NATS credentials (`POST /api/secondary/{name}/rotate-token`);
  other runtime secrets are rotated by an operator manually setting a new
  value and running `setup.sh update` (which does not overwrite an existing
  non-placeholder value, so the operator must intentionally replace it).
  There is no automatic time-based rotation for any runtime secret today.
- Sensitive information must never be hardcoded in source or committed to
  version control (`AGENTS.md` `AG-SEC-003`); GitHub secret scanning and push
  protection are both enabled on this repository as a backstop.

## Vulnerability Management Policy

This section documents the project's Software Composition Analysis (SCA) and
Static Application Security Testing (SAST) remediation policy.

### SCA (dependency vulnerability) findings

- **Tooling**: `cargo audit` runs against both first-party Rust crates
  (`services/ui`, `services/dns/nats-subscriber`) on every pull request and
  push, using `cargo audit --deny warnings` -- this denies on **any** reported
  advisory, not only Critical/High severity. Container base images and their
  OS packages are scanned with Trivy at image-build time.
- **Threshold**: zero-tolerance by default. Any `cargo audit` finding, or any
  Trivy-reported vulnerability not already listed in `.trivyignore.yaml`, is
  treated as a blocking failure. A finding may only be accepted (not fixed) by
  adding a dated, justified entry to `.trivyignore.yaml` with an explicit
  `expired_at` date, forcing periodic re-review rather than a silent permanent
  exception -- there is no equivalent suppression file for `cargo audit`
  findings today, so a Rust dependency advisory must be fixed (upgrade,
  patch, or replace the dependency) rather than suppressed.
- **License findings**: dependency license compliance is not currently
  automated by a dedicated SCA license-scanning tool (e.g. `cargo-deny`'s
  license checks). This is a known gap; license review today is manual.
- **Enforcement status**: the `cargo-audit (dns/nats-subscriber)` and
  `cargo-audit (ui)` jobs run on every pull request and push to `current_dev`
  (the active development branch, per issue #825's branch-model decision) and
  feed into the `CI scope policy` job in `.github/workflows/build-push.yml`.
  `CI scope policy` **is** a required branch-protection status check on
  `master` -- but `master` receives only occasional stable-release promotions,
  not day-to-day merges. **`current_dev`, where pull requests actually land,
  currently has no branch protection rule at all** (confirmed via
  `gh api repos/wiki-mod/lancache-ng/branches/current_dev/protection`, which
  returns 404 "Branch not protected"). In practice this means a failing
  `cargo-audit` result is clearly visible as a red check on a `current_dev`
  PR, but nothing in GitHub's own repository configuration currently stops
  that PR from being merged anyway. Closing this gap requires enabling branch
  protection on `current_dev` with `CI scope policy` (or an equivalent
  aggregate check) as a required status check -- a repository-settings change
  for the maintainer to make, tracked as a Level 3 follow-up in issue #1130.

### SAST (static analysis) findings

- **Tooling**: GitHub CodeQL (`.github/workflows/codeql.yml`) analyzes the
  `actions` (GitHub Actions workflow) and `rust` (both first-party crates)
  languages on every pull request, push, and a daily schedule, uploading
  results as GitHub code scanning alerts.
- **Threshold**: any CodeQL alert on human-authored code (not the documented
  macro-expansion extraction-warning carve-out in issue #394) at Error or
  Warning severity must be triaged and either fixed or explicitly dismissed
  with a documented reason before the affected code ships in a stable
  release, matching this project's existing warnings-as-errors posture for
  every other static check (`cargo clippy`, `shellcheck`, `actionlint`; see
  `CONTRIBUTING.md`'s "Warning-as-errors policy").
- **Enforcement status**: CodeQL already runs on every `current_dev` pull
  request and push (`.github/workflows/codeql.yml`'s `branches:` list
  explicitly includes `current_dev`, added by issue #709 specifically so
  CodeQL keeps scanning the branch real work actually lands on), and results
  are visible as GitHub code scanning alerts. Two things still need to happen
  before a CodeQL finding actually blocks a merge, both tracked as Level 3
  follow-ups in issue #1130: (1) the CodeQL analysis result is not yet fed
  into the `CI scope policy` gate (or an equivalent check) the way
  `cargo-audit` is, and (2) as described just above, `current_dev` has no
  branch protection at all today, so even a check that is technically
  required would not yet be enforced there. Until both land, enforcement of
  this threshold relies on manual review of the repository's Security tab
  before each release.

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
