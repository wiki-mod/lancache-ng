# lancache-ng Threat Model

> **Last reviewed against release: `v0.3.0`**
> **Last review date: 2026-07-24**
>
> This document must be re-audited for every release. It describes the security
> posture of a *specific* architecture, and that architecture changes between
> versions. Wording alone going stale (e.g. a service renamed, a mitigation
> narrowed) silently turns this file into misinformation, which is worse than
> having no threat model. Before tagging a release, work through
> [How to re-audit this document](#how-to-re-audit-this-document-per-release) and
> bump the marker above.

This document outlines the security threats that lancache-ng is designed to
protect against, the mitigations that actually exist in the current codebase,
and the risks that are explicitly out of scope.

lancache-ng is a **trusted-LAN appliance**. It intercepts and caches
game/software downloads for devices on a local network, optionally decrypting
HTTPS via a locally-trusted CA. Its entire security model assumes the LAN is
trusted; it is **not** hardened for internet exposure. Everything below is
framed against that assumption.

---

## Component currency inventory

A reviewer can use this table to see, at a glance, which parts of the system
this document was last checked against. When a component's implementation
changes in a release, update its row (and the threats that reference it) and set
"Last verified" to that release. A row whose version lags the release marker at
the top is a signal that its threats need re-checking.

| Component | Primary source of truth | Last verified | Threats |
|---|---|---|---|
| DNS spoofing (PowerDNS RPZ) | `services/watchdog/src/main.rs` (`pdns_auth`, `rpz_zone`), `services/dns/cdn-domains.txt` | v0.2.0 | T1, T4, T11 |
| TLS interception + local CA | `services/watchdog/src/main.rs` (`nginx`), `services/ui/nginx/conf.d/https.conf` | v0.2.0 | T7, T8, T10 |
| Proxy request policy (client CIDR + host allowlists) | `services/watchdog/src/main.rs` (`nginx`), `services/ui/nginx/conf.d/http.conf` | v0.2.0 | T2, T9 |
| Admin UI authentication | `services/ui/src/main.rs` | v0.2.0 | T3 |
| Docker access (socket in the `services` container, watchdog client) | `deploy/prod/docker-compose.yml`, `services/common/shared.rs` (`DockerApi`) | `current_dev` (Issue #1683) | T6 |
| DHCP — Kea mode | `services/watchdog/src/main.rs` (`kea_dhcp4`, `kea_ctrl_fence`, `kea_dhcp_ddns`), `docs/README.md` | v0.2.0 | T12 |
| DHCP — dnsmasq-proxy and dnsmasq-relay modes | `services/watchdog/src/main.rs` (`dnsmasq_conf`), `docs/README.md` | v0.2.0 | T12, T13 |
| Zone transfer to secondaries (TSIG, NOTIFY, AXFR) | `services/watchdog/src/main.rs` (`pdns_auth`) | v0.2.0 | T5 |
| Secondary-node registration | `deploy/secondary/docker-compose.yml`, `services/ui/src/main.rs` | v0.2.0 | T5, T14 |
| Console exclusion-by-omission | `services/dns/cdn-domains.txt`, `docs/README.md` | v0.2.0 | T4, T10 |
| Zone/record known-good snapshot + rollback listener | `services/ui/src/main.rs` (`zone-rollback`), `docs/README.md` | v0.3.0 | T4 |

---

## Assets to protect

1. **Cache integrity** — cached content must not be modified or poisoned; a
   poisoned entry is served to every subsequent client.
2. **WAN bandwidth / download speed** — the reason the appliance exists; a
   bypass or DoS that defeats caching degrades the service.
3. **Client trust in the local CA (HTTPS mode only)** — the CA private key can mint
   certificates every client trusts. Its compromise is the highest-impact event
   in the whole system.
4. **Control-plane integrity** — the Admin UI, PowerDNS API, Kea Control Agent
   API, and the Docker control path. Anyone who can drive these
   can redirect traffic, poison the cache, or (via Docker) take the host.
5. **Deployment confidentiality** — the appliance must not be reachable from
   untrusted networks.

Note on **client privacy**: in HTTPS mode the proxy decrypts client HTTPS
downloads by design. This is an intentional capability, not an asset the system
protects *from the operator*. It is called out again in "Out of scope".

---

## Trust boundaries

```
┌──────────────────────────────────────────────────────────────────────┐
│  UNTRUSTED: Internet (WAN)                                             │
│    - Real CDN origins            - External/public DNS resolvers       │
│    - Potential MITM on WAN path  - Internet-based attackers            │
└───────────────────────────────▲──────────────────────────────────────┘
                                 │  proxy → CDN over TLS (verified),
                                 │  resolved via NGINX_UPSTREAM_RESOLVER
                                 │  (real DNS, never the LAN spoof DNS)
┌───────────────────────────────┴──────────────────────────────────────┐
│  TRUSTED: LAN boundary  (core assumption: every device here is trusted)│
│                                                                        │
│  ┌──────────────── lancache-ng appliance (single Docker host) ──────┐ │
│  │  DATA PLANE                          CONTROL PLANE                │ │
│  │   - proxy (nginx): HTTP cache,        - Admin UI (auth-gated)     │ │
│  │     HTTPS-mode MITM cache, HTTP-       - PowerDNS HTTP API        │ │
│  │     mode SNI passthrough              - Kea Control Agent API     │ │
│  │   - DNS (PowerDNS auth + recursor)      (port 8000, host-net)     │ │
│  │   - DHCP (Kea) OR dnsmasq-proxy       - PowerDNS API (internal)    │ │
│  │                                       - watchdog in `services`    │ │
│  │  Local CA key (HTTPS mode) lives on     (Docker socket mount) ────┼─┼─► Docker
│  │  host: <CA_DIR>/ca.key                                           │ │   daemon
│  └──────────────────────────────────────────────────────────────────┘ │
│                                                                        │
│  LAN clients: PCs, Steam Deck, phones (install CA for HTTPS mode)      │
│  Consoles (PS5/Xbox/Switch): cannot install CA → excluded from spoof   │
│    list → use appliance purely as an unrestricted DNS resolver         │
└────────────────────────────────────────────────────────────────────────┘
```

**Key assumptions:**

- Every device on the LAN is trusted. There is **no** isolation between clients.
- Attackers are modelled as either (a) external/WAN, or (b) a compromised or
  rogue device that has somehow reached the LAN despite assumption 1.
- The operator is trusted and is responsible for firewalling the appliance's
  control-plane ports off from any untrusted network segment.

---

## Architecture in scope (for context)

Threats below reference these mechanisms. This is a summary, not the
authoritative description — see `AGENTS.md`'s `## Architecture` section and the
per-component sources in the inventory table (**corrected 2026-08-05, issue
#1391 doc-sweep audit**: this used to cite `CLAUDE.md`, which no longer carries
architecture content as of 2026-07-31 — that content moved into `AGENTS.md`).

- **DNS spoofing** — PowerDNS (authoritative + recursor) in
  one container. Before PowerDNS starts, the supervisor (`rpz_zone` in
  `services/watchdog/src/main.rs`) builds an **RPZ zone**
  from `cdn-domains.txt`, pointing each listed CDN hostname (and its wildcards)
  at the proxy IP via A/AAAA records. Everything *not* listed is resolved
  normally by the recursor against real upstream DNS.
- **Two proxy modes** (one nginx container, selected by which DNS IP the client
  uses): **HTTP mode** reads SNI via `ssl_preread` and forwards HTTPS blind
  to the real CDN (no CA needed); **HTTPS mode** terminates TLS using a per-domain
  wildcard cert signed by the local CA, caches, then re-fetches from the origin
  over verified TLS.
- **Local CA (HTTPS mode)** — generated on first start (RSA-4096, 10-year) into
  the CA state directory (`CA_DIR`). `ca.key` is the crown jewel and stays
  outside the checkout; `ca.crt` is
  a public certificate distributed to clients.
- **Proxy request policy** — `PROXY_SECURITY_MODE` (`lazy` default / `strict`)
  controls whether only listed CDN hosts may be proxied; `PROXY_ALLOWED_CLIENT_CIDRS`
  optionally restricts which client source networks the proxy answers at all.
  For HTTP/HTTPS traffic this is an `http{}`/`https{}` control (returns 403
  otherwise). The http-mode `stream{}` SNI-passthrough listener (`:8443`)
  and the HTTPS-mode stream-level SNI dispatcher (`:443`) enforce
  `PROXY_SECURITY_MODE=strict`'s domain allowlist differently (an unlisted
  SNI is routed to a closed `127.0.0.1:9`, not a 403), and enforce
  `PROXY_ALLOWED_CLIENT_CIDRS` separately via `ngx_stream_access_module`
  plain `allow`/`deny` directives (a TCP-level accept/reject before
  `ssl_preread`, not the `$lancache_client_allowed` geo variable, which is
  http-context-only and structurally unusable from `stream{}`) — see T2.
- **Admin UI** — Rust/axum service. Fail-closed auth (see T3). Has no Docker
  access; it writes the desired state (`DESIRED_STATE_FILE`) that the
  supervisor inside the supervised containers reads to run or stop its own
  processes (see T6).
- **DHCP** — optional, mutually-exclusive modes (`disabled` / `kea` /
  `dnsmasq-proxy` / `dnsmasq-relay`) in the one `dhcp` container, so clients
  receive the appliance's DNS automatically.
- **Zone transfer** — PowerDNS NOTIFY + TSIG-signed AXFR carries DNS record
  changes to optional remote **secondary** DNS nodes.

---

## Threat analysis

Each threat lists likelihood and impact *within the trusted-LAN model*.
"Likelihood: High (if exposed to internet)" means the risk is realised primarily
when the operator breaks the core assumption by exposing a control-plane port.

### T1: Cache poisoning from a compromised/MITM'd CDN

**Threat**: An attacker who compromises a CDN, or intercepts the proxy→CDN path,
injects malicious content that the proxy caches and serves to every client.

**Likelihood**: Low · **Impact**: High

**Mitigations**:
- The proxy fetches HTTPS-mode origins over TLS with `proxy_ssl_verify on` and the container's system CA
  bundle (`proxy_ssl_trusted_certificate`, `/etc/ssl/certs/ca-certificates.crt` on
  this service's current Alpine base, issue #815 -- the same path the prior
  Debian base also used); see also T8.
- Upstream resolution uses `NGINX_UPSTREAM_RESOLVER` (default `8.8.8.8 8.8.4.4`, IPv4 only),
  never the LAN spoof DNS — the supervisor's nginx render (`nginx` in
  `services/watchdog/src/main.rs`) refuses to start nginx if the resolver names a
  LanCache IP, preventing a resolve-to-self loop.
- Cache key is `$host$uri` (query-string signatures stripped), so a per-request
  signature cannot be used to smuggle a distinct poisoned object under a shared
  key without also passing origin validation.

**Residual risk**: Medium — a genuine CDN compromise or trusted-CA misissuance is
outside the appliance's control.

---

### T2: LAN client poisons the cache

**Threat**: A compromised or rogue LAN device sends crafted requests to trick the
proxy into caching attacker-controlled content under a legitimate key.

**Likelihood**: Medium · **Impact**: High (poison served to all clients)

**Mitigations**:
- Cache key includes the `Host` header (`$host$uri`); responses are only cached
  after the origin fetch succeeds over verified TLS.
- `PROXY_SECURITY_MODE=strict` limits proxied hosts to those derived from
  `cdn-domains.txt` (deny-by-default `$cdn_host_allowed` map, rooted via the
  vendored Public Suffix List — see `Psl` and `nginx` in
  `services/watchdog/src/main.rs`),
  removing the "proxy anything" behaviour of the default `lazy` mode. This
  enforcement applies to the `http{}`/`https{}` `location /` blocks (HTTP
  403 response); the http-mode `stream{}` SNI-passthrough listener
  enforces the same domain list differently — an unlisted SNI is routed to
  a closed `127.0.0.1:9`, not a 403.
- `PROXY_ALLOWED_CLIENT_CIDRS` optionally restricts which client networks the
  proxy will answer at all for HTTP/HTTPS traffic (`$lancache_client_allowed`
  → 403 in `conf.d/http.conf`/`https.conf`). The externally-facing stream-level
  SNI-passthrough listeners (`:8443` HTTP mode, `:443` HTTPS-mode dispatch)
  enforce the same CIDR list independently, via `ngx_stream_access_module`
  `allow`/`deny` directives generated into
  `stream.d/access.d/00-stream-client-acl.conf` (a TCP-level accept/reject
  ahead of `ssl_preread`, since `$lancache_client_allowed`'s geo variable
  cannot cross the `http{}`/`stream{}` context boundary) — a denied
  connection is refused before any TLS handshake, not answered with an
  HTTP 403.

**Residual risk**: Medium — `lazy` mode (the default) will proxy any requested
host; strict mode and client CIDR limits are opt-in. Ultimately bounded by the
trusted-LAN assumption.

---

### T3: Unauthorized access to the Admin UI

**Threat**: An attacker reaches the Admin UI and purges the cache, edits domain
lists, switches DHCP mode, or sets a desired service state that stops or runs
the DHCP or NTP process.

**Likelihood**: Low on a firewalled LAN; High if the UI port is exposed to an
untrusted network · **Impact**: High

**Mitigations** (verified in `services/ui/src/main.rs` / `config.rs`):
- **Authentication is fail-closed by default.** `preflight`
  requires *both* `UI_AUTH_USER` and `UI_AUTH_PASSWORD_HASH` (an Argon2id hash;
  the password itself is never stored). If both are unset the UI
  **refuses to start** unless the operator has *explicitly* set
  `ALLOW_INSECURE_UI=true`. A partial config (only one of the two) is a hard
  startup error. There is no silent unauthenticated default.
- A password changed on the Setup page needs the old password, at least 12
  characters, and is stored only as an Argon2id hash in a 0600 file next to
  the settings file. A new `UI_AUTH_PASSWORD_HASH` in `.env` wins over that
  file, so the reset path stays with the host operator.
- A valid session cookie never substitutes for required Basic auth on protected
  routes (regression-tested).
- Startup also fails closed if `SECONDARY_REGISTRATION_TOKEN` is empty (an empty
  token would authenticate any secondary; see T14).

**Residual risk**: Low, and entirely operator-controlled: it exists only if the
operator sets `ALLOW_INSECURE_UI=true` *and* exposes the UI beyond the trusted
LAN. `deploy/prod` binds the UI to `UI_BIND_IP`, which defaults to
`IP_HTTP`; `UI_BIND_IP=127.0.0.1` restricts it further.

---

### T4: DNS spoofing bypass or misdirection

**Threat**: A client is pointed (or tricked into pointing) at a different
resolver, bypassing the cache; or an attacker manipulates which hostnames the
appliance spoofs.

**Likelihood**: Low · **Impact**: Medium (cache bypass; no local compromise)

**Mitigations**:
- Clients are configured to use the appliance's DNS (statically, or via a DHCP
  mode — see T12).
- The spoof set is an explicit allowlist (`cdn-domains.txt`); domains are
  validated before being written into the RPZ zone. DNS record changes flow only
  through the authenticated PowerDNS API and TSIG-signed zone transfers (see
  T5), not from arbitrary clients.
- **Zone/record rollback (issue #628)**: known-good snapshots are listed and
  restored by `lancache-ui zone-snapshots` / `zone-rollback` inside the `ui`
  container (`services/ui/src/main.rs`). There is no network listener for it;
  the restore uses the PowerDNS API with `X-API-Key`. Rollback is always
  operator-selected, never automatic on startup.
- The PowerDNS API key is a shared handshake secret bootstrapped safely (issue
  #858): the supervisor in `dns` (`pdns_api_key` and `stack_secret` in
  `services/watchdog/src/main.rs`, `resolve_shared_secret` in
  `services/common/shared.rs`) resolves `PDNS_API_KEY` through the
  shared-secrets volume so PowerDNS and the Admin UI's PowerDNS REST client
  always agree on the exact same value. A real operator/`setup.sh` value always
  wins; an empty or known-placeholder one is replaced by a generated
  first-writer-wins value shared with the UI instead of crash-looping. A key
  shorter than 16 characters is still refused as defense in depth.
- RPZ SOA serials are kept monotonic so secondary nodes converge correctly.

**Residual risk**: Low — correct client DNS configuration is the operator's
responsibility. A bypass costs caching, not integrity.

---

### T5: DNS zone-transfer abuse (primary → secondary)

**Threat**: An untrusted party pulls zone data from the primary (AXFR), or
pushes forged NOTIFY/updates to make a secondary load wrong DNS data.

**Likelihood**: Low · **Impact**: Medium (DNS state disclosure; wrong records
on a secondary until the next good transfer)

**Mitigations**:
- Secondaries replicate with native PowerDNS NOTIFY + AXFR. Every transfer is
  signed with the TSIG key (`DDNS_TSIG_NAME`/`DDNS_TSIG_KEY`), bound per zone
  (`TSIG-ALLOW-AXFR` / `AXFR-MASTER-TSIG`); `allow-axfr-ips` holds only the
  optional `PDNS_AXFR_FROM` hosts, so a secondary without the key gets nothing.
- The TSIG key reaches a secondary only through the authenticated
  registration answer (`/api/secondary/register`, see T14).
- Record changes are written only by the Admin UI through the PowerDNS API
  (`X-API-Key`); secondaries never publish records.
- SOA serials are monotonic (RFC 1982); the dashboard shows a lagging
  secondary (lost NOTIFY or broken AXFR).

**Residual risk**: Low — bounded by keeping the TSIG secret and the
registration token secret. Rotating the TSIG key requires re-registering
every secondary.

---


### T6: Docker control-path abuse (host takeover)

**Threat**: A compromised container or attacker reaches the Docker API and
creates privileged containers or `exec`s into others, escaping to the host.

**Likelihood**: Medium (a control plane with Docker reach is inherently
sensitive) · **Impact**: Critical (full host compromise)

**Mitigations / actual exposure** (verified in
`deploy/prod/docker-compose.yml` and `services/common/shared.rs`):
- **The Admin UI has no Docker access.** It only writes the desired service
  state, which the supervisor inside the supervised containers reads without
  any Docker call. A compromised UI cannot call the Docker API.
- **The `services` container mounts the Docker socket read-write, with no
  socket proxy.** Its watchdog process is the only Docker API client in the
  code (`DockerApi`: container list of the compose project, inspect, and
  restart of a failing container). The mount is visible to every process in that container
  (watchdog, syslog-ng, chronyd, retention), and the socket itself
  grants the full Docker API, so a compromise of the `services` container is a
  host compromise. The container drops all capabilities except the list in
  `deploy/prod/docker-compose.yml`.
- **Scheduled automatic updates (#819) do not add a new socket-access
  surface.** Unlike the removed Watchtower helper (which mounted the socket
  **read-write** in its own container for image updates), the update
  orchestrator runs as a host `systemd` timer/service invoking `setup.sh
  auto-update` directly on the host, with the same access a manual operator
  running `setup.sh update` already has -- no container is granted expanded
  Docker-socket or filesystem access to perform it.

**Residual risk**: Medium — the network-facing control-plane path (UI) has no
Docker reach; the risk concentrates in the `services` container, whose
read-write socket mount gives any compromised process in it the full Docker
API.

---

### T7: TLS impersonation of the proxy (HTTPS mode)

**Threat**: An on-path LAN attacker impersonates the cache to a client.

**Likelihood**: Low · **Impact**: High

**Mitigations**:
- HTTPS-mode clients validate the proxy certificate against the locally-installed
  CA; an impostor without the CA key cannot present a trusted cert.
- HTTP mode performs no local TLS termination (SNI passthrough), so this
  vector does not apply there.

**Residual risk**: Low — bounded by client trust of the CA and by the CA key
staying secret (see T8/Assets).

---

### T8: Upstream TLS verification failure (proxy→CDN)

**Threat**: If proxy→origin TLS verification were disabled/misconfigured, an
on-path attacker between proxy and CDN could impersonate the origin and poison
the cache.

**Likelihood**: Low · **Impact**: High

**Mitigations**:
- `proxy_ssl_verify on` with the container's system CA bundle for every HTTPS origin connection; HTTP clients fetch over HTTP.
- Origin names resolve via real upstream DNS, never the spoof DNS (see T1).

**Residual risk**: Medium — verification reduces MITM risk but cannot stop a real
CDN compromise or public-CA misissuance.

---

### T9: Cache-exhaustion / request-flood DoS

**Threat**: A client requests many unique large objects, filling the cache disk
or saturating the proxy.

**Likelihood**: Medium · **Impact**: Medium (degradation / eviction)

**Mitigations**:
- Configurable cache size limits; `proxy_cache_use_stale` keeps serving under
  pressure.
- `PROXY_ALLOWED_CLIENT_CIDRS` can restrict which clients may drive the proxy
  over HTTP/HTTPS, and is now also enforced (via a separate `ngx_stream_
  access_module` check) for the http-mode `stream{}` SNI-passthrough
  listener (`:8443`) and the HTTPS-mode stream-level SNI dispatcher (`:443`),
  so a flood over either stream-level listener is rejected at the TCP level
  before it can reach any relay or backend (see T2).
- Disk-usage warnings/alarms via the watchdog: since issue #870, the
  watchdog-computed cache-disk yellow/red color is rendered live on the
  Admin UI dashboard's "Service health" card (`services/ui/src/main.rs`),
  closing the visibility gap #849 observability finding #3 identified.
  Further alarms (CPU, memory) are shown on the dashboard from the watchdog's
  own checks; there is no separate metrics service.

**Residual risk**: Medium — there is no per-client request rate limiting by
default; the operator must configure limits.

---

### T10: Client connects to HTTPS mode without the CA (expected failure)

**Threat**: A client uses HTTPS mode without installing the CA and downloads fail.

**Likelihood**: High (user error) · **Impact**: Low (fails safe, no compromise)

**Mitigations**:
- Clear per-OS install docs (`docs/README.md`) and, in future, an
  easier distribution path (see that doc's distribution section).
- HTTP mode is the CA-free alternative.
- Devices that *cannot* install a CA (consoles) are intentionally excluded from
  the spoof list, so they never hit this failure — see T4 and the console note in
  `docs/README.md`.

**Residual risk**: Low — intended, safe-failing behaviour.

---

### T11: Console breakage from over-broad DNS spoofing

**Threat**: This threat is specific to **https-mode DNS** (the mode that performs
TLS interception). If console CDN domains were added to the spoof list *and* the
console were pointed at https-mode DNS, the console (which cannot trust the local
CA) would fail the TLS handshake to the proxy — and because the appliance's DNS
would keep returning the proxy IP on every retry, the console could not fall back
to the real CDN. The failure is immediate and obvious (the console cannot reach
that CDN at all), not a silent degradation.

Pointed at **http-mode DNS** instead, the same spoofed domain is harmless for
HTTPS: the unified `services/proxy`'s `ssl_preread`-based SNI passthrough
(`stream{}` block, `:8443` — `services/proxy-standard` was retired and merged
into this single service in the v0.2.0 refactor) forwards the TLS connection
to the real CDN blind, with no interception and no CA
involved, so the console's handshake succeeds normally. Only HTTP traffic for
that domain would be cached — the default, low-impact behavior this appliance is
built around, with no other restriction on the console.

**Likelihood**: Low (requires the operator to add console domains) · **Impact**:
Medium on https-mode DNS (console downloads for that CDN break, though the cause is
immediately obvious); negligible on http-mode DNS (HTTPS passes through
unaffected, only HTTP gets cached).

**Mitigations**:
- Console CDN domains (Xbox/PlayStation/Nintendo) are **deliberately omitted**
  from `cdn-domains.txt`, with an in-file explanation. Consoles keep using the
  appliance as an ordinary, unrestricted DNS resolver; their CDN names resolve to
  the real internet and work normally (no caching benefit, no breakage).
- `docs/README.md` (named in the in-file explanation) lists the
  hosts to *opt in* to Xbox-PC (Game Pass) or Nintendo caching only on a LAN
  known to have no such consoles.

**Residual risk**: Low — safe by default; only an explicit operator opt-in, and
even then only https-mode DNS carries real breakage risk. Opting into Xbox-PC
(Game Pass) caching on a LAN that still has consoles present re-introduces
the risk for that specific CDN.

---

### T12: DHCP control-plane exposure (Kea mode)

**Threat**: In `kea` mode the appliance runs a full DHCP server with
`network_mode: host` and `NET_ADMIN`. Its Kea Control Agent API (port 8000) can
reconfigure DHCP (including the DNS servers handed to every client). Host
networking would otherwise expose that API on all LAN interfaces.

**Likelihood**: Medium (only when Kea mode is enabled) · **Impact**: High
(reprogramming DHCP-issued DNS redirects the whole LAN)

**Mitigations** (verified in `services/watchdog/src/main.rs`):
- `KEA_CTRL_TOKEN` is a shared handshake secret bootstrapped safely (issue #858):
  resolved through the shared-secrets volume so Kea's Control Agent and the Admin
  UI's DHCP API client always agree. A real value wins; an empty or
  known-placeholder one is generated first-writer-wins and shared instead of
  crash-looping, and the container still refuses to run a known-placeholder token
  as fail-closed defense in depth. The Control Agent API requires this token.
- `kea_ctrl_fence` installs **iptables rules that restrict the Control Agent
  port to the ranges in `KEA_CTRL_ALLOW_FROM`** (SOT: the Docker bridge network
  and loopback) and DROP everything else — specifically because host networking
  would otherwise publish it LAN-wide. The managed chain is flushed and refilled
  on every start.
- `DDNS_TSIG_KEY` authenticates Kea→PowerDNS dynamic updates and is a shared
  handshake secret (issue #858): PowerDNS (verifier) and Kea (signer) resolve the
  same key through the shared-secrets volume. **Behavior change:** an empty
  `DDNS_TSIG_KEY` previously meant "TSIG off, DDNS restricted to loopback"; it now
  generates a shared TSIG key so DDNS is TSIG-authenticated end-to-end by default.
  A known-placeholder (`CHANGE_ME*`/`changeme*`) value is normalized to empty
  before resolution and replaced the same way: with a writable shared-secrets
  volume it is **not** rejected — a real key is generated and used, same as an
  empty value. Only if the shared volume is unwritable does resolution fall back
  to empty; PowerDNS then applies the old empty = TSIG-off, loopback-only
  fail-safe, while the supervisor does not start `kea-dhcp-ddns` without a
  resolved `DDNS_TSIG_KEY` (`kea_dhcp_ddns`).

**Residual risk**: Medium — depends on the host's iptables being effective and on
the operator running Kea only where it is the sole DHCP server on the LAN.

---

### T13: DHCP DNS-option spoofing / competing servers (dnsmasq-proxy mode)

**Threat**: In `dnsmasq-proxy` mode the appliance answers the proxy-DHCP portion
alongside an existing DHCP server. A client may accept the wrong DNS option, and
proxy-DHCP DNS options are not reliably honoured by ordinary clients.

**Likelihood**: Medium · **Impact**: Low–Medium (cache bypass, not compromise)

**Mitigations** (verified in `services/watchdog/src/main.rs` (`dnsmasq_conf`,
`dnsmasq`), `services/ui/src/main.rs` (`update_dhcp_proxy`) and
`docs/README.md`):
- Fail-closed configuration: the Admin UI refuses to save without a valid
  `DHCP_SUBNET_START` and `UPSTREAM_DHCP_IP`; a render without a usable subnet
  fails `dnsmasq --test`, and dnsmasq then runs from the newest known-good
  snapshot or does not start.
- The mode is documented as a deliberately limited helper for networks whose
  router DHCP cannot be disabled; the Admin UI's DHCP check probes for competing
  servers and DNS-option override.
- Issue #450 added an optional-option surface (router/NTP/domain/PXE-boot/
  custom options via `dhcp-option-pxe`), documented in `docs/README.md`
  as carrying the exact same limitation as the pre-existing DNS option: all
  of it rides the supplemental ProxyDHCP/PXE exchange, never the ordinary
  client's real lease. A value holding a line break is skipped with a warning
  by `dnsmasq_line`, and custom options that `parse_custom_options` refuses are
  skipped with a warning, rather than silently accepted; the rendered config is
  still validated by
  `dnsmasq --test` before dnsmasq starts, same as every other value here.
- **Update (issue #705):** the threat above assumes dnsmasq actually answers
  PXE-tagged DHCPDISCOVERs. Investigation for #705 found it never did, on
  any install, past or present: dnsmasq's ProxyDHCP mode does not reply to
  *any* DHCPDISCOVER at all unless at least one `pxe-service` directive is
  present in its config, and nothing in this service ever rendered one
  before #705. So the "appliance answers the proxy-DHCP portion" premise
  above only holds once an operator explicitly opts in by setting
  `DHCP_PROXY_PXE_BOOT_SERVER` plus at least one
  `DHCP_PROXY_PXE_BOOT_FILENAME_*` variable (see `docs/README.md`,
  section 5.3). By default (the pre-#705 state, and every
  install that never sets those variables), `dnsmasq-proxy` mode renders no
  `pxe-service` directive, never replies to a DHCPDISCOVER at all, and this
  threat does not apply. Once the operator opts in, the mitigations above
  (fail-closed required values, PXE-scoped-only delivery, `dnsmasq --test`
  validation) resume applying as documented.

**Residual risk**: Medium once PXE boot-pointer opt-in is configured — by
design the upstream DHCP server's DNS option can win, causing cache bypass.
Not a security compromise, but a correctness/coverage limitation the operator
must understand. None while the opt-in variables are left unset (the default):
dnsmasq renders no `pxe-service` directive and never replies to a
DHCPDISCOVER at all, so there is no proxy-DHCP reply for a client to prefer
incorrectly.

---

### T14: Rogue secondary DNS node registration

**Threat**: An attacker registers a forged "secondary" DNS node to receive DNS
updates or obtain the TSIG key.

**Likelihood**: Low · **Impact**: Medium (information disclosure of DNS state; a
copy of all zones)

**Mitigations**:
- `SECONDARY_REGISTRATION_TOKEN` is **fail-closed**: the Admin UI refuses to start
  if it is empty (an empty token would match any registration attempt).
- A registered secondary receives the TSIG key and the primary address; it
  then pulls zones by signed AXFR only (T5). It cannot publish DNS records.
- A secondary can be removed (`DELETE /api/secondary/{name}`) without
  affecting the others; removal renews the TSIG key at once, so the
  removed node can no longer transfer zones. The DNS page can renew it
  any time ("TSIG-Schlüssel erneuern").

**Residual risk**: Low–Medium — bounded by keeping the registration token and
the TSIG key secret.

---

## Out of scope

The following are **not** addressed by lancache-ng:

1. **Internet-facing deployment.** The appliance is not hardened for WAN
   exposure. External DDoS, zero-days, and APTs are out of scope. Exposing any
   control-plane port (UI, Kea API, PowerDNS API) to an untrusted network
   breaks the core assumption.
2. **Inter-client isolation / multi-tenancy.** Any LAN client can receive any
   cached content. There is no per-user separation.
3. **Operator-side privacy in HTTPS mode.** HTTPS mode decrypts client HTTPS by
   design; the operator can see decrypted download traffic. This is the point of
   the feature, not a defect.
4. **Encrypted-response replay across clients.** Content cached under a shared
   key may be served to clients other than the original requester even if the
   original URL carried a per-request signature (intended, has privacy nuance).
5. **Hardware / side-channel attacks** (Spectre, Meltdown, etc.).
6. **Physical access** to the appliance host.
7. **Supply-chain attacks** on base images or dependencies (mitigated only by
   the SOT-owned external image list per
   `docs/combined-release-and-checklist.md` and upstream practices, not by this
   appliance).

---

## Deployment risk tiers

### Low risk
- Private, firewalled LAN; control-plane ports unreachable from untrusted
  segments.
- Admin UI authenticated (`UI_AUTH_USER`/`UI_AUTH_PASSWORD_HASH` set — the default
  posture) or bound to `127.0.0.1`.
- Zone transfers to secondaries only TSIG-signed (default).
- Kea Control Agent reachable only on Docker-internal ranges (default).
- Scheduled automatic updates left disabled (default) unless wanted -- and
  even when enabled, it runs on the host, not as a container with expanded
  socket access.

### Medium risk
- Many untrusted or guest devices on the same flat LAN.
- Proxy left in `lazy` mode with no `PROXY_ALLOWED_CLIENT_CIDRS`.
- No cache-size monitoring or request limits.
- PowerDNS zone transfers (AXFR) reachable by some untrusted segment.

### High risk (breaks the core assumption — avoid)
- Admin UI exposed beyond the LAN, **especially** with `ALLOW_INSECURE_UI=true`.
- Kea API 8000, or the PowerDNS API reachable from untrusted networks.
- Direct Docker socket exposed to untrusted containers/networks.
- No firewall between the appliance and an untrusted uplink.

---

## How to re-audit this document (per release)

This is the repeatable process the currency markers depend on. Run it before
tagging each release, then update the top marker and the
[component currency inventory](#component-currency-inventory).

1. **Diff the architecture since the last reviewed release.** Read `AGENTS.md`'s
   `## Architecture` section (corrected 2026-08-05, issue #1391 doc-sweep audit
   — this used to say `CLAUDE.md`, which moved this content to `AGENTS.md` on
   2026-07-31) and diff the sources listed in the inventory table:
   - `services/watchdog/src/main.rs` (every config render: `pdns_auth`,
     `rpz_zone`, `nginx`, `kea_dhcp4`, `kea_ctrl_fence`, `kea_dhcp_ddns`,
     `dnsmasq_conf`), `services/dns/cdn-domains.txt`,
     `services/ui/nginx/conf.d/*.conf`
   - `services/ui/src/main.rs`
     (`preflight`, `ALLOW_INSECURE_UI`, startup guards)
   - `docs/README.md`
   - the PowerDNS zone-transfer settings (TSIG, NOTIFY, AXFR) rendered by
     `pdns_auth` in `services/watchdog/src/main.rs`
   - `deploy/prod/docker-compose.yml`
     — especially every service that mounts the Docker socket (SOT
     `DOCKER_SOCKET`) and every caller of `DockerApi`.
2. **For each component, confirm the mitigations still match the code** —
   fail-closed guards, allowlists, iptables scoping, credential roles. If a
   mitigation was narrowed, broadened, renamed, or removed, rewrite the affected
   threat. Do **not** only reword.
3. **Check for new components/ports** not yet in this document (a new service, a
   new exposed port, a new external image with socket access) and add threats for
   them.
4. **Re-verify the two things most prone to silent drift:** which services still
   have direct Docker socket access (T6), and whether Admin UI auth is still
   fail-closed by default (T3). These have gone stale before.
5. **Reconcile internal consistency** — the Conclusion and the risk tiers must
   not contradict the individual threats (e.g. never re-introduce
   "unauthenticated by default").
6. **Update** the inventory "Last verified" cells, the top marker, and the review
   date.

---

## Security roadmap (non-binding)

1. Per-client request rate limiting / flood protection in the proxy.
2. Rotate-able TSIG keys for secondaries without re-registration.
3. Audit logging of Admin UI and control-plane operations.
4. Optional content-signature verification for cached objects.
5. Security-event alerts on the Admin UI dashboard (watchdog data).

---

## Conclusion

lancache-ng is designed for **trusted, isolated LAN environments only**. It
deliberately trades some guarantees (it MITMs client HTTPS in HTTPS mode; it trusts
every LAN device) for caching performance, while keeping the *control plane*
fail-closed: the Admin UI, the PowerDNS API key, the Kea Control Agent,
DDNS updates, and secondary registration all refuse to start in an
insecure/unauthenticated state unless the operator explicitly opts out. The Admin UI
has no Docker access; only the `services` container mounts the Docker socket,
read-write, for its watchdog. Scheduled automatic updates run on the host
via `systemd`, not as a container, so they add no socket-access surface.

The operator remains responsible for:
1. Deploying on a trusted, firewalled LAN and keeping control-plane ports off
   untrusted segments.
2. Leaving auth enabled (never `ALLOW_INSECURE_UI=true` on anything reachable).
3. Choosing `strict` proxy mode and client CIDR limits when the LAN is not fully
   trusted.
4. Protecting the local CA private key (`<CA_DIR>/ca.key`) in HTTPS mode.
5. Monitoring disk and activity, and keeping images updated.

For security concerns, use the project's private security reporting channel
(`SECURITY.md`).
