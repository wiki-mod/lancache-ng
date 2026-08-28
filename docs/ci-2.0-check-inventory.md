# CI 2.0 Check Inventory: What Is Kept, What Is Dropped, What Gets Faster

Status: triage document for the CI 2.0 rewrite. Tracked by issue #1683,
companion to `docs/ci-2.0-architecture.md`.

`docs/ci-2.0-architecture.md` specifies **what happens when** — flows, states,
orderings, conditions. It does not carry the accumulated list of **individual
checks** this repository grew over years, each one bought with a real incident.
This file is that list, and the reasoned decision for each entry.

The old `.github/**` implementation is read here for exactly one purpose:
recovering the **inventory of what is checked**. No code, no structure, no
function names, no copy template are carried forward (§82 of the architecture
plan).

## The three questions asked of every check

Per maintainer directive, each check is judged on:

1. **Must it exist?** Does it protect against a real failure that remains
   possible?
2. **Is it still needed?** Is the original trigger still reachable under the new
   identity/ledger architecture, or is it now structurally impossible?
3. **Can it be faster?** Does it run too often, too late, or too expensively —
   can it be bundled, pulled forward, cached, or made cheaper?

## Performance contract this triage serves

The binding target: **a no-op run (nothing changed semantically) finishes in
under 2 minutes, and must not exceed 3–5 minutes.** Today every check below runs
repository-wide on every pull request, and self-hosted and hosted-fallback
variants of the same check run *concurrently, unconditionally* (§72.1, verified
on PR #1695: nine job pairs started within the same second).

Measured on a real runner host inside the pinned build-tools container
(AG-VAL-016; sccache-build-slave-240, `build-tools:nightly`, 2026-08-28):
the planner's full verdict for a real multi-commit diff takes **35 ms**, one
content-derived build identity 12–16 ms, all 11 identities together **117 ms**,
and the entire 108-test engine suite **5.6 s**. The engine's share of a no-op
run is therefore negligible; the budget is spent almost entirely on GitHub's
own job scheduling and checkout overhead, which the empty-matrix design (§71)
keeps to a single light job.

That is the structural change this inventory encodes. Three rules follow, and
they apply to every "kept" entry below without being repeated each time:

- **Diff-scoped by default.** A check examines the files the change touched.
  Repository-wide scope is an explicit, named exception (§98), not a default.
- **The no-op gate runs first and alone.** The planner answers "did anything
  semantically change?" before any check job is scheduled. On a no-op, the
  required check reports success and nothing else starts (§62, §63).
- **One implementation, one execution.** Self-hosted and hosted are execution
  locations of the same `ci.sh` call, sequential and conditional, never two
  parallel jobs (§72, §72.1, §72.2).

## Root cause this rewrite must structurally exclude

Verified failure mode of the old CI, and an acceptance criterion for the new
identity engine:

- Image identity was tied to the **commit SHA**, not to content. `proxy:sha-<commit>`
  is absent whenever proxy was legitimately unchanged at that commit and
  therefore not built. The staging check demands exactly that tag, and its
  fallback only triggers when the workflow did not run at all — so "the workflow
  ran, this service was legitimately not built" falls through the gap and fails
  hard, while a content-identical image already exists (541 `sha-` tags for proxy
  alone).
- The inverse: a workflow-file-only edit rebuilt every service, though no
  container content was affected.

Both are excluded by construction in CI 2.0: identity comes from **content**
(§16), and the governing question is *"does this service have the same content
as an already-accepted artifact?"* — never *"does a build run exist for this
commit?"*

---

## A. Kept, unchanged in substance

These protect against failures that remain fully possible. They change only in
*when* and *how widely* they run, per the three rules above.

| Check | What it protects |
|---|---|
| `check-mutable-refs.sh` | External action refs must be pinned, not mutable tags |
| `check-action-node-versions.sh` | Deprecated Node runtimes in actions; also bans YAML anchors in composite actions |
| `check-language-policy.sh` | AG-REL-001: only Rust and shell for code we write |
| `check-file-headers.sh` | Canonical header + SPDX contract |
| `check-line-endings.sh` | LF-only line endings |
| `check-executable-bits.sh` | Bare-path-invoked scripts must be mode 100755 |
| `check-compose-healthchecks.sh` | Every service keeps a healthcheck |
| `check-governance-guards.sh` | Stale TODO/FIXME and partial-work markers |
| `check-pr-title-convention.sh` | Conventional-Commit PR titles |
| `check-pr-tracking-metadata.sh` | AG-GH-008 tracking metadata on every PR |
| `validate-pr-template.sh` | PR template completeness |
| `check-changelog-direct-edit.sh` | Direct CHANGELOG edits (warn-only) |
| `check-naming-consistency.sh` | Names match `docs/naming-conventions.md` |
| `check-logging-matrix.sh` | Logging-matrix doc drift |
| `check-proxy-cache-env-doc-drift.sh` | proxy cache env vs. documented behavior |
| `check-setup-prompt-drift.sh` | `setup.sh` wizard vs. simulation scripts |
| `check-netdata-curl-pin.sh` | netdata's vendored curl pin vs. tracked CVEs |
| `check-vex-drift.sh` | `.trivyignore.yaml` vs. generated OpenVEX |
| `check-stable-external-images.sh` | Release gate on third-party image pins |
| `check-dependabot-docker-base-consistency.sh` | Dependabot grouping vs. real Dockerfile bases |
| `check-idempotence-test-coverage.sh` | Convergence/idempotence tests stay present |
| `check-validation-subnet-wrapper-coverage.sh` | Subnet-collision wrapper coverage |
| `check-build-tools-smoke-coverage.sh` | Every tool the build-tools Dockerfile verifies is either covered by the smoke test or explicitly excluded |
| `check-review-chronology-comments.sh` | AG-CODE-002/003/012 comment-content rules |
| `check-trivy-action-direct-usage.sh` | AG-VAL-029: trivy-action only via the retry wrapper |
| `check-pipefail-early-exit-grep.sh` | pipefail/SIGPIPE early-exit `grep` pattern |
| `check-orphaned-branches.sh` | AG-GH-017 branch hygiene (scheduled, not per-PR) |

### A.1 The `validate-compose` inline steps, triaged individually

The 21 inline steps inside `validate-compose` split into two groups. Nine
`Check …` steps are plain invocations of standalone scripts already triaged
above (`check-naming-consistency.sh`, `check-workflow-service-lists.sh`,
`check-vex-drift.sh`, `check-netdata-curl-pin.sh`,
`check-idempotence-test-coverage.sh`, `check-bats-path-filter-coverage.sh`,
`check-setup-prompt-drift.sh`, `check-proxy-cache-env-doc-drift.sh`,
`check-logging-matrix.sh`) — their verdicts stand; the job wrapper around them
disappears with the job.

The twelve `Validate …` blocks carry real inline logic, each judged on the
three questions (exist / still needed / faster). All are diff-scoped in CI 2.0
unless marked repo-wide:

| Inline block | Verdict | Reasoning |
|---|---|---|
| Stack image contract | **Keep** | Runs `validate-stack-images.sh`; a stack referencing a non-accepted image is the exact failure §47 exists to stop. In CI 2.0 the ledger-backed `stack-candidate` check covers the same invariant structurally; the script remains as the compose-side half. |
| Prebuilt production install path | **Keep** | Protects the `LANCACHE_STATE_DIR`/legacy-override contract and rollback path snapshots (PR #447). Nothing in CI 2.0 makes this impossible; runs only when its inputs change. |
| Compose files | **Keep** | Renders every compose profile; inactive-profile services are otherwise never validated (PR #343). Gate on compose/env/setup.sh diffs. |
| NATS/atomic-write + socket proxy | **Keep** | Guards the single `docker-socket-proxy.sh` allowlist (PR #635); a silent allowlist regression is a security hole, not a style issue. |
| DHCP proxy env-file + PXE | **Keep** | Three real contracts (env_file-only for prod dhcp-proxy PR #472, dnsmasq optional-option surface PR #643, PXE opt-in passthrough PR #765); each was a real regression once. |
| setup.sh required keys + Kea preflight | **Keep** | Fails on committed secrets (`NATS_*TOKEN=` in tracked `.env`) and Kea preflight drift; the secret-leak half is repo-wide by its nature (explicit §98 exception). |
| setup.sh update-migration safety | **Keep** | Prerelease-protection semantics (Issue #1095/PR #1532); still reachable, cheap, diff-scoped on setup.sh. |
| Shellcheck hygiene + Rust acceleration policy | **Keep, split** | Two unrelated things in one step. The heredoc `-i` requirement moves into the shellcheck check's own scope; the sccache/ccache-redis wiring checks (real ui/watchdog regression) become their own diff-scoped check on the acceleration files. |
| Rust acceleration preflight + image chain | **Keep, reduced** | The QEMU-vs-native arm64 guard (CVE-2026-39822) and ghcr-build-push-retry wiring stay. The checks asserting build-push.yml's own internal job structure die with build-push.yml — they guard the old file's shape, not a product invariant. |
| Build-tools tag promotion + distcc/sccache wiring | **Keep, reduced** | The branch-name-vs-release-tag collision guard (a real v0.2.0 incident class) stays. The parts that extract-and-run build-push.yml's inline promote script test the old implementation, which no longer exists; CI 2.0's `promote` has its own tests instead. |
| Image channel/tag resolution + stack images | **Drop** | Asserts how the old YAML resolves channel tags at build time. CI 2.0 resolves digests through the ledger and verifies them on readback (§51-§53) — the checked mechanism itself is gone. |
| Channel/branch-model mapping (#825/#1141) | **Keep, reshaped** | The invariants (current_dev never auto-publishes nightly; nightly stays schedule/dispatch-only; nightly-refresh must exist) survive, but as assertions over the new ci2 workflows, not greps over build-push.yml's job text. |

Net: 10 of 12 inline blocks survive as requirements (2 of them reduced, 1
split), 1 dies with the mechanism it checks, 1 is reshaped onto the new
workflows. They move out of workflow YAML into `ci.sh`/`ci.bats` (§81) — a
relocation with per-block scope decisions, not a bulk copy.

## B. Dropped — the failure they guard against becomes structurally impossible

| Check | Why it can go |
|---|---|
| `check-workflow-service-lists.sh` | It exists because service lists are duplicated across workflows. CI 2.0 has exactly one list, in `ci.sh` (§7). With no second copy, there is nothing to keep in sync. Replaced by `ci.bats`'s inventory tests, which assert the single list is complete and every service has full metadata. |
| `check-bats-path-filter-coverage.sh` | It keeps hand-maintained `on.push.paths` / `on.pull_request.paths` lists in `build-tools-smoke.yml` aligned with real bats dependencies. CI 2.0 derives impact from content in the planner instead of from hand-written path filters (§10, §11), so the lists it guards cease to exist. |
| `check-pr-diff-file-headers.sh` | A second entry point into the same header contract as `check-file-headers.sh`, existing only because the old CI needed a separate diff-scoped job. Diff scoping is the default in CI 2.0, so one implementation covers both. |

**Not dropped silently:** each of these represents a real past incident. The
incident stays covered — by the new structure (single list, content-derived
impact, diff-scoped-by-default) rather than by a guard script. If any of these
premises turns out not to hold during implementation, the corresponding guard
comes back.

## C. Kept, but restructured and faster

| Check | Change |
|---|---|
| `check-deny-short-sha.sh` | Currently a repository-wide grep. Becomes diff-scoped, and is additionally enforced at runtime by `ci_validate_full_git_sha` / `ci_validate_full_oci_digest` in `ci.sh` (§15). Static check catches it at review time; the runtime validators make a short identifier unusable even if one slips in. |
| `check-workflow-line-limit.sh` | Exists because `build-push.yml` reached 8,171 lines. CI 2.0 workflows are thin orchestrators (§5, §6), so the ceiling becomes near-trivially satisfied. Kept as a cheap regression guard, with a ceiling set to the new architecture's reality rather than the old file's size. |
| `check-pipefail-scope-coverage.sh` | A meta-guard asserting another guard's fixtures stay complete. Kept, but folded into `ci.bats` as an ordinary test rather than its own CI job — it needs no separate runner, checkout, or job slot. |
| ShellCheck (`shellcheck-and-standing-guards`) | Today: unconditional, repository-wide `find . -name '*.sh' -o -name '*.bats' \| xargs shellcheck`, with a hosted twin that has *no* `if:` condition at all — verified on PR #1648 (a single-file `AGENTS.md` PR): the self-hosted job correctly skipped, the hosted fallback still ran a full 3m7s repo-wide scan. Becomes diff-scoped and single-execution (§72.1, §98). This is the single largest no-op-path saving in the inventory. |
| All self-hosted / hosted-fallback pairs | Nine pairs run concurrently today, always. Becomes one job calling one `ci.sh` command, with the hosted variant gated on the self-hosted attempt being *unavailable* — never on it having genuinely failed (§72.2). |

## Open items for maintainer confirmation

1. The four drops in section B rest on the premise that the new structure
   actually removes the duplication each one guards. Confirm at cutover (§84
   Phase 14), not before.
2. `check-changelog-direct-edit.sh` is warn-only today. Whether it becomes
   blocking under CI 2.0 is a policy decision, not a technical one.
3. `check-orphaned-branches.sh` runs on a schedule rather than per-PR. It stays
   in `gc.yml`'s domain rather than `ci.yml`'s; confirm that placement.
