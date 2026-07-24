# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Capability inventory for services/dhcp-proxy (dnsmasq ProxyDHCP/PXE relay).
# Working notes for the project-wide capability audit tracked in issue #843.
# Examined against `origin/v0.2.0` (branch base commit 3f53ac3 at time of writing).

# services/dhcp-proxy capability inventory

Scope examined (all against `origin/v0.2.0`):

- `services/dhcp-proxy/Dockerfile`, `.dockerignore`
- `services/dhcp-proxy/dnsmasq.conf.template`
- `services/dhcp-proxy/entrypoint.sh` (675 lines)
- `config/prod/dhcp-proxy.env`
- `deploy/prod/docker-compose.yml` (dhcp-proxy service block + cross-references in `ui`/`dhcp` services)
- `scripts/dhcp-proxy-pxe-simulation.sh` (389 lines)
- `tests/bats/dhcp_proxy_known_good_snapshot.bats`, `tests/bats/dhcp_proxy_optional_directives.bats` + their helpers
- `docs/dhcp-modes.md`
- `services/ui/src/routes/dhcp.rs`, `services/ui/src/templates/dhcp.html` (Admin UI cross-reference)
- `.github/workflows/full-setup-validate.yml`, `.github/workflows/full-setup-deep-validate.yml`
- GitHub issues/PRs: #450, #705, #765, #647, #840, #716, #415, #633, #820, #557 (via `gh issue/pr view`)

## 1. What this service is

`services/dhcp-proxy` is a dnsmasq-based **ProxyDHCP** helper (RFC 4388), not a
DHCP relay in the RFC 1542/BOOTP-relay sense despite "relay" appearing in its
own comments and `docs/dhcp-modes.md`'s mode name. It runs alongside an
existing DHCP server that keeps owning real leases; dnsmasq only answers the
supplemental PXE/ProxyDHCP exchange. It is one of four DHCP modes
(`disabled` / `kea` / `dnsmasq-proxy` / `dnsmasq-relay`), mutually exclusive
with `services/dhcp` (Kea) — both bind UDP/67. **Update (#844):** this same
`dhcp-proxy` container also serves the new `dnsmasq-relay` mode (a real DHCP
relay to `UPSTREAM_DHCP_IP`, giaddr = `DHCP_RELAY_LOCAL_ADDR`); the entrypoint
reads `DHCP_MODE` and renders `dnsmasq-relay.conf.template` instead of the
ProxyDHCP `dnsmasq.conf.template`. In relay mode `UPSTREAM_DHCP_IP` stops being
documentation-only (see the caveat below) and becomes the real forwarding
target.

**Naming caveat (own finding, not previously flagged anywhere in code/docs):**
`UPSTREAM_DHCP_IP` is **documentation-only** — confirmed by entrypoint.sh's
own comment and `docs/dhcp-modes.md`'s explicit note. A prior revision fed it
into dnsmasq's `dhcp-proxy=<ip>` directive, which per `dnsmasq --help` is an
RFC 5107 serverid-override that only does anything paired with
`--dhcp-relay=` — never configured here. It was a no-op and was removed in
commit `e86bced` (PR closing #450). No actual DHCP packet relay to
`UPSTREAM_DHCP_IP` occurs; the variable exists purely so the operator and the
Admin UI's DHCP-conflict-probe agree on which server is expected to answer.

## 2. Capability matrix

| Capability | Config source | Rendered as | Tested by | Status |
|---|---|---|---|---|
| DNS server injection (PXE option 6) | `DHCP_DNS_PRIMARY`, `DHCP_DNS_SECONDARY` (required; secondary defaults to primary) | `dhcp-option-pxe=6,...` in `dnsmasq.conf.template` | `dhcp-proxy-pxe-simulation.sh` (asserts `dns_servers` field) | Working, but **inert without a `pxe-service` directive** (see §3) |
| ProxyDHCP subnet scope | `DHCP_SUBNET_START` (required) | `dhcp-range=${DHCP_SUBNET_START},proxy` | Implicitly via all PXE-sim scenarios (container must start and log "DHCP, proxy on subnet") | Working |
| Interface bind | `DHCP_PROXY_INTERFACE` (optional, issue #450) | `interface=<if>` | `dhcp_proxy_optional_directives.bats` | Unit-tested |
| Router option (opt 3) | `DHCP_PROXY_ROUTER` (optional, #450) | `dhcp-option-pxe=3,<ip>` | `dhcp_proxy_optional_directives.bats` | Unit-tested, PXE-scoped only (never reaches ordinary DHCP clients) |
| NTP servers (opt 42) | `DHCP_NTP_SERVERS` (optional, #450) | `dhcp-option-pxe=42,<csv>` | `dhcp_proxy_optional_directives.bats` | Unit-tested, PXE-scoped only |
| Domain name (opt 15) | `DHCP_PROXY_DOMAIN` (optional, #450) | `dhcp-option-pxe=15,<domain>` | `dhcp_proxy_optional_directives.bats` | Unit-tested, PXE-scoped only |
| Boot filename/server (`dhcp-boot`) | `DHCP_PROXY_BOOT_FILENAME` + `DHCP_PROXY_BOOT_SERVER` (optional, #450) | `dhcp-boot=<file>,,<server>` | `dhcp_proxy_optional_directives.bats` (incl. the "server without filename → warns, not rendered" case) | Unit-tested |
| Custom safe options | `DHCP_PROXY_CUSTOM_OPTIONS` (`CODE:VALUE;CODE:VALUE`, optional, #450) | one `dhcp-option-pxe=<code>,<value>` line per entry | `dhcp_proxy_optional_directives.bats` (malformed entry, out-of-range code, non-numeric code, whitespace-trim-but-not-collapse cases all covered) | Unit-tested, thorough |
| **PXE boot-pointer (BIOS)** | `DHCP_PROXY_PXE_BOOT_SERVER` + `DHCP_PROXY_PXE_BOOT_FILENAME_BIOS` (optional, opt-in, issue #705/PR #765) | `pxe-service=x86PC,...` + `dhcp-match=...client-arch,0` + `dhcp-boot=tag:...` | `dhcp-proxy-pxe-simulation.sh` only (real packet capture against arch 0) | **No bats/unit coverage at all** — see §3 |
| **PXE boot-pointer (UEFI x86-64 / ARM64)** | `DHCP_PROXY_PXE_BOOT_SERVER` + `DHCP_PROXY_PXE_BOOT_FILENAME_UEFI` (#705/PR #765) | `dhcp-match` for arch 7 and 11 (shared tag) + `dhcp-boot=tag:...` (no `pxe-service` — confirmed inert for non-x86PC) | `dhcp-proxy-pxe-simulation.sh` only (arch 7 and 11 probes) | **No bats/unit coverage at all** — see §3 |
| Inert `pxe-service=IA64_EFI,...,0` placeholder | rendered automatically when BIOS is NOT configured but UEFI is, purely to satisfy "at least one pxe-service must exist" | `pxe-service=IA64_EFI,"lancache-ng PXE proxy active",0` | Not exercised by the PXE-sim script directly (script always configures both BIOS+UEFI) — a UEFI-only configuration path is **untested end-to-end** | Gap (see §5) |
| Known-good config snapshot + rollback | `KEEP_KNOWN_GOOD_CONFIGS` (default 3), `DHCP_PROXY_CONFIG_SNAPSHOT_DIR` | `dnsmasq --test` gate, then `kgs_snapshot_create`/`kgs_snapshot_apply` (shared library, byte-copy of `scripts/lib/known-good-snapshots.sh`, issue #415) | `dhcp_proxy_known_good_snapshot.bats` (valid path, rollback path, no-snapshot-available refusal, retention pruning) | Unit-tested, thorough |
| Central logging (`log-facility`) | fixed path `/var/log/lancache-dhcp-proxy/dnsmasq.log` (issue #633) | `log-facility=...` in template | **No automated test** confirms fluent-bit/syslog actually picks this file up | Gap (manual-verification-only, consistent with rest of #633's scope) |
| Docker wiring: `network_mode: host` | compose | required for a real broadcast DHCP/PXE listener on 67/udp | Implicit (PXE-sim builds/runs the real image, but on an isolated bridge network + explicit `--ip`, not host networking — see caveat below) | dev/prod compose config only, `docker compose config` validated |
| `cap_add: NET_BIND_SERVICE, NET_ADMIN` | compose | dnsmasq passes `--test` without `NET_ADMIN` but then fails to actually bind ("process is missing required capability NET_ADMIN") — confirmed live per PR #765/#450 commit message | Covered implicitly by PXE-sim (container must reach "ready" state) | Working |
| `ui-data:/data:ro` mount + `/data/lancache-ui-settings.env` sourcing | compose + entrypoint.sh `if [ -f ... ]; then . ...; fi` | Lets the Admin UI's persisted settings override the `env_file` defaults | **No test exercises this sourcing path directly** (bats tests source only the extracted functions, never run the full entrypoint against a real settings file) | Gap |

## 3. The root-cause bug this service already had (issue #705, fixed by PR #765)

Confirmed by real packet capture (documented at length in `entrypoint.sh`'s
own header comments, and repeated in `docs/dhcp-modes.md`): dnsmasq's
ProxyDHCP mode **does not reply to any DHCPDISCOVER at all** — PXE-tagged or
not — unless at least one `pxe-service` directive exists in its config. Before
#705/PR #765, nothing in this codebase ever rendered one, so **every single
option covered by issue #450** (DNS injection included) had been silently
inert since #450 shipped: accepted by `dnsmasq --test`, never once delivered
to a real client. This is why `_dhcp_proxy_render_pxe_service_directives` is
the single most important function in `entrypoint.sh` and is exercised by
`scripts/dhcp-proxy-pxe-simulation.sh` — but that script is the *only* thing
that exercises it (see §5).

## 4. Docker Compose wiring (dev + prod, structurally identical)

- Activated only via `docker compose --profile dhcp-proxy up` — **not** by
  the `DHCP_MODE` environment variable. `DHCP_MODE=${DHCP_MODE:-disabled}` is
  wired into the `dhcp` (Kea) service's environment and the `ui` (Admin UI)
  service's environment, but **the `dhcp-proxy` service itself receives no
  `DHCP_MODE` variable at all** — its activation is entirely governed by
  which Compose profile `setup.sh`/the Admin UI enables, while `DHCP_MODE` is
  read only by Kea and the UI (presumably for API wiring/display purposes).
  This split is consistent with `docs/dhcp-modes.md`'s statement that
  "`setup.sh` writes exactly one runtime Compose profile ... never both" —
  the profile is the actual switch, `DHCP_MODE` is a parallel descriptive
  value consumed by other services. Not a bug, but worth naming explicitly
  since a reader could otherwise assume `DHCP_MODE=dnsmasq-proxy` itself
  starts the container.
- `restart: unless-stopped` (dev) vs. `restart: always` (prod), matching the
  project-wide dev/prod split.
- prod adds `logging: {driver: json-file, max-size: 5m, max-file: 2}`; dev
  does not override the Docker default logging driver.
- Both mount `ui-data:/data:ro`, `dhcp-proxy-config-snapshots:/var/lib/lancache-dhcp-proxy`,
  `dhcp-proxy-logs:/var/log/lancache-dhcp-proxy`, matching the known-good-snapshot
  and central-logging conventions used across the other services.

## 5. Test coverage gaps (concrete, verified)

1. **`_dhcp_proxy_render_pxe_service_directives` has zero bats/unit
   coverage.** `tests/bats/helpers/dhcp-proxy-optional-directives-helpers.sh`
   extracts only `_dhcp_proxy_render_optional_directives` and
   `_dhcp_proxy_render_custom_options` via `awk` — confirmed by reading the
   helper directly. `git grep -n "_dhcp_proxy_render_pxe_service_directives"
   -- tests/` returns nothing. The *only* thing that exercises this
   function's actual output is `scripts/dhcp-proxy-pxe-simulation.sh`, a full
   Docker-container-and-scapy integration test.

2. **That integration test is `workflow_dispatch`-only, not part of the
   automatic PR gate.** Confirmed directly: `full-setup-validate.yml`'s `on:`
   block is `workflow_dispatch` only (no `pull_request`/`schedule` trigger).
   `full-setup-deep-validate.yml` — the workflow explicitly designed to run
   "automatically on every relevant PR" (#715) and is a superset gate for
   Kea, setup-cli-simulation, SSL/HTTP caching, etc. — contains an explicit
   code comment at the `dhcp-kea-lease-flow-simulation` job: *"dhcp-proxy
   still has no deep job (tracked in #705) and so is still uncovered here."*
   **#705 is closed** (it scoped and delivered exactly the manual-dispatch
   script, before `full-setup-deep-validate.yml`/#715 existed) — so that
   comment's "tracked in #705" pointer is stale relative to current reality;
   there is currently **no open issue** that tracks promoting
   `dhcp-proxy-pxe-simulation.sh` into the automatic deep-validate gate. The
   closest existing open issue is **#716** ("governance: no rule requires a
   new service to be added to full-stack CI validation"), which already uses
   `services/dhcp`+`services/dhcp-proxy`'s original 2026-06-22 omission from
   `full-setup-validate.yml` as its own motivating evidence — but #716 is a
   governance-rule issue, not a promotion-to-deep-validate tracking issue for
   this specific script. **Net effect: a regression in
   `_dhcp_proxy_render_pxe_service_directives` (the function responsible for
   the #705 root-cause fix) would not be caught automatically on any PR** —
   only by someone remembering to manually run "Full-Setup Validate".

3. **A UEFI-only PXE configuration (`DHCP_PROXY_PXE_BOOT_SERVER` +
   `DHCP_PROXY_PXE_BOOT_FILENAME_UEFI` only, no BIOS filename) is never
   exercised end to end.** `dhcp-proxy-pxe-simulation.sh` always sets both
   `bios_boot_filename` and `uefi_boot_filename` in the same run,  so the
   code path that renders the inert `pxe-service=IA64_EFI,...,0` placeholder
   (the `have_bios -eq 0` branch in `entrypoint.sh`) has real packet-level
   behavior asserted nowhere — only reasoned about in comments.

4. **The known-good-snapshot rollback tests use a stub `dnsmasq` binary**,
   not the real one — legitimate for unit-level adapter testing (matches the
   project's own stated intent in the test file's header), but means no
   automated test proves a *real* `dnsmasq --test` accepts/rejects the same
   inputs the stub is told to. This is a known, accepted pattern shared with
   other known-good-snapshot adapters in this project, not unique to
   dhcp-proxy.

5. **The `/data/lancache-ui-settings.env` sourcing path (Admin UI → dhcp-proxy
   config handoff) has no test.** Neither bats test runs the full
   entrypoint.sh top-level script; both only source extracted function
   bodies. No fixture exercises "Admin UI writes settings, dhcp-proxy
   container picks them up on next restart."

## 6. Admin UI cross-reference — verified gap

Checked `services/ui/src/routes/dhcp.rs`'s dnsmasq-proxy read/write key lists
(three separate fixed key-list occurrences plus the form-submission handler)
and `services/ui/src/templates/dhcp.html` directly:

**Exposed and read/write via the Admin UI:** `DHCP_SUBNET_START`,
`DHCP_DNS_PRIMARY`, `DHCP_DNS_SECONDARY`, `UPSTREAM_DHCP_IP`,
`DHCP_PROXY_INTERFACE`, `DHCP_PROXY_ROUTER`, `DHCP_NTP_SERVERS`,
`DHCP_PROXY_DOMAIN`, `DHCP_PROXY_BOOT_FILENAME`, `DHCP_PROXY_BOOT_SERVER`,
`DHCP_PROXY_CUSTOM_OPTIONS` — i.e. every issue #450 variable.

**NOT present anywhere in `dhcp.rs` or `dhcp.html`:** `DHCP_PROXY_PXE_BOOT_SERVER`,
`DHCP_PROXY_PXE_BOOT_FILENAME_BIOS`, `DHCP_PROXY_PXE_BOOT_FILENAME_UEFI` —
confirmed by direct grep against both files, zero matches. These are exactly
the three variables PR #765/#705 added to `entrypoint.sh`, the env templates,
and `docs/dhcp-modes.md`. PR #765's own body (checked via `gh pr view 765`)
lists its changed files explicitly (`entrypoint.sh`,
`tools/build-tools/Dockerfile`, `full-setup-validate.yml`,
`docs/dhcp-modes.md`, `CHANGELOG.md`) and does **not** mention
`services/ui` at all — i.e. this was a silent omission from that PR's own
stated scope, not a documented "Scope Boundaries" exclusion.

Per this project's own governance ("Feature Completeness": *"If backend code
supports a feature but the Admin UI does not expose it, treat that as UI
delivery debt by default"*), this is a real, currently-untracked gap: an
operator can only configure PXE boot-pointer support by hand-editing
`config/{dev,prod}/dhcp-proxy.env` or the persisted settings file — the
Admin UI's DHCP page has no fields for it, and (per §5) no automated check
would catch the Admin UI silently failing to persist these three keys.

**Only partially tracked:** issue **#647** ("spec: define full dnsmasq
relay/proxy DHCP Admin UI feature scope", open) is the closest existing
issue, but it **predates** #705/PR #765 (it discusses the #450 option surface
and the `dhcp-proxy=`/`--dhcp-relay=` question, not the later PXE
boot-pointer variables) — it does not enumerate this specific gap. #647's own
"reverted pending discussion" framing of the `dhcp-proxy=`/relay question
also appears settled by now at the code+docs level (current
`dnsmasq.conf.template` has no such directive, and `docs/dhcp-modes.md`
documents the removal as confirmed-via-live-testing) — noted here as an
observation for the maintainer to confirm/close that sub-question, not
resolved unilaterally in this audit.

## 7. Cross-referenced issue/PR status (verified via `gh issue/pr view`, not assumed)

| # | Title | State | Relevance |
|---|---|---|---|
| #450 | v0.2.0 make dnsmasq relay/proxy DHCP options configurable | CLOSED | Delivered the interface/router/NTP/domain/boot/custom-options surface |
| #705 | test: DHCP dnsmasq-proxy PXE (option-60/option-6) simulation | CLOSED | Root-cause "no pxe-service → no reply at all" bug + PXE boot-pointer feature + simulation script |
| #765 (PR) | fix(dhcp-proxy): opt-in PXE boot-pointer support + real PXE simulation | MERGED | Implements #705; did not touch `services/ui` (see §6) |
| #415 | Add known-good configuration snapshots for runtime-managed services | CLOSED | Snapshot/rollback library shared with other services |
| #633 | Follow-up: full logging matrix, Admin UI integration, retention budget engine | CLOSED | Central logging pipeline (`log-facility`) |
| #820 | ci: full-setup-deep-validate stack jobs collide on validation subnet | CLOSED | Subnet-reservation locking reused by `dhcp-proxy-pxe-simulation.sh` |
| #557 | v0.2.0: build a real multi-service e2e client-simulation test | CLOSED | Parent scoping issue; #705 is its dnsmasq-proxy child scenario |
| #647 | spec: define full dnsmasq relay/proxy DHCP Admin UI feature scope | **OPEN** | Predates PXE boot-pointer vars; does not cover the §6 gap |
| #840 | DHCP (Kea + dnsmasq-proxy): umbrella for scattered feature/bug/research work | **OPEN** | References #646/#647/#770/#815; does not reference the deep-validate coverage gap (§5.2) or the UI PXE-vars gap (§6) |
| #716 | governance: no rule requires a new service to be added to full-stack CI validation | **OPEN** | General governance gap; cites dhcp-proxy's original 2026-06-22 omission as evidence, but is not itself the tracking issue for promoting the PXE simulation into the automatic gate |
| #815 | Evaluate migrating DNS/DHCP services to Alpine base images | **OPEN** | Would affect `services/dhcp-proxy/Dockerfile`'s `mirror.gcr.io/library/debian:trixie-slim` base + `dnsmasq`/`gettext` packages |

## 8. Recommended follow-ups (not filed — for maintainer decision)

- File an issue to promote `dhcp-proxy-pxe-simulation.sh` into
  `full-setup-deep-validate.yml`'s automatic PR gate (§5.2) — currently
  no open issue tracks this specifically.
- File an issue (or fold into #647) to add Admin UI fields for
  `DHCP_PROXY_PXE_BOOT_SERVER`/`_FILENAME_BIOS`/`_FILENAME_UEFI` (§6) —
  currently untracked, backend-complete/UI-incomplete gap per this
  project's own "Feature Completeness" governance rule.
- Consider a bats-level unit test for
  `_dhcp_proxy_render_pxe_service_directives` (mirroring the pattern already
  used for the other two rendering functions) so a regression there is
  caught by fast, always-run tests rather than only the manual-dispatch
  Docker simulation.
