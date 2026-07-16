# lancache-ng Threat Model

> **Last reviewed against release: `v0.2.0`**
> **Last review date: 2026-07-09**
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
| DNS spoofing (PowerDNS RPZ) | `services/dns/entrypoint.sh`, `services/dns/cdn-domains.txt` | v0.2.0 | T1, T4, T11 |
| TLS interception + local CA | `services/proxy/entrypoint.sh`, `services/proxy/conf.d/https.conf` | v0.2.0 | T7, T8, T10 |
| Proxy request policy (client CIDR + host allowlists) | `services/proxy/entrypoint.sh`, `services/proxy/conf.d/http.conf` | v0.2.0 | T2, T9 |
| Admin UI authentication | `services/ui/src/main.rs`, `services/ui/src/config.rs` | v0.2.0 | T3 |
| Docker access mediation (socket-proxy) | `deploy/quickstart/docker-compose.yml` | v0.2.0 | T6 |
| DHCP — Kea mode | `services/dhcp/entrypoint.sh`, `docs/dhcp-modes.md` | v0.2.0 | T12 |
| DHCP — dnsmasq-proxy mode | `services/dhcp-proxy/entrypoint.sh`, `docs/dhcp-modes.md` | v0.2.0 | T12, T13 |
| NATS event bus + role-scoped credentials | `deploy/quickstart/docker-compose.yml` (nats), `services/dns/nats-subscriber/` | v0.2.0 | T5 |
| Secondary-node registration / remote NATS | `deploy/prod/docker-compose.nats-secondary.yml`, `services/ui/src/main.rs` | v0.2.0 | T5, T14 |
| Console exclusion-by-omission | `services/dns/cdn-domains.txt`, `docs/install-ca-cert.md` | v0.2.0 | T4, T10 |

---

## Assets to protect

1. **Cache integrity** — cached content must not be modified or poisoned; a
   poisoned entry is served to every subsequent client.
2. **WAN bandwidth / download speed** — the reason the appliance exists; a
   bypass or DoS that defeats caching degrades the service.
3. **Client trust in the local CA (SSL mode only)** — the CA private key can mint
   certificates every client trusts. Its compromise is the highest-impact event
   in the whole system.
4. **Control-plane integrity** — the Admin UI, PowerDNS API, Kea Control Agent
   API, NATS event bus, and the Docker control path. Anyone who can drive these
   can redirect traffic, poison the cache, or (via Docker) take the host.
5. **Deployment confidentiality** — the appliance must not be reachable from
   untrusted networks.

Note on **client privacy**: in SSL mode the proxy decrypts client HTTPS
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
│  │     SSL-mode MITM cache, standard-     - PowerDNS HTTP API        │ │
│  │     mode SNI passthrough              - Kea Control Agent API     │ │
│  │   - DNS (PowerDNS auth + recursor)      (port 8000, host-net)     │ │
│  │   - DHCP (Kea) OR dnsmasq-proxy       - NATS event bus (4222)     │ │
│  │                                       - docker-socket-proxy       │ │
│  │  Local CA key (SSL mode) lives on       (HAProxy allowlist) ──────┼─┼─► Docker
│  │  host: <install>/certs/ca.key                                    │ │   daemon
│  └──────────────────────────────────────────────────────────────────┘ │
│                                                                        │
│  LAN clients: PCs, Steam Deck, phones (install CA for SSL mode)        │
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
authoritative description — see `CLAUDE.md` and the per-component sources in the
inventory table.

- **DNS spoofing** — PowerDNS (authoritative + recursor + a NATS subscriber) in
  one container. At startup `services/dns/entrypoint.sh` builds an **RPZ zone**
  from `cdn-domains.txt`, pointing each listed CDN hostname (and its wildcards)
  at the proxy IP via A/AAAA records. Everything *not* listed is resolved
  normally by the recursor against real upstream DNS.
- **Two proxy modes** (one nginx container, selected by which DNS IP the client
  uses): **standard mode** reads SNI via `ssl_preread` and forwards HTTPS blind
  to the real CDN (no CA needed); **SSL mode** terminates TLS using a per-domain
  wildcard cert signed by the local CA, caches, then re-fetches from the origin
  over verified TLS.
- **Local CA (SSL mode)** — generated on first start (RSA-4096, 10-year) into
  `<install>/certs/`. `ca.key` is the crown jewel and is gitignored; `ca.crt` is
  a public certificate distributed to clients.
- **Proxy request policy** — `PROXY_SECURITY_MODE` (`lazy` default / `strict`)
  controls whether only listed CDN hosts may be proxied; `PROXY_ALLOWED_CLIENT_CIDRS`
  optionally restricts which client source networks the proxy answers at all
  (returns 403 otherwise).
- **Admin UI** — Rust/axum service. Fail-closed auth (see T3). Reaches Docker
  only through the scoped `docker-socket-proxy`.
- **DHCP** — optional, three mutually-exclusive modes (`disabled` / `kea` /
  `dnsmasq-proxy`) so clients receive the appliance's DNS automatically.
- **NATS event bus** — carries DNS record changes from the Admin UI to the
  PowerDNS node(s), including optional remote **secondary** DNS nodes.

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
- The proxy fetches origins over TLS with `proxy_ssl_verify on` and the Debian CA
  bundle (`proxy_ssl_trusted_certificate`); see also T8.
- Upstream resolution uses `NGINX_UPSTREAM_RESOLVER` (default `8.8.8.8 8.8.4.4 [2001:4860:4860::8888] [2001:4860:4860::8844]`),
  never the LAN spoof DNS — `services/proxy/entrypoint.sh` refuses to start if the
  resolver is set to a lancache DNS/proxy IP, preventing a resolve-to-self loop.
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
- `PROXY_SECURITY_MODE=strict` limits proxied hosts to those in
  `cdn-ssl-domains.txt` (deny-by-default `$cdn_host_allowed` map), removing the
  "proxy anything" behaviour of the default `lazy` mode.
- `PROXY_ALLOWED_CLIENT_CIDRS` optionally restricts which client networks the
  proxy will answer at all (`$lancache_client_allowed` → 403).

**Residual risk**: Medium — `lazy` mode (the default) will proxy any requested
host; strict mode and client CIDR limits are opt-in. Ultimately bounded by the
trusted-LAN assumption.

---

### T3: Unauthorized access to the Admin UI

**Threat**: An attacker reaches the Admin UI and purges the cache, edits domain
lists, switches DHCP mode, or drives the (scoped) Docker control path.

**Likelihood**: Low on a firewalled LAN; High if the UI port is exposed to an
untrusted network · **Impact**: High

**Mitigations** (verified in `services/ui/src/main.rs` / `config.rs`):
- **Authentication is fail-closed by default.** `resolve_admin_ui_auth_mode`
  requires *both* `UI_AUTH_USER` and `UI_AUTH_PASSWORD`. If both are unset the UI
  **refuses to start** unless the operator has *explicitly* set
  `ALLOW_INSECURE_UI=true`. A partial config (only one of the two) is a hard
  startup error. There is no silent unauthenticated default.
- A valid session cookie never substitutes for required Basic auth on protected
  routes (regression-tested).
- Startup also fails closed if `SECONDARY_REGISTRATION_TOKEN` is empty (an empty
  token would authenticate any secondary; see T14).

**Residual risk**: Low, and entirely operator-controlled: it exists only if the
operator sets `ALLOW_INSECURE_UI=true` *and* exposes the UI beyond the trusted
LAN. The quickstart binds the UI to the LAN IP by default and documents
`UI_BIND_IP=127.0.0.1` to restrict it further.

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
  over the authenticated NATS event bus and the PowerDNS API (see T5), not from
  arbitrary clients.
- The PowerDNS API key is a shared handshake secret bootstrapped safely (issue
  #858): `services/dns/entrypoint.sh` resolves `PDNS_API_KEY` through the
  shared-secrets volume so PowerDNS and the Admin UI's PowerDNS REST client
  always agree on the exact same value. A real operator/`setup.sh` value always
  wins; an empty or known-placeholder one is replaced by a generated
  first-writer-wins value shared with the UI instead of crash-looping. The
  entrypoint still refuses to run a known placeholder or a key shorter than 16
  characters as defense in depth.
- RPZ SOA serials are kept monotonic so secondary nodes converge correctly.

**Residual risk**: Low — correct client DNS configuration is the operator's
responsibility. A bypass costs caching, not integrity.

---

### T5: NATS event bus abuse

**Threat**: An untrusted party connects to NATS (4222) and publishes forged DNS
record changes, or subscribes to read cache/DNS metadata.

**Likelihood**: High *if the port is exposed*; otherwise Low · **Impact**: High
(forged DNS records reprogram what the appliance spoofs)

**Mitigations** (verified in `deploy/quickstart/docker-compose.yml`):
- NATS is **not published on the host** in the default deployment — it is only
  reachable on the internal Docker network. This also covers nats-server's own
  HTTP monitor endpoint (`http_port: 8222`, added for the Docker healthcheck
  and Netdata's NATS collector): it carries no credentials of its own
  (nats-server's monitor has no built-in auth), so any container reachable on
  the same internal Docker network can read `/varz`/`/healthz` without a NATS
  role credential — but it is read-only server metadata (version, connection
  counts), not the DNS-record data path itself, and stays unreachable from
  outside the Docker network exactly like the client port.
- Access is **credentialled and role-scoped**, not a single shared account.
  Four static identities exist with least-privilege permissions:
  - **UI writer** — may only `publish` `lancache.dns.record` / `lancache.dns.flush`.
  - **DNS writer** (standard node / reconciler) — publish DNS records + the
    specific JetStream stream/consumer subjects it needs; subscribe to
    `lancache.dns.>`.
  - **DNS replica** (the primary's own co-located dns-ssl container only —
    there is always exactly one) — consume-only JetStream permissions;
    cannot publish DNS records.
  - **Auth-callout responder** (the Admin UI itself) — no subject permissions
    of its own; only recognized by name so its own connection to answer
    `$SYS.REQ.USER.AUTH` doesn't recursively trigger the callout it exists to
    answer.
  All eight of these role credentials are required at startup (`:?` guards) so
  the bus never comes up unauthenticated.
- **Registered secondaries no longer share a credential (issue #583).** Each
  gets its own unique NATS username/password at registration time, issued via
  NATS's auth-callout mechanism (see `services/ui/src/nats_auth_callout.rs`):
  the Admin UI signs a per-connection JWT after checking the presented
  credential's hash against that one secondary's row in its `secondaries`
  table, live, on every single connection attempt. Removing a secondary
  (`DELETE /api/secondary/{name}`) or rotating its credential
  (`POST /api/secondary/{name}/rotate-token`) takes effect on that
  secondary's very next reconnect, with zero effect on any other secondary —
  there is no shared token whose compromise or rotation affects the whole
  fleet, and no static config file to rewrite per secondary.
- Remote/secondary access is opt-in only via
  `deploy/prod/docker-compose.nats-secondary.yml` with `NATS_BIND_IP` bound to a
  trusted LAN/VPN interface, and must be firewalled to that scope.

**Residual risk**: Medium — correct firewalling of the optional secondary
binding is the operator's responsibility, and the role split limits but does not
eliminate what a compromised *writer* credential could do (forge DNS records).
A compromised *secondary* credential is scoped to exactly that one secondary's
consume-only JetStream permissions (same scope the old shared reader role
had) and can be individually revoked without touching any other secondary.

---

### T6: Docker control-path abuse (host takeover)

**Threat**: A compromised container or attacker reaches the Docker API and
creates privileged containers or `exec`s into others, escaping to the host.

**Likelihood**: Medium (a control plane with Docker reach is inherently
sensitive) · **Impact**: Critical (full host compromise)

**Mitigations / actual exposure** (verified in
`deploy/quickstart/docker-compose.yml`):
- The **Admin UI and watchdog do not mount the Docker socket directly.** They
  reach Docker only through `docker-socket-proxy`, a HAProxy instance on an
  `internal` `docker-api` network with a **deny-by-default allowlist**. It permits
  only `_ping`/`version`, `inspect`/`logs`/`restart`/`start`/`stop` on a fixed set
  of named `lancache-*` containers, and **explicitly denies** generic container
  creation and `exec`. A compromised UI therefore cannot obtain a general Docker
  API.
- **However, one other service still holds direct socket access** and remains
  part of this threat's real surface:
  - `netdata` mounts `/var/run/docker.sock` **read-only** (for metrics).
  A compromise of it bypasses the scoped proxy.
- **Scheduled automatic updates (#819) do not add a new socket-access
  surface.** Unlike the removed Watchtower helper (which mounted the socket
  **read-write** in its own container for image updates), the update
  orchestrator runs as a host `systemd` timer/service invoking `setup.sh
  auto-update` directly on the host, with the same access a manual operator
  running `setup.sh update` already has -- no container is granted expanded
  Docker-socket or filesystem access to perform it.

**Residual risk**: Low-Medium — the primary control-plane path (UI) is well
contained; residual risk concentrates in netdata's read-only socket access.
Removing Watchtower (#819) eliminated the one read-write in-container socket
exposure this threat previously had to accept as a real, documented
trade-off.

---

### T7: TLS impersonation of the proxy (SSL mode)

**Threat**: An on-path LAN attacker impersonates the cache to a client.

**Likelihood**: Low · **Impact**: High

**Mitigations**:
- SSL-mode clients validate the proxy certificate against the locally-installed
  CA; an impostor without the CA key cannot present a trusted cert.
- Standard mode performs no local TLS termination (SNI passthrough), so this
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
- `proxy_ssl_verify on` with the Debian CA bundle for all origin connections.
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
- `PROXY_ALLOWED_CLIENT_CIDRS` can restrict which clients may drive the proxy.
- Disk-usage warnings/alarms via the watchdog and Netdata.

**Residual risk**: Medium — there is no per-client request rate limiting by
default; the operator must configure limits and monitor disk.

---

### T10: Client connects to SSL mode without the CA (expected failure)

**Threat**: A client uses SSL mode without installing the CA and downloads fail.

**Likelihood**: High (user error) · **Impact**: Low (fails safe, no compromise)

**Mitigations**:
- Clear per-OS install docs (`docs/install-ca-cert.md`) and, in future, an
  easier distribution path (see that doc's distribution section).
- Standard mode is the CA-free alternative.
- Devices that *cannot* install a CA (consoles) are intentionally excluded from
  the spoof list, so they never hit this failure — see T4 and the console note in
  `docs/install-ca-cert.md`.

**Residual risk**: Low — intended, safe-failing behaviour.

---

### T11: Console breakage from over-broad DNS spoofing

**Threat**: This threat is specific to **ssl-mode DNS** (the mode that performs
TLS interception). If console CDN domains were added to the spoof list *and* the
console were pointed at ssl-mode DNS, the console (which cannot trust the local
CA) would fail the TLS handshake to the proxy — and because the appliance's DNS
would keep returning the proxy IP on every retry, the console could not fall back
to the real CDN. The failure is immediate and obvious (the console cannot reach
that CDN at all), not a silent degradation.

Pointed at **standard-mode DNS** instead, the same spoofed domain is harmless for
HTTPS: `services/proxy-standard`'s `ssl_preread`-based SNI passthrough forwards
the TLS connection to the real CDN blind, with no interception and no CA
involved, so the console's handshake succeeds normally. Only HTTP traffic for
that domain would be cached — the default, low-impact behavior this appliance is
built around, with no other restriction on the console.

**Likelihood**: Low (requires the operator to add console domains) · **Impact**:
Medium on ssl-mode DNS (console downloads for that CDN break, though the cause is
immediately obvious); negligible on standard-mode DNS (HTTPS passes through
unaffected, only HTTP gets cached).

**Mitigations**:
- Console CDN domains (Xbox/PlayStation/Nintendo) are **deliberately omitted**
  from `cdn-domains.txt`, with an in-file explanation. Consoles keep using the
  appliance as an ordinary, unrestricted DNS resolver; their CDN names resolve to
  the real internet and work normally (no caching benefit, no breakage).
- The file documents how to *opt in* to Xbox-PC (Game Pass) caching only on a LAN
  known to have no consoles.

**Residual risk**: Low — safe by default; only an explicit operator opt-in, and
even then only ssl-mode DNS carries real breakage risk.
re-introduces the risk.

---

### T12: DHCP control-plane exposure (Kea mode)

**Threat**: In `kea` mode the appliance runs a full DHCP server with
`network_mode: host` and `NET_ADMIN`. Its Kea Control Agent API (port 8000) can
reconfigure DHCP (including the DNS servers handed to every client). Host
networking would otherwise expose that API on all LAN interfaces.

**Likelihood**: Medium (only when Kea mode is enabled) · **Impact**: High
(reprogramming DHCP-issued DNS redirects the whole LAN)

**Mitigations** (verified in `services/dhcp/entrypoint.sh`):
- `KEA_CTRL_TOKEN` is a shared handshake secret bootstrapped safely (issue #858):
  resolved through the shared-secrets volume so Kea's Control Agent and the Admin
  UI's DHCP API client always agree. A real value wins; an empty or
  known-placeholder one is generated first-writer-wins and shared instead of
  crash-looping, and the container still refuses to run a known-placeholder token
  as fail-closed defense in depth. The Control Agent API requires this token.
- The entrypoint installs **iptables rules that restrict port 8000 to
  Docker-internal ranges** (`172.16.0.0/12`, `127.0.0.0/8`) and DROP everything
  else — specifically because host networking would otherwise publish it LAN-wide.
  The managed chain is idempotent and self-heals across restarts.
- `DDNS_TSIG_KEY` authenticates Kea→PowerDNS dynamic updates and is a shared
  handshake secret (issue #858): PowerDNS (verifier) and Kea (signer) resolve the
  same key through the shared-secrets volume. **Behavior change:** an empty
  `DDNS_TSIG_KEY` previously meant "TSIG off, DDNS restricted to loopback"; it now
  generates a shared TSIG key so DDNS is TSIG-authenticated end-to-end by default.
  A known-placeholder value is still rejected fail-closed, and if the shared
  volume is unwritable the old empty = TSIG-off, loopback-only fail-safe still
  applies.

**Residual risk**: Medium — depends on the host's iptables being effective and on
the operator running Kea only where it is the sole DHCP server on the LAN.

---

### T13: DHCP DNS-option spoofing / competing servers (dnsmasq-proxy mode)

**Threat**: In `dnsmasq-proxy` mode the appliance answers the proxy-DHCP portion
alongside an existing DHCP server. A client may accept the wrong DNS option, and
proxy-DHCP DNS options are not reliably honoured by ordinary clients.

**Likelihood**: Medium · **Impact**: Low–Medium (cache bypass, not compromise)

**Mitigations** (verified in `services/dhcp-proxy/entrypoint.sh`,
`docs/dhcp-modes.md`):
- Fail-closed configuration: `DHCP_SUBNET_START`, `DHCP_DNS_PRIMARY`, and
  `UPSTREAM_DHCP_IP` are all required or the container refuses to start.
- The mode is documented as a deliberately limited helper for networks whose
  router DHCP cannot be disabled; the Admin UI's DHCP check probes for competing
  servers and DNS-option override.
- Issue #450 added an optional-option surface (router/NTP/domain/PXE-boot/
  custom options via `dhcp-option-pxe`), documented in `docs/dhcp-modes.md`
  as carrying the exact same limitation as the pre-existing DNS option: all
  of it rides the supplemental ProxyDHCP/PXE exchange, never the ordinary
  client's real lease. A structurally malformed optional value is skipped
  with a warning by `_dhcp_proxy_render_optional_directives` rather than
  silently accepted; the rendered config is still validated by
  `dnsmasq --test` before dnsmasq starts, same as every other value here.
- **Update (issue #705):** the threat above assumes dnsmasq actually answers
  PXE-tagged DHCPDISCOVERs. Investigation for #705 found it never did, on
  any install, past or present: dnsmasq's ProxyDHCP mode does not reply to
  *any* DHCPDISCOVER at all unless at least one `pxe-service` directive is
  present in its config, and nothing in this service ever rendered one
  before #705. So the "appliance answers the proxy-DHCP portion" premise
  above only holds once an operator explicitly opts in by setting
  `DHCP_PROXY_PXE_BOOT_SERVER` plus at least one
  `DHCP_PROXY_PXE_BOOT_FILENAME_*` variable (see `docs/dhcp-modes.md`'s
  "PXE boot-pointer" section). By default (the pre-#705 state, and every
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
updates or join the NATS mesh.

**Likelihood**: Low · **Impact**: Medium (information disclosure of DNS state; a
foothold in the sync mesh)

**Mitigations**:
- `SECONDARY_REGISTRATION_TOKEN` is **fail-closed**: the Admin UI refuses to start
  if it is empty (an empty token would match any registration attempt).
- Since issue #583, each secondary receives its own individually-revocable
  NATS credential at registration time (T5) instead of a role shared across
  every registered secondary, and reaches NATS only over the operator's
  trusted LAN/VPN interface (`NATS_BIND_IP`).
- A forged registration only grants the consume-only DNS-sync permission
  scope (T5); it cannot publish DNS records, and can be revoked on its own
  (`DELETE /api/secondary/{name}`) without affecting any legitimately
  registered secondary.

**Residual risk**: Low–Medium — bounded by keeping the token secret and the NATS
secondary interface off untrusted networks.

---

## Out of scope

The following are **not** addressed by lancache-ng:

1. **Internet-facing deployment.** The appliance is not hardened for WAN
   exposure. External DDoS, zero-days, and APTs are out of scope. Exposing any
   control-plane port (UI, NATS, Kea API, PowerDNS API) to an untrusted network
   breaks the core assumption.
2. **Inter-client isolation / multi-tenancy.** Any LAN client can receive any
   cached content. There is no per-user separation.
3. **Operator-side privacy in SSL mode.** SSL mode decrypts client HTTPS by
   design; the operator can see decrypted download traffic. This is the point of
   the feature, not a defect.
4. **Encrypted-response replay across clients.** Content cached under a shared
   key may be served to clients other than the original requester even if the
   original URL carried a per-request signature (intended, has privacy nuance).
5. **Hardware / side-channel attacks** (Spectre, Meltdown, etc.).
6. **Physical access** to the appliance host.
7. **Supply-chain attacks** on base images or dependencies (mitigated only by
   digest-pinning external images per `docs/release-versioning.md` and upstream
   practices, not by this appliance).

---

## Deployment risk tiers

### Low risk
- Private, firewalled LAN; control-plane ports unreachable from untrusted
  segments.
- Admin UI authenticated (`UI_AUTH_USER`/`UI_AUTH_PASSWORD` set — the default
  posture) or bound to `127.0.0.1`.
- NATS unpublished (default) or its optional secondary binding firewalled.
- Kea Control Agent reachable only on Docker-internal ranges (default).
- Scheduled automatic updates left disabled (default) unless wanted -- and
  even when enabled, it runs on the host, not as a container with expanded
  socket access.

### Medium risk
- Many untrusted or guest devices on the same flat LAN.
- Proxy left in `lazy` mode with no `PROXY_ALLOWED_CLIENT_CIDRS`.
- No cache-size monitoring or request limits.
- Optional NATS secondary binding reachable by some untrusted segment.

### High risk (breaks the core assumption — avoid)
- Admin UI exposed beyond the LAN, **especially** with `ALLOW_INSECURE_UI=true`.
- NATS 4222, Kea API 8000, or the PowerDNS API reachable from untrusted networks.
- Direct Docker socket exposed to untrusted containers/networks.
- No firewall between the appliance and an untrusted uplink.

---

## How to re-audit this document (per release)

This is the repeatable process the currency markers depend on. Run it before
tagging each release, then update the top marker and the
[component currency inventory](#component-currency-inventory).

1. **Diff the architecture since the last reviewed release.** Read `CLAUDE.md`
   and diff the sources listed in the inventory table:
   - `services/dns/entrypoint.sh`, `services/dns/cdn-domains.txt`
   - `services/proxy/entrypoint.sh`, `services/proxy/conf.d/*.conf`
   - `services/ui/src/config.rs`, `services/ui/src/main.rs`
     (`resolve_admin_ui_auth_mode`, `ALLOW_INSECURE_UI`, startup guards)
   - `services/dhcp/entrypoint.sh`, `services/dhcp-proxy/entrypoint.sh`,
     `docs/dhcp-modes.md`
   - `services/dns/nats-subscriber/`, and the `nats` service block +
     `deploy/prod/docker-compose.nats-secondary.yml`
   - `deploy/quickstart/docker-compose.yml` and `deploy/prod/docker-compose.yml`
     — especially every service that mounts `/var/run/docker.sock` and the
     `docker-socket-proxy` HAProxy ACLs.
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
2. Stronger, rotate-able NATS auth beyond the shared-credential model.
3. Audit logging of Admin UI and control-plane operations.
4. Optional content-signature verification for cached objects.
5. Security-event metrics/alerts via the existing Netdata integration.

---

## Conclusion

lancache-ng is designed for **trusted, isolated LAN environments only**. It
deliberately trades some guarantees (it MITMs client HTTPS in SSL mode; it trusts
every LAN device) for caching performance, while keeping the *control plane*
fail-closed: the Admin UI, NATS credentials, the PowerDNS API key, the Kea Control Agent,
DDNS updates, and secondary registration all refuse to start in an
insecure/unauthenticated state unless the operator explicitly opts out. The Docker control path for the Admin UI
is mediated by a deny-by-default socket proxy, though netdata (read-only)
retains direct socket access. Scheduled automatic updates run on the host
via `systemd`, not as a container, so they add no socket-access surface.

The operator remains responsible for:
1. Deploying on a trusted, firewalled LAN and keeping control-plane ports off
   untrusted segments.
2. Leaving auth enabled (never `ALLOW_INSECURE_UI=true` on anything reachable).
3. Choosing `strict` proxy mode and client CIDR limits when the LAN is not fully
   trusted.
4. Protecting the local CA private key (`<install>/certs/ca.key`) in SSL mode.
5. Monitoring disk and activity, and keeping images updated.

For security concerns, use the project's private security reporting channel
(`SECURITY.md`).
