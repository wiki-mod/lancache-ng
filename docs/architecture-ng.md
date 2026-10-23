# LanCache-NG Architecture

## Services

Every service below (proxy, PowerDNS, Kea DHCP, dnsmasq DHCP, Watchdog, Admin UI)
already existed before this project's first version tag (`v0.1.0`, cut
2026-07-06) was created, so a per-service "included since vX.Y.Z" column
would not actually differentiate anything -- every real row would read the
same "v0.1.0" regardless of which service is genuinely older or newer
(verified against each service directory's first commit in git history, not
assumed). The one row below that a version field genuinely would
differentiate is CacheHamster (the Cache-Prefill feature's service, issue
#871), which is called out explicitly instead: it is not shipped in any
tagged version, current or planned, and does not yet have real Steam
depot-fetch capability.

| Service | Default | Replaces | Notes |
|---|---|---|---|
| nginx (proxy) | on | — | Mainline from nginx.org, Alpine base (issue #815) |
| PowerDNS | on | dnsmasq | Authoritative + Recursor for DNS spoofing & recursion |
| Kea DHCP / DHCP modes | off | — | Configurable four-state: `disabled` / `kea` / `dnsmasq-proxy` / `dnsmasq-relay` (#844); requires PowerDNS (DDNS via nsupdate) in `kea` mode. Kea and both dnsmasq modes run in the one `dhcp` container; its supervisor starts Kea or dnsmasq by `DHCP_MODE` (`disabled` in the SOT): `dnsmasq-proxy` injects PXE options alongside an existing server, `dnsmasq-relay` forwards DHCP to an upstream server on another segment. See [docs/dhcp-modes.md](dhcp-modes.md). |
| NTP (chronyd inside `services`) | off (`NTP_ENABLED`) | — | The supervisor runs chronyd while `NTP_ENABLED` is true and the desired state of `ntp` is not `stopped` (see the Watchdog section). chrony-based NTP server, disciplined against public NTP servers, serving LAN clients on UDP/123; optional "auto-set as DHCP NTP server" toggle pushes its LAN address into Kea's `ntp-servers` option. See the "Kea DHCP" section below. |
| Watchdog (inside `services`) | on | — | Supervisor of every supervised image, restart of an unhealthy container, retention; see the Watchdog section |
| syslog-ng (inside `services`) | on; per-service switches `LOGGING_PROXY_ENABLED`, `LOGGING_DNS_ENABLED`, `LOGGING_DHCP_ENABLED`, `LOGGING_UI_ENABLED` (Admin UI `/logs`) | — | Central log receiver; every container logs to it through the Docker syslog driver — see the syslog-ng section's logging matrix below |
| Admin UI | on | — | Axum/Rust, Tera, Tailwind, separate port |
| CacheHamster (Cache-Prefill) | off (no supervised program) | — | **Built, functionally still a scaffold**: `services/cachehamster` (issue #871) is built into the `services` image as `lancache-cachehamster`; no supervisor starts it, an operator runs it by hand (`docker compose exec services lancache-cachehamster ...`). No real Steam depot-fetch capability yet -- credential-store + stream-fetch primitives only. Mechanism decided: stream-and-discard prefill, not SteamCMD; its own crate (not a `services/ui` module). See [docs/design-steam-prefill.md](design-steam-prefill.md) (issue #816, issue #871) for the current design plan and its one remaining open decision (credential strategy). Do not treat this row as a runnable feature until Steam control-plane/depot integration lands. |

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
| `ROOT_ZONE_MIRROR` | SOT runtime default in `.github/yaml/build-manifest.yml`; the supervisor's `recursor` render (`services/watchdog/src/main.rs`) turns the mirror on unless the value parses as false | Root zone mirror (AXFR from root servers). Was previously documented here as `ENABLE_ROOT_MIRROR` — that name does not exist in code; `docs/dns-admin-ui-scope.md` already used the correct name. |
| Global AAAA-response filter | off by default | Suppresses all AAAA answers for every client, regardless of address family. Not an env var/restart-time setting: toggled live via the Admin UI (`POST /domains/aaaa-filter`), which writes/removes a marker file on the shared `powerdns-state` volume, read live by `filter-aaaa.lua`'s recursor `preresolve` hook. (Previously documented here as two separate env vars, `FILTER_AAAA_V4`/`FILTER_AAAA_V6` — neither name appears anywhere in `services/dns/` or `services/ui/src`; see `docs/dns-admin-ui-scope.md` §1b for the real, shipped mechanism.) **Planned change, not yet implemented**: starting with v0.3.0, this filter is intended to default to **on** instead of off (maintainer decision recorded in issue #1068; no dedicated tracking issue exists yet for the code change itself). Current shipped behavior as of this writing is still off-by-default — do not treat this bullet as already-shipped. |
| `DNS_REPLICATION_ROLE` | `native` | Selects whether a DNS container owns local zones normally (`native`), acts as the transfer primary (`primary`), or creates the fixed LAN/reverse zones as PowerDNS secondaries (`secondary`). Shipped production and full-setup topology sets `dns` to `primary`; remote secondaries (`setup.sh secondary`) use `secondary`. |
| `DNS_XFR_PRIMARY` | — | Required when `DNS_REPLICATION_ROLE=secondary`; host:port endpoint of the PowerDNS primary used for native AXFR/refresh polling. Remote secondaries receive this from the Admin UI registration response. |
| `DNS_XFR_NOTIFY_TARGETS` | — | Comma/space-separated NOTIFY targets for a primary. Shipped local topology notifies no local target; remote secondaries can still converge through PowerDNS's refresh polling when they are not listed here. |
| `PDNS_SOA_REFRESH` | `30` (`build-manifest.yml` `runtime.defaults`) | Primary SOA `refresh` (seconds), seeded into `default-soa-content` and rewritten onto every zone by `run_soa_maintainer`. Short by design (issue #1095): it is the only convergence guarantee for a secondary that missed a single-shot UDP NOTIFY, replacing the old `10800`s (3h) drift window. |
| `PDNS_SOA_RETRY` | `10` (`runtime.defaults`) | Primary SOA `retry` (seconds); must be `< PDNS_SOA_REFRESH` (RFC 1912). |
| `PDNS_SOA_RESYNC_INTERVAL` | `3600` (`runtime.defaults`) | Primary-only cadence (seconds) at which `run_soa_maintainer` re-anchors the `YYMMDDxxx` date serial at day rollover and bumps + NOTIFYs as a generic force-resync safety net (issue #1095). |
| `NATS_BIND_IP` | — | Trusted LAN/VPN interface for optional NATS host binding used by remote secondaries; the `dns` service publishes NATS on it (loopback when unset). Also drives the address the Admin UI hands out during secondary registration -- see below. |
| `NATS_ADVERTISE_URL` | — | Explicit override for the NATS URL the Admin UI hands a remote secondary during registration (issue #866), for setups `NATS_BIND_IP` alone can't express (non-default port, `tls://` scheme, VPN hostname). Always wins over `NATS_BIND_IP` when set. |

**allow-query / allow-recursion:** open to all RFC-1918 + IPv6 ULA by default

### Remote secondary NATS access

The production Compose file publishes the NATS port only on the SOT `LOOPBACK_BIND_IP` by default. This keeps the event bus closed for installations that do not use remote secondaries.

Enable host binding for remote secondary DNS nodes only when you intentionally
publish NATS to a trusted LAN or VPN interface. `ENABLE_SECONDARY` is not a
runtime switch read by setup, Compose, DNS, or UI code; native zone replication
is controlled by `DNS_REPLICATION_ROLE`/`DNS_XFR_PRIMARY`, while `NATS_BIND_IP`
only publishes the NATS registration/event path.

Example:

```sh
NATS_BIND_IP=192.168.1.5 \
  docker compose --env-file deploy/prod/.env.local -f deploy/prod/docker-compose.yml up -d dns
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
all. See `services/ui/src/main.rs`'s `advertised_nats_url()` and its unit
tests for the exact precedence and rejection rules.

Note that setting `NATS_BIND_IP`/`NATS_ADVERTISE_URL` on the primary and
restarting only the `ui` container is not, on its own, enough to make a
registration attempt actually succeed end-to-end: the `dns` service, which
runs NATS, must be recreated with `NATS_BIND_IP` set to publish the NATS port
on that address in the first place. `ui` only computes what to *advertise*;
it does not control what `dns` publishes.

**nsupdate (RFC 2136):** TSIG-secured dynamic DNS channel into PowerDNS authoritative. Kea DHCP sends lease add/update/delete events through `kea-dhcp-ddns` to `dns` only; PowerDNS accepts those updates only for the LAN and private reverse zones that are explicitly mapped to the shared `DDNS_TSIG_KEY`. Registered remote DNS secondaries consume those same zone changes through native PowerDNS AXFR/NOTIFY, so DHCP-driven records have one writer and do not depend on Kea's `dns-servers` failover list behaving like fan-out.

## Kea DHCP

- DHCPv4 + DHCPv6 (dual-stack)
- IP ranges as start–end (no CIDR required)
- Static assignments: MAC → IP, editable via UI
- DDNS → PowerDNS: lease = automatically an A record (in the configured DHCP domain) and a PTR record (in the matching private reverse zone) via TSIG-secured nsupdate (RFC 2136). PTR updates were **not** applied in production until issue #768's fix: Kea's D2 daemon used to send every reverse update's on-wire zone as the literal `in-addr.arpa.`, which had no matching PowerDNS zone (only narrower private-range subzones exist), so PowerDNS rejected every PTR update regardless of octet; `reverse-ddns` now lists one entry per real private reverse zone instead. See [docs/dhcp-modes.md](dhcp-modes.md) for the full detail.
- DDNS enable/disable (issue #1076): whether Kea writes those DNS records is a separate control from whether Kea DHCP is running at all. The `DHCP_DDNS_ENABLED` env var (SOT runtime default in `.github/yaml/build-manifest.yml`) sets the first-boot default for Kea's `dhcp-ddns.enable-updates`, and the Admin UI's DHCP page carries an independent "Enable DDNS Updates" toggle that flips `enable-updates` live via the Kea Control API. It defaults **off** for a fresh install (opt-in, matching Kea's own default), while an already-running install keeps whatever value it already has — the supervisor's `kea_dhcp4_own` (`services/watchdog/src/main.rs`) sets the `dhcp-ddns` block only when the saved `kea-dhcp4.conf` has none, so the toggle's choice (and any existing install's on-state) survives restarts.
- REST API (Kea Control Agent) for Admin UI
- NTP option (`ntp-servers`, DHCPv4 option 42): each subnet's value is a plain operator-editable field (`main.rs`'s `add_subnet`/`update_subnet`), defaulting to the project-wide `DHCP_NTP_SERVERS` setting. When the LanCache-NG-NTP container is enabled AND its separate "auto-set as DHCP NTP server" toggle is on, `main.rs`'s `apply_ntp_lan_ip_to_all_subnets` instead forces every subnet's `ntp-servers` option to that container's LAN address (`IP_HTTP`), overriding any per-subnet manual value for as long as the toggle stays on; turning it off restores the project-wide default via `restore_default_ntp_on_all_subnets`. The toggle is deliberately independent from the NTP container's own enable/disable switch — enabling the container never auto-populates DHCP by itself.
- **Multi-threading is explicitly disabled** (`"multi-threading": {"enable-multi-threading": false}`, set by the supervisor's `kea_dhcp4_own` in `services/watchdog/src/main.rs` on every Kea start when the saved `kea-dhcp4.conf` has no `multi-threading` key). This is a deliberate override, not an oversight: Kea has shipped multi-threaded packet processing enabled by default since 2.4.0, but that feature targets high-query-rate ISP/carrier deployments processing thousands of leases per second across many CPU cores -- this project's DHCP server serves one LAN/lab-scale subnet, so the added concurrency surface (interacting with the `lease_cmds` hook, the DDNS-forwarding path, and the Admin UI's config-write/rollback machinery, none of which were designed against concurrent packet handlers) buys no real benefit here. No project history (commit messages, linked PRs) documents an incompatibility that was actually hit; this is a preventive simplicity choice, re-stated here so it isn't mistaken for an unexamined default. An operator with a genuinely large multi-subnet deployment can re-enable it (Kea's own default), but should first re-verify it against the hooks/DDNS paths above.

## Admin UI security headers

The Admin UI sends security response headers by default. The policy is compatible with the current self-hosted frontend assets and does not require external CDN JavaScript. Operators can tune the behavior with environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `UI_SECURITY_HEADERS` | `true` | Set to `false`, `0`, `off`, or `no` to disable the Admin UI security header middleware. |
| `UI_HSTS_MODE` | `auto` | Controls `Strict-Transport-Security`: `auto` only sends HSTS when `X-Forwarded-Proto: https` is present, `always` sends it on every response, and `never` disables it. |

Keep `UI_HSTS_MODE=auto` for direct LAN HTTP access or TLS-terminating reverse proxies that also leave `http://<host>:8080` reachable. Use `always` only when the UI hostname is intended to be HTTPS-only.

## Watchdog

`lancache-watchdog` (`services/watchdog/src/main.rs`) is the entry point of
the four supervised images: `services`, `proxy`, `dns` and `dhcp`. The `ui`
image has no supervisor. Every value below is an environment key that the
SOT (`.github/yaml/build-manifest.yml`) bakes in; the binary has no defaults.

**Supervisor.** `lancache-watchdog supervise` (the default) reads
`LANCACHE_PROCESSES`, which the image build bakes from the SOT `processes:`
list of that image, and keeps each program running:

| Image | Programs |
| --- | --- |
| `services` | `watch`, `retention`, `syslog-ng`, `chronyd`, `netdata` |
| `proxy` | `nginx` |
| `dns` | `pdns`, `dns-http`, `dns-https`, `nats-server`, `nats-subscriber`, `soa` |
| `dhcp` | `kea-dhcp4`, `kea-ctrl-agent`, `kea-dhcp-ddns`, `dnsmasq`, `dhcp-probe` |

Every `SUPERVISE_TICK` seconds the supervisor:
- starts a wanted program that is not running, after its backoff
  (`RETRY_BACKOFF_START` doubling up to its maximum; a run of
  `SUPERVISE_BACKOFF_RESET` seconds resets it);
- stops a running program that is no longer wanted (TERM, then KILL after
  `SUPERVISE_STOP_GRACE`);
- restarts a running program whose watched input file changed (for example
  the Admin UI settings file, `cdn-domains.txt` or the NATS config);
- writes `supervise.json` into `SUPERVISE_RUN_DIR`.

A program is wanted (`Kind::wanted`) by these rules:
- `kea-dhcp4`, `kea-ctrl-agent` and `kea-dhcp-ddns` only in the Kea DHCP
  mode, `dnsmasq` only in a dnsmasq mode, and both only while the desired
  state of `dhcp` is not `stopped`;
- `chronyd` only while `NTP_ENABLED` is true and the desired state of `ntp`
  is not `stopped`;
- `nats-server` and `soa` not on a DNS secondary;
- `dns-https` only when `IP_HTTPS` is set;
- every other program always.

The desired state is `DESIRED_STATE_FILE`. The Admin UI writes it; the
supervisor reads it on every tick. No Docker call is involved.

**Healthcheck.** Compose runs `lancache-watchdog healthcheck` in the four
supervised containers (`x-watchdog-healthcheck` in
`deploy/prod/docker-compose.yml`). It fails when:
- `supervise.json` is older than `SUPERVISE_STATUS_MAX_AGE` seconds;
- a wanted program is not running;
- a running `nats-subscriber` or `kea-ctrl-agent` does not accept a TCP
  connection on its port, or a running `kea-dhcp4` does not accept one on
  its control socket;
- in the `proxy` container, nginx does not answer its health URL, and with
  `HTTPS_ENABLED` also its HTTPS health URL checked against the stack CA.

The `ui` container runs `lancache-ui healthcheck`. `ci.sh check
compose-healthchecks` (part of `ci.sh check all`) fails for a compose service
without a healthcheck, except a service named in the SOT field
`validation.healthcheck_exempt`; the SOT has no such field today.

**Watch (restart of an unhealthy container).** The `watch` task in the
`services` container is the only Docker API client (`DockerApi` in
`services/common/shared.rs`). It reaches the socket `DOCKER_SOCKET`, mounted
read-write with no socket proxy (see `SECURITY.md` section 3). Every
`CHECK_INTERVAL` seconds it:
- lists the containers of its own compose project (the project label of its
  own container);
- inspects each container and counts `unhealthy` readings in a row;
- restarts the container after `RESTART_AFTER` readings in a row
  (`DOCKER_RESTART_GRACE`, `DOCKER_RESTART_TIMEOUT`); `starting`, no health,
  unreachable and `degraded` readings do not count.

Its own container is only reported, never restarted: a self-restart would end
the restart call. The watchdog never starts or stops a container. Docker's
`restart: always` restarts a container that exits.

**Status.** The `watch` task writes `status.json` (`STATUS_FILE`, on the
`watchdog-status` volume) every cycle:
- one row per compose service: health text, color and failure count;
- a `syslog-ng` row, red ("silent log loss") when syslog-ng processed
  messages but no log file was written;
- the cache disk color: yellow from `DISK_WARN_PCT`, red from
  `DISK_ALARM_PCT`, `unknown` when `df` fails.

The `ui` container mounts the volume read-only; the dashboard reads it through
`GET /api/watchdog-status` (`ROUTE_WATCHDOG_STATUS` in
`services/ui/src/main.rs`).

**Retention.** The `retention` task in the `services` container runs every
`CHECK_INTERVAL` seconds:
- once a day it deletes cache files older than `CACHE_VALID_DAYS`
  (`purge_cache`, stamp `PURGE_STAMP`);
- it xz-compresses every closed syslog file (`compress_syslog`); today's
  files stay open in syslog-ng;
- once a day it deletes syslog files older than `SYSLOG_RETENTION_DAYS`,
  then the oldest ones until the store fits `SYSLOG_MAX_GB`; today's files
  stay, and an over-budget store is retried after
  `SYSLOG_PRUNE_RETRY_COOLDOWN` (`prune_syslog`, stamp
  `SYSLOG_PRUNE_STAMP`).

Each target directory is resolved (symlinks and `..`) and must lie strictly
inside `CACHE_DIR_ALLOWED_PREFIX` or `SYSLOG_LOG_ROOT_ALLOWED_PREFIX`;
otherwise nothing is deleted and no stamp is written.

**Other entry points.** `lancache-watchdog probe` prints one DHCP probe as
JSON; `lancache-watchdog get KEY` prints one baked value.

### Known benign startup/log messages (issue #849 item 8)

Four log lines observed during real field testing (#1068 item 8) that read
as alarming out of context but are expected, documented behavior once traced
to their actual source -- collected here rather than left as unexplained
"is this a problem?" notes:

- **`Reconciler: published 0 records`** (`services/dns/nats-subscriber/src/main.rs`'s
  `reconciler()`): a periodic (every `DNS_SYNC_TICK`, SOT runtime.defaults) full-resync pass that queries
  PowerDNS's `lan.` zone via its REST API and re-publishes every non-SOA/NS
  record over NATS, independent of the event-driven immediate-publish path
  used when a record actually changes. **Expected** whenever the `lan.` zone
  genuinely has no non-SOA/NS records yet -- a fresh install before any
  DHCP-DDNS client has registered, an install with DHCP-DDNS disabled
  entirely (`DHCP_DDNS_ENABLED=false`, the SOT default in `.github/yaml/build-manifest.yml`),
  or any deployment that legitimately has zero dynamically-registered LAN
  hosts. **Would be a real problem** only if DHCP-DDNS is enabled with active
  leases and this line persists anyway -- that would point at a PowerDNS
  API-connectivity or zone-content issue worth investigating directly (e.g.
  `pdns_control` / the zone's REST endpoint), not this reconciler's own logic.
- **NATS connection-refused-then-retry on `lancache-ui` startup**
  (`services/ui/src/main.rs`'s `connect_nats_with_retry()`): the Admin UI's
  `main()` awaits this function -- with a 1s-to-30s capped exponential
  backoff loop that treats "not yet reachable" as its normal steady state --
  *before* binding its own HTTP listener at all. Since Compose starts `ui`
  and `nats` concurrently (no blocking `depends_on: condition:
  service_healthy` between them), a connection-refused during `ui`'s first
  few seconds while `nats-server` is still initializing is an expected,
  self-resolving start-order race, confirmed harmless by design (the same
  reasoning already documented on `services/ui/src/main.rs`'s
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

**Corrected 2026-08-29 (issue #871 decision-rework pass): the `steamcmd`-based engine this
section previously described as the plan is retired.** The maintainer decided (recorded on
issue #871) that the engine described below — `steamcmd` fetching a full local game install —
conflicts with issue #816's non-negotiable stream-and-discard requirement and is not the
direction this project takes. See
[docs/design-steam-prefill.md](design-steam-prefill.md) (issue #816, issue #871) for the full
design discussion and its still-open implementation decisions (credential strategy is
unresolved; which-service-houses-the-engine is resolved below) before relying on any detail
here.

**Updated 2026-08-29 (issue #871, scaffold PR): `services/cachehamster` now
exists as a Rust crate** (maintainer decision: a new, independently-switchable service, not a
`services/ui` module — the operator must be able to turn CacheHamster off without affecting
the rest of the stack). Implemented so far: the credential-store (Argon2id-as-KDF +
XChaCha20-Poly1305 AEAD encryption of an operator-supplied Steam credential, with optional
persistence — see "Credential handling" below) and the stream-fetch primitive
(bounded-concurrency streaming GET into a discard sink, with throughput logging — see
"Throughput display" below). **Not yet implemented**: the Steam control-plane login
(`steam-vent`) and depot/manifest parsing (`steamroom`) that would resolve a real app ID into
real CDN chunk URLs — this needs a real Steam account to test safely against and is
deliberately deferred (see `services/cachehamster/src/main.rs`'s own module doc comment).

**Infra integration (issue #871, issue #1683): built into `services`, functionally still
inert.** `lancache-cachehamster` is a crate of the `services` image (`crates` of `services`
in `.github/yaml/build-manifest.yml`), so CI builds, scans and publishes it with that image.
It is no supervised program (`processes` of `services` does not list it), so nothing
starts it; `deploy/prod/docker-compose.yml` passes `CACHEHAMSTER_URLS` and mounts
`CACHEHAMSTER_DATA_DIR` into `services`. It has no full-stack CI check (AG-VAL-027): an
inert scaffold with no real depot-fetch behavior and no CI-available Steam credential gives
no testable claim. Do not treat this row as a runnable feature until the Steam
control-plane/depot integration above lands.

**Decision: stream-and-discard prefill, no SteamCMD.** `steamcmd` was rejected because
`steamcmd app_update` performs a real local install — it downloads, verifies, decompresses, and
writes the full depot content to disk on whatever host runs it, which is exactly the
disk-space/SSD-wear cost this project does not want to impose on an operator's cachehamster
host. The
selected mechanism instead talks to Steam's CDN directly and streams each depot chunk's HTTP
response body straight into a discard sink — the bytes exist only long enough to pass through
lancache-ng's proxy (which is what actually caches them) and are never buffered to a file or
held as a complete object in memory.

**Planned workflow** (not yet implemented — design-only):
1. Operator enters a Steam app ID (Admin UI or CLI, per the still-open "which service houses
   this" decision).
2. A depot/manifest layer resolves the app ID's depots and chunk list (control-plane login only
   where required — see the credential-strategy decision below).
3. Each chunk's CDN URL is fetched with a plain streaming HTTP GET, routed through the LAN's
   http-mode DNS/proxy path so lancache-ng's own cache observes and stores it, and the
   response body is drained directly into a discard sink as it arrives — never written to disk,
   never fully buffered in memory.
4. Progress (bytes/chunks fetched, current throughput) is displayed live to the operator.

**Throughput display and safety margin:** the maintainer asked that the design consider
`mbuffer` or `pv` between the download and the discard step, for (a) a speed readout in the
log and (b) a safety net if the download ever outpaces the discard. In the Rust
streaming-to-`tokio::io::sink()` design this decision selects, (b) does not apply structurally —
there is no separate consumer stage that can fall behind; the network read itself is always the
rate-limiting step, so nothing can back up behind a slower "discard" stage. (a) is still a real,
worthwhile requirement and is satisfied natively: a byte counter around the copy loop, logged on
a periodic interval, gives the same throughput visibility `pv` would, without needing an
external process or an extra pipe stage. An external `mbuffer`/`pv` stage would only become
relevant if a future revision of this design moves the fetch loop out of process (e.g. a shell
pipeline instead of an in-process Rust stream); if that ever happens, verify package
availability on this project's actual base images first (per AG-VAL-023) rather than assuming.
The real lever for sustaining line-rate throughput at 1–10 Gbit/s is fetch concurrency (multiple
chunks in flight at once), not buffering — a single HTTP stream rarely saturates a 10 GbE link
against a real CDN.

**Steam account:** credential strategy (dedicated/throwaway account vs. the operator's own,
where credentials are stored) is still an open decision — see
[docs/design-steam-prefill.md](design-steam-prefill.md). Whatever is decided, credentials are
never committed to the repo or baked into an image.

**Tracking:** planned: which app IDs were warmed + which CDN URLs belong to them → basis for targeted purging.

Epic / GOG: not planned to be supported.

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

- Netdata integrated (proxy via `/api/netdata`)
- Statistics: CPU, RAM, network MB/s (realtime + history), disk I/O
- Dashboard: cache fill level, hit/miss rate, active connections
- Watchdog per-service traffic light bar: one indicator per service
  (green/yellow/red) plus a cache-disk usage indicator, persistently visible
  in the dashboard's "Service health" card, live-polled every 10 seconds
  (issue #870; see the "Status" note under Watchdog above)
- Netdata alarm forwarding (bug-hunt #849 observability pass,
  finding #3): the `netdata` container's own `health.d` alarms (disk usage,
  CPU, memory, ...) previously had no notification integration or Admin UI
  surface of their own. The `netdata:` service's compose command block now
  configures Netdata's `custom_sender()` alarm-notify mechanism to POST each
  alarm event to the Admin UI's `POST /api/netdata-alarms`
  (`services/ui/src/main.rs`), gated by a shared
  `NETDATA_ALARM_TOKEN` (issue #858 shared-secret pattern, same as
  `PDNS_API_KEY`). The dashboard's "Netdata alarms" card
  (`services/ui/src/main.rs`) shows the most recent alarms
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
