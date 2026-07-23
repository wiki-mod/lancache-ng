# services/ui feature routes capability inventory

Source-of-truth working document for the `services/ui` (Admin UI) "feature routes" slice of the
project-wide capability inventory tracked in issue #843. Findings here are also posted as a single
GitHub comment on #843; this file is the durable, continuously-updated working copy so nothing is
lost mid-audit.

Audited against: `origin/v0.2.0` (commit `3f53ac3` at the time of this pass).

> **Currency check (2026-07-18):** re-verified against `origin/v0.2.0` @
> `dc8d79c6` (68 commits landed since this document's `3f53ac3b` baseline);
> see corrections below. Two of these commits are directly relevant to
> route-level behavior described in this document: `53a5ba7f` (#878) fixed
> `domains.rs`'s `add_dns`/`remove_dns` silently redirecting as success on a
> failed CDN-domain-file write (a correctness fix, not a coverage-gap fix --
> the E2E-coverage-gap claim below for these two routes still stands, since
> no simulation script was added). `d971063c` (#978) converted
> `GET /api/dhcp/check` to `POST /api/dhcp/check` with an explicit CSRF check
> (closing a real CSRF-exemption gap on a state-mutating GET), corrected
> below; the underlying auto-fire-on-page-load behavior itself
> (dhcp.html's `DOMContentLoaded` handler still calls this endpoint,
> restarting the dhcp-probe container and running a real nmap scan,
> whenever its enclosing `{% if dhcp_has_kea %}` script block renders --
> i.e. Kea mode only, not every `/dhcp` load regardless of mode) is
> unchanged and not addressed by that fix. `domains.rs`,
> `secondaries.rs`, and `dhcp.rs` also grew in line/test count from other
> commits in the interim (line/test counts corrected below); the syslog
> branch of `logs.rs` gained a real (if different) filter mechanism
> (`?host=`, #865/#848) since this document was written, corrected below.
> Every other narrative/behavioral claim in this document was independently
> re-checked against current code and remains accurate.

> **Second currency check (2026-07-18, responding to a second round of
> review findings):** four further corrections, all independently verified
> against current `origin/v0.2.0` code. (1) `scripts/syslog-forwarding-simulation.sh`
> does exercise `GET /logs` end-to-end (`assert_marker_reaches_ui` polls the
> real Admin UI route), so `/logs` is not actually uncovered as this
> document previously claimed -- corrected below, and the simulation-script
> count corrected from 11 to the real 12 (`ls scripts/*-simulation.sh`),
> since the original count missed this script. (2) `register_secondary` in
> `secondaries.rs` fails closed with `503` via
> `state.config.advertised_nats_url()` *before* generating a NATS password
> or writing to SQLite when neither `NATS_ADVERTISE_URL` nor
> `NATS_BIND_IP` is configured (issue #866) -- this gate was missing from
> this document's description of that route, corrected below. (3) The
> `dhcp.html` conflict-check auto-run described above is scoped to Kea mode
> via `{% if dhcp_has_kea %}` (set from `dhcp_mode.is_kea()` in
> `dhcp_page()`), not unconditional on every `/dhcp` load -- corrected in
> both places this document previously overstated it. (4)
> `update_nats_conf()`/`reload_nats_conf()` is called exactly once, at
> Admin UI startup (`main.rs`), not from any topology-change path --
> `register_secondary`/`remove_secondary`/`rotate_token` deliberately never
> call it (the auth-callout responder re-checks the `secondaries` table
> live instead) -- corrected below.

## services/ui feature routes capability inventory

Scope: exhaustive pass over every file in `services/ui/src/routes/` (10 files, all read in full against `origin/v0.2.0`), cross-referenced against `services/ui/src/main.rs`'s route table (the actual HTTP method+path wiring, since the route modules themselves don't declare their own paths), `services/ui/src/templates/` (8 templates), the 12 `scripts/*-simulation.sh` E2E scripts, and the current open-issue list. Governance read in full for this pass: `.github/AGENTS.md` (all 452 lines, including the Rule Enforcement Matrix), `CLAUDE.md` (both the stale copy on `fix/sccache-fallback-exit-code` and the current `origin/v0.2.0` version -- they differ meaningfully, e.g. `origin/v0.2.0` describes a unified single `services/proxy` container with port-based mode split, not two separate proxy services), and `CONTRIBUTING.md` (`origin/v0.2.0`, 299 lines).

Files present: `dashboard.rs`, `dhcp.rs` (5780 lines as of the 2026-07-18 currency check, 5568 at original writing -- by far the largest route file in the project), `dns_snapshots.rs`, `domains.rs`, `logs.rs`, `mod.rs` (shared helpers, not a route module), `netdata_proxy.rs`, `secondaries.rs`, `setup.rs`, `stats.rs`.

---

### `mod.rs` -- shared helpers (no routes of its own)

- `render()`: Tera rendering wrapper. On template error, shows full error detail (template name + Tera error text) in dev mode, a generic "Template Rendering Failed" message in prod mode -- deliberately never leaks template internals to an operator's browser in production.
- `insert_csrf_token()` / `verify_csrf_token()` / `verify_csrf_header()`: per-session CSRF token plumbing. The session token itself is carried in a request header set by the `basic_auth` middleware (not shown in this directory); comparison is constant-time (`subtle::ConstantTimeEq`) to avoid a timing side-channel on the token value. `verify_csrf_token` reads the token from a form field (`csrf_token`), `verify_csrf_header` reads it from an `x-csrf-token` header -- used respectively by HTML-form routes vs. the JSON API routes in `secondaries.rs`.
- Covered by 4 unit tests in this file (render error/success in dev/prod, CSRF token round-trip). No dedicated E2E simulation for CSRF itself, but every `*-simulation.sh` script that POSTs a form (see below) implicitly exercises the real CSRF flow end-to-end since a wrong/missing token would 403 the request.

---

### `dashboard.rs` -- `GET /` and `GET /api/metrics`

- `dashboard()` (`GET /`): renders the main landing page. Fetches, concurrently via `tokio::join!`: nginx stub_status for standard mode and (only if `ssl_enabled` and the SSL proxy URL actually differs from the standard one) SSL mode; cache directory size via `du` (spawn_blocking); nginx log stats + last 10 log lines (spawn_blocking); syslog-ng store size + stats (spawn_blocking, only if `syslog_enabled`, else short-circuits to `0.0`/default without touching the filesystem). Renders `dashboard.html`.
- `metrics_api()` (`GET /api/metrics`): JSON-only counterpart exposing just the nginx stub_status pair (standard/SSL). **Correction (2026-07-18 review pass): this route is not orphaned.** `dashboard.html`'s own inline `<script>` block (`refreshDashboardMetrics()`) polls `fetch('/api/metrics')` every 10 seconds and patches the standard/SSL connection-count numbers in place, specifically to avoid re-running `dashboard()`'s much heavier cache-size/log-tail work on every refresh. The route's own doc comment in `dashboard.rs` ("nothing in this codebase currently calls this endpoint from the frontend") is itself stale and was corrected in the same pass -- see the source fix alongside this document update.
- Backend calls: nginx (`nginx_client::get_stub_status`, `get_cache_size_gb`, `get_log_stats`, `parse_log_tail`), syslog-ng (`syslog_client::get_syslog_size_gb`, `get_syslog_stats`), no Kea/PowerDNS/NATS/Docker calls.
- E2E coverage: no dedicated simulation script hits `GET /` or `GET /api/metrics` directly. **Correction (2026-07-18): `ui-reachability-crash-loop-simulation.sh` does not GET `/dhcp` either** -- it only curls the unauthenticated `GET /health` route (wired under `main.rs`'s `public_routes`, bypassing the Basic Auth/CSRF `protected_routes` middleware entirely), so it proves the Admin UI answers HTTP requests during a crash-loop but exercises neither `/` nor `/api/metrics` nor any auth-gated route. Coverage is effectively unit-tests-only for `cache_usage_pct` (not shown above, but present in the file) plus whatever manual verification happened in past PRs.

---

### `logs.rs` -- `GET /logs`

- `logs_page()`: two mutually-exclusive branches (per the file's own header comment) -- if `SYSLOG_ENABLED=true` (the `logging` Compose profile), renders the last N entries from the syslog-ng store (`syslog_client::parse_syslog_tail`); otherwise falls back to parsing nginx's own access log tail directly (`nginx_client::parse_log_tail`), splitting the budget between a shared or split standard/SSL log file. Supports a `?filter=<cache_status>` query param in the nginx branch only (retains only entries matching the given cache status, e.g. `HIT`/`MISS`) -- the syslog branch still has no equivalent *cache-status* filter wired, but as of #865/#848 (landed after this document's original writing) it gained its own, differently-shaped `?host=` filter (restricting the tail to one wired host's subdirectory, backed by a real dropdown in `logs.html`'s syslog-mode branch and a `list_syslog_hosts()` helper), and the code's own comment now explicitly documents the asymmetry as intentional (`?filter` "has no meaning for syslog lines"), not an unflagged gap. `?host=` is only ever honored when it's an exact member of `list_syslog_hosts()`'s real result.
- Backend calls: nginx or syslog-ng log files only, no Kea/PowerDNS/NATS/Docker.
- E2E coverage: **corrected (2026-07-18, second review pass) -- `/logs` IS covered.** `scripts/syslog-forwarding-simulation.sh`'s `assert_marker_reaches_ui()` helper repeatedly curls the real Admin UI `GET /logs` route (`http://$ip_standard:8080/logs`) and asserts a unique per-service marker is visible in the rendered HTML, for six services (proxy, ui, nats, dns-standard, dns-ssl, watchdog) plus a weaker netdata presence check -- this is real HTTP-route-level proof against the live syslog branch of `logs_page()`, not just syslog-ng ingestion. This document's prior "none of the 11 simulation scripts hit `/logs`" claim was wrong on two counts: the script exists and does hit this route, and the actual script count is 12, not 11 (see the scope line above). The nginx-log-tail branch (`?filter=`, when `SYSLOG_ENABLED` is false) and the `?host=` syslog filter param remain untested by this script, which always runs with syslog enabled -- that narrower gap is real but distinct from "no coverage at all". #453 (open, "central syslog-ng logging with fluent-bit forwarding") remains the umbrella issue for any residual `/logs` UI-level gaps (e.g. the untested `?host=`/`?filter=` param combinations, and dhcp/dhcp-proxy which this script's own header comment excludes).

---

### `stats.rs` -- `GET /stats`

- `stats_page()`: renders `stats.html` with only `active_page` set. All 14 lines of this file are the render call -- every actual stat is fetched client-side by `admin.css`/`chart.umd.min.js` JS hitting `/api/netdata/*` and/or `/api/metrics` directly (not server-rendered into this route). This route is effectively a static page shell.
- E2E coverage: none of the 12 simulation scripts hit `/stats` (re-verified 2026-07-18 against the corrected script count).

---

### `netdata_proxy.rs` -- `GET /api/netdata/{*path}`

- `proxy()`: forwards to Netdata's own `/api/v1/{data,charts}` endpoints only -- `build_netdata_url` explicitly allowlists `path` to exactly `"data"` or `"charts"` (rejects anything containing `/` or `..`, and anything not in `ALLOWED_NETDATA_ENDPOINTS`), so this cannot be used as an open proxy to arbitrary Netdata (or other) URLs.
- Backend calls: Netdata HTTP API only (`state.config.netdata_url`).
- Well unit-tested in-file (4 tests: allowed data URL + query params, query encoding, charts endpoint, rejection of unsafe/unapproved paths). No E2E simulation script exercises this route against a real Netdata container.

---

### `setup.rs` -- `GET /setup`, `POST /setup/update`

- `setup_page()`: renders network config (`standard_ip`, `ssl_ip`), current DHCP mode, and (issue #819) the current release-channel (`stable`/`nightly`) + scheduled-auto-update setting.
- `update_stack_settings()`: validates CSRF, validates the channel is exactly `"stable"` or `"nightly"` (explicitly rejects `"dev"` and `"pinned"`, and the old hard-cut `"edge"` name -- see `is_valid_ui_channel`'s own comment: `"dev"` is out of scope split into #825, `"pinned"` is a `setup.sh`-internal state this control never sets), then calls `routes::dhcp::persist_stack_settings` to write both values into the same whole-file-overwrite settings file `dhcp.rs`'s `persist_ui_settings`/`update_dhcp_mode` write to.
- Deliberately does **not** touch Docker at all (unlike every DHCP mutation route) -- the file's own header comment explains why: both settings are consumed entirely on the host by `setup.sh`'s `lancache-converge.service` (a systemd timer polling the same `ui-data` volume), a deliberate choice over giving this container a new docker-socket-proxy path to manage a host systemd unit directly (see #819's thread).
- Backend calls: none live (file write only); the actual effect (channel switch, scheduled update) is applied out-of-band by a host-side systemd timer, not synchronously by this request.
- E2E coverage: none of the 12 simulation scripts hit `/setup` or `/setup/update` (re-verified 2026-07-18 against the corrected script count). `setup-cli-simulation.sh` tests `setup.sh`'s own CLI channel resolution, not this Admin-UI route or the settings-file contract between them.

---

### `dns_snapshots.rs` -- `POST /domains/zones/rollback` (no GET of its own; folded into `domains_page`)

- `fetch_zone_snapshot_groups()`: called from `domains_page` (not a route itself), fetches every rollback-managed zone's known-good snapshot list from `nats-subscriber`'s own rollback listener (`GET {DNS_ROLLBACK_URL}/snapshots`, default `http://dns-standard:8083`). Fails soft to an empty list on any error (unreachable listener renders as "no snapshots yet", not a broken page).
- `rollback_zone_snapshot()` (`POST /domains/zones/rollback`): forwards an operator-selected `(zone, snapshot_id)` pair to the listener's `POST {DNS_ROLLBACK_URL}/rollback`. This handler's own job is CSRF verification only -- all real validation (zone whitelist, snapshot-id membership, diff/PATCH/check-zone/flush/republish) happens inside `nats-subscriber`. Fire-and-log on failure, always redirects back to `/domains` regardless of the listener's response.
- Explicitly scoped to `dns-standard` only (mirrors `PDNS_AUTH_URL`/`PDNS_REC_URL`'s single-primary convention) -- the module's own header comment documents this as deliberate, not an oversight, and names the reason a `dns-ssl` rollback UI isn't a trivial copy (the `local.lan.`/private reverse zones aren't NATS-replicated between `dns-standard` and `dns-ssl`), tracked as a real follow-up rather than solved here. This is directly related to open issue #836 ("setup.sh reset-to-last-known-good-config: complete the dns/pdns service target") and the `dns-ssl` half of #770's asymmetric-replication theme.
- Backend calls: `nats-subscriber`'s rollback listener over HTTP only (not NATS itself, not PowerDNS directly).
- E2E coverage gap confirmed by direct inspection: `dns-zone-rollback-simulation.sh` (issue #628's own E2E proof) calls the rollback listener **directly** (`curl http://$dns_standard_ip:8083/snapshots` and presumably `/rollback` the same way) to prove the listener's own diff/rollback logic -- it does **not** go through the Admin UI's `POST /domains/zones/rollback` route at all. This is the same class of gap issue #837 already opened for the Kea rollback route (`POST /dhcp/snapshot/rollback`) -- worth either extending #837's scope or filing a sibling issue for this route, since right now neither of the project's two config-rollback UI routes has E2E coverage of the actual HTTP path an operator's browser would hit.

---

### `domains.rs` -- CDN domain list, LAN DNS records, AAAA filter (1321 lines as of 2026-07-18, 1139 at original writing)

Routes (from `main.rs`): `GET /domains`, `POST /domains/dns/add`, `POST /domains/dns/remove`, `POST /domains/lan/add`, `POST /domains/lan/remove`, `POST /domains/aaaa-filter`.

- `domains_page()`: renders the CDN domain list (parsed from `cdn_domains_file`), LAN DNS records (fetched live from PowerDNS Authoritative's `zones/lan` API), current AAAA-filter marker state, and (via `dns_snapshots.rs`) the zone snapshot rollback panel.
- `add_dns()` / `remove_dns()`: validate and rewrite `cdn_domains_file` (atomic temp-file+rename, with an in-place fallback for bind-mounted individual files that can't be renamed -- `EBUSY`/errno 16 -- documented as intentionally non-atomic in that fallback case), then flush the PowerDNS Recursor's cache for the exact changed domain (canonical dot-terminated form required by PDNS or the flush itself is rejected) and publish a `lancache.dns.flush` NATS event so every recursor instance clears cache, not just the one this UI talks to. If `ssl_enabled`, restarts the SSL proxy service (via `docker_client::restart_service`) since the proxy derives its wildcard-cert root domains and host-allowlist from this same file at container startup -- **no separate SSL domain list exists anymore**, so any CDN-domain add/remove that needs TLS interception requires this restart to take effect. **As of #878** (landed after this document's original writing): a failed `cdn_domains_file` write now maps through a shared `dns_write_result_to_response` helper to `500 Internal Server Error` instead of the unconditional success redirect both handlers previously sent regardless of write outcome -- the best-effort recursor-flush/proxy-restart calls that follow a *successful* write remain fire-and-log, since they're downstream side effects rather than the request's own mutation.
- `add_lan_record()` / `remove_lan_record()`: publish a `lancache.dns.record` NATS message (`{action: replace|delete, zone: "lan", ...}`) rather than calling PowerDNS's API directly -- the actual zone mutation happens asynchronously in `nats-subscriber`. Validates record type (A/AAAA/CNAME/MX/TXT for add; a much wider set incl. SRV/CAA/DS/DNSKEY/NAPTR/LOC/HTTPS/SVCB/`TYPE<n>` for delete, since an operator must be able to delete a pre-existing rrset outside the add-form's whitelist), TTL bounds, and name/content shape per record type (including underscore-label support for TXT/SRV-style names like `_dmarc.lan.`/`_acme-challenge.lan.`).
- `toggle_aaaa_filter()`: writes/removes a marker file (`aaaa-filter-enabled`) in **both** `dns-standard` and `dns-ssl`'s state dirs. If either write fails, returns 500 rather than reporting success -- "the UI must not report success if any DNS instance cannot observe the requested marker state" per its own comment.
- Backend calls: PowerDNS Authoritative (`fetch_lan_records`), PowerDNS Recursor (`flush_recursor_cache`), NATS publish (`lancache.dns.flush`, `lancache.dns.record`), Docker restart (`restart_ssl` -> `docker_client::restart_service`), direct filesystem writes (domain file, AAAA marker files).
- Extensive in-file unit test coverage (21 tests as of 2026-07-18, 14 at original writing -- the growth is `add_dns`/`remove_dns`'s new failure-mapping tests from #878, see the currency-check note above): domain entry parsing incl. wildcard-only (`.example.com`) vs. root-domain semantics (explicitly distinct per `AGENTS.md`'s "Domain scope semantics" rule -- not normalized away), atomic file rewrite preserving comments/mixed line-endings (issue #656 regression test), bind-mount EBUSY fallback, LAN record validation edge cases, and (since #878) `dns_write_result_to_response`'s success/failure mapping for both `add_dns` and `remove_dns`.
- E2E coverage: `/domains/lan/add` and `/domains/lan/remove` ARE exercised end-to-end by both `dns-zone-rollback-simulation.sh` and `ui-nats-dns-integration-simulation.sh` (real HTTP POST through the UI, real NATS publish, real PowerDNS zone mutation, real `dig` verification). **Not** covered by any simulation script: `/domains/dns/add`, `/domains/dns/remove` (the CDN-domain-file + SSL-proxy-restart path), and `/domains/aaaa-filter`. Given that `add_dns`/`remove_dns` is the one route in this file that also triggers a Docker container restart (`restart_ssl`), and per `AG-VAL-014` ("Proxy/cache behavior changes require a response or cache-behavior check that proves the proxy still serves the intended path"), this looks like the most operationally significant untested path in this file.

---

### `secondaries.rs` -- NATS secondary node registration (629 lines as of 2026-07-18, 589 at original writing; test count unchanged at 5)

Routes: `GET /secondaries`, `POST /api/secondary/register` (public, own token, not behind Basic Auth), `DELETE /api/secondary/{name}`, `POST /api/secondary/{name}/rotate-token`.

- `secondaries_page()`: lists registered secondaries from SQLite (`name`, `consumer_name`, `registered_at`, `last_seen`), plus the primary's own URL and the shared registration token (rendered so an operator can copy it into a secondary's own setup).
- `register_secondary()`: validates a constant-time-compared registration token (rejects outright if the token is unconfigured/empty -- prevents accidental open registration) and a name (alphanumeric+dash, ≤32 chars). **Correction (2026-07-18, second review pass): a fail-closed advertise-URL gate runs next, missing from this document's prior description.** Issue #866: before generating any credential or touching SQLite, the handler resolves `state.config.advertised_nats_url()`; if neither `NATS_ADVERTISE_URL` nor `NATS_BIND_IP` is configured on this primary, it returns `503 Service Unavailable` immediately (with no side effects) rather than handing out the Docker-internal `nats_url`, which a remote secondary could never reach. Only once that gate passes does the rest proceed: per issue #583, each secondary gets its own NATS identity: a fresh 32-byte CSPRNG password is generated, hashed, and only the hash is ever persisted (`INSERT OR REPLACE`) -- the plaintext password is returned exactly once in the JSON response and never stored. Returns the full bootstrap payload a secondary's own setup needs: NATS URL/user/password, PDNS API key, and the image registry/prefix/channel/tag to pull.
- `remove_secondary()` (DELETE): deletes the DB row. No `nats.conf` rewrite or NATS restart needed -- the auth-callout responder re-checks the table live on every connection attempt (issue #583's design), so this revokes access on the secondary's very next reconnect with zero blast radius on other secondaries.
- `rotate_token()`: regenerates only this one secondary's NATS password (its `nats_user`/name never changes) -- the endpoint finally does what its name says, per the comment referencing #433's history of this same endpoint once returning an unchanged shared value.
- `update_nats_conf()`/`reload_nats_conf()` (not routes): render and atomically write only the `auth_callout {}` fragment (`nats_auth_callout.conf`, issue #811) -- **not** the whole `nats.conf` anymore, which the `nats` container's own entrypoint owns and idempotently regenerates on every restart. **Correction (2026-07-18, second review pass): this document previously said these are "called by other code paths e.g. after topology changes" -- verified against current code, that is not accurate.** `reload_nats_conf` has exactly one call site, in `main.rs` at Admin UI startup (writing the initial fragment and restarting NATS once so it picks up the config without a Docker `exec`). None of `register_secondary`, `remove_secondary`, or `rotate_token` call it -- as already noted above for `remove_secondary`, a topology change only ever writes to the `secondaries` table; the auth-callout responder re-checks that table live on every connection attempt, so no fragment rewrite or NATS restart is needed (or performed) for any of those three routes. `reload_nats_conf` still requires a NATS container restart because `nats-server` explicitly refuses to hot-reload `auth_callout` config.
- Backend calls: SQLite (`state.db`), Docker restart (only via `reload_nats_conf`, not on every register/rotate/remove), no PowerDNS/Kea calls.
- Strong in-file unit test coverage (5 tests) incl. two dedicated idempotence/convergence tests (issue #640) proving the `auth_callout.conf` fragment write is byte-identical and leftover-`.tmp`-free across repeated renders -- directly satisfying `AG-OP-006`'s convergence checklist for this specific write path.
- E2E coverage: `nats-secondary-auth-callout-simulation.sh` covers `POST /api/secondary/register`, `DELETE /api/secondary/{name}`, and `POST /api/secondary/{name}/rotate-token` against a real NATS instance. `GET /secondaries` itself (the HTML page) has no dedicated E2E check, though it's low-risk (pure DB read + render, same shape as `stats_page`).
- Open security-hardening issues directly against this surface: #839 (Argon2id instead of the current password-hash scheme, active disconnect on removal/rotation, xkey encryption), #682, #681, #680 (component pieces of the same #839 umbrella) -- all open, all v0.3.0-scoped, all about strengthening this exact route file's credential handling rather than adding new routes.

---

### `dhcp.rs` -- by far the largest and most complex route file (5780 lines as of 2026-07-18, 5568 at original writing)

Routes (from `main.rs`): `GET /dhcp`, `POST /dhcp/mode`, `POST /dhcp/proxy`, `POST /dhcp/subnet/add`, `POST /dhcp/subnet/update`, `POST /dhcp/subnet/remove`, `POST /dhcp/subnet/option/add`, `POST /dhcp/subnet/option/remove`, `POST /dhcp/static/add`, `POST /dhcp/static/remove`, `POST /dhcp/lease/release`, `POST /dhcp/snapshot/rollback`, `POST /api/dhcp/check` (converted from `GET` by #978, see below).

**Whole-stack mode control:**
- `dhcp_page()`: renders current DHCP mode (disabled/Kea/dnsmasq-proxy), dnsmasq-proxy settings, and -- only if Kea is actually reachable (`kea_api_available`: mode is Kea AND `dhcp_api_url` is non-empty) -- live subnets/leases/reservations (leases+reservations fetched concurrently via `tokio::join!`) plus known-good Kea config snapshots. Never hard-errors: an unreachable Kea renders empty tables rather than a broken page.
- `update_dhcp_mode()`: switches the whole stack between the three modes by starting/stopping the `dhcp`/`dhcp-proxy` Compose services via the Docker socket proxy (`docker_client`), then persists the new mode to a settings file `entrypoint.sh` reads on next container start. Has real rollback-on-persist-failure logic (issue #671): a pre-flight writability check (`check_settings_dir_writable`) runs before any Docker mutation, and if the persist step still fails afterward (e.g. volume filled up in the gap between check and write), it best-effort rolls the already-mutated Docker containers back to the previous mode and surfaces both errors if that rollback also fails.
- `update_dhcp_proxy()`: validates and saves dnsmasq-proxy's relay/PXE settings (issue #450's optional fields: interface, router, NTP servers, domain, boot filename/server, and a free-form custom-option textarea parsed as `CODE:VALUE` per line). Explicitly excludes DHCP option codes 3/6/15/42/119 from the free-form list (dedicated fields already cover them) to avoid two divergent ways of setting the same option -- same exclusion list Kea's per-subnet custom options enforce (`is_ui_managed_subnet_option_code`).

**Kea subnet/reservation/lease/option management (the exact #556 scope):**
- `add_subnet()` / `update_subnet()` / `remove_subnet()`: full CRUD on Kea `subnet4` entries via `kea_config_modify` (config-get -> modify -> config-test -> config-set -> config-write, with confirmed/ambiguous-failure-aware rollback). `update_subnet` carries forward existing custom options and re-filters existing reservations to the new CIDR so a reservation outside the changed subnet range isn't silently orphaned inside it.
- `add_subnet_option()` / `remove_subnet_option()`: per-subnet arbitrary DHCP option management (**this is exactly the "custom DHCP-option management" issue #556 asked for**) -- validated code (1-254, excluding the 5 UI-managed codes) and data (non-empty, ≤1024 bytes, single-line).
- `add_reservation()` / `remove_reservation()`: static host reservations by MAC. `add_reservation` has a real safety guard: it checks the config's *global* `Dhcp4.host-reservation-identifiers` list actually includes `"hw-address"` before writing (Kea's compiled-in default does, but a hand-edited config could exclude it) -- refuses to write a reservation Kea would silently never match, per `AGENTS.md`'s `AG-OP-005` ("do not silently invert defaults").
- `release_lease()` (**the other #556 ask**): calls Kea's `lease4-del` directly via `kea_post` (bypasses the config-modify chain entirely -- this is a runtime lease-database action, not a config-file change). Correctly distinguishes Kea's `CONTROL_RESULT_EMPTY` (3, "no matching lease" -- an ordinary race, surfaced as 404) from a genuine error (surfaced as 500). **Update (2026-07-23, issue #1083):** `lease4-del` does not trigger a DDNS removal, so on a successful release this route now also cleans up the lease's DDNS records: it `lease4-get`s the hostname first, then publishes forward-A and reverse-PTR `delete` events on the same `lancache.dns.record` NATS subject both PowerDNS instances consume (`forward_record_zone_and_name`/`reverse_ptr_zone_and_name`). Best-effort (logs on publish failure, never fails the release); records are keyed by the released lease's own IP/hostname, so a mismatch is a stale-record miss, never a wrong-delete.
- **Cross-reference: issue #556 ("DHCP Admin UI is still missing lease release and custom DHCP-option management") is CLOSED.** Both gaps it named are fully implemented in the current `origin/v0.2.0` code (`release_lease` and `add_subnet_option`/`remove_subnet_option` above) -- this is a stale example in this audit's own task framing; the code has moved past it.
- `rollback_kea_snapshot()`: operator-selected rollback to one of N retained known-good Kea config snapshots (#614). Path-traversal-safe (`form.snapshot_id` is never used to build a filesystem path unless it exactly matches an id `list_snapshot_ids` already found on disk). Reuses the same `kea_config_modify` chain, so a rollback gets the identical config-test/config-set/config-write/rollback-on-failure guarantees as every other mutation, plus its own fresh known-good snapshot on success.
- `check_dhcp_conflict()` (`POST /api/dhcp/check`, converted from `GET` by **#978** since this document's original writing): runs a predeclared one-shot `dhcp-probe` container (nmap broadcast-dhcp-discover conflict scan + a `dhclient` dry-run) via start/wait/logs only -- Docker `exec` and generic container creation are explicitly banned from the UI's Docker API surface for security reasons (per the file's own header comment). Returns a combined `{status, conflict, client}` JSON with `conflict_found` outranking everything else regardless of the client check's own result. **#978 closed a real CSRF-exemption gap**: this route mutates server state (starts/stops the `dhcp-probe` container) but was previously reachable via a plain, CSRF-exempt `GET` (this app's CSRF protection only ever covered mutating HTTP methods) -- it is now `POST` with an explicit `verify_csrf_header` check, mirroring `secondaries::remove_secondary`/`rotate_token`. This does **not** change `dhcp.html`'s own `DOMContentLoaded` handler, which still calls this endpoint (now as a CSRF-token-bearing POST) whenever its script renders -- the disruptive auto-restart-probe-plus-scan behavior itself is unrelated to the CSRF gap and remains exactly as before. **Correction (2026-07-18, second review pass): this document previously said this fires "on every single page load of `/dhcp`" -- verified against the current template, that overstates it.** The entire script block containing `checkDhcpConflict()` and its `DOMContentLoaded` listener is wrapped in `{% if dhcp_has_kea %}` in `dhcp.html`, and `dhcp_page()` sets `dhcp_has_kea` from `dhcp_mode.is_kea()` -- so the auto-run only fires when the stack is in Kea mode. Disabled and dnsmasq-proxy-mode `/dhcp` page loads do not auto-call `/api/dhcp/check` or restart the probe container.

**Kea API core (shared machinery, not routes):** `kea_post`/`kea_result` (raw Control Agent HTTP + Kea's own success/failure result-code convention), `kea_config_modify`/`kea_config_modify_with_post` (the full config-get/modify/test/set/write chain with a 3-way write-outcome type -- `Success`/`ConfirmedFailure`/`AmbiguousFailure` -- so a network error on `config-write` is never conflated with Kea explicitly rejecting the write; an ambiguous failure gets one retry before giving up rather than either blindly rolling back a write that may have actually succeeded, or leaving a genuine failure unconfirmed forever), `rollback_kea_config` (re-applies the pre-change config on a confirmed write failure).

**Backend calls:** Kea Control Agent (HTTP, basic-auth), Docker (start/stop/restart for `dhcp`/`dhcp-proxy` services, and the narrow start/wait/logs-only surface for the `dhcp-probe` one-shot container), filesystem (settings file, Kea config snapshots via `kea_snapshots` module). No PowerDNS or NATS calls in this file itself (Kea's own DDNS updates -- lease -> PowerDNS record -- happen inside Kea/its DDNS process, not through this Rust code).

**E2E coverage** (4 dedicated simulation scripts: `dhcp-kea-ctrl-agent-mutation-simulation.sh`, `dhcp-kea-lease-flow-simulation.sh`, `dhcp-proxy-pxe-simulation.sh`, `ui-reachability-crash-loop-simulation.sh`):
- Confirmed covered end-to-end through the real Admin UI HTTP route: `POST /dhcp/static/add`, `POST /dhcp/static/remove` (`dhcp-kea-ctrl-agent-mutation-simulation.sh`, which authenticates a real session/CSRF flow against `GET /dhcp` first).
- **Confirmed NOT covered by any simulation script's actual HTTP route calls** (verified by grepping every `curl` call in all 12 scripts): `POST /dhcp/mode`, `POST /dhcp/proxy` (the dnsmasq-proxy PXE script tests dnsmasq's own rendered config directly, not this route), `POST /dhcp/subnet/add`, `POST /dhcp/subnet/update`, `POST /dhcp/subnet/remove`, `POST /dhcp/subnet/option/add`, `POST /dhcp/subnet/option/remove` (i.e. the #556 custom-option feature itself has unit tests but no E2E route-level proof), `POST /dhcp/lease/release`, and `POST /dhcp/snapshot/rollback` -- this last one already has its own tracked gap in **open issue #837** ("Add real E2E test for Admin UI's Kea rollback HTTP route"), confirming #837's description is accurate: `scripts/setup-reset-kea-config-simulation.sh` only proves the CLI (`setup.sh reset-to-last-known-good-config kea`) fallback path, not this UI route. **Correction (2026-07-18 review pass): `POST /dhcp/lease/release` was previously miscategorized as covered.** `dhcp-kea-ctrl-agent-mutation-simulation.sh` explicitly documents (in its own comment above the relevant call) that it clears the active lease via Kea's `lease4-del` control command directly against the Control Agent, "not the Admin UI's `/dhcp/lease/release` route (`release_lease()` in dhcp.rs)" -- a repo-wide grep of all `scripts/*.sh` finds no script that actually calls this route via HTTP. `ui-reachability-crash-loop-simulation.sh` also does not cover it or any other `/dhcp` route: it only curls the unauthenticated `GET /health` (wired under `main.rs`'s `public_routes`, bypassing the Basic Auth/CSRF `protected_routes` middleware `/dhcp` sits behind), so it was never a valid "auth-gate case" citation for this file's routes either.
- Extremely thorough in-file unit/mock test suite (roughly 2200 of the file's 5568 lines are `#[cfg(test)]` code) covering the `kea_config_modify_with_post` write-outcome state machine (confirmed vs. ambiguous failure, retry-then-rollback), NTP hostname resolution vs. malformed-IPv4 rejection, subnet CIDR/pool validation, custom option code/data validation, and the exact preserved-vs.-replaced option/reservation semantics `update_subnet` must maintain.

**Cross-referenced open issues specifically about this file's scope:**
- **#556** (closed) -- both named gaps (lease release, custom option management) are implemented; see above.
- **#646** (open, spec) -- "define full Kea DHCP Admin UI feature scope": explicitly frames the current subnet/reservation/option/snapshot feature set as built incrementally without one agreed picture of the intended full surface, and asks (among other things) whether DHCP-DDNS follow-through and real behavior test coverage match what's actually verified -- this audit's E2E-gap findings above (subnet/option/mode/proxy/rollback routes untested end-to-end) are exactly the kind of evidence #646 is asking for.
- **#647** (open, spec) -- sibling spec issue for dnsmasq-proxy mode, including an unresolved question about whether `dhcp-proxy=${UPSTREAM_DHCP_IP}` was an orphaned fragment of a never-finished real DHCP-relay capability (not just dead code) -- directly relevant to `update_dhcp_proxy`'s `upstream_dhcp_ip` field in this file.
- **#837** (open) -- E2E gap for `POST /dhcp/snapshot/rollback`, confirmed accurate above.
- **#770** (open, known-limitation) -- DDNS lease records only reach `dns-standard`, not `dns-ssl`, because Kea's `dns-servers` config is a failover pair, not a fan-out list. This is a Kea-DDNS-internal limitation, not something `dhcp.rs` itself could fix without a DDNS architecture change; relevant context for anyone reading this file's lease-management routes and wondering why a Kea-issued lease's DNS record doesn't appear on both DNS nodes.
- **#836** (open) -- "setup.sh reset-to-last-known-good-config: complete the dns/pdns service target" -- the CLI-side sibling of this file's own `rollback_kea_snapshot`/`dns_snapshots.rs`'s `rollback_zone_snapshot`, tracking that the CLI rescue path doesn't yet cover every service target the Admin UI's own rollback routes do.
- **#840** (open, umbrella) -- general DHCP (Kea + dnsmasq-proxy) scattered feature/bug/research tracker; this file's open E2E gaps and #646/#647 above are all threads that could reasonably roll up under it.

---

### Summary table: route-level E2E coverage gaps found

| Route | Method | File | E2E coverage |
|---|---|---|---|
| `/` | GET | dashboard.rs | None |
| `/api/metrics` | GET | dashboard.rs | None via any simulation script -- but polled live by `dashboard.html`'s own JS every 10s, so not unused by the frontend (correction, 2026-07-18 review pass) |
| `/logs` | GET | logs.rs | Covered (syslog-forwarding-simulation.sh, syslog branch only; correction, 2026-07-18 second review pass) |
| `/stats` | GET | stats.rs | None |
| `/api/netdata/{*path}` | GET | netdata_proxy.rs | None (strong unit tests only) |
| `/setup`, `/setup/update` | GET/POST | setup.rs | None |
| `/domains/dns/add`, `/domains/dns/remove` | POST | domains.rs | None (the one route pair here that also restarts a Docker service) |
| `/domains/aaaa-filter` | POST | domains.rs | None |
| `/domains/zones/rollback` | POST | dns_snapshots.rs | None via the UI route (listener tested directly instead) -- same gap class as #837 |
| `/dhcp/mode`, `/dhcp/proxy` | POST | dhcp.rs | None via the UI route |
| `/dhcp/subnet/*`, `/dhcp/subnet/option/*` | POST | dhcp.rs | None via the UI route (unit-tested only) |
| `/dhcp/snapshot/rollback` | POST | dhcp.rs | None -- tracked in open #837 |
| `/dhcp/lease/release` | POST | dhcp.rs | None via the UI route -- `dhcp-kea-ctrl-agent-mutation-simulation.sh` clears the lease via Kea's `lease4-del` directly instead (correction, 2026-07-18 review pass) |
| `/secondaries` (GET page) | GET | secondaries.rs | None (low risk: pure read+render) |
| `/domains/lan/add`, `/domains/lan/remove` | POST | domains.rs | Covered (2 scripts) |
| `/dhcp/static/add`, `/dhcp/static/remove` | POST | dhcp.rs | Covered |
| `/api/secondary/register`, `/api/secondary/{name}`, `/api/secondary/{name}/rotate-token` | POST/DELETE | secondaries.rs | Covered |

Not a claim that every uncovered route is broken -- `dhcp.rs` and `domains.rs` in particular carry very strong in-file unit/mock test suites for their pure logic (validation, parsing, the Kea write-outcome state machine). The gap is specifically **real HTTP-route-level proof against a live backend**, the same distinction #837 already draws for the Kea rollback route.
