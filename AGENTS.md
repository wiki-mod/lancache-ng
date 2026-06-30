# Repository Governance

This file contains repository-wide agent rules. It applies to all paths in this repository, including `.github/**`, `setup.sh`, `deploy/**`, `config/**`, `scripts/**`, and `services/**`.

## Language

All GitHub content — issues, pull requests, commit messages, code comments, and documentation — must be written in **English**.

## Issue And PR Tracking

- Issue descriptions must include the correct links to related pull requests, issues, or parent tracking threads when those relationships are known.
- Pull requests must reference their tracking issue in the PR body whenever possible.
- Use closing keywords such as `Fixes #123` or `Closes #123` only when merging the PR should close the issue.
- Use non-closing references such as `Refs #123` for parent trackers, design discussions, drafts, or partial follow-up work.
- Do not leave known issue/PR relationships only in chat history; capture them in GitHub so review, merge, and cleanup decisions stay traceable.

## Agent Workflow

- Start every branch from a freshly fetched and rebased current base branch.
- Use a separate worktree for each non-trivial PR or subagent task.
- Do not push directly to `master`. All changes go through pull requests.
- Do not merge, close, or delete repository work unless the maintainer explicitly asks for that exact action.
- Keep PRs in draft until the branch has passed local validation and known review findings are addressed.
- Resolve review threads only after the finding was actually fixed or a clear maintainer-approved explanation was posted.
- Treat warnings as errors for repository work. Do not list a check as successful when it emitted warnings, failed setup, or used a broken fallback.
- Treat standard failures such as `command not found`, missing files, missing environment variables, permission denied, malformed commands, empty required outputs, and failed tool setup as hard failures.
- Do not hide required command failures with `|| true`. Use optional fallbacks only when the command is explicitly optional and the reason is documented.
- Use local Bash tools such as `rg` for text searches; do not rely on vague manual inspection when a deterministic search is possible.
- Do not add Python scripts, Python dependencies, or another runtime language to the project without explicit maintainer approval.
- Project-facing text must be in English.
- Take the big Picture
- Think big.
  - Always look at the bigger picture. Do not only consider the change itself. Consider its dependencies, its impact, and what may happen as a result.

## Required Validation

- Run the narrowest relevant checks for the files changed, and report any check that could not be run.
- Shell changes require at least `bash -n`, `shellcheck --severity=warning`, and `git diff --check` for the changed shell files.
- Rust changes require `cargo fmt --check`, `cargo check`, `cargo clippy -- -D warnings`, and `cargo test` for the affected crate or workspace path, unless the PR documents a real blocker.
- Dockerfile or Compose changes require `docker compose config` for the affected deployment files and a relevant image build when practical.
- Workflow changes require syntax validation and a careful review of runner labels, secrets, variables, matrix behavior, and cache behavior.
- Setup, update, or migration changes require fixture or dry-run coverage that proves fresh install, repeated update, missing-key migration, existing-value preservation, and placeholder rejection.
- DNS behavior changes require a real DNS response check, not only process or port reachability.
- Proxy/cache behavior changes require a response or cache-behavior check that proves the proxy still serves the intended path.
- Do not weaken checks to make a branch green. If a check is wrong, replace it with an equally strong or stronger check that validates the real behavior.

## Setup, Update, And Migration Semantics

- Setup, update, and migration logic must be idempotent: running the same operation repeatedly must not rotate existing secrets, overwrite local configuration, or create new side effects unless the user explicitly requested that change.
- Setup, update, and migration logic must converge old or incomplete installations toward the current expected state.
- Missing required configuration values should be generated when safe or rejected with a clear fail-closed error when they require user input.
- Existing non-empty local values must be preserved by default.
- Known placeholders such as `CHANGE_ME_*` are not valid runtime values and must be replaced or rejected before dependent services start.
- Validation must happen before container restart, image pull, or runtime mutation when a failed validation would leave the installation in a worse state.
- Re-running `setup.sh update` after a successful update should report no destructive changes and should not rewrite stable local files unnecessarily.

## Project Language

This project is written in **Rust**. Shell scripts are permitted for entrypoints and automation.

No other runtime language (Go, Python, Node.js, etc.) may be introduced without explicit approval from @djdomi.

## Feature Completeness

- Treat the Admin UI as an unfinished control plane.
- If backend code supports a feature but the Admin UI does not expose it, treat that as UI delivery debt by default.
- Do not remove partially implemented features merely because a review found them incomplete; first decide whether the correct fix is to finish and wire the feature.
- Kea and PowerDNS were selected because they provide APIs. Prefer completing API-backed integrations over deleting the feature surface.

## Architecture

A LAN cache that intercepts and caches game/software downloads. Two operating modes:

| Mode | Port 443 | CA cert needed? |
|---|---|---|
| standard | SNI passthrough | No |
| ssl | MITM-cached (TLS interception) | Yes |

Stack: Docker / Debian Trixie, nginx, PowerDNS, NATS JetStream, Rust services.

## Coding Patterns

- **Docker builds**: production/service Dockerfiles use multi-stage builds with pinned `rust:slim` builder images. Do not use `rust:latest` or Debian-based builder images for production/service Dockerfiles. Local developer helper scripts and the repository build-tools image intentionally use `rust:latest` by default when the image is explicitly overrideable; this keeps developer and CI validation tooling current while remaining separate from production service image pinning.
- **Build-tools image**: `tools/build-tools/Dockerfile` intentionally uses `rust:latest`, then installs and smoke-tests required tools such as `rustfmt`, `clippy`, `sccache`, `cargo-audit`, and `shellcheck`. It must explicitly set and verify `PATH`, especially `/usr/local/cargo/bin`, to avoid false `command not found` failures.
- **TLS in Rust**: use `reqwest` with `default-features = false, features = ["rustls-tls"]`. Never add `openssl-sys` as a dependency — `rust:slim` has no OpenSSL headers.
- **sccache**: controlled by `SCCACHE_REDIS_MODE` (`required`, `optional`, `off`) and the `SCCACHE_REDIS_URL` GitHub Actions secret. Never hardcode a Redis URL.
- **Cache key**: nginx uses `$host$uri` (not `$request_uri`) — CDN query-string signatures must not bust the cache.
- **DNS resolver in nginx**: must point to `8.8.8.8`, never to the local PowerDNS recursor — that would cause an infinite loop.

## Runtime Behavior

- Lazy proxy/cache behavior is the intended default.
- Strict proxy/cache behavior is explicit opt-in for users who want tighter allowlisting and accept the maintenance burden.
- Do not silently invert the lazy default.
- DNS health checks must use a real query/response probe such as `dig` or an equivalent strong check.
- `ping` is not an acceptable DNS health check because it only proves network reachability.
- `ss` is not an acceptable DNS health check by itself because it only proves that a socket is listening.

## Secrets And Sensitive Data

- Never commit private credentials, tokens, personal contact data, or internal LAN-only secrets.
- Use GitHub Secrets for secret values and GitHub Variables for non-secret configuration values.
- Do not hardcode local Redis, scheduler, distcc, or runner endpoints in source files, Dockerfiles, or workflows.
- If sensitive data appears in a branch, stop normal work and remove it from the active branch before continuing.

## What Not To Do

- Do not push directly to `master`. All changes go through pull requests.
- Do not hardcode LAN IP addresses in Dockerfiles or source files.
- Do not introduce a new programming language without explicit approval.
- Do not use `proxy_cache_key $request_uri` — query strings contain per-request CDN signatures.
