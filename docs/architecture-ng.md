# LanCache-NG Architecture

## Services

Exactly five containers. Programs inside a container start through OpenRC
(`openrc-init` as PID 1, package init.d scripts) or, for the proxy, as the
container's only process.

| Container | Programs | Start |
|---|---|---|
| proxy | nginx | nginx is the entrypoint |
| dns | PowerDNS authoritative, PowerDNS Recursor | OpenRC (`OPENRC_SERVICES`) |
| dhcp | Kea (dhcp4, ctrl-agent, ddns) or dnsmasq, by `DHCP_MODE` | OpenRC runlevel per mode (`OPENRC_RUNLEVELS`); mode off: the UI keeps the container stopped |
| services | watchdog, cachehamster, syslog-ng, chronyd, snmpd | OpenRC; watchdog and cachehamster get generated openrc-run files with supervise-daemon |
| ui | Admin UI (Axum, Tera), rrdtool graphs | the binary is the entrypoint |

NATS, the `nats-subscriber` and Netdata are gone since 2.0 (PR #1858).

## nginx

Mainline from nginx.org (never the base OS's own distro package). Base: `alpine:3.24`
(migrated from `debian:13-slim` as part of issue #815's Alpine push).

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

**Cache configuration (env vars set at `setup.sh` install time; see "Cache
Retention & Cleanup" below for what the Admin UI actually lets an operator
change after initial setup — currently only `CACHE_MAX_SIZE`, via the
dashboard's resize control, issue #1069 part 3):**

`CACHE_MAX_SIZE` and `CACHE_MEM_MB` live in `deploy/prod/.env.local` (per install). The other defaults below come from `runtime.defaults` in `build-manifest.yml`; an operator overrides one in the same file.

| Variable | Default | Description |
|---|---|---|
| `CACHE_MAX_SIZE` | `50g` | Max cache size — the Admin UI dashboard's resize control re-validates a requested size against real free disk space at `CACHE_DIR` (same buffer-scaled safety check as the setup-time prompt, issue #1069) before persisting it for the host convergence tick to apply |
| `CACHE_MEM_MB` | `512` | keys_zone size (1MB ≈ 8,000 keys, nginx's own documented rule of thumb — see "Cache tuning review" below for the sizing math; previously documented here as `200`, which never matched the real shipped default `512` in `runtime.defaults` of the SOT) |
| `CACHE_MIN_FREE` | `1g` | Free-disk-space floor (bug-hunt #849 item 11) — the cache manager evicts LRU entries once free space at `CACHE_DIR`'s filesystem drops below this, independent of and in addition to `CACHE_MAX_SIZE` |
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

**Note:** `max_size` is not a hard limit — cache can exceed it with crashed workers. Watchdog monitors actual disk usage. `min_free` (see above) is an nginx-native backstop for the more common case (no crash, just an operator-chosen `CACHE_MAX_SIZE` that doesn't leave enough real headroom on a shared filesystem) — it does not cover the crashed-worker case either, since it is enforced by the same cache-manager process `max_size` already relies on.

### Cache tuning review (bug-hunt #849/#1068 item 11)

`proxy_cache_lock on` (see `services/proxy/proxy-params.conf`) was already in
place before this review — only one worker fetches a given cache-miss URL at
a time, with a 2h `proxy_cache_lock_timeout` for large in-flight game
downloads (see `AGENTS.md`'s `AG-KD-006`). No change needed there.

The rest of `proxy_cache_path`'s tuning knobs beyond `max_size`/`min_free`
(`manager_files`, `manager_threshold`, `manager_sleep`, `loader_files`,
`loader_threshold`, `loader_sleep`) are all still at nginx's untouched
defaults (`100` files / `200ms` / `50ms` for both the manager and loader).
Whether these need raising for a given deployment depends on two things this
project's own install base varies on enormously and that this documentation
cannot know in advance: how many cache files/slices actually accumulate, and
how fast the host's disk can service metadata operations. Rather than invent
a number, here is the reasoning and the exact commands to derive one for a
real host:

- **`keys_zone` sizing.** Every cached byte range is one key (see the slice
  module above), so the number of keys a fully-populated cache holds is
  `CACHE_MAX_SIZE / CACHE_SLICE_SIZE`, not the number of distinct files —
  a single large game update sliced into `CACHE_SLICE_SIZE` chunks
  contributes one key per chunk. Using nginx's own ~8,000-keys-per-MB rule
  of thumb, the keys_zone memory a fully-populated cache needs is
  approximately:
  ```text
  keys_zone_MB ≈ (CACHE_MAX_SIZE_bytes / CACHE_SLICE_SIZE_bytes) / 8000
  ```
  At the shipped defaults (`CACHE_MAX_SIZE=50g`, `CACHE_SLICE_SIZE=8m`) that
  is `(50*1024/8)/8000 ≈ 0.8 MB` — the shipped `CACHE_MEM_MB=512` default
  covers roughly `512*8000*8m ≈ 32 TB` of fully-populated cache before
  running out of key-metadata space, i.e. comfortable headroom for any
  `CACHE_MAX_SIZE` a home/LAN deployment is realistically likely to set. An
  operator scaling `CACHE_MAX_SIZE` well past that point (a large multi-site
  or ISP-scale deployment) should recompute `keys_zone_MB` with the formula
  above rather than assume the shipped default still has headroom.
- **Cache-loader throughput after a restart.** The cache loader (which
  re-indexes on-disk cache entries into the keys_zone at nginx startup)
  processes at most `loader_files` (default `100`) entries or runs for at
  most `loader_threshold` (default `200ms`) per iteration, whichever comes
  first, then sleeps `loader_sleep` (default `50ms`) before the next
  iteration. At the disk-bound worst case (each iteration hits its `200ms`
  threshold), that is a ceiling of `100 files / 250ms ≈ 400 files/sec`;
  actual throughput on a fast disk that finishes each 100-file batch well
  under the threshold can be higher (bounded instead by `loader_sleep`
  alone, `100 files / 50ms = 2000 files/sec`). For a cache holding `N` slice
  files, full re-indexing after a restart therefore takes somewhere between
  `N/2000` and `N/400` seconds — on a slow/loaded disk or with a very large
  `N`, this can be minutes, during which requests for not-yet-reloaded
  entries are treated as cache misses. To find your own real `N` and decide
  whether to raise `loader_files`/`loader_threshold`, run this against a
  live deployment's actual cache directory:
  ```bash
  find "$CACHE_DIR" -type f | wc -l
  ```
  (`$CACHE_DIR` is the host path bind-mounted to `/var/cache/nginx/lancache`
  via the `proxy-cache` named volume's `driver_opts.device` — see
  `deploy/prod/docker-compose.yml`'s top-level `volumes:` block for the
  exact wiring.) The same
  `manager_files`/`manager_threshold`/`manager_sleep` throttle governs the
  cache **manager** (LRU/`min_free` eviction during normal operation, not
  just at startup) — a deployment with a very large `N` and a cache that
  stays near `CACHE_MAX_SIZE`/`CACHE_MIN_FREE` continuously may see eviction
  lag behind ingestion under the same defaults, for the same reason. No
  change is made to any of these defaults in this pass: this project's real
  install base spans everything from small home hardware to larger LAN
  setups, and a single hardcoded replacement value would be exactly as
  unverified for most of that range as the untouched nginx default is —
  raise `manager_files`/`loader_files` (and their paired `_threshold`
  values) only after measuring `N` and disk latency on the actual target
  host, not preemptively.

## PowerDNS

- Two programs: the authoritative server (LAN zone, private reverse zones,
  RPZ from the CDN list) and the recursor (clients).
- The Admin UI writes records through the native PowerDNS HTTP API (PATCH
  rrsets). PowerDNS raises the serial and sends NOTIFY.
- Secondaries pull the zones by AXFR. `DNS_SECONDARIES` ("name@ip") feeds
  `also-notify` and `allow-axfr-ips`. DDNS needs TSIG unless
  `DDNS_ALLOW_UNSIGNED` is on (`dnsupdate-require-tsig`).
- On a secondary the watchdog compares serials and flushes the recursor
  cache when a new zone arrived.
- AAAA filter: `DNS_FILTER_AAAA`; the recursor Lua script answers AAAA with
  no data.
- Zone snapshots and rollback: see
  [known-good-config-snapshots.md](known-good-config-snapshots.md).

## Kea DHCP

- DHCPv4 + DHCPv6 (dual-stack)
- IP ranges as start–end (no CIDR required)
- Static assignments: MAC → IP, editable via UI
- DDNS → PowerDNS: lease = automatically an A record (in the configured DHCP domain) and a PTR record (in the matching private reverse zone) via TSIG-secured nsupdate (RFC 2136). PTR updates were **not** applied in production until issue #768's fix: Kea's D2 daemon used to send every reverse update's on-wire zone as the literal `in-addr.arpa.`, which had no matching PowerDNS zone (only narrower private-range subzones exist), so PowerDNS rejected every PTR update regardless of octet; `reverse-ddns` now lists one entry per real private reverse zone instead. See [docs/dhcp-modes.md](dhcp-modes.md) for the full detail.
- DDNS enable/disable (issue #1076): whether Kea writes those DNS records is a separate control from whether Kea DHCP is running at all. The `DHCP_DDNS_ENABLED` env var (SOT runtime default in `.github/yaml/build-manifest.yml`) sets the first-boot default for Kea's `dhcp-ddns.enable-updates`, and the Admin UI's DHCP page carries an independent "Enable DDNS Updates" toggle that flips `enable-updates` live via the Kea Control API. It defaults **off** for a fresh install (opt-in, matching Kea's own default), while an already-running install keeps whatever value it already has — the supervisor's `kea_dhcp4_own` (`services/watchdog/src/main.rs`) sets the `dhcp-ddns` block only when the saved `kea-dhcp4.conf` has none, so the toggle's choice (and any existing install's on-state) survives restarts.
- REST API (Kea Control Agent) for Admin UI
- NTP option (`ntp-servers`, DHCPv4 option 42): each subnet's value is a plain operator-editable field (`main.rs`'s `add_subnet`/`update_subnet`), defaulting to the project-wide `DHCP_NTP_SERVERS` setting. When LanCache-NG-NTP (chronyd in the `services` container) is enabled AND its separate "auto-set as DHCP NTP server" toggle is on, `main.rs`'s `apply_ntp_lan_ip_to_all_subnets` instead forces every subnet's `ntp-servers` option to the stack's LAN address (`IP_HTTP`), overriding any per-subnet manual value for as long as the toggle stays on; turning it off restores the project-wide default via `restore_default_ntp_on_all_subnets`. The toggle is deliberately independent from LanCache-NG-NTP's own enable/disable switch — enabling NTP never auto-populates DHCP by itself.
- **Multi-threading is explicitly disabled** (`"multi-threading": {"enable-multi-threading": false}`, set by the supervisor's `kea_dhcp4_own` in `services/watchdog/src/main.rs` on every Kea start when the saved `kea-dhcp4.conf` has no `multi-threading` key). This is a deliberate override, not an oversight: Kea has shipped multi-threaded packet processing enabled by default since 2.4.0, but that feature targets high-query-rate ISP/carrier deployments processing thousands of leases per second across many CPU cores -- this project's DHCP server serves one LAN/lab-scale subnet, so the added concurrency surface (interacting with the `lease_cmds` hook, the DDNS-forwarding path, and the Admin UI's config-write/rollback machinery, none of which were designed against concurrent packet handlers) buys no real benefit here. No project history (commit messages, linked PRs) documents an incompatibility that was actually hit; this is a preventive simplicity choice, re-stated here so it isn't mistaken for an unexamined default. An operator with a genuinely large multi-subnet deployment can re-enable it (Kea's own default), but should first re-verify it against the hooks/DDNS paths above.

## Admin UI security headers

The Admin UI sends security response headers by default. The policy is compatible with the current self-hosted frontend assets and does not require external CDN JavaScript. Operators can tune the behavior with environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `UI_SECURITY_HEADERS` | `true` | Set to `false`, `0`, `off`, or `no` to disable the Admin UI security header middleware. |
| `UI_HSTS_MODE` | `auto` | Controls `Strict-Transport-Security`: `auto` only sends HSTS when `X-Forwarded-Proto: https` is present, `always` sends it on every response, and `never` disables it. |

Keep `UI_HSTS_MODE=auto` for direct LAN HTTP access or TLS-terminating reverse proxies that also leave `http://<host>:8080` reachable. Use `always` only when the UI hostname is intended to be HTTPS-only.

## Watchdog

The watchdog only watches. It reads states, raises alarms and restarts a
container within limits. It renders no config and supervises no program.

| Check | Source | Action |
|---|---|---|
| Container state and health | Docker API | restart, at most `WATCHDOG_RESTART_LIMIT` per `WATCHDOG_RESTART_WINDOW` |
| Free disk | `WATCHDOG_DISK_PATHS`, `WATCHDOG_DISK_MIN_FREE_PERCENT` | alarm |
| Certificates | `WATCHDOG_CERT_FILES`, `WATCHDOG_CERT_WARN_SECS` | alarm |
| Zone serial primary and secondary | DNS SOA | alarm; on a secondary a recursor cache flush |
| DHCP mode off | `DHCP_MODE` | a stopped dhcp container is not an error |

Alarms go to `WATCHDOG_ALARM_FILE`; the Admin UI shows them.

## syslog-ng

Central log receiver for the stack. One syslog-ng runs inside the `services` container; the watchdog starts it from a config it renders itself (`syslog_ng_conf` in `services/watchdog/src/main.rs`). There is no Fluent Bit and no separate syslog container.

**Currently implemented:**
- Every container logs through Docker's `syslog` driver (`x-logging` in `deploy/prod/docker-compose.yml`) to `udp://127.0.0.1:${LANCACHE_LOG_PORT}`; syslog-ng listens there.
- Files land in `${SYSLOG_NG_LOG_DIR}/<program>/YYYYMMDD.log`, one file per container and day. The directory is group-readable for `LOG_READER_GROUP`, so the Admin UI reads it read-only.
- Logging is switched per service, not globally: `LOGGING_PROXY_ENABLED`, `LOGGING_DNS_ENABLED`, `LOGGING_DHCP_ENABLED` and `LOGGING_UI_ENABLED` (default on). The Admin UI saves them on the `/logs` page into its settings file; it does not touch syslog-ng. The watchdog reads that file, re-renders the config with the switched-off programs filtered out and restarts syslog-ng (the settings file is watched). The `services` container (watchdog) always logs and has no switch.
- With the proxy switch off, the proxy access log gets no new lines, so the Admin UI statistics and dashboard show no new traffic. The `/logs` page says so.
- Retention (`SYSLOG_RETENTION_DAYS`, `SYSLOG_MAX_GB`) is done by the retention task of the watchdog.
- The Admin UI reads `/logs` from the store directly (read-only mount).
- `ci.sh check logging-matrix` (part of `ci.sh check all`) fails if a Compose service has no row in the logging matrix table below, if a row names a service that no longer exists, or if a service has more than one row.

**Not implemented yet:**
- Per-service log level configuration in the Admin UI.
- Configurable remote forwarding destination (IP/port/protocol) from the Admin UI.

**Logging matrix** (one row per Compose service in `deploy/prod/docker-compose.yml`; `ci.sh check logging-matrix` enforces it):

| Service | Logging path | Store directory under `SYSLOG_NG_LOG_DIR` |
| --- | --- | --- |
| `services` | Docker `syslog` driver (`x-logging`) → syslog-ng in `services` | `LanCache-NG-services/` |
| `proxy` | Docker `syslog` driver (`x-logging`) → syslog-ng in `services` | `LanCache-NG-proxy/` |
| `dns` | Docker `syslog` driver (`x-logging`) → syslog-ng in `services` | `LanCache-NG-dns/` |
| `dhcp` | Docker `syslog` driver (`x-logging`) → syslog-ng in `services` | `LanCache-NG-dhcp/` |
| `ui` | Docker `syslog` driver (`x-logging`) → syslog-ng in `services` | `LanCache-NG-ui/` |

## Cache Warming

The cachehamster runs in the services container. The Admin UI drives it
through `docker exec` (`lancache-cachehamster status`, `login-begin`,
`login-poll`, `library`, `add`, `start`, `cancel`, `remove`).

- Jobs run now, later (started by hand) or at a set time. Up to
  `CACHEHAMSTER_QUEUES` jobs run at once, each with
  `CACHEHAMSTER_CONCURRENCY` connections.
- Every body is read and dropped in memory; nothing is written to disk.
- Steam: QR login through the Steam Web API. Only the sealed refresh token
  is stored. An own CM connection (websocket) reads PICS app info and
  manifest request codes. The zipped manifest is read in memory for chunk
  ids only. Chunks are fetched through the proxy with Host
  `STEAM_CDN_HOST`.

## Cache Retention & Cleanup

**Two automatic mechanisms, plus one Admin UI operator control:**

| Mechanism | Trigger | Basis |
|---|---|---|
| nginx `inactive` | automatic, continuous | not accessed since `CACHE_INACTIVE` |
| Watchdog purge cron | daily automatic | file older than `CACHE_VALID_DAYS` (`purge_cache` in the watchdog's retention task, `services/watchdog/src/main.rs`) |
| Admin UI cache resize | operator on-demand from the dashboard | requested whole-GB `CACHE_MAX_SIZE`, re-validated against real free disk space (issue #1069 part 3) |

`setup.sh`'s initial "Cache size in GiB" prompt also validates the requested
size against real free disk space at `CACHE_DIR`, with a safety buffer that
scales with the requested size (issue #1069); `CACHE_INACTIVE` is likewise a
real setup-time prompt, not just a silent default. (This setup-time
validation shipped on `master`/v0.2.0 via issue #1069's PR #1070; as of this
writing it has not yet been synced into `current_dev`'s `setup.sh` — a
branch-hygiene gap, not a design decision. The Admin UI resize control
described below is independent of that gap: it runs its own real
disk-space check inside the Admin UI container regardless of whether
`setup.sh`'s own prompt-time check has landed on this branch.)

**Admin UI cache resize (`services/ui/src/main.rs`, issue #1069 part
3):** the dashboard shows current usage, current `CACHE_MAX_SIZE`, and lets an
operator submit a new whole-GB size. The request is re-validated against real
free disk space at `CACHE_DIR` with the same buffer-scaled safety check as
`setup.sh`'s prompt (reject unless
`available_free_space_at(CACHE_DIR) - buffer(cache_gb) >= cache_gb`; on
rejection, the largest currently-passing value is suggested). A validated
request does not take effect synchronously: `CACHE_MAX_SIZE` reaches the
proxy container via the runtime env
(`deploy/prod/docker-compose.yml`'s
`CACHE_MAX_SIZE: ${CACHE_MAX_SIZE:-}` in the `x-environment` map `proxy-ui`), which this container has
no filesystem access to, and the Admin UI's Docker access deliberately has no
exec capability to send nginx a reload signal even if it did (see
`services/ui/src/main.rs`'s header comment). The request is instead
persisted to the `ui-data`-backed settings file, and `setup.sh`'s
`cmd_converge_reconcile` (run on the host by `lancache-converge.service`,
currently every ~5 minutes) folds it into the real `.env` and lets the
existing `docker compose up -d --remove-orphans` convergence step recreate the
proxy container — the same host-bridged model issue #819's release-channel
control already established. This is a full container recreate, not a live
reload: empirically, nginx itself DOES accept a changed `max_size` for an
existing cache zone via a plain `nginx -s reload` (verified against nginx's
own source — `ngx_http_file_cache_init` in `src/http/ngx_http_file_cache.c`
reuses the shared-memory zone across a reload while recalculating `max_size`
from the new config, and `ngx_master_process_cycle` in
`src/os/unix/ngx_process_cycle.c` respawns fresh cache manager/loader
processes with that new config on `SIGHUP`); it is this project's own
supervisor's `nginx` render in `services/watchdog/src/main.rs` (fills
`CACHE_MAX_SIZE` from the container env into `nginx.conf` when it starts nginx,
and sends nginx no reload signal) that
makes a full recreate the only mechanism available today, not a limitation of
nginx itself. The convergence writes the setup.sh-managed runtime env
(`deploy/prod/.env.local`), from which `deploy/prod/docker-compose.yml`
interpolates both `CACHE_MAX_SIZE` for the `proxy` service and
`CACHE_MAX_GB` for the `ui` service, so the dashboard's displayed target and
the limit nginx enforces change in the same recreate.

**Not yet implemented:** a manual "clear cache now" / purge-by-age / purge-
by-access / pin-app-ID surface. The watchdog's `purge_cache`
(`services/watchdog/src/main.rs`) is the only automatic purge path beyond nginx's own
`inactive` eviction; there is no route or template anywhere in
`services/ui/src/main.rs` that clears, previews, or selectively deletes cache
entries. See issue #1069's own feasibility notes for why an out-of-cycle
cache-manager sweep needs a bespoke script (nginx has no external signal for
one) rather than being a given.

## Monitoring (Admin UI)

- snmpd in the services container exposes host and service counters.
- The Admin UI samples them every `STATS_STEP` into RRD files and draws the
  graphs with rrdtool (`/stats`, ranges from `STATS_RANGES`).
- The dashboard shows container states, watchdog alarms, cache fill level
  and the recent requests.

## Admin UI

Runs on its own Axum webserver (port 8080) — independent from nginx. If nginx is down, the UI is still reachable and shows the error.

- Two modes: **Beginner** (guided, no jargon) / **Expert** (technical direct)
- DNS: create zones, host entries, PTR checkbox for LAN IPs
- Kea: lease overview, create/edit static assignments
- Cache: start warming, progress, purging, retention + slice/size settings
- Logs: filtered by host/service (implemented against the central syslog-ng path, #848); level-selectable filtering is not yet implemented (an open decision from #1343): syslog-ng stores every line with no severity filter, and nginx's access lines have no severity field at all
- Advanced options (root mirror, filter AAAA, secondary, syslog forwarding) under "Advanced" (syslog forwarding configuration is not yet exposed in the UI; no open tracking issue as of this writing — see the syslog-ng section's "Not implemented yet" note above)

## IPv6

- PowerDNS: dual-stack listeners, AAAA records, IPv6 reverse zones
- Kea: DHCPv6 parallel to DHCPv4
- nginx: already IPv6-capable
- Docker: IPv6 on Linux host via `"ipv6": true` in `daemon.json`

## Security

- All generated secrets (TSIG keys, Kea API token) auto-generated at container start, never in repo
- Docker socket only in the `services` container, read-write and with no socket proxy; its watchdog lists, inspects and restarts the stack's containers (see `SECURITY.md` section 3)
- Repo is public: no real IPs, passwords, or keys in config files

## Implementation order

1. nginx (slice module + optimizations)
2. PowerDNS (authoritative + recursor)
3. Kea DHCP
4. Watchdog
5. syslog-ng
6. CacheHamster (Cache-Prefill)
7. Admin UI
