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
| nginx (proxy) | on | — | Mainline from nginx.org, Alpine base (issue #815) |
| PowerDNS | on | dnsmasq | Authoritative + Recursor for DNS spoofing & recursion |
| Kea DHCP / DHCP modes | off | — | Configurable four-state: `disabled` / `kea` / `dnsmasq-proxy` / `dnsmasq-relay` (#844); requires PowerDNS (DDNS via nsupdate) in `kea` mode. The two dnsmasq modes share one `dhcp-proxy` container (config selected by DHCP_MODE): `dnsmasq-proxy` injects PXE options alongside an existing server, `dnsmasq-relay` forwards DHCP to an upstream server on another segment. See [docs/dhcp-modes.md](dhcp-modes.md). |
| LanCache-NG-NTP | off (`ntp` Compose profile) | — | chrony-based NTP server, disciplined against public NTP servers, serving LAN clients on UDP/123; optional "auto-set as DHCP NTP server" toggle pushes its LAN address into Kea's `ntp-servers` option. See the "Kea DHCP" section below. |
| Watchdog | on | — | Health checks, auto-restart, purge cron |
| syslog (fluent-bit + syslog-ng, combined) | on (`logging` Compose profile, default-enabled since #1343; real opt-out via `LOGGING_ENABLED=0`) | — | Central log receiver; fluent-bit forwards logs from every wired service to syslog-ng inside the same container (#453, combined into one image 2026-08) — see the syslog-ng section's full logging matrix below, not just proxy access logs |
| Admin UI | on | — | Axum/Rust, Tera, Tailwind, separate port |
| Cache Warmer | not implemented | — | **Design-only, not shipped**: no `services/` code, no Compose service, nothing runnable exists yet under this name. See [docs/design-steam-prefill.md](design-steam-prefill.md) (issue #816, overlapping #871) for the current proactive cache-warming design plan and its open maintainer decisions. Do not treat this row as an existing on/off feature until that design actually lands. |

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

| Variable | Default | Description |
|---|---|---|
| `CACHE_MAX_SIZE` | `50g` | Max cache size — the Admin UI dashboard's resize control re-validates a requested size against real free disk space at `CACHE_DIR` (same buffer-scaled safety check as the setup-time prompt, issue #1069) before persisting it for the host convergence tick to apply |
| `CACHE_MEM_MB` | `512` | keys_zone size (1MB ≈ 8,000 keys, nginx's own documented rule of thumb — see "Cache tuning review" below for the sizing math; previously documented here as `200`, which never matched the real shipped default in `config/prod/proxy.env`/`deploy/quickstart/.env`/`setup.sh`, all `512` since this variable was introduced 2026-06-18/19) |
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
  `deploy/prod/docker-compose.yml`'s top-level `volumes:` block, or
  `deploy/quickstart/docker-compose.yml`'s direct `${CACHE_DIR}:...` bind
  mount, for the exact wiring in use on a given deployment profile.) The same
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
| `ROOT_ZONE_MIRROR` | `1` (enabled) in `services/dns/entrypoint.sh`'s own fallback; this repo's shipped `config/prod/dns-*.env` explicitly set `1` | Root zone mirror (AXFR from root servers). Was previously documented here as `ENABLE_ROOT_MIRROR` — that name does not exist in code; `docs/dns-admin-ui-scope.md` already used the correct name. |
| Global AAAA-response filter | off by default | Suppresses all AAAA answers for every client, regardless of address family. Not an env var/restart-time setting: toggled live via the Admin UI (`POST /domains/aaaa-filter`), which writes/removes a marker file on the shared `powerdns-state` volume, read live by `filter-aaaa.lua`'s recursor `preresolve` hook. (Previously documented here as two separate env vars, `FILTER_AAAA_V4`/`FILTER_AAAA_V6` — neither name appears anywhere in `services/dns/` or `services/ui/src`; see `docs/dns-admin-ui-scope.md` §1b for the real, shipped mechanism.) **Planned change, not yet implemented**: starting with v0.3.0, this filter is intended to default to **on** instead of off (maintainer decision recorded in issue #1068; no dedicated tracking issue exists yet for the code change itself). Current shipped behavior as of this writing is still off-by-default — do not treat this bullet as already-shipped. |
| `DNS_REPLICATION_ROLE` | `native` | Selects whether a DNS container owns local zones normally (`native`), acts as the transfer primary (`primary`), or creates the fixed LAN/reverse zones as PowerDNS secondaries (`secondary`). Shipped production/quickstart/full-setup topology sets `dns-standard` to `primary` and `dns-ssl` to `secondary`. |
| `DNS_XFR_PRIMARY` | — | Required when `DNS_REPLICATION_ROLE=secondary`; host:port endpoint of the PowerDNS primary used for native AXFR/refresh polling. Remote secondaries receive this from the Admin UI registration response. |
| `DNS_XFR_NOTIFY_TARGETS` | — | Comma/space-separated NOTIFY targets for a primary. Shipped local topology notifies `dns-ssl:5300`; remote secondaries can still converge through PowerDNS's refresh polling when they are not listed here. |
| `NATS_BIND_IP` | — | Trusted LAN/VPN interface for optional NATS host binding used by remote secondaries; intentionally required by the secondary NATS override file. Also drives the address the Admin UI hands out during secondary registration -- see below. |
| `NATS_ADVERTISE_URL` | — | Explicit override for the NATS URL the Admin UI hands a remote secondary during registration (issue #866), for setups `NATS_BIND_IP` alone can't express (non-default port, `tls://` scheme, VPN hostname). Always wins over `NATS_BIND_IP` when set. |

**allow-query / allow-recursion:** open to all RFC-1918 + IPv6 ULA by default

### Remote secondary NATS access

The production Compose file keeps NATS on the Docker network by default and does not publish port `4222` on the host. This keeps the event bus closed for installations that do not use remote secondaries.

Enable host binding for remote secondary DNS nodes only when you intentionally
publish NATS to a trusted LAN or VPN interface. `ENABLE_SECONDARY` is not a
runtime switch read by setup, Compose, DNS, or UI code; native zone replication
is controlled by `DNS_REPLICATION_ROLE`/`DNS_XFR_PRIMARY`, while this override
only publishes the NATS registration/event path.

Example:

```sh
NATS_BIND_IP=192.168.1.5 \
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

**nsupdate (RFC 2136):** TSIG-secured dynamic DNS channel into PowerDNS authoritative. Kea DHCP sends lease add/update/delete events through `kea-dhcp-ddns` to `dns-standard` only; PowerDNS accepts those updates only for the LAN and private reverse zones that are explicitly mapped to the shared `DDNS_TSIG_KEY`. `dns-ssl` and registered remote DNS secondaries consume those same zone changes through native PowerDNS AXFR/NOTIFY, so DHCP-driven records have one writer and do not depend on Kea's `dns-servers` failover list behaving like fan-out.

## Kea DHCP

- DHCPv4 + DHCPv6 (dual-stack)
- IP ranges as start–end (no CIDR required)
- Static assignments: MAC → IP, editable via UI
- DDNS → PowerDNS: lease = automatically an A record (in the configured DHCP domain) and a PTR record (in the matching private reverse zone) via TSIG-secured nsupdate (RFC 2136). PTR updates were **not** applied in production until issue #768's fix: Kea's D2 daemon used to send every reverse update's on-wire zone as the literal `in-addr.arpa.`, which had no matching PowerDNS zone (only narrower private-range subzones exist), so PowerDNS rejected every PTR update regardless of octet; `reverse-ddns` now lists one entry per real private reverse zone instead. See [docs/dhcp-modes.md](dhcp-modes.md) for the full detail.
- DDNS enable/disable (issue #1076): whether Kea writes those DNS records is a separate control from whether Kea DHCP is running at all. The `DHCP_DDNS_ENABLED` env var (`config/{dev,prod}/dhcp.env`) sets the first-boot default for Kea's `dhcp-ddns.enable-updates`, and the Admin UI's DHCP page carries an independent "Enable DDNS Updates" toggle that flips `enable-updates` live via the Kea Control API. It defaults **off** for a fresh install (opt-in, matching Kea's own default), while an already-running install keeps whatever value it already has — `migrate_dhcp4_config()` merges the persisted `dhcp-ddns` block over the default, so the toggle's choice (and any existing install's on-state) survives restarts.
- REST API (Kea Control Agent) for Admin UI
- NTP option (`ntp-servers`, DHCPv4 option 42): each subnet's value is a plain operator-editable field (`routes/dhcp.rs`'s `add_subnet`/`update_subnet`), defaulting to the project-wide `DHCP_NTP_SERVERS` setting. When the LanCache-NG-NTP container is enabled AND its separate "auto-set as DHCP NTP server" toggle is on, `routes/dhcp.rs`'s `apply_ntp_lan_ip_to_all_subnets` instead forces every subnet's `ntp-servers` option to that container's LAN address (`STANDARD_IP`), overriding any per-subnet manual value for as long as the toggle stays on; turning it off restores the project-wide default via `restore_default_ntp_on_all_subnets`. The toggle is deliberately independent from the NTP container's own enable/disable switch — enabling the container never auto-populates DHCP by itself.
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

**Health checks:** every persistent-daemon service across `deploy/*/docker-compose.yml`
has a Docker Compose `healthcheck:` block (#1169 closed the last gaps:
`dhcp-proxy`, `ntp`, `netdata`, and `docker-socket-proxy` previously had none
at all), enforced going forward by `scripts/tracked/check-compose-healthchecks.sh`
(CI job `compose-healthchecks` in `build-push.yml`) so a newly added service
can't silently regress this. Two deliberate exceptions: `dhcp-probe` (see its
own row further down), a one-shot helper the Admin UI starts and stops on
demand, and `syslog-logs-permissions`, the one-shot `logs` volume ownership
migration init container documented in the syslog-ng section below -- both
`restart: "no"` and run to completion rather than staying up as a
long-running daemon, so a liveness
healthcheck has no meaningful state to probe. The watchdog binary itself only
*acts* on a subset of the services below -- see the "Auto-restart" scope note
directly below this list before assuming every entry here is watched and
restarted by the watchdog daemon.
- nginx: HTTP request on `/health`
- PowerDNS: DNS query test via `rec_control`
- Kea: REST API ping
- nats: HTTP probe against nats-server's own monitor endpoint (`http_port: 8222` set in the compose-generated boot config, checked via `wget` against `/healthz` -- nats:2-alpine ships BusyBox's wget/nc but no curl, verified empirically)
- ui: HTTP request on `/health` (`services/ui/src/main.rs`'s shallow liveness route, checked via `curl`, present in the image)
- syslog (combined fluent-bit + syslog-ng, when the `logging` profile is active): `services/syslog/healthcheck.sh` checks BOTH processes independently -- `syslog-ng-ctl stats` against the real control socket for syslog-ng, `pgrep -f` against fluent-bit's own bundled-interpreter cmdline for fluent-bit (its `/proc/<pid>/comm` stays `ld-linux-x86-64` for its whole lifetime, confirmed live, since it is invoked through an explicit dynamic-linker interpreter argument rather than the kernel's normal PT_INTERP path -- `pgrep -x fluent-bit` would never match) -- and only reports healthy when both are, additionally writing a structured per-process status file
- dhcp-proxy (dnsmasq): liveness + config-integrity, not a functional DHCP probe (#1169) -- dnsmasq has no REST/control-socket API and this config disables DNS entirely (`port=0`), so a query/response probe like PowerDNS's isn't possible, and synthesizing a real DHCPDISCOVER every interval would inject genuine broadcast LAN traffic as a healthcheck side effect. Checks that PID 1 is still `dnsmasq` (the entrypoint execs it directly, no wrapper shell) and that `dnsmasq --test` still validates the on-disk config
- ntp (chrony): real query/response probe via `chronyc tracking` against chronyd's own command socket (#1169) -- a genuine round-trip, not a bare port-listen check, but deliberately does not require an already-synchronised stratum, since "alive but not yet synced" is a legitimate transient state during `start_period` or an upstream network blip
- netdata: HTTP probe against its own REST API, `GET /api/v1/info` (#1169), matching the check `deploy/full-setup/docker-compose.yml`'s validation stack already used for the same pinned image
- docker-socket-proxy: HTTP probe against the Docker API's own `/_ping` endpoint (#1169), explicitly allowlisted by `scripts/untracked/docker-socket-proxy.sh`'s own `safe_ping` ACL -- proves the HAProxy frontend is actually forwarding to the real Docker socket backend, not just that port 2375 is open

**Auto-restart:** X failed checks → `docker restart <container>`. Scope,
verified against the compiled `services/watchdog` Rust binary (the production
`ENTRYPOINT` since issue #842's ENTRYPOINT swap -- see this file's own
`services/watchdog/Dockerfile` and `deploy/*/docker-compose.yml`): `main()`'s
own `monitored` list covers `proxy`, `dns-standard`, `nats` (always
monitored, not flag-gated), `netdata` (always monitored, added by #842's
2026-08-07 restart-capability decision), and (when `SSL_ENABLED=1`)
`dns-ssl` -- the container names it takes via
`CONTAINER_PROXY`/`CONTAINER_DNS_STANDARD`/`CONTAINER_NATS`/
`CONTAINER_DNS_SSL`/`CONTAINER_NETDATA`. The binary writes this state to a
`status.json` file every `CHECK_INTERVAL` seconds (default 30); see "Status"
below for how the Admin UI renders it. The legacy `services/watchdog/watchdog.sh`
bash implementation this replaced remains in the repository (with its own
bats coverage still passing) as a historical reference and manual-rollback
source, but is no longer copied into the production image or executed --
see #842's own PR for why full removal is a deliberate follow-up, not part
of the ENTRYPOINT swap itself.

These five `CONTAINER_*` variables exist only as a fail-loud consistency
check, not a real renaming mechanism: the binary rejects any value that
does not match the fixed default and exits at startup (issue #849 bug-hunt
finding #5, carried forward from the bash implementation into
`config::resolve_container_names`). Running more than one lancache-ng stack
on the same host is a deliberate non-goal, not an unfinished feature -- see
the fail-loud messages' own comments in `services/watchdog/src/config.rs`
for the full reasoning and the pointer to open a feature request for a
genuine multi-stack-per-host need.

Beyond the five restart-capable services above, the watchdog binary has
alert-only paths that never call `restart()`: it probes `docker-socket-proxy`
every cycle through `/_ping`, monitors `ui` (always), the correct `dhcp`/
`dhcp-proxy` container (per `DHCP_MODE`), `syslog` when `LOGGING_ENABLED` is
truthy, and `ntp` when `NTP_ENABLED` is truthy. Alert-only coverage is
deliberately distinct from restart permission: observing a service through
the inspect allowlist does not grant or imply a Docker restart action for it.

- **`ui`**: has a real Docker healthcheck and is alert-only monitored
  unconditionally. **Corrected 2026-08-19 (issue #1486): `ui` is no longer
  restart-grant-free.** It has its own narrow `safe_ui_restart` acl (`POST
  .../containers/lancache-ui/restart` only, never `start`/`stop`) for the
  Admin UI's own operator-initiated self-restart control
  (`/setup/restart-ui`) -- deliberately restart-only so this path can never
  leave `ui` stopped. This grant is not caller-specific: the socket proxy
  authorizes only the HTTP method/path, not which client sent the request,
  so any client able to reach the proxy (UI, watchdog, or otherwise) could
  invoke this endpoint once it exists -- watchdog's Rust rewrite simply has
  no code that does so, and still never calls `restart_container` for `ui`,
  so `ui` remains outside `check_and_maybe_restart`'s blind
  restart-on-unhealthy loop exactly as before; only an explicit operator
  request through the Admin UI can trigger this restart.
- **`dhcp` (Kea) and `dhcp-proxy` (dnsmasq)**: both have real Docker
  healthchecks and are alert-only monitored (the container matching the
  active `DHCP_MODE`). Deliberately kept start/stop-only in
  `scripts/untracked/docker-socket-proxy.sh` (`safe_dhcp_action`), never given a
  `restart` grant: Kea/dnsmasq's own known-good-config rollback semantics
  and the Admin UI's start/stop-driven lifecycle control are the intended
  recovery path, and a watchdog-triggered blind restart mid-rollback could
  actively conflict with that -- a concern raised explicitly in #842's own
  history and not yet reversed by any later maintainer decision.
- **`netdata`**: promoted to real restart-capability (#842, 2026-08-07
  decision) -- see the `Auto-restart` paragraph above. Its own dedicated
  `safe_netdata_restart` allowlist grant follows the same
  one-acl-per-service pattern `safe_ntp_action`/`safe_dhcp_action` already
  use, rather than widening the shared `safe_service_restart` acl.
- **`ntp` (chrony)**: alert-only monitored when `NTP_ENABLED` is truthy. Its
  own start/stop-only Admin-UI toggle (`safe_ntp_action`) mirrors `dhcp`'s
  shape; no restart grant exists for it either.
- **`syslog` (combined fluent-bit + syslog-ng)**: alert-only monitored when
  `LOGGING_ENABLED` is truthy. Its dual-process healthcheck
  (`services/syslog/healthcheck.sh`) feeds the Docker health state consumed
  here. `syslog` (and `watchdog` itself) must never gain a restart grant or
  become user-disableable via the Admin UI -- an explicit, deliberate
  maintainer decision (#1486's cross-reference on #842), not an
  oversight.

**Alert-only monitoring's own allowlist precondition (issue #842/#849,
2026-08-05):** alert-only health reads require inspect-only Docker API access
through `scripts/untracked/docker-socket-proxy.sh`'s allowlist. That inspection grant is
separate from the `safe_service_restart` allowlist; alert-only monitoring does
not call `restart_container()`, so observing a target never makes it
restart-capable. **Watchdog's alert-only monitoring of `syslog` is gated by
`LOGGING_ENABLED`** (`resolve_bool`, default `false`), matching the Compose
`logging` profile that determines whether the combined syslog+fluent-bit
container exists. The watchdog binary uses this same gate, so a normal logging-enabled installation includes the
container in alert-only monitoring and in `status.json` without requiring the
separate retention opt-in. `SYSLOG_ENABLED` remains an independent, narrower
double opt-in for the storage-budget retention/pruning engine only; it does not
control whether watchdog monitors the running logging service. Direct manual
profile activation must set `LOGGING_ENABLED=1` as documented in the syslog-ng
section below, because bypassing `setup.sh` otherwise leaves the profile and
watchdog's deployment-state input inconsistent.
- **`docker-socket-proxy`**: this is watchdog's own gateway to the Docker
  API. If it is down or hung, watchdog cannot reach any container through
  it -- including this one -- so "restart docker-socket-proxy via
  docker-socket-proxy" cannot work by construction. It now has a real Docker
  healthcheck too (#1169, an HTTP probe against the Docker API's own
  `/_ping`), which makes the problem visible/measurable via `docker inspect`,
  but does not fix the chicken-and-egg restart problem above -- Docker's own
  `restart: always` already covers a hard process crash, which is the only
  failure mode watchdog could conceivably help with here anyway.

  **Alert-only probe (issue #1170 Part 1, added after the above analysis):**
  a *hung-but-not-crashed* docker-socket-proxy (process alive, HAProxy not
  answering) used to be completely invisible -- Docker's own `restart:
  always` only reacts to the process exiting, and nothing else in the stack
  polled it at all. The watchdog binary's `main()` loop now
  hits `docker-socket-proxy`'s own `GET /_ping` endpoint every cycle (already
  permitted by `scripts/untracked/docker-socket-proxy.sh`'s `safe_ping` ACL -- zero new
  privilege) and writes the result into `status.json`'s `services` map like
  any other monitored container, so it renders on the Admin UI dashboard.
  This is deliberately alert-only, driven through `AlertCounter` rather
  than `FailureCounter` --
  the circular-dependency reasoning above still fully applies to *restarting*
  it. Actually self-healing docker-socket-proxy from inside its own
  container (a supervisor that kills its own PID 1 so `restart: always`
  recovers it) is tracked separately as issue #1170 Part 2 and was not
  implemented here; it has open verification questions (reliable
  in-container hang detection, a clean way to trigger PID 1 exit) that this
  alert-only probe does not need to answer.

All of the above still get Docker's own `restart: always`/`restart: "no"`
policy (`deploy/*/docker-compose.yml`), which restarts a container that
*exits*; watchdog's gap is specifically for a container that is still
running but reports unhealthy (hung, wedged) without ever exiting.

**Scheduled purge (cron, daily):** since issue #842 (2026-08-01), this and the
two retention engines below run in `services/watchdog/retention.sh` inside a
dedicated `retention:` Compose service, separate from the health-monitoring
`watchdog` container. `retention-entrypoint.sh` performs the privilege drop
and launches the long-running retention loop with its own restricted mount,
capability, filesystem, and network posture. Keeping destructive file
retention in a separate container prevents a fault or compromise in that logic
from sharing the watchdog's Docker API channel or status-writer process. Every
env-derived target directory (`CACHE_DIR`, `SYSLOG_LOG_ROOT`,
`FLUENT_BIT_SELFLOG_DIR`) is canonicalized via `realpath -m` and checked
against an expected mount-root prefix (`CACHE_DIR_ALLOWED_PREFIX`/
`SYSLOG_LOG_ROOT_ALLOWED_PREFIX`/`FLUENT_BIT_SELFLOG_DIR_ALLOWED_PREFIX`,
defaulting to `/var/cache`/`/var/log`/`/var/lib`) before any `find`/`rm` runs
against it, fail-closed (loud rejection, no deletion, no stamp write) on any
value resolving outside that prefix.
- Remove cache entries older than `CACHE_VALID_DAYS` (`config/prod/watchdog.env`, `find -mtime`) — not `CACHE_VALID_HIT`, which is the unrelated nginx/proxy cache-validity variable in `config/prod/proxy.env` (both happen to default to `365`, which previously masked this doc citing the wrong one)
- Complements nginx `inactive` (which works by access time)
- Syslog retention (opt-in, `SYSLOG_ENABLED=true`): storage-budget pruning under `SYSLOG_LOG_ROOT` — see the syslog-ng section below for the exact age-then-size ordering

**Disk monitoring:**
- `watchdog.sh`'s `disk_info()` computes a yellow (85% full) / red (95% full)
  color and writes it into `status.json` every 30 seconds, monitoring actual
  disk usage, not just nginx `max_size`. Since issue #870, the Admin UI's
  dashboard reads this file (`services/ui/src/watchdog_status.rs`) and
  renders the color in the "Service health" card's "Cache disk" indicator,
  polling `GET /api/watchdog-status` every 10 seconds to stay live -- this
  closes #849 observability finding #3. The dashboard's own cache-usage bar
  (`cache_pct` in `services/ui/src/routes/dashboard.rs`) remains a separate,
  independently computed value (used cache bytes vs. `CACHE_MAX_GB`), not
  this disk-usage color.

**Status:** `watchdog.sh` computes per-service health and disk-usage color
(green/yellow/red) into `status.json` every 30 seconds. Since issue #870,
the Admin UI (`services/ui/src/routes/dashboard.rs`,
`services/ui/src/watchdog_status.rs`, `templates/dashboard.html`) reads and
renders that file as a per-service "traffic light" indicator in the
dashboard's "Service health" card, sharing `status.json` via the
`watchdog-status` named volume (mounted read-only into the `ui` container --
see `deploy/*/docker-compose.yml`'s `ui:` service). A missing or stale
`status.json` (watchdog not running, or crashed) renders as an explicit
"unavailable"/"stale" state rather than a silently frozen last-known color.
Since issue #1170 Part 1, the `services` map also includes an entry for
`docker-socket-proxy` itself (alert-only -- see its dedicated bullet above);
the dashboard renders it through the same generic per-service loop as every
other entry, with no template or route changes needed for it specifically.

### Known benign startup/log messages (issue #849 item 8)

Four log lines observed during real field testing (#1068 item 8) that read
as alarming out of context but are expected, documented behavior once traced
to their actual source -- collected here rather than left as unexplained
"is this a problem?" notes:

- **`Reconciler: published 0 records`** (`services/dns/nats-subscriber/src/main.rs`'s
  `reconciler()`): a periodic (every 60s) full-resync pass that queries
  PowerDNS's `lan.` zone via its REST API and re-publishes every non-SOA/NS
  record over NATS, independent of the event-driven immediate-publish path
  used when a record actually changes. **Expected** whenever the `lan.` zone
  genuinely has no non-SOA/NS records yet -- a fresh install before any
  DHCP-DDNS client has registered, an install with DHCP-DDNS disabled
  entirely (`DHCP_DDNS_ENABLED=false`, the default -- see `config/prod/dhcp.env`),
  or any deployment that legitimately has zero dynamically-registered LAN
  hosts. **Would be a real problem** only if DHCP-DDNS is enabled with active
  leases and this line persists anyway -- that would point at a PowerDNS
  API-connectivity or zone-content issue worth investigating directly (e.g.
  `pdns_control` / the zone's REST endpoint), not this reconciler's own logic.
- **`pdns_server is ready (attempt 2)`** (`services/dns/entrypoint.sh`): after
  starting the PowerDNS authoritative server (`run_auth &`) in the
  background, the entrypoint polls `pdns_control rping` (a real control-socket
  RPC, not a bare network ping -- satisfies AG-VAL-018's "real query/response
  probe" requirement) up to 10 times, 0.5s apart, before starting the
  recursor, so the recursor's own startup never races ahead of the auth
  server's control socket becoming responsive. `attempt 2` simply means the
  auth server took slightly over 0.5s (one extra poll cycle) to finish
  initializing after being forked -- a normal, self-resolving startup
  ordering delay, not a retry-after-failure or a bug. Any single-digit
  attempt count here is unremarkable; only exhausting all 10 attempts (the
  `WARNING: pdns_server did not respond to ping` line) would indicate a real
  problem.
- **NATS connection-refused-then-retry on `lancache-ui` startup**
  (`services/ui/src/main.rs`'s `connect_nats_with_retry()`): the Admin UI's
  `main()` awaits this function -- with a 1s-to-30s capped exponential
  backoff loop that treats "not yet reachable" as its normal steady state --
  *before* binding its own HTTP listener at all. Since Compose starts `ui`
  and `nats` concurrently (no blocking `depends_on: condition:
  service_healthy` between them), a connection-refused during `ui`'s first
  few seconds while `nats-server` is still initializing is an expected,
  self-resolving start-order race, confirmed harmless by design (the same
  reasoning already documented on `services/ui/src/nats_auth_callout.rs`'s
  own unconditional reconnect loop, which treats "connection dropped, retry"
  as its permanent steady state, not just a startup-only condition).
- **netdata: permission-denied on `/host/proc/<pid>/io` for nginx, and a
  missing `/etc/netdata/scripts.d`** -- two distinct findings bundled in the
  original report:
  - The permission-denied error is **already fixed** (PR #1125, `pid: host`
    in `deploy/*/docker-compose.yml`'s `netdata:` service, plus
    `cap_add: SYS_PTRACE` and `security_opt: apparmor:unconfined`): without
    `pid: host`, netdata's own PID namespace is merely a sibling of, not an
    ancestor of, the host's, so the kernel's `ptrace_may_access` check for a
    process outside netdata's own container fails with `Permission denied`
    regardless of `SYS_PTRACE` -- this is netdata's own documented
    requirement for `apps.plugin` to read other containers' `/proc/<pid>`
    entries, not a project-specific workaround.
  - The missing `/etc/netdata/scripts.d` message is **netdata's own,
    harmless, expected behavior for an unused optional collector**, verified
    against netdata's own documentation (AG-VAL-023) rather than assumed:
    `scripts.d.plugin` is a real, separate netdata external plugin that runs
    Nagios-compatible/custom scripts, configured via `scripts.d/nagios.conf`
    under that directory. This project configures no custom Nagios-style
    scripts anywhere, so the directory is legitimately absent, and netdata
    logs this the same way it reports any other optional, unconfigured
    external plugin at startup -- informational, not an error, and not
    something this project's `netdata:` service needs to create or mount. An
    operator who wants to silence the message specifically (not required for
    correct operation) can disable `scripts.d.plugin` in netdata's own
    `netdata.conf` `[plugins]` section.

## syslog-ng

Central log receiver for the stack (#453), opt-in via `docker compose --profile logging up -d` in `prod` and `quickstart` alike. **Also set `LOGGING_ENABLED=1` in the deployment's `.env`** when activating this way directly (rather than through `setup.sh`, which sets both together): `LOGGING_ENABLED` is the flag `services/watchdog/watchdog.sh` reads to decide whether the syslog+fluent-bit container is part of this stack for alert-only health monitoring at all -- starting the `logging` profile without it still runs the container correctly, but watchdog silently omits it from monitoring and the Admin UI dashboard's service list, since a `LOGGING_ENABLED`-unset stack is indistinguishable from one that never opted into logging at all. Since the syslog+fluent-bit consolidation PR (2026-08), `syslog-ng` and `fluent-bit` (the `syslog` service) run as two supervised processes inside ONE container (`services/syslog/`) instead of two separate ones -- a deliberate maintainer decision to accept crash-coupling and a single Docker HEALTHCHECK slot (mitigated by the real dual-process check described below) in exchange for one image to build/scan/patch instead of two. `fluent-bit` tails every wired service's log file(s) (see the matrix below) and forwards each one to `syslog-ng` over `127.0.0.1:6601` (RFC 5424, plain LF framing, `network()` source with `flags(syslog-protocol)`) -- a loopback connection within the shared container network namespace, not a Compose service-to-service hop anymore; the proxy/nginx access log additionally gets a second, local plain-text copy (used by Netdata's `web_log` job). `syslog-ng` writes received logs per-source, per-day under `/var/log/lancache-syslog-ng/<host>/<YYYYMMDD>.log`. Port 6601 (not the original 601) is deliberate: 601 is a privileged port (confirmed live -- `/proc/sys/net/ipv4/ip_unprivileged_port_start` defaults to 1024 on a real runner) and this container's `syslog-ng` runs as a non-root uid with no `CAP_NET_BIND_SERVICE` grant; 601 was never published to the host or documented as an external contract, so the renumbering has no external impact.

**Currently implemented:**
- Size-bounded rotation: an active log file is rotated once it exceeds `SYSLOG_MAX_FILE_MB` (default 100), then `syslog-ng` is signaled (`SIGHUP`, same-uid so no added capability is needed) to reopen the (recreated) destination file. The rotation loop compares real file byte sizes via `stat -c%s`, not `find -size +100M` (GNU-only syntax that silently never matches on Alpine's `find`, confirmed live -- a real portability bug the consolidation PR's own POC caught and fixed).
- Compression: rotated files are compressed with `zstd -T0` at `SYSLOG_COMPRESSION_LEVEL` (default 19); falls back to `gzip` if `zstd` cannot be installed at container start (e.g. no network egress).
- Config for both fluent-bit and syslog-ng is a static file baked into the combined image at build time (`services/syslog/fluent-bit.conf`, `services/syslog/syslog-ng.conf`) -- nothing in either varies per deployment, so unlike the previous CLI-flag/inline-heredoc approach there is nothing to generate at container start.
- Every service in the matrix below is wired end to end except `dhcp-probe` (one-shot diagnostic, see its row for why that's a deliberate N/A, not a gap).
- Per-service wiring mechanism varies by what the underlying daemon actually supports (#633): a native dual stdout+file option where one exists (Kea's `output-options` array), a `tee` of the daemon's own stdout into a file where no such option exists (PowerDNS has no file-log directive on Linux at all; nats-server and dnsmasq each support only one log destination at a time, not both simultaneously), or a second application-level logging layer (the Admin UI's `tracing-subscriber` setup). Every one of these choices is a documented, deliberate trade-off recorded in the matrix's Notes column, not an oversight.
- Storage-budget retention: `services/watchdog/retention.sh`'s `maybe_prune_syslog()` (since #842; opt-in via `SYSLOG_ENABLED=true`, `--profile logging`) enforces an overall storage budget on top of syslog-ng's own fixed-threshold rotation above. Age-based deletion runs first (`SYSLOG_RETENTION_DAYS`, default 30); if the tree under `SYSLOG_LOG_ROOT` is still over `SYSLOG_MAX_GB` (default 10) afterward, the oldest remaining files are deleted next — regardless of age — until back under budget. Size budget takes priority over the retention-days floor. Rate-limited via its own stamp file (once per day), same pattern as the cache purge above; `SYSLOG_LOG_ROOT` is validated (`realpath -m` + expected-prefix check) before any scan, same as `CACHE_DIR`.
- Fluent-bit self-log rotation (#1236): `services/watchdog/retention.sh`'s `maybe_rotate_fluent_bit_selflog()` (since #842) bounds `/data/fluent-bit.log` (the combined container's own `fluent-bit` operational log, see the logging matrix row below) on the `syslog-data` volume, which neither of the two mechanisms above touches.
- **Least-privilege capability posture** (new in the consolidation PR): the combined container runs entirely as fixed non-root uid 10001 (not root, unlike the previous two separate images), with exactly one added capability -- `DAC_READ_SEARCH` -- so fluent-bit can read today's root:root 0640 producer logs it doesn't own. Verified live to be sufficient for fluent-bit's read-only access pattern, narrower than a `DAC_OVERRIDE` grant would be. The fluent-bit interpreter binary carries a matching `setcap` file capability baked into the image; running this image without the matching `cap_add: [DAC_READ_SEARCH]` fails closed at exec, not silently. Producer logs themselves are not yet made group-readable for a fully-zero-capability posture -- tracked as a separate, real follow-up (see this PR's own body).
- **Existing `logs` volume ownership migration**: Docker copies an image path's uid/gid only when it initializes a new named volume; it does not update an already-populated volume after an image upgrade. The `syslog-logs-permissions` one-shot Compose service therefore runs before `syslog` in both production and quickstart, recursively assigns the shared `/var/log/lancache` tree to uid/gid 10001, and must complete successfully before the non-root collector starts. The initializer has no network, a read-only root filesystem, and only `CAP_CHOWN`; repeated starts are intentionally idempotent. This keeps existing proxy-log copies writable without widening the long-running syslog container's capability set.
- **Silent-data-loss detection** (new in the consolidation PR): a periodic detector compares syslog-ng's own "processed" stats counter (`syslog-ng-ctl stats`) against real bytes landing on disk under `SYSLOG_NG_LOG_ROOT`, alerting (and surfacing via a structured healthcheck status field) if syslog-ng believes it delivered messages that never actually reached disk -- e.g. a bind-mounted log-root directory left root-owned instead of chowned to uid 10001. `setup.sh` pre-creates and chowns this directory on fresh install specifically to avoid the condition; this detector is the defense-in-depth backstop for an installation that predates that fix or has its permissions changed later.
- **Real dual-process healthcheck**: `services/syslog/healthcheck.sh` checks fluent-bit AND syslog-ng independently (not just "is the container running") and only reports healthy when both are, writing a structured per-process status file (including the data-loss alert flag above) for a future Admin UI/watchdog integration -- the granularity fix for the two-container era's single "one process, one Docker HEALTHCHECK slot" limitation.
- `scripts/tracked/check-logging-matrix.sh`, run in CI's `validate-compose` job, fails if a Compose service has no row in the logging matrix table below, or if a row names a service that no longer exists.
- Admin UI log reading from the central path: `services/ui/src/syslog_client.rs` (opt-in via `SYSLOG_ENABLED=true`, same 4-variable contract watchdog's retention engine uses) reads `/logs` and a dashboard tile from `SYSLOG_LOG_ROOT` directly, transparently decompressing rotated `.zst`/`.gz` files, instead of the `STANDARD_LOG`/`SSL_LOG` direct-nginx-read path. Disabled installs keep the old direct-nginx-read behavior unchanged.

**Not implemented yet:**
- Per-service log level configuration in the Admin UI.
- Configurable remote forwarding destination (IP/port/protocol) from the Admin UI.
- Fully zero-added-capability posture for the combined container: needs every producer log this project controls to be group-readable by gid 10001, a real, separate cross-service change tracked in issue #1427.

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
| retention | Via fluent-bit → syslog-ng | #842 Teil 2: `retention.sh`'s own dedicated sidecar container (separate from `watchdog` above, see docs above this table's "Scheduled purge" section). `retention-entrypoint.sh` tees its stdout into `/var/log/lancache-watchdog/retention.log` on the same `watchdog-logs` volume `watchdog` above already writes `watchdog.log` to -- fluent-bit already tails that whole directory, so this file is picked up automatically, no separate fluent-bit input needed. |
| nats | Via fluent-bit → syslog-ng | Like dnsmasq, nats-server logs to exactly one destination — no dual-output mode exists — so `log_file: /var/log/lancache-nats/nats.log` (set both in the compose-generated boot config and, authoritatively, by the Admin UI's `update_nats_conf`) means `docker logs` goes quiet on this container while the `logging` profile is active; same accepted trade-off as dhcp-proxy |
| netdata | Via fluent-bit → syslog-ng | The pinned netdata image ships its default `/var/log/netdata/*.log` paths as symlinks to `/dev/stdout`/`/dev/stderr` (nothing for fluent-bit to tail), so — same "no local repo checkout to bind-mount a config file from" constraint as `syslog`/`syslog-ng` below — an inline `entrypoint` override writes a `netdata.conf` that redirects the `[logs]` `collector`/`daemon`/`health` sources to real files at `/var/log/netdata/*.file.log`, then `exec`s the image's own `/usr/sbin/run.sh`; that path is mounted onto the `netdata-logs` volume, which fluent-bit tails read-only. `access`/`debug` stay on their stdout defaults (high-rate/empty). netdata v2 has no separate `error` log key — error-level events land in `daemon`/`collector` |
| dhcp-probe | Not applicable | One-shot diagnostic helper (`restart: "no"`), started and stopped on demand by the Admin UI for a single probe run — no persistent process or log stream to route |
| syslog-logs-permissions | Not applicable | One-shot `logs` volume ownership migration init container (`restart: "no"`, see the "Existing `logs` volume ownership migration" bullet above), runs `chown` to completion and exits — no persistent process or log stream to route |
| ntp | Not yet wired (local container stdout + `/var/log/chrony` file only) | chronyd's own `log` directive (see `services/ntp/chrony.conf`) writes `tracking`/`measurements`/`statistics` to `/var/log/chrony` alongside its normal stdout, but the `ntp-logs` volume is not yet tailed by fluent-bit into the central pipeline — a known, deliberately deferred follow-up, same class as the two "Not implemented yet" items above |
| fluent-bit + syslog-ng (`syslog`, combined container since the consolidation PR) | Via fluent-bit → syslog-ng (self-log, #864) | `Log_File /data/fluent-bit.log` (static `services/syslog/fluent-bit.conf`, not a CLI flag since the consolidation) redirects fluent-bit's own operational log (startup, tail-input errors, forwarding failures) into a file instead of `docker logs`, which a dedicated tail input (`tag=fluent-bit.selflog`) re-ingests and forwards — same single-destination trade-off already documented for dnsmasq/nats-server (`docker logs` on this container goes quiet while the `logging` profile is active). **Fixed (#1236)**: during a real syslog-ng outage, fluent-bit's own retry logging (roughly one line/second at the default 5s flush interval) used to feed back into the very tail input forwarding it, growing this file unboundedly for the outage's duration — neither syslog-ng's own rotation nor watchdog's `maybe_prune_syslog` covered it (both operate on the syslog-ng output tree, not this container's own `/data` volume). `services/watchdog/retention.sh`'s `maybe_rotate_fluent_bit_selflog()` (moved out of `watchdog.sh` by #842) now bounds it directly (see the "syslog-ng" section above for the full mechanism); see `services/syslog/entrypoint.sh`'s own comment for the in-place detail. syslog-ng itself has no self-log forwarding of its own (would be redundant, since it lives in the same container and its own stdout is already `docker logs` on this same container). A NEW pipeline stage since the consolidation: the silent-data-loss detector's own alert log (`data-loss-detector.syslog` tag) IS forwarded through fluent-bit, surfacing a detected silent-write-failure condition through the same Admin UI `/logs` view as every other source (with one caveat: if syslog-ng's own destination write is what's actually broken, the alert message itself can be lost the same way -- the structured healthcheck status file's `data_loss_alert_active` field is the cause-independent channel for that specific case). |
| docker-socket-proxy | Not applicable | Third-party pinned image (`tecnativa/docker-socket-proxy`); only Docker's own stdout logging driver applies, there is no application log stream of our own to forward |

## Cache Warming

**Corrected 2026-08-05 (issue #1391 doc-sweep audit): this section previously described Cache
Warming in the present tense as an already-shipped feature, contradicting this document's own
services table above ("Cache Warmer | not implemented ... Design-only, not shipped: no
`services/` code, no Compose service, nothing runnable exists yet under this name"), which is
the accurate statement — confirmed directly against the real tree (`services/warmer/` does not
exist; no `warmer`/`steamcmd` service in any `deploy/*/docker-compose.yml`).** The design below
describes the current *plan*, not a shipped capability — see
[docs/design-steam-prefill.md](design-steam-prefill.md) (issue #816, overlapping #871) for the
authoritative, up-to-date design discussion and its open maintainer decisions before relying on
any detail here.

**Planned workflow** (not yet implemented — design-only):
1. User enters Steam app ID
2. `steamcmd` fetches depot manifest (anonymous for F2P, optional with account for paid games)
3. Chunk URLs fetched through local proxy → cached
4. Progress displayed live in Admin UI (total chunks / completed / MB/s)

**Steam account:** planned to be optional via env var (`STEAM_USER`, `STEAM_PASS`) — never in repo, never in image.

**Tracking:** planned: which app IDs were warmed + which CDN URLs belong to them → basis for targeted purging.

Epic / GOG: not planned to be supported.

## Cache Retention & Cleanup

**Two automatic mechanisms, plus one Admin UI operator control:**

| Mechanism | Trigger | Basis |
|---|---|---|
| nginx `inactive` | automatic, continuous | not accessed since `CACHE_INACTIVE` |
| Watchdog purge cron | daily automatic | file older than `CACHE_VALID_DAYS` (`services/watchdog/retention.sh`'s `maybe_purge()`, since #842 -- a separate process from the health-check daemon) |
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

**Admin UI cache resize (`services/ui/src/routes/cache.rs`, issue #1069 part
3):** the dashboard shows current usage, current `CACHE_MAX_SIZE`, and lets an
operator submit a new whole-GB size. The request is re-validated against real
free disk space at `CACHE_DIR` with the same buffer-scaled safety check as
`setup.sh`'s prompt (reject unless
`available_free_space_at(CACHE_DIR) - buffer(cache_gb) >= cache_gb`; on
rejection, the largest currently-passing value is suggested). A validated
request does not take effect synchronously: `CACHE_MAX_SIZE` reaches the
proxy container via the real deployment `.env`
(`deploy/quickstart/docker-compose.yml`'s
`environment: - CACHE_MAX_SIZE=${CACHE_MAX_SIZE}`), which this container has
no filesystem access to, and the Admin UI's Docker access deliberately has no
exec capability to send nginx a reload signal even if it did (see
`services/ui/src/docker_client.rs`'s header comment). The request is instead
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
`services/proxy/entrypoint.sh` (renders `nginx.conf` from its template once,
before `exec nginx`, with no signal handler to re-render and reload) that
makes a full recreate the only mechanism available today, not a limitation of
nginx itself. Scope boundary: this convergence path writes the
`setup.sh`-managed runtime `.env` unconditionally (it does not check which
compose style is in use), which only `deploy/quickstart/docker-compose.yml`
(what `setup.sh` actually installs at `/opt/lancache-ng`) reads
`CACHE_MAX_SIZE` from directly — a manual `deploy/prod` checkout's proxy
service instead reads `config/prod/proxy.env` via `env_file:`, a file this
convergence tick never touches. This makes an Admin UI resize on a
`deploy/prod` install worse than an inert no-op: `.env`'s `CACHE_MAX_GB` still
gets updated, so the dashboard's own "pending" banner clears and its usage bar
starts showing the new target size once `docker compose up -d` recreates the
`ui` container — while the real `proxy` container keeps enforcing the
untouched old `CACHE_MAX_SIZE` from `config/prod/proxy.env`. The dashboard
would misleadingly display a resize that never actually reached nginx on that
deployment style. Not fixed as part of this capability (would require also
writing `config/prod/proxy.env` from the same convergence tick, a separate,
`deploy/prod`-specific change).

**Not yet implemented:** a manual "clear cache now" / purge-by-age / purge-
by-access / pin-app-ID surface. `services/watchdog/watchdog.sh`'s
`maybe_purge()` is the only automatic purge path beyond nginx's own
`inactive` eviction; there is no route or template anywhere in
`services/ui/src/routes` that clears, previews, or selectively deletes cache
entries. See issue #1069's own feasibility notes for why an out-of-cycle
cache-manager sweep needs a bespoke script (nginx has no external signal for
one) rather than being a given.

## Monitoring (Admin UI)

- Netdata integrated (proxy via `/api/netdata`)
- Statistics: CPU, RAM, network MB/s (realtime + history), disk I/O
- Dashboard: cache fill level, hit/miss rate, active connections
- Watchdog per-service traffic light bar: one indicator per service
  (green/yellow/red) plus a cache-disk usage indicator, persistently visible
  in the dashboard's "Service health" card, live-polled every 10 seconds
  (issue #870; see the "Status" note under Watchdog above)
- Netdata alarm forwarding (bug hunt #849, `docs/bug-hunt/observability.md`
  finding #3): the `netdata` container's own `health.d` alarms (disk usage,
  CPU, memory, ...) previously had no notification integration or Admin UI
  surface of their own. The `netdata:` service's compose command block now
  configures Netdata's `custom_sender()` alarm-notify mechanism to POST each
  alarm event to the Admin UI's `POST /api/netdata-alarms`
  (`services/ui/src/routes/netdata_alarms.rs`), gated by a shared
  `NETDATA_ALARM_TOKEN` (issue #858 shared-secret pattern, same as
  `PDNS_API_KEY`). The dashboard's "Netdata alarms" card
  (`services/ui/src/netdata_alarms.rs`) shows the most recent alarms
  server-rendered, not live-polled — an alarm is a discrete event, not a
  continuously-changing gauge. This forwards alarm *events* only; Netdata's
  full metrics dashboard (port 19999) remains unpublished, so deep
  investigation of a forwarded alarm still needs direct Netdata access (see
  `docs/threat-model.md`'s T9 for the residual-risk framing).

## Admin UI

Runs on its own Axum webserver (port 8080) — independent from nginx. If nginx is down, the UI is still reachable and shows the error.

- Two modes: **Beginner** (guided, no jargon) / **Expert** (technical direct)
- DNS: create zones, host entries, PTR checkbox for LAN IPs
- Kea: lease overview, create/edit static assignments
- Cache: start warming, progress, purging, retention + slice/size settings
- Logs: filtered by host/service (implemented against the central syslog-ng path, #848); level-selectable filtering is not yet implemented -- raised during #1343's scope discussion and left an explicit open decision there rather than built ad hoc, since fluent-bit's pipeline forwards every tailed line verbatim today with no severity filter anywhere, and nginx's `access.log` in particular has no severity field to filter on at all
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
