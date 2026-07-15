# Bug hunt: services/ui core

CLD-1784120597

Part of the project-wide "vacuum-first" bug-hunt sweep tracked in issue #849
(sub-issue of #843). This is a raw, unfiltered collection pass over the
**core** module surface of `services/ui` — `main.rs`, `config.rs`,
`nats_auth_callout.rs`, `nats_config.rs`, `session.rs`, `docker_client.rs`,
`nginx_client.rs`, `syslog_client.rs`, and `kea_snapshots.rs` (explicitly
assigned to this pass, even though the parallel `docs/inventory-ui-core`
capability inventory scoped it to the DHCP-route agent instead — noted below
where relevant). `routes/mod.rs`'s shared helpers are covered too, since this
component's SoT document covers them.

Per the agreed methodology for this sweep: nothing below has been
pre-filtered or self-verified. Severity labels are a first-pass estimate only,
not a final triage — that happens in a later, separate verification phase.
All source was read directly from `origin/v0.2.0` (checked out as this
branch's parent) to match the capability-inventory document's own branch
convention.

Starting point: `docs/capability-inventory/SoT-ui-core.md` (branch
`docs/inventory-ui-core`) and the original audit comment on issue #843. That
document is a floor, not a ceiling, for this pass — several items below
overlap with it (repeated here deliberately per the "vacuum first" rule), and
several are new.

---

## 1. `config.rs` — `resolve_cache_max_gb` silently swallows malformed legacy values

**File**: `services/ui/src/config.rs`, function `resolve_cache_max_gb` (~line 686)

`CACHE_MAX_GB`'s own parse already falls through silently on a bad value
(`.and_then(|value| value.parse::<f64>().ok())`), but the legacy
`STANDARD_CACHE_MAX_GB`/`SSL_CACHE_MAX_GB` fallback goes further: each side
individually does `.parse().unwrap_or(50.0)` (or `unwrap_or(standard)` for
the SSL side). A non-numeric legacy value is never rejected or logged — it
silently becomes `50.0` (or silently inherits the other, valid, side's
value), and the explicit "these disagree, panic" fail-closed check only
fires when the *parsed* values differ, so a malformed value that happens to
coerce to the same number as its sibling never triggers it either.

Concretely: `STANDARD_CACHE_MAX_GB=abc`, `SSL_CACHE_MAX_GB=50`,
`CACHE_MAX_GB` unset → `standard` parses to `50.0` (fallback), `ssl` parses
to `50.0`, no disagreement is detected, and the UI silently starts with
`cache_max_gb = 50.0` as if that were a validated, intentional value, with
zero log line anywhere pointing at the malformed `STANDARD_CACHE_MAX_GB`.
This is inconsistent with this same file's `UI_SESSION_TTL_SECONDS` handling
(`env_u64`), which explicitly errors out on a non-numeric value instead of
silently defaulting.

**Severity estimate**: moderate (config-validation fail-open, inconsistent
with the rest of the file's own stated fail-closed philosophy; not reachable
by an external attacker, only misconfiguration).

---

## 2. `config.rs` — `derive_lancache_image_channel`'s `v`-prefix check is too broad

**File**: `services/ui/src/config.rs`, function `derive_lancache_image_channel` (~line 640)

```rust
} else if tag.starts_with("sha-") || tag.starts_with('v') {
    "pinned".to_string()
}
```

Any tag starting with the single ASCII character `v` is classified as
"pinned", not just a `vX.Y.Z`-shaped release tag. A mutable/arbitrary tag
like `very-old-tag`, `vnext`, or `v-testing` would be mislabeled "pinned" in
the Admin UI's release-channel display, even though nothing about it is
actually a pinned release. This is display-only (not a security issue), but
it can mislead an operator into believing their install is pinned to a
specific version when it isn't.

**Severity estimate**: minor / info (display-only, but a real deterministic
edge case, not a hypothetical).

---

## 3. `nats_auth_callout.rs` — subscribe-failure path never applies exponential backoff

**File**: `services/ui/src/nats_auth_callout.rs`, `run_auth_callout` (~line 370)

```rust
let mut sub = match client.subscribe(REQUEST_AUTH_SUBJECT).await {
    Ok(s) => s,
    Err(err) => {
        tracing::error!(...);
        tokio::time::sleep(delay).await;
        continue;
    }
};
```

The connect-failure branch above this does `delay = min(delay * 2, max_delay)`
on every failure (proper exponential backoff, 1s→30s cap). The
subscribe-failure branch does not — it sleeps whatever `delay` currently is
and `continue`s, which re-enters the loop from the top and reconnects to
NATS. Since a successful reconnect resets `delay` back to `1s` right before
subscribe is attempted again, a *persistently* failing subscribe (e.g. a
permissions problem specifically on `$SYS.REQ.USER.AUTH`, as opposed to a
connection failure) causes the responder to hot-loop reconnect + subscribe
roughly once per second indefinitely, rather than backing off the way every
other retry loop in this file (and `connect_nats_with_retry` in `main.rs`)
does.

**Severity estimate**: moderate (missing backoff on one specific failure
path; would show up as sustained ~1 req/s reconnect traffic against the local
NATS broker under a specific misconfiguration, not a crash).

---

## 4. `nats_auth_callout.rs` — `now_unix()` silently returns 0 on clock skew before epoch

**File**: `services/ui/src/nats_auth_callout.rs`, `now_unix()` (~line 127)

```rust
fn now_unix() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64
}
```

If the system clock reads before the Unix epoch (container clock
misconfiguration), this silently returns `0` rather than erroring or
logging. Every subsequently issued user JWT would then compute `iat = 0`,
`exp = 0 + USER_JWT_TTL_SECS` (~90 days after epoch, i.e. 1970), meaning
every issued secondary credential would already be expired the moment it's
issued, with no diagnostic anywhere explaining why secondaries suddenly
cannot connect.

**Severity estimate**: minor / info (real but requires a badly-misconfigured
host clock; silent rather than logged).

---

## 5. `secondaries.nats_user` has no DB-level uniqueness constraint

**Files**: `services/ui/src/main.rs` (schema/migration),
`services/ui/src/nats_auth_callout.rs` (`authorize_secondary_with_conn`)

The `secondaries` table's `nats_user` column (added by
`migrate_secondaries_table_for_auth_callout`) has no `UNIQUE` constraint —
only `name` (PK) and `consumer_name` are unique. `authorize_secondary_with_conn`
does `SELECT nats_password_hash FROM secondaries WHERE nats_user = ?1` with
no `ORDER BY`/uniqueness assumption enforced at the schema level; `rusqlite`'s
`query_row` silently uses whichever row SQLite returns first if more than one
row shares the same `nats_user`. Today this is only reachable if the
(out-of-scope, `routes/secondaries.rs`) generation logic ever produced a
collision, but the schema itself provides no defense-in-depth against that —
uniqueness is a purely application-level invariant, unenforced by SQLite.

**Severity estimate**: minor / info (defense-in-depth gap, not a currently
demonstrated exploit path — the generator is presumed to use a CSPRNG-derived
unique value, but that code is out of this pass's file list).

---

## 6. `nginx_client::get_cache_size_gb` / `syslog_client::get_syslog_size_gb` — prefix allowlist has no path-boundary check

**Files**: `services/ui/src/nginx_client.rs` (~line 297),
`services/ui/src/syslog_client.rs` (~line 242)

Both functions gate their `du -sb` shell-out behind an allowlist check of the
form:

```rust
if !allowed_prefixes.iter().any(|prefix| path.starts_with(prefix)) {
    return 0.0;
}
```

`str::starts_with` is a raw string-prefix check, not a path-segment boundary
check. A path like `/opt/lancache-ng/cache-evil-sibling` would pass the
`nginx_client` allowlist (prefix `/opt/lancache-ng/cache`) even though it is
a sibling directory, not a subdirectory, of the intended cache root; the
same applies to `syslog_client`'s single-entry allowlist
(`/var/log/lancache-syslog-ng-something-else` would pass the
`/var/log/lancache-syslog-ng` prefix check). Both functions' own doc
comments/inline comments describe this allowlist as "a real path-traversal
guard, not just a comment" — the boundary gap means it is slightly less
strict than that framing implies. Currently only reachable via
operator-configured `CACHE_DIR`/`SYSLOG_LOG_ROOT` values, not raw
request input, so exploitability today is low, but the check itself doesn't
actually enforce the directory boundary it appears to.

**Severity estimate**: minor (real gap in an allowlist boundary check; low
exploitability today given the only inputs are operator-controlled config
values, not request-controlled).

---

## 7. `kea_snapshots.rs` — `read_snapshot` has no defense-in-depth against a hostile `id`

**File**: `services/ui/src/kea_snapshots.rs`, `read_snapshot` (~line 150)

```rust
pub fn read_snapshot(snapshot_root: &Path, id: &str) -> Result<Value, KeaSnapshotError> {
    let path = snapshot_root.join(id).join(SNAPSHOT_FILE_NAME);
    ...
}
```

The function's own doc comment explicitly says the path-traversal guard is
the *caller's* responsibility ("Callers must only pass an `id` obtained from
`list_snapshot_ids`... that membership check is this module's path-traversal
guard"). `read_snapshot` itself performs zero validation of `id` — no
rejection of `..`, path separators, or absolute paths. I confirmed the one
current caller, `routes/dhcp.rs::rollback_kea_snapshot`, does correctly check
`known_ids.iter().any(|id| id == &form.snapshot_id)` before calling
`read_snapshot`, and since `list_snapshot_ids`' ids come from
`fs::read_dir` entry names (which cannot contain path separators), this is
safe *today*. But note: in Rust, `Path::join` on an **absolute** `id`
argument *replaces* the base path entirely rather than concatenating — so if
any future or alternate caller ever passes an unchecked `id` (e.g. a
refactor that forgets to replicate the membership check, or a new
route/API that reuses this module), `read_snapshot` would read an arbitrary
absolute path with no error, no log, and no indication anything unusual
happened. This is a security boundary that lives entirely in the caller with
zero enforcement in the module whose actual job is the filesystem I/O.

**Severity estimate**: minor today (mitigated by the one real caller),
info/moderate as a defense-in-depth gap that a future change could
silently reopen. Flagging explicitly since this module's own doc comment
already flags the design tradeoff — the goal here is to note it lives in
`kea_snapshots.rs` itself, not only `routes/dhcp.rs`.

*Scoping note*: `docs/capability-inventory/SoT-ui-core.md` explicitly
excludes `kea_snapshots.rs` from its own analysis, attributing it to the
DHCP-route agent's parallel pass — but this file is explicitly listed in
this bug-hunt task's assigned component, so it's covered here regardless of
that other document's scoping choice, per this sweep's "say so explicitly
rather than dropping it silently" rule.

---

## 8. `routes/mod.rs::render()` — template-render failure still returns HTTP 200

**File**: `services/ui/src/routes/mod.rs`, `render()` (~line 24)

On a Tera rendering error, both the dev-mode and prod-mode branches return
`Html<String>` with no explicit status code override — `Html<T>`'s
`IntoResponse` implementation defaults to `200 OK`. So a template rendering
failure (a real server-side error) is indistinguishable, at the HTTP status
level, from a successful page render; only the response *body* text differs.
Any external health-check/monitoring/automation that keys off HTTP status
rather than parsing body content for "Template Rendering Failed" would treat
a broken page render as a success.

**Severity estimate**: minor (real, but low-impact given human eyeballs
observe the message directly on the actual admin page; genuinely misleading
for status-code-based automation).

---

## 9. `services/ui/Cargo.toml` — `reqwest` TLS feature name deviates from `AGENTS.md`'s literal text

**File**: `services/ui/Cargo.toml`, line 18; cross-referenced against
`.github/AGENTS.md`'s "TLS in Rust" coding pattern.

`AGENTS.md` says: *"use `reqwest` with `default-features = false, features =
["rustls-tls"]`. Never add `openssl-sys` as a dependency."* The actual
manifest is:

```
reqwest = { version = "0.13", default-features = false, features = ["json", "stream", "rustls"] }
```

i.e. the feature is named `rustls`, not `rustls-tls`. I confirmed via
`Cargo.lock` that no `openssl-sys` is anywhere in the dependency tree and
`rustls 0.23.41` is present, so the actual *intent* of the governance rule
(no OpenSSL) is honored — this looks like reqwest 0.13's TLS feature having
been renamed/restructured from the older `rustls-tls` naming used in
reqwest's pre-0.12 releases, which `AGENTS.md`'s text still literally
reflects. A contributor following `AGENTS.md`'s literal feature name on this
pinned reqwest major version would get a "feature does not exist" Cargo
error. This is a governance-doc/actual-dependency-version drift, not a code
bug.

**Severity estimate**: info (documentation accuracy issue, not a runtime
defect; flagging per this sweep's "doc inaccuracies count too" instruction).

---

## 10. `main.rs::init_tracing()` — a bad `UI_LOG_FILE` path fails completely silently

**File**: `services/ui/src/main.rs`, `init_tracing()` (~line 653)

```rust
let file_layer = OpenOptions::new()
    .create(true)
    .append(true)
    .open(&ui_log_file)
    .ok()
    .map(|file| ...);
```

This is documented as intentional ("a missing/unwritable log path is never a
hard failure"), and that's a reasonable design given tracing itself isn't
initialized yet at this point (chicken-and-egg: nothing can log the failure
to log). But the practical consequence is that an operator who typos
`UI_LOG_FILE` (e.g. points it at a directory that doesn't exist, or a path
the container user can't write) gets silently downgraded to stdout-only
logging with **no diagnostic anywhere** — not in the file (it doesn't exist),
not in stdout (nothing announces the fallback), not in any later log line.
The only way to notice is to go looking for the file and find it missing.

**Severity estimate**: info (matches documented intent, but there's a
concrete, easy operator-observability improvement available: log a one-line
stdout-only warning after `init_tracing()` returns, once the stdout layer is
guaranteed to exist).

---

## 11. Confirmed correct (independently re-verified), not a finding: CI does run `cargo test` for `services/ui`

Re-verified directly against `origin/v0.2.0`'s `.github/workflows/build-push.yml`
(extracted with `MSYS_NO_PATHCONV=1 git show origin/v0.2.0:.github/workflows/build-push.yml`,
per the capability-inventory document's own documented gotcha about `git show
<ref>:<path>` silently mangling under MSYS path conversion on this Windows
host): the `ui_test` job (line ~2652) runs `cargo test --locked
--manifest-path services/ui/Cargo.toml` via
`./.github/actions/cargo-with-sccache-fallback`, gated by
`detect-changes.outputs.ui`/`workflow`, after `ui_rust_quality` (fmt/clippy).
This matches — and independently confirms — `SoT-ui-core.md`'s own
already-corrected section 11. Recorded here as a positive confirmation, not
a new finding, since this sweep is meant to be exhaustive rather than only
listing problems.

---

## 12. Items already identified in `SoT-ui-core.md`, re-confirmed directly against the code (repeated here per "vacuum first, don't skip because it's already documented")

- `impl fmt::Display for Config` (`config.rs` ~line 314) is a decorative stub
  (`"Config {{ template_dir: {:?}, cdn_domains_file: {:?}, ... }}"` literal
  ellipsis, 2 of ~55 fields). Confirmed nothing in the read files calls it.
- `docker_client.rs` has zero `#[cfg(test)]` coverage; confirmed
  `container_name_for_service`'s match arms are pure and would be trivial to
  unit test.
- `routes/mod.rs` has two near-duplicate CSRF helpers, `verify_csrf_token`
  (explicit token parameter) and `verify_csrf_header` (reads
  `x-csrf-token` itself) — confirmed both do the same
  `subtle::ConstantTimeEq` check against the session header, just with
  different call conventions.
- `nginx_client.rs`'s `log_regex()` 8 capture groups are positionally coupled
  to `services/proxy/nginx.conf`'s `log_format` directive with no automated
  check tying the two together — confirmed the regex and the doc comment
  both call this out, but there really is no test/CI check enforcing it.
- The four documented, open, deferred-hardening items in
  `nats_auth_callout.rs`'s module doc (`xkey` encryption #682/#839,
  unverified incoming request signature #839, no active-disconnect-on-
  revocation #681, unsalted-SHA-256-not-Argon2id #680) — confirmed present
  verbatim in the current module doc comment, all still open per the
  document's own citation.
- `scripts/ui-rust-checks.sh` referenced by nothing in the repo except its
  own doc page (`docs/ui-rust-dev-checks.md`) — not independently re-grepped
  in this pass (accepted as already verified by the capability-inventory
  document), noted here only for completeness of the raw sweep list.

---

## Files read in full for this pass

- `services/ui/src/main.rs`
- `services/ui/src/config.rs`
- `services/ui/src/nats_auth_callout.rs`
- `services/ui/src/nats_config.rs`
- `services/ui/src/session.rs`
- `services/ui/src/docker_client.rs`
- `services/ui/src/nginx_client.rs`
- `services/ui/src/syslog_client.rs`
- `services/ui/src/kea_snapshots.rs`
- `services/ui/src/routes/mod.rs`
- `services/ui/Cargo.toml` / `Cargo.lock` (dependency/feature cross-check)
- `.github/workflows/build-push.yml` (CI wiring cross-check, extracted via
  `MSYS_NO_PATHCONV=1`)
- Spot-checked `services/ui/src/routes/dhcp.rs` (`rollback_kea_snapshot`,
  ~line 1645) only to verify the one real caller of
  `kea_snapshots::read_snapshot` does the membership check it depends on —
  not a full read of that file, which belongs to the DHCP-route agent's own
  pass.

## Methodology note

This is a raw collection pass, not a final verdict. Severity labels above are
a first estimate for triage convenience only. No finding here has been
dismissed as "already known" or "probably fine" — per the sweep's own rule,
everything observed is recorded, and filtering/verification happens in a
later, separate phase.
