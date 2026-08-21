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
   bash scripts/classify-image-impact.sh <last_validation.commit> <commit under test>
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
- `full-setup-validate.yml` (11 jobs incl. `full-setup-sims` composing the reusable
  `full-setup-sims.yml`) is **`workflow_dispatch`-only** — it does not run
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
  <branch>` — or running the underlying `scripts/*-simulation.sh` script directly
  against a real stack over SSH on a Linux host, not assuming a green `current_dev`
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
| **DHCP — dnsmasq ProxyDHCP** | `dhcp_proxy_known_good_snapshot.bats`/`dhcp_proxy_optional_directives.bats` pass; PXE-relevant options actually get injected | Same bats files; `full-setup-validate.yml`'s `dhcp-proxy-pxe-simulation` job for a real PXE client boot-option probe | Fail if bats fail or the PXE simulation doesn't observe the expected boot options on the wire |
| **DHCP — dnsmasq relay** (new, PR #1117) | `dnsmasq-relay` mode genuinely **relays** (not just injects options) between two network segments | `bash scripts/dhcp-relay-flow-simulation.sh` (build-tools container / real Docker host) — this is the exact script #1117 used: two isolated bridges (client-net, server-net), a real `dhclient` DISCOVER on the client-net side, confirms the upstream DHCP server on the separate server-net received the request via the relay's `giaddr` and answered with a lease from the *client subnet's* pool. `tests/bats/setup_dhcp_mode.bats` for the mode-selection/config-render unit coverage | Fail unless the granted lease's subnet matches the client-side pool specifically (proves `giaddr` routing worked, not a coincidental same-subnet fallback) |
| **DNS — PowerDNS zones/RPZ** | Real DNS resolution (recursor + authoritative), zone writes propagate, RPZ wildcard coverage is correct | `dig` against `dns-standard`/`dns-ssl` for a known CDN domain and a known `.lan` record — `ping`/`ss` are explicitly **not** acceptable substitutes (`AG-VAL-019`/`AG-VAL-020`). `tests/bats/dns_zone_generation.bats`, `dns_known_good_snapshot.bats`, `dns_config_snapshot_idempotence.bats` | Fail if `dig` doesn't return the expected record, or any DNS bats file fails |
| **DNS — reset-to-known-good** (new, PR #1152) | `setup.sh reset-to-last-known-good-config dns <zone>` genuinely rolls a live PowerDNS zone back | `bash scripts/setup-reset-dns-config-simulation.sh` (real full-setup stack: makes two real UI-driven zone writes, each producing a real snapshot, then runs the actual CLI against the earlier snapshot, confirms via a real `dig` query that the record content actually reverted). Note from #1152 itself: this script's own real run required two environment-only deviations at the time (a locally built `dns` image; a patched healthcheck probe domain, both because of the unrelated, since-fixed #1150 bug) — when running it again, confirm no deviation is needed anymore before treating a clean run as fully representative | Fail unless the post-rollback `dig` result matches the earlier snapshot's content exactly, and the CLI genuinely used the in-container `PDNS_API_KEY` (the script deliberately seeds a wrong host-side key as a regression guard for this) |
| **NATS — secondary registration/rotation/removal** | Per-secondary credential isolation; rotation invalidates the old credential; removal actually blocks | `bash scripts/nats-secondary-auth-callout-simulation.sh` against a real `nats-server` + a real `nats-subscriber` built from the branch under test | Fail if an old credential still authenticates after rotation, or a removed secondary can still connect |
| **NATS — active disconnect on remove/rotate** (new, PR #1172) | A secondary already connected *at the exact moment* of removal/rotation is force-disconnected within seconds, not left connected until its next reconnect (up to 90 days under the old JWT TTL) | The same `nats-secondary-auth-callout-simulation.sh`, extended in #1172: hold a real `nats-subscriber` connection open, confirm it's live via `nats-server`'s own `connz` HTTP monitor endpoint, remove/rotate that secondary from the Admin UI **while still connected**, then **poll `connz` until the connection actually disappears** — the HTTP 200 from the removal API call is not the proof; the connection's disappearance from `connz` is | Fail if `connz` still lists the connection after a reasonable poll window, or if an unrelated secondary's connection is also kicked (over-broad `CONNZ` filter) |
| **NATS — xkey encryption** (new, PR #1168) | The auth-callout request/response is genuinely encrypted on the wire, not just configured | The packet-capture phase `nats-secondary-auth-callout-simulation.sh` gained in #1168: capture real `nats-server`↔Admin-UI traffic, assert the sealed-box `xkv1` marker is present AND the JWT's own literal base64 header marker is **absent** (checking for the raw password substring is **not sufficient** — the payload is always base64-JWT-encoded regardless of encryption, so a naive substring check "passes" unconditionally; #1168's own methodology note documents this exact false-positive trap). Run once with `xkey:` configured (must show encrypted) and once with it removed as a negative control (must show the plaintext marker) — a check that can't fail is not a check | Fail if the plaintext JWT header marker appears in a run where `xkey` is configured, or if the negative-control run does *not* show it (proves the assertion methodology itself still discriminates) |
| **Admin UI — cache-resize** (new, PR #1174) | A submitted resize genuinely changes what nginx enforces, not just what the dashboard displays | Submit a resize via the UI/API, wait for the ~5-minute `lancache-converge.service` tick, then `docker exec <proxy container> nginx -T 2\>&1 \| grep proxy_cache_path` and confirm the rendered `max_size=` value actually changed to the new target — a `200 OK` from the form or an unchanged dashboard number is **not** proof. On `deploy/quickstart` this reaches the real proxy; on a manual `deploy/prod` checkout it does **not** (documented gap in #1174 — the `ui` container's own display updates but `config/prod/proxy.env` is untouched) — validate against the deployment profile actually in use and do not assume `deploy/prod` behaves like `deploy/quickstart` here | Fail if `nginx -T`'s rendered `max_size` doesn't match the submitted value on quickstart; on `deploy/prod`, confirm this known-misleading-display gap is still documented, not silently "fixed" by an unrelated change without updating this plan |
| **Watchdog — dashboard health card** (new, PR #1165) | The dashboard's color indicators reflect real, live container health — not a frozen or fabricated state | Stop a monitored container (`docker stop lancache-dns-ssl`), wait one `watchdog.sh` cycle (default 30s), `curl http://<ui>/api/watchdog-status` and confirm the entry flips to `red`/`unhealthy`; restart it and confirm it flips back to `green`. Confirm a deliberately stale/missing `status.json` renders `Stale`/`Unavailable`, not a silently frozen last-known color | Fail if the API/dashboard doesn't reflect a real state transition within roughly one `CHECK_INTERVAL` |
| **Watchdog — NATS monitoring** (new, PR #1167) | A hung (not crashed) `nats` container gets detected and restarted | `docker kill --signal=STOP lancache-nats` from **outside** the container's PID namespace (an in-container `kill -STOP 1` is a no-op — PID 1 ignores unhandled stop/kill signals from within its own namespace, confirmed live in #1167), wait 3× `CHECK_INTERVAL`, confirm watchdog logs `RESTARTING lancache-nats` and `docker inspect --format='{{.State.StartedAt}}'` shows a genuinely new start time | Fail if no restart occurs after 3 consecutive unhealthy reads, or if `StartedAt` is unchanged (a restart request that silently failed) |
| **Edition-2024 build (PR #1179)** | All three Rust crates actually build/test/lint clean on the real target (Linux, build-tools container) — not just a Windows-side `cargo check` | For each of `services/ui`, `services/dns/nats-subscriber`, `tools/pxe-client-probe`, inside the build-tools container: `cargo fmt --manifest-path <crate>/Cargo.toml -- --check`, `cargo check --locked --all-targets --manifest-path <crate>/Cargo.toml`, `cargo clippy --locked --all-targets --manifest-path <crate>/Cargo.toml -- -D warnings`, `cargo test --locked --manifest-path <crate>/Cargo.toml`. A **Windows-authored** `cargo check` result is not acceptable evidence per `.github/AGENTS.md`'s build-tools-container contract — the Windows host cannot build Rust for this project's Linux/Docker targets at all | Fail on any non-zero exit from any of the four commands for any of the three crates, or if the check ran outside the pinned build-tools container |
| **SBOM/VEX generation (PR #1194)** | `scripts/generate-vex.sh`'s output matches the committed `vex.openvex.json` byte-for-byte, and the drift guard actually fails when it should | `bash scripts/check-vex-drift.sh` (must report in-sync); `bash scripts/generate-vex.sh \| jq empty` (must be valid JSON); as a negative control, mutate `.trivyignore.yaml` in a scratch copy and re-run the drift guard, confirming it exits non-zero with a clear diff (already proven once, 2026-07-24 — reuse this exact reusable check going forward rather than re-deriving it) | Fail if the drift guard passes on a real mismatch (the negative control), or if it reports drift on an untouched checkout |
| **Fixture key-drift guard (PR #1199)** | The bats guard actually catches a reintroduced historical `.env`-key gap, not just that it parses | `bats tests/bats/setup_update_idempotence.bats` (guard test runs first, must pass on a clean checkout). As a negative control, remove one known-required key (e.g. `NTP_ENABLED`) from `write_converged_env_fixture()` in a scratch copy and re-run — must fail naming that exact key (already proven once, 2026-07-24 — reuse this exact check) | Fail if the guard doesn't name the specific missing key on the negative control, or passes when a key truly is missing |
| **CI/build-tools infra** (path-filter narrowing, permissions hardening — PRs #1190/#1202/#1204) | The narrowed path filters/permissions still trigger for every real change they must cover, and don't over- or under-trigger | `bash scripts/check-bats-path-filter-coverage.sh` (asserts every real bats dependency is covered by `build-tools.yml`'s path filters); `bash scripts/check-workflow-service-lists.sh` (keeps hardcoded service arrays in sync across workflow files); `actionlint -config-file .github/actionlint.yaml <changed workflow files>` for syntax/permissions/runner-label review per `AG-VAL-011` | Fail if either check script reports a gap, or `actionlint` reports any finding |
| **Governance docs (AGPL/MAINTAINERS/OSPS/SBOM policy PRs)** | Documentation actually matches current code/CI behavior, not aspirational text | `bash scripts/check-file-headers.sh` (header contract); manual read-through of each touched doc against the actual current code path it describes, per `AG-DOC-001`. There is no automated drift-detection tool for this yet (`AGENTS.md`'s own "Known Gaps" section says so explicitly) — this remains a manual-review item | Fail (flag as a defect, not skip) if a doc's claim contradicts current code behavior |
| **actionlint SIGKILL guard** (2026-07-25 runner-leak incident, AG-CI-016/017) | A hung, signal-deaf `actionlint` process inside `build-tools.yml`'s lint step is force-killed from inside the container, not left to leak the runner slot | Read the step's `timeout --kill-after=<grace> --signal=KILL <limit>` wrapper around both lint invocations in `.github/workflows/build-tools.yml`; on a self-hosted runner host, confirm no `actionlint` process older than the configured limit+grace is running (`ps -eo pid,etime,cmd \| grep actionlint`) after a normal run completes. Reproducing the actual Go-runtime deadlock on demand is not practical — this remains a structural/timeout-mechanism proof, not a live-deadlock reproduction (documented gap, matches this incident's own on-host verification standard) | Fail if any `actionlint` process survives past `<limit>+<grace>` on a real run, or if the wrapper is missing from either lint step |
| **BuildKit build-tools-image concurrency serialization** (2026-07-25, AG-CI-016/017, issue #1065) | Concurrent `build-tools.yml` amd64 image builds on the same self-hosted runner host no longer race on the shared BuildKit content store | Read the `concurrency:` group added to the amd64 build-tools-image job in `.github/workflows/build-tools.yml` (job-level constant group, `cancel-in-progress: false` — queues rather than cancels). Trigger two PRs whose diffs both touch `tools/build-tools/**` in quick succession and confirm via the Actions run queue that the second run genuinely waits (queued state) rather than starting concurrently and hitting the `ref layer-sha256:...locked...unavailable` signature again | Fail if two such builds run concurrently on the same host, or if the layer-lock signature recurs in a real run |
| **Q1 — build-tools.yml trigger narrowing + build-tools-smoke.yml** (2026-07-25, issue #1253) | `build-tools.yml` only rebuilds the image for real `tools/build-tools/**` content changes; `build-tools-smoke.yml` still runs bats/shellspec against the published image for every other test/script-relevant change | `bash scripts/check-bats-path-filter-coverage.sh` (now targets `build-tools-smoke.yml`, per its retargeted header comment — confirm it still reports full coverage); open a scratch PR touching only a `tests/bats/**` file (not `tools/build-tools/**`) and confirm `build-tools.yml`'s image-build job does not trigger while `build-tools-smoke.yml` does and passes | Fail if a test-only change still triggers a full image rebuild, or if a real `tools/build-tools/**` change fails to trigger one |
| **Runner-host cleanup script, versioned in-repo** (2026-07-25, `tools/runner-host/`) | The cleanup script actually reclaims disk (measure → clean → re-measure), reaps stale/orphaned build-tools containers across all self-hosted hosts, and is consistent (not host-local/ad-hoc) | `shellcheck tools/runner-host/*.sh` (must be clean); run the script for real on a self-hosted runner host via SSH, capture disk usage before/after, confirm the after-measurement shows real reclaimed space and that no `docker ps -a` entries for stopped/hung build-tools containers remain | Fail if the script only measures without a real reduction, or if it's missing from any host it's meant to run on |
| **CVE-2026-34040 non-exploitability documentation** (2026-07-25, `.trivyignore.yaml`) | The accepted-risk justification is a verified technical claim (vulnerable code is daemon-only, absent from the vendored client binaries), not a deferred "revisit later" placeholder | `bash scripts/check-vex-drift.sh` (must report in-sync after the regenerated `vex.openvex.json`); read the `.trivyignore.yaml` entry's statement and confirm it names the specific reason (module split at moby v29, vulnerable code in `pkg/authorization`, daemon-only, absent from `docker-buildx`/`docker-compose` client binaries) rather than a vague "no fix available yet" | Fail if the ignorefile reverts to a vague justification, or if a real Trivy scan of the built images still flags this CVE as unaddressed without an equally specific replacement justification |
| **New/renumbered governance rules — AG-CI-014, AG-CI-016/017 (post #1242 AG-CI-015 collision), AG-GH-008 correction, AG-WF-027** (2026-07-25) | `AGENTS.md` has no duplicate rule IDs, and the Rule Enforcement Matrix has a row for every rule | `grep -oE "\*\*\[AG-[A-Z]+-[0-9]+\]\*\*" AGENTS.md \| grep -oE "AG-[A-Z]+-[0-9]+" \| sort \| uniq -c` — every ID must appear exactly once as a rule definition (a second appearance elsewhere in prose as a `Rule-Ref:` cross-mention is fine; a second **definition** is not); cross-check each new/renumbered ID has a matching Rule Enforcement Matrix row | Fail on any duplicate rule-definition ID, or a rule missing its matrix row |
| **CI script ecosystem — case-insensitive repo-name comparisons** (fixed, PR #1360, 2026-08-01 — no dedicated tracking issue; #842 is the unrelated watchdog-monitoring issue this PR's Part 1 also happened to ship alongside) | No script anywhere in `scripts/**`/`.github/**` (including inline workflow shell) compares a GitHub repository-identity value (`GITHUB_REPOSITORY`, `HEAD_REPO`/`head_repository`, `GITHUB_EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME`, `BASE_REPOSITORY`, or an equivalent) with a bare, case-sensitive `==`/`=`/`!=` — GitHub repository names are case-insensitive for identity, but the two context values feeding such a comparison are not guaranteed to agree on casing at every point in time (confirmed live during this repo's rename to `LanCache-NG`: `scripts/lib/validation-image-tag.sh`'s `vit_pr_staging_available()` and `scripts/select-build-tools-image.sh`'s fork-vs-same-repo trust check both misclassified a genuine same-repo PR as a fork PR under the old casing, one fail-closed in the safe direction and one merely wrong). Both known call sites are fixed (`${x,,}` lowercasing on both sides, per each file's own incident comment) with dedicated regression coverage: `tests/bats/validation_image_tag.bats` (2 new cases) and the new `tests/bats/select_build_tools_image.bats` (6 cases) | `bats tests/bats/validation_image_tag.bats tests/bats/select_build_tools_image.bats` (must pass, including the same-repo-different-casing case in each); as the ecosystem-wide guard against a *third* call site reintroducing this bug class elsewhere: `grep -rniE '"\$\{?[a-z_]*repo[a-z_]*\}?"[[:space:]]*(==\|!=\|=)[[:space:]]*"\$' scripts/ .github/` (deliberately no `--include` filter — a bare-`.sh` restriction would silently skip `build-push.yml`'s ~9000 lines of inline bash, the most likely place a third call site would appear). **Verified 2026-08-01, both directions**: run against the pre-fix commit (`git show 433c3fd2^:scripts/select-build-tools-image.sh \| grep -niE '...'`, same pattern) correctly flags the exact pre-fix lines (`"$head_repo" == "$repository"`, `"$head_repository" = "$base_repository"`); run against the current tree returns zero hits (both fixed call sites now use `${x,,}`, which the pattern's brace-then-bare-name shape correctly does not match) — a check that can't fail is not a check, and this one demonstrably can. No dedicated script exists for this today, so it remains a documented manual/grep-assisted check, not yet automated as its own CI job (a candidate for future consideration under `AG-VAL-028`'s periodic-reassessment recommendation, not yet acted on); every hit still needs a human glance to confirm it's a genuine repo-identity comparison and not an unrelated `repo`-substring false positive. **Explicit scope note**: this check targets shell-level (`bash`/`sh`) comparisons only, matching the two real fixed call sites. It deliberately does **not** flag the ~15 GitHub Actions expression-level `${{ github.event.pull_request.head.repo.full_name == github.repository }}` comparisons already present in `build-push.yml`/`codeql.yml` (e.g. `PR_IS_FORK`'s own definition) — checked against GitHub's own documentation (`docs.github.com`'s Expressions reference), which states plainly that `==`/`!=` string comparisons in workflow expressions are already case-insensitive ("GitHub ignores case when comparing strings"), unlike bash's `[[ ]]`/`[ ]`. Those YAML-expression comparisons are therefore not part of this bug class and are correctly out of this check's scope, not an unexamined gap in it | Fail if either bats file fails, or if the grep turns up a new case-sensitive shell-level repository-identity comparison with no `,,` lowercasing |
| **build-push.yml — pushed image commit-label matches the PR's actual current head** (open gap, no structural fix yet — incident 2026-08-01, PR #1354) | A `build`/`build-arm64` run reporting `success` genuinely built and pushed the commit it claims to, not an earlier, already-superseded commit from the same branch | Confirmed live: rapid, closely-spaced `gh pr update-branch` calls on PR #1354 left `build-push.yml` labeling the pushed `proxy` image with `org.opencontainers.image.revision=220c80f` (a superseded commit) while the run's own reported `head_sha` was already the newer `c4c0e6b6` — a real `docker inspect <image> --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'` mismatch against `gh pr view --json headRefOid`, not merely a suspected race. The only remediation applied was an empty follow-up commit to force a clean, uncontested re-run (commit `2f737bcc`) — there is no code-level guard preventing recurrence, and no dedicated tracking issue exists yet (folded into the PR's own history only). Before trusting any `build`/`build-arm64` "success" as evidence for a specific commit — especially right after any rapid sequence of `gh pr update-branch`/force-push calls on the same PR — compare the pushed image's `org.opencontainers.image.revision` label against `gh pr view <n> --json headRefOid --jq .headRefOid` (or `git rev-parse HEAD` for a push event) for that exact SHA, not just a green check mark | Fail (and re-run) if the pushed image's revision label does not match the commit under test, regardless of the workflow run's own reported conclusion |
| **Untouched-service staging back-fill — ancestor fallback for a PR base commit with no push-triggered build** (fixed, 2026-08-01) | An untouched service's back-fill genuinely succeeds once the PR base commit is POSITIVELY confirmed both to have never had a push-triggered `build-push.yml` run at all AND to have changed only paths that match that trigger's own `paths-ignore` list (the two-part proof that this was a deliberate skip, not a CI outage silently misread as one) — WITHOUT weakening the #808/#626 fail-closed guarantee for a base commit whose build genuinely failed, is stuck, or is still running, and WITHOUT the two independent copies of this recovery logic (`scripts/ensure-pr-staging-images.sh` and `build-push.yml`'s own "Ensure PR staging tags exist for full-setup services" step) drifting apart | The shared implementation now lives in `scripts/lib/staging-ancestor-fallback.sh`, sourced by both callers so a fix to one can never leave the other exposed to the same bug class: `saf_base_commit_paths_are_ignorable()` (diffs the commit against its first parent and checks every changed path against `**/*.md`/`docs/**`, with `CHANGELOG.md` explicitly excluded — the missing safety property a bare "zero runs" reading cannot provide on its own), `saf_base_commit_has_confirmed_run()` (positively confirms zero runs of a given event type before considering any fallback — any run, or an inconclusive check after retrying through `ghcr_retry`, preserves today's strict failure), and `saf_find_built_ancestor()` (bounded, `--first-parent`-only ancestor walk — `git log --max-count` at the source, never piped through `head`, to avoid a real SIGPIPE-under-`pipefail` hazard — accepting a candidate's run of any TAG-PUBLISHING trigger type (push, workflow_dispatch, schedule — not push-only, but also explicitly not pull_request: a pull_request run's `github.sha` is a synthetic merge commit, not the candidate's own commit, so it never publishes that candidate's `sha-<commit>` tag regardless of what the Actions API's `head_sha` field reports for it), reusing `sif_wait_for_fresh_base_image()` against each candidate and never skipping that freshness proof; a run-less candidate is walked past only after its own changed paths are also positively confirmed ignorable, the same proof `saf_base_commit_paths_are_ignorable()` applies to BASE_SHA itself, so a mid-walk commit that introduced a real, unbuilt change can never be silently substituted away; a candidate whose run-check itself is inconclusive fails closed immediately rather than falling through to the freshness check on an unconfirmed candidate; a candidate whose own build-push.yml run is positively confirmed still active via `saf_candidate_run_is_active()` — a real race, not hypothetical, since several commits merging in rapid succession does not mean each one's build finished before the next one's ancestor walk runs — gets exactly one retry with its own dedicated extended budget, never a blind timeout increase (AG-CI-013); an inconclusive or confirmed-not-active answer changes nothing). All GitHub API calls go through `curl` + `GH_TOKEN` directly, never the `gh` CLI, since AG-CI-001/AG-CI-002 mean `gh` cannot be assumed present on the bare `lancache-light` runner tier both real callers actually execute on — depending on it would make this whole mechanism silently unreachable there; `curl` itself is also explicitly capability-checked (`command -v curl`) rather than assumed, since AG-CI-001 does not carve out an exception for it either; `GH_TOKEN` is read directly from the environment inside `_saf_github_api_get` rather than passed as one of its own positional arguments, so it can never appear in `ghcr_retry`'s own `::warning::`/`::error::` diagnostics (which log the wrapped command's full argument list verbatim on every failed attempt); the same `curl` call also carries explicit `--connect-timeout 10 --max-time 30` bounds, so a connection GitHub accepts but then stalls mid-transfer becomes a bounded, retryable failure instead of an unbounded hang that `ghcr_retry`'s own bounded-attempts design could never even reach; and a 401 (invalid token) or 404 (wrong endpoint/repository) response is classified as a permanent, non-retryable failure via `scripts/lib/ghcr-retry.sh`'s new `GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE` convention (a wrapped command signals "retrying cannot help" by exiting with this reserved code; `ghcr_retry` returns immediately instead of exhausting its full backoff budget), while every other non-200 status (5xx, 403/429, a malformed response) stays on the ordinary retryable path exactly as before. `saf_find_built_ancestor()`'s own per-candidate run-existence lookup is also cached for the lifetime of the process, keyed by (repository, candidate) — a long docs-only ancestor chain otherwise means every untouched service independently re-walks and re-queries the identical candidate history against a shared, repository-scoped API rate limit; only a DEFINITIVE answer (a run exists, or is confirmed absent) is ever cached, never an inconclusive one, so a transient query failure for one service can never poison a later, independent query for another. This cache is deliberately scoped to ONLY the ancestor-candidate lookup, not to `saf_base_commit_has_confirmed_run()` generally — BASE_SHA's own push-run check inside `saf_resolve_untouched_backfill_source()` is independently re-derived twice on purpose (see that function's own header), specifically so a fast-path bug can only cost time, never safety, and a shared cache at a lower level would have silently defeated that guarantee. `saf_resolve_untouched_backfill_source()` orchestrates all of it, including a fast path that checks both proofs BEFORE the long freshness wait so a confirmed-deliberate skip fails/falls back in seconds rather than waiting out the full ceiling first, and takes THREE independent freshness-budget pairs rather than one shared pair: a long, congestion-scale pair for the wait against BASE_SHA's own image (the one wait in this mechanism that can legitimately be racing a real, still-building push run), a short pair for `saf_find_built_ancestor()`'s own per-candidate INITIAL checks (an already-confirmed-run historical ancestor's image either exists already or never will, so a long ceiling there only slows down every fallback for no correctness benefit — collapsing this back into the long pair would hard-fail this gate on a perfectly healthy, still-running build), and a third, separate pair governing ONLY the one-time extended retry for a candidate confirmed still active. That third pair was originally the SAME parameter as the long BASE_SHA pair (deliberately, reasoning "the same patience BASE_SHA's own possibly-in-progress build already gets") until a Codex review on this PR correctly identified that this let `build-push.yml`'s own "Ensure PR staging tags exist for full-setup services" step (inside `full-setup-validate`, `timeout-minutes: 30`) implicitly inherit a fresh, up-to-5400s (90-minute) extension it cannot survive — that job would simply be killed by its own GitHub Actions job timeout partway through the wait, never rescuing an image landing more than a few minutes into it, unlike `scripts/ensure-pr-staging-images.sh`'s own caller (`full-setup-deep-validate.yml`'s "ensure PR staging images" job, `timeout-minutes: 100`, explicitly sized for exactly this scenario). Making the extended budget its own explicit parameter lets each caller size it honestly against its own job envelope: `scripts/ensure-pr-staging-images.sh` still passes 900/5400 (its 100-minute job affords it), while `build-push.yml`'s step now explicitly passes `0 0` (this 30-minute job's own real runs are 30-71s; there is no meaningfully-sized extension that both fits its remaining budget, shared across every untouched service the loop checks, and outlasts the short budget already just tried) — a caller-scoped, principled fix, not a blind timeout bump: the extended-retry mechanism itself is unchanged and still fully benefits the caller whose job was actually built for it, while the caller that cannot afford it degrades to exactly the fail-fast behavior it already had before the mechanism existed. The mutable `nightly`/`latest` channel tags are never touched — only one immutable per-commit tag is ever substituted for another. `tests/bats/ensure_pr_staging_images.bats` gained 6 new integration cases (13→19) exercising this end-to-end through the real script (ancestor 2 commits back found and used; bounded depth genuinely stops before reaching a further-back usable ancestor; no ancestor anywhere fails closed distinctly; a confirmed run on the base commit itself preserves the existing strict failure with no fallback attempted; an inconclusive run-check is treated the same as a confirmed run; a real non-doc path change blocks the fallback even with zero push runs — the single most important regression guard for this mechanism); the new `tests/bats/staging_ancestor_fallback.bats` (55 cases) unit-tests the shared library directly, including the SIGPIPE regression, a real merge-commit fixture proving `--first-parent` is honored, curl-based retry/backoff behavior (including a non-200 HTTP status being treated as retryable, not accepted as a false zero, and a missing `curl` binary itself being treated as an explicit capability-check failure, not an assumption), non-push-run acceptance for ancestor candidates, the two-budget split (a confirmed-in-flight BASE_SHA build must resolve under the long budget even when the short ancestor-candidate budget alone would have already timed out), the same paths-are-ignorable proof applied to every skipped ancestor candidate mid-walk, not only BASE_SHA itself (a run-less candidate that itself touched a real, non-doc path must block the walk rather than let it substitute an older, unrelated ancestor), an inconclusive run-check for a candidate failing closed rather than falling through to the freshness check on an unconfirmed candidate, the ancestor-candidate build-proof query never counting a pull_request-triggered run (its github.sha is a synthetic merge commit, not the candidate's own sha, so it never publishes that candidate's sha-<commit> tag) while still stopping at the first confirmed tag-publishing event type rather than always querying all three, an unset GH_TOKEN failing closed rather than depending on a real `gh` CLI/network call, and a candidate confirmed still building via `saf_candidate_run_is_active()` getting exactly one extended-budget retry (with dedicated cases proving a confirmed-not-active or inconclusive activity check never triggers that retry, even when a longer wait would otherwise have succeeded, and a missing `curl` binary for this same activity check being treated as its own explicit capability-check failure, mirroring the identical guard in `saf_query_run_count` rather than assuming the caller already checked), a dedicated case proving `GH_TOKEN` never appears in any of `ghcr_retry`'s own retry/failure diagnostic lines (forcing every attempt to fail and asserting the token string is absent from `stderr`, not merely that GitHub's own masking would have hidden it), and a dedicated case proving the extended-retry budget is genuinely independent of the long BASE_SHA budget (a generous 300/600 BASE_SHA pair alongside a `0 0` extended pair must fail fast on a candidate that would only resolve at ~3 real seconds, proving the two are no longer silently the same value), a dedicated case proving a `0 0` extended budget still performs one genuine freshness re-check rather than none at all (a call-count-based stub reporting stale on its first invocation and fresh from the second onward must still resolve successfully via that second, extended-position check), a case proving a 401 and a case proving a 404 both fail fast on the first attempt rather than exhausting the full retry budget, and two cases proving the ancestor-candidate run-lookup cache: one proving a repeated call for the same candidate (simulating a second untouched service) hits the cache instead of re-querying, and one proving an inconclusive answer is never cached (a later, independent query for the same candidate can still succeed) — plus a case proving BASE_SHA's own intentionally-independent pre/post push-run re-derivation in `saf_resolve_untouched_backfill_source()` is unaffected by that cache (both checks still genuinely execute), and an end-to-end case with curl genuinely absent from `PATH` throughout an entire `saf_resolve_untouched_backfill_source()` call (not just a low-level function's own return code) proving the inconclusive answer this produces is never misread as a genuine confirmation: the call fails, and the "Substituting nearest built ancestor" success message that would mean the ancestor substitution fired never appears; a case proving `saf_base_commit_paths_are_ignorable()` correctly distinguishes a genuinely empty commit (a real parent, zero changed paths -- `git diff-tree` exits 0, found no differences) from a failed diff against a root commit (no parent to diff against -- `git diff-tree` exits 128), since both produce identical empty stdout and only the diff's own exit status tells them apart: the empty commit is confirmed ignorable (status 0), not inconclusive; and the mid-walk counterpart of that same fix inside `saf_find_built_ancestor()` itself, proving a run-less ancestor candidate that is itself a genuinely empty commit is walked past to an older, real ancestor instead of blocking the walk the way a genuinely unconfirmable candidate correctly still does; the Authorization header itself is no longer passed to `curl` as a literal `-H "Authorization: Bearer <token>"` argument (visible for the process's lifetime to any other process running as the same host user via e.g. `/proc/<pid>/cmdline` on a shared self-hosted runner) nor written to a mode-600 temp file (file permission bits protect against other USERS, not other processes owned by the identical UID, which could still derive the file's own path from curl's own argv and open it directly) but supplied via curl's own `-K -` (config read from stdin) as a bash here-string, which this project's own pinned bash implements as a pipe rather than a temp file, so no file containing the token's value ever exists on disk at any point; dedicated cases prove the token never appears in curl's own invoked argv (only the literal, harmless `-K -`), that the token's value never appears in any file anywhere under `$TMPDIR` (recursively, not just a specific expected path), and that the header content is genuinely fresh on every `ghcr_retry` attempt, not just the first (since `_saf_github_api_get` is re-invoked as a fresh function call, and therefore a fresh here-string, on each retry). `SAF_ANCESTOR_RUN_CACHE_DIR`'s own directory is no longer left behind unconditionally on every process that ever sources this file (mktemp's uniqueness means it is never reused by a later run, so on a long-lived self-hosted runner that leaked without bound) but removed via an EXIT trap that composes with -- rather than silently discards -- any EXIT trap the calling script had already installed for its own purposes, using `eval` (not manual prefix/suffix string slicing, which cannot correctly undo bash's own escaping for a single quote embedded in the prior trap's own command) to recover and re-chain that prior trap exactly. Dedicated cases prove: the directory's removal; a pre-existing trap's own effect still firing; a pre-existing trap whose own command contains an embedded single quote surviving the chaining byte-for-byte (verified empirically first that bash 5.2 -- the version in the pinned build-tools image -- fires its EXIT trap on SIGTERM even with no explicit TERM trap of its own); and -- under the `set -euo pipefail` both real callers use, which is the only configuration in which either half can break -- BOTH that the prior trap runs AT ALL for a failing script and that the `$?` it reads is the script's own real exit status. Those two are one property, not two: the ordering that satisfies them is invoking the prior trap FIRST and doing the cache cleanup after it. Doing the cleanup first overwrites `$?` with the cleanup's own successful `rm` (a genuine CI failure reported to the prior trap as `0`), and the obvious remedy -- capturing `$?` and restoring it via an `(exit "$captured_status")` subshell before calling the prior trap -- is strictly worse: that subshell IS a failing command, so under `set -e` it aborts the trap body and the prior trap never runs at all. Both behaviours were reproduced live on bash 5.2 (the pinned build-tools image's version) against the real library file, and the regression cases now set `set -euo pipefail` themselves for exactly this reason -- an earlier version of the exit-status case did not, and therefore passed against an implementation that silently skipped the prior trap on every real failure. Cleanup is additionally backstopped by placing the cache directory (and every API response body file) under `$RUNNER_TEMP` when GitHub Actions provides it, since no EXIT trap can survive the SIGKILL a job-timeout expiry ultimately delivers, while Actions wipes `RUNNER_TEMP` itself between jobs; a dedicated case asserts that placement. The composition's real scope is also stated rather than overclaimed in the file's own header: it composes with an EXIT trap the caller registered BEFORE the `source` line and nothing else, and no caller in this repository registers one at all today. The ancestor-candidate run-existence cache's own on-disk entries are now written via a temp file plus atomic rename rather than a direct redirection (a write that fails partway, e.g. the runner's disk filling up, can otherwise leave an empty regular file behind even with the write's own error swallowed) and validated on read to be exactly `"0"` or `"1"` (anything else, including empty, is treated as a cache miss and re-queried, not silently read as arithmetic `0` -- the single most permissive, and wrong, outcome for a failed write); a dedicated case simulates exactly that corrupted-empty-file scenario and proves a genuine re-query still happens. `saf_find_built_ancestor`'s own "validate every skipped ancestor" check no longer fails closed on a run-less candidate with a real (non-doc) path change purely because GitHub Actions' own workflow-run retention window has expired for that candidate -- this project's durable per-commit `sha-<short>` image tags (docs/release-versioning.md) are not subject to that retention, so a positively confirmed existing, correctly-labeled image for that exact candidate is now accepted as stronger, retention-independent proof of a genuine build and used directly, with the original fail-closed behavior preserved only when that image ALSO does not exist (covered by both the original negative case and a new positive case; a pre-existing integration case in `tests/bats/ensure_pr_staging_images.bats` needed its own revision stub properly scoped to the specific image tag queried, since it had never previously needed to distinguish one candidate's image query from another's) -- `scripts/ensure-pr-staging-images.sh`'s own `build_push_run_active()` congestion probe now shares that same `curl`-based query through the library's `saf_event_has_incomplete_run()` instead of keeping a second `gh api --jq` implementation of the identical question -- the last `gh`/`jq` dependency in a script that runs on the bare `lancache-light` tier, where AG-CI-001/AG-CI-002 mean a missing `gh` silently downgraded that probe to a permanent "not active" -- and `tests/bats/ensure_pr_staging_images.bats`'s #975 fixtures now stub `curl` rather than `gh`, so the real query construction stays exercised. `bats tests/bats/ensure_pr_staging_images.bats tests/bats/staging_ancestor_fallback.bats` (74 cases total, must all pass); `tests/bats/ghcr_retry.bats` gained 2 new cases (10→12) for the shared `GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE` mechanism this fix's fail-fast-on-permanent-error behavior relies on (one proving the immediate return with no retry/backoff/relogin, one proving every other exit code's existing retry behavior is unaffected); `shellcheck --severity=warning` and `actionlint` clean on the changed shell files and `build-push.yml`; as a durable, non-rotting negative control (deliberately not pinned to any one historical commit, since GitHub's workflow-run retention window means a hardcoded SHA reference here would eventually stop reflecting real state for reasons unrelated to correctness): pick the current tip of `current_dev` via `git rev-parse origin/current_dev` and confirm `gh api repos/wiki-mod/lancache-ng/actions/workflows/build-push.yml/runs?head_sha=<that sha>&event=push` returns at least one run if that commit's own diff touches a non-doc path, or reason about why it doesn't otherwise — the discriminating query shape itself (event-scoped `head_sha` lookup) is what must keep working, not any specific commit's answer | Fail if either bats file regresses (especially the "confirmed run -> no fallback" and "real path -> paths gate blocks fallback" cases, the two load-bearing fail-closed guards), if `shellcheck`/`actionlint` reports a new finding, or if the `gh api` query shape itself stops discriminating a commit with a real run from one without |
| **pipefail/SIGPIPE early-exit-consumer pattern in `tools/build-tools/Dockerfile`** (fixed, PR #1374, issue #815, 2026-08-01) | An early-exiting consumer (`grep -q`/`grep -m`, `head`, `sed -n`) piped from a still-writing producer under `set -o pipefail` cannot silently fail the pipeline with an unrelated-looking exit code (141/SIGPIPE) again in this specific file | Real CI job 91393831566 (run 30709307913) failed exactly this way on `rustup target list --installed | grep -qx ...` / `rustc -vV | grep -qE ...`; fixed by capturing each producer's output into a variable first, then grepping the variable via a here-string. `bash scripts/check-pipefail-early-exit-grep.sh` (wired into the `shellcheck`/`shellcheck-hosted` jobs in `build-push.yml`); `bats tests/bats/check_pipefail_early_exit_grep.bats` (11 cases, including a negative control reproducing the exact incident pattern and confirming the guard catches it, plus confirming the real fixed Dockerfile passes) | Fail if the guard script reports a finding in `tools/build-tools/Dockerfile`, or if the negative-control bats case stops catching the reintroduced pattern |
| **Review-chronology code comments (AG-CODE-003 sub-pattern)** (2026-08-02) | No git-tracked source/config comment narrates the review chronology of the change it sits in ("caught in review", "before this fix", "flagged in review on PR #123", and similar phrasings) — these read as internal notes to the reviewer/author at PR-open time, not durable technical rationale, and go stale/confusing the moment the PR merges | `bash scripts/check-review-chronology-comments.sh` (wired into `build-push.yml`'s `file-headers` job); `bats tests/bats/check_review_chronology_comments.bats` (14 cases: 6 real-shaped positive fixtures proving the fail path is reachable per `AG-VAL-024`, including the reverse-order "a PR review (#765) found ..." shape and the self-review compound-word case; 5 deliberate near-miss negative fixtures — "manual review to notice it", "remembered during review", bare "regression pin", "after this PR merges"/"until this PR's OWN builds" — proving the tight adjacency regex does not over-match generic review/PR mentions; the excluded-file-type and self-reference-exclusion cases; and the "passes against the real repository tree" case). A real audit against this repo's own tracked files (2026-08-02) found eighteen genuine instances across fourteen files, fixed in the same pass this guard was added, so the check starts clean | Fail if the guard script reports any finding against the real tree, or if any of the 14 bats cases regresses (especially the 5 negative-fixture cases — a widened regex that starts flagging generic "review"/"PR" mentions is a false-positive regression, not an improvement) |

**Known, deliberately not-yet-closed gap (do not treat as silently dropped):** the guard above (`scripts/check-pipefail-early-exit-grep.sh`) is intentionally scoped to only scan `tools/build-tools/Dockerfile` -- the one file the confirmed incident occurred in -- not the whole repository. An earlier, wider version of the same script (scanning every `scripts/**`/`tools/**` shell file) found **41 preexisting instances** of the identical raw pattern (a live pipe into `grep -q`/`head`/`sed -n`) already in this codebase, e.g. `scripts/check-file-headers.sh`, `scripts/check-netdata-curl-pin.sh`, `scripts/setup-cli-simulation.sh`, `scripts/syslog-forwarding-simulation.sh`, and others. None of the 41 has a confirmed real failure behind it (most looked lower-risk on inspection -- a `printf`/short-string producer piped into `grep -q`, which rarely writes enough to fill a pipe buffer before the consumer's read completes, unlike `rustc -vV`'s larger multi-line output), but none has been individually triaged either. Fixing or reviewing all 41 in PR #1374 would have been a disproportionate scope expansion for a musl-toolchain/network-verification change with no reported incident in any of those 41 locations, and risked introducing real regressions into currently-working scripts under mechanical pattern-matching pressure. Tracked as **issue #1377** (repo-wide review of these 41 findings, plus widening `scripts/check-pipefail-early-exit-grep.sh`'s `scan_files` back to the full `scripts/**`/`tools/**` set once each has been triaged as either a real fix (capture-first) or a reviewed-safe `# pipefail-safe: <reason>` suppression).

---

## Part B — Stack Test Plan

Full end-to-end scenarios against the actually-running system on a real Docker host
(the Windows authoring/CI-orchestration environment cannot build or run this stack —
use a real Linux host, e.g. over SSH to a self-hosted runner, per
`.github/AGENTS.md`'s build-tools-container contract and the recurring
"no local Windows testing" note in prior validation passes).

### 1. Bring-up

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
  `build-push.yml` run against that exact commit. This applies to `scripts/*-simulation.sh`
  invocations too — `nats-secondary-auth-callout-simulation.sh` and
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
  <proxy>:8443 -servername steamcontent.com` and confirm the presented certificate is
  the real CDN's own cert, not this project's CA.
- **SSL/MITM mode**: same `dig` against the SSL DNS instance; `openssl s_client
  -connect <proxy>:443 -servername steamcontent.com -CAfile certs/ca.crt` and confirm
  the presented certificate **is** signed by the project's own CA (proves
  interception is actually happening, not merely configured).
- `ping`/`ss` alone are not acceptable substitutes for either check (`AG-VAL-019`/
  `AG-VAL-020`) — a real query/response or a real TLS handshake is required.

### 3. DHCP — all three modes

- **Kea**: real DHCPDISCOVER→DHCPOFFER→DHCPREQUEST→DHCPACK cycle via
  `dhcp-kea-lease-flow-simulation` (or its underlying script run directly), confirm a
  real lease was granted from the configured pool and is visible via Kea's Control
  Agent API.
- **dnsmasq ProxyDHCP**: real PXE boot-option probe via
  `dhcp-proxy-pxe-simulation`/`tools/pxe-client-probe` (the Rust PXE probe rewritten
  in PR #1159), confirm the expected boot filename/next-server options are actually
  injected on the wire.
- **dnsmasq relay** (new): `bash scripts/dhcp-relay-flow-simulation.sh` — see Part A's
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

Run `scripts/nats-secondary-auth-callout-simulation.sh` end-to-end (this single script
already covers, per PRs #1172/#1168's own extensions to it): registration with
distinct per-secondary credentials, isolation between two secondaries, credential
rotation invalidating the old credential, **active disconnect** of an already-live
connection on remove/rotate (verified via `connz` polling, not the HTTP response),
and **xkey-encrypted** auth-callout traffic (verified via packet capture with a
negative control). See Part A's NATS rows for the specific pass/fail criteria on each
sub-mechanism — this section is the "run it as one real end-to-end pass" framing,
Part A is the "what does each individual claim need to prove" framing.

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
- For each monitored service, repeat the hung-not-crashed proof pattern from Part A's
  NATS-monitoring row (external `SIGSTOP`, not an in-container one) and confirm a
  genuine restart (new `StartedAt`).
- Known open, non-blocking gap (#1166, surfaced during #1167's own live validation):
  `restart_container()`'s `CURL_MAX_TIME` (default 5s) can be shorter than Docker's
  own restart grace period (10s) for a container slow to respond to SIGTERM, producing
  a spurious `WARNING: restart call failed` log line even when the restart actually
  succeeds a few seconds later. If you see this, cross-check `docker inspect
  --format='{{.State.StartedAt}}'` before concluding the restart genuinely failed —
  this is a known, separately-tracked cosmetic-log bug, not (yet) a real functional
  failure.

### 8. Central logging / syslog forwarding

- If the optional `logging` profile is enabled: confirm real log lines from a
  monitored service actually arrive at the `syslog-ng`/fluent-bit target, not just
  that the containers are up. `syslog-forwarding-simulation` (part of
  `full-setup-deep-validate.yml`) is the reusable proof for this — invoke it directly
  or via `gh workflow run` rather than re-deriving a new check.
- Confirm the healthcheck limitation this project has already documented for itself
  (`AG-VAL-023`'s netdata precedent, and `syslog`'s own compose-file comment): a
  binary-presence healthcheck (`fluent-bit -V`, `syslog-ng-ctl healthcheck`) proves
  the binary is intact, not that the tailing pipeline actually works — validate the
  pipeline directly (a real log line arriving at the target), don't trust the
  healthcheck alone.

### 9. Resource-Leak / Cleanup Pass (standing check, run every release)

Framing note: this project is written in Rust (memory-safe), so the classic
C-style heap-leak question does not apply the same way. The resource-leak concern
that **does** apply, and must be checked explicitly every release, is whether
processes, containers, connections, and file descriptors are actually released when
a service is removed, rotated, or restarted — not merely that the API call that
triggered the removal/rotation/restart returned success.

| What to check | How to check it for real | Pass/fail |
|---|---|---|
| A removed/rotated NATS secondary's live connection is actually gone, not just access-revoked | Reuse `scripts/nats-secondary-auth-callout-simulation.sh`'s `connz`-polling pattern from PR #1172: after removal, poll `nats-server`'s own `connz` HTTP monitor endpoint until the connection entry disappears — do not stop at the HTTP 200 from the removal API | Fail if the connection lingers in `connz` past a reasonable poll window |
| Watchdog-restarted containers leave no orphaned process/connection from the pre-restart instance | After a watchdog-triggered restart (Part B §7), `docker exec <host or a diagnostic container> ss -tnp` (or `netstat -tnp` if `ss` is unavailable) targeting the restarted service's port, confirm no stale connection to the old container's now-dead PID remains | Fail if a stale ESTABLISHED/CLOSE-WAIT connection to the pre-restart process persists |
| `docker compose down -v` genuinely removes every container and named volume for the stack | `docker ps -a --filter "name=lancache"` and `docker volume ls --filter "name=lancache"` immediately after teardown — both must return empty | Fail if any lancache-prefixed container or volume remains |
| A resized/rotated proxy container (cache-resize, PR #1174) doesn't leave the old container running alongside the new one | `docker ps --filter "name=lancache-proxy"` immediately after a convergence-triggered recreate — exactly one container, with a `StartedAt` matching the recreate, not two | Fail if more than one `lancache-proxy` container is running, or the old one's `StartedAt` is unchanged (recreate didn't actually happen) |
| No file-descriptor exhaustion from repeated watchdog restart cycles over a longer soak | `docker exec <container> ls /proc/1/fd \| wc -l` sampled before and after several forced restart cycles of the same service — should return to a stable baseline, not grow monotonically | Fail (flag for investigation) if FD count trends upward across cycles rather than stabilizing |

---

## Current Known Feature-Specific Checks (dated 2026-07-24 — prune/update every release)

This section names the concrete new features merged on 2026-07-24 that the Standing
checks above were written to cover generically. It exists so a future validator
knows *why* a given Standing check row exists and can retire the specific example
once it stops being new, without deleting the durable check itself:

- DHCP dnsmasq-relay mode (PR #1117, closes #844) — first real relay mode alongside
  ProxyDHCP; `scripts/dhcp-relay-flow-simulation.sh` is its canonical proof.
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
  CLI-driven PowerDNS zone rollback via `scripts/setup-reset-dns-config-simulation.sh`.
- Edition-2024 bump across all three Rust crates (PR #1179, closes #1178) — real
  fixes required (rustfmt style-edition drift, `unsafe` env-var-mutation annotations,
  collapsible-if-let clippy fixes), not a clean drop-in; validate on the real
  build-tools-container Linux target, not a Windows-side `cargo check`.
- Per-release CycloneDX SBOM + OpenVEX document (PR #1194, refs #1130) — drift guard
  (`scripts/check-vex-drift.sh`) already proven once against a real mismatch; the
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
  `scripts/select-build-tools-image.sh`'s fork-vs-same-repo trust check), each
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
  consolidated into #1095, **known accepted limitation** — see Coverage Assessment
  below) — `container-scan`'s throwaway pre-build image and `build`/`build-arm64`'s
  actually-pushed image are two independent `docker buildx build` invocations that
  never produce matching digests, even for byte-identical inputs, because each
  build stamps its own fresh `created` timestamp into the image config.
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
  above) — `scripts/ensure-pr-staging-images.sh`'s untouched-service back-fill had no
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
  `find_built_ancestor()`. New Standing check row above (`scripts/check-pipefail-
  early-exit-grep.sh`, wired into the `shellcheck`/`shellcheck-hosted` jobs); a
  proposed AGENTS.md rule for the general failure class (`AG-VAL-030`) was posted
  as a PR #1374 comment for maintainer review, per `AG-WF-025`.

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
- **Netdata-alarm → Admin UI notification integration** remains entirely unbuilt (PR
  #1165 explicitly marks this half of the original dashboard vision as still open,
  `docs/bug-hunt/observability.md` finding #3 "PARTIALLY FIXED").
- **The DNS reset-to-known-good E2E** (PR #1152) has only ever been run with two
  environment deviations in place (a locally built image, a patched healthcheck probe
  domain) due to the since-fixed #1150 bug — the *unmodified* real CI path for this
  script has never actually completed clean; confirm that on the next run rather than
  assuming it now works unmodified.
- **Kea/PDNS/NATS config-writer idempotence** is still manual-review-only per
  `.github/AGENTS.md`'s own enforcement matrix (`AG-OP-006`/`AG-OP-007` row) — only
  the `.env`-migration path and watchdog's restart-counter convergence have real
  repeat-run fixture coverage.
- **This document's own Validation State Tracking mechanism** (`docs/validation-
  state.json`) is brand new as of this PR — it starts with every field `null` and has
  not yet been exercised by a real validation pass. The first real run against it is
  itself a gap until it happens.
- **`tools/runner-host/lancache-ci-runner-clone-init.sh`'s `sccache-fetch` mode has
  no mechanical guard against reintroducing host-copied scheduler credentials**
  (confirmed real, PR #1624/#1626, 2026-08-21): the pre-fix `sccache-fetch` installed
  `/opt/<RUNNER_USER>/.config/sccache/config` at mode `0644` (world-readable),
  live-verified on 5 heavy hosts to contain a commented-out but still-plaintext
  dist-auth token and JWT `secret_key`; the pre-existing source hosts this fleet was
  cloned from (`lancache-240`/`lancache-241`) were found to carry the *active*,
  non-commented token in `client.conf` at world-readable modes (`2775`/`644`
  respectively) — a worse instance of the same class. #1626's fix removes the
  host-copy code path entirely (binaries only; runtime config comes from a
  per-job, secret-backed `SCCACHE_CONF`), which is the real fix, but nothing in CI
  would catch a *future* regression reintroducing a similar `install -m 0644 ...`
  line under a runner-user config path in this script family. Maintainer decision
  (2026-08-21, threat model: LAN-only hosts, no external attacker, `codex` is both
  the SSH-login and CI-job user so the file-mode bit does not change the real
  access vector): no urgent remediation sprint for the already-provisioned hosts
  and no credential rotation — cleanup happens as part of the normal host-prep
  rollout, not a special pass. A cheap future guard, not built in this pass: reject
  `install -m 06[4-7][4-7]`/`chmod 644` targeting a path under a runner-user
  `.config/`/credential directory anywhere in `tools/runner-host/*.sh`.
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

**Known, accepted limitations (not fixable without larger rework — recorded per
`AG-VAL-029`'s "genuinely unautomatable/impractical" carve-out, not silently
omitted):**

- **C-7: `container-scan`'s throwaway image and `build`/`build-arm64`'s pushed image
  never share a digest** (issue #1348, consolidated into #1095, see
  `build-push.yml`'s own comment at the `container-scan` job header, roughly lines
  5003-5011) — both are independent `docker buildx build` invocations of the same
  Dockerfile/commit; a fresh build stamps a new `created` timestamp into the image
  config every time, so the two builds' digests never match even given
  byte-identical inputs. **This is not currently a correctness/provenance gap**: the
  "Scan pushed service digest with Trivy" step (`build-push.yml`'s `build` and
  `build-arm64` jobs, per issue #1095 Step 3) already scans the exact digest that
  gets pushed for all 8 services, not just `build-tools` as before — so the
  security-relevant claim ("the scanned image is the shipped image") is verified
  independently of `container-scan`'s throwaway build. What remains unfixed is a
  **cost/redundancy** problem only: every changed service's Dockerfile gets built
  twice per run (once to scan, once to push), tracked under the larger #1095
  CI-pipeline rework, not expected to be resolved by a small, targeted fix.
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

---

## Appendix — Reusable Scripts/Commands Index

| Script / command | Proves |
|---|---|
| `scripts/dhcp-relay-flow-simulation.sh` | Real two-segment DHCP relay (PR #1117) |
| `scripts/nats-secondary-auth-callout-simulation.sh` | NATS secondary lifecycle, active-disconnect (`connz`/`KICK`), xkey encryption (packet capture + negative control) |
| `scripts/setup-reset-dns-config-simulation.sh` | Real CLI-driven PowerDNS zone rollback (PR #1152) |
| `scripts/setup-reset-kea-config-simulation.sh` | Real CLI-driven Kea config rollback |
| `scripts/generate-vex.sh` / `scripts/check-vex-drift.sh` | OpenVEX document reproducibility and drift detection (PR #1194) |
| `tests/bats/setup_update_idempotence.bats` (first `@test`) | `.env` key-drift guard (PR #1199) |
| `scripts/check-idempotence-test-coverage.sh` | Every stateful config-writer has repeat-run/idempotence test coverage |
| `scripts/check-bats-path-filter-coverage.sh` | Every real bats dependency is covered by `build-tools.yml`'s path filters |
| `scripts/check-workflow-service-lists.sh` | Hardcoded service arrays stay in sync across workflow files |
| `scripts/check-naming-consistency.sh` | Container-name/allowlist/env-var naming contract (`docs/naming-conventions.md`) |
| `scripts/check-file-headers.sh` | File-header contract (`AG-HDR-*`) |
| `scripts/classify-image-impact.sh` | The single source of truth for "which subsystem does this diff touch" — reused by this document's own staleness reasoning, `detect-changes`, and the `promote` job's version-bump logic |
| `scripts/validate-stack-images.sh` | Release-notes/workflow status-line consistency |
| `scripts/select-build-tools-image.sh` | Resolves the pinned build-tools image/digest for every container-based check above |
| `scripts/full-setup-client-simulation.sh` | Full-setup harness client-side probe |
| `gh workflow run full-setup-validate.yml --repo wiki-mod/lancache-ng --ref <branch>` | Manually triggers the `workflow_dispatch`-only stack-simulation suite (does not run automatically on PRs) |
