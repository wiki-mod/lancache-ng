# DNS / PowerDNS Admin UI — Feature Scope

This is the written decision issue #645 asked for: a single place that says
what the Admin UI is intended to let an operator configure/manage for DNS
(PowerDNS authoritative + recursor, both standard and SSL mode), so that code
which looks unused or half-finished is not misread as dead/removable by a
future contributor or agent. DNS/PowerDNS feature work has happened
incrementally (domain list management, LAN records, DDNS, secondary
registration, NATS sync) without ever writing down the full intended surface
in one place — this document is that surface.

This is a **scoping document, not an implementation plan**. Nothing in the
"planned but unbuilt" sections below is committed to v0.2.0; per issue #645's
own framing, v0.2.0 is trending toward feature freeze, so most of that list is
candidate v0.3.0 scope until a maintainer decision says otherwise. Where this
document says "planned but unbuilt," treat the referenced code (or its
absence) as intentional, not as something to "clean up."

Related: #415/#616 (known-good config snapshots, implemented), #628 (PowerDNS
zone/record rollback, scoped but not implemented — see
[known-good-config-snapshots.md](known-good-config-snapshots.md)'s "Zones,
records, and TSIG/DDNS metadata" section), #630 (a live-verification bug class
found while building the Kea snapshot adapter, fixed in #614; the PowerDNS
adapter's own doc already records the equivalent live verification against
real `pdns_recursor`/`pdns_server` binaries — see "Known-good config snapshot
coverage" below), #433/#583 (per-secondary NATS identity, implemented).

## 1. Operator-configurable via Admin UI vs. config-file-only

PowerDNS-related settings fall into three groups today, not two — the
question "UI or config file" undersells that some settings are UI-only
runtime state with no corresponding env var at all.

### 1a. Config-file-only (env var, requires a container restart to change)

These are read once at container start by `services/dns/entrypoint.sh` and
baked into `pdns.conf` / `recursor.conf` via `render_template_atomic()`. The
Admin UI has no route that writes any of them. Changing one means editing the
compose `.env` file and restarting the `dns-standard`/`dns-ssl` containers.

| Variable | Purpose |
|---|---|
| `PDNS_API_KEY` | Authoritative + recursor REST API key (the Admin UI itself is a client of this API, not a manager of the setting) |
| `DDNS_ALLOW_FROM` | CIDR allow-list for RFC 2136 dynamic updates |
| `DDNS_TSIG_KEY` / `DDNS_TSIG_NAME` / `DDNS_TSIG_ALGORITHM` | TSIG key material and metadata re-applied to every DDNS-eligible zone on every start via `configure_ddns_tsig()` |
| `LOG_QUERIES` | Query logging on/off |
| `ROOT_ZONE_MIRROR` (`ENABLE_ROOT_MIRROR` in `docs/architecture-ng.md`) | AXFR root zone mirror |
| `ENABLE_SECONDARY` / `SECONDARY_MASTERS` / `SECONDARY_ZONES` | Legacy PowerDNS-native secondary/AXFR wiring — see 3a below, this is a *different* mechanism from the NATS-based secondary sync the Admin UI actually manages |
| `NATS_URL` / `NATS_USER` / `NATS_PASSWORD` / `NATS_TOKEN` / `NATS_CONSUMER` / `NATS_RECONCILER` | This node's own NATS connection identity for the `nats-subscriber` process |
| `KEEP_KNOWN_GOOD_CONFIGS` / `DNS_CONFIG_SNAPSHOT_DIR` | Known-good config snapshot retention/location (see #415) |

These are intentionally config-file-only: they are either security-sensitive
(TSIG key, API key, NATS credentials — exposing a rotate-via-UI path for
these needs its own threat-model discussion, not an incidental add-on here)
or install-topology decisions (root mirror, legacy PowerDNS secondary/AXFR)
made once at deploy time, not tuned routinely.

### 1b. Operator-configurable via Admin UI today

| Setting | Route | Mechanism |
|---|---|---|
| CDN domain list (`cdn-domains.txt`) — add/remove, plain or wildcard-only (`.domain.com`) entries | `POST /domains/add`, `POST /domains/remove` (`services/ui/src/routes/domains.rs`) | Direct atomic file write to the shared `cdn-domains.txt`, consumed by both the DNS RPZ zone (regenerated every start from this file) and the SSL proxy's wildcard-cert root domain list |
| LAN records in the `lan.` zone (A/AAAA/CNAME/MX/TXT) — add/remove | `POST /domains/lan/add`, `POST /domains/lan/remove` | Publishes a `lancache.dns.record` NATS message consumed by every node's `nats-subscriber`, which applies it via the PowerDNS API and re-publishes to JetStream for durability/secondary replication |
| Global AAAA-response filter (suppress all AAAA answers) | `POST /domains/aaaa-filter` | Writes/removes a marker file on the shared `powerdns-state` volume, read live (no caching, `dq.variable=true`) by `filter-aaaa.lua`'s recursor `preresolve` hook — takes effect immediately, no restart |
| Secondary node registration, credential rotation, removal | `services/ui/src/routes/secondaries.rs` (`/secondaries` page + `/secondaries/register`, `/secondaries/{name}/rotate`, `/secondaries/{name}` DELETE) | Per-secondary NATS auth-callout credential (issue #583); revocation is instant (deleting the DB row denies the next reconnect) since `nats.conf` itself is now static and never rewritten per secondary |
| Recursor cache flush for a specific name | Internal helper (`flush_recursor_cache`, called by the add/remove routes above) | PowerDNS Recursor `cache/flush?domain=` API call, plus a NATS `lancache.dns.flush` broadcast so every recursor instance (not just the one this UI process talks to) drops its cached answer for that exact name |

**Doc-drift note found during this investigation:** `docs/architecture-ng.md`'s
PowerDNS table currently lists `FILTER_AAAA_V4` and `FILTER_AAAA_V6` as two
separate env vars ("Filter AAAA records for IPv4 clients" / "...for IPv6
clients"). Neither name appears anywhere in `services/dns/` or
`services/ui/src` — the real, shipped mechanism is the single global marker
file described in the table above, filtering AAAA answers for every client
regardless of address family, toggled live via the Admin UI rather than by
env var/restart. This document reflects the real, current mechanism; the
architecture doc's table entry is stale and should be corrected in a small
follow-up doc fix (out of scope here to avoid mixing a correction into a
scoping decision, per this project's usual one-topic-per-PR convention).

### 1c. Not settings — read-only status surfaces

The `/domains` page also renders the current `cdn-domains.txt` contents and
the current LAN zone's rrsets (`fetch_lan_records`) as read-only listings
alongside the add/remove forms above; these are not a separate configuration
category, just the display half of 1b's mutation routes.

## 2. Zone/record management surface

**What exists today:** the zone topology itself is fixed at five zones
(`lan.`, `local.lan.`, and the three RFC-1918 reverse zones — see
`docs/architecture-ng.md`'s zone table), all created idempotently by
`services/dns/entrypoint.sh` on every start (`create-zone ... || true`). The
Admin UI cannot create, delete, or list arbitrary zones — it only manages
*records inside* the fixed `lan.` zone (see 1b) and the CDN domain list that
drives RPZ. `local.lan.` and the reverse zones exist and are created, but
have no Admin UI record-management route at all today; their record content
comes entirely from DDNS (Kea lease updates via `nsupdate`) and NATS-driven
secondary reconciliation, not manual entry.

**Intentionally out of scope (not planned):**
- Arbitrary zone creation/deletion via the Admin UI. The zone list is a fixed
  part of this project's DNS architecture (LAN TLD + reverse zones + RPZ),
  not a general-purpose PowerDNS zone manager. Letting an operator create
  unrelated zones is a materially different product (a general DNS admin
  panel) and is not this project's goal.
- The RPZ zone (`rpz.`) has no direct record editor and should not get one:
  it is fully regenerated from `cdn-domains.txt` on every start, so the
  correct edit surface is already the CDN domain list (1b), not a separate
  RPZ-specific UI.
- TSIG key/metadata management via the UI. This is config-file-only by design
  (see 1a) — rotating a TSIG key that Kea's `kea-dhcp-ddns` also depends on
  needs coordinated rollout across both containers, not a one-sided UI edit.

**Planned but unbuilt (candidate v0.3.0 scope):**
- Record management for `local.lan.` and the private reverse zones. Today
  only `lan.` has an Admin UI CRUD surface; the other two zones that DDNS/NATS
  actually populate have no manual override path if an operator needs to fix
  or inspect a record PowerDNS-side without going through Kea.
- A PTR-record checkbox alongside LAN A-record creation.
  `docs/architecture-ng.md` currently states "DNS: create zones, host
  entries, PTR checkbox for LAN IPs" under "Admin UI" — verified against
  `services/ui/src/templates/domains.html` and `domains.rs` during this
  investigation: no PTR-related code exists in either file. This is a
  planned-but-unbuilt feature the architecture doc got ahead of, not a
  regression or dead code to remove. (The "create zones" half of that same
  architecture-doc bullet is addressed by the "intentionally out of scope"
  point above — that part was never intended to mean arbitrary zone
  creation, based on the fixed-zone design described throughout this
  document and `docs/architecture-ng.md`'s own zone table.)
- Zone/record-level rollback UI — see #628 and section 4 below; the design
  exists (PR #730), no code does yet.

## 3. Secondary / DDNS / NATS sync

Two independent secondary mechanisms exist in this codebase, at different
maturity levels; conflating them was a real risk this document exists partly
to prevent.

### 3a. Legacy PowerDNS-native secondary/AXFR (`ENABLE_SECONDARY` / `SECONDARY_MASTERS` / `SECONDARY_ZONES`)

Config-file-only (1a), PowerDNS's own built-in secondary/AXFR zone transfer
mechanism. This predates the NATS-based sync below and is a different
replication method (PowerDNS pulling zone data directly from a master via
AXFR) with no Admin UI surface at all — it is set-and-forget at deploy time.
Not slated for an Admin UI surface; it is a low-level PowerDNS protocol
knob, not an operator workflow this project's UI is meant to wrap.

### 3b. NATS-based secondary sync (the actively developed mechanism, #433/#583)

**Current state (implemented):** every DNS node — the primary's own
co-located `dns-ssl` container and every remote secondary added via
`setup.sh secondary` — runs the same `dns` image and its own
`nats-subscriber` process, consuming the same JetStream stream
(`LANCACHE_DNS`) and applying record changes to its own local PowerDNS
instance independently. Each secondary gets its own per-node NATS
auth-callout credential (issue #583, superseding an earlier shared-token
model), managed entirely through `services/ui/src/routes/secondaries.rs`'s
`/secondaries` page: register (issues a one-time-displayed credential),
rotate (regenerates just that node's password, old one stops working
instantly), remove (revokes on that node's next reconnect, `nats.conf`
itself is never rewritten). LAN record adds/removes from the `/domains` page
(1b) publish to the same stream every subscriber consumes, so a record
change made once on the primary's Admin UI replicates to every registered
secondary automatically.

**Intended end state vs. current state:** the identity/credential model
(register/rotate/revoke per secondary) is complete per #583. What is not yet
built is any Admin UI visibility into *replication health* — the
`/secondaries` page shows `last_seen` per secondary (from the `secondaries`
table) but nothing surfaces whether a specific secondary's local zone data
has actually converged with the primary's, or is lagging/diverged for some
reason (e.g. that secondary's `nats-subscriber` crashed after a partial
batch — see #653, a currently-open related bug in the batch queue this issue
belongs to, about a stale update surviving a same-batch failure). A
convergence/health indicator per secondary is planned-but-unbuilt, candidate
v0.3.0 scope, not started.

## 4. Known-good config snapshot / rollback (#415/#616) — Admin UI perspective

See [known-good-config-snapshots.md](known-good-config-snapshots.md) for the
full mechanism; this section only covers what is or isn't exposed through the
Admin UI specifically, since that is #645's concern.

**Implemented, no Admin UI surface (by design):** `pdns.conf` and
`recursor.conf` snapshot/rollback (#615) is fully automatic and
container-startup-scoped — validate the freshly generated config with
`pdns_server --config=check` / `pdns_recursor --config=check`, snapshot on
success, and on failure search stored snapshots newest-to-oldest until one
validates. There is nothing for an operator to click: this happens before the
Admin UI process is even reachable (it lives in `services/dns/entrypoint.sh`,
a different container). The only operator-visible signal today is the
`[known-good-snapshot][dns][...]`-tagged container log lines at fallback
time — there is no dashboard/status indicator surfacing "this DNS node is
currently running a stale known-good config because the last regeneration was
rejected." That gap applies identically to the nginx and dnsmasq adapters
(same mechanism, same log-only signal) and is not DNS-specific, so it is not
re-scoped as a DNS-only ask here; a shared "config snapshot rollback
happened" status surface across all three adapters (nginx/dnsmasq/PowerDNS)
would be the natural way to close it, candidate v0.3.0 scope, not started.

**Scoped design, not yet implemented:** zone/record data rollback (#628) —
covered by PR #730's rewrite of
[known-good-config-snapshots.md](known-good-config-snapshots.md)'s "Zones,
records, and TSIG/DDNS metadata" section (open at the time of writing; not
yet merged into `v0.2.0`). Unlike the file-based adapters above, this design
explicitly calls for an **Admin UI-visible, operator-selected rollback**
(analogous to the existing `/dhcp` page's Kea snapshot picker) rather than an
automatic startup-time rollback, because a stale zone snapshot can silently
undo real client DHCP leases or hostnames. Nothing here exists in code yet —
no snapshot creation in `nats-subscriber`, no `/domains`-page (or new page)
snapshot list, no rollback route. This is the single largest concrete gap
between "what #645 asks the Admin UI to eventually cover" and "what exists
today," and per PR #730's own design doc, an implementation PR still needs to
resolve one open question before it can be built: how a primary-side rollback
re-publishes onto the NATS stream so secondaries (3b above) converge to the
same restored records, rather than silently diverging from the rolled-back
primary.

**Kea, for contrast (already Admin UI-visible):** the `/dhcp` page's
operator-selected snapshot list (#614) is the existing precedent the #628
zone/record design explicitly follows. It is out of scope for *this*
document (DHCP, not DNS) but is the right reference point for what "Admin
UI-visible PowerDNS zone rollback" should eventually look like.

## 5. Summary table

| Area | State | Where |
|---|---|---|
| Static `pdns.conf`/`recursor.conf` settings (API key, TSIG, DDNS allow-from, query logging, root mirror, legacy AXFR secondary) | Config-file-only, implemented | `services/dns/entrypoint.sh`, `docs/architecture-ng.md` |
| CDN domain list (RPZ + SSL cert scope) | Admin UI, implemented | `services/ui/src/routes/domains.rs`, `/domains` |
| `lan.` zone records (A/AAAA/CNAME/MX/TXT) | Admin UI, implemented | `services/ui/src/routes/domains.rs`, `/domains` |
| `local.lan.` / reverse zone records | No Admin UI route | Planned, v0.3.0 candidate |
| PTR checkbox on LAN A records | Not built (doc claimed it; code doesn't have it) | Planned, v0.3.0 candidate |
| Global AAAA filter | Admin UI, implemented | `services/ui/src/routes/domains.rs`, `filter-aaaa.lua` |
| Arbitrary zone create/delete | Not planned | Deliberately out of scope |
| RPZ direct record editor | Not planned | Deliberately out of scope (edit via CDN domain list instead) |
| Legacy PowerDNS-native secondary/AXFR | Config-file-only, implemented, no UI planned | `services/dns/entrypoint.sh` |
| NATS-based secondary registration/rotate/remove | Admin UI, implemented | `services/ui/src/routes/secondaries.rs`, `/secondaries` |
| NATS secondary replication-health indicator | Not built | Planned, v0.3.0 candidate |
| Static config snapshot/rollback status indicator | Not built (log-only today) | Planned, v0.3.0 candidate, not DNS-specific |
| Zone/record snapshot/rollback (#628) | Design scoped (PR #730), zero code | Planned, v0.3.0 candidate, blocked on the NATS-replication design question above |

## How to use this document

If you are about to remove, "clean up," or flag as dead any DNS/PowerDNS-
adjacent code that looks incomplete, check this document first. If the gap
you found is listed under "planned but unbuilt" or "scoped design, not yet
implemented" above, it is intentional — file or link a v0.3.0-scoped issue
instead of deleting it, and update this document if the scope decision
changes. If it's not listed here at all, that's this document's own gap:
update it rather than guessing.
