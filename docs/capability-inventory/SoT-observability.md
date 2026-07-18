# Capability inventory: Observability (`netdata` / `syslog-ng` / `fluent-bit`) (Source of Truth / working notes)

Part of the project-wide capability inventory audit (umbrella issue #843).
This file is the personal safety-net / working copy for the observability
component (netdata + the central logging pipeline), committed incrementally
on branch `docs/inventory-observability` so no research is lost if the
session is interrupted. The authoritative, English public log entry for this
component is posted as a comment on issue #843.

Status: **research complete, comment posted**. This file mirrors that
comment's content (plus fuller source citations) so it survives
independently of GitHub availability. Public comment:
https://github.com/wiki-mod/lancache-ng/issues/843#issuecomment-4977058482

Scope: `netdata` service, `syslog`/`fluent-bit` + `syslog-ng` logging profile
as wired in `deploy/{dev,prod,quickstart,full-setup}/docker-compose.yml`,
`services/syslog/netdata-web_log.conf`, `services/ui/src/routes/netdata_proxy.rs`,
`services/ui/src/routes/logs.rs`, `services/ui/src/syslog_client.rs`,
`services/watchdog/watchdog.sh`'s `maybe_prune_syslog()`. Read against
**`origin/v0.2.0`**. Cross-referenced against issues #453 (central logging
umbrella, OPEN), #632 (baseline, closed), #633 (follow-up: full matrix,
Admin UI integration, retention engine — CLOSED 2026-07-13, verified against
PRs #753/#756/#757/#758), and PR #828 (**merged** 2026-07-15 into `v0.2.0` as
commit `4a5e0c11` — "real syslog-ng -> Admin UI visibility E2E simulation";
open at the time this doc was originally written, merged later the same day).

> **Currency check (2026-07-18):** re-verified against `origin/v0.2.0` @
> `dc8d79c6` (68 commits merged since this doc's `3f53ac3b` base). Two
> corrections: (1) PR #828's status above updated from "open" to "merged";
> it remains a test-only PR that adds no fix, per this doc's own §3.4/§4
> analysis. (2) The `logs.rs` per-host-filtering gap this doc calls "not yet
> fixed" (§3.4, point 1, and the summary table) **is now fixed**: PR #865
> (`2137157f`, closes #848) wires a real `?host=` query parameter through to
> `parse_syslog_tail`, adds `list_syslog_hosts()` for a UI dropdown, and
> defensively rejects a path-traversal-shaped host value -- the exact
> landmine this doc's own bughunt sibling (finding #10) had flagged as latent
> in the unfixed code. Point 3 (200-line cap starving quiet hosts) is also
> fixed, by PR #861 (`88b429d6`). Point 2 (`?filter=` silently ignored in
> syslog mode) was not independently re-verified against the current
> `logs.html` template in this pass -- current code documents `filter` and
> `host` as intentionally distinct, mode-specific parameters (see
> `logs.rs`'s own doc comments), which may or may not fully resolve the
> original UX concern; flagging as unconfirmed rather than asserting either
> way. See details in the section below.

---

## 1. Governance docs read (full text, this session)

- `AGENTS.md` (root, 452 lines, origin/v0.2.0) — full read.
- `.github/AGENTS.md` (origin/v0.2.0) — is only a 9-line pointer to root `AGENTS.md`; read in full.
- `CLAUDE.md` (origin/v0.2.0, 172 lines) — full read.
- `CONTRIBUTING.md` (origin/v0.2.0, 299 lines) — full read.

## 2. netdata — what's wired vs. what's available but unused

### 2.1 Deployment wiring (all 4 compose files compared)

| Compose file | `netdata-logs` volume (own logs → fluent-bit) | `logs:/var/log/lancache:ro` mount (web_log source file) | `netdata-web_log.conf` bind-mount (web_log job config) | Healthcheck |
|---|---|---|---|---|
| `deploy/dev` | yes | yes | yes | **none** |
| `deploy/quickstart` | yes | yes | **no** | **none** |
| `deploy/prod` | yes | **no** | **no** | **none** |
| `deploy/full-setup` (CI validation only) | **no** (no logging profile at all here) | n/a | n/a | yes — `curl http://127.0.0.1:19999/api/v1/info` |

**Finding (new, not previously flagged in #453/#633 threads):** Netdata's
`web_log` collector (live per-request nginx analytics: per-status-code
counters, response time, etc., configured via
`services/syslog/netdata-web_log.conf` pointing at
`/var/log/lancache/nginx-proxy.log`) is only fully wired in `dev`. In
`quickstart` the source file mount exists but the collector config
bind-mount does not, so netdata has no `web_log` job at all. In `prod`
neither exists, even though the file is actually produced there (fluent-bit's
`file=nginx-proxy.log` output is present in all three real deployment
composes — confirmed at `deploy/{dev,prod,quickstart}/docker-compose.yml`,
the `syslog` service's fluent-bit command args). This is a three-way
inconsistency across dev/quickstart/prod for one specific netdata collector,
independent of and in addition to the general central-logging matrix that
#633 already closed out.

**Finding:** netdata has **no Docker `HEALTHCHECK`** in `dev`, `prod`, or
`quickstart` — only the CI-only `full-setup` compose defines one (and that
one is unrelated to any real deployment target). `ui`'s `depends_on: netdata`
has no `condition: service_healthy` anywhere real, so this doesn't currently
break anything, but it does mean an operator has no Docker-native signal if
netdata's collector process dies while the container itself stays up.
`setup.sh`'s `cmd_debug` (~line 3922) does list `netdata` among the services
whose last-30-lines-of-logs get dumped for troubleshooting — that's a
separate, working diagnostic path, unrelated to Docker healthchecks. Note
that same `cmd_debug` service list does **not** include `nats`, `dhcp`,
`dhcp-proxy`, `syslog`, or `syslog-ng` — so a DAU running `./setup.sh debug`
gets zero visibility into the logging-pipeline containers' own stdout via
that command, only via `docker compose logs` directly or the Admin UI.

### 2.2 Admin UI's netdata integration — hard-allowlisted proxy, 2 of netdata's API surface

`services/ui/src/routes/netdata_proxy.rs` (145 lines): a single `proxy()`
handler forwards `/api/netdata/<path>?...` to `http://netdata:19999/api/v1/<path>`,
but `ALLOWED_NETDATA_ENDPOINTS` hard-allowlists exactly **two** of netdata's
REST API endpoints: `data` and `charts`. Path traversal (`/`, `..`) and any
other endpoint name (`alarms`, `info`, `allmetrics`, `badge.svg`,
`variable`, `weights`, etc.) are rejected with `404`/`400`. Well-tested
(4 unit tests covering URL construction, query-param encoding, allowlist
enforcement, and rejection of unsafe paths).

`services/ui/src/templates/stats.html` is the only consumer: it polls
exactly **4** netdata charts every 3s (`system.cpu`, `system.ram`,
`net.eth0`/`net.eth1` fallback, `system.io`) into 4 Chart.js line charts
(CPU %, RAM GB, network MB/s rx/tx, disk MB/s read/write). `docs/architecture-ng.md`
documents this accurately ("Netdata integrated (proxy via `/api/netdata`)" /
"Statistics: CPU, RAM, network MB/s (realtime + history), disk I/O" — no
drift found here).

**Netdata capability confirmed present in the container but never surfaced
to the operator anywhere in this project:**
- **Port 19999 is never published to the host** in any of the 4 compose
  files (grepped `19999` across all of `deploy/*` — only ever appears as the
  internal `NETDATA_URL=http://netdata:19999` env var or the full-setup
  healthcheck). An operator cannot reach netdata's own native dashboard,
  even though the upstream image ships one, unless they manually `docker
  exec`/port-forward.
- **Netdata's built-in alarms/health-check engine** (netdata ships default
  alarm templates for disk-full, high load, OOM risk, etc. out of the box,
  with zero custom config needed) is running — `docs/threat-model.md` line
  376 cites "Disk-usage warnings/alarms via the watchdog and Netdata" as an
  existing mitigation, and this is technically true (stock netdata default
  health templates fire without any extra config in this repo) — but there
  is **no `alarms` API proxy route, no notification integration
  (email/webhook/Slack/etc.), and no Admin UI surface for alarm state at
  all**. If a netdata alarm fires, nothing in this project's own UI/logging
  path would show it to an operator; it would only appear in netdata's own
  (unreachable) dashboard or its own log files (which do get forwarded to
  syslog-ng per the logging matrix, so a sufficiently determined operator
  reading raw syslog-ng output could see an alarm transition line — but nowhere
  is this decoded/displayed as "alarm").
- `docs/threat-model.md` line 629 separately lists "Security-event
  metrics/alerts via the existing Netdata integration" as a **future**
  hardening item (item 5 of a numbered future-work list) — i.e. the
  threat model itself is honest that today's netdata "integration" is
  system-metrics-only, not alerting-integrated, which matches the code.
- **Netdata's Docker/cgroups auto-discovery is implicitly active** (the
  container mounts `/var/run/docker.sock:ro`, `/proc`, `/sys` — netdata's
  standard trio for its `cgroups.plugin` and `docker` module to
  auto-discover and chart every sibling container's CPU/mem/blkio/network
  individually), but the Admin UI never queries any `cgroup_*`/per-container
  chart — only the 4 host-wide charts listed above. Per-container resource
  breakdown (e.g. "how much CPU is the `proxy` container using right now")
  is available inside netdata but completely unexposed to the operator.
- **Netdata Cloud claiming** is not referenced anywhere in the repo (no
  `NETDATA_CLAIM_URL`/`NETDATA_CLAIM_TOKEN`/`NETDATA_CLAIM_ROOMS` env vars
  found) — confirmed intentionally absent, consistent with this being a
  fully self-hosted, LAN-only project (cloud claiming would phone home to
  Netdata Cloud, which would need an explicit operator opt-in this project
  doesn't offer).
- **`allmetrics` (Prometheus-compatible metrics export)** — not proxied,
  not referenced. No path exists today to scrape netdata into an external
  Prometheus/Grafana stack without bypassing this project's own Admin UI
  proxy entirely (which the closed `docker-socket-proxy`-style network
  topology doesn't prevent, since netdata itself isn't behind a proxy —
  see network section below — but is undocumented as a supported
  integration path).
- netdata sits on the plain `lancache` network like every other service —
  it is **not** on the `docker-api` internal network (that's only for the
  Admin UI's socket-proxy path) and has no other network isolation beyond
  Docker's default bridge; nothing prevents another container on the same
  `lancache` network from hitting `http://netdata:19999` directly and using
  any of its full (non-allowlisted) API surface, including `alarms`, `info`,
  `allmetrics` — the allowlisting in `netdata_proxy.rs` only constrains what
  the *Admin UI's own outbound path* can request, not network-level access
  to netdata itself. (This mirrors the pattern already flagged for the
  broader threat model re: read-only Docker-socket access — not a new class
  of finding, just noting it applies to netdata's HTTP API surface too.)

## 3. Central logging pipeline (`syslog-ng` / `fluent-bit`) — status per #453/#632/#633

### 3.1 Timeline / decision history (from #453's own comment thread + #633)

- 2026-07-10: confirmed then-current state — only a fluent-bit-only,
  `profiles: [logging]`-gated service in dev/quickstart tailing the nginx
  access log to a plain file; no syslog-ng, no per-service matrix, no
  retention policy, prod had nothing at all.
- 2026-07-11: umbrella #453 split into #632 (baseline: syslog-ng receiver +
  fluent-bit forwarder, dev/prod/quickstart parity, proxy log wired,
  fixed-threshold rotation+compression) and #633 (follow-up: full
  per-container matrix, Admin UI integration, full retention/storage-budget
  engine, CI logging-matrix guard, fluent-bit healthcheck).
- Both #632 and #633 closed by 2026-07-13, verified against real merged
  code across 4 PRs: #753 (CI guard `scripts/check-logging-matrix.sh` +
  fluent-bit healthcheck), #756 (wired remaining 9 services into the
  pipeline), #757 (`maybe_prune_syslog()` retention engine in
  `watchdog.sh`), #758 (`syslog_client.rs` + `/logs`/dashboard Admin UI
  integration, `Closes #633` — merged into `v0.2.0` integration branch, not
  the repo default branch, so GitHub auto-close never fired; closed
  manually after verification).
- 2026-07-14 (same day as this audit): maintainer/agent found the prior
  "done" claim on #453 was itself under-scoped — proving "a log line
  reaches syslog-ng on disk" (#756's own smoke test) is **not** the same
  claim as "the Admin UI's `/logs` route actually displays that line to an
  operator." While scoping a real end-to-end test for the latter, a **real,
  still-open bug** was found in `services/ui/src/routes/logs.rs`
  (see §3.4 below) and a **real compose-topology gap** was found:
  `deploy/full-setup/docker-compose.yml` — the base every existing
  `scripts/*-simulation.sh` CI script builds on — has neither
  `dhcp`/`dhcp-proxy` nor the `logging` profile (`syslog-ng`/`fluent-bit`)
  at all; only `dev`/`quickstart` have all 9 wired services *and* the full
  logging profile together. PR #828 (open, not yet merged into `v0.2.0`)
  adds `scripts/syslog-forwarding-simulation.sh` running against
  `deploy/quickstart` instead, proving 6 of 9 services
  (`proxy`, `ui`, `nats`, `dns-standard`, `dns-ssl`, `watchdog`) end-to-end
  with a real per-run-unique marker, plus a documented **weaker** check for
  `netdata` (no operator-triggerable marker mechanism exists for a
  third-party image with no forwardable custom-event surface — the test
  instead just waits up to 90s for *any* line attributed to host `netdata`
  to appear via the real `/logs` route). `dhcp`/`dhcp-proxy` are explicitly
  deferred (both use `network_mode: host` in `deploy/quickstart`, untested
  territory for shared CI runners, needs sequential non-simultaneous
  bring-up design since both DHCP modes would contend for the same
  host-network ports).

### 3.2 Fluent-bit (`syslog` service) wiring — verified directly in `deploy/dev/docker-compose.yml` (1307 lines; `prod`/`quickstart` structurally identical)

Image: `cr.fluentbit.io/fluent/fluent-bit:3.2.10` (pinned by digest).
Config delivered entirely as CLI flags (`command:` list), not a bind-mounted
file — deliberate, because (a) this image ships no shell at all
(distroless-style) so no `entrypoint.sh` templating trick is possible, and
(b) `quickstart` has no local repo checkout to bind-mount a config file
from. One `tail` input + `record_modifier` filter + `syslog` output triplet
per source, all sharing one process:

| Source tailed | fluent-bit tag | Local plain-file copy too? | `record host=` | `record ident=` |
|---|---|---|---|---|
| `/var/log/nginx/access.log` | `nginx.syslog` | **yes** → `nginx-proxy.log` (feeds netdata's `web_log` job, dev only — see §2.1) | `lancache-proxy` | (unset in filter shown; access log keeps nginx's own format) |
| `/var/log/nginx/error.log` | `nginx-error.syslog` | yes (own file) | `lancache-proxy` | — |
| `/var/log/nginx/stream.log` (SNI passthrough, standard mode) | `nginx-stream.syslog` | yes (own file) | `lancache-proxy` | — |
| `/var/log/lancache-dns-standard/*.log` | `dns-standard.syslog` | no | `lancache-dns-standard` | `pdns` |
| `/var/log/lancache-dns-ssl/*.log` | `dns-ssl.syslog` | no | `lancache-dns-ssl` | `pdns` |
| `/var/log/kea/*.log` | `dhcp.syslog` | no | `lancache-dhcp` | `kea-dhcp4` |
| `/var/log/lancache-dhcp-proxy/*.log` | `dhcp-proxy.syslog` | no | `lancache-dhcp-proxy` | `dnsmasq` |
| `/var/log/lancache-ui/*.log` | `ui.syslog` | no | `lancache-ui` | `lancache-ui` |
| `/var/log/lancache-watchdog/*.log` | `watchdog.syslog` | no | `lancache-watchdog` | `watchdog` |
| `/var/log/lancache-nats/*.log` | `nats.syslog` | no | `lancache-nats` | `nats-server` |
| `/var/log/lancache-netdata/*.log` | `netdata.syslog` | no | `lancache-netdata` | `netdata` |

All 9 non-proxy tags forward to `syslog-ng` over TCP/601, RFC 5424 framing,
`syslog_hostname_key=host`/`syslog_appname_key=ident`/`syslog_message_key=log`
— i.e. the `host`/`ident` record-modifier fields become the actual RFC5424
Hostname/App-Name fields syslog-ng receives and uses to build its
per-host directory tree. Matches `docs/architecture-ng.md`'s logging matrix
table exactly (no drift found in the matrix itself).

**Fluent-bit healthcheck** is deliberately weaker than syslog-ng's: the
pinned image ships no shell/wget/curl, so the only self-contained exec-form
check available is `fluent-bit -V` (proves the binary is intact/executable,
not that the live tail→forward pipeline is actually healthy). Documented as
an accepted trade-off in both the compose file's own comment and
`docs/architecture-ng.md`.

**Per-service delivery mechanism, why it differs (from the compose file's
own extensive inline comments, cross-checked against `docs/architecture-ng.md`'s
matrix — consistent):**
- PowerDNS: no native file-log directive on Linux at all → `entrypoint.sh`'s
  `run_auth`/`run_recursor` `tee` stdout into a file.
- Kea (dhcp): native dual-output (`output-options` array lists both
  `stdout` and a file) — the one service with a real native dual-destination
  option. File output is hard-restricted by Kea itself to exactly
  `/var/log/kea` (security hardening against arbitrary file writes via a
  malicious `config-set` API call) — this project's usual
  `/var/log/lancache-<service>` naming convention could not be used here
  (issue #773).
- dnsmasq (dhcp-proxy) / nats-server: each supports only **one** log
  destination at a time (no dual-output mode) — `docker logs` on these two
  containers goes silent once the `logging` profile is active, an accepted
  documented trade-off (nats's authoritative `log_file:` setting lives in
  the Admin UI's `update_nats_conf`, not the compose-generated boot config,
  since issue #811).
- Admin UI (`ui`): `main.rs`'s `init_tracing()` adds a second
  `tracing-subscriber` layer writing to `UI_LOG_FILE` alongside stdout —
  best-effort, a missing/unwritable log path never blocks startup.
- watchdog: `watchdog.sh` itself is unchanged; the compose
  `entrypoint`/`command` override wraps it with
  `exec /watchdog.sh > >(tee -a ...) 2>&1` so it stays PID 1 (signal
  handling unaffected) while also feeding a file.
- netdata: writes `health.log`/`collector.log`/`error.log` etc. under
  `/var/log/netdata` by default — that path is mounted onto the shared
  `netdata-logs` volume, fluent-bit tails it read-only. (No custom netdata
  log-level/verbosity configuration found anywhere in the repo — stock
  defaults.)
- `dhcp-probe`: **not applicable**, one-shot diagnostic helper
  (`restart: "no"`), started/stopped on demand by the Admin UI for a single
  probe run — no persistent process/log stream to route. Documented as a
  deliberate N/A, not a gap.

### 3.3 syslog-ng (central receiver) — config, rotation, retention

Image `balabit/syslog-ng:latest` (pinned by digest, despite the mutable-looking
tag — confirmed digest-pinned in the compose `image:` line). Config
generated inline via heredoc at container start (same "no local repo
checkout in quickstart" reasoning as fluent-bit).

- Listens on `network(transport(tcp) port(601) flags(syslog-protocol))`.
- Single destination: `file("/var/log/lancache-syslog-ng/$HOST/$YEAR$MONTH$DAY.log", template("$ISODATE $HOST $PROGRAM: $MSGONLY\n"), create-dirs(yes))`.
- `dir-group(10001)`/`group(10001)` explicitly set (numeric gid, no
  `/etc/group` entry needed) — the container runs as root with no `user()`
  drop configured, so files/dirs would otherwise be `root:root` with
  `0750`/`0640` perms, which would leave the Admin UI's unprivileged
  `lancache` user (uid/gid 10001) with **zero read access** to its own
  `logs-syslog-ng:ro` mount. This is a real, non-obvious fix documented
  inline (referencing PR #758's review) — worth flagging as a concrete
  example of "why the WHY-comment matters" per AGENTS.md's comment-style
  rules, since the failure mode (silent empty `/logs` page, not a crash)
  would be very hard to diagnose without the comment.
- **Rotation/compression baseline** (fixed-threshold, not the full budget
  engine): a background loop (`while true; sleep
  SYSLOG_NG_ROTATE_INTERVAL_SECONDS`) finds any active log file over
  `SYSLOG_MAX_FILE_MB` (default 100), renames it with a UTC timestamp
  suffix, sends syslog-ng `SIGHUP` (PID 1) to reopen the destination file,
  then compresses the rotated file with `zstd -T0 -<SYSLOG_COMPRESSION_LEVEL>`
  (default 19), falling back to `gzip` if `zstd` could not be installed at
  container start (e.g. no network egress) — degrades gracefully rather
  than failing hard.
- **Healthcheck**: `syslog-ng-ctl healthcheck --timeout 5` — a real
  liveness probe (unlike fluent-bit's binary-only check), since this image
  does ship a shell/the `syslog-ng-ctl` control tool.
- **Storage-budget retention** (the actual `SYSLOG_ENABLED`/`SYSLOG_MAX_GB`/
  `SYSLOG_RETENTION_DAYS`/`SYSLOG_LOG_ROOT` contract #633 asked for) lives in
  `services/watchdog/watchdog.sh`'s `maybe_prune_syslog()`, **not** in the
  syslog-ng container itself: rate-limited to once/day via a stamp file
  (same pattern as the existing cache-purge job), age-based deletion first
  (`SYSLOG_RETENTION_DAYS`, default 30), then if still over `SYSLOG_MAX_GB`
  (default 10) the oldest remaining files are deleted regardless of age
  until back under budget — i.e. **size budget takes priority over the
  age floor**, confirmed both in code and in `docs/architecture-ng.md`'s
  prose. `SYSLOG_LOG_ROOT` is deliberately **not** an independently
  compose-settable var for watchdog (per a #757 review comment in the
  compose file) — watchdog.sh already defaults it to
  `/var/log/lancache-syslog-ng`, matching the fixed volume mount target;
  exposing it as a separately overridable compose var would silently break
  pruning if ever changed inconsistently with the mount.
- Test coverage: `tests/bats/watchdog_syslog_prune.bats` exists (not read
  in full this pass, but confirmed present and named appropriately for this
  function).

### 3.4 Admin UI (`services/ui/src/syslog_client.rs`, `services/ui/src/routes/logs.rs`) — **confirmed live bug, not just a doc claim**

`syslog_client.rs` (698 lines): reader for the central store, transparently
handling plain/`.zst`/`.gz` rotated files (never assumes one compression
state). Two public entry points:

- `parse_syslog_tail(log_root: &str, host: Option<&str>, limit: usize) -> Vec<SyslogEntry>`
  — **already supports per-host filtering** (`Some(h)` restricts to that
  host's subdirectory, `None` merges all hosts), fully unit-tested including
  a dedicated "merges and orders multiple hosts by timestamp" test.
- `get_syslog_stats(log_root) -> SyslogStats { hosts: Vec<SyslogHostStats { host, files, size_bytes, days }>, total_files, total_size_bytes }`
  — per-host file count/size/distinct-day-count, cheap (metadata-only, no
  decompression), also fully unit-tested.

**Confirmed directly in current `origin/v0.2.0` code** (`services/ui/src/routes/logs.rs`,
101 lines) — matches exactly what the maintainer's 2026-07-14 comment on
#453 already flagged, verified here first-hand rather than taken on faith:

1. `logs_page()`'s syslog-mode branch (when `SYSLOG_ENABLED=true`) **always**
   calls `syslog_client::parse_syslog_tail(&log_root, None, 200)` — the
   `host` parameter is hardcoded `None` even though the function fully
   supports per-host filtering. **There is no way to view one service's
   logs in isolation once syslog mode is on.**
2. The `?filter=` query parameter (`LogFilter.filter`) is read and applied
   via `all_logs.retain(...)` **only in the non-syslog (direct nginx) branch**
   (line ~94-96) — in the syslog-mode branch it is silently accepted by the
   `Query<LogFilter>` extractor but never read or applied. A user passing
   `?filter=HIT` while syslog mode is on gets zero filtering, with no error
   or indication that the parameter was ignored.
3. The 200-line cap in syslog mode applies **globally across all merged
   hosts** (not per-host), so a chatty service (e.g. `proxy` under load)
   can push a quieter service's (e.g. `dhcp`) log lines out of the visible
   window entirely — no pagination, no "since timestamp" escape hatch.

This is a textbook instance of AGENTS.md's Feature Completeness rule
("If backend code supports a feature but the Admin UI does not expose it,
treat that as UI delivery debt by default") — the backend
(`syslog_client.rs`) already has the capability; only the route wiring in
`logs.rs` is incomplete. **Not yet fixed as of this audit (2026-07-15)**; PR
#828 is a *test* PR, adds no fix. **FIXED as of 2026-07-18's currency
check**: PR #865 (`2137157f`, closes #848) wires a real `?host=` parameter
through to `parse_syslog_tail` and adds `list_syslog_hosts()` for a UI
dropdown -- confirmed directly against current `origin/v0.2.0`'s
`services/ui/src/routes/logs.rs`.

**Dashboard tile** (`services/ui/src/templates/dashboard.html`, gated on
`syslog_enabled`): shows only `syslog_stats.hosts | length` (host *count*,
not names) and `syslog_stats.total_files`, plus `syslog_size_gb` /
`syslog_max_gb` as a fraction. **`SyslogHostStats`'s per-host `files`,
`size_bytes`, and `days` fields are computed by `get_syslog_stats()` but
never individually rendered** — no per-host breakdown table exists in the
UI despite the data already being computed on every dashboard render. Same
"backend computes it, UI doesn't show it" pattern as the `logs.rs` finding
above, just on the dashboard instead of the logs page.

### 3.5 Documentation drift found in `docs/architecture-ng.md` itself (internal inconsistency, not code-vs-doc)

- The top-of-file services table (line 11) still describes syslog-ng's
  fluent-bit forwarding scope as **"fluent-bit forwards proxy access logs
  to it (#453)"** — but the same document's own later "Currently
  implemented" section (line 163) and full logging-matrix table (lines
  177-190) correctly describe all **9** wired services
  (proxy/dns-standard/dns-ssl/dhcp/dhcp-proxy/ui/watchdog/nats/netdata), not
  just the proxy. This is a stale summary line inside the same file as its
  own more complete, more current section — an internal drift, not
  something contradicted by code.
- Line 245 ("Logs: filtered by service, level selectable (not yet
  implemented against the central syslog-ng path; see follow-up #633)") and
  line 246 ("syslog forwarding configuration is not yet exposed in the UI;
  see follow-up #633") both **cite #633 as the tracking issue for a gap that
  is still real in code** (confirmed in §3.4 above), but **#633 itself is
  now closed** (2026-07-13). Per AGENTS.md's Documentation Drift rule
  (`AG-DOC-001`), this is exactly the kind of drift that must be flagged: a
  reader following the `#633` reference today lands on a closed issue with
  no indication that the specific gap it's citing is still open. The
  underlying capability gap (per-host log filtering, `?filter=` ignored in
  syslog mode) is real and current; the citation pointing at it is stale.
  This should reference a new/reopened tracking issue, not the closed #633,
  once one exists — not something I'm creating or fixing in this
  research-only pass, just flagging per this audit's own scope (inventory,
  not remediation).

## 4. Cross-reference against #453 / #633 acceptance criteria — summary table

| #453 required item | Status (verified against `origin/v0.2.0` this session) |
|---|---|
| Dedicated `syslog-ng` central receiver | Done — TCP/601, RFC5424, per-host/per-day file destination |
| `fluent-bit` as collector/forwarder (not final authority) | Done |
| All lancache-ng containers routed into syslog-ng | Done for 9/9 applicable services; `dhcp-probe` justified N/A |
| dev/prod/quickstart profile consistency | Done for the **logging pipeline** itself (all 3 have `syslog`+`syslog-ng` with `profiles: [logging]`) — but **not** done for netdata's `web_log` collector specifically (§2.1 finding, new) |
| Persisted log storage path defined | `SYSLOG_LOG_ROOT=/var/log/lancache-syslog-ng`, fixed, not independently overridable by design |
| Admin UI reads aggregated central logs | Partially — `/logs` and dashboard both read from syslog-ng store when enabled, but with the real per-host/filter gaps in §3.4 |
| Retention/storage-budget engine | Done — `watchdog.sh`'s `maybe_prune_syslog()`, age-first-then-size-budget-priority |
| CI guard for logging matrix | Done — `scripts/check-logging-matrix.sh` in `validate-compose` |
| fluent-bit healthcheck | Done (binary-integrity only, documented limitation) |
| **Live E2E proof: real event → syslog-ng → Admin UI visibility** | **Merged 2026-07-15** (`4a5e0c11`, PR #828) — covers 6/9 services with per-run markers + a weaker netdata check; `dhcp`/`dhcp-proxy` explicitly deferred |
| **`logs.rs` per-host/filter bug found during that E2E scoping** | **FIXED 2026-07-16** by PR #865 (`2137157f`) — `?host=` now wired through to `parse_syslog_tail`; see currency-check note above |

## 5. Open items / follow-up candidates surfaced by this inventory (not filed as issues — this is a research pass, not a fix pass)

1. `services/ui/src/routes/logs.rs`'s `logs_page` hardcodes `host=None` and
   ignores `?filter=` in syslog mode — real, current, user-facing gap.
2. `docs/architecture-ng.md` cites the now-closed #633 for a still-open gap
   (documentation drift, `AG-DOC-001` territory) — needs a live tracking
   issue reference once one exists.
3. netdata's `web_log` collector wiring is inconsistent across
   dev/quickstart/prod (full in dev, source-file-only in quickstart,
   nothing in prod) — never previously called out in the #453/#633 threads
   reviewed.
4. netdata has no Docker healthcheck in any real deployment profile.
5. Dashboard's `syslog_stats` per-host breakdown (files/size/days) is
   computed but not rendered.
6. netdata's built-in alarms engine runs (stock templates) but has no
   Admin UI surface, no notification integration, and the threat model's
   own future-work list (line 629) already acknowledges alerting
   integration is not yet built — consistent, not a contradiction.
7. netdata's HTTP API (port 19999) is reachable by any other container on
   the shared `lancache` network without going through the Admin UI's
   2-endpoint allowlist — not a new class of finding vs. the existing
   threat-model treatment of read-only Docker-socket access, but worth
   naming explicitly for netdata's own API surface.
