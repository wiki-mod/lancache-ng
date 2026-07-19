# services/ui core + NATS/auth capability inventory

Part of the project-wide capability inventory tracked in issue #843. This document
covers `services/ui`'s **core** module surface — not the feature routes
(`routes/dhcp.rs`, `routes/domains.rs`, `routes/logs.rs`, `routes/secondaries.rs`,
`routes/stats.rs`, `routes/dashboard.rs`, `routes/setup.rs`,
`routes/netdata_proxy.rs`, `routes/dns_snapshots.rs`), which are a separate,
parallel audit pass.

In scope for this document: `main.rs`, `config.rs`, `nats_auth_callout.rs`,
`nats_config.rs`, `session.rs`, `docker_client.rs`, `nginx_client.rs`,
`syslog_client.rs`, `routes/mod.rs`'s shared helpers, and a scoping note on
`kea_snapshots.rs`.

**Branch note**: all source was read directly from `origin/v0.2.0` blobs
(`git show origin/v0.2.0:<path>`) rather than trusting any particular local
working tree checkout, since v0.2.0 is the branch these features (in
particular #583's auth-callout work) actually shipped on.

Exact per-file `#[test]` counts below were produced with
`grep -c '#\[test\]' <file>` against each file, not hand-counted.

> **Currency check (2026-07-18):** re-verified against `origin/v0.2.0` @
> `dc8d79c6`; see corrections below. Three files grew substantially since
> this document was first written (68 commits landed on `v0.2.0` in the
> interim, several touching this exact file list): `main.rs` (1156 → 1751
> lines, 12 → 19 tests: 15 `#[test]` + 4 `#[tokio::test]`), `config.rs`
> (1393 → 2133 lines, 24 → 40 tests), and
> `syslog_client.rs` (698 → 1046 lines, 12 → 18 tests) — driven by
> `e7f2a06d` (AG-CODE-010 WHY-comments on ~52 test functions), `f29b3fe9`
> (#951, basic_auth integration tests), `dc8d79c6` (#988, case-insensitive
> placeholder detection + parity fixture), `afa3bbf9` (#881, NATS-URL
> reachability check), `020904a6` (#855, auto-generated registration token),
> `73a4fe00` (#877, SYSLOG_ENABLED/SYSLOG_MAX_GB parsing parity), `4a5e0c11`
> (#828, syslog E2E simulation test), and `2137157f`/`88b429d6` (#865/#861,
> syslog host-filter wiring). All test/line counts below are corrected to
> match current `origin/v0.2.0`. Everything else in this document —
> `nats_auth_callout.rs`, `nats_config.rs`, `session.rs`, `docker_client.rs`,
> `nginx_client.rs`, `routes/mod.rs`, the CI-gap analysis, and every
> narrative/behavioral claim — was independently re-verified against current
> code and remains accurate; only the counts and two leftover
> pre-retraction sentences below needed correction.

---

## 1. `main.rs` (1751 lines, 19 tests: 15 `#[test]` + 4 `#[tokio::test]`) — process entry point, wiring, security middleware

**`AppState`** (shared, `Arc`-wrapped): `templates` (Tera), `config`, `docker`
(bollard client), `http_client` (reqwest), `file_lock`/`kea_config_lock`/
`dhcp_probe_lock` (concurrency guards used by the feature routes, out of this
pass's scope), `nats` (async_nats::Client), `db` (Mutex<rusqlite::Connection>),
`ui_session_secret` ([u8;32]), `ui_session_ttl` (Duration),
`nats_issuer_public_key` (String — the auth-callout issuer's public NKey,
baked into nats.conf's `auth_callout { issuer: ... }`).

**Startup sequence in `main()`** (in order, each step fails closed with
`std::process::exit(1)` on error, logged via `tracing::error!` first):
1. `init_tracing()` — dual-layer tracing: stdout + best-effort file layer at
   `UI_LOG_FILE` (default `/var/log/lancache-ui/ui.log`), opened with
   `create(true).append(true)`; a missing/unwritable log path is *not* fatal
   (installs without the `logging` compose profile still start, stdout-only).
2. `config::Config::from_env()` — see section 2.
3. `preflight_startup_config(cfg)` → validates `ui_session_ttl_seconds`
   (1..=1 year) and `nats_config::validate_runtime_nats_credentials` (all four
   NATS role username/password pairs). Returns the parsed TTL `Duration`. Note
   `secondary_registration_token` is **not** checked here — see step 10 below
   for where it's actually resolved and validated.
4. `resolve_admin_ui_auth_mode(auth_user, auth_password, allow_insecure_ui)` —
   both-or-neither gate for `UI_AUTH_USER`/`UI_AUTH_PASSWORD`;
   `ALLOW_INSECURE_UI=true` is the only way to start with neither set, and
   does so with a `tracing::warn!`.
5. `load_templates(cfg)` — panics (deploy-time defect, not runtime condition)
   on any missing/unparseable template. Registers 4 Tera functions
   (`lancache_image_registry/prefix/channel/tag`) *before* adding templates,
   since Tera validates function calls at parse time.
6. `docker_client::connect_from_env()` — see section 6.
7. `reqwest::Client` with a 10s timeout.
8. `connect_nats_with_retry(cfg)` — **blocking**: exponential backoff (1s→30s
   cap) loop, retries forever, no HTTP listener binds until this succeeds. A
   NATS outage takes down the *entire* Admin UI, not just NATS-backed
   features — explicitly called out in the doc comment. Auths with
   `nats_ui_user`/`nats_ui_password` when both non-empty, else
   `async_nats::connect` (unauthenticated — only reachable if the preflight
   NATS-credential check above didn't already exit(1), so in practice this
   branch is dead in a correctly configured deployment, but not dead code in
   the compiler sense).
9. `load_or_create_session_secret()` — 32-byte random secret persisted to
   `/data/lancache-ui-session.secret` (hex, `create_new` for atomicity/no-lost-
   update-race, mode 0600 on unix). Survives container recreate so sessions
   aren't invalidated every restart.
10. `load_or_create_secondary_registration_token(cfg.secondary_registration_token,
    SECONDARY_REGISTRATION_TOKEN_FILE)`, then
    `validate_secondary_registration_token()` — resolves and validates the
    token (non-empty, non-placeholder) alongside the other durable `/data`
    secrets, running only *after* `connect_nats_with_retry` (step 8) and
    `load_or_create_session_secret` (step 9), not inside the preflight gate in
    step 3.
11. Issuer keypair resolution: `NATS_ISSUER_SEED` (literal seed, env var)
    takes precedence over `nats_auth_callout::load_or_create_issuer_keypair
    (nats_issuer_seed_path)` (file-based, default
    `/data/lancache-nats-issuer.seed`). The literal-seed path exists *only*
    for the full-setup validation harness (no persistent `/data` volume, needs
    a deterministic pre-known keypair) — not used in dev/prod.
12. SQLite open at `/data/lancache-ui.db`, `CREATE TABLE IF NOT EXISTS
    secondaries (name PK, nats_token, consumer_name UNIQUE, registered_at,
    last_seen)`, then `migrate_secondaries_table_for_auth_callout()` —
    additive ALTER TABLE adding `nats_user`/`nats_password_hash` (idempotent,
    checks `PRAGMA table_info` first; legacy `nats_token` column kept as
    inert dead weight rather than dropped, since SQLite `DROP COLUMN` needs a
    table rebuild).
13. Build `AppState`, then `routes::secondaries::reload_nats_conf(&state)`
    (best-effort, only `tracing::warn!`s on failure — writes the initial
    `auth_callout.conf` fragment; deep-dive is the other agent's scope, noted
    here only as an integration point).
14. `tokio::spawn(nats_auth_callout::run_auth_callout(state, issuer_keypair))`
    — runs for the process lifetime, no supervision beyond its own internal
    reconnect loop (see section 3).
15. Router assembly (public vs. protected — see below), `security_headers`
    middleware applied to the whole merged router, bind `0.0.0.0:8080`.

**Public routes** (no Basic Auth): `GET /health`, `POST /api/secondary/register`
(gated by its own token, not session auth), `GET /favicon.ico`,
`GET /static/logo-icon.png`. The doc comment explains *why* the two static
assets are public rather than behind `basic_auth`: serving brand assets
through the protected router would attach a session-issuing `Set-Cookie` to a
response already marked publicly cacheable, letting a shared cache replay one
client's session cookie to another (flagged on PR #553's review) — the
browser's own Basic Auth prompt still gates the origin regardless.

**Protected routes** (behind `basic_auth` middleware, ~30 routes): `/`,
`/dhcp` + 12 DHCP mutation endpoints (mode, proxy, 3 subnet CRUD, 2 subnet
option CRUD, 2 static-reservation CRUD, lease release, snapshot rollback, and
`/api/dhcp/check`), `/domains` + 5 mutation endpoints (DNS add/remove, LAN
add/remove, `/domains/aaaa-filter` toggle) + zone rollback,
`/stats`, `/logs`, `/setup` + update, `/api/metrics`, `/api/netdata/{*path}`,
static CSS/JS, `/secondaries`, secondary delete/rotate. (Handler bodies for
dhcp/domains/logs/secondaries/setup/stats/dashboard/netdata_proxy/
dns_snapshots are the other agent's scope.)

**`health()`** — literal `"ok"`, no NATS/Docker/DNS reachability check.
Explicitly documented as intentionally *shallow*: mirrors the proxy service's
unauthenticated `/healthz`. This is the exact endpoint
`scripts/ui-reachability-crash-loop-simulation.sh` polls to prove the Admin UI
answers HTTP while `proxy` is crash-looping (issue #763's requirement) — see
section 11.

**Security middleware**:
- `security_headers` — CSP (`ADMIN_UI_CSP` const: `default-src 'self'` +
  `unsafe-inline` on script/style-src only, documented as a deliberate,
  narrow exception since templates use inline `onclick=`/`<style>` rather
  than nonces), `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`,
  `Referrer-Policy: no-referrer`, conditional HSTS via
  `state.config.hsts_mode.should_send(is_https)`. Entirely skippable via
  `UI_SECURITY_HEADERS=false` (`security_headers_enabled`).
- `basic_auth` — re-checks Basic Auth on *every* request when configured,
  **independent of the session cookie** (the cookie only ever carries CSRF
  state, never authentication — explicitly tested:
  `a_valid_session_cookie_never_substitutes_for_required_basic_auth`).
  Constant-time comparison via SHA-256-then-`ct_eq` (`basic_auth_is_valid`) to
  avoid both a timing side channel on raw byte comparison *and* the
  length-leak `subtle`'s `ct_eq` has on mismatched-length slices. Issues/
  validates the session cookie, sets the internal
  `x-lancache-ui-csrf-token` header for downstream handlers, and — for
  mutating methods (POST/PUT/PATCH/DELETE) — buffers the body (max 1 MiB,
  `MAX_CSRF_BODY_BYTES`) to check the CSRF token from either the
  `X-CSRF-Token` header or the `csrf_token` form field.
- `secondary_registration_token_is_placeholder()` — pattern-matches 6 forms
  of "still a checked-in default" (empty, `CHANGE_ME_*`, `YOUR_*_HERE`,
  `changeme*`, `*change-me*`, `lancache-*-secret`, `<...>`), specifically
  added (per the doc comment) because an earlier exact-literal check missed
  `deploy/quickstart/.env`'s distinct placeholder, and README.md's own
  code-block example is itself pasteable verbatim.

**Tests in `main.rs`** (19 total: 15 `#[test]` functions, all `#[cfg(test)]`,
plus 4 `#[tokio::test]` async integration tests — all 19 **are** compiled and
run automatically in CI via the `ui_test` job, see section 11; the 15/4 split
was previously collapsed into a single "15" figure here, undercounting the
async tests since this document's counting methodology (line ~20,
`grep -c '#\[test\]'`) doesn't match `#[tokio::test]`): migration idempotence
(2 tests), `x-forwarded-proto` HTTPS detection, CSP self-hosted-only
assertion, Basic Auth accept/reject, session-cookie-never-substitutes-for-auth,
insecure-mode opt-in gate, placeholder-token rejection (now case-insensitive
with hyphen/underscore normalization, plus a cross-implementation
parity-fixture test — #988), TTL bounds, startup preflight ordering, template
function rendering, session/CSRF header helper — plus the 4 `#[tokio::test]`
full-chain Basic Auth middleware integration tests added by #951 (lines 1592,
1619, 1644, 1685 as of this currency check), which exercise the real Axum
router/middleware stack end-to-end rather than a unit-level assertion.

---

## 2. `config.rs` (2133 lines, 40 tests) — env-driven runtime config

`Config::from_env()` reads **~55 distinct env vars** into a typed struct
(full field list below is exhaustive from the struct definition). Two custom
enums: `HstsMode` (`Auto`/`Always`/`Never`, `should_send(is_https)`) and
`DhcpMode` (`Disabled`/`Kea`/`DnsmasqProxy`, mutually exclusive since both
bind DHCP :67/udp).

**Every env var read** (grouped):
- Proxy/cache: `PROXY_SERVICE`, `STANDARD_LOG`, `SSL_LOG`, `CACHE_DIR` (+
  legacy `STANDARD_CACHE_MAX_GB`/`SSL_CACHE_MAX_GB` fallback, hard-panics if
  the two legacy values *disagree* and `CACHE_MAX_GB` is unset —
  `mismatched_legacy_cache_limits_fail_closed` test), `PROXY_STANDARD_URL`,
  `PROXY_SSL_URL`, `PROXY_SSL_SERVICE`, `SSL_ENABLED`, `CACHE_MAX_GB`,
  `STANDARD_IP`, `SSL_IP`.
- DNS state/services: `DNS_STANDARD_STATE_DIR`, `DNS_SSL_STATE_DIR`,
  `DNS_STANDARD_SERVICE`, `DNS_SSL_SERVICE`, `NETDATA_URL`, `PDNS_AUTH_URL`,
  `PDNS_REC_URL`, `DNS_ROLLBACK_URL` (dns-standard only — dns-ssl rollback is
  explicitly out of scope for now, per a comment pointing at
  `routes/dns_snapshots.rs`), `PDNS_API_KEY`, `CDN_DOMAINS_FILE`.
- DHCP: `DHCP_MODE` (+ legacy `DHCP_ENABLED` bool, only honored when
  `DHCP_MODE` is unset), `DHCP_API_URL`, `DHCP_API_TOKEN`,
  `DHCP_DNS_PRIMARY`/`SECONDARY`, `DHCP_NTP_SERVERS`, `DHCP_SUBNET_START`,
  `UPSTREAM_DHCP_IP`, `DHCP_PROXY_INTERFACE`/`ROUTER`/`DOMAIN`/
  `BOOT_FILENAME`/`BOOT_SERVER`/`CUSTOM_OPTIONS` (issue #450),
  `KEA_CONFIG_SNAPSHOT_DIR`, `KEEP_KNOWN_GOOD_CONFIGS` (clamped ≥1, silently
  defaults on invalid input — deliberately lenient, mirrors
  `scripts/lib/known-good-snapshots.sh`).
- Auth/session: `UI_AUTH_USER`, `UI_AUTH_PASSWORD`, `ALLOW_INSECURE_UI`,
  `UI_SESSION_TTL_SECONDS` (rejects non-numeric *and* >1 year),
  `UI_SECURITY_HEADERS`, `UI_HSTS_MODE`.
- NATS (4 static roles, each username+password): `NATS_URL`,
  `NATS_UI_USER`/`PASSWORD`, `NATS_DNS_WRITER_USER`/`PASSWORD`,
  `NATS_DNS_REPLICA_USER`/`PASSWORD` (renamed from `nats_dns_reader_*` under
  #583 — a fixed static credential is fine here because there's always
  exactly one co-located dns-ssl instance, unlike external secondaries),
  `NATS_CALLOUT_USER`/`PASSWORD` (the auth-callout responder's own bypass
  identity), `NATS_ISSUER_SEED_PATH`, `NATS_ISSUER_SEED` (literal override),
  `NATS_CONF_PATH`, `NATS_AUTH_CALLOUT_PATH` (must match the nats
  entrypoint's `include` target — issue #811), `NATS_SERVICE`,
  `NATS_LOG_FILE`, `NATS_BIND_IP` (mirrors the Compose port `HOST` field this
  container listens on), `NATS_ADVERTISE_URL` (explicit override for the
  externally-reachable NATS URL; both feed `advertised_nats_url()`, which a
  remote secondary's registration flow depends on — see issue #866 and
  `routes/secondaries.rs`).
- Secondary registration: `SECONDARY_REGISTRATION_TOKEN`.
- Release/update: `LANCACHE_IMAGE_REGISTRY`, `LANCACHE_IMAGE_PREFIX`,
  `LANCACHE_IMAGE_CHANNEL` (auto-derived from tag via
  `derive_lancache_image_channel` if unset — `dev`/`nightly`/`latest` pass
  through, `v*`/`sha-*` → `pinned`, else `latest`; the old `edge` name was
  hard-cut in v0.3.0 (#1056) and now falls through to `latest`),
  `LANCACHE_IMAGE_TAG`,
  `AUTO_UPDATE_ENABLED` (#819 — this field is a *display mirror* only; the
  actual effective toggle for the host systemd timer goes through
  `ui_settings_file`, since this container can't flip a host-level timer
  synchronously).
- Misc: `TEMPLATE_DIR`, `UI_SETTINGS_FILE`, `LANCACHE_DEV_MODE`,
  `UI_LOGS_MAX_ENTRIES` (caps how many lines `routes/logs.rs` returns per
  request), `SYSLOG_ENABLED`, `SYSLOG_LOG_ROOT`, `SYSLOG_MAX_GB`,
  `SYSLOG_RETENTION_DAYS` (#633/#757 — display/reporting only, the UI never
  enforces the budget, `watchdog.sh` does).

**`fmt::Debug` impl**: hand-written, redacts every secret field
(`dhcp_api_token`, `auth_user`/`password`, `pdns_api_key`, all 4 NATS
passwords, `nats_issuer_seed`, `secondary_registration_token`) as
`***REDACTED***` or presence-only — a stray `{:?}` in a log line can't leak a
credential. `fmt::Display` is a stub (`{ template_dir, cdn_domains_file, ... }`
literal ellipsis, not real formatting) — technically present but functionally
decorative; nothing in the codebase appears to rely on `Display` for `Config`
(`Debug` is what tracing/panic machinery would reach for) — worth flagging as
a candidate "defined but not really used" item, though not a bug (harmless if
never called with real intent to show all fields).

**Two-layer effective-config pattern**: 10 `effective_*` getters (DHCP mode,
DNS primary/secondary, NTP, subnet start, upstream DHCP IP, 6 dnsmasq-proxy
optional fields, image channel override, auto-update-enabled) each check
`ui_settings_file` (default `/data/lancache-ui-settings.env`, a plain
unescaped `KEY=value` line format, first-match-wins, no full env-file parser)
before falling back to the env-var value captured at process start.
`ui_override_lines()` renders only the 12 DHCP-related effective values
(`DHCP_MODE` + the 11 optional subnet/DNS/NTP/proxy fields) back into that
same line format (omitting empty values so a cleared override reverts to the
env default rather than pinning `""`) — it does **not** write
`lancache_image_channel`/`auto_update_enabled`. Those two are instead
persisted by a separate function, `routes/dhcp.rs`'s
`persist_stack_settings()` (called from `routes/setup.rs`'s
`update_stack_settings`), which writes the full 14-key set — the same 12
DHCP-related keys plus `LANCACHE_IMAGE_CHANNEL`/`AUTO_UPDATE_ENABLED` — through
the shared `write_ui_settings_file()` helper so there is exactly one
authoritative whitelist for the settings file's contents even though two
different call sites populate it. This is how DHCP-mode/settings changes
take effect from the Admin UI without a container restart — but two of these
(`lancache_image_channel`/`auto_update_enabled`, #819) explicitly do **not**
take effect inside this container at all; they're polled by `setup.sh`'s
host-side `lancache-converge.service` on its next 5-minute tick.

**Tests**: 40 `#[test]` functions, all gated behind a shared `env_test_lock()`
mutex (since `cargo test` runs in parallel threads and `std::env::set_var` is
process-global) — a genuinely careful pattern; these run automatically in CI
via the `ui_test` job (section 11), not a gap. The increase from the
original 24 is mostly new NATS-URL-reachability and syslog-parsing-parity
coverage added by #881/#877/#828 since this document was first written.

---

## 3. `nats_auth_callout.rs` (718 lines, 15 tests) — per-secondary NATS identity (issue #583, per #433's decision)

This is the module with the most novel/bespoke cryptographic code in the
whole service — worth the most scrutiny.

**Mechanism** (from the extensive module doc comment, independently
cross-checked against the code): the flat `authorization { users = [...] }`
block in `nats.conf` gains one more static user (this process's own
callout-bypass identity, `nats_callout_user`/`nats_callout_password`) plus an
`auth_callout {...}` sub-block whose `auth_users` list must name *every*
static username (UI, DNS-writer, DNS-replica, callout-bypass) — not just the
callout responder's own. This is called out as counterintuitive and easy to
get wrong (confirmed against a real nats-server 2.14.3): a username absent
from `auth_users` gets routed through the callout even if it happens to match
a static `users` entry. No `accounts {}` block exists; everyone (UI/DNS-
writer/DNS-replica/every secondary) lives in the implicit default account
`$G`.

**Public functions**:
- `encode_nats_jwt(claims: Value, signer: &KeyPair) -> Result<String, String>`
  — hand-rolled compact NATS JWT v2 encoder (no mature Rust crate covers the
  `AuthorizationRequest`/`AuthorizationResponse` envelope). Fixed header
  `{"typ":"JWT","alg":"ed25519-nkey"}`, computes `jti` via `compute_jti`
  (base32-nopad of SHA-512/256 over the claims-with-empty-jti), signs
  `base64url(header).base64url(payload)` with Ed25519 via the `nkeys` crate.
- `decode_jwt_payload(token: &str) -> Result<Value, String>` — decodes (does
  **not** verify) the payload of any 3-part dot-separated JWT.
- `load_or_create_issuer_keypair(path: &str) -> Result<KeyPair, String>` —
  same create_new+0600 persistence pattern as `main.rs`'s session secret.
  This keypair signs every per-secondary user JWT ever issued; its seed
  never leaves the file.
- `hash_nats_password(password: &str) -> String` — plain unsalted SHA-256
  hex. Explicitly justified as safe *because* passwords are always 32-byte
  CSPRNG output (never user-chosen), so salting adds nothing against
  precomputed tables a fixed random value already defeats — issue #680
  (open) tracks upgrading this to Argon2id anyway (defense-in-depth /
  consistency with password-hashing best practice generally, not because the
  current justification is wrong).
- `secondary_permissions() -> Value` — the fixed subject-level ACL every
  secondary gets: pub `$JS.API.STREAM.INFO.LANCACHE_DNS`,
  `$JS.API.CONSUMER.INFO.LANCACHE_DNS.>`,
  `$JS.API.CONSUMER.CREATE.LANCACHE_DNS.>`,
  `$JS.API.CONSUMER.DURABLE.CREATE.LANCACHE_DNS.>`,
  `$JS.API.CONSUMER.MSG.NEXT.LANCACHE_DNS.>`, `$JS.ACK.LANCACHE_DNS.>`; sub
  `lancache.dns.>`, `_INBOX.>`. (Enumerated explicitly rather than as a
  `$JS.API.CONSUMER.*.LANCACHE_DNS.>` wildcard — that shorthand would make
  the granted ACL look broader than what's actually enforced, since it would
  also read as covering `CONSUMER.DELETE`/`CONSUMER.LIST`/`CONSUMER.PAUSE`
  and other verbs the four listed subjects do not grant.) Test
  `secondary_permissions_scope_matches_dns_reader_role` explicitly asserts
  secondaries can **never** publish to `lancache.dns.record` (only the
  DNS-writer role may).
- `run_auth_callout(state: Arc<AppState>, issuer: Arc<KeyPair>)` — the
  long-running responder loop `main.rs` spawns once, unsupervised beyond its
  own internal reconnect (1s→30s exponential backoff, mirrors
  `connect_nats_with_retry`). Connects as `nats_callout_user`, subscribes to
  `$SYS.REQ.USER.AUTH`, and for every request: decodes the JWT payload,
  extracts `user_nkey`/`server_id`/`connect_opts.user`/`connect_opts.pass`,
  calls `authorize_secondary`, builds and publishes a signed response.

**Private/internal**: `authorize_secondary` (DB lock + delegate) /
`authorize_secondary_with_conn` (the actual query: `SELECT
nats_password_hash FROM secondaries WHERE nats_user = ?1`, constant-time-
compares against `hash_nats_password(presented)`) — deliberately
indistinguishable outcome for "never registered" vs. "wrong password".
`build_response` constructs the signed `AuthorizationResponse` JWT, success
case embedding a nested signed user JWT with `aud: "$G"` (the module doc
calls out, with real operational detail, that nats-server rejects an
omitted/mismatched `aud` with a *misleadingly-fine-looking* log line even
though the outer envelope verifies correctly — this exact regression is
guarded by `build_response_success_contains_signed_user_jwt`'s explicit
`aud` assertion).

**Revocation property**: no caching anywhere in this path — every single
connection attempt re-queries the `secondaries` table, so `DELETE`/rotate
takes effect on the very next reconnect with zero effect on any other
secondary. This is the core property #583 was built to deliver, and it is
the single most thoroughly tested behavior in the file (4 dedicated tests:
accept/reject correct-vs-wrong password, unknown user, removal-revokes-
only-that-one, rotation-invalidates-old-only).

**Documented, deliberately deferred hardening** (module doc's own "Deferred
hardening" section, cross-referenced against currently open issues — all
four map to real, still-open tickets, i.e. these aren't stale claims):
- `xkey` (curve25519 sealed-box encryption of the `$SYS.REQ.USER.AUTH` round
  trip) — **issue #682** (open).
- Incoming `AuthorizationRequest`'s own nats-server signature is never
  verified — folded into **issue #839** (open, "Argon2id, active disconnect,
  xkey encryption").
- Active disconnect of an already-established connection on
  removal/rotation (revocation currently only blocks the *next* reconnect,
  not an already-open session) — **issue #681** (open).
- SHA-256→Argon2id password hashing — **issue #680** (open).

**Legacy interop**: `main.rs::migrate_secondaries_table_for_auth_callout`
leaves pre-#583 rows with `NULL nats_user`/`nats_password_hash`;
`authorize_secondary_with_conn`'s `SELECT ... WHERE nats_user = ?1`
naturally returns no row for those, so a legacy secondary is denied (not
panicked, not silently authorized) until re-registered/rotated — tested
(`legacy_pre_583_row_with_null_auth_callout_columns_is_denied`) and
documented in CHANGELOG.md as a required manual step post-upgrade per the
module's own comment.

**Tests**: 15 `#[test]` functions covering JWT round-trip/header
shape/signature verify/tamper-rejection, malformed-token rejection, password
hash determinism, permission-scope assertion, response-building
(success+failure), and issuer-keypair persistence-across-reload.

**Integration points into the other agent's scope**: this module calls into
`routes::secondaries::{reload_nats_conf, register_secondary,
remove_secondary, rotate_token}` (via `main.rs`'s wiring, not directly) —
noted here only as a handoff boundary, not analyzed.

---

## 4. `nats_config.rs` (377 lines, 27 tests) — NATS credential syntax validation

Small, focused, and fully unit-tested — the highest test-to-code-line ratio
of any file in this pass.

- `validate_nats_username(username: &str) -> Result<(), String>` —
  non-empty, no control chars (ASCII <32 or 127/DEL), restricted to
  `[A-Za-z0-9_.-]` (rejects spaces, quotes, unicode, every NATS-config-
  syntax-breaking metacharacter).
- `validate_nats_password(password: &str) -> Result<(), String>` —
  non-empty, no control chars, no `"`, no `\`. **Single quotes are
  explicitly allowed** (documented reasoning: generated config always
  double-quotes string values, so `'` is inert data, not a terminator) — a
  deliberately narrower restriction than the username validator, and
  unicode is explicitly allowed in passwords (tested:
  `unicode_in_password_allowed`, `pässwörd`/`密码`) vs. explicitly rejected
  in usernames (`unicode_in_username_rejected`).
- `validate_nats_credentials(username, password) -> Result<(), String>` —
  convenience wrapper, fails fast on username first.
- `validate_optional_nats_credentials(label, username, password:
  Option<&str>)` — rejects `None` before ever calling the string validator (a
  deliberate choice per its own comment: materializing `""` as a fallback
  right at the call site would put a hard-coded-looking literal into a
  password-shaped dataflow again).
- `validate_runtime_nats_credentials(config: &Config) -> Result<(), String>`
  — the function `main.rs`'s `preflight_startup_config` actually calls;
  validates all 4 static NATS roles (UI, DNS-writer, DNS-replica, auth-
  callout) in sequence, fails on the first bad one.

This is defense-in-depth, not the primary defense — `setup.sh` generates
these as random hex, so in the overwhelmingly common path this validator
never rejects anything real; it exists to catch environment-provided
overrides that would otherwise corrupt the generated `nats.conf` string
interpolation or silently break startup with a confusing NATS-side parse
error instead of a clear one here.

---

## 5. `session.rs` (228 lines, 3 tests) — per-session CSRF cookie issuance/validation

Small, self-contained, hand-rolled HMAC — **no external HMAC crate
dependency**, `hmac_sha256()` is implemented directly (standard RFC 2104
construction: 64-byte key block, 0x36/0x5c pads, double SHA-256). Worth
noting as a place where "hand-rolled crypto" is a real (if small and
well-tested) risk surface, same category as `nats_auth_callout.rs`'s JWT
implementation.

- Cookie format: `v1.{expires_at_unix}.{csrf_token_hex}.{hmac_hex}`,
  `SameSite=Strict; HttpOnly` (+ `Secure` when the request arrived over
  HTTPS, via `forwarded_proto_is_https`).
- `issue_session`/`issue_session_at` — generates a fresh random 32-byte CSRF
  token, builds and signs the cookie.
- `validate_session_cookie` — parses exactly 4 dot-separated parts (rejects
  extra/missing parts), checks expiry against `now`, recomputes and
  constant-time-compares the signature.
- `token_matches` — constant-time CSRF token comparison, used by
  `main.rs::basic_auth` for the actual CSRF check on mutating requests.
- Explicitly documented as **never used for authentication** — only for
  binding one CSRF token to one browser session; see `main.rs`'s
  `requires_basic_auth_rejection` for why Basic Auth is re-checked on every
  request independent of this cookie's validity.

**Tests**: 3 tests (issue produces unique tokens/cookies, tamper+expiry
rejection, csrf-token-requires-matching-session).

---

## 6. `docker_client.rs` (86 lines, 0 tests) — Docker API wrapper, deliberately narrow

The entire Docker surface this service can reach is **restart/start/stop by
a fixed allowlisted name** — no exec, no arbitrary container list/create/
remove.

- `connect_from_env() -> Result<Docker>` — precedence: `DOCKER_PROXY_URL`
  (if set and non-empty) → `DOCKER_HOST` (only honored if `tcp://`-prefixed)
  → `Docker::connect_with_socket_defaults()` (the raw Docker socket,
  presumably mounted read-write in dev but intended to go through
  `docker-socket-proxy` in prod per the architecture).
- `restart_service`/`start_service`/`stop_service_if_present` — all resolve
  through `container_name_for_service` first, so an arbitrary string can
  never reach bollard's API.
- `container_name_for_service(service_name: &str) -> Result<&'static str>`
  — the actual allowlist: `proxy`/`lancache-proxy`,
  `dns-standard`/`lancache-dns-standard`, `dns-ssl`/`lancache-dns-ssl`,
  `dhcp`/`lancache-dhcp`, `dhcp-proxy`/`lancache-dhcp-proxy`,
  `dhcp-probe`/`lancache-dhcp-probe`, `nats`/`lancache-nats` — anything
  else is rejected with a named error, not silently ignored.
- `stop_service_if_present` specifically swallows `304 Not Modified`/`404
  Not Found` from bollard as success (idempotent stop of an already-stopped/
  nonexistent container), everything else propagates as a real error.

**No `#[cfg(test)]` module in this file at all** — zero unit tests. Given the
file is a thin wrapper whose real behavior only manifests against a live
Docker daemon, this is defensible (there's little to unit-test besides the
allowlist match logic, which *could* trivially be tested but isn't) —
flagging as a small, concrete gap: `container_name_for_service`'s match arms
are pure and 100% unit-testable with zero mocking, and currently aren't.

---

## 7. `nginx_client.rs` (656 lines, 8 tests) — nginx stub_status + access-log reader

Sibling client wrapper to `docker_client.rs` (both live directly under
`services/ui/src/`, both consumed by dashboard/logs/stats routes rather than
being routes themselves).

- `NginxStatus` (`Serialize`, `Default`, `Clone`): `active`, `accepts`,
  `handled`, `requests`, `reading`, `writing`, `waiting`.
- `get_stub_status(client: &reqwest::Client, base_url: &str) ->
  Option<NginxStatus>` — GETs `{base_url}/nginx_status` (nginx's
  `stub_status` module output) with a 3s timeout, parses via
  `parse_stub_status`.
- `parse_stub_status(text: &str) -> Option<NginxStatus>` — parses nginx's
  fixed 4-line `stub_status` text format; per-field parse failures default
  to `0` rather than aborting the whole parse (`unwrap_or(0)` on each field).
- `LogEntry`/`LogStats` (both `Serialize`): structured representations of one
  parsed access-log line, and aggregate hit/miss/expired/other + byte/percent
  stats across one or more log files.
- `parse_log_tail(path: &str, limit: usize) -> Vec<LogEntry>` — returns the
  last `limit` **complete** lines of a (potentially multi-GB) access log
  without a full linear scan, via `read_last_lines`'s backward-chunked read
  (`TAIL_CHUNK_SIZE = 64 KiB`). Oldest-first within the tail window; callers
  (`routes/logs.rs`) reverse for newest-first display — this ordering
  contract is explicitly documented and load-bearing (double-reversing would
  silently corrupt display order).
- `read_last_lines(file: &mut File, limit: usize) -> Vec<String>` — the
  actual backward-seek algorithm: seeks to EOF, pulls `TAIL_CHUNK_SIZE`
  chunks backward until strictly more than `limit` newlines have been seen
  (the "strictly more, not >=" margin is explicitly commented as
  intentional, avoiding an off-by-one short result from a chunk boundary
  discard), then reconstructs complete lines from the accumulated buffer,
  discarding a possibly-truncated leading segment unless byte 0 was reached.
  Heavily tested (see below) including a dedicated test that engineers a
  line straddling the exact chunk boundary and asserts byte-for-byte
  reconstruction.
- `bytes_to_line(bytes: &[u8]) -> String` — strips a trailing `\r` (CRLF
  logs), uses lossy UTF-8 conversion so one malformed byte sequence anywhere
  in the tail cannot panic or truncate every subsequent line (a real,
  previously-fixed bug class per the code comments referencing issues
  #657/#663).
- `get_log_stats(standard_log: &str, ssl_log: &str) -> LogStats` —
  aggregates hit/miss/expired/other counts and total bytes across both log
  paths, de-duplicating when `standard_log == ssl_log` (the v0.2.0 shared-
  cache model routes both modes through one cache but still writes separate
  logs by default). Iterates `reader.lines()` handling each line's `Result`
  explicitly (not `map_while(Result::ok)`, which would silently stop the
  whole scan at the first invalid-UTF-8 line — a real fixed bug, tested by
  `bad_line_in_middle_does_not_truncate_stats`).
- `get_cache_size_gb(path: &str) -> f64` — shells out to `du -sb`
  (deliberately not a Rust directory walk — `du` is the right tool for
  potentially hundreds-of-GB directories), gated by an explicit path
  allowlist (`/opt/lancache-ng/cache`, `/var/cache/proxy`, `/data/lancache`)
  plus rejection of any path containing `..` or a non-absolute path — a
  real path-traversal guard, not just a comment. Blocking; callers
  (`routes/dashboard.rs`) must run it inside `tokio::task::spawn_blocking`.
- `unique_paths`, `log_regex()`/`stub_status_regex()` (both lazily
  compiled via `OnceLock`), `parse_log_line`, `format_bytes` — internal
  helpers.

**Log format coupling**: `log_regex()`'s 8 capture groups are positionally
matched against nginx's custom `log_format` directive in
`services/proxy/nginx.conf` — the doc comment explicitly flags that the
group count/order here and that directive must stay in sync; there is no
automated check tying the two together (a real, if narrow, coupling risk —
a future nginx.conf log_format edit could silently desync this regex without
either side failing loudly, only the numbers being wrong on the `/logs`
page).

**Tests**: 8 `#[test]` functions — shared-log-path dedup, bad-line-mid-file
resilience, missing-file-returns-empty, empty-file, smaller-than-chunk full
read, missing-trailing-newline handling, correct-last-N-lines-with-content-
and-order (not just count), and the chunk-boundary-split-line reconstruction
test.

---

## 8. `syslog_client.rs` (1046 lines, 18 tests) — central syslog-ng store reader

Sibling to `nginx_client.rs` per its own doc comment ("not a patch to it: the
two log formats are unrelated"). Part of the #633 central-logging-pipeline
work (PR2/#756 extended which services feed it, PR3/#757 added storage-
budget pruning — that pruning itself lives in `watchdog.sh`, not here).

- Layout contract: `<SYSLOG_LOG_ROOT>/<host>/<YYYYMMDD>.log` (active),
  `...log.<rotated-ts>` (just rotated), `...log.<rotated-ts>.zst|.gz`
  (compressed — zstd by default, gzip fallback if zstd couldn't be
  installed at container start with no network egress). Every reader here
  must transparently handle all three forms.
- `list_syslog_hosts(log_root) -> Vec<String>` — sorted list of host
  directory names under the syslog root (empty if the root is missing).
  Called from `routes/logs.rs` for two purposes on every `/logs` render in
  syslog mode: populating the host-filter dropdown, and allowlisting the
  caller-controlled `?host=` query parameter before it reaches
  `parse_syslog_tail` — an unrecognized/typo'd host falls back to "all
  hosts" instead of a confusing empty result, and `parse_syslog_tail`'s own
  `is_safe_host_component` check is a second, defensive layer rather than
  the sole gate. This is the actual host-enumeration/allowlist control for
  that query surface, not just a test-covered utility.
- `SyslogEntry`/`SyslogHostStats`/`SyslogStats` (all `Serialize`) — parsed
  entry, per-host file/size/distinct-day aggregate, and store-wide totals.
  `SyslogHostStats` deliberately has **no line-count field** — removed per
  #758 review because counting non-empty lines would require decompressing
  every `.zst`/`.gz` file on every dashboard render with no caching or
  upper bound, turning a routine page load into a full-store decompress
  scan on an install with GBs of retained history.
- `parse_syslog_tail(log_root, host: Option<&str>, limit) -> Vec<SyslogEntry>`
  — same oldest-first-in-tail-window ordering contract as
  `nginx_client::parse_log_tail`, but a fundamentally different algorithm
  since compressed streams have no random byte-seek access: lists candidate
  files, sorts newest-mtime-first, decodes whole files starting from the
  newest until `limit` lines are collected. Now takes an optional `host`
  filter (`?host=` on `/logs` in syslog mode, #865/#848) restricted to a
  single bare directory-name segment (`is_safe_host_component`) — rejects
  anything else outright rather than trusting `routes/logs.rs` to have
  pre-validated against `list_syslog_hosts()`, since `host` can come straight
  from an HTTP query parameter. **Multi-host starvation guard, corrected
  twice**: the original #758 fix only guaranteed every host directory with
  candidate files gets at least one file *opened* before the file-listing
  loop's early break fires — it did not stop a later global sort-by-
  timestamp-then-truncate-to-`limit` step from still fully evicting a quiet
  host's lines once a noisier host produced enough newer lines to fill the
  whole budget on its own (issue #859). **#861 replaced that global
  sort+truncate with a per-host floor merge**: `PER_HOST_FLOOR = 10`, and
  each host with data is round-robin-guaranteed
  `(limit / hosts_with_data).clamp(1, PER_HOST_FLOOR)` of its own most recent
  lines first, with any remaining budget filled from the globally most
  recent leftover lines — a quiet host (e.g. watchdog's handful of startup
  lines) can no longer be fully starved by a high-volume host (e.g.
  netdata), while a genuinely more-recent/active host still dominates the
  fill-in pass when it isn't competing for the guaranteed floor.
- `get_syslog_stats(log_root) -> SyslogStats` — metadata-only aggregation
  (`fs::read_dir` + `Metadata::len()`, no file content read at all) across
  every file under the root; deliberately not a bounded tail read like
  `parse_syslog_tail` — always visits every file, but never decompresses
  any of them.
- `get_syslog_size_gb(path) -> f64` — mirrors `nginx_client::
  get_cache_size_gb`'s allowlist-then-`du` shape, but with a
  **single-entry** allowlist (`/var/log/lancache-syslog-ng`) rather than
  `get_cache_size_gb`'s multi-entry one — explicitly documented as correct,
  not an oversight: the syslog mount path is fixed across every deploy
  variant, unlike `CACHE_DIR` which legitimately varies.
- `read_file_transparent(path) -> Option<String>` — whole-file read (not
  streaming) + transparent `.zst`/`.gz` decompression by extension, lossy
  UTF-8 conversion (same malformed-byte-sequence resilience as
  `nginx_client`'s equivalent fix, applied to a different format).
- `parse_syslog_line(host_name, line) -> Option<SyslogEntry>` — parses
  syslog-ng's `d_lancache` destination template (`$ISODATE $HOST $PROGRAM:
  $MSGONLY`); a line that doesn't match the shape is **kept** with the raw
  text in `message` rather than dropped (same "never truncate/drop on a
  parse miss" principle as `nginx_client`'s #663 fix).
- `extract_day(path) -> Option<String>` — pulls the `YYYYMMDD` prefix from a
  filename for the per-host distinct-day count; returns `None` (not a
  guess) for anything not exactly 8 ASCII digits.

**Tests**: 18 `#[test]` functions — plain-text tail-in-order, zst
transparent decompress, gz transparent decompress, multi-host
interleave-by-timestamp, four #758 starvation-guard regression tests
(newest-file-alone-satisfies-limit doesn't starve other hosts, a quiet host
isn't starved at the final merge step, high-volume activity dominates when
uncontested, recent activity wins the shared budget across multiple active
hosts), limit-respecting/most-recent-kept, unparseable-lines-kept-not-dropped,
path-traversal-rejected, missing-root-returns-empty, stats aggregation across
mixed plain/rotated files, compressed-files-counted-by-metadata-only (a second
#758-review regression test), stats-on-missing-root, two `list_syslog_hosts`
tests (sorted host directory names, empty for a missing root), and
syslog-allowlist rejection (mirrors `nginx_client`'s path-traversal guard
tests).

---

## 9. `routes/mod.rs` (160 lines, 4 tests) — shared route helpers (not a feature route itself)

- `render(templates, name, ctx, dev_mode) -> Html<String>` — on a Tera
  render failure, `dev_mode=true` (`LANCACHE_DEV_MODE=true`, `config.dev_mode`)
  returns the raw template name + Tera error inline in the response body;
  `dev_mode=false` returns a fixed generic "Template Rendering Failed"
  message with **zero** of the real error/template name leaked to the client
  (tested: `render_error_returns_generic_message_in_prod_mode` explicitly
  asserts the template name and error text are both absent). This is the
  one place in the core surface where a config flag (`LANCACHE_DEV_MODE`)
  directly controls information disclosure to an already-authenticated (or,
  if `ALLOW_INSECURE_UI=true`, *unauthenticated*) client — worth being
  deliberate that `LANCACHE_DEV_MODE` is never accidentally left `true` in a
  prod deployment; nothing in this file itself enforces that, it's purely an
  operator/deploy-tooling responsibility.
- `insert_csrf_token(ctx, headers)` — pulls the CSRF token `basic_auth`
  middleware attached to the internal header and inserts it into the Tera
  context for every protected page render.
- `verify_csrf_token(headers, token) -> Result<(), StatusCode>` /
  `verify_csrf_header(headers) -> Result<(), StatusCode>` — two
  near-duplicate CSRF-verification helpers: the former compares against an
  explicit `token: &str` parameter (used where a route already extracted a
  token some other way), the latter reads `x-csrf-token` from headers
  itself. Both constant-time compare via `subtle::ConstantTimeEq`. This is a
  minor duplication worth flagging (two functions doing the same
  constant-time-compare-against-the-session-token check with slightly
  different call conventions) rather than a bug — feature routes (out of
  this pass's scope) are the actual callers of both.

---

## 10. Scoping note: `kea_snapshots.rs` (407 lines, 8 tests) — NOT covered here, belongs to the DHCP-route agent

This module (Kea's known-good-config-snapshot adapter, issue #614 following
up on #415) sits directly under `services/ui/src/` like the other files in
this document, so it is technically a "top-level module, not a route file"
by the same rule this document otherwise applies. It is deliberately
**excluded from this pass's detailed analysis** and flagged explicitly here
(per this issue's own "say so explicitly rather than dropping it silently"
expectation) because every one of its public functions
(`create_snapshot`/`list_snapshot_ids`/`read_snapshot`/`prune_snapshots`/
`kgs_log`/`snapshot_created_unix`) is documented, in the module's own doc
comment, as consumed exclusively by `routes/dhcp.rs`
(`kea_config_modify`/`rollback_kea_snapshot`) — it has no caller and no
meaning outside the DHCP feature route, unlike `docker_client.rs`/
`nginx_client.rs`/`syslog_client.rs`, which are generic infra consumed by
multiple different feature routes (dashboard, logs, stats, secondaries).
The DHCP-route agent's parallel pass should cover this file; noting its
existence, line count, and test count here only so it isn't silently
missing from the overall project inventory.

Brief structural summary for handoff purposes only (not a full analysis):
snapshot IDs are fixed-width (20-digit) zero-padded nanosecond timestamps so
plain string sort equals chronological order; snapshots are written to a
`.staging.<id>` directory and atomically `rename`d into `<id>` so a
process killed mid-write never leaves a partial snapshot visible;
`prune_snapshots` deletes oldest-first beyond `KEEP_KNOWN_GOOD_CONFIGS`
(clamped ≥1, mirroring `config.rs`'s own clamp of the same env var);
`kgs_log` emits the same `[known-good-snapshot][<service>][<LEVEL>]`
greppable log vocabulary shared with the shell adapters
(`scripts/lib/known-good-snapshots.sh`) for nginx/dnsmasq/PowerDNS, but this
Rust module is explicitly **not** embedded into that shell library the way
the other three adapters are (Kea's config is mutated live via HTTP against
the Kea Control Agent, not regenerated from a shell template at container
start) — and `tests/bats/known_good_snapshots_sync.bats` deliberately does
not cover this file for that same reason.

---

## 11. Cross-cutting: is any of this actually exercised in CI?

**Two end-to-end simulation scripts were checked in full**, both real
multi-container integration tests (not mocks):

- **`scripts/nats-secondary-auth-callout-simulation.sh`** (261 lines) —
  starts `proxy`, `docker-socket-proxy`, `dns-standard`, `dns-ssl`, `nats`,
  `ui` from *published* images (not a fresh build of the PR's own code —
  same caveat issue #626 raised generally about this class of validation),
  waits for health, then: registers two secondaries via the real `POST
  /api/secondary/register`, asserts they get genuinely distinct
  `nats_user`/`nats_password`, connects each with the real `nats-subscriber`
  binary (from the `dns` image) to prove the credentials actually
  authenticate, removes one via `DELETE /api/secondary/{name}` and asserts
  its *old* credential is now rejected while the other secondary is
  completely unaffected, then rotates the survivor's credential via `POST
  .../rotate-token` and asserts old-rejected/new-accepted. This is a
  genuinely strong, real end-to-end proof of the exact property #583/#433
  asked for — not a stub.
- **`scripts/ui-reachability-crash-loop-simulation.sh`** (192 lines) —
  forces the real `proxy` service into an actual, continuous crash loop
  (`exit 1` entrypoint override, `restart: unless-stopped` unchanged) and
  proves: the Admin UI still starts and becomes `healthy`, its own
  `RestartCount` stays ≤1 (it never restarts itself reacting to an unrelated
  dependency's crash loop), and a fresh client container gets a real `200`
  from `GET /health` — all while re-confirming `proxy` is *still*
  crash-looping at the end (guards against a false-positive where proxy
  happened to recover mid-test). This is the concrete, previously-missing
  proof issue #763 called for (the module doc explicitly says the
  `depends_on` lack of `condition: service_healthy` had "never actually been
  exercised... only inferred by reading the compose file" before this
  script existed). It also explicitly documents two things it does **NOT**
  prove (own dependencies breaking the UI's own control-plane calls; a
  crash-looping DNS/DHCP service's own rollback listener staying reachable
  while *it* crash-loops) — the actual "rescue mode" gap #763 still tracks
  as deferred.

**CORRECTED after maintainer review — `cargo test` DOES run in CI.** An
earlier version of this section claimed no workflow invokes `cargo` at all.
That claim was wrong, caught directly by the maintainer against the actual
workflow file, and is retracted here rather than left standing (see revision
history at the bottom of this document for the full account).

**What actually runs, verified directly against `origin/v0.2.0`'s
`.github/workflows/build-push.yml`**:

- **`ui_test`** (job `test (ui)`) runs `cargo test --locked --manifest-path
  services/ui/Cargo.toml` via `./.github/actions/cargo-with-sccache-fallback`,
  on `[self-hosted, linux, lancache, lancache-heavy]`. **This ~134 figure is
  this document's core-file subset, not the job's full test count** — `cargo
  test` runs the *entire* crate, so it also executes every test in the
  route-handler modules this document deliberately scopes out to the other
  agent's parallel pass (per the note at the top of this section): 55 in
  `routes/dhcp.rs`, 21 in `routes/domains.rs`, and smaller counts in the
  other `routes/*.rs` files (`routes/mod.rs`'s 4 are already included below).
  The ~134 covers: `main.rs` (19: 15 plain `#[test]` plus 4 `#[tokio::test]`
  middleware integration tests added by #951), `config.rs` (40),
  `nats_auth_callout.rs` (15), `nats_config.rs` (27), `session.rs` (3),
  `docker_client.rs` (0), `nginx_client.rs` (8),
  `syslog_client.rs` (18), `routes/mod.rs` (4), plus `kea_snapshots.rs`'s own
  8 (compiled from the same crate, scoped to the other agent). (Original
  count at first writing was ~91; the growth reflects 68 commits landed on
  `v0.2.0` since, per the currency-check note at the top of this document,
  not a miscount.)
- **`dns_test`** (job `test (dns/nats-subscriber)`) runs the identical
  pattern for `services/dns/nats-subscriber/Cargo.toml`.
- Both are gated by `detect-changes` outputs (`ui`/`dns_rust`/`workflow` ==
  `true`) — deliberate, correctly-scoped path filtering ("UI tests run only
  when the UI or workflow contract changes... keeps docs/setup-only PRs from
  paying for unrelated Rust test work", per the job's own comment), **not** a
  coverage gap. `ui_rust_quality`/`dns_rust_quality` jobs (fmt/clippy) run
  upstream of the two test jobs with the same scoping, and a `rust_coverage`
  job depends on both `dns_test` and `ui_test`.
- So: the well-designed unit test suite this document catalogs (careful
  env-var test isolation via `env_test_lock()`, real crypto round-trip
  tests, real revocation-property tests, real chunk-boundary
  file-reconstruction tests, real multi-host log-merge starvation-guard
  regression tests) **is** enforced automatically on every PR that touches
  UI code or the workflow contract itself, exactly as `CONTRIBUTING.md`
  implies it should be.

**What is still a genuine, standalone finding (not retracted)**: the
`services/ui/Dockerfile` build stage itself runs `cargo build --release
--locked` only, never `cargo test` — but that's expected and correct, since
the Dockerfile builds the release binary for the running image; test
enforcement living in the CI workflow rather than the Dockerfile is the
normal, sound split. Separately, **`scripts/ui-rust-checks.sh`** (a real,
well-built local Docker-based fmt/check/clippy/test/build script, documented
in `docs/ui-rust-dev-checks.md` as letting contributors skip installing a
host Rust toolchain) is referenced by nothing in the repository except its
own doc page — confirmed by grepping the whole repo for `ui-rust-checks`,
one hit outside its own file. Since `build-push.yml` already runs the
equivalent checks natively in CI, this script is likely redundant/dead for
CI purposes specifically (it may still be a useful pre-push local dev
convenience) — a smaller, still-valid finding on its own, distinct from the
retracted "no CI test coverage" claim above.

---

## 12. Summary table: defined-but-unused / incomplete / notable findings

| Finding | File | Status |
|---|---|---|
| ~~`cargo test` never runs in any GitHub Actions workflow for `services/ui`~~ — **RETRACTED**: `build-push.yml`'s `ui_test`/`dns_test` jobs do run `cargo test` for `services/ui` and `services/dns/nats-subscriber` respectively, correctly path-scoped via `detect-changes`. See section 11. | crate-wide | **Corrected finding — was wrong, fixed after maintainer review** |
| `scripts/ui-rust-checks.sh` (a real local fmt/check/clippy/test/build script) is referenced by nothing in the repo except its own doc page — likely redundant given `build-push.yml` already runs the equivalent checks in CI | crate-wide | Still valid, smaller finding (unaffected by the retraction above) |
| `impl fmt::Display for Config` is a stub (hardcoded `"..."` ellipsis, only 2 of ~55 fields shown) — present but not meaningfully usable, and nothing appears to call it over `Debug` | `config.rs` | Defined but decorative; not a bug, just dead-ish |
| `docker_client.rs` has zero `#[cfg(test)]` coverage, despite `container_name_for_service`'s match arms being pure and trivially testable | `docker_client.rs` | Gap, low severity |
| `routes/mod.rs` has two near-duplicate CSRF-verification helpers (`verify_csrf_token` vs `verify_csrf_header`) with slightly different call conventions | `routes/mod.rs` | Minor duplication, not a bug |
| `nginx_client.rs`'s `log_regex()` capture groups are positionally coupled to `services/proxy/nginx.conf`'s `log_format` directive with no automated check tying the two together | `nginx_client.rs` | Narrow coupling risk, not currently broken |
| xkey (curve25519) encryption of the `$SYS.REQ.USER.AUTH` round trip is not implemented | `nats_auth_callout.rs` | Tracked: **#682** (open), rolled into **#839** (open) |
| Incoming `AuthorizationRequest`'s own nats-server signature is never verified | `nats_auth_callout.rs` | Tracked: **#839** (open) |
| No active disconnect of an already-established secondary connection on removal/rotation (only blocks the *next* reconnect) | `nats_auth_callout.rs` | Tracked: **#681** (open) |
| Secondary password hashing is unsalted SHA-256, not Argon2id | `nats_auth_callout.rs` | Tracked: **#680** (open) |
| Legacy pre-#583 `nats_token` column kept as permanently inert dead weight (never dropped, SQLite `DROP COLUMN` needs a table rebuild) | `main.rs` | Deliberate, documented trade-off, not a gap |
| `nats_ui_password`/etc. use `Option<String>` specifically to dodge a CodeQL `rust/hard-coded-cryptographic-value` false positive, not for a functional reason | `config.rs` | Deliberate, documented, worth knowing if CodeQL findings on this file get re-triaged later |
| `LANCACHE_DEV_MODE` directly controls whether template-render errors leak internals to the client; nothing in-process enforces it's off in prod | `routes/mod.rs` | Operator/deploy-tooling responsibility, not a code gap |
| `kea_snapshots.rs` sits in `services/ui/src/` alongside the files covered here but is exclusively a DHCP-route dependency | `kea_snapshots.rs` | Out of scope for this document by design — see section 10 |

## 13. Cross-reference against existing issues

- **#433** (closed, decision issue) → chose Option 1 ("finish the
  originally-intended design"), implemented in **#583** (closed) as exactly
  `nats_auth_callout.rs` + the `secondaries` table migration in `main.rs`.
  Confirmed: the module's own doc comments cite both issues directly and
  the decision record matches what's actually in the code.
- **#811** (closed) — "ui's NATS auth-callout permanently fails...
  lancache-nats-callout user never provisioned in nats.conf" — this is the
  counterintuitive `auth_users`-must-list-every-static-username gotcha the
  module doc now documents at length; the fix is presumably in
  `routes/secondaries.rs::update_nats_conf` (other agent's scope) but the
  *reason it was subtle* is fully explained in this module's doc comment.
- **#680, #681, #682, #839** (all open) — the four items in
  `nats_auth_callout.rs`'s own "Deferred hardening" section map 1:1 to
  these four still-open tickets; nothing here is stale or already fixed.
- **#763** (referenced by `ui-reachability-crash-loop-simulation.sh`, not
  independently re-checked for open/closed state here) — the
  Admin-UI-must-stay-reachable requirement this script proves.

---

## Revision history

- Initial pass posted as a GitHub comment on #843 (six core files +
  `routes/mod.rs`); missed three top-level `src/` modules
  (`nginx_client.rs`, `syslog_client.rs`, `kea_snapshots.rs`) and had two
  hand-counted (off-by-one) test counts.
- This document corrects both: adds sections 7–8 (nginx_client.rs,
  syslog_client.rs) and section 10 (explicit kea_snapshots.rs scoping
  note), replaces every test count with a `grep -c '#\[test\]'`-verified
  number, and adds the `scripts/ui-rust-checks.sh` finding to the CI-gap
  analysis (a real cargo-test-capable script exists but is wired to nothing
  in CI).
- **Retraction**: the headline CI-gap claim in the previous revision ("no
  GitHub Actions workflow runs `cargo test` for `services/ui`") was wrong.
  The maintainer caught it directly against `build-push.yml`'s `ui_test`/
  `dns_test` jobs (both run `cargo test`, correctly path-scoped via
  `detect-changes`). Root cause: an earlier check looped `git show
  origin/v0.2.0:<workflow-file>` over every workflow file and grepped for
  `cargo`; on this Windows/MSYS environment, `git show <ref>:<path>` silently
  fails with `fatal: ambiguous argument` due to MSYS's automatic path
  conversion mangling the `ref:path` argument (colon-then-slash gets read as
  a Windows path and rewritten, e.g. `origin/v0.2.0:.github/workflows/
  build-push.yml` becomes `origin\v0.2.0;.github\workflows\build-push.yml`),
  and the failure was swallowed rather than surfaced — so the loop produced
  an empty, falsely-reassuring "no cargo anywhere" result for every single
  workflow file, not just this one. Re-run with `MSYS_NO_PATHCONV=1` (or by
  extracting the blob to a file first) finds the jobs immediately. Section
  11 and the summary table above are corrected; this is recorded here as a
  durable methodology note for any future `git show <ref>:<path>` loop run
  on this host.
- **Currency re-verification (2026-07-18)**, against `origin/v0.2.0` @
  `dc8d79c6` (68 commits landed since this document's `3f53ac3b` baseline):
  re-ran `grep -c '#\[test\]'` and `wc -l` against every in-scope file.
  `main.rs`, `config.rs`, and `syslog_client.rs` grew substantially (test/line
  counts corrected in their respective sections and in section 11's per-file
  list); `nats_auth_callout.rs`, `nats_config.rs`, `session.rs`,
  `docker_client.rs`, `nginx_client.rs`, and `routes/mod.rs` were unchanged.
  Also found and fixed two leftover sentences (main.rs's and config.rs's own
  "Tests" paragraphs) that still asserted the already-retracted "not compiled
  or run by any CI workflow" claim and pointed at a stale "section 9" —
  section numbering shifted to 11 when sections 7/8/10 were added in the
  prior revision, and those two paragraphs were missed at the time. Updated
  `syslog_client.rs`'s multi-host-starvation-guard description: #861/#859
  replaced the original #758 file-open-level guard with a per-host floor
  merge (`PER_HOST_FLOOR = 10`), since the original guard only ensured every
  host's file got *opened*, not that its lines survived the final truncate.
  Every other narrative/behavioral claim in this document was independently
  re-checked against current code and found accurate.
- **Second review round (2026-07-18), five findings, all real and fixed**:
  (1) the protected-routes summary said `/domains` had 4 mutation endpoints;
  `POST /domains/aaaa-filter` (`main.rs`, mounted behind the same
  `basic_auth`/CSRF layer) is a 5th and was missing from the count. (2) the
  `ui_test` CI-job paragraph said the ~130-test figure was "exactly" what the
  job runs; `cargo test` actually runs the whole crate, so it also executes
  the route-handler tests this document deliberately scopes out (55 in
  `routes/dhcp.rs`, 21 in `routes/domains.rs`, etc.) — reworded to say the
  aggregate (now ~134, see finding 5 below) is this document's core-file
  subset, not the job's total. (3)
  `secondary_permissions()`'s NATS ACL was documented as the wildcard
  `$JS.API.CONSUMER.*.LANCACHE_DNS.>`; the actual code enumerates exactly
  four subjects (`CONSUMER.INFO`/`CONSUMER.CREATE`/`CONSUMER.DURABLE.CREATE`/
  `CONSUMER.MSG.NEXT`), and the wildcard shorthand made the enforced ACL look
  broader than it is — replaced with the explicit list. (4)
  `list_syslog_hosts()` was mentioned only in the Tests paragraph and in
  passing elsewhere, never given its own function bullet, despite being the
  actual host-enumeration/allowlist gate `routes/logs.rs` applies to the
  caller-controlled `?host=` parameter before tailing — added as its own
  bullet in section 8. (5) `main.rs`'s test count (15) counted only
  `#[test]`, missing 4 `#[tokio::test]` full-chain Basic Auth middleware
  integration tests added by #951 (19 total) — this document's own stated
  counting methodology (line ~20, `grep -c '#\[test\]'`) does not match
  `#[tokio::test]`, so this was a systematic gap for any file with async
  tests; checked every other in-scope file for the same gap and found none
  (only `main.rs` has `#[tokio::test]` functions). Corrected in the section 1
  header, the section 1 Tests paragraph, the top currency-check note, and
  section 11's per-file count and aggregate (the ~130 core-file sum was
  itself stale once main.rs's component changed from 15 to 19 — it is now
  ~134; fixing the leaf count without reconciling the aggregate would have
  reproduced the exact same undercount class one level up).
