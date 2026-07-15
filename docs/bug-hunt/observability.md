# Bug hunt: Observability (`netdata` / `syslog-ng` / `fluent-bit`)

Part of the project-wide vacuum-first bug-hunt sweep (umbrella issue #849,
sub-issue of #843). This is a raw findings collection, not a filtered/
pre-verified report — per the sweep's agreed methodology, verification is a
separate, later phase run from the orchestrating workflow itself, not by this
pass. Every item below was independently re-derived by reading the current
code on `origin/v0.2.0` (not merely copied from the earlier capability
inventory), even where it overlaps with items already noted in
`docs/capability-inventory/SoT-observability.md` (branch
`docs/inventory-observability`) or the issue #843 comment that preceded it.

Scope: `netdata` service, the `syslog`(fluent-bit)/`syslog-ng` central logging
pipeline as wired in `deploy/{dev,prod,quickstart,full-setup}/docker-compose.yml`,
`services/syslog/netdata-web_log.conf`, `services/ui/src/routes/netdata_proxy.rs`,
`services/ui/src/routes/logs.rs`, `services/ui/src/syslog_client.rs`,
`services/ui/src/routes/dashboard.rs`, `services/ui/src/templates/{dashboard,logs,stats,base}.html`,
`services/watchdog/watchdog.sh`, `scripts/check-logging-matrix.sh`,
`docs/architecture-ng.md`, `docs/threat-model.md`.

Read against `origin/v0.2.0` in a dedicated clone (`bughunt-observability`
branch based on `origin/v0.2.0`), not the maintainer's main checkout.

---

## Findings

### 1. Docs claim a per-service "traffic light bar" in the Admin UI that does not exist anywhere in the code

`docs/architecture-ng.md` states, in two places:
- Line ~153 (Watchdog section): "**Status:** displayed as traffic light bar in Admin UI (green/yellow/red per service)"
- Line ~235 (Monitoring section): "Watchdog traffic light bar: one indicator per service, persistently visible"

Exhaustively grepped the entire Admin UI template set
(`services/ui/src/templates/*.html`) for `bg-green`/`bg-red`/`bg-yellow`/
`indicator`/`health_color`/`watchdog` and read `base.html` (the shared layout
every page extends) end to end: there is no per-service colored status
indicator anywhere. `base.html`'s sidebar only shows the runtime image tag/
channel and a static "Netdata läuft intern und speist die Graphen" note — no
health data. `dashboard.html` has no such element either. No Rust route
(`main.rs`'s router, `dashboard.rs`, `metrics_api`) ever queries or exposes
per-container health/color state; `docker_client.rs` only exposes
`restart_service`/`start_service`/`stop_service_if_present`/
`container_name_for_service`. `services/watchdog/watchdog.sh` computes
exactly this data (`health_color()`, `write_status()`) but nothing in the
Admin UI reads it (see Finding 2). This is a genuine, currently-shipping
documentation-vs-code drift (AG-DOC-001 territory), not a misreading — the
feature the docs describe for the current release simply isn't there.

### 2. `watchdog.sh`'s `write_status()`/`STATUS_FILE`/`watchdog-status` volume content is never rendered to an operator

`write_status()` runs every `CHECK_INTERVAL` (default 30s) and writes a JSON
file (per-service health color, failure counts, disk pct/color) to
`STATUS_FILE` (default `/var/run/watchdog/status.json`) on the
`watchdog-status` named volume. Grepped every compose file, every Rust route,
and every template for `status.json`/`STATUS_FILE`/`watchdog-status`:

- The `watchdog-status` volume is declared and mounted **only** onto the
  `watchdog` container itself in `deploy/{dev,prod,quickstart}/docker-compose.yml`
  (e.g. `deploy/dev/docker-compose.yml:216`). No other service in any of
  these three real compose files mounts it.
- The Admin UI's own volume list (`deploy/dev/docker-compose.yml`'s `ui:`
  service, ~line 1143 onward) does not include `watchdog-status` at all.
- The only place `status.json` is referenced outside `watchdog.sh` itself is
  `deploy/full-setup/docker-compose.yml:188`'s CI-only validation
  healthcheck: `test -f /var/run/watchdog/status.json || exit 1`. That is a
  **CI-only existence check** ("did watchdog write *a* file"), not a
  consumer of the file's content (disk pct/color, per-service health), and
  `deploy/full-setup` is a CI validation harness, not a real deployment
  target.
- Confirmed the real `watchdog` service definitions in `dev`/`prod`/
  `quickstart` have **no `healthcheck:` block at all** (only `full-setup`'s
  watchdog gets one) — so even Docker's own `docker inspect` health status
  for watchdog is unavailable to an operator in a real deployment.

Precise framing (revised after an advisor pass flagged an earlier overreach
in this same finding): it is not that literally nothing references the file
anywhere in the repo — CI's `full-setup` does check it exists — but that in
every real deployment (`dev`/`prod`/`quickstart`), the file's *content* is
computed on a 30s cycle and then never read by anything. This is a real,
verified monitoring-visibility gap, not dead code in the strict sense and not
a security defect by itself.

### 3. Threat model's T9 mitigation ("Disk-usage warnings/alarms via the watchdog and Netdata") is not actually operator-visible today

`docs/threat-model.md` line ~376 lists this as an existing mitigation for
T9 (cache-exhaustion/request-flood DoS). Both halves are true in isolation
but neither is currently visible to an operator:
- Watchdog's `disk_info()` computes `DISK_WARN_PCT`/`DISK_ALARM_PCT`-based
  yellow/red status for `CACHE_DIR`'s filesystem — but per Finding 2, this
  lands only in `status.json`, which nothing reads in a real deployment.
  There is also no `log()` call anywhere in `watchdog.sh` announcing a
  warn/alarm threshold crossing to `docker logs watchdog` either — the
  color transition is silent even to someone tailing the container's own
  stdout.
- Netdata's stock default alarm templates do run (per the existing
  capability-inventory research), but have no notification integration and
  no Admin UI surface, and the native dashboard (port 19999) is never
  published to the host in any of the 4 compose files (grepped `19999`
  across all of `deploy/*` — only ever the internal `NETDATA_URL` env var or
  the full-setup healthcheck).
- The Admin UI does have its own, *different* disk-adjacent metric
  (`dashboard.rs`'s `cache_pct = cache_used_gb / cache_max_gb`), but that
  compares usage against the operator's *configured* cache-size setting, not
  the underlying filesystem's actual free space — it does not substitute for
  watchdog's `df`-based physical-disk-fullness check.

Net effect: an operator relying on the threat model's stated mitigation for
T9 has, in the current real deployment, no way to see either half of it
without manually running `df`/`docker exec`-ing into containers. Moderate
severity: a visibility gap in a named threat-model mitigation, not an
exploitable vulnerability by itself.

### 4. `SYSLOG_ENABLED` boolean-parsing mismatch between the Admin UI and watchdog.sh

- `services/ui/src/config.rs`'s `env_bool()` (used for `Config::syslog_enabled`)
  accepts, case-insensitively: `"1"`, `"true"`, `"yes"`, `"on"` as true and
  `"0"`, `"false"`, `"no"`, `"off"` as false.
- `services/watchdog/watchdog.sh`'s `maybe_prune_syslog()` gates on
  `if [ "$SYSLOG_ENABLED" != "true" ]` — an **exact, case-sensitive** string
  comparison against the literal `true` only.

Both containers receive the identical raw compose env var
(`SYSLOG_ENABLED=${SYSLOG_ENABLED:-false}`), so if an operator sets, e.g.,
`SYSLOG_ENABLED=1` or `SYSLOG_ENABLED=yes` or `SYSLOG_ENABLED=True` in their
`.env` — all reasonable, common ways to write "on" for a boolean env var, and
all explicitly accepted by the UI's own `env_bool()` — the Admin UI will
correctly treat syslog mode as enabled (switches `/logs` and the dashboard
tile to syslog-ng mode), giving the operator every reason to believe central
logging + retention is fully active, while `watchdog.sh`'s retention/pruning
engine **silently no-ops forever** (fail-closed by design, but with zero
warning surfaced anywhere). This directly contradicts the UI's own code
comment (`config.rs` ~line 615, and the compose file comment at
`deploy/dev/docker-compose.yml:1215-1218`) which explicitly claims: "same 4
vars/defaults as the watchdog retention engine ... so the UI's 'enabled'
toggle and its actual budget display always agree with what watchdog is
enforcing." That guarantee is false for every accepted value other than the
literal `"true"`. Real-world risk: unbounded syslog-ng storage growth on an
install the operator believes has retention enabled, discovered only when
disk fills up. `tests/bats/watchdog_syslog_prune.bats` only tests the
literal `false`/unset no-op case, never a truthy-but-not-`"true"` value, so
there is no test that would have caught this cross-component mismatch
either.

### 5. `SYSLOG_MAX_GB` numeric-clamp mismatch between the Admin UI and watchdog.sh

`watchdog.sh`'s `maybe_prune_syslog()` explicitly clamps an oversized
`SYSLOG_MAX_GB` to 1,048,576 GiB (1 PiB) with a logged warning, specifically
to avoid a signed 64-bit arithmetic overflow when multiplied by 1024³. The
Admin UI's `env_u32_clamped()` (`config.rs`) has no equivalent magnitude
clamp — it only rejects non-numeric or `<1` values, falling back to the
compiled default (10) for those, but happily accepts any `u32` value up to
~4.29 billion. Since `1,048,577..4,294,967,295` all pass `env_u32_clamped`
uncleaned while watchdog silently clamps to 1,048,576, an operator who sets
an absurdly large `SYSLOG_MAX_GB` would see the dashboard display a budget
number (`syslog_max_gb` in `dashboard.rs`/`dashboard.html`) that does not
match what watchdog is actually enforcing. Low real-world likelihood (needs
a deliberately huge value), but a real, verified parity gap between the two
"same contract" implementations.

### 6. Netdata's `web_log` collector wiring is inconsistent across dev/quickstart/prod — prod gets none of it despite producing the source file

Directly verified (not just re-cited from the earlier inventory) via grep
across all three real compose files:

| Compose file | `logs:/var/log/lancache` mount on `netdata` | `netdata-web_log.conf` bind-mount onto `/etc/netdata/go.d/web_log.conf` | `file=nginx-proxy.log` produced by fluent-bit |
|---|---|---|---|
| `deploy/dev` | yes (`:ro`, line 1253) | yes (line 1254) | yes (line 564) |
| `deploy/quickstart` | yes (`:ro`, line 1297) | **no** | yes (line 312) |
| `deploy/prod` | **no** | **no** | yes (line 609) |

`prod` — the primary real deployment target most operators actually run —
gets **zero** netdata web-log analytics: neither the source file nor the
collector config is available to it, even though fluent-bit dutifully
produces `nginx-proxy.log` there too. This 3-way inconsistency is invisible
to `scripts/check-logging-matrix.sh` (see Finding 8) since that script only
checks matrix-row existence per Compose service, not per-collector wiring
parity across the three files.

### 7. Netdata has no Docker healthcheck in any real deployment — but a working one already exists in CI, proving this is fixable, not a technical limitation

Confirmed via grep: `deploy/{dev,prod,quickstart}/docker-compose.yml`'s
`netdata:` service blocks have no `healthcheck:` at all. Only
`deploy/full-setup/docker-compose.yml:385-389` (CI-only validation compose)
defines one: `test: ["CMD-SHELL", "curl -sf http://127.0.0.1:19999/api/v1/info ..."]`,
using the identical pinned image
(`netdata/netdata@sha256:a130dbbf3d6e6a5472efdebaa123797190a5822627e908106d34edae02bc8a74`)
as the real deployments. `.github/workflows/build-push.yml`'s
`services_with_healthcheck="proxy dns-standard dns-ssl watchdog nats ui netdata"`
(~line 2359) actively waits for and asserts this healthcheck reports
`healthy` in CI. Since the identical image/healthcheck combination is proven
to work in `full-setup`, its absence from `dev`/`prod`/`quickstart` is a
confirmed, fixable inconsistency, not something the image can't support.

### 8. `syslog-ng`'s healthcheck is real but orphaned — nothing acts on "unhealthy"

`syslog-ng`'s `healthcheck` (`syslog-ng-ctl healthcheck --timeout 5`) is a
genuine liveness probe (unlike fluent-bit's binary-only `-V` check). However:
- Docker itself does not restart a container automatically on a failing
  `HEALTHCHECK` — that status is purely informational via `docker inspect`
  unless something external (an autoheal sidecar, a monitor) acts on it.
  Grepped the whole repo for `autoheal`/`willfarrell`/`restart-unhealthy`:
  none exists.
- `watchdog.sh`'s `check_and_maybe_restart()` loop (main loop, bottom of the
  file) only monitors and can restart exactly three hardcoded containers:
  `$C_PROXY`, `$C_DNS_STD`, `$C_DNS_SSL`. `netdata`, `ui`, `nats`,
  `syslog-ng`, `syslog` (fluent-bit), `dhcp`, and `dhcp-proxy` are never
  monitored or auto-restarted by watchdog at all.

Net effect: a `syslog-ng` process that wedges internally (passes the
container-alive check but its control socket hangs) would sit reporting
`unhealthy` in `docker inspect` indefinitely, with no automatic corrective
action from anything in this project, and (per Finding 2) no UI surface to
even notice the status short of manually running `docker inspect`.

### 9. `logs.rs` hardcodes `host=None` and silently drops `?filter=` in syslog mode (reverified directly in current code, not taken from the prior inventory on faith)

`services/ui/src/routes/logs.rs`, `logs_page()`:
```rust
if state.config.syslog_enabled {
    let mut syslog_logs = tokio::task::spawn_blocking(move || {
        syslog_client::parse_syslog_tail(&log_root, None, 200)
    })
    ...
}
```
`host` is hardcoded `None` even though `syslog_client::parse_syslog_tail`
fully supports per-host filtering (`Some(h)`) and is unit-tested for exactly
that. The `LogFilter.filter` query param is read via the `Query<LogFilter>`
extractor but is only ever applied (`all_logs.retain(...)`) in the
**non-syslog** branch — in syslog mode it is silently accepted and ignored
with no error. `logs.html`'s syslog-mode branch (confirmed by reading the
template) has **no filter UI at all** (no host search box, no cache-status
buttons) — consistent with the backend gap, but meaning there is currently
no way, UI or API, to view one service's logs in isolation once syslog mode
is on.

### 10. Latent path-traversal landmine for whoever fixes Finding 9

`syslog_client::parse_syslog_tail(log_root: &str, host: Option<&str>, ...)`:
```rust
let host_dirs = match host {
    Some(h) => vec![Path::new(log_root).join(h)],
    None => list_host_dirs(log_root),
};
```
If `host` is ever wired up from user input (the exact fix Finding 9 calls
for — e.g. a `?host=` query param), the `Some(h)` branch joins that string
directly into a `Path` with **zero validation** — no `..` check, no
allowlist — unlike the project's own established pattern in the same file
(`get_syslog_size_gb` explicitly rejects any path containing `".."`). Currently
unreachable (the only caller always passes `None`), so not exploitable
today, but a real landmine for whoever implements the per-host filter fix
without independently noticing this gap.

### 11. `netdata_proxy.rs` hardcodes response `Content-Type: application/json` regardless of the upstream's actual format

```rust
Response::builder()
    .status(status.as_u16())
    .header("content-type", "application/json")
    .body(Body::from(body_bytes))
```
Both allowlisted netdata endpoints (`data`, `charts`) support a `format=`
query parameter (`json`/`csv`/`html`/etc. in netdata's own API). The proxy
forces `application/json` on every response regardless of what `format` the
caller actually requested. Currently harmless because the only real caller
(`stats.html`'s `fetchChart()`) always passes `format=json`, but a manual
`curl /api/netdata/data?chart=system.cpu&format=csv` (allowed by the
allowlist — only the endpoint *name* is restricted, not other params) would
receive CSV bytes mislabeled as `application/json`.

### 12. `stats.html`'s error banner only ever displays once per page load

```js
let errorShown = false;
...
async function refresh() {
  try {
    ... // 4 chart fetches
    document.getElementById('netdata-error').classList.add('hidden');
  } catch (e) {
    if (!errorShown) {
      document.getElementById('netdata-error').classList.remove('hidden');
      errorShown = true;
    }
  }
}
```
`errorShown` is set `true` on the first failure and **never reset to
`false`** on a subsequent successful `refresh()`. So: netdata goes down →
banner shows once → netdata recovers → banner correctly hides (via the
`try` block's `classList.add('hidden')`) → netdata goes down again later →
`if (!errorShown)` is now false → the banner never reappears for the rest of
that page load, even though the connection is genuinely lost again. Only a
full page reload resets the JS state.

### 13. Dashboard's per-host syslog stats are computed every render but never displayed

`syslog_client::get_syslog_stats()` computes `SyslogHostStats { host, files,
size_bytes, days }` per host on every `/` (dashboard) render (confirmed in
`dashboard.rs` lines ~73-80). `dashboard.html`'s syslog card (line ~145) only
renders the aggregate `syslog_stats.hosts | length` (a bare count) and
`syslog_stats.total_files` — the per-host breakdown the backend already
computed is discarded. Textbook instance of this project's own Feature
Completeness rule (backend capability exists, Admin UI doesn't expose it).

### 14. `docs/architecture-ng.md`'s top-of-file services table contradicts its own later, more complete section

Line ~11 (top services table): "syslog-ng | off (`--profile logging`) | — |
Central log receiver; fluent-bit forwards proxy access logs to it (#453)" —
but the same document's own "Currently implemented" section (line ~163) and
full logging-matrix table (lines ~177-190) correctly describe **9** wired
services, not just the proxy. Internal drift within one file, not
code-vs-doc drift.

### 15. `docs/architecture-ng.md` cites the now-closed #633 for a still-open gap

Lines ~245-246 ("Logs: filtered by service, level selectable (not yet
implemented against the central syslog-ng path; see follow-up #633)" and
"syslog forwarding configuration is not yet exposed in the UI; see
follow-up #633") both cite #633 as the tracking issue — but #633 itself is
closed (2026-07-13, per project history), while the underlying gaps they
describe (Finding 9, and no forwarding-destination config in the UI) are
still real and current in the code checked this session. A reader following
`#633` today lands on a closed issue with no signal that the specific gap
cited is still open (AG-DOC-001 territory).

### 16. `scripts/check-logging-matrix.sh` structurally cannot catch the netdata web_log wiring drift (Finding 6)

Read the script in full: by its own explicit design (stated in its own
header comment), it only verifies that every real Compose service has *a*
row in the logging-matrix table and that every row names a real service —
it deliberately does not check *how* a service is wired ("that's a human
judgment call ... not something worth encoding as a second source of
truth"). This means the dev/quickstart/prod inconsistency in Finding 6 is
categorically outside what this CI guard can ever detect, since it concerns
a *sub-collector's* wiring parity across files, not a service's mere
presence in the matrix.

### 17. `syslog-ng`'s zstd install runs fresh on every container (re)start, not baked into the image

```bash
(
  if ! command -v zstd >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y --no-install-recommends zstd >/dev/null 2>&1 || true
  fi
  while true; do ... done
) &
```
Since `balabit/syslog-ng:latest` doesn't ship `zstd` and this compose-embedded
script is the only place it's installed, every container start (not just the
first ever start of a fresh install, every `docker compose restart`/host
reboot/image-repull too) re-attempts `apt-get update && apt-get install
zstd`. If network egress is blocked (a scenario the project's own comments
elsewhere explicitly anticipate — "e.g. no network egress"), this adds a
network-timeout delay to every restart before falling back to gzip, and
silently swallows the failure (`|| true`) with no operator-visible log line
noting that compression fell back to gzip for this container's lifetime.
Additionally: if the initial attempt fails, nothing re-attempts installing
zstd later even if network recovers mid-lifetime of that container instance
— the `while true` loop's own `if command -v zstd` check inside the loop
will keep evaluating false forever once the initial install attempt failed.

### 18. `write_status()`'s comment claims a guarantee the code doesn't enforce

```bash
# Written with plain string interpolation ... every value going into the
# template is either a fixed enum ... an integer counter, or a container
# name we ourselves defaulted, so there's no untrusted/arbitrary string
# that could break the JSON structure.
```
`$C_PROXY`/`$C_DNS_STD`/`$C_DNS_SSL` default to fixed strings but are fully
operator-overridable via `CONTAINER_PROXY`/`CONTAINER_DNS_STANDARD`/
`CONTAINER_DNS_SSL` env vars (per this project's own naming-convention
overrides). If an operator ever sets one of these to a value containing a
literal `"` or backslash, the hand-built JSON heredoc in `write_status()`
would be corrupted — contradicting the comment's explicit claim that no
untrusted/arbitrary string can reach this path. Low real-world impact given
Finding 2 (nothing currently reads `status.json` in a real deployment
anyway), but the comment's stated invariant is not actually true.

### 19. Dashboard's "Recent requests" tile and `/logs` disagree on which log source to use once syslog mode is on

`dashboard.rs`'s `recent_logs_task` always calls
`nginx_client::parse_log_tail` directly against `STANDARD_LOG`/`SSL_LOG`,
unconditionally — it never switches to the syslog-ng merged store the way
`routes/logs.rs`'s `logs_page()` does when `SYSLOG_ENABLED=true`. Not clearly
a bug (nginx keeps writing its own access log regardless of whether
`syslog-ng` is also receiving a copy), but it does mean the dashboard's
"Recent requests" tile and the dedicated `/logs` page can show different
underlying data sources on the same install once syslog mode is enabled,
which could confuse an operator comparing the two views.

### 20. Netdata's full HTTP API is reachable, unauthenticated, by any other container on the shared network (reverified directly, not just cited from prior inventory)

Confirmed directly: `netdata` sits on the plain `lancache` Docker network
like every other service (all 3 real compose files) — it is not on the
`docker-api` internal network, and has no other network-level isolation.
The Admin UI's `netdata_proxy.rs` allowlist (`ALLOWED_NETDATA_ENDPOINTS =
["data", "charts"]`) only constrains what the *Admin UI's own outbound
proxy path* can request — it does nothing to restrict any other container
on the same Docker network from calling `http://netdata:19999/api/v1/alarms`,
`/api/v1/info`, `/api/v1/allmetrics`, etc. directly. This mirrors the
project's already-documented threat-model treatment of read-only
Docker-socket access as a residual risk concentrated in netdata (see
`docs/threat-model.md` T-series section on Docker socket access), just
applied to netdata's own HTTP surface specifically, which the threat model
does not currently call out.

---

## Summary table

| # | Area | Severity (this pass's own estimate, not yet independently verified) |
|---|---|---|
| 1 | Docs vs. code: "traffic light bar" doesn't exist | Serious |
| 2 | watchdog status.json never rendered to an operator | Moderate |
| 3 | Threat-model T9 mitigation not operator-visible | Moderate |
| 4 | `SYSLOG_ENABLED` bool-parsing mismatch (UI vs watchdog) | Serious |
| 5 | `SYSLOG_MAX_GB` clamp mismatch (UI vs watchdog) | Minor |
| 6 | netdata web_log wiring inconsistent dev/quickstart/prod | Moderate |
| 7 | netdata no healthcheck in real deploys (CI proves it's fixable) | Minor |
| 8 | syslog-ng healthcheck orphaned, nothing consumes it | Moderate |
| 9 | `logs.rs` host=None / dropped `?filter=` in syslog mode | Serious |
| 10 | Path-traversal landmine in `parse_syslog_tail`'s host param | Minor |
| 11 | netdata_proxy hardcodes Content-Type: application/json | Minor |
| 12 | `stats.html` error banner only shows once per page load | Minor |
| 13 | Dashboard per-host syslog stats computed, never rendered | Minor |
| 14 | architecture-ng.md stale summary line (internal drift) | Info |
| 15 | architecture-ng.md cites closed #633 for open gap | Info |
| 16 | check-logging-matrix.sh structurally can't catch Finding 6 | Info |
| 17 | syslog-ng zstd install repeats every restart, no retry later | Info |
| 18 | write_status() comment claims an unenforced guarantee | Info |
| 19 | Dashboard vs /logs disagree on log source in syslog mode | Info |
| 20 | netdata's full API reachable by any container on the network | Info |

All findings above were derived by directly reading the current code/config/
docs on `origin/v0.2.0` in a dedicated clone this session. None have been
independently verified yet — that is explicitly a separate, later phase per
this sweep's agreed methodology.
