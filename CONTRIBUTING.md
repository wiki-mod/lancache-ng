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

- Open an issue for large behavior changes before writing a big patch.
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

- whether AI assistance was used, using the optional transparency notice when applicable
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
- When a PR is merged, completion claims must be checked against the merged code on `github/master`, not just the PR head or narrative.
- If no issue exists, explain why in the PR body instead of leaving the relationship unclear.
- Open PRs should include links for relevant review context (for example tracking and umbrella issue).

Use the visible `Linked issues` section in the template for those links so the
rendered PR body keeps the relationship obvious even when nobody edits the body
after opening the PR.

### Changelog expectations

There is no checked-in changelog file.
For each user-facing change, include a short changelog-style summary in the PR body under a clear heading (for example `## Changelog`).
This summary should be reused in the final release notes text when available.
Every pull request should include a changelog section that explains user-visible
behavior, operational impact, validation performed, and any explicit follow-up
issue. Silent changes are not acceptable for release, setup, CI, or runtime
behavior. Keep this section current by editing it directly as the PR changes,
not by appending new comments each time something is fixed or added.

Use the template's visible `Risk / Rollback / Follow-up` section to capture
the remaining operator risk and any rollback or follow-up notes.

### Quality and release process expectations

- Treat warnings as failures in local checks and workflow validation.
- Keep workflow action references pinned to explicit versions or SHAs; avoid floating tags such as `@v4` in project PRs.
- Keep workflow changes reviewable:
  - document changed checks,
  - explain any intentional risk,
  - and include PR links to all impacted issue threads.

## Code comments and file headers

These are required, not stylistic suggestions — a PR missing them will fail CI or get flagged in review.

- **File headers.** Every source/config file you add or touch (Rust, shell, YAML, Dockerfiles, `.conf`/template files, HTML/CSS/JS) must open with a short header: the project name and repo URL in the exact form `lancache-ng (https://github.com/wiki-mod/lancache-ng)`, followed by a purpose description of that specific file, using the comment syntax valid for that file's language (`//!` for Rust, `#` for shell/YAML/Dockerfiles, Tera's `{# ... #}` for HTML templates under `services/ui/src/templates/`, `/* ... */` for CSS, `//` for JS). `scripts/check-file-headers.sh` enforces this in CI (`file-headers` job in `build-push.yml`) — it fails a PR if any non-excluded tracked file is missing the exact header string. A short list of files are excluded (`.md` files, the root `.env`/`.env.example`, lockfiles, `.gitkeep`, the `VERSION` file, JSON-backed `.conf` files, vendored/generated build artifacts) — see `scripts/check-file-headers.sh`'s `is_excluded()` function for the exact list, and AGENTS.md's "File Headers" section for the full rationale (why each exclusion exists, how to scale header detail to a file's complexity, and what NOT to invent in a header).
- **Code comments.** Comment only when the WHY would not be obvious from well-named identifiers and the surrounding code — not what the code does, which should be readable from the code itself. Do comment: complex logic, guards, fallbacks, security decisions, non-obvious side effects, a workaround for a specific bug, or a deliberate deviation from the obvious approach. A missing WHY-comment on code that clearly needs one is treated as a defect, whether or not it predates your change — if you're already touching that code, add the missing comment as part of your PR rather than leaving the gap. Do not reference the current task, PR number, or fix in a comment (e.g. "fixed for #123") — that belongs in the PR description, not in code that outlives the change. See AGENTS.md's "Comment Style" section for the full guidance, including how to document a deliberately deferred fix versus a straightforward WHY-comment.

## Local checks

Run the checks that match your change.

For shell scripts:

```bash
bash -n setup.sh
shellcheck --severity=warning setup.sh
```

For Compose changes:

```bash
docker compose -f deploy/quickstart/docker-compose.yml config
docker compose -f deploy/prod/docker-compose.yml config
```

For image inventory, release, or package-channel changes:

```bash
bash scripts/validate-stack-images.sh
```

For workflow changes:

```bash
actionlint .github/workflows/*.yml
```

For Rust services, run the relevant Cargo checks for the service you changed.
The UI service lives in `services/ui`. The DNS crate is in `services/dns/nats-subscriber`.

```bash
cargo test --locked --manifest-path services/ui/Cargo.toml
cargo test --locked --manifest-path services/dns/nats-subscriber/Cargo.toml
```

For Rust coverage checks (requires `cargo-tarpaulin`), use:

```bash
cargo install cargo-tarpaulin
cargo tarpaulin --engine llvm --manifest-path services/ui/Cargo.toml --locked --out json
cargo tarpaulin --engine llvm --manifest-path services/dns/nats-subscriber/Cargo.toml --locked --out json
```

`--engine llvm` matches what CI uses: tarpaulin's default ptrace-based engine needs a
capability Docker containers don't grant by default (it fails with "ASLR disable
failed: EPERM"), so both CI and local instructions use the LLVM source-based engine
instead.

Rust code coverage must stay at or above 40% for each crate. This is a minimum
baseline; improvements above 40% are encouraged. The 40% threshold was set as
a conservative baseline for the current codebase — as coverage improves, the
threshold should be raised accordingly.

If you cannot run a relevant check locally, say so in the pull request and
explain why.

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
- `edge` is the tested pre-stable channel from `master`
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
