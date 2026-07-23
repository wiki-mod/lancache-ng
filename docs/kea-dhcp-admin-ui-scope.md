# Kea DHCP Admin UI — Feature Scope

This is the written decision issue #646 asked for: a single place that says what
the Admin UI is intended to let an operator configure/manage for **Kea (full
DHCP mode)**, so that code which looks unused or half-finished is not misread as
dead/removable by a future contributor or agent. Kea feature work has happened
incrementally (subnets, reservations, options, activation preflight #449,
known-good config snapshots #614/#631) without ever writing down the full
intended surface in one place — this document is that surface. It is the DHCP/Kea
sibling of [`dns-admin-ui-scope.md`](dns-admin-ui-scope.md) (issue #645) and
[`dnsmasq-dhcp-admin-ui-scope.md`](dnsmasq-dhcp-admin-ui-scope.md) (issue #647).

This is a **scoping document, not an implementation plan**. Nothing in the
"planned but unbuilt" sections below is committed work; per issue #646's own
framing this is v0.3.0-candidate scope until a maintainer decision says
otherwise. Where this document says "planned but unbuilt," treat the referenced
code (or its absence) as intentional, not as something to "clean up."

## 0. Prerequisite finding: the DHCP Admin UI is not working end-to-end today

This must come first because it changes what "full feature scope" means for this
UI. Live hands-on testing against a running v0.2.0 install (issue #1068, sections
6–7) found the DHCP Admin UI **completely non-functional end-to-end for both DHCP
modes**: Native DHCP (Kea) and dnsmasq-proxy both failed to activate ("Failed to
start '…' — TEST Failed"). This happened despite the building blocks this issue
references as already built (#631 known-good config snapshots, #642 real Kea
lease-flow behaviour test, #557 multi-service e2e client simulation) all being
merged/closed with passing CI.

The implication: the existing CI coverage does not exercise the actual failure
path an operator hits going through the Admin UI activation flow. **A working
activation baseline is itself part of this UI's scope**, not a separate concern —
whoever picks up the Kea Admin UI rework should treat "why does activation fail
despite green CI" as a prerequisite, not defer it. This is not yet root-caused
here; #1068 is the tracking issue for the field-test failure.

## 1. Operator-configurable via Admin UI vs. config-file-only

### 1a. Config-file-only (env var / JSON template, requires a container restart)

These are read at `services/dhcp` container start (`services/dhcp/entrypoint.sh`
plus the JSON templates `kea-dhcp4.conf`, `kea-ctrl-agent.conf`,
`kea-dhcp-ddns.conf`) and are not writable from any Admin UI route today.

| Setting | Source | Notes |
|---|---|---|
| Control-agent API socket / auth | `kea-ctrl-agent.conf`, `entrypoint.sh` | The Admin UI is a *client* of the Kea control-agent API (`lease4-del`, `config-*`), not a manager of the agent's own config |
| Kea DDNS TSIG / update keys | `kea-dhcp-ddns.conf`, PowerDNS `configure_ddns_tsig()` | Shared with PowerDNS; rotating needs coordinated rollout across both containers, not a one-sided UI edit (same reasoning as the DNS doc's §1a) |
| `DHCP_DOMAIN` (forward DDNS target zone, default `lan`) | `config/*/dhcp.env` | Determines which PowerDNS zone forward DDNS host records land in — defaults to the already-UI-managed `lan.` zone |
| DDNS target DNS server list | `kea-dhcp-ddns.conf` `forward-ddns`/`reverse-ddns` → `dns-servers` | See §3; this is the subject of open bug #770 |
| NTP defaults | `DHCP_NTP_SERVERS` (`config/*/dhcp.env`) | Project-wide policy value (AG-OP-014) — not a per-PR cleanup target |
| Known-good snapshot retention/dir | `entrypoint.sh` env | Automatic, see §4 |

### 1b. Operator-configurable via Admin UI today

Routes are registered in `services/ui/src/main.rs`; handlers live in
`services/ui/src/routes/dhcp.rs`.

| Setting | Route | Handler |
|---|---|---|
| DHCP mode (`disabled` / `kea` / `dnsmasq-proxy`) | `POST /dhcp/mode` | `update_dhcp_mode` → `reconcile_dhcp_mode`, persisted to the UI settings file (whole file rewritten each save) |
| Subnet add / edit / remove | `POST /dhcp/subnet/{add,update,remove}` | `add_subnet` / `update_subnet` / `remove_subnet` |
| Per-subnet DHCP options | `POST /dhcp/subnet/option/{add,remove}` | `add_subnet_option` / `remove_subnet_option`; option code parsed by `parse_custom_dhcp_option_code` — **numeric codes 1–254 only today** (see §2, open issue #1085) |
| Static reservations (MAC → IP) | `POST /dhcp/static/{add,remove}` | `add_reservation` / `remove_reservation` |
| Release an active lease | `POST /dhcp/lease/release` | `release_lease` → Kea `lease4-del`; **does not remove the DDNS-created A/PTR records** (open issue #1083, see §3) |
| DHCP conflict pre-check ("DHCP-Precheck") | `POST /api/dhcp/check` | `check_dhcp_conflict` — probes for a foreign DHCP server before activation; CSRF-exempt GET-style probe (#947/#978) |
| Kea config snapshot rollback | `POST /dhcp/snapshot/rollback` | `rollback_kea_snapshot` (#614) |

### 1c. Not settings — read-only status surfaces

`dhcp_page` (`GET /dhcp`) also renders the current subnets, reservations, active
leases, and snapshot list as read-only displays alongside the mutation forms —
the display half of 1b, not a separate configuration category.

## 2. Subnet / reservation / option management surface

**What exists today:** subnet CRUD, reservation CRUD, and per-subnet custom DHCP
options are all live (1b). Options are validated by `parse_custom_dhcp_option_code`,
which currently accepts only numeric option codes in the 1–254 range.

**Planned but unbuilt (v0.3.0 candidate):**

- **Non-numeric Kea subnet keys for PXE (`next-server`, `server-hostname`,
  `boot-file-name`)** — open issue **#1085**. The custom-option mechanism
  (`add_subnet_option` / `parse_custom_dhcp_option_code`) rejects these three
  because they are not numeric option codes, even though Kea treats them as
  first-class per-subnet keys. The mockup's "PXE options" grouping depends on
  them. This is an intentional planned extension, not a bug in the numeric
  validator — the validator is correct for what it currently claims to cover.
- **Standard-options table with per-option tooltips** — maintainer design input
  on #646 (2026-07-19): standard DHCP options should *all* be configurable,
  presented as a table, with a mouseover/tooltip description per option. Today
  the surface is a free-form "add a numeric option code + value" form, not a
  curated table of named standard options. See §6 for the i18n dependency this
  introduces.

**Intentionally out of scope (not planned):** a general-purpose Kea JSON config
editor in the UI. Kea's full config surface is large; exposing arbitrary JSON
editing is a different product from a curated subnet/reservation/option manager
and is not this project's goal.

## 3. DHCP-DDNS follow-through (Kea lease → PowerDNS record)

**Current state.** `services/dhcp/kea-dhcp-ddns.conf` has `dhcp-ddns.enable-updates`
hardcoded `true` in `kea-dhcp4.conf` (line 20). Kea's D2 daemon sends forward
host-record updates to `${DHCP_DOMAIN}` (default `lan`, landing in the
UI-managed `lan.` PowerDNS zone) and reverse/PTR updates to the per-octet private
reverse zones (fixed in #768 — previously a single non-existent `in-addr.arpa.`
catch-all caused NOTAUTH rejections).

**Two confirmed gaps, both open and in-flight as of this writing:**

- **#1076 — no independent "Enable DDNS Updates" toggle.** `enable-updates` is
  hardcoded `true` with no way to turn DDNS off while leaving DHCP-Server on.
  Issuing an address should not have to mean also updating DNS. The mockup's
  DHCP-Server panel already shows this as a dedicated toggle in the merged
  toggle-row; the real backend wiring (UI route + `entrypoint.sh` +
  `kea-dhcp4.conf` templating) is the open work.
- **#770 — DDNS updates only reach `dns-standard`, not `dns-ssl`.** Each
  `forward-ddns`/`reverse-ddns` domain's `dns-servers` list is a **failover**
  list (D2 tries the first server, falls back to the second only on failure),
  **not** a fan-out. So only whichever server answers first gets the record; the
  other DNS instance silently misses it. The real fix is to make DDNS reach
  *both* `dns-standard` and `dns-ssl` (likely two separate `ddns-domains`
  entries, one per target server, or another D2 mechanism).
- **#1083 — lease release leaves orphaned DNS records.** `release_lease` calls
  Kea `lease4-del`, which (confirmed against Kea's documentation) does **not**
  trigger a DDNS removal. The A/PTR records the lease created via DDNS survive
  the lease being released, leaving stale forward/reverse DNS entries.

**Intended end state:** DDNS is an operator-toggleable feature (#1076) that,
when on, reliably writes to *every* project DNS instance (#770) and cleans up
after itself when a lease is released or expires (#1083). Until those land,
treat the current single-target, always-on, no-cleanup behaviour as a known
limitation, not as intended final behaviour.

## 4. Known-good config snapshot / rollback (#614/#631) — Admin UI perspective

**Implemented, Admin UI-visible:** the `/dhcp` page exposes an operator-selected
Kea config snapshot picker with a rollback action (`rollback_kea_snapshot`,
`POST /dhcp/snapshot/rollback`, #614). This is the precedent the DNS
zone/record-rollback design (#628/#788) explicitly followed — see the DNS scope
doc's §4 and [`known-good-config-snapshots.md`](known-good-config-snapshots.md).

**Not built (log-only today):** there is no dashboard indicator surfacing "this
Kea node is currently running a stale known-good config because the last
regeneration was rejected." That gap is shared across all three file-based
snapshot adapters (nginx/dnsmasq/PowerDNS/Kea) and is not Kea-specific; a shared
"config snapshot rollback happened" status surface is the natural way to close
it (v0.3.0 candidate, not started — same note as the DNS doc's §4).

**Optional direction from #644:** an Admin-UI DHCP-conflict *display* (beyond the
one-shot pre-activation `check_dhcp_conflict` probe) — surfacing an ongoing
foreign-DHCP-server presence in the dashboard — is noted in #644 as an optional
enhancement, not committed scope.

## 5. Real-behavior test coverage vs. Admin UI surface

The UI surface in §1b is broader than what is currently *verified to work
end-to-end through the Admin UI*. Real-behavior coverage exists for the Kea lease
flow (#448/#642), the multi-service client simulation (#557 scenario 3), and
snapshot recovery (#634/#943), but — per §0 — none of that caught the live
activation failure in #1068. The scope decision here: the Admin UI surface is
considered "delivered" only when its activation path is covered by a test that
exercises the same route flow an operator triggers, not only the underlying Kea
binaries in isolation.

## 6. DHCP options table + i18n — the one real product decision this issue raises

The maintainer's design input (standard-options table with a localized
per-option tooltip) surfaces a **blocking dependency, verified against current
code: the Admin UI has no i18n / multi-language infrastructure at all.**
`services/ui/Cargo.toml` carries no i18n/locale/gettext/fluent crate; no template
under `services/ui/src/templates/` has a `lang=` attribute or language selector;
a full-tree grep for translation code found only Tailwind's `--tw-translate-x`
CSS utility and an unrelated code comment. The UI is hardcoded to one language.

So a *localized* tooltip depends on a real i18n foundation being built first —
that is a whole separate feature, not part of the options table.

**Recommended decision (flagged for maintainer confirmation, since #646 posed
this as an open choice):** ship the standard-options table **English-only** in
the first v0.3.0 iteration, and track a proper i18n layer (crate + locale files +
language selector) as an **explicit separate follow-up issue**, rather than
blocking the options table on i18n. Rationale: the options table delivers
operator value on its own; coupling it to a UI-wide i18n rebuild would delay both
and mix two unrelated changes (against the project's no-topic-mixing preference).
If the maintainer wants localized tooltips in the *first* release of the table
instead, the i18n layer becomes a hard prerequisite and must be scheduled ahead
of it. This document records the recommendation; the maintainer decides the
ordering.

## 7. Summary table

| Area | State | Where |
|---|---|---|
| DHCP mode switch (disabled/kea/dnsmasq-proxy) | Admin UI, implemented | `dhcp.rs::update_dhcp_mode` |
| End-to-end activation of either mode | **Broken in v0.2.0 field test** | #1068 (prerequisite) |
| Subnet CRUD | Admin UI, implemented | `dhcp.rs::{add,update,remove}_subnet` |
| Reservation CRUD | Admin UI, implemented | `dhcp.rs::{add,remove}_reservation` |
| Per-subnet numeric DHCP options (1–254) | Admin UI, implemented | `dhcp.rs::add_subnet_option` |
| PXE keys (`next-server`/`server-hostname`/`boot-file-name`) | Not built | Planned, #1085 |
| Standard-options table with tooltips | Not built | Planned, v0.3.0; i18n decision in §6 |
| Lease release | Admin UI, implemented | `dhcp.rs::release_lease` |
| Lease release → DDNS record cleanup | Not built (orphaned records) | Bug, #1083 |
| DHCP conflict pre-check ("DHCP-Precheck") | Admin UI, implemented | `dhcp.rs::check_dhcp_conflict` |
| Kea config snapshot rollback | Admin UI, implemented | `dhcp.rs::rollback_kea_snapshot`, #614 |
| "Enable DDNS Updates" toggle (independent of DHCP-Server) | Not built (hardcoded on) | Planned, #1076 |
| DDNS fan-out to both dns-standard + dns-ssl | Not built (failover, not fan-out) | Bug, #770 |
| Snapshot-rollback status indicator | Not built (log-only) | Planned, v0.3.0, not Kea-specific |
| UI i18n / localization | Not built (no infra at all) | Prerequisite for localized tooltips, §6 |
| General Kea JSON config editor | Not planned | Deliberately out of scope |

## How to use this document

If you are about to remove, "clean up," or flag as dead any Kea/DHCP-adjacent
code that looks incomplete, check this document first. If the gap you found is
listed under "planned but unbuilt" or as an open issue above, it is intentional —
file or link a v0.3.0-scoped issue instead of deleting it, and update this
document if the scope decision changes. If it's not listed here at all, that's
this document's own gap: update it rather than guessing.
