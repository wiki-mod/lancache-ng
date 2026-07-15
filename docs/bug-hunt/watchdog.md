# Bug hunt: `services/watchdog`

Part of the unscoped, exhaustive bug-hunt sweep tracked under issue #849
(sub-issue of the project-wide capability inventory, #843). Component:
`services/watchdog/watchdog.sh`, its `Dockerfile`/`.dockerignore`, its
compose wiring across `deploy/dev`, `deploy/prod`, `deploy/quickstart`,
`deploy/full-setup`, its env configs (`config/{dev,prod}/watchdog.env`),
its bats test suite (`tests/bats/watchdog_idempotence.bats`,
`tests/bats/watchdog_syslog_prune.bats`, `tests/bats/helpers/watchdog-helpers.sh`),
its CI wiring (`.github/workflows/build-push.yml`,
`.github/workflows/build-tools.yml`, `.github/workflows/full-setup-validate.yml`,
`.github/workflows/full-setup-deep-validate.yml`), its cross-component
dependency `scripts/docker-socket-proxy.sh`, and `docs/architecture-ng.md`'s
watchdog section.

Methodology: exhaustive, unscoped read-through (no pre-filtering, no
self-verification during collection -- verification is a later, separate
phase). Starting point was `docs/capability-inventory/SoT-watchdog.md`
(branch `docs/inventory-watchdog`) and the matching narrative comment on
issue #843, both read in full before this pass began; this document does
not re-litigate every SoT item verbatim but does re-confirm the load-bearing
ones directly against the code, and focuses primarily on what the SoT pass
did not already surface (CI wiring, cross-file/cross-service coupling,
documentation-vs-code mismatches).

All line numbers below reference `services/watchdog/watchdog.sh` at
`origin/v0.2.0` (450 lines) unless stated otherwise.

---

## 1. CI: the watchdog bats test suite does not run for a watchdog.sh-only change

**Severity: critical.**

`build-push.yml` has a dedicated `watchdog_test` job (and a
`watchdog_test-hosted` GitHub-hosted fallback) that correctly triggers when
`services/watchdog/**` changes (via `detect-changes.outputs.watchdog`, which
is computed by `scripts/classify-image-impact.sh:139`:
`output_bool "watchdog" touches_prefix "services/watchdog/"`). But both jobs'
entire body is:

```yaml
- name: test (watchdog)
  run: |
    bash -n services/watchdog/watchdog.sh
    test -x services/watchdog/watchdog.sh
```

(`.github/workflows/build-push.yml:2987-2990` and `:3009-3012`) -- a syntax
check and an executable-bit check. Neither job ever runs `bats`.

Grepping the entire `build-push.yml` for `bats` (case-insensitive) returns
zero matches. The *only* place in the whole CI surface that actually
executes `bats tests/bats` (which is the whole `tests/bats/` directory, not
watchdog-specific) is a single step in `.github/workflows/build-tools.yml`:

```yaml
docker run --rm ... "${BUILD_TOOLS_SCAN_IMAGE_AMD64:?...}" \
  bash -lc 'set -euo pipefail; bats tests/bats'
```

(`build-tools.yml:336-345`, labeled "Run Bats setup fixtures").

But `build-tools.yml`'s own trigger is path-filtered and does **not**
include `services/watchdog/` (or any `services/**` path) at all:

```yaml
on:
  workflow_dispatch:
  schedule:
    - cron: "23 3 * * 0"
  push:
    branches: [master, v0.2.0]
    paths:
      - "tools/build-tools/**"
      - ".github/workflows/build-tools.yml"
      - "tests/bats/**"
      - "tests/shellspec/**"
      - "setup.sh"
      - "scripts/check-idempotence-test-coverage.sh"
  pull_request:
    branches: [master, v0.2.0]
    paths: [... identical list ...]
```

(`build-tools.yml:21-44`.)

Net effect: a pull request that changes only `services/watchdog/watchdog.sh`
(the single most likely real-world change to this component) correctly
triggers `watchdog_test`/`watchdog_test-hosted`, both of which pass on
syntax/executable-bit alone, and does **not** trigger `build-tools.yml`,
which is the only place `watchdog_idempotence.bats` and
`watchdog_syslog_prune.bats` ever execute. Those two bats files contain
well-written, "excellently tested" (per the SoT's own words) coverage for
`check_and_maybe_restart()`, `write_status()`, and `maybe_prune_syslog()` --
but none of it runs in CI for the PR that actually changes the logic it's
supposed to protect. It would only run via the weekly Sunday 03:23 UTC cron,
a manual `workflow_dispatch`, or a PR that happens to also touch
`tests/bats/**`/`tests/shellspec/**`/`setup.sh`/etc. in the same diff --
i.e., typically only *after* a behavioral regression has already merged to
`master`/`v0.2.0`.

This isn't specific to watchdog -- the same trigger gap would affect every
other bats-tested shell component in the repo (`tests/bats/*.bats` covers
more than just watchdog) -- but it directly undermines the specific,
repeatedly-praised-as-well-tested claims made about this file in the SoT,
in code comments, and in CHANGELOG history (#111, #112, #633, #757).

**Evidence**: direct greps of `build-push.yml` (zero `bats` matches),
`build-tools.yml` (the sole `bats tests/bats` invocation plus its path
filter), and `scripts/classify-image-impact.sh:139` confirming the disjoint
trigger sets.

---

## 2. `disk_info()` can emit syntactically invalid JSON

**Severity: serious.**

```sh
disk_info() {
    local dir="$1"
    [ -d "$dir" ] || { printf '{"pct": 0, "status": "unknown"}'; return; }
    local pct
    pct=$(df "$dir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}') || pct=0
    local status="green"
    if   [ "${pct:-0}" -ge "$DISK_ALARM_PCT" ]; then status="red"
    elif [ "${pct:-0}" -ge "$DISK_WARN_PCT"  ]; then status="yellow"
    fi
    printf '{"pct": %s, "status": "%s"}' "$pct" "$status"
}
```

(lines 100-112). The threshold comparisons on lines 108-110 correctly guard
against an empty `$pct` via `"${pct:-0}"`, but the final `printf` on line 111
uses the raw, unguarded `"$pct"`. If `$pct` ends up empty (see finding 3
below for a concrete, realistic trigger), the emitted JSON is:

```
{"pct": , "status": "green"}
```

which is not valid JSON (empty value before the comma). Reproduced directly:

```
$ bash -c 'pct=""; status="green"; printf "{\"pct\": %s, \"status\": \"%s\"}\n" "$pct" "$status"'
{"pct": , "status": "green"}
```

This breaks `write_status()`'s own documented atomicity/validity contract
for its one JSON consumer contract. It's not currently caught by
`watchdog_idempotence.bats` because every test there explicitly strips the
`"disk"` key from its JSON comparisons (`jq 'del(.updated, .disk)'`) before
comparing -- the one `run jq empty "$status_file"` full-file parse check
that *would* catch this only runs under test fixture conditions where `df`
never wraps (see finding 3), so this path is never exercised in CI.

---

## 3. `disk_info()`'s `df`/`awk` parsing breaks on wrapped `df` output

**Severity: serious** (compounds finding 2).

`pct=$(df "$dir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')`
(line 106) assumes `df`'s output is always exactly a header line plus one
data line. That's false whenever the filesystem/device name is long enough
that `df` wraps the entry onto its own line (a real condition with long
OverlayFS/device-mapper/LVM-thin device paths, which is exactly the kind of
name a Docker-managed bind/volume backing `/var/cache/lancache` can have).
When that happens, `NR==2` is just the device name (no `$5` field at all),
and `awk` still exits 0 -- so the `|| pct=0` fallback never fires, and `pct`
is simply empty.

Reproduced directly with a synthetic wrapped-`df`-style fixture:

```
$ bash -c '
fake_df="Filesystem                                                     1K-blocks     Used Available Use% Mounted on
/dev/mapper/very-long-device-name-that-exceeds-the-normal-column-width-of-the-filesystem-column
                                                                 103080204 45662356  52126260  47% /var/cache/lancache"
pct=$(printf "%s\n" "$fake_df" | awk "NR==2 {gsub(/%/,\"\",\$5); print \$5}")
echo "parsed pct=[$pct]"
'
parsed pct=[]
```

Combined with finding 2, a genuinely 95%+-full cache disk behind a
long-named device would silently produce either invalid JSON or a
falsely-green disk status -- precisely the alerting path `DISK_WARN_PCT`/
`DISK_ALARM_PCT` exist to catch. `disk_info()` has zero direct test coverage
(confirmed in the SoT), so neither of these two bugs is caught anywhere.

---

## 4. `get_health()`/`restart_container()` curl calls have no timeout; nothing detects a hung watchdog

**Severity: serious.**

```sh
get_health() {
    curl -sf "${DOCKER_PROXY_URL}/containers/${name}/json" 2>/dev/null \
        | jq -r '.State.Health.Status // "none"' 2>/dev/null \
        || echo "unreachable"
}
restart_container() {
    curl -sf -X POST "${DOCKER_PROXY_URL}/containers/${name}/restart" >/dev/null 2>&1 \
        || log "WARNING: restart call failed for $name"
}
```

(lines 72-88.) Neither `curl` invocation sets `--max-time`/`--connect-timeout`.
If `docker-socket-proxy` accepts the TCP connection but then stalls (HAProxy
under load, an upstream Docker socket hang, a runaway host), `curl -sf` with
no timeout can block indefinitely. The main loop (lines 440-449) is entirely
single-threaded and sequential -- `write_status()`, `maybe_purge()`, and
`maybe_prune_syslog()` all run after the three `check_and_maybe_restart()`
calls in the same iteration -- so one hung `curl` call freezes health
checking, restart, status-file writing, cache purging, and syslog pruning
all at once, indefinitely, with the daemon process itself never exiting
(bash blocked in a foreground `curl`, not crashed).

Because the process never exits, Docker's own `restart: always`/
`unless-stopped` policy never triggers. None of `deploy/dev`,
`deploy/prod`, or `deploy/quickstart`'s `docker-compose.yml` define a Docker
`healthcheck:` for the `watchdog` service itself (confirmed by grep across
all three; only the separate, CI-only `deploy/full-setup/docker-compose.yml`
adds a synthetic `test -f /var/run/watchdog/status.json` healthcheck, solely
so that harness's own health-gate logic has something to poll -- it is not
present in any real deployment path). So in a real dev/prod/quickstart
install, a stalled Docker-socket-proxy connection can silently disable the
entire watchdog daemon -- no more restarts, no more status updates, no more
purge/prune -- with nothing in the stack positioned to notice or recover.

---

## 5. Operator-configurable container-name env vars are silently incompatible with `docker-socket-proxy.sh`'s hardcoded allowlist

**Severity: serious.**

`config/dev/watchdog.env` and `config/prod/watchdog.env` both document
`CONTAINER_PROXY`, `CONTAINER_DNS_STANDARD`, and `CONTAINER_DNS_SSL` as "the
Docker container name for..." the corresponding service, worded as if they
are a supported, operator-facing customization point (and `watchdog.sh`
itself reads them via `${CONTAINER_PROXY:-lancache-proxy}` etc., lines
25-31).

But `scripts/docker-socket-proxy.sh` -- the HAProxy config generator that
gates *every* Docker API call `get_health()`/`restart_container()` make --
hardcodes the permitted container names directly into its ACL regexes and
does not read these env vars at all:

```
acl lancache_container path,url_dec -m reg -i ^(/v[0-9.]+)?/containers/(lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-dhcp|lancache-dhcp-proxy|lancache-dhcp-probe|lancache-nats)(/|$)
acl safe_container_inspect path,url_dec -m reg -i ^(/v[0-9.]+)?/containers/(lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-dhcp|lancache-dhcp-proxy|lancache-dhcp-probe|lancache-nats)/json$
acl safe_service_restart path,url_dec -m reg -i ^(/v[0-9.]+)?/containers/(lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-nats)/restart$
```

(`scripts/docker-socket-proxy.sh:44-47`).

If an operator ever exercises the documented customization (renaming a
monitored container via `CONTAINER_PROXY`/`CONTAINER_DNS_STANDARD`/
`CONTAINER_DNS_SSL`, and correspondingly updating the compose
`container_name:` to match), the HAProxy allowlist still only permits the
old hardcoded literal names. Every subsequent `get_health()` call for the
renamed container gets an HTTP 403 from HAProxy (surfacing as the generic
`"unreachable"` string, indistinguishable from a genuinely down
docker-socket-proxy), and every `restart_container()` call logs `WARNING:
restart call failed for $name` forever. Nothing in `watchdog.sh`,
`docker-socket-proxy.sh`, or (so far as checked) `setup.sh` cross-validates
that these three independent places -- the compose `container_name:`, the
watchdog env var, and the HAProxy ACL regex -- actually agree.

Currently latent (both shipped env files use the matching defaults), but a
real landmine for the exact customization path the env vars' own comments
advertise.

---

## 6. `maybe_purge()` silently no-ops forever (with a false "success" stamp) if `CACHE_DIR` is missing or unreadable

**Severity: serious.**

```sh
log "Daily purge: removing cache files older than ${CACHE_VALID_DAYS} days"
if [ -d "$CACHE_DIR" ]; then
    local count=0
    while IFS= read -r -d '' file; do
        if [ -f "$file" ] && rm -- "$file"; then
            count=$(( count + 1 ))
        fi
    done < <(find "$CACHE_DIR" -type f -mtime "+${CACHE_VALID_DAYS}" -print0 2>/dev/null)
    log "Purged $count files from $CACHE_DIR"
fi
mkdir -p "$(dirname "$PURGE_STAMP")"
echo "$now" > "$PURGE_STAMP"
```

(lines 211-223.) Two compounding gaps:

- There is no `else` branch when `[ -d "$CACHE_DIR" ]` is false: unlike
  `maybe_prune_syslog()`'s analogous check (`log "SYSLOG_LOG_ROOT=... does
  not exist yet; skipping syslog prune"; return`, lines 314-317),
  `maybe_purge()` logs *nothing at all* if `CACHE_DIR` doesn't exist.
- `PURGE_STAMP` is written unconditionally on lines 221-222, *outside* the
  `-d` check -- so even when `CACHE_DIR` is missing/misconfigured, the
  24-hour rate-limit stamp is still refreshed every time this function runs,
  meaning the no-op repeats silently, once a day, forever, with zero
  operator-visible signal that anything is wrong.

Separately, the `find ... -print0 2>/dev/null` on line 218 discards all
`find` errors (permission problems, I/O errors, a vanished mid-scan file)
with no logging at all -- unlike the near-identical scans in
`maybe_prune_syslog()` (lines 324, 381), which capture stderr to a temp file
and explicitly `log "ERROR: find failed while ..."` on any failure. A total
scan failure in `maybe_purge()` is indistinguishable in the logs from
"there was nothing old enough to purge," since `log "Purged $count files..."`
still fires with `count=0` either way.

This is the same asymmetry the SoT already flagged as a test-coverage gap
(`maybe_purge()` has zero bats coverage vs. `maybe_prune_syslog()`'s ~10
tests) but goes further: even setting testing aside, the two functions'
actual production error-handling behavior has silently diverged despite
being modeled on the same idiom, and the divergence specifically removes
the "fail loud" property the sibling function's own comments describe as
deliberate.

---

## 7. `docs/architecture-ng.md` documents the wrong variable name for the purge threshold

**Severity: moderate.**

`docs/architecture-ng.md` states, twice:

> - Remove cache entries older than `CACHE_VALID_HIT` (`find -mtime`)
>   (line 144)
> - Watchdog purge cron | daily automatic | file older than `CACHE_VALID_HIT`
>   (line 215, in the cache-eviction mechanisms table)

But `CACHE_VALID_HIT` is not read anywhere in `watchdog.sh`. It is the
nginx/proxy service's own cache-validity directive, set in
`config/{dev,prod}/proxy.env` (`CACHE_VALID_HIT=365d`) and consumed by
`services/proxy` (confirmed: `grep CACHE_VALID` shows `CACHE_VALID_HIT` only
in `services/proxy/proxy-params.conf`, `services/proxy/entrypoint.sh`, and
the proxy env files -- never in `services/watchdog/watchdog.sh` or
`config/{dev,prod}/watchdog.env`). The variable `maybe_purge()` actually
reads is `CACHE_VALID_DAYS` (line 12, default `365`, a plain integer day
count, wired only through `config/{dev,prod}/watchdog.env`).

The two variables currently share the same numeric value (`365`), which is
almost certainly why this has gone unnoticed -- but they are independently
configurable, live in different services' env files, and use different
value formats (`365d` duration string vs. `365` integer). Following the doc
to "change how long until the cache is purged" by editing `CACHE_VALID_HIT`
would have zero effect on `maybe_purge()`'s actual behavior.

---

## 8. `docs/architecture-ng.md`'s "Watchdog" "Health checks" list misattributes checks watchdog.sh never performs or consumes

**Severity: moderate.**

```
## Watchdog
...
**Health checks:**
- nginx: HTTP request on `/health`
- PowerDNS: DNS query test via `rec_control`
- Kea: REST API ping
- syslog-ng: `syslog-ng-ctl healthcheck` (...); fluent-bit: `fluent-bit -V` (...)
```

(`docs/architecture-ng.md:135-139`.) Reading this under the "## Watchdog"
heading implies these are checks the watchdog performs or at least consumes
per-service. In reality:

- `watchdog.sh`'s `check_and_maybe_restart()` is called for exactly three
  containers (`C_PROXY`, `C_DNS_STD`, conditionally `C_DNS_SSL`; main loop,
  lines 440-445) -- confirmed by the SoT and by direct reading. **Kea and
  syslog-ng/fluent-bit are never monitored, never restarted, and their
  health status is never read by this script at all.**
- Every monitored container's health comes from one single, generic call:
  `curl .../containers/$name/json | jq '.State.Health.Status'` (`get_health()`,
  lines 72-79). `watchdog.sh` has no knowledge of and does not itself
  execute an HTTP `/health` request, a `rec_control` call, a REST ping, a
  `syslog-ng-ctl healthcheck`, or `fluent-bit -V` -- those are separate
  Docker `healthcheck:` blocks defined independently in each service's
  compose entry, and `get_health()` merely reads whatever status Docker's
  own healthcheck machinery already computed and cached.

An operator reading this section literally could reasonably conclude
watchdog actively health-checks, and can restart, Kea/syslog-ng/fluent-bit --
neither of which is true.

---

## 9. `write_status()`'s "trusted input" comment overstates what's actually true

**Severity: minor.**

The function's header comment says every value written into its
string-interpolated JSON is "either a fixed enum (`health_color`'s output),
an integer counter, or a container name we ourselves defaulted, so there's
no untrusted/arbitrary string that could break the JSON structure" (lines
142-149, emphasis on "ourselves defaulted"). But `$C_PROXY`/`$C_DNS_STD`/
`$C_DNS_SSL` come from `CONTAINER_PROXY`/`CONTAINER_DNS_STANDARD`/
`CONTAINER_DNS_SSL`, which are operator-configurable (confirmed set in both
`config/dev/watchdog.env` and `config/prod/watchdog.env`, and documented as
such -- see also finding 5). A container name containing a literal `"` or
backslash would corrupt the emitted JSON; nothing validates or escapes these
values before interpolation. Currently latent since shipped defaults are
safe plain strings, but the comment's stated invariant isn't actually
enforced by anything.

---

## 10. No Docker `healthcheck:` for the watchdog container in any real deployment compose file

**Severity: minor** (context for finding 4).

Grepped across `deploy/dev/docker-compose.yml`, `deploy/prod/docker-compose.yml`,
and `deploy/quickstart/docker-compose.yml`: none define a `healthcheck:` for
the `watchdog` service, unlike `proxy`, `dns-standard`, `dns-ssl`, `dhcp`
(Kea), `syslog` (fluent-bit), and `syslog-ng`, which all have one. Only the
separate, CI-only `deploy/full-setup/docker-compose.yml` (used exclusively
by `full-setup-validate.yml`/`full-setup-deep-validate.yml`) adds a
synthetic `test -f /var/run/watchdog/status.json || exit 1` healthcheck,
apparently added solely so that harness's own polling loop
(`services_with_healthcheck="proxy dns-standard dns-ssl watchdog nats ui netdata"`)
has something to check -- it is not present for actual operators. Combined
with finding 4's unbounded curl calls, there is no external mechanism in any
real deployment that would detect or recover from a hung/stuck watchdog
daemon.

---

## 11. Single-threaded main loop couples health-check latency to purge/prune duration

**Severity: minor/info.**

The main loop (lines 440-449) runs `check_and_maybe_restart()` for all
monitored containers, then `write_status()`, then `maybe_purge()`, then
`maybe_prune_syslog()`, in strict sequence, once per `CHECK_INTERVAL`
(default 30s). `maybe_purge()`/`maybe_prune_syslog()` are rate-limited to
once per 24h, but when they do run, their `find`/`du`/`rm` work against
potentially large trees (prod caches are documented up to 500GB; syslog-ng
archives are budgeted up to `SYSLOG_MAX_GB`, default 10GB but
operator-configurable) executes fully synchronously before the loop returns
to health-checking. There is no time bound, backgrounding, or chunking --
a slow purge/prune pass directly and proportionally delays failure
detection and auto-restart for the three actually-monitored containers on
that cycle. Purely a design observation; no evidence of this actually
biting in practice was sought or found, and the daily rate-limit means the
window is bounded to once per day rather than every cycle.

---

## 12. Test-harness fragility: function extraction relies on unverified literal-text anchors

**Severity: info.**

`tests/bats/helpers/watchdog-helpers.sh`'s `load_watchdog_functions()`
slices the real `watchdog.sh` via:

```sh
awk '
    /^DOCKER_PROXY_URL=/ { capture = 1 }
    /^log "Watchdog started\./ { capture = 0 }
    capture { print }
' "$repo_root/services/watchdog/watchdog.sh" > "$helper_file"
source "$helper_file"
```

(`watchdog-helpers.sh:24-37`.) This works correctly today, but if either
anchor's exact text or position in `watchdog.sh` ever changes (e.g. a
cosmetic reword of the "Watchdog started." log line, or reordering the
top-of-file variable defaults so `DOCKER_PROXY_URL=` is no longer the first
line-anchored default) without a matching update to this helper, `awk`
would silently match nothing, produce an empty (or truncated) extraction
file, and `source` on it would succeed trivially with no error. The failure
would only surface later, as a confusing "command not found" deep inside
individual `@test` bodies that call the now-undefined functions, rather
than as a clear "test harness failed to extract the functions under test"
message at `setup()` time. No self-check (e.g. asserting the extracted file
is non-empty, or that a known function name is actually defined after
sourcing) exists in `load_watchdog_functions()` itself.

---

## 13. No validation against duplicate `CONTAINER_*` env var values

**Severity: info.**

Nothing in `watchdog.sh` (nor, so far as checked in this pass, `setup.sh`)
verifies that `CONTAINER_PROXY`/`CONTAINER_DNS_STANDARD`/`CONTAINER_DNS_SSL`
are pairwise distinct. If an operator ever set two of them to the same
value (typo, copy-paste), `write_status()` would emit a JSON object with a
duplicate key (line 162-173's heredoc has no uniqueness check; most JSON
parsers silently keep only the last occurrence), and
`check_and_maybe_restart()` would run its failure-counting/restart logic
twice per loop iteration against the same real container, under two
independent, uncoordinated failure counters.

---

## 14. `docker-socket-proxy`'s own readiness is not confirmed before watchdog's first calls

**Severity: info** (self-healing in practice).

`docker-socket-proxy` has no Docker `healthcheck:` of its own in any compose
file, and `watchdog`'s `depends_on: [docker-socket-proxy]` (all three real
compose files) uses the plain list form, which only waits for the
dependency container to *start*, not for HAProxy inside it to actually be
accepting connections on `:2375`. In practice this is a narrow, bounded,
self-healing startup race: HAProxy typically binds well within a second,
and even a missed first cycle self-corrects within one `CHECK_INTERVAL`
(30s default) via `get_health()`'s own `"unreachable"` fallback and the next
loop iteration. Noted for completeness alongside findings 4/10, since it's
the same "nothing confirms docker-socket-proxy is actually serving" gap
at the opposite end of the daemon's lifecycle.

---

## 15. Carried forward / re-confirmed from the SoT (not re-discovered here, but independently re-verified against the current code during this pass)

These were already documented in `docs/capability-inventory/SoT-watchdog.md`
(branch `docs/inventory-watchdog`) and the matching #843 comment; listed
here only because this pass independently re-read and confirmed each one
against `origin/v0.2.0`'s actual code, per the "vacuum first" instruction
that prior documentation is a starting point, not a boundary:

- `maybe_purge()` has zero direct bats coverage despite sharing
  `maybe_prune_syslog()`'s exact stamp-validation idiom and historical bug
  class (#111/#112). Confirmed: `grep -n maybe_purge tests/bats/*.bats`
  shows it only inside a comment in `watchdog_syslog_prune.bats`, never
  invoked, and not present at all in `watchdog_idempotence.bats`.
- `get_health()`/`restart_container()`'s real curl+jq/curl-POST logic
  (including the `"unreachable"` and `WARNING: restart call failed`
  branches) is always stubbed out in both bats files -- confirmed by
  reading `watchdog_idempotence.bats:57-66`, which redefines both functions
  entirely before any test runs.
- `disk_info()`'s threshold math has no direct assertions -- confirmed:
  every JSON comparison in `watchdog_idempotence.bats` explicitly
  `del(.updated, .disk)`s before comparing (lines 170, 176, 203, 208, 221,
  227).
- `resolve_cache_dir()`'s error-exit path (disagreeing
  `CACHE_DIR_STANDARD`/`CACHE_DIR_SSL`) is untested directly. Separately
  re-verified during this pass (see note below) that the `exit 1` inside
  `resolve_cache_dir()`, called via `CACHE_DIR="$(resolve_cache_dir)"` at
  line 70, *does* correctly propagate and halt the whole script under
  `set -euo pipefail` -- confirmed experimentally with a minimal repro
  (`X="$(f)"` where `f` echoes then `exit 1`, under `set -euo pipefail`,
  does exit the parent script with status 1). This is *not* a bug: bash's
  "assignment-only simple command's exit status is the last command
  substitution's exit status" rule means `errexit` does catch it. Recorded
  here explicitly so a future pass doesn't have to re-derive this from
  scratch.
- `health_color()`'s `starting`/`unhealthy`/default-to-yellow branches are
  asserted nowhere; only `healthy`->green is exercised (confirmed: grep for
  `health_color` usage in both bats files only appears via the `healthy`
  fixture path).
- `check_and_maybe_restart()`'s silent no-op for `"none"`/`"unreachable"`
  health strings (falls through both the `unhealthy` and `healthy` branches
  untouched, lines 129-139) is real and untested even in the well-covered
  idempotence suite -- confirmed by reading every `drive_health_sequence`
  call in `watchdog_idempotence.bats`; none passes `none` or `unreachable`.
- `STATUS_FILE`/`write_status()`'s output has no consumer anywhere in
  `services/ui/src/` -- confirmed via grep for `status.json`, `STATUS_FILE`,
  and `watchdog-status` across the UI source tree during this pass: zero
  matches, matching the SoT's finding.
- The `full-setup`/`full-setup-deep-validate` CI harnesses only assert
  `watchdog`'s Docker health status reaches `"healthy"` within 90s
  (`full-setup-validate.yml:356-410`) -- they do not exercise
  `get_health()`/`restart_container()`'s real behavior against a live
  Docker-socket-proxy end to end (e.g. actually killing a monitored
  container's health and confirming watchdog restarts it), reinforcing
  rather than closing the SoT's finding that this logic is never tested
  against a real endpoint anywhere in the project, CI included.

---

## Posting status

Findings from this file were also posted as a single English GitHub comment
(prefixed `CLD-<unix-timestamp>`) on the umbrella sweep issue #849, per
`AGENTS.md`'s active-comment-maintenance convention.
