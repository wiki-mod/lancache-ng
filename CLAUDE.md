# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

A LAN cache that intercepts and caches game/software downloads on a local network. Built as an alternative to [lancachenet](https://github.com/lancachenet) with two key additions:

- **SSL interception** (MITM via custom CA certificate) — clients must install the CA cert once
- **IPv6 support** — full dual-stack

Everything runs in Docker containers based on Debian 13 (Trixie) images.

## Governance

**[AG-GOV-001]** **Mandatory at the start of every session/task in this repo**: read `AGENTS.md` (repo root) and `.github/AGENTS.md` in full, and follow them as the binding, authoritative rule-set for this repository — not optional background reading. This is the *only* rule that stays in this file rather than living in `AGENTS.md` itself, and it stays here deliberately: `AGENTS.md` is not auto-loaded into context the way this file is, so the instruction to go read it has to live somewhere that *is* auto-loaded, or nothing would ever prompt a session to discover `AGENTS.md` in the first place. **The authoritative, most current version of both files lives on `current_dev`** (the active development branch), not necessarily on whatever branch/worktree you happen to be checked out on — `master` only receives governance-doc updates when a release is cut from `current_dev`, so it can lag behind by however long it has been since the last release. If your working branch is not `current_dev` (e.g. you are on `master`, a `vX.Y.Z` release branch, or a stale local checkout), fetch and read the `current_dev` copy of these two files (e.g. `git show origin/current_dev:AGENTS.md`) rather than trusting your current branch's copy as current. If either file changes during a session (e.g. after a `git pull` or a merge), re-read it before continuing work that it governs.

**As of 2026-07-30, this file carries no other independent rules of its own.** Every rule that previously lived here directly (chat/code language, GitHub content language, project language, master-push policy, the DNS-resolver/serial-file/build-tools/CDN-domain/setup/IPv6 rules) has moved into `AGENTS.md` — see that file's `AG-CC-*`, `AG-KD-*`, `AG-CDN-*`, `AG-SETUP-*`, and `AG-IPV6-*` entries, plus the mirrored/merged rules noted inline next to their `AGENTS.md` counterparts (e.g. `AG-WF-015`, `AG-GH-001`, `AG-REL-001`, `AG-WF-004`/`AG-WF-014`, `AG-OP-002`). This reverses an earlier, explicitly-flagged-as-reversible decision (PR #971/#972) to give this file its own parallel rule-ID namespace — that split caused real confusion about which file was actually authoritative, so the rule content now has exactly one home. What remains below is pure architecture, setup, and design-decision documentation for Claude Code sessions working in this repo; none of it is a citable, independently-enforced rule.

## Architecture

```
services/proxy/          # nginx: unified proxy serving both standard + SSL mode via different ports
services/dns/            # PowerDNS (authoritative + recursor) for DNS caching & spoofing (split into standard + SSL instances)
config/prod/             # Settings for production deployment
certs/                   # CA certificate (auto-generated if missing; ca.key is gitignored)
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
  per root CDN domain (e.g. covers `*.steamcontent.com`), signed by our CA, plus an
  additional cert for some `cdn-domains.txt` entries that a root-level wildcard SAN
  cannot cover (issue #1272) — the exact threshold differs by entry shape: a
  **leading-dot wildcard-only entry** (e.g. `.cdn.example.com`) needs its own deeper
  cert whenever the entry itself differs from the root at all, even by exactly one
  label (its actual matched hosts are always one label *deeper* than the entry text,
  so `.cdn.example.com` under root `example.com` already needs its own
  `*.cdn.example.com`-only cert); a **bare exact-host entry** (e.g.
  `tlu.dl.delivery.mp.microsoft.com`) needs its own cert only once the host itself is
  *more than one* label past the root, since a bare entry exactly one label past root
  is already covered by the root's own `*.<root>` wildcard. Every generated cert's
  subject CN is a fixed placeholder (`lancache-ng`), never the real hostname —
  OpenSSL's default CN policy caps it at 64 bytes, well under the 253-byte domains
  `cdn-domains.txt` can otherwise contain; the real hostname lives only in each
  cert's SAN, which TLS clients validate against per RFC 6125. Cert/key filenames for
  these deeper entries are a namespaced SHA-256 hash of the hostname, not the hostname
  itself, to stay under Linux's 255-byte filename limit. nginx selects the cert via
  `map $ssl_server_name $ssl_cert_name` in `conf.d/00-ssl-map.conf` (the `00-`
  prefix ensures it sorts first and the map is defined before the server blocks that use it).
- **Upstream resolver must be real DNS**: nginx's `resolver` directive points at real upstream DNS,
  not our PowerDNS recursor — see `AGENTS.md`'s `AG-OP-002` for the binding rule, the
  `NGINX_UPSTREAM_RESOLVER` default value, and why using our own DNS would create an infinite loop.
- **`proxy_cache_lock on`**: Only one nginx worker fetches a cache-miss URL at a time. Other
  workers wait. Critical for large game files that multiple clients might request simultaneously.
- **Cache key is `$host$uri` (not `$request_uri`)**: CDN download URLs often include per-request
  expiry signatures in the query string. Using `$uri` (path only) means the same file always
  hits the same cache entry regardless of the signature. The full URL (with signature) is still
  forwarded to the origin for validation.
- **nginx's stream module for standard-mode SNI passthrough**: `services/proxy/Dockerfile` installs
  nginx from nginx.org's own mainline apt repo, not Debian's own `nginx` package. nginx.org's
  package compiles the stream module in statically (confirmed via its own `nginx -V` output:
  `--with-stream --with-stream_ssl_preread_module`, among others) — there is no separate module
  package to install and no `load_module` directive anywhere in `services/proxy/nginx.conf`.
  (Corrected 2026-07-30: this bullet previously and incorrectly described a separate
  `libnginx-mod-stream` package requiring an explicit `load_module` line — that described
  Debian's own nginx package, which this project does not use.)
- **Serial file**: OpenSSL's certificate serial file (`ca.srl`) is stored alongside the CA
  certificate and key in the certs directory — see `AGENTS.md`'s `AG-KD-002` for the binding rule.
- **`build-tools`'s CI tools: prebuilt binary by default, source-build only when there's a
  concrete reason** — see `AGENTS.md`'s `AG-KD-003` for the binding rule and its full,
  repeatedly-reconfirmed history (actionlint, Docker CLI, docker-compose).

## No Separate Dev Environment

There is only one deployment profile, `deploy/prod/` — there used to be a parallel
`deploy/dev/`/`config/dev/` pair (separate LAN IPs, offset DNS ports, a separate compose
file kept in sync with prod by hand), retired in v0.3.0 (#766). That split was never
something the maintainer actually asked for: the original, much simpler intent behind
"dev" was just "the branch I currently develop on" (`current_dev`, see
`docs/release-versioning.md` and #825/#1141's branch model), not a second live deployment
environment. An earlier AI session misread that as a request to build a whole parallel
profile, and it grew from there — this has now been undone.

Local iteration and real validation both use `deploy/prod/docker-compose.yml` directly;
the difference between "developing" and "deploying" is which git ref is checked out
(`current_dev` vs. a `vX.Y.Z` release branch vs. `master`), not which compose file or
config directory is used. In practice, most real validation for this project happens via
SSH against Linux self-hosted runners rather than a local Docker Desktop install (Rust
builds and full-stack `docker compose up` runs are not exercised on the Windows
authoring host — see the IPv6 note below for one concrete Docker-Desktop-on-Windows
limitation).

## Running

```bash
docker compose -f deploy/prod/docker-compose.yml up -d
```

## First-time Setup

**Prod**: two LAN IPs are required (see `AGENTS.md`'s `AG-SETUP-001` for the binding rule). Add the second:
```
ip addr add 192.168.1.11/24 dev eth0
```
Edit `deploy/prod/.env` to set `IP_STANDARD` and `IP_SSL`.
Edit `config/prod/dns-standard.env` and `config/prod/dns-ssl.env` with the matching IPs.
Optionally run `certs/generate-ca.sh` to create a dedicated CA before first start.
Create cache directory: `mkdir -p /opt/lancache-ng/cache` (or wherever `LANCACHE_STATE_DIR` points)

## Adding More CDN Domains

- Add the hostname to `services/dns/cdn-domains.txt` (or via the Admin UI) — see `AGENTS.md`'s
  `AG-CDN-001` for the binding rule (this is the only file to maintain).
- The proxy derives each entry's registrable root domain automatically at
  startup (using the vendored Mozilla Public Suffix List, see
  `services/proxy/entrypoint.sh`) and generates a wildcard cert for it.
- Restart the containers (or wait for the Admin UI to trigger it) so the proxy picks up the new domain.

## IPv6 Notes

Docker Desktop on Windows has limited IPv6 support. In production (Linux host), IPv6 works
fully — see `AGENTS.md`'s `AG-IPV6-001` for the binding Docker-daemon-config rule.
