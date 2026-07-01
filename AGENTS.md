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
- Before changing, reviewing, or resolving an issue or pull request, read the full issue/PR context, including the description, linked issues and PRs, all review comments, replies, and resolved threads, then evaluate the surrounding file and project-wide impact instead of acting only on an isolated line.
- Treat review findings as failure classes, not isolated line comments. Before marking a finding fixed, check matching install, update, secondary, release, CI, documentation, and test paths for the same class of issue.
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

Shell automation should use Bash by default when it relies on project fail-closed behavior such as `set -euo pipefail`, arrays, `[[ ... ]]`, process substitution, or other Bash-specific syntax. POSIX `sh` is acceptable only for intentionally small portable scripts that are validated with ShellCheck in `sh` mode.

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

- **Docker builds**: production/service Dockerfiles use multi-stage builds with pinned `rust:slim` builder images. Do not use `rust:latest` or Debian-based builder images for production/service Dockerfiles. Local developer helper scripts and the repository build-tools image intentionally use `rust:latest` by default when the image is explicitly overrideable; this keeps developer validation tooling current while remaining separate from production service image pinning.
- **Runner baseline**: assume self-hosted runners do not provide project validation tools. Workflows must use pinned GitHub Actions, the repository build-tools image, or explicit fail-closed capability checks instead of relying on host-installed utilities. Pin GitHub Actions to full commit SHAs with a version comment, not mutable tags such as `@v4`, branch names, or `@main`. Do not install project validation tools with ad-hoc `sudo apt-get` in workflows.
- **Runner portability**: LAN-only acceleration such as Redis-backed sccache, sccache-dist, distcc, local Buildx cache paths, and self-hosted runner labels must stay explicitly configurable. Treat the current self-hosted runner farm as an optimization layer, not as the only valid CI environment. Do not make repository builds impossible on future GitHub-hosted runners merely because local acceleration is unavailable; use documented modes, variables, and fail-closed capability checks instead of hidden host assumptions.
- **Build-tools image**: `tools/build-tools/Dockerfile` intentionally uses `rust:latest`, then installs and smoke-tests required tools such as `rustfmt`, `clippy`, `sccache`, `cargo-audit`, `shellcheck`, `actionlint`, `distcc`, `distcc-pump`, Docker CLI, Docker Compose, and DNS/setup/template fixture tools such as `dig`, `ip`, `openssl`, `rsync`, and `envsubst`. It must explicitly set and verify `PATH`, especially `/usr/local/cargo/bin`, to avoid false `command not found` failures. CodeQL and Trivy image scanning remain GitHub workflow and runner capabilities, not tools bundled into this image.
- **TLS in Rust**: use `reqwest` with `default-features = false, features = ["rustls-tls"]`. Never add `openssl-sys` as a dependency — `rust:slim` has no OpenSSL headers.
- **sccache**: controlled by `SCCACHE_REDIS_MODE` (`required`, `optional`, `off`) and the `SCCACHE_REDIS_URL` GitHub Actions secret. Never hardcode a Redis URL. If `SCCACHE_DIST_SCHEDULER_URL` is configured, the matching `SCCACHE_DIST_AUTH_TOKEN` secret must also be configured and wired into `SCCACHE_CONF`; setting only a scheduler URL environment variable is not a valid sccache-dist setup. When installing sccache from source, keep the sccache version pinned, avoid locked installs while the pinned upstream lockfile emits yanked-crate warnings, and enable only the Redis plus `dist-client` features unless a PR explicitly justifies another backend.
- **distcc/pump**: Rust service builders that install `distcc` must receive host lists through BuildKit secrets or trusted CI variables, never hardcoded Dockerfile values. When enabled, they must set `CC=distcc`, `GCC=distcc`, `CXX=distcc`, and discover either `/usr/local/lib/distcc` or `/usr/lib/distcc` before putting the discovered wrapper directory at the front of `PATH`, so direct `cc`, `gcc`, `c++`, and `g++` calls are intercepted across Debian and distcc-ng layouts. `distcc-pump` host lists must include at least one `,cpp` host entry, but builders that compile crates with generated C headers must use normal distcc hosts instead of pump because pump assumes sources and includes do not change during the include-server lifetime. Distcc must log `[INFO] trying distcc path.` when it is actually attempted, must use `DISTCC_FALLBACK=0`, and may retry once with the normal local compiler if the distcc path is unavailable. Any image that installs Debian `distcc-pump` must patch the known invalid Python regex escapes before package configuration and verify the result with `python3 -Werror::SyntaxWarning`.
- **Build parallelism**: Cargo and Docker Rust builds must use one project-wide job rule unless a PR justifies an override: the optional `CARGO_BUILD_JOBS` repository variable wins when set and must be validated as a positive integer; otherwise use detected CPU cores minus two, with a minimum of four jobs. Do not hardcode service-local values such as `CARGO_BUILD_JOBS=6`.
- **Build acceleration wiring**: Installing `sccache`, `distcc`, or `distcc-pump` is not sufficient. Every PR that changes Rust builders or build workflows must verify the full chain: repository variable or secret, workflow input, BuildKit secret or Cargo environment, Dockerfile consumption, and a fail-closed smoke/status check.
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
