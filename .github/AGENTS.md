# Coding Standards & Architecture Reference

This file is read by GitHub Copilot and other AI coding tools. Follow these rules on every change.

## Language

- **GitHub content** (issues, PRs, commit messages, comments, documentation): English only.
- **Code and configuration**: English only.
- **Chat with the project owner**: German.

## Project Stack

- **Rust** — the only permitted application language. No Go, Python, Node.js, or other runtimes without explicit approval from `@djdomi`.
- **Shell (bash)** — for container entrypoints and scripts.
- **nginx, PowerDNS, NATS JetStream, Kea DHCP** — infrastructure components.
- Everything runs in **Docker containers** based on **Debian 13 (Trixie)**.

## Architecture Overview

Two-mode LAN cache (DNS-spoofed download caching):

| Mode | DNS IP | Port 80 | Port 443 | CA cert? |
|---|---|---|---|---|
| standard | `IP_STANDARD` | cached | SNI passthrough | No |
| ssl | `IP_SSL` | cached | MITM-cached | Yes |

Two separate nginx services handle the modes:
- `services/proxy-standard`: SNI passthrough (nginx stream module) for standard mode
- `services/proxy`: TLS interception (nginx http block with cert generation) for SSL mode

## Key Patterns

- **Multi-stage Docker builds**: `rust:slim` builder → `debian:trixie-slim` runtime.
- **No OpenSSL Rust dependencies in slim images**: use `reqwest` with `rustls-tls` feature, not `openssl-sys`.
- **sccache**: opt-in only via `SCCACHE_REDIS_URL` build arg — never hardcoded.
- **Cache key**: `$host$uri` (not `$request_uri`) — CDN query signatures must not bust the cache.
- **nginx resolver**: always `8.8.8.8`, never the LAN DNS — avoids proxy loops.
- **Serial file**: write to `/tmp/lancache-ca.srl`, not next to the CA key (which may be read-only).

## What NOT to Do

- No direct pushes to `master` — all changes go through pull requests.
- No hardcoded LAN IPs in Dockerfiles or application code.
- No new languages or runtimes without explicit approval from `@djdomi`.
- Do not add `runs-on: ubuntu-latest` — use `[self-hosted, linux]`.
- The standard proxy requires nginx's stream module (`libnginx-mod-stream` Debian package) for SNI passthrough — load it via `load_module modules/ngx_stream_module.so;` in `nginx.conf`.

## Directory Structure

```
services/proxy/          # nginx: TLS interception (SSL mode)
services/proxy-standard/ # nginx: SNI passthrough (standard mode, stream module)
services/dns/            # PowerDNS (auth + recursor) with NATS subscriber
services/ui/             # Admin UI (Rust/Axum)
services/dhcp/           # Kea DHCP server
services/watchdog/       # Container health monitor
config/dev/              # Dev environment settings
config/prod/             # Production settings
deploy/dev/              # docker-compose for local development
deploy/prod/             # docker-compose for production
certs/                   # CA certificate (auto-generated if missing)
```
