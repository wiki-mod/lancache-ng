# Contributing to lancache-ng

Thank you for helping improve lancache-ng.

lancache-ng is network infrastructure software. Changes can affect DNS, DHCP,
TLS interception, Docker startup, cache correctness and local network
availability. Please keep contributions small, reviewable and easy to test.

## Project scope

lancache-ng provides a Docker based LAN cache stack with:

- DNS based cache routing
- an nginx cache proxy
- optional SSL caching with a locally trusted CA
- an Admin UI
- optional DHCP and secondary DNS features
- setup and update automation for first-time users

When proposing changes, prefer behavior that keeps installation and updates
safe for non-expert operators.

## Before you start

- **File an issue first when the work covers multiple distinct topics/scope,
  is being logged now but not implemented immediately (a backlog item with
  no branch/code yet to attach a PR to), or genuinely needs discussion or a
  maintainer decision before any code gets written.** These are cases where
  a PR literally cannot exist yet, or where tracking needs to outlive and
  span more than one PR.
- **A separate issue is not required for a single, well-scoped fix or small
  feature that gets implemented in the same sitting it was found in.** In
  that case the PR itself is the complete record: the PR title carries the
  role an issue title would have played, the PR body's Summary/Changelog
  sections carry the what/why, and labels/milestone go directly on the PR.
  Don't open a placeholder issue just to close it moments later with the
  same PR — that produces two records to maintain instead of one, with the
  issue usually ending up as a near-empty pointer.
- Keep unrelated changes in separate pull requests.
- Do not commit real passwords, API keys, certificates, private IP details from
  your environment, or generated runtime state.
- Do not assume that every operator runs the same LAN subnet, host OS, storage
  layout or Docker configuration.

## Pull request expectations

Opening a PR pre-fills `.github/pull_request_template.md`. Fill in every
section rather than deleting the ones that feel redundant for a small
change — a short "N/A, this is a one-line typo fix" is fine, but the
section headings themselves should stay so reviewers always know where to
look. At minimum, each pull request should explain:

- whether AI assistance was used, using the transparency notice at the top of the template
  - It's okay for us if you used it — just be fair enough to tell us. Keep and edit the notice if you used AI, delete it if you didn't, and never leave it in place saying something that isn't true for this specific PR.
- what changed
- what the PR actually changes in before/after terms, with a concrete example where possible
- why the change is needed and what it fixes or adds
- how users or operators are affected
- what the PR deliberately does NOT touch (scope boundaries)
- which files were actually touched (scope evidence)
- which checks were run, with the exact commands
- any remaining risk or follow-up work

The template now exposes visible `Linked issues` and `Risk / Rollback /
Follow-up` sections. Fill those in directly instead of relying on hidden
comments so the rendered PR body always surfaces the tracking and risk
context reviewers need.
- if the change touches build, CI, or release automation, whether any accelerator (`sccache`, `sccache-dist`, `distcc`, `distcc-pump`, or Buildx cache) is optional, preferred, or a gate
- whether a GitHub-hosted fallback still works without LAN-only cache assumptions

Prefer focused pull requests. For example, do not mix documentation rewrites,
CI fixes and runtime behavior changes unless they must land together.

As the PR evolves (new commits, findings fixed, scope changes), update the
PR body directly rather than adding new comments to track progress. Comments
are for review-thread replies and discussion, not for changelog/status
updates that belong in the body.

### PR and issue linking

Track related work explicitly in the PR body:

- Use `Refs #123` for parent issues, umbrella issues, and follow-up references.
- Use `Closes #123` only when this PR should also close that issue.
- If the PR title or body says scaffold, partial, deferred, not covered, not implemented, or follow-up, keep the PR open-scoped: explain the remainder with `Refs #123` and avoid `Fixes #123` / `Closes #123` unless the full issue is actually complete.
- When a PR is merged, completion claims must be checked against the merged code on the active development branch (`current_dev` as of #825, not a hardcoded `master`/`v0.2.0` assumption), not just the PR head or narrative.
- If no issue exists, that's expected and fine per the "Before you start" guidance above for single, well-scoped work implemented immediately — no need to explain why in that case. If work that genuinely should have had an issue (multi-topic, backlog, needs-discussion) shipped without one, explain why in the PR body instead of leaving the relationship unclear.
- **`Closes #123` does not auto-close the issue when merging to `current_dev`** — GitHub's built-in closing-keyword behavior only fires on merges to the repository's default branch (`master`). Until this is automated (tracked in #1137), whoever merges a current_dev PR with a closing keyword must manually close the referenced issue(s) and post a real closing report (not just a bare link) — see the next section.

### Closing an issue manually (current_dev merges)

Because of the `current_dev` auto-close gap above, closing an issue by hand still needs to leave a real record, not just a status change:

- Post a comment on the issue with an actual closing report before/when closing it: what was resolved, a link to the PR, and the concrete evidence (the PR's own Summary/Changelog content is usually sufficient to paste in directly — it's already required to exist by the PR template).
- The same applies to any merge-readiness assessment (CI status, mergeability, caveats) — record it as a PR/issue comment, not only as a chat message to whoever asked. GitHub is this project's record of truth, not a chat transcript.
- Open PRs should include links for relevant review context (for example tracking and umbrella issue).

Use the visible `Linked issues` section in the template for those links so the
rendered PR body keeps the relationship obvious even when nobody edits the body
after opening the PR.

### Changelog expectations

For each user-facing change, include a short changelog-style summary in the PR body under a clear heading (for example `## Changelog`).
This summary should be reused in the final release notes text when available.
Every pull request should include a changelog section that explains user-visible
behavior, operational impact, validation performed, and any explicit follow-up
issue. Silent changes are not acceptable for release, setup, CI, or runtime
behavior. Keep this section current by editing it directly as the PR changes,
not by appending new comments each time something is fixed or added.

#### Releasing Changes to CHANGELOG.md

lancache-ng maintains a `CHANGELOG.md` file at the repository root, following
the [Keep a Changelog](https://keepachangelog.com/) format.

As of #899, updating it is automatic and requires no manual collection step:

1. `.github/workflows/release-drafter.yml` drafts/updates a GitHub Release on
   every push to `master`/`v0.2.0`, listing each merged PR as `#NUMBER | TITLE`
   grouped by label (config: `.github/release-drafter.yml`).
2. When that release is published (manually, or via a `workflow_dispatch` run
   of the same workflow), `.github/workflows/update-changelog.yaml` fires and
   writes the release's name and notes into `CHANGELOG.md`, committing the
   result automatically.

Applying the `skip-changelog` label to a PR excludes it from the drafted
release notes (e.g. a pure internal refactor with no user-visible effect).

`scripts/collect-changelog-entries.sh` (added in #890) remains as a manual
fallback -- useful for reconstructing history or if the automated pipeline is
ever disabled -- but is no longer the primary path.

Maintainers reviewing release PRs should verify that `CHANGELOG.md` accurately
reflects user-visible behavior changes across all merged work for that release.

Use the template's visible `Risk / Rollback / Follow-up` section to capture
the remaining operator risk and any rollback or follow-up notes.

### Quality and release process expectations

#### Warning-as-errors policy

All actionable static analysis warnings are treated as build failures under the warnings-as-errors rule:

**Hard failures (block a PR):**
- `cargo check` warnings — enabled via `RUSTFLAGS: "-D warnings"` in `dns_rust_quality` and `ui_rust_quality` jobs
- `cargo clippy` warnings — enforced via `cargo clippy -- -D warnings` in the same jobs
- `shellcheck` warnings — enforced via `shellcheck --severity=warning` in the `shellcheck` job
- `actionlint` warnings — enforced via `actionlint .github/workflows/*.yml`
- `docker compose config` warnings — enforce via pattern matching for `warn|warning` in `validate-compose` job
- File header checks — enforced via `bash scripts/check-file-headers.sh`

**Known exception (tracked in issue #394):**
GitHub's CodeQL Rust extractor emits `macro expansion failed` warnings for ordinary macros (`format!`, `assert_eq!`, `vec!`, `json!`, `tracing::*`, etc.) as a documented upstream limitation, not due to code defects in this repository. This exception is **scoped to CodeQL Rust macro-expansion extraction warnings only** and does not extend to `cargo check` or `cargo clippy` warnings, which remain hard failures. Every instance of a CodeQL macro-expansion warning must stay tracked in #394, and #394 must be periodically reevaluated to monitor upstream status rather than being left as a permanent blanket excuse.

Because of this limitation, **a green CodeQL Rust job must not be read as full security-scan coverage of the Rust codebase.** A concrete historical example (PR #357, Actions run 28596839186) shows the Rust extractor reporting 12 files "extracted with errors" against 2 "without error" while the job still concluded `success`. That state is expected: CodeQL's own authoritative quality gate — the `rust/diagnostic/database-quality` ("Low Rust analysis quality") diagnostic query — did not fire on that run, so CodeQL classifies partial macro-expansion extraction as normal, not degraded. The raw per-file counts are metric-query output printed only to the analysis log summary; they are not exposed as a supported, machine-readable workflow output (github/codeql-action #1742, open since 2023), and the database is cleaned after `analyze`. This is why `.github/workflows/codeql.yml` reports CodeQL's own `database-quality` determination and a standing caveat in the job summary rather than enforcing a hand-rolled count threshold (which would be permanently red on an upstream limitation that is not tunable here — Rust supports only `build-mode: none`). Rust security correctness continues to be enforced separately by the `dns_rust_quality`, `ui_rust_quality`, `dns_test`, and `ui_test` jobs, which are independent of CodeQL extraction quality.

- Keep workflow action references pinned to full commit SHAs with a version comment; floating tags such as `@v4` are forbidden in project PRs, because Dependabot and similar tooling report them as a security finding.
- Keep workflow changes reviewable:
  - document changed checks,
  - explain any intentional risk,
  - and include PR links to all impacted issue threads.

## Code comments and file headers

These are required, not stylistic suggestions — a PR missing them will fail CI or get flagged in review.

- **File headers.** Every source/config file you add or touch (Rust, shell, YAML, Dockerfiles, `.conf`/template files, HTML/CSS/JS) must open with a short header: the project name and repo URL in the exact form `lancache-ng (https://github.com/wiki-mod/lancache-ng)`, followed by a purpose description of that specific file, using the comment syntax valid for that file's language (`//!` for Rust, `#` for shell/YAML/Dockerfiles, Tera's `{# ... #}` for HTML templates under `services/ui/src/templates/`, `/* ... */` for CSS, `//` for JS). `scripts/check-file-headers.sh` enforces this in CI (`file-headers` job in `build-push.yml`) — it fails a PR if any non-excluded tracked file is missing the exact header string. A short list of files are excluded (`.md` files, the root `.env`/`.env.example`, lockfiles, `.gitkeep`, the `VERSION` file, JSON-backed `.conf` files, vendored/generated build artifacts) — see `scripts/check-file-headers.sh`'s `is_excluded()` function for the exact list, and AGENTS.md's "File Headers" section for the full rationale (why each exclusion exists, how to scale header detail to a file's complexity, and what NOT to invent in a header).
- **Code comments.** Comment only when the WHY would not be obvious from well-named identifiers and the surrounding code — not what the code does, which should be readable from the code itself. Do comment: complex logic, guards, fallbacks, security decisions, non-obvious side effects, a workaround for a specific bug, or a deliberate deviation from the obvious approach. A missing WHY-comment on code that clearly needs one is treated as a defect, whether or not it predates your change — if you're already touching that code, add the missing comment as part of your PR rather than leaving the gap. Do not reference the current task, PR number, or fix in a comment (e.g. "fixed for #123") — that belongs in the PR description, not in code that outlives the change. See AGENTS.md's "Comment Style" section for the full guidance, including how to document a deliberately deferred fix versus a straightforward WHY-comment.

## Local checks

### Using the build-tools container for verification

All project verification (Rust checks, build validation, linting, tool checks) must run inside the project's build-tools container, not against host-local tools. This ensures that your verification matches what CI will test: the same Rust version, the same clippy/rustfmt rules, the same sccache/distcc configuration, and the same versions of shellcheck, actionlint, and other tools.

Treat host-local tools (`cargo`, `rustc`, `rustfmt`, `clippy`, `shellcheck`, `actionlint`, `sccache`) as potentially missing, misconfigured, or stale. They do not prove that your change will pass CI. **Verification with host tools instead of the build-tools container does not count as valid testing**.

To run checks with the build-tools container:

1. The build-tools image is selected automatically: `bash scripts/select-build-tools-image.sh` determines the correct version (published image or local build).
2. Run checks inside the container with the standard pattern:

```bash
BUILD_TOOLS_IMAGE="$(bash scripts/select-build-tools-image.sh)"
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/work:ro" -w /work "$BUILD_TOOLS_IMAGE" <check-command>
```

### Specific checks

Run the checks that match your change.

For shell scripts, run the checks inside the build-tools container:

```bash
BUILD_TOOLS_IMAGE="$(bash scripts/select-build-tools-image.sh)"
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/work:ro" -w /work "$BUILD_TOOLS_IMAGE" \
  bash -lc 'set -euo pipefail; find . -name "*.sh" -not -path "./.git/*" -not -path "*/target/*" -print0 | xargs -0 --no-run-if-empty shellcheck --severity=warning'
```

For Compose changes, you can validate locally (this does not depend on build-tools):

```bash
docker compose -f deploy/quickstart/docker-compose.yml config
docker compose -f deploy/prod/docker-compose.yml config
```

For image inventory, release, or package-channel changes, run inside the build-tools container:

```bash
BUILD_TOOLS_IMAGE="$(bash scripts/select-build-tools-image.sh)"
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/work:ro" -w /work "$BUILD_TOOLS_IMAGE" \
  bash scripts/validate-stack-images.sh
```

For workflow changes, run inside the build-tools container:

```bash
BUILD_TOOLS_IMAGE="$(bash scripts/select-build-tools-image.sh)"
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/work:ro" -w /work "$BUILD_TOOLS_IMAGE" \
  actionlint .github/workflows/*.yml
```

Also run `scripts/check-action-node-versions.sh` (issue #801) if you changed or re-pinned any `uses:` action reference -- it scans every pinned action across all workflows and fails if any of them declares a deprecated Node runtime in its own `action.yml`/`action.yaml`:

```bash
bash scripts/check-action-node-versions.sh
```

#### Optional: a local pre-push hook for this same check

`.githooks/pre-push` runs `scripts/check-action-node-versions.sh` automatically before a push that touches any `.github/workflows/*.yml`/`*.yaml` file, so a deprecated-runtime pin surfaces before you push, not only after CI comes back red. This is an **optional, best-effort local convenience layer only** -- the build-push.yml `shellcheck`/`shellcheck-hosted` jobs are the actual, non-bypassable enforcement (they run the same script inside the pinned build-tools container). The hook degrades cleanly (never blocks a push) if it can't run in your environment at all (e.g. no `curl` on `PATH`), but does block the push if it actually runs and finds a real deprecated-runtime pin -- bypass with `git push --no-verify` if needed, same as any other pre-push hook.

Enable it once per checkout:

```bash
git config core.hooksPath .githooks
```

For Rust services, run the relevant Cargo checks for the service you changed inside
the build-tools container. The UI service lives in `services/ui`. The DNS crate is in `services/dns/nats-subscriber`.

```bash
BUILD_TOOLS_IMAGE="$(bash scripts/select-build-tools-image.sh)"
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/work:ro" -w /work "$BUILD_TOOLS_IMAGE" \
  bash -lc 'cargo test --locked --manifest-path services/ui/Cargo.toml && cargo test --locked --manifest-path services/dns/nats-subscriber/Cargo.toml'
```

For Rust coverage checks (requires the build-tools container with `cargo-tarpaulin`), use:

```bash
BUILD_TOOLS_IMAGE="$(bash scripts/select-build-tools-image.sh)"
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/work:ro" -w /work "$BUILD_TOOLS_IMAGE" \
  bash -lc 'cargo tarpaulin --engine llvm --manifest-path services/ui/Cargo.toml --locked --out json && cargo tarpaulin --engine llvm --manifest-path services/dns/nats-subscriber/Cargo.toml --locked --out json'
```

`--engine llvm` matches what CI uses: tarpaulin's default ptrace-based engine needs a
capability Docker containers don't grant by default (it fails with "ASLR disable
failed: EPERM"), so both CI and local instructions use the LLVM source-based engine
instead.

Rust code coverage has a per-crate minimum threshold, not one shared number:
`services/ui` must stay at or above 35% (real measured coverage is ~38.6% as
of this writing), and `services/dns/nats-subscriber`'s threshold is still set
at 0% in the workflow. Issue #504 (closed via PR #515) already added real
unit tests for `dns_record_to_zone_update()`'s subscribe/forward logic
(extracted as a pure, testable function), so the crate's tests are no longer
data-model-only, but the `rust_coverage` job's threshold was deliberately
left at 0% pending a real tarpaulin measurement and hasn't been raised since.
Raise each crate's threshold independently as that crate gains real coverage
— do not average or share a single "minimum" number across both, since their
coverage levels differ by an order of magnitude for unrelated reasons.

If you cannot run a relevant check locally (for example, if Docker is unavailable),
say so in the pull request and explain why.

## Setup and update safety

The setup flow is part of the product. Treat `setup.sh` changes as runtime
changes, not only as installer changes.

Setup and update are pull-only flows that consume prebuilt first-party images.
They must not depend on local build accelerators or host-specific cache state.

Setup and update changes must preserve these rules:

- existing local `.env` values must not be overwritten silently
- newly required values should be added during update when safe
- generated secrets must be unique per installation
- Docker Compose should be validated before restarting containers
- errors should fail closed and be understandable to non-expert operators

## Release and package changes

Release and package changes must follow `docs/release-versioning.md` and the
machine-readable inventory in `release/stack-images.yml`.

Required rules:

- first-party runtime images are promoted as one stack package set
- `latest` means the latest stable release only
- `nightly` is the tested pre-stable channel built continuously from `master` (formerly `edge`)
- release candidates use `vX.Y.Z-rc.N` and must be GitHub prereleases
- stable releases use `vX.Y.Z` and may move `latest`
- release-capable paths must not depend on mutable `build-tools:latest`
- compose image references must keep `LANCACHE_IMAGE_REGISTRY`,
  `LANCACHE_IMAGE_PREFIX`, and `LANCACHE_IMAGE_TAG` wired consistently
- package, workflow, release-note, and setup changes must run
  `bash scripts/validate-stack-images.sh`

## Admin UI changes

The Admin UI is an operator control plane. UI changes should make the current
state clear, especially when a feature is optional, unavailable or partially
configured.

Avoid hiding operational failures. If the UI cannot read logs, talk to Docker,
reach PowerDNS or update a service, show a clear error instead of pretending
that the action succeeded.

## Security-sensitive changes

Open a private security report instead of a public issue if you found a
vulnerability that could expose secrets, allow unauthorized administration,
weaken TLS interception safety, publish trusted services to the network or
break DNS/DHCP isolation.

For normal hardening changes, use a regular pull request and explain the threat
or failure mode being reduced.
