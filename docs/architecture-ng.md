# LanCache-NG Architecture

## Services

| Service | Default | Replaces | Notes |
|---|---|---|---|
| nginx (proxy) | on | — | Mainline from nginx.org, Debian 13 Base |
| PowerDNS | on | dnsmasq | Authoritative + Recursor for DNS spoofing & recursion |
| Kea DHCP | off | — | Requires PowerDNS (DDNS via nsupdate) |
| Watchdog | on | — | Health checks, auto-restart, purge cron |
| syslog-ng | on | — | Central logging for all containers |
| Admin UI | on | — | Axum/Rust, Tera, Tailwind, separate port |
| Cache Warmer | off | — | steamcmd, startable on demand |

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
| `CACHE_MAX_SIZE` | `500g` | Max cache size — UI checks against available disk space |
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
| `ENABLE_ROOT_MIRROR` | `false` | Root zone mirror (AXFR from root servers) |
| `FILTER_AAAA_V4` | `false` | Filter AAAA records for IPv4 clients |
| `FILTER_AAAA_V6` | `false` | Filter AAAA records for IPv6 clients |
| `ENABLE_SECONDARY` | `false` | Enable secondary zones. When set to `true` for remote secondaries, also include `deploy/prod/docker-compose.nats-secondary.yml` so NATS is bound only to the trusted interface specified by `NATS_BIND_IP`. |
| `NATS_BIND_IP` | — | Trusted LAN/VPN interface for optional NATS host binding used by remote secondaries; intentionally required by the secondary NATS override file. |
| `SECONDARY_MASTERS` | — | Primary DNS IP |
| `SECONDARY_ZONES` | — | Comma-separated zone list |

**allow-query / allow-recursion:** open to all RFC-1918 + IPv6 ULA by default

### Remote secondary NATS access

The production Compose file keeps NATS on the Docker network by default and does not publish port `4222` on the host. This keeps the event bus closed for installations that do not use remote secondaries.

There are two compatible ways to enable host binding for secondary DNS nodes:

1. **Reuse the existing secondary switch**: when `ENABLE_SECONDARY=true`, include `deploy/prod/docker-compose.nats-secondary.yml` and set `NATS_BIND_IP` to the trusted LAN or VPN interface that secondary nodes use.
2. **Use a separate explicit binding switch**: leave `ENABLE_SECONDARY` for DNS behavior, and include `deploy/prod/docker-compose.nats-secondary.yml` only when you intentionally want to publish NATS for remote secondary synchronization.

Example:

```sh
ENABLE_SECONDARY=1 NATS_BIND_IP=192.168.1.5 \
  docker compose -f deploy/prod/docker-compose.yml \
  -f deploy/prod/docker-compose.nats-secondary.yml up -d
```

Do not bind NATS to `0.0.0.0` unless an external firewall or VPN policy restricts access to trusted secondary nodes.

**nsupdate (RFC 2136):** TSIG-secured dynamic DNS channel into PowerDNS authoritative. Kea DHCP sends lease add/update/delete events through `kea-dhcp-ddns`; PowerDNS accepts those updates only for the LAN and private reverse zones that are explicitly mapped to the shared `DDNS_TSIG_KEY`.

## Kea DHCP

- DHCPv4 + DHCPv6 (dual-stack)
- IP ranges as start–end (no CIDR required)
- Static assignments: MAC → IP, editable via UI
- DDNS → PowerDNS: lease = automatically A + PTR in the configured DHCP domain via TSIG-secured nsupdate (RFC 2136)
- REST API (Kea Control Agent) for Admin UI

## Admin UI security headers

The Admin UI sends security response headers by default. The policy is compatible with the current self-hosted frontend assets and does not require external CDN JavaScript. Operators can tune the behavior with environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `UI_SECURITY_HEADERS` | `true` | Set to `false`, `0`, `off`, or `no` to disable the Admin UI security header middleware. |
| `UI_HSTS_MODE` | `auto` | Controls `Strict-Transport-Security`: `auto` only sends HSTS when `X-Forwarded-Proto: https` is present, `always` sends it on every response, and `never` disables it. |

Keep `UI_HSTS_MODE=auto` for direct LAN HTTP access or TLS-terminating reverse proxies that also leave `http://<host>:8080` reachable. Use `always` only when the UI hostname is intended to be HTTPS-only.

## Watchdog

Lightweight container with Docker socket access (restart permission).

**Health checks:**
- nginx: HTTP request on `/health`
- PowerDNS: DNS query test via `rec_control`
- Kea: REST API ping
- syslog-ng: Process check

**Auto-restart:** X failed checks → `docker restart <container>`

**Scheduled purge (cron, daily):**
- Remove cache entries older than `CACHE_VALID_HIT` (`find -mtime`)
- Complements nginx `inactive` (which works by access time)

**Disk monitoring:**
- Warning in UI at 85% full (yellow)
- Alarm at 95% (red)
- Monitors actual disk usage, not just nginx `max_size`

**Status:** displayed as traffic light bar in Admin UI (green/yellow/red per service)

## syslog-ng

Central logging for all containers. All services send to syslog-ng.

- Self-managed storage: max file size + automatic rotation
- Retention configurable (default: 30 days)
- **Log level per service configurable in Admin UI:**

| Service | Level options |
|---|---|
| nginx | `emerg / error / warn / info / debug` |
| PowerDNS | `critical / error / warning / notice / info / debug` |
| Kea | `fatal / error / warn / info / debug` |
| Watchdog | `error / info / debug` |

- **Forwarding:** destination IP + port + protocol (UDP/TCP/TLS, RFC 5424 or 3164) configurable in Admin UI
- Change in UI → writes config → `syslog-ng-ctl reload`

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
| Watchdog purge cron | daily automatic | file older than `CACHE_VALID_HIT` |
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
- Watchdog traffic light bar: one indicator per service, persistently visible

## Admin UI

Runs on its own Axum webserver (port 8080) — independent from nginx. If nginx is down, the UI is still reachable and shows the error.

- Two modes: **Beginner** (guided, no jargon) / **Expert** (technical direct)
- DNS: create zones, host entries, PTR checkbox for LAN IPs
- Kea: lease overview, create/edit static assignments
- Cache: start warming, progress, purging, retention + slice/size settings
- Logs: filtered by service, level selectable
- Advanced options (root mirror, filter AAAA, secondary, syslog forwarding) under "Advanced"

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
