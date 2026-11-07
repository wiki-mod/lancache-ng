# lancache-ng Threat Model

> **Last reviewed against: `current_dev` at `3005b2b4`**
> **Last review date: 2026-11-07**
> **Latest release tag at review time: `v0.3.2`. It is not contained in
> `current_dev`; this document describes the five-container architecture of
> `current_dev` (see `docs/architecture-ng.md`), not the v0.3.2 images.**
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

## Open gaps found by the 2026-11-07 review

These are places where the code on `current_dev` does not do what this
document used to state, or what `AGENTS.md` / `SECURITY.md` require. Each one
was verified by reading the cited code; none was verified by running a stack.
They are listed here and not described as mitigations. Fixing them is a code
change, not a documentation change.

| ID | Gap | Evidence (`current_dev` `3005b2b4`) | Threat |
|---|---|---|---|
| G1 | The Admin UI is not fail-closed. `setup.sh` and the compose file deliver `UI_AUTH_USER` and `UI_AUTH_PASSWORD_HASH`, but the UI reads `UI_USER` and `UI_PASSWORD_HASH`. With no hash the UI accepts every request and does not refuse to start. `AG-SEC-001` requires fail-closed. | `deploy/prod/docker-compose.yml` lines 343-344 and `setup.sh` (`set_env_key UI_AUTH_PASSWORD_HASH`); `services/ui/src/main.rs` `login_ok` (returns `true` for an empty hash) and `s.text("UI_PASSWORD_HASH")`; no Rust code reads `ALLOW_INSECURE_UI`; the message `Admin-UI authentication is required` exists only in docs | T3 |
| G2 | The Kea Control Agent is reachable on all host interfaces (`dhcp` runs with `network_mode: host`) and its config has no `authentication` block; the UI client sends no credentials. The iptables fence of the old document no longer exists: `KEA_CTRL_ALLOW_FROM` and `KEA_CTRL_CHAIN` appear only in the SOT. | `.github/yaml/build-manifest.yml` (`KEA_CTRL_ADDRESS=@ANY_BIND_IP@`, `ANY_BIND_IP=0.0.0.0`); `services/common/shared.rs` `kea_conf::ctrl_agent`, `kea::Api`; no `iptables` call in `services/` or `setup.sh` | T12 |
| G3 | `AG-OP-002` requires nginx to resolve upstream names with real resolvers, never with the local PowerDNS recursor, because project DNS can route proxied CDN hosts back to the proxy. `NGINX_UPSTREAM_RESOLVER` is rendered without a check that it is not a LanCache address; only `DNS_UPSTREAM_SERVERS` has such a guard. | `services/ui/nginx/nginx.conf` (`resolver ${NGINX_UPSTREAM_RESOLVER}`), `services/common/shared.rs` `recursor_conf::yaml` (the only "would loop" guard) | T1 |
| G4 | `SECURITY.md` says only the `services` container mounts the Docker socket. The compose file also mounts it into `ui`. | `SECURITY.md` line 107; `deploy/prod/docker-compose.yml` lines 130 and 361 | T6 |

---

## Component currency inventory

A reviewer can use this table to see, at a glance, which parts of the system
this document was last checked against. When a component's implementation
changes, update its row (and the threats that reference it) and set "Last
verified" to the release or commit that was read. A row that lags the marker at
the top is a signal that its threats need re-checking.

| Component | Primary source of truth | Last verified | Threats |
|---|---|---|---|
| DNS spoofing (PowerDNS RPZ) | `services/common/shared.rs` (`recursor_conf::rpz`, `recursor_conf::yaml`, `pdns_conf::auth`), `services/dns/cdn-domains.txt` | `current_dev` `3005b2b4` | T1, T4, T11 |
| TLS interception + local CA | `services/common/shared.rs` (`cert::make_ca`, `cert::make_leaf`, `render::issue_certs`, `nginx_conf`), `services/ui/nginx/conf.d/https.conf` | `current_dev` `3005b2b4` | T7, T8, T10 |
| Proxy request policy (client CIDR + host allowlists) | `services/common/shared.rs` (`nginx_conf`), `services/ui/nginx/proxy-params.conf`, `services/ui/nginx/conf.d/*.conf` | `current_dev` `3005b2b4` | T2, T9 |
| Admin UI authentication | `services/ui/src/main.rs` (`login_ok`, `auth`, `Csrf`), `deploy/prod/docker-compose.yml`, `setup.sh` | `current_dev` `3005b2b4` (gap G1) | T3 |
| Docker access (socket in `services` and `ui`) | `deploy/prod/docker-compose.yml`, `services/common/shared.rs` (`docker::Api`) | `current_dev` `3005b2b4` | T6 |
| DHCP: Kea mode | `services/common/shared.rs` (`kea_conf`, `kea::Api`), `deploy/prod/docker-compose.yml` (`dhcp`), `docs/dhcp-modes.md` | `current_dev` `3005b2b4` (gap G2) | T12 |
| DHCP: dnsmasq-proxy and dnsmasq-relay modes | `services/common/shared.rs` (`dnsmasq_conf`), `docs/dhcp-modes.md` | `current_dev` `3005b2b4` | T12, T13 |
| Zone transfer to secondaries (TSIG, NOTIFY, AXFR) | `services/common/shared.rs` (`pdns_conf::auth`), `services/ui/src/main.rs` (`rotate_tsig`, `TSIG-ALLOW-AXFR`, `AXFR-MASTER-TSIG`) | `current_dev` `3005b2b4` | T5 |
| Secondary-node registration | `services/ui/src/main.rs` (`register`, `registration_token`, `secondary_action`), `deploy/secondary/docker-compose.yml` | `current_dev` `3005b2b4` | T5, T14 |
| Console exclusion-by-omission | `services/dns/cdn-domains.txt`, `docs/install-ca-cert.md` | `current_dev` `3005b2b4` | T4, T10 |
| Zone/record known-good snapshot + rollback | `services/ui/src/main.rs` (`rollback`, `zone_snapshots_cli`, route `/domains/zone-rollback`), `docs/known-good-config-snapshots.md` | `current_dev` `3005b2b4` | T4 |

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
│  │  - proxy (nginx): HTTP cache,        - Admin UI (`ui`, Docker)    │ │
│  │    HTTPS-mode MITM cache, HTTP-      - PowerDNS HTTP API          │ │
│  │    mode SNI passthrough              - Kea Control Agent API      │ │
│  │  - DNS (PowerDNS auth + recursor)      (port 8000, host-net, G2)  │ │
│  │  - DHCP (Kea) OR dnsmasq             - watchdog in `services`     │ │
│  │                                        (Docker socket)            │ │
│  │                                                                   │ │
│  │  Local CA key (HTTPS mode) lives on host: <CA_DIR>/ca.key         │ │
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
authoritative description: see `docs/architecture-ng.md` and the per-component
sources in the inventory table.

- **Containers** — exactly five: `services` (watchdog, cachehamster, syslog-ng,
  chronyd, snmpd), `proxy` (nginx), `dns` (PowerDNS auth and two recursors),
  `dhcp` (Kea or dnsmasq, selected by `DHCP_MODE`) and `ui`. Inside a
  container OpenRC keeps the programs alive; the watchdog in `services`
  restarts a sick container through the Docker API.
- **Who writes configs** — the `ui` renders every config from the SOT
  (`.github/yaml/build-manifest.yml`) and the saved settings (`render::all` in
  `services/common/shared.rs`), writes the changed files into the
  `lancache-config` volume and wakes only the affected owner containers (reload
  or restart through the Docker API, `apply::plan`). The owner containers mount
  that volume read-only. The watchdog never writes configs.
- **DNS spoofing** — PowerDNS (authoritative + recursor) in the `dns`
  container. The `ui` builds an **RPZ zone** from `cdn-domains.txt`
  (`recursor_conf::rpz`) that points each listed CDN hostname (and its
  wildcards) at the proxy IP via A/AAAA records. Everything *not* listed is
  resolved normally by the recursor. An optional upstream resolver
  (`DNS_UPSTREAM_SERVERS`, `DNS_UPSTREAM_ZONES`) can take names outside the
  LAN zones; DNSSEC validation stays on except for zones the operator lists in
  `DNS_UPSTREAM_UNSIGNED_ZONES`.
- **Two proxy modes** (one nginx container, selected by which DNS IP the client
  uses): **HTTP mode** reads SNI via `ssl_preread` and forwards HTTPS blind
  to the real CDN (no CA needed); **HTTPS mode** terminates TLS using a per-domain
  wildcard cert signed by the local CA, caches, then re-fetches from the origin
  over verified TLS.
- **Local CA (HTTPS mode)** — created by the `ui` (`cert::make_ca`;
  `CA_KEY_TYPE=rsa:4096`, `CA_DAYS=3650`, key file mode `0600`) in the CA state
  directory (`CA_DIR`). `ca.key` is the crown jewel and stays outside the
  checkout; `ca.crt` is a public certificate distributed to clients.
- **Proxy request policy** — `PROXY_SECURITY_MODE` (`lazy` default, `strict`
  opt-in, `AG-OP-003`) controls whether only listed CDN hosts may be proxied; `PROXY_ALLOWED_CLIENT_CIDRS`
  restricts which client source networks the proxy answers at all (default: the
  private networks and `fc00::/7`). For HTTP/HTTPS traffic this is an
  `http{}`/`https{}` control (returns 403 otherwise, `proxy-params.conf`). The
  stream-level SNI listeners (HTTP-mode passthrough and the HTTPS-mode
  dispatcher) enforce the domain allowlist differently (an unlisted SNI goes to
  a closed backend, not a 403) and enforce the client list through generated
  `allow`/`deny` directives (`nginx_conf`), a TCP-level accept/reject before
  `ssl_preread`; the `$lancache_client_allowed` geo variable is http-context
  only — see T2.
- **Admin UI** — Rust web service (`ui`). It saves settings, renders configs,
  and holds the Docker socket to wake owner containers and to read container
  state (see T3 for authentication and T6 for Docker access).
- **DHCP** — optional, mutually-exclusive modes (`off` / `kea` /
  `dnsmasq-proxy` / `dnsmasq-relay`) in the one `dhcp` container; the `ui`
  writes the mode file and OpenRC starts only that mode's programs, so clients
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
- The proxy fetches HTTPS origins over TLS with `proxy_ssl_verify on` and the
  container's system CA bundle (`proxy_ssl_trusted_certificate
  /etc/ssl/certs/ca-certificates.crt`, `services/ui/nginx/proxy-params.conf`);
  see also T8.
- Upstream resolution uses `NGINX_UPSTREAM_RESOLVER` (default `8.8.8.8 8.8.4.4`,
  `ipv6=off`, `services/ui/nginx/nginx.conf`), not the LAN spoof DNS. There is
  **no check** that the configured resolver is not a LanCache address (gap G3);
  an operator who sets it to the appliance's own DNS creates a resolve-to-self
  loop.
- Cache key is `$host$uri$slice_range` (never `$request_uri`, `AG-OP-001`), so
  query-string signatures do not create separate cache objects and a
  per-request signature cannot be used to smuggle a distinct poisoned object
  under a shared key without also passing origin validation.

**Residual risk**: Medium — a genuine CDN compromise or trusted-CA misissuance is
outside the appliance's control.

---

### T2: LAN client poisons the cache

**Threat**: A compromised or rogue LAN device sends crafted requests to trick the
proxy into caching attacker-controlled content under a legitimate key.

**Likelihood**: Medium · **Impact**: High (poison served to all clients)

**Mitigations**:
- Cache key includes the `Host` header (`$host$uri$slice_range`); responses are
  only cached after the origin fetch succeeds over verified TLS.
- The proxy mode is a deliberate design choice (`AG-OP-003`): **lazy is the
  mandated default** (cache-first: nginx takes the upstream destination from the
  client `Host` or `$ssl_server_name`, `AG-KD-004`, so any host a client reaches
  the cache for is proxied and new CDN hostnames work out of the box); **strict requires an
  explicit operator opt-in** from an operator who accepts its tighter allowlist
  and its maintenance burden. Strict limits proxied hosts to those derived from
  `cdn-domains.txt` (deny-by-default `$cdn_host_allowed` map, rooted via the
  vendored Public Suffix List; see `Psl` and `nginx_conf::hosts` in
  `services/common/shared.rs`) and answers others with HTTP 403 in the
  `http{}`/`https{}` `location /` blocks; the stream-level SNI listeners
  enforce the same domain list differently — an unlisted SNI is routed to a
  closed backend, not a 403. It breaks downloads until a missing CDN hostname is
  added to `cdn-domains.txt` (`README.md`, `PROXY_SECURITY_MODE`), so it is a
  trade-off, not a fix.
- `PROXY_ALLOWED_CLIENT_CIDRS` restricts which client networks the proxy will
  answer at all. Its default is the private networks and `fc00::/7`
  (`.github/yaml/build-manifest.yml`). For HTTP/HTTPS traffic
  `$lancache_client_allowed` returns 403; the externally-facing stream-level
  SNI listeners enforce the same list independently with generated `allow` /
  `deny all` directives (`nginx_conf`), a TCP-level accept/reject ahead of
  `ssl_preread`, so a denied connection is refused before any TLS handshake.

**Residual risk**: Medium — poisoning needs a device that is allowed to reach the
cache; the client list (`PROXY_ALLOWED_CLIENT_CIDRS`) is the control that
limits that set. The default `lazy` mode is the intended cache-first behavior
(`AG-OP-003`), not a defect; an operator with untrusted devices on the LAN
narrows the client list first and chooses `strict` only if the allowlist
maintenance is acceptable. Ultimately bounded by the trusted-LAN assumption.

---

### T3: Unauthorized access to the Admin UI

**Threat**: An attacker reaches the Admin UI and purges the cache, edits domain
lists, switches DHCP mode, or sets a desired service state that stops or runs
the DHCP or NTP process. Because the UI also holds the Docker socket (T6), full
control of the UI is full control of the host.

**Likelihood**: Low on a firewalled LAN; High if the UI port is exposed to an
untrusted network · **Impact**: Critical

**Required design** (`AG-SEC-001`): the `ui` fails closed and may restart-loop
when neither `UI_AUTH_USER` with its password hash nor `ALLOW_INSECURE_UI=true`
is configured.

**State in the code** (`services/ui/src/main.rs`, `current_dev` `3005b2b4`):
- **The required fail-closed behaviour is not implemented (gap G1).**
  `login_ok` accepts every request when `UI_PASSWORD_HASH` is empty, no start
  check refuses an empty hash, and no Rust code reads `ALLOW_INSECURE_UI`.
  `setup.sh` and the compose file deliver the credentials as `UI_AUTH_USER` /
  `UI_AUTH_PASSWORD_HASH`, which the UI does not read. Until this is fixed, do
  not rely on the Admin UI login.
- When a hash is set, HTTP Basic credentials are checked with Argon2id and a
  constant-time user compare (`secret::equal`).
- Every state-changing request needs a CSRF token bound to the session
  (`Csrf::check`, `Csrf::check_header`); the session cookie is `HttpOnly` and
  `SameSite=Strict`.
- A password changed on the Setup page needs the old password and at least
  `UI_PASSWORD_MIN_LENGTH` characters (default 12, allowed 8 to 128); only the
  Argon2id hash is stored, in the UI settings file in the `ui-data` volume.
- The registration route for secondaries has its own token (T14).

**Residual risk**: High while G1 is open: the UI is unauthenticated by default
on whatever address `UI_BIND_IP` selects (`IP_HTTP` by default,
`deploy/prod/docker-compose.yml`). With G1 fixed it drops to Low and entirely
operator-controlled: it exists only if the operator sets `ALLOW_INSECURE_UI=true`
*and* exposes the UI beyond the trusted LAN. `UI_BIND_IP=127.0.0.1` restricts it
further.

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
  validated before being written into the RPZ zone (`dns::cdn_entry`,
  `recursor_conf::rpz`). DNS record changes flow only through the
  PowerDNS API (`X-API-Key`) and TSIG-signed zone transfers (see T5), not from
  arbitrary clients.
- **Zone/record rollback**: known-good snapshots are listed and restored by the
  `ui` (`rollback`; route `/domains/zone-rollback` behind the UI
  authentication and CSRF check, and the CLI `lancache-ui zone-snapshots` /
  `zone-rollback`). Rollback is always operator-selected, never automatic on
  startup. It is therefore only as protected as the Admin UI itself (T3).
- The PowerDNS API key is a shared secret resolved by `secret::resolve`: the
  operator's value wins; an empty or template-like value
  (`secret::is_placeholder`) is replaced by a generated value stored in the
  shared secret file, first writer wins, so PowerDNS and the UI always agree.
- RPZ SOA serials are kept monotonic so secondary nodes converge correctly
  (`dns::serial_cmp`).

**Residual risk**: Low — correct client DNS configuration is the operator's
responsibility. A bypass costs caching, not integrity.

---

### T5: DNS zone-transfer abuse (primary → secondary)

**Threat**: An untrusted party pulls zone data from the primary (AXFR), or
pushes forged NOTIFY/updates to make a secondary load wrong DNS data.

**Likelihood**: Low · **Impact**: Medium (DNS state disclosure; wrong records
on a secondary until the next good transfer)

**Mitigations**:
- Secondaries replicate with native PowerDNS NOTIFY + AXFR. `pdns_conf::auth`
  allows AXFR by TSIG, not by IP list; `allow-axfr-ips` holds only the optional
  `PDNS_AXFR_FROM` hosts (empty by default). The UI sets the per-zone TSIG
  metadata (`TSIG-ALLOW-AXFR` on the primary, `AXFR-MASTER-TSIG` on a
  secondary), so a secondary without the key gets nothing.
- The TSIG key reaches a secondary only through the token-checked registration
  answer (`register`, see T14).
- Record changes are written only by the Admin UI through the PowerDNS API
  (`X-API-Key`); secondaries never publish records.
- SOA serials are monotonic (RFC 1982); the watchdog (`dns_sync`) and the DNS
  page (`secondary_health`) show a lagging secondary (lost NOTIFY or broken
  AXFR).

**Residual risk**: Low — bounded by keeping the TSIG secret and the
registration token secret. Removing a secondary calls `rotate_tsig`.

---


### T6: Docker control-path abuse (host takeover)

**Threat**: A compromised container or attacker reaches the Docker API and
creates privileged containers or `exec`s into others, escaping to the host.

**Likelihood**: Medium (a control plane with Docker reach is inherently
sensitive) · **Impact**: Critical (full host compromise)

**Actual exposure** (verified in `deploy/prod/docker-compose.yml` and
`services/common/shared.rs`):
- **Two containers mount the Docker socket read-write, with no socket proxy:
  `services` (compose line 130) and `ui` (compose line 361).** The `ui`
  mounts it "for apply and the overview": it wakes owner containers after it
  writes configs and reads container state. The watchdog in `services` reads
  container health and restarts sick containers.
- The shared client (`docker::Api`) can list the compose project, inspect,
  read stats, `exec` in a container, and start, stop, restart or HUP a
  container. The mounted socket itself grants the full Docker API, so a
  compromise of either container is a host compromise.
- Reaching the `ui` through the network therefore reaches Docker; this makes
  the Admin UI authentication (T3, gap G1) part of this threat. The earlier
  statement that the Admin UI has no Docker access is no longer true.
- **Scheduled automatic updates do not add a socket-access surface.** They run
  on the host as a `systemd` timer or, on Alpine hosts without systemd, an
  OpenRC loop service invoking `setup.sh` (`AUTO_UPDATE_ENABLED=0` by default).
  No container is granted expanded Docker or filesystem access to perform them.

**Residual risk**: High — both the UI (network-facing) and `services` hold a
read-write socket mount; the risk is concentrated in the Admin UI, whose
authentication has gap G1. `SECURITY.md` still says only `services` mounts the
socket (gap G4).

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
- `PROXY_ALLOWED_CLIENT_CIDRS` (default: private networks and `fc00::/7`)
  restricts which clients may drive the proxy over HTTP/HTTPS, and is also
  enforced by the stream-level listeners through generated `allow` / `deny all`
  directives, so a flood over either stream-level listener is rejected at the
  TCP level before it can reach any relay or backend (see T2).
- Disk-usage warnings/alarms: the watchdog checks the free space of the cache
  (`DISK_WARN_PCT`, `DISK_ALARM_PCT`) each round and writes the alarm file the
  Admin UI dashboard shows. Further alarms (CPU, memory) come from the same
  checks and from SNMP; there is no separate metrics service.

**Residual risk**: Medium — there is no per-client request rate limiting by
default; the operator must configure limits.

---

### T10: Client connects to HTTPS mode without the CA (expected failure)

**Threat**: A client uses HTTPS mode without installing the CA and downloads fail.

**Likelihood**: High (user error) · **Impact**: Low (fails safe, no compromise)

**Mitigations**:
- Clear per-OS install docs (`docs/install-ca-cert.md`) and, in future, an
  easier distribution path (see that doc's distribution section).
- HTTP mode is the CA-free alternative.
- Devices that *cannot* install a CA (consoles) are intentionally excluded from
  the spoof list, so they never hit this failure — see T4 and the console note in
  `docs/install-ca-cert.md`.

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
- `docs/install-ca-cert.md` (named in the in-file explanation) lists the
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
networking publishes that API on every host interface unless something fences it.

**Likelihood**: Medium (only when Kea mode is enabled) · **Impact**: High
(reprogramming DHCP-issued DNS redirects the whole LAN)

**State in the code** (`services/common/shared.rs`, `current_dev` `3005b2b4`):
- **The Control Agent is bound to `KEA_CTRL_ADDRESS`, whose SOT default is
  `0.0.0.0`, with no `authentication` block (`kea_conf::ctrl_agent`), and the
  UI's client (`kea::Api`) sends no credentials (gap G2).** `KEA_CTRL_TOKEN`
  is delivered to the containers but nothing in the Kea configuration checks it.
- **The iptables fence of the old design is gone.** `KEA_CTRL_ALLOW_FROM` and
  `KEA_CTRL_CHAIN` exist only in the SOT; no code applies firewall rules. Do not
  rely on host networking being fenced.
- `kea_conf::ddns` signs the Kea→PowerDNS dynamic updates with TSIG
  (`DDNS_TSIG_KEY`, algorithm `DDNS_TSIG_ALGORITHM`); the key is a shared secret
  resolved by `secret::resolve` like the PowerDNS API key (T4): an empty or
  template-like value is replaced by a generated one, so DDNS is
  TSIG-authenticated end to end by default.

**Residual risk**: High while G2 is open: any host on any network segment that
can reach port 8000 of the appliance while Kea mode is on can drive the DHCP
configuration. Medium after a fence or authentication exists, and always
dependent on the operator running Kea only where it is the sole DHCP server on
the LAN.

---

### T13: DHCP DNS-option spoofing / competing servers (dnsmasq-proxy mode)

**Threat**: In `dnsmasq-proxy` mode the appliance answers the proxy-DHCP portion
alongside an existing DHCP server. A client may accept the wrong DNS option, and
proxy-DHCP DNS options are not reliably honoured by ordinary clients.

**Likelihood**: Medium · **Impact**: Low–Medium (cache bypass, not compromise)

**Mitigations** (verified in `services/common/shared.rs` `dnsmasq_conf` and
`docs/dhcp-modes.md`):
- A render with a bad value fails instead of producing a config
  (`dnsmasq_conf::render` returns an error; `render::all` returns the errors
  instead of files).
- The mode is documented as a deliberately limited helper for networks whose
  router DHCP cannot be disabled; the Admin UI's DHCP check probes for competing
  servers and DNS-option override (`dhcp_probe`).
- The optional-option surface (router/NTP/domain/PXE-boot/custom options via
  `dhcp-option-pxe`) is documented in `docs/dhcp-modes.md` as carrying the same
  limitation as the DNS option: all of it rides the supplemental ProxyDHCP/PXE
  exchange, never the ordinary client's real lease.
- dnsmasq's ProxyDHCP mode does not reply to *any* DHCPDISCOVER unless at least
  one `pxe-service` directive is present. `dnsmasq_conf::pxe` renders those
  only when the operator sets `DHCP_PROXY_PXE_BOOT_SERVER` plus a boot filename
  (see `docs/dhcp-modes.md`, "PXE boot-pointer"). By default `dnsmasq-proxy`
  mode never replies to a DHCPDISCOVER and this threat does not apply.

**Residual risk**: Medium once the PXE boot-pointer opt-in is configured — by
design the upstream DHCP server's DNS option can win, causing cache bypass. Not
a security compromise, but a correctness/coverage limitation the operator must
understand. None while the opt-in variables are left unset (the default).

---

### T14: Rogue secondary DNS node registration

**Threat**: An attacker registers a forged "secondary" DNS node to receive DNS
updates or obtain the TSIG key.

**Likelihood**: Low · **Impact**: Medium (information disclosure of DNS state; a
copy of all zones)

**Mitigations**:
- The registration route is public but checks the registration token with a
  constant-time compare (`register`, `secret::equal`): a wrong token gets
  `401`, and when no token can be read or created the route answers `503`
  (`registration_token`). The token is a generated 64-hex-digit secret
  (`SECONDARY_REGISTRATION_TOKEN`); the UI can renew it (`renew_token`, action
  `rotate`).
- A registered secondary receives the TSIG key and the primary address; it
  then pulls zones by signed AXFR only (T5). It cannot publish DNS records.
- A secondary can be removed (`/api/secondary/{name}/remove`, behind the UI
  authentication and CSRF header check) without affecting the others; removal
  calls `rotate_tsig` at once, so the removed node's key stops working.

**Residual risk**: Low–Medium — bounded by keeping the registration token and
the TSIG key secret, and by the Admin UI authentication (T3, gap G1) for the
remove and rotate actions. The bootstrap authorization is one shared token, not
a one-time token bound to one secondary.

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
7. **Supply-chain attacks** on base images or dependencies (not addressed by
   this appliance; the project only resolves its own images by channel digest,
   see `docs/release-versioning.md`).

---

## Deployment risk tiers

### Low risk
- Private, firewalled LAN; control-plane ports unreachable from untrusted
  segments.
- Admin UI authenticated, or bound to `127.0.0.1`. With gap G1 open the
  authentication has to be verified by the operator; do not assume it.
- Zone transfers to secondaries only TSIG-signed (default).
- Kea mode off, or Kea Control Agent port 8000 blocked by the host firewall
  (gap G2: the appliance does not fence it).
- Scheduled automatic updates left disabled (default) unless wanted — and even
  when enabled, they run on the host, not as a container with expanded socket
  access.

### Medium risk
- Many untrusted or guest devices on the same flat LAN.
- A client list wider than the devices that should use the cache (the default
  is the private networks and `fc00::/7`).
- No cache-size monitoring or request limits.
- PowerDNS zone transfers (AXFR) reachable by some untrusted segment.

### High risk (breaks the core assumption — avoid)
- Admin UI exposed beyond the LAN, **especially** with `ALLOW_INSECURE_UI=true`
  or while gap G1 is open.
- Kea API 8000, or the PowerDNS API reachable from untrusted networks.
- Direct Docker socket exposed to untrusted containers/networks.
- No firewall between the appliance and an untrusted uplink.

---

## How to re-audit this document (per release)

This is the repeatable process the currency markers depend on. Run it before
tagging each release, then update the top marker and the
[component currency inventory](#component-currency-inventory).

1. **Diff the architecture since the last reviewed release.** Read
   `docs/architecture-ng.md` and diff the sources listed in the inventory table:
   - `services/common/shared.rs`: every config render (`recursor_conf`,
     `pdns_conf`, `nginx_conf`, `kea_conf`, `dnsmasq_conf`), `cert`, `secret`,
     `docker`, `render` and `apply`
   - `services/ui/src/main.rs` (`login_ok`, `auth`, `Csrf`, `register`,
     `secondary_action`, `rollback`, startup guards) and `services/watchdog/src/main.rs`
   - `services/dns/cdn-domains.txt`, `services/ui/nginx/**`
   - `docs/dhcp-modes.md`
   - `deploy/prod/docker-compose.yml`: every service that mounts the Docker
     socket (SOT `DOCKER_SOCKET`; today `services` **and** `ui`) and every
     caller of `docker::Api`
   - the security-relevant defaults in `.github/yaml/build-manifest.yml`
     (`PROXY_ALLOWED_CLIENT_CIDRS`, `PROXY_SECURITY_MODE`, `KEA_CTRL_*`,
     `CA_*`, `UI_PASSWORD_MIN_LENGTH`, `AUTO_UPDATE_*`).
2. **For each component, confirm the mitigations still match the code** —
   fail-closed guards, allowlists, firewall rules, credential roles. Search for
   every function, variable and route name this document cites; a name with no
   hit is a stale claim. If a mitigation was narrowed, broadened, renamed, or
   removed, rewrite the affected threat. Do **not** only reword.
3. **Check for new components/ports** not yet in this document (a new service, a
   new exposed port, a new external image with socket access) and add threats for
   them.
4. **Re-verify the two things most prone to silent drift:** which containers
   still have direct Docker socket access (T6), and whether Admin UI auth is
   still fail-closed by default (T3, `AG-SEC-001`). These have gone stale before.
5. **Reconcile internal consistency** — the Conclusion and the risk tiers must
   not contradict the individual threats, and every gap in "Open gaps" must
   either still be open in the code or be removed.
6. **Update** the inventory "Last verified" cells, the top marker, and the
   review date.

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
every LAN device) for caching performance. The design goal is a fail-closed
*control plane*: the Admin UI, the PowerDNS API key, the Kea Control Agent,
DDNS updates, and secondary registration should refuse to start or answer in an
insecure/unauthenticated state unless the operator explicitly opts out.

At the 2026-11-07 review that goal is met for the PowerDNS API key, DDNS
updates (TSIG) and secondary registration, and **not met for the Admin UI
login (G1) and the Kea Control Agent (G2)**; see "Open gaps found by the
2026-11-07 review". Both the `ui` and `services` containers mount the Docker
socket read-write (T6), so the Admin UI is the most sensitive network-facing
component. Scheduled automatic updates run on the host via `systemd` or an
OpenRC service, not as a container, so they add no socket-access surface.

The operator remains responsible for:
1. Deploying on a trusted, firewalled LAN and keeping control-plane ports off
   untrusted segments.
2. Verifying that the Admin UI login is enforced. `ALLOW_INSECURE_UI=true` is a
   valid explicit choice for an intentionally unauthenticated UI on a trusted
   LAN (`AG-SEC-001`), but not on anything reachable from an untrusted network.
3. Narrowing `PROXY_ALLOWED_CLIENT_CIDRS` when the LAN is not fully trusted;
   `strict` proxy mode is an opt-in that accepts a maintained allowlist
   (`AG-OP-003`).
4. Protecting the local CA private key (`<CA_DIR>/ca.key`) in HTTPS mode.
5. Blocking Kea Control Agent port 8000 at the host firewall while Kea mode is
   on, until G2 is closed.
6. Monitoring disk and activity, and keeping images updated.

For security concerns, use the project's private security reporting channel
(`SECURITY.md`).
