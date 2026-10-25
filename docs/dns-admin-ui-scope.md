# DNS / PowerDNS Admin UI — Feature Scope

This is the written decision issue #645 asked for: a single place that says
what the Admin UI is intended to let an operator configure/manage for DNS
(PowerDNS authoritative + recursor, both http and https mode), so that code
which looks unused or half-finished is not misread as dead/removable by a
future contributor or agent. DNS/PowerDNS feature work has happened
incrementally (domain list management, LAN records, DDNS, secondary
registration, NATS sync) without ever writing down the full intended surface
in one place — this document is that surface.

This is a **scoping document, not an implementation plan**. Nothing in the
"planned but unbuilt" sections below is committed to v0.2.0; per issue #645's
own framing, v0.2.0 completed its feature freeze and stabilization pass
(#986, closed) and is now an archived release branch that only takes
deliberate backports (see docs/release-versioning.md), so most of that list
is candidate v0.3.0 scope until a maintainer decision says otherwise. Where
this document says "planned but unbuilt," treat the referenced code (or its
absence) as intentional, not as something to "clean up."

Related: #415/#616 (known-good config snapshots, implemented), #628 (PowerDNS
zone/record rollback, implemented via PR #788 — see
[known-good-config-snapshots.md](known-good-config-snapshots.md)'s "Zones,
records, and TSIG/DDNS metadata" section), #433/#583 (per-secondary NATS
identity, implemented).

Code owners named below:

| Owner | File |
|---|---|
| Supervisor renders (`pdns_auth`, `dns_zones`, `ddns_tsig`, `recursor`, `rpz_zone`, `nginx`, `kea_dhcp_ddns`, `nats_server`) | `services/watchdog/src/main.rs` |
| Zone lists (`reverse_zones`, `rollback_zones`), CDN row rule (`cdn_entry`), NATS server config render | `services/common/config.rs` |
| Admin UI routes and handlers | `services/ui/src/main.rs` |
| Record events, flushes, zone snapshots, rollback listener | `services/dns/nats-subscriber/src/main.rs` |
| Default values of every key | SOT runtime defaults in `.github/yaml/build-manifest.yml` |

## 1. Operator-configurable via Admin UI vs. config-file-only

PowerDNS-related settings fall into three groups today, not two — the
question "UI or config file" undersells that some settings are UI-only
runtime state with no corresponding env var at all.

### 1a. Config-file-only (env var, requires a container restart to change)

The supervisor reads these from the `dns` container env when it starts
PowerDNS, renders `pdns.conf` (`pdns_auth`) and `recursor.conf` (`recursor`),
checks each render with the program's own config check and falls back to a
known-good snapshot (§4). The Admin UI has no route that writes any of them.
Changing one means changing the install's env (`setup.sh` writes it) and
recreating the `dns` container — **except `PDNS_API_KEY`, which is a shared
value with more than one consumer**: the `ui` container reads the same key at
startup and sends it as the `X-API-Key` header on every PowerDNS
authoritative/recursor API call the Admin UI makes. Recreating only `dns`
after rotating `PDNS_API_KEY` leaves `ui` running with the stale key, so its
`/domains` reads and flushes fail with 401 until `ui` is recreated too. As a
rule, restart every consumer of a shared value, not just the DNS containers.

| Variable | Purpose |
|---|---|
| `PDNS_API_KEY` | Authoritative + recursor REST API key, resolved by `pdns_api_key` (the Admin UI itself is a client of this API, not a manager of the setting) |
| `DDNS_TSIG_KEY` | TSIG key material. `ddns_tsig` imports it on every start and sets the per-zone `TSIG-ALLOW-DNSUPDATE` metadata for each zone of `rollback_zones`: with the key name by default, without it when the Admin UI's unsigned-updates marker is set (1b). An empty key revokes the metadata and deletes the key |
| `IP_HTTP` / `IP_HTTPS` | `pdns_auth` allows RFC 2136 dynamic updates from these addresses when a TSIG key exists and the node is a primary; otherwise only from loopback |
| `LOG_QUERIES` | Query logging on/off |
| `ROOT_ZONE_MIRROR` | AXFR root zone mirror; `recursor` turns it on unless the value parses as false |
| `DNS_REPLICATION_ROLE` / `DNS_XFR_PRIMARY` | Zone transfer role and primary endpoint, see 3a |
| `NATS_BIND_IP` / `NATS_ADVERTISE_URL` | **Not PowerDNS-native secondary/AXFR wiring — see 3a below.** They only publish/advertise the NATS registration/event path for remote secondary setup |
| `NATS_URL` / `NATS_USER` / `NATS_PASSWORD` / `NATS_TOKEN` / `NATS_CONSUMER` / `NATS_RECONCILER` / `NATS_RECORD_WRITES` | This node's own NATS connection identity and record-write switch for the `nats-subscriber` process |
| `KEEP_KNOWN_GOOD_CONFIGS` / `DNS_CONFIG_SNAPSHOT_DIR` | Known-good config snapshot retention/location (see #415) |

These are intentionally config-file-only: they are either security-sensitive
(TSIG key, API key, NATS credentials — exposing a rotate-via-UI path for
these needs its own threat-model discussion, not an incidental add-on here)
or install-topology decisions (root mirror, the NATS secondary-bind override)
made once at deploy time, not tuned routinely.

### 1b. Operator-configurable via Admin UI today

| Setting | Route | Mechanism |
|---|---|---|
| CDN domain list (`cdn-domains.txt`) — add/remove, plain or wildcard-only (`.domain.com`) entries | `POST /domains/dns/add` (`add_dns`), `POST /domains/dns/remove` (`remove_dns`) | `edit_domains` takes the ui's file lock and writes the list through `write_file` (`services/common/shared.rs`): temp file plus rename, and on a file bind mount, which refuses the rename with `EBUSY`, a truncate-then-write of the same file. An add re-enables a disabled entry instead of repeating it; a removal also takes a malformed legacy line by its text. Then `after_domain_change` flushes the name from the recursors. The supervisor watches the list file for both `recursor` (which regenerates the RPZ through `rpz_zone`) and `nginx`, and restarts each program when the file changes, so no manual `dns` or `proxy` restart is needed |
| CDN domain list — per-entry enable/disable toggle for pre-shipped "Default CDN" entries (#1073) | `POST /domains/dns/toggle` (`toggle_default_domain`) | `with_enabled` flips a leading `!` marker on the matching line; the entry stays in the file and the list, and `rpz_zone` and the nginx render skip `!` rows (`cdn_rows`). The first operator addition inserts the custom-domains marker line once (`with_added`); `domain_rows` treats rows before that marker as pre-shipped defaults (toggle-able) and rows after it as operator additions (removable only). Same flush and supervisor restart as add/remove |
| LAN records in the LAN zone (A/AAAA/CNAME/MX/TXT) — add/remove | `POST /domains/lan/add`, `POST /domains/lan/remove` | `set_lan_record` publishes a record event (`publish_record`) to the `LANCACHE_DNS` JetStream stream; the primary's `nats-subscriber` applies it to its local PowerDNS through the API; secondaries acknowledge it without a local write (`NATS_RECORD_WRITES=0`, see 3b) and converge by AXFR |
| Manual PTR records in the provisioned IPv4 reverse zones — add/remove | `POST /domains/ptr/add` (`add_ptr_record`), `POST /domains/ptr/remove` | `set_ptr_record` PATCHes the reverse zone directly on the primary's PowerDNS (`patch_reverse_zone`); the flush follows only an accepted write |
| Global AAAA-response filter (suppress all AAAA answers) | `POST /domains/aaaa-filter` (`toggle_aaaa_filter`) | `set_markers` writes/removes a marker file in `DNS_STATE_DIR`; `recursor` passes its path to `filter-aaaa.lua`, whose `preresolve` hook reads it live — takes effect immediately, no restart |
| `ddns-allow-unsigned-updates` toggle (issue #815 follow-up, default off) | `POST /domains/ddns-allow-unsigned-updates` (`toggle_ddns_allow_unsigned_updates`) | TSIG enforcement is active by default; this toggle lets an operator explicitly *relax* it. `set_markers` writes/removes the unsigned-updates marker in `DNS_STATE_DIR`; `pdns_auth` on a primary watches that marker, so the supervisor restarts PowerDNS and `ddns_tsig` sets the metadata with or without the key name. The route refuses to enable the toggle (redirect with an error) when `tsig_key_configured` finds no real `DDNS_TSIG_KEY`, because there would be no enforcement to relax |
| Secondary node registration, address, health check, credential rotation, removal | `/secondaries` page, `POST /api/secondary/register`, `/api/secondary/{name}/address`, `POST /api/secondary/{name}/health`, `POST /api/secondary/{name}/rotate-token`, `DELETE /api/secondary/{name}` | Per-secondary NATS auth-callout credential (issue #583). The supervisor's `nats_server` renders the NATS config from the roles in `services/common/config.rs`; the ui writes only the auth-callout fragment, so a secondary is not a config edit. `authorize_secondary` re-checks the `secondaries` table on every connection attempt, so a removed/rotated credential is rejected from that node's *next* reconnect, not on its already-established connection |
| Zone snapshot rollback | `POST /domains/zones/rollback` (`rollback_zone_snapshot`) | Forwards to the `nats-subscriber` rollback listener, see §4 |
| Recursor cache flush for a specific name | Internal helper (`flush_recursor_cache`, called by the routes above) | PowerDNS Recursor `cache/flush?domain=` API call, plus a NATS flush broadcast so every recursor instance drops its cached answer for that name. For record changes the broadcast carries the expected state (`record_flush`: zone, record type, content, TTL when known); each subscriber confirms its local PowerDNS has converged to that state before flushing and defers via NATS redelivery up to a delivery ceiling, then flushes anyway, so a stale re-cache is narrowed but not fully impossible (issue #1095). A CDN change sends the name only (`flush_name`) |

### 1c. Not settings — read-only status surfaces

`domains_page` (`GET /domains`) also renders the current `cdn-domains.txt`
rows (`domain_rows`), the LAN zone's rrsets, the PTR rows of the provisioned
reverse zones (`fetch_ptr_records`), the AAAA-filter and unsigned-updates
marker states, and the zone snapshot groups (`fetch_zone_groups`) next to the
forms above; these are the display half of 1b's routes, not a separate
configuration category.

## 2. Zone/record management surface

**What exists today:** the zone topology is fixed: `rollback_zones`
(`services/common/config.rs`) returns the LAN zone, `local.` plus the LAN
zone, the IPv4 reverse zones of `reverse_zones` (`10.in-addr.arpa.`,
`168.192.in-addr.arpa.` and one zone per `16.172.` through `31.172.`), and the
two ULA IPv6 reverse zones `c.f.ip6.arpa.` / `d.f.ip6.arpa.`. `dns_zones`
creates them on every start of a primary (an "exists already" refusal is
accepted, any other failure is fatal) or as AXFR secondaries of
`DNS_XFR_PRIMARY` on a secondary. The Admin UI cannot create, delete, or list
arbitrary zones — it manages records inside the LAN zone, PTR records inside
the IPv4 reverse zones (1b), and the CDN domain list that drives RPZ.
`local.` plus the LAN zone has no Admin UI record route, and nothing in the
default config sends DDNS to it: `kea_dhcp_ddns` sends forward host-record
updates to the LAN zone (`DHCP_DOMAIN`, SOT default `lan`), so Kea's forward
DDNS records land in the UI-managed LAN zone. `ddns_tsig` grants
`TSIG-ALLOW-DNSUPDATE` to every zone of `rollback_zones`, `local.` zone
included. `reverse-ddns` lists one `ddns-domains` entry per zone of
`reverse_zones`, so reverse/PTR DDNS updates reach the correct per-octet zone
(#768 fixed the earlier single `in-addr.arpa.` catch-all that PowerDNS
answered with NOTAUTH). `dns` is the only DDNS write target; remote DNS
secondaries receive the same forward and reverse zone state through native
PowerDNS AXFR/NOTIFY.

**Intentionally out of scope (not planned):**
- Arbitrary zone creation/deletion via the Admin UI. The zone list is a fixed
  part of this project's DNS architecture (LAN TLD + reverse zones + RPZ),
  not a general-purpose PowerDNS zone manager.
- The RPZ zone (`rpz.`) has no direct record editor and should not get one:
  `rpz_zone` regenerates it from `cdn-domains.txt` on every recursor start,
  so the edit surface is the CDN domain list (1b).
- TSIG key management via the UI. Key *material* (`DDNS_TSIG_KEY`) is
  config-file-only by design (1a): rotating a key that Kea's `kea-dhcp-ddns`
  also uses needs a coordinated rollout across both containers. The 1b
  unsigned-updates toggle flips only the per-zone `TSIG-ALLOW-DNSUPDATE`
  association (set with or without the key name), never introduces or
  removes a key, and needs no coordination with Kea. It is a narrow exception
  for this one boolean, not a UI surface for key rotation or arbitrary
  per-zone metadata.

**Planned but unbuilt (candidate v0.3.0 scope):**
- Record management for `local.` plus the LAN zone and for the IPv6 reverse
  zones. Today the LAN zone has a CRUD surface and the IPv4 reverse zones have
  a manual PTR surface; the others have no manual override path.
- A PTR checkbox on the LAN A-record form that creates the matching PTR in
  the same step. Manual PTRs exist as their own form (1b); the combined step
  does not.

## 3. Secondary / DDNS / NATS sync

### 3a. PowerDNS-native secondary/AXFR

**Current state (implemented for the fixed project zones):** `dns` is the
only writer for LAN/reverse zone data. On a primary, `dns_zones` sets each
zone's kind to primary, sets `SOA-EDIT-DNSUPDATE`/`SOA-EDIT-API` to
`INCREASE` and `NOTIFY-DNSUPDATE`, activates the shared TSIG key for
transfers, and sets `ALSO-NOTIFY` for the configured notify targets.
Registered remote DNS nodes run the same image with
`DNS_REPLICATION_ROLE=secondary`; `dns_zones` creates the fixed zones there as
PowerDNS secondaries of `DNS_XFR_PRIMARY` and refuses to start without the
shared TSIG key.

`register_secondary`'s answer carries the bootstrap fields a remote secondary
needs for this path: the PowerDNS API key, the shared DDNS/transfer TSIG
secret (registration is refused without it), and the primary transfer
endpoint. A registered secondary also receives its per-node NATS credential,
but `deploy/secondary/docker-compose.yml` sets `NATS_RECORD_WRITES=0`, so NATS
record messages do not become a second local PowerDNS writer.

### 3b. NATS-based secondary control/event path (#433/#583)

**Current state (implemented):** secondary registration, credential rotation,
credential revocation, flush events, and primary-side record publishing use
NATS. Since #1164 secondaries do not apply record messages to their local
PowerDNS databases: with `NATS_RECORD_WRITES=0` the `nats-subscriber`
acknowledges them without a write, and zone data converges through native
PowerDNS AXFR/refresh.

**Replication health:** `check_secondary_health`
(`POST /api/secondary/{name}/health`) sends an SOA query for the LAN zone to
the secondary's recorded private address and returns status, serial and
detail; a successful answer is the only writer of the `last_seen` column,
which `secondaries.html` shows. A secondary without a recorded private
address answers `no_address`. **Not built:** a periodic check, and a
comparison of the secondary's serial against the primary's that flags
lagging or diverged zones (candidate v0.3.0 scope).

## 4. Known-good config snapshot / rollback (#415/#616) — Admin UI perspective

See [known-good-config-snapshots.md](known-good-config-snapshots.md) for the
full mechanism; this section only covers what is or isn't exposed through the
Admin UI specifically, since that is #645's concern.

**Implemented, no Admin UI surface (by design):** `pdns.conf` and
`recursor.conf` snapshot/rollback (#615) is automatic at each program start:
the supervisor checks the fresh render with the program's own config check
(`pdns_check`), keeps it as a snapshot on success, and on failure tries the
stored snapshots newest first until one passes. This happens in the `dns`
container's supervisor, before any Admin UI action. The only operator-visible
signal today is the `[known-good-snapshot][dns-auth][...]` /
`[known-good-snapshot][dns-recursor][...]` log lines and the supervisor's
"runs from known-good snapshot" warning — there is no dashboard indicator for
"this DNS node runs a known-good config because the last render was
rejected." That gap applies identically to the nginx, dnsmasq and Kea
adapters and is not DNS-specific; a shared status surface across all four
adapters would close it (candidate v0.3.0 scope, not started).

**Implemented:** zone/record data rollback (#628, PR #788).
[known-good-config-snapshots.md](known-good-config-snapshots.md)'s "Zones,
records, and TSIG/DDNS metadata" section is the authoritative detail; this is
only the Admin UI-facing summary. Unlike the file-based adapters above, this
is an **Admin UI-visible, operator-selected rollback** (like the `/dhcp`
page's Kea snapshot picker), because a stale zone snapshot can silently undo
real client leases or hostnames. The `nats-subscriber` snapshots the data
rrsets (SOA/NS excluded) of every zone of `rollback_zones` after every
NATS-applied write and every `DNS_SYNC_TICK` (which covers Kea's direct DDNS
writes and the ui's direct PTR writes). `serve_rollback` listens on
`DNS_ROLLBACK_LISTEN_ADDR` and `DNS_ROLLBACK_PORT`, checks the `X-API-Key`, and
serves `GET /snapshots` and `POST /rollback`; the ui forwards to it
(`fetch_zone_groups`, `rollback_zone_snapshot`), and the `/domains` page's
"Zone-Snapshots & Rollback" tab (`templates/domains.html`) is the picker. For
the LAN zone only, a rollback re-publishes the restored entries as record
events, after applying the patch and before flushing recursor caches; this
needs the record subject in the writer's publish list, which the NATS server
config render in `services/common/config.rs` grants.

**Kea, for contrast (already Admin UI-visible):** the `/dhcp` page's
operator-selected snapshot list (#614) is the precedent the #628 zone/record
design follows. It is out of scope for *this* document (DHCP, not DNS).

## 5. Summary table

| Area | State | Where |
|---|---|---|
| Static `pdns.conf`/`recursor.conf` settings (API key, TSIG, DDNS allow-from, query logging, root mirror) | Config-file-only, implemented | `pdns_auth`, `recursor`, `ddns_tsig` in `services/watchdog/src/main.rs`; SOT runtime defaults |
| CDN domain list (RPZ + HTTPS cert scope) | Admin UI, implemented; the supervisor restarts the recursor and nginx when the file changes | `services/ui/src/main.rs`, `/domains` |
| LAN zone records (A/AAAA/CNAME/MX/TXT) | Admin UI, implemented | `services/ui/src/main.rs`, `/domains` |
| Manual PTR records (IPv4 reverse zones) | Admin UI, implemented | `services/ui/src/main.rs`, `/domains` |
| `local.` zone / IPv6 reverse zone records | No Admin UI route | Planned, v0.3.0 candidate |
| PTR checkbox on LAN A records | Not built | Planned, v0.3.0 candidate |
| Global AAAA filter | Admin UI, implemented | `services/ui/src/main.rs`, `filter-aaaa.lua` |
| Arbitrary zone create/delete | Not planned | Deliberately out of scope |
| RPZ direct record editor | Not planned | Deliberately out of scope (edit via CDN domain list instead) |
| PowerDNS-native secondary/AXFR | Implemented for registered remote DNS secondaries; `dns` remains the only zone writer | `dns_zones` in `services/watchdog/src/main.rs`, `deploy/*/docker-compose.yml`, `setup.sh secondary` |
| NATS-based secondary registration/rotate/remove | Admin UI, implemented; registration also returns the AXFR endpoint and shared TSIG material | `services/ui/src/main.rs`, `/secondaries` |
| Secondary health check (SOA probe, `last_seen`) | Admin UI, on request | `check_secondary_health` in `services/ui/src/main.rs`, `/secondaries` |
| Secondary serial comparison against the primary | Not built | Planned, v0.3.0 candidate |
| Static config snapshot/rollback status indicator | Not built (log-only today) | Planned, v0.3.0 candidate, not DNS-specific |
| Zone/record snapshot/rollback (#628) | Admin UI, implemented (PR #788) | `services/ui/src/main.rs`, `services/dns/nats-subscriber/src/main.rs`, `services/common/shared.rs`, `/domains` "Zone-Snapshots & Rollback" tab |

## How to use this document

If you are about to remove, "clean up," or flag as dead any DNS/PowerDNS-
adjacent code that looks incomplete, check this document first. If the gap
you found is listed under "planned but unbuilt" above, it is intentional —
file or link a v0.3.0-scoped issue instead of deleting it, and update this
document if the scope decision changes. If it's not listed here at all, that's
this document's own gap: update it rather than guessing.
