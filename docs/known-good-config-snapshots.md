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

### Why the contract is one document but two files per adapter, not one shared file

`scripts/lib/known-good-snapshots.sh` is the canonical, tested reference
implementation. It is not baked into the `proxy` or `dhcp-proxy` container
images via a shared Docker build context, because each of those Dockerfiles
builds from its own isolated service directory
(`services/proxy/`, `services/dhcp-proxy/`) with no shared-file context wired
up for either — unlike `cdn-domains.txt`, which already uses a named
`dns-domains` additional build context for the `proxy` image only. Extending
that pattern to a second shared context for both images would require
`build-push.yml`'s image build matrix to support multiple `--build-context`
values per image, which it does not today (`build_contexts` is treated as one
`name=path` pair). Given the mechanism itself is genuinely small (roughly 150
lines of straightforward bash), each entrypoint embeds a byte-identical copy
of the same functions instead, marked with
`# BEGIN known-good-snapshot library` / `# END known-good-snapshot library`
comments. `tests/bats/known_good_snapshots_sync.bats` fails if either
embedded copy ever drifts from `scripts/lib/known-good-snapshots.sh`, so
"generic" here means one documented, behaviorally-verified contract that
happens to exist as three physically-identical copies, not literal
single-file reuse at runtime.

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

## PowerDNS (design only, not implemented)

PowerDNS is explicitly treated differently in issue #415, and this PR does
not implement PDNS snapshot/rollback. PowerDNS's state splits into two very
different categories:

1. **Static service config** — `pdns.conf` and `recursor.conf`, rendered by
   `services/dns/entrypoint.sh`'s `render_template_atomic()` from templates
   and env vars (`PDNS_API_KEY`, `DDNS_ALLOW_FROM`, `LOG_QUERIES`). This is
   the same shape of problem as nginx/dnsmasq: file-based, deterministically
   regenerated, and could in principle use the exact same
   validate-then-snapshot contract described above. PowerDNS does not expose
   a dedicated "check config, don't start" flag equivalent to `nginx -t` or
   `dnsmasq --test`; `pdns_control` requires a running daemon. A safe adapter
   for this piece alone would need either a short-lived
   `pdns_server --config-check`-equivalent invocation (verify current
   PowerDNS version support before relying on it) or a start-then-verify
   pattern (start, confirm the control socket responds and the config it
   loaded matches what was intended, otherwise stop and fall back) rather
   than the pure pre-start validation the other two adapters use.
2. **Zones, records, and TSIG/DDNS metadata** — authoritative over
   `pdns.sqlite3` and mutated live via `pdnsutil`, the Admin UI's DDNS/NATS
   sync path, and dynamic DNS updates from Kea. This is API/database-backed
   state, not a config file. A blind file-level snapshot/restore of
   `pdns.sqlite3` while the daemon is live risks capturing an inconsistent
   database file, and "rolling back" zone/record data has completely
   different implications than rolling back a static config file — it can
   silently undo legitimate client DHCP leases, DDNS-driven hostname
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
   API/database-backed state.

Given that, the honest scope for PDNS in this PR is this documented design,
not an implementation. Follow-up issue #615 scopes PDNS static-config
snapshotting (item 1 above, which likely *can* reuse the generic contract
directly) separately from any zone/record rollback design (item 2, which
needs its own explicit export/validate/apply/verify flow per the issue's
acceptance criteria, and should stay out of the generic file-snapshot
mechanism entirely).

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
