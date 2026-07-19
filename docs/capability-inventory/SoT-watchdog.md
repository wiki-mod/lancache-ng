# Capability inventory: `services/watchdog`

Part of the project-wide capability inventory (#843). Audited file:
`services/watchdog/watchdog.sh` on `origin/v0.2.0` (450 lines), plus its
Dockerfile, env configs, compose wiring, and test coverage. This is a
deeper, function-level companion to `docs/architecture-ng.md`, not a
replacement for it.

Component role: health monitor, auto-restart daemon, daily cache-age purge,
syslog-ng retention engine, and Admin-UI status-file writer.

> **Currency check (2026-07-18):** re-verified against `origin/v0.2.0` @
> `dc8d79c6` (68 commits merged since this doc's `3f53ac3b` base). PR #885
> ("watchdog.sh hardening bundle") added four new bats files --
> `tests/bats/watchdog_disk_info.bats` (4 tests), `tests/bats/watchdog_purge.bats`
> (6 tests), `tests/bats/watchdog_config_validation.bats` (13 tests), and
> `tests/bats/watchdog_curl_timeout.bats` (4 tests) -- confirmed present via
> `git ls-tree` on current `origin/v0.2.0`. This closes the three
> test-coverage gaps this doc calls out below as untested/undertested:
> `disk_info()` (§ below, "never unit-tested at all"), `maybe_purge()`
> ("zero bats coverage... largest test-coverage gap"), and the
> `get_health()`/curl real-endpoint gap. `resolve_cache_dir()`'s specific
> error-exit path was not independently re-confirmed as covered by the new
> `watchdog_config_validation.bats` in this pass -- flagged as likely but
> unconfirmed. See the inline updates on each finding below and the
> re-ranked "Summary of test-coverage gaps" section at the end.

## 1. Monitored containers (tracked in #842, not re-litigated here)

`check_and_maybe_restart()` is called for exactly three containers in the
main loop: `C_PROXY` (`lancache-proxy`), `C_DNS_STD`
(`lancache-dns-standard`), and conditionally `C_DNS_SSL`
(`lancache-dns-ssl`, only when `SSL_ENABLED=1`). `nats`, `ui`, `dhcp`,
`dhcp-proxy`, `netdata`, `syslog-ng`, `docker-socket-proxy` are not
monitored or restarted by this script. See #842 for the design discussion;
this inventory only adds the exhaustive rest of the file's behavior below.

## 2. Every function, in detail

**`log()`** (line 36) -- `echo "[watchdog] $(date -u +%H:%M:%S) $*"`. All
output goes to stdout only; there is no dedicated log level or log file
written by the script itself (see section 5 for how stdout is captured
downstream).

**`resolve_cache_dir()`** (lines 40-68, called once at line 70 to set
`CACHE_DIR`) -- Migration-safety helper for pre-v0.2.0 installs.
Precedence: if `CACHE_DIR` is set, use it verbatim. Else, if both
`CACHE_DIR_STANDARD` and `CACHE_DIR_SSL` are set and disagree, `exit 1`
with an explicit error (refuses to guess which split path is
authoritative). Else falls back to whichever single split var is set, else
hardcoded default `/var/cache/lancache`. **Status: split
`CACHE_DIR_STANDARD`/`CACHE_DIR_SSL` are confirmed EOL** -- `deploy/prod/.env`
states no compose file reads them anymore as of #445; `setup.sh update`
reads them exactly once to migrate into `CACHE_DIR` then deletes both keys.
This function's split-path branches are now pure legacy-migration
dead-weight for any install created after #445 landed, kept only for
pre-v0.2.0 upgraders. **Not covered by any bats test** -- neither
`watchdog_idempotence.bats` nor `watchdog_syslog_prune.bats` calls
`resolve_cache_dir()` directly (only its side effect, a pre-set
`CACHE_DIR`, is used by tests).

**`get_health(name)`** (lines 72-79) -- **updated by PR #885 (2026-07-16)**:
no longer a straight `curl | jq` pipe. Current code captures curl's own exit
status first (`body=$(curl -sf --max-time "$CURL_MAX_TIME"
$DOCKER_PROXY_URL/containers/$name/json) || { echo "unreachable"; return; }`,
`CURL_MAX_TIME` defaulting to 5s), then runs
`jq -r '.State.Health.Status // "none"' <<< "$body"` against the captured
body, falling back to the literal string `"unreachable"` on either the curl
failure or a jq parse failure. The `--max-time` bound and the
capture-then-parse split both exist specifically so a hung/unresponsive
docker-socket-proxy can't stall the whole single-threaded main loop
indefinitely (a bare pipe would let an empty curl stdout reach `jq`'s
`// "none"` fallback silently, never producing `"unreachable"`). **Was never
tested against a real or mocked HTTP endpoint as of this audit
(2026-07-15); now partially covered** by `tests/bats/watchdog_curl_timeout.bats`
(added by PR #885, 2026-07-16), which stubs `curl` itself (not `get_health()`)
so the function's real curl+jq logic runs under test -- confirmed 4 tests
covering the `--max-time` flag being passed, `CURL_MAX_TIME` override, and
the `"unreachable"` bash fallback on a real curl failure. The `// "none"`
jq-fallback sub-case (an HTTP response with no `.State.Health.Status` field)
was not independently confirmed as covered in this pass.

**`restart_container(name)`** (lines 81-88) -- **updated by PR #885
(2026-07-16)**: `curl -sf --max-time "$CURL_MAX_TIME" -X POST
$DOCKER_PROXY_URL/containers/$name/restart`, logs `WARNING: restart call
failed for $name` on failure but does not retry or escalate. Comment notes
restart is *intentionally* the only mutating Docker call the socket-proxy
allowlist permits (no create/exec). **Partially fixed, same as
`get_health()`'s test-gap class**: `tests/bats/watchdog_curl_timeout.bats`
(added by PR #885) confirms the `--max-time` flag is passed, but no test
drives a real curl failure through `restart_container()`, so the
`WARNING: restart call failed` log branch itself is still untested.

**`health_color(status)`** (lines 90-98) -- maps Docker health strings to
dashboard colors: `healthy`->green, `starting`->yellow, `unhealthy`->red,
anything else (including `none`/`unreachable`)->yellow (default case).
**Only the `healthy`->green path is exercised by tests** (via
`write_status` assertions in `watchdog_idempotence.bats`); `starting`,
`unhealthy`, and the `none`/`unreachable` default-to-yellow fallback are
never asserted anywhere. Design note: a genuinely unreachable Docker
socket proxy (`"unreachable"`) renders identically to a container still
`starting` (both yellow) -- an operator cannot distinguish "container is
booting" from "watchdog itself lost Docker API access" from the color
alone.

**`disk_info(dir)`** (lines 100-112) -- returns `unknown` status if `dir`
doesn't exist; otherwise runs **`df -P "$dir"`** (updated by PR #885,
2026-07-16 -- `-P` forces POSIX single-line output so a long overlay/mapper
device name can't wrap onto its own line and shift `awk 'NR==2'` onto the
wrong row), extracts the `Use%` column via awk into `${pct:-0}` (also added
by PR #885, so a `df` failure or unexpected output shape still produces
valid JSON instead of a syntactically-broken `{"pct": , ...}`), and buckets
into `red` (>= `DISK_ALARM_PCT`, default 95), `yellow` (>= `DISK_WARN_PCT`,
default 85), else `green`. **Was not directly
unit-tested at all as of this audit (2026-07-15); now covered by
`tests/bats/watchdog_disk_info.bats` (4 tests), added by the same PR #885
change described above (see the sibling bughunt-watchdog doc's findings
#2/#3).** It's invoked as a side effect of `write_status()`,
but every bats assertion explicitly strips the `"disk"` key from the JSON
before comparing (`jq 'del(.updated, .disk)'`), specifically because live
`df` output is non-deterministic in CI. That means the actual threshold
math (off-by-one at exactly 85%/95%, `df` parse failures defaulting
`pct=0`, the `[ -d "$dir" ]` unknown-status branch) has zero assertions
anywhere. **Consequence of the `write_status()` finding below:
`disk_info()` never calls `log()`, and its only output sink is the
`disk.cache` block inside `STATUS_FILE`.** Since nothing reads that file
(see below), `DISK_WARN_PCT`/`DISK_ALARM_PCT` currently produce neither a
log line nor any consumed signal anywhere in the stack -- disk-space
alerting is a fully implemented but end-to-end dead path, not just an
undertested function.

**`check_and_maybe_restart(name, fcount_ref, hstring_ref)`** (lines
120-140) -- uses bash namerefs (`local -n`) to mutate the caller's own
`F_*`/`H_*` globals in place. Increments the failure counter **only** on
the exact string `"unhealthy"`, restarts and resets the counter once it
reaches `RESTART_AFTER` (default 3), and resets the counter (logging
`RECOVERED` if it was previously nonzero) **only** on the exact string
`"healthy"`. Every other `get_health()` result -- `"starting"` (expected,
transient), but also `"none"` (container has no Docker healthcheck defined
at all) and `"unreachable"` (the Docker socket proxy itself is
unreachable) -- falls through both branches untouched: the counter neither
increments nor resets, and no restart is ever triggered. **Behavioral gap
worth flagging explicitly: auto-restart is a silent no-op for any
monitored container that lacks a working Docker healthcheck, and equally a
silent no-op for all three monitored containers simultaneously if
`docker-socket-proxy` itself goes down** -- there is no separate alarm path
for "watchdog can no longer see anything," it just quietly stops
restarting. **Well tested for the paths it does cover**:
`watchdog_idempotence.bats` proves the full unhealthy-streak-then-restart
cycle, the early-recovery-resets-without-restarting near-miss case, and
repeats each scenario across multiple cycles to prove convergence (no
counter drift) -- but no test drives a `"none"` or `"unreachable"` sequence
through this function, so the no-op gap above is undocumented by tests
too, only found by reading the code.

**`write_status()`** (lines 150-175) -- writes `STATUS_FILE` (default
`/var/run/watchdog/status.json`) via string interpolation (not a JSON
library), atomically through a `.tmp` + `mv`. Emits per-container
`status`/`health`/`failures`, plus a `disk.cache` block from
`disk_info()`. Its own header comment states the file is "consumed by the
Admin UI dashboard." **Well tested for structural convergence/atomicity**
(no leftover `.tmp`, identical JSON across repeated writes, SSL-enabled
branch). **Major cross-referenced finding, Admin UI half: this file is not
consumed by the Admin UI.** Grepping the entire `services/ui/src/` tree for
`status.json`, `STATUS_FILE`, or `watchdog-status` (the named Docker
volume backing `/var/run/watchdog`) returns zero matches. The
`watchdog-status` volume is mounted only into the `watchdog` container
itself in all three compose files (`deploy/dev`, `deploy/prod`,
`deploy/quickstart`) -- never into `ui`. The Admin UI's actual dashboard
health/status (`services/ui/src/routes/dashboard.rs`) instead queries
nginx's own `stub_status` module directly via
`nginx_client::get_stub_status()`, a completely independent mechanism that
duplicates none of `get_health()`/`health_color()`/`write_status()`'s
logic. Per `AGENTS.md`'s Feature Completeness section ("if backend code
supports a feature but the Admin UI does not expose it, treat that as UI
delivery debt by default"), this reads as exactly that category: the
Admin-UI side of this consumer was never wired. Flagging as inventory
here, not proposing removal or a fix. Not previously flagged in any open
issue found by search. **Currency update (2026-07-18): the file is no
longer unconsumed overall.** PR #885 added `services/watchdog/healthcheck.sh`,
a Docker `HEALTHCHECK` (wired into `watchdog` in all four compose files,
including the previously-uncovered `full-setup`) that reads `STATUS_FILE`'s
mtime to detect a stalled main loop -- a real runtime dependency on
`write_status()` continuing to refresh this file every cycle. The Admin-UI
delivery-debt finding above still stands; only the broader "not consumed by
anything" framing needed correcting.

**`maybe_purge()`** (lines 177-223) -- daily (rate-limited via
`PURGE_STAMP`, 86400s) deletion of cache files older than
`CACHE_VALID_DAYS` (default 365) under `CACHE_DIR`. Validates the stamp is
all-digits (resets to 0 with a logged error otherwise), forces decimal
parsing via `10#$last` to avoid octal misinterpretation of stamps like
`"08"`, and clamps a future-dated stamp back to 0. Validates
`CACHE_VALID_DAYS` the same all-digits way, skipping the purge entirely if
invalid. Uses a single `find -print0` / `while read -d ''` loop (fixed in
#112, which had previously logged a count from a separate, mismatched find
call). Stamp-in-`/tmp` volatility was fixed in #111 (stamp now lives under
`/var/run/watchdog`, which is a named volume, so it survives container
restarts). **Had zero bats coverage as of this audit (2026-07-15) --
confirmed by grep: `maybe_purge` appeared in `watchdog_syslog_prune.bats`
only inside a comment describing the helper-extraction range, never as an
actual test invocation, and did not appear in `watchdog_idempotence.bats`
at all. This was the single largest test-coverage gap found in this file.
Now FIXED**: `tests/bats/watchdog_purge.bats` (6 tests), added by PR #885
(2026-07-16, the same PR that also fixed `maybe_purge()`'s
false-success-stamp-on-missing-`CACHE_DIR` bug), confirmed present on
current `origin/v0.2.0`. Its sibling `maybe_prune_syslog()` (below) still
has more dedicated tests (~10 vs 6), but the "zero coverage" gap itself is
closed.

**`maybe_prune_syslog()`** (lines 249-435, by far the largest function in
the file) -- **updated by PR #877 (2026-07-16, `73a4fe0`)**: the gate used
to be a fail-closed no-op unless `SYSLOG_ENABLED=true` exactly; it now uses
the shared `is_truthy()` helper, accepting `1`/`true`/`yes`/`on`
case-insensitively, matching the Admin UI's `env_bool()` parsing so the two
no longer disagree on values like `SYSLOG_ENABLED=yes` (opt-in `logging`
profile still required either way). Rate-limited daily via its own
`SYSLOG_PRUNE_STAMP`, same stamp-validation idiom as `maybe_purge()`.
Two-pass retention engine per #633/#757:

- **Pass 1 (age)**: deletes anything under `SYSLOG_LOG_ROOT` (default
  `/var/log/lancache-syslog-ng`) older than `SYSLOG_RETENTION_DAYS`
  (default 30), a floor not the primary control.
- **Pass 2 (size)**: re-measures with `du -sb`; if still over
  `SYSLOG_MAX_GB` (default 10; **also floored by PR #877, 2026-07-16**: a
  value below 1 GiB -- including a literal `0`, which the pre-existing
  digit-only validation let through unchanged -- falls back to the default
  10 instead of producing a 0-byte budget that would make the size pass
  treat every file as over budget, matching the Admin UI's
  `env_u32_clamped()` minimum; and hard-clamped at 1048576 GiB / 1 PiB to
  prevent signed 64-bit overflow in the `max_gb * 1024^3` multiplication,
  per #757 review), deletes oldest-first by `%T@` mtime regardless of age,
  explicitly skipping today's per-host `$YEAR$MONTH$DAY.log` file (still
  open for writing by syslog-ng; unlinking it would orphan the inode).
- Every `find`/`du` failure path is a bare `return` (not `return 1`),
  deliberately, since the script runs under `set -euo pipefail` and a hard
  failure here must not kill the whole watchdog daemon.
- **Excellently tested**: `watchdog_syslog_prune.bats` has ~10 tests
  covering the fail-closed no-op, age-only pruning, size-only no-op-under-
  budget, the exact age-then-size priority ordering (a fixture proving an
  in-retention file still gets removed by the size pass), oldest-first size
  pruning in isolation, rate-limit no-op on second run, invalid-input
  clamping for both `SYSLOG_RETENTION_DAYS` and `SYSLOG_MAX_GB`,
  missing-`SYSLOG_LOG_ROOT` handling, today's-active-file protection, and
  the overflow-clamp itself. This is the best-tested single function in
  this file relative to its complexity.
- **Wiring note**: `SYSLOG_ENABLED`/`SYSLOG_MAX_GB`/`SYSLOG_RETENTION_DAYS`
  are injected via top-level `.env` -> compose `environment:` block (not
  via `config/*/watchdog.env`, unlike every other watchdog var).
  `SYSLOG_LOG_ROOT` is deliberately *not* wired anywhere in compose
  (documented in `deploy/prod/docker-compose.yml`): the script's own
  default matches the fixed bind-mount target shared with the `syslog-ng`
  service, and overriding it would silently break pruning without changing
  where syslog-ng actually writes. So `SYSLOG_LOG_ROOT` exists as a
  script/test-only override, not an operator-facing knob.

## 3. Env vars -- full list and where each is actually set

| Var | Default | Set via `config/{dev,prod}/watchdog.env`? | Notes |
|---|---|---|---|
| `DOCKER_PROXY_URL` | `http://docker-socket-proxy:2375` | yes | |
| `CHECK_INTERVAL` | `30` | yes | main loop sleep |
| `RESTART_AFTER` | `3` | yes | |
| `DISK_WARN_PCT` | `85` | yes | |
| `DISK_ALARM_PCT` | `95` | yes | |
| `CACHE_VALID_DAYS` | `365` | yes | |
| `STATUS_FILE` | `/var/run/watchdog/status.json` | no (script default only) | see orphan finding above |
| `SSL_ENABLED` | `1` | yes | |
| `CONTAINER_PROXY` / `CONTAINER_DNS_STANDARD` / `CONTAINER_DNS_SSL` | `lancache-proxy` / `lancache-dns-standard` / `lancache-dns-ssl` | yes | |
| `CACHE_DIR` | `/var/cache/lancache` | yes | |
| `CACHE_DIR_STANDARD` / `CACHE_DIR_SSL` | unset | no, not documented in either env file | EOL per #445, migration-only |
| `SYSLOG_ENABLED` | `false` | no -- wired via compose `environment:` from root `.env` | |
| `SYSLOG_MAX_GB` | `10` | no -- same as above | |
| `SYSLOG_RETENTION_DAYS` | `30` | no -- same as above | |
| `SYSLOG_LOG_ROOT` | `/var/log/lancache-syslog-ng` | no, intentionally unwired anywhere | script/test-only override |
| `PURGE_STAMP` / `SYSLOG_PRUNE_STAMP` | hardcoded paths under `/var/run/watchdog` | not overridable via env at all (no `${VAR:-...}` indirection) | |

## 4. Timestamp/stamp-file mechanisms

Two independent rate-limiting mechanisms, both following the same idiom
(digit-only validation via `case ''|*[!0-9]*)`, forced decimal parsing via
`10#$var`, future-timestamp clamping): `PURGE_STAMP` (24h),
`SYSLOG_PRUNE_STAMP` (24h). Both live under `/var/run/watchdog`, which is
the same named volume (`watchdog-status`) as `STATUS_FILE` -- so despite
the orphaned-consumer finding above, this volume is not itself dead: it is
load-bearing for surviving container restarts without re-triggering a
purge/prune storm (the exact bug #111 fixed for `PURGE_STAMP`).

## 5. Logging/stdout capture (not in watchdog.sh itself, but part of its runtime contract)

`watchdog.sh`'s `log()` writes only to stdout; per #633, the compose files
override the entrypoint (`entrypoint: ["/bin/bash", "-c"]` + `exec
/watchdog.sh > >(tee -a /var/log/lancache-watchdog/watchdog.log) 2>&1`) to
additionally tee stdout into a file that fluent-bit tails for the central
syslog-ng pipeline, while `exec` keeps `watchdog.sh` as PID 1 for correct
signal handling. This is compose-level wiring, not part of the script, but
is the only place the script's log level (there is none -- `log()` has no
severity distinction) gets structured downstream.

## 6. Cross-referenced issues

- #842 (open) -- narrow container-monitoring scope, already covered, not
  duplicated here.
- #111 (closed) -- `PURGE_STAMP` volatility in `/tmp`; verified fixed,
  stamp now under the persistent `/var/run/watchdog` volume.
- #112 (closed) -- `maybe_purge()` double-find count mismatch; verified
  fixed, single `find -print0` loop.
- #86 (closed) -- "watchdog has no tests in CI test matrix"; largely
  addressed for `check_and_maybe_restart`/`write_status`/
  `maybe_prune_syslog`, but see the `maybe_purge()`/`resolve_cache_dir()`/
  `get_health()`/`restart_container()`/`disk_info()`/`health_color()` gaps
  above -- whether #86 should be treated as fully closed-the-loop given
  these gaps is a call for whoever triages this inventory, not asserted
  here as a reopen.
- #445 (closed) -- single `CACHE_DIR` migration; confirms
  `resolve_cache_dir()`'s split-path branches are legacy-only.
- #633 / #757 (closed) -- syslog retention engine origin; both fully
  reflected in the current `maybe_prune_syslog()` implementation and its
  test suite.
- No existing open issue was found (searched "watchdog", "status.json",
  "disk_info", "resolve_cache_dir") covering the orphaned-`STATUS_FILE`/
  Admin-UI-never-reads-it finding in section 2 -- this appears to be new.

## 7. Summary of test-coverage gaps (ranked by size of gap)

> **Currency check (2026-07-18):** items 1-3 below are FIXED by PR #885
> (2026-07-16), which added `watchdog_purge.bats`, `watchdog_curl_timeout.bats`,
> and `watchdog_disk_info.bats`. Original ranking preserved for the
> historical record; current status noted per item.

1. `maybe_purge()` -- zero direct test coverage despite sharing the exact
   stamp-validation idiom and historical bug class (#111/#112) as the
   extensively-tested `maybe_prune_syslog()`. **FIXED**: `watchdog_purge.bats`
   (6 tests).
2. `get_health()` / `restart_container()` -- the real curl+jq/curl-POST
   logic (including the `"unreachable"` and `WARNING: restart call failed`
   branches) is always stubbed out in bats, never exercised.
   **`get_health()`: FIXED** (curl-boundary-stubbed, not function-stubbed):
   `watchdog_curl_timeout.bats` (4 tests) covers `--max-time` wiring,
   `CURL_MAX_TIME` override, and the `"unreachable"` fallback on curl
   failure; the `// "none"` jq-fallback sub-case was not independently
   confirmed. **`restart_container()`: only partially fixed** -- the same
   file confirms its `--max-time` wiring, but no test drives a curl failure
   through `restart_container()`, so the `WARNING: restart call failed`
   log branch remains untested; do not treat this item as closed for
   `restart_container()`.
3. `disk_info()` -- threshold math (85%/95% boundaries, `df` parse
   failure, missing-dir unknown status) is never directly asserted; only
   indirectly invoked and then explicitly stripped from JSON comparisons.
   **FIXED**: `watchdog_disk_info.bats` (4 tests).
4. `resolve_cache_dir()` -- no direct test; its error-exit path
   (disagreeing split cache dirs) and legacy-fallback branches are
   unexercised. **Not independently re-confirmed this pass** -- may be
   partially covered by the new `watchdog_config_validation.bats` (13
   tests), but this wasn't verified line-by-line against that file's
   actual assertions.
5. `health_color()` -- only the `healthy`->green mapping is asserted;
   `starting`, `unhealthy`, and the `none`/`unreachable`->yellow default
   are not. **Not independently re-confirmed this pass.**

Best-covered in this file: `check_and_maybe_restart()` and
`maybe_prune_syslog()`, both with multi-scenario convergence/idempotence-
style test suites -- though `check_and_maybe_restart()`'s `"none"`/
`"unreachable"` silent-no-op path (section 2) is untested even there (not
independently re-confirmed this pass).

## 8. Posting status

Findings from this file were also posted as a single English GitHub
comment on the umbrella issue #843 (`## services/watchdog capability
inventory`), per that issue's log-as-comments convention.
