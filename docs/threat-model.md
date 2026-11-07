# lancache-ng Threat Model

> **Last reviewed against: `current_dev` at `3005b2b4` and the code of pull
> request #1985 at `9a4b4be4`**
> **Last review date: 2026-11-07**
> **Latest release tag at review time: `v0.3.2`. It is not contained in
> `current_dev`; this document describes the five-container architecture of
> `current_dev` (see `docs/architecture-ng.md`), not the v0.3.2 images.**

This document outlines the security threats that lancache-ng is designed to
protect against, the mitigations that actually exist in the current codebase,
and the risks that are explicitly out of scope.

lancache-ng is a **trusted-LAN appliance**. It intercepts and caches
game/software downloads for devices on a local network, optionally decrypting
HTTPS via a locally-trusted CA. Its entire security model assumes the LAN is
trusted; it is **not** hardened for internet exposure. Everything below is
framed against that assumption.

---

## Security-relevant limits of the current code

The statements in this document come from reading the code, its callers,
defaults and alternate paths; no running stack exercised the Admin UI login,
the Kea Control Agent or the nginx resolver check (`AG-INT-001`). The
identifiers G1 to G3 are stable references used by code comments.

| ID | Topic | State in the code (#1985 `9a4b4be4`) | Threat |
|---|---|---|---|
| G1 | Admin UI login | The compose file passes `UI_AUTH_USER` and `UI_AUTH_PASSWORD_HASH` to the UI as `UI_USER` and `UI_PASSWORD_HASH` (`deploy/prod/docker-compose.yml`). An unauthenticated Admin UI is an explicit choice made in the setup flow with a default of open (`ALLOW_INSECURE_UI=true` in the SOT runtime defaults): `setup.sh` asks "Protect Admin-UI with password? [y/N]" (default No) and, on No, "Allow Admin-UI without authentication?" (default from the SOT value); answering No to both repeats the question. An update appends `ALLOW_INSECURE_UI=true` to an install that has no login, so the open state is an explicit entry in `.env`. `AG-SEC-001` allows this as an explicit operator choice, including trusted LAN deployments. The `ui` process does not read `ALLOW_INSECURE_UI`, and `login_ok` accepts every request when the hash is empty, so the refusal that `AG-SEC-001` describes for "neither credentials nor `ALLOW_INSECURE_UI=true`" exists only in the setup flow. | T3 |
| G2 | Kea Control Agent | `kea_conf::ctrl_agent` writes a basic `authentication` block (user `KEA_CTRL_USER`, password `KEA_CTRL_TOKEN`) and `kea::Api` sends them. The bind address is `KEA_CTRL_ADDRESS=@ANY_BIND_IP@` (`0.0.0.0`) on the host network. `KEA_CTRL_ALLOW_FROM` and `KEA_CTRL_CHAIN` exist only in the SOT; no code applies a firewall fence. | T12 |
| G3 | nginx upstream resolver | `AG-OP-002` requires real upstream resolvers for nginx. `render::nginx_files` and the UI save path check every `NGINX_UPSTREAM_RESOLVER` entry with `recursor_conf::upstream_entry` (numeric address only; loopback, unspecified and this host's own addresses are refused as "would loop"). | T1 |

---

## Component currency inventory

The table names the source of each component and the commit it was read against.

| Component | Primary source of truth | Last verified | Threats |
|---|---|---|---|
| DNS spoofing (PowerDNS RPZ) | `services/common/shared.rs` (`recursor_conf::rpz`, `recursor_conf::yaml`, `pdns_conf::auth`), `services/dns/cdn-domains.txt` | `current_dev` `3005b2b4` | T1, T4, T11 |
| TLS interception + local CA | `services/common/shared.rs` (`cert::make_ca`, `cert::make_leaf`, `render::issue_certs`, `nginx_conf`), `services/ui/nginx/conf.d/https.conf` | `current_dev` `3005b2b4` | T7, T8, T10 |
| Proxy request policy (client CIDR + host allowlists) | `services/common/shared.rs` (`nginx_conf`), `services/ui/nginx/proxy-params.conf`, `services/ui/nginx/conf.d/*.conf` | `current_dev` `3005b2b4` | T2, T9 |
| Admin UI authentication | `services/ui/src/main.rs` (`login_ok`, `auth`, `Csrf`), `deploy/prod/docker-compose.yml`, `setup.sh` | #1985 `9a4b4be4` | T3 |
| Docker access (socket in `services` and `ui`) | `deploy/prod/docker-compose.yml`, `services/common/shared.rs` (`docker::Api`) | `current_dev` `3005b2b4` | T6 |
| DHCP: Kea mode | `services/common/shared.rs` (`kea_conf`, `kea::Api`), `deploy/prod/docker-compose.yml` (`dhcp`), `docs/README.md` (section 5) | #1985 `9a4b4be4` | T12 |
| DHCP: dnsmasq-proxy and dnsmasq-relay modes | `services/common/shared.rs` (`dnsmasq_conf`), `docs/README.md` (section 5) | `current_dev` `3005b2b4` | T12, T13 |
| Zone transfer to secondaries (TSIG, NOTIFY, AXFR) | `services/common/shared.rs` (`pdns_conf::auth`), `services/ui/src/main.rs` (`rotate_tsig`, `TSIG-ALLOW-AXFR`, `AXFR-MASTER-TSIG`) | `current_dev` `3005b2b4` | T5 |
| Secondary-node registration | `services/ui/src/main.rs` (`register`, `registration_token`, `secondary_action`), `deploy/secondary/docker-compose.yml` | `current_dev` `3005b2b4` | T5, T14 |
| Console exclusion-by-omission | `services/dns/cdn-domains.txt`, `docs/README.md` (section 4) | `current_dev` `3005b2b4` | T4, T10 |
| Zone/record known-good snapshot + rollback | `services/ui/src/main.rs` (`rollback`, `zone_snapshots_cli`, route `/domains/zone-rollback`), `docs/README.md` (section 6) | `current_dev` `3005b2b4` | T4 |

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
  `ipv6=off`, `services/ui/nginx/nginx.conf`), not the LAN spoof DNS
  (`AG-OP-002`). The render and the UI save path refuse an entry that is not a
  numeric address or that is loopback, unspecified or one of this host's own
  addresses (`recursor_conf::upstream_entry`, gap G3), so the resolver cannot
  point back at the appliance by that route.
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

**Rule** (`AG-SEC-001`): the `ui` service MUST fail closed and MAY restart-loop
when neither `UI_AUTH_USER` and `UI_AUTH_PASSWORD` nor `ALLOW_INSECURE_UI=true`
is configured; a restarting UI logging `Admin-UI authentication is required` is
expected security behavior; and `ALLOW_INSECURE_UI=true` remains a valid
explicit operator choice for an intentionally unauthenticated UI, including
trusted LAN deployments. The setup flow generates `UI_AUTH_PASSWORD` and
delivers only its Argon2id hash.

**State in the code** (`services/ui/src/main.rs`, code of #1985 `9a4b4be4`):
- **Password set:** the compose file passes `UI_AUTH_USER` and
  `UI_AUTH_PASSWORD_HASH` to the UI as `UI_USER` and `UI_PASSWORD_HASH`
  (gap G1). `login_ok` then requires HTTP Basic credentials, checked with
  Argon2id and a constant-time user compare (`secret::equal`).
- **No password:** `login_ok` accepts every request when `UI_PASSWORD_HASH` is
  empty. Unauthenticated access is an explicit choice with a default of open
  (`ALLOW_INSECURE_UI=true` in the SOT runtime defaults): `setup.sh` asks
  "Protect Admin-UI with password? [y/N]" (default No) and, on No, "Allow
  Admin-UI without authentication?" (default from the SOT value); answering No
  to both repeats the question. An update appends `ALLOW_INSECURE_UI=true` to an
  install that has no login. The `ui` process itself does not read
  `ALLOW_INSECURE_UI` (searched in `services/`) and does not refuse to start;
  the choice is made in the setup flow.
- Every state-changing request needs a CSRF token bound to the session
  (`Csrf::check`, `Csrf::check_header`); the session cookie is `HttpOnly` and
  `SameSite=Strict`.
- A password changed on the Setup page needs the old password and at least
  `UI_PASSWORD_MIN_LENGTH` characters (default 12, allowed 8 to 128); only the
  Argon2id hash is stored, in the UI settings file in the `ui-data` volume.
- The registration route for secondaries has its own token (T14).

**Residual risk**: Depends on the operator's explicit choice. With a password
set it is Low. With the default (no password) anyone who can reach the address
`UI_BIND_IP` selects (`IP_HTTP` by default, `deploy/prod/docker-compose.yml`)
controls the stack and, through the Docker socket, the host: acceptable only on
a trusted LAN, as `AG-SEC-001` states. `UI_BIND_IP=127.0.0.1` restricts it
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
  the Admin UI authentication (T3) part of this threat; with the unauthenticated
  default, reaching the UI is enough.
- **Scheduled automatic updates do not add a socket-access surface.** They run
  on the host as a `systemd` timer or, on Alpine hosts without systemd, an
  OpenRC loop service invoking `setup.sh` (`AUTO_UPDATE_ENABLED=0` by default).
  No container is granted expanded Docker or filesystem access to perform them.

**Residual risk**: High — both the UI (network-facing) and `services` hold a
read-write socket mount; the risk is concentrated in the Admin UI, which is
unauthenticated unless the operator sets a password (T3).

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
- `proxy_cache_path` limits the cache with `CACHE_MAX_GB`, `CACHE_MIN_FREE` and
  `CACHE_INACTIVE`; `proxy_cache_use_stale` keeps serving under pressure.
- `PROXY_ALLOWED_CLIENT_CIDRS` (default: private networks and `fc00::/7`)
  restricts which clients may drive the proxy over HTTP/HTTPS, and is also
  enforced by the stream-level listeners through generated `allow` / `deny all`
  directives, so a flood over either stream-level listener is rejected at the
  TCP level before it can reach any relay or backend (see T2).
- Disk-usage warnings/alarms: the watchdog checks the free space of the cache
  (`DISK_WARN_PCT`, `DISK_ALARM_PCT`) each round and writes the alarm file the
  Admin UI dashboard shows; `/stats` draws SNMP and Docker figures.

**Residual risk**: Medium — the nginx templates contain no `limit_req` or
`limit_conn`, so no per-client request rate limit exists.

---

### T10: Client uses HTTPS mode without the CA

**Threat**: A client uses the HTTPS-mode DNS address without the local CA
installed and its downloads fail.

**Likelihood**: High (user error) · **Impact**: Low (fails safe, no compromise)

**Mitigations**:
- Per-platform install steps and the distribution of `ca.crt` to clients are in
  `docs/README.md`, sections 4.1 and 4.3.
- HTTP mode needs no CA: the proxy forwards HTTPS by SNI passthrough.
- Consoles must not use the HTTPS-mode DNS address (`docs/README.md`,
  section 4.2).

**Residual risk**: Low — the failure is the intended safe behavior.

---

### T11: Console breakage from DNS spoofing in HTTPS mode

**Threat**: A console cannot install the local CA. If its CDN hosts are on the
spoof list and it uses the HTTPS-mode DNS address, it receives the proxy
certificate, rejects it and cannot fall back to the real CDN, because the
appliance keeps answering with the proxy address.

**Likelihood**: Low · **Impact**: Medium (downloads from that CDN fail on the
console)

**Mitigations**:
- `services/dns/cdn-domains.txt` lists no PlayStation or Nintendo CDN hosts; a
  host that is not on the list resolves to the real CDN (`docs/README.md`,
  section 4.2).
- The list contains nine Xbox and Game Pass hosts (`docs/README.md`,
  section 4.2).
- On the HTTP-mode DNS address the proxy forwards HTTPS by SNI passthrough, so
  no local certificate is involved.

**Residual risk**: Low — it needs a console on the HTTPS-mode DNS address and a
spoofed host of that console's CDN.

---

### T12: DHCP control-plane exposure (Kea mode)

**Threat**: In `kea` mode the appliance runs a full DHCP server with
`network_mode: host` and `NET_ADMIN`. Its Kea Control Agent API (port 8000) can
reconfigure DHCP (including the DNS servers handed to every client). Host
networking publishes that API on every host interface unless something fences it.

**Likelihood**: Medium (only when Kea mode is enabled) · **Impact**: High
(reprogramming DHCP-issued DNS redirects the whole LAN)

**State in the code** (`services/common/shared.rs`, code of #1985 `9a4b4be4`):
- **Authentication:** `kea_conf::ctrl_agent` writes a basic `authentication`
  block (user `KEA_CTRL_USER`, password `KEA_CTRL_TOKEN`) and the UI's client
  (`kea::Api`) sends them with `basic_auth` (gap G2). `KEA_CTRL_TOKEN` is a
  generated shared secret (`managed_secrets` in the SOT).
- **Reachability:** the Control Agent is bound to `KEA_CTRL_ADDRESS`, whose SOT
  default is `0.0.0.0`, on the host network. **No firewall fence exists:**
  `KEA_CTRL_ALLOW_FROM` and `KEA_CTRL_CHAIN` appear only in the SOT, and no code
  in `services/` or `setup.sh` calls `iptables`. The port is open to the LAN and
  protected only by the basic-auth login.
- `kea_conf::ddns` signs the Kea→PowerDNS dynamic updates with TSIG
  (`DDNS_TSIG_KEY`, algorithm `DDNS_TSIG_ALGORITHM`); the key is a shared secret
  resolved by `secret::resolve` like the PowerDNS API key (T4): an empty or
  template-like value is replaced by a generated one, so DDNS is
  TSIG-authenticated end to end by default.

**Residual risk**: Medium — a LAN host that knows the token can drive the DHCP
configuration; without it the login is refused. Basic authentication over plain
HTTP exposes the token to anyone who can sniff the segment. Always dependent on
the operator running Kea only where it is the sole DHCP server on the LAN.

---

### T13: DHCP DNS-option spoofing / competing servers (dnsmasq-proxy mode)

**Threat**: In `dnsmasq-proxy` mode the appliance answers the proxy-DHCP portion
alongside an existing DHCP server. A client may accept the wrong DNS option, and
proxy-DHCP DNS options are not reliably honoured by ordinary clients.

**Likelihood**: Medium · **Impact**: Low–Medium (cache bypass, not compromise)

**Mitigations** (verified in `services/common/shared.rs` `dnsmasq_conf` and
`docs/README.md`, section 5):
- A render with a bad value fails instead of producing a config
  (`dnsmasq_conf::render` returns an error; `render::all` returns the errors
  instead of files).
- The mode is documented as a deliberately limited helper for networks whose
  router DHCP cannot be disabled; the Admin UI's DHCP check probes for competing
  servers and DNS-option override (`dhcp_probe`).
- The optional-option surface (router/NTP/domain/PXE-boot/custom options via
  `dhcp-option-pxe`) is documented in `docs/README.md`, section 5, as carrying the same
  limitation as the DNS option: all of it rides the supplemental ProxyDHCP/PXE
  exchange, never the ordinary client's real lease.
- dnsmasq's ProxyDHCP mode does not reply to *any* DHCPDISCOVER unless at least
  one `pxe-service` directive is present. `dnsmasq_conf::pxe` renders those
  only when the operator sets `DHCP_PROXY_PXE_BOOT_SERVER` plus a boot filename
  (see `docs/README.md`, section 5.3). By default `dnsmasq-proxy`
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
the TSIG key secret, and by the Admin UI authentication (T3, unauthenticated by default) for the
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
   see `docs/combined-release-and-checklist.md`).

---

## Deployment risk tiers

### Low risk
- Private, firewalled LAN; control-plane ports unreachable from untrusted
  segments.
- Admin UI with a password set, bound to `127.0.0.1`, or consciously left
  unauthenticated on a trusted LAN (`AG-SEC-001`).
- Zone transfers to secondaries only TSIG-signed (default).
- Kea mode off, or Kea Control Agent port 8000 reachable only from trusted
  hosts (the appliance does not fence it; the basic-auth login protects it).
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
- Admin UI exposed beyond the LAN, **especially** without a password
  (`ALLOW_INSECURE_UI=true`).
- Kea API 8000, or the PowerDNS API reachable from untrusted networks.
- Direct Docker socket exposed to untrusted containers/networks.
- No firewall between the appliance and an untrusted uplink.

---

## Operator responsibilities

1. Deploy on a trusted, firewalled LAN and keep control-plane ports off
   untrusted segments.
2. Set an Admin UI password unless the UI is intentionally unauthenticated.
   `ALLOW_INSECURE_UI=true` is a valid explicit choice on a trusted LAN
   (`AG-SEC-001`), but not on anything reachable from an untrusted network.
3. Narrow `PROXY_ALLOWED_CLIENT_CIDRS` when the LAN is not fully trusted;
   `strict` proxy mode is an opt-in that accepts a maintained allowlist
   (`AG-OP-003`).
4. Protect the local CA private key (`<CA_DIR>/ca.key`) in HTTPS mode.
5. Restrict Kea Control Agent port 8000 at the host firewall while Kea mode is
   on; the appliance does not fence it.
6. Monitor disk and activity, and keep images updated.

Security concerns are reported through the private channel in `SECURITY.md`.

## Howto audit this file

The audit procedure of this file is `docs/policy/howto-audit-documentation.md`.

### Special deviation

| Field | Content |
| --- | --- |
| Step | 4 and 5 |
| Reason | The likelihood, impact and residual-risk ratings are assessments, not code facts |
| Replacement | The audit checks that each rating does not contradict the mitigations and gaps listed in the same threat; it does not verify the rating against code |
