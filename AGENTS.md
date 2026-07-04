# lancache-ng — Repository Governance

**Project**: lancache-ng — a local download cache for home networks, LAN parties, labs, schools, offices, or gaming rooms. Stores game/software downloads locally so repeat downloads on the LAN run at LAN speed instead of re-fetching from the internet. Adds SSL interception (MITM via a custom CA) and full IPv6 dual-stack support on top of the original lancachenet concept.
**Repository**: https://github.com/wiki-mod/lancache-ng
**See also**: `CLAUDE.md` (Claude Code project instructions, auto-loaded every session) for architecture details and dev/prod setup; `README.md` for end-user-facing documentation.

This file contains repository-wide agent rules. It applies to all paths in this repository, including `.github/**`, `setup.sh`, `deploy/**`, `config/**`, `scripts/**`, and `services/**`.

## Language

All GitHub content — issues, pull requests, commit messages, code comments, and documentation — must be written in **English**.

## Issue And PR Tracking

- Issue descriptions must include the correct links to related pull requests, issues, or parent tracking threads when those relationships are known.
- Issues should also carry labels, an issue Type, a Milestone when one applies, and Project-board assignment; use GitHub's native parent/sub-issue relationship (not just a title convention) when an issue is genuinely a sub-task of a tracking issue. An issue left as an unclassified note without these fields is not fully triaged.
- Pull requests must reference their tracking issue in the PR body whenever possible.
- Every pull request body must include a changelog-style summary: what changed, user-visible impact, how it was validated, known risk, and any follow-up work. A PR without this cannot be called integration-ready regardless of CI status.
- Use closing keywords such as `Fixes #123` or `Closes #123` only when merging the PR should close the issue.
- Use non-closing references such as `Refs #123` for parent trackers, design discussions, drafts, or partial follow-up work.
- Scaffold or partial-fix PRs must say they are scaffold or partial in the title/body, must name the remaining open tracker with `Refs #123`, and must not use `Fixes #123` / `Closes #123` for the unresolved remainder.
- After a PR lands, compare the merge commit or current `github/master` against the original issue before claiming completion; PR-head-only claims are not sufficient.
- Do not leave known issue/PR relationships only in chat history; capture them in GitHub so review, merge, and cleanup decisions stay traceable.

## Agent Workflow

- Start every branch from a freshly fetched and rebased current base branch.
- Before making readiness, mergeability, or integration-order statements, fetch the PR branch and base branch, rebase the local worktree onto the current remote base, and verify the resulting head. If a branch cannot be rebased, state that blocker instead of giving a readiness conclusion.
- Use a separate worktree for each non-trivial PR or subagent task.
- Use fanout for bounded independent work when it reduces main-thread cost without reducing quality. Prefer the cheapest suitable model and reasoning level: Spark first while available; if Spark is unavailable, rate-limited, or unsuitable, evaluate `gpt-5.4-mini` next before keeping delegable work in the main thread.
- Choosing main-thread work while Spark is unavailable requires a concrete reason, such as unsafe delegation, time-critical local context, or higher integration risk from a separate agent.
- Treat subagent results as stale until verified against the current remote base and current PR head. Before using an agent result for readiness, conflict resolution, review comments, or merge guidance, compare the reported commit/base with GitHub and rerun the relevant checks on the current head.
- Do not block on subagents when useful non-overlapping work is available. Poll sparingly, and close completed agents after their result has been reviewed or superseded.
- Do not push directly to `master`. All changes go through pull requests.
- Do not merge, close, or delete repository work unless the maintainer explicitly asks for that exact action.
- Keep PRs in draft until the branch has passed local validation and known review findings are addressed.
- Resolve review threads only after the finding was actually fixed or a clear maintainer-approved explanation was posted.
- Every review finding that was fixed must receive a factual reply explaining the fix and must then be resolved, even if GitHub already marks the thread as outdated after later code movement.
- If GitHub does not allow resolving a stale or outdated thread, add a factual PR comment naming the finding, explaining why it is fixed, and stating that GitHub did not allow resolving it.
- Before changing, reviewing, or resolving an issue or pull request, read the full issue/PR context, including the description, linked issues and PRs, all review comments, replies, and resolved threads, then evaluate the surrounding file and project-wide impact instead of acting only on an isolated line.
- Treat review findings as failure classes, not isolated line comments. Before marking a finding fixed, check matching install, update, secondary, release, CI, documentation, and test paths for the same class of issue.
- README and other documentation can lag behind current code and governance decisions; do not treat existing docs as automatically authoritative when they conflict with current architecture or an agreed rule. When a conflict is found, either correct the documentation or ask before changing behavior to match stale docs.
- Prefer GraphQL (`gh api graphql`) over plain `gh issue`/`gh pr` comment and body-update commands for GitHub writes, since the plain CLI commands have repeatedly failed or behaved inconsistently in this project. Whichever method is used, read the result back immediately per the rules below.
- When writing GitHub issue or pull-request bodies/comments from local files, verify the API call uploads file content and not the literal file path. Read the GitHub object back immediately and treat bodies such as `@/tmp/...` as malformed failed writes that must be corrected before continuing.
- When sending Markdown through GraphQL string variables, pass the raw file content with the CLI's file-upload mode instead of pre-encoding it as JSON. Read the object back and treat leading JSON quotes, escaped newlines, or literal file paths as malformed failed writes.
- Treat warnings as errors for repository work. Do not list a check as successful when it emitted warnings, failed setup, or used a broken fallback.
- **Known conflict with the warnings-as-errors rule, tracked in issue #394**: GitHub's CodeQL Rust extractor emits `macro expansion failed` warnings for ordinary macros (`format!`, `assert_eq!`, `vec!`, `json!`, `tracing::*`, etc.) as a documented upstream limitation of its `rust-analyzer`-based extraction, not because of a defect in this repository's code. A strict, unscoped reading of "warnings are errors" would block CodeQL runs on essentially every Rust PR. Until upstream resolves this, treat these specific, named CodeQL extraction warnings as a carved-out, explicitly tracked exception: they do not block a PR by themselves, but every instance must stay referenced in #394, and #394 must be periodically reevaluated rather than left as a permanent blanket excuse. This exception is scoped to CodeQL Rust macro-expansion extraction warnings only — it does not extend to `cargo check`/`cargo clippy` warnings, which remain hard failures under the rule above.
- Treat standard failures such as `command not found`, missing files, missing environment variables, permission denied, malformed commands, empty required outputs, and failed tool setup as hard failures.
- Quote search patterns so literals such as backticks, `$()`, `${...}`, pipes, and redirects cannot be interpreted by the shell. A command that accidentally executes part of the search pattern is malformed and invalidates that verification attempt.
- Do not hide required command failures with `|| true`. Use optional fallbacks only when the command is explicitly optional and the reason is documented.
- Use local Bash tools such as `rg` for text searches; do not rely on vague manual inspection when a deterministic search is possible.
- Do not add Python scripts, Python dependencies, or another runtime language to the project without explicit maintainer approval. Local, one-off `python3` commands for inspection or validation (e.g. checking JSON/YAML, a quick text transform) are fine as long as nothing Python-related is committed to the repository.
- Project-facing text must be in English.
- Take the big picture
- Think big.
  - Always look at the bigger picture. Do not only consider the change itself. Consider its dependencies, its impact, and what may happen as a result.

## Required Validation

- Run the narrowest relevant checks for the files changed, and report any check that could not be run.
- Shell changes require at least `bash -n`, `shellcheck --severity=warning`, and `git diff --check` for the changed shell files.
- Rust changes require `cargo fmt --check`, `cargo check`, `cargo clippy -- -D warnings`, and `cargo test` for the affected crate or workspace path, unless the PR documents a real blocker.
- Dockerfile or Compose changes require `docker compose config` for the affected deployment files and a relevant image build when practical.
- Workflow changes require syntax validation and a careful review of runner labels, secrets, variables, matrix behavior, and cache behavior.
- Local Docker build checks for Rust service builders must mirror CI acceleration wiring when they are used to prove build performance or cache behavior. That means passing the same `BUILD_TOOLS_IMAGE`, `CARGO_BUILD_JOBS`, and BuildKit secret mounts for sccache, sccache-dist, and distcc. A local build without those secrets may validate Dockerfile syntax only; it must not be cited as proof that the compile farm is used.
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

- **Docker builds**: production/runtime Dockerfiles still use multi-stage builds with pinned base images, but the Rust service builders for `services/dns` and `services/ui` consume the prebuilt `ghcr.io/wiki-mod/lancache-ng/build-tools` contract through a `BUILD_TOOLS_IMAGE` argument. Do not add ad-hoc `rust:latest` or Debian-based bootstrap layers back into those service builders. Local developer helper scripts and the repository build-tools image intentionally use `rust:latest` by default when the image is explicitly overrideable; this keeps developer validation tooling current while remaining separate from production service image pinning.
- **Runner baseline**: assume self-hosted runners do not provide project validation tools. Workflows must use pinned GitHub Actions, the repository build-tools image, or explicit fail-closed capability checks instead of relying on host-installed utilities. Pin GitHub Actions to full commit SHAs with a version comment, not mutable tags such as `@v4`, branch names, or `@main`. Do not install project validation tools with ad-hoc `sudo apt-get` in workflows.
- **Runner tiers**: route lightweight static checks to `[self-hosted, linux, lancache, lancache-light]` and memory-heavy Rust, CodeQL, container scan, Docker build, and release jobs to `[self-hosted, linux, lancache, lancache-heavy]`. Do not rely on the broad `lancache` label alone for jobs with meaningful CPU or memory pressure.
- **Build acceleration scope**: `sccache`, `sccache-dist`, `distcc`, `distcc-pump`, and local Buildx cache paths are allowed only as Dev/CI optimizations. Production, runtime, setup, and update flows must stay pull-only against prebuilt images and must not depend on those accelerators.
- **Runner portability**: LAN-only acceleration such as Redis-backed sccache, sccache-dist, distcc, local Buildx cache paths, and self-hosted runner labels must stay explicitly configurable. Treat the current self-hosted runner farm as an optimization layer, not as the only valid CI environment. GitHub-hosted fallback jobs must validate without inheriting LAN-only assumptions about Redis URLs, distcc schedulers, cache paths, or runner labels; use documented modes, variables, and fail-closed capability checks instead of hidden host assumptions.
- **Build-tools image**: `tools/build-tools/Dockerfile` intentionally uses `rust:latest`, then installs and smoke-tests required tools such as `rustfmt`, `clippy`, `sccache`, `cargo-audit`, `shellcheck`, `actionlint`, `distcc`, `distcc-pump`, Docker CLI, Docker Compose, and DNS/setup/template fixture tools such as `dig`, `ip`, `openssl`, `rsync`, and `envsubst`. It must explicitly set and verify `PATH`, especially `/usr/local/cargo/bin`, to avoid false `command not found` failures. CI jobs that only need bundled validation tools must use the prebuilt image instead of compiling those tools per job; for example, do not install `cargo-audit` in workflow jobs. CodeQL and Trivy image scanning remain GitHub workflow and runner capabilities, not tools bundled into this image.
- **Tool image rebuilds**: routine pull requests must not rebuild the build-tools image unless `tools/build-tools` or the build workflow changed. The dedicated build-tools workflow must support manual and scheduled refreshes and publish `linux/amd64` plus `linux/arm64` images after smoke tests and scans. Release tags must always build the tag-scoped build-tools image so release jobs never run with a mutable `latest` tool image.
- **Release job acceleration contract**: any release or release-adjacent job that uses build acceleration must document whether the accelerator is optional, preferred, or a hard gate. Do not leave the fallback behavior implicit.
- **TLS in Rust**: use `reqwest` with `default-features = false, features = ["rustls-tls"]`. Never add `openssl-sys` as a dependency — `rust:slim` has no OpenSSL headers.
- **sccache**: controlled by `SCCACHE_REDIS_MODE` (`required`, `optional`, `off`) and the `SCCACHE_REDIS_URL` GitHub Actions secret. Never hardcode a Redis URL. If `SCCACHE_DIST_SCHEDULER_URL` is configured, the matching `SCCACHE_DIST_AUTH_TOKEN` secret must also be configured and wired into `SCCACHE_CONF`; setting only a scheduler URL environment variable is not a valid sccache-dist setup. When installing sccache from source, keep the sccache version pinned, avoid locked installs while the pinned upstream lockfile emits yanked-crate warnings, and enable only the Redis plus `dist-client` features unless a PR explicitly justifies another backend.
- **distcc/pump**: Rust service builders that install `distcc` must receive host lists through BuildKit secrets or trusted CI variables, never hardcoded Dockerfile values. When enabled, they must set `CC=distcc`, `GCC=distcc`, `CXX=distcc`, and discover either `/usr/local/lib/distcc` or `/usr/lib/distcc` before putting the discovered wrapper directory at the front of `PATH`, so direct `cc`, `gcc`, `c++`, and `g++` calls are intercepted across Debian and distcc-ng layouts. `distcc-pump` host lists must include at least one `,cpp` host entry. `distcc-pump` remains the default, preferred acceleration path — the bypass below is selective, not a reason to disable pump for a whole builder: specific compile inputs known to break pump's include-server assumptions (e.g. generated C headers such as `aws-lc-sys`'s, since pump assumes sources and includes do not change during the include-server lifetime) must route through normal (non-pump) distcc hosts or local compiler fallback for those inputs only, while the rest of that builder's compilation still uses pump normally. Distcc must log `[INFO] trying distcc path.` when it is actually attempted, must use `DISTCC_FALLBACK=0`, and may retry once with the normal local compiler if the distcc path is unavailable. Any image that installs Debian `distcc-pump` must patch the known invalid Python regex escapes before package configuration and verify the result with `python3 -Werror::SyntaxWarning`.
- **Build parallelism**: Cargo and Docker Rust builds must use one project-wide job rule unless a PR justifies an override: the optional `CARGO_BUILD_JOBS` repository variable wins when set and must be validated as a positive integer; otherwise use detected CPU cores minus two, with a minimum of four jobs. Do not hardcode service-local values such as `CARGO_BUILD_JOBS=6`.
- **Build acceleration wiring**: Installing `sccache`, `distcc`, or `distcc-pump` is not sufficient. Every PR that changes Rust builders or build workflows must verify the full chain: repository variable or secret, workflow input, BuildKit secret or Cargo environment, Dockerfile consumption, and a fail-closed smoke/status check.
- **Prebuilt build-tools contract**: Rust service builders should consume a prebuilt `build-tools` image by immutable release, SHA, or the selected CI image contract instead of rebuilding toolchains in each service image. Reintroducing ad-hoc local toolchain compilation in `services/dns` or `services/ui` requires a documented reason and a separate review of first-user-experience impact.
- **Cache key**: nginx uses `$host$uri` (not `$request_uri`) — CDN query-string signatures must not bust the cache.
- **DNS resolver in nginx**: must point to `8.8.8.8`, never to the local PowerDNS recursor — that would cause an infinite loop.
- **Domain scope semantics**: a leading-dot domain entry such as `.example.com` is an explicit wildcard/subdomain scope and is not equivalent to the root domain `example.com`. Do not normalize away the leading dot or treat root and wildcard scope as interchangeable in any validation, matching, or migration logic that touches domain entries.

## Release And Package Consistency

- `latest` means the current stable release channel; it must not be moved by a routine `master` build. `edge` means the tested pre-stable channel promoted from `master`. Release tags (`vX.Y.Z`) are immutable. Any documentation, issue, PR body, workflow comment, or setup output implying `latest` equals `edge` or `master` is wrong and must be corrected.
- Stack versioning, GHCR package/channel definitions, and release documentation must move together: release and package changes must follow `docs/release-versioning.md` and the machine-readable inventory in `release/stack-images.yml`, and must run `bash scripts/validate-stack-images.sh`. A package/image change that only edits workflow files without checking these is incomplete.

## Comment Style

- Comment only when the code would not otherwise be quickly understandable. Well-named identifiers already say what trivial code does (setting a variable, calling a function, reading a file) — do not restate that in a comment.
- Comment concrete cases where the WHY is non-obvious: complex logic, guards, fallbacks, security decisions, non-obvious side effects, a workaround for a specific bug, or a deliberate deviation from the obvious/standard approach. Also comment when omitting the note would let someone later reintroduce the same mistake. If removing the comment would not confuse a future reader, remove it.
- Code must stay human-readable. Silent or hard-to-follow changes are not acceptable — if a change needs explanation to be trusted, write the comment; don't ship it silently.
- Short structural/orientation comments that label the steps of a longer sequential procedure (e.g. `// Step 1: Fetch current config`, `// Step 2: Validate and normalize`) are also acceptable and encouraged, even when they don't explain a hidden WHY — they help a reader scan a long function without re-deriving its structure. Reviewers (including automated ones) must not flag this style as "unnecessary" or "restates the code" just because `Comment Style` otherwise favors minimal comments; readability-oriented step labels are a distinct, allowed category from WHY-comments, not a violation of this section.
- A missing comment is a defect too, not just a neutral default. When touching code in an area that should already have a WHY-comment under the categories above (complex logic, a guard, a fallback, a security decision, a non-obvious side effect) but doesn't — whether it was missed originally or never added — add it as part of the change. Do not leave the gap just because it predates your edit; "there wasn't one before" is not a reason to skip adding one now.
- Do not reference the current task, PR number, or fix in a comment (e.g. "fixed for #123", "added by the CR-9 pass"). That belongs in the PR/commit description, not in code that outlives the change.
- When documenting a known limitation or deliberately deferred fix (not a bug you're fixing now), prefer a structured note over a one-liner: state the problem, the mitigation/fix direction if one exists, and a dated status line describing the current real-world state (e.g. "STATUS: as of 2026-07-02, X still uses the old path; once Y migrates, this fallback becomes dead code"). This lets a future reader tell a documented tradeoff apart from an accidental gap.
- Placeholder/scaffold markers (e.g. `TODO(#123): ...`) must be removed the moment the referenced work is actually implemented in that same change. A stale TODO claiming work is still needed, sitting next to code that already does it, is worse than no comment — it actively misleads the next reader/reviewer. Before finishing a fix that started from a TODO/scaffold marker, grep for and delete the marker it replaces.

## File Headers

- Every source/config file (Rust, shell, YAML, Dockerfiles, `.conf`/template files, HTML/CSS/JS) should open with a short header: the project name and repo URL, using the literal parenthetical form `lancache-ng (https://github.com/wiki-mod/lancache-ng)` — this exact string is what `scripts/check-file-headers.sh` greps for, so don't substitute an em-dash or other punctuation — followed by a purpose description of that specific file. Use the comment syntax valid for that specific file's language — do not default to `#` for every non-Rust file, since that is invalid syntax in some of them:
  - Rust: `//!` inner doc comments.
  - Shell, YAML, Dockerfiles, and genuinely plain-text `.conf`/template files (i.e. not files that only carry a `.conf` extension while actually holding JSON — see the JSON exclusion below): `#` line comments (after the shebang line, if there is one).
  - HTML Tera templates under `services/ui/src/templates/`: Tera's own `{# ... #}` comment syntax, not a raw HTML `<!-- ... -->` comment. Several templates in this directory (e.g. `dashboard.html`) start with `{% extends "base.html" %}` as their required first tag; Tera tolerates a `{# ... #}` comment before `extends`, but a literal `<!-- ... -->` comment is ordinary HTML content and breaks that requirement, causing `load_templates` in `services/ui/src/main.rs` to fail at startup. Use `{# ... #}` for every template in this directory, including ones that don't currently extend another template, so the convention stays uniform and safe if that changes later.
  - CSS (`.css`): `/* ... */` comments.
  - JavaScript (`.js`): `//` line comments (or `/* ... */` for a multi-line block).
  - If a file's language isn't listed here, use that language's own standard comment syntax — never `#` by default without checking it's actually valid for that file type.
- Before adding a header to any file with a `.conf`/`.json`/`.txt`/other generic-looking extension, check what actually parses it and how. If the content is genuinely JSON (JSON has no comment syntax at all), do not add any header; a `#` or any other comment line would break parsing. In this repo, all three Kea config files under `services/dhcp/` are JSON despite the `.conf` extension and must be excluded on this basis: `kea-dhcp4.conf` (parsed by `migrate_dhcp4_config` in `services/dhcp/entrypoint.sh`), `kea-ctrl-agent.conf`, and `kea-dhcp-ddns.conf`. The same JSON exclusion applies to any other file this project treats as machine-parsed structured data without a comment syntax, whatever its extension.
- Do not add a header to a file whose entire content is consumed as a single raw value by a strict parser, where any extra text (including a comment) would corrupt that value. The clearest example in this repo is the root `VERSION` file: `setup.sh`'s `derive_current_release_image_tag` reads the whole file, strips whitespace, and requires the result to match a release-tag pattern — a header would be concatenated into that value and break setup/update with an invalid release image tag.
- Do not add a header to a vendored third-party file or a generated/compiled build artifact — it isn't this project's own hand-authored source, and in the vendored case it likely already carries its own upstream header. In this repo: `services/ui/src/static/chart.umd.min.js` is the vendored, minified Chart.js library (already opens with its own `/*! Chart.js v4.5.1 ... */` header) and `services/ui/src/static/admin.css` is compiled/minified Tailwind CSS output, not hand-written CSS. If a hand-written source input for a generated artifact is ever added to the repo (e.g. a Tailwind config or an unminified source file), that source input is in scope for a header; the generated output it produces is not.
- Scale the header's detail to the file's actual complexity — a file with several distinct responsibilities (e.g. a multi-role entrypoint script, a large route-wiring module) should name them; a simple, single-purpose file (e.g. an install-and-copy Dockerfile) should stay short. Do not pad a simple file's header just to match a fixed line count.
- Every technical claim in a header must be verified against the actual file content and, where relevant, git history — do not assert an unconfirmed reason for a design choice (e.g. why a particular base image or repo is used) if no documented rationale exists; state the observable fact instead.
- Excluded: `.md` files, a literal root-level `.env` or `.env.example` file (not every file with a `.env` extension — the per-service defaults under `config/dev/` and `config/prod/` such as `dhcp.env` are ordinary committed config and are in scope for a header), lockfiles (`Cargo.lock`), `.gitkeep`, the root `VERSION` file, vendored/generated build artifacts, and any file whose content is JSON or another comment-free structured format regardless of its extension (see above for concrete examples of each). See `scripts/check-file-headers.sh`'s `is_excluded()` function for the exact, executable list this maps to.
- No license line — the project has not adopted a license yet; that is a separate, not-yet-started decision and must not be conflated with file headers.
- The repo-wide backfill for this rollout (originally tracked in issue #409, backfill itself tracked in #431) is complete, and `scripts/check-file-headers.sh` runs as a CI job (`file-headers` in `build-push.yml`) that fails a PR if any non-excluded tracked file is missing the header. If you add a new file, or a future PR turns up one this backfill missed, add the header immediately rather than treating CI failure as something to work around.

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
