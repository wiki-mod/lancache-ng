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

Each pull request should explain:

- what changed
- why the change is needed
- how users or operators are affected
- which checks were run
- any remaining risk or follow-up work

Prefer focused pull requests. For example, do not mix documentation rewrites,
CI fixes and runtime behavior changes unless they must land together.

### PR and issue linking

Track related work explicitly in the PR body:

- Use `Refs #123` for parent issues, umbrella issues, and follow-up references.
- Use `Closes #123` only when this PR should also close that issue.
- Open PRs should include links for relevant review context (for example tracking and umbrella issue).

### Changelog expectations

There is no checked-in changelog file.
For each user-facing change, include a short changelog-style summary in the PR body under a clear heading (for example `## Changelog`).
This summary should be reused in the final release notes text when available.
Every pull request should include a changelog section that explains user-visible
behavior, operational impact, validation performed, and any explicit follow-up
issue. Silent changes are not acceptable for release, setup, CI, or runtime
behavior.

### Quality and release process expectations

- Treat warnings as failures in local checks and workflow validation.
- Keep workflow action references pinned to explicit versions or SHAs; avoid floating tags such as `@v4` in project PRs.
- Keep workflow changes reviewable:
  - document changed checks,
  - explain any intentional risk,
  - and include PR links to all impacted issue threads.

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
The UI service lives in `services/ui`.

```bash
cargo test --locked --manifest-path services/ui/Cargo.toml
```

If you cannot run a relevant check locally, say so in the pull request and
explain why.

## Setup and update safety

The setup flow is part of the product. Treat `setup.sh` changes as runtime
changes, not only as installer changes.

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
