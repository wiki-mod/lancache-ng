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

Related: issue #415. Related but distinct: the Kea DHCP mutation path's
single-level, in-request rollback added in PR #380 (see "Kea" below).

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
   | dhcp (Kea) | not yet implemented — see "Kea" below | n/a |

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
`dnsmasq.conf.template` and env vars (`DHCP_SUBNET_START`,
`DHCP_DNS_PRIMARY`, `DHCP_DNS_SECONDARY`, `UPSTREAM_DHCP_IP`) on every start.
This mode has no live/UI-driven config mutation, so, like nginx, the only
meaningful trigger for rollback is "the config this container is about to
start with is invalid":

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

## Kea (deferred to a follow-up issue)

Kea already has a real, working, single-level safety net from PR #380:
`kea_config_modify()` in `services/ui/src/routes/dhcp.rs` retains the config
from `config-get`, applies the candidate via `config-test` → `config-set`,
and — if the follow-up `config-write` (persist to disk) fails in a confirmed
way — rolls back to the retained old config via another `config-set`. That
protects one request's mutation from leaving the running and persisted
config diverged, but it is in-memory and scoped to a single request: it does
not keep a multi-generation history on disk, and there is no
`KEEP_KNOWN_GOOD_CONFIGS`-style retention or rollback-to-an-older-snapshot
capability for Kea today.

This PR does **not** implement persisted, multi-generation Kea snapshots.
Meeting issue #415's Kea acceptance criteria for real — "validate the
selected snapshot before applying," "verify runtime and persisted state
after rollback," preserving the existing `config-test → config-set →
config-write` model while adding a rollback-history UI — needs a new Admin
UI route, template, and Rust-side snapshot/prune/apply logic operating
against the same documented contract as the shell adapters above (same
retention semantics, same `KEEP_KNOWN_GOOD_CONFIGS` variable, same log
vocabulary), persisted into the already-persistent `kea-data` volume
(`/var/lib/kea`). That is a second PR's worth of work on its own and is
intentionally out of scope here; tracked in #614.

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

**pdns.conf: no check-only flag exists — start-then-verify instead.**
Debian Trixie's `pdns-server` package (4.9.x) has no equivalent: its
`--help` output lists no config-check option, only `--config` (dump the
effective config to stdout) and `--no-config` (skip parsing entirely),
neither of which validates a candidate file. `_dns_auth_probe()` in
`services/dns/entrypoint.sh` instead does the start-then-verify pattern the
issue anticipated for exactly this case: start `pdns_server` in the
foreground against the candidate config, poll the control socket with
`pdns_control rping` for up to ~5s, then stop the probe process either way
regardless of outcome. This is safe and reliable because, verified
empirically against the real binary: a config that fails to parse (bad
syntax) or whose backend fails to initialize (unknown `launch=` backend, or
a `gsqlite3-database=` path that does not exist) makes `pdns_server` exit
within well under a second, before it ever creates the control socket — so
`pdns_control rping` reliably distinguishes a valid candidate (process stays
up, control socket responds) from an invalid one (process exits, socket
never appears) without needing any deeper semantic check. The probe instance
is always torn down after the check (success or failure); the real,
long-running server is started separately, afterward, by the existing
`run_auth()` restart loop once a valid config is confirmed in place — so a
successful probe briefly starts and stops `pdns_server` an extra time at
every container start, which is an accepted, minor startup-time cost for
correctness (there is no way to check validity without actually starting the
daemon, since no check-only flag exists).
`_dns_auth_validate_snapshot_or_rollback()` wraps `_dns_auth_probe()` in the
same validate-then-snapshot-or-rollback shape as the other adapters, using
`_dns_auth_probe` as the validator instead of a pure pre-start check
command.

Ordering matters here in a way it does not for nginx/dnsmasq: pdns.conf
validation/rollback runs *before* any `pdnsutil` call in the entrypoint
(zone creation, TSIG import), because those calls also read `pdns.conf` via
`--config-dir` — if pdns.conf is rolled back to a known-good snapshot,
every subsequent `pdnsutil` call in that same startup must see the rolled-
back config, not the rejected candidate. It runs *after* the SQLite database
file exists (so the `gsqlite3` backend can actually open it during the
probe), but before zone creation and `configure_ddns_tsig`.

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
there is no separate CLI to inspect or hand-pick a snapshot in this PR. The
snapshot directories are plain files under the volumes listed above and can
be inspected directly with `docker compose exec` /
`docker run --rm -v <volume>:/data busybox ls -la /data` for manual triage if
needed.
