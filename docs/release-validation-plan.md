# Release Validation Plan

This is the repeatable, reusable test plan for validating lancache-ng before cutting
a release, on a real Linux Docker host. It exists because, as of 2026-07-24, no such
document existed: coverage was scattered across `tests/bats/*.bats`, `tests/shellspec/`,
each crate's `cargo test`, and the CI workflow YAML files themselves (whose job names
are the closest thing to an implicit checklist). This document is meant to be run
**every release**, not just once — subsystem checks are written to stay durable as
the codebase evolves; only the "Current known feature-specific checks" section below
is expected to age and needs pruning/updating release over release.

Two independent things are validated here, and both matter:

- **CI** — do the automated pipelines (`build-push.yml`, `build-tools.yml`,
  `full-setup-validate.yml`, `full-setup-deep-validate.yml`) actually enforce what they
  claim to enforce, verified with real executed runs, not static reading of the YAML.
- **Stack** — does the actual running system, brought up for real on a real Docker
  host, behave the way its features claim to behave.

Neither substitutes for the other. A green CI run does not prove the live stack
behaves correctly (CI's own simulation jobs are themselves a form of "stack" testing,
but a maintainer doing a pre-release pass on real hardware is exercising paths CI's
runner topology and job scoping do not always reach identically). A working live
stack does not prove CI's gates would have caught a regression before merge. Validate
both.

**Governing principle, threaded through every check below**: verification must go
beyond "does it compile / does the existing test suite pass" and prove the actual
claimed behavior is real. `cargo test`/`cargo clippy`/`bats` passing is necessary but
not sufficient — see the worked examples throughout this document, and the "Standing
checks" tables' "How to check it for real" column specifically. In a memory-safe Rust
codebase, "no leaks" is not the C/C++ heap-corruption question; the resource-leak
concern that actually applies here is whether processes, containers, connections, and
file descriptors are actually released when a service is removed, rotated, or
restarted — not just that an API call returned success. See the dedicated
"Resource-Leak / Cleanup Pass" section under Part B.

---

## Validation State Tracking (read this before running anything below)

Before starting any validation pass, answer these questions for real, from the
checkable record in [`docs/validation-state.json`](./validation-state.json) — never
from memory, from "someone said so in a PR comment once," or from assumption:

1. **What was the last verified state?** Read `last_stack_validation` and
   `last_ci_validation` in `docs/validation-state.json`: each names a `commit`, `date`,
   `validator`, `scope`, `summary`, and `evidence_ref` (a URL or file path to the real
   executed proof — a CI run, a PR/issue comment quoting command output, or a log
   file). A `null` commit means "never validated under this mechanism" — treat that
   exactly like a fresh install with no history.
2. **Am I about to test Stack, CI, or both?** Decide explicitly before starting; the
   two have independent records (see policy below) and independent procedures (Part A
   vs Part B of this document).
3. **Has Stack already been validated at or after the current commit?** Compare
   `last_stack_validation.commit` against the commit you intend to validate
   (`git rev-parse HEAD` on the branch/tag under test). If they're equal, Stack is
   current *only if* nothing relevant changed since — see question 5. If
   `last_stack_validation.commit` is not an ancestor of the current commit at all
   (history was rewritten), treat the record as void per `full_invalidation_triggers`
   in the state file, not as merely "stale."
4. **Has CI already been validated at or after the current commit?** Same check
   against `last_ci_validation.commit`.
5. **What changed since the last validation, so re-validation can be scoped?** Run:
   ```bash
   git fetch origin --tags
   git log --name-only <last_validation.commit>..<commit under test> -- .
   ```
   Then classify that diff using the **exact same classifier CI already uses for
   this purpose** — do not invent a second, drifting definition of "what counts as
   DHCP-relevant":
   ```bash
   bash scripts/untracked/classify-image-impact.sh <last_validation.commit> <commit under test>
   ```
   This prints the same `dns_rust`/`ui`/`watchdog`/`dhcp`/`dhcp_proxy`/`ntp`/`proxy`/
   `build_tools`/`workflow`/`docs`/`governance`/`setup_runtime`/`deploy`/
   `release_contract`/`scripts` booleans build-push.yml's `detect-changes` job and the
   `promote` job's version-bump logic both already consume. Cross-reference each
   `true` boolean against `docs/validation-state.json`'s `subsystem_validation` map
   (whose `path_prefixes` mirror the same classifier) to know exactly which
   subsystem-specific checks in Part A/B below need a fresh run, and which can be
   skipped as still-current. This is what makes re-validation **incremental**: only
   run the subsystem checks whose `path_prefixes` the diff actually touched, plus any
   check whose own doc entry says it depends on a subsystem that changed.
6. **Where is the record kept?** `docs/validation-state.json`, committed to the repo
   — not a PR comment, not a chat transcript, not tribal memory. It is versioned
   alongside the code it describes, so `git blame`/`git log` on the file itself is a
   real audit trail of who validated what, when.
7. **What counts as "stale"?** Per-subsystem, not all-or-nothing, using the same
   classifier as question 5: a subsystem's recorded validation is stale the moment
   `git log <its recorded commit>..HEAD -- <its path_prefixes>` is non-empty. A
   change to an unrelated subsystem's paths does **not** invalidate this one. Full,
   blanket invalidation (every subsystem, both layers) applies only for the three
   cases listed in `full_invalidation_triggers` in the state file: a governance
   (`AGENTS.md`/`.github/AGENTS.md`) change, an unreconstructable diff (the same case
   `classify-image-impact.sh --all-changed` exists for), or a history rewrite that
   makes the recorded commit not an ancestor of the current one.
8. **Who/what may update this record?** Only as a direct, atomic result of an actual
   completed validation run with real evidence attached — the same "real executed
   proof, not a static claim" principle `AG-CI-012` already established for
   branch-trigger completeness (see the proposed `AG-REL-011` rule, below, which
   generalizes that principle to this record specifically — corrected 2026-08-01:
   an earlier version of this note pointed at `AG-VAL-028`, a rule number this
   document's own original PR proposed for this exact purpose but which was never
   adopted under that number and was later independently reassigned to an unrelated
   rule, the manual-review-CI-checkability recommendation; the live proposal
   generalizing this specific principle is `AG-REL-011`, in PR #1368, itself still
   open/Draft as of this correction). Never write a passing
   entry because a check "should" pass, because an earlier version of the code
   passed, or because a subagent reported success without the caller re-verifying the
   evidence per `AG-WF-021`. Update the specific layer(s) and specific
   `subsystem_validation` entries actually exercised in that run — do not blanket-mark
   every subsystem current just because one ran.
9. **Can Stack and CI have independently-current states, or does a stale one block
   trusting the other?** Answer, explicitly: **yes, they are tracked independently
   (they prove different claims — CI proves the automated gates enforce correctness
   on this commit; Stack proves the actual running system behaves correctly on this
   commit, and neither implies the other), but for a release-readiness declaration,
   both must be current as of the same commit (or a commit with no relevant changes
   since, per question 7).** A stale CI record does block a release-ready
   declaration even if Stack is fresh, and vice versa — do not let a fresh result in
   one layer paper over a stale result in the other. It is entirely valid, and
   expected in normal operation, for only one layer to need re-validation after an
   incremental change (e.g. a pure-docs PR only invalidates nothing per the
   classifier; a Rust-only PR with no workflow/script changes may leave CI's own
   pipeline-correctness proof untouched while still requiring a fresh Stack pass for
   the subsystem it touched) — track them separately, gate release-readiness on both.
10. **This mechanism is proposed as new `AGENTS.md` rules**, not yet adopted — see the
    accompanying PR body for the exact proposed rule text. **Corrected 2026-08-01**:
    this document's own introducing PR originally proposed the enforcing rule IDs
    `AG-VAL-028`/`AG-VAL-029`/`AG-CI-013` for the two principles in this section (every
    real incident needs a durable check; a release-readiness declaration must not
    trust a self-invalidated `validation-state.json` record) — none were adopted
    under those numbers, and all three were later independently reassigned to
    unrelated rules (`AG-VAL-028` now covers periodic CI-checkability review of
    manual-review-only rules; `AG-CI-013` now covers the retry-wrapper convention for
    flaky registry/build operations), leaving both principles as unenforced prose for
    over a week. The live, correctly-numbered proposal is **`AG-VAL-029`** (every
    confirmed real bug/CI failure/infrastructure incident must produce a durable
    check here, or a recorded reason in Coverage Assessment if genuinely
    unautomatable) and **`AG-REL-011`** (a release-readiness declaration must not rely
    on a `validation-state.json` record a `full_invalidation_trigger` has since
    invalidated) — see PR #1368 for the exact rule text; that PR is **still open/Draft
    as of 2026-08-01**, submitted for maintainer review in the same spirit `AG-WF-025`
    itself requires for a new rule proposal, and is not yet merged into `AGENTS.md`.

**Practical update recipe** once a validation run actually completes with real
evidence:

```bash
# Example: after a completed Stack pass for the "admin-ui" and "watchdog" subsystems
# only (an Admin UI PR that didn't touch DHCP/DNS/NATS), edit docs/validation-state.json:
#   - last_stack_validation: commit/date/validator/scope="incremental:admin-ui,watchdog"
#     /summary/evidence_ref updated
#   - subsystem_validation.admin-ui and .watchdog: commit/date/validator/evidence_ref updated
#   - every other subsystem_validation entry: left untouched (still valid from its own
#     last recorded commit, per the per-subsystem staleness rule in question 7)
git diff docs/validation-state.json   # review the exact fields you changed before committing
```

---

## Part A — CI Test Plan

CI's job is to *automatically* catch a regression before merge. Validating CI means
proving each pipeline gate actually enforces what it claims, not just that the YAML
parses. Every entry below states what to check, how to check it for real (reusing an
already-existing proof where one exists — do not re-invent it), and pass/fail
criteria.

**Two different automation surfaces exist, and they are triggered differently — know
which one a given check actually runs under before treating "current_dev CI is green"
as proof of it:**

- `build-push.yml` / `build-tools.yml`: run automatically on every PR (`pull_request`)
  and push, including against `current_dev`. This is where `rust_coverage`,
  `dns_rust_quality`/`ui_rust_quality`, `dns_test`/`ui_test`/`watchdog_test`,
  `dns_cargo_audit`/`ui_cargo_audit`, `shellcheck`, `file-headers`, `validate-compose`
  (incl. the VEX-drift guard), `pr-tracking-metadata-check`, and `container-scan` live.
- `full-setup-validate.yml` (4 top-level jobs — `full-setup-sims`,
  `dhcp-proxy-pxe-simulation`, `dhcp-relay-flow-simulation`,
  `dhcp-kea-ctrl-agent-mutation-simulation`, confirmed directly 2026-08-05, correcting
  a prior "11 jobs" count that was already stale — `full-setup-sims` itself composes
  the reusable `full-setup-sims.yml`, which carries a further 12 jobs) is
  **`workflow_dispatch`-only** — it does not run
  automatically on any PR; confirmed directly (2026-07-24): its `on:` block has no
  `pull_request` trigger at all.
- `full-setup-deep-validate.yml`'s `pull_request` trigger **does** include
  `current_dev` — `branches: [master, current_dev, "v[0-9]*"]`, confirmed directly
  (2026-07-24) against the workflow file itself (a prior version of this document
  claimed `current_dev` was excluded; it is not — see #709's audit, which restored
  `current_dev` here specifically to match `build-push.yml`'s own `pull_request`
  trigger). It does, however, carry a docs-only `paths-ignore` (`**/*.md`,
  `docs/**`, added by #1203), so a PR that touches only docs does not trigger it —
  do not treat a green `current_dev` PR as proof this workflow ran unless the diff
  also touched a non-docs path. For subsystems whose real E2E proof lives in one of
  these two workflows (DHCP relay, NATS active-disconnect/xkey, DNS reset-to-last-
  known-good, syslog forwarding, etc.), "repeatable CI validation" for
  `full-setup-validate.yml` specifically means actually invoking it —
  `gh workflow run full-setup-validate.yml --repo wiki-mod/lancache-ng --ref
  <branch>` — or running the underlying `scripts/untracked/simulations/*-simulation.sh`
  script directly against a real stack over SSH on a Linux host, not assuming a green `current_dev`
  PR check already covered it. Note also: `gh workflow run`'s own `image_tag` input
  defaults to `nightly` — before trusting that dispatch as evidence for a specific
  commit, confirm the `nightly` channel tag has actually been rebuilt from that
  commit (`build-push.yml`'s run for that exact SHA on `current_dev` must have
  completed and published), not just that the dispatch itself succeeded; a stale
  `nightly` silently validates the wrong content.

### Standing checks per subsystem

| Subsystem | What to check | How to check it for real | Pass/fail |
|---|---|---|---|
| **DHCP — Kea** | `dhcp_kea_config_generation.bats`/`dhcp_lease_flow_parsing.bats` pass, AND the real Kea Control Agent lease flow works | `bats tests/bats/dhcp_kea_config_generation.bats tests/bats/dhcp_lease_flow_parsing.bats` (build-tools container) for config-gen; `full-setup-validate.yml`'s `dhcp-kea-lease-flow-simulation` job (or `gh workflow run`) for a real DHCPDISCOVER→DHCPACK cycle against Kea, asserting a real lease was granted from the configured pool, not just that the container started | Fail if the bats config-gen tests fail, or if the lease-flow simulation does not show a granted IP from the correct pool |
| **DHCP — Kea Admin UI mutation + rollback** (added 2026-08-05, issue #1391 audit — previously wired into CI but never referenced in this document) | A static reservation added via the Admin UI (`POST /dhcp/static/add`, issue #634) genuinely affects a subsequent real lease request; the Admin UI's own Kea-rollback route (issue #837) genuinely restores Kea to an earlier real snapshot | `full-setup-validate.yml`'s `dhcp-kea-ctrl-agent-mutation-simulation` job (`scripts/untracked/simulations/dhcp-kea-ctrl-agent-mutation-simulation.sh`) for the UI-driven mutation proof; `full-setup-deep-validate.yml`'s `dhcp-kea-ui-rollback-simulation` job (`scripts/untracked/simulations/dhcp-kea-ui-rollback-simulation.sh`) for the UI-driven rollback proof — both already CI-wired, reuse rather than re-derive | Fail if the mutation isn't reflected in a subsequent real lease, or if the post-rollback Kea state doesn't match the earlier snapshot |
| **DHCP — dnsmasq ProxyDHCP** | `dhcp_proxy_known_good_snapshot.bats`/`dhcp_proxy_optional_directives.bats` pass; PXE-relevant options actually get injected | Same bats files; `full-setup-validate.yml`'s `dhcp-proxy-pxe-simulation` job for a real PXE client boot-option probe | Fail if bats fail or the PXE simulation doesn't observe the expected boot options on the wire |
| **DHCP — dnsmasq relay** (new, PR #1117) | `dnsmasq-relay` mode genuinely **relays** (not just injects options) between two network segments | `bash scripts/untracked/simulations/dhcp-relay-flow-simulation.sh` (build-tools container / real Docker host) — this is the exact script #1117 used: two isolated bridges (client-net, server-net), a real `dhclient` DISCOVER on the client-net side, confirms the upstream DHCP server on the separate server-net received the request via the relay's `giaddr` and answered with a lease from the *client subnet's* pool. `tests/bats/setup_dhcp_mode.bats` for the mode-selection/config-render unit coverage | Fail unless the granted lease's subnet matches the client-side pool specifically (proves `giaddr` routing worked, not a coincidental same-subnet fallback) |
| **DNS — PowerDNS zones/RPZ** | Real DNS resolution (recursor + authoritative), zone writes propagate, RPZ wildcard coverage is correct | `dig` against `dns-standard`/`dns-ssl` for a known CDN domain and a known `.lan` record — `ping`/`ss` are explicitly **not** acceptable substitutes (`AG-VAL-019`/`AG-VAL-020`). `tests/bats/dns_zone_generation.bats`, `dns_known_good_snapshot.bats`, `dns_config_snapshot_idempotence.bats` | Fail if `dig` doesn't return the expected record, or any DNS bats file fails |
| **DNS — reset-to-known-good** (new, PR #1152) | `setup.sh reset-to-last-known-good-config dns <zone>` genuinely rolls a live PowerDNS zone back | `bash scripts/untracked/simulations/setup-reset-dns-config-simulation.sh` (real full-setup stack: makes two real UI-driven zone writes, each producing a real snapshot, then runs the actual CLI against the earlier snapshot, confirms via a real `dig` query that the record content actually reverted). Note from #1152 itself: this script's own real run required two environment-only deviations at the time (a locally built `dns` image; a patched healthcheck probe domain, both because of the unrelated, since-fixed #1150 bug) — when running it again, confirm no deviation is needed anymore before treating a clean run as fully representative | Fail unless the post-rollback `dig` result matches the earlier snapshot's content exactly, and the CLI genuinely used the in-container `PDNS_API_KEY` (the script deliberately seeds a wrong host-side key as a regression guard for this) |
| **NATS — secondary registration/rotation/removal** | Per-secondary credential isolation; rotation invalidates the old credential; removal actually blocks | `bash scripts/untracked/simulations/nats-secondary-auth-callout-simulation.sh` against a real `nats-server` + a real `nats-subscriber` built from the branch under test | Fail if an old credential still authenticates after rotation, or a removed secondary can still connect |
| **NATS — Admin UI DNS-sync propagation** (added 2026-08-05, issue #1391 audit — previously wired into CI but never referenced in this document, and a genuinely different NATS function than secondary-lifecycle) | A DNS entry created via the Admin UI is really propagated end-to-end: UI → NATS → `nats-subscriber` → PowerDNS, and is genuinely resolvable, not just accepted by the UI | `full-setup-sims.yml`'s `ui-nats-dns-integration-simulation` job (`scripts/untracked/simulations/ui-nats-dns-integration-simulation.sh`, issue #400) — creates a real entry via the Admin UI, confirms it lands in PowerDNS via a real `dig`, then removes it and confirms removal propagates too — already CI-wired, reuse rather than re-derive | Fail if the entry never resolves via `dig` after creation, or still resolves after removal |
| **NATS — active disconnect on remove/rotate** (new, PR #1172) | A secondary already connected *at the exact moment* of removal/rotation is force-disconnected within seconds, not left connected until its next reconnect (up to 90 days under the old JWT TTL) | The same `nats-secondary-auth-callout-simulation.sh`, extended in #1172: hold a real `nats-subscriber` connection open, confirm it's live via `nats-server`'s own `connz` HTTP monitor endpoint, remove/rotate that secondary from the Admin UI **while still connected**, then **poll `connz` until the connection actually disappears** — the HTTP 200 from the removal API call is not the proof; the connection's disappearance from `connz` is | Fail if `connz` still lists the connection after a reasonable poll window, or if an unrelated secondary's connection is also kicked (over-broad `CONNZ` filter) |
| **NATS — xkey encryption** (new, PR #1168) | The auth-callout request/response is genuinely encrypted on the wire, not just configured | The packet-capture phase `nats-secondary-auth-callout-simulation.sh` gained in #1168: capture real `nats-server`↔Admin-UI traffic, assert the sealed-box `xkv1` marker is present AND the JWT's own literal base64 header marker is **absent** (checking for the raw password substring is **not sufficient** — the payload is always base64-JWT-encoded regardless of encryption, so a naive substring check "passes" unconditionally; #1168's own methodology note documents this exact false-positive trap). Run once with `xkey:` configured (must show encrypted) and once with it removed as a negative control (must show the plaintext marker) — a check that can't fail is not a check | Fail if the plaintext JWT header marker appears in a run where `xkey` is configured, or if the negative-control run does *not* show it (proves the assertion methodology itself still discriminates) |
| **Admin UI — cache-resize** (new, PR #1174) | A submitted resize genuinely changes what nginx enforces, not just what the dashboard displays | Submit a resize via the UI/API, wait for the ~5-minute `lancache-converge.service` tick, then `docker exec <proxy container> nginx -T 2\>&1 \| grep proxy_cache_path` and confirm the rendered `max_size=` value actually changed to the new target — a `200 OK` from the form or an unchanged dashboard number is **not** proof. On `deploy/quickstart` this reaches the real proxy; on a manual `deploy/prod` checkout it does **not** (documented gap in #1174 — the `ui` container's own display updates but `config/prod/proxy.env` is untouched) — validate against the deployment profile actually in use and do not assume `deploy/prod` behaves like `deploy/quickstart` here | Fail if `nginx -T`'s rendered `max_size` doesn't match the submitted value on quickstart; on `deploy/prod`, confirm this known-misleading-display gap is still documented, not silently "fixed" by an unrelated change without updating this plan |
| **Watchdog — dashboard health card** (new, PR #1165) | The dashboard's color indicators reflect real, live container health — not a frozen or fabricated state | Stop a monitored container (`docker stop lancache-dns-ssl`), wait one `watchdog.sh` cycle (default 30s), `curl http://<ui>/api/watchdog-status` and confirm the entry flips to `red`/`unhealthy`; restart it and confirm it flips back to `green`. Confirm a deliberately stale/missing `status.json` renders `Stale`/`Unavailable`, not a silently frozen last-known color | Fail if the API/dashboard doesn't reflect a real state transition within roughly one `CHECK_INTERVAL` |
| **Watchdog — NATS monitoring** (new, PR #1167) | A hung (not crashed) `nats` container gets detected and restarted | `docker kill --signal=STOP lancache-nats` from **outside** the container's PID namespace (an in-container `kill -STOP 1` is a no-op — PID 1 ignores unhandled stop/kill signals from within its own namespace, confirmed live in #1167), wait 3× `CHECK_INTERVAL`, confirm watchdog logs `RESTARTING lancache-nats` and `docker inspect --format='{{.State.StartedAt}}'` shows a genuinely new start time | Fail if no restart occurs after 3 consecutive unhealthy reads, or if `StartedAt` is unchanged (a restart request that silently failed) |
| **Watchdog — hang-simulation technique for multi-process monitored services** (corrected, issue #1391, 2026-08-05) | The row above's technique is **only valid for a genuinely single-process container** (`nats`). Confirmed live during the 2026-08-02 pass (see this document's own `docs/validation-state.json` record): `docker kill --signal=STOP <container>` only ever signals PID 1 inside the container's PID namespace. For `proxy` (nginx master + 8 worker processes + cache manager/loader) this stops only the master; the workers stay `S` (sleeping) and keep serving requests throughout (confirmed via `/proc/<pid>/status`), so the container's own healthcheck genuinely stays green and this technique cannot produce the hang it claims to test for any multi-process monitored service. **Corrected 2026-08-05 (this row previously prescribed `docker pause`, which was itself found on re-check, per an advisor review, to prove the wrong thing — see the two empirical results below, both required before this row was finalized):** the correct fix is **`docker top <container> -o pid` then `kill -STOP` every listed PID from outside the container (root/`sudo`, not `docker exec` for this part — an in-container, same-namespace signal to a sibling process would also work but was not the tested path here)**, not `docker pause`. | `docker inspect --format='{{.State.Health.Status}}'`/`{{.State.Health.FailingStreak}}` after stopping every PID, then `{{json .State.Health.Log}}` to confirm a real failing probe (not just a state-machine short-circuit) ran. **Both techniques verified empirically 2026-08-05** (isolated `nginx:alpine` container, own healthcheck, Docker Engine 29.6.1, self-hosted runner — real multi-process container: 1 master + 7 workers, confirmed via `docker top`): (1) **`docker pause` reproduced 2/2 but proves the wrong thing** — flips `.State.Health.Status` to `unhealthy` within one poll cycle, but `FailingStreak` stays `0` and `.State.Health.Log` gains no new entry; Docker's own pause-handling short-circuits health-checking entirely (a healthcheck `exec` cannot even start in a paused container's frozen cgroup) and stamps `unhealthy` from container *state*, not from a completed failing probe. This only proves "watchdog restarts a container Docker has already flagged unhealthy by other means" — already proven by the existing `docker stop`/crash coverage — and does **not** touch the actual open question, issue #1391's own wording: "it remains genuinely unknown whether Watchdog would detect a real full nginx hang." (2) **Multi-PID `SIGSTOP` closes that actual gap.** `docker top`-listed PIDs confirmed `State: T (stopped)` via `/proc/<pid>/status` after signalling every one (not just PID 1) from the host. Because `SIGSTOP` suspends existing processes without freezing the container's cgroup, Docker can still schedule a *new* healthcheck exec — which genuinely attempts to connect, genuinely cannot get a response (every worker able to `accept()`/serve is stopped), and genuinely times out at the configured `--health-timeout`: two consecutive real failed probes were recorded (`ExitCode: 1`, empty `Output`, ~2.0s duration matching the configured client timeout), `FailingStreak` reached `2`, and `Status` became `unhealthy` through this real timeout path — the same code path and timing character a real in-process hang would produce, unlike `docker pause`'s instant, probe-free flip. `SIGCONT` on every PID correctly restored `healthy`. Use multi-PID `SIGSTOP`/`SIGCONT` as the prescribed technique for `proxy`/`dns-standard`/`dns-ssl`; `docker pause` remains documented above only as a distinct, faster check for "does watchdog act on Docker's own unhealthy determination," not a hang-detection proof | Fail if `.State.Health.FailingStreak` does not increase via a real timed-out probe (`ExitCode` non-zero from an actual command run, not merely `Status` changing) within a few `CHECK_INTERVAL`-equivalent poll cycles after multi-PID-stopping a monitored service, or if a subsequent live pass against the real `proxy`/`dns-standard`/`dns-ssl` images does not show a genuine watchdog-triggered restart (new `StartedAt`) using this technique |
| **Edition-2024 build (PR #1179)** | All three Rust crates actually build/test/lint clean on the real target (Linux, build-tools container) — not just a Windows-side `cargo check` | For each of `services/ui`, `services/dns/nats-subscriber`, `tools/pxe-client-probe`, inside the build-tools container: `cargo fmt --manifest-path <crate>/Cargo.toml -- --check`, `cargo check --locked --all-targets --manifest-path <crate>/Cargo.toml`, `cargo clippy --locked --all-targets --manifest-path <crate>/Cargo.toml -- -D warnings`, `cargo test --locked --manifest-path <crate>/Cargo.toml`. A **Windows-authored** `cargo check` result is not acceptable evidence per `.github/AGENTS.md`'s build-tools-container contract — the Windows host cannot build Rust for this project's Linux/Docker targets at all | Fail on any non-zero exit from any of the four commands for any of the three crates, or if the check ran outside the pinned build-tools container |
| **SBOM/VEX generation** (PR #1194; re-architected Issue #1095 F-22 — `vex.openvex.json` is no longer committed to `current_dev`) | `scripts/untracked/generate-vex.sh` always produces valid, non-empty OpenVEX JSON from `.trivyignore.yaml` (the generator-smoke-test guard, `scripts/tracked/check-vex-drift.sh`, no longer compares against a second committed copy — there isn't one); the `CI-Automation/vex` orphan branch is refreshed by `.github/workflows/vex-regenerate.yml` on real `.trivyignore.yaml`/generator changes; release tags regenerate their own asset fresh | `bash scripts/tracked/check-vex-drift.sh` (must report valid JSON with a non-zero statement count); `bash scripts/untracked/generate-vex.sh \| jq empty` (must be valid JSON); as a negative control, feed a scratch-copy `.trivyignore.yaml` with a syntax error into the generator and confirm the smoke test exits non-zero. `vex-regenerate.yml`'s own real `push`-triggered execution cannot be proven from a PR (AG-CI-012 — only provable after this file merges to `current_dev`); its `workflow_dispatch` input can exercise the generate/commit/push logic for real ahead of that, but does not prove the automatic path-filtered `push` trigger itself | Fail if the smoke test passes on genuinely malformed `.trivyignore.yaml` (the negative control), or reports invalid/empty JSON on an untouched checkout |
| **`docker run` stdin-heredoc requires `-i`** (Issue #1095 F-22, confirmed real incident) | Confirmed empirically against the real v0.3.0 release (published 2026-08-03, run 30788959407): `build-push.yml`'s "Create or update GitHub release for built images" and "Attach OpenVEX document to the release" steps, plus `release-sbom`'s asset-upload step, all reported `success` but the release body carried none of the release-notes step's own generated text and the release carried zero assets — `docker run` without `-i` never attaches container stdin, so the `bash -s <<'MARKER'` heredoc fed to each ran nothing. All three fixed with `-i`; `scripts/untracked/check-docker-run-stdin-heredoc.sh` (wired into the shared `file-headers-check` composite action) now fails closed on any future `docker run ... \| bash -s`/`sh -s` heredoc invocation in `.github/workflows/**`/`.github/actions/**` missing `-i` | `bash scripts/untracked/check-docker-run-stdin-heredoc.sh` (must report no violations on the current tree); as a negative control, scratch-copy a workflow file, strip `-i` from one known-good invocation, and confirm the check reports that exact file/line. The real v0.3.0 evidence above (`gh release view v0.3.0 --json body,assets`, `gh api .../actions/runs/30788959407/jobs`) is itself the primary confirmation this was a real bug, not merely a plausible one | Fail if the guard passes on a real missing-`-i` instance (the negative control), or if a future release still ships an empty release body/asset list despite these steps reporting success |
| **Fixture key-drift guard (PR #1199)** | The bats guard actually catches a reintroduced historical `.env`-key gap, not just that it parses | `bats tests/bats/setup_update_idempotence.bats` (guard test runs first, must pass on a clean checkout). As a negative control, remove one known-required key (e.g. `NTP_ENABLED`) from `write_converged_env_fixture()` in a scratch copy and re-run — must fail naming that exact key (already proven once, 2026-07-24 — reuse this exact check) | Fail if the guard doesn't name the specific missing key on the negative control, or passes when a key truly is missing |
| **CI/build-tools infra** (path-filter narrowing, permissions hardening — PRs #1190/#1202/#1204) | The narrowed path filters/permissions still trigger for every real change they must cover, and don't over- or under-trigger | `bash scripts/tracked/check-bats-path-filter-coverage.sh` (asserts every real bats dependency is covered by `build-tools.yml`'s path filters); `bash scripts/tracked/check-workflow-service-lists.sh` (keeps hardcoded service arrays in sync across workflow files); `actionlint -config-file .github/actionlint.yaml <changed workflow files>` for syntax/permissions/runner-label review per `AG-VAL-011` | Fail if either check script reports a gap, or `actionlint` reports any finding |
| **Governance docs (AGPL/MAINTAINERS/OSPS/SBOM policy PRs)** | Documentation actually matches current code/CI behavior, not aspirational text | `bash scripts/tracked/check-file-headers.sh` (header contract); manual read-through of each touched doc against the actual current code path it describes, per `AG-DOC-001`. There is no automated drift-detection tool for this yet (`AGENTS.md`'s own "Known Gaps" section says so explicitly) — this remains a manual-review item | Fail (flag as a defect, not skip) if a doc's claim contradicts current code behavior |
| **actionlint SIGKILL guard** (2026-07-25 runner-leak incident, AG-CI-016/017) | A hung, signal-deaf `actionlint` process inside `build-tools.yml`'s lint step is force-killed from inside the container, not left to leak the runner slot | Read the step's `timeout --kill-after=<grace> --signal=KILL <limit>` wrapper around both lint invocations in `.github/workflows/build-tools.yml`; on a self-hosted runner host, confirm no `actionlint` process older than the configured limit+grace is running (`ps -eo pid,etime,cmd \| grep actionlint`) after a normal run completes. Reproducing the actual Go-runtime deadlock on demand is not practical — this remains a structural/timeout-mechanism proof, not a live-deadlock reproduction (documented gap, matches this incident's own on-host verification standard) | Fail if any `actionlint` process survives past `<limit>+<grace>` on a real run, or if the wrapper is missing from either lint step |
| **BuildKit build-tools-image concurrency serialization** (2026-07-25, AG-CI-016/017, issue #1065) | Concurrent `build-tools.yml` amd64 image builds on the same self-hosted runner host no longer race on the shared BuildKit content store | Read the `concurrency:` group added to the amd64 build-tools-image job in `.github/workflows/build-tools.yml` (job-level constant group, `cancel-in-progress: false` — queues rather than cancels). Trigger two PRs whose diffs both touch `tools/build-tools/**` in quick succession and confirm via the Actions run queue that the second run genuinely waits (queued state) rather than starting concurrently and hitting the `ref layer-sha256:...locked...unavailable` signature again | Fail if two such builds run concurrently on the same host, or if the layer-lock signature recurs in a real run |
| **CodeQL PR supersession reclamation** (2026-08-08/09, AG-CI-017) | CodeQL runs do not share a GitHub concurrency group, because its one-pending-member behavior can let an older job evict the latest SHA. Each PR run instead checks the authoritative `refs/pull/<N>/head` before scheduling analysis and rechecks after runner admission; stale runs skip all expensive steps, while independent scheduling guarantees the current head cannot be displaced by an older run. **Accepted residual risk** (discussed and knowingly deferred, not fixed): the live head check only runs once, near the start of each run; a run already past it keeps running its full ~2h even if a later push on the same PR makes it stale, so pushes spaced further apart than detect-changes' own ~10-17s but closer together than ~2h can briefly occupy more than one `lancache-heavy` runner for the same PR. A source-level cap (counting this PR's other in-progress runs via the GitHub API) was scoped out: that call needs `curl`, which AG-VAL-016 requires running inside the build-tools container, and `detect-changes` has no container step today — adding one would cost real seconds on every PR push to guard against a scenario that is rare in practice. This is accepted for now, not closed: revisit if it stops being rare, or fold it into a future broader rework of this workflow's CI scheduling, where adding the cap is cheaper than bolting it on separately. | Push three Rust-relevant commits to a scratch PR with the middle run delayed in `detect-changes`. Confirm no `Analyze` job is cancelled by a concurrency group, the newest SHA reaches both matrix legs, and each older leg either finishes or reports `superseded=true` before CodeQL initialization. Also force the remote-head command to fail transiently and confirm it retries four times before the deliberate fail-open behavior, and confirm it fails closed immediately (no retry) on a permanent "ref not found" (exit code 2) result. Scheduler ordering requires real GitHub Actions runs; locally run the resolver bats tests and actionlint. | Fail if `analyze` gains a shared concurrency key, an older run cancels or displaces the newest SHA, a stale run proceeds past its successful live-head recheck, a current PR head is classified as superseded, or the newest Rust-relevant run does not execute actual Rust analysis. |
| **Q1 — build-tools.yml trigger narrowing + build-tools-smoke.yml** (2026-07-25, issue #1253) | `build-tools.yml` only rebuilds the image for real `tools/build-tools/**` content changes; `build-tools-smoke.yml` still runs bats/shellspec against the published image for every other test/script-relevant change | `bash scripts/tracked/check-bats-path-filter-coverage.sh` (now targets `build-tools-smoke.yml`, per its retargeted header comment — confirm it still reports full coverage); open a scratch PR touching only a `tests/bats/**` file (not `tools/build-tools/**`) and confirm `build-tools.yml`'s image-build job does not trigger while `build-tools-smoke.yml` does and passes | Fail if a test-only change still triggers a full image rebuild, or if a real `tools/build-tools/**` change fails to trigger one |
| **Runner-host cleanup script, versioned in-repo** (2026-07-25, `tools/runner-host/`) | The cleanup script actually reclaims disk (measure → clean → re-measure), reaps stale/orphaned build-tools containers across all self-hosted hosts, and is consistent (not host-local/ad-hoc) | `shellcheck tools/runner-host/*.sh` (must be clean); run the script for real on a self-hosted runner host via SSH, capture disk usage before/after, confirm the after-measurement shows real reclaimed space and that no `docker ps -a` entries for stopped/hung build-tools containers remain | Fail if the script only measures without a real reduction, or if it's missing from any host it's meant to run on |
| **CVE-2026-34040 non-exploitability documentation** (2026-07-25, `.trivyignore.yaml`) | The accepted-risk justification is a verified technical claim (vulnerable code is daemon-only, absent from the vendored client binaries), not a deferred "revisit later" placeholder | `bash scripts/tracked/check-vex-drift.sh` (must still report valid, non-empty OpenVEX JSON for this entry after any `.trivyignore.yaml` edit — see the SBOM/VEX generation row above for that guard's current, generator-smoke-test-only scope); read the `.trivyignore.yaml` entry's statement and confirm it names the specific reason (module split at moby v29, vulnerable code in `pkg/authorization`, daemon-only, absent from `docker-buildx`/`docker-compose` client binaries) rather than a vague "no fix available yet" | Fail if the ignorefile reverts to a vague justification, or if a real Trivy scan of the built images still flags this CVE as unaddressed without an equally specific replacement justification |
| **New/renumbered governance rules — AG-CI-014, AG-CI-016/017 (post #1242 AG-CI-015 collision), AG-GH-008 correction, AG-WF-027** (2026-07-25) | `AGENTS.md` has no duplicate rule IDs, and the Rule Enforcement Matrix has a row for every rule | `grep -oE "\*\*\[AG-[A-Z]+-[0-9]+\]\*\*" AGENTS.md \| grep -oE "AG-[A-Z]+-[0-9]+" \| sort \| uniq -c` — every ID must appear exactly once as a rule definition (a second appearance elsewhere in prose as a `Rule-Ref:` cross-mention is fine; a second **definition** is not); cross-check each new/renumbered ID has a matching Rule Enforcement Matrix row | Fail on any duplicate rule-definition ID, or a rule missing its matrix row |
| **CI script ecosystem — case-insensitive repo-name comparisons** (fixed, PR #1360, 2026-08-01 — no dedicated tracking issue; #842 is the unrelated watchdog-monitoring issue this PR's Part 1 also happened to ship alongside) | No script anywhere in `scripts/**`/`.github/**` (including inline workflow shell) compares a GitHub repository-identity value (`GITHUB_REPOSITORY`, `HEAD_REPO`/`head_repository`, `GITHUB_EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME`, `BASE_REPOSITORY`, or an equivalent) with a bare, case-sensitive `==`/`=`/`!=` — GitHub repository names are case-insensitive for identity, but the two context values feeding such a comparison are not guaranteed to agree on casing at every point in time (confirmed live during this repo's rename to `LanCache-NG`: `scripts/lib/validation-image-tag.sh`'s `vit_pr_staging_available()` and `scripts/untracked/select-build-tools-image.sh`'s fork-vs-same-repo trust check both misclassified a genuine same-repo PR as a fork PR under the old casing, one fail-closed in the safe direction and one merely wrong). Both known call sites are fixed (`${x,,}` lowercasing on both sides, per each file's own incident comment) with dedicated regression coverage: `tests/bats/validation_image_tag.bats` (2 new cases) and the new `tests/bats/select_build_tools_image.bats` (6 cases) | `bats tests/bats/validation_image_tag.bats tests/bats/select_build_tools_image.bats` (must pass, including the same-repo-different-casing case in each); as the ecosystem-wide guard against a *third* call site reintroducing this bug class elsewhere: `grep -rniE '"\$\{?[a-z_]*repo[a-z_]*\}?"[[:space:]]*(==\|!=\|=)[[:space:]]*"\$' scripts/ .github/` (deliberately no `--include` filter — a bare-`.sh` restriction would silently skip `build-push.yml`'s ~9000 lines of inline bash, the most likely place a third call site would appear). **Verified 2026-08-01, both directions**: run against the pre-fix commit (`git show 433c3fd2^:scripts/untracked/select-build-tools-image.sh \| grep -niE '...'`, same pattern) correctly flags the exact pre-fix lines (`"$head_repo" == "$repository"`, `"$head_repository" = "$base_repository"`); run against the current tree returns zero hits (both fixed call sites now use `${x,,}`, which the pattern's brace-then-bare-name shape correctly does not match) — a check that can't fail is not a check, and this one demonstrably can. No dedicated script exists for this today, so it remains a documented manual/grep-assisted check, not yet automated as its own CI job (a candidate for future consideration under `AG-VAL-028`'s periodic-reassessment recommendation, not yet acted on); every hit still needs a human glance to confirm it's a genuine repo-identity comparison and not an unrelated `repo`-substring false positive. **Explicit scope note**: this check targets shell-level (`bash`/`sh`) comparisons only, matching the two real fixed call sites. It deliberately does **not** flag the ~15 GitHub Actions expression-level `${{ github.event.pull_request.head.repo.full_name == github.repository }}` comparisons already present in `build-push.yml`/`codeql.yml` (e.g. `PR_IS_FORK`'s own definition) — checked against GitHub's own documentation (`docs.github.com`'s Expressions reference), which states plainly that `==`/`!=` string comparisons in workflow expressions are already case-insensitive ("GitHub ignores case when comparing strings"), unlike bash's `[[ ]]`/`[ ]`. Those YAML-expression comparisons are therefore not part of this bug class and are correctly out of this check's scope, not an unexamined gap in it | Fail if either bats file fails, or if the grep turns up a new case-sensitive shell-level repository-identity comparison with no `,,` lowercasing |
| **build-push.yml — pushed image commit-label matches the PR's actual current head** (open gap, no structural fix yet — incident 2026-08-01, PR #1354) | A `build`/`build-arm64` run reporting `success` genuinely built and pushed the commit it claims to, not an earlier, already-superseded commit from the same branch | Confirmed live: rapid, closely-spaced `gh pr update-branch` calls on PR #1354 left `build-push.yml` labeling the pushed `proxy` image with `org.opencontainers.image.revision=220c80f` (a superseded commit) while the run's own reported `head_sha` was already the newer `c4c0e6b6` — a real `docker inspect <image> --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'` mismatch against `gh pr view --json headRefOid`, not merely a suspected race. The only remediation applied was an empty follow-up commit to force a clean, uncontested re-run (commit `2f737bcc`) — there is no code-level guard preventing recurrence, and no dedicated tracking issue exists yet (folded into the PR's own history only). Before trusting any `build`/`build-arm64` "success" as evidence for a specific commit — especially right after any rapid sequence of `gh pr update-branch`/force-push calls on the same PR — compare the pushed image's `org.opencontainers.image.revision` label against `gh pr view <n> --json headRefOid --jq .headRefOid` (or `git rev-parse HEAD` for a push event) for that exact SHA, not just a green check mark | Fail (and re-run) if the pushed image's revision label does not match the commit under test, regardless of the workflow run's own reported conclusion |
| **Untouched-service staging back-fill — ancestor fallback for a PR base commit with no push-triggered build** (fixed, 2026-08-01) | An untouched service's back-fill genuinely succeeds once the PR base commit is POSITIVELY confirmed both to have never had a push-triggered `build-push.yml` run at all AND to have changed only paths that match that trigger's own `paths-ignore` list (the two-part proof that this was a deliberate skip, not a CI outage silently misread as one) — WITHOUT weakening the #808/#626 fail-closed guarantee for a base commit whose build genuinely failed, is stuck, or is still running, and WITHOUT the two independent copies of this recovery logic (`scripts/untracked/ensure-pr-staging-images.sh` and `build-push.yml`'s own "Ensure PR staging tags exist for full-setup services" step) drifting apart | The shared implementation now lives in `scripts/lib/staging-ancestor-fallback.sh`, sourced by both callers so a fix to one can never leave the other exposed to the same bug class: `saf_base_commit_paths_are_ignorable()` (diffs the commit against its first parent and checks every changed path against `**/*.md`/`docs/**`, with `CHANGELOG.md` explicitly excluded — the missing safety property a bare "zero runs" reading cannot provide on its own), `saf_base_commit_has_confirmed_run()` (positively confirms zero runs of a given event type before considering any fallback — any run, or an inconclusive check after retrying through `ghcr_retry`, preserves today's strict failure), and `saf_find_built_ancestor()` (bounded, `--first-parent`-only ancestor walk — `git log --max-count` at the source, never piped through `head`, to avoid a real SIGPIPE-under-`pipefail` hazard — accepting a candidate's run of any TAG-PUBLISHING trigger type (push, workflow_dispatch, schedule — not push-only, but also explicitly not pull_request: a pull_request run's `github.sha` is a synthetic merge commit, not the candidate's own commit, so it never publishes that candidate's `sha-<commit>` tag regardless of what the Actions API's `head_sha` field reports for it), reusing `sif_wait_for_fresh_base_image()` against each candidate and never skipping that freshness proof; a run-less candidate is walked past only after its own changed paths are also positively confirmed ignorable, the same proof `saf_base_commit_paths_are_ignorable()` applies to BASE_SHA itself, so a mid-walk commit that introduced a real, unbuilt change can never be silently substituted away; a candidate whose run-check itself is inconclusive fails closed immediately rather than falling through to the freshness check on an unconfirmed candidate; a candidate whose own build-push.yml run is positively confirmed still active via `saf_candidate_run_is_active()` — a real race, not hypothetical, since several commits merging in rapid succession does not mean each one's build finished before the next one's ancestor walk runs — gets exactly one retry with its own dedicated extended budget, never a blind timeout increase (AG-CI-013); an inconclusive or confirmed-not-active answer changes nothing). All GitHub API calls go through `curl` + `GH_TOKEN` directly, never the `gh` CLI, since AG-CI-001/AG-CI-002 mean `gh` cannot be assumed present on the bare `lancache-light` runner tier both real callers actually execute on — depending on it would make this whole mechanism silently unreachable there; `curl` itself is also explicitly capability-checked (`command -v curl`) rather than assumed, since AG-CI-001 does not carve out an exception for it either; `GH_TOKEN` is read directly from the environment inside `_saf_github_api_get` rather than passed as one of its own positional arguments, so it can never appear in `ghcr_retry`'s own `::warning::`/`::error::` diagnostics (which log the wrapped command's full argument list verbatim on every failed attempt); the same `curl` call also carries explicit `--connect-timeout 10 --max-time 30` bounds, so a connection GitHub accepts but then stalls mid-transfer becomes a bounded, retryable failure instead of an unbounded hang that `ghcr_retry`'s own bounded-attempts design could never even reach; and a 401 (invalid token) or 404 (wrong endpoint/repository) response is classified as a permanent, non-retryable failure via `scripts/lib/ghcr-retry.sh`'s new `GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE` convention (a wrapped command signals "retrying cannot help" by exiting with this reserved code; `ghcr_retry` returns immediately instead of exhausting its full backoff budget), while every other non-200 status (5xx, 403/429, a malformed response) stays on the ordinary retryable path exactly as before. `saf_find_built_ancestor()`'s own per-candidate run-existence lookup is also cached for the lifetime of the process, keyed by (repository, candidate) — a long docs-only ancestor chain otherwise means every untouched service independently re-walks and re-queries the identical candidate history against a shared, repository-scoped API rate limit; only a DEFINITIVE answer (a run exists, or is confirmed absent) is ever cached, never an inconclusive one, so a transient query failure for one service can never poison a later, independent query for another. This cache is deliberately scoped to ONLY the ancestor-candidate lookup, not to `saf_base_commit_has_confirmed_run()` generally — BASE_SHA's own push-run check inside `saf_resolve_untouched_backfill_source()` is independently re-derived twice on purpose (see that function's own header), specifically so a fast-path bug can only cost time, never safety, and a shared cache at a lower level would have silently defeated that guarantee. `saf_resolve_untouched_backfill_source()` orchestrates all of it, including a fast path that checks both proofs BEFORE the long freshness wait so a confirmed-deliberate skip fails/falls back in seconds rather than waiting out the full ceiling first, and takes THREE independent freshness-budget pairs rather than one shared pair: a long, congestion-scale pair for the wait against BASE_SHA's own image (the one wait in this mechanism that can legitimately be racing a real, still-building push run), a short pair for `saf_find_built_ancestor()`'s own per-candidate INITIAL checks (an already-confirmed-run historical ancestor's image either exists already or never will, so a long ceiling there only slows down every fallback for no correctness benefit — collapsing this back into the long pair would hard-fail this gate on a perfectly healthy, still-running build), and a third, separate pair governing ONLY the one-time extended retry for a candidate confirmed still active. That third pair was originally the SAME parameter as the long BASE_SHA pair (deliberately, reasoning "the same patience BASE_SHA's own possibly-in-progress build already gets") until a Codex review on this PR correctly identified that this let `build-push.yml`'s own "Ensure PR staging tags exist for full-setup services" step (inside `full-setup-validate`, `timeout-minutes: 30`) implicitly inherit a fresh, up-to-5400s (90-minute) extension it cannot survive — that job would simply be killed by its own GitHub Actions job timeout partway through the wait, never rescuing an image landing more than a few minutes into it, unlike `scripts/untracked/ensure-pr-staging-images.sh`'s own caller (`full-setup-deep-validate.yml`'s "ensure PR staging images" job, `timeout-minutes: 100`, explicitly sized for exactly this scenario). Making the extended budget its own explicit parameter lets each caller size it honestly against its own job envelope: `scripts/untracked/ensure-pr-staging-images.sh` still passes 900/5400 (its 100-minute job affords it), while `build-push.yml`'s step now explicitly passes `0 0` (this 30-minute job's own real runs are 30-71s; there is no meaningfully-sized extension that both fits its remaining budget, shared across every untouched service the loop checks, and outlasts the short budget already just tried) — a caller-scoped, principled fix, not a blind timeout bump: the extended-retry mechanism itself is unchanged and still fully benefits the caller whose job was actually built for it, while the caller that cannot afford it degrades to exactly the fail-fast behavior it already had before the mechanism existed. The mutable `nightly`/`latest` channel tags are never touched — only one immutable per-commit tag is ever substituted for another. `tests/bats/ensure_pr_staging_images.bats` gained 6 new integration cases (13→19) exercising this end-to-end through the real script (ancestor 2 commits back found and used; bounded depth genuinely stops before reaching a further-back usable ancestor; no ancestor anywhere fails closed distinctly; a confirmed run on the base commit itself preserves the existing strict failure with no fallback attempted; an inconclusive run-check is treated the same as a confirmed run; a real non-doc path change blocks the fallback even with zero push runs — the single most important regression guard for this mechanism); the new `tests/bats/staging_ancestor_fallback.bats` (55 cases) unit-tests the shared library directly, including the SIGPIPE regression, a real merge-commit fixture proving `--first-parent` is honored, curl-based retry/backoff behavior (including a non-200 HTTP status being treated as retryable, not accepted as a false zero, and a missing `curl` binary itself being treated as an explicit capability-check failure, not an assumption), non-push-run acceptance for ancestor candidates, the two-budget split (a confirmed-in-flight BASE_SHA build must resolve under the long budget even when the short ancestor-candidate budget alone would have already timed out), the same paths-are-ignorable proof applied to every skipped ancestor candidate mid-walk, not only BASE_SHA itself (a run-less candidate that itself touched a real, non-doc path must block the walk rather than let it substitute an older, unrelated ancestor), an inconclusive run-check for a candidate failing closed rather than falling through to the freshness check on an unconfirmed candidate, the ancestor-candidate build-proof query never counting a pull_request-triggered run (its github.sha is a synthetic merge commit, not the candidate's own sha, so it never publishes that candidate's sha-<commit> tag) while still stopping at the first confirmed tag-publishing event type rather than always querying all three, an unset GH_TOKEN failing closed rather than depending on a real `gh` CLI/network call, and a candidate confirmed still building via `saf_candidate_run_is_active()` getting exactly one extended-budget retry (with dedicated cases proving a confirmed-not-active or inconclusive activity check never triggers that retry, even when a longer wait would otherwise have succeeded, and a missing `curl` binary for this same activity check being treated as its own explicit capability-check failure, mirroring the identical guard in `saf_query_run_count` rather than assuming the caller already checked), a dedicated case proving `GH_TOKEN` never appears in any of `ghcr_retry`'s own retry/failure diagnostic lines (forcing every attempt to fail and asserting the token string is absent from `stderr`, not merely that GitHub's own masking would have hidden it), and a dedicated case proving the extended-retry budget is genuinely independent of the long BASE_SHA budget (a generous 300/600 BASE_SHA pair alongside a `0 0` extended pair must fail fast on a candidate that would only resolve at ~3 real seconds, proving the two are no longer silently the same value), a dedicated case proving a `0 0` extended budget still performs one genuine freshness re-check rather than none at all (a call-count-based stub reporting stale on its first invocation and fresh from the second onward must still resolve successfully via that second, extended-position check), a case proving a 401 and a case proving a 404 both fail fast on the first attempt rather than exhausting the full retry budget, and two cases proving the ancestor-candidate run-lookup cache: one proving a repeated call for the same candidate (simulating a second untouched service) hits the cache instead of re-querying, and one proving an inconclusive answer is never cached (a later, independent query for the same candidate can still succeed) — plus a case proving BASE_SHA's own intentionally-independent pre/post push-run re-derivation in `saf_resolve_untouched_backfill_source()` is unaffected by that cache (both checks still genuinely execute), and an end-to-end case with curl genuinely absent from `PATH` throughout an entire `saf_resolve_untouched_backfill_source()` call (not just a low-level function's own return code) proving the inconclusive answer this produces is never misread as a genuine confirmation: the call fails, and the "Substituting nearest built ancestor" success message that would mean the ancestor substitution fired never appears; a case proving `saf_base_commit_paths_are_ignorable()` correctly distinguishes a genuinely empty commit (a real parent, zero changed paths -- `git diff-tree` exits 0, found no differences) from a failed diff against a root commit (no parent to diff against -- `git diff-tree` exits 128), since both produce identical empty stdout and only the diff's own exit status tells them apart: the empty commit is confirmed ignorable (status 0), not inconclusive; and the mid-walk counterpart of that same fix inside `saf_find_built_ancestor()` itself, proving a run-less ancestor candidate that is itself a genuinely empty commit is walked past to an older, real ancestor instead of blocking the walk the way a genuinely unconfirmable candidate correctly still does; the Authorization header itself is no longer passed to `curl` as a literal `-H "Authorization: Bearer <token>"` argument (visible for the process's lifetime to any other process running as the same host user via e.g. `/proc/<pid>/cmdline` on a shared self-hosted runner) nor written to a mode-600 temp file (file permission bits protect against other USERS, not other processes owned by the identical UID, which could still derive the file's own path from curl's own argv and open it directly) but supplied via curl's own `-K -` (config read from stdin) as a bash here-string, which this project's own pinned bash implements as a pipe rather than a temp file, so no file containing the token's value ever exists on disk at any point; dedicated cases prove the token never appears in curl's own invoked argv (only the literal, harmless `-K -`), that the token's value never appears in any file anywhere under `$TMPDIR` (recursively, not just a specific expected path), and that the header content is genuinely fresh on every `ghcr_retry` attempt, not just the first (since `_saf_github_api_get` is re-invoked as a fresh function call, and therefore a fresh here-string, on each retry). `SAF_ANCESTOR_RUN_CACHE_DIR`'s own directory is no longer left behind unconditionally on every process that ever sources this file (mktemp's uniqueness means it is never reused by a later run, so on a long-lived self-hosted runner that leaked without bound) but removed via an EXIT trap that composes with -- rather than silently discards -- any EXIT trap the calling script had already installed for its own purposes, using `eval` (not manual prefix/suffix string slicing, which cannot correctly undo bash's own escaping for a single quote embedded in the prior trap's own command) to recover and re-chain that prior trap exactly. Dedicated cases prove: the directory's removal; a pre-existing trap's own effect still firing; a pre-existing trap whose own command contains an embedded single quote surviving the chaining byte-for-byte (verified empirically first that bash 5.2 -- the version in the pinned build-tools image -- fires its EXIT trap on SIGTERM even with no explicit TERM trap of its own); and -- under the `set -euo pipefail` both real callers use, which is the only configuration in which either half can break -- BOTH that the prior trap runs AT ALL for a failing script and that the `$?` it reads is the script's own real exit status. Those two are one property, not two: the ordering that satisfies them is invoking the prior trap FIRST and doing the cache cleanup after it. Doing the cleanup first overwrites `$?` with the cleanup's own successful `rm` (a genuine CI failure reported to the prior trap as `0`), and the obvious remedy -- capturing `$?` and restoring it via an `(exit "$captured_status")` subshell before calling the prior trap -- is strictly worse: that subshell IS a failing command, so under `set -e` it aborts the trap body and the prior trap never runs at all. Both behaviours were reproduced live on bash 5.2 (the pinned build-tools image's version) against the real library file, and the regression cases now set `set -euo pipefail` themselves for exactly this reason -- an earlier version of the exit-status case did not, and therefore passed against an implementation that silently skipped the prior trap on every real failure. Cleanup is additionally backstopped by placing the cache directory (and every API response body file) under `$RUNNER_TEMP` when GitHub Actions provides it, since no EXIT trap can survive the SIGKILL a job-timeout expiry ultimately delivers, while Actions wipes `RUNNER_TEMP` itself between jobs; a dedicated case asserts that placement. The composition's real scope is also stated rather than overclaimed in the file's own header: it composes with an EXIT trap the caller registered BEFORE the `source` line and nothing else, and no caller in this repository registers one at all today. The ancestor-candidate run-existence cache's own on-disk entries are now written via a temp file plus atomic rename rather than a direct redirection (a write that fails partway, e.g. the runner's disk filling up, can otherwise leave an empty regular file behind even with the write's own error swallowed) and validated on read to be exactly `"0"` or `"1"` (anything else, including empty, is treated as a cache miss and re-queried, not silently read as arithmetic `0` -- the single most permissive, and wrong, outcome for a failed write); a dedicated case simulates exactly that corrupted-empty-file scenario and proves a genuine re-query still happens. `saf_find_built_ancestor`'s own "validate every skipped ancestor" check no longer fails closed on a run-less candidate with a real (non-doc) path change purely because GitHub Actions' own workflow-run retention window has expired for that candidate -- this project's durable per-commit `sha-<short>` image tags (docs/release-versioning.md) are not subject to that retention, so a positively confirmed existing, correctly-labeled image for that exact candidate is now accepted as stronger, retention-independent proof of a genuine build and used directly, with the original fail-closed behavior preserved only when that image ALSO does not exist (covered by both the original negative case and a new positive case; a pre-existing integration case in `tests/bats/ensure_pr_staging_images.bats` needed its own revision stub properly scoped to the specific image tag queried, since it had never previously needed to distinguish one candidate's image query from another's) -- `scripts/untracked/ensure-pr-staging-images.sh`'s own `build_push_run_active()` congestion probe now shares that same `curl`-based query through the library's `saf_event_has_incomplete_run()` instead of keeping a second `gh api --jq` implementation of the identical question -- the last `gh`/`jq` dependency in a script that runs on the bare `lancache-light` tier, where AG-CI-001/AG-CI-002 mean a missing `gh` silently downgraded that probe to a permanent "not active" -- and `tests/bats/ensure_pr_staging_images.bats`'s #975 fixtures now stub `curl` rather than `gh`, so the real query construction stays exercised. `bats tests/bats/ensure_pr_staging_images.bats tests/bats/staging_ancestor_fallback.bats` (74 cases total, must all pass); `tests/bats/ghcr_retry.bats` gained 2 new cases (10→12) for the shared `GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE` mechanism this fix's fail-fast-on-permanent-error behavior relies on (one proving the immediate return with no retry/backoff/relogin, one proving every other exit code's existing retry behavior is unaffected); `shellcheck --severity=warning` and `actionlint` clean on the changed shell files and `build-push.yml`; as a durable, non-rotting negative control (deliberately not pinned to any one historical commit, since GitHub's workflow-run retention window means a hardcoded SHA reference here would eventually stop reflecting real state for reasons unrelated to correctness): pick the current tip of `current_dev` via `git rev-parse origin/current_dev` and confirm `gh api repos/wiki-mod/lancache-ng/actions/workflows/build-push.yml/runs?head_sha=<that sha>&event=push` returns at least one run if that commit's own diff touches a non-doc path, or reason about why it doesn't otherwise — the discriminating query shape itself (event-scoped `head_sha` lookup) is what must keep working, not any specific commit's answer | Fail if either bats file regresses (especially the "confirmed run -> no fallback" and "real path -> paths gate blocks fallback" cases, the two load-bearing fail-closed guards), if `shellcheck`/`actionlint` reports a new finding, or if the `gh api` query shape itself stops discriminating a commit with a real run from one without |
| **pipefail/SIGPIPE early-exit-consumer pattern, repo-wide** (fixed, PR #1374 + issue #1377, 2026-08-01/2026-08-05) | An early-exiting consumer (`grep -q`/`grep -m`, `head`, a `sed -n` address/substitute combined with an explicit `q`/`Q`) piped from a still-writing producer under `set -o pipefail` cannot silently fail the pipeline with an unrelated-looking exit code (141/SIGPIPE) anywhere in `scripts/**`, `tools/**`, `services/**` (including every `tools/*/Dockerfile*` and `services/*/Dockerfile*`), or `setup.sh` | Real CI job 91393831566 (run 30709307913) failed exactly this way on `rustup target list --installed | grep -qx ...` / `rustc -vV | grep -qE ...` in `tools/build-tools/Dockerfile` (PR #1374). Issue #1377 then re-ran the same detection pattern repo-wide, found 56 further locations (the codebase had drifted since PR #1374's original 41-location count), individually triaged every one, and fixed each genuine risk with the same capture-into-variable-then-here-string pattern; a handful backed by a hard tool contract for single-line/self-limiting output (`docker inspect --format` on one field of one container, `docker ps -q --filter name=^X$`, `find ... -print -quit`, one Docker `HEALTHCHECK CMD-SHELL` line that runs under the container's own `/bin/sh -c`) were marked `# pipefail-safe: <reason>` instead, since converting them would add no safety value. Also proved empirically on runner 192.168.1.229, under `set -euo pipefail`: `seq 1 200000 | head -1`/`grep -q`/`grep -m1` all reproducibly exit 141 (even a small/fast producer is not a reliable safety signal); a bare `sed -n` address/substitute with no explicit `q`/`Q` reads to EOF regardless of matches and never exits 141; a here-string (`<<<"$var"`) never exits 141 regardless of variable size, unlike `printf '%s\n' "$var" | consumer`, which can still SIGPIPE for a large enough `$var`. `bash scripts/untracked/check-pipefail-early-exit-grep.sh` (`scan_files` now repo-wide via `git ls-files`, wired into the `shellcheck`/`shellcheck-hosted` jobs in `build-push.yml`); `bats tests/bats/check_pipefail_early_exit_grep.bats` (extended with a `scripts/**`-path negative control proving the widened scope actually catches a new instance, plus confirming the real fixed tree passes) | Fail if the guard script reports a finding anywhere in its repo-wide scan, or if any negative-control bats case stops catching its reintroduced pattern |
| **Review-chronology code comments (AG-CODE-003 sub-pattern)** (2026-08-02) | No git-tracked source/config comment narrates the review chronology of the change it sits in ("caught in review", "before this fix", "flagged in review on PR #123", and similar phrasings) — these read as internal notes to the reviewer/author at PR-open time, not durable technical rationale, and go stale/confusing the moment the PR merges | `bash scripts/untracked/check-review-chronology-comments.sh` (wired into `build-push.yml`'s `file-headers` job); `bats tests/bats/check_review_chronology_comments.bats` (14 cases: 6 real-shaped positive fixtures proving the fail path is reachable per `AG-VAL-024`, including the reverse-order "a PR review (#765) found ..." shape and the self-review compound-word case; 5 deliberate near-miss negative fixtures — "manual review to notice it", "remembered during review", bare "regression pin", "after this PR merges"/"until this PR's OWN builds" — proving the tight adjacency regex does not over-match generic review/PR mentions; the excluded-file-type and self-reference-exclusion cases; and the "passes against the real repository tree" case). A real audit against this repo's own tracked files (2026-08-02) found eighteen genuine instances across fourteen files, fixed in the same pass this guard was added, so the check starts clean | Fail if the guard script reports any finding against the real tree, or if any of the 14 bats cases regresses (especially the 5 negative-fixture cases — a widened regex that starts flagging generic "review"/"PR" mentions is a false-positive regression, not an improvement) |
| **`standard-passthrough-shim` restart policy + runner-host reaper `StartedAt`-vs-`Created` blind spot** (fixed, issue #1095, 2026-08-05/06 multi-day container-leak incident) | (a) `deploy/full-setup/docker-compose.yml`'s profile-gated, per-run-only `standard-passthrough-shim` service carries no restart policy, so a crashed/killed instance stays exited instead of resurrecting itself; (b) `tools/runner-host/lancache-ci-cleanup.sh`'s `reap_orphaned_running_containers` keys its age check on each container's immutable `.Created` timestamp, not the restart-resettable `.State.StartedAt`, so a leaked container that happens to get restarted (by a crash-loop, or by Docker's own restart manager on daemon/host startup) is still reaped by its true age; (c) the same script also reaps `lancache-ng-validation-*` Docker networks left with zero attached containers after (b) removes their last container | Confirmed live on runner host `192.168.1.240` (2026-08-05): three `lancache-ng-validation-*-standard-passthrough-shim-1` containers created 2026-08-03 had survived that host's own reboot ~14h earlier and every scheduled cleanup run since, because each run's `StartedAt` read showed only the few-minutes-old post-reboot restart time (root-caused via direct `journalctl -u lancache-ci-cleanup.timer/.service` + `docker inspect` inspection over SSH, not log-reading alone) — the same host's own two other genuinely-active validation containers (created within the last hour) were correctly left alone throughout, proving the discrimination held even before the fix. The `.Created`-keyed fix was proven both ways in dry-run mode against this exact real state (`DRY_RUN=1`: the 2-day-old three flagged "WOULD REAP", the young one correctly kept), then run for real (`DRY_RUN=0`) to reap the three real orphans, confirmed gone afterward via `docker ps -a`. The network reap was proven via a real, disposable `lancache-ng-validation-99999_validation` network + container on runner host `192.168.1.243`: kept while a container was attached (0 removal), reaped once that container was removed (0 attached containers) — both directions demonstrated live, not just read from the code. `deploy/full-setup/docker-compose.yml`'s edited service was validated with a real `docker compose --profile ssl-mitm-proof config` (resolves to `restart: 'no'`, not the YAML boolean `false`) and a real `docker compose ... up -d --no-deps standard-passthrough-shim` on `192.168.1.243` (`HostConfig.RestartPolicy.Name=no`, container reaches `Health=healthy`), then torn down cleanly. `bash -n`/`shellcheck --severity=warning` clean on `tools/runner-host/lancache-ci-cleanup.sh` inside the pinned build-tools container | Fail if a future orphaned `lancache-ng-validation-*` container survives a runner-host reboot past `REAP_VALIDATION_AFTER_HOURS` (i.e. if the age check is ever changed back to a restart-resettable signal), if `reap_orphaned_validation_networks` ever removes a network reporting a nonzero attached-container count, or if `standard-passthrough-shim` (or any other genuinely throwaway, profile-gated validation service added later) regains a `restart:` policy other than `"no"` without a stated, reviewed reason |
| **Proxy cache env/doc drift — CACHE_MEM_MB (bug-hunt #849/#1068 item 11)** (fixed, 2026-08-05) | `docs/architecture-ng.md`'s nginx cache-configuration table's documented default for each `CACHE_*` variable stays in sync with the real shipped default in `config/prod/proxy.env` | Confirmed live via `git log` that `CACHE_MEM_MB`'s documented default (`200`) had been wrong for ~7 weeks — the real shipped default (`config/prod/proxy.env`, `deploy/quickstart/.env`, `setup.sh`) has been `512` since the variable was introduced 2026-06-18/19. Fixed the doc and added `bash scripts/untracked/check-proxy-cache-env-doc-drift.sh` (wired into `build-push.yml`, same job as the setup-prompt-drift/logging-matrix doc guards), which parses every `CACHE_*=value` line in `config/prod/proxy.env` and, for each one with a matching table row in `docs/architecture-ng.md`, fails if the documented default disagrees with the real one. Verified both directions on runner host `.241`: passes cleanly against the real tree (7 of 7 documented `CACHE_*` variables matched); a negative control reintroducing the exact historical drift (`CACHE_MEM_MB=200` in a scratch copy of `proxy.env`, doc left at `512`) reproducibly fails with the specific mismatched key/values named | Fail if the guard script reports a finding against the real tree, or if the negative control (reintroducing a `CACHE_*` value mismatch) stops being caught |
| **Proxy stream-level client ACL** (fixed, 2026-08-06/07) | `PROXY_ALLOWED_CLIENT_CIDRS` genuinely restricts which client IPs may open a TCP connection to EITHER externally-facing stream-level listener — the standard-mode `:8443` SNI-passthrough listener, and the SSL-mode `:443` SNI dispatcher — not just the `http`-context `geo`/`map`-driven `$lancache_client_allowed` check inside the MITM/passthrough relays, which never runs for a client the stream layer itself should have rejected before `ssl_preread` ever extracts an SNI. The generated ACL (`entrypoint.sh`'s `_render_stream_client_acl`, `/etc/nginx/stream.d/access.d/00-stream-client-acl.conf`) must apply to both external listeners, never to the internal loopback-only MITM/passthrough relay hops the SSL-mode dispatcher hands off to (those must stay reachable from 127.0.0.1 regardless of the configured CIDR list, or the relay chain itself breaks) | `bats tests/bats/proxy_stream_client_acl.bats` (4 cases) proves the generated config text; the following differential live proof is what actually proves nginx *enforces* it (bats alone only proves generation) — run two real `proxy` containers, one with `PROXY_ALLOWED_CLIENT_CIDRS` unset (default: no restriction) and one with it set to a CIDR that excludes the test client's own address: **(A) SSL-mode `:443` dispatcher** (`SSL_ENABLED=1` on both): (1) against the unrestricted container, `openssl s_client -connect <host>:443 -servername <a configured CDN domain>` extracts the SNI and proceeds to an upstream-resolution attempt (fails only for the unrelated, expected reason that the sandbox has no real upstream DNS for that domain — this is the "allowed" baseline, not a false pass); (2) against the restricted container from an excluded address, the same command is rejected instantly at the TCP layer (`access forbidden by rule`/connection reset) with the SNI never reaching `ssl_preread` at all — the stream access log shows the deny, not a `ssl_preread` failure. **(B) standard-mode `:8443` listener** (either `SSL_ENABLED` value): the identical allowed-vs-excluded differential, `openssl s_client -connect <host>:8443 -servername <a configured CDN domain>` in place of `:443` — this is nginx.conf's own static `stream {}` block, generated independently of "2a."'s SSL-mode dispatcher, so passing (A) proves nothing about (B) or vice versa; both must be run. The instant-403-vs-SNI-extracted distinction is what discriminates a real ACL enforcement from an unrelated connectivity failure; a naive single fixed-timeout comparison between the two cases is **not** sufficient (an early version of this check used one timeout for both cases and produced misleadingly identical-looking results). A second, separate live check proves the SSL-mode scoping specifically: with `PROXY_ALLOWED_CLIENT_CIDRS` set to a CIDR that includes the test caller (e.g. `127.0.0.0/8`), `openssl s_client -connect 127.0.0.1:443 -servername <a covered domain>` must still complete a TLS handshake presenting the container's own `CN=lancache-ng` MITM certificate — proving the ACL, scoped to `stream.d/access.d/`, was correctly kept off the two internal 127.0.0.1-only relay server blocks the dispatcher hands off to, not merely reasoned about | Fail if an excluded client's connection is not rejected before SNI extraction on EITHER listener, if an included client's request is wrongly rejected on either, or if the internal-relay handshake in the SSL-mode-scoping check fails to complete (proof the ACL leaked onto a loopback-only relay hop) |

**Gap closed (2026-08-05, issue #1377):** the guard above was previously scoped to only scan `tools/build-tools/Dockerfile` -- the one file PR #1374's confirmed incident occurred in -- with a documented, tracked gap covering the rest of the repository. Issue #1377 closed that gap: `scripts/untracked/check-pipefail-early-exit-grep.sh`'s `scan_files` now discovers every tracked shell script under `scripts/**`/`tools/**`/`services/**` plus `setup.sh`, and every `tools/*/Dockerfile*`/`services/*/Dockerfile*`, via `git ls-files`, so a newly added script or service Dockerfile is covered automatically rather than needing this list hand-maintained. (Corrected 2026-08-08: `services/**` Dockerfiles were initially left out of this widened scope even though the real-incident shape this guard exists to catch was still present, unscanned, in `services/ui/Dockerfile` and `services/dns/Dockerfile` -- both fixed with the same capture-into-here-string pattern once found.) See the Standing check row above for what was found and fixed.

**New Standing check row, added out of table-row order on purpose (2026-08-06/07, bug-hunt #849, PR #1472)** -- inserted here rather than immediately after the CACHE_MEM_MB row above, specifically so this addition doesn't land on the exact same anchor line as `fix/849-proxy-stream-sni-hardening`'s sibling N1 row and force an avoidable merge conflict between two sibling PRs touching the same file in the same pass:

| Subsystem | What to check | How to check it for real | Pass/fail |
|---|---|---|---|
| **Proxy `/healthz` unauthenticated-probe ACL — finding #11 (bug-hunt #849, PR #1472)** (fixed, then corrected, 2026-08-06/07) | `conf.d/http.conf`'s and `conf.d/https.conf`'s `location = /healthz` blocks genuinely reject a source outside `127.0.0.1/32`/`172.16.0.0/12`, not merely contain `allow`/`deny` text that looks correct | **A real bug was caught here, not just prevented**: the fix's first version served the body via a bare `return 200 "ok\n";` in the SAME location as the `allow`/`deny` directives. `bats tests/bats/proxy_healthz_acl_and_hidden_headers.bats`'s static grep-based assertions all passed against that version — they only check the ACL text is present, never that nginx enforces it. A real differential live-container test caught what the static test couldn't: two real `proxy` containers built from this branch, one queried from a genuinely excluded source (a second container on a dedicated Docker bridge network outside both allowed CIDRs, confirmed via a throwaway `$remote_addr`-echoing location that this was really the TCP peer address nginx saw, not an assumption) — that version returned **200 to every source, including the excluded one**. Root cause, confirmed in isolation on a stock, unmodified `nginx:1.27-alpine` image (not specific to this project's build): `return` is an `ngx_http_rewrite_module` directive that runs in nginx's rewrite phase, which executes **before** the access phase `allow`/`deny` are evaluated in — a bare `deny all;` alone in a fresh location correctly returned 403 in the same test rig, but the identical `deny all;` alongside a `return` in the same location returned 200 regardless of source. The corrected version serves the body via `alias` to a real file (`entrypoint.sh`'s own "3a." step generates `/etc/nginx/lancache-healthz-body.txt` at startup) — `alias` uses `ngx_http_static_module`'s content-phase handler, which runs *after* the access phase. Re-verified live after the fix, all four real call paths: (1) the exact Compose healthcheck commands (`curl -sf http://127.0.0.1/healthz`, `curl -ksf https://127.0.0.1:8445/healthz`, both via `docker exec` to match how Docker's own `HEALTHCHECK` actually invokes them inside the container's network namespace) both return `200`/`ok`; (2) a request from the same dedicated-network excluded source now correctly gets `403`; (3) a request from a Docker-bridge-range address (`172.17.0.2`, inside the allowed `172.16.0.0/12`) still gets `200`/`ok`, proving the fix didn't over-restrict the legitimate inter-container/gateway-probe case; (4) re-checked with `SSL_ENABLED=0` too (the port-80-only deployment mode, not exercised by the first three checks) -- `/healthz` still returns `200`/`ok` there, and the generated body file itself is `644 root:root` (world-readable, so the nginx worker user reading it as a non-owner/non-group process is not a permission-denied path that could be mistaken for the ACL's own 403). `tests/bats/proxy_healthz_acl_and_hidden_headers.bats` gained 2 new cases asserting the location bodies use `alias` and contain no `return`, so a regression back to the exact broken shape is caught statically even without a live-nginx harness (this project's `build-tools` image has no `nginx` binary, confirmed via `which nginx`/`nginx -v` both failing inside it — a real `nginx -t`/live-request CI harness for this remains a documented gap, not yet automated) | Fail if a genuinely excluded source ever gets `200` from either `/healthz` location, if a genuinely allowed source (loopback, Docker-bridge-range, or `SSL_ENABLED=0` mode) ever gets a non-`200`/wrong body, or if either bats file's `alias`/no-`return` assertions regress |

---

## Part B — Stack Test Plan

Full end-to-end scenarios against the actually-running system on a real Docker host
(the Windows authoring/CI-orchestration environment cannot build or run this stack —
use a real Linux host, e.g. over SSH to a self-hosted runner, per
`.github/AGENTS.md`'s build-tools-container contract and the recurring
"no local Windows testing" note in prior validation passes).

### 1. Bring-up

- **Real `setup.sh install` bring-up is the correct starting point for `deploy/quickstart`,
  not a direct `docker compose up` (confirmed real bug, issue #1391, 2026-08-05).**
  `install_quickstart_compose_assets()` (`setup.sh:1595-1621`) is what actually populates
  `deploy/quickstart/scripts/untracked/docker-socket-proxy.sh` and
  `deploy/quickstart/scripts/lib/shared-secret-bootstrap.sh` — a path a plain `git clone`
  does not carry at all (`deploy/quickstart/` only tracks `.env` and
  `docker-compose.yml`). Confirmed live in the 2026-08-02 pass and re-confirmed by static
  audit: without that step, Docker's own bind-mount auto-vivification silently creates an
  **empty directory** at that path instead of failing, which breaks `docker-socket-proxy`
  (its own `entrypoint:` *is* the missing file) and `nats` (which sources the missing file
  to generate its own config) — both crash-loop. **The `docker compose up` command itself
  still exits 0** — the failure only shows up later as a crash-looping container, so a
  validator relying on the `up` exit code alone will not see it; check `docker compose
  ps`/`docker inspect --format='{{.State.Health.Status}}'` per container instead. This is
  `deploy/quickstart`-specific: `deploy/prod` reaches the same two files via a path
  (`../../scripts/...`) that already exists in a real checkout, so it does not break this
  way. `deploy/quickstart/docker-compose.yml`'s own header comment documents a "manual"
  bring-up path with no warning about this trap — do not follow it verbatim for a Part B
  pass.

  **Recommended real bring-up sequence (documented here, not yet executed live as part of
  this pass — see Coverage Assessment):**
  1. On a real Linux host with Docker + Compose v2 and `expect` installed, derive the
     current real prompt sequence with `bash setup.sh list-prompts <answers-file>`
     (introspective — no root or Docker required, `setup.sh:3617-3621`/`6030-6047`).
  2. Feed that sequence into the same `expect`-based driving mechanism
     `scripts/untracked/simulations/setup-cli-simulation.sh` already uses in CI (`build_expect_prompt_block`,
     that script's own lines ~237-316) to run `bash setup.sh` for real (`install` is the
     default action with no subcommand, `setup.sh:3607-3609` — a real install run needs
     root, `setup.sh:6160-6161` enforces `[[ "$(id -u)" = "0" ]]`). Set
     `LANCACHE_IMAGE_CHANNEL`/`LANCACHE_IMAGE_TAG` only as a per-command env prefix on this
     one invocation, never exported process-wide, so it cannot leak into a later
     update/migration phase that should read the channel back from the written `.env`.
     Prefer a non-loopback `IP_STANDARD` (e.g. `127.0.0.2`) to avoid port contention with
     other work on a shared runner (the same reasoning `scripts/untracked/simulations/setup-cli-simulation.sh`
     already documents for itself).
  3. Expect `Stack started` as the success marker (`Failed to pull required container
     images` as the documented failure case).
  4. Only then run this section's remaining bring-up checks (`docker compose ps` health,
     etc.) against the resulting `<install_dir>` — this is the point where a real Part B
     pass would confirm `install_quickstart_compose_assets()` actually ran and
     `docker-socket-proxy`/`nats` are healthy, in direct contrast to the broken direct
     `docker compose up` path described above.
- **Profile choice**: `deploy/quickstart/docker-compose.yml` for
  the profile that most closely matches what `setup.sh install` actually produces for
  an operator (this is also the only profile the Admin UI's cache-resize convergence
  loop, PR #1174, actually reaches — see Part A); `deploy/prod/docker-compose.yml`
  when specifically validating prod-only divergences (e.g. the cache-resize
  misleading-display gap). `deploy/full-setup/docker-compose.yml` is CI's own
  self-contained validation harness, useful for reproducing exactly what
  `full-setup-validate.yml`/`full-setup-deep-validate.yml` do locally. (There used to
  be a `deploy/dev/docker-compose.yml` fourth option here; it was retired in v0.3.0,
  #766 — every remaining profile above references images by `image:`, not `build:`,
  so there is no compose-level `--build` shortcut; see `CONTRIBUTING.md`'s "Building
  the full stack" for exercising local source changes against these profiles.)
- Bring up: `docker compose -f deploy/<profile>/docker-compose.yml up -d`.
  Confirm every service reaches `healthy` (`docker compose ps`) within a reasonable
  window — `docker inspect --format='{{.State.Health.Status}}' <container>` for any
  service whose Compose `ps` summary looks ambiguous.
- **Formerly known `deploy/dev`-only bring-up flake (issue #1215, confirmed live/reproduced
  3/3, 2026-07-24) — moot as of v0.3.0's dev-folder retirement (#766).** `deploy/dev`'s
  custom `lancache` bridge network gave some services a static `ipv4_address` but left
  others to Docker's dynamic IPAM pool in the same subnet with no `ip_range` carve-out,
  causing an intermittent `Address already in use` failure. This paragraph is kept only as
  a historical pointer for anyone who finds #1215 referenced elsewhere — the file this bug
  lived in (`deploy/dev/docker-compose.yml`) no longer exists, so the bug cannot recur.
  `deploy/quickstart`/`deploy/prod`/`deploy/full-setup` never had this custom bridge
  (confirmed at the time #1215 was filed) and remain unaffected.
- **Image-freshness trap (confirmed live, 2026-07-24; local-build guidance updated for
  v0.3.0's dev-folder retirement, #766):** `deploy/quickstart`/`deploy/prod`/`deploy/full-setup`
  all **pull** published `${LANCACHE_IMAGE_REGISTRY}/.../<service>:${LANCACHE_IMAGE_TAG}`
  images (default tag `latest`, or `nightly` if you set it) — these channel tags can lag
  the commit under test by a large number of commits (confirmed live: `nightly` was 29
  commits behind this same v0.3.0 commit, missing every feature merged that day) because
  the promote pipeline can be backlogged. Before trusting a pulled-image validation run as
  evidence for a specific commit, check the image's own revision label —
  `docker inspect <image> --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'`
  — and confirm it descends from the commit under test; if it doesn't (or the tag doesn't
  exist yet for that commit), either build locally instead (build the specific service
  directly, matching how CI itself builds first-party images and how `CONTRIBUTING.md`'s
  "Building the full stack" documents exercising local source changes, e.g.
  `docker build -t ghcr.io/wiki-mod/lancache-ng/dns:<local-tag> services/dns` with the
  matching `BUILD_TOOLS_IMAGE`/`additional_contexts` build args that service's Dockerfile
  needs, then point `LANCACHE_IMAGE_TAG` at `<local-tag>`) or wait for a fresh
  `build-push.yml` run against that exact commit. This applies to
  `scripts/untracked/simulations/*-simulation.sh` invocations too —
  `nats-secondary-auth-callout-simulation.sh` and
  `syslog-forwarding-simulation.sh` both default `LANCACHE_IMAGE_TAG` to a mutable channel
  and need the same treatment; the DHCP simulation scripts
  (`dhcp-kea-lease-flow-simulation.sh`, `dhcp-proxy-pxe-simulation.sh`,
  `dhcp-relay-flow-simulation.sh`) are unaffected — they always `docker build` their own
  images directly from the checked-out source, never from a registry tag.
- Tear down after the full pass: `docker compose -f deploy/<profile>/docker-compose.yml
  down -v`, and confirm via `docker ps -a` and `docker volume ls` that no stack
  containers or named volumes remain (see the Resource-Leak section below — this is
  itself the first, simplest instance of that check).

### 2. DNS resolution — both modes

- **Example-domain caveat (confirmed live, 2026-07-24):** not every domain in
  `services/dns/cdn-domains.txt` resolves publicly from every validation host/network path
  — `steamcontent.com`/`content1-5.steampowered.com`/`lancache.steampowered.com` returned no
  answer at all from one real validation host even via `8.8.8.8` directly (not a proxy
  problem, confirmed by querying public DNS with no proxy involved). If your chosen example
  domain doesn't resolve, don't treat that as a proxy/DNS-spoofing failure — pick a
  different entry from the same file (`download.epicgames.com` and `deb.debian.org` were
  confirmed reachable and were used for this pass's evidence) before concluding anything is
  broken.
- **Standard mode**: `dig @<IP_STANDARD> steamcontent.com` (or any
  configured CDN domain) resolves to the proxy's IP. Confirm the TLS handshake for
  that domain is **passthrough** (no interception) — `openssl s_client -connect
  <proxy>:443 -servername steamcontent.com` and confirm the presented certificate is
  the real CDN's own cert, not this project's CA. **Port correction (2026-08-05,
  issue #1391):** a prior version of this document named `:8443` here — that is
  only the container-**internal** listener port; every real deployment profile maps
  it to the standard HTTPS port externally (`deploy/quickstart/docker-compose.yml`
  and `deploy/prod/docker-compose.yml` both publish `${IP_STANDARD}:443:8443`,
  confirmed directly against both files, 2026-08-05) — `:443` is what an operator or
  validator actually connects to from outside the container.
- **SSL/MITM mode**: same `dig` against the SSL DNS instance; `openssl s_client
  -connect <proxy>:443 -servername steamcontent.com -CAfile
  deploy/<profile>/certs/ca.crt` and confirm the presented certificate **is** signed
  by the project's own CA (proves interception is actually happening, not merely
  configured). **CA-path correction (2026-08-05, issue #1391):** a prior version of
  this document referenced a bare `certs/ca.crt`, which does not exist at the repo
  root. Confirmed directly (2026-08-05): every deployment profile's proxy service
  mounts `./certs:/etc/nginx/ssl/ca` (relative to the profile's own
  `docker-compose.yml`, per this document's own `AG-VAL-010` note on Compose `.env`/
  path resolution), and the CA is generated into that same directory on first start
  — so the real path, run from the repo root, is `deploy/<profile>/certs/ca.crt`
  (e.g. `deploy/quickstart/certs/ca.crt` for a quickstart bring-up), never a
  repo-root `certs/ca.crt`. Using the wrong path fails `openssl verify`/`s_client`
  with a misleading error that looks like broken interception but is only a wrong
  path.
- `ping`/`ss` alone are not acceptable substitutes for either check (`AG-VAL-019`/
  `AG-VAL-020`) — a real query/response or a real TLS handshake is required.
- **Wildcard/subdomain scope semantics (open gap, not yet closed by this pass —
  issue #1391):** the checks above only ever resolve one literal domain per mode;
  they never prove `AG-OP-015`'s scope rule (a leading-dot `cdn-domains.txt` entry is
  an explicit wildcard scope, not equivalent to the root domain) against the live
  resolver itself. Note this is narrower than it first looks: the **proxy** layer's
  half of this same rule (which cert/backend gets selected once a request already
  arrived) already has real, negative-controlled, handshake-level proof —
  `scripts/untracked/simulations/proxy-deep-wildcard-tls-simulation.sh` and
  `scripts/untracked/simulations/proxy-standard-mode-sni-routing-simulation.sh` (both wired into
  `full-setup-sims.yml`, see issues #1272/#1297). What remains genuinely untested is
  the **DNS** layer specifically: does `dig` against a wildcard-only (`.example.com`)
  scope's bare root correctly *not* resolve to the proxy (RPZ should not match it),
  while a subdomain of it (`sub.example.com`) correctly *does*? A live pass still
  needs to pick one wildcard-only and one bare-exact entry from
  `services/dns/cdn-domains.txt` (or a scratch entry) and `dig` all three of: the
  wildcard scope's own bare root, a subdomain under it, and an unrelated
  non-matching domain — asserting the first does not resolve to the proxy unless
  also separately listed, the second does, and the third does not. Not run as part
  of this pass; tracked for the live-stack follow-up milestone.

### 3. DHCP — all three modes

- **Kea**: real DHCPDISCOVER→DHCPOFFER→DHCPREQUEST→DHCPACK cycle via
  `dhcp-kea-lease-flow-simulation` (or its underlying script run directly), confirm a
  real lease was granted from the configured pool and is visible via Kea's Control
  Agent API. Also run **`dhcp-kea-ctrl-agent-mutation-simulation`** (a static
  reservation added via the Admin UI genuinely affects a subsequent real lease) and
  **`dhcp-kea-ui-rollback-simulation`** (the Admin UI's own Kea-rollback route
  genuinely restores an earlier real snapshot) — added to this document 2026-08-05
  (issue #1391 audit); both already existed and were CI-wired, just never referenced
  here. See Part A's new row for the exact mechanism.
- **dnsmasq ProxyDHCP**: real PXE boot-option probe via
  `dhcp-proxy-pxe-simulation`/`tools/pxe-client-probe` (the Rust PXE probe rewritten
  in PR #1159), confirm the expected boot filename/next-server options are actually
  injected on the wire.
- **dnsmasq relay** (new): `bash scripts/untracked/simulations/dhcp-relay-flow-simulation.sh` — see Part A's
  entry for the exact mechanism; this is the canonical reusable proof, run it as-is
  rather than re-deriving a new one.
- Confirm the three modes are genuinely mutually exclusive at the config-render level
  (`DHCP_MODE` selects exactly one rendered `dnsmasq`/Kea config) — inspect the
  rendered config inside the running container, not just the env var.

### 4. Cache hit/miss — HTTP and HTTPS

- Request a real CDN file through the proxy twice; confirm the second response is a
  cache **HIT** (`$upstream_cache_status` in nginx's access log, or an
  `X-Cache-Status` header if configured) and that response bytes are byte-identical
  between the miss and the hit.
- Confirm the cache key genuinely ignores query-string signatures
  (`AG-OP-001`/`AG-OP-012`): request the same path with two different query strings,
  confirm both hit the same cache entry (second request is a HIT even though the
  query string differs).
- **Correction (confirmed live, 2026-07-24, against v0.3.0/commit 88ddbf6a): standard-mode
  HTTPS is NOT cached, and this is not testable as a HIT/MISS check at all.** A prior
  version of this document claimed standard-mode passthrough HTTPS "should still cache"
  because "SNI-routed connections still terminate at nginx's `stream` block only for the
  TLS layer" — that premise is wrong. Per `CLAUDE.md`'s own architecture section, standard
  mode's `stream` block uses `ssl_preread` to read the ClientHello's SNI **without
  terminating TLS at all**; it then blindly forwards the still-encrypted bytes straight to
  the real origin (`proxy_pass` in the `stream` context). nginx never sees plaintext HTTP
  on this path, so it cannot apply `proxy_cache` and cannot add `X-Cache-Status` (confirmed
  live: a real request through the standard-mode HTTPS port returns the origin's own
  `Server` header directly, e.g. `Server: Apache` for a real mirror, with no
  `X-Cache-Status` header at all — compare against the passthrough certificate proof two
  bullets above, which already demonstrates the same blind-forward behavior at the TLS
  layer). Only **HTTP** is cached in standard mode. Do not attempt a HIT/MISS proof against
  standard-mode HTTPS — there is nothing to observe.
- SSL/MITM-mode intercepted HTTPS **is** cached (confirmed live: a real MISS-then-HIT with
  byte-identical bodies, same as the HTTP case above) — nginx genuinely terminates TLS here,
  so the request reaches the normal HTTP proxy/cache layer. Confirmed also that the cache is
  shared across all three reachable paths (standard-mode HTTP, SSL/MITM HTTP, SSL/MITM
  HTTPS) since the cache key is `$host$uri` regardless of scheme or which mode's listener
  received the request — a request already cached via one path can come back as an
  immediate HIT via a different path for the same host+URI.

### 5. NATS — full secondary lifecycle, incl. today's new mechanisms

Run `scripts/untracked/simulations/nats-secondary-auth-callout-simulation.sh` end-to-end (this single script
already covers, per PRs #1172/#1168's own extensions to it): registration with
distinct per-secondary credentials, isolation between two secondaries, credential
rotation invalidating the old credential, **active disconnect** of an already-live
connection on remove/rotate (verified via `connz` polling, not the HTTP response),
and **xkey-encrypted** auth-callout traffic (verified via packet capture with a
negative control). See Part A's NATS rows for the specific pass/fail criteria on each
sub-mechanism — this section is the "run it as one real end-to-end pass" framing,
Part A is the "what does each individual claim need to prove" framing.

Also run `scripts/untracked/simulations/ui-nats-dns-integration-simulation.sh` (added to this document
2026-08-05, issue #1391 audit — already existed and was CI-wired, just never
referenced here) — a genuinely different NATS function than the secondary-lifecycle
script above: proves the Admin UI → NATS → `nats-subscriber` → PowerDNS DNS-sync
propagation path end-to-end via a real `dig`, both for creation and removal.

### 6. Admin UI — reachability, dashboard, and today's new controls

- Reachability: `curl -u <user>:<pass> http://<ui host>:<port>/` (or confirm the
  fail-closed `Admin-UI authentication is required` restart-loop behavior is what you
  expect if `UI_AUTH_USER`/`ALLOW_INSECURE_UI` isn't configured — `AG-SEC-001`: this is
  intended security behavior, not a broken build).
- Watchdog health-dashboard card (new): see Part A's entry — the green→red→green
  live-transition proof, driven by an actual container stop/start, is the standard.
- Cache-resize control (new): see Part A's entry — the `nginx -T` rendered-config
  proof, not a `200 OK`.

### 7. Watchdog — auto-restart coverage

- Confirm coverage matches the **documented, deliberate** per-service decision table
  from PR #1167 exactly (`docs/architecture-ng.md`'s Watchdog section): `proxy`,
  `dns-standard`, `dns-ssl` (SSL-mode only), and `nats` (new) are monitored/restarted;
  `ui`, `dhcp` (Kea), `dhcp-proxy` (dnsmasq), `netdata`, `syslog`/`syslog-ng` are
  deliberately **not** — each for a distinct, documented reason (allowlist gaps for
  `ui`/`dhcp`, no meaningful healthcheck defined for `dhcp-proxy`/`netdata`, no fixed
  `container_name` for `syslog`). Do not treat an unmonitored service in this list as
  a regression — check `docs/architecture-ng.md`'s table before filing anything.
- For `nats` (the only single-process monitored service), repeat the hung-not-crashed
  proof pattern from Part A's NATS-monitoring row (external `SIGSTOP`, not an
  in-container one) and confirm a genuine restart (new `StartedAt`).
- **For `proxy`, `dns-standard`, and `dns-ssl` (multi-process containers), use
  `docker top <container> -o pid` then `kill -STOP` every listed PID from outside
  the container (root/`sudo`), instead of `--signal=STOP` on the container** — see
  Part A's "hang-simulation technique for multi-process monitored services" row
  (corrected, issue #1391, 2026-08-05) for why `--signal=STOP` cannot produce a
  real hang on these services, and for the empirical evidence that this
  multi-PID technique produces a genuine, timeout-based failing probe where
  `docker pause` (considered and rejected — see that row) does not. **Not yet
  re-run against the real running stack as of this pass** (tracked as a
  live-stack follow-up, issue #1391): `dns-standard` was previously tested via
  `docker stop` (a crash, not a hang) and `dns-ssl` was not tested at all in the
  2026-08-02 pass; both, plus `proxy`, need a real pass with this technique
  against the actual images, confirming a real `FailingStreak` increase from a
  timed-out probe (not just a `Status` flip) and a genuine watchdog-triggered
  restart (new `StartedAt`).
- Known open, non-blocking gap (#1166, surfaced during #1167's own live validation):
  `restart_container()`'s `CURL_MAX_TIME` (default 5s) can be shorter than Docker's
  own restart grace period (10s) for a container slow to respond to SIGTERM, producing
  a spurious `WARNING: restart call failed` log line even when the restart actually
  succeeds a few seconds later. If you see this, cross-check `docker inspect
  --format='{{.State.StartedAt}}'` before concluding the restart genuinely failed —
  this is a known, separately-tracked cosmetic-log bug, not (yet) a real functional
  failure.

### 8. Central logging / syslog forwarding

- The `logging` profile is on by default since issue #1343 (a real opt-out remains
  via `LOGGING_ENABLED=0`, not an opt-in feature) — confirm real log lines from a
  monitored service actually arrive at the `syslog-ng`/fluent-bit target, not just
  that the containers are up. `syslog-forwarding-simulation` (part of
  `full-setup-deep-validate.yml`) is the reusable proof for this — invoke it directly
  or via `gh workflow run` rather than re-deriving a new check.
- **UPDATED (syslog+fluent-bit consolidation PR, 2026-08):** `syslog` and
  `syslog-ng` are no longer two separate containers -- they are one combined
  container (`services/syslog/`) running both processes, under the single
  Compose service name `syslog`. Its healthcheck
  (`services/syslog/healthcheck.sh`) is no longer a binary-presence-only
  check: it verifies fluent-bit AND syslog-ng independently (a real
  `syslog-ng-ctl stats` probe against the control socket, plus a
  cmdline-based process check for fluent-bit) and only reports healthy when
  both are, writing a structured status file
  (`/var/lib/lancache-syslog-data/health-status.json`, including a
  `data_loss_alert_active` field). Still validate the pipeline directly (a
  real log line arriving at the target) in addition to trusting this
  healthcheck, per `AG-VAL-023`'s netdata precedent -- a real check on top of
  a real check is the point, not a contradiction.
- **Standing check (AG-VAL-029, added by issue #1343):** `scripts/untracked/simulations/setup-cli-simulation.sh`'s
  Phase 1 now asserts, after a default fresh install (every wizard prompt answered
  with its default), that `.env` contains `LOGGING_ENABLED=1`, that `COMPOSE_PROFILES`
  includes `logging`, and that the real `syslog` container (the combined
  fluent-bit+syslog-ng container since the consolidation PR above) is actually
  running — guarding against a regression back to the bug this issue fixed (central
  logging silently never starting on a normal install). This runs as part of the same
  CI job the rest of this section already points at (`setup-cli-simulation` in
  `full-setup-sims.yml`), not a new standalone check.
- **Standing check (AG-VAL-029, added by the syslog+fluent-bit consolidation
  PR, 2026-08 -- real confirmed bug):** the combined `syslog` container ships
  a periodic silent-data-loss detector (`services/syslog/data-loss-detector.sh`,
  invoked from `entrypoint.sh`'s detector loop) comparing syslog-ng's own
  "processed" stats counter against real bytes landing on disk under the
  syslog-ng log root. This guards against a real, live-reproduced bug: a
  bind-mounted log-root directory left root-owned (Docker's own default when
  the host directory does not already exist before first container start)
  silently swallows every message a non-root syslog-ng receives --
  `syslog-ng-ctl stats` still increments its `processed` counter and
  syslog-ng logs no error at all, while zero bytes ever reach disk. Verified
  live on a self-hosted runner (see the PR body for the exact reproduction
  commands): the detector correctly fires (`processed_delta=1
  bytes_delta=0`, non-zero exit) against the broken condition and stays
  silent (`bytes_delta=71`, exit 0) against a matched, correctly-owned
  control run delivering the same message. `setup.sh` also now pre-creates
  and chowns this directory on fresh install specifically to prevent the
  condition from occurring in the first place (see setup.sh's own "Creating
  directories" step); this detector is the defense-in-depth backstop for an
  install that predates that fix, skipped the fix (e.g. a from-scratch
  manual deploy without running setup.sh), or has its permissions changed
  later.

### 9. Resource-Leak / Cleanup Pass (standing check, run every release)

Framing note: this project is written in Rust (memory-safe), so the classic
C-style heap-leak question does not apply the same way. The resource-leak concern
that **does** apply, and must be checked explicitly every release, is whether
processes, containers, connections, and file descriptors are actually released when
a service is removed, rotated, or restarted — not merely that the API call that
triggered the removal/rotation/restart returned success.

| What to check | How to check it for real | Pass/fail |
|---|---|---|
| A removed/rotated NATS secondary's live connection is actually gone, not just access-revoked | Reuse `scripts/untracked/simulations/nats-secondary-auth-callout-simulation.sh`'s `connz`-polling pattern from PR #1172: after removal, poll `nats-server`'s own `connz` HTTP monitor endpoint until the connection entry disappears — do not stop at the HTTP 200 from the removal API | Fail if the connection lingers in `connz` past a reasonable poll window |
| Watchdog-restarted containers leave no orphaned process/connection from the pre-restart instance | After a watchdog-triggered restart (Part B §7), `docker exec <host or a diagnostic container> ss -tnp` (or `netstat -tnp` if `ss` is unavailable) targeting the restarted service's port, confirm no stale connection to the old container's now-dead PID remains | Fail if a stale ESTABLISHED/CLOSE-WAIT connection to the pre-restart process persists |
| `docker compose down -v` genuinely removes every container and named volume for the stack | `docker ps -a --filter "name=lancache"` and `docker volume ls --filter "name=lancache"` immediately after teardown — both must return empty | Fail if any lancache-prefixed container or volume remains |
| A resized/rotated proxy container (cache-resize, PR #1174) doesn't leave the old container running alongside the new one | `docker ps --filter "name=lancache-proxy"` immediately after a convergence-triggered recreate — exactly one container, with a `StartedAt` matching the recreate, not two | Fail if more than one `lancache-proxy` container is running, or the old one's `StartedAt` is unchanged (recreate didn't actually happen) |
| No file-descriptor exhaustion from repeated watchdog restart cycles over a longer soak | `docker exec <container> ls /proc/1/fd \| wc -l` sampled before and after several forced restart cycles of the same service — should return to a stable baseline, not grow monotonically | Fail (flag for investigation) if FD count trends upward across cycles rather than stabilizing |

### 10. NTP — clock discipline (added 2026-08-05, issue #1391)

**Correction to this document's own prior gap-framing:** `ntp` did **not** have "zero
validation coverage, ever" — `scripts/untracked/simulations/ntp-cap-sys-time-simulation.sh` already exists
and is wired into `full-setup-deep-validate.yml`'s `ntp-cap-sys-time-simulation` job,
which forces a real clock skew against a running `chrony` container and proves it
disciplines back to a synchronised state (`Stratum > 0`, `Leap status: Normal`) on a
real runner — that is real evidence, just never a **Part B** (stack) pass, and never
referenced anywhere in this document until now. `docs/validation-state.json`'s
`subsystem_validation.ntp` entry is still genuinely `null`, and this document's own
Validation State Tracking policy treats Part A and Part B as independently tracked —
a CI proof does not, by itself, satisfy a Part B stack-validation claim.

- Reuse `scripts/untracked/simulations/ntp-cap-sys-time-simulation.sh` directly against the live stack
  under validation (not a synthetic/CI-only fixture) — the same script, run against
  the actual `ntp` container brought up as part of this Part B pass, rather than
  re-deriving a new check.
- Confirm `CAP_SYS_TIME` is genuinely required and scoped no wider than necessary:
  cross-reference against PR #1413 (`security(ntp): least-privilege hardening for
  chrony`, open as of 2026-08-05) if that PR has since merged, since it changes the
  exact capability/seccomp posture this scenario forces skew against.
- **Not yet run as part of this pass** (tracked as a live-stack follow-up, issue
  #1391): a real Part B execution of this script against a live-brought-up stack,
  with the result recorded in `docs/validation-state.json`'s `ntp` entry — this
  document only records that the reusable proof exists and names it, per this
  section's own "Coverage Assessment" discipline of being honest about what remains
  open.

### 11. `setup.sh update` (self-update) — live scenario (added 2026-08-05, issue #1391)

**Confirmed gap:** Part A's `setup-cli-simulation.sh` only exercises the `.env`-migration
*logic* (Phase 2/2b); no Part B scenario had ever brought up a real stack and run a real
`setup.sh update` against it, until §12 below closed part of that gap for real
(2026-08-05/2026-08-06, issue #1391) — see that section for what is now actually
executed rather than merely recommended. The real mechanism was traced in full against
current `current_dev` code (`cmd_update()`/`perform_stack_update_flow()`):
pause the convergence timer, re-run the asset-population step
(`install_quickstart_compose_assets()` — an update also refreshes these assets, not just a
fresh install), take a pre-update rollback backup (`cmd_backup --config`), migrate `.env`
and re-validate the Compose config, `docker compose pull`, re-validate again, then apply
the update in a fixed order (`apply_stack_update_ordered()`): every
non-UI service first with a 180s health gate, then `ui` last with a 120s gate. Any failure
anywhere in this sequence triggers an automatic `rollback_stack_update()`
that restores the pre-update backup. **Confirmed by direct code
reading: no `docker compose down -v`/`--volumes` appears anywhere in this entire
update/rollback path** — only `up -d --remove-orphans` — so named volumes and bind mounts
are never destroyed by this flow's own design.

**Recommended live scenario (documented here; step 6's rollback negative control is now
executed for real — see §12 below — the remaining steps are not yet executed, see
Coverage Assessment):**
1. Bring up a real stack via the `setup.sh install` sequence in `### 1` above.
2. Record each service's image digest (`docker inspect <image> --format
   '{{.Id}}'`) and `StartedAt` before updating.
3. Run `bash setup.sh update` for real against this stack.
4. Confirm the image digest actually changed for at least one updated service (proves a
   real `docker compose pull`, not a no-op), and that `StartedAt` genuinely advanced for
   each recreated container (proves a real recreate, not just a reported success).
5. Confirm the cache directory's contents and the `ui-data`/watchdog-status volumes are
   unchanged after the update (proves the no-`-v` guarantee holds in practice, not just in
   the code being read).
6. As a negative control: force a health-gate failure partway through (e.g. a deliberately
   broken image tag for one non-UI service) and confirm `rollback_stack_update()` actually
   fires and restores the pre-update state — a check that can't fail is not a check.
   **Executed for real, 2026-08-05/2026-08-06, issue #1391 — see §12 below**: a
   deliberately-injected real regression (`docker-compose.override.yml` breaking a
   previously-healthy service's own healthcheck) reproduced this exact negative
   control end-to-end, including the actual `rollback_stack_update()` fire and a
   confirmed restore.

### 12. Update health gate — pre-existing failure baseline (not a regression)

Concrete, already-executed proof of part of §11 above — specifically its step 6
negative control (force a health-gate failure, confirm `rollback_stack_update()`
fires) — plus a second, real regression this fix's own live testing found and
closed that §11's original recommendation did not anticipate: the gate used to
fail (and roll back) on **any** currently-unhealthy service, not only a genuine
regression caused by the update itself.

Real incident (issue #1391, post-merge verification pass, 2026-08-05): `setup.sh
update`'s post-update health gate (`wait_for_stack_health`/
`apply_stack_update_ordered`) used to fail on **any** currently-unhealthy non-UI
service, with no way to distinguish "this service regressed because of what the
update just changed" from "this service was already broken before the update
started, for a reason unrelated to the update." Reproduced twice, deterministically,
end-to-end on a live running stack: a real install with `ntp` enabled came up with
`ntp` permanently crash-looping (a known, already-tracked environment limitation —
issue #1296, this project's self-hosted LXC runners withhold real `CAP_SYS_TIME`
clock-adjustment from nested Docker containers) while every other service was
healthy; running `setup.sh update` against that stack rolled the **entire stack**
back both times, purely because of `ntp`, even though nothing the update changed was
responsible for `ntp`'s failure. Real-world consequence: an operator whose
environment can't make an opt-in service healthy (`ntp`, or similarly `dhcp`/
`dhcp-proxy`) could never again apply **any** update — including unrelated security
fixes to `proxy`/`dns`/`ui` — without first manually disabling the broken optional
service, and nothing in the failure output told them which service was actually
blocking the gate.

Fixed by `capture_stack_health_baseline()`, called from `perform_stack_update_flow`
right after `_UPDATE_ENV_FILE`/`_UPDATE_COMPOSE_FILES` are set up — **before**
`sync_repo_to_default_branch`, `install_quickstart_compose_assets`, or
`cmd_backup --config` run, not merely before `apply_stack_update_ordered` recreates
a container. **This placement is itself a real finding from live testing, worth
recording so a future validator does not reintroduce the same subtlety**: an
earlier version of this fix captured the baseline later, inside
`apply_stack_update_ordered`, and looked correct under bats' fake-`docker` unit
coverage — but a real end-to-end reproduction caught it being too late in practice.
`cmd_backup --config`'s own "stop the whole stack for a consistent backup, then
restart it" cycle already restarts every container using whatever compose/script
content `sync_repo_to_default_branch`/`install_quickstart_compose_assets` just
refreshed (by design — see the latter's own comment about copied quickstart
installs using current container wiring "during the whole update"). A compose-level
regression (e.g. a changed healthcheck) therefore already gets baked into a real
container recreate during *that* restart, before the later capture point could ever
see the true pre-update state — confirmed live when a deliberately-injected `nats`
regression (forcing its real, previously-passing healthcheck to always fail via a
`docker-compose.override.yml`) was wrongly classified as "pre-existing" instead of a
regression on the first live verification pass, and correctly caught only after
moving the capture to this earlier point.
`capture_stack_health_baseline` samples each named service's health
`_UPDATE_HEALTH_BASELINE_SAMPLES` times, a few seconds apart, and only records it as
baseline-healthy if every sample agrees — a single sample is not reliable against a
genuinely crash-looping container, whose Docker-reported state can transiently read
"running"/"healthy" for an instant between one restart attempt and the next crash a
few seconds later. `wait_for_stack_health` then fails the gate only when a service
that **was** baseline-healthy (or has no baseline at all — a brand-new service the
update itself introduces, or a fresh install with no prior state to compare
against) is unhealthy afterward; a service already unhealthy before the update is
not blocked on, and is named explicitly in a `print_warn` rather than silently
ignored. A real regression (healthy → unhealthy) still fails the gate and still
triggers `rollback_stack_update` exactly as before — this scenario's whole point is
narrowing the failure condition to genuine regressions, not weakening the gate
itself.

| What to check | How to check it for real | Pass/fail |
|---|---|---|
| An update against a stack with an opt-in service already unhealthy pre-update (e.g. `ntp` crash-looping per issue #1296) no longer rolls back | Bring up a real stack with `ntp` enabled on an LXC-hosted runner (or any environment where it's known to crash-loop), confirm it stays unhealthy, then run a real `setup.sh update` against the stack and confirm it completes and reports `Proceeding despite service(s) unhealthy before this update started too: ntp` rather than rolling back | Fail if the update still rolls back solely because of the pre-existing, unrelated `ntp` failure |
| A genuine regression (a service healthy before the update, unhealthy after) still rolls the stack back | Bring up a real stack with every non-UI service healthy, drop in a `docker-compose.override.yml` that makes one previously-healthy service (not `proxy`/`dns`, to keep `verify_stack_functional_health`'s functional probe out of the result) fail its healthcheck/command on recreate, run `setup.sh update`, confirm it reports `Service(s) regressed from healthy to unhealthy during this update: <service>` and rolls back via `rollback_stack_update` | Fail if the update proceeds despite the real regression, or the rollback does not restore the pre-update backup |
| `tests/bats/setup_update_health_baseline.bats` (deterministic, fake-`docker`/`dc_update`, no real Docker daemon needed) | `bats tests/bats/setup_update_health_baseline.bats` (build-tools container) — covers both directions above plus the flapping-single-sample false-positive guard and the no-baseline/fresh-install fail-closed default | Fail if any of the 9 cases fail |

Not yet covered by this scenario (recorded honestly rather than silently assumed):
whether an operator-facing override flag (e.g. `setup.sh update
--ignore-unhealthy=<service>`) should exist for a baseline-unhealthy service that is
NOT opt-in/profile-gated, and whether the update should warn more loudly (beyond the
`print_warn` line above) when it proceeds with a known-broken service still present —
both remain open questions for issue #1391's still-deferred systematic Part B
rewrite, not resolved by this scenario.

---

## Current Known Feature-Specific Checks (dated 2026-07-24 — prune/update every release)

This section names the concrete new features merged on 2026-07-24 that the Standing
checks above were written to cover generically. It exists so a future validator
knows *why* a given Standing check row exists and can retire the specific example
once it stops being new, without deleting the durable check itself:

- DHCP dnsmasq-relay mode (PR #1117, closes #844) — first real relay mode alongside
  ProxyDHCP; `scripts/untracked/simulations/dhcp-relay-flow-simulation.sh` is its canonical proof.
- NATS active-disconnect on secondary removal/rotation (PR #1172, closes #681) — closes
  a documented up-to-90-day access window; `connz`/`KICK` proof via the extended
  `nats-secondary-auth-callout-simulation.sh`.
- NATS auth-callout xkey encryption (PR #1168, closes #682) — packet-capture proof
  with a negative control, same script.
- Watchdog NATS monitoring (PR #1167, refs #842) — hung-container detection via
  external `SIGSTOP`; also surfaced #1166 (open, non-blocking) as a side effect.
- Admin UI watchdog health-dashboard card (PR #1165, closes #870) — live green/red
  transitions driven by a real container stop/start.
- Admin UI cache-resize capability (PR #1174, refs #1069 — deliberately `Refs`, not
  `Closes`, since #1069's expanded scope is only partially covered) — `nginx -T`
  rendered-config proof; known `deploy/prod` misleading-display gap.
- `setup.sh reset-to-last-known-good-config dns`/`pdns` (PR #1152, closes #836) — real
  CLI-driven PowerDNS zone rollback via `scripts/untracked/simulations/setup-reset-dns-config-simulation.sh`.
- Edition-2024 bump across all three Rust crates (PR #1179, closes #1178) — real
  fixes required (rustfmt style-edition drift, `unsafe` env-var-mutation annotations,
  collapsible-if-let clippy fixes), not a clean drop-in; validate on the real
  build-tools-container Linux target, not a Windows-side `cargo check`.
- Per-release CycloneDX SBOM + OpenVEX document (PR #1194, refs #1130) — drift guard
  (`scripts/tracked/check-vex-drift.sh`) already proven once against a real mismatch; the
  live GitHub Releases API upload path itself has **not** yet been exercised
  end-to-end (see Coverage Assessment below).
- `migrate_env_for_update()` key-drift guard (PR #1199, closes #1197) — mechanical
  bats guard, proven once against a reintroduced historical gap (`NTP_ENABLED`).
- CI build-tools path-filter narrowing + permissions hardening (PRs #1190/#1202/#1204)
  — verify via `check-bats-path-filter-coverage.sh`/`check-workflow-service-lists.sh`.
- Governance/OSPS-baseline docs: AGPL-3.0-or-later adoption (#1145/#1180),
  MAINTAINERS.md (#1182), OSPS Baseline Level 3 docs (#1185), various SECURITY.md/
  CONTRIBUTING.md updates (#1189/#1193/#1196) — manual doc-vs-code drift review per
  `AG-DOC-001`, no automated check exists yet.

### Additions dated 2026-08-01 (real incidents since the 2026-07-24 survey above)

Per `AG-VAL-029` (proposed, PR #1368 — see the Validation State Tracking section's
item 10): every confirmed real bug/CI failure found since the survey above must
leave a durable check here, not just a point fix. The following incidents surfaced
between 2026-07-24 and 2026-08-01 and are now covered by the Standing checks table
above (or explicitly recorded as a known, not-yet-fixed gap in Coverage Assessment
below, per that same rule's "genuinely unautomatable case" carve-out):

- **Repo-rename case-sensitivity bug** (PR #1360, fixed, no dedicated tracking
  issue) — this
  repository's rename to `LanCache-NG` exposed a case-sensitive bash `==`
  comparison of GitHub repository-identity values in two places
  (`scripts/lib/validation-image-tag.sh`'s `vit_pr_staging_available()`,
  `scripts/untracked/select-build-tools-image.sh`'s fork-vs-same-repo trust check), each
  misclassifying a genuine same-repo PR. Both fixed with `${x,,}` lowercasing and
  dedicated bats regression coverage; see the new Standing check row above, which
  also adds an ecosystem-wide grep guard against a third call site reintroducing
  the same bug class elsewhere in `scripts/**`/`.github/**`.
- **`build-push.yml` tag-commit race** (PR #1354, 2026-08-01, **not structurally
  fixed** — see the new Standing check row above and Coverage Assessment below) —
  rapid `gh pr update-branch` calls left a pushed image labeled with an earlier,
  superseded commit than the workflow run's own reported head; remediated only by
  forcing a fresh, uncontested re-run, not by a code-level guard.
- **C-7 / container-scan vs. published-digest scan mismatch** (issue #1348,
  consolidated into #1095, **fixed** — see Coverage Assessment below) —
  `container-scan`'s throwaway pre-build image and `build`/`build-arm64`'s
  actually-pushed image used to be two independent `docker buildx build`
  invocations that never produced matching digests; `container-scan`'s redundant
  rebuild-and-scan branch was removed, leaving `build`/`build-arm64`'s own
  pushed-digest scan as the sole, matching-numbers-correct vulnerability gate.
- **`build-push.yml` self-modification trigger bug** (PR #1367 POC, **open, not yet
  resolved** — see Coverage Assessment below) — a PR that itself modifies
  `build-push.yml` may not reliably receive a `pull_request`-triggered run of the
  new workflow content.
- **Watchdog Rust-crate findings** (PR #1355, **open/unmerged as of 2026-08-01 —
  pending, not yet a validated feature** — see Coverage Assessment below) —
  `CACHE_DIR` legacy-variable precedence and `ping()` timeout/stall detection in the
  new (not-yet-wired-in) `services/watchdog` Rust crate.
- **Untouched-service staging back-fill ancestor fallback** (fixed, 2026-08-01, issue
  #1095 Part 1 follow-up, triggered by PR #1355 — see the new Standing check row
  above) — `scripts/untracked/ensure-pr-staging-images.sh`'s untouched-service back-fill had no
  recovery path when a PR's base commit was itself a docs/governance-only commit
  that `build-push.yml`'s own push `paths-ignore` (#1095 Part 1) deliberately never
  builds; the wait was structurally unwinnable and always failed at the hard
  ceiling. PR #1355's "ensure PR staging images" job stayed in FAILURE for 15+ hours
  for exactly this reason before the fix. A first version of the fix (PR #1371)
  drew a real-world Codex review pass identifying several further gaps — a positive
  proof that BASE_SHA's own *changed paths* actually matched the ignore-list (not
  just that no run existed, which an unrelated CI outage could also produce), the
  same recovery logic duplicated independently in `build-push.yml`'s own equivalent
  step, a SIGPIPE hazard in the ancestor walk once the real ancestor count exceeds
  the search depth, a missing `--first-parent` (this project does not squash-merge,
  so a plain `git log` walk can surface a side-branch commit before the real prior
  target-branch state), no retry on the decisive GitHub API query, and an
  asymmetric non-push-run rejection for ancestor candidates — all addressed by
  extracting the shared implementation into `scripts/lib/staging-ancestor-fallback.sh`
  (see the Standing check row above for the current, corrected state).
- **pipefail/SIGPIPE early-exit-consumer bug in `tools/build-tools/Dockerfile`**
  (PR #1374, issue #815, fixed; **standing check added, deliberately narrow scope
  — see Coverage Assessment below**) — real CI job 91393831566 (run 30709307913)
  failed with exit 141 on `rustup target list --installed | grep -qx ...` /
  `rustc -vV | grep -qE ...`: `grep -q` exits as soon as it matches, closing the
  pipe while the still-writing producer receives SIGPIPE, which `pipefail` then
  reports as the pipeline's own failure. Fixed by capturing each producer's output
  into a variable first, then grepping the variable via a here-string (eliminates
  the live pipe entirely). The identical shape (`git log | tail | head -n 50`) was
  independently found and fixed the same session in PR #1371's
  `find_built_ancestor()`. New Standing check row above
  (`scripts/untracked/check-pipefail-early-exit-grep.sh`, wired into the
  `shellcheck`/`shellcheck-hosted` jobs); a
  proposed AGENTS.md rule for the general failure class was posted as a PR #1374
  comment for maintainer review, per `AG-WF-025` (originally drafted as
  `AG-VAL-030`, since claimed by an unrelated rule; landed as `AG-VAL-032` via
  issue #1377, which also fixed the repo-wide instances and widened this
  script's scope -- see the Standing check row above).

### Additions dated 2026-08-07 (real incident since the 2026-08-01 survey above)

- **`gc-pr-staging-images.yml` narrow-checkout runner corruption** (issue #1095,
  fixed) — `actions/checkout@v7.0.1`'s `sparseCheckoutNonConeMode()` (selected by
  this workflow's `sparse-checkout-cone-mode: false`) sets `core.sparseCheckout`
  via `git config` but writes the narrow path patterns by appending directly to
  `.git/info/sparse-checkout`, never through the `git sparse-checkout set`
  porcelain command. Reproduced repeatedly, live, on a self-hosted runner host
  (git 2.47.3, `.240`), both against a real shallow clone of this repository and
  throwaway synthetic repositories of varying size: a sparse-checkout state set
  up that way does not reliably clear on a later job's plain `git
  sparse-checkout disable`, nor on `git sparse-checkout init` immediately
  followed by `disable` — both report success, but across repeated runs the
  actual outcome varied between full recovery and index skip-worktree bits
  staying set on every path outside the narrow set; the exact trigger for the
  variation was not isolated. Self-hosted runners reuse one working directory
  across unrelated jobs/workflows, and no other workflow in this repo passes a
  sparse-checkout input at all, so whatever state a `gc-pr-staging-images.yml`
  run leaves behind is inherited by the next job scheduled onto the same
  runner instance — traced via one such runner's own `_diag` worker logs (a
  "reap closed-PR staging tags and orphaned versions" run, followed without an
  intervening second reap run by a `build-push.yml` job that failed) to real
  "No such file or directory" / "Can't find 'action.yml'" failures observed
  across several unrelated `build-push.yml` jobs, on multiple runner hosts, on
  2026-08-07. Because `disable`'s own exit code proved unreliable as a success
  signal, the fix does not trust it: after the reap script runs, it sweeps any
  remaining index skip-worktree bits directly via `git update-index
  --no-skip-worktree` and asserts (failing the job loudly) that none remain,
  rather than assuming the restore worked. The count itself is computed with
  `awk` rather than `grep -c`, and only after capturing `git ls-files -v`'s
  output into a variable first — a real git failure at that point must trip
  `set -e` immediately via the plain assignment, and the count must never end
  up empty (an empty `[ "$x" -ne 0 ]` comparison is a runtime error, not a
  `set -e`-fatal one, inside an `if` condition, so it would otherwise silently
  skip the check instead of failing it); confirmed with a real run against a
  non-git directory that the step now exits non-zero rather than silently
  succeeding. New standing check:
  `tests/bats/gc_pr_staging_images.bats` (sparse-checkout-restore test group,
  merged in from the former standalone
  `gc_pr_staging_images_sparse_checkout_restore.bats` as part of issue #1557)
  regresses the failure (plain `disable` leaving `core.sparseCheckout` set), every stage of
  the fix including the always-reproducible case of a skip-worktree bit that
  `disable` alone does not clear, and the fail-closed behavior itself, against
  a throwaway local git repository — no network or real clone needed. A
  durable guard against a *future* self-hosted workflow reintroducing a narrow
  `sparse-checkout` input without a matching restore step does not exist yet;
  recorded as an open gap in Coverage Assessment below.

### Additions dated 2026-08-14 (real incident since the 2026-08-07 survey above)

- **F-17 SHA retention audit** (issue #1095, PR #1501, new — protect-only, no
  destructive path exists yet) — `release/stack-images.yml`'s retention contract
  gained `accepted_ordinary_roots_per_package` (raised from a first draft of 10 to
  30 during review, since a burst of concurrently open PRs that each only touch
  YAML/governance files still produces one new build-tools `sha-<commit>` image per
  push, and a ten-slot window could evict still-relevant recent history). A new
  read-only GHCR audit (`.github/workflows/gc-sha-retention-audit.yml`,
  `scripts/untracked/gc-sha-retention-audit.sh`, `scripts/lib/sha-retention-
  audit.sh`, `scripts/lib/github-api-retry.sh`) inventories every first-party
  package version, ranks legacy ordinary roots from first-parent Git history, and
  reports beyond-budget candidates as a labeled dry-run `decision=would-delete`
  line (real GHCR `created_at` build date attached for display only, never fed
  into ranking) rather than issuing any deletion call. `tests/bats/sha_retention_
  audit.bats` includes a structural guard
  (`retention audit code and workflow contain no destructive package path`) that
  greps the audit's own implementation and workflow for `-X DELETE`/
  `delete:packages`/`GHCR_PACKAGE_DELETE_PAT` and fails if any is found. Three
  real bugs surfaced and were fixed during live CI runs against this workflow
  rather than only in local/synthetic testing: an invalid `runner` context
  reference, an overly strict required-argument check that rejected a real
  legitimately-empty tags field on an untagged package version (run
  31773692600), and a 25-minute per-package timeout (run 31774741729) traced to
  redundant per-version `jq` subprocess calls, fixed by consolidating id/digest/
  tags/`created_at` extraction into one combined `jq` call per version — which
  itself needed a `|`-delimited `read` instead of `jq`'s `@tsv`, since bash's
  `read` treats a literal tab as IFS whitespace regardless of the configured
  `IFS` value and would otherwise silently drop an empty middle field. Deferred,
  not yet authorized: any destructive-activation pass (selection by date, tag
  pattern, or explicit digest/alias) — see `docs/release-versioning.md`'s
  Retention section for the current data-model boundary this leaves in place.

  **Update, same day (protected-reference model, PR #1501):** the audit's
  generic `non-sha-tag-attached`/`non-ordinary-version`/
  `acceptance-evidence-unavailable` reasons are now specific
  (`nightly-channel-protected`, `latest-channel-protected`,
  `stable-release-protected`, `+`-joined when more than one applies)
  whenever a version's digest is currently referenced by `nightly`, `latest`,
  or one of a package's `minimum_stable_releases` (3) newest stable release
  tags — derived from already-fetched GHCR tag data, no extra API call. A
  root carrying only an *unrecognized* extra tag (a release-candidate/staging
  tag, or a release tag past `minimum_stable_releases`) is no longer
  blanket-protected; it now falls through into the same ordinary
  root-candidate ranking as a plain root. 14 new `tests/bats/sha_retention_
  audit.bats` cases cover every new helper (`sra_read_minimum_stable_releases`,
  `sra_is_stable_release_tag`, `sra_release_sort_key`,
  `sra_select_supported_release_tags`, `sra_classify_channel_tag`,
  `sra_other_tags_from_csv`, `sra_protected_reference_reason`,
  `sra_extra_tag_protect_reason`), including the combined-reason case, the
  unsupported-old-release case, and the unrecognized-tag fallthrough case —
  this file's own standing coverage for this subsystem, satisfying AG-VAL-029
  for this change rather than leaving it as a point fix with no durable
  regression net. **Not implemented, recorded as an open gap below rather
  than silently skipped:** a "previous nightly" safety net (protecting the
  digest `nightly` pointed at immediately before the current one) — see
  `docs/release-versioning.md`'s Retention section for why (GHCR exposes no
  tag history; a real implementation needs a new `actions: read` lookup
  against `nightly-refresh.yml`'s own run history) and the maintainer
  decision requested in PR #1501's `#issuecomment-5292505929`.

**New Standing check row, added out of table-row order on purpose (2026-08-14, PR #1501 protected-reference model)** -- inserted here immediately after the narrative it verifies, rather than into the large table above, for the same anchor-line/merge-conflict reason given at the "bug-hunt #849" insertion point further down this document:

| Subsystem | What to check | How to check it for real | Pass/fail |
|---|---|---|---|
| **F-17 SHA retention audit — protected-reference model, current-state-only** (PR #1501, 2026-08-14) | The new specific reasons (`nightly-channel-protected`/`latest-channel-protected`/`stable-release-protected`) actually fire on real GHCR data instead of only in bats fixtures, AND the narrowed scope genuinely lets an unrecognized extra tag fall through to ordinary ranking rather than silently reverting to blanket-protecting every tagged root | Confirmed live 2026-08-14 against real GHCR data, `gc-sha-retention-audit.yml` run [31794626426](https://github.com/wiki-mod/lancache-ng/actions/runs/31794626426) (commit `bbd51666`, conclusion `success`) -- full record in PR #1501's `#issuecomment-5292835967`. **Note on run/commit currency:** this row itself landed in a docs-only follow-up commit (`48ad2a15`) pushed after `bbd51666`; `48ad2a15` touches only this file (`git show --stat 48ad2a15`), no audit code path, so the cited run's evidence remains representative of the code currently on this branch. Fetch the job log to a file (`gh run view <run-id> --repo wiki-mod/lancache-ng --log > <file>` -- pass the specific run ID, never rely on `--limit 1`'s newest-run guess once a later push exists) and run the two discriminating greps below against it, exactly as run for the 2026-08-14 confirmation. Grep (1): non-zero count required across all three reasons -- a run with all-zero counts is not evidence the mechanism regressed away silently, it means the mechanism never fired at all this run and must be investigated before being read as a pass. Grep (2): confirm at least one matched line's `tags=` field contains a tag other than a `sha-<commit>`/`sha-<commit>-<arch>` shape -- proves a real unrecognized-extra-tag root fell through to ordinary ranking instead of being blanket-protected. The 2026-08-14 run's own concrete instance for (2): package `proxy`, id `1106042122`, `tags=pr-1436-sha-dee3889,sha-62f05e4`, `legacy_rank=31`, `budget=beyond-30`, `decision=would-delete`, `reason=acceptance-evidence-unavailable` -- a real `decision`-outcome change traced to a real record, not merely a `reason`-text difference. `tests/bats/sha_retention_audit.bats`'s 14 new cases (38 total) cover the same properties at the unit level and must also pass, but do not substitute for this live-data check -- a bats fixture cannot regress the way `sra_protected_reference_reason` silently reading a stale/wrong tag classification against real GHCR data could. See the fenced commands immediately below this table for the exact, copy-pasteable greps (a markdown table cell cannot safely carry an unescaped shell pipe) | Fail if grep (1) returns zero total matches across all three reasons on a real run's log, or if grep (2) finds no line with both a numeric `legacy_rank` and a non-`sha-` extra tag (the narrowed-scope fallthrough no longer demonstrable against real data), or if `tests/bats/sha_retention_audit.bats` regresses |

```bash
# (1) at least one non-zero count required across all three reasons
grep -oE "reason=(nightly-channel-protected|latest-channel-protected|stable-release-protected)" <logfile> | sort | uniq -c

# (2) at least one line needed with a numeric legacy_rank AND a non-sha- extra tag in `tags=`
grep -E "legacy_rank=[0-9]" <logfile> | grep -v "decision=protect"
```

### Additions dated 2026-08-15 (real incident since the 2026-08-07 survey above)

- **`current-dev-auto-close.yml` closing-keyword scanner reading the whole PR
  body** (issue #1496, fixed) — the scanner matched `keyword #N` phrases
  anywhere in a merged PR's body, with no way to distinguish a real closing
  instruction from a worked example, quotation, or incident description
  elsewhere in the body. This class of bug produced two confirmed real
  false auto-closes of issue #1095: once via PR #1443's own negated-sentence
  prose (before a same-sentence negation lookbehind existed), and again via
  PR #1491's own worked-examples section (the PR that *added* that negation
  lookbehind), which still matched nine unrelated `#N` references purely
  from illustrative prose. Fix (this PR): the scanner now reads only the
  exact `## Linked Issues` heading's section (line-based match, up to the
  next level-2 heading), failing closed to "close nothing" when that
  section is missing or duplicated; `scripts/validate-pr-template.sh` makes
  the section required/validated for non-draft PRs. Proven via four real
  `workflow_dispatch` dry-run executions against this branch's pushed code
  (commit `97f26d1d`, byte-identical to the runs' actual commit `c51bac87`
  for both touched files — confirmed via `git diff c51bac87 97f26d1d --
  .github/workflows/current-dev-auto-close.yml
  scripts/validate-pr-template.sh`, empty output): real run `31904977220`
  replays PR #1491 itself and now finds zero matches; real run `31905211266`
  proves multiple legitimate `Closes`/`Fixes` references and a non-closing
  `Refs` reference all resolve correctly; real runs `31905524192` and
  `31905565459` prove the duplicated- and missing-heading fail-closed paths
  respectively, against a disposable scratch PR opened and deleted
  immediately after (see PR #1580's Validation section for the full
  transcript). **New standing check: none yet** — this workflow's scanning
  logic is inline `actions/github-script` JS with no local Node tooling in
  this project's build-tools image, and `scripts/tracked/validate-pr-template.sh`
  has no existing bats coverage at all to extend (pre-existing gap, not
  introduced by this fix); recorded as an open gap in Coverage Assessment
  below rather than left unautomated silently.

## Coverage Assessment (from this survey — be honest about gaps)

**Well-covered, reusable, real proofs already exist for:**

- DHCP Kea lease flow, dnsmasq ProxyDHCP PXE options, and the new dnsmasq-relay mode
  (all three have a real E2E simulation script, not just config-render unit tests).
- NATS secondary lifecycle including both of today's new hardening mechanisms
  (active-disconnect, xkey) — both proven with negative controls, which is exactly
  the rigor this document asks for elsewhere.
- The SBOM/VEX drift guard and the `.env` key-drift bats guard — both already
  proven once against a real induced failure, on 2026-07-24, by an earlier agent
  pass; this document's job is to make sure that proof gets *reused*, not re-derived,
  every release.
- File-header, naming-consistency, and bats-path-filter-coverage CI guards — all
  mechanical, all scriptable, all already exist and run today.

**Genuinely under-tested today — do not assume these are covered without a fresh,
explicit pass:**

- **Admin UI cache-resize's full loop** (dashboard submission → `.env` write →
  `lancache-converge.service` tick → `docker compose up -d` recreate → nginx actually
  enforcing the new size) has never been run start-to-finish as a single live E2E
  proof — PR #1174 explicitly states this ("Could not run: a live end-to-end ...
  cycle"). The `deploy/prod` misleading-display gap is *documented* but not fixed.
  **Partially advanced, 2026-07-24** (still not fully closed — see below): confirmed
  live that a real UI form submission (`POST /cache/resize`) correctly persists
  `CACHE_MAX_GB` into the `ui-data` volume's `lancache-ui-settings.env`, and that
  `lancache-converge.service`'s ExecStart is actually **two separate steps**, not one —
  `setup.sh converge-reconcile <install_dir>` (merges the UI override into the deploy
  `.env`; confirmed live this correctly wrote `CACHE_MAX_SIZE`/`CACHE_MAX_GB`) followed by
  a distinct, pre-existing container-drift-convergence `ExecStart` line that actually runs
  `docker compose up -d` to recreate the drifted container. On a host with no
  `lancache-converge` systemd units installed (any manual `docker compose` bring-up, not a
  real `setup.sh install`), running `bash setup.sh converge-reconcile <install_dir>`
  by hand exercises step 1 only — `nginx -T` will still show the old `max_size` until
  something also runs `docker compose up -d proxy` (step 2). This pass did not run step 2
  against a real convergence-driven recreate, so `nginx -T`'s rendered `max_size` was
  **not** confirmed to change — the headline claim of this check remains unproven; do not
  record this subsystem as validated on the strength of step 1 alone.
- **`release-sbom`'s actual GitHub Releases API upload path** (PR #1194) has never
  been exercised against the live API — only the Trivy CycloneDX command and the
  shellchecked upload heredoc bodies were verified in isolation. This needs a real
  tag-triggered release run before being trusted.
- **Watchdog's `restart_container()` curl-timeout-vs-grace-period race** (#1166) is
  a known, open, non-blocking bug that produces a false-negative warning log on a
  slow-to-stop container — validators must know to cross-check `StartedAt` rather
  than trusting the warning literally.
- **Netdata-alarm → Admin UI notification integration** (`docs/bug-hunt/
  observability.md` finding #3, PR #1165's remaining open half) has been built:
  the `netdata` container's `custom_sender()` integration
  (`deploy/*/docker-compose.yml`'s `netdata:` service, all three real profiles)
  POSTs each Netdata health.d alarm event to the Admin UI's new
  `POST /api/netdata-alarms` (`services/ui/src/routes/netdata_alarms.rs`,
  `services/ui/src/netdata_alarms.rs`), gated by a shared `NETDATA_ALARM_TOKEN`
  (issue #858 pattern) and rendered on the dashboard's new "Netdata alarms"
  card. Durable coverage added: `docker compose -f <file> config --quiet` for
  all three deployment profiles (catching a real Compose `$`-interpolation
  parse bug during this work, not merely asserted clean), plus unit tests for
  the storage module's bounded history, idempotent-append-on-duplicate-
  `unique_id`, and malformed/missing-file tolerance, and for the ingest route's
  fail-closed constant-time token check. **Still unproven**: whether
  `SEND_CUSTOM="YES"`/`DEFAULT_RECIPIENT_CUSTOM="lancache-ui"` alone actually
  cause Netdata's real `custom_sender()` to fire for a genuine alarm depends on
  Netdata's own per-role recipient resolution, which this pass could not
  exercise end-to-end — the wiring is written to Netdata's documented
  `health_alarm_notify.conf` contract, but a live `alarm-notify.sh ... test`
  run against a real deployed stack is the still-needed follow-up proof.
- **The DNS reset-to-known-good E2E** (PR #1152) has only ever been run with two
  environment deviations in place (a locally built image, a patched healthcheck probe
  domain) due to the since-fixed #1150 bug — the *unmodified* real CI path for this
  script has never actually completed clean; confirm that on the next run rather than
  assuming it now works unmodified.
- **Corrected 2026-08-05 (issue #1391 audit) — this entry was itself stale.** A prior
  version claimed "Kea/PDNS/NATS config-writer idempotence is still manual-review-only
  per `.github/AGENTS.md`'s own enforcement matrix (`AG-OP-006`/`AG-OP-007` row) — only
  the `.env`-migration path and watchdog's restart-counter convergence have real
  repeat-run fixture coverage." `AGENTS.md`'s own `AG-OP-006` row (corrected in PR
  #1409, 2026-08-05) already states this wording was stale: Kea/PDNS/NATS/dhcp-proxy
  config-writers are covered by dedicated repeat-run bats tests (delivered by #640,
  enforced project-wide by `scripts/tracked/check-idempotence-test-coverage.sh`) —
  e.g. `tests/bats/nats_conf_entrypoint_idempotence.bats`,
  `tests/bats/dhcp_proxy_known_good_snapshot.bats`. This document had not been
  synced with that correction until now — a small, concrete instance of exactly the
  drift class issue #1391's proposed `AG-VAL-033` rule is meant to prevent going
  forward. (Also note: the enforcement matrix itself lives in the repo-root
  `AGENTS.md`, not `.github/AGENTS.md` — the latter is a 9-line pointer to the
  former; a prior version of this bullet cited the wrong file.)
- **This document's own Validation State Tracking mechanism** (`docs/validation-
  state.json`) is brand new as of this PR — it starts with every field `null` and has
  not yet been exercised by a real validation pass. The first real run against it is
  itself a gap until it happens.
- **Watchdog Rust-crate findings** (PR #1355, **open, not merged, as of 2026-08-01**
  — do not treat as covered): the new `services/watchdog` Rust crate's
  `config::resolve_cache_dir()` (mirrors `watchdog.sh`'s `CACHE_DIR` vs. legacy
  `CACHE_DIR_STANDARD`/`CACHE_DIR_SSL` precedence: `CACHE_DIR` wins outright, a
  conflicting legacy pair with no `CACHE_DIR` fails closed, a single legacy var is
  honored, default only when none are set) and `docker_client::ping()`'s
  stricter-than-bash timeout/stall detection (actually consumes the `/_ping`
  response body and requires it to equal exactly `OK`, catching a gateway that
  stalls after headers, which the bash's status-code-only probe would report
  healthy) both have real unit-test and live-binary coverage **in the PR itself**,
  but the crate is not wired in anywhere — `services/watchdog/Dockerfile`'s
  `ENTRYPOINT` still runs the bash script unchanged. Until this PR merges **and** a
  follow-up actually switches the entrypoint, these findings describe an unused,
  parallel implementation, not validated production behavior; re-check this PR's
  merge status before adding a Standing check row for it.
- **Proxy `slice` + a cached 301/302 response has never been exercised end-to-end**
  (bug-hunt #849, finding #14, 2026-08-06) -- documented exception per Rule-Ref:
  AG-DOC-011:
  - **Scope**: The `slice`-plus-cached-redirect end-to-end path only --
    `services/proxy/proxy-params.conf` configures `slice ${CACHE_SLICE_SIZE};`
    alongside `proxy_cache_valid 200 206 301 302 ${CACHE_VALID_HIT};`, so a
    redirecting origin response is both eligible for range-slicing AND for
    being cached and re-served on a later request.
  - **Reason**: Closing this for real needs a live nginx instance in front of
    a controlled origin that returns a 3xx for a ranged request, which none
    of this project's current simulation scripts provide; building one is a
    genuinely separate undertaking from the rest of the #849 proxy pass (most
    of which is covered by unit-level bats tests against extracted shell
    functions, not a new live-nginx harness) -- recorded here rather than
    rushed into an under-verified script under time pressure.
  - **Tracking**: bug-hunt #849 finding #14 (2026-08-06). Follow-up: a
    dedicated `scripts/untracked/simulations/proxy-slice-redirect-cache-simulation.sh`
    (mirroring the existing `proxy-*-simulation.sh` scripts' shape and location)
    is the concrete next step, not yet built.
  - **Validation**: No automated coverage exists for this exact path today.
    `scripts/untracked/simulations/ssl-mitm-cache-simulation.sh`'s own comment explains why *its*
    assertions check the literal HTTP status (to guard against a redirect
    masquerading as real content) -- that is a different check and must not
    be read as covering this gap. Until the follow-up script lands, treat any
    claim that "slice-plus-redirect caching works" as unverified.
  - **Non-Expansion**: This exception covers only the slice-plus-cached-
    redirect path. It does not cover any other proxy caching/slice behavior
    (which has real coverage elsewhere), and it does not extend to the other
    three finding-#9 gaps this same PR closes (multi-file known-good-snapshot
    rejection, CA/cert-dir permission hardening, PSL-backed registrable-domain
    derivation) -- all of those have real, non-exempted test coverage now.
- **Five gaps confirmed by this audit pass (2026-08-05, issue #1391),
  corrected/documented here (in some cases with a concrete, code-verified recommended
  sequence) but NOT yet closed by a live run** — tracked explicitly as a follow-up
  milestone, not silently left implicit: (1) the multi-PID-`SIGSTOP`
  hang-simulation-technique fix for `proxy`/`dns-standard`/`dns-ssl` (Part A/B
  Watchdog rows above — corrected from an earlier, rejected `docker pause` version of
  this same fix, see those rows for both empirical results) is verified against a
  synthetic multi-process `nginx:alpine` Docker healthcheck mechanism, not yet against
  the real `proxy`/`dns-standard`/`dns-ssl` images nor a real watchdog-observed
  restart; (2) the `ntp` Part B scenario (§10 above) names the
  reusable script but has not itself been run against a live-brought-up stack, and
  `docs/validation-state.json`'s `ntp` entry remains `null`; (3) the DNS
  wildcard-scope live `dig` proof (§2 above) is specified but not executed; (4) the
  real `setup.sh install` bring-up sequence (§1 above) has a concrete, code-verified
  recommended procedure (reusing `scripts/untracked/simulations/setup-cli-simulation.sh`'s own `expect`
  mechanism) but has not itself been executed as part of this pass; (5) the
  `setup.sh update` live scenario (§11 above) has a concrete, code-verified
  procedure; its step 6 negative-control rollback test (and, going beyond what §11's
  original steps anticipated, the new pre-existing-failure-forgiveness behavior
  documented in §12) **has since been executed for real** (2026-08-05/2026-08-06,
  issue #1391's health-gate fix) — steps 1-5 (digest/`StartedAt`/cache-content checks
  across a normal, non-failing update) remain not yet executed. Each of the still-open
  items above needs a real running stack and real evidence, not reasoning, before it
  can be recorded as closed — see issue #1391 for the full remaining scope and the
  explicit decision to split this into a separate live-stack milestone rather than
  compress it into this pass.

- **AG-VAL-034's GNU/BusyBox construct audit for Alpine-migrated services has no
  standing mechanical check yet, despite recurring four times** (`services/watchdog`
  #1346, `services/dhcp`/`dhcp-proxy` #1347, `services/dns` #1425, `services/proxy`
  issue #815/this migration pass) — each occurrence was caught only by a human/agent
  reading the entrypoint script line-by-line and cross-checking against a real
  `alpine:3.24` container, exactly the standing-check gap `AG-VAL-029` exists to close.
  `AG-VAL-034`'s own rule text already names the missing piece: "a mechanical guard
  for `services/*/entrypoint.sh` against an Alpine final stage is proposed future
  work, not yet built." Recorded here rather than silently deferred a fifth time: a
  low-false-positive version would grep each Alpine-based service's `entrypoint.sh`
  for the confirmed-recurring pattern shapes (`find[^|]*-printf`, `date[^|]*%N`,
  `grep[^|]*-[a-zA-Z]*P\b`) and assert the corresponding fix package
  (`findutils`/`coreutils`/`grep`) is present in that service's `Dockerfile` — the
  same shape as `scripts/untracked/check-pipefail-early-exit-grep.sh`'s existing pattern/fix-package
  cross-check. Not built in this pass; a future PR should add it as its own standing
  check rather than relying on the fifth migration's agent to re-derive this list from
  scratch again.

- **`current-dev-auto-close.yml`'s `## Linked Issues`-only scanner (issue
  #1496) and `scripts/validate-pr-template.sh`'s new required-section check
  for it have no standing automated regression test.** The scanner's
  extraction/fail-closed logic is inline `actions/github-script` JS with no
  local Node tooling in this project's build-tools image, so it cannot be
  unit-tested the way a standalone shell script can; `validate-pr-template.sh`
  itself has zero bats coverage today for any of its required sections, not
  only the new one, a pre-existing gap this fix did not introduce or close.
  The four real `workflow_dispatch` dry-run executions recorded in this
  document's 2026-08-15 addition above and in PR #1580's own Validation
  section are a one-time manual proof, not a repeatable CI guard — a future
  regression in this scanner would not be caught automatically. A future PR
  should add bats coverage for `validate-pr-template.sh` (extending it into
  the existing `tests/bats/check_pr_tracking_metadata.bats`-style sibling
  pattern, per `AG-CODE-013`) and, separately, evaluate whether the
  `current-dev-auto-close.yml` extraction logic is worth factoring out of
  the inline script into a testable shell/script form.

**Known, accepted limitations (not fixable without larger rework — recorded per
`AG-VAL-029`'s "genuinely unautomatable/impractical" carve-out, not silently
omitted):**

- ~~C-7: `container-scan`'s throwaway image and `build`/`build-arm64`'s pushed image
  never share a digest~~ — **fixed** (issue #1348/#1095's G8 finding; no longer an
  accepted limitation, see the 2026-08-01 entry above and `container-scan`'s own
  job-header comment in `build-push.yml`). `container-scan`'s redundant
  rebuild-and-scan branch for a changed service was removed entirely;
  `build`/`build-arm64`'s existing "Scan pushed service digest with Trivy" step is
  now the sole vulnerability scan, and it always scans the exact pushed digest.
- **`build-push.yml` self-modification trigger bug** (open, unresolved as of
  2026-08-01; maintainer's own POC is PR #1367, `Refs #1095`, `Refs #1356`) — a PR
  that itself modifies `build-push.yml` does not reliably receive a real
  `pull_request`-triggered run reflecting the new workflow content. **Root cause not
  yet confirmed** — do not assume any particular mechanism (e.g. a GitHub Actions
  merge-ref/base-branch-content nuance) without first reading PR #1367's own
  findings; this entry records the observed symptom only. PR #1367 exists
  specifically to test whether a **non-draft** PR (unlike four prior draft-PR
  attempts) triggers a real run; PR #1356 (widening the Step 4 push-reuse
  allowlist, itself a `build-push.yml` change) is one real, current example of a PR
  potentially affected by this gap. Do not assume a `build-push.yml`-modifying PR's
  own CI status is meaningful evidence until this is resolved — cross-check against
  a separate, already-merged run of the same content if in doubt.
- **`build-push.yml` tag-commit race** (PR #1354, 2026-08-01) — see the new Standing
  check row above for the mechanism and the required cross-check. No code-level fix
  exists; the only remediation applied so far was forcing a fresh, uncontested
  re-run (an empty commit), which sidesteps the specific instance without closing
  the underlying race (rapid `gh pr update-branch`/force-push calls against the
  same PR can still resolve `github.sha`/the image tag to a superseded commit while
  the workflow reports success for the newer one). No dedicated tracking issue
  exists yet for the root cause itself.
- **`proxy-ssl-mode-two-relay-dispatch-simulation.sh`'s negative control is a
  documented, deliberate exception, not silently omitted (issue #1276/#1322,
  2026-08-05).** This job's real positive-path assertions (dispatch-map content,
  real depth-1 MITM handshake, real depth-2 passthrough handshake reaching the
  actual distinct `backend-two-real` certificate, client-IP preservation,
  healthcheck ports) are a committed, repeatable CI check, same as every other
  entry in this document's "Well-covered" list above. What is deliberately NOT
  automated is a live negative control (rebuilding a "pre-fix" proxy image and
  asserting it reproduces the original hostname-mismatch bug): an earlier
  version of this script computed a `git merge-base` against the base branch at
  runtime to find that pre-fix reference, and it worked correctly only while the
  fix lived solely on its own PR branch. Once that fix merged into `current_dev`,
  the same computation had no stable, branch-independent pre-fix commit left to
  find — it produced three different, unpredictable TLS errors across three
  real CI runs on PRs unrelated to this fix (confirmed on #1425). This is a
  structural limitation, not a resourcing gap: there is no git-history-relative
  reference point that means "before this fix" once the fix is part of the base
  branch's own history, for any future PR that inherits this permanently-running
  test. The negative control was instead performed once, live, by hand, with
  full `openssl s_client` output recorded in issue #1276's own comment thread —
  matching how this project has proven every prior fix in this same family
  (neither `proxy-standard-mode-sni-routing-simulation.sh` nor
  `proxy-deep-wildcard-tls-simulation.sh` bakes a live negative control into its
  permanently-running script either). The depth-2 real-backend-certificate
  assertion that remains in the committed script carries the ongoing regression
  signal: a pre-fix build cannot produce that certificate for that SNI at all.
- **No repo-wide guard against a future workflow reintroducing an unrestored
  narrow `sparse-checkout` on a self-hosted job** (2026-08-07, issue #1095) —
  `tests/bats/gc_pr_staging_images.bats` (sparse-checkout-restore test group,
  merged in from the former standalone
  `gc_pr_staging_images_sparse_checkout_restore.bats` as part of issue #1557)
  regresses the specific failure and fix in `gc-pr-staging-images.yml` (the one workflow in
  this repo that currently sets a `sparse-checkout` input), but nothing checks
  the repo's workflow files themselves for a *new* `sparse-checkout` input added
  to some other self-hosted job without an equivalent restore step. A grep-based
  guard (flag any `sparse-checkout:` input in `.github/workflows/**` whose job
  does not also contain a matching config-unset/pattern-file-removal step) is
  plausible but not yet built — this is a real, currently-open gap, not a
  silently-assumed-covered case.
- **Recorded exception (2026-08-07): no mechanical guard against a
  config-file comment's factual claim going stale as the code it describes
  changes.**
  - **Scope**: any comment in a tracked config/workflow file that asserts a
    factual claim about surrounding code (e.g. a base-image identity, a
    dependency's version, a service's runtime behavior) which can drift out
    of sync with a later, unrelated code change.
  - **Reason**: judging whether a comment's factual claim is still true
    resists cheap, reliable mechanical detection in general -- a check would
    need to parse the comment's specific claim and cross-reference it
    against the exact file(s) it describes, which differs per comment and
    isn't a generic pattern worth building a linter for. This is the same
    class AG-VAL-028 already carves out for the AG-CODE-* family.
  - **Tracking**: issue #1095's F-18 audit found and fixed one real instance
    (`.github/dependabot.yml`'s Docker-block comment asserted "every service
    pins the same Debian base," accurate when written but stale since issue
    #815 migrated every listed service to an identical Alpine base image).
  - **Validation**: found and fixed only by a human/agent reading the
    comment against the real `FROM` lines during an unrelated audit, not by
    any CI check when first found. **Updated 2026-08-08**: this specific
    recurring claim (that every Docker directory `.github/dependabot.yml`
    groups into one PR shares an identical final-stage base image) is
    concrete and mechanically checkable, unlike the general class this
    exception covers -- `scripts/tracked/check-dependabot-docker-base-consistency.sh`
    (wired into the `file-headers-check` composite action) now fails CI if
    any listed Dockerfile's final `FROM` line ever diverges from the
    others, with bats coverage
    (`tests/bats/check_dependabot_docker_base_consistency.bats`, including a
    real-repository self-check) proving both the passing and failing path --
    see that file's own case count directly rather than a number restated
    here, which has already drifted stale more than once as cases were
    added.
    The general exception below still stands for any *other* config-file
    comment's factual claim, which remains genuinely hard to check
    mechanically.
  - **Non-Expansion**: this exception covers only the general
    "comment-vs-code drift is hard to check mechanically" class. It does not
    exempt any single already-known-stale comment from being fixed once
    found (Rule-Ref: AG-DOC-001 still requires that), and does not cover a
    comment whose claim is checkable by an existing, narrower guard (e.g.
    AG-CODE-003's review-chronology phrasing already has one).
- **Recorded exception (2026-08-08, Rule-Ref: AG-CC-004): third-party
  automated-reviewer output language cannot be checked by a durable, repeatable
  CI test.**
  - **Scope**: Rule-Ref: AG-CC-004's requirement that a third-party automated tool's
    GitHub-bound output (e.g. Codex's PR review comments) be English.
  - **Reason**: checking this mechanically would require either scripting a
    real trigger of that external tool's review inside CI (not something this
    repository controls or can invoke on demand) or scraping its
    already-posted comments after the fact on a schedule with no fixed timing
    guarantee — neither is a genuine standing check in the sense this
    document's other entries mean.
  - **Tracking**: `AGENTS.md`'s Rule-Ref: AG-CC-004 rule text and its Rule Enforcement
    Matrix entry; issue #1507 (the language-rules rework this exception was
    recorded alongside).
  - **Validation**: manual-review-only — spot-check an automated reviewer's
    GitHub-bound output language against Rule-Ref: AG-GH-001 whenever a review is
    observed; no automated pass/fail signal exists for this today.
  - **Non-Expansion**: this exception covers only automated-reviewer output
    language checking. It does not extend to any other AG-CC-*/AG-GH-*
    requirement, and does not exempt a human contributor's or an agent's own
    GitHub-bound output from Rule-Ref: AG-GH-001 in any way. Revisit if this tool (or
    a future one) ever exposes an on-demand, scriptable review trigger that
    would make a real CI check practical.

- **Recorded exception (2026-08-08, issue #1095 G2, `AGENTS.md`'s AG-VAL-029
  Known-Gaps entries): two `set -e`/`$?`-dependent construct shapes stay
  manual-review-only, no durable CI guard.** Full technical detail lives in
  `AGENTS.md`'s Known Gaps section under `AG-VAL-029 assessment
  (2026-08-08, ...)` (two entries); this entry exists so this document's own
  Coverage Assessment does not silently omit them, per AG-VAL-029's own
  requirement that an unautomatable case be recorded here, not only
  elsewhere.
  - **Scope**: (1) a fail-closed helper's `$(...)` call embedded directly
    inside a larger command's argument list (`printf`/`echo` with the
    substitution buried in an argument) instead of assigned to its own
    variable first; (2) a `scripts/lib/*.sh` file that is sourced elsewhere
    and sets a bare, non-`local` top-level variable whose name can collide
    with a caller's own identically-named variable.
  - **Reason**: both are call-site *shapes*, not fixed function/variable
    names — a denylist would miss future instances, and a shape-based regex
    (any `$(...)` nested in another command's arguments; any bare top-level
    assignment in a sourced lib file) flags the overwhelming majority of
    ordinary, harmless code in this codebase as a false positive. This is
    the same class of judgment call AG-VAL-028 already documents as
    resisting cheap, reliable mechanical detection for the AG-CODE-* family.
  - **Tracking**: `AGENTS.md`'s Known Gaps section, `AG-VAL-029 assessment
    (2026-08-08, ...)` entries (two, immediately following the sparse-checkout
    entry above in that file's own list); issue #1095's G2 finding.
  - **Validation**: the two real instances that prompted this (embedded-call
    shape: `scripts/lib/validation-image-tag.sh`'s `vit_resolve_tag()` and
    `.github/workflows/build-push-hosted-fallback.yml`'s short-SHA step;
    top-level-variable-collision shape: `scripts/lib/validation-image-tag.sh`
    self-sourcing `scripts/lib/docker-metadata.sh` and clobbering
    `scripts/plan-deep-validation.sh`'s own `script_dir`) are each fixed and
    covered by their own bats regression case. The embedded-call shape is
    covered directly by `tests/bats/docker_metadata.bats` (the
    `set -euo pipefail` reproduction of the hosted-fallback workflow's own
    shell shape) and `tests/bats/validation_image_tag.bats` (`vit_resolve_tag()`
    exercised in isolation). The `script_dir` collision specifically is
    **not** covered by either of those two files -- both source the affected
    libraries directly and never set a caller-owned `script_dir` first, so
    neither can observe a clobber of it. That collision's actual regression
    coverage is `tests/bats/plan_deep_validation.bats`, which runs
    `scripts/plan-deep-validation.sh` end to end as a real subprocess (not a
    sourced function call) and therefore does set `script_dir` before
    sourcing `validation-image-tag.sh`, then still depends on that same
    `script_dir` afterward for `detect-full-setup-changes.sh` -- a clobber
    would make that later step resolve the wrong path and fail the test's
    `status -eq 0` assertion. No standing CI guard exists against a *future*
    instance of either shape; manual code review is the only current check.
  - **Non-Expansion**: this exception covers only these two named call-site
    shapes as they exist today. A future instance of either shape found
    elsewhere in the repo is a new occurrence to fix on its own merits
    (Rule-Ref: AG-WF-011), not automatically covered by this entry, and a
    third occurrence of the same underlying pattern should prompt revisiting
    whether a mechanical guard is worth the false-positive cost after all
    (Rule-Ref: AG-WF-025).

- **F-17 SHA retention audit: no "previous nightly" protection** (PR #1501,
  2026-08-14) — the protected-reference model protects only the exact digest
  `nightly` currently points at, not whichever digest it pointed at
  immediately before that. GHCR's package-version API exposes no tag
  history at all (only the current pointer), so proving "the previous
  nightly build" requires reading `nightly-refresh.yml`'s own GitHub Actions
  run history via a new `actions: read` permission and API surface this
  audit's workflow does not have today. In practice, `accepted_ordinary_
  roots_per_package` (30) already retains far more than one prior build's
  `sha-<commit>` root as ordinary ranked history regardless of channel-tag
  status, so a last-known-good nightly commit typically stays available as
  an ordinary root even without dedicated channel-level protection — but
  this is incidental retention, not a proven guarantee. **Tracking**: PR
  #1501's `#issuecomment-5292505929` records the open maintainer decision on
  whether to build the dedicated lookup.

---

## Appendix — Reusable Scripts/Commands Index

| Script / command | Proves |
|---|---|
| `scripts/untracked/simulations/dhcp-relay-flow-simulation.sh` | Real two-segment DHCP relay (PR #1117) |
| `scripts/untracked/simulations/nats-secondary-auth-callout-simulation.sh` | NATS secondary lifecycle, active-disconnect (`connz`/`KICK`), xkey encryption (packet capture + negative control) |
| `scripts/untracked/simulations/setup-reset-dns-config-simulation.sh` | Real CLI-driven PowerDNS zone rollback (PR #1152) |
| `scripts/untracked/simulations/setup-reset-kea-config-simulation.sh` | Real CLI-driven Kea config rollback |
| `scripts/untracked/generate-vex.sh` / `scripts/tracked/check-vex-drift.sh` | OpenVEX document reproducibility and drift detection (PR #1194) |
| `tests/bats/setup_update_idempotence.bats` (first `@test`) | `.env` key-drift guard (PR #1199) |
| `scripts/tracked/check-idempotence-test-coverage.sh` | Every stateful config-writer has repeat-run/idempotence test coverage |
| `scripts/tracked/check-bats-path-filter-coverage.sh` | Every real bats dependency is covered by `build-tools.yml`'s path filters |
| `scripts/tracked/check-workflow-service-lists.sh` | Hardcoded service arrays stay in sync across workflow files |
| `scripts/tracked/check-naming-consistency.sh` | Container-name/allowlist/env-var naming contract (`docs/naming-conventions.md`) |
| `scripts/tracked/check-file-headers.sh` | File-header contract (`AG-HDR-*`) |
| `scripts/untracked/check-trivy-action-direct-usage.sh` | `aquasecurity/trivy-action` is only ever invoked through `.github/actions/trivy-scan-retry` (issue #1535, AG-CI-013, quoted or unquoted `uses:` scalars alike), and every real call site (`.github/workflows` and `.github/actions`) sets both `dockerhub-username`/`dockerhub-password` to a real, non-empty `secrets.*`/`inputs.*` reference, not merely present (issue #1535 follow-up) |
| `scripts/untracked/classify-image-impact.sh` | The single source of truth for "which subsystem does this diff touch" — reused by this document's own staleness reasoning, `detect-changes`, and the `promote` job's version-bump logic |
| `scripts/untracked/validate-stack-images.sh` | Release-notes/workflow status-line consistency |
| `scripts/untracked/select-build-tools-image.sh` | Resolves the pinned build-tools image/digest for every container-based check above |
| `scripts/untracked/simulations/full-setup-client-simulation.sh` | Full-setup harness client-side probe |
| `gh workflow run full-setup-validate.yml --repo wiki-mod/lancache-ng --ref <branch>` | Manually triggers the `workflow_dispatch`-only stack-simulation suite (does not run automatically on PRs) |
