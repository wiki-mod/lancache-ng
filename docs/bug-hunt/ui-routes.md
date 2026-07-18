# services/ui feature routes -- exhaustive bug-hunt raw findings

CLD-1784120516

Umbrella issue: #849 (sub-issue of #843). Component: `services/ui/src/routes/` (every file:
`dashboard.rs`, `dhcp.rs`, `dns_snapshots.rs`, `domains.rs`, `logs.rs`, `mod.rs`,
`netdata_proxy.rs`, `secondaries.rs`, `setup.rs`, `stats.rs`), cross-referenced against
`services/ui/src/main.rs` (route table, auth/CSRF middleware, config validation),
`services/ui/src/session.rs`, `services/ui/src/config.rs`, `services/ui/src/nginx_client.rs`,
and `services/ui/src/templates/`.

Audited against a fresh clone of `origin/v0.2.0` (branch `bughunt-ui-routes`).

> **Currency check (2026-07-18):** re-verified against `origin/v0.2.0` @
> `dc8d79c6` (68 commits landed since this document's `3f53ac3b` baseline);
> see corrections below. Two commits directly fix findings recorded here:
> `53a5ba7f` (#878) fixed finding #11's `add_dns`/`remove_dns` silent-
> success-on-failed-write bug (verdict updated to FIXED below; finding #12,
> `restart_ssl`'s own failure still being swallowed, remains unfixed --
> that fire-and-log path was deliberately left alone by #878 as a
> downstream side effect, not the request's own mutation). `d971063c`
> (#978) closed the CSRF-exemption half of finding #21 (converted
> `GET /api/dhcp/check` to `POST` with an explicit CSRF check) but did
> **not** address the finding's core behavioral claim -- `dhcp.html`'s
> `DOMContentLoaded` handler still auto-fires this endpoint unconditionally
> on every page load, still restarting the dhcp-probe container and running
> a real nmap broadcast scan with no caching or cooldown; verdict updated
> to PARTIALLY FIXED below. Every other finding in this document was
> independently re-checked against current code and remains accurate/
> unfixed as originally recorded.

Methodology: vacuum-first, unscoped, exhaustive -- every finding is collected as observed, with
no pre-filtering or self-verification during collection (verification is a later, separate
phase per the maintainer-agreed workflow for issue #849). Starting point was
`docs/capability-inventory/SoT-ui-routes.md` (branch `docs/inventory-ui-routes`), but this pass
is NOT bounded by it -- new findings not present in that document are included below, and
findings that overlap with it are still listed (for completeness) with a note.

---

## mod.rs -- shared helpers

1. **`insert_csrf_token` silently defaults to an empty-string token when the session header is
   absent, and `verify_csrf_token`/`verify_csrf_header` do not special-case an empty token as
   always-invalid.** (`routes/mod.rs:47-61`) `insert_csrf_token` does
   `crate::session::csrf_header_value(headers).unwrap_or("")`. If the session middleware were
   ever to set the internal CSRF header (`x-lancache-ui-csrf-token`) to an actual empty string
   (as opposed to omitting it entirely), `verify_csrf_token`/`verify_csrf_header` would compare
   an attacker-submitted empty token against that empty session token via `ct_eq` and succeed,
   bypassing CSRF protection. Today `session.rs`'s session-token generation appears to always
   produce a non-empty CSPRNG value, so this is not currently reachable, but the helper itself
   has no defensive floor (`if session_token.is_empty() { return Err(FORBIDDEN) }`) guarding the
   invariant it relies on. Severity: info/latent -- flagging as a missing defense-in-depth
   check, not a currently exploitable path.

---

## dashboard.rs -- `GET /`, `GET /api/metrics`

2. **The dashboard's "recent logs" preview silently drops all standard-mode traffic when
   `STANDARD_LOG` and `SSL_LOG` are configured as two different files.** (`routes/dashboard.rs:46-53`)
   ```rust
   let path = if cfg.standard_log == cfg.ssl_log {
       cfg.standard_log.clone()
   } else {
       cfg.ssl_log.clone()
   };
   move || nginx_client::parse_log_tail(&path, 10)
   ```
   When the logs differ (a supported, documented configuration -- see CLAUDE.md's "Two-Mode /
   Two-IP Architecture", each mode gets its own proxy service), this always reads only
   `ssl_log` and never reads `standard_log` at all. Any standard-mode (HTTP passthrough / no-CA)
   client traffic is completely invisible in the dashboard's "recent activity" section in that
   configuration, even though `get_log_stats`/`logs.rs`'s own `/logs` page correctly read and
   merge both files. This is an actual behavioral inconsistency between `dashboard.rs` and
   `logs.rs` for the exact same "recent log lines" concept, not just a coverage gap.

3. **`metrics_api` (`GET /api/metrics`) is confirmed dead code from the frontend's perspective**
   (already noted in the SoT inventory; repeating here per the "no pre-filtering" collection
   rule). No JS/template in `services/ui/src/templates/` or `static/` calls it. Either wire it
   up or remove it -- as currently shipped it's unreachable functionality that still consumes
   review/test attention.

4. `cache_usage_pct` (`routes/dashboard.rs:145-151`) has no lower-bound clamp: if `used_gb` were
   ever negative (not currently possible from `get_cache_size_gb`'s real implementation, but
   nothing in this function's own signature prevents a negative `f64` argument), the result
   would silently produce a percentage below the intended 0..=100 range as a large `u64` after
   the `as u64` cast of a negative float (this actually saturates to 0 in Rust's float-to-int
   cast semantics since 1.45, so in practice this is a non-issue -- info-level only, noting the
   function has no explicit invariant/assertion documenting that reliance).

---

## logs.rs -- `GET /logs`

5. **Cross-source log merge in the non-syslog branch is not chronologically interleaved --
   it's two blocks concatenated and reversed, not a real merge by time.** (`routes/logs.rs:64-90`)
   `nginx_client::parse_log_tail` returns each source's own tail window oldest-first (confirmed
   in `nginx_client.rs`'s own doc comment: "oldest-first within the tail window ... routes/
   logs.rs reverses the result itself to show newest-first"). When `standard_log != ssl_log`,
   `logs_page` does:
   ```rust
   standard_logs.into_iter().chain(ssl_logs).collect()
   ```
   i.e. `[standard(oldest..newest), ssl(oldest..newest)]`, and only afterward does
   `all_logs.reverse()` on the *whole combined list*. The result is
   `[ssl(newest..oldest), standard(newest..oldest)]` -- every SSL-log entry (regardless of its
   actual timestamp) is placed before every standard-log entry in the rendered "most recent
   first" list. If the standard proxy's most recent request is more recent than the SSL proxy's
   most recent request, it will still render *below* the SSL block instead of at the top. This
   is a real correctness bug in the split-log branch, not merely a display nuance -- an operator
   split-log setup gets a `/logs` page whose ordering does not reflect actual chronological
   order across the two sources.

6. **PARTIALLY ADDRESSED, re-verified against current code.** The `?filter=<cache_status>` query
   param is still only applied in the nginx branch (`routes/logs.rs:94-96` at original writing);
   the syslog branch (`state.config.syslog_enabled == true`) still silently ignores it if present
   in the URL. What changed since original writing: #865/#848 (commit `2137157f`) gave the
   syslog branch its own, differently-shaped `?host=` filter (restricting the tail to one wired
   host's subdirectory, backed by a real dropdown in `logs.html`'s syslog-mode branch and a new
   `list_syslog_hosts()` helper), and the code's own comment now explicitly documents the
   `?filter`/`?host` split as intentional ("kept separate from the nginx branch's `?filter=`,
   which filters by cache_status and has no meaning for syslog lines"). So the specific
   *cache-status* filter is still nginx-only and still silently ignored in syslog mode (the
   original claim), but this is no longer an *unflagged* asymmetry with no code-level marker --
   it is now an explicitly documented, deliberate design split, with a real (if different) filter
   mechanism on the syslog side. Originally flagged in the SoT inventory as an unflagged
   asymmetry; that characterization needed correcting there too (see the sibling
   `docs/inventory-ui-routes` PR in this same review pass).

---

## netdata_proxy.rs -- `GET /api/netdata/{*path}`

7. No per-route timeout beyond the global 10s `reqwest::Client` default
   (`main.rs:719-720`) -- fine on its own, but there is no upper bound on response body size
   read via `upstream.bytes().await` (`routes/netdata_proxy.rs:60-63`); a compromised or
   misbehaving Netdata container (or an operator who points `NETDATA_URL` somewhere unexpected)
   could return an unbounded response body that this handler buffers entirely into memory
   before responding. Low severity given Netdata is a same-compose-network, operator-trusted
   service, but noting the gap since this is the one route in the whole `routes/` directory that
   proxies an arbitrary-size upstream response.

8. `params.iter()` (a `HashMap<String,String>`) is extended into the query string in
   nondeterministic order per request (`routes/netdata_proxy.rs:38-40`). Harmless for Netdata's
   own API (order-independent query params), but notable as the one place in this directory
   that could produce non-reproducible request logs/traces if ever needed for debugging.

---

## setup.rs -- `GET /setup`, `POST /setup/update`

9. **Doc comment vs. code mismatch: `SettingsError::into_response`'s comment claims "both error
   paths below use fixed messages," but `update_stack_settings` has three error-construction
   call sites, and the third interpolates a dynamic value.** (`routes/setup.rs:71-85` and
   `routes/setup.rs:120-144`) The comment at line 77-81 says:
   ```rust
   // No user input is ever interpolated into this body (both error paths below use fixed
   // messages), so this never needs to escape untrusted content...
   ```
   but `update_stack_settings` actually has three `SettingsError::new(...)` call sites: the CSRF
   failure (fixed message), the invalid-channel failure (fixed message), and:
   ```rust
   .map_err(|err| SettingsError::new(StatusCode::INTERNAL_SERVER_ERROR, err.to_string()))?;
   ```
   which interpolates `persist_stack_settings`'s `DhcpError`'s `Display` output directly, and
   that string is later embedded unescaped into the HTML body in `into_response`. In practice
   `persist_stack_settings`'s only failure mode today is a filesystem/io error whose text is
   operator-config-derived (a path from `state.config.ui_settings_file`), not end-user request
   input, so this is not currently exploitable as stored/reflected XSS -- but the comment's
   claim is factually wrong (there are 3 paths, not "both"/2, and the third is not fixed), which
   is exactly the kind of stale invariant-claim that could mislead a future contributor into
   reusing this pattern somewhere the error text *is* attacker-influenced.

---

## dns_snapshots.rs -- `POST /domains/zones/rollback`

10. **`rollback_zone_snapshot` always redirects to `/domains` regardless of whether the
    downstream rollback actually succeeded, with zero operator-visible error signal, directly
    contradicting `CONTRIBUTING.md`'s Admin UI section** ("Avoid hiding operational failures...
    show a clear error instead of pretending that the action succeeded."). (`routes/
    dns_snapshots.rs:134-173`) Both the non-2xx-response branch and the network-failure branch
    only `tracing::error!(...)` server-side and then still `Ok(Redirect::to("/domains"))`. There
    is no flash-message/error-banner mechanism in `templates/domains.html` (confirmed: no
    match for flash/error_message/notice/alert in that template) for this or any other route in
    this file, so an operator who clicks "rollback" against, e.g., a temporarily-unreachable
    `nats-subscriber` listener, or an invalid zone/snapshot-id combination the listener itself
    rejects, sees an identical page reload to a successful rollback. This is the same failure
    class the SoT document already flagged as an E2E *coverage* gap for this route, but the
    deeper issue here is a genuine *product* gap independent of test coverage: even a manual,
    fully-successful-latency-aside test of this route cannot distinguish success from failure
    from the browser.

---

## domains.rs -- CDN domain list, LAN DNS records, AAAA filter

11. **~~Same silent-failure-on-write pattern as finding #10, twice more in this file, and
    inconsistently applied within the same file.~~ FIXED by #878 (commit `53a5ba7f`).**
    (`routes/domains.rs`, originally cited at `:94-158`, now shifted by the fix's own +182-line
    diff) `add_dns` and `remove_dns` previously did:
    ```rust
    if let Err(e) = wrote {
        tracing::error!("Failed to write dns domain: {}", e);
    } else {
        flush_recursor_cache(&state, &domain.domain).await;
        if state.config.ssl_enabled {
            restart_ssl(&state).await;
        }
    }
    Ok(Redirect::to("/domains"))
    ```
    -- the `Ok(Redirect::to("/domains"))` was unconditional; a failed file write (disk full,
    permission error, or the bind-mount EBUSY fallback path itself failing) produced the exact
    same response as success. **Confirmed fixed against current `origin/v0.2.0`**: both handlers
    now call a shared `dns_write_result_to_response(wrote, "write"|"remove")` helper immediately
    after the write, which maps a write failure to `Err(StatusCode::INTERNAL_SERVER_ERROR)` via
    `?` before the function ever reaches the recursor-flush/SSL-restart/redirect steps -- verified
    directly in the current source (`dns_write_result_to_response` at line 342, called from both
    `add_dns` line 114 and `remove_dns` line 144), plus the two new regression tests
    `add_dns_write_failure_maps_to_error_not_success` and
    `remove_dns_write_failure_maps_to_error_not_success`. The fix's own commit message confirms
    this mirrors `toggle_aaaa_filter`'s existing convention (see finding #12's original text,
    still applicable) rather than introducing a new pattern. The SoT inventory's separate
    E2E-*coverage*-gap claim for this route pair (no simulation script exercises
    `/domains/dns/add`/`/domains/dns/remove`) is **not** addressed by this fix and still stands --
    #878 only changed the failure-mapping logic, it did not add an E2E test.

12. **`restart_ssl`'s own failure is still swallowed -- NOT addressed by #878, remains a live
    finding.** (`routes/domains.rs:327-333` in current `origin/v0.2.0`) If the domain file write
    (finding #11, now fixed) succeeds but the subsequent SSL proxy restart fails (Docker socket
    proxy unreachable, container already restarting, etc.), the operator still gets redirected
    to `/domains` with no error -- meaning TLS interception for the domain they just added will
    silently not take effect until a manual restart, with the Admin UI's own page implying the
    change is live. Confirmed in current code: `restart_ssl` still only `tracing::error!`s and
    returns `()`, called with `.await` (result discarded) from both `add_dns` and `remove_dns`
    after the (now-checked) file write succeeds. #878's own commit message explicitly scopes this
    as deliberately out of scope ("the best-effort recursor-flush/proxy-restart calls that follow
    a successful write stay fire-and-log, since they are downstream side effects, not the
    request's own mutation") -- so this is a known, accepted gap rather than an oversight, but it
    remains unfixed and operator-visible.

13. **`normalize_lan_name` cannot produce the exact zone-apex name `"lan."` from the bare input
    `"lan"` (no trailing dot) -- it mangles it into `"lan.lan."` instead.**
    (`routes/domains.rs:771-780`)
    ```rust
    fn normalize_lan_name(name: &str) -> String {
        let trimmed = name.trim().to_lowercase();
        if trimmed.ends_with('.') {
            trimmed
        } else if trimmed.ends_with(".lan") {
            format!("{}.", trimmed)
        } else {
            format!("{}.lan.", trimmed)
        }
    }
    ```
    `"lan".ends_with(".lan")` is `false` (the string is too short to contain the leading `.`), so
    a bare `"lan"` falls through to the final branch and becomes `"lan.lan."` -- a subdomain of
    the LAN zone, not the zone apex. An operator wanting to add/remove a record at the exact
    zone root (e.g. an apex TXT or a `lan.` NS-adjacent record) must know to type the trailing
    dot themselves (`"lan."`) to get the intended name; every existing unit test that exercises
    the apex (`validate_lan_record("lan.", ...)`) already passes the trailing dot in directly,
    so this normalization edge case has no test coverage either way.

14. **`MAX_TTL` is `u32::MAX` (4294967295), which exceeds PowerDNS/RFC 2181's signed-32-bit TTL
    range (0..=2147483647).** (`routes/domains.rs:357-358`, used by `validate_lan_record` at
    line 469) A TTL value between `2147483648` and `4294967295` passes this route's own
    validation and gets published to NATS/`nats-subscriber`, which then presumably forwards it
    to PowerDNS's API -- whether PowerDNS accepts, silently truncates/wraps, or rejects such a
    value was not traced further in this file (out of this file's own code), but the UI-level
    validation itself allows a value the DNS protocol/PowerDNS doesn't support, pushing a
    possible failure downstream into the same fire-and-log NATS publish path already flagged as
    silent (`add_lan_record`, line ~188-197) -- i.e. this could compound into a record silently
    never actually being written with the TTL the operator entered.

15. `is_valid_txt_content` (`routes/domains.rs:442-446`) has no upper length bound on TXT record
    content -- only rejects empty and control characters. Combined with `LanRecordForm` having
    no visible request body size cap traced in this file, an operator (or, since this route
    requires authentication+CSRF, at least an authenticated session) could submit an arbitrarily
    large TXT value that this route accepts and forwards via NATS before any PowerDNS-side limit
    is hit. Low severity given the route requires an authenticated admin session already.

16. `fetch_lan_records` (`routes/domains.rs:741-769`) doesn't check `resp.status().is_success()`
    before calling `.json()`, unlike `flush_recursor_cache` in the same file which does check
    success. A non-2xx response from PowerDNS Authoritative still gets parsed as JSON; if it
    happens to be a JSON error body without an `rrsets` key the function correctly falls back to
    `vec![]`, so this is not currently a crash/panic risk, just an inconsistency with the
    success-checking pattern used elsewhere in the same file.

---

## secondaries.rs -- NATS secondary registration

17. **`SECONDARY_REGISTRATION_TOKEN` has no minimum-length/entropy validation at startup, and
    `register_secondary`/`rotate_token` (the two handlers that check it) have no rate-limiting
    or lockout on repeated failed attempts.** (`routes/secondaries.rs:110-140, 217-235`;
    validation in `main.rs`'s `validate_secondary_registration_token`, `main.rs:618-634`) Startup
    validation only rejects an empty token or a known placeholder string -- it does not enforce
    any minimum length. `register_secondary` is deliberately public (not behind Basic Auth, per
    its own module doc and the SoT inventory), and both it and `rotate_token` compare the
    submitted token via constant-time `ct_eq` but never track/limit failed attempts. If an
    operator sets a short/weak token (nothing stops them), an attacker with LAN access to the
    Admin UI's port could brute-force it online with no lockout. The setup docs' recommended
    generation (`openssl rand -hex 32`, 256 bits) makes this a non-issue when followed, but nothing
    in the code enforces that operators actually do.

18. **`register_secondary` allows silently overwriting (hijacking) an existing secondary's
    identity by re-registering with the same `name`, with no uniqueness check and no operator
    confirmation.** (`routes/secondaries.rs:110-188`) `INSERT OR REPLACE INTO secondaries` means
    any caller who knows (or brute-forces, see #17) the shared registration token can register
    with a `name` that already belongs to an active, legitimate secondary; the old row (and its
    NATS password hash) is silently replaced, the original device is locked out on its next
    reconnect, and the attacker/new caller receives a fresh working credential under the same
    identity -- indistinguishable, from the primary's perspective, from the legitimate
    secondary reprovisioning itself. The module's own comment frames this as intentional ("it's
    already the table's primary key, so no separate uniqueness check is needed"), but that
    reasoning only covers the *idempotent-reprovisioning* case, not the *hijack-an-active-
    secondary* case, which the current code cannot distinguish since it has no notion of
    "already registered and currently in use" vs. "never registered."

19. No explicit request body size limit (`axum::extract::DefaultBodyLimit`) was found anywhere
    in `main.rs` for the whole router, including the public, pre-authentication
    `register_secondary`/`rotate_token` JSON endpoints (`routes/secondaries.rs:110-113,
    217-222`). Depending on the axum/tower-http version in use, this may or may not already be
    bounded by a library-level default -- flagging as needing an explicit check rather than
    asserting a concrete exploit, since this pass did not confirm the effective limit.

---

---

## dhcp.rs -- by far the largest and most complex route file (5568 lines; full non-test code,
lines 1-3317, read in full; test module, lines 3318-5568, scanned by test-name coverage)

20. **`add_reservation`'s `hostname` field is submitted to Kea with zero format validation,
    unlike every other identity-bearing field in this file.** (`routes/dhcp.rs:1436-1494`)
    `add_reservation` validates `form.mac` (`is_valid_mac`) and `form.ip` (`is_valid_ip`) before
    use, but `form.hostname` is inserted straight into the reservation JSON
    (`"hostname": form.hostname`, line ~1484) with no length cap, no character-set check, and no
    DNS-label validity check -- a sharp contrast with `routes/domains.rs`'s LAN-record routes,
    which validate every name field against `is_valid_dns_fqdn`/`is_valid_dns_fqdn_allow_
    underscore` before it can reach NATS/PowerDNS. Since Kea's DDNS integration turns a
    reservation's hostname into an actual DNS record (per this project's own architecture, a
    lease/reservation hostname eventually becomes a `dns-standard`-side A/PTR record), an
    unvalidated hostname here could produce a malformed DDNS update that Kea/PowerDNS then has
    to reject or mishandle downstream, with the rejection surfacing far from where the bad input
    was actually accepted. Whether Kea's own config-test/config-set validates hostname shape
    server-side (which would fail this request loudly rather than silently) was not traced
    further outside this file.

21. **PARTIALLY FIXED by #978 (commit `d971063c`) -- the CSRF-exemption half is closed, the
    disruptive auto-trigger-on-every-page-load behavior itself is NOT.** Originally: "`GET /dhcp`
    silently triggers a real, disruptive Docker container restart plus a broadcast DHCP-conflict
    scan on the LAN on every single page load, with no caching, cooldown, or opt-out."
    (`templates/dhcp.html:656-657` at original writing, calling `check_dhcp_conflict` /
    `routes/dhcp.rs:1604-1611, 2100-2185` at original writing)
    `document.addEventListener('DOMContentLoaded', checkDhcpConflict)` means every browser load
    (or reload) of `/dhcp` fires a request to `/api/dhcp/check`, which (`check_dhcp_probe` ->
    `run_dhcp_probe`) stops and restarts the predeclared `dhcp-probe` container and runs a real
    `nmap broadcast-dhcp-discover` scan plus a `dhclient` dry-run on the LAN. `state.
    dhcp_probe_lock` serializes concurrent runs so they queue rather than corrupt each other's
    output, but nothing throttles or caches the result across page loads -- an operator who
    refreshes the page repeatedly (or has a browser extension/monitoring tool auto-refreshing an
    open `/dhcp` tab) queues a fresh stop/start/scan cycle every single time, each one taking real
    wall-clock time (a full nmap broadcast scan plus a dhclient dry-run) and each one emitting a
    real DHCPDISCOVER onto the LAN. This is a meaningful operational side-effect for what looks,
    from the URL, like a plain read-only settings page.

    **What #978 actually changed, confirmed against current `origin/v0.2.0`**: the request was
    previously a plain `GET`, CSRF-exempt because this app's CSRF protection only ever covers
    mutating HTTP methods -- a real security gap, since this "read" silently mutates server state.
    #978 converted the route to `POST /api/dhcp/check` (confirmed in `main.rs`'s route table) with
    an explicit `verify_csrf_header` check inside `check_dhcp_conflict` (mirroring
    `secondaries::remove_secondary`/`rotate_token`), and updated `dhcp.html`'s `fetch()` call to
    `POST` with an `X-CSRF-Token` header sourced from the page's own rendered CSRF token. **The
    CSRF-exemption gap is genuinely closed.** But `dhcp.html`'s
    `document.addEventListener('DOMContentLoaded', checkDhcpConflict)` line is untouched by #978
    -- confirmed still present verbatim in current `templates/dhcp.html` -- so the endpoint still
    fires automatically, unconditionally, on every single page load, exactly as before; only the
    HTTP method and the presence of a CSRF token changed, not the auto-fire behavior or the
    absence of any caching/cooldown/opt-out. #978's own commit message and PR scope confirm this
    was a CSRF-hardening fix (closing issue #947) and made no claim about addressing the
    auto-trigger behavior -- so this is not a regression in the fix, just a distinct problem it
    was never meant to solve. Not present in the SoT inventory (which now documents the CSRF fix
    but not, and never claimed to cover, the auto-trigger-on-page-load behavior).

22. **`remove_subnet_option`'s "nothing matched" case surfaces as a 500 Internal Server Error,
    not a 404, unlike `release_lease`'s explicit not-found handling in the very same file.**
    (`routes/dhcp.rs:1404-1434`, `remove_custom_subnet_option` at line ~2944) When no option
    matches the given code+data, `remove_custom_subnet_option` returns
    `Err("custom option not found")`, which `remove_subnet_option` maps through the generic
    `.map_err(|e| DhcpError::config_error(e.to_string()))?` pipeline -- `config_error` always
    constructs `StatusCode::INTERNAL_SERVER_ERROR`. Compare this to `release_lease`
    (`routes/dhcp.rs:1528-1570`), which explicitly special-cases Kea's own "no matching lease"
    result as `StatusCode::NOT_FOUND`, precisely because "the thing you tried to remove/release
    was already gone" is an ordinary race, not a server failure. A double-submitted "remove
    option" form (e.g. a double click, or a stale page reloaded after someone else already
    removed it) renders as a 500 in this file's own error page and would show up as a real
    backend failure in any monitoring that treats a 500 status as an incident, when the intended
    end state (the option is gone) is already true.

23. **CSRF verification happens after the (side-effect-free) `require_kea_mode` state check in
    every Kea mutation handler, rather than first.** (`routes/dhcp.rs:1196-1198` and every
    following mutation handler in this file follow the identical
    `require_kea_mode(&state)?;` then `crate::routes::verify_csrf_token(...)` order) Not
    exploitable today since `require_kea_mode` only reads already-authenticated-session-visible
    config state and has no side effect, but it is a minor inversion of the usual "verify the
    request is legitimate before doing anything else with it" ordering used elsewhere in this
    project (e.g. `routes/domains.rs`'s handlers all call `verify_csrf_token` as their very
    first statement). Flagging as an info-level consistency note, not a vulnerability.

24. **The Admin UI's own user-facing template text is inconsistently in German across at least
    seven template files rendered by these very routes, contradicting `AGENTS.md`'s explicit
    "Project-facing text must be in English" rule.** Confirmed German strings (JS `alert()`/
    `confirm()` dialogs and status text, not just incidental content) in:
    `templates/dhcp.html` (`checkDhcpConflict()`'s entire status-line vocabulary -- "Prüfe...",
    "Konfliktprobe läuft...", "Fremder DHCP-Server gefunden", "DHCP-Client-Dry-Run
    fehlgeschlagen", "Fehler beim Prüfen: ", etc., lines ~575-635),
    `templates/secondaries.html` (`alert()`/`confirm()` dialogs: "Token erfolgreich rotiert für
    ${name}", "${name} wirklich entfernen?", "Fehler beim Rotieren des Tokens: ...", lines
    ~167-196), `templates/setup.html`, `templates/logs.html`, `templates/domains.html`
    ("Speichern" button label, line 193), `templates/base.html` ("Netdata läuft intern und
    speist die Graphen.", line 118), and `templates/stats.html` ("Netdata-Verbindung nicht
    verfügbar. Starte den Stack mit Netdata:", line 41). This is rendered directly by the routes
    in this component (`dhcp_page` renders `dhcp.html`, `secondaries_page` renders
    `secondaries.html`, `setup_page` renders `setup.html`, `domains_page` renders
    `domains.html`, `logs_page` renders `logs.html`), so it is squarely in scope here even
    though the actual strings live in `templates/`, not the `.rs` files themselves. This reads
    as a systemic language-consistency defect (most of the surrounding UI text is English, with
    German sentences mixed in at specific call sites -- looking like `CLAUDE.md`'s "Chat
    language: German" convention leaking into shipped, English-required "Code language"
    surfaces) rather than an isolated typo, and is not mentioned anywhere in the existing SoT
    inventory.

25. `axum::extract::Json`/`Form` in this axum 0.8 project (`services/ui/Cargo.toml:14`) apply a
    2 MB default body-size limit automatically per-extractor unless explicitly overridden --
    this resolves the concern initially raised in this same pass about `routes/secondaries.rs`'s
    public `register_secondary`/`rotate_token` JSON bodies (see finding #19 above); noting this
    here so the finding isn't miscounted as still-open. No corresponding issue found for this
    file's own `Form` extractors either.

---

## Coverage note

`stats.rs` (14 lines) was read in full in the first commit -- no findings beyond what the SoT
inventory already documents (it is a pure render-only page shell).

All 9 route files plus `mod.rs` (10 files, matching the SoT inventory's own file count) have now
been read in full for their non-test code. `dhcp.rs`'s ~2250-line test module was scanned by
test-name/coverage rather than read line-by-line, given its size; no additional findings were
derived from the test code itself beyond the coverage-gap observations already folded into the
numbered findings above (e.g. finding #20's note that no test exercises `add_reservation`'s
hostname field, since none of the existing tests target it).

This document is the raw, unfiltered output of the collection phase for issue #849 (vacuum-first,
no self-verification during collection, per the maintainer-agreed methodology for this sweep).
Severity judgments in the accompanying tool-call findings are the collecting agent's own
first-pass estimate, not a verified ranking -- verification is a separate, later phase.

