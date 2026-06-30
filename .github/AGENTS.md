# Repository Governance

## Language

All GitHub content — issues, pull requests, commit messages, code comments, and documentation — must be written in **English**.

## Issue And PR Tracking

- Issue descriptions must include the correct links to related pull requests, issues, or parent tracking threads when those relationships are known.
- Pull requests must reference their tracking issue in the PR body whenever possible.
- Use closing keywords such as `Fixes #123` or `Closes #123` only when merging the PR should close the issue.
- Use non-closing references such as `Refs #123` for parent trackers, design discussions, drafts, or partial follow-up work.
- Do not leave known issue/PR relationships only in chat history; capture them in GitHub so review, merge, and cleanup decisions stay traceable.

## Project Language

This project is written in **Rust**. Shell scripts are permitted for entrypoints and automation.

No other runtime language (Go, Python, Node.js, etc.) may be introduced without explicit approval from @djdomi.

## Architecture

A LAN cache that intercepts and caches game/software downloads. Two operating modes:

| Mode | Port 443 | CA cert needed? |
|---|---|---|
| standard | SNI passthrough | No |
| ssl | MITM-cached (TLS interception) | Yes |

Stack: Docker / Debian Trixie, nginx, PowerDNS, NATS JetStream, Rust services.

## Coding Patterns

- **Docker builds**: production/service Dockerfiles use multi-stage builds with pinned `rust:slim` builder images. Do not use `rust:latest` or Debian-based builder images for production/service Dockerfiles. Local developer helper scripts may default to `rust:latest` when the image is explicitly overrideable.
- **TLS in Rust**: use `reqwest` with `default-features = false, features = ["rustls-tls"]`. Never add `openssl-sys` as a dependency — `rust:slim` has no OpenSSL headers.
- **sccache**: controlled by `SCCACHE_REDIS_MODE` (`required`, `optional`, `off`) and the `SCCACHE_REDIS_URL` GitHub Actions secret. Never hardcode a Redis URL.
- **Cache key**: nginx uses `$host$uri` (not `$request_uri`) — CDN query-string signatures must not bust the cache.
- **DNS resolver in nginx**: must point to `8.8.8.8`, never to the local PowerDNS recursor — that would cause an infinite loop.

## What Not To Do

- Do not push directly to `master`. All changes go through pull requests.
- Do not hardcode LAN IP addresses (e.g. `192.168.x.x`) in Dockerfiles or source files.
- Do not introduce a new programming language without explicit approval.
- Do not use `proxy_cache_key $request_uri` — query strings contain per-request CDN signatures.
