# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Bug-hunt raw findings for services/dhcp-proxy (dnsmasq ProxyDHCP/PXE relay).
# Unscoped, exhaustive sweep for issue #849 (sub-issue of #843), examined
# against `origin/v0.2.0` (base commit 3f53ac3 at time of writing).
# Methodology: vacuum-first, no pre-filtering, no self-verification during
# collection (per maintainer-agreed workflow for #849). Verification happens
# in a later, separate phase.

# services/dhcp-proxy bug-hunt raw findings

Scope examined (full read or targeted grep-and-read, all against `origin/v0.2.0`):

- `services/dhcp-proxy/entrypoint.sh` (full read, 675 lines)
- `services/dhcp-proxy/Dockerfile`, `.dockerignore`, `dnsmasq.conf.template` (full read)
- `config/dev/dhcp-proxy.env`, `config/prod/dhcp-proxy.env`, `deploy/quickstart/.env` (dhcp-proxy keys)
- `deploy/dev/docker-compose.yml`, `deploy/prod/docker-compose.yml`, `deploy/quickstart/docker-compose.yml` (dhcp-proxy service blocks + healthcheck comparison across the whole file)
- `scripts/dhcp-proxy-pxe-simulation.sh` (full read, 389 lines) + `scripts/lib/pxe-client-probe.py` (full read)
- `tests/bats/dhcp_proxy_known_good_snapshot.bats`, `tests/bats/dhcp_proxy_optional_directives.bats`, `tests/bats/known_good_snapshots_sync.bats` + their helpers (full read)
- `docs/dhcp-modes.md` (full read, 379 lines)
- `services/ui/src/routes/dhcp.rs`, `services/ui/src/templates/dhcp.html` (targeted grep + read of every dnsmasq-proxy/PXE-related section)
- `setup.sh` (targeted grep for DHCP_PROXY*/dnsmasq-proxy handling)
- `.github/workflows/full-setup-validate.yml`, `.github/workflows/full-setup-deep-validate.yml`, `.github/workflows/build-push.yml` (dhcp-proxy job/guard wiring)
- `release/stack-images.yml`, `scripts/validate-stack-images.sh`
- `CHANGELOG.md` (dhcp-proxy/#450/#705 entries)
- `tools/build-tools/Dockerfile` (python3-scapy/tcpdump packages)

Prior art consulted (not treated as a boundary): `docs/capability-inventory/SoT-dhcp-proxy.md` on branch
`docs/inventory-dhcp-proxy`, and the original audit comment on issue #843. Findings below that
independently reconfirm a SoT point are marked as such; several go further than the SoT did
(new evidence, new mechanisms, or new files the SoT didn't examine).

---

## 1. Doc/code mismatch: managed-DHCP-option-code collision protection for
   `DHCP_PROXY_CUSTOM_OPTIONS` exists only in the Admin UI, not in the container

`docs/dhcp-modes.md` line 190 states, for `DHCP_PROXY_CUSTOM_OPTIONS`:

> Codes already covered by the dedicated fields above (3, 6, 15, 42) are
> rejected here to avoid two conflicting ways to set the same option.

But `services/dhcp-proxy/entrypoint.sh`'s `_dhcp_proxy_render_custom_options` (lines 465-509)
has **no such check** — it only validates: non-empty code/value, numeric code, and
range 1-254. It never checks whether the code collides with 3 (router), 6 (DNS), 15
(domain), or 42 (NTP).

The claim IS true, but only for the Admin UI's `parse_custom_options_form`/
`parse_custom_dhcp_option_code` (`services/ui/src/routes/dhcp.rs` lines 1147-1175,
2813-2846), which explicitly rejects codes `3|6|15|42|119` (confirmed by the
dedicated test `custom_options_form_rejects_managed_codes_and_malformed_lines`,
dhcp.rs line ~5111, asserting `parse_custom_options_form("3:10.0.0.1").is_err()`).

**Concrete failure scenario:** an operator hand-edits `config/prod/dhcp-proxy.env`
(a fully documented, supported configuration surface per this project's own
CLAUDE.md/docs) and sets both:
```
DHCP_PROXY_ROUTER=10.0.0.1
DHCP_PROXY_CUSTOM_OPTIONS=3:10.0.0.99
```
`entrypoint.sh` renders **both** `dhcp-option-pxe=3,10.0.0.1` (from the dedicated
field) and `dhcp-option-pxe=3,10.0.0.99` (from the unchecked custom-options path)
into the same `dnsmasq.conf`, with no warning — exactly the "two conflicting ways
to set the same option" the documentation claims cannot happen. `dnsmasq --test`
would accept this file (both lines are individually valid syntax), so the
existing validate-then-rollback gate does not catch it either.

Severity: moderate (documented safety guarantee silently doesn't hold outside the
Admin UI path; requires direct env-file editing, which is a supported, documented
workflow, not an edge case).

---

## 2. Feature-completeness gap: PXE boot-pointer vars are unreachable through
   `setup.sh` or the Admin UI (3 layers, not just the Admin UI as SoT flagged)

The SoT doc (§6) already flagged that `services/ui/src/routes/dhcp.rs` and
`dhcp.html` never expose `DHCP_PROXY_PXE_BOOT_SERVER` /
`DHCP_PROXY_PXE_BOOT_FILENAME_BIOS` / `DHCP_PROXY_PXE_BOOT_FILENAME_UEFI`. This
sweep independently reconfirmed that (zero matches for `PXE_BOOT` anywhere
under `services/ui`) and found the gap is **wider**:

1. **`setup.sh` has zero references to these three variables anywhere** —
   confirmed via `grep -n "PXE_BOOT\|DHCP_PROXY_PXE" setup.sh` (no output).
   Compare with every other issue #450 optional var, each of which gets:
   - an interactive `ask` prompt in the `dnsmasq-proxy` configuration block
     (setup.sh ~line 5510+),
   - an `append_env_key_if_missing` backfill call during `setup.sh update`
     (setup.sh ~line 2498-2504) so existing installations get the new key
     added on upgrade,
   - inline validation (setup.sh ~line 2529-2545).

   None of that exists for the three PXE vars. An installation that ran
   `setup.sh update` after upgrading past PR #765 gets **no** migration path
   to even discover these variables exist.

2. **The Admin UI form struct (`UpdateDhcpProxyForm`, dhcp.rs lines 377-402)
   has no fields for them** (SoT already found this).

3. **`write_ui_settings_file`'s fixed key whitelist (dhcp.rs ~line 724-747)
   never had these three keys added.** The function's own comment reads:
   > "this key list is the authoritative whitelist of what this file can
   > ever contain, so a future field must be added here too or
   > persist_ui_settings will silently drop it even if the caller passes it
   > in `values`."

   Because `UpdateDhcpProxyForm` never collects these values in the first
   place, this specific silent-drop mechanism doesn't currently corrupt an
   operator's hand-set env-file values on a save (sourcing a settings file
   that never mentions a key does not unset an already-exported env var) —
   but it is exactly the trap the comment warns about, and it means any
   future attempt to wire these fields through the *existing*
   `update_dhcp_proxy` route without also touching this whitelist would
   silently do nothing.

`docs/dhcp-modes.md`'s "Configuring dnsmasq-proxy mode" section opens with:
> "`setup.sh` prompts for these values when you pick `dnsmasq-proxy`,
> validates them, and writes them to `.env`. They can also be edited later
> from the Admin UI DHCP page."

— stated once, before all three subsections (Required / Optional / PXE
boot-pointer), so it reads as a blanket claim covering the PXE boot-pointer
section too. In reality, for the three PXE vars, **neither** half of that
sentence is true: setup.sh never prompts for them, and the Admin UI page
cannot edit them. The *only* way to configure PXE support is direct,
undocumented-as-such hand-editing of `config/{dev,prod}/dhcp-proxy.env` (or
`deploy/quickstart/.env`).

Per this project's own governance ("Feature Completeness": *"If backend code
supports a feature but the Admin UI does not expose it, treat that as UI
delivery debt by default"*), and given `setup.sh`'s equally complete silence,
this is real, currently-undertracked debt spanning setup.sh + Admin UI, not
just the Admin UI alone.

Severity: moderate.

---

## 3. Newline-injection asymmetry in `entrypoint.sh`'s optional-directive rendering

`_dhcp_proxy_render_pxe_service_directives` (added in PR #765, entrypoint.sh
lines 544-549) explicitly checks the concatenation of
`DHCP_PROXY_PXE_BOOT_SERVER`/`_FILENAME_BIOS`/`_FILENAME_UEFI` for an embedded
newline before rendering anything, specifically to prevent corrupting/injecting
into the rendered config file.

`_dhcp_proxy_render_optional_directives` (the older, #450 function, lines
411-451) has **no equivalent check** for `DHCP_PROXY_INTERFACE`,
`DHCP_PROXY_ROUTER`, `DHCP_NTP_SERVERS`, `DHCP_PROXY_DOMAIN`,
`DHCP_PROXY_BOOT_FILENAME`, or `DHCP_PROXY_BOOT_SERVER` — each is `printf`'d
unquoted straight into `dnsmasq.conf` via e.g.
`printf 'dhcp-option-pxe=3,%s\n' "$DHCP_PROXY_ROUTER" >> "$dest_conf"`. A value
containing an embedded newline would inject an arbitrary extra line (i.e. an
arbitrary extra dnsmasq directive) into the generated config.

Also: `dnsmasq.conf.template`'s own required vars (`DHCP_SUBNET_START`,
`DHCP_DNS_PRIMARY`, `DHCP_DNS_SECONDARY`) are substituted via `envsubst` with
no newline check anywhere in the pipeline either.

The Admin UI's own validators (`is_valid_interface_name`, `parse_ipv4`,
`is_valid_domain_name`, `is_valid_boot_filename`) do reject anything containing
control characters/newlines when a value is set **through the UI form**, so
this is not exploitable through the normal Admin UI flow. But any operator
setting these directly in `config/{dev,prod}/dhcp-proxy.env` or
`deploy/quickstart/.env` (documented, supported paths) has no such protection
at the container level — inconsistent with the newline defense that was
specifically added for the newer PXE vars in the same file.

Severity: minor/moderate (real gap, but requires an operator or tooling to
embed a raw newline into an env-file value, an unusual but not impossible
input path — e.g. a scripted/generated `.env`).

---

## 4. Governance guard in `build-push.yml` covers `_dhcp_proxy_render_optional_directives`
   but has no equivalent for `_dhcp_proxy_render_pxe_service_directives`

`.github/workflows/build-push.yml` (lines 993-996) contains an explicit
regression guard:
```
grep -F '_dhcp_proxy_render_optional_directives()' services/dhcp-proxy/entrypoint.sh >/dev/null || ...
grep -F '_dhcp_proxy_render_optional_directives /etc/dnsmasq.conf' services/dhcp-proxy/entrypoint.sh >/dev/null || ...
```
There is **no equivalent guard** for `_dhcp_proxy_render_pxe_service_directives`
— the function entrypoint.sh's own comment calls *"the single most important
function in this file"* (it's what makes dnsmasq's ProxyDHCP mode reply to any
DHCPDISCOVER at all; see finding context in §5/§6 below and the SoT's §3). A
future refactor that accidentally removes or forgets to call this function
would not be caught by this guard, by any bats test (see §5), or by anything
except the `workflow_dispatch`-only PXE simulation job.

(There IS a separate, good guard a few lines earlier in the same file — lines
977-990 — that verifies the three PXE env keys are defined in
`config/{dev,prod}/dhcp-proxy.env` and `deploy/quickstart/.env` and are passed
through in `deploy/quickstart/docker-compose.yml`'s `environment:` block. That
guard is solid and does not have the gap described here; it just doesn't cover
the *rendering function itself* the way the older #450 guard does.)

Severity: minor (defense-in-depth gap, not a live bug).

---

## 5. `_dhcp_proxy_render_pxe_service_directives` has zero bats/unit coverage
   (independently reconfirmed from SoT §5.1)

`tests/bats/helpers/dhcp-proxy-optional-directives-helpers.sh` extracts only
`_dhcp_proxy_render_optional_directives` and `_dhcp_proxy_render_custom_options`
via a targeted `awk` block matching those two function names specifically —
confirmed by reading the helper directly. Grepping `tests/` for
`_dhcp_proxy_render_pxe_service_directives` returns nothing. The only thing
that exercises this function's actual rendered output is
`scripts/dhcp-proxy-pxe-simulation.sh`, a full Docker-container-and-scapy
integration test that only runs on `workflow_dispatch` (see §6).

Severity: info (test-coverage gap, reconfirms SoT).

---

## 6. Stale issue-tracking comment in `full-setup-deep-validate.yml`
   (independently reconfirmed from SoT §5.2)

Line 775-776:
```
# the automatic gate (it was absent from the shallow check). dhcp-proxy
# still has no deep job (tracked in #705) and so is still uncovered here.
```
Issue **#705 is CLOSED** (it delivered exactly the manual-dispatch PXE
simulation script that already exists, not a promotion of that script into
the automatic PR gate). There is currently no open issue that specifically
tracks promoting `dhcp-proxy-pxe-simulation.sh` into
`full-setup-deep-validate.yml`'s automatic gate; the closest is #716 (a
general "no rule requires a new service to be added to CI validation"
governance issue), which is not itself that tracking issue. This comment's
"tracked in #705" pointer is therefore stale and, per this project's own
Comment Style governance rule, misleading to a future reader who follows it
expecting to find where the promotion work is tracked.

Net effect (unchanged from SoT): a regression in
`_dhcp_proxy_render_pxe_service_directives` would not be caught automatically
on any PR — only by someone remembering to manually dispatch "Full-Setup
Validate".

Severity: info.

---

## 7. Untested doc claim: `DHCP_PROXY_BOOT_SERVER` "defaults to dnsmasq's own
   address if left empty while a filename is set"

`docs/dhcp-modes.md` line 189 states, for `DHCP_PROXY_BOOT_SERVER`:
> "Requires `DHCP_PROXY_BOOT_FILENAME`; defaults to dnsmasq's own address if
> left empty while a filename is set."

But `entrypoint.sh`'s `_dhcp_proxy_render_optional_directives` (line 443)
always renders:
```
printf 'dhcp-boot=%s,,%s\n' "$DHCP_PROXY_BOOT_FILENAME" "$DHCP_PROXY_BOOT_SERVER" >> "$dest_conf"
```
When `DHCP_PROXY_BOOT_SERVER` is empty but `DHCP_PROXY_BOOT_FILENAME` is set,
this renders a **literal trailing empty field**: `dhcp-boot=somefile,,` (note
the trailing comma with nothing after it) rather than omitting the third
field entirely (`dhcp-boot=somefile,,` vs. what an entirely-omitted field
would look like, `dhcp-boot=somefile,`, or `dhcp-boot=somefile` with no
comma at all). Whether dnsmasq treats an explicit-but-empty trailing
comma-field identically to an omitted one (and truly defaults to its own
address in that exact rendering, as the docs assert) is not verified
anywhere in this codebase:

- `tests/bats/dhcp_proxy_optional_directives.bats` only tests "both filename
  and server set" and "server set without filename" — never "filename set,
  server left empty".
- `scripts/dhcp-proxy-pxe-simulation.sh` never exercises the #450
  `DHCP_PROXY_BOOT_FILENAME`/`DHCP_PROXY_BOOT_SERVER` pair at all (it only
  configures the separate #705 PXE vars).

So this specific documented behavior rests entirely on an unverified
assumption about dnsmasq's own parsing of a rendered-but-empty trailing
field.

Severity: info (needs live `dnsmasq --test`/packet-level verification to
confirm either way; flagging as unverified, not asserting it's wrong).

---

## 8. UEFI-only PXE configuration path never exercised end-to-end
   (independently reconfirmed from SoT §5.3)

`scripts/dhcp-proxy-pxe-simulation.sh` always sets both `bios_boot_filename`
(line 205) and `uefi_boot_filename` (line 206) in the same run and passes
both `DHCP_PROXY_PXE_BOOT_FILENAME_BIOS` and `_UEFI` to the container (lines
221-223). The `have_bios -eq 0` branch in
`_dhcp_proxy_render_pxe_service_directives` (entrypoint.sh lines 613-631,
which renders the inert `pxe-service=IA64_EFI,"lancache-ng PXE proxy
active",0` placeholder for a UEFI-only configuration) therefore has no
packet-level behavior asserted anywhere — only reasoned about in code
comments. A UEFI-only operator configuration (`DHCP_PROXY_PXE_BOOT_SERVER` +
`_FILENAME_UEFI` only, no BIOS filename) — explicitly called out as
supported in `docs/dhcp-modes.md` line 219-220 ("Both a BIOS-only and a
UEFI-only configuration are supported") — has never actually been observed
to produce a real DHCPOFFER end to end.

Severity: info (reconfirms SoT with the exact script line numbers).

---

## 9. No automated test exercises the `/data/lancache-ui-settings.env`
   sourcing path (independently reconfirmed from SoT §5.5)

Neither `tests/bats/dhcp_proxy_known_good_snapshot.bats` nor
`tests/bats/dhcp_proxy_optional_directives.bats` runs the full
`entrypoint.sh` top-level script — both only source extracted function
bodies via the awk-based helpers (`dhcp-proxy-optional-directives-helpers.sh`,
`dhcp-proxy-known-good-snapshot-helpers.sh`). No fixture anywhere proves "the
Admin UI writes `/data/lancache-ui-settings.env`, and the dhcp-proxy
container's entrypoint actually sources and honors it on next restart" —
including the specific interaction in finding §2 above (that this file's
fixed key whitelist omits the PXE vars).

Severity: info.

---

## 10. No Docker Compose healthcheck at all for the dhcp-proxy service (dev AND prod)

Confirmed by reading the full `dhcp-proxy:` service block in both
`deploy/dev/docker-compose.yml` (lines 278-305) and
`deploy/prod/docker-compose.yml` (lines 318-347): **no `healthcheck:` key at
all**. Every other long-running service in the same compose files has one:
nginx (`curl .../healthz`), PowerDNS x2 (`rec_control ping && ss -lnu | grep
':53'`), Kea (a `KEA_CTRL_HOST`-aware CMD-SHELL probe), fluent-bit (`-V`
binary-integrity check), syslog-ng (`syslog-ng-ctl healthcheck`). A dead or
hung dnsmasq process inside this container produces no unhealthy status via
`docker inspect`/`docker compose ps`, unlike every sibling service. This may
be partly explained by `dnsmasq.conf.template`'s own documented tradeoff
(dnsmasq supports only one log destination, so `docker logs` shows nothing
once `log-facility=` is set, ruling out a log-based check) combined with no
alternative (e.g. a UDP DHCP-proxy self-probe) ever having been implemented —
but the net result is a genuine observability/monitoring gap for this
specific service, worth comparing against how the project's Watchdog service
currently reacts (or doesn't) to a hung dnsmasq.

Severity: info/minor (new finding, not previously in SoT).

---

## 11. Python script embedded in a Rust-only project for CI/simulation tooling,
    with no visible documented maintainer approval

`scripts/lib/pxe-client-probe.py` is a Python 3 script (using `scapy`) that
`scripts/dhcp-proxy-pxe-simulation.sh` invokes inside the build-tools image to
craft and parse real PXE-tagged DHCP packets. `tools/build-tools/Dockerfile`
installs `python3`, `python3-scapy`, and `tcpdump` specifically to support it
(lines ~224-263, ~375-379), with an extensive comment justifying the
technical necessity (no off-the-shelf DHCP client can send a real PXE-tagged
DHCPDISCOVER; scapy's own live-sniff was found unreliable against this
project's dnsmasq build, so tcpdump-plus-offline-rdpcap is used instead).

This project's own governance (`AGENTS.md`: *"This project is written in
Rust... No other runtime language (Go, Python, Node.js, etc.) may be
introduced without explicit approval from @djdomi."*; `CLAUDE.md`: *"Project
language: Rust... No Go, Python, Node.js, or other runtimes without explicit
approval from the user."*) requires explicit maintainer approval for exactly
this kind of addition. The code comments thoroughly justify the *technical*
choice but never state that this specific Rust-only-language exception was
explicitly approved by the maintainer. This may well have been discussed and
approved during PR #765's review (not verified in this sweep — recommend
checking that PR's review thread/comments directly) — flagging because, as
currently written, no approval trail survives in the repository itself, and
a future contributor/reviewer has no way to tell "approved exception" apart
from "slipped through review" just by reading the code.

Severity: info (process/governance finding, not a runtime bug; the technical
rationale for using Python here is well-argued regardless of approval status).

> **Resolution (2026-07-24, issue #1158):** confirmed as a real governance gap
> — the exception was not approved during PR #765's review; the maintainer
> caught it directly over a week after merge. The probe was rewritten as the
> Rust crate `tools/pxe-client-probe/` and the `python3-scapy` tooling removed,
> closing the gap. `tcpdump` remains (the Rust probe still captures replies with
> it) and `python3` remains (required by `distcc-pump`, unrelated to this
> script). This resolution note is a forward pointer only; the finding text
> above is preserved as the original `origin/v0.2.0` snapshot observation.

---

## 12. `release/stack-images.yml`'s `compose:` list for `dhcp-proxy` (and `dhcp`)
    omits `deploy/quickstart/docker-compose.yml`, which does reference the image

`release/stack-images.yml` lines 82-89 list `dhcp-proxy`'s `compose:` entries
as only `deploy/prod/docker-compose.yml`. But `deploy/quickstart/docker-compose.yml`
line ~1114 does contain a `dhcp-proxy:` service block referencing
`ghcr.io/.../dhcp-proxy:${LANCACHE_IMAGE_TAG:-latest}`. The manifest's own
`compose:` field for this image is therefore incomplete/stale relative to the
actual repo. Note: the `dhcp` (Kea) entry has the exact same omission pattern,
so this might be a deliberate convention for optional/profile-gated services
rather than a dhcp-proxy-specific bug — but `scripts/validate-stack-images.sh`
never actually reads or validates the `compose:` field's contents at all (confirmed
by reading the full script), so there is no way to tell "intentional" from
"simply never audited" from the code alone.

Severity: info.

---

## 13. `validate-stack-images.sh`'s per-image quickstart registry-variable check
    does not cover `dhcp`/`dhcp-proxy`

`scripts/validate-stack-images.sh` lines 107-118 explicitly `require_grep`
that `deploy/quickstart/docker-compose.yml` references `proxy`, `dns`,
`watchdog`, and `ui` through the `${LANCACHE_IMAGE_REGISTRY:-ghcr.io}/${LANCACHE_IMAGE_PREFIX:-wiki-mod/lancache-ng}`
variable pattern (not a hardcoded image reference). There is **no equivalent
check for `dhcp` or `dhcp-proxy`**, even though quickstart's compose file does
reference both through the same pattern (confirmed:
`dhcp-proxy:${LANCACHE_IMAGE_TAG:-latest}` is present and correctly
variable-based today). If a future edit accidentally hardcoded the
dhcp-proxy image reference in quickstart compose (bypassing
`LANCACHE_IMAGE_REGISTRY`/`_PREFIX`/`_TAG`), this governance-required
validator (mandated by `CONTRIBUTING.md`'s "Release and package changes"
section for exactly this class of change) would not catch it for these two
services, unlike the four it does check.

Severity: minor (concrete, verifiable CI-coverage gap; currently-compliant
by care, not by an enforced check).

---

## 14. CI runner-tier: `dhcp-proxy-pxe-simulation` job runs on `lancache-light`
    despite doing a real `docker build` + multi-container run

`.github/workflows/full-setup-validate.yml`'s `dhcp-proxy-pxe-simulation` job
(lines 761-823) does `docker build -q -t "$image_tag" services/dhcp-proxy`
plus starts two containers (dnsmasq-proxy + a scapy/tcpdump client) — yet
runs on `[self-hosted, linux, lancache, lancache-light]`. Per `AGENTS.md`'s
own runner-tier rule (*"route lightweight static checks to ...
lancache-light and memory-heavy Rust, CodeQL, container scan, Docker build,
and release jobs to ... lancache-heavy"*), a job that does a Docker build
arguably belongs on the heavy tier. That said, **every single job in this
workflow file** uses `lancache-light` uniformly (confirmed via
`grep -n "runs-on:"` across the whole file, 11/11 matches all
`lancache-light`) — so this looks like a pre-existing, file-wide choice
rather than something dhcp-proxy-specific, and may already be a deliberate,
accepted tradeoff (these are all fast, throwaway single-image builds, not
the main multi-platform release builds). Flagging since it directly affects
this component's own CI wiring and is one instance of the pattern, not
because it's uniquely wrong here.

Severity: info.

---

## 15. Admin UI's shared managed-option-code list blocks DHCP option 119 for
    dnsmasq-proxy custom options, though nothing dnsmasq-proxy-specific uses it

`is_ui_managed_subnet_option_code` (dhcp.rs line 2813-2814) matches
`3 | 6 | 15 | 42 | 119`, and `parse_custom_options_form` (the dnsmasq-proxy
custom-options form parser) reuses this exact same code/data validator
"including the exclusion of codes 3/6/15/42/119" per its own doc comment
(dhcp.rs line ~1143). Codes 3/6/15/42 map to dnsmasq-proxy's own dedicated
router/DNS/domain/NTP fields, so excluding them from the free-form list makes
sense. Code 119 (domain-search) maps to a **Kea-only** dedicated field —
dnsmasq-proxy mode has no domain-search field of its own at all. An operator
configuring dnsmasq-proxy mode through the Admin UI therefore cannot set DHCP
option 119 via the custom-options textarea, even though doing so would not
create "two conflicting ways to set the same option" (the stated rationale
for the exclusion) in dnsmasq-proxy mode specifically — it's an artificial
restriction inherited wholesale from the Kea validator's own reserved list.

Severity: info (minor UX restriction, not a correctness bug).

---

## 16. Combined observability note (not a new bug, connects #10 to the template's own documented tradeoff)

`dnsmasq.conf.template`'s own header comment (lines 39-46) documents that
dnsmasq supports only one logging destination at a time, so once
`log-facility=/var/log/lancache-dhcp-proxy/dnsmasq.log` is set (which it
always is, unconditionally, in this template), `docker logs` on this
container shows nothing for DHCP transactions — an accepted, already-documented
tradeoff, not new. Combined with finding §10 (no compose healthcheck at all),
the net result is that there is currently **no way to observe this service's
live health** short of tailing the log file/fluent-bit pipeline directly —
worth the maintainer's attention as a combined gap even though each half is
individually either documented (this one) or already flagged (§10).

Severity: info.
