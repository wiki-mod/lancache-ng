# Contributing to lancache-ng

Decision making: `GOVERNANCE.md`. Plans and non-goals: `ROADMAP.md`.

lancache-ng is network infrastructure. A change can affect DNS, DHCP, TLS
interception, Docker startup, cache correctness and LAN availability. Keep
contributions small, reviewable and testable.

## Scope

A Docker-based LAN cache stack with:

- DNS-based cache routing
- an nginx cache proxy
- optional HTTPS caching with a locally trusted CA
- an Admin UI
- optional DHCP and secondary DNS
- setup and update automation for non-expert operators

Changes keep installation and updates safe for non-expert operators.

## Before you start

- Open an issue first when the work spans several topics, is a backlog item
  without code yet, or needs a maintainer decision before coding.
- A single, well-scoped fix or small feature needs no separate issue; the pull
  request is the record.
- Keep unrelated changes in separate pull requests.
- Do not commit passwords, API keys, certificates, private IP addresses of
  your network or generated runtime state.
- Do not assume a specific LAN subnet, host OS, storage layout or Docker
  configuration.

## Pull requests

Fill in every section of `.github/pull_request_template.md`; write "N/A" where
a section does not apply. Each pull request states:

- whether AI assistance was used (notice at the top of the template; keep it
  only if it is true)
- what changes, in before/after terms, with an example where possible
- why the change is needed
- how users and operators are affected
- what the pull request does not touch
- which files were touched
- which checks were run, with the exact commands
- remaining risk and follow-up work
- for build, CI or release changes: whether an accelerator (`sccache`,
  `sccache-dist`, `distcc`, `distcc-pump`, Buildx cache) is optional,
  preferred or a gate, and whether the change works on a GitHub-hosted runner
  (no LAN proxy, no dist scheduler, no distcc host)

Do not mix documentation rewrites, CI fixes and runtime changes unless they
must land together. Update the pull request body when the change evolves;
comments are for review discussion.

### Linking issues

- `## Linked Issues` must keep this exact heading; `ci.sh close-linked-issues`
  and `ci.sh check pr-template` read it.
- `Refs #N` references an issue and leaves it open.
- `Closes #N` closes the issue when the pull request merges. On `current_dev`,
  the `close-linked-issues` job of `ci.yml` posts the pull request body on
  each listed open issue and closes it; on `master`, GitHub closes it.
- Do not use `Closes`/`Fixes` for partial work.
- Completion claims are checked against the merged code on `current_dev`.
- When closing an issue by hand, comment what was resolved, the pull request
  link and the evidence.

### Changelog

Each pull request with a user-visible change has a `## Changelog` section:
behavior, operational impact, validation and follow-up.

`CHANGELOG.md` (Keep a Changelog format) is maintained automatically:

1. Every push to `current_dev` or `master` runs `ci.sh release-draft` (job
   `release-draft` in `ci.yml`). It keeps one draft GitHub Release with the
   pull requests merged since the last published release, grouped by label.
   The proposed version is `minor` when a pull request carries `enhancement`,
   else `patch`. Groups, icons, labels and bumps: SOT
   `.github/yaml/build-manifest.yml` (`release_notes`,
   `release_notes_categories`).
2. The maintainer publishes the draft in the GitHub release view or with a
   `release.yml` dispatch on `master` with `action: publish-draft`. The tag
   runs `.github/workflows/release.yml`.
3. For a stable `vX.Y.Z` tag, `ci.sh release-changelog` adds the release text
   to `CHANGELOG.md` as `## [X.Y.Z] - <date>` on the default branch.

The label `skip-changelog` excludes a pull request from the notes.
`ci.sh release-notes [<ref or tag> [<base tag>]]` prints the notes without
publishing.

## Quality gates

These fail a pull request:

- `cargo fmt --check`, `cargo clippy -- -D warnings` and `cargo test` of each
  changed crate (`ci.sh test-stack`, job `test`)
- `shellcheck` and `actionlint` findings (`ci.sh check shellcheck`,
  `ci.sh check actionlint`, job `lint`)
- every check of `ci.sh check all` (file headers, comment contract, compose
  config and the other entries of `CI_CHECKS`), job `checks`

CodeQL Rust reports `macro expansion failed` for ordinary macros (`format!`,
`assert_eq!`, `vec!`, `json!`, `tracing::*`). These extraction warnings are
accepted; clippy warnings are not. A green CodeQL Rust job is not full
coverage of the Rust code; the Rust gates are fmt, clippy and test in the
`test` job.

## Tests

A change that adds a feature, changes runtime, setup or update behavior, or
fixes a bug without an existing regression test adds or updates a test:

- Rust: `#[test]` functions in the changed crate
- shell and setup logic: a test in `.github/scripts/ci.bats`, only with a
  maintainer ACK on the pull request

Every `ci.bats` test starts with
`if [ "${<name>_is_enabled:-false}" != "true" ]; then skip ...; fi`.
Default `false` keeps it off; `ci.sh check ci-bats enable-all` or
`enable-<name>`, or a `ci.yml` dispatch with `bats_enable`, turns it on.

A behavior change without a test change states the reason in the pull
request. Documentation, comment and formatting changes need no test.

## Workflows

- Actions are referenced by their major tag `vN`, never by commit SHA or
  branch. The SOT `github_actions` block lists the allowed actions;
  `ci.sh check action-node-versions` checks the reference shape and fails on a
  deprecated Node runtime.
- Document changed checks and any intentional risk in the pull request.

## Comments and file headers

Both are checked by `ci.sh check comments`.

- **File header**: line 1 empty or the interpreter line, then
  `LanCache-NG (https://github.com/wiki-mod/lancache-ng)` and
  `SPDX-License-Identifier: AGPL-3.0-or-later` in the file's comment syntax.
  Header text and exclusions: SOT `file_headers`.
- **Comment block**: `What:` and `Why:` on one line each, at most 60
  characters, and `From: Issue #N | PR #N` when a source is known.

## Building from source

The stack has five containers: `services`, `proxy`, `dns`, `dhcp`, `ui`. Each
is a build target in the SOT with its own Dockerfile (`services` from
`services/watchdog/`, the others from `services/<name>/`). Building from
source means building these images instead of pulling
`ghcr.io/wiki-mod/lancache-ng/*`.

### Tooling

- Docker Engine and Docker Compose v2 (`docker compose`).
- No local Rust, Node.js, Python or Go toolchain. The Dockerfiles build the
  workspace crates inside the `ghcr.io/wiki-mod/lancache-ng/build-tools` image
  (build argument `BUILD_TOOLS_IMAGE`, resolved by
  `bash .github/scripts/ci.sh build-tools resolve-image`, which needs
  `GITHUB_ACTOR` and `GHCR_TOKEN`).
- A local Rust toolchain for editor tooling is optional; verification counts
  only inside the build-tools container.

### One service image

```bash
bash .github/scripts/ci.sh build ui linux/amd64
```

The Dockerfiles declare their build arguments without defaults and need the
`ci-scripts` build context, so a plain `docker build` fails; `ci.sh build`
passes all of them.

### Full stack

`deploy/prod/docker-compose.yml` uses `image:` only and never builds. To run
local changes, build each changed service, tag it to the image reference the
compose file resolves (`LANCACHE_IMAGE_REGISTRY`, `LANCACHE_IMAGE_PREFIX`,
`LANCACHE_IMAGE_TAG` in `deploy/prod/.env.local`), then run
`docker compose -f deploy/prod/docker-compose.yml up -d`. Compose pulls only a
missing image, so a matching local tag is used. For another host, push the
image to a registry it can pull from or load it into its Docker daemon.

## Dependencies

- **Rust crates**: workspace members of the root `Cargo.toml`, locked in the
  committed `Cargo.lock`. `reqwest` uses `rustls-tls`, never `openssl-sys`.
  `ci.sh check cargo-audit` flags vulnerable versions (job `cargo-audit` in
  `ci.yml` on lockfile changes, daily in `nightly.yml`).
- **GitHub Actions**: major tag `vN`; SOT `github_actions`.
- **Docker base images**: SOT `base_images`, passed to the Dockerfiles as
  build arguments (`docs/policy/ci-image-pinning-policy.md`).
- **Dependabot** (`.github/dependabot.yml`): weekly GitHub Actions updates on
  `current_dev`, grouped into one pull request.
- Cargo fetches crates from crates.io during the image build; no third-party
  Rust source is committed. The Public Suffix List is not committed;
  `setup.sh` loads it at install and update, `ci.sh update-psl` in CI, into
  `services/ui/nginx/public_suffix_list.dat` (git-ignored).

## Local checks

All verification runs inside the build-tools container. Results from host
tools do not count.

```bash
BUILD_TOOLS_IMAGE="$(bash .github/scripts/ci.sh build-tools resolve-image)"
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/work:ro" -w /work "$BUILD_TOOLS_IMAGE" <check-command>
```

`build-tools resolve-image` needs `GITHUB_ACTOR` and `GHCR_TOKEN`. It reads the
channel of `GITHUB_BASE_REF` or `GITHUB_REF_NAME`, else the SOT
`release.default_channel`, and accepts the image only when every platform
image is `ACCEPTED` for `build-tools` in the acceptance ledger
(`CI-ERROR-BUILDTOOLS-0031` otherwise).

| Change | Check command |
|--------|---------------|
| Shell scripts | `bash .github/scripts/ci.sh check shellcheck` |
| Workflows | `bash .github/scripts/ci.sh check actionlint` and `bash .github/scripts/ci.sh check action-node-versions` |
| Rust (`-p <crate>` narrows it) | `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test` (mount `$PWD` writable) |
| Everything | `bash .github/scripts/ci.sh check all` |
| Compose (no container needed) | `docker compose -f deploy/prod/docker-compose.yml config` |

A check that could not be run is named in the pull request with the reason.

## Setup and update

`setup.sh` is part of the product; its changes are runtime changes. Setup and
update pull prebuilt images and do not depend on build accelerators or host
cache state. Rules:

- existing `.env` values are never overwritten silently
- newly required values are added during update when safe
- generated secrets are unique per installation
- Docker Compose is validated before containers restart
- errors fail closed with a message a non-expert operator understands

## Releases and packages

Release and package changes follow `docs/combined-release-and-checklist.md` and
the SOT (`services`, `build_toolchain`, `base_images`, `release`).

- first-party runtime images are promoted as one stack set
- `latest` is the channel from `master`; release tags `vX.Y.Z` move it
- `nightly` is the experimental channel from `current_dev`, moved daily and on
  demand by `.github/workflows/nightly.yml` after validation, never rebuilt
  there
- release candidates are `vX.Y.Z-rc.N` GitHub prereleases
- every job after the first runs in the build-tools image the first job
  resolved to a digest; only the first job and the jobs that run when it
  failed use the mutable `build-tools:nightly` channel
- a `release.yml` dispatch on `master` with `action: promote-build-tools` moves
  `build-tools:latest` to the ledger-`ACCEPTED` build-tools image of the
  dispatched tree; it never builds
- every first-party compose image is one `LANCACHE_IMAGE_REF_<NAME>` value,
  written by `setup.sh` as `<image>@<digest>`
- package, workflow, release-note and setup changes pass
  `bash .github/scripts/ci.sh check all`

## Admin UI

The Admin UI shows the current state, including optional, unavailable or
partly configured features. When it cannot read logs, reach Docker or
PowerDNS, or update a service, it shows an error; it never reports a failed
action as successful.

## Collaborator access

`.github/CODEOWNERS` lists one owner (`@djdomi`). Before anyone gets write,
triage or admin access, a `CODEOWNERS` entry or access to a repository secret,
the maintainer reviews:

- the contributor's history on this repository
- the identity behind the account (established account, known affiliation)
- the narrowest scope that fits the need

The review happens before access is granted. A bot or GitHub App that grants
permissions goes through the same review before installation.

## Security issues

Report vulnerabilities privately (see `SECURITY.md`): exposed secrets,
unauthorized administration, weaker TLS interception, services published to
the network, or broken DNS/DHCP isolation. Hardening changes go through a
normal pull request that names the threat being reduced.
