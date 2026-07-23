<!--
lancache-ng (https://github.com/wiki-mod/lancache-ng)
Raw bug-hunt findings for services/dns, part of the vacuum-first sweep
tracked in issue #849 (sub-issue of #843).
-->

# Bug hunt: services/dns

CLD-1784120971

Part of the project-wide "vacuum-first" bug-hunt sweep tracked in issue #849 (sub-issue
of #843). This is a raw, unfiltered collection pass -- everything noticed is listed,
including info-level items already touched on by the earlier capability-inventory audit
(`docs/capability-inventory/SoT-dns.md` on `docs/inventory-dns`) where this pass
re-verified them directly against current code. Verification/triage happens in a later,
separate phase of the workflow, not here.

Audited against `origin/v0.2.0` (HEAD at audit time: `3f53ac3b`), in a dedicated worktree/
branch (`bughunt-dns`), covering: `services/dns/entrypoint.sh`, `pdns.conf.template`,
`recursor.conf.template`, `recursor.lua`, `filter-aaaa.lua`, `cdn-domains.txt`,
`Dockerfile`, the full `nats-subscriber` Rust crate (`main.rs`, `zone_snapshots.rs`,
`rollback_listener.rs`, `nats_publish.rs`, `Cargo.toml`), the DNS-relevant `tests/bats/*`
files, `deploy/{dev,prod,quickstart,full-setup}/docker-compose.yml`'s DNS service
definitions (healthcheck, networking, ports, env), `config/{dev,prod}/dns-{standard,ssl}.env`,
`docs/architecture-ng.md` and `docs/dns-admin-ui-scope.md`, `setup.sh`'s
`reset-to-last-known-good-config` DNS path, and `services/ui/src/routes/dns_snapshots.rs`
(the thin Admin UI forwarder into this component's rollback listener).

> **Currency check (2026-07-18):** re-verified against `origin/v0.2.0` @ `dc8d79c6`
> (68 commits merged since this doc's `3f53ac3b` base). Finding #1 (DNS healthcheck
> governance-rule violations) is now **FIXED** by PR #876 (`9c31967a`, "fix: real
> dig-based DNS healthcheck across all deploy profiles (#869)"), merged 2026-07-16 --
> see the updated finding and the run-2 verdict note below. All other findings
> (#2-#17, N1-N3) remain accurate; no other merged commit in that range touches this
> component's code paths.

---

## 1. [Healthcheck] DNS container healthchecks are inconsistent across deploy profiles and mostly violate this repo's own governance rules for DNS health checks — FIXED by PR #876 (2026-07-16)

**Status update (2026-07-18): FIXED.** PR #876 (`9c31967a`, closing #869) replaced every
non-compliant healthcheck with the same real `dig @127.0.0.1 steamcontent.com A +short
+time=2 +tries=1 | grep -q .` probe already used by `quickstart`, across **all** of
`deploy/dev/docker-compose.yml`, `deploy/prod/docker-compose.yml`,
`deploy/full-setup/docker-compose.yml`, **and** `deploy/secondary/docker-compose.yml`
(confirmed directly against current `origin/v0.2.0`: all five profiles now share the
identical dig-based `test:` line). The original finding below (kept for the historical
record) no longer describes current code.

<details>
<summary>Original finding (as of 2026-07-15, now superseded)</summary>

`AGENTS.md` explicitly states:

- AG-VAL-018: "DNS health checks must use a real query/response probe such as `dig` or an equivalent strong check."
- AG-VAL-019: "`ping` is not an acceptable DNS health check because it only proves network reachability."
- AG-VAL-020: "`ss` is not an acceptable DNS health check by itself because it only proves that a socket is listening."
- AG-VAL-004: "Do not hide required command failures with `|| true`."

Current state, verified directly against each compose file:

| File | `dns-standard`/`dns-ssl` healthcheck `test:` |
|---|---|
| `deploy/dev/docker-compose.yml` (both services) | `rec_control ping && ss -lnu \| grep -q ':53 '` |
| `deploy/prod/docker-compose.yml` (both services) | `rec_control ping && ss -lnu \| grep -q ':53 '` |
| `deploy/full-setup/docker-compose.yml` (both services) | `rec_control ping 2>/dev/null \|\| true` |
| `deploy/quickstart/docker-compose.yml` (both services) | `dig @127.0.0.1 steamcontent.com A +short +time=2 +tries=1 \| grep -q .` |

- **dev/prod**: combines a recursor-control-socket ping (process-alive only) with an
  `ss -lnu | grep ':53 '` check -- literally the exact pattern AG-VAL-020 names as
  insufficient by itself. Neither half is a real query/response probe (AG-VAL-018).
  Neither checks that `pdns_server` (authoritative) is up, that the RPZ zone actually
  loaded, or that `nats-subscriber` (the same container's third process, owning both the
  zone/record replication path and the rollback listener on 8083) is alive at all.
- **full-setup**: `rec_control ping 2>/dev/null || true` -- the trailing `|| true`
  swallows any and every failure of `rec_control ping`, so this healthcheck **always
  exits 0** regardless of whether the recursor is running, responding, or even installed.
  This is a complete no-op healthcheck, a direct instance of the pattern AG-VAL-004
  forbids.
- **quickstart** (only): a real `dig`-based query/response check against a real CDN
  domain from the shipped `cdn-domains.txt` -- this is the version that actually satisfies
  AG-VAL-018.

This is not a hypothetical drift risk -- it is a confirmed regression/never-fixed gap with
a paper trail in this repo's own history:

- Issue #44 ("fix: rec_control ping healthcheck does not verify port 53 binding or RPZ
  zone load") explicitly asked for a real DNS query check (`dig`, or `pdnsutil check-zone`)
  and was closed via PR #134.
- PR #134 (`b0d44a4`) actually shipped the **weaker** `ss -lnu`-based interim fix for
  `dev`/`prod`/`quickstart` -- not the dig-based fix the issue asked for.
- A later, unrelated commit (`5fecd6f`, PR #769, "DDNS updates never reach PowerDNS")
  bundled in an upgrade of **quickstart only** to the real `dig`-based check, without the
  same change ever propagating to `dev`/`prod`.
- `full-setup`'s always-true healthcheck has existed unchanged since that deploy profile
  was first added (`a316e5d`) and was never touched by either fix.

Net effect: three of the four ways to run this stack ship a DNS healthcheck that does not
meet this project's own documented bar, one of which (`full-setup`) provides no
verification value whatsoever, and none of the four check `nats-subscriber`'s liveness at
all (a hung/crash-looping `nats-subscriber` -- e.g. a NATS auth failure, or a stuck
`zone_snapshot_watcher` -- would leave the container reporting healthy indefinitely).

**Evidence:** `deploy/dev/docker-compose.yml:105,147`; `deploy/prod/docker-compose.yml:117,169`;
`deploy/full-setup/docker-compose.yml:131,156`; `deploy/quickstart/docker-compose.yml:925,971`;
`gh issue view 44`; `gh pr view 134` (files: `deploy/dev/docker-compose.yml`,
`deploy/prod/docker-compose.yml`, `deploy/quickstart/docker-compose.yml`,
`services/dns/pdns.conf.template`, `services/proxy/entrypoint.sh`,
`services/ui/src/routes/secondaries.rs`); `git log -S "dig @127.0.0.1 steamcontent" --oneline -- deploy/quickstart/docker-compose.yml`
→ `5fecd6f`; `git log -S "rec_control ping 2>/dev/null || true" --oneline -- deploy/full-setup/docker-compose.yml`
→ `a316e5d`.

</details>

---

## 2. [IPv6] PowerDNS Recursor has no IPv6 listener at all, contradicting this project's core "full dual-stack" claim

`recursor.conf.template`'s `incoming.listen` is:

```yaml
incoming:
  listen:
    - 0.0.0.0
```

Never `::`. `allow_from` does include `fc00::/7` (ULA), but that is meaningless if no
IPv6 socket is ever bound to receive a query in the first place. The authoritative side
(`pdns.conf.template`) similarly only binds `127.0.0.1,${PDNS_LOCAL_ADDRESS}` (both always
IPv4) -- reasonable there since it's only ever reached over loopback/the container's own
bridge IP, but the recursor is the actual client-facing, port-53 service every LAN client
would query.

This directly contradicts:
- `CLAUDE.md`: "**IPv6 support** — full dual-stack"
- `docs/architecture-ng.md:64`: "IPv4 + IPv6 everywhere (dual-stack)"
- `docs/architecture-ng.md:250`: "PowerDNS: dual-stack listeners, AAAA records, IPv6 reverse zones"

Compounding this: there is **zero** IPv6 wiring anywhere in any `deploy/*/docker-compose.yml`
-- no `enable_ipv6:` on any network, no IPv6-form port-publish syntax (e.g. `[::]:53:53/udp`
or a literal IPv6 host address), and in fact zero occurrences of the string "ipv6"
(case-insensitive) in any of the four compose files at all. `PROXY_IPV6`/AAAA-record
generation (RPZ zone, `filter-aaaa.lua`) is fully implemented on the *content* side, but
there is no verified path anywhere in this repo for a client to actually reach this
service and receive a DNS answer over IPv6 transport.

**Evidence:** `services/dns/recursor.conf.template:4-13`; `services/dns/pdns.conf.template:15`;
`grep -rn -i ipv6 deploy/*/docker-compose.yml` → no matches; `CLAUDE.md` "Project Purpose"
section; `docs/architecture-ng.md:64,250`.

---

## 3. [Doc drift] `docs/architecture-ng.md`'s PowerDNS "Optional features" table is substantially wrong, not just the two items already flagged by the capability-inventory audit

The SoT audit (`docs/capability-inventory/SoT-dns.md` §11) already flagged
`FILTER_AAAA_V4`/`FILTER_AAAA_V6` and the "PTR checkbox" claim as stale. Re-verifying the
whole table (`docs/architecture-ng.md:77-87`) directly against current code turns up that
almost none of it matches reality:

| Doc claims | Actual code |
|---|---|
| `ENABLE_ROOT_MIRROR`, default `false` | Real var is `ROOT_ZONE_MIRROR` (`entrypoint.sh:56`: `ROOT_ZONE_MIRROR="${ROOT_ZONE_MIRROR:-1}"`) -- wrong name *and* wrong default (defaults to **on**, not off) |
| `FILTER_AAAA_V4` / `FILTER_AAAA_V6`, two separate vars | Neither exists anywhere in `services/dns/` or `services/ui/src`; real mechanism is one global marker-file toggle (`filter-aaaa.lua`, no per-address-family split) |
| `SECONDARY_MASTERS` / `SECONDARY_ZONES` | Confirmed absent from all of `pdns.conf.template`/`entrypoint.sh` -- no PowerDNS-native secondary/AXFR support exists at all (also independently confirmed by `docs/dns-admin-ui-scope.md` §3a) |
| `ENABLE_SECONDARY` | Real, but per `docs/dns-admin-ui-scope.md` this names an unrelated NATS-bind convention, not a PowerDNS secondary/AXFR feature -- the table presents it as if it belonged to the same PowerDNS-secondary feature set as the two nonexistent vars next to it |

This is the entire "Optional features" table for PowerDNS -- effectively none of the five
rows accurately describes current code.

**Evidence:** `docs/architecture-ng.md:77-87`; `services/dns/entrypoint.sh:56`;
`services/dns/pdns.conf.template` (no `SECONDARY_MASTERS`/`SECONDARY_ZONES`/AXFR-secondary
directives present); `docs/dns-admin-ui-scope.md` §3a.

---

## 4. [Doc drift] `docs/dns-admin-ui-scope.md` still describes the zone/record rollback mechanism as unimplemented design, but it has been fully shipped and tested for some time

`docs/dns-admin-ui-scope.md:250-295` (§4, "Known-good config snapshot / rollback — Admin
UI perspective") says:

> **Scoped design, not yet implemented:** zone/record data rollback (#628) — ... **PR #730
> is open, not yet merged into `v0.2.0`, as of this writing** ... Nothing here exists in
> code yet — no snapshot creation in `nats-subscriber`, no `/domains`-page (or new page)
> snapshot list, no rollback route.

and the summary table (line 295): `Zone/record snapshot/rollback (#628) | Design scoped
(PR #730), zero code | Planned, v0.3.0 candidate, blocked on the NATS-replication design
question above`.

This is stale. Confirmed directly against current code at `origin/v0.2.0`: issue #628 is
closed, and `services/dns/nats-subscriber/src/zone_snapshots.rs`,
`services/dns/nats-subscriber/src/rollback_listener.rs`, and
`services/ui/src/routes/dns_snapshots.rs` all exist, are fully wired (snapshot creation on
every NATS-applied write plus a 60s unconditional export-and-diff watcher, a real
`GET /snapshots` + `POST /rollback` HTTP listener with `X-API-Key` auth on port 8083, and
an Admin UI route forwarding to it), and are covered by 23 unit tests
(`zone_snapshots.rs`), 4 unit tests (`rollback_listener.rs`), and a real end-to-end
simulation (`scripts/dns-zone-rollback-simulation.sh`). This was already flagged in the
capability-inventory SoT pass (§11); re-verified independently here as part of this sweep.

**Evidence:** `docs/dns-admin-ui-scope.md:250-295`; `services/dns/nats-subscriber/src/zone_snapshots.rs`
(exists, 23 tests); `services/dns/nats-subscriber/src/rollback_listener.rs` (exists, 4
tests, `router()`/`serve()` wiring); `services/ui/src/routes/dns_snapshots.rs` (exists);
`gh issue view 628` (closed).

---

## 5. [Concurrency] No mutual exclusion between the rollback listener's PATCH and the NATS consumer's live record-update PATCH -- a race can silently undo either one

`rollback_handler` (`rollback_listener.rs`):
1. `GET`s the current live zone state (no lock held) -- lines 316-352.
2. Builds the rollback patch from that snapshot (no lock held) -- line 355.
3. **Only then** acquires `state.snapshot_lock` (line 364) and applies the `PATCH`
   (lines 366-423) while holding it.

`handle_dns_record` (`main.rs`, the NATS consumer's own live-record-update path) sends its
own `PATCH` to the exact same PowerDNS zone API endpoint (lines 692-704) **without ever
acquiring `snapshot_ctx.lock`/`snapshot_lock` at all** -- that shared lock is only ever
taken later, inside `maybe_snapshot_zone` (line 153), purely to guard this process's own
*snapshot bookkeeping*, never the live PowerDNS write itself.

Consequence: an Admin-UI-driven record change (arriving via NATS at any point) and an
operator-triggered rollback can interleave freely. If both target the same `(name, type)`
key, whichever `PATCH` reaches PowerDNS's SQLite-backed API last wins -- silently
reverting part of the just-applied Admin UI change, or silently undoing part of the
intended rollback, with no error, no log correlation between the two events, and no
retry. The window is a real HTTP round-trip (GET + patch-build) on the rollback side,
open to interleaving with anything the NATS consumer processes in that window.

**Evidence:** `services/dns/nats-subscriber/src/rollback_listener.rs:238-364` (GET, build,
then lock);`services/dns/nats-subscriber/src/main.rs:650-704` (`handle_dns_record`'s PATCH,
no lock taken); `zone_snapshots.rs`'s `SnapshotContext`/`RollbackState.snapshot_lock` doc
comments confirm the lock's stated purpose is "so a snapshot-creation tick and an
in-progress rollback ... never interleave" -- concurrent *live writes* are not in scope of
what it protects.

---

## 6. [Error handling] Zone-creation loops in `entrypoint.sh` mask all `pdnsutil create-zone` failures, not just "already exists"

```bash
for zone in "${LAN_ZONES[@]}"; do
    pdnsutil --config-dir=/etc/pdns/auth create-zone "$zone" || true
done

for zone in "${PRIVATE_REVERSE_ZONES[@]}"; do
    pdnsutil --config-dir=/etc/pdns/auth create-zone "$zone" || true
done
```

The comment above this block says "will not error if already exist," which is true for
the *expected* re-run case, but the blanket `|| true` also silently swallows any *other*
failure mode -- SQLite corruption/lock contention, disk full, permission error on
`/var/lib/powerdns`, or a malformed zone name -- with zero log output distinguishing that
case from "zone already existed." This is the exact pattern AG-VAL-004 calls out
("Do not hide required command failures with `|| true`. Use optional fallbacks only when
the command is explicitly optional and the reason is documented"): the fallback here is
not scoped to the one documented reason (idempotent re-creation), it is unconditional. A
real failure to create e.g. `lan.` on first boot would leave the zone missing with no
FATAL/ERROR line anywhere, surfacing only much later as unexplained NXDOMAIN/zone-not-
found errors from DDNS or the Admin UI.

**Evidence:** `services/dns/entrypoint.sh:676-684`.

---

## 7. [Correctness, latent] `dns_record_to_zone_update` allows a `replace` action with `ttl: None`, which is silently unrecoverable if it ever reaches PowerDNS

```rust
"replace" => (
    Some("REPLACE".to_string()),
    record.ttl,          // Option<i32>, may be None
    record.records.clone(),
),
```

`RRset.ttl` is `#[serde(skip_serializing_if = "Option::is_none")]`, so a `None` ttl omits
the `"ttl"` key entirely from the JSON body sent to PowerDNS's zone `PATCH` endpoint.
PowerDNS's HTTP API requires `ttl` for a `REPLACE` changetype rrset; a request missing it
would be rejected as a 4xx. `handle_dns_record`'s success path treats any 4xx as an
"unrecoverable, won't retry" client error and acks (drops) the message permanently.

No currently-known caller actually triggers this: `services/ui/src/routes/domains.rs`'s
`add_lan_record` always sets `ttl` (`form.ttl.unwrap_or(300)`), and the `reconciler()`/
rollback-republish paths source `ttl` from a live PowerDNS export where it should already
be populated. But the code path is explicitly built and unit-tested as a supported case
(`dns_record_to_zone_update_replace_without_ttl` asserts this "must succeed" at the Rust
layer) without any comment noting that the resulting PowerDNS API call would actually
fail -- a latent trap for any future publisher that constructs a `replace` message without
an explicit ttl.

**Evidence:** `services/dns/nats-subscriber/src/main.rs:624-648` (`dns_record_to_zone_update`),
`main.rs:730-741` (4xx → ack, won't retry), `main.rs:1038-1057` (the test asserting this
succeeds at the Rust layer); `services/ui/src/routes/domains.rs:167` (`form.ttl.unwrap_or(300)`,
confirming the only known producer always sets ttl today).

---

## 8. [Test coverage gap] No drift guard between `entrypoint.sh`'s inline RPZ-generation logic and its hand-copied duplicate in the bats test helper

`services/dns/entrypoint.sh`'s RPZ zone-generation block (lines ~688-729) is inlined
directly in the main script body -- it is not factored into a standalone, sourceable
function. `tests/bats/dns_zone_generation.bats` tests this behavior via
`tests/bats/helpers/dns-zone-helpers.sh`'s `generate_rpz_zone()`, which is a **manually
maintained, hand-copied duplicate** of that same logic (currently identical, verified by
direct comparison), not an extraction/sourcing of the real script.

Unlike the known-good-snapshot shell library, which has an explicit drift guard
(`tests/bats/known_good_snapshots_sync.bats`, diffing the embedded copy in `entrypoint.sh`
against the canonical `scripts/lib/known-good-snapshots.sh` byte-for-byte), there is no
equivalent test anywhere that would fail if `entrypoint.sh`'s RPZ block and
`dns-zone-helpers.sh`'s copy ever diverge. A future edit to one without the other would
leave `dns_zone_generation.bats` green while testing logic that no longer matches
production.

**Evidence:** `services/dns/entrypoint.sh:688-729`; `tests/bats/helpers/dns-zone-helpers.sh:8-60`;
`grep -rn "dns-zone-helpers\|generate_rpz_zone" tests/bats/*.bats scripts/` → only
referenced from `dns_zone_generation.bats` itself, no sync-check file found.

---

## 9. [Documented-but-unfixed] `configure_ddns_tsig()` has no revoke path if `DDNS_TSIG_KEY` is later blanked

```bash
configure_ddns_tsig() {
    case "$DDNS_TSIG_KEY" in
        "")
            echo "[lancache-dns] DDNS_TSIG_KEY is not set; TSIG-authenticated DNS updates are not configured."
            return
            ;;
        ...
```

If an operator previously configured a real `DDNS_TSIG_KEY` (granting
`TSIG-ALLOW-DNSUPDATE` on all 22 `DDNS_UPDATE_ZONES`) and later blanks it (config edit,
migration), this function just logs and returns -- it never calls anything to revoke the
previously-granted `TSIG-ALLOW-DNSUPDATE` metadata. The zones retain stale TSIG
authorization indefinitely. Already documented as a known, unfixed gap in
`docs/known-good-config-snapshots.md`'s "Zones, records" section; re-confirmed directly
against the current code here. No open GitHub issue found tracking this specific gap.

**Evidence:** `services/dns/entrypoint.sh:413-434` (`configure_ddns_tsig`, no revoke call
in the empty-key branch).

---

## 10. [Security hardening, info] All three processes in this container run as root

The `Dockerfile` has no `USER` directive, and neither `pdns.conf.template` nor
`recursor.conf.template` sets `setuid`/`setgid`. None of the three long-lived processes
(`pdns_server`, `pdns_recursor`, `nats-subscriber`) actually need root: the authoritative
server's own bind (`local-address=127.0.0.1,${PDNS_LOCAL_ADDRESS}`, port 5300) is an
unprivileged port; the recursor's port-53 bind is the only thing that would need
elevated privilege, and that could be granted via `CAP_NET_BIND_SERVICE` instead of full
root. A compromise of any of the three processes (a future PowerDNS CVE, or a bug in the
Rust `nats-subscriber`'s own HTTP-facing surfaces) would grant full root inside the
container rather than a scoped, unprivileged user.

**Evidence:** `services/dns/Dockerfile` (no `USER` directive anywhere); `services/dns/pdns.conf.template`,
`services/dns/recursor.conf.template` (no `setuid`/`setgid` directive in either).

---

## 11. [Info] Root-zone AXFR mirror uses IPv4-only root server addresses

```lua
zoneToCache(".", "axfr", "199.9.14.201", { refreshPeriod=3600, retryOnError=3600 })
zoneToCache(".", "axfr", "192.33.4.12",    { refreshPeriod=3600, retryOnError=3600 })
zoneToCache(".", "axfr", "192.5.5.241",    { refreshPeriod=3600, retryOnError=3600 })
```

All three hardcoded root-server addresses are IPv4-only (b/c/f.root-servers.net); no
IPv6 root-server address is configured as a fallback. Consistent with finding #2's
broader IPv4-only-transport gap for this component -- if this container's IPv4 route
were ever to fail while IPv6 connectivity remained available, the root-zone mirror
(`ROOT_ZONE_MIRROR=1`, on by default) would have no way to refresh. Low real-world risk
given typical Docker networking, but a real single-point-of-failure on the transport
IP family.

**Evidence:** `services/dns/recursor.lua:38-40`.

---

## 12. [Info, superseded by #1072] Wildcard-only ("leading dot") CDN domain syntax is implemented and unit-tested but never exercised by the real shipped domain list

**STATUS as of #1072's fix:** this finding described the state of the file *before* a
related bug and a related migration. The bug this finding didn't itself flag:
`entrypoint.sh`'s RPZ generator emitted the wildcard `*.<domain>` record
**unconditionally**, regardless of `is_wildcard_only` -- a bare entry always got both the
exact-match record and a wildcard record, so the leading-dot form was never actually
needed to get subdomain coverage, which is exactly why no one had reached for it. #1072
fixed the generator so the wildcard record is now gated by `is_wildcard_only`, and
migrated the `services/dns/cdn-domains.txt` entries that rely on real subdomain coverage
(see that PR body for the per-entry migration reasoning) to the leading-dot form. The
original observation below is preserved for historical context; "zero leading-dot
entries" is no longer accurate post-migration.

Original finding: `entrypoint.sh`'s RPZ generator (and the mirrored bats helper) both
fully implement a "leading dot = wildcard-only, no base-domain record" convention for
`cdn-domains.txt` entries. `tests/bats/dns_zone_generation.bats` exercises this via
synthetic fixtures. However, the real, shipped `services/dns/cdn-domains.txt` (162 lines)
contains **zero** leading-dot entries (`grep -n '^\.' services/dns/cdn-domains.txt` → no
matches) -- this behavior has never been exercised against the actual file PowerDNS loads
in production, only against test fixtures.

**Evidence:** `services/dns/cdn-domains.txt` (`grep -n '^\.'` → empty);
`services/dns/entrypoint.sh:712-716` (`is_wildcard_only` branch).

---

## 13. [Info] `setup.sh reset-to-last-known-good-config dns`'s die-message points at a now-closed issue as if it were still blocking

```
die "reset-to-last-known-good-config for '$service' is not implemented yet: it depends on
the PowerDNS zone/record rollback listener tracked in issue #628. Once that lands, this
command will call it the same way the 'kea' target already calls Kea's Control Agent
API. Until then, see docs/known-good-config-snapshots.md's \"Manual recovery\" section."
```

Issue #628 is closed, and the listener this message says is still pending
(`rollback_listener.rs`, port 8083) has been fully implemented and tested for some time
(see finding #4 / SoT §5b-§6). The underlying CLI-completion gap is already tracked
(issue #836, explicitly deferred to v0.3.0 by maintainer decision) -- this is not a new
feature gap, but the specific wording of this die-message is itself now factually
stale/misleading on its own: an operator who checks issue #628 after reading this message
would find it closed and could reasonably wonder why the CLI still refuses, since the
message frames the closed issue as the open blocker.

**Evidence:** `setup.sh:4353` (`cmd_reset_to_last_known_good_config`'s die message for the
`dns`/`pdns` case); `gh issue view 628` (closed); `gh issue view 836` (open, the actual
tracked CLI gap).

---

## 14. [Info] `filter-aaaa.lua`'s AAAA-suppression hook has zero observability

```lua
function preresolve(dq)
    if dq.qtype == pdns.AAAA and filter_active() then
        dq.rcode = pdns.NOERROR
        dq.variable = true
        return true
    end
    return false
end
```

Functionally correct (returning `NOERROR` with no records is the right NODATA-style
synthesized answer to force IPv4 fallback), but there is no log line anywhere when this
actually fires and suppresses a query. An operator toggling the filter via the Admin UI
has no way to directly confirm from DNS-side logs that a specific query was actually
suppressed versus just genuinely having no AAAA record. Also re-opens/`io.open`s the
marker file on every single AAAA query with no caching -- functionally fine (a marker-file
existence check is cheap), just worth noting as an unoptimized per-query I/O call.

**Evidence:** `services/dns/filter-aaaa.lua:9-24`.

---

## 15. [Info] RPZ SOA serial's `tail -c 11` truncation is currently a no-op

```bash
SERIAL=$(date +%s | tail -c 11)
```

`date +%s` currently emits a 10-digit value plus a trailing newline (11 bytes total), so
`tail -c 11` currently passes the entire value through unchanged -- the truncation this
line implies only actually starts removing digits once Unix time reaches 11 digits
(around the year 2286). Harmless today, but worth flagging that this isn't bounding
anything yet, in case it was intended to guard against a different-width input.

**Evidence:** `services/dns/entrypoint.sh:690`; mirrored in
`tests/bats/helpers/dns-zone-helpers.sh:13`.

---

## 16. [Info] `run_check_zone` (rollback_listener.rs) has no execution timeout

```rust
fn run_check_zone(zone: &str) -> bool {
    match std::process::Command::new("pdnsutil")
        .args(["--config-dir=/etc/pdns/auth", "check-zone", zone])
        .output()
    { ... }
}
```

Invoked via `tokio::task::spawn_blocking` with no timeout wrapper. A hang in `pdnsutil
check-zone` (e.g. against a corrupted or unusually large zone) would tie up a
`spawn_blocking` worker thread indefinitely, delaying (but not corrupting, since the
PATCH has already been applied and this call is purely informational) the HTTP response
to the operator's rollback request. Low real-world risk given the bounded set of 22
managed zones and their typical size, but there is no defensive timeout.

**Evidence:** `services/dns/nats-subscriber/src/rollback_listener.rs:139-152`.

---

## 17. [Info] `zone_snapshot_watcher`'s 22 sequential per-zone GETs share one 10s-timeout HTTP client with no per-tick budget

`zone_snapshot_watcher` iterates all 22 `ROLLBACK_ZONES` every 60 seconds, calling
`maybe_snapshot_zone` (one `GET` per zone) sequentially. Each call can take up to the
shared client's 10s timeout if PowerDNS is responding slowly (not down, just degraded).
In the worst case (every zone slow but not failing), a single tick could take up to
~220 seconds, well past the 60s interval -- self-correcting since this uses
`tokio::time::interval` (ticks queue up / fire immediately once the previous await
resolves, no double-firing), but worth noting as an unbounded-worst-case interaction
between per-request timeout and per-tick zone count that neither the code nor
`docs/known-good-config-snapshots.md` calls out explicitly.

**Evidence:** `services/dns/nats-subscriber/src/main.rs:176-188` (`zone_snapshot_watcher`);
`main.rs:292-299` (shared `http_client` with `Duration::from_secs(10)` timeout).

---

## Summary

Confirmed, previously-undocumented findings from this pass: the DNS healthcheck
inconsistency/governance-violation across all four deploy profiles (#1, the most
actionable and highest-confidence finding here, with a full paper trail via issues #44/
PR #134/PR #769 -- **now FIXED by PR #876/#869, merged 2026-07-16, see currency-check
note above**), the IPv6-listener gap contradicting this project's core dual-stack
claim (#2), the rollback-vs-live-write TOCTOU race (#5), the blanket `|| true` on zone
creation (#6), the latent replace-without-ttl trap (#7), and the missing RPZ-helper
drift guard (#8). Findings #3, #4, #9, #13 re-verify and extend doc-drift/gaps the
capability-inventory SoT pass already flagged, confirming they are still true against
current code as of this sweep. Findings #10-#12, #14-#17 are lower-severity/info-level
observations collected per this sweep's vacuum-first, no-prefiltering mandate.

---

# Re-verification pass (run 2) — self-verified against `3f53ac3`

CLD-1784147487

Second independent pass over the same component, this time with in-context
self-verification of every finding above (no separate verifier agent). Base
re-confirmed as the current `origin/v0.2.0` tip: `gh api
repos/wiki-mod/lancache-ng/branches/v0.2.0 --jq .commit.sha` →
`3f53ac3b55e4975cdf8155a91fb80dd2cfdd3363`, so none of the findings below are
upstream-fixed since the run-1 write-up.

## Verdicts on findings 1–17

All 17 re-verified directly against the code at `3f53ac3` and **CONFIRMED**. The
run-1 evidence above holds line-for-line; spot notes where re-verification added
detail:

- **#1 Healthcheck (serious):** confirmed as of this run (5 profiles / 4 distinct
  styles including bare `rec_control ping` on `secondary`,
  `deploy/secondary/docker-compose.yml:34`, not in the run-1 table; only
  `quickstart` compliant). **Currency check (2026-07-18): now FIXED** by PR #876
  (`9c31967a`, closes #869), merged two days after this run -- all five profiles
  now share the same dig-based probe. See the FIXED note on finding #1 above.
- **#2 Recursor no IPv6 listener (serious):** confirmed; known/deferred as
  #851. Run-1 already noted the authoritative bind is IPv4-only too — see N2.
- **#3 / #4 doc-drift (moderate):** confirmed by tree-wide grep. #3: of the 7
  rows in `architecture-ng.md`'s optional-features table, `ENABLE_ROOT_MIRROR`,
  `FILTER_AAAA_V4/V6`, `SECONDARY_MASTERS`, `SECONDARY_ZONES` = 0 code refs;
  `ENABLE_SECONDARY` appears only in a compose comment. #4: confirmed stale
  (setup.sh:4347 shows the real merge was #628/PR #788).
- **#5 TOCTOU (moderate):** confirmed and worth emphasizing — `snapshot_lock`
  guards only snapshot bookkeeping (`maybe_snapshot_zone`, main.rs:153); the
  consumer's live PATCH (main.rs:698) is never under it, and the rollback
  handler's current-state GET (rollback_listener.rs:316-353) runs *before* the
  lock, so the two PowerDNS writers are never mutually excluded.
- **#6–#8 (minor):** confirmed (zone-create `|| true` at entrypoint.sh:677-684;
  `replace`+`ttl:None` dropped as 4xx-ack at main.rs:730-741; RPZ helper is a
  hand-copy with no sync guard, and `dns_zone_generation.bats:139` exercises the
  copy not the entrypoint).
- **#9–#17 (info):** all confirmed (TSIG no-revoke; root uid; IPv4-only root
  AXFR; wildcard-only syntax unit-tested but 0 leading-dot lines in the shipped
  `cdn-domains.txt`; stale setup.sh #628 message; AAAA-filter no observability;
  `tail -c 11` no-op; `run_check_zone` no timeout; 22 sequential GETs on one
  10s client).

## New findings this pass

### N1 [info/minor] — consumer PATCH path does not canonicalize `record.zone`, unlike the snapshot and rollback paths
`main.rs::handle_dns_record` builds the PATCH URL from `record.zone` verbatim
(main.rs:692-695), while its own post-PATCH snapshot uses
`canonical_zone(&record.zone)` (main.rs:722-728) and the rollback listener uses
`canonical_zone` + `zone_api_id`. A `lancache.dns.record` message whose `zone`
carries a trailing dot (`"lan."`) would PATCH `.../zones/lan.` — PowerDNS's API
id is `lan` — and get a 4xx that `handle_dns_record` acks and silently drops
(main.rs:730-741), while the snapshot trigger (canonicalized) still fires against
the correct zone. All in-tree publishers send the bare form (UI
`domains.rs:182,231` `"zone": "lan"`; reconciler main.rs:884; rollback republish
rollback_listener.rs:467), so live impact is nil today — but the consumer has no
defensive normalization; the contract rests entirely on every publisher agreeing
on the bare form. Fix: `zone_api_id(&canonical_zone(&record.zone))` on the PATCH
URL, matching the other two paths.

### N2 [info] — authoritative DDNS bind is IPv4-only (already noted within finding #2, restated for the #851 scope)
`detect_pdns_local_address` (entrypoint.sh:121-143) only detects IPv4
(`ip -4 route get` / `ip -4 addr show`), and `pdns.conf.template:15` binds
`127.0.0.1,${PDNS_LOCAL_ADDRESS}` — IPv4 only. So #851's dual-stack gap is
broader than the recursor's missing `::` listener: the authoritative
DDNS-update path is IPv4-only too, and a purely-IPv6 DDNS host could never reach
it. Fold into #851 scope.

### N3 [info] — both PowerDNS REST-API allowlists are IPv4-only
Distinct from the recursor's *incoming DNS* `allow_from` (which does list
`fc00::/7`): the REST/webserver allowlists list only IPv4 loopback + RFC1918 —
`pdns.conf.template:31` `webserver-allow-from=127.0.0.1,10.0.0.0/8,
172.16.0.0/12,192.168.0.0/16` and `recursor.conf.template:114-118`
`webservice.allow_from` (no `::1` / `fc00::/7`). A caller reaching these APIs
over IPv6 would be rejected. No live breakage (nats-subscriber uses
`127.0.0.1`), another facet of the #851 dual-stack gap.

## Overall (run 2)

Nothing in run-1 was overturned; every finding stands against the current
`3f53ac3` tip. The actionable, currently-untracked items remain the healthcheck
governance violation (#1, serious) and the two doc-drifts (#3/#4, moderate); the
TOCTOU (#5) is real but inherent to the current locking design; the dual-stack
gap is tracked (#851) but broader than the recursor alone (N2/N3). Everything
else is minor/info hardening and observability debt.
