# Changelog

All notable changes to lancache-ng are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.2] - 2026-10-23

### Added

- DNS: upstream resolver for names outside the LAN zones (`DNS_UPSTREAM_SERVERS`, `DNS_UPSTREAM_ZONES`, `DNS_UPSTREAM_UNSIGNED_ZONES`). (#1918, #1920)
- setup.sh: external DNS server prompt during install and `configure-upstream-dns` command. (#1920)

### Fixed

- DNS: `NGINX_UPSTREAM_DNS` and `UPSTREAM_DNS` had no effect; upstream forwarding is configured through the variables above. (#1918, #1920)
- CI: automated patch release tag failed on GitHub-hosted runners. (#1928)
- CI: release tag runs used the `nightly` build-tools image. (#1929)

### Changed

- CI: GitHub-hosted runners by default; self-hosted only with `PROJECT_SELFHOSTED_RUNNER_USAGE_CI=true`. (#1927)
- CI: Full-Setup Deep Validate runs on manual dispatch only. (#1929)
- CI: container-scan no longer rebuilds changed images. (#1929)
- CI: full-setup simulations run in parallel. (#1929)
- CI: CodeQL Rust analysis runs only on Rust changes. (#1929)

### Notes

- Tag `v0.3.1` exists without a GitHub release.

## [0.3.0] - 2026-08-03

- No changelog entry was recorded for this release. See the GitHub release notes for v0.3.0.

## [0.2.0] - 2026-07-18

### Added

- DNS: known-good snapshots and operator-selected rollback for PowerDNS zone/record data (`lan.`, `local.lan.`, private reverse zones); rollback listener on `DNS_ROLLBACK_LISTEN_ADDR` (default `0.0.0.0:8083`); Admin UI "Zone-Snapshots" tab on `/domains`. (#628)
- setup.sh: `create-logs-for-issue` collects compose logs/ps/config, a redacted `.env`, host facts and snapshot listings into one archive. (#762)
- setup.sh: `reset-to-last-known-good-config <service> [install-dir] [snapshot-id] [--yes]` for Kea. (#763)
- Known-good config snapshots with automatic rollback on failed validation: nginx proxy and dnsmasq `dhcp-proxy` (#415), Kea DHCP (#614), PowerDNS `pdns.conf`/`recursor.conf` including secondary nodes (#615). Retention via `KEEP_KNOWN_GOOD_CONFIGS` (default 3).
- NATS: per-secondary credentials via auth callout; rotation and revocation per secondary. (#583)
- Logging: all services forward to the syslog-ng/fluent-bit pipeline. (#633)
- Logging: syslog storage retention in watchdog (`SYSLOG_ENABLED`, `SYSLOG_RETENTION_DAYS` default 30, `SYSLOG_MAX_GB` default 10). (#633)
- Admin UI: `/logs` reads the central syslog store when `SYSLOG_ENABLED`; dashboard syslog storage tile. (#633)
- `dnsmasq-proxy` DHCP mode completed: documentation, mode-selection and exclusion tests, Compose validation. (#518)
- Release channel `dev` published from the integration branch. (#507)
- Full-setup validation image for offline Compose testing. (#498)
- CI: Rust coverage reporting with `cargo-tarpaulin`. (#495)
- CI: image-pinning policy and `scripts/check-mutable-refs.sh`. (#497)
- CI: PR template completeness check. (#501)
- CI: `scripts/check-action-node-versions.sh` rejects actions on deprecated Node runtimes; `download-artifact` pin updated. (#801, #802)
- CI: `scripts/check-idempotence-test-coverage.sh`; repeat-run test for the NATS config writer. (#640, #732)
- CI: `scripts/check-logging-matrix.sh`; fluent-bit healthcheck. (#633)
- CI: GitHub-hosted fallbacks for cheap lint jobs. (#491, #499)
- Tests: Admin UI reachability during a dependency crash loop; Kea static reservation scenario (#707); bats and ShellSpec suites for setup.sh migration, channel selection, nats-subscriber, proxy certificates, DNS zone/RPZ and Kea config generation. (#460, #461, #494, #515, #524, #525, #526)
- Documentation: build-tools container as the only local verification path (#512); Compose `.env` resolution and Admin UI auth gate (#520); live build-status badge (#500).
- Documentation: AGENTS.md rules for issue detail and successor coverage. (#522)
- `CHANGELOG.md` with v0.1.0 release notes. (#513)

### Changed

- NATS: `NATS_DNS_READER_USER`/`NATS_DNS_READER_PASSWORD` renamed to `NATS_DNS_REPLICA_USER`/`NATS_DNS_REPLICA_PASSWORD`. Secondaries registered before this change must be re-registered or have their credential rotated. (#583)
- DHCP: opt-in PXE boot pointer for `dnsmasq-proxy` mode (`DHCP_PROXY_PXE_BOOT_SERVER`, `DHCP_PROXY_PXE_BOOT_FILENAME_BIOS`, `DHCP_PROXY_PXE_BOOT_FILENAME_UEFI`). (#705)
- Secrets: `PDNS_API_KEY`, `KEA_CTRL_TOKEN`, `DDNS_TSIG_KEY` and the four `NATS_*_PASSWORD` values are generated once into a shared volume when empty; an empty `DDNS_TSIG_KEY` now enables TSIG by default. (#858)
- Build: Rust builder stages for `dns` and `ui` use the shared build-tools image.
- CI: workflows also run for the `v0.2.0` branch. (#503)
- CI: CodeQL Rust job reports extraction quality. (#517)
- CI: validation subnet pool uses `/27` slots within `172.30.0.0/16`. (#832)
- Review-gate cleanup stream closed. (#135)
- Documentation: warnings-as-errors policy (#496); `build-tools:latest` references (#523); agent revalidation and GraphQL upload rules.

### Fixed

- Secondary registration returned the internal NATS URL; now uses `NATS_ADVERTISE_URL` or `NATS_BIND_IP` and refuses with HTTP 503 when neither is routable. (#866)
- DNS rollback cache flush was denied by NATS permissions. (#867)
- Admin UI reported success when a CDN domain file write failed. (#875)
- `SYSLOG_ENABLED` and `SYSLOG_MAX_GB` were parsed differently by the Admin UI and watchdog. (#874)
- `build-tools.yml` path filter skipped most bats-tested files. (#873)
- `setup.sh update` health gate passed when `dig` or `curl` was missing. (#868)
- DNS healthchecks differed between profiles and did not query DNS in four of five. (#869)
- Admin UI `/logs` ignored filters in syslog mode; host filter added with path-traversal protection. (#848)
- Validation network teardown race (`has active endpoints`). (#834, #835)
- watchdog: invalid `status.json` on wrapped `df` output, missing curl timeouts, empty health results, unvalidated `CHECK_INTERVAL`, `SSL_ENABLED` parsing; new watchdog healthcheck. (#872)
- Validation subnet collisions on shared runners. (#820)
- NATS auth callout was overwritten on every NATS restart on dev and prod. (#811)
- setup.sh ran a backtick in a `.env` comment as a command.
- `dns-zone-rollback-simulation.sh` reused stale local images. (#809)
- `upload-artifact` pinned to a Node 20 release. (#799)
- setup.sh CLI simulation tested the stale `edge` channel instead of the PR images.
- SSL MITM simulation could not tell the SSL and standard DNS answers apart. (#668)
- sccache-dist remote build failures did not trigger the local fallback. (#783)
- `promote` shared the pipeline concurrency group and could be skipped during merge bursts. (#777)
- Contradicting CodeQL carve-out rules AG-VAL-021 and AG-VAL-022. (#702)
- Proxy image was not rebuilt when only `services/dns/cdn-domains.txt` changed. (#771)
- Reverse DHCP-DDNS (PTR) updates always failed. (#768)
- Kea failed to start with the `logging` profile; logs now in `/var/log/kea`. (#773)
- `select-build-tools-image.sh` trusted a stale `:latest` image and smoke-tested too few tools. (#775)
- PowerDNS `webserver-allow-from` covered only `172.16.0.0/12`; now full RFC1918. (#654)
- Admin UI sent unresolved NTP hostnames to Kea. (#670)
- build-tools branch tags could overwrite `vX.Y.Z` release tags; now suffixed `-tc`. (#704)
- `promote`/`release` jobs were skipped on every push. (#533)
- `validate full-setup image` ran before `promote`. (#534)
- `lancache-dhcp-probe` failed on fresh quickstart installs. (#538, #539)
- GHCR push retry reused the failed session. (#540, #541)
- `detect-changes` diffed against the base tip instead of the merge base. (#537)
- `ui` full-setup healthcheck missing `curl`; Go toolchain removed from build-tools. (#535)
- `full-setup-validate` resolved the wrong image channel. (#516)
- `setup.sh install` gave a misleading error for a missing `latest` channel. (#527)
- `ui` and `dns` builds failed when sccache Redis was unreachable. (#521)
- DHCP and quickstart installer follow-ups. (#476)
- `dhcp-proxy` dnsmasq proxy mode bound port 53. (#485)
- Outdated two-proxy architecture description. (#511)
- shellcheck SC2064 in a test trap. (#514)
- Missing executable bit on two simulation scripts. (#711)
- Kea lease-flow simulation could not read its lease file. (#712)
- Admin UI "release lease" failed; `lease_cmds` hook loaded. (#694)
- CDN domain removal rewrote line endings of the whole file. (#656)
- arm64 rollout gaps in backfill, docs and setup.sh platform check. (#592, #665)
- build-tools image had no `docker buildx`. (#787)
- setup.sh CLI simulation collided across concurrent runs. (#669)
- Admin UI `/logs` dropped quiet hosts in syslog mode. (#859)
- `build-push.yml` serialized whole runs on rapid pushes. (#888)
- PR template: do not edit `CHANGELOG.md` in the same PR; `scripts/collect-changelog-entries.sh`. (#889)

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