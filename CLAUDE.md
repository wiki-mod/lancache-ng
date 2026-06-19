# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

A LAN cache that intercepts and caches game/software downloads on a local network. Built as an alternative to [lancachenet](https://github.com/lancachenet) with two key additions:

- **SSL interception** (MITM via custom CA certificate) — clients must install the CA cert once
- **IPv6 support** — full dual-stack

Everything runs in Docker containers based on Debian 13 (Trixie) images.

## Key Constraints

- The user is not a programmer. Make all technical decisions independently; only ask when a choice has real operational impact (hardware, cost, network topology).
- Chat language: German. Code language: English.

## Architecture

```
services/proxy/          # nginx: HTTP + HTTPS caching (SSL mode, CA cert required)
services/proxy-standard/ # nginx: HTTP caching + HTTPS passthrough (no CA cert needed)
services/dns/            # dnsmasq DNS server (shared by both modes)
config/dev/              # Settings for local development
config/prod/             # Settings for production deployment
certs/                   # CA certificate (auto-generated if missing; ca.key is gitignored)
deploy/dev/              # docker-compose for local dev
deploy/prod/             # docker-compose for production
docs/                    # End-user guides (e.g. how to install the CA cert)
```

## Two-Mode / Two-IP Architecture

lancachenet caches only HTTP. This project adds two operating modes — clients pick one
by configuring which DNS server IP they point to:

| Mode | DNS IP (prod) | Port 80 | Port 443 | CA cert needed? |
|---|---|---|---|---|
| **standard** | `192.168.1.10` | cached | passthrough (SNI) | No |
| **ssl** | `192.168.1.11` | cached | MITM-cached | Yes — install `certs/ca.crt` |

- **Standard mode** (`services/proxy-standard`): nginx `stream` block reads SNI via
  `ssl_preread` and forwards HTTPS blind to the real CDN. No TLS interception. HTTP
  is cached normally. Suitable for devices that can't or won't import custom CAs.
- **SSL mode** (`services/proxy`): full TLS interception via per-domain wildcard certs
  signed by the LAN CA. Both HTTP and HTTPS downloads are cached.
- Each mode gets its own proxy + DNS service, each bound to a distinct LAN IP.
  This is enforced by the `${IP_STANDARD}` / `${IP_SSL}` variables in `deploy/*/`env`.

## How SSL Interception Works (ssl mode)

1. **DNS spoofing**: dnsmasq resolves CDN hostnames (e.g. `steamcontent.com`) to the proxy's IP.
2. **Client connects** to proxy IP:443, sending SNI `steamcontent.com` in the TLS ClientHello.
3. **nginx** reads the SNI via `$ssl_server_name`, looks up the matching cert in `ssl-map.conf`
   (generated at startup), and presents a wildcard cert for `steamcontent.com` signed by our CA.
4. Client accepts because it trusts our CA → TLS handshake succeeds.
5. nginx decrypts the request, checks `proxy_cache`, fetches from the real CDN if needed
   (using `8.8.8.8` as resolver, never the LAN cache DNS to avoid loops), caches the response.
6. Consoles (PS5, Xbox) are **not** in the DNS list — if their CDN domains were redirected
   here, the TLS handshake would fail and the console could not fall back (our DNS would
   keep returning the proxy IP on every retry). By omitting them from DNS, consoles reach
   real CDNs directly and work normally (no caching, but no breakage).

## Key Design Decisions

- **nginx instead of Squid**: Squid's `intercept` mode requires iptables DNAT and reads
  `SO_ORIGINAL_DST` for the upstream IP — in a DNS-spoof scenario (no real DNAT) it would
  get the proxy's own IP and loop. nginx reads `Host`/`$ssl_server_name` directly, which is
  exactly what a DNS-spoofed client provides.
- **Pre-generated wildcard certs**: At startup, `entrypoint.sh` generates one 2048-bit cert
  per root CDN domain (e.g. covers `*.steamcontent.com`), signed by our CA. nginx selects
  the cert via `map $ssl_server_name $ssl_cert_name` in `conf.d/00-ssl-map.conf` (the `00-`
  prefix ensures it sorts first and the map is defined before the server blocks that use it).
- **Upstream resolver must be real DNS**: nginx's `resolver` directive is set to `8.8.8.8`,
  not our dnsmasq. If nginx used our DNS, `proxy_pass https://$host` would resolve CDN names
  back to the proxy → infinite loop.
- **`proxy_cache_lock on`**: Only one nginx worker fetches a cache-miss URL at a time. Other
  workers wait. Critical for large game files that multiple clients might request simultaneously.
- **Cache key is `$host$uri` (not `$request_uri`)**: CDN download URLs often include per-request
  expiry signatures in the query string. Using `$uri` (path only) means the same file always
  hits the same cache entry regardless of the signature. The full URL (with signature) is still
  forwarded to the origin for validation.
- **`libnginx-mod-stream`**: The standard proxy needs nginx's stream module for SNI passthrough.
  This module is in a separate Debian package and loaded via `load_module modules/ngx_stream_module.so;`
  at the top of `nginx.conf` (before the `events {}` block).
- **Serial file in `/tmp`**: The CA key is in a `:ro` mounted volume in prod. OpenSSL's
  `-CAcreateserial` would try to write `ca.srl` to the same directory — that fails. Instead
  we write the serial file to `/tmp/lancache-ca.srl` and pass it with `-CAserial`.

## Dev vs Prod Split

| | dev | prod |
|---|---|---|
| Cache size | 10 GB | 500 GB (configure per disk in `config/prod/proxy.env`) |
| Cache volume | Docker named volume | `/srv/lancache/{standard,ssl}` on host |
| CA cert | Auto-generated on first start | Mount pre-generated `certs/ca.crt` + `ca.key` |
| DNS query logging | On | Off |
| Ports (standard DNS) | 5300 (avoids Windows conflict) | 53 |
| Ports (ssl DNS) | 5353 | 53 |
| Container restart | `unless-stopped` | `always` |

## Running

```bash
# Development
docker compose -f deploy/dev/docker-compose.yml up --build

# Production
docker compose -f deploy/prod/docker-compose.yml up -d --build
```

## First-time Setup

1. **Dev**: just `docker compose up` — CA and all certs are auto-generated.
   Copy `certs/ca.crt` to clients and install it (see `docs/install-ca-cert.md`).
   DNS ports are offset (5300/5353) to avoid the Windows DNS client conflict.

2. **Prod**: two LAN IPs are required. Add the second:
   ```
   ip addr add 192.168.1.11/24 dev eth0
   ```
   Edit `deploy/prod/.env` to set `IP_STANDARD` and `IP_SSL`.
   Edit `config/prod/dns-standard.env` and `config/prod/dns-ssl.env` with the matching IPs.
   Optionally run `certs/generate-ca.sh` to create a dedicated CA before first start.
   Create cache directories: `mkdir -p /srv/lancache/standard /srv/lancache/ssl`

## Adding More CDN Domains

- **DNS**: add the hostname to `services/dns/cdn-domains.txt`
- **SSL cert**: add the root domain to `services/proxy/cdn-ssl-domains.txt`
  (if the root domain is already listed, subdomains are already covered)
- Rebuild and restart the containers

## IPv6 Notes

Docker Desktop on Windows has limited IPv6 support. In production (Linux host), IPv6 works
fully. The Docker daemon needs `"ipv6": true` in `/etc/docker/daemon.json` on the host.
