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
first is in scope for the generic file-snapshot mechanism (#615). The
second is explicitly deferred; see "Zones, records, and TSIG/DDNS metadata
(deferred)" below.

### Static service config — `pdns.conf` / `recursor.conf` (implemented, #615)

`services/dns/entrypoint.sh` regenerates `recursor.conf` and
`pdns.conf` on every start from templates and env vars (`PDNS_API_KEY`,
`DDNS_ALLOW_FROM`, `LOG_QUERIES`) via `render_template_atomic()`. This is the
same shape of problem as nginx/dnsmasq — file-based, deterministically
regenerated — and reuses the exact same generic contract, but the two files
belong to two independent daemons (the recursor and the authoritative
server) with two independently-generated configs, so each is validated,
snapshotted, and rolled back **separately**: a broken `recursor.conf` never
blocks a still-good `pdns.conf` from starting, and vice versa. Both live
under one persistent volume per `dns-standard`/`dns-ssl` container
(`pdns-config-snapshots-standard`, `pdns-config-snapshots-ssl`, mounted at
`/var/lib/lancache-dns`), in separate `recursor/` and `auth/` subdirectories
so the two independent snapshot histories never collide.

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

### Zones, records, and TSIG/DDNS metadata (deferred)

Authoritative over `pdns.sqlite3` and mutated live via `pdnsutil`, the
Admin UI's DDNS/NATS sync path, and dynamic DNS updates from Kea. This is
API/database-backed state, not a config file. A blind file-level
snapshot/restore of `pdns.sqlite3` while the daemon is live risks capturing
an inconsistent database file, and "rolling back" zone/record data has
completely different implications than rolling back a static config file —
it can silently undo legitimate client DHCP leases, DDNS-driven hostname
records, or secondary-node reconciliation state that changed after the
snapshot was taken. Restoring database state safely needs the database
backend either stopped or in a supported hot-backup mode, an explicit
decision about which zones are in scope (LAN zones vs. the CDN RPZ zone,
which is fully regenerated from `cdn-domains.txt` on every start and
therefore does not need snapshotting at all), and a clear answer for what
"invalid" even means for record data (there is no equivalent of
`nginx -t` for "is this zone file consistent with what NATS/DHCP expect
right now"). Rushing this into the generic file-snapshot contract would
violate the issue's explicit warning against blind file rollback for
API/database-backed state. This stays out of scope of the generic
file-snapshot mechanism entirely and needs its own explicit
export/validate/apply/verify design in a dedicated follow-up issue before
any implementation.

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
