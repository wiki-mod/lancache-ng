# Bug hunt: services/dhcp (Kea DHCP + Admin UI integration)

Part of the unscoped vacuum-first bug-hunt sweep, issue #849 (sub-issue of #843).
Scope: `services/dhcp/` (Kea DHCPv4, Control Agent, DHCP-DDNS/D2), the Kea-facing
parts of `services/ui/src/routes/dhcp.rs` and `services/ui/src/kea_snapshots.rs`,
`services/ui/dhcp-probe.sh`, the Kea-focused simulation scripts
(`scripts/dhcp-kea-lease-flow-simulation.sh`,
`scripts/dhcp-kea-ctrl-agent-mutation-simulation.sh`), and the Kea-related bats
tests. Read against `origin/v0.2.0`. Starting point: the existing Kea capability
inventory posted to issue #843 (CLD-1784091523), re-verified against current code,
not assumed accurate.

Methodology: exhaustive, unscoped collection — every finding is listed regardless
of severity, including info-level notes and things that turned out, on closer
inspection, not to be bugs (kept here with the reasoning that ruled them out, per
the "no self-verification during collection, but note what you traced" spirit of
this sweep). No pre-filtering. Verification of which of these are real, actionable
bugs happens in a later, separate phase.

## Findings

### 1. `entrypoint.sh`'s blind `wait` never notices a dead sibling daemon (moderate)

`services/dhcp/entrypoint.sh` starts `kea-dhcp4`, `kea-ctrl-agent`, and (if
present) `kea-dhcp-ddns` as three background jobs, then calls plain `wait` with
no arguments (line 534). Bash's argument-less `wait` blocks until *every*
currently-running background job has exited — if exactly one of the three dies
(OOM kill, a bad runtime config, a crash), `wait` keeps blocking on the survivors
and the container's PID 1 never exits. Docker's own restart policy therefore
never triggers, because from Docker's point of view the container is still
running.

This interacts badly with the Docker Compose healthcheck (`deploy/*/docker-compose.yml`),
which only sends `config-get` for `service: ["dhcp4"]` through the Control Agent.
That check *does* correctly catch a dead `kea-dhcp4` (the Control Agent can't
reach its unix control socket and returns a non-zero result, so the healthcheck
correctly goes unhealthy — traced this through, not a bug on its own). But it
never touches `kea-dhcp-ddns` at all. If `kea-dhcp-ddns` crashes:
- DHCP leases keep being issued normally (kea-dhcp4 unaffected).
- The healthcheck keeps reporting "healthy" forever.
- Every forward (A) and reverse (PTR) DDNS record update silently stops
  happening, with no operator-visible signal anywhere except reading the
  container's own logs by hand.

The identical single-blind-`wait` pattern also exists in `services/dns/entrypoint.sh`
(`kill $AUTH_PID $REC_PID $NATS_PID` trap + plain `wait`), so this looks like a
project-wide convention rather than a one-off mistake in this file — worth a
cross-cutting fix/issue rather than a DHCP-only patch, but concretely present
here.

**Evidence:** `services/dhcp/entrypoint.sh` lines 500–534 (`kea-dhcp4 &`,
`kea-ctrl-agent &`, `kea-dhcp-ddns &`, trap, then bare `wait`); healthcheck
definition in e.g. `deploy/quickstart/docker-compose.yml` lines 1090–1103
(`config-get`/`service: ["dhcp4"]` only, no D2 check anywhere).

### 2. `DHCP_DDNS_PORT` has no format validation before unquoted JSON interpolation (minor)

`kea-dhcp-ddns.conf`'s template splices `${DHCP_DDNS_PORT}` in *unquoted*
(`"port": ${DHCP_DDNS_PORT}`, used 12 times across forward/reverse `dns-servers`
entries). Every other class of value in this file gets some form of gate:
`DHCP_LEASE_TIME` is implicitly gated by bash arithmetic (`$((DHCP_LEASE_TIME * 2))`
at line 189 aborts the whole script with a bash syntax error on non-numeric
input), and every `*_IP`/NTP field goes through `is_ipv4`/`resolve_ntp_server`.
`DHCP_DDNS_PORT` gets neither: `: "${DHCP_DDNS_PORT:=5300}"` (line 70) is the only
handling. A non-numeric value (a deploy-config typo) renders syntactically
invalid JSON, and per finding #1 above, the resulting `kea-dhcp-ddns` startup
failure is completely silent (backgrounded, unmonitored, healthcheck doesn't
cover it).

**Evidence:** `services/dhcp/entrypoint.sh` line 70 (default only, no validator
call); `services/dhcp/kea-dhcp-ddns.conf` lines 24, 28, 42, 46, ... (`"port":
${DHCP_DDNS_PORT}`, unquoted, repeated per zone entry).

### 3. `migrate_dhcp4_config()` — the upgrade/migration jq pipeline — has zero direct test coverage (moderate)

This is the single most complex, most safety-critical function in the entrypoint
(NTP-hostname migration map, `default-lease-time`/`max-lease-time` → `valid-lifetime`/
`max-valid-lifetime` renaming, `dhcp-ddns` block defaulting, `lease_cmds` hook
insertion, dual stdout+file logger patching) and CHANGELOG.md documents it as
having already shipped multiple real regressions in production (#773 wrong log
path, causing a full outage for any install with the `logging` profile; #694/#749
hook-path and comment-syntax bugs). Despite that history, nothing in the test
suite exercises its *migration* branches:

- `tests/bats/helpers/dhcp-kea-helpers.sh`'s awk-based function extractor
  explicitly whitelists only `is_ipv4|is_ipv4_csv|resolve_ntp_server|resolve_ntp_csv|build_ntp_option|render_kea_config|render_kea_dhcp4_config`
  — `migrate_dhcp4_config` and `build_ntp_migration_map` are not in that list and
  are never extracted or sourced by any bats test.
- `tests/bats/dhcp_kea_config_generation.bats` mentions `migrate_dhcp4_config` only
  in a comment (explaining why `is_ipv4` exists), never calls it.
- Both Kea E2E scripts (`scripts/dhcp-kea-lease-flow-simulation.sh`,
  `scripts/dhcp-kea-ctrl-agent-mutation-simulation.sh`) build a brand-new Kea
  container with no pre-existing `/var/lib/kea/kea-dhcp4.conf`, so
  `migrate_dhcp4_config` always runs once, against its own just-rendered
  first-boot template output. `cmp -s "$next" "$runtime"` then finds no diff
  (the fresh render already has every field the migration would otherwise add),
  so the entire jq migration logic — the actual "upgrade an old, pre-existing
  install" code path this function exists for — is skipped every single time
  any test in this repo runs.

The net effect: the function most likely to break silently on the *next* schema
change (it already has, three times) is exercised by nothing except a live
operator's real upgrade.

**Evidence:** `tests/bats/helpers/dhcp-kea-helpers.sh` lines 15 (awk whitelist);
`tests/bats/dhcp_kea_config_generation.bats` lines 56–64 (comment-only mention);
CHANGELOG.md entries referencing `migrate_dhcp4_config` (log-path fix #773,
hook-path fix #694/#749).

### 4. `add_reservation` never checks whether the requested IP is already reserved to a different MAC (moderate)

`upsert_reservation` (`services/ui/src/routes/dhcp.rs` lines 3261–3301) only
matches an existing reservation by normalized MAC address. Calling
`add_reservation` twice with two different MACs but the same `ip` field appends
a *second*, independent reservation entry with a duplicate `ip-address` —
nothing rejects it, nothing warns about it. Kea's own `config-test`/`config-set`
only guarantee identifier (MAC) uniqueness, not reserved-address uniqueness
within a subnet, so this can silently create two devices statically configured
to fight over the same IP with zero operator-facing error, unlike every other
cross-field check this same file performs for the subnet form (pool/gateway
containment, pool-range ordering, lease-time bounds).

**Evidence:** `services/ui/src/routes/dhcp.rs` `upsert_reservation` (lines
3261–3301) — match key is `hw-address` only; `add_reservation` (lines 1436–1494)
passes `form.ip` straight through with no cross-reservation uniqueness check.

### 5. `add_reservation` never checks the reservation IP falls inside the target subnet's own CIDR (minor)

Contrast with `validate_dhcp_form` (used by `add_subnet`/`update_subnet`), which
checks pool bounds and gateway containment against the subnet CIDR via
`ipv4_in_cidr`, and with `compatible_reservations_for_subnet` (used by
`update_subnet`), which filters *existing* reservations against a *changed*
CIDR. `add_reservation` itself only calls `is_valid_ip` — a bare "is this
syntactically an IPv4 address" check — never `ipv4_in_cidr` against the target
subnet. An operator can reserve an address from an entirely unrelated network
for any `subnet_id`; whatever happens next depends entirely on Kea's own
(version-dependent) acceptance of out-of-subnet reservations, not a clear 400
from this project's own validation the way every other geometry mistake in this
file gets one.

**Evidence:** `services/ui/src/routes/dhcp.rs` `add_reservation` (lines
1436–1494), specifically the `is_valid_ip(&form.ip)` check at line 1443 — no
`ipv4_in_cidr` call anywhere in this function.

### 6. `add_subnet`/`update_subnet` never check for CIDR/pool overlap against other existing subnet4 entries (info)

Nothing in `add_subnet` or `update_subnet` compares the submitted CIDR/pool
against the *other* subnets already in Kea's config. An operator can create two
subnets with identical or overlapping ranges. Kea itself does not reject
overlapping `subnet4` definitions at `config-test`/`config-set` time (a
well-known real-world Kea operational trap — which subnet actually serves a
given client then depends on interface/relay-agent context, not simply array
order), so this can produce ambiguous, hard-to-diagnose subnet selection with no
warning from either Kea or this project's own validation.

**Evidence:** `services/ui/src/routes/dhcp.rs` `validate_dhcp_form` (lines
2516–2554) checks pool/gateway containment within *one* subnet's own CIDR only;
no cross-subnet overlap check exists anywhere in `add_subnet`/`update_subnet`.

### 7. `dhcp-probe.sh`'s nmap failure path can be misreported as "no conflict found" (moderate)

```sh
if ! nmap --script broadcast-dhcp-discover ... >"$nmap_out" 2>&1; then
    :
fi
cat "$nmap_out"
conflict_ip="$(sed -n 's/^[|_[:space:]]*Server Identifier:[[:space:]]*//p' "$nmap_out" | sed -n '1p')"
if [ -n "$conflict_ip" ]; then
    printf '__LANCACHE_DHCP_CONFLICT_RESULT__ found %s\n' "$conflict_ip"
elif [ -s "$nmap_out" ]; then
    printf '__LANCACHE_DHCP_CONFLICT_RESULT__ not_found\n'
else
    printf '__LANCACHE_DHCP_CONFLICT_RESULT__ unavailable no-nmap-output\n'
fi
```

`nmap`'s own non-zero exit is deliberately swallowed (documented intent — the
probe should still report *something*). The problem is the fallback logic: if
nmap fails outright (e.g. missing `CAP_NET_RAW`/root privilege for the raw
broadcast send, or any other startup error), nmap still writes its normal
startup banner ("Starting Nmap ... ( https://nmap.org )") plus the error text to
the combined `2>&1` output — so `$nmap_out` is essentially *never* empty in
practice, even on a hard failure. That routes execution into the `elif [ -s
"$nmap_out" ]` branch, which reports `not_found` — i.e. "scanned, no rogue DHCP
server seen" — for a probe that never actually completed a scan at all. The
`unavailable no-nmap-output` branch this was presumably meant to catch is
effectively dead code. This is exactly the "unavailable disguised as
verified-clean" failure class this project's own `AGENTS.md` explicitly forbids
for DNS health checks ("ping is not an acceptable DNS health check... `ss` is
not acceptable by itself"), and the sibling `dhclient`-check code path in the
very same script is careful to avoid it (`parse_client_probe_result` in
`dhcp.rs` defaults to `Unavailable`, not `Passed`, when its own marker line is
missing).

**Evidence:** `services/ui/dhcp-probe.sh` lines 33–46.

### 8. `deploy/quickstart/docker-compose.yml`'s `dhcp-probe` bind-mount source does not exist in the repo (info — mitigated in the documented flow)

```yaml
dhcp-probe:
  ...
  entrypoint: ["/usr/local/bin/dhcp-probe.sh"]
  volumes:
    - ./scripts/dhcp-probe.sh:/usr/local/bin/dhcp-probe.sh:ro
```

There is no `scripts/dhcp-probe.sh` anywhere in this repository — the real file
is `services/ui/dhcp-probe.sh`. `deploy/dev/docker-compose.yml` and
`deploy/prod/docker-compose.yml` have no equivalent bind-mount at all (they rely
on the file already baked into the `ui` image). This resolves correctly *only*
because `setup.sh`'s `install_quickstart_compose_assets()` copies
`services/ui/dhcp-probe.sh` into `<install_dir>/scripts/dhcp-probe.sh` (and
force-removes a stale auto-vivified directory there, per the existing #538
workaround) before this compose file is ever run from the *installed* copy.
Nothing enforces that path if `deploy/quickstart/docker-compose.yml` is ever run
directly from a repo checkout (`docker compose -f deploy/quickstart/docker-compose.yml up`,
bypassing `setup.sh`) — Docker would auto-vivify an empty directory at the
missing source path and shadow the real script inside the container with an
empty directory, breaking the `dhcp-probe` container's entrypoint outright.
Traced every CI reference to this file: all of them (`build-push.yml`) only run
`docker compose ... config`/grep-based structural checks, never `up`, against
this file directly; the one job that does bring up a real quickstart stack
(`scripts/setup-cli-simulation.sh`, via `full-setup-validate.yml`) goes through
the real `setup.sh` install flow, so this gap is currently masked everywhere
it's exercised — but it is a live trap for a future contributor/reviewer who
tries to validate this compose file standalone (the exact kind of manual check
`CONTRIBUTING.md`'s own example command gestures at).

**Evidence:** `deploy/quickstart/docker-compose.yml` lines 1168–1175; `setup.sh`
`install_quickstart_compose_assets()` lines 1427–1455 (the actual, working copy
step); no `scripts/dhcp-probe.sh` found anywhere via repo-wide search.

### 9. `run_dhcp_probe`'s "container exited non-zero" handling is likely unreachable given the current `dhcp-probe.sh` (info)

`services/ui/src/routes/dhcp.rs`'s `run_dhcp_probe` treats a non-zero probe
container exit code as a hard error (`anyhow::anyhow!("DHCP probe container
exited with code {}...")`). But `services/ui/dhcp-probe.sh` is written so that
every failure mode (nmap failure, no default interface, dhclient failure) is
captured as a `__LANCACHE_DHCP_..._RESULT__` marker line, never as a script
`exit 1` — the script has no explicit `exit` at all after its first
`nmap`-swallowing guard, so its own final exit status is whatever the last
`printf` returns, i.e. always 0. This makes the Rust-side "nonzero exit" branch
effectively dead code under the shell script's current design — not a behavior
bug (marker-line parsing still works), but worth flagging: if a future edit to
`dhcp-probe.sh` reintroduces an uncaught early exit (e.g. `set -eu` tripping on
some new command), the Rust side is technically ready for it, but there is
currently no test proving that path is reachable/correct.

**Evidence:** `services/ui/src/routes/dhcp.rs` lines 2176–2182 vs.
`services/ui/dhcp-probe.sh` (no unconditional `exit` after the initial
nmap-failure swallow at lines 35–37).

### 10. Re-confirmed, already tracked: DDNS `dns-servers` is failover, not fan-out (issue #770, open) (info)

Re-verified directly against current `services/dhcp/kea-dhcp-ddns.conf`: both
`forward-ddns` and `reverse-ddns` list `${DHCP_DNS_SERVER_IP}` then
`${DHCP_DNS_SERVER_IP_SSL}` in that order for every zone entry. Kea's D2 daemon
treats this as a first-to-last failover list, not fan-out, so as long as
`dns-standard` answers, `dns-ssl` never receives a DHCP-driven DNS record.
Already open as issue #770 and documented in `docs/dhcp-modes.md`; listed here
only for the vacuum-first sweep's completeness requirement, not as a new
finding.

**Evidence:** `services/dhcp/kea-dhcp-ddns.conf` (every `dns-servers` array,
e.g. lines 21–29); `docs/dhcp-modes.md` lines 327–340.

### 11. Config env-file drift note: `DHCP_DNS_SERVER_IP_SSL` absent from `config/dev/dhcp.env` (info, likely intentional)

`config/dev/dhcp.env` sets `DHCP_DNS_SERVER_IP` (`172.28.0.3`) but has no
`DHCP_DNS_SERVER_IP_SSL` entry, so it falls back to `entrypoint.sh`'s own
default of `127.0.0.1` — meaning dev's reverse/forward DDNS "SSL" target is a
loopback address inside the `dhcp` container itself, not a real dns-ssl
instance. This is consistent with a single-DNS-instance dev setup and is very
likely intentional (dev doesn't run a second PowerDNS instance by default), but
is worth a maintainer glance since it's silent (no comment in the env file
calls out that this field is being skipped rather than genuinely unset).

**Evidence:** `config/dev/dhcp.env` (no `DHCP_DNS_SERVER_IP_SSL` line);
`services/dhcp/entrypoint.sh` line 63 (`: "${DHCP_DNS_SERVER_IP_SSL:=127.0.0.1}"`).

## Verification pass (self-verified against origin/v0.2.0)

Second, independent pass: every finding above re-checked directly against the
real code in its own context (not delegated), each with its own reasoning, plus
independent follow-through for anything not yet traced to its end. Verdicts:

- **#1 (blind `wait` hides a dead D2) — CONFIRMED, moderate.** `entrypoint.sh`
  starts three daemons (lines 501/505/510) and calls bare `wait` (line 534);
  bash's argument-less `wait` blocks until *all* jobs exit, so one dead daemon
  never makes PID 1 exit and Docker's restart policy never fires. Confirmed the
  healthcheck (dev compose lines 257-270, prod 293+) only runs
  `config-get service:["dhcp4"]` through the Control Agent: a dead `kea-dhcp4`
  *is* caught (config-get errors → `jq .result==0` fails → unhealthy), a dead
  `kea-ctrl-agent` *is* caught (curl fails → unhealthy), but a dead
  `kea-dhcp-ddns` is caught by nothing → forward/reverse DDNS silently stops
  while the container stays "healthy". Same single-blind-`wait` shape in
  `services/dns/entrypoint.sh`, so it is a project-wide class.

- **#2 (`DHCP_DDNS_PORT` unvalidated, unquoted) — CONFIRMED, minor.** Only
  handling is the default at line 70 (`: "${DHCP_DDNS_PORT:=5300}"`); no
  `is_ipv4`/numeric gate. It is spliced *unquoted* into `kea-dhcp-ddns.conf`
  (`"port": ${DHCP_DDNS_PORT}`, 36 occurrences), so a non-numeric value yields
  syntactically invalid JSON and — per #1 — a *silent* D2 startup failure.
  Reachability proven by the mirror image of #2's own refutation: a repo-wide
  grep shows `DHCP_DDNS_PORT` is set in **no** compose `environment:` block and
  **no** env-file — it flows purely from the entrypoint default, so the value an
  operator can typo (e.g. via a future env addition) reaches JSON with nothing
  in between. Refinement to the original rationale: the claim that
  `DHCP_LEASE_TIME` is fully gated by `$((DHCP_LEASE_TIME * 2))` is only
  partly true — bash evaluates a pure-identifier value (`abc`) as a nested
  variable to `0` with no error, so `valid-lifetime`/`max-valid-lifetime` (also
  unquoted, `kea-dhcp4.conf` lines 66-67) are an equally unvalidated splice;
  the difference is that a broken `kea-dhcp4.conf` *is* caught by the
  healthcheck, so its failure is not silent the way D2's is.

- **#3 (`migrate_dhcp4_config` has zero direct test coverage) — CONFIRMED,
  moderate.** The bats extractor (`tests/bats/helpers/dhcp-kea-helpers.sh` line
  15) whitelists only `is_ipv4|is_ipv4_csv|resolve_ntp_server|resolve_ntp_csv|build_ntp_option|render_kea_config|render_kea_dhcp4_config`;
  `migrate_dhcp4_config`/`build_ntp_migration_map` are never sourced. Grep across
  `tests/` finds `migrate_dhcp4_config` only in one explanatory comment
  (`dhcp_kea_config_generation.bats` line 58), never a call. Both E2E sims boot a
  fresh container so migration runs once against its own just-rendered template
  (`cmp -s` → no-op) — the actual "upgrade an existing install" jq branches run
  only on a live operator's real upgrade. This is the most-complex,
  most-regression-prone function in the entrypoint (CHANGELOG: #773 log-path
  outage, #694/#749 hook-path/comment bugs) and nothing exercises its migration
  path.

- **#4 (duplicate reserved IP across MACs) — CONFIRMED as a UI-side validation
  gap, moderate.** `add_reservation` (dhcp.rs 1436) validates only
  `is_valid_mac` + `is_valid_ip` (syntactic); `upsert_reservation` (3261) matches
  existing entries by `hw-address` only, so two different MACs with the same
  `ip-address` both persist. No `ip-address`-uniqueness check anywhere in this
  path. Scope-limited claim per the evidence I actually hold: whether Kea itself
  then rejects the duplicate is **version-dependent and unverified from here**
  (Kea's `ip-reservations-unique` global defaults to `true` in recent releases
  and *would* reject it at config-set time, turning this into a hard 500 the
  operator sees; older/relaxed configs would silently accept two devices
  fighting for one IP). Either way the UI does no pre-check of its own, unlike
  every subnet-geometry check in the same file — that gap is the confirmed part.

- **#5 (reservation IP not checked against subnet CIDR) — CONFIRMED, minor.**
  `add_reservation` calls `is_valid_ip` (bare IPv4 syntax) and never
  `ipv4_in_cidr` against the target subnet, unlike `validate_dhcp_form` (2533-2535)
  for pools/gateway and `compatible_reservations_for_subnet` (3189) for existing
  reservations. An operator can attach an out-of-subnet address to any
  `subnet_id` with no 400 from this project's own validation.

- **#6 (no cross-subnet CIDR/pool overlap check) — CONFIRMED as a UI-side gap,
  info.** `add_subnet`/`update_subnet` (1192/1268) only run `validate_dhcp_form`,
  which checks geometry *within one* subnet's own CIDR; nothing compares against
  the other `subnet4` entries. Same hedge as #4: the downstream "Kea does not
  reject overlapping subnet4" claim is **version-dependent and not verified from
  here**; the confirmed part is that this project performs no overlap check of
  its own.

- **#7 (nmap failure misreported as `not_found`) — CONFIRMED, downgraded to
  minor.** The logic is real: on nmap failure the `2>&1` banner/error text makes
  `$nmap_out` non-empty, so `elif [ -s "$nmap_out" ]` reports `not_found`
  (`dhcp-probe.sh` 40-46), and that flows straight through
  `parse_conflict_probe_result` (dhcp.rs 2199) → `NotFound` → UI shows "no
  conflict". Traced to the end. **But** the original trigger example ("missing
  CAP_NET_RAW / root privilege") does not apply in the default deployment: the
  `ui` image sets no `USER` (Dockerfile ends at root) and the `dhcp-probe`
  compose service sets no `user:`, so the probe runs as root, and Docker's
  default capability set grants root `CAP_NET_RAW` — nmap's raw broadcast works
  without any `cap_add`. So the misclassification is real but its trigger is a
  genuine nmap runtime error, not a structural every-run failure; minor.

- **#8 (quickstart `dhcp-probe` bind-mount source absent) — CONFIRMED, info
  (mitigated).** `deploy/quickstart/docker-compose.yml` line 1174 bind-mounts
  `./scripts/dhcp-probe.sh`, which exists nowhere in the repo (real file is
  `services/ui/dhcp-probe.sh`); `deploy/dev` and `deploy/prod` have no such mount
  (they use the baked-in image copy, ui Dockerfile line 472). `setup.sh`
  `install_quickstart_compose_assets()` copies the file into
  `<install_dir>/scripts/dhcp-probe.sh` (and force-removes an auto-vivified dir
  per #538), guarded by `tests/bats/setup_quickstart_assets.bats`. Trap only
  bites someone running the quickstart compose file straight from a repo checkout
  (Docker auto-vivifies an empty dir over the container's real script). All CI
  hits the file via the real setup flow, so it is masked everywhere exercised.

- **#9 (run_dhcp_probe non-zero-exit branch unreachable) — PARTIALLY REFUTED,
  info.** `dhcp-probe.sh` runs `set -eu` (line 7), so it is *not* true that the
  script can only exit 0: any unguarded command failure (`mktemp -d`, `date`,
  an unbound var from a future edit) exits non-zero, and a container OOM/abort
  also yields a non-zero wait status. So the Rust branch (dhcp.rs 2176-2182) is
  legitimately-reachable defensive code for infra/early-exit failures, not dead
  code — and it never masks a real conflict result (a found conflict still exits
  0). Reframe: correctly defensive, just untested.

- **#10 (DDNS `dns-servers` is failover, not fan-out) — CONFIRMED, already
  tracked (#770), info.** Re-verified: every `dns-servers` array in
  `kea-dhcp-ddns.conf` lists `${DHCP_DNS_SERVER_IP}` then
  `${DHCP_DNS_SERVER_IP_SSL}`; Kea D2 treats this first-to-last, so `dns-ssl`
  never gets a record while `dns-standard` answers. Unchanged.

- **#11 (dev `dhcp.env` missing `DHCP_DNS_SERVER_IP_SSL`) — REFUTED for the real
  deployment path, info.** The env-file omission is inert: `deploy/dev` (line
  240) and `deploy/prod` (line 278) set `DHCP_DNS_SERVER_IP_SSL=${IP_SSL}` in the
  compose `environment:` block, which by Compose precedence overrides `env_file:`.
  So the value comes from `IP_SSL` (from `deploy/*/.env`), never from the
  entrypoint's `127.0.0.1` fallback, in any normal `docker compose` run. The
  127.0.0.1 fallback would only ever appear if someone ran the container with the
  env-file alone and no compose environment — not a deployment path. See new
  finding N1 for the residual real inconsistency this uncovered.

## New findings from this pass

- **N1. dev/prod compose use bare `${IP_SSL}` where quickstart uses
  `${IP_SSL:-${IP_STANDARD}}` (info/minor).** `deploy/quickstart` line 1073 sets
  `DHCP_DNS_SERVER_IP_SSL=${IP_SSL:-${IP_STANDARD}}`, but `deploy/dev` (240) and
  `deploy/prod` (278) use bare `${IP_SSL}` (same for `DHCP_DNS_SECONDARY`). In a
  standard-only deployment where `IP_SSL` is unset in `deploy/*/.env`, dev/prod
  resolve the SSL DDNS target (and the secondary DNS option) to empty →
  entrypoint's `127.0.0.1` fallback, i.e. a dead second failover target inside
  the dhcp container itself, whereas quickstart degrades to `IP_STANDARD`. This
  is the actual residue of the (refuted) #11: not the env-file, but the missing
  `:-${IP_STANDARD}` default in the two non-quickstart compose files. Low impact
  because it is only the failover entry (#770), but it is a silent
  standard-only-mode inconsistency between the three compose variants.

- **N2. `kea-dhcp4.conf` `valid-lifetime`/`max-valid-lifetime` are unquoted,
  incompletely-gated env splices (info).** Same unquoted-JSON-interpolation class
  as #2 (`kea-dhcp4.conf` lines 66-67). `DHCP_LEASE_TIME`'s only gate is
  `$((DHCP_LEASE_TIME * 2))` at entrypoint line 189, which bash evaluates to `0`
  (no error) for a pure-identifier value like `abc`, letting the raw token reach
  JSON. A trailing-garbage value (`86400x`) *does* abort via arithmetic under
  `set -e`, so the gate is partial, not absent. Distinct from #2 in that the
  resulting broken `kea-dhcp4.conf` is caught by the healthcheck (not silent),
  so lower severity — noted for completeness of the interpolation-safety class.

## New findings from a follow-up pass (SoT-dhcp.md capability inventory, #843)

This pass re-read `services/dhcp/entrypoint.sh` and its compose wiring
against current `origin/v0.2.0` while building `docs/capability-inventory/SoT-dhcp.md`,
which post-dates issue #858 (shared-secret bootstrap, merged 2026-07-16) and
issue #967/PR #988 (case-insensitive placeholder-detection parity, merged
2026-07-18) -- both landed after this file's original collection pass. One
new finding, already fully actioned (per issue #1068 item 9's working-doc
wind-down guidance, a fully-filed finding is a one-line pointer here, not a
duplicated write-up):

- **N3. `KEA_CTRL_TOKEN` healthcheck placeholder-detection fallback drift**
  (moderate) -- filed and fully detailed as issue #1091, `Refs #849`. Not
  repeated here to avoid maintaining two copies of the same analysis.

## Out of scope / explicitly not re-litigated here

- `services/dhcp-proxy` (dnsmasq ProxyDHCP/PXE mode) — different code path,
  covered by its own PXE simulation script and bats tests; only the DHCP-mode
  mutual-exclusion plumbing it shares with Kea in `dhcp.rs`/`config.rs` was
  glanced at, not deeply reviewed here.
- `services/ui/src/config.rs`, `main.rs`, `session.rs`, `nats_auth_callout.rs` —
  covered by the separate "services/ui core + NATS/auth" capability-inventory
  pass; only the DHCP/Kea-specific fields (`kea_config_snapshot_dir`,
  `kea_keep_known_good_configs`, `effective_dhcp_*` getters) were checked here,
  and no issues were found in that subset.
- Issue #837 (no real E2E test for the Admin UI's own `/dhcp/snapshot/rollback`
  route) and issue #836 (`setup.sh reset-to-last-known-good-config`'s `dns`/`pdns`
  target still `die`s) — both already open and already covered by the existing
  #843 inventory comment; re-verified still accurate, not repeated in full here.
