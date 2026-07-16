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

- Added a known-good snapshot/rollback mechanism for PowerDNS zone/record
  data (#628, the zone/record design #615/#625 deliberately deferred --
  see `docs/known-good-config-snapshots.md`'s "Zones, records, and
  TSIG/DDNS metadata" section for the full design). `services/dns/
  nats-subscriber` gained its own Rust reimplementation of the snapshot
  retention primitives (`zone_snapshots.rs`, mirroring `services/ui/src/
  kea_snapshots.rs`'s pattern): after every NATS-applied record write
  (`handle_dns_record`'s post-`PATCH` hook) and on a new unconditional
  60-second periodic export-and-diff watcher (covering Kea's
  direct-to-PowerDNS DDNS writes, which bypass NATS entirely), the current
  data rrsets (SOA/NS excluded) for `lan.`, `local.lan.`, and the private
  reverse zones are exported and snapshotted under
  `${DNS_CONFIG_SNAPSHOT_DIR}/zones/<zone>`, skipping the write when
  content is unchanged from the most recent snapshot so periodic
  reconciler republishes don't burn through retention. A new local HTTP
  listener (`rollback_listener.rs`, `DNS_ROLLBACK_LISTEN_ADDR`, default
  `0.0.0.0:8083`, `X-API-Key`-authenticated with `PDNS_API_KEY`) lets the
  Admin UI list snapshots per zone and trigger an operator-selected
  rollback: diffs the snapshot against the live zone, issues the
  equivalent `REPLACE`/`DELETE` `PATCH`, re-runs `pdnsutil check-zone` as a
  post-apply sanity check, flushes every changed name from both
  recursors' packet caches (via `lancache.dns.flush`, reaching both
  `dns-standard` and `dns-ssl`), and -- for `lan.` only, since it is the
  one zone with existing NATS replication -- re-publishes the restored
  records so secondaries converge immediately rather than waiting on the
  next reconciler tick. `local.lan.`/the private reverse zones are not
  NATS-replicated today (a pre-existing gap, not something this PR
  extends), so `dns-secondary` nodes do not converge for those zones
  either after a rollback; this is documented rather than silently
  assumed. The Admin UI's new `/domains` "Zone-Snapshots" tab
  (`services/ui/src/routes/dns_snapshots.rs`, mirroring the existing Kea
  snapshot list/rollback UI) is scoped to `dns-standard` only for now,
  matching `PDNS_AUTH_URL`/`PDNS_REC_URL`'s existing single-primary
  convention. Rollback stays operator-selected, never automatic on
  startup, same as the Kea adapter. Known gap carried over unchanged from
  #730: this whole mechanism assumes the `dns-standard`/`dns-ssl`
  container is reachable, which is not guaranteed in the crash-loop
  scenario it exists to help recover from -- tracked separately as #763.
  Also added a real end-to-end CI test (`scripts/dns-zone-rollback-
  simulation.sh`, wired into `.github/workflows/full-setup-deep-
  validate.yml`'s `dns-zone-rollback-simulation` job) that drives two real
  DNS writes through the actual UI/NATS path, calls the rollback listener's
  real HTTP endpoints (auth, list, rollback) against a live `dns-standard`
  container, and confirms via real `dig` queries that both PowerDNS's data
  and the recursor's cache were actually rolled back -- proving the
  PATCH/DELETE round-trip and cache-flush behavior the crate's unit tests
  cannot exercise against a live PowerDNS instance.
- Added `setup.sh create-logs-for-issue` (#762): bundles `docker compose
  logs`/`ps`/`config` output, a secret-redacted copy of `.env`/`.env.local`,
  host facts (Docker/Compose versions, kernel, disk space), and
  known-good-snapshot directory listings (`docs/known-good-config-snapshots.md`)
  into one compressed, timestamped archive an operator can attach to a
  GitHub bug report, instead of manually running and pasting a series of
  commands. Every credential-shaped value this script generates/manages
  (`PDNS_API_KEY`, `DDNS_TSIG_KEY`, `KEA_CTRL_TOKEN`, the `NATS_*_PASSWORD`
  set, `SECONDARY_REGISTRATION_TOKEN`, `UI_AUTH_PASSWORD`) is redacted
  value-by-value across every collected artifact -- not just name-filtered
  out of `.env` -- so a secret interpolated into `docker compose config`'s
  resolved YAML or echoed by a service's own startup logs is scrubbed too,
  on top of a name-pattern safety net for any future credential-shaped
  variable. Compression prefers zstd, then bzip2, then gzip, extending the
  same "best available compressor, fall back gracefully" idiom already used
  for syslog-ng log rotation (`deploy/*/docker-compose.yml`) with the
  missing bzip2 middle tier. Automatic upload/attachment to GitHub is
  explicitly out of scope -- the operator reviews and attaches the archive
  themselves.
- Added `scripts/check-action-node-versions.sh`, a CI guard (issue #801,
  systemic follow-up to #799/#800) that scans every pinned GitHub Action
  across all `.github/workflows/*.yml` files -- both third-party actions and
  this repo's own local composite actions under `.github/actions/` -- and
  fails the build if any of them declares a deprecated Node runtime
  (`node6`/`node10`/`node12`/`node16`/`node20`) in its own action.yml/
  action.yaml. External actions are resolved at their pinned ref via the
  GitHub Contents API (curl + `GH_TOKEN`, matching this project's existing
  `check-pr-tracking-metadata.sh` convention rather than depending on the
  `gh` CLI, which is not installed in the build-tools image); local composite
  actions are read straight off disk. Wired into `build-push.yml`'s
  `shellcheck`/`shellcheck-hosted` jobs, with its own fixture-based
  `tests/bats/check_action_node_versions.bats` suite (fully offline, via a
  mock `curl`) that includes a permanent regression test against the real,
  historical pre-#800 `actions/upload-artifact@834a144...` pin content,
  proving this guard would have caught #799. Building this guard also found
  a second, not-yet-fixed instance of the same problem
  (`actions/download-artifact`, #802), fixed in the same PR since the new
  guard would otherwise fail on its own pre-existing pin. The
  `actions/upload-artifact` pin itself was intentionally left untouched at
  first -- that fix was #800's, still open when this PR was opened, so this
  guard's own CI run stayed red on that one pin until #800 merged; now that
  #800 has landed and this branch is rebased onto it, the pin is current
  (`v7.0.1`) and the guard passes cleanly. Also adds an optional local
  `.githooks/pre-push` hook that runs the same script before a push touching
  any workflow file, as an early warning only -- the
  `shellcheck`/`shellcheck-hosted` CI jobs remain the actual enforcement (see
  CONTRIBUTING.md).
- Added a real end-to-end test for the Admin UI reachability claim #763's
  crash-loop-recovery discussion depends on: `deploy/*/docker-compose.yml`'s
  `ui` service `depends_on` list has never had a `condition: service_healthy`
  gate, which was meant to guarantee the Admin UI starts independently of
  whether `proxy`/`nats`/`docker-socket-proxy` are healthy -- but that claim
  had only ever been read off the compose file, never actually exercised.
  `scripts/ui-reachability-crash-loop-simulation.sh` (new, wired into both
  `full-setup-deep-validate.yml` and `full-setup-validate.yml` as
  `ui-reachability-crash-loop-simulation`) deliberately forces `proxy` into a
  genuine, continuous crash loop and confirms the Admin UI still starts,
  becomes healthy, never restarts itself, and answers a real HTTP request on
  `/health` throughout.
- Added `setup.sh reset-to-last-known-good-config <service> [install-dir]
  [snapshot-id] [--yes]` (#763's CLI-fallback scope item): for when the Admin
  UI itself is unreachable but a service's own control surface still is.
  Automates docs/known-good-config-snapshots.md's existing Kea "Manual
  recovery" by-hand sequence (inspect the snapshot JSON under
  `kea-data/config-snapshots`, then `config-test` -> `config-set` ->
  `config-write` against the real Kea Control Agent) into one invocation --
  the same sequence `services/ui/src/routes/dhcp.rs`'s `rollback_kea_snapshot`
  already runs when the Admin UI IS reachable. Verified end-to-end by the new
  `scripts/setup-reset-kea-config-simulation.sh` (wired into both workflows as
  `setup-reset-kea-config-simulation`): adds two real reservations through the
  Admin UI (creating two known-good snapshots), rolls back to the first via
  the new CLI command, and confirms via a fresh `config-get` against the real
  Kea server that the second reservation is genuinely gone and the first is
  intact -- not just that the command claimed success. The `dns`/`pdns`
  service target is not yet implemented: it depends on #628/PR #788's
  PowerDNS zone/record rollback listener, which was still open at the time of
  this change; the command fails closed with a clear pointer instead of
  guessing at an API surface still subject to change.
  This PR does not add any new "reset to last-known-good config" UI page:
  that already exists today for Kea (`services/ui/src/routes/dhcp.rs`'s
  `rollback_kea_snapshot`, `/dhcp` page) and, once #628/PR #788 merges, for
  PowerDNS zone/record data (`/domains` page's "Zone-Snapshots" tab) --
  #763's own corrected scope treats building a new unified reset UI as out of
  scope precisely because that mechanism already exists per-service.
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
- Wired the remaining 9 services into the syslog-ng/fluent-bit central
  logging pipeline (#633, follow-up to #453/#632, which shipped only the
  proxy access log): proxy's `error.log`/`stream.log`, `dns-standard`/
  `dns-ssl`, `dhcp` (Kea), `dhcp-proxy` (dnsmasq), `ui`, `watchdog`, `nats`,
  and `netdata` all now forward to syslog-ng, each via whatever mechanism
  its own daemon actually supports: Kea's native dual `output-options`
  (stdout + file); a `tee` of the daemon's own stdout into a file for
  PowerDNS (no native file-log directive on Linux) and watchdog (its
  `log()` function is unchanged, the compose entrypoint tees it); a second
  `tracing-subscriber` layer for the Admin UI; and a single-destination
  trade-off (documented, `docker logs` goes quiet on that one container
  while the `logging` profile is active) for dnsmasq's `log-facility=` and
  nats-server's `log_file:`, since neither supports simultaneous
  stdout+file output despite what an earlier version of this plan assumed.
  `dhcp-probe` stays intentionally unwired (one-shot diagnostic, no
  persistent stream); `docs/architecture-ng.md`'s logging matrix records
  every service's real mechanism.
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
- Added `scripts/check-logging-matrix.sh` (#633, follow-up to #453/#632),
  wired into the `validate-compose` CI job right after the existing naming
  consistency check: compares `docs/architecture-ng.md`'s logging matrix
  table against the real Compose service list (via
  `docker compose config --services`, all profiles activated, across
  `dev`/`prod`/`quickstart`) and fails if a service has no matrix row, or a
  row names a service that no longer exists. Filled in the matrix's 2
  previously-missing rows (`docker-socket-proxy`, `watchtower` -- both
  third-party pinned images with no application log stream of their own to
  forward) so the guard starts green. Also added a `healthcheck` block to
  the `syslog` (fluent-bit) service in all 3 Compose files, plus its `-H -P
  2020` HTTP monitoring server flags: the pinned
  `cr.fluentbit.io/fluent/fluent-bit:3.2.10` image ships no shell and no
  `wget`/`curl`/`ss` at all, so `syslog-ng`'s `CMD-SHELL` healthcheck shape
  can't be mirrored exactly -- `fluent-bit -V` (exec form, binary-integrity
  check only) is the one self-contained probe that image supports.
- Added an Admin UI reader for the central syslog-ng log store (#633,
  follow-up to #453): `services/ui/src/syslog_client.rs` (sibling to
  `nginx_client.rs`) reads and transparently decompresses (`.zst`/`.gz`)
  files under `SYSLOG_LOG_ROOT`, mirroring `SYSLOG_ENABLED`/`SYSLOG_MAX_GB`/
  `SYSLOG_RETENTION_DAYS`/`SYSLOG_LOG_ROOT`'s existing watchdog contract. The
  `/logs` page now branches on `SYSLOG_ENABLED`: enabled installs see a tail
  of the central store (every wired service, not just the proxy); disabled
  installs keep the previous direct-nginx-access-log-read behavior
  unchanged. The dashboard gained a syslog storage tile (size/host/file/line
  counts) alongside the existing cache and connection stats, gated the same
  way.

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
- Recorded completion of the #135 review-gate cleanup stream so remaining
  work can continue as ordinary `v0.2.0` development instead of blocking the
  closed review umbrella.
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
- Added opt-in PXE boot-pointer support to `dnsmasq-proxy` DHCP mode (#705):
  `DHCP_PROXY_PXE_BOOT_SERVER` plus `DHCP_PROXY_PXE_BOOT_FILENAME_BIOS`/
  `DHCP_PROXY_PXE_BOOT_FILENAME_UEFI` let `services/dhcp-proxy` point real
  PXE clients (legacy BIOS and both x86-64/ARM64 UEFI, dnsmasq architecture
  codes 0/7/11) at an operator's own external, already-existing PXE/TFTP
  boot server — this project never hosts or serves boot files itself. Fixes
  a root-cause bug found while building this: dnsmasq's ProxyDHCP mode never
  replied to any DHCPDISCOVER at all, PXE-tagged or not, because no
  `pxe-service` directive was ever rendered; every #450 optional dnsmasq-proxy
  option was therefore silently inert since #450 shipped. The fix stays
  opt-in (both new variables must be set) since unlocking ProxyDHCP replies
  is itself a real behavior change for the LAN segment. See
  `docs/dhcp-modes.md`'s "PXE boot-pointer" section for the full option
  reference and the wire-level details (`dhcp-boot`/`dhcp-match`, not
  `pxe-service`, is what actually delivers the configured external server to
  UEFI and, for the external-address case, BIOS clients too), and
  `scripts/dhcp-proxy-pxe-simulation.sh` for the new end-to-end simulation
  (a synthetic PXE client, via `scapy`) that proves it against a real
  `dnsmasq` container for both architectures and confirms an ordinary,
  non-PXE-tagged client still receives no reply.
- CI: redesigned the `full-setup-validate`/`full-setup-deep-validate`/
  `build-push` validation-subnet reservation pool from one `/24` per octet
  of `172.30.0.0/16` (252 usable slots, of which the validation stack only
  ever actually used ~10 of each `/24`'s 256 addresses) to one `/27` per
  slot -- 30 usable hosts, comfortably more than the stack needs today with
  headroom for it to grow -- drawn from a pool of 8 `/27` blocks per octet
  within the SAME already-owned `172.30.0.0/16` (~2,000 slots, an ~8x
  increase), rather than widening the search into the wider private
  `172.16.0.0/12` block (#832). The small pool was the direct root cause of
  the birthday-paradox collision frequency issue #820/#821's flock+retry
  mechanism exists to route around; that retry mechanism is unchanged and
  still the safety net for a genuine collision, it should now just fire far
  less often. Deliberately did NOT widen into the full `172.16.0.0/12`
  range: that range is ALSO Docker's own default address-pool range for
  other, unrelated bridge networks on the same self-hosted runner host, and
  this project already hit a real bug from relying on that exact range once
  (PowerDNS's `webserver-allow-from` only covering it, above). A full
  inventory of every fixed-subnet reservation in the project (`172.28.0.0/16`
  dev compose, `172.31.0.0/16` DHCP Kea lease-flow simulation,
  `172.29.0.0/16` DHCP proxy PXE simulation -- all untouched, all in
  different, unrelated `/16`s) and every consumer that assumed the
  reservation's old `/24` shape was done as part of this change; besides the
  three workflows and `scripts/lib/reserve-validation-subnet.sh`/
  `.github/actions/derive-validation-network` themselves, this found and
  fixed two consumer scripts that computed their OWN additional addresses
  (beyond the ~10 the core services claim) directly from the reserved
  subnet's assumed `/24` shape --
  `scripts/dhcp-kea-ctrl-agent-mutation-simulation.sh` (a Kea test server,
  DHCP pool, and static reservation address) and
  `scripts/setup-reset-kea-config-simulation.sh` (the same, for its own
  separate Kea instance) -- both renumbered to fit within a `/27` and
  rewritten to parse the reserved subnet's actual base offset instead of
  assuming it is always `.0`. Also consolidated three call sites
  (`build-push.yml`, `full-setup-validate.yml`, and a separate,
  never-actually-shared inline copy of the Docker-network conflict check in
  `build-push.yml` that still had the exact bare-`startswith` footgun the
  shared `validation_subnet_conflicts` helper (#820) was supposed to have
  already fixed everywhere) onto the single shared
  `validation_subnet_export_env`/`validation_subnet_conflicts` functions
  instead of each keeping its own hand-written copy of the address-export
  formula, closing off the exact kind of silent divergence a partial `/24`
  to `/27` migration could otherwise have left behind. **Real regression
  caught by this PR's own CI run and fixed before merge**:
  `validation_subnet_reserve` (in `scripts/lib/reserve-validation-subnet.sh`)
  turned out to be a generic "reserve one free integer with host-local
  flock" primitive ALSO reused, on their own separate `172.31.0.0/16` /
  `172.29.0.0/16` ranges, by `scripts/dhcp-kea-lease-flow-simulation.sh` and
  `scripts/dhcp-proxy-pxe-simulation.sh` -- neither of which has (or wants)
  a `/27` subdivision. An earlier version of this change renamed that
  function's output from `octet=` to `slot=` for the general pool's benefit,
  which silently broke both DHCP scripts (still parsing the now-gone
  `octet=` key), producing the literal invalid subnet string
  `"172.31..0/24"`/`"172.29..0/24"` in real CI. Fixed by restoring
  `validation_subnet_reserve`/`validation_subnet_derive_octet` to their
  exact original, octet-only behavior (used by the two DHCP scripts,
  unchanged) and adding separate `validation_subnet_reserve_slot`/
  `validation_subnet_derive_slot` functions for the four general-pool call
  sites instead.

### Fixed

- Fixed `build-tools.yml`'s bats-triggering path filter silently excluding
  most of the project's actual bats-tested files (#873). The filter only
  ever matched `tests/bats/**`/`tests/shellspec/**` themselves, `setup.sh`,
  and `scripts/check-idempotence-test-coverage.sh` -- so a PR that changed
  only, say, `services/watchdog/watchdog.sh` never ran the
  `watchdog_idempotence.bats`/`watchdog_syslog_prune.bats` suite already
  written for it, since `build-tools.yml` is the only workflow that ever
  executes bats/shellspec. Traced every `tests/bats/*.bats` file's real
  (non-fixture) file dependency and confirmed the gap was not
  watchdog-specific: `services/dns/**`, `services/dhcp/**`,
  `services/dhcp-proxy/**`, `services/proxy/**`, `services/watchdog/**`,
  `services/ui/dhcp-probe.sh`, `deploy/{dev,prod,quickstart}/
  docker-compose.yml`, `scripts/lib/**`, and seven individual top-level
  `scripts/*.sh` files (`classify-image-impact.sh`,
  `compute-next-release-tag.sh`, `detect-full-setup-changes.sh`,
  `ensure-pr-staging-images.sh`, `plan-deep-validation.sh`,
  `docker-socket-proxy.sh`, `check-action-node-versions.sh`) all had real
  bats coverage the path filter never triggered on. Added all of these to
  both the `push` and `pull_request` path filters in `build-tools.yml`.
  Publish scope is unaffected -- `determine-publish-scope` still only
  rebuilds/publishes the build-tools image itself on `tools/build-tools/**`
  or workflow-file changes, so the added paths only cause the existing
  local build-and-bats-run to execute, never a new image publish. Refs
  #822 (the cross-cutting "point-fix without a guard" pattern audit this
  gap is an instance of); a durable CI guard that keeps the filter in sync
  with actual bats dependencies going forward is tracked separately as
  follow-up #879 rather than built into this fix.
- Fixed `setup.sh update`'s post-update functional health gate
  (`verify_stack_functional_health`) silently no-oping instead of failing
  when its required probe tool was missing (#868). `dig` was never part of
  setup.sh's own dependency bootstrap, so on the common default install
  (`curl | bash`, no `dig` on the host) the DNS half of the gate silently
  skipped itself and reported the update healthy regardless of whether DNS
  actually worked; the HTTP `/healthz` half had the identical
  `command -v curl` skip-shaped gap. Fixed the whole pattern, not just the
  observed `dig` symptom: every probe now routes through a new
  `require_functional_check_tool` helper that treats a missing tool as a
  FAILED check, not a skipped one, so a missing dependency can never look
  like "verified healthy". `perform_stack_update_flow` now also installs
  `curl` and `dig` up front via `install_missing_tools` (extended with a new
  `package_name_for_tool` mapping, since `dig` ships in the
  `bind9-dnsutils`/`dnsutils` package, not a package literally named `dig`)
  before anything else in the update is mutated, so the fail-closed branch
  above stays the rare exception on a real run rather than the normal case.
  See `tests/bats/setup_functional_health_gate.bats` for coverage proving
  both the missing-tool fail-closed path and that the probes still
  correctly fail on a real broken HTTP/DNS endpoint when the tool is
  present.
- Fixed DNS healthchecks being inconsistent across deploy profiles and, in
  4 of 5 cases, non-compliant with this repo's own AGENTS.md rules
  (AG-VAL-018/019/020) (#869). Only `deploy/quickstart/docker-compose.yml`
  used a real query/response probe (`dig @127.0.0.1 steamcontent.com A
  +short`). `dev` and `prod` used `rec_control ping && ss -lnu | grep -q
  ':53 '` -- `ss` is explicitly banned as a DNS healthcheck (AG-VAL-020,
  it only proves a socket is listening) and `rec_control ping` alone is
  liveness-only (AG-VAL-019). `full-setup` used `rec_control ping
  2>/dev/null || true`, where the trailing `|| true` forced exit 0
  regardless of the real result, so the healthcheck could never report
  unhealthy. `secondary` used bare `rec_control ping`, the same
  liveness-only gap as dev/prod. All four now use the identical
  `dig`-based probe `quickstart` already used correctly; `dnsutils` is
  already installed in every profile's `dns` image
  (`services/dns/Dockerfile`), so no new tooling was required.
- Fixed the Admin UI's `/logs` page silently ignoring any filter in syslog
  mode (#848): `logs_page()` called `syslog_client::parse_syslog_tail(&log_root,
  None, max_entries)` with a hardcoded `None` host argument regardless of
  what was requested, even though `parse_syslog_tail` already accepted and
  correctly handled a `host: Option<&str>` filter (existing test coverage in
  `syslog_client.rs` proved the underlying capability worked -- only the
  route never passed anything through). The nginx-log branch's existing
  `?filter=` query parameter filters by `cache_status` (HIT/MISS/EXPIRED),
  which has no meaning for syslog lines, so a new, separate `?host=` query
  parameter was added instead of overloading `filter` with mode-dependent
  semantics -- a bookmarked `?filter=HIT` URL would otherwise be silently
  reinterpreted as a (nonexistent) host named "HIT" if syslog mode were
  toggled on the same install. `logs.rs` now passes the parsed `host` straight
  to `parse_syslog_tail`, and a new `syslog_client::list_syslog_hosts()`
  helper lists every wired host currently under `SYSLOG_LOG_ROOT` so the
  Admin UI can offer a real host dropdown instead of a text field the
  operator has to guess values for; `logs.html`'s syslog-mode branch
  previously had no filter UI at all (only the legacy nginx branch did), so
  a `<select>` bound to `?host=` was added, mirroring the existing
  `dhcp.html`/`setup.html` dropdown styling. Selecting "Alle Hosts" clears
  the filter by navigating back to `/logs` with no query string.
  Independent review caught that wiring a raw, caller-controlled `?host=`
  straight into `parse_syslog_tail`'s `Path::new(log_root).join(h)` would
  have been a path-traversal / arbitrary-file-read regression (e.g.
  `?host=../../../data` reading the session secret) -- this was fixed
  two ways: `logs_page()` now only ever honors a `?host=` value that is an
  exact member of `list_syslog_hosts()`'s real result (an unrecognized or
  traversal-shaped value silently falls back to "all hosts"), and
  `parse_syslog_tail` itself independently rejects any `host` argument that
  is not a single bare directory-name segment (empty, `.`, `..`, or
  containing `/`/`\`), so every future caller is protected, not just this
  one. Added `list_syslog_hosts_returns_sorted_host_directory_names`,
  `list_syslog_hosts_returns_empty_for_missing_root`, and
  `parse_syslog_tail_ignores_host_with_path_traversal` unit tests in
  `syslog_client.rs`, plus a `logs_html_renders_syslog_host_filter_dropdown_with_selection`
  test in `main.rs` that renders the real on-disk `logs.html` template
  (not a throwaway inline one) to prove the dropdown reflects the selected
  host correctly.
- Fixed an intermittent `has active endpoints` teardown race that could poison
  a shared validation Docker network for whichever job ran next in
  `full-setup-deep-validate.yml` (#834) -- a distinct bug from the
  octet-hash-collision class #820 already fixed above (`has active
  endpoints` does not match `validation_subnet_output_is_collision`'s
  collision signatures, and correctly so). All simulation jobs in one run
  share the same Compose project/network name, and every teardown trap ran
  `docker compose down -v --remove-orphans >/dev/null 2>&1 || true`: when
  `down`'s own container-removal-vs-network-endpoint-detach step lost
  Docker's real async race, the failure was silently swallowed and the job
  still reported success, while leaving the shared network non-empty for
  the next job in the sequential `needs:` chain to trip over (a real,
  unguarded failure that time). Confirmed directly from two same-run job
  failures hitting the identical network id 7 minutes apart, and live-
  reproduced against a real Docker daemon on a runner host. Fixed in #835 by
  adding `validation_network_await_detached` / `validation_network_teardown`
  / `validation_project_networks_teardown` to
  `scripts/lib/reserve-validation-subnet.sh` (poll until Docker itself
  confirms zero attached containers, force-disconnect stragglers past a
  bounded timeout, clear `::error::` if still stuck), applied at every
  `docker compose down ... || true` / bare `docker network rm ... || true`
  teardown site sharing this pattern across the codebase, not only the two
  jobs that happened to surface it: `dns-zone-rollback-simulation.sh`,
  `ssl-mitm-cache-simulation.sh`, `ui-nats-dns-integration-simulation.sh`,
  `nats-secondary-auth-callout-simulation.sh`, `setup-cli-simulation.sh`
  (both teardown sites), `dhcp-kea-lease-flow-simulation.sh`,
  `dhcp-proxy-pxe-simulation.sh`, `ui-rust-checks.sh`, and the "Tear down
  full-setup validation stack" step in `full-setup-deep-validate.yml`,
  `full-setup-validate.yml`, and `build-push.yml`. CI-only, no
  production/runtime behavior change.
- Fixed a bundle of four watchdog.sh defects plus two related divergences
  found via the #849 vacuum-first bug hunt (#872): `disk_info()` was calling
  `df` without `-P`, so a wrapped long-device-name line made `awk 'NR==2'`
  read the wrong row and the JSON percentage come back empty; the printf
  that assembled the JSON then interpolated the raw (possibly empty)
  `$pct` instead of `${pct:-0}`, so a single empty read produced
  syntactically invalid JSON (`{"pct": , ...}`) that corrupted the whole
  `status.json` for every reader, including the Admin UI dashboard. Fixed
  both: `df -P` plus `${pct:-0}` in the printf. Separately, `get_health()`
  and `restart_container()`'s `curl -sf` calls had no `--max-time`, so a
  hung/unresponsive docker-socket-proxy could stall the entire
  single-threaded main loop indefinitely with no way for Docker or an
  operator to notice; both now pass `--max-time` (`CURL_MAX_TIME`,
  default 5s). Adding that timeout surfaced a second, adjacent latent bug in
  the same function, caught by this PR's own new test suite: `get_health()`
  piped `curl` straight into `jq -r '.State.Health.Status // "none"' ||
  echo "unreachable"`, but `jq` exits 0 with no output on a completely empty
  stdin (not a parse error) -- so a `curl` failure that produced empty
  output (connection refused, or exactly what a real `--max-time` timeout
  itself produces) never reached the `|| echo "unreachable"` fallback at
  all, and `get_health()` silently returned an empty string instead.
  `check_and_maybe_restart()` only recognizes the literal strings
  "healthy"/"unhealthy", so an empty result was silently ignored every
  cycle -- no failure counter, no restart, ever, for a container the proxy
  genuinely could not reach. Fixed by capturing curl's own exit status
  directly (`body=$(curl ...) || { echo "unreachable"; return; }`) before
  ever handing anything to `jq`, instead of relying on the pipeline's
  combined exit behavior. `deploy/full-setup` already had a working
  `test -f status.json` healthcheck for watchdog, but dev/prod/quickstart
  had none at all -- a new `services/watchdog/healthcheck.sh`, shipped in
  the image and wired into all four compose files (upgrading full-setup's
  too), checks the file's *mtime* rather than mere existence (3x
  `CHECK_INTERVAL`, floored at 60s), since a stalled main loop leaves a
  stale-but-present file that an existence check would read as healthy
  forever; the main loop also now re-runs `write_status()` a second time
  after `maybe_purge()`/`maybe_prune_syslog()` so the once-daily long-running
  purge scan can't age the file out on its own and cause a false-positive
  unhealthy flap. `CONTAINER_PROXY`/`CONTAINER_DNS_STANDARD`/
  `CONTAINER_DNS_SSL` looked like supported renaming knobs, but
  `scripts/docker-socket-proxy.sh`'s HAProxy allowlist and the Admin UI's
  `docker_client.rs` both hardcode the same three default container names
  and read neither knob at all -- a rename silently made every health check
  for that container return "unreachable" and every restart 403 through the
  proxy. Since wiring real renaming support end-to-end would require
  changes to the proxy allowlist and the Admin UI (out of scope for a
  watchdog.sh hardening pass), watchdog now fails loudly at startup instead
  on a mismatch. `maybe_purge()` used to stamp the daily-purge rate-limit
  file unconditionally even when `CACHE_DIR` didn't exist (the purge block
  was silently skipped with no log line, yet the stamp claimed it ran) and
  swallowed real `find` errors via `2>/dev/null`, unlike the sibling
  `maybe_prune_syslog()`, which logs them -- both now match that sibling's
  pattern: an early `return` before any stamp write on a missing
  `CACHE_DIR`, and `find` failures captured and logged instead of hidden.
  Also fixed: `CHECK_INTERVAL` was unvalidated while every other numeric
  knob got a `case ''|*[!0-9]*)` guard (a bad value reaches `sleep` under
  `set -e` and crashes the daemon); it now gets the same guard plus a floor
  of 1 (a literal 0 would busy-loop). `SSL_ENABLED` used to require the
  exact literal `"1"`, diverging from the Admin UI's
  `env_bool("SSL_ENABLED", true)`, which also accepts `true`/`yes`/`on`
  case-insensitively -- `SSL_ENABLED=true` silently left dns-ssl
  unmonitored; a new `is_truthy()` helper (matching #874's identically-named
  fix for `SYSLOG_ENABLED`) normalizes it to a canonical `1`/`0` at startup.
  Finally, `resolve_cache_dir()`'s fail-closed error for a legacy divergent
  `CACHE_DIR_STANDARD`/`CACHE_DIR_SSL` misconfiguration was logged via
  `log()` to stdout, which the `CACHE_DIR="$(resolve_cache_dir)"` command
  substitution silently captured and discarded -- it now goes to stderr via
  a new `log_err()` helper. New bats coverage: `watchdog_disk_info.bats`,
  `watchdog_purge.bats` (no dedicated test file existed for `maybe_purge()`
  before this fix), `watchdog_config_validation.bats`, and
  `watchdog_curl_timeout.bats`.
- Fixed recurring `Pool overlaps with other one on this address space` /
  `overlaps existing network state` failures in every full-setup validation
  path when two runs shared a self-hosted runner host (#820) -- eliminated
  for the whole bug class, not just the jobs that happened to fail visibly.
  `full-setup-deep-validate.yml`'s stack-starting jobs never adopted the
  #703 flock-plus-retry validation-subnet reservation that the manual
  `full-setup-validate.yml` already used: its `full-setup-validate` job used
  a single fail-hard pre-flight check followed by a plain `docker compose
  up`, and its five compose-stack simulation jobs (SSL MITM, UI/NATS/DNS,
  Watchtower, NATS auth-callout, DNS zone rollback) started stacks on one
  shared hash-derived octet with no lock and no retry. Two concurrent runs
  deriving the same octet (only 252 buckets), or one losing the
  check-then-create race mid-flight, hard-failed and forced a manual re-run
  (real recurrence: run `29287590206`'s NATS auth-callout job died on octet
  22). Separately, `dhcp-kea-lease-flow-simulation.sh` (172.31.0.0/16) and
  `dhcp-proxy-pxe-simulation.sh` (172.29.0.0/16) had their own,
  self-contained instance of the identical bug: each derived its own subnet
  octet from a bare hash with no lock and no retry, then called `docker
  network create` directly -- the PID-based object naming these two scripts
  already had only prevents Docker object *name* collisions, not subnet
  *CIDR* collisions, which Docker's IPAM tracks daemon-wide regardless of
  name; verified this was a real, not merely theoretical, gap before fixing
  it (no structural proof of safety was possible -- the birthday-paradox
  math is identical to the deep-validate case, just on a different `/16`).
  All eight jobs across both workflows now reserve a host-locked,
  overlap-checked octet and retry on a genuine subnet collision only, via
  the shared `scripts/lib/reserve-validation-subnet.sh` primitives (new
  `validation_subnet_export_env` / `validation_subnet_output_is_collision`
  / `validation_subnet_conflicts` helpers -- the last one consolidates what
  used to be a copy-pasted overlap-check python block across five separate
  callers, including `full-setup-validate.yml`'s own pre-existing #703 copy,
  into one shared definition) and a new single-command wrapper
  `scripts/lib/run-in-validation-subnet.sh` for the five deep-validate
  simulation jobs. The two DHCP scripts adopt the same reserve-check-create-
  retry loop directly (their subnet-dependent addresses are computed only
  after a candidate octet's `docker network create` actually succeeds), each
  in its own lock namespace so 172.29/172.30/172.31 contention never
  cross-serializes. Because every octet is chosen against the runner's live
  `docker network`/`ip addr` state at claim-time and retried on collision,
  this also self-heals around a leftover bridge interface a crashed run
  left behind, independent of any host-side cleanup hook.
- Fixed the NATS auth-callout mechanism being permanently broken on every real
  `deploy/dev` and `deploy/prod` install (#811): the `nats` container's
  entrypoint unconditionally regenerated the whole `/etc/nats/nats.conf` on
  every start, so the Admin UI's own write-then-restart sequence (it writes the
  full config with the `auth_callout {}` block, then restarts `nats` to apply
  it) clobbered its own config -- the restart re-ran the entrypoint, which
  overwrote the just-written file a fraction of a second before `nats-server`
  re-exec'd against it. `lancache-nats-callout` never existed in the running
  config and the UI's responder task looped forever on `authorization
  violation`, from the very first boot, with zero secondaries needed to
  reproduce. Fixed by splitting the config the way every other service in this
  project already scopes its own regeneration: the entrypoint now owns only the
  static `nats.conf` (jetstream, `log_file`, the four static roles -- UI,
  DNS-writer, DNS-replica, and the callout responder user) and `include`s a
  separate `auth_callout.conf` fragment that ONLY the Admin UI writes
  (`services/ui/src/routes/secondaries.rs::update_nats_conf`, now emitting just
  the `auth_callout {}` stanza to `NATS_AUTH_CALLOUT_PATH`). The entrypoint
  regenerates its own file idempotently on every restart and only ever creates
  an empty placeholder for the fragment when absent, never overwriting it, so
  the UI's callout config survives restarts. The UI still restarts `nats` to
  apply the fragment because a SIGHUP-style live reload cannot deliver it --
  `nats-server` explicitly refuses (`config reload not supported for
  AuthCallout`), verified empirically against `nats-server 2.14.3`, as was the
  `include`-inside-`authorization {}` mechanism the fix relies on. Added
  `NATS_CALLOUT_USER`/`NATS_CALLOUT_PASSWORD` to the `nats` service (fed by the
  same compose vars as the `ui` service so the responder's static bypass user
  always matches) across `deploy/dev`, `deploy/prod`, and `deploy/quickstart`;
  `deploy/full-setup`'s CI harness now prebakes the same split so the
  auth-callout simulation exercises the real `include` path.
- Fixed `setup.sh` writing an unescaped backtick in a comment inside the
  main `.env`-writing heredoc (found during a real end-to-end install test,
  2026-07-14): since that heredoc is deliberately unquoted (`<<EOF`, not
  `<<'EOF'`) so `${IP_STANDARD}` etc. interpolate, an unescaped backtick in
  the comment text is real command substitution, not an inert comment.
  Every install ran `resolver` as a shell command, printing `setup.sh: line
  4950: resolver: command not found` to stderr and silently deleting the
  word "resolver" from the written `.env`'s own comment. Escaped the
  backticks; the `NGINX_UPSTREAM_RESOLVER=` value itself was always correct
  and unaffected.
- Fixed `scripts/dns-zone-rollback-simulation.sh` (#809) never pulling fresh
  images before starting its stack, unlike its sibling
  `ssl-mitm-cache-simulation.sh`: Compose's default `pull_policy: missing`
  silently reuses whatever image a runner already has cached locally under
  the target tag. Confirmed live: a runner with an 11-hour-stale local
  `dns:dev` image (from before this script's own rollback listener existed)
  silently ran that old binary, producing a permanent connection-refused
  that looked exactly like a startup race rather than what it actually was.
  Added the same explicit `pull --quiet` step the sibling script already
  uses, for the identical reason.
- Fixed `build-push.yml`'s `rust_coverage` job pinning `actions/upload-artifact`
  to `v4.3.6`, whose own action metadata still declares the deprecated Node 20
  runtime (#799). Bumped to `v7.0.1`; the `name`/`path`/`retention-days` inputs
  used here are unaffected across that range.
- Fixed the `full-setup-deep-validate.yml` PR gate's `setup.sh CLI simulation`
  job perpetually validating stale images. `scripts/setup-cli-simulation.sh`
  hardcoded the mutable `edge` channel, which only moves on a push to `master`;
  with `master` long frozen, every PR (including every `v0.2.0` PR) revalidated
  months-old images instead of its own code -- the same "blocking check coupled
  to a slow-moving channel tag" class of bug as #775 and #777. The job now
  installs the PR's OWN immutable `pr-<N>-sha-<short>` image set (pinned,
  threaded from the deep-validate plan and gated on `ensure-pr-staging-images`),
  so it tests this PR's images against this PR's checked-out `setup.sh`/compose
  and can never go stale; `workflow_dispatch`/fork/Dependabot runs fall back to
  the base-ref channel (`dev` for `v0.2.0`, `edge` for `master`) resolved from
  the event rather than hardcoded. `setup.sh`'s `validate_lancache_image_tag`
  now also accepts the CI-only immutable `pr-<N>-sha-<short>` staging-tag format
  as a pinned target (operator-facing pinned/derive messages still name only
  `sha-*`/`vX.Y.Z`, so these ephemeral CI tags are not advertised for
  production installs).
- Fixed `scripts/ssl-mitm-cache-simulation.sh` being unable to prove SSL
  mode's DNS actually routes to a distinct MITM endpoint (#668): it
  previously asserted `dns-standard` and `dns-ssl` both resolve a test CDN
  domain to the exact same hardcoded proxy address, so a `dns-ssl` wrongly
  wired to the standard-mode address would have passed identically. Added a
  `standard-passthrough-shim` service to `deploy/full-setup/docker-compose.yml`
  (Compose-profile-gated, only started by this script) that reproduces
  prod's real `IP_STANDARD:443` -> proxy-container-`:8443` port-forward as a
  genuinely separate, dialable address; `dns-standard`'s `PROXY_IP` now
  points there instead of at the proxy container's own address. The test now
  connects to whatever each DNS server *actually* answers with and inspects
  the certificate presented: `dns-ssl`'s resolved address must present a
  certificate issued by the LAN CA (and be rejected by the public trust
  store), while `dns-standard`'s resolved address must present the real
  origin's own certificate (and validate cleanly against the public trust
  store) -- proving the DNS-driven MITM-vs-passthrough distinction
  end-to-end instead of a shared-address assumption. Also updated
  `scripts/full-setup-client-simulation.sh`'s DNS check to expect the two
  nameservers' now-genuinely-different answers.
- Fixed `cargo-with-sccache-fallback`'s `is_sccache_failure` check missing the
  sccache-dist remote-build failure signature (issue #783): when a
  compile-farm host's sccache-dist server itself rejects a C-dependency
  build (observed: a `bwrap` sandbox on one dist server failing to mount
  `/proc`, surfaced by `cc-rs`/`zstd-sys`/`aws-lc-sys` as a generic
  `ToolExecError`/exit-254 with no other sccache-recognizable string), the
  action's local-compile fallback never triggered and the job went straight
  to a hard failure -- confirmed across 4 real CI reruns on one PR, all
  landing on the same dist server, none of which matched the prior regex.
  `is_sccache_failure` now also matches `sccache: Job failed on server`, so
  builds degrade gracefully to a local (non-distributed) compile instead of
  failing outright.
- Fixed `build-push.yml`'s `promote` job (moves the mutable `:dev`/`:edge`
  GHCR channel tags) sharing the workflow-level `"Build & Push-publish"`
  concurrency group with the rest of the pipeline. During a burst of rapid
  merges to `v0.2.0`, each push's run competes for that same single pending
  slot as the slow build/test/scan stages, so a whole run for an intermediate
  commit -- including its `promote` job -- can be superseded and thrown away
  before it ever starts, leaving `:dev`/`:edge` stuck on a pre-burst image for
  the rest of the window (confirmed live: PR #765's own run never started a
  single job, superseded by the next merge's push). `promote` now has its own
  job-level `"Build & Push-promote"` concurrency group, decoupling its
  scheduling from the heavy pipeline's queue; `backfill-stack-latest.yml`
  joins the same new group so the two tag-moving workflows still serialize
  against each other. `promote` also re-resolves the branch ref's current tip
  via `git ls-remote` immediately before moving any tag and skips as a no-op
  if a newer commit has already landed, so a run that does get to execute
  never briefly points `dev`/`edge` at a commit it already knows is stale
  (#777). Note: this does not resurrect commits whose entire pipeline run was
  never scheduled in the first place (no `sha-*` images exist to promote for
  those) -- that is a separate build-throughput-vs-merge-rate problem the
  issue's own "possible directions" left undecided.
- Fixed `AGENTS.md`'s two CodeQL macro-expansion carve-out rules (AG-VAL-021,
  AG-VAL-022) contradicting each other: AG-VAL-021's worked example described
  macro-*generated* code while the general rule it illustrated (AG-VAL-022)
  correctly scoped the exception to ordinary macro *invocations* in
  human-authored source. Reworded AG-VAL-021 as its own, genuinely distinct
  case (CodeQL findings in code a macro actually generates, which needs
  test-coverage evidence AG-VAL-022 does not), with explicit citations to the
  upstream CodeQL bugs (github/codeql#19966, #19982, #20659) AG-VAL-022's
  exception rests on (#702).
- Fixed the proxy image not being rebuilt when a PR only changed
  `services/dns/cdn-domains.txt`. `services/proxy/Dockerfile` `COPY`s that
  exact file into the image at build time (the `dns-domains` named build
  context, baked in as `/etc/nginx/cdn-domains.txt`), but both
  `.github/workflows/build-push.yml`'s `detect-changes` job and its hand-kept
  mirror `scripts/detect-full-setup-changes.sh` only treated `services/proxy/`
  itself as a proxy-touching path, so a domain-list-only change shipped a
  fresh `dns` image while leaving the proxy image's baked-in domain list
  stale until some unrelated `services/proxy/` change next happened to
  rebuild it. Both detectors now also set `proxy=true` for
  `services/dns/cdn-domains.txt`, fixed together in the same change since
  `detect-full-setup-changes.sh`'s fail-closed staging guard would otherwise
  poll for a PR-staging `proxy` tag `build-push.yml` never pushes and time
  out (#771).
- Fixed reverse (PTR) DHCP-DDNS updates always failing in production,
  independent of and not fixed by #706's forward-DDNS fix. Kea's D2 daemon's
  `reverse-ddns.ddns-domains` targeted a single hardcoded catch-all zone,
  the literal `in-addr.arpa.`, but PowerDNS never creates a zone with that
  exact name -- it only ever creates the narrower private-range subzones
  `services/dns/entrypoint.sh`'s `PRIVATE_REVERSE_ZONES` lists (e.g.
  `31.172.in-addr.arpa.`) -- so every PTR update was rejected with RCODE 9
  (NOTAUTH) "Can't determine backend for domain", for any leased address,
  unconditionally. `services/dhcp/kea-dhcp-ddns.conf`'s `reverse-ddns` now
  lists one `ddns-domains` entry per real IPv4 private reverse zone
  (mirroring `PRIVATE_REVERSE_ZONES` verbatim), so Kea's D2 can match a
  lease's reverse FQDN against the correct, real zone by suffix instead of a
  zone nothing hosts. Verified against a real Kea 2.6.3 + PowerDNS 5.2.11
  stack: a granted DHCP lease now produces a matching PTR record via a real
  TSIG-signed DDNS update (#768).
- Fixed Kea DHCP (`kea-dhcp4`, `kea-ctrl-agent`, `kea-dhcp-ddns`) failing to
  start at all once the `logging` profile's file-log wiring (#633/#756) was
  active. Kea's packaged binaries hard-restrict file-logger `output` paths
  to exactly `/var/log/kea` (a security hardening against arbitrary file
  writes via a malicious `config-set`); #756 pointed all three daemons'
  file loggers at `/var/log/lancache-dhcp/*.log` instead, following this
  project's usual per-service naming convention, which Kea rejects at
  config-load time with "invalid path in `output`" -- a full outage for any
  install with the `logging` profile enabled, not just a missing log
  stream. Both the static configs and `migrate_dhcp4_config()`'s upgrade
  path now write to `/var/log/kea/*.log`, and the `dhcp-logs` volume mount
  plus fluent-bit's tail source were remapped to match in all three Compose
  files (#773).
- Fixed `scripts/select-build-tools-image.sh` silently trusting a stale,
  incomplete published build-tools image. Its `BUILD_TOOLS_REQUIRE_PUBLISHED=true`
  strict path hardcoded `:latest`, a channel that only moves on a stable
  `vX.Y.Z` release tag (none exist yet) and so can sit stale for weeks, while
  `:dev` (promoted on every `v0.2.0` push) and `:edge` (promoted on every
  `master` push) stay current; it now resolves the channel that actually
  matches the current ref instead. Its `smoke_test_image()` tool list was
  also missing `dhclient`, `expect`, `tcpdump`, and any `python3-scapy`
  check, even though `tools/build-tools/Dockerfile` genuinely installs and
  verifies all of these -- letting the stale `:latest` image pass the smoke
  test anyway. Confirmed as the root cause of PR #764's `DHCP Kea lease-flow
  simulation` job failing with `dhclient: command not found` even after
  #773's Kea log-path fix landed (#775).
- Fixed the PowerDNS authoritative server's `webserver-allow-from` in
  `services/dns/pdns.conf.template` only permitting `127.0.0.1` and
  `172.16.0.0/12` — Docker's default address-pool range. Operators who
  customize `/etc/docker/daemon.json`'s `default-address-pools` to use
  `10.0.0.0/8` or `192.168.0.0/16` bridge networks had the UI container's
  calls to this API (port 8081) rejected. Widened to the full RFC1918 range,
  matching the pattern already used by `recursor.conf.template`'s own REST
  API `allow_from` (port 8082). Standard installs (Docker's default
  `172.17.0.0/16`–`172.31.0.0/16` pools) were never affected (#654).
- Fixed the Admin UI's `/dhcp` add-subnet and update-subnet forms sending an
  unresolved NTP hostname straight into Kea's `ntp-servers` option-data,
  which Kea's own IPv4-only validation for that option then rejected at
  `config-set` time. `services/dhcp/entrypoint.sh` already resolved
  `DHCP_NTP_SERVERS` hostnames to IPv4 for the initial Kea config (#310), but
  the Admin UI's live mutation path had no equivalent step, so a stock
  install's shipped default (`debian.pool.ntp.org,time.nist.gov`,
  pre-filled into the form) failed on first save unless an operator manually
  replaced it with raw IPs. Both routes now resolve each NTP entry via the
  OS resolver before writing the subnet, returning a clear 400 naming the
  offending hostname if it can't be resolved to an IPv4 address, instead of
  Kea's own opaque config-set error (#670).
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
- Fixed the Admin UI's `remove_domain()` (CDN domain-list removal) picking a
  single line separator for the *whole* domain-list file — CRLF if the file
  contained CRLF anywhere, else LF — and rejoining every retained line with
  it. On a file with mixed line endings (e.g. a CRLF header/comment
  hand-edited on Windows followed by LF domain entries appended from
  Linux/the container), every surviving LF domain entry was rewritten with a
  spurious trailing `\r`. Since the domain value is read verbatim by the
  proxy/DNS entrypoints, that stray `\r` could leak into generated nginx
  map/cert names and stream targets. Each retained line now keeps its own
  original terminator (`\r\n`, `\n`, or none for a final line with no
  trailing newline) instead of being normalized to one file-wide separator
  (#656).
- Fixed three arm64-rollout gaps left over from native arm64 image builds
  (#592): `backfill-stack-latest.yml` still required only `linux/amd64` even
  though `release/stack-images.yml` declares every runtime service's `latest`
  channel as `linux/amd64` + `linux/arm64` (an operator backfill from an
  older amd64-only release could have silently reset `latest` to an
  amd64-only stack); `docs/release-versioning.md`'s Platform Support section
  still described amd64 as the only supported platform and setup as failing
  closed on any non-amd64 host; and `setup.sh`'s
  `assert_prebuilt_image_platform_supported()` only checked the host's
  architecture in general, never whether the specific resolved
  `LANCACHE_IMAGE_TAG`/channel actually publishes a manifest for that
  architecture, so an arm64 host pinned to a pre-arm64 tag could pass that
  guard and only fail deep inside `docker compose pull`, after setup.sh had
  already written install state. Added
  `assert_resolved_image_tag_platform_supported()`, which mirrors
  `scripts/require-image-platforms.sh`'s `docker buildx imagetools inspect`
  approach, and calls it right after the tag/channel is resolved and before
  the first state-mutating write in the install, update, and secondary-node
  flows (#665).
- Fixed the `setup.sh CLI simulation` and `deep full-setup validation` jobs in
  `full-setup-deep-validate.yml` failing on every PR since #744 merged. #744
  added `assert_resolved_image_tag_platform_supported()`, which hard-requires
  a working `docker buildx` before continuing; that check runs inside the
  `build-tools` image (`tools/build-tools/Dockerfile`), which never installed
  a `docker buildx` CLI plugin at all, so it failed closed with "docker
  buildx is required ... Install the docker-buildx-plugin package". Built
  `docker buildx` from source in the existing `actionlint-builder` stage
  (same CVE-staleness rationale already applied to the Docker CLI and
  docker-compose there) and installed it as a CLI plugin alongside them.
  Buildx v0.35.0 pins `github.com/containerd/containerd/v2` at v2.2.4, which
  carries three HIGH-severity CVEs (CVE-2026-53488/53489/53492) fixed in
  2.2.5+ -- caught by this image's own Trivy scan step during development of
  this fix -- so the build now `go get`s that one module up to v2.2.6 before
  building buildx, the same way the Dockerfile already deliberately accepts
  (via `.trivyignore.yaml`) that `github.com/docker/docker`'s v28.5.2 pin
  cannot be bumped the same way (no v29.x Go module tags exist upstream).
  Also, buildx's release tag ships a committed `vendor/` directory, which Go
  auto-selects over the network fetch once `go get` touches `go.mod` --
  `go mod vendor` re-syncs it before the build to avoid an "inconsistent
  vendoring" failure. Filed #791 as a deliberate follow-up (not done here)
  to widen `scripts/select-build-tools-image.sh`'s smoke test for `docker
  buildx version`, matching the #775 precedent: that check can only be
  added once the published `:dev`/`:edge` build-tools image actually
  contains buildx, i.e. after this fix merges and republishes -- adding it
  in this same PR would fail the strict, no-fallback `validate-compose` and
  `shellcheck (GitHub-hosted fallback)` jobs against the still-stale
  currently-published image (#787).
- Fixed `scripts/setup-cli-simulation.sh` (shared by the `setup.sh CLI
  simulation` job in both `full-setup-deep-validate.yml` and
  `full-setup-validate.yml`) colliding with itself across concurrent CI runs
  on the shared self-hosted runner pool: `deploy/quickstart/docker-compose.yml`
  pins a static top-level `name: lancache-ng`, which Compose prefers over the
  `--project-directory` basename it would otherwise derive, so every run
  resolved to the identical Compose project (and therefore identical
  container/volume names) regardless of each run already using its own
  unique `mktemp`-derived install directory. Confirmed live (run
  `29322035897`): two concurrent runs both resolved to project `lancache-ng`,
  and `setup.sh`'s own `guard_restore_shared_project_volumes` (#669) correctly
  refused to proceed once it saw another active install under that name --
  the guard was doing its job; this script simply never gave concurrent runs
  the per-run isolation it assumes. Same failure family as #820 (shared-host,
  concurrent-CI, no per-run isolation), a different specific resource (Compose
  project name, not a subnet octet). The script now exports a
  `COMPOSE_PROJECT_NAME` derived from its own already-unique install
  directory's basename (sanitized to Compose's `^[a-z0-9][a-z0-9_-]*$`
  requirement) before every `docker compose` call, in both places the script
  can mint a fresh install directory (initial run and the port-collision
  retry loop); a real end-user install is unaffected, since it never sets the
  simulation-only env var this derivation depends on, and the compose yaml's
  static `name: lancache-ng` is deliberately left unchanged for real installs
  (see #669 item 6 for why per-install-dir project naming stays out of scope
  for that case).
- Fixed the Admin UI's `/logs` view (syslog mode) permanently starving a
  naturally quiet host once a noisier host produced enough recent lines to
  fill the global entry budget (#859). `syslog_client::parse_syslog_tail`
  already guaranteed (via the #758 `dirs_with_candidates`/`hosts_seen` fix)
  that every host's newest file gets opened before the collection loop's
  early-break can fire, but the final merge step afterward
  (`collected.sort_by(timestamp)` + truncate-to-`limit`) was completely
  host-blind: if every other host's lines happened to be newer, a quiet
  host's entire contribution could still be sorted out of the window and
  silently disappear from the rendered page, even though its file was read
  correctly and its data was still on disk. The concrete, safety-critical
  instance: `services/watchdog/watchdog.sh` logs a handful of lines at
  container start and then stays silent unless it detects and acts on a
  real problem, while `netdata`'s continuous PLUGINSD/health-check chatter
  can burn through the default 200-line budget within minutes -- once that
  happens, watchdog's log (including a future real-incident line) becomes
  permanently invisible via the Admin UI for the rest of the container's
  uptime. This was a general capacity/fairness bug in the merge, not
  watchdog-specific, so the fix is general too: the merge now groups
  collected lines by host, reserves each host with data at least
  `per_host_floor = (limit / hosts_with_data).clamp(1, PER_HOST_FLOOR)`
  (`PER_HOST_FLOOR` is a small constant, 10) of its own most recent lines
  via a round-robin pass, and only then fills any remaining budget with the
  globally most recent leftover lines across all hosts -- so a quiet host
  can no longer be fully evicted, while a genuinely high-volume, genuinely
  recent host still dominates the window whenever it isn't competing with
  other hosts for space, and can still win most of the shared budget even
  when it IS competing against other active hosts. The floor is
  deliberately a small constant rather than a pure equal share of `limit`
  across hosts: an equal share would, once every active host has at least
  that many lines, consume the entire budget in the floor pass and leave
  nothing for the recency-fill pass, degrading the merge to a fixed count
  per host regardless of actual recency -- an over-correction caught during
  review before merge. New unit tests in `services/ui/src/syslog_client.rs`
  cover a quiet host surviving alongside 50 newer lines from a noisy host
  while the overall limit is still respected, a single uncontested noisy
  host still getting exactly its most recent lines with no fairness
  penalty, and four simultaneously-active hosts where the two genuinely
  newer hosts each win their entire history while the two older hosts still
  keep their guaranteed floor rather than being squeezed to zero; all
  pre-existing `parse_syslog_tail` tests (including the #758 regression
  test) continue to pass unmodified.

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