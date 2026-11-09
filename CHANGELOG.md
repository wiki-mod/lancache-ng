# Changelog

All notable changes to lancache-ng are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-11-09

### Changes

- #1979 | fix(ui): follow-up to the admin UI mockup (NTP block, recent requests, shared drain)

### 🚀 Added

- #2004 | Promotion 0.3.4 to 0.4.0
- #2008 | feat(release): release-drafter layout and one-click publish in CI 2.0

### 📚 Documentation

- #2004 | Promotion 0.3.4 to 0.4.0
- #2008 | feat(release): release-drafter layout and one-click publish in CI 2.0
- #2007 | docs(release): drop the /logs notice and the 11.2 narrative
- #2006 | fix(ci): promotion PR toolchain and changelog label rule
- #1997 | ci(1683): CI 2.0 rewrite, continuation after #1984
- #1984 | CI 2.0 rewrite (continues #1858)
- #1988 | docs: re-audit the threat model and the capability inventory against current\_dev
- #1985 | fix(ui): SOT paths, programs menu, install channel, upstream checks
- #1989 | docs(docs): merge release and operator documents
- #1983 | Sync to current\_dev: CI 2.0 (#1858) and rewrite (#1980)
- #1976 | feat(ui): take over the admin UI mockup design

### 🧰 Chore / CI

- #2004 | Promotion 0.3.4 to 0.4.0
- #2008 | feat(release): release-drafter layout and one-click publish in CI 2.0
- #2006 | fix(ci): promotion PR toolchain and changelog label rule
- #2002 | fix: six release-check findings for 0.4.x
- #2001 | fix(ci): channel-check loads the Public Suffix List too
- #1997 | ci(1683): CI 2.0 rewrite, continuation after #1984
- #1991 | fix(ui): DHCP modes, one text per field, cache size, per-game evict and full wipe
- #1995 | fix(ci): restore gha-runtime-args for the master workflows
- #1984 | CI 2.0 rewrite (continues #1858)
- #1985 | fix(ui): SOT paths, programs menu, install channel, upstream checks
- #1989 | docs(docs): merge release and operator documents
- #1983 | Sync to current\_dev: CI 2.0 (#1858) and rewrite (#1980)
- #1981 | build-tools: add apk rust-src and rustup
- #1976 | feat(ui): take over the admin UI mockup design

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
