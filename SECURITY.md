# Security Policy

## Security Contact

If you discover a security vulnerability in lancache-ng, please report it privately to the repository owner:

- **GitHub**: Please open a private security advisory via [GitHub Security Advisories](https://github.com/wiki-mod/lancache-ng/security/advisories)

Do **not** open a public GitHub issue for security vulnerabilities. Private disclosure helps us address issues before they are publicly known.

## Supported Versions

| Version | Status | Support Until |
|---------|--------|----------------|
| 0.3.x (pre-1.0) | Current | Ongoing |
| 0.2.x | Supported (previous line) | Until the next minor line is published |
| 0.1.x and older | EOL | Ended |

Support covers the current minor line and the minor line before it. An
installation on an older line has no support and has to be updated first.

How the table is read:

| Position | Meaning | Support |
|----------|---------|---------|
| Current line | The newest minor line | Yes |
| One line back (-1) | The minor line before the current one | Yes, until the next minor line is published |
| Two lines back (-2) and older | Every earlier minor line | No (EOL) |

Example: 0.3.x is current and 0.2.x is one line back. When 0.4.x is published,
0.4.x is current, 0.3.x is one line back and 0.2.x is EOL. An operator who
wants support keeps the installation on the current line or the one before it.

lancache-ng has not reached a `1.0.0` release yet (see `docs/combined-release-and-checklist.md`
for the full channel/tagging model); the current stable release line is `v0.3.x`.

### Scope and duration of support (per minor line)

- **What is supported**: the current minor line and the minor line before it.
  Every `vX.Y.Z` release is a full stack release (see
  `docs/combined-release-and-checklist.md`, section "Release model"); support
  is per stack release line, not per individual service image.
- **What kind of support**: security fixes and correctness bug fixes, applied
  by publishing a new stable release of a supported line.
- **Duration**: a minor line is supported until the next minor line after the
  current one is published, and is EOL from then on. With 0.3.x current, 0.2.x
  is supported until 0.4.x is published.
- **Updating**: an installation on an unsupported line is updated to a
  supported line to receive support.
- **Pre-1.0 caveat**: as a pre-1.0 project, breaking changes and security-
  relevant behavior changes can still land between minor versions; the
  `CHANGELOG.md` and each release's notes call these out explicitly.

## Reporting a Vulnerability

This is the project's documented process for responding to vulnerability
reports, satisfying the OpenSSF Best Practices Badge's Silver-tier
`vulnerability_response_process` criterion (project #13763, issue #1130):

1. **Contact**: Send a detailed report to the security contact above, or use GitHub's private advisory feature.
2. **Information to include**:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if you have one)
3. **Response**: We will acknowledge receipt within 48 hours and work to address the issue.
4. **Disclosure**: Once a fix is released, the vulnerability will be disclosed responsibly and
   publicly, as a [GitHub Security Advisory](https://github.com/wiki-mod/lancache-ng/security/advisories)
   on this repository. That page is the authoritative, public record of every vulnerability
   confirmed in lancache-ng; an empty list there means no vulnerability has been confirmed yet,
   not that this project does not publish them.
5. **Credit**: Every vulnerability report resolved within the last 12 months is credited to its
   reporter(s) in the corresponding GitHub Security Advisory, unless the reporter explicitly
   requests anonymity. This satisfies the Best Practices Badge's Silver-tier
   `vulnerability_report_credit` criterion. If a past advisory is missing credit that the
   reporter did not decline, that is a documentation gap to fix on that advisory, not a policy
   exception.

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
- HTTPS mode (`192.168.1.11` DNS) is designed for maximum caching benefit
- Clients that cannot or will not trust the CA can use HTTP mode instead

### 2. DNS Spoofing of CDN Domains

**Design**: PowerDNS authoritative zone redirects known CDN domains to the cache proxy's IP via zone files compiled from `cdn-domains.txt`.

**Tradeoff**: All traffic for whitelisted CDN domains is intercepted. This is **intentional** — without DNS spoofing, clients would bypass the cache.

**Mitigation**:
- Only known CDN domains are spoofed; see `services/dns/cdn-domains.txt`
- Gaming consoles (PS5, Xbox) are explicitly excluded to prevent breakage
- The spoofing scope is limited to a curated list; arbitrary domains are not affected
- Clients can opt out by using HTTP mode (passthrough HTTPS) or external DNS

**What is spoofed**: Game CDNs (Steam, Epic, Blizzard, etc.) and software distributors.

**What is not spoofed**: Web browsers, corporate networks, banking, or other general-purpose traffic.

### 3. Docker Socket Mount in the services and ui Containers

**Design**: Two containers mount the Docker daemon socket (SOT `DOCKER_SOCKET`, read-write, no socket proxy): `services` for its watchdog, which lists the stack's containers, inspects them and restarts a failing one, and `ui`, which wakes owner containers after it writes configs, reads container state and statistics, and runs commands in containers (`docker` module in `services/common/shared.rs`, `deploy/prod/docker-compose.yml`).

**Known Risk**: The Docker socket is a privileged interface — any process with access can run arbitrary containers with full host privileges. A compromise of the `services` container or of the `ui` container is a host compromise. The Admin UI is network-facing, so its authentication is part of this risk.

**Mitigation**:
- The `services` container drops all capabilities except the list in `deploy/prod/docker-compose.yml`
- Enable the Admin UI authentication before production deployment (see section 4)
- Configure Docker rootless mode on the host if available
- Restrict network access to the Admin UI and the `services` ports (do not expose them to untrusted networks)

### 4. Admin UI Authentication Must Be Explicit

**Design**: The setup flow now requires either UI credentials or an explicit `ALLOW_INSECURE_UI=true` opt-in before the Admin UI can start without authentication.

**Status**: Unauthenticated access is an explicit choice with a default of open (`ALLOW_INSECURE_UI=true`): `setup.sh` asks "Protect Admin-UI with password? [y/N]" (default No) and, on No, "Allow Admin-UI without authentication?"; answering No to both repeats the question. With a password set the Admin UI requires HTTP Basic credentials. The choice is made in the setup flow; the `ui` process itself does not read `ALLOW_INSECURE_UI` (see `docs/threat-model.md`, T3).

**Required before production**:
- Configure authentication for the Admin UI
- Avoid `ALLOW_INSECURE_UI=true` on untrusted or shared networks
- Restrict Admin UI access to trusted network segments
- Do not expose the Admin UI directly to the internet

### 5. Upstream TLS Verification in nginx

**Design**: nginx fetches the real CDN with the scheme the client used: HTTP requests over HTTP, HTTPS-mode requests over HTTPS with the upstream certificate chain validated (`proxy_ssl_verify on`).

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
`DDNS_TSIG_KEY`, `SNMP_COMMUNITY`, `UI_AUTH_PASSWORD` and
`SECONDARY_REGISTRATION_TOKEN`):
- **Storing**: written to the operator's own `.env` file (gitignored) or, for
  values shared across containers, a shared-secrets Docker volume (see
  `docs/threat-model.md` T4/T5/T12 for the exact mechanism per secret).
  `ca.key` lives in the CA state directory (`CA_DIR`), outside the
  checkout (`AGENTS.md` `AG-KD-002`).
- **Accessing**: each service's entrypoint resolves only the specific
  secret(s) it needs from `.env`/the shared-secrets volume at startup; no
  service is handed a shared "all secrets" credential set.
- **Generating**: a missing or known-placeholder (`CHANGE_ME_*`) value is
  generated automatically on first start (fail-safe generation, not a
  fail-closed rejection, for values that are safe to auto-generate); an
  existing non-placeholder operator-supplied value is always preserved
  (`AGENTS.md` `AG-OP-006`/`AG-OP-009`). `setup.sh update`/`setup.sh
  auto-update` never rotates an already-set secret.
- **Rotating**: the Admin UI exposes explicit rotation for the secondary
  registration token (`/api/secondary/{name}/rotate`) and renews the TSIG key
  when a secondary is removed (`/api/secondary/{name}/remove`);
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

- **Tooling**: `bash .github/scripts/ci.sh check cargo-audit` runs
  `cargo audit --deny warnings` against the workspace lockfile
  (`CI_CARGO_LOCK`): in `ci.yml` when the plan sees that lockfile change, and
  daily in `nightly.yml` -- this denies on **any** reported
  advisory, not only Critical/High severity. Container base images and their
  OS packages are scanned with Trivy at image-build time.
- **Threshold**: zero-tolerance by default. Any `cargo audit` finding, or any
  Trivy-reported vulnerability not already listed in `.trivyignore.yaml`, is
  treated as a blocking failure. A finding may only be accepted (not fixed) by
  adding a justified entry to `.trivyignore.yaml`; Trivy accepts the entry
  without an exception expiry date, so the entry remains an explicit,
  documented disposition rather than an untracked suppression -- there is no
  equivalent suppression file for `cargo audit`
  findings today, so a Rust dependency advisory must be fixed (upgrade,
  patch, or replace the dependency) rather than suppressed.
- **License findings**: dependency license compliance is not currently
  automated by a dedicated SCA license-scanning tool (e.g. `cargo-deny`'s
  license checks). This is a known gap; license review today is manual.
- **Enforcement status**: the `cargo-audit` job of `.github/workflows/ci.yml`
  runs `ci.sh check cargo-audit` when a change touches the workspace lockfile
  (SOT `CI_CARGO_LOCK`), and the `cargo-audit` job of
  `.github/workflows/nightly.yml` runs it once a day against new advisory
  data. In `ci.yml` it feeds the `result` job, the always-present aggregate
  check meant for branch protection. **`current_dev`, where pull requests
  actually land, is protected** (as read with
  `gh api repos/wiki-mod/lancache-ng/branches/current_dev/protection` and
  `gh api repos/wiki-mod/lancache-ng/rulesets` on 2026-11-07): `result` is a required status
  check, enforced for non-administrators (`enforce_admins` is false), and an
  active ruleset requires a pull request before merging. A failing
  `cargo-audit` result therefore fails `result` and blocks a `current_dev`
  pull request for non-administrators.

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
  are visible as GitHub code scanning alerts. Before a CodeQL finding
  actually blocks a merge, the CodeQL analysis result has to be fed into the
  `result` gate (or an equivalent required check) the way `cargo-audit` is;
  this is tracked as a Level 3 follow-up in issue #1130 and its current
  state is not verified here. Until then, enforcement of this
  threshold relies on manual review of the repository's Security tab before
  each release.

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
4. **Logging and Monitoring**: Regularly review logs for suspicious activity.
5. **Regular Updates**: Keep the software and dependencies up to date.

## Responsible Disclosure

We take security seriously and appreciate responsible disclosure. If you discover a vulnerability:

1. Do not publicly disclose it until a fix is available
2. Provide clear, actionable information
3. Allow time for a response and patch release
4. Work with us to coordinate disclosure timing

Thank you for helping keep lancache-ng secure.
