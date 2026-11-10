# Security Policy

## Reporting a vulnerability

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/wiki-mod/lancache-ng/security/advisories).
Do not open a public issue for a vulnerability.

A report contains:

- description of the vulnerability
- steps to reproduce
- impact
- suggested fix, if known

Process:

1. Receipt is acknowledged within 48 hours.
2. The fix is published in a release of every supported line.
3. The vulnerability is then published as a GitHub Security Advisory on this
   repository. That list is the public record of confirmed vulnerabilities.
4. The reporter is credited in the advisory unless they ask to stay anonymous.

Do not disclose a vulnerability publicly before the fix is released.

## Supported versions

| Line | Support |
|------|---------|
| Current minor line (served by the `latest` channel) | Yes |
| Previous minor line | Yes, until the next minor line is released |
| Older lines | No (EOL) |

Support means security and correctness fixes, published as new releases of a
supported line. Every `vX.Y.Z` release is a full stack release; support applies
per stack release line, not per service image. An installation on an EOL line
is updated to a supported line first.

lancache-ng is before `1.0.0`. Breaking and security-relevant changes can land
between minor versions; `CHANGELOG.md` and the release notes list them.
Channels and tags: `docs/combined-release-and-checklist.md`.

## Deployment scope

lancache-ng is LAN software for trusted networks (home, office, data center
with controlled access).

Not supported:

- internet-facing deployment
- untrusted, public or open networks
- multi-tenant environments without isolation

## Design decisions and risks

### TLS interception with a local CA

- HTTPS mode intercepts and caches HTTPS downloads. Clients must trust the
  locally generated CA.
- The CA key stays on the host in `CA_DIR`; only the certificate goes to
  clients.
- Clients that do not trust the CA use HTTP mode (the DNS IP of HTTP mode,
  `IP_HTTP`).

### DNS redirection of CDN domains

- The DNS service answers the domains in `services/dns/cdn-domains.txt` with
  the cache IP. All traffic for these domains goes through the cache.
- Only listed domains are redirected; every other name resolves normally.
- The list covers game launchers, Windows Update and Xbox, and Linux
  distributions.

### Docker socket in the `services` and `ui` containers

- `services` (watchdog) and `ui` mount the Docker socket read-write
  (`DOCKER_SOCKET`, `deploy/prod/docker-compose.yml`). `services` lists,
  inspects and restarts stack containers; `ui` reads container state, wakes
  containers after config writes and runs commands in them.
- Access to the socket equals root on the host. A compromise of `services` or
  `ui` is a host compromise.
- `services` drops all capabilities except the list in
  `deploy/prod/docker-compose.yml`.
- Protect the Admin UI with a password and restrict network access to it.

### Admin UI authentication

- With a password hash set, the Admin UI requires HTTP Basic authentication.
- Without a hash, the `ui` process does not start unless
  `ALLOW_INSECURE_UI=true`.
- `setup.sh install` asks "Protect Admin-UI with password? [y/N]"; on No it asks
  "Allow Admin-UI without authentication?". The default is open access.
- `setup.sh reset-sign-in` turns the sign-in off after a lockout.
- On shared or untrusted networks, set a password and do not use
  `ALLOW_INSECURE_UI=true`. Never expose the Admin UI to the internet.

### Upstream TLS verification

- nginx fetches the origin with the scheme of the client request. HTTPS
  origins are verified: `proxy_ssl_verify on` with
  `proxy_ssl_trusted_certificate` (`services/ui/nginx/proxy-params.conf`).
- nginx resolves origins with public resolvers, not the local redirecting
  DNS, so the real origin certificate is checked.
- With verification off or a wrong CA bundle, an attacker on the network could
  impersonate a CDN and poison the cache.

## Secrets

### CI secrets

- Stored as GitHub Actions Secrets (values) or Variables (non-secret
  settings), never in workflow files, Dockerfiles or source. Examples: the
  GHCR publish token, `SCCACHE_REDIS_URL`, `SCCACHE_DIST_AUTH_TOKEN`.
- Each workflow job declares its own `permissions:` block.
- Rotation is manual in the repository settings.

### Runtime secrets

The local CA key, `PDNS_API_KEY`, `KEA_CTRL_TOKEN`, `DDNS_TSIG_KEY`,
`SNMP_COMMUNITY`, `UI_AUTH_PASSWORD` and `SECONDARY_REGISTRATION_TOKEN`.

- **Storage**: the install's `.env` (not in git) or the shared-secrets Docker
  volume; `ca.key` in `CA_DIR`, outside the checkout. Details per secret:
  `docs/threat-model.md`.
- **Access**: each service reads only the secrets it needs at start.
- **Generation**: a missing value or a `CHANGE_ME_*` placeholder is generated
  on first start. An existing value is never overwritten; `setup.sh update`
  and `setup.sh auto-update` do not rotate secrets.
- **Rotation**: the Admin UI rotates the secondary registration token and
  renews the TSIG key when a secondary is removed. Other secrets are rotated by
  setting a new value in `.env` and running `setup.sh update`. There is no
  time-based rotation.
- Secrets are never committed. GitHub secret scanning and push protection are
  enabled on the repository.

## Vulnerability management

### Dependencies (SCA)

- `ci.sh check cargo-audit` runs `cargo audit --deny warnings` on the workspace
  lockfile: in `ci.yml` when the lockfile changes, and daily in `nightly.yml`.
  Any advisory fails, regardless of severity.
- Trivy scans container images and their OS packages at build time.
- Every finding blocks. A Trivy finding can only be accepted with a justified
  entry in `.trivyignore.yaml`. There is no suppression file for
  `cargo audit`; a Rust advisory is fixed by upgrading, patching or replacing
  the dependency.
- License compliance of dependencies is reviewed manually; no tool checks it.
- The `cargo-audit` result feeds the `result` job of `ci.yml`, a required
  status check on `current_dev`. A finding blocks a pull request for
  non-administrators.

### Static analysis (SAST)

- CodeQL (`.github/workflows/codeql.yml`, workflow `CI 2.0 CodeQL`) runs on
  every pull request, on pushes to `current_dev` and `master`, and weekly
  (Monday 03:27 UTC). Languages: `actions` and `rust` (SOT
  `codeql_languages`). Results are GitHub code scanning alerts.
- Every alert of severity Error or Warning on project code is fixed or
  dismissed with a reason before the code ships in a stable release.
- CodeQL is not part of the `result` job, so an alert does not block a merge.
  The Security tab is reviewed before each release.

## Operating recommendations

1. Run the host on a trusted, isolated LAN.
2. Restrict the Admin UI to trusted users and network segments.
3. Limit DNS, cache and Admin UI ports to trusted IPs with firewall rules.
4. Review the logs regularly.
5. Keep lancache-ng and the host up to date.
