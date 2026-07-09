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

## Governance

**Mandatory at the start of every session/task in this repo**: check whether `AGENTS.md` (repo root) and `.github/AGENTS.md` exist, read both in full, and follow them as binding rules for this repository — not optional background reading. `AGENTS.md` is not auto-loaded into context the way this file is; you must actively read it yourself. If either file changes during a session (e.g. after a `git pull` or a merge), re-read it before continuing work that it governs.

See `.github/AGENTS.md` for the full coding standards and architecture reference.

- **GitHub content language**: English — issues, PRs, commit messages, comments, and docs must all be in English.
- **Project language**: Rust (and shell for scripts) for code *we write*. This is about avoiding language sprawl in our own source, not a blanket ban on ever invoking another language's toolchain — a third-party CI tool (e.g. `actionlint`) that happens to be written in Go may still need to be *compiled* with a current Go toolchain for a real technical reason (e.g. avoiding a stale, statically-embedded stdlib with known CVEs baked into its upstream prebuilt release binary). That distinction — installing/running vs. writing new source in another language, or introducing a language runtime for a reason beyond "the upstream tool happens to be written in it" — still needs explicit approval from the user before doing it, every time, not just once.
- **No direct pushes to master**: all changes go through pull requests.

## Architecture

```
services/proxy/          # nginx: unified proxy serving both standard + SSL mode via different ports
services/dns/            # PowerDNS (authoritative + recursor) for DNS caching & spoofing (split into standard + SSL instances)
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

- **Standard mode** (port 8443 on `IP_STANDARD`): nginx `stream` block reads SNI via
  `ssl_preread` and forwards HTTPS blind to the real CDN. No TLS interception. HTTP
  is cached normally. Suitable for devices that can't or won't import custom CAs.
- **SSL mode** (port 443 on `IP_SSL`): full TLS interception via per-domain wildcard certs
  signed by the LAN CA. Both HTTP and HTTPS downloads are cached.
- **Single unified proxy service** (`services/proxy`): one nginx container handles both modes
  via separate ports and Docker port mappings. Both modes share a single cache volume.
- **Two DNS services** (`dns-standard` and `dns-ssl`), each bound to a distinct LAN IP.
  This is enforced by the `${IP_STANDARD}` / `${IP_SSL}` variables in `deploy/*/`env`.

## How SSL Interception Works (ssl mode)

1. **DNS spoofing**: PowerDNS authoritative resolves CDN hostnames (e.g. `steamcontent.com`) to the proxy's IP via zone files generated from `cdn-domains.txt`.
2. **Client connects** to proxy IP:443, sending SNI `steamcontent.com` in the TLS ClientHello.
3. **nginx** reads the SNI via `$ssl_server_name`, looks up the matching cert in `ssl-map.conf`
   (generated at startup), and presents a wildcard cert for `steamcontent.com` signed by our CA.
4. Client accepts because it trusts our CA → TLS handshake succeeds.
5. nginx decrypts the request, checks `proxy_cache`, fetches from the real CDN if needed
   (using `NGINX_UPSTREAM_RESOLVER` as the real upstream resolver, never the LAN cache DNS to avoid loops), caches the response.
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
- **Upstream resolver must be real DNS**: nginx's `resolver` directive is configured by `NGINX_UPSTREAM_RESOLVER` (default `8.8.8.8 8.8.4.4`),
  not our PowerDNS recursor. If nginx used our DNS, `proxy_pass https://$host` would resolve CDN names
  back to the proxy → infinite loop.
- **`proxy_cache_lock on`**: Only one nginx worker fetches a cache-miss URL at a time. Other
  workers wait. Critical for large game files that multiple clients might request simultaneously.
- **Cache key is `$host$uri` (not `$request_uri`)**: CDN download URLs often include per-request
  expiry signatures in the query string. Using `$uri` (path only) means the same file always
  hits the same cache entry regardless of the signature. The full URL (with signature) is still
  forwarded to the origin for validation.
- **`libnginx-mod-stream`**: The unified proxy uses nginx's stream module for standard-mode SNI passthrough.
  This module is in a separate Debian package and loaded via `load_module modules/ngx_stream_module.so;`
  at the top of `nginx.conf` (before the `events {}` block).
- **Serial file in `/tmp`**: To avoid permission errors when generating certs, OpenSSL's
  serial file is always written to `/tmp/lancache-ca.srl` rather than the certs directory,
  and passed with `-CAserial`.
- **`build-tools`'s CI tools: prebuilt binary by default, source-build only when there's a
  concrete reason**: `cargo-audit` and `cargo-tarpaulin` are fetched as checksum-verified
  prebuilt release binaries — they're Rust, so there's no behavioral difference from building
  them ourselves, just wasted build time. `actionlint` is the one exception, built from source
  against `golang:latest`: Go statically embeds its entire standard library into every compiled
  binary, so a stale upstream release binary permanently carries whatever stdlib CVEs existed
  when *its* maintainers last cut a release — confirmed for real (2026-07-09): actionlint's
  latest release (v1.7.12, published 2026-03-30) scores 11 HIGH/CRITICAL Trivy findings
  (crypto/x509, crypto/tls, net/mail, HTTP/2) via its embedded Go 1.26.1 stdlib, while building
  the same version from source with `golang:latest` picks up a current Go toolchain (1.26.5 as
  of this writing) and scores 0. This is a narrow, justified exception to the "Rust and shell
  only" project-language rule (see above), not a general license to add other language
  toolchains — re-justify it the same way (a real Trivy/CVE finding, not a hypothetical one)
  before reaching for a compiled-from-source dependency in another language again.

## Dev vs Prod Split

| | dev | prod |
|---|---|---|
| Cache size | 10 GB | 500 GB (configure per disk in `config/prod/proxy.env`) |
| Cache volume | Docker named volume | `${LANCACHE_STATE_DIR:-/opt/lancache-ng}/cache` on host |
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
   Create cache directory: `mkdir -p /opt/lancache-ng/cache` (or wherever `LANCACHE_STATE_DIR` points)

## Adding More CDN Domains

- Add the hostname to `services/dns/cdn-domains.txt` (or via the Admin UI) — this is the only file to maintain.
- The proxy derives each entry's registrable root domain automatically at
  startup (using the vendored Mozilla Public Suffix List, see
  `services/proxy/entrypoint.sh`) and generates a wildcard cert for it.
- Restart the containers (or wait for the Admin UI to trigger it) so the proxy picks up the new domain.

## IPv6 Notes

Docker Desktop on Windows has limited IPv6 support. In production (Linux host), IPv6 works
fully. The Docker daemon needs `"ipv6": true` in `/etc/docker/daemon.json` on the host.
