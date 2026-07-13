# Changelog

All notable changes to lancache-ng are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Pending stable release (live on dev)

Covers all work merged into `v0.2.0` since the `v0.1.0` tag (2026-07-06). Not yet
a stable, tagged release, but already published and pullable via the `dev`
channel (see `docs/release-versioning.md`) -- "Unreleased" undersold that this
is real, live, running code, not just work sitting in source control.

### Added

- Added the repeat-run/idempotence test that was still missing for NATS's
  static `nats.conf` writer (#640, follow-up to the #456 convergence audit):
  Kea (`services/ui/src/routes/dhcp.rs`), PowerDNS's static config
  (`tests/bats/dns_config_snapshot_idempotence.bats`), and the watchdog
  (`tests/bats/watchdog_idempotence.bats`) already had this coverage from
  their own #614/#615 implementation PRs and the #456 audit itself; NATS's
  `update_nats_conf()` (per #583's per-secondary-identity decision) did not,
  so its config-rendering logic was pulled out into a pure `render_nats_conf`
  function and a test now drives the render → atomic-write pipeline twice in
  a row, proving it converges to byte-identical output for an unchanged
  config. Also added `scripts/check-idempotence-test-coverage.sh`, a small CI
  guard (with its own `tests/bats/check_idempotence_test_coverage.bats`
  fixture coverage) that fails the build if any known config-writer
  entrypoint loses its repeat-run test.
  - Hardened during PR review (#732): the guard now also covers the nginx
    proxy and `dhcp-proxy` known-good-snapshot adapters (previously only
    documented in the script's own header, not actually enforced), rejects
    commented-out `@test`/`#[test]` evidence and `#[ignore]`d Rust tests
    (none of which `cargo test`/`bats` actually run, so none should count as
    proof), and requires the NATS writer's evidence to match a
    writer-specific `nats_conf` marker (its self-referential evidence file
    already had an unrelated pre-existing test whose name happened to
    contain "repeat", which alone satisfied the old, broader check). The
    script's Bats fixture suite gained matching regression coverage for each
    case, and `.github/workflows/build-tools.yml`'s path filter now also
    triggers on changes to the guard script itself, so its own fixture suite
    runs on script-only PRs instead of only the real-repo happy-path check
    in `build-push.yml`.
- Extended `scripts/dhcp-kea-lease-flow-simulation.sh` with a static host
  reservation scenario (#707): after its existing Discover/Offer/Request/Ack
  check, it now adds a real reservation for a known MAC directly through
  Kea's own Control Agent API and confirms a subsequent real DHCP lease
  request for that MAC receives the reserved address, plus a companion
  negative case confirming a different, unrelated MAC still receives an
  ordinary dynamic-pool address rather than the reservation.
- Added a known-good configuration snapshot mechanism for the nginx proxy and
  dnsmasq `dhcp-proxy` adapters: generated config is validated (`nginx -t`,
  `dnsmasq --test`) before being snapshotted to a persistent, service-owned
  volume, retaining the last `KEEP_KNOWN_GOOD_CONFIGS` (default 3) validated
  configs, and a candidate that fails validation at startup automatically
  rolls back to the newest snapshot that re-validates instead of crash-looping
  or running with an invalid config; see `docs/known-good-config-snapshots.md`
  (#415).
- Extended the known-good configuration snapshot mechanism to Kea DHCP
  (#614, follow-up to #415): every DHCP config mutation from the Admin UI
  that already passes Kea's own `config-test` → `config-set` → `config-write`
  chain (PR #380) now also snapshots the applied config into the persistent
  `kea-data` volume, retaining `KEEP_KNOWN_GOOD_CONFIGS` (default 3, same
  variable as the other adapters). The `/dhcp` page lists snapshots and lets
  an operator roll back to one explicitly; the selected snapshot is
  re-validated with `config-test` before being applied. Unlike the nginx/
  dnsmasq/PowerDNS adapters, this is a Rust reimplementation of the shared
  contract (`services/ui/src/kea_snapshots.rs`), not an embedded shell
  library copy, since Kea's config is mutated live through the Admin UI's
  HTTP API rather than regenerated from a template at container startup.
- Extended the known-good configuration snapshot mechanism to PowerDNS's
  static `pdns.conf`/`recursor.conf`, rendered by `services/dns/entrypoint.sh`:
  both files are validated with their real, side-effect-free `--config=check`
  flag before being snapshotted (`pdns_recursor --config=check` and
  `pdns_server --config=check` respectively — confirmed live against the real
  packaged binaries that `pdns_server` supports this too, even though its
  `--help` output doesn't document it the way `pdns_recursor`'s does). Both
  configs are validated and rolled back independently per
  `dns-standard`/`dns-ssl` container, and the same mechanism now also covers
  the remote secondary DNS node (`setup.sh secondary`), including a
  `KEEP_KNOWN_GOOD_CONFIGS` retention knob wired through the generated
  secondary compose/`.env` the same way as the primary. A failed
  `recursor.conf` rollback now warns explicitly when the restored snapshot's
  `PDNS_API_KEY` no longer matches the live environment, since that leaves the
  recursor's REST API authenticating with a stale key while pdns.conf, the
  Admin UI, and `nats-subscriber` keep using the current one. Zone/record/
  database rollback (`pdns.sqlite3`) remains explicitly out of scope, per
  #415's own guidance — it *is* still covered by the regular
  `setup.sh backup`/`restore` flow, which is unrelated to this snapshot
  mechanism; see `docs/known-good-config-snapshots.md` (#615).
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
- Implemented per-secondary NATS identity via NATS auth callout (#583, per
  #433's "finish the originally-intended design" decision): every registered
  secondary now gets its own unique, individually-revocable NATS credential
  instead of the shared DNS-reader role all secondaries used to present. A
  small responder inside the Admin UI (`services/ui/src/nats_auth_callout.rs`)
  answers NATS's `$SYS.REQ.USER.AUTH` callout by checking the presented
  credential's hash against that one row in the `secondaries` table, live, on
  every connection attempt, and signs a per-connection user JWT scoped to the
  same DNS-sync permissions the old shared role had. `rotate_token` now
  actually regenerates that one secondary's own credential; removing a
  secondary revokes only that secondary, immediately, with zero effect on any
  other. Added `scripts/nats-secondary-auth-callout-simulation.sh`, a real
  multi-service integration test proving registration, isolation between two
  independently registered secondaries, immediate revocation on removal, and
  credential rotation all work against a real nats-server and the real
  `nats-subscriber` client.
- Added GitHub-hosted CI fallback jobs for `pr-template-check` and
  `watchdog_test`, completing hosted-fallback coverage for the full
  cheap-lint job class (`file-headers`, `line-endings`, `shellcheck`,
  `pr-template-check`, `watchdog_test`). Added
  `docs/ci-github-hosted-fallback-decision.md`, a standalone decision
  document on whether/how the harder Rust build/test and image build/push
  job classes could get a GitHub-hosted fallback path, with follow-up issues
  filed for both (#491).
- Added a storage-budget retention engine for the central syslog-ng log
  store (#633, follow-up to #453): `watchdog.sh`'s new `maybe_prune_syslog()`
  is modeled directly on the existing cache-purge function (rate-limited via
  its own stamp file, untrusted numeric input clamped to a safe default,
  every deletion explicitly logged). Opt-in via `SYSLOG_ENABLED=true`;
  age-based deletion (`SYSLOG_RETENTION_DAYS`, default 30) runs first, then
  — only if the tree under `SYSLOG_LOG_ROOT` is still over `SYSLOG_MAX_GB`
  (default 10) — the oldest remaining files are deleted next regardless of
  age, until back under budget. Wired into all 3 compose files
  (`dev`/`prod`/`quickstart`) as a read-write mount of the existing
  `logs-syslog-ng` volume into the `watchdog` service; documented as
  commented samples in `deploy/prod/.env`, matching the existing
  `SYSLOG_MAX_FILE_MB` precedent.

### Changed

- Renamed the `NATS_DNS_READER_USER`/`NATS_DNS_READER_PASSWORD` NATS role to
  `NATS_DNS_REPLICA_USER`/`NATS_DNS_REPLICA_PASSWORD` (#583): this static
  credential is now understood to be specifically for the primary's own
  co-located `dns-ssl` container (there is always exactly one, so a static
  credential is fine), not for registered secondaries, which authenticate via
  NATS auth callout instead. **Upgrade note**: any secondary registered before
  this change has a `NULL` per-secondary credential after the automatic,
  additive database migration and cannot authenticate until it is
  re-registered (`setup.sh secondary ...`) or its credential is rotated from
  the Admin UI's Secondaries page.

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

- Fixed the PowerDNS authoritative server's `webserver-allow-from` in
  `services/dns/pdns.conf.template` only permitting `127.0.0.1` and
  `172.16.0.0/12` — Docker's default address-pool range. Operators who
  customize `/etc/docker/daemon.json`'s `default-address-pools` to use
  `10.0.0.0/8` or `192.168.0.0/16` bridge networks had the UI container's
  calls to this API (port 8081) rejected. Widened to the full RFC1918 range,
  matching the pattern already used by `recursor.conf.template`'s own REST
  API `allow_from` (port 8082). Standard installs (Docker's default
  `172.17.0.0/16`–`172.31.0.0/16` pools) were never affected (#654).
- Fixed `build-tools.yml`'s branch-triggered publish path writing an
  unconditional, bare branch-name-derived mutable tag to the `build-tools`
  GHCR package. Because the integration branch is literally named `v0.2.0`,
  a qualifying push there republished `build-tools:v0.2.0` — the exact same
  tag string `build-push.yml`'s `promote` job writes as the real, immutable
  `vX.Y.Z` stable-release tag for the same package once that version is
  actually tagged, silently overwriting it on the next
  `tools/build-tools/**`-touching commit. Branch-derived tags are now always
  suffixed `-tc` ("test candidate", e.g. `v0.2.0-tc`), which can never
  collide with a release-channel tag by construction, and a new CI guard in
  `build-push.yml`'s compose-validation job asserts this derivation can
  never emit a `vX.Y.Z`-shaped tag, so this can't silently regress (#704).
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
- Fixed `scripts/nats-secondary-auth-callout-simulation.sh` being committed
  without the executable bit, which made `full-setup-validate.yml`'s "NATS
  auth-callout simulation" job fail every run with exit code 126 (`Permission
  denied`) — a recurrence of the same defect class already fixed once in
  #617 for a different script. `scripts/dhcp-kea-lease-flow-simulation.sh`
  had the identical missing-bit defect, only masked because its own workflow
  step already invoked it via an explicit `bash` prefix; fixed its
  executable bit too, and normalized every `scripts/*.sh` invocation in
  `full-setup-validate.yml` to use an explicit `bash scripts/...sh` prefix so
  the executable bit can no longer cause a job failure for any of them
  (#711).
- Fixed `scripts/dhcp-kea-lease-flow-simulation.sh` failing its own
  success-check (`dhclient never obtained a lease from the Kea container`)
  despite a genuinely successful DHCP exchange (`DHCPACK`/`bound to` in the
  raw `dhclient` log). Root cause: ISC dhclient drops privileges to an
  unprivileged system account right after binding the raw DHCP socket, so it
  could no longer create its own `-pf`/`-lf` files in the bind-mounted test
  directory — the lease was negotiated correctly but never persisted to
  disk for the harness to read back. Made that per-run temp directory
  world-writable so dhclient's post-privilege-drop identity can write the
  lease file the harness's option-verification depends on (#712).
- Fixed Kea's Control Agent rejecting `lease4-del` with result code 2
  (`CONTROL_RESULT_COMMAND_UNSUPPORTED`) because `services/dhcp/kea-dhcp4.conf`
  never loaded the `lease_cmds` hook library that command requires. This
  broke the Admin UI's "release lease" button (`release_lease()` in
  `services/ui/src/routes/dhcp.rs`, `POST /dhcp/lease/release`) in
  production on every real Kea instance, not just the new mutation test that
  surfaced it — every release attempt returned an error instead of freeing
  the lease. Fixed by adding a `hooks-libraries` entry for
  `libdhcp_lease_cmds.so` (shipped by `kea-common`, already a hard
  dependency of `kea-dhcp4-server` in `services/dhcp/Dockerfile`, so no new
  package is needed) (#694, Codex review finding). The hook's install path
  is architecture-specific (Debian's multiarch lib directory differs
  between amd64 and arm64), so `services/dhcp/entrypoint.sh` resolves it
  dynamically at startup (`find /usr/lib -maxdepth 5 -name
  libdhcp_lease_cmds.so`) instead of hardcoding either path, and
  `migrate_dhcp4_config` now also adds this `hooks-libraries` entry to an
  already-deployed installation's runtime `kea-dhcp4.conf` on upgrade, so
  existing Kea data volumes gain `lease_cmds` on the next container start
  without an operator having to reset the volume.
  **Note:** an earlier version of this fix documented the rationale above
  with a `//` WHY-comment directly inside `services/dhcp/kea-dhcp4.conf`.
  Kea's own config parser tolerates `//` line comments, but
  `migrate_dhcp4_config` and `tests/bats/dhcp_kea_config_generation.bats`
  both parse that same file with `jq`, which does not support any comment
  syntax and aborted on it (`jq: parse error: Invalid numeric literal`,
  caught by a live `full-setup-validate` run before this change merged).
  `kea-dhcp4.conf` must stay comment-free, unlike Kea's own runtime files,
  for exactly this reason — do not re-add a `//` comment to it; put such
  rationale in this CHANGELOG or the commit message instead.

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