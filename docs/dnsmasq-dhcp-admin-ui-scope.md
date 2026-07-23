# dnsmasq relay/proxy DHCP Admin UI — Feature Scope

This is the written decision issue #647 asked for: a single place that says what
the Admin UI is intended to let an operator configure/manage for **dnsmasq
relay/proxy DHCP mode**, so that code which looks unused or half-finished is not
misread as dead/removable by a future contributor or agent. It is the sibling of
[`dns-admin-ui-scope.md`](dns-admin-ui-scope.md) (issue #645) and
[`kea-dhcp-admin-ui-scope.md`](kea-dhcp-admin-ui-scope.md) (issue #646).

This is a **scoping document, not an implementation plan**. Where it says
"planned but unbuilt," treat the referenced code (or its absence) as intentional,
not as something to "clean up."

## 0. The concrete open question this issue existed to resolve — now resolved

`services/dhcp-proxy/dnsmasq.conf.template` uses `dhcp-range=<subnet>,proxy`,
which puts dnsmasq into self-contained RFC 4388 ProxyDHCP/PXE mode — it answers
*supplementary* PXE/boot options alongside an existing DHCP server, but issues no
addresses of its own. This was confirmed live during #450's review (identical
`dnsmasq-dhcp: DHCP, proxy on subnet …` startup log with or without the separate
`--dhcp-proxy=` flag, which only affects relays configured through a *different*,
never-used `--dhcp-relay=` mechanism). #450's PR removed the inert
`dhcp-proxy=${UPSTREAM_DHCP_IP}` line as a no-op and its template comment
concluded the line "was a no-op … so it has been removed rather than carried
forward."

**Maintainer decision (2026-07-20), the resolution this issue was opened for:**
real DHCP relay support (`--dhcp-relay=`) was **genuinely intended as an
unfinished feature, not dead/orphaned code.** The `dhcp-proxy=${UPSTREAM_DHCP_IP}`
fragment was an orphaned remnant of an *intended-but-never-finished* real DHCP
packet-relay capability.

That means #450's template comment was **correct about current behaviour**
(the flag does nothing today) but **wrong about intent** (it concluded from
"does nothing today" that it was never meant to do anything — the exact
"Bringschuld misread as unnötig" failure mode this issue was created to prevent).

### Consequences of that decision

1. **Real DHCP packet relay** to `UPSTREAM_DHCP_IP` via dnsmasq's
   `--dhcp-relay=` (relaying DISCOVER/OFFER/REQUEST/ACK to a DHCP server on a
   different subnet or VLAN), distinct from the current ProxyDHCP/PXE-supplemental
   mode, is now **confirmed in-scope**. It already has its own focused
   implementation issue, **#844** ("dhcp-proxy: add a real dnsmasq DHCP-relay
   mode alongside existing ProxyDHCP-only mode", v0.3.0) — this scoping decision
   confirms #844 is wanted, not speculative.
2. The stale intent claim in `dnsmasq.conf.template`'s comment should be
   corrected as part of that real-relay implementation work (which rewrites that
   directive area anyway), not silently left asserting the line was never meant
   to function. Until then, this document is the authoritative record that the
   intent characterization in that comment is known to be wrong.
3. The mockup already reflects this: its capability-comparison table lists a
   distinct **DHCP-Relay** column ("Relays requests to a DHCP server on a
   different subnet or VLAN") and marks the DHCP-Relay sub-tab as "a planned
   addition, not yet available to turn on." DHCP-Relay is a *third* mode
   alongside DHCP-Server (Kea) and DHCP-Proxy (dnsmasq ProxyDHCP), not a rename
   of either.

## 1. What dnsmasq relay/proxy settings are operator-configurable via the Admin UI

The `dnsmasq-proxy` mode is selected via the same DHCP mode switch as Kea
(`POST /dhcp/mode`, value `dnsmasq-proxy`). Its settings are edited via
`POST /dhcp/proxy` (`update_dhcp_proxy` in `services/ui/src/routes/dhcp.rs`) and
rendered into `dnsmasq.conf.template` by `services/dhcp-proxy/entrypoint.sh` via
`envsubst`.

**Configurable today (all validated server-side in `update_dhcp_proxy`):**

| Field | Env var | Validation |
|---|---|---|
| Proxy subnet | `DHCP_SUBNET_START` | must be a valid IPv4 |
| Primary DNS | `DHCP_DNS_PRIMARY` | must be a valid IPv4 |
| Secondary DNS (optional) | `DHCP_DNS_SECONDARY` | valid IPv4 if set |
| Upstream DHCP IP | `UPSTREAM_DHCP_IP` | must be a valid IPv4 — see the caveat below |
| Listen interface (optional, #450) | `DHCP_PROXY_INTERFACE` | valid interface name if set |
| Router/gateway option (optional, #450) | `DHCP_PROXY_ROUTER` | valid IPv4 if set |
| NTP servers (optional, #450) | `DHCP_NTP_SERVERS` | validated list; project-policy defaults (AG-OP-014) |
| Domain option (optional, #450) | `DHCP_PROXY_DOMAIN` | valid domain name if set |
| PXE boot filename (optional, #450) | `DHCP_PROXY_BOOT_FILENAME` | valid boot filename if set |
| PXE boot server (optional, #450) | `DHCP_PROXY_BOOT_SERVER` | valid IPv4 if set; **cross-field**: a boot server requires a boot filename |

**Caveat on `UPSTREAM_DHCP_IP` today:** it is collected and validated by the UI,
but in the *current* ProxyDHCP mode it does **not** drive real packet relay —
`dnsmasq.conf.template` never emits a `--dhcp-relay=` directive. It becomes
genuinely load-bearing only once the real-relay feature (§0) is implemented.
Documenting this here so the field is not misread as "already wired to relay"
nor as "dead input to delete."

## 2. Planned but unbuilt (v0.3.0 candidate)

- **Real DHCP packet relay (`--dhcp-relay=` to `UPSTREAM_DHCP_IP`)** — confirmed
  in-scope per §0; tracked in **#844**. This is the "DHCP-Relay" mode/tab in the
  mockup, currently shown as planned/not-yet-available.
- **Admin UI exposure of the DHCP-Relay mode** — the mode switch would gain a
  third value once relay is built; the mockup's DHCP-Relay sub-tab is the design
  reference.

## 3. Intentionally out of scope (not planned)

- Turning dnsmasq-proxy mode into a general dnsmasq admin panel (arbitrary
  `dnsmasq.conf` directives via the UI). The curated option set above (plus PXE
  and, later, relay) is the intended surface, not raw config editing.

## 4. Relationship to Kea full-DHCP mode — where the line is

Three mutually exclusive modes, selected by the single DHCP mode switch:

| Mode | Issues addresses? | Works alongside another DHCP server? | Relays to another subnet? | Backend |
|---|---|---|---|---|
| **DHCP-Server** (`kea`) | Yes | No (conflicts by design) | No | Kea — see [`kea-dhcp-admin-ui-scope.md`](kea-dhcp-admin-ui-scope.md) |
| **DHCP-Proxy** (`dnsmasq-proxy`) | No (supplemental PXE/options only) | Yes | No | dnsmasq ProxyDHCP |
| **DHCP-Relay** (planned) | No (forwards to a remote server) | Yes | Yes | dnsmasq `--dhcp-relay=` (§0) |

This three-way split is documented clearly enough for a non-technical operator
only once the mockup's comparison table (which uses plain-language capability
rows rather than "Kea"/"dnsmasq" jargon) is actually built into the UI — #1068's
field test flagged the current UI's raw "KEA"/"dnsmasq-proxy" terminology as
confusing for the target audience. Presenting these three modes in operator
language (not backend names) is part of the intended scope, tracked alongside the
broader DHCP Admin UI rework.

## 5. Summary table

| Area | State | Where |
|---|---|---|
| dnsmasq-proxy mode select | Admin UI, implemented | `dhcp.rs::update_dhcp_mode` (`dnsmasq-proxy`) |
| Proxy subnet / DNS / interface / router / NTP / domain settings | Admin UI, implemented | `dhcp.rs::update_dhcp_proxy`, #450 |
| PXE boot filename/server (proxy) | Admin UI, implemented | `dhcp.rs::update_dhcp_proxy`, #450 |
| `UPSTREAM_DHCP_IP` drives real relay | Not built (collected but inert today) | Planned — real relay issue (§0) |
| Real DHCP packet relay (`--dhcp-relay=`) | Not built (intended, unfinished — maintainer-confirmed) | Planned, own issue |
| DHCP-Relay mode/tab in UI | Not built | Planned (mockup reference) |
| Plain-language mode presentation (vs. "KEA"/"dnsmasq" jargon) | Not built | Planned, #1068 |
| General dnsmasq config editor | Not planned | Deliberately out of scope |

## How to use this document

If you are about to remove, "clean up," or flag as dead any dnsmasq-proxy or
`UPSTREAM_DHCP_IP`/`dhcp-relay`-adjacent code that looks incomplete, check this
document first. The `--dhcp-relay=` capability specifically is
**maintainer-confirmed intended-but-unfinished work**, not dead code — do not
remove `UPSTREAM_DHCP_IP` plumbing or re-assert in any comment that relay "was
never meant to function." If a gap you found is not listed here, that's this
document's own gap: update it rather than guessing.

## Follow-up

- Real DHCP packet relay (`--dhcp-relay=`) implementation is tracked in **#844**.
  This scoping document does not implement it; it records that it is in-scope and
  why, and that the stale intent claim in `dnsmasq.conf.template`'s comment
  should be corrected as part of that work.
