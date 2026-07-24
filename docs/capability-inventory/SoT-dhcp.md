# Capability inventory: `services/dhcp`

Part of the project-wide capability inventory (#843). Audited files:
`services/dhcp/entrypoint.sh` (706 lines), `services/dhcp/Dockerfile`,
`services/dhcp/kea-dhcp4.conf`, `services/dhcp/kea-ctrl-agent.conf`,
`services/dhcp/kea-dhcp-ddns.conf` (all three genuinely JSON despite the
`.conf` extension -- see `AG-HDR-002`, no file header on any of them), on
`origin/v0.2.0`, plus the Kea-facing parts of
`services/ui/src/routes/dhcp.rs` (5780 lines) and
`services/ui/src/kea_snapshots.rs`, the three compose files' `dhcp`
service definitions, `config/{dev,prod}/dhcp.env`, `setup.sh`'s Kea
activation preflight, and Kea-related test/simulation coverage. This is a
deeper, function-level companion to `docs/architecture-ng.md` and
`docs/dhcp-modes.md`, not a replacement for either.

Component role: Kea DHCPv4 server + Control Agent (REST API) + DHCP-DDNS
(D2) daemon, providing full DHCP lease service plus dynamic forward/reverse
DNS record updates into PowerDNS. Mutually exclusive with `dhcp-proxy`
(dnsmasq ProxyDHCP/PXE mode, covered by its own `SoT-dhcp-proxy.md`) -- both
modes want UDP port 67.

> **Provenance note**: A full raw capability inventory for this exact
> component was already posted as a GitHub comment on issue #843
> (`CLD-1784091523`, 2026-07-15) but was never turned into this file -- an
> instance of the exact failure mode `AGENTS.md`'s `AG-GH-017` describes
> (real analysis surviving only as a comment, invisible to anyone reading
> the issue as "done"). This document reuses that comment's verified,
> still-accurate findings but was independently re-checked line-by-line
> against current `origin/v0.2.0` (`8b26af17`) rather than transcribed, and
> corrects two respects in which that comment is now stale: it predates the
> shared-secret bootstrap mechanism (issue #858 / PR #886, merged
> 2026-07-16) and the case-insensitive placeholder-parity hardening (issue
> #967 / PR #988, merged 2026-07-18), and it predates PR #978's
> domain/hostname/MAC validation and CSRF-exemption fixes in `dhcp.rs`
> (merged 2026-07-17).

## 1. Container / process surface (`entrypoint.sh`, `Dockerfile`)

Three Kea daemons are started as background jobs and supervised together:
`kea-dhcp4` (DHCPv4 lease service), `kea-ctrl-agent` (REST API on `:8000`),
and `kea-dhcp-ddns` (D2, only started `if command -v kea-dhcp-ddns`, which
is always true in the shipped image -- the `command -v` guard is defensive,
not a real optional-feature switch). All three are killed together by a
single `trap ... EXIT TERM`, which also tears down the iptables chain (see
§3). **The trailing `wait` (line 706) takes no arguments**, so it blocks
until *all three* background jobs exit -- if exactly one daemon dies, PID 1
never exits and Docker's restart policy never fires (tracked as bug-hunt
finding #1, already in `docs/bug-hunt/dhcp.md`, not repeated in full here).

**Dockerfile**: built `FROM debian:trixie-slim`, installs
`kea-dhcp4-server`, `kea-ctrl-agent`, `kea-dhcp-ddns-server`, `kea-admin`,
plus `nmap`, `gettext` (`envsubst`), `openssl`, `curl`, `jq`, `iptables`.
`nmap` is present in this image for exactly one caller: `setup.sh`'s
`run_kea_dhcp_activation_preflight()` (see §7), which runs
`docker compose ... run --rm --no-deps dhcp nmap --script
broadcast-dhcp-discover ...` -- this is caught by `entrypoint.sh`'s very
first `case "${1:-}" in nmap|/usr/bin/nmap|/bin/nmap) exec "$@" ;; esac`
(lines 175-179), which bypasses the entire Kea startup sequence and execs
`nmap` directly. This is a **separate** rogue-DHCP-server discovery
mechanism from the Admin UI's own `GET /api/dhcp/check` (`dhcp.rs`'s
`run_dhcp_probe`), which runs `nmap` inside the **`ui`** image's own
`dhcp-probe` container instead (`services/ui/dhcp-probe.sh`, which also
installs `nmap` -- `services/ui/Dockerfile` line 461) -- same underlying
technique, two independent trigger points (one-time pre-activation setup
gate vs. on-demand Admin UI page action), not shared code.

`EXPOSE 67/udp 8000`. `chmod +x /entrypoint.sh` at build time -- this
combined with `ENTRYPOINT ["/entrypoint.sh"]` is why the executable bit
matters here (`AG-VAL-024`); it is baked into the image, not dependent on
the source checkout's own file mode.

## 2. Shared-secret bootstrap (issue #858, hardened by #967/#988)

`entrypoint.sh` embeds a byte-identical copy (between `# BEGIN
shared-secret-bootstrap library` / `# END ...` markers) of
`scripts/lib/shared-secret-bootstrap.sh`'s function definitions -- this
image builds from `services/dhcp/` alone with no shared build context, so
the functions must be duplicated rather than mounted/copied in. Drift
between this embedded copy and the canonical file (and the two sibling
copies in `services/dns/entrypoint.sh` and
`services/ui/docker-entrypoint.sh`) is guarded by
`tests/bats/shared_secret_bootstrap_sync.bats` (4 tests, byte-diff based).

- **`secret_is_placeholder(value)`** -- true for empty, or (after
  lowercasing and folding `-`/`_` together, per #967/#988) a value starting
  with `change_me`/`changeme`, starting with `your_`, or ending in `_here`.
  Deliberately narrower than `setup.sh`'s own separate
  `secret_value_is_placeholder()` in two ways (documented, not
  reconciled -- maintainer's Option B decision on #967): does not recognize
  the legacy `lancache-*-secret` template shape (because the now-retired
  `deploy/dev/docker-compose.yml`/`deploy/dev/.env`, v0.3.0 #766, shipped a
  real, working dev secret in exactly that shape, e.g. the former dev
  `KEA_CTRL_TOKEN` value below -- kept as a regression case) or a bare infix
  `change-me`/`change_me` without a `CHANGE_ME`/`changeme` **prefix**.
- **`resolve_shared_secret(name, current_value_or_empty, gen_func)`** -- if
  a non-empty configured value is passed, uses it verbatim (never persisted
  to the shared volume -- every container already reads the same `.env`).
  Otherwise reads `$LANCACHE_SHARED_SECRET_DIR/<name>` if some other
  container already created it, else generates one and claims it via
  `mktemp` (same directory) + `ln` (atomic hardlink, fails if the target
  already exists) -- the classic create-race pattern: the loser of the race
  falls back to reading the winner's value instead of erroring. Returns
  non-zero only if the shared volume itself is unwritable.
- **Used for two secrets in this service**: `KEA_CTRL_TOKEN` (shared file
  `kea-ctrl-token`, hex32) -- also consumed by the Admin UI's own
  `docker-entrypoint.sh`, which resolves `DHCP_API_TOKEN` against this same
  `kea-ctrl-token` file (`_ui_resolve_or_die DHCP_API_TOKEN kea-ctrl-token
  ...`), so the Kea Control Agent's REST credential and the Admin UI's REST
  client credential converge on one value regardless of which container
  boots first. `DDNS_TSIG_KEY` (shared file `ddns-tsig-key`, base64 32) --
  also consumed by `services/dns/entrypoint.sh` under the identical key
  name, so Kea's D2 daemon and PowerDNS agree on the TSIG secret that signs
  DDNS updates.
- **Legacy shipped defaults**: a separate, case-sensitive (not
  `secret_is_placeholder`-routed) literal check rejects
  `lancache-dhcp-secret`/`lancache-dhcp-dev-secret`/`lancache-dhcp-prod-secret`
  for `KEA_CTRL_TOKEN` specifically, both when deciding whether to treat
  the configured value as "already real" for `resolve_shared_secret`
  (line 219) and in the final fail-closed check (lines 246-252).
- **Fail-closed check**: after resolution, `KEA_CTRL_TOKEN` is re-validated
  with `secret_is_placeholder` plus the legacy-literal check; a placeholder
  surviving resolution (shared volume unwritable, `resolve_shared_secret`
  returned empty) still `exit 1`s with an actionable
  `openssl rand -hex 32` hint. `DDNS_TSIG_KEY` gets the same treatment
  (placeholder-only, no legacy-literal list) -- Kea, unlike PowerDNS (which
  falls back to a loopback-only, TSIG-off safe state per
  `docs/threat-model.md` T12), has no safe degraded mode for DDNS and
  always requires a real key.
- **Real config values, not placeholders, by design**:
  the now-retired `deploy/dev/.env`'s (v0.3.0, #766)
  `KEA_CTRL_TOKEN=lancache-dev-kea-control-token-change-me` was a genuine
  working dev secret (the `-change-me` **infix**, not a
  `CHANGE_ME`/`changeme` prefix, is exactly the shape `secret_is_placeholder`
  is documented to deliberately not match, kept as a regression case) --
  `deploy/prod/.env` and
  `deploy/quickstart/.env` both ship the literal
  `KEA_CTRL_TOKEN=CHANGE_ME_KEA_CTRL_TOKEN`, which *does* match (prefix
  `change_me`) and is expected to be regenerated/operator-replaced.

**Fresh finding from this pass** (see `docs/bug-hunt/dhcp.md` new finding
N3): the three compose files' own `dhcp` service healthchecks each embed an
*independent*, hand-written fallback pattern to detect "is `KEA_CTRL_TOKEN`
still the compose-injected placeholder, in which case read the real
generated value from the shared-secret file instead" -- because a
Docker `HEALTHCHECK CMD-SHELL` only sees the container's static
compose-defined environment, never anything the entrypoint resolved and
exported afterward. All three inline patterns are already flagged (not
filed) as an out-of-scope 4th+ placeholder-detection family in a comment on
#967 and in PR #988's own "Scope Boundaries" section -- this inventory
independently re-confirms it live against current code and files it
properly (see the bug-hunt doc and the linked issue).

## 3. Kea Control Agent API firewalling (iptables)

`network_mode: host` (prod/quickstart; dev uses a bridge network with a
published port) means the Control Agent's `:8000` would otherwise be
reachable from the whole LAN. `entrypoint.sh` creates/rebuilds a dedicated
`LANCACHE_KEA_CTRL` iptables chain on every start: flushes it, removes
every legacy inline/duplicate jump rule from prior entrypoint versions
(self-healing for hosts with accumulated duplicates -- issue #159), inserts
one scoped jump near the top of `INPUT`, then rebuilds the chain itself
(`ACCEPT` from `172.16.0.0/12` -- the Docker bridge range -- and
`127.0.0.0/8`, then `DROP` everything else, order matters). The same
cleanup logic (in reverse) runs in the `EXIT`/`TERM` trap. Requires
`iptables` to be present and `NET_ADMIN` capability (compose `cap_add`);
silently skipped (`command -v iptables` guard, no warning) if `iptables`
is unavailable -- see §7 for whether that silent skip is itself worth a
flag (deliberately not re-litigated here, already covered elsewhere).

## 4. Config rendering, migration, and persistence model

Three Kea configs render once, on first boot only, from
`/etc/kea/<name>.conf.template` (baked into the image) to
`/var/lib/kea/<name>.conf` (on the `kea-data` volume, survives restarts).
After first boot, each of the three follows a **different** update
strategy on every subsequent container start:

| File | Strategy | Why |
|---|---|---|
| `kea-dhcp4.conf` | **Migrated** via `migrate_dhcp4_config()`, a narrow `jq` merge | The only file the Admin UI mutates live (`config-set`/`config-write`); a full regeneration would clobber operator-added subnets/reservations/options |
| `kea-ctrl-agent.conf` | **Fully regenerated**, `cmp`'d against a fresh render, overwritten if different | No UI-mutated state to protect; lets a template change (new auth default, logger, socket path) reach already-deployed installs. Manual edits are silently discarded by design -- documented, ties to issue #651 |
| `kea-dhcp-ddns.conf` | **Fully regenerated**, same `cmp`-then-overwrite pattern | Same rationale as ctrl-agent; also not UI-mutated |

**`migrate_dhcp4_config()`** (the most complex function in the file) does,
in order: sets `control-socket.socket-name` to the fixed path; ensures the
`lease_cmds` hook is present (resolved at runtime via `find /usr/lib
-maxdepth 5 -name libdhcp_lease_cmds.so`, arch-independent -- fails closed
with `exit 1` if not found, since `lease4-del` needs it); defaults
`multi-threading.enable-multi-threading` to `false` if unset; defaults
`dhcp-ddns`/`ddns-*` fields to the D2-enabled shape if unset; migrates
`default-lease-time`/`max-lease-time` → `valid-lifetime`/`max-valid-lifetime`
(deleting the old keys) via `//`-fallback, not overwrite, so an
already-migrated install is untouched; migrates any `ntp-servers` option
whose `data` is not already an IPv4 CSV list, via a **separately built
migration map** (`build_ntp_migration_map()` -- pre-resolves every distinct
legacy hostname/CSV value found anywhere in the config to its IPv4
resolution *before* the jq pass, since jq itself cannot shell out to
`getent`); and adds a `/var/log/kea/kea-dhcp4.log` file-logger output
alongside (not replacing) the existing `stdout` output for both the
`kea-dhcp4` and `kea-dhcp4.dhcp4` loggers (central logging pipeline, issue
#633). **`multi-threading.enable-multi-threading: false` (both the first-boot
template, `kea-dhcp4.conf` line 8, and the migration default above) has no
documented rationale anywhere in this codebase** -- checked the full commit
history via `git log --all -S "enable-multi-threading" -- services/dhcp/`;
the one commit that introduced it (`59527fca`, "Fix Kea DDNS updates to
PowerDNS") carries no comment or commit-message explanation for why it is
explicitly disabled rather than left at Kea's own default. This is exactly
the open question raised in the maintainer's own field-testing issue #1068
(item 10, "needs an explanation: what does this setting actually do, and
why is it currently disabled?") -- flagging honestly as an undocumented gap
rather than inventing a plausible-sounding rationale (per `AG-HDR-006`, a
technical claim about *why* a design choice was made must be verified
against actual file content/git history, not asserted). Kea's own
multi-threading feature (a packet-processing thread pool for lease
allocation and hook execution) is a real, documented upstream option;
whether it would help or hurt this project's typical LAN-scale request
rate, and whether every loaded hook (`lease_cmds`) is safe to run
multi-threaded, is a real open question for whoever answers #1068, not
determined here.

The whole migration is a no-op (`cmp -s` finds no diff, file left
untouched) once a config already has every field. **Zero direct test
coverage** -- the bats function-extractor whitelist for this file does not
include `migrate_dhcp4_config`/`build_ntp_migration_map`, and both Kea E2E
simulation scripts always boot from an empty volume, so the migration
always runs exactly once against its own just-rendered template (already
tracked as bug-hunt finding #3).

**Kea's own file-logger path restriction** (comment at entrypoint.sh lines
167-172, confirmed against Kea 2.6.3 packaged behavior): Kea hard-restricts
file-logger `output` paths to exactly `/var/log/kea` as a security
hardening against arbitrary file writes via a malicious `config-set` -- any
other path (including this project's usual `/var/log/lancache-*`
convention) fails config load outright, refusing to start rather than just
losing the file log. This is why `/var/log/kea` (not `/var/log/lancache-dhcp`)
is the fixed, non-configurable log directory for this service (issue
#773 -- a prior version of this migration used the wrong path and caused a
full outage for any install with the `logging` profile enabled).

## 5. Templated env vars, NTP handling, and validation helpers

`is_ipv4`/`is_ipv4_csv`/`resolve_ntp_server`/`resolve_ntp_csv`/
`build_ntp_option` -- the same NTP-hostname-resolution shape used by the
migration path above, but for first-boot template rendering: `DHCP_NTP_SERVERS`
(space-separated hostnames or IPv4s, default `debian.pool.ntp.org
time.nist.gov`) is resolved to a CSV of IPv4s via `getent ahostsv4` (falls
back to `getent hosts` filtering for a dotted-quad first field), and the
whole first-boot render fails closed (`render_kea_dhcp4_config` returns
non-zero) if any entry cannot be resolved. Covered by
`tests/bats/dhcp_kea_config_generation.bats` (22 tests) via a bats-extracted
copy of these specific functions (not `migrate_dhcp4_config`, see above).

Other templated vars (all exported and listed in `ENVSUBST_VARS` for
`envsubst`'s allowlist, so no stray `$FOO`-shaped text in a template can
leak through unintentionally): `DHCP_SUBNET` (default `10.0.0.0/24`),
`DHCP_RANGE_START`/`_END`, `DHCP_GATEWAY`, `DHCP_DOMAIN` (default `lan`,
also becomes the DDNS forward zone's `${DHCP_DOMAIN}.` name -- see §6),
`DHCP_LEASE_TIME` (default 86400s; `DHCP_MAX_LEASE_TIME` is always exactly
double, computed via `$(( DHCP_LEASE_TIME * 2 ))`), `DHCP_DNS_PRIMARY`/
`_SECONDARY` (default `127.0.0.1`/`127.0.0.1`, overridden per-compose to
the real proxy IPs), `KEA_CTRL_HOST` (default `0.0.0.0`),
`KEA_LEASE_CMDS_HOOK_PATH` (resolved at runtime, see §4).

`DHCP_LEASE_TIME`'s arithmetic gate is only a **partial** validator: bash
evaluates a pure-identifier non-numeric value (e.g. `abc`) as a nested
variable reference that resolves to `0` with no error under
`$(( ))`, rather than aborting -- only a value with genuine trailing
garbage (e.g. `86400x`) trips a real arithmetic syntax error under `set
-e`. This is bug-hunt finding N2 (info), already in `docs/bug-hunt/dhcp.md`.

## 6. DHCP-DDNS (D2) -- forward + reverse

`kea-dhcp-ddns.conf` configures one TSIG key (`lancache-ddns-key`,
`HMAC-SHA256`, secret = `DDNS_TSIG_KEY`), one **forward** zone
(`${DHCP_DOMAIN}.`, matching `services/dns/entrypoint.sh`'s `LAN_ZONES`
entry `lan.` when `DHCP_DOMAIN` is left at its default), and **18 reverse**
zones -- one entry per IPv4 private-range reverse zone PowerDNS actually
creates (`10.in-addr.arpa.`, `168.192.in-addr.arpa.`, and
`16.172.in-addr.arpa.` through `31.172.in-addr.arpa.`, 16 entries -- the
full RFC 1918 `172.16.0.0/12` range split into per-/16 subzones). Verified
this list is exactly `services/dns/entrypoint.sh`'s `PRIVATE_REVERSE_ZONES`
array **minus** its two IPv6 entries (`c.f.ip6.arpa.`, `d.f.ip6.arpa.`) --
correctly excluded since this project's Kea config is DHCPv4-only and D2
never generates an IPv6 PTR update. `tests/bats/dhcp_kea_config_generation.bats`
guards the two lists staying in sync if `PRIVATE_REVERSE_ZONES` ever
changes.

Both forward and reverse zone `"name"` fields carry a **literal trailing
dot** (e.g. `"lan."`, `"10.in-addr.arpa."`) -- required because Kea's D2
daemon matches an update's target FQDN against each `ddns-domains` entry's
`name` as a DNS-name suffix, not a substring; without the trailing dot the
name parses as a non-fully-qualified label and D2 silently discards every
update with a "no match" error instead of sending it (confirmed
empirically against a real Kea 2.6.3 instance, issue #706). Every
`dns-servers` array lists `${DHCP_DNS_SERVER_IP}` (port `${DHCP_DDNS_PORT}`,
default `5300` -- `pdns_server`'s real DNS-protocol port, not `53`, which is
`pdns_recursor` and does not relay the DNS UPDATE opcode) then
`${DHCP_DNS_SERVER_IP_SSL}` in that fixed order -- Kea's D2 treats this as a
**first-to-last failover list, not fan-out**, so `dns-ssl` only ever
receives a DDNS record if `dns-standard` is unreachable. This is a known,
already-open architectural gap (issue #770), re-confirmed still present
here, not proposed for a fix in this inventory.

`DHCP_DDNS_PORT`'s only handling is a bare default
(`: "${DHCP_DDNS_PORT:=5300}"`) -- no `is_ipv4`-style numeric gate -- and it
is spliced **unquoted** into the JSON template (`"port": ${DHCP_DDNS_PORT}`,
appearing once per `dns-servers` entry × 19 zone entries × 2 servers each).
A non-numeric value renders syntactically invalid JSON, and because the D2
daemon's death is invisible to the Compose healthcheck (§1's blind `wait`
finding), the resulting startup failure would be completely silent. This
is bug-hunt finding #2, already in `docs/bug-hunt/dhcp.md`.

## 7. Kea Control Agent API surface actually exercised by the Admin UI

| Kea command | Called from (`dhcp.rs`) | Purpose |
|---|---|---|
| `config-get` | `fetch_dhcp_config`, start of every mutation | Read live `Dhcp4` config; a `hash` field is stripped before any config is reused as a write basis (issue #630 regression fix) |
| `config-test` | `kea_config_modify_with_post` | Validate a candidate config before applying |
| `config-set` | `kea_config_modify_with_post`, rollback path | Apply to the running server; rolled back to the pre-modification config on any subsequent failure |
| `config-write` | `kea_write_config` | Persist to disk; a 3-way outcome (`Success`/`ConfirmedFailure`/`AmbiguousFailure`) drives retry/rollback logic |
| `lease4-get-all` | `fetch_leases` | Populate the read-only leases table |
| `lease4-del` | `release_lease` (`POST /dhcp/lease/release`) | Force-release a lease; result code 0 = released, 3 = already gone (mapped to 404, not 500), other = error |

**Never called at all**: `statistic-get`, `reservation-add`/`reservation-get`
(the `host_cmds` hook -- not loaded; removed per issue #55, the Debian
Trixie package does not exist, which is why reservations go through direct
`subnet4[].reservations` JSON edits via `config-set` instead), any
`subnet6`/`lease6`/Dhcp6 command (project is DHCPv4-only), any
High-Availability hook command.

## 8. Admin UI mutation routes (all behind `require_kea_mode`, CSRF-protected)

- `POST /dhcp/subnet/add`, `/update`, `/remove` -- full `subnet4` CRUD:
  CIDR, pool range, gateway, DNS×2, NTP servers (hostnames resolved to IPv4
  *before* write, issue #670), domain (validated with `is_valid_domain_name`
  since PR #978 -- previously unvalidated), lease-time bounds (60–604800s).
  `update_subnet` preserves existing custom options and filters
  reservations against a changed CIDR via `compatible_reservations_for_subnet`.
- `POST /dhcp/subnet/option/add`, `/remove` -- arbitrary numeric-code custom
  DHCP options per subnet (option-data ≤1024 chars); rejects the 5
  UI-managed option codes (3/6/15/42/119) to avoid a silent duplicate.
- `POST /dhcp/static/add`, `/remove` -- static reservations by MAC.
  `add_reservation` validates MAC + IP syntax and (since PR #978) hostname
  via `is_valid_domain_name` when non-empty, then guards against a
  hand-edited global `Dhcp4.host-reservation-identifiers` that excludes
  `hw-address` (would `config-set` successfully but never actually match --
  fails loudly instead, per `AG-OP-005`). Does **not** check whether the
  requested IP is already reserved to a different MAC, and does **not**
  check the IP falls inside the target subnet's own CIDR (bug-hunt
  findings #4/#5, both already documented). `remove_reservation` validates
  MAC (added by PR #978, previously absent, inconsistent with
  `add_reservation`/`release_lease`).
- `POST /dhcp/lease/release` -- force-release via `lease4-del` (§7).
- `POST /dhcp/snapshot/rollback` -- operator-selected rollback to one
  known-good snapshot (§9), reusing the same `config-test → config-set →
  config-write` chain, membership-checked against `list_snapshot_ids`
  (path-traversal guard).
- `GET /api/dhcp/check` -- on-demand rogue-DHCP-server discovery (§1's `ui`
  image path, distinct from `setup.sh`'s). Since PR #978, this route is
  explicitly CSRF-exempted-as-a-`GET` **but validated as actually mutating
  state** (starts/stops the `dhcp-probe` container) -- `dhcp.html` fires it
  automatically via `DOMContentLoaded`, so simply loading the `/dhcp` page
  triggers a real container restart + broadcast nmap scan on every page
  view (already flagged in the sibling `ui-core`/`ui-routes` bug-hunt
  passes, not repeated in full here).
- `POST /dhcp/mode`, `/dhcp/proxy` -- whole-stack DHCP mode switch
  (`disabled`/`kea`/`dnsmasq-proxy`) and dnsmasq-proxy field configuration
  (out of this Kea-scoped inventory's depth).

## 9. Known-good config snapshots (`kea_snapshots.rs`, issue #614)

One snapshot per successful `config-write`, written to
`<snapshot_root>/<nanosecond-id>/dhcp4.json` via staging-dir + atomic
rename. Retention via `KEEP_KNOWN_GOOD_CONFIGS` (default 3, oldest pruned
first; `0`/invalid clamped to the default rather than disabling retention).
Rust-native reimplementation of the same `[known-good-snapshot][kea][LEVEL]`
log contract the shell adapters (nginx/dnsmasq/PowerDNS) share -- not
literally shared code, since Kea's config lives in a live JSON object, not
a shell-templated file. `read_snapshot` performs no `id` validation of its
own (no `..`/absolute-path rejection); the membership check lives entirely
in the one real caller, `rollback_kea_snapshot` -- correct today, but no
defense-in-depth if a second caller is ever added without the same check
(already flagged in the `ui-core` bug-hunt pass as a future-proofing gap,
not repeated in full here). Two independent consumers of the same snapshot
store: the Admin UI's own rollback route, and the separate CLI fallback
`setup.sh reset-to-last-known-good-config kea` (for when the Admin UI
itself is unreachable) -- same files, two different code paths applying
them.

`/var/lib/kea/config-snapshots` is created and `chown`'d to the Admin UI's
fixed UID/GID (10001) by `entrypoint.sh` on every start (not by Kea, which
never touches this directory) -- necessary because `/var/lib/kea` itself is
root-owned and this container runs as root while the UI container runs as
a distinct, non-root, fixed UID.

## 10. Kea capabilities present in the underlying software but unused here

- Client classification (`client-classes`) -- preserved verbatim on
  existing reservations, never overwritten, but no UI to create/assign
  classes.
- Kea statistics API (`statistic-get` etc.) -- no dashboard/metrics
  integration (contrast with `netdata_proxy.rs` for other services).
- High-Availability hook -- single Kea instance only, no HA pair.
- DHCPv6/`subnet6`/`lease6` -- project is IPv4-only for DHCP.
- TLS on the Control Agent -- plain HTTP restricted to Docker-internal
  networks via iptables (§3) instead; acceptable given the
  network-boundary mitigation, but worth noting as an unused hardening
  option.
- Per-subnet `host-reservation-identifiers` -- deliberately never written
  (real Kea rejects it at subnet scope, issue #692); only the global
  default is relied upon, with a fail-loud guard (§8) if a manual edit
  breaks that assumption.

## 11. Test coverage matrix

| Test | What it actually proves |
|---|---|
| `tests/bats/dhcp_kea_config_generation.bats` (22 tests) | First-boot NTP resolution/validation functions, DDNS reverse-zone list stays in sync with `PRIVATE_REVERSE_ZONES`, rendered JSON parses |
| `tests/bats/dhcp_lease_flow_parsing.bats` (7 tests) | Lease-flow output parsing helpers |
| `tests/bats/setup_dhcp_mode.bats` (9 tests) | `setup.sh`'s DHCP-mode selection/env wiring |
| `tests/bats/shared_secret_bootstrap.bats` (7 tests) | `secret_is_placeholder`/`resolve_shared_secret` logic in isolation |
| `tests/bats/shared_secret_bootstrap_sync.bats` (4 tests) | Byte-identity of the embedded copy in this file vs. the canonical library and the two sibling copies |
| `dhcp.rs` `#[cfg(test)]`/`#[tokio::test]` (70 in-file tests) | `kea_config_modify`'s success/rollback/retry/ambiguous-failure matrix, global-reservation-identifiers guard, `lease4-del` result-code handling, CSRF/mode gating, validation helpers |
| `kea_snapshots.rs` `#[test]` (8 in-file tests) | Snapshot creation, retention, rollback ID membership |
| `scripts/dhcp-kea-lease-flow-simulation.sh` (issues #448/#642) | Real `dhclient` DORA exchange against a real Kea container; pool/router/DNS/NTP/lease-time options, static-reservation-honored-by-real-lease, forward+reverse DDNS follow-through against real PowerDNS |
| `scripts/dhcp-kea-ctrl-agent-mutation-simulation.sh` (issue #634) | Real Admin UI HTTP route `POST /dhcp/static/add`/`/remove` (session+CSRF), confirms via `config-get` and a subsequent real lease request -- "representative, not route-by-route exhaustive," explicitly does not cover subnet/option routes or DDNS |
| `scripts/setup-reset-kea-config-simulation.sh` (issue #794, Refs #763) | The **CLI** rollback (`setup.sh reset-to-last-known-good-config kea --yes`) genuinely rolls a real running Kea server back |

**Not covered**: `migrate_dhcp4_config`/`build_ntp_migration_map` (§4,
zero direct coverage -- bug-hunt finding #3); the Admin UI's own
`POST /dhcp/snapshot/rollback` HTTP route has no real E2E test, only
mocked unit coverage (already tracked as issue #837, open, v0.3.0).

## 12. Cross-referenced issue state (re-verified live, not from memory)

- **#556** (DHCP Admin UI missing lease release / custom option management)
  -- CLOSED, correctly: both gaps are implemented.
- **#646** (spec: define full Kea DHCP Admin UI feature scope) -- OPEN,
  v0.3.0. Still no written decision on DDNS follow-through end-state,
  snapshot/rollback completeness, or coverage parity.
- **#770** (DDNS `dns-servers` is failover, not fan-out) -- OPEN, re-confirmed
  still present (§6).
- **#773** (Kea file-logger path restriction outage) -- CLOSED; the fix
  (`/var/log/kea`, §4) is present and correct in current code.
- **#837** (no real E2E test for the Admin UI's own rollback route) -- OPEN,
  v0.3.0. Matches §11's own finding exactly.
- **#836** (`setup.sh reset-to-last-known-good-config`'s `dns`/`pdns`
  target still unimplemented) -- OPEN, v0.3.0. The `kea` target (§9) is
  complete and E2E-tested.
- **#858** (shared-secret bootstrap) -- CLOSED, implemented (§2).
- **#967** (divergent placeholder-detection implementations, Option B:
  cross-validate, don't unify) -- CLOSED via PR #988. Its own comment
  thread and PR body explicitly flag the compose-file `KEA_CTRL_TOKEN`
  healthcheck fallback inconsistency (§2) as an out-of-scope 4th+ family,
  never filed as its own issue until this pass.
- **#159** (protect Kea Control Agent from LAN exposure) -- CLOSED; the
  iptables chain (§3) is present and self-healing.

## 13. Summary

The Kea DHCP surface (subnet CRUD, custom options, static reservations,
lease listing/release, mode switching, DDNS forward+reverse, known-good
snapshot + two independent rollback paths, LAN-exposure firewalling,
cross-container shared-secret convergence) is substantially built and
mostly real-E2E-tested against actual Kea/DHCP traffic. Concrete open gaps,
all already tracked except the last: the DDNS fan-out-vs-failover
limitation (#770); the missing real E2E test for the Admin UI's own
rollback route (#837); the `migrate_dhcp4_config` test-coverage gap (no
issue found, tracked only in `docs/bug-hunt/dhcp.md` finding #3); and the
compose-healthcheck placeholder-detection drift newly filed from this pass
(§2, `docs/bug-hunt/dhcp.md` finding N3).

## 14. Posting status

Findings from this file were also posted as a GitHub comment on the
umbrella issue #843, per that issue's log-as-comments convention.
