# Known-Good Configuration Snapshots

LanCache-NG regenerates several runtime-managed service configurations from
templates, environment variables, and files such as `cdn-domains.txt` every
time a container starts (or, for Kea, whenever the Admin UI pushes a change).
This mechanism keeps a small, validated history of those generated configs so
a bad regeneration — a malformed `cdn-domains.txt` entry, a template bug
introduced by an upgrade, a bad env var — does not either crash-loop the
container or silently run with an invalid config.

This is separate from `setup.sh backup`/`restore` (see
[backup-restore.md](backup-restore.md)), which is a manual, operator-driven
disaster-recovery mechanism covering the whole install. Known-good snapshots
are small, automatic, config-only, and scoped to one service's own generated
runtime config.

Related: issue #415 (parent), #614 (Kea adapter). Related but distinct: the
Kea DHCP mutation path's single-level, in-request rollback added in PR #380
(see "Kea" below).

## Contract

The generic contract (implemented once, documented in
`scripts/lib/known-good-snapshots.sh`, and followed by every file-based
adapter) is:

1. **Validate before snapshotting.** A snapshot is only created after the
   candidate config passes that service's real validation command (`nginx
   -t`, `dnsmasq --test`, Kea `config-test`). Nothing invalid is ever
   snapshotted.
2. **Retention is configurable, default 3.** `KEEP_KNOWN_GOOD_CONFIGS`
   controls how many validated snapshots are kept per service; the oldest
   are pruned automatically whenever a new one is created. The default of 3
   applies if the variable is unset, empty, or not a positive integer.
3. **Snapshots live in a persistent, service-owned volume**, never in the
   ephemeral container layer, so they survive container recreation:

   | Service | Snapshot path (in-container) | Volume |
   |---|---|---|
   | proxy (nginx) | `/var/lib/lancache-proxy/config-snapshots` | `proxy-config-snapshots` |
   | dhcp-proxy (dnsmasq) | `/var/lib/lancache-dhcp-proxy/config-snapshots` | `dhcp-proxy-config-snapshots` |
   | dns-standard, dns-ssl (PowerDNS recursor + auth) | `/var/lib/lancache-dns/config-snapshots/{recursor,auth}` | `pdns-config-snapshots-standard`, `pdns-config-snapshots-ssl` |
   | dns-secondary (remote secondary node, same image/entrypoint) | `/var/lib/lancache-dns/config-snapshots/{recursor,auth}` | `pdns-config-snapshots` |
   | dhcp (Kea) | `/var/lib/kea/config-snapshots` — see "Kea" below | `kea-data` (shared with the `dhcp` service) |

4. **Rollback refuses invalid snapshots.** When a candidate config fails
   validation, the adapter tries every stored snapshot from newest to
   oldest, re-validating each one before applying it. A snapshot that fails
   validation is rejected and logged; it is never applied. If no snapshot
   validates (or none exist), the destination files are left exactly as
   they were before the rollback attempt was made, and the caller treats
   this as fatal (refuses to start rather than run with something unverified).
5. **Every lifecycle event is logged explicitly**, tagged
   `[known-good-snapshot][<service>][<LEVEL>]` with `LEVEL` one of `CREATE`,
   `PRUNE`, `SELECT` (chosen for rollback), or `REJECT`/`FATAL`.

### Why the contract is one document but several files per adapter, not one shared file

`scripts/lib/known-good-snapshots.sh` is the canonical, tested reference
implementation. It is not baked into the `proxy`, `dhcp-proxy`, or `dns`
container images via a shared Docker build context, because each of those
Dockerfiles builds from its own isolated service directory
(`services/proxy/`, `services/dhcp-proxy/`, `services/dns/`) with no
shared-file context wired up for any of them — unlike `cdn-domains.txt`,
which already uses a named `dns-domains` additional build context for the
`proxy` image only. Extending that pattern to a second shared context for
every image would require `build-push.yml`'s image build matrix to support
multiple `--build-context` values per image, which it does not today
(`build_contexts` is treated as one `name=path` pair). Given the mechanism
itself is genuinely small (roughly 150 lines of straightforward bash), each
entrypoint embeds a byte-identical copy of the same functions instead,
marked with `# BEGIN known-good-snapshot library` /
`# END known-good-snapshot library` comments.
`tests/bats/known_good_snapshots_sync.bats` fails if any embedded copy ever
drifts from `scripts/lib/known-good-snapshots.sh`, so "generic" here means
one documented, behaviorally-verified contract that happens to exist as
four physically-identical copies (the canonical file plus one embedded copy
each in proxy, dhcp-proxy, and dns), not literal single-file reuse at
runtime.

## nginx / proxy

`services/proxy/entrypoint.sh` regenerates `nginx.conf`, `proxy-params.conf`,
the SSL/security maps (`00-ssl-map.conf`), and the stream target map
(`00-stream-targets.conf`) on every start from templates, env vars, and
`cdn-domains.txt`. After generation:

- `nginx -t` validates the live config in place (there is no way to validate
  an isolated copy in a temp location, because `nginx.conf` includes
  `/etc/nginx/conf.d/*.conf` and `/etc/nginx/stream.d/*.conf` via fixed
  absolute paths, not relative ones — validation always checks the real,
  currently-generated files).
- If valid: the four generated files are snapshotted, oldest pruned beyond
  `KEEP_KNOWN_GOOD_CONFIGS` (default 3), and nginx starts normally.
- If invalid: the entrypoint tries every stored snapshot, newest to oldest,
  copying each one's files onto the live config paths and re-running
  `nginx -t` after each copy. The first snapshot that validates is kept in
  place and nginx starts from it. If none validate (including "no snapshots
  exist yet"), the container exits non-zero rather than starting nginx with
  a config that failed validation.

Static, non-templated files (`conf.d/http.conf`, `conf.d/https.conf`,
`public_suffix_list.dat`) are not snapshotted; they are not runtime-managed
and are already covered by the image build.

**Operational risk to know about:** if the fallback path is ever taken, nginx
keeps running on a *stale* known-good config while the newly generated one —
whatever an operator most recently changed (a `cdn-domains.txt` edit,
`PROXY_SECURITY_MODE`, an env var) — was rejected. If the underlying source
of the bad generation is not fixed, every subsequent restart regenerates the
same broken candidate and falls back again, silently running on
increasingly stale config. The `WARNING`/`ERROR` log lines at fallback time
are the only current signal of this; there is no separate health/status
indicator. Watch container logs after any config change that requires a
proxy restart.

## dnsmasq / dhcp-proxy

`services/dhcp-proxy/entrypoint.sh` renders `/etc/dnsmasq.conf` from
`dnsmasq.conf.template` (via envsubst, for the four required env vars
`DHCP_SUBNET_START`, `DHCP_DNS_PRIMARY`, `DHCP_DNS_SECONDARY`,
`UPSTREAM_DHCP_IP`) plus the issue #450 optional dnsmasq relay/proxy options
(router/NTP/domain/PXE-boot/custom options, appended conditionally by
`_dhcp_proxy_render_optional_directives` rather than templated, since an
unset optional value must produce no line at all -- see
`docs/dhcp-modes.md`) on every start. This mode has no live/UI-driven config
mutation, so, like nginx, the only meaningful trigger for rollback is "the
config this container is about to start with is invalid":

- `dnsmasq --test -C /etc/dnsmasq.conf` validates the generated config
  before dnsmasq actually starts.
- If valid: the config is snapshotted and pruned to `KEEP_KNOWN_GOOD_CONFIGS`
  (default 3).
- If invalid: same newest-to-oldest rollback search as nginx, validating each
  snapshot with the same `dnsmasq --test` command before accepting it. If
  none validate, the container exits non-zero instead of starting dnsmasq
  with an invalid config.

Same operational risk as nginx applies: a persistently broken input
(`UPSTREAM_DHCP_IP` typo, etc.) falls back to the same stale snapshot on
every restart until the input is fixed.

## Kea

Kea already has a real, working, single-level safety net from PR #380:
`kea_config_modify()` in `services/ui/src/routes/dhcp.rs` retains the config
from `config-get`, applies the candidate via `config-test` → `config-set`,
and — if the follow-up `config-write` (persist to disk) fails in a confirmed
way — rolls back to the retained old config via another `config-set`. That
protects one request's mutation from leaving the running and persisted
config diverged, but on its own it is in-memory and scoped to a single
request: it kept no multi-generation history on disk, and had no
`KEEP_KNOWN_GOOD_CONFIGS`-style retention or rollback-to-an-older-snapshot
capability for Kea.

#614 adds that persisted layer on top, without replacing PR #380's
single-request safety net. Unlike the nginx/dnsmasq/PowerDNS adapters, Kea's
config is mutated live through this Admin UI's own Rust HTTP client against
the Kea Control Agent, not regenerated from a shell template at container
startup — so this adapter is not a byte-identical embedded shell library
copy like the other three. It is a Rust reimplementation of the same
documented contract, in `services/ui/src/kea_snapshots.rs`:

- **Snapshot creation is a side effect of `kea_config_modify()`'s existing
  chain**, not a separate step: every one of the DHCP mutation routes
  (subnet/reservation add/update/remove, DHCP option add/remove) already
  goes through `config-get` → modify → `config-test` → `config-set` →
  `config-write`. On a confirmed `config-write` success, the exact validated
  and applied config is snapshotted into `/var/lib/kea/config-snapshots`
  (the persistent `kea-data` volume, shared with the `dhcp` service), then
  pruned to `KEEP_KNOWN_GOOD_CONFIGS` (default 3, same variable and default
  as the other adapters). This satisfies "validate before snapshotting"
  without a redundant second `config-test`: the existing chain already
  gates it.
- Snapshot creation is best-effort and non-fatal, matching the nginx
  adapter's own treatment of a failed `kgs_snapshot_create`: if writing the
  snapshot fails (e.g. the shared volume is unexpectedly unwritable), the
  mutation itself still succeeds (it was already applied and persisted by
  Kea), and a `WARNING` is logged that rollback protection is degraded until
  it succeeds again.
- **Rollback is operator-selected, not automatic.** The nginx/dnsmasq/
  PowerDNS adapters search their stored snapshots newest-to-oldest
  automatically, because "the config this container is about to start with
  is invalid" is their only rollback trigger, at a single well-defined
  moment (container startup). Kea has no equivalent moment — its config
  only ever changes through this Admin UI, live. So the `/dhcp` page lists
  known-good snapshots (newest first) and an operator picks one explicitly;
  only that snapshot is validated (via `config-test`, logging `REJECT` and
  refusing the rollback if it fails) and applied (via the same
  `kea_config_modify()` chain, which also verifies persisted state through
  its existing `config-write` confirmation and records a fresh snapshot of
  the restored config).
- `KEA_CONFIG_SNAPSHOT_DIR` (default `/var/lib/kea/config-snapshots`) and
  `KEEP_KNOWN_GOOD_CONFIGS` (default 3, same variable name as the shell
  adapters) configure this adapter; both are read by the Admin UI process,
  not a shell entrypoint.
- The `dhcp` (Kea) container's `services/dhcp/entrypoint.sh` chowns
  `config-snapshots/` to the Admin UI's fixed UID/GID (10001) on every
  start, since that container runs as root and the Admin UI runs as a fixed
  non-root user — the same pattern already used to keep the shared
  `nats.conf` writable by the Admin UI after a NATS restart (see
  `deploy/*/docker-compose.yml`'s `nats` service).
- `tests/bats/known_good_snapshots_sync.bats` does not (and should not)
  cover this adapter: there is no embedded shell copy to drift, since none
  of this lives in a shell entrypoint. Coverage lives in
  `services/ui/src/kea_snapshots.rs`'s and `services/ui/src/routes/dhcp.rs`'s
  own `cargo test` suites instead.

## PowerDNS

PowerDNS's state splits into two very different categories, and only the
first reuses the generic file-snapshot mechanism (#615). The second needs
its own mechanism, described in its own terms below; see "Zones, records,
and TSIG/DDNS metadata" below.

### Static service config — `pdns.conf` / `recursor.conf` (implemented, #615)

`services/dns/entrypoint.sh` regenerates `recursor.conf` and
`pdns.conf` on every start from templates and env vars (`PDNS_API_KEY`,
`DDNS_ALLOW_FROM`, `LOG_QUERIES`) via `render_template_atomic()`. This is the
same shape of problem as nginx/dnsmasq — file-based, deterministically
regenerated — and reuses the exact same generic contract, but the two files
belong to two independent daemons (the recursor and the authoritative
server) with two independently-generated configs, so each is validated,
snapshotted, and rolled back **separately**: a broken `recursor.conf` does
not block a still-good `pdns.conf` from starting, and vice versa, *as long
as rollback succeeds* — i.e. a known-good snapshot exists for the failing
side. The entrypoint validates the recursor first
(`_dns_recursor_validate_snapshot_or_rollback ... || exit 1`) and, on a fresh
install or once snapshot history is exhausted, that call returns 1 and the
container exits before ever reaching `pdns.conf` generation/validation — so
on those two occasions a broken `recursor.conf` genuinely does prevent the
authoritative server from starting too. Both live
under one persistent volume per `dns-standard`/`dns-ssl` container
(`pdns-config-snapshots-standard`, `pdns-config-snapshots-ssl`, mounted at
`/var/lib/lancache-dns`), in separate `recursor/` and `auth/` subdirectories
so the two independent snapshot histories never collide. A remote secondary
DNS node (`setup.sh secondary`, `deploy/secondary/docker-compose.yml`) runs
the same `dns` image and entrypoint, so it gets the identical
`/var/lib/lancache-dns/config-snapshots/{recursor,auth}` layout too — its own
persistent volume there is named `pdns-config-snapshots` (one node, so no
`-standard`/`-ssl` suffix is needed).

**recursor.conf: pure pre-start check, like `nginx -t`.** Debian Trixie's
`pdns-recursor` package (5.2.x) ships a genuine, side-effect-free check-only
invocation: `pdns_recursor --config=check --config-dir=<dir>`. Verified
empirically against the real packaged binary (not assumed from
documentation) before writing the adapter: it parses and validates the YAML
config and exits non-zero on error — both on a YAML syntax error and on a
semantically-invalid-but-syntactically-fine config (an unrecognized
top-level key) — without binding any sockets or starting the recursor. This
is exactly the pure pre-start validator the other two adapters use, so
`_dns_recursor_validate_snapshot_or_rollback()` in
`services/dns/entrypoint.sh` follows the identical
validate-then-snapshot-or-rollback shape as
`_proxy_validate_snapshot_or_rollback()` /
`_dhcp_proxy_validate_snapshot_or_rollback()`, just with
`pdns_recursor --config=check` as the validator command.

**pdns.conf: also a pure pre-start check, once verified live.** An earlier
draft of this adapter assumed `pdns_server` had no check-only flag, because
its `--help` output doesn't spell out "check" as a value the way
`pdns_recursor`'s `--help` explicitly does ("You can use --config=check to
test the config file...") — `pdns_server --help` only documents `--config`
as "Provide configuration file on standard output" and `--no-config` as
"Don't parse configuration file", with no mention of a check mode. That
draft built a start-then-verify probe instead: start `pdns_server` in the
foreground, poll the control socket with `pdns_control rping`, then tear
the probe down either way. Before merging, `--config=check` was tried
directly against the real Debian Trixie `pdns-server` package (4.9.x) on a
self-hosted runner anyway (rather than trusting the absence of documentation)
and turned out to work exactly like `pdns_recursor --config=check`: it
parses the config, attempts to load the configured `launch=` backend
module, and exits non-zero on error — confirmed against an unloadable
backend module and an unknown/malformed setting (the realistic failure mode
here, since a broken `PDNS_API_KEY`/`DDNS_ALLOW_FROM` template substitution
produces exactly that) — all without ever binding a port or leaving a
process running. `_dns_auth_validate_snapshot_or_rollback()` in
`services/dns/entrypoint.sh` therefore uses
`pdns_server --config=check --config-dir=<dir>` directly, the same
validate-then-snapshot-or-rollback shape as every other adapter here,
instead of the more complex probe — no `_dns_auth_probe()` function exists
in the merged version of this adapter.

One real limitation carries over either way: neither `--config=check` nor
a full running daemon validates semantic values such as CIDR syntax in
`allow-dnsupdate-from` — confirmed empirically (starting a real
`pdns_server` with a garbage `allow-dnsupdate-from` value still binds its
port and answers `pdns_control rping` normally). This is a pre-existing
PowerDNS behavior, not a gap introduced by preferring the simpler
check-only flag over a full start.

Ordering matters here in a way it does not for nginx/dnsmasq: pdns.conf
validation/rollback runs *before* any `pdnsutil` call in the entrypoint
(zone creation, TSIG import), because those calls also read `pdns.conf` via
`--config-dir` — if pdns.conf is rolled back to a known-good snapshot,
every subsequent `pdnsutil` call in that same startup must see the rolled-
back config, not the rejected candidate. It's kept positioned after the
SQLite database file exists and before zone creation / `configure_ddns_tsig`
for that reason, even though `--config=check` itself doesn't actually
require the database file to exist (confirmed empirically — it still exits
0 with a nonexistent `gsqlite3-database=` path, since it does not open the
backend the way a full start does).

**Operational risk to know about:** same shape as nginx/dnsmasq — if the
fallback path is taken, PowerDNS keeps running on a stale known-good config
while the newly generated one (whatever `PDNS_API_KEY`/`DDNS_ALLOW_FROM`/
`LOG_QUERIES` change an operator most recently made) was rejected, and every
restart re-generates and re-rejects the same broken candidate until the
underlying input is fixed. The `WARNING`/`ERROR` `[lancache-dns]` log lines
at fallback time are the only current signal.

### Zones, records, and TSIG/DDNS metadata

Authoritative over `pdns.sqlite3` and mutated live via `pdnsutil`, the
Admin UI's DDNS/NATS sync path, and dynamic DNS updates from Kea. This is
API/database-backed state, not a config file, so it cannot reuse the
generic file-snapshot contract (#615) as-is: a blind file-level
snapshot/restore of `pdns.sqlite3` while the daemon is live risks capturing
an inconsistent database file, and "rolling back" zone/record data has
completely different implications than rolling back a static config file —
it can silently undo legitimate client DHCP leases, DDNS-driven hostname
records, or secondary-node reconciliation state that changed after the
snapshot was taken. Issue #628 tracks this gap; this section is that
issue's design. No snapshot/rollback code exists yet for zone/record data —
everything below is the scoped design an implementation PR should follow,
not a description of running behavior.

**Scope decision.** Looking at what `services/dns/entrypoint.sh` actually
does on every start narrows the problem a lot:

- The RPZ zone (`rpz.`) is fully regenerated from `cdn-domains.txt` on
  every start (see "Generate RPZ Zone from cdn-domains.txt" in the
  entrypoint) and is never mutated any other way. It needs no snapshot at
  all — restoring `cdn-domains.txt` (already covered by
  `setup.sh backup`/`restore`, see
  [backup-restore.md](backup-restore.md)) is sufficient to reproduce it
  exactly.
- TSIG key material and the `TSIG-ALLOW-DNSUPDATE` zone metadata are also
  fully reproducible **when `DDNS_TSIG_KEY` is set**: `configure_ddns_tsig()`
  runs unconditionally on every start, re-importing the key from
  `DDNS_TSIG_KEY`/`DDNS_TSIG_NAME`/`DDNS_TSIG_ALGORITHM` and re-setting the
  metadata on every zone in `DDNS_UPDATE_ZONES`. There is nothing here that a
  restart doesn't already reconstruct from environment variables, so this
  metadata needs no snapshot of its own in that case. That guarantee does
  not hold if `DDNS_TSIG_KEY` is later blanked: `configure_ddns_tsig()`
  returns immediately when it is empty (`services/dns/entrypoint.sh`,
  `configure_ddns_tsig()`'s `""` case) without clearing any
  `TSIG-ALLOW-DNSUPDATE` metadata or key rows a previous start already wrote,
  so a host that had DDNS enabled and then has the key removed or blanked
  (migration, config edit) can retain stale TSIG authorization that no
  restart converges away. This snapshot/rollback design does not cover that
  case; it is a pre-existing gap in `configure_ddns_tsig()` itself, tracked
  as a follow-up rather than solved here since it is about TSIG metadata
  hygiene, not zone/record rollback.
- `lan.` / `local.lan.` and the private reverse zones (`PRIVATE_REVERSE_ZONES`
  in the entrypoint) are created idempotently (`create-zone ... || true`)
  but never repopulated — their *record* contents come entirely from
  DDNS updates (Kea leases, hostname registrations) applied directly to the
  primary's PowerDNS instance. **Correction on NATS coverage:** only the
  `lan.` zone has any NATS-driven path today — the Admin UI's record
  mutation routes (`services/ui/src/routes/domains.rs`) publish with a
  hardcoded `"zone": "lan"`, and `nats-subscriber`'s `reconciler()` only
  polls/republishes `/zones/lan` (`services/dns/nats-subscriber/src/main.rs`).
  `local.lan.` and the private reverse zones have no NATS reconciliation
  path at all: Kea's `forward-ddns`/`reverse-ddns` config
  (`services/dhcp/kea-dhcp-ddns.conf`) sends DDNS updates only to the
  primary `dns-standard`/`dns-ssl` instances' own DDNS ports, never to
  `dns-secondary` nodes and never through NATS. So today, a `dns-secondary`
  node never receives `local.lan.`/reverse-zone records at all, regardless
  of rollback — this is a pre-existing replication gap this design does not
  create and cannot fix on its own; see "Secondary nodes and NATS
  replication" below for how the implementation PR must treat it.

So the only state that genuinely needs a snapshot/rollback story is the
**dynamic record data inside `lan.`, `local.lan.`, and the private reverse
zones** — not the zone list, not TSIG, not RPZ.

**Execution path: PowerDNS's HTTP API, not `pdnsutil` from a container that
can't reach it.** An earlier draft of this design routed every step through
`pdnsutil list-zone` / `check-zone` / `load-zone`. That does not work as a
whole: `pdnsutil` operates directly on the local `pdns.sqlite3` backend, so
every one of those commands can only run *inside* the `dns-standard`/
`dns-ssl` container, with `--config-dir=/etc/pdns/auth` (the config
directory the authoritative server is actually generated into by
`services/dns/entrypoint.sh` — the default `/etc/pdns` is empty in this
image; every existing `pdnsutil` call in the entrypoint, e.g.
`configure_ddns_tsig()`'s `import-tsig-key`/`set-meta` calls, already passes
this flag). The Admin UI, which the design assigns the operator-facing
rollback action to, cannot do that: `services/ui/Dockerfile` doesn't install
`pdnsutil` and doesn't mount the `pdns-config-snapshots-{standard,ssl}`
volumes, and even if it did, running `pdnsutil` from a second container
against a `pdns.sqlite3` file that a live `pdns_server` in another container
already has open is not a safe way to read or mutate it.

What the Admin UI *does* already reach is PowerDNS's Authoritative HTTP API
on port 8081 (`services/ui/src/config.rs`'s `pdns_auth_url`, default
`http://dns-standard:8081`) — the same API `services/dns/nats-subscriber`
already uses for `GET`/`PATCH /zones/lan` (`handle_dns_record`, the
`reconciler`) and the same API family whose recursor sibling on 8082 the UI
already calls for cache flushes (`flush_recursor_cache` in
`services/ui/src/routes/domains.rs`). This design therefore routes zone
snapshot capture and rollback through that API instead of `pdnsutil`:

- **Snapshot mechanism.** The canonical, rollback-usable snapshot artifact is
  the same JSON `GET /api/v1/servers/localhost/zones/<zone>` response
  `nats-subscriber` already parses elsewhere in this same process — the
  `ZoneInfo`/`rrsets` shape `reconciler()` already deserializes, and the
  same shape `handle_dns_record`'s `dns_record_to_zone_update` already
  builds `REPLACE`/`DELETE` operations from — not the `/export` endpoint.
  This matters because `/export` returns AXFR/zone-file *text*, while
  PowerDNS's `PATCH /zones/{zone}` consumes JSON `rrsets`; storing the AXFR
  text as "the snapshot" would leave rollback with no defined way to turn it
  back into `rrsets` JSON without writing and maintaining a zone-file parser
  that does not exist anywhere in this codebase today. Storing the same
  JSON shape the reconciler and `handle_dns_record` already speak avoids
  that problem entirely and keeps one rrset representation across the whole
  adapter. `services/dns/nats-subscriber` — which already runs inside the
  `dns-standard`/`dns-ssl` container and already speaks this API — issues
  this call and writes the result under
  `${DNS_CONFIG_SNAPSHOT_DIR}/zones/<zone>`, one `snapshot_root` per zone,
  applying the same `KEEP_KNOWN_GOOD_CONFIGS` retention default as every
  other adapter. An implementation PR may additionally store the `/export`
  AXFR text alongside the JSON purely as a human-readable artifact for
  manual inspection (see "Manual recovery" below) — but it is never the
  thing rollback diffs or patches from; the JSON `rrsets` snapshot is the
  only artifact the rollback path itself reads. Because `nats-subscriber` is
  a compiled Rust binary in its own process (`services/dns/Dockerfile` copies it to
  `/usr/local/bin/nats-subscriber` and the entrypoint execs it as a separate
  process at the bottom of the file), it cannot call the `kgs_*` shell
  functions embedded in `services/dns/entrypoint.sh` — a child process
  cannot invoke its parent shell's functions, and
  `scripts/lib/known-good-snapshots.sh` is not even copied into this image
  (`services/dns/Dockerfile` has no such `COPY`). This adapter therefore
  needs its own Rust reimplementation of the retention primitives (create/
  list/prune), the same decision already made for Kea's
  `services/ui/src/kea_snapshots.rs` — not a fourth embedded shell copy, and
  not a cross-process call into `entrypoint.sh`.
- **Trigger point.** `nats-subscriber`'s `handle_dns_record` (the NATS-driven
  apply path) is one trigger, but not the only in-scope write path: Kea's
  DDNS updates (`services/dhcp/kea-dhcp-ddns.conf`'s `forward-ddns`/
  `reverse-ddns` `dns-servers`) go straight to PowerDNS over TSIG-
  authenticated DNS UPDATE, bypassing NATS and `nats-subscriber` entirely.
  A design that only snapshots after a NATS-applied write would silently
  stop covering DHCP-driven lease/PTR record changes, which this section
  claims are in scope. The implementation PR must add a second trigger for
  DDNS-originated changes — e.g. a periodic export-and-diff similar in
  shape to the existing 60-second `reconciler`, or a PowerDNS
  primary-notify-style hook — rather than relying solely on the NATS apply
  point.
  Two further requirements apply to whichever trigger(s) end up
  implemented:
  - **Skip no-op applies.** The existing `reconciler` (services/dns/nats-
    subscriber/src/main.rs:442-541) polls `/zones/lan` every 60 seconds and
    republishes every non-SOA/NS rrset unconditionally, regardless of
    whether anything changed; JetStream's default ~120s duplicate-message
    window only partially absorbs this. A trigger that snapshots on every
    confirmed apply without comparing content would let these periodic
    republishes burn through the default retention of 3 snapshots within
    minutes, pushing out genuinely different history. The trigger must
    compare the freshly exported zone against the most recently stored
    snapshot (e.g. a content hash) and skip snapshot creation when nothing
    changed.
  - **Snapshot failures are best-effort, never fatal to message
    acknowledgment.** `nats-subscriber`'s consumer loop only calls
    `msg.ack().await` when `handle_message` returns `true`; on `false` it
    lets JetStream redeliver
    (services/dns/nats-subscriber/src/main.rs:187-200). If a post-apply
    snapshot/export failure were folded into that same return value, an
    already-applied and already-confirmed PATCH would be redelivered and
    reapplied indefinitely whenever the snapshot volume or helper is
    unavailable — stalling this consumer even though PowerDNS already has
    the correct data. `handle_dns_record`/the DDNS-side trigger must log
    (`[known-good-snapshot][dns][...]`) and otherwise treat a snapshot
    failure as non-fatal: still return `true`/ack the already-applied write.
- **Validation.** Snapshot creation is validated by construction: a
  snapshot is only captured from a `GET .../zones/<zone>` (the JSON `rrsets`
  form described above) immediately after a `PATCH .../zones/<zone>` call
  PowerDNS itself already accepted (a 2xx response), so there is no
  separate pre-snapshot check to run — unlike
  nginx/dnsmasq/pdns.conf/recursor.conf, there is no free-standing candidate
  file to validate before it exists; the API's own acceptance of the PATCH
  *is* the validation gate. This replaces an earlier draft's `pdnsutil
  check-zone <zone>` step here, which was not actually possible as
  described: `check-zone` validates the zone already loaded into the
  backend, not an arbitrary file, so it cannot pre-validate an export before
  accepting it as a snapshot. `pdnsutil check-zone --config-dir=/etc/pdns/auth
  <zone>` (run locally by `nats-subscriber` inside the `dns-standard`/
  `dns-ssl` container, where `pdnsutil` and the live backend both already
  exist) remains useful as a *secondary structural sanity check* — SOA
  serial sanity, dangling CNAME targets, delegation consistency, none of
  which the API's per-RR validation catches — but only as a check against
  the zone's current live state (before snapshotting, or after a rollback
  has already been applied), never as a way to pre-validate a candidate file
  in isolation.
- **Applying a rollback stays operator-selected, never automatic.** Because
  no structural check can judge semantic correctness (whether a zone's
  contents are consistent with Kea's current DHCP leases or NATS's current
  reconciliation state right now), and because restoring an older zone
  snapshot can undo real client leases or hostnames created since that
  snapshot, this follows the same pattern already documented above for Kea:
  an operator picks a specific timestamped snapshot for a specific zone.
  Execution needs a DNS-side path the Admin UI can actually reach, since (as
  established above) the UI cannot run `pdnsutil` itself: `nats-subscriber`
  — already resident in the `dns-standard`/`dns-ssl` container, already
  holding the snapshot files it wrote, and already speaking the PowerDNS API
  — is the natural place for a small local HTTP listener (a new port,
  alongside PowerDNS's own 8081/8082) that the Admin UI calls to list
  snapshots for a zone and to trigger a rollback. On a rollback request,
  `nats-subscriber` diffs the snapshot's rrsets against the zone's current
  rrsets (`GET .../zones/<zone>`, which it already knows how to call) and
  issues the equivalent `PATCH .../zones/<zone>` — `REPLACE` for every rrset
  present in the snapshot, `DELETE` for every current rrset absent from it
  — mirroring the `dns_record_to_zone_update` shape `handle_dns_record`
  already implements, then re-runs the `check-zone` structural sanity check
  from the point above as a post-apply confirmation. No automatic
  startup-time rollback is ever attempted for zone data, unlike the
  nginx/dnsmasq/PowerDNS static-config adapters above.
- **The rollback listener must require authentication.** A local HTTP
  listener that can list zone snapshots and trigger a `PATCH`-based rollback
  is a control-plane endpoint, not a read-only status page, and this
  project never treats Docker Compose network reachability alone as a trust
  boundary for anything comparable: PowerDNS's own Authoritative HTTP API on
  port 8081 is reachable by every container on the same network this new
  listener would be, and it still requires the `X-API-Key` header
  (`PDNS_API_KEY`) on every call (`services/dns/nats-subscriber/src/main.rs`,
  `services/ui/src/routes/domains.rs`); NATS itself went further and moved
  from a single shared credential to individually-revocable per-secondary
  identities via an auth callout (`services/ui/src/nats_auth_callout.rs`,
  #583) rather than relying on network placement alone. A rollback listener
  with no equivalent check would let anything else reachable on the same
  Compose network — not just the Admin UI — list and roll back zone
  snapshots, silently bypassing whatever authentication the Admin UI itself
  enforces on the operator. The implementation PR must gate this listener
  the same way this project already gates every comparable internal
  surface: require a shared key on every request (reusing `PDNS_API_KEY` via
  the same `X-API-Key` header convention is the natural fit, since
  `nats-subscriber` already holds that value in memory for its own calls to
  PowerDNS's API), and treat binding the listener to a container-local/
  loopback-only address as defense-in-depth on top of that check, never as
  a substitute for it.
- **Flush recursor caches after a rollback.** A `load`/`PATCH`-style
  rollback can change or delete many names in one operation, but
  `flush_recursor_cache` (`services/ui/src/routes/domains.rs:264-289`)
  documents that PowerDNS Recursor's flush endpoint only clears an exact
  name — even `?domain=lan.` leaves an already-changed leaf record cached —
  and the recursor's packet cache keeps successful answers for 3600 seconds
  by default (`services/dns/recursor.conf.template`'s `packetcache.ttl`).
  Re-running `check-zone` after a rollback confirms the authoritative data
  is structurally sound, but says nothing about what recursors are still
  serving from cache. The rollback path must enumerate every name whose
  rrset changed (available directly from the diff computed in the point
  above) and flush each one against every recursor instance (both
  `dns-standard` and `dns-ssl`, matching the two-mode/two-IP architecture),
  not rely on a single whole-zone or root flush call.

**Secondary nodes and NATS replication.** Every DNS node (primary and each
remote secondary from `setup.sh secondary`) runs its own
`nats-subscriber` consuming the same JetStream stream and applying updates
to its own local PowerDNS instance independently — record data is
replicated through NATS messages, not through file or database copying
between nodes, **but only for the `lan.` zone today** (see the correction
under "Scope decision" above: the reconciler and the Admin UI's publish
path are both hardcoded to `zone: "lan"`, and `local.lan.`/reverse-zone
DDNS updates go straight to the primary, never through NATS). Two separate
things follow from that:

- For `lan.`, an implementation PR must confirm how a rollback on one node
  interacts with existing NATS replication: applying the rollback's `PATCH`
  locally changes only that node's own database, so a rollback on the
  primary needs an explicit answer for whether/how it re-publishes the
  restored state onto the NATS stream so secondaries converge to the same
  records, rather than leaving the primary and its secondaries silently
  holding different data for the rolled-back zone. JetStream's own message
  history is itself a form of replay log for these changes and may turn out
  to be part of the answer.
- For `local.lan.` and the private reverse zones, there is no existing NATS
  replication to preserve or break in the first place — a rollback on the
  primary for these zones only ever affects that one node, exactly like
  every DDNS write to them already does today. The implementation PR must
  either extend NATS coverage to these zones (so both normal DDNS-driven
  convergence and rollback convergence work the same way `lan.` does), or
  explicitly document that `dns-secondary` nodes do not carry `local.lan.`/
  reverse-zone records and will not converge after a rollback either. Either
  way, this design does not silently assume replication that does not
  exist.

**Known gap: this rollback path assumes the container is reachable.**
Everything described above — the Admin UI listing zone snapshots, an
operator picking one, `nats-subscriber`'s local admin listener applying the
diffed `PATCH` inside the `dns-standard`/`dns-ssl` container — depends on an
operator (or the Admin UI acting on their behalf) actually being able to
reach that container's listener. That assumption is not safe in precisely the scenario this mechanism
exists to help with: if PowerDNS is crash-looping because its own
zone/record data is broken — the same class of problem `check-zone` and
rollback are meant to fix — the container may never stay up long enough
to be reached, and the rollback tool built to fix that state becomes
unreachable during the very crash-loop it exists to resolve. This is not
unique to PowerDNS: the Kea adapter documented above has the identical
latent gap, since its rollback also goes through a running Kea Control
Agent. A real fix — a degraded-but-reachable "rescue mode" a
crash-looping service can come up in specifically so an operator can
intervene, plus a DAU-readable recovery runbook for this whole document —
is tracked separately in issue #763 and is explicitly out of scope for
this design. Until #763 lands, read everything in this section as *the
rollback mechanism once the container is reachable*, not as a complete
incident-recovery story for a PowerDNS zone/record crash-loop.

## Manual recovery

If a service ever exhausts its known-good snapshots (fresh install with no
prior successful start, or every snapshot also fails validation — e.g. after
a `dnsmasq`/`nginx` version upgrade that rejects previously-valid syntax),
the container refuses to start and logs `FATAL` known-good-snapshot lines.
Fix the underlying input (`cdn-domains.txt`, template, env var) and restart;
there is no separate CLI to inspect or hand-pick a snapshot for the
nginx/dnsmasq/PowerDNS adapters. The snapshot directories are plain files
under the volumes listed above and can be inspected directly with
`docker compose exec` /
`docker run --rm -v <volume>:/data busybox ls -la /data` for manual triage if
needed.

Kea has no equivalent exhaustion state, since it never rolls back
automatically: an operator picks a snapshot from the `/dhcp` page's list, and
if none there look right, `kea-dhcp4.conf` on disk is untouched by a failed
rollback attempt (`kea_config_modify()`'s existing PR #380 behavior). If the
Admin UI itself is unreachable, the snapshot JSON files under
`kea-data`'s `config-snapshots/` (mounted at `/var/lib/kea/config-snapshots`
in both the `ui` and `dhcp` containers) can be inspected the same way, and a
chosen one applied manually against the Kea Control Agent API
(`config-test` → `config-set` → `config-write`, the same three-call
sequence the Admin UI itself uses).

The PowerDNS zone/record adapter designed above under "Zones, records, and
TSIG/DDNS metadata" has no equivalent manual-CLI fallback documented here
yet. Like Kea's on-disk snapshot JSON files, its snapshots are also stored
as JSON `rrsets` (see "Snapshot mechanism" above), but there is currently no
established procedure for inspecting one directly and hand-applying it
outside the Admin UI — largely because the snapshot mechanism itself does
not exist yet; that section is a scoped design for a future implementation
PR, not running behavior today. Once it is implemented, it will still share
the same underlying limitation called out above: any fallback procedure
documented here would still need either `nats-subscriber`'s local admin
listener reachable inside the `dns-standard`/`dns-ssl` container (and,
per the auth requirement above, credentials for it), or, for the stored
JSON snapshot files themselves, the container reachable to inspect them and
run `pdnsutil --config-dir=/etc/pdns/auth check-zone` against the live zone
directly — which is exactly the gap issue #763 is meant to close. Writing
that fallback procedure down is therefore deferred to #763 rather than
invented here
ahead of the mechanism it would document.
