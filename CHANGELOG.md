# Changelog

All notable changes to lancache-ng are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

Covers all work merged into `v0.2.0` since the `v0.1.0` tag (2026-07-06).

### Added

- Added a known-good configuration snapshot mechanism for the nginx proxy and
  dnsmasq `dhcp-proxy` adapters: generated config is validated (`nginx -t`,
  `dnsmasq --test`) before being snapshotted to a persistent, service-owned
  volume, retaining the last `KEEP_KNOWN_GOOD_CONFIGS` (default 3) validated
  configs, and a candidate that fails validation at startup automatically
  rolls back to the newest snapshot that re-validates instead of crash-looping
  or running with an invalid config. Kea and PowerDNS adapters are deferred to
  follow-up issues; see `docs/known-good-config-snapshots.md` (#415).
- Completed the `dnsmasq-proxy` DHCP mode: documentation guide, DHCP
  mode-selection tests, the Kea/dnsmasq mutual-exclusion invariant test,
  dnsmasq template rendering coverage, and Compose validation for both DHCP
  modes (#518).
- Implemented the `dev` release channel end-to-end: pushes to the active
  `vX.Y.Z`-pattern integration branch now publish `dev`-tagged images for
  every first-party service, mirroring how `master` publishes `edge`. A
  manual `channel` workflow input can additionally promote `dev` or `edge`
  from any ref on demand. `dev` never creates a GitHub release and never
  moves `latest` (#507).
- Added a full-setup validation image for offline, deterministic Compose
  testing of the entire stack composition without external network
  dependencies (#498).
- Added Rust code coverage reporting and gating in CI (`cargo-tarpaulin`
  against `services/ui` and `services/dns/nats-subscriber`), uploading JSON
  reports as artifacts and failing the job on regression (#495).
- Added a CI image-pinning policy (`docs/ci-image-pinning-policy.md`) and
  `scripts/check-mutable-refs.sh` to detect mutable image references,
  including untagged `FROM` lines (#497).
- Added a PR-template completeness check: non-draft PRs now fail CI if a
  required template section is missing; draft PRs warn without blocking
  (#501).
- Added a GitHub-hosted fallback for the file-headers CI check so that lint
  feedback isn't blocked when self-hosted runners are unavailable (#499).
- Published a live build-status badge on the README and documented the
  coverage-measurement process (#500).
- Established the build-tools container as the only valid local verification
  path in `AGENTS.md`/`CONTRIBUTING.md`: host-local Rust/lint tools must be
  assumed missing, misconfigured, or stale unless a task explicitly targets
  host provisioning (#512).
- Documented Compose's per-file `.env`-resolution behavior and the Admin
  UI's intentional fail-closed auth gate, based on a real live verification
  session (#520).
- Added `AGENTS.md` rules requiring issue-detail depth and explicit
  successor-coverage statements for follow-up issues (#522).
- Added bats-core and ShellSpec test fixtures exercising `setup.sh`'s real
  `.env`-migration and host-simulation helper functions, reusing the
  production functions instead of duplicating their logic in test-only code
  (#460, #461).
- Added test suite coverage for the image-channel-selection config loader and
  for `setup.sh`'s configuration-preserving migration semantics, both wired
  in as real, non-advisory CI gates (#494).
- Added unit tests for `nats-subscriber`'s real subscribe/forward logic
  (#515, closes #504), a comprehensive bats suite for proxy certificate
  generation (#524, closes #401), bats-core tests for DNS zone/RPZ generation
  (#525), and Kea/DHCP config generation tests (#526, issue #404).
- Created `CHANGELOG.md` with `v0.1.0` release notes (#513).

### Changed

- CI: `build-push`, `codeql`, and `build-tools` workflows now also trigger on
  PRs/pushes targeting `v0.2.0`, not just `master` (#503).
- The CodeQL Rust job now reports CodeQL's own extraction-quality
  determination in its job summary, so a green Rust status is not misread as
  full security-scan coverage; documents the underlying upstream CodeQL
  Rust-extractor limitation (#517).
- Documented the existing warnings-as-errors CI policy explicitly in
  `CONTRIBUTING.md` (which checks are hard PR-blocking failures, and the one
  scoped CodeQL exception tracked in #394) — no CI behavior changed (#496).
- Clarified, for every remaining `build-tools:latest` reference, whether it
  is an intentional fallback or tracked for pinning in #508 — no functional
  build/CI change (#523).
- Documented that subagent findings must be revalidated against the current
  GitHub head before use, and that local Rust builder checks only prove
  compile-farm behavior when the same BuildKit cache secrets are wired.
- Documented that readiness/mergeability statements require a fresh fetch,
  rebase onto the current remote base, and a verified head before any
  conclusion.
- Documented the GraphQL Markdown upload guard so PR/issue bodies cannot be
  accidentally written as JSON-escaped strings.
- Switched the Rust builder stages for `services/dns` and `services/ui` to
  the shared `ghcr.io/wiki-mod/lancache-ng/build-tools` image contract,
  threading the selected build-tools image through the build workflow and
  keeping downstream Docker build jobs on a pullable GHCR image instead of
  exporting runner-local validation tags across jobs, while keeping BuildKit
  secret wiring for `sccache` Redis, `sccache-dist`, and `distcc` host lists
  intact.

### Fixed

- Fixed `promote`/`release` CI jobs being silently skipped on every push due
  to an implicit `success()` evaluation bug — this was the reason `dev` and
  `edge` channel images were never actually published (#533).
- Fixed `validate full-setup image` racing ahead of `promote` on push events,
  which made it try to pull that push's own not-yet-published channel image
  (#534).
- Fixed a quickstart-install bug where `lancache-dhcp-probe` failed to start
  on every fresh install because `setup.sh` never copied `dhcp-probe.sh` into
  the install directory, and hardened the same install step to recover
  cleanly if a previous install already hit this bug (#538, #539).
- CI: the build job's existing push retry now re-authenticates to GHCR and
  waits before retrying, instead of instantly reusing the same session that
  just failed, to self-heal intermittent ghcr.io push-auth failures without
  needing a manual rerun (#540, #541).
- Fixed `detect-changes`' path-scoping to diff against the real merge-base
  instead of the base branch's moving tip, so PR branches lagging behind
  `v0.2.0` no longer get unrelated files misattributed as their own changes
  (#537).
- Fixed `ui`'s full-setup validation healthcheck by installing `curl` in its
  runtime image, and dropped an unauthorized Go toolchain from `build-tools`
  in favor of a checksummed prebuilt `actionlint` binary with a verified
  reason on record (#535).
- Fixed `full-setup-validate` resolving the wrong image channel (`latest`)
  for pre-release integration branches; it now resolves `edge`/`dev`/`latest`
  the same way the `promote` job does (#516).
- **Users/operators:** when `setup.sh install` encounters a missing `latest`
  channel, it now explains that the project is pre-1.0, offers concrete
  alternatives (the `edge` channel or a pinned version), and links the
  release-versioning documentation instead of showing a misleading error
  (#527).
- Fixed `ui` and `dns` image builds failing outright when `sccache` couldn't
  reach its Redis server; they now fall back to a local compile the same way
  `distcc` failures were already handled (#521).
- Fixed follow-up DHCP and quickstart installer findings from #476:
  quickstart installs now include the socket-proxy entrypoint, DHCP mode is
  persisted only after Docker reconciliation succeeds, and routed DNS option
  values may live outside the served subnet.
- `dhcp-proxy`'s dnsmasq proxy mode now completely disables DNS functionality
  (adds `no-resolv`/`no-poll`) to prevent port 53 binding conflicts in
  proxy-only deployments (#485).
- Fixed an outdated two-proxy architecture description in the docs (#511).
- Fixed a shellcheck `SC2064` warning in a test cleanup trap, no functional
  change (#514).

## [0.1.0] - 2026-07-06

### Added

#### Core Features
- **DNS caching with PowerDNS**: Authoritative DNS server for redirecting known CDN domains to local cache IP, with recursor fallback for unknown domains
- **Two-mode proxy architecture**:
  - Standard mode: HTTP caching + HTTPS SNI passthrough (no client certificate required)
  - SSL mode: HTTP + HTTPS caching with local CA certificate and TLS interception
- **Admin UI**: Rust/Axum web interface for cache management, DNS record editing, status monitoring
- **DHCP service**: Kea DHCP server with optional DHCP mode and DDNS support
- **Secondary DNS support**: Multi-node DNS configurations via NATS JetStream for distributed setups
- **Setup automation**: Interactive `setup.sh` installer with curl|bash support, auto-Docker installation, configuration validation
- **Watchtower helper**: Optional automatic Docker image update service

#### Admin UI Features
- Cache status dashboard with hit/miss/purge statistics
- DNS record management (add/edit/remove LAN records)
- DHCP lease viewer and DHCP configuration UI
- Logs page with nginx access log viewer and cache filter
- Optional Basic Auth protection for Admin UI
- Per-session CSRF tokens for security
- IPv6 support in IP validation and configuration

#### DNS Service Features
- RPZ (Response Policy Zone) support via PowerDNS
- Health checks and automatic service recovery
- PDNS Lua script for optional AAAA record filtering
- Standalone recursor with caching and security options
- DNS query logging (dev mode) with Fluent Bit log aggregation

#### DHCP Service Features
- Multi-subnet DHCP configuration
- DHCP-to-DNS integration via DDNS
- dnsmasq proxy mode for DHCP-only deployments
- Kea REST API integration for remote management

#### Setup & Deployment
- Two-IP architecture support (standard + SSL mode on separate IPs)
- Dev vs production configuration split
- Docker Compose orchestration (quickstart, dev, prod profiles)
- Backup and restore functionality
- Setup reconfiguration (`--reconfigure` flag) for IP changes
- Automated update flow with compose file refresh

#### Build & CI Infrastructure
- GitHub Actions CI with Docker image publishing
- Distcc distributed C/C++ compilation for faster builds
- Redis-backed sccache for Rust build caching
- Prebuilt service images published to GHCR
- Build-tools image for consistent Rust/C dependencies
- Cargo.lock for reproducible Rust builds
- Trivy security scanning of container images
- amd64 platform validation and gating

#### Documentation & Governance
- CLAUDE.md project documentation with architecture overview
- AGENTS.md governance guidelines for code contributors
- CONTRIBUTING.md with pull request and changelog expectations
- docs/release-versioning.md release channel contract
- File-purpose headers enforced via CI
- Comment style conventions documented
- Shell script linting via shellcheck

#### Security Hardening
- Docker socket API proxy with narrowed EXEC capability restrictions
- TLS interception via custom CA certificate (SSL mode)
- NATS message authentication with tokens
- Kea control socket secured via generated tokens
- Shell-side domain validation before use
- Config rollback logic when updates fail
- CSRF token generation and validation in Admin UI
- XSS prevention in template rendering
- Path traversal protections in request handling

### Fixed

#### Critical Bug Fixes
- DHCP startup failures and configuration syntax errors
- NATS token not written to config on secondary nodes
- DNS healthcheck failures and socket creation issues
- PowerDNS recursor 5.x compatibility (setting migrations, socket handling)
- Dashboard division-by-zero errors with zero cached files
- DHCP overflow handling in UI lease calculations
- IP validation edge cases

#### Stability Improvements
- Improved DNS entrypoint robustness and error recovery
- NATS acknowledgment behavior on parse failures with retry delay
- Healthcheck port verification and reliability
- Certificate serial persistence across restarts
- Root server IP configuration correctness
- Setup.sh octal literal crash and word-splitting fixes
- Quickstart compose file validation and completeness
- nginx SNI passthrough with empty host handling
- nginx_status ACL subnet correctness

#### Configuration Fixes
- OpenSSL serial file written to /tmp (avoiding permission errors)
- Cache key now uses `$host$uri` instead of `$request_uri` (query-string agnostic caching)
- nginx configuration structure (proxy-params placement, large file settings)
- Duplicate NATS configuration keys resolved
- Duplicate volumes in compose files fixed
- PDNS API key and authoritative API exposure in quickstart

### Changed

- DNS backend migration from BIND9 to PowerDNS (improved RPZ support, recursor flexibility)
- Base OS image upgraded from Debian 12 (Bookworm) to Debian 13 (Trixie)
- Admin UI framework updated to Axum 0.8 with Rust async ecosystem
- GitHub Actions workflows upgraded to Node 24 compatible versions
- nginx now handles both standard and SSL modes in single container (removed separate proxy-ssl service)
- Cache location normalized to single `/srv/lancache/cache` directory (from multi-mount)
- Watchtower helper switched from the original `containrrr/watchtower` (EOL since 2025, incompatible with Docker 29) to the maintained `nicholas-fedor/watchtower` fork

### Deprecated

- BIND9 DNS server (replaced by PowerDNS)

### Security

- Reduced Docker socket API surface (removed EXEC capability to DHCP probe container)
- NATS authentication tokens enforced on configuration updates
- CSPRNG token generation for all security-sensitive tokens
- Template error messages sanitized in production mode (no sensitive paths exposed)
- Weak default passwords hardened (KEA_CTRL_TOKEN, PDNS_API_KEY)
- Prevent stored XSS in LAN record handling and AAAA filter toggle

### Technical Details

- **Architecture**: DNS-spoofed CDN requests → nginx cache (via `proxy_cache_lock` for concurrency) → upstream real CDN
- **Cache bypass**: Console manufacturers (PS5, Xbox) excluded from DNS list to prevent failed handshakes and enable fallback
- **Build acceleration**: Distcc for C/C++ in sccache fallback path; Redis sccache for Rust compilation
- **Monitoring**: Optional Fluent Bit aggregation for centralized logging, Netdata proxy option
- **Platform**: linux/amd64 (only tested/supported prebuilt platform in 0.1.0)