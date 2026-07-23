# LanCache-NG Architecture

## Services

Every service below (proxy, PowerDNS, Kea DHCP, dhcp-proxy, Watchdog, Admin UI)
already existed before this project's first version tag (`v0.1.0`, cut
2026-07-06) was created, so a per-service "included since vX.Y.Z" column
would not actually differentiate anything -- every real row would read the
same "v0.1.0" regardless of which service is genuinely older or newer
(verified against each service directory's first commit in git history, not
assumed). The one row below that a version field genuinely would
differentiate is Cache Warmer, which is called out explicitly instead: it is
not shipped in any tagged version, current or planned, only a design
document.

| Service | Default | Replaces | Notes |
|---|---|---|---|
| nginx (proxy) | on | — | Mainline from nginx.org, Debian 13 Base |
| PowerDNS | on | dnsmasq | Authoritative + Recursor for DNS spoofing & recursion |
| Kea DHCP / DHCP modes | off | — | Configurable tri-state: `disabled` / `kea` / `dnsmasq-proxy`; requires PowerDNS (DDNS via nsupdate). See [docs/dhcp-modes.md](dhcp-modes.md). |
| Watchdog | on | — | Health checks, auto-restart, purge cron |
| syslog-ng | off (`--profile logging`) | — | Central log receiver; fluent-bit forwards logs from every wired service to it (#453) — see the syslog-ng section's full logging matrix below, not just proxy access logs |
| Admin UI | on | — | Axum/Rust, Tera, Tailwind, separate port |
| Cache Warmer | not implemented | — | **Design-only, not shipped**: no `services/` code, no Compose service, nothing runnable exists yet under this name. See [docs/design-steam-prefill.md](design-steam-prefill.md) (issue #816, overlapping #871) for the current proactive cache-warming design plan and its open maintainer decisions. Do not treat this row as an existing on/off feature until that design actually lands. |

## nginx

Mainline from nginx.org (not Debian package). Base: `debian:13-slim`.

**Performance configuration:**

```nginx
worker_processes      auto;
worker_rlimit_nofile  65535;
thread_pool default   threads=32 max_queue=65536;

events {
    worker_connections  4096;
    use epoll;
    multi_accept on;
}

sendfile    on;
tcp_nopush  on;
tcp_nodelay on;
aio         threads=default;
directio    4m;
```

**Cache configuration (all values as env var + configurable in Admin UI):**

| Variable | Default | Description |
|---|---|---|
| `CACHE_MAX_SIZE` | `50g` | Max cache size — UI checks against available disk space |
| `CACHE_MEM_MB` | `200` | keys_zone size (1MB ≈ 8,000 keys) |
| `CACHE_SLICE_SIZE` | `8m` | Slice size: `4m/8m/16m/32m/64m/128m/256m/512m` |
| `CACHE_VALID_HIT` | `365d` | Validity duration for 200/206/301/302 |
| `CACHE_VALID_ANY` | `1m` | Validity duration for everything else |
| `CACHE_INACTIVE` | `365d` | Remove if not accessed for X days |

**Slice module** (for range requests in game downloads):
```nginx
slice               $CACHE_SLICE_SIZE;
proxy_cache_key     "$host$uri$slice_range";
proxy_set_header    Range $slice_range;
proxy_cache_valid   206 $CACHE_VALID_HIT;
```

**Note:** `max_size` is not a hard limit — cache can exceed it with crashed workers. Watchdog monitors actual disk usage.

## PowerDNS

- Runs in two processes: authoritative (answering CDN zones) + recursor (recursive queries for clients)
- Zone data from `/etc/pdns` directory: `cdn-domains.txt` compiled into PowerDNS zones
- IPv4 + IPv6 everywhere (dual-stack)

**Zones:**

| Zone | Type | Purpose |
|---|---|---|
| `lan` | primary | LAN TLD |
| `local.lan` | primary | LAN hosts (manageable via Admin UI) |
| `10.in-addr.arpa` | primary | Reverse 10/8 |
| `168.192.in-addr.arpa` | primary | Reverse 192.168/16 |
| `16–31.172.in-addr.arpa` | primary | Reverse 172.16/12 |
| `ip6.arpa` (ULA) | primary | IPv6 reverse |

**Optional features (environment variables):**

| Variable | Default | Meaning |
|---|---|---|
| `ROOT_ZONE_MIRROR` | `1` (enabled) in `services/dns/entrypoint.sh`'s own fallback; this repo's shipped `config/dev/dns-*.env` explicitly override it to `0`, `config/prod/dns-*.env` explicitly set `1` | Root zone mirror (AXFR from root servers). Was previously documented here as `ENABLE_ROOT_MIRROR` — that name does not exist in code; `docs/dns-admin-ui-scope.md` already used the correct name. |
| Global AAAA-response filter | off by default | Suppresses all AAAA answers for every client, regardless of address family. Not an env var/restart-time setting: toggled live via the Admin UI (`POST /domains/aaaa-filter`), which writes/removes a marker file on the shared `powerdns-state` volume, read live by `filter-aaaa.lua`'s recursor `preresolve` hook. (Previously documented here as two separate env vars, `FILTER_AAAA_V4`/`FILTER_AAAA_V6` — neither name appears anywhere in `services/dns/` or `services/ui/src`; see `docs/dns-admin-ui-scope.md` §1b for the real, shipped mechanism.) **Planned change, not yet implemented**: starting with v0.3.0, this filter is intended to default to **on** instead of off (maintainer decision recorded in issue #1068; no dedicated tracking issue exists yet for the code change itself). Current shipped behavior as of this writing is still off-by-default — do not treat this bullet as already-shipped. |
| `ENABLE_SECONDARY` | — | Not read by any code — a documentation-only narrative convention for when to include `deploy/prod/docker-compose.nats-secondary.yml`. The actual secondary-sync mechanism is NATS-based (see `NATS_BIND_IP`/`NATS_ADVERTISE_URL` below and `docs/dns-admin-ui-scope.md` §3); PowerDNS's own native secondary/AXFR mode is not implemented at all — `SECONDARY_MASTERS`/`SECONDARY_ZONES` (previously listed here) appear nowhere in this repository. |
| `NATS_BIND_IP` | — | Trusted LAN/VPN interface for optional NATS host binding used by remote secondaries; intentionally required by the secondary NATS override file. Also drives the address the Admin UI hands out during secondary registration -- see below. |
| `NATS_ADVERTISE_URL` | — | Explicit override for the NATS URL the Admin UI hands a remote secondary during registration (issue #866), for setups `NATS_BIND_IP` alone can't express (non-default port, `tls://` scheme, VPN hostname). Always wins over `NATS_BIND_IP` when set. |

**allow-query / allow-recursion:** open to all RFC-1918 + IPv6 ULA by default

### Remote secondary NATS access

The production Compose file keeps NATS on the Docker network by default and does not publish port `4222` on the host. This keeps the event bus closed for installations that do not use remote secondaries.

There are two compatible ways to enable host binding for secondary DNS nodes:

1. **Reuse the existing secondary switch**: when `ENABLE_SECONDARY=true`, include `deploy/prod/docker-compose.nats-secondary.yml` and set `NATS_BIND_IP` to the trusted LAN or VPN interface that secondary nodes use.
2. **Use a separate explicit binding switch**: leave `ENABLE_SECONDARY` for DNS behavior, and include `deploy/prod/docker-compose.nats-secondary.yml` only when you intentionally want to publish NATS for remote secondary synchronization.

Example:

```sh
ENABLE_SECONDARY=1 NATS_BIND_IP=192.168.1.5 \
  docker compose --env-file deploy/prod/.env.local -f deploy/prod/docker-compose.yml \
  -f deploy/prod/docker-compose.nats-secondary.yml up -d
```

Do not bind NATS to `0.0.0.0` unless an external firewall or VPN policy restricts access to trusted secondary nodes.

**Registration hands out this same `NATS_BIND_IP` address (issue #866):** the
Admin UI's `POST /api/secondary/register` used to always return the literal
`nats://nats:4222` in its `nats_url` field -- correct for the primary's own
internal services, but never reachable from a real remote secondary, since
that address only resolves inside the primary's own Docker network.
`setup.sh secondary` wrote that unreachable value straight into the
secondary's `.env`, which then ran successfully and printed a false "is
running" success message, while the `nats-subscriber` container silently
retried a connection that could never succeed and no DNS record ever synced.
As of #866, registration now returns `nats://<NATS_BIND_IP>:4222` whenever
`NATS_BIND_IP` is set on the primary to a routable address -- the same value
already required by the host-binding override above, so a primary that has
that override active for the `nats` service gets a working registration
response for free. An IPv6 `NATS_BIND_IP` literal is bracketed automatically
(`nats://[2001:db8::5]:4222`), since an unbracketed IPv6 literal is not a
parsable NATS URL; the same bracketing applies whether `NATS_BIND_IP` itself
was written bracketed (`[2001:db8::5]`, Compose's own documented form for an
IPv6 host-port field) or bare.
`NATS_BIND_IP` is only ever echoed back when it is itself a routable IP
literal. It is rejected (falls through to the HTTP 503 refusal described
below, the same as leaving it unset) in every other case:
- **Wildcard listen addresses** (`0.0.0.0` or `::`, bracketed or not) -- the
  "external firewall/VPN" case described above -- are never echoed back,
  since a wildcard is only meaningful as a bind address, never as something
  a remote secondary could dial.
- **Loopback addresses** (`127.0.0.1` or `::1`) are rejected the same way: a
  genuinely remote secondary can never dial loopback on the primary, so
  advertising it would silently reproduce the original #866 failure under a
  configuration that merely looks valid.
- **Hostnames** (anything that does not parse as an IP literal at all) are
  also rejected: `NATS_BIND_IP` feeds Compose's port `HOST` field, which is
  an IP/port bind, not a resolvable name, so there is no guarantee a
  hostname value is reachable at the address `nats` actually publishes on.
All three cases need the explicit `NATS_ADVERTISE_URL` override instead, with
the real routable LAN/VPN address, reverse-proxy hostname, non-default
port, or `tls://` scheme that `NATS_BIND_IP` alone cannot express.
`NATS_ADVERTISE_URL` always takes precedence over `NATS_BIND_IP` and is
never reformatted or validated as an IP literal -- an operator who sets it
explicitly is asserting the value is already correct and reachable.
Neither variable has a default. If a primary has configured **neither** (or
only a `NATS_BIND_IP` that falls into one of the three rejected cases above
with no `NATS_ADVERTISE_URL`), registration now refuses the request outright
with HTTP 503 instead of falling back to the unreachable `nats_url` --
`setup.sh secondary` reports this clearly (rather than its generic "verify
the token/name" message) and names the exact variable to set. This endpoint
has no other legitimate caller: every real invocation is a genuine
remote-secondary registration, so there is no "install that doesn't use
remote secondaries" case that could be broken by refusing here -- an
install that never runs `setup.sh secondary` never reaches this code path at
all. See `services/ui/src/config.rs`'s `advertised_nats_url()` and its unit
tests for the exact precedence and rejection rules.

Note that setting `NATS_BIND_IP`/`NATS_ADVERTISE_URL` on the primary and
restarting only the `ui` container is not, on its own, enough to make a
registration attempt actually succeed end-to-end: the `nats` service itself
still needs `docker-compose.nats-secondary.yml` included (and the stack
recreated with it) to publish port 4222 on that address in the first place.
`ui` only computes what to *advertise*; it does not control what `nats`
itself publishes.

**nsupdate (RFC 2136):** TSIG-secured dynamic DNS channel into PowerDNS authoritative. Kea DHCP sends lease add/update/delete events through `kea-dhcp-ddns`; PowerDNS accepts those updates only for the LAN and private reverse zones that are explicitly mapped to the shared `DDNS_TSIG_KEY`.

## Kea DHCP

- DHCPv4 + DHCPv6 (dual-stack)
- IP ranges as start–end (no CIDR required)
- Static assignments: MAC → IP, editable via UI
- DDNS → PowerDNS: lease = automatically an A record (in the configured DHCP domain) and a PTR record (in the matching private reverse zone) via TSIG-secured nsupdate (RFC 2136). PTR updates were **not** applied in production until issue #768's fix: Kea's D2 daemon used to send every reverse update's on-wire zone as the literal `in-addr.arpa.`, which had no matching PowerDNS zone (only narrower private-range subzones exist), so PowerDNS rejected every PTR update regardless of octet; `reverse-ddns` now lists one entry per real private reverse zone instead. See [docs/dhcp-modes.md](dhcp-modes.md) for the full detail.
- DDNS enable/disable (issue #1076): whether Kea writes those DNS records is a separate control from whether Kea DHCP is running at all. The `DHCP_DDNS_ENABLED` env var (`config/{dev,prod}/dhcp.env`) sets the first-boot default for Kea's `dhcp-ddns.enable-updates`, and the Admin UI's DHCP page carries an independent "Enable DDNS Updates" toggle that flips `enable-updates` live via the Kea Control API. It defaults **off** for a fresh install (opt-in, matching Kea's own default), while an already-running install keeps whatever value it already has — `migrate_dhcp4_config()` merges the persisted `dhcp-ddns` block over the default, so the toggle's choice (and any existing install's on-state) survives restarts.
- REST API (Kea Control Agent) for Admin UI
- **Multi-threading is explicitly disabled** (`"multi-threading": {"enable-multi-threading": false}` in `services/dhcp/kea-dhcp4.conf`, re-asserted on every migration by `services/dhcp/entrypoint.sh`'s `migrate_dhcp4_config`). This is a deliberate override, not an oversight: Kea has shipped multi-threaded packet processing enabled by default since 2.4.0, but that feature targets high-query-rate ISP/carrier deployments processing thousands of leases per second across many CPU cores -- this project's DHCP server serves one LAN/lab-scale subnet, so the added concurrency surface (interacting with the `lease_cmds` hook, the DDNS-forwarding path, and the Admin UI's config-write/rollback machinery, none of which were designed against concurrent packet handlers) buys no real benefit here. No project history (commit messages, linked PRs) documents an incompatibility that was actually hit; this is a preventive simplicity choice, re-stated here so it isn't mistaken for an unexamined default. An operator with a genuinely large multi-subnet deployment can re-enable it (Kea's own default), but should first re-verify it against the hooks/DDNS paths above.

## Admin UI security headers

The Admin UI sends security response headers by default. The policy is compatible with the current self-hosted frontend assets and does not require external CDN JavaScript. Operators can tune the behavior with environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `UI_SECURITY_HEADERS` | `true` | Set to `false`, `0`, `off`, or `no` to disable the Admin UI security header middleware. |
| `UI_HSTS_MODE` | `auto` | Controls `Strict-Transport-Security`: `auto` only sends HSTS when `X-Forwarded-Proto: https` is present, `always` sends it on every response, and `never` disables it. |

Keep `UI_HSTS_MODE=auto` for direct LAN HTTP access or TLS-terminating reverse proxies that also leave `http://<host>:8080` reachable. Use `always` only when the UI hostname is intended to be HTTPS-only.

## Watchdog

Lightweight container with Docker socket access (restart permission).

**Health checks:** every service below has a Docker Compose `healthcheck:`
block, but `watchdog.sh` itself only *acts* on a subset of them -- see the
"Auto-restart" scope note directly below this list before assuming every
entry here is watched and restarted by the watchdog daemon.
- nginx: HTTP request on `/health`
- PowerDNS: DNS query test via `rec_control`
- Kea: REST API ping
- nats: HTTP probe against nats-server's own monitor endpoint (`http_port: 8222` set in the compose-generated boot config, checked via `wget` against `/healthz` -- nats:2-alpine ships BusyBox's wget/nc but no curl, verified empirically)
- ui: HTTP request on `/health` (`services/ui/src/main.rs`'s shallow liveness route, checked via `curl`, present in the image)
- syslog-ng: `syslog-ng-ctl healthcheck` (when the `logging` profile is active); fluent-bit: `fluent-bit -V` (binary-integrity only -- the pinned image ships no shell/wget/curl, so a real liveness probe isn't possible without a custom image build)

**Auto-restart:** X failed checks → `docker restart <container>`. Scope,
verified against `services/watchdog/watchdog.sh`: the daemon's own
`check_and_maybe_restart` loop only polls and auto-restarts `proxy`,
`dns-standard`, and (when `SSL_ENABLED=1`) `dns-ssl` -- the three container
names it takes via `CONTAINER_PROXY`/`CONTAINER_DNS_STANDARD`/
`CONTAINER_DNS_SSL`. `watchdog.sh` writes this state to a `status.json` file
every 30 seconds, but as of this writing the Admin UI has no route or
template that reads that file -- there is no per-service dashboard status
indicator today (UI delivery debt; see "Status" below).
Kea, syslog-ng, fluent-bit, `nats`, and `ui` all have a real Docker
healthcheck too (so `docker inspect`/`docker compose ps` and CI's own
wait-for-healthy scripts can see it), but the watchdog daemon does not poll
or restart any of those five itself.

**Scheduled purge (cron, daily):**
- Remove cache entries older than `CACHE_VALID_DAYS` (`config/{dev,prod}/watchdog.env`, `find -mtime`) — not `CACHE_VALID_HIT`, which is the unrelated nginx/proxy cache-validity variable in `config/{dev,prod}/proxy.env` (both happen to default to `365`, which previously masked this doc citing the wrong one)
- Complements nginx `inactive` (which works by access time)
- Syslog retention (opt-in, `SYSLOG_ENABLED=true`): storage-budget pruning under `SYSLOG_LOG_ROOT` — see the syslog-ng section below for the exact age-then-size ordering

**Disk monitoring:**
- `watchdog.sh`'s `disk_info()` computes a yellow (85% full) / red (95% full)
  color and writes it into `status.json` every 30 seconds, monitoring actual
  disk usage, not just nginx `max_size` -- but, same gap as "Status" above,
  nothing in the Admin UI reads or renders that file, so this warning/alarm
  is not currently operator-visible in the UI (see #849 observability
  finding #3). The dashboard's own cache-usage bar (`cache_pct` in
  `services/ui/src/routes/dashboard.rs`) is a separate, independently
  computed value (used cache bytes vs. `CACHE_MAX_GB`), not this disk-usage
  color.

**Status:** `watchdog.sh` computes per-service health and disk-usage color
(green/yellow/red) into `status.json` every 30 seconds, but nothing in the
Admin UI (`services/ui/src/routes/dashboard.rs`, `templates/dashboard.html`)
reads or renders that file as of this writing -- there is no per-service
"traffic light" indicator in the UI today. Treat this as unfinished Admin UI
delivery, not a shipped feature (see "Feature Completeness" in `AGENTS.md`).

## syslog-ng

Central log receiver for the stack (#453), opt-in via `docker compose --profile logging up -d` in `dev`, `prod`, and `quickstart` alike. `fluent-bit` (the `syslog` service) is the collector/forwarder: it tails every wired service's log file(s) (see the matrix below) and fans each one out to a forward to `syslog-ng` over TCP/601 (RFC 5424, plain LF framing, `network()` source with `flags(syslog-protocol)`); the proxy/nginx access log additionally gets a second, local plain-text copy (used by Netdata's `web_log` job in dev). `syslog-ng` writes received logs per-source, per-day under `/var/log/lancache-syslog-ng/<host>/<YYYYMMDD>.log`.

**Currently implemented:**
- Size-bounded rotation: an active log file is rotated once it exceeds `SYSLOG_MAX_FILE_MB` (default 100), then `syslog-ng` is signaled (`SIGHUP`) to reopen the (recreated) destination file.
- Compression: rotated files are compressed with `zstd -T0` at `SYSLOG_COMPRESSION_LEVEL` (default 19); falls back to `gzip` if `zstd` cannot be installed at container start (e.g. no network egress).
- Config for both `syslog` and `syslog-ng` is generated at container start (CLI flags for fluent-bit, an inline heredoc for syslog-ng) rather than bind-mounted, so `quickstart` — which has no local repo checkout — runs the identical pipeline as `dev`/`prod`.
- Every service in the matrix below is wired end to end except `dhcp-probe` (one-shot diagnostic, see its row for why that's a deliberate N/A, not a gap).
- Per-service wiring mechanism varies by what the underlying daemon actually supports (#633): a native dual stdout+file option where one exists (Kea's `output-options` array), a `tee` of the daemon's own stdout into a file where no such option exists (PowerDNS has no file-log directive on Linux at all; nats-server and dnsmasq each support only one log destination at a time, not both simultaneously), or a second application-level logging layer (the Admin UI's `tracing-subscriber` setup). Every one of these choices is a documented, deliberate trade-off recorded in the matrix's Notes column, not an oversight.
- Storage-budget retention: `watchdog.sh`'s `maybe_prune_syslog()` (opt-in via `SYSLOG_ENABLED=true`, `--profile logging`) enforces an overall storage budget on top of syslog-ng's own fixed-threshold rotation above. Age-based deletion runs first (`SYSLOG_RETENTION_DAYS`, default 30); if the tree under `SYSLOG_LOG_ROOT` is still over `SYSLOG_MAX_GB` (default 10) afterward, the oldest remaining files are deleted next — regardless of age — until back under budget. Size budget takes priority over the retention-days floor. Rate-limited via its own stamp file (once per day), same pattern as the cache purge above.
- `syslog` (fluent-bit) has a `healthcheck` block (`fluent-bit -V`, binary-integrity only -- see the logging matrix table below for why a real liveness probe isn't possible with the pinned image), matching `syslog-ng`'s existing block shape.
- `scripts/check-logging-matrix.sh`, run in CI's `validate-compose` job, fails if a Compose service has no row in the logging matrix table below, or if a row names a service that no longer exists.
- Admin UI log reading from the central path: `services/ui/src/syslog_client.rs` (opt-in via `SYSLOG_ENABLED=true`, same 4-variable contract watchdog's retention engine uses) reads `/logs` and a dashboard tile from `SYSLOG_LOG_ROOT` directly, transparently decompressing rotated `.zst`/`.gz` files, instead of the `STANDARD_LOG`/`SSL_LOG` direct-nginx-read path. Disabled installs keep the old direct-nginx-read behavior unchanged.

**Not implemented yet (no open tracking issue as of this writing — #633, which used to be cited here, closed 2026-07-13 once its own four listed sub-items landed; these two were never actually part of that list):**
- Per-service log level configuration in the Admin UI.
- Configurable remote forwarding destination (IP/port/protocol) from the Admin UI.

**Logging matrix** (maintained here per #453's requirement; kept up to date as more services are wired):

| Service | Logging path | Notes |
| --- | --- | --- |
| proxy (nginx) | Via fluent-bit → syslog-ng | `access.log`, `error.log`, and `stream.log` (SNI-passthrough logging, standard mode) all tailed and forwarded, each its own fluent-bit tag/db pair |
| dns-standard | Via fluent-bit → syslog-ng | PowerDNS has no native file-log directive on Linux (confirmed against upstream docs — only syslog/stdout); `entrypoint.sh`'s `run_auth`/`run_recursor`/`run_nats_subscriber` `tee` each process's stdout into `/var/log/lancache-dns/{pdns-auth,pdns-recursor,nats-subscriber}.log` on the `dns-logs-standard` volume instead |
| dns-ssl | Via fluent-bit → syslog-ng | Same mechanism as dns-standard, own `dns-logs-ssl` volume so the two instances' log files never collide |
| dhcp | Via fluent-bit → syslog-ng | Kea's `loggers[].output-options` now lists both `stdout` and a file under `/var/log/kea/` for all three daemons (`kea-dhcp4.log`, `kea-ctrl-agent.log`, `kea-dhcp-ddns.log` — native dual-output, no `docker logs` loss). Must be exactly `/var/log/kea`, not this project's usual `/var/log/lancache-<service>` convention: Kea's packaged binaries hard-restrict file-logger `output` paths to that one directory (a security hardening against arbitrary file writes via a malicious `config-set`), rejecting any other path at config-load time and refusing to start at all (issue #773). `migrate_dhcp4_config()` adds the file output to any pre-existing DHCPv4 runtime config on upgrade, while the Control Agent and DHCP-DDNS runtime configs are unconditionally regenerated from their templates on every start so they never need a migration path |
| dhcp-proxy | Via fluent-bit → syslog-ng | dnsmasq's `log-facility=` directive supports only one destination at a time (no dual-output mode), so `docker logs` goes quiet on this container while the `logging` profile is active — an accepted, documented trade-off, also applied to `nats` below for the same upstream reason; `entrypoint.sh`'s own startup diagnostics still reach `docker logs` since they run before dnsmasq is exec'd |
| ui | Via fluent-bit → syslog-ng | `main.rs`'s `init_tracing()` adds a second `tracing-subscriber` layer that appends to `UI_LOG_FILE` (default `/var/log/lancache-ui/ui.log`) alongside the existing stdout layer; best-effort — a missing/unwritable log path never blocks startup |
| watchdog | Via fluent-bit → syslog-ng | `watchdog.sh` itself is unchanged; the compose `entrypoint`/`command` override `tee`s its stdout into `/var/log/lancache-watchdog/watchdog.log` via `exec /watchdog.sh > >(tee -a ...) 2>&1`, so it stays PID 1 (signal handling unaffected) |
| nats | Via fluent-bit → syslog-ng | Like dnsmasq, nats-server logs to exactly one destination — no dual-output mode exists — so `log_file: /var/log/lancache-nats/nats.log` (set both in the compose-generated boot config and, authoritatively, by the Admin UI's `update_nats_conf`) means `docker logs` goes quiet on this container while the `logging` profile is active; same accepted trade-off as dhcp-proxy |
| netdata | Via fluent-bit → syslog-ng | The pinned netdata image ships its default `/var/log/netdata/*.log` paths as symlinks to `/dev/stdout`/`/dev/stderr` (nothing for fluent-bit to tail), so — same "no local repo checkout to bind-mount a config file from" constraint as `syslog`/`syslog-ng` below — an inline `entrypoint` override writes a `netdata.conf` that redirects the `[logs]` `collector`/`daemon`/`health` sources to real files at `/var/log/netdata/*.file.log`, then `exec`s the image's own `/usr/sbin/run.sh`; that path is mounted onto the `netdata-logs` volume, which fluent-bit tails read-only. `access`/`debug` stay on their stdout defaults (high-rate/empty). netdata v2 has no separate `error` log key — error-level events land in `daemon`/`collector` |
| dhcp-probe | Not applicable | One-shot diagnostic helper (`restart: "no"`), started and stopped on demand by the Admin UI for a single probe run — no persistent process or log stream to route |
| fluent-bit (`syslog`) | Local container stdout only | No self-log forwarding to syslog-ng yet (no open tracking issue as of this writing — see the "Not implemented yet" note above); healthcheck is `fluent-bit -V` (binary-integrity only -- the pinned image ships no shell/wget/curl, so a real liveness probe isn't possible without a custom image build) |
| syslog-ng | Local container stdout only | Healthcheck via `syslog-ng-ctl healthcheck`; no self-log forwarding to itself (would be redundant) |
| docker-socket-proxy | Not applicable | Third-party pinned image (`tecnativa/docker-socket-proxy`); only Docker's own stdout logging driver applies, there is no application log stream of our own to forward |

## Cache Warming

Separate container (`services/warmer`) with `steamcmd`.

**Workflow:**
1. User enters Steam app ID
2. `steamcmd` fetches depot manifest (anonymous for F2P, optional with account for paid games)
3. Chunk URLs fetched through local proxy → cached
4. Progress displayed live in Admin UI (total chunks / completed / MB/s)

**Steam account:** optional via env var (`STEAM_USER`, `STEAM_PASS`) — never in repo, never in image.

**Tracking:** which app IDs were warmed + which CDN URLs belong to them → basis for targeted purging.

Epic / GOG: not supported.

## Cache Retention & Cleanup

**Three mechanisms combined:**

| Mechanism | Trigger | Basis |
|---|---|---|
| nginx `inactive` | automatic, continuous | not accessed since `CACHE_INACTIVE` |
| Watchdog purge cron | daily automatic | file older than `CACHE_VALID_DAYS` |
| Manual purge | Admin UI on-demand | freely selectable |

**Manual purging in Admin UI:**

| Action | Granularity |
|---|---|
| Clear entire cache | Everything |
| Purge by age | Older than X days — preview "~X GB freed" before confirmation |
| Purge by access | Not accessed for X days |
| Delete single title | All chunks of a warmed app ID |
| Pinning | Protect app ID from LRU + automatic purge |

**Size validation:** Admin UI checks available disk space when saving `CACHE_MAX_SIZE`. Warning > 90% of available space, error if exceeded.

## Monitoring (Admin UI)

- Netdata integrated (proxy via `/api/netdata`)
- Statistics: CPU, RAM, network MB/s (realtime + history), disk I/O
- Dashboard: cache fill level, hit/miss rate, active connections
- Watchdog per-service traffic light bar: **not yet implemented** -- `watchdog.sh`
  computes the underlying `status.json` state, but the Admin UI does not read
  or render it (see the "Status" note under Watchdog above)

## Admin UI

Runs on its own Axum webserver (port 8080) — independent from nginx. If nginx is down, the UI is still reachable and shows the error.

- Two modes: **Beginner** (guided, no jargon) / **Expert** (technical direct)
- DNS: create zones, host entries, PTR checkbox for LAN IPs
- Kea: lease overview, create/edit static assignments
- Cache: start warming, progress, purging, retention + slice/size settings
- Logs: filtered by host/service (implemented against the central syslog-ng path, #848); level-selectable filtering is not yet implemented (no open tracking issue as of this writing)
- Advanced options (root mirror, filter AAAA, secondary, syslog forwarding) under "Advanced" (syslog forwarding configuration is not yet exposed in the UI; no open tracking issue as of this writing — see the syslog-ng section's "Not implemented yet" note above)

## IPv6

- PowerDNS: dual-stack listeners, AAAA records, IPv6 reverse zones
- Kea: DHCPv6 parallel to DHCPv4
- nginx: already IPv6-capable
- Docker: IPv6 on Linux host via `"ipv6": true` in `daemon.json`

## Security

- All generated secrets (TSIG keys, Kea API token) auto-generated at container start, never in repo
- Docker socket in watchdog: restart permission only, no full admin
- Repo is public: no real IPs, passwords, or keys in config files

## Implementation order

1. nginx (slice module + optimizations)
2. PowerDNS (authoritative + recursor)
3. Kea DHCP
4. Watchdog
5. syslog-ng
6. Cache warmer
7. Admin UI
