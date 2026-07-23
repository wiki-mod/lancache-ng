# lancache-ng — Repository Governance

**Project**: lancache-ng — a local download cache for home networks, LAN parties, labs, schools, offices, or gaming rooms. Stores game/software downloads locally so repeat downloads on the LAN run at LAN speed instead of re-fetching from the internet. Adds SSL interception (MITM via a custom CA) and full IPv6 dual-stack support on top of the original lancachenet concept.
**Repository**: https://github.com/wiki-mod/lancache-ng
**See also**: `CLAUDE.md` (Claude Code project instructions, auto-loaded every session) for architecture details and dev/prod setup; `README.md` for end-user-facing documentation.

This file contains repository-wide agent rules. It applies to all paths in this repository, including `.github/**`, `setup.sh`, `deploy/**`, `config/**`, `scripts/**`, and `services/**`.

## Language

**[AG-GH-001]** All GitHub content — issues, pull requests, commit messages, code comments, and documentation — must be written in **English**.

## Source of Truth and Conflict Resolution

When working across this repository's documentation and governance stack, conflicts and inconsistencies can emerge between the various sources of guidance. This section establishes an explicit precedence order to resolve such conflicts and a requirement that agents must surface real conflicts rather than silently choosing one source over another.

**Precedence order for resolving documentation conflicts:**

When an agent encounters a real inconsistency or conflict between two governance/documentation sources, apply this precedence order to determine which source takes priority:

1. **[AG-DOC-002] Executable checks and current code behavior** — What the code actually does today and what the CI checks actually enforce today are the ground truth. If documentation claims behavior that contradicts what the code or CI verifiably does, the documentation is stale.
2. **[AG-DOC-003] `AGENTS.md` (this file)** — Repository-wide hard rules for agent behavior, workflow, validation, and governance apply to all work in this repository, except where a more specific source lower in this list carries scoped precedence within its own area. Two such sources currently make that kind of claim, and both take precedence over this file's general guidance within their own stated scope: the area-specific AGENTS files in item 3 (Rule-Ref: AG-DOC-004), once you have identified that your work falls into that area, as item 3 itself states; and `SECURITY.md` in item 4 (Rule-Ref: AG-DOC-005), for security-relevant work, as item 4 itself states.
3. **[AG-DOC-004] Area-specific AGENTS files** (e.g., `.github/AGENTS.md` for GitHub Actions work) — Specialized guidance for specific areas takes precedence over general guidance once you have identified that your work falls into that area.
4. **[AG-DOC-005] `SECURITY.md`** — Security-specific behavior and constraints are documented separately and take precedence for security-relevant work.
5. **[AG-DOC-006] Architecture and release documentation** (e.g., `docs/architecture-ng.md`, `docs/release-versioning.md`, `docs/release-external-images.md`, `docs/threat-model.md`) — System design and release procedures are documented here with rationale.
6. **[AG-DOC-007] `README.md` and user-facing documentation** (e.g., `docs/install-ca-cert.md`) — End-user guides and high-level project descriptions are placed last because they are more likely to lag behind operational or technical changes.

**Surfacing and resolving conflicts:**

When an agent finds a real conflict between two of these sources (not a misreading, but a genuine inconsistency that reflects stale documentation or outdated guidance):

- **[AG-DOC-008] Do not silently pick a side and proceed.** This masks the problem and allows drift to accumulate.
- **[AG-DOC-009] Surface the conflict explicitly** — note it in a PR comment, a dedicated issue, or a follow-up task description. Explain which sources disagree and what real-world behavior you observed.
- **[AG-DOC-010] Fix one side of the conflict or ask for guidance** — either update the stale documentation to match reality, or update the code/CI if the documentation is more correct. Only ask for guidance when the correct behavior is genuinely ambiguous or depends on a user decision. Per the user-context rule (see "Agent Autonomy and User-Context Rule" below), agents are expected to make technical decisions independently; guidance is only needed when there is real operational impact (hardware, cost, network topology) or when the correct target behavior is not determinable from code and documentation alone.

This precedence order exists because this project touches DNS, DHCP, TLS interception, Docker startup behavior, cache correctness, and local network availability — all areas where documentation drift is not a stylistic gap but a real operational risk.

## Documentation Drift Is A Defect

**[AG-DOC-001]** A PR that touches architecture, security, setup, DNS, release, Admin UI authentication, or user-facing behavior must verify that the relevant documentation still accurately describes the resulting reality after the change. Documentation includes: `README.md`, `SECURITY.md`, `docs/threat-model.md`, `docs/architecture-ng.md`, `docs/release-versioning.md`, `docs/release-external-images.md`, `CLAUDE.md`, this file (`AGENTS.md`), and `.github/AGENTS.md`.

A PR is not complete if it leaves any of these documents objectively wrong or describing behavior that contradicts the change. Stale documentation is not a follow-up item — it is a blocker. If a code change invalidates a documented behavior, statement, or threat model characterization, the PR must update the documentation or explicitly explain why the documentation statement is still correct despite the code change.

This rule exists because real drift was discovered and fixed in issue #529: `docs/threat-model.md` contained a stale reference to BIND9 (the system now uses PowerDNS), and described Admin UI authentication as "no authentication by default" when the current code actually fails closed and requires either explicit `UI_AUTH_USER`/`UI_AUTH_PASSWORD` configuration or an explicit `ALLOW_INSECURE_UI=true` opt-out. Both of these drifts were operational risks — operators following the threat model would make incorrect security assumptions, and future developers would misunderstand the current authentication behavior.

## Issue And PR Tracking

- **[AG-GH-002]** Issue descriptions must include the correct links to related pull requests, issues, or parent tracking threads when those relationships are known.
- **[AG-GH-009]** Issues should also carry labels, an issue Type, a Milestone when one applies, and Project-board assignment; use GitHub's native parent/sub-issue relationship (not just a title convention) when an issue is genuinely a sub-task of a tracking issue. An issue left as an unclassified note without these fields is not fully triaged.
- **[AG-GH-003]** Pull requests must reference their tracking issue in the PR body whenever possible.
- **[AG-GH-010]** Every pull request body must include a changelog-style summary: what changed, user-visible impact, how it was validated, known risk, and any follow-up work. A PR without this cannot be called integration-ready regardless of CI status.
- **[AG-GH-008]** Pull requests must carry at least one label, a Milestone (when one applies — same qualifier as the issue-metadata rule above; not every issue has one, and a PR mirroring such an issue doesn't need to invent one either), and Project-board assignment. When a PR closes or fixes a single issue via `Closes #123`/`Fixes #123`, mirror that issue's labels and Milestone rather than picking new ones. When a PR closes one issue but also carries a non-closing `Refs #456` to a parent tracker or design discussion, the closed/fixed issue is the metadata source — never the `Refs` target, since a `Refs`-only tracker can legitimately carry different labels or a different Milestone than the specific PR resolving one of its sub-tasks. A PR with no tracking issue at all (a maintainer-directed or housekeeping change — the PR template explicitly allows stating no issue exists) still needs its own labels and Milestone chosen at review time; there's simply no issue to copy them from. A PR with correct code and green CI but no labels and no Project-board entry is not properly filed; do not treat "the code is right" as equivalent to "the tracking metadata is complete."
- **[AG-GH-004]** Use closing keywords such as `Fixes #123` or `Closes #123` only when merging the PR should close the issue.
- **[AG-GH-005]** Use non-closing references such as `Refs #123` for parent trackers, design discussions, drafts, or partial follow-up work.
- **[AG-GH-011]** Scaffold or partial-fix PRs must say they are scaffold or partial in the title/body, must name the remaining open tracker with `Refs #123`, and must not use `Fixes #123` / `Closes #123` for the unresolved remainder.
- **[AG-GH-012]** After a PR lands, compare the merge commit or current `github/master` against the original issue before claiming completion; PR-head-only claims are not sufficient.
- **[AG-GH-006]** Do not leave known issue/PR relationships only in chat history; capture them in GitHub so review, merge, and cleanup decisions stay traceable.
- **[AG-GH-013]** Actively maintain issues and PRs with comments as work happens, not only a body/description written once at creation time. Post a comment for each significant finding, decision, root cause, or piece of new information as soon as it is known, rather than batching everything into one end-of-work summary. This applies to agents doing the work, not only to whoever dispatched them: an agent performing non-trivial investigation, a fix, or research must post its own findings as GitHub comments while working, not leave them only in a chat transcript or a final report for someone else to transcribe afterward. Concretely: within the first 15 minutes of starting non-trivial work on an issue or PR, post an initial WIP comment stating what is being investigated or attempted, then post a further update at least every 15 minutes thereafter for as long as the task runs, until it is done. Determine elapsed time by actually running a real time/date command (e.g. `date +%s`, compared against a timestamp captured at task start)—never by estimating from turn count, amount of work done, or a subjective sense that "it's probably been a while." A vague or absent update cadence is exactly the gap this rule exists to close; "I'll summarize everything at the end" is not compliance, no matter how thorough that summary turns out to be.
- **[AG-GH-014]** **Issues must carry enough detail to be independently actionable, not a one-line note.** A well-formed issue names the exact files/functions it concerns — the specific paths to be edited, not just the general topic area or subsystem — states concrete, checkable acceptance criteria (not "improve X" or "look into Y"), and explains why the problem is real (a reproduction, a real log excerpt, a specific code reference) rather than asserting it abstractly. The bar: someone with no other context should be able to read the issue body alone and say which changes are needed, even before any PR exists. An issue that only a person who already has the full context in their head can act on is under-specified and must be expanded before being handed to an implementer — human or agent — who does not share that context. This matters more, not less, when issues are meant to be picked up by an agent with no memory of the conversation that created them.
- **[AG-GH-015]** **A follow-up/successor issue narrowing or continuing an earlier issue's scope must state explicitly, in its own body, whether it fully covers the original's acceptance criteria or only a subset.** Do not create a narrower issue and leave the reader to infer from titles or labels whether it supersedes the original. If the successor only covers part of the original: name exactly what remains uncovered, and update the *original* issue's body (not just a comment) with a "Current Status" note pointing at the successor and stating plainly that closing the original once the successor lands would be premature. This project has repeatedly created a narrow follow-up issue for a large finding and then let the original silently rot as if it were resolved — treat that pattern as a known failure mode to actively guard against, not an acceptable shortcut.
- **[AG-GH-016]** **Before closing an issue as resolved, superseded, or duplicate, actually diff its acceptance criteria against the PR/issue you believe covers it — do not match on topic or title similarity alone.** Two issues about "the same area" are not automatically the same issue; one may be a strict subset of the other's scope. Prefer verifying against the real current repository state (run the actual check, read the actual current file) over trusting either issue's prose, since both may have been written before the code moved further.
- **[AG-GH-017]** Before starting new work that will produce a branch (a fix, an investigation, documentation, an audit), first check whether a branch, PR (open, closed, or merged), or issue already covers the same scope—via `git fetch --all --prune && git branch -r` (a stale local remote-tracking list, from before the last fetch, misses branches pushed since—`-r` alone shows cached refs, not a live remote listing), `gh pr list --state all --limit 200 --search <keywords>`, and `gh issue list --state all --limit 200 --search <keywords>` for relevant keywords/issue numbers (both `gh` commands default to open-only and a 30-result limit, which silently under-searches a repository with hundreds of issues/PRs; a "no match" from the defaults is not proof nothing exists)—rather than starting fresh and risking duplicate integration. This extends Rule-Ref: AG-WF-018's "search issues before filing a new one" to branches and PRs specifically, and to every dispatched agent, not just the coordinator. Second, once a branch is pushed, it must be traceable in writing—either as an open/draft/closed PR, or as an explicit comment on a linked issue naming the branch and its purpose—at or shortly after creation. A branch containing real analysis, fix, or documentation work that exists only as raw commits, with no PR and no written trace anywhere in the tracked issue, is not acceptable no matter how good its content is (a real incident prompted this rule: 19 `bughunt-*`/`docs/inventory-*` branches pushed 2026-07-15, containing thousands of lines of genuine analysis for issues #843/#849, were discovered unreferenced and unmerged three days later, invisible to anyone reading those issues). This applies to every agent and every dispatch: a subagent instructed to investigate or produce work on a new branch must first check for pre-existing coverage, and must then either open a Draft PR or post an issue comment linking the branch and summarizing its contents before ending its own work—"I pushed a branch" is not a completed handoff by itself. A branch that will not become a PR (abandoned, superseded, exploratory-only, or found to duplicate existing work) must be flagged for deletion with a clear written explanation (e.g. an issue comment naming the branch and why it's no longer needed) rather than left dangling with no explanation at all; per Rule-Ref: AG-WF-005, actual deletion still requires the maintainer's explicit instruction—an agent does not delete it unilaterally just because it decided the branch is abandoned.
- **[AG-GH-018]** **Pull request titles must follow a Conventional-Commit shape: `type(scope)!: subject`.** This repository **merge-commits pull requests (it does not squash)**, so the PR title — not any individual commit inside it — is the unit that both a human changelog reader and any future automated release tool (see issue #819's `release-please` investigation) actually reads to determine what changed and how the version should move. Enforcement therefore targets the PR title itself, validated by `scripts/check-pr-title-convention.sh` and the `pr-title-convention-check`/`pr-title-convention-check-hosted` CI jobs in `build-push.yml` (mirroring `pr-template-check`'s and `pr-tracking-metadata-check`'s draft/non-draft behavior: a draft PR gets a warning, a non-draft PR with a non-conforming title fails the check). This taxonomy was derived from an actual audit of this repository's git history (roughly 250 commits on `current_dev`, roughly 150 on `master` at the time of the audit — see issue #850's audit comment), not invented in the abstract; it codifies what this project's real usage already mostly does, with the small number of deviations named explicitly below.

  **Allowed types** (each maps to the SemVer `vY.X.Z` component it should bump once the automated version-bump tooling from issue #819 exists; they are documented for consistency and changelog clarity regardless of whether that automation is wired up yet):

  | Type | Meaning | Bumps |
  |---|---|---|
  | `feat` | A new user-facing capability | `X` (minor) |
  | `fix` | A bug fix | `Z` (patch) |
  | `docs` | Documentation-only change | none |
  | `refactor` | Code change with no behavior change | none |
  | `perf` | A performance improvement | `Z` (patch) |
  | `test` | Test-only change | none |
  | `build` | Build system, packaging, or dependency change | none |
  | `ci` | CI/CD workflow or tooling change | none |
  | `chore` | Maintenance work not covered by the above | none |
  | `style` | Formatting/whitespace only, no logic change | none |
  | `revert` | Reverts a previous commit/PR | matches the reverted change's own type |

  A `!` immediately after the type (or after the scope, if one is present) — e.g. `feat!:` or `fix(proxy)!:` — or a `BREAKING CHANGE:` footer in the PR body marks a breaking change. **Because this project is deliberately pre-1.0 (`Y` stays `0` until a production-ready milestone, per issue #819), a breaking change bumps the MINOR (`X`), not the major (`Y`), while pre-1.0** — this is standard SemVer pre-1.0 practice and maps directly to `release-please`'s `bump-minor-pre-major: true` setting, should that automation land. The major version bump to `1.0.0` remains a deliberate, manual maintainer decision, never an automatic side effect of a `feat!:` title.

  **`security` is NOT a standard Conventional-Commit type, and is deliberately excluded from the allowed set above** — despite three real, deliberate uses of `security:` in this project's own history at the time of the #850 audit. **This exclusion is flagged here explicitly as a pending decision the maintainer can flip, not a silent ban**: the recommended alternative is `fix(security): ...` / `feat(security): ...` (using `security` as a *scope*, not a type), which keeps the type set standard and `release-please`-compatible. `scripts/check-pr-title-convention.sh` implements the standard-only set today, with a comment at its `allowed_types` array naming exactly what to add if the maintainer instead decides to keep `security:` as a first-class type. Until that decision is made, a PR titled `security: ...` fails this check with a message explaining the alternative and pointing at issue #850 — this is a documented, reversible default, not a permanent removal of a type the project uses today.

  **Scopes** are optional (a type-only title such as `fix: ...` is valid on its own), lowercase, and — when present — must be one of the documented project areas below, matching `docs/naming-conventions.md`'s real service names plus a small number of non-service project areas already in real use: `proxy`, `dns`, `dhcp`, `dhcp-proxy`, `ui`, `nats`, `watchdog`, `netdata`, `setup`, `ci`, `governance`, `docs`, `scripts`, `tests`, `build-tools`. A scope outside this list (e.g. `fix(bogus-scope): ...`) fails the check with a pointer to this list. Extending the list requires updating both this rule and `scripts/check-pr-title-convention.sh`'s `allowed_scopes` array together, the same way `docs/naming-conventions.md`'s own service-name additions must stay in sync with the files that depend on it.

  **Good title examples:**
  - `feat(dhcp): add IPv6 lease support to Kea config generation`
  - `fix: correct nginx cache key to include $host`
  - `fix(proxy)!: change default cache TTL, breaking existing cache entries`
  - `docs(governance): add Conventional-Commit PR-title rule and lint`
  - `chore(build-tools): bump bats to 1.11.0`

  **Bad title examples (and why):**
  - `Feature: add IPv6 support` — capitalized and not a recognized type (`Feature` is not `feat`)
  - `harden(ci): tighten the workflow permissions` — `harden` is not a Conventional-Commit type; use `fix(ci): ...` or `chore(ci): ...` depending on intent
  - `fix(networking): resolve DNS timeout` — `networking` is not a documented scope; the closest real area is `dns`
  - `security: patch a credential leak` — `security` is not (yet) a standard type here; use `fix(security): patch a credential leak`
  - `update the README` — no type prefix at all
  - `CLD-1784784450 fix(docs): update stale line` — the agent identifying marker (per Rule-Ref: AG-WF-017) belongs in the PR **body**, never the title; a title that leads with it is itself a violation of AG-WF-017, independent of this rule

  **Enforcement is from here forward only.** This rule and its CI check apply to PR titles going forward from when this rule merges; already-merged commit/PR-title history is **not** rewritten or retroactively judged non-compliant, since doing so would rewrite merge-commit history in a way Rule-Ref: AG-WF-004's PR-only workflow does not contemplate.

## Agent Workflow

- **[AG-WF-001]** Start every branch from a freshly fetched and rebased current base branch.
- **[AG-WF-020]** Before making readiness, mergeability, or integration-order statements, fetch the PR branch and base branch, rebase the local worktree onto the current remote base, and verify the resulting head. If a branch cannot be rebased, state that blocker instead of giving a readiness conclusion.
- **[AG-WF-002]** Use a separate worktree for each non-trivial PR or subagent task.
- **[AG-WF-003]** Use fanout for bounded independent work when it reduces main-thread cost without reducing quality. Prefer the cheapest suitable model and reasoning level: Spark first while available; if Spark is unavailable, rate-limited, or unsuitable, evaluate `gpt-5.4-mini` next before keeping delegable work in the main thread.
- Choosing main-thread work while Spark is unavailable requires a concrete reason, such as unsafe delegation, time-critical local context, or higher integration risk from a separate agent.
- **[AG-WF-021]** Treat subagent results as stale until verified against the current remote base and current PR head. Before using an agent result for readiness, conflict resolution, review comments, or merge guidance, compare the reported commit/base with GitHub and rerun the relevant checks on the current head.
- **[AG-WF-022]** Do not block on subagents when useful non-overlapping work is available. Poll sparingly, and close completed agents after their result has been reviewed or superseded.
- **[AG-WF-024]** Any agent that spawns sub-agents of its own must dispatch each one with its own explicitly-assigned, verified-clean working directory—never assume a worktree (even one the harness labels "isolated") starts from a pristine, correctly-based checkout. Before doing any work, an agent (top-level or sub-agent) must verify its actual current branch/HEAD against the expected clean base (e.g. `git fetch origin && git log --oneline -5` and compare against `origin/<base-branch>`) and, if it does not match, must not attempt to salvage the worktree in place by default—prefer discarding it and provisioning a genuinely fresh one from a clean checkout of `origin/<base-branch>`. If a fresh worktree is not available and an existing one must be reset in place instead: `git reset --hard origin/<base-branch>` (clears tracked-file modifications a plain `checkout -B` does not touch), followed by `git clean -fd` (removes untracked files)—deliberately NOT `git clean -fdx`, since `-x` also deletes gitignored files this repo legitimately keeps locally (e.g. `certs/*.key`, `.env`), and could silently destroy real secrets or generated state instead of just another task's stray work—then verify `git status --porcelain` is empty before proceeding, since no single one of `checkout -B`, `reset --hard`, or `clean -fd` alone guarantees a fully clean worktree—never trust an inherited or recycled worktree's state by default. A sub-agent must never overwrite, rebase onto, or push over its parent's (or any other agent's) branch or in-flight work. Before executing `git push --force`/`-f`, `--force-with-lease`, `--force-if-includes`, or any other force-variant push, an agent must first re-verify—immediately before running it, not earlier and not from memory—that the action matches what is actually intended: confirm the current branch/HEAD, confirm exactly what the remote ref currently points to and why it is being overwritten, and confirm the content about to be pushed is the agent's own intended work and not something else's (another branch's, another agent's, or stale/inherited state). Only after that verification genuinely passes may the force action proceed. A rejected non-fast-forward push is a stop-and-re-verify condition, never something to force past reflexively. Every spawned sub-agent must read and accept the same `AGENTS.md`/`CLAUDE.md`/`.github/AGENTS.md` governance as its parent (inheritance of context is never assumed), and must explicitly report back—by name—that it has done so before starting substantive work: a bare "understood" is not acceptance; it must state that it read `AGENTS.md`, `CLAUDE.md`, and `.github/AGENTS.md`, with no shortcut. It must also check back with the dispatching agent before taking any action whose failure mode is silent data loss or overwriting another branch's history, rather than resolving it autonomously. A real incident prompted this rule (2026-07-18): a sub-agent, dispatched with the harness's own worktree-isolation option, was handed a recycled worktree slot still checked out to an unrelated, in-flight branch (traceable to a completely different agent's PR from earlier the same session) instead of a clean base—and, without verifying this before working, ended up force-pushing that unrelated content onto its own assigned target branch, destroying that branch's clean single-commit history. It was caught only via an explicit `git diff --stat` sanity check by the parent agent afterward, not prevented beforehand by any rule, and recovered from the local reflog only because that reflog happened to still exist.
- **[AG-WF-004]** Do not push directly to `master`. All changes go through pull requests.
- **[AG-WF-005]** Do not merge, close, or delete repository work unless the maintainer explicitly asks for that exact action.
- **[AG-WF-006]** Keep PRs in draft until the branch has passed local validation and known review findings are addressed.
- **[AG-WF-007]** Resolve review threads only after the finding was actually fixed or a clear maintainer-approved explanation was posted.
- **[AG-WF-008]** Every review finding that was fixed must receive a factual reply explaining the fix and must then be resolved, even if GitHub already marks the thread as outdated after later code movement.
- **[AG-WF-009]** If GitHub does not allow resolving a stale or outdated thread, add a factual PR comment naming the finding, explaining why it is fixed, and stating that GitHub did not allow resolving it.
- **[AG-WF-010]** Before changing, reviewing, or resolving an issue or pull request, read the full issue/PR context, including the description, linked issues and PRs, all review comments, replies, and resolved threads, then evaluate the surrounding file and project-wide impact instead of acting only on an isolated line.
- **[AG-WF-011]** Treat review findings as failure classes, not isolated line comments. Before marking a finding fixed, check matching install, update, secondary, release, CI, documentation, and test paths for the same class of issue.
- README and other documentation can lag behind current code and governance decisions; do not treat existing docs as automatically authoritative when they conflict with current architecture or an agreed rule. When a conflict is found, either correct the documentation or ask before changing behavior to match stale docs.
- Prefer GraphQL (`gh api graphql`) over plain `gh issue`/`gh pr` comment and body-update commands for GitHub writes, since the plain CLI commands have repeatedly failed or behaved inconsistently in this project. Whichever method is used, read the result back immediately per the rules below.
- **[AG-WF-012]** When writing GitHub issue or pull-request bodies/comments from local files, verify the API call uploads file content and not the literal file path. Read the GitHub object back immediately and treat bodies such as `@/tmp/...` as malformed failed writes that must be corrected before continuing.
- When sending Markdown through GraphQL string variables, pass the raw file content with the CLI's file-upload mode instead of pre-encoding it as JSON. Read the object back and treat leading JSON quotes, escaped newlines, or literal file paths as malformed failed writes.
- **[AG-VAL-001]** Treat warnings as errors for repository work. Do not list a check as successful when it emitted warnings, failed setup, or used a broken fallback.
- **[AG-VAL-022] Known conflict with the warnings-as-errors rule, tracked in issue #394**: GitHub's CodeQL Rust extractor emits `macro expansion failed` warnings for ordinary macros (`format!`, `assert_eq!`, `vec!`, `json!`, `tracing::*`, etc.) as a documented upstream limitation of its `rust-analyzer`-based extraction, not because of a defect in this repository's code. A strict, unscoped reading of "warnings are errors" would block CodeQL runs on essentially every Rust PR. Until upstream resolves this, treat these specific, named CodeQL extraction warnings as a carved-out, explicitly tracked exception: they do not block a PR by themselves, but every instance must stay referenced in #394, and #394 must be periodically reevaluated rather than left as a permanent blanket excuse. This exception is scoped to CodeQL Rust macro-expansion extraction warnings only — it does not extend to `cargo check`/`cargo clippy` warnings, which remain hard failures under the rule above. A related but distinct case — CodeQL findings in code a macro actually *generates*, not just extraction warnings on ordinary macro *invocations* — is documented separately as Rule-Ref: AG-VAL-021, which requires additional test-coverage evidence this rule does not.
- **[AG-VAL-002]** Treat standard failures such as `command not found`, missing files, missing environment variables, permission denied, malformed commands, empty required outputs, and failed tool setup as hard failures.
- **[AG-VAL-003]** Quote search patterns so literals such as backticks, `$()`, `${...}`, pipes, and redirects cannot be interpreted by the shell. A command that accidentally executes part of the search pattern is malformed and invalidates that verification attempt.
- **[AG-VAL-004]** Do not hide required command failures with `|| true`. Use optional fallbacks only when the command is explicitly optional and the reason is documented.
- **[AG-VAL-005]** Use local Bash tools such as `rg` for text searches; do not rely on vague manual inspection when a deterministic search is possible.
- **[AG-REL-001]** Do not introduce another runtime language (Go, Python, Node.js, etc.) into the project without explicit approval from @djdomi. Local, one-off commands for inspection or validation (e.g. a quick `python3` JSON/YAML check, a one-off text transform) are fine as long as nothing from that language is committed to or into the repository. If a different language or tool was used for testing, you must state which language/tool was used and exactly what was tested with it.
- **[AG-GH-007]** Project-facing text must be in English.
- Take the big picture
- Think big.
  - **[AG-WF-013]** Always look at the bigger picture. Do not only consider the change itself. Consider its dependencies, its impact, and what may happen as a result.
- **[AG-WF-016]** Do not silently remove, narrow, or "simplify" any AGENTS.md content — values, rules, or anything else that belongs in this file — without the maintainer's explicit consent. Do not replace existing content with a different representation or style just because that would be easier to satisfy technically. Rules may be numbered to allow direct reference (e.g. when citing a violation). No rule number may be reused for a new rule; a rule ID always identifies exactly one rule. Referencing an existing rule elsewhere in the document must use the explicit form `Rule-Ref: <ID>` (e.g. "see Rule-Ref: AG-WF-004"), never a bare repeated ID.
- **[AG-WF-017]** Every commit message, GitHub comment, issue/PR body, or closing action created by an agent must carry an identifying marker (a `<PREFIX>-<unix-timestamp>` first line, the timestamp obtained fresh via `date +%s` at write time, not reused across writes) so it can never be mistaken for an action the human maintainer performed directly. The prefix identifies which AI system authored the write, per this project's convention: Claude uses `CLD-`, Codex uses `CDX-`, and any other AI system used on this repository picks its own short, stable, self-identifying prefix rather than reusing one of these. If a system genuinely cannot determine its own identity (e.g. a smaller model with no reliable way to know which product it is), and only in that case, use the generic fallback prefix `AI-` — this is a last resort for a true inability to self-identify, not a default to reach for out of convenience when a real identity is knowable. This applies without exception: commits, pushes, review replies, issue/PR bodies and comments, and any closing/labeling action performed on the agent's own initiative. Agent-driven and maintainer-driven writes share the same git/GitHub identity in this repository, so committer name or author metadata alone cannot distinguish them, and different AI systems working in the same repository are equally indistinguishable from each other without a prefix — the marker is the only reliable signal for both. A real incident prompted this rule: a dispatched agent, examining an unmarked commit from several hours earlier, assumed it was the maintainer's own direct action rather than an earlier agent's work, and reasoned from that wrong premise before being corrected. Do not skip the marker because a write feels trivial or purely mechanical. The marker belongs in the *body* (commit message, comment, issue/PR body text) — never in a PR or issue *title* (topic line), which must stay a clean, human-readable description on its own. A second real incident prompted this clarification: a dispatched agent created a PR whose title itself began with the `<PREFIX>-<timestamp>` marker, which then carried through into the squash-merge commit's own subject line in the target branch's permanent history — technically still "a write by an agent," but not what this rule's "body" wording ever called for.
- **[AG-WF-018]** Before filing a new issue, or before treating an architectural or process question as unclaimed ground worth opening a fresh issue for, search existing issues first (e.g. `gh issue list --search "<topic keywords>" --state all`). This applies even when the question feels like it originated in the current conversation — a maintainer may have raised the same topic in an earlier session, and an issue search is the only reliable way to find it before duplicating it. A real incident prompted this rule: an agent filed a new issue proposing a branch-model redesign without searching first, duplicating an existing, more authoritative issue on the exact same topic (with direct maintainer quotes from two days earlier) — the new issue's content had to be merged into the original and the duplicate closed. Do not skip this search because the topic feels novel or because no duplicate seems likely; check anyway.
- **[AG-WF-019]** The Bash tool's working directory does not reliably persist across separate tool invocations, and a `cd` that fails silently (e.g. because its target directory does not exist yet) can leave a later command in the same or a subsequent invocation running in the wrong directory instead of erroring out visibly. Never issue a bare `cd <path>` and trust that a later, separate command will run there — always chain `cd "<path>" && pwd && <command>` within one invocation, and treat `pwd`'s printed output as the actual proof of location, not an assumption. This applies with particular force to any command that mutates state (`git merge`, `git push`, `rm`, writes) — verify location before, not after. A real incident prompted this rule: a `cd` into a temp clone directory failed silently because the directory had not yet been created, leaving a subsequent `git merge` command to run against the maintainer's own main checkout instead of the intended isolated clone. It was caught immediately via `git status`/`git log` before any commit landed and reverted cleanly with `git merge --abort`, but the near-miss was entirely preventable with this chaining discipline.

## Required Validation

- **[AG-VAL-006]** Run the narrowest relevant checks for the files changed, and report any check that could not be run.
- **[AG-VAL-007]** Shell changes require at least `bash -n`, `shellcheck --severity=warning`, and `git diff --check` for the changed shell files.
- **[AG-VAL-008]** Rust changes require `cargo fmt --check`, `cargo check`, `cargo clippy -- -D warnings`, and `cargo test` for the affected crate or workspace path, unless the PR documents a real blocker.
- **[AG-VAL-009]** Dockerfile or Compose changes require `docker compose config` for the affected deployment files and a relevant image build when practical.
- **[AG-VAL-010]** **Dev-stack `.env` resolution**: `deploy/dev/docker-compose.yml` (and the other `deploy/*/docker-compose.yml` files) resolve `.env` relative to the compose file's own directory, not the directory `docker compose` is invoked from — e.g. `docker compose -f deploy/dev/docker-compose.yml up` from the repo root reads `deploy/dev/.env`, not a root-level `.env`. A repo-root `.env` is silently ignored for these stacks. `deploy/dev/.env` already ships with working dev defaults; edit it directly for live dev-stack verification instead of creating a new `.env` elsewhere. After changing a value, confirm it actually took effect with `docker compose -f deploy/dev/docker-compose.yml config | grep <VAR>` before concluding a change had no effect or that source code is broken.
- **[AG-SEC-001]** **Admin-UI auth gate is intentional, not a bug**: the `ui` service fails closed and restart-loops if neither `UI_AUTH_USER`/`UI_AUTH_PASSWORD` nor `ALLOW_INSECURE_UI=true` is set. During live verification, a restarting `ui` container logging `Admin-UI authentication is required` is expected security behavior, not evidence of a broken build — check the log message before assuming a startup crash. `ALLOW_INSECURE_UI=true` is a legitimate, explicit operator choice documented in `deploy/prod/.env` for an intentionally unauthenticated UI (e.g. a trusted LAN), not merely a throwaway test-only flag — do not describe it as forbidden or as if setting it always requires special justification.
- **[AG-VAL-011]** Workflow changes require syntax validation and a careful review of runner labels, secrets, variables, matrix behavior, and cache behavior.
- **[AG-VAL-025]** Local Docker build checks for Rust service builders must mirror CI acceleration wiring when they are used to prove build performance or cache behavior. That means passing the same `BUILD_TOOLS_IMAGE`, `CARGO_BUILD_JOBS`, and BuildKit secret mounts for sccache, sccache-dist, and distcc. A local build without those secrets may validate Dockerfile syntax only; it must not be cited as proof that the compile farm is used.
- **[AG-VAL-012]** Setup, update, or migration changes require fixture or dry-run coverage that proves fresh install, repeated update, missing-key migration, existing-value preservation, and placeholder rejection.
- **[AG-VAL-013]** DNS behavior changes require a real DNS response check, not only process or port reachability.
- **[AG-VAL-014]** Proxy/cache behavior changes require a response or cache-behavior check that proves the proxy still serves the intended path.
- **[AG-VAL-015]** Do not weaken checks to make a branch green. If a check is wrong, replace it with an equally strong or stronger check that validates the real behavior.
- **[AG-VAL-023]** Before building an integration or a verification check around a third-party tool's or image's assumed behavior, check that tool's own documentation for the relevant configuration options first. Do not extrapolate a hard limitation from observed default behavior alone, and do not write an assumption into project docs as established fact without having checked upstream. Concrete incident: the central logging pipeline (#632/#633) was built assuming netdata writes real log files under `/var/log/netdata/*.log` by default (recorded as fact in `docs/architecture-ng.md`'s logging matrix) — nobody had checked that netdata's own `[logs]` configuration section documents explicit, overridable file paths for `error`/`collector`/`access`/`health`/`daemon` logs, independent of whichever destination the pinned image's default paths happen to symlink to. This applies before filing a bug against upstream behavior, before designing a workaround, and before downgrading a check to something weaker because the original approach "doesn't work" — a few minutes with the tool's own config reference is cheaper than any of those.
- **[AG-VAL-026]** Inside any blocking CI gate, never trust a mutable channel tag (e.g. `dev`, `nightly`, `latest`) or a runner-local cached Docker image as being current at the point it is used — resolve it to an immutable per-commit tag/digest and/or pull fresh immediately before the check that depends on it, not at some earlier point the gate merely assumes still holds. A mutable reference can drift between when a workflow starts and when a given job actually consumes it, and a cached local layer can silently be hours old. This class of bug has recurred concretely and repeatedly: #786 (a hardcoded `edge` channel tag), #775 (a hardcoded `:latest` build-tools image reference), #809 (a missing `docker compose pull` leaving an 11-hour-old stale local layer in place), #626 (pulling the base-ref's channel tag instead of testing the PR's own diff), and #536 (diffing against the moving base branch tip instead of a fixed `merge-base`). Before adding a new blocking check that reads a tag, a cached image, or any other externally-mutable reference, verify it resolves to something pinned to the exact commit/state under test — do not assume a tag that "usually" points to the right thing still does at check time.
- **Build-tools container verification**: All Rust, build, and tooling checks must run inside the project's build-tools container at the matching immutable version. Host-local tools (`cargo`, `rustc`, `rustfmt`, `clippy`, `sccache`, `cargo-audit`, `shellcheck`, `actionlint`) are not sufficient verification proof. Treat host tools as potentially missing, wrongly configured, stale, or unavailable — they prove only host provisioning, not project requirements. Falling back from the build-tools container to host tools invalidates the verification attempt. The build-tools image must be selected via the matching immutable digest or pinned version tag, never via an accidental mutable local image such as `lancache-ng-build-tools-validation:latest`. See the build-tools section under Coding Patterns for container selection and image pinning rules.

## Setup, Update, And Migration Semantics

- **[AG-OP-006]** Setup, update, and migration logic must be idempotent: running the same operation repeatedly must not rotate existing secrets, overwrite local configuration, or create new side effects unless the user explicitly requested that change.
- **[AG-OP-007]** Setup, update, and migration logic must converge old or incomplete installations toward the current expected state.
- **[AG-OP-008]** Missing required configuration values should be generated when safe or rejected with a clear fail-closed error when they require user input.
- **[AG-OP-009]** Existing non-empty local values must be preserved by default.
- **[AG-OP-014]** DHCP NTP settings are a project-wide policy decision, not a per-PR cleanup target. Preserve the currently established DHCP NTP defaults and semantics exactly as they are defined in the repo unless a maintainer explicitly opens a separate issue/PR to change that policy. Do not silently remove, narrow, or "simplify" NTP values, and do not replace them with a different representation just because a validation path would be easier to satisfy.
- **[AG-SEC-002]** Known placeholders such as `CHANGE_ME_*` are not valid runtime values and must be replaced or rejected before dependent services start.
- **[AG-OP-010]** Validation must happen before container restart, image pull, or runtime mutation when a failed validation would leave the installation in a worse state.
- **[AG-OP-011]** Re-running `setup.sh update` after a successful update should report no destructive changes and should not rewrite stable local files unnecessarily.
- **[AG-OP-013]** Any PR that changes setup, migration, generated config, runtime state writing, reload/restart behavior, backup/restore, or Compose/profile wiring must answer these five questions in the PR body: what state does this path own; what is the target converged state; what happens when it runs twice with the same input; what happens when validation fails halfway through; what test or guard proves this behavior. See issue #456.

### Convergence/Idempotence Checklist

Use this checklist (issue #456) when touching any stateful write path — `setup.sh`
install/update/migration, `.env` generation/merge, Compose/profile generation,
Kea/PowerDNS/dnsmasq/NATS/nginx config writers, watchdog recovery, or
backup/restore:

- [ ] Running the operation twice with identical input produces byte-identical
  output (or an explicitly documented, deliberately volatile exception, e.g. a
  channel-resolved image digest — name it, don't just accept unexplained diffs).
- [ ] Stable secrets/tokens are never rotated by a repeat run; only missing or
  known-placeholder values are (re)generated.
- [ ] A failed validation does not leave the target half-written, does not
  proceed to restart/reload/pull, and does not delete the last-known-good state.
- [ ] An already-migrated or already-converged install is detected and left
  alone rather than re-mutated.
- [ ] At least one repeat-run or fixture test exercises the above for the
  specific path being changed — see `tests/bats/setup_update_idempotence.bats`
  for the pattern (source the real function, run it twice against a realistic
  fixture, diff the result) and `scripts/setup-cli-simulation.sh`'s "Phase 2b"
  for the same proof against the real CLI end-to-end rather than only the
  extracted function.
- [ ] Any part of this checklist that cannot be satisfied in the current PR is
  listed explicitly with a linked follow-up issue, owner/scope, and reason —
  not silently dropped.

## Project Language

**[AG-REL-004]** This project is written in **Rust**. Shell scripts are permitted for entrypoints and automation.

No other runtime language may be introduced without explicit maintainer approval; see Rule-Ref: AG-REL-001 for the full language-approval rule, its examples, and its local one-off command exception. (AG-REL-005 retired 2026-07-10: merged into AG-REL-001, which said the same thing with more detail. Not reused per AG-WF-016.)

**[AG-REL-006]** Shell automation should use Bash by default when it relies on project fail-closed behavior such as `set -euo pipefail`, arrays, `[[ ... ]]`, process substitution, or other Bash-specific syntax. POSIX `sh` is acceptable only for intentionally small portable scripts that are validated with ShellCheck in `sh` mode.

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

## Naming Convention

`docs/naming-conventions.md` is the single, authoritative naming contract for
every runtime object this project creates: Compose project/service names,
Docker `container_name` values, Docker volumes, host bind-mount directories,
GHCR image/package names, environment variables that refer to services or
containers, the Docker socket proxy's security allowlist, and backup/restore
paths that depend on those names. Any change that adds a new service,
volume, environment variable, or socket-proxy allowlist entry must follow
that document's rule for its category, not invent a new naming shape
inline. `scripts/check-naming-consistency.sh` (run in CI as part of
`validate-compose` in `.github/workflows/build-push.yml`) enforces the
mechanically-checkable parts of that contract — the allowlist in
`scripts/docker-socket-proxy.sh` must stay a superset of the container names
the Admin UI (`services/ui/src/docker_client.rs`) and watchdog
(`services/watchdog/watchdog.sh`) can act on, and the Admin UI's `*_SERVICE`
defaults must match a real Compose service name — but does not replace
reading the document for anything that needs human judgment.

## Coding Patterns

- **[AG-REL-002]** **Docker builds**: production/runtime Dockerfiles still use multi-stage builds with pinned base images, but the Rust service builders for `services/dns` and `services/ui` consume the prebuilt `ghcr.io/wiki-mod/lancache-ng/build-tools` contract through a `BUILD_TOOLS_IMAGE` argument. Do not add ad-hoc `rust:latest` or Debian-based bootstrap layers back into those service builders. Local developer helper scripts and the repository build-tools image intentionally use `rust:latest` by default when the image is explicitly overrideable; this keeps developer validation tooling current while remaining separate from production service image pinning.
- **[AG-CI-001]** **Runner baseline**: assume self-hosted runners do not provide project validation tools. Workflows must use pinned GitHub Actions, the repository build-tools image, or explicit fail-closed capability checks instead of relying on host-installed utilities. Pin GitHub Actions to full commit SHAs with a version comment, not mutable tags such as `@v4`, branch names, or `@main`. Do not install project validation tools with ad-hoc `sudo apt-get` in workflows.
- **[AG-CI-002]** **Runner tiers**: route lightweight static checks to `[self-hosted, linux, lancache, lancache-light]` and memory-heavy Rust, CodeQL, container scan, Docker build, and release jobs to `[self-hosted, linux, lancache, lancache-heavy]`. Do not rely on the broad `lancache` label alone for jobs with meaningful CPU or memory pressure.
- **[AG-CI-009]** **Build acceleration scope**: `sccache`, `sccache-dist`, `distcc`, `distcc-pump`, and local Buildx cache paths are allowed only as Dev/CI optimizations. Production, runtime, setup, and update flows must stay pull-only against prebuilt images and must not depend on those accelerators.
- **[AG-CI-003]** **Runner portability**: LAN-only acceleration such as Redis-backed sccache, sccache-dist, distcc, local Buildx cache paths, and self-hosted runner labels must stay explicitly configurable. Treat the current self-hosted runner farm as an optimization layer, not as the only valid CI environment. GitHub-hosted fallback jobs must validate without inheriting LAN-only assumptions about Redis URLs, distcc schedulers, cache paths, or runner labels; use documented modes, variables, and fail-closed capability checks instead of hidden host assumptions.
- **[AG-VAL-017]** **Build-tools image**: `tools/build-tools/Dockerfile` intentionally uses `rust:latest`, then installs and smoke-tests required tools such as `rustfmt`, `clippy`, `sccache`, `cargo-audit`, `shellcheck`, `actionlint`, `bats`, `shellspec`, `distcc`, `distcc-pump`, Docker CLI, Docker Compose, and DNS/setup/template fixture tools such as `dig`, `ip`, `openssl`, `rsync`, and `envsubst`. It must explicitly set and verify `PATH`, especially `/usr/local/cargo/bin`, to avoid false `command not found` failures. CI jobs that only need bundled validation tools must use the prebuilt image instead of compiling those tools per job; for example, do not install `cargo-audit` in workflow jobs. CodeQL and Trivy image scanning remain GitHub workflow and runner capabilities, not tools bundled into this image.

  **[AG-VAL-016]** **Build-tools verification contract**: Project verification (build, Rust checks, linting, tooling validation) must run inside the build-tools container at the matching version — this is the _only_ valid verification path. The build-tools image is maintained as a single published version, selected through an immutable digest when possible (e.g. `ghcr.io/wiki-mod/lancache-ng/build-tools:latest`, pulled by `scripts/select-build-tools-image.sh`). A locally-built fallback image is permitted only when the script determines it is safe — that is, for branches within this repository. Host-local tools must be treated as absent, misconfigured, or stale unless the verification task explicitly targets host provisioning setup. Falling back from the build-tools container to host tools (e.g., running `cargo check` directly instead of `docker run ... build-tools cargo check`) invalidates the verification attempt. CI jobs, local developer checks, and pull request validation must all use the same build-tools version resolved by `scripts/select-build-tools-image.sh` or pulled at the matching digest. Use the pattern `docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/work:ro" -w /work "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}" <command>` for consistency with CI. Product-runtime verification (testing that docker-compose deploys correctly, that DNS responds, that the cache proxy serves files) proves product behavior; host-provisioning tests (verifying that a developer's local Rust installation works, that a CI runner has Docker installed) are separate concerns and do not substitute for build-tools verification.
- **[AG-CI-010]** **Tool image rebuilds**: routine pull requests must not rebuild the build-tools image unless `tools/build-tools` or the build workflow changed. The dedicated build-tools workflow must support manual and scheduled refreshes and publish `linux/amd64` plus `linux/arm64` images after smoke tests and scans. Release tags must always build the tag-scoped build-tools image so release jobs never run with a mutable `latest` tool image.
- **[AG-CI-011]** **Release job acceleration contract**: any release or release-adjacent job that uses build acceleration must document whether the accelerator is optional, preferred, or a hard gate. Do not leave the fallback behavior implicit.
- **[AG-REL-003]** **TLS in Rust**: use `reqwest` with `default-features = false, features = ["rustls-tls"]`. Never add `openssl-sys` as a dependency — `rust:slim` has no OpenSSL headers.
- **[AG-CI-004]** **sccache**: controlled by `SCCACHE_REDIS_MODE` (`required`, `optional`, `off`) and the `SCCACHE_REDIS_URL` GitHub Actions secret. Never hardcode a Redis URL. If `SCCACHE_DIST_SCHEDULER_URL` is configured, the matching `SCCACHE_DIST_AUTH_TOKEN` secret must also be configured and wired into `SCCACHE_CONF`; setting only a scheduler URL environment variable is not a valid sccache-dist setup. When installing sccache from source, keep the sccache version pinned, avoid locked installs while the pinned upstream lockfile emits yanked-crate warnings, and enable only the Redis plus `dist-client` features unless a PR explicitly justifies another backend.
- **[AG-CI-005]** **distcc/pump**: Rust service builders that install `distcc` must receive host lists through BuildKit secrets or trusted CI variables, never hardcoded Dockerfile values. When enabled, they must set `CC=distcc`, `GCC=distcc`, `CXX=distcc`, and discover either `/usr/local/lib/distcc` or `/usr/lib/distcc` before putting the discovered wrapper directory at the front of `PATH`, so direct `cc`, `gcc`, `c++`, and `g++` calls are intercepted across Debian and distcc-ng layouts. `distcc-pump` host lists must include at least one `,cpp` host entry. `distcc-pump` remains the default, preferred acceleration path — the bypass below is selective, not a reason to disable pump for a whole builder: specific compile inputs known to break pump's include-server assumptions (e.g. generated C headers such as `aws-lc-sys`'s, since pump assumes sources and includes do not change during the include-server lifetime) must route through normal (non-pump) distcc hosts or local compiler fallback for those inputs only, while the rest of that builder's compilation still uses pump normally. Distcc must log `[INFO] trying distcc path.` when it is actually attempted, must use `DISTCC_FALLBACK=0`, and may retry once with the normal local compiler if the distcc path is unavailable. Any image that installs Debian `distcc-pump` must patch the known invalid Python regex escapes before package configuration and verify the result with `python3 -Werror::SyntaxWarning`.
- **[AG-CI-006]** **Build parallelism**: Cargo and Docker Rust builds must use one project-wide job rule unless a PR justifies an override: the optional `CARGO_BUILD_JOBS` repository variable wins when set and must be validated as a positive integer; otherwise use detected CPU cores minus two, with a minimum of four jobs. Do not hardcode service-local values such as `CARGO_BUILD_JOBS=6`.
- **[AG-CI-007]** **Build acceleration wiring**: Installing `sccache`, `distcc`, or `distcc-pump` is not sufficient. Every PR that changes Rust builders or build workflows must verify the full chain: repository variable or secret, workflow input, BuildKit secret or Cargo environment, Dockerfile consumption, and a fail-closed smoke/status check.
- **[AG-REL-008]** **Prebuilt build-tools contract**: Rust service builders should consume a prebuilt `build-tools` image by immutable release, SHA, or the selected CI image contract instead of rebuilding toolchains in each service image. Reintroducing ad-hoc local toolchain compilation in `services/dns` or `services/ui` requires a documented reason and a separate review of first-user-experience impact.
- **[AG-CI-008]** **Dockerfile ARG defaults for tool images**: `ARG BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools:latest`-style defaults exist only as a fallback for a manual `docker build` invocation without `--build-arg`. Every real CI build (workflow jobs, release jobs) always passes `--build-arg BUILD_TOOLS_IMAGE=...` explicitly and never falls back to this default. A PR that pins or updates this default for "consistency," without showing a real path where CI actually consumes it, is not a bug fix — see issue #508, closed as already-resolved-by-design.
- **[AG-OP-001]** **Cache key**: nginx uses `$host$uri` (not `$request_uri`) — CDN query-string signatures must not bust the cache.
- **[AG-OP-002]** **DNS resolver in nginx**: must point to `8.8.8.8`, never to the local PowerDNS recursor — that would cause an infinite loop.
- **[AG-OP-015]** **Domain scope semantics**: a leading-dot domain entry such as `.example.com` is an explicit wildcard/subdomain scope and is not equivalent to the root domain `example.com`. Do not normalize away the leading dot or treat root and wildcard scope as interchangeable in any validation, matching, or migration logic that touches domain entries.

## Release And Package Consistency

- `latest` means the current stable release channel; it must not be moved by a routine `master` build. `nightly` means the tested pre-stable channel promoted from `master` (renamed from `edge` in v0.3.0, #1056). Release tags (`vX.Y.Z`) are immutable. Any documentation, issue, PR body, workflow comment, or setup output implying `latest` equals `nightly` or `master` is wrong and must be corrected.
- Stack versioning, GHCR package/channel definitions, and release documentation must move together: release and package changes must follow `docs/release-versioning.md` and the machine-readable inventory in `release/stack-images.yml`, and must run `bash scripts/validate-stack-images.sh`. A package/image change that only edits workflow files without checking these is incomplete.

## Comment Style

- **[AG-CODE-001]** Comment only when the code would not otherwise be quickly understandable. Well-named identifiers already say what trivial code does (setting a variable, calling a function, reading a file) — do not restate that in a comment.
- **[AG-CODE-002]** Comment concrete cases where the WHY is non-obvious: complex logic, guards, fallbacks, security decisions, non-obvious side effects, a workaround for a specific bug, or a deliberate deviation from the obvious/standard approach. Also comment when omitting the note would let someone later reintroduce the same mistake. If removing the comment would not confuse a future reader, remove it.
- **[AG-CODE-006]** Code must stay human-readable. Silent or hard-to-follow changes are not acceptable — if a change needs explanation to be trusted, write the comment; don't ship it silently.
- **[AG-CODE-007]** Short structural/orientation comments that label the steps of a longer sequential procedure (e.g. `// Step 1: Fetch current config`, `// Step 2: Validate and normalize`) are also acceptable and encouraged, even when they don't explain a hidden WHY — they help a reader scan a long function without re-deriving its structure. Reviewers (including automated ones) must not flag this style as "unnecessary" or "restates the code" just because `Comment Style` otherwise favors minimal comments; readability-oriented step labels are a distinct, allowed category from WHY-comments, not a violation of this section.
- **[AG-CODE-008]** A missing comment is a defect too, not just a neutral default. When touching any part of a file, check the **entire file** — not only the specific lines you edited — for places that should already have a WHY-comment under the categories above (complex logic, a guard, a fallback, a security decision, a non-obvious side effect) but don't, whether the gap was missed originally or never added, and add it as part of the change. Do not leave the gap just because it predates your edit or sits outside your diff; "there wasn't one before" and "it's not part of what I changed" are not reasons to skip adding one now.
- **[AG-CODE-003]** Do not reference the current task, PR number, or fix in a comment (e.g. "fixed for #123", "added by the CR-9 pass"). That belongs in the PR/commit description, not in code that outlives the change.
- **[AG-CODE-004]** When documenting a known limitation or deliberately deferred fix (not a bug you're fixing now), prefer a structured note over a one-liner: state the problem, the mitigation/fix direction if one exists, and a dated status line describing the current real-world state (e.g. "STATUS: as of 2026-07-02, X still uses the old path; once Y migrates, this fallback becomes dead code"). This lets a future reader tell a documented tradeoff apart from an accidental gap.
- **[AG-CODE-005]** Placeholder/scaffold markers (e.g. `TODO(#123): ...`) must be removed the moment the referenced work is actually implemented in that same change. A stale TODO claiming work is still needed, sitting next to code that already does it, is worse than no comment — it actively misleads the next reader/reviewer. Before finishing a fix that started from a TODO/scaffold marker, grep for and delete the marker it replaces.
- **[AG-CODE-009]** A descriptive identifier or name alone — including a `#[test]` function name — is not a valid comment. When the WHY behind a non-obvious edge case, security invariant, race condition, or off-by-one scenario isn't clear from the name, the reasoning must be spelled out explicitly: not what is being asserted (already visible in the code), but why this specific case would otherwise silently break something.
- **[AG-CODE-010]** For this project specifically, every `#[test]` function must carry at least a short comment explaining its purpose, regardless of whether the case looks "obvious" on its own. This project's domain (nginx/DNS/DHCP/Kea/Rust systems code) is complex enough that this intentionally overrides the general minimal-comment default (see Rule-Ref: AG-CODE-001) for test code — the same liberal standard applies to non-test code whenever in doubt.

## File Headers

- **[AG-HDR-001]** Every source/config file (Rust, shell, YAML, Dockerfiles, `.conf`/template files, HTML/CSS/JS) should open with a short header: the project name and repo URL, using the literal parenthetical form `lancache-ng (https://github.com/wiki-mod/lancache-ng)` — this exact string is what `scripts/check-file-headers.sh` greps for, so don't substitute an em-dash or other punctuation — followed by a purpose description of that specific file. Use the comment syntax valid for that specific file's language — do not default to `#` for every non-Rust file, since that is invalid syntax in some of them:
  - Rust: `//!` inner doc comments.
  - Shell, YAML, Dockerfiles, and genuinely plain-text `.conf`/template files (i.e. not files that only carry a `.conf` extension while actually holding JSON — see the JSON exclusion below): `#` line comments (after the shebang line, if there is one).
  - HTML Tera templates under `services/ui/src/templates/`: Tera's own `{# ... #}` comment syntax, not a raw HTML `<!-- ... -->` comment. Several templates in this directory (e.g. `dashboard.html`) start with `{% extends "base.html" %}` as their required first tag; Tera tolerates a `{# ... #}` comment before `extends`, but a literal `<!-- ... -->` comment is ordinary HTML content and breaks that requirement, causing `load_templates` in `services/ui/src/main.rs` to fail at startup. Use `{# ... #}` for every template in this directory, including ones that don't currently extend another template, so the convention stays uniform and safe if that changes later.
  - CSS (`.css`): `/* ... */` comments.
  - JavaScript (`.js`): `//` line comments (or `/* ... */` for a multi-line block).
  - If a file's language isn't listed here, use that language's own standard comment syntax — never `#` by default without checking it's actually valid for that file type.
- **[AG-HDR-002]** Before adding a header to any file with a `.conf`/`.json`/`.txt`/other generic-looking extension, check what actually parses it and how. If the content is genuinely JSON (JSON has no comment syntax at all), do not add any header; a `#` or any other comment line would break parsing. In this repo, all three Kea config files under `services/dhcp/` are JSON despite the `.conf` extension and must be excluded on this basis: `kea-dhcp4.conf` (parsed by `migrate_dhcp4_config` in `services/dhcp/entrypoint.sh`), `kea-ctrl-agent.conf`, and `kea-dhcp-ddns.conf`. The same JSON exclusion applies to any other file this project treats as machine-parsed structured data without a comment syntax, whatever its extension.
- **[AG-HDR-003]** Do not add a header to a file whose entire content is consumed as a single raw value by a strict parser, where any extra text (including a comment) would corrupt that value. The clearest example in this repo is the root `VERSION` file: `setup.sh`'s `derive_current_release_image_tag` reads the whole file, strips whitespace, and requires the result to match a release-tag pattern — a header would be concatenated into that value and break setup/update with an invalid release image tag.
- **[AG-HDR-004]** Do not add a header to a vendored third-party file or a generated/compiled build artifact — it isn't this project's own hand-authored source, and in the vendored case it likely already carries its own upstream header. In this repo: `services/ui/src/static/chart.umd.min.js` is the vendored, minified Chart.js library (already opens with its own `/*! Chart.js v4.5.1 ... */` header) and `services/ui/src/static/admin.css` is compiled/minified Tailwind CSS output, not hand-written CSS. `services/proxy/public_suffix_list.dat` is the vendored Mozilla Public Suffix List (already opens with its own `// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0` header), used at proxy startup to derive each CDN domain's registrable root for wildcard cert coverage. If a hand-written source input for a generated artifact is ever added to the repo (e.g. a Tailwind config or an unminified source file), that source input is in scope for a header; the generated output it produces is not.
- **[AG-HDR-005]** Scale the header's detail to the file's actual complexity — a file with several distinct responsibilities (e.g. a multi-role entrypoint script, a large route-wiring module) should name them; a simple, single-purpose file (e.g. an install-and-copy Dockerfile) should stay short. Do not pad a simple file's header just to match a fixed line count.
- **[AG-HDR-006]** Every technical claim in a header must be verified against the actual file content and, where relevant, git history — do not assert an unconfirmed reason for a design choice (e.g. why a particular base image or repo is used) if no documented rationale exists; state the observable fact instead.
- **[AG-HDR-007]** Excluded: `.md` files, a literal root-level `.env` or `.env.example` file (not every file with a `.env` extension — the per-service defaults under `config/dev/` and `config/prod/` such as `dhcp.env` are ordinary committed config and are in scope for a header), lockfiles (`Cargo.lock`), `.gitkeep`, the root `VERSION` file, vendored/generated build artifacts, and any file whose content is JSON or another comment-free structured format regardless of its extension (see above for concrete examples of each). See `scripts/check-file-headers.sh`'s `is_excluded()` function for the exact, executable list this maps to.
- **[AG-HDR-008]** No license line — the project has not adopted a license yet; that is a separate, not-yet-started decision and must not be conflated with file headers.
- **[AG-HDR-009]** The repo-wide backfill for this rollout (originally tracked in issue #409, backfill itself tracked in #431) is complete, and `scripts/check-file-headers.sh` runs as a CI job (`file-headers` in `build-push.yml`) that fails a PR if any non-excluded tracked file is missing the header. If you add a new file, or a future PR turns up one this backfill missed, add the header immediately rather than treating CI failure as something to work around.

## Runtime Behavior

- **[AG-OP-003]** Lazy proxy/cache behavior is the intended default.
- **[AG-OP-004]** Strict proxy/cache behavior is explicit opt-in for users who want tighter allowlisting and accept the maintenance burden.
- **[AG-OP-005]** Do not silently invert the lazy default.
- **[AG-VAL-018]** DNS health checks must use a real query/response probe such as `dig` or an equivalent strong check.
- **[AG-VAL-019]** `ping` is not an acceptable DNS health check because it only proves network reachability.
- **[AG-VAL-020]** `ss` is not an acceptable DNS health check by itself because it only proves that a socket is listening.
- **[AG-VAL-024]** A new shell script's executable bit (`git` file mode `100755`) is invisible and unverifiable from a Windows authoring environment, where Git commonly runs with `core.filemode=false` — `chmod +x` has no effect there, and no local check reveals whether the bit is actually set in the commit. An agent can verify a new script's logic thoroughly on such a host and still ship it non-executable, discovering this only when real Linux CI execs it directly (`Permission denied`, exit 126) — never from anything observable in the authoring sandbox. Concrete incident: PR #937's `check-workflow-service-lists.sh` was committed as `100644`; all 8 of its own bats fixtures failed in the real build-tools-container CI run for this reason alone, invisible to the author's manual walkthrough. To prevent recurrence: (1) prefer invoking new scripts via an explicit interpreter (`bash "$script"`, not `"$script"` or `./script.sh`) at every call site (test harnesses included) — this removes the executable-bit dependency entirely; (2) if direct invocation is genuinely required somewhere, verify the mode explicitly with `git ls-files -s <path>` (must show `100755`) rather than inferring it from local testing on a non-Linux or `core.filemode=false` host. Separately, the same incident also exposed a `set -euo pipefail` fail-closed branch that was dead code — a `grep`/pipeline returning no matches (exit 1) silently killed the whole script via `errexit` before its intended diagnostic message was ever reached. A fail-closed path guarded by `set -e` must be exercised by an actual failing-input run in real CI, not only reasoned through manually.

## Secrets And Sensitive Data

- **[AG-SEC-003]** Never commit private credentials, tokens, personal contact data, or internal LAN-only secrets.
- **[AG-SEC-004]** Use GitHub Secrets for secret values and GitHub Variables for non-secret configuration values.
- **[AG-SEC-005]** Do not hardcode local Redis, scheduler, distcc, or runner endpoints in source files, Dockerfiles, or workflows.
- **[AG-SEC-006]** If sensitive data appears in a branch, stop normal work and remove it from the active branch before continuing.

## What Not To Do

- **[AG-WF-014]** Do not push directly to `master`. All changes go through pull requests.
- **[AG-SEC-007]** Do not hardcode LAN IP addresses in Dockerfiles or source files.
- Do not introduce a new programming language without explicit approval; see Rule-Ref: AG-REL-001. (AG-REL-007 retired 2026-07-10: merged into AG-REL-001, which said the same thing with more detail. Not reused per AG-WF-016.)
- **[AG-OP-012]** Do not use `proxy_cache_key $request_uri` — query strings contain per-request CDN signatures.

## Documented Exceptions to Hard Rules

Hard rules in this governance exist to prevent real failures — runtime crashes, security exposures, documentation drift, stale CI gates, and cascading operational risk. A rule must be clearly broken only when there is a documented reason, and exceptions must state that reason explicitly, name what still must be validated despite the exception, and be narrowly scoped.

**[AG-DOC-011]** Every documented exception must follow this format:

- **Scope**: What the exception narrows (e.g., "Rust builder images for service X" or "CodeQL analysis for auto-generated code in path Y").
- **Reason**: Why the normal rule does not apply in this case (e.g., "generator output is deterministic and pre-audited," or "this image must use rust:latest because...").
- **Tracking**: Issue and/or PR reference where this exception was discussed and approved.
- **Validation**: What validation is still required despite the exception. Omitting validation because "the exception lets us skip it" misses the point — the exception narrows the rule, but safety verification must land somewhere else.
- **Non-Expansion**: What the exception explicitly does NOT cover (e.g., "this exception applies only to service X, not to other services" or "only to CodeQL analysis, not to other security checks").

### [AG-VAL-021] Second, distinct case: CodeQL findings in actually macro-generated code (issue #394, closed)

This is a separate case from Rule-Ref: AG-VAL-022 above, not an unreconciled restatement of it. That rule covers extraction *warnings* CodeQL's Rust extractor emits for ordinary, human-authored macro *invocations* (`format!`, `vec!`, ...) — confirmed to be a pure tooling artifact, tracked upstream as [github/codeql#19966](https://github.com/github/codeql/issues/19966), [#19982](https://github.com/github/codeql/issues/19982), and [#20659](https://github.com/github/codeql/issues/20659) (CodeQL's Rust support is `rust-analyzer`-based and cannot cleanly expand macros, especially procedural ones, without running the real compiler; all three remain open upstream with no fix commitment). PR #517 made this extraction-quality signal visible instead of leaving CI silently green. This exception instead covers real CodeQL *findings* ("overly complex", "unreachable") in code a macro actually *generates* — since that code is genuinely unusual, not just misread by the extractor, "it's just a tooling artifact" is not sufficient justification by itself; this exception additionally requires test evidence the generated code behaves correctly despite the finding.

- **Scope**: CodeQL analysis of Rust code generated by macros that expand to large intermediate representations.
- **Reason**: Rust procedural macros can generate code that CodeQL reports as overly complex or unreachable, even though the actual compiled binary and test behavior are correct. The generated code is not human-readable and is not part of the reviewable source surface. Blocking on CodeQL false positives in generated code delays legitimate security fixes.
- **Tracking**: issue #394 (closed — see the intro above for the upstream bug references this closure rests on). This exception was approved as part of the v0.2.0 security hardening pass.
- **Validation**: CodeQL analysis must still run on human-written code. The exception narrows which CodeQL findings are treated as blocking. A CodeQL exception pull request must demonstrate that the finding occurs in generated code (not human-authored code), that the finding is a known false positive for macro expansions, and that the relevant code path has test coverage that proves the behavior is correct despite the CodeQL report.
- **Non-Expansion**: This exception applies only to CodeQL Rust analysis. It does not cover other languages, other security checks (e.g., cargo-audit, SAST linters), or changes to non-generated Rust code. It also does not extend the plain-extraction-warning exception in Rule-Ref: AG-VAL-022, which covers warnings on ordinary macro invocations needing no test-coverage evidence since they are a confirmed tooling artifact unrelated to actual code behavior.

## Agent Closing-Report Contract

Finishing a nontrivial task (any PR, any issue fix, any multi-step verification) requires a closing report that proves you understood the work, not just executed instructions. The report must be part of the PR body, closing issue/PR comment, or final-task output (the form varies by context; the content does not).

A closing report must document:

1. **Context read** — Which issue(s), PR(s), design doc(s), existing code, or threat models did you actually read to understand the task scope? Name them explicitly. (This is not "I read the issue" — it's "I read #529 (full text), .github/AGENTS.md (lines 1-50 and the build-tools section), and CLAUDE.md (the Key Constraints section)" or similar specificity.) Omitting what you read is a red flag that you may have missed related constraints or design decisions.

2. **Areas changed** — List the file paths or subsystems you modified. Be exact (e.g., "edited AGENTS.md lines 1-200 to add rule IDs and enforcement matrix" or "modified services/dns/entrypoint.sh to add console-domain exclusion check").

3. **Related areas deliberately NOT changed (with reason)** — If the task description or issue context mentions work that you chose not to do, or related areas that appear to need similar changes but you left them untouched, state that explicitly and say why (e.g., "did not update .github/AGENTS.md because the issue scope is root AGENTS.md only" or "did not change README.md console section because issue #529 Track A is handling that separately"). This proves you recognized the boundary and did not accidentally miss work.

4. **Exact validation commands run and real results** — Not "ran tests" but "`bash scripts/check-file-headers.sh` — exit 0, no findings" or "`cargo clippy --locked --manifest-path services/ui/Cargo.toml -- -D warnings` — 12 warnings fixed, exit 0". Include the exact command so a reviewer can re-run it. If a check could not be run, state that too (e.g., "could not run docker compose config because Docker is unavailable on this host").

5. **Checks that could not be run (with reason)** — If the task normally requires a validation check but you could not run it (no Docker, no Rust toolchain, CI-only gate), state that explicitly. Do not claim success when a check is skipped. The report must distinguish between "check passed," "check skipped with reason," and "check failed."

6. **Known open risks** — Anything that feels incomplete, partially implemented, or dependent on follow-up work must be stated (e.g., "admin UI does not yet expose the new feature" or "the exception needs re-evaluation once upstream macro behavior changes"). Acknowledge what's outstanding rather than implying the task is fully shipped.

7. **Documentation checked/updated for drift** — Did you read the relevant documentation (README.md, threat-model.md, architecture docs) to verify it still describes the code behavior correctly? If you found drift, did you fix it? If not, why not? (Reference rule Rule-Ref: AG-DOC-001 — documentation drift is a defect.) State explicitly whether documentation was checked or skipped, and if skipped, why (e.g., "documentation changes are out of scope for this PR and tracked in issue #XXX").

8. **Follow-up issue reference or explicit "none"** — If this work creates or depends on a follow-up task, cite it (e.g., "depends on #500 being merged first" or "follow-up: #502 will add Admin UI support for this feature"). If there is no follow-up work, state "no follow-up required" explicitly, rather than omitting it. An omission looks like incomplete thought; an explicit statement closes the loop.

This contract overlaps with the `.github/pull_request_template.md` sections but is stricter: satisfying the template's headings with vague content (e.g., "Validation: tests pass") does not satisfy this rule. The content must be real, specific, and honest — including about gaps.

## Agent Autonomy and User-Context Rule

**[AG-WF-015]** The user of this repository is not a software programmer. This is a deliberate operational constraint, not a gap to work around.

**[AG-WF-023]** Agents and tools working on this repository must make technical decisions independently and must only ask for guidance when a choice has real operational impact such as hardware selection, network topology, cost implications, or time-to-value tradeoffs — not when the correct technical decision is determinable from code, documentation, and governance alone.

An example of a decision that agents should make independently: "The code changed from BIND9 to PowerDNS; should I update the threat model?" Answer: yes, update it. The code change determines the answer, not user preference.

An example of a decision that requires guidance: "The proposed optimization would increase cache RAM from 10GB to 50GB; is that acceptable for this operator's network?" Answer: ask. The hardware impact depends on the operator's deployment context, not the code alone.

When in doubt, prefer making the decision. The governance and code provide strong signals. This rule exists to keep workflows efficient and prevent decision-delegation bottlenecks on matters that are technically determinable.

## Agent Spawn Acceptance Protocol

Every agent, on being spawned as a sub-agent (by another agent or by the main thread), must, before doing any substantive work:

1. Read `AGENTS.md`, `CLAUDE.md`, and `.github/AGENTS.md` in full, with no shortcut (no skimming, no assuming inherited context from the dispatch prompt is a substitute).
2. Explicitly report back—by name, and as its very first action before taking any other tool action toward its assigned task—that it has read all three files: state "I have read AGENTS.md, CLAUDE.md, and .github/AGENTS.md" verbatim or equivalent, not merely "understood" or "acknowledged."
3. The parent/main thread that spawned it must confirm this acceptance is genuine, not rote, by asking the sub-agent to cite or quote at least one specific rule (by its `[AG-...]` ID) from the files it claims to have read. Because a sub-agent typically continues into substantive work within the same dispatch rather than pausing for a synchronous reply, the dispatching agent must perform this spot-check at the earliest checkpoint it can actually reach the sub-agent (e.g. its first status update or progress check-in), not only at the end, and must be willing to interrupt and redirect a sub-agent whose acceptance turns out to be rote or wrong rather than only discovering this after substantive work is already done.

This applies at every level of a spawn chain, not only to agents dispatched directly by the main thread—a sub-agent that itself spawns further sub-agents must apply this same protocol to each one, and must itself have already gone through it with its own parent.

## Rule Enforcement Matrix

This matrix maps the hard rules defined above to how they are currently enforced. An entry marked "Known gap, not currently enforced" is not a failure of this governance — it is more informative than claiming coverage that does not exist. Over time, gaps may close as CI infrastructure or validation tooling matures.

| Rule ID | Rule Name | Current Enforcement |
|---------|-----------|-------------------|
| AG-GH-001 | All GitHub content in English | Manual review (PR description language scan, commit message review) |
| AG-GH-002 | Issue descriptions include links | Manual review |
| AG-GH-003 | PRs reference tracking issue | Manual review |
| AG-GH-004 | Closes vs Refs keywords | Manual review |
| AG-GH-005 | Non-closing Refs for drafts | Manual review |
| AG-GH-006 | Issue/PR links in GitHub not chat | Manual review |
| AG-GH-007 | Project-facing text is English | Manual review |
| AG-GH-008 | PRs carry issue's labels/Milestone/Project | CI-enforced (`pr-tracking-metadata-check` in build-push.yml, blocking on non-draft PRs); Project-board sub-check requires `PROJECT_AUTOMATION_PAT` (see enforcement notes) |
| AG-GH-009 | Issues carry labels/Type/Milestone/Project-board/parent-sub-issue relationship | Manual review |
| AG-GH-010 | PR body includes a changelog-style summary (change, impact, validation, risk, follow-up) | Manual review |
| AG-GH-011 | Scaffold/partial-fix PRs must say so and use `Refs #123`, not `Fixes`/`Closes`, for the unresolved remainder | Manual review |
| AG-GH-012 | Compare merge commit/current master against the original issue before claiming completion | Manual review |
| AG-GH-013 | Actively maintain issues/PRs with comments as work happens, not only a one-time body; concrete 15-min-initial + every-15-min cadence, verified via a real time/date command | Manual review |
| AG-GH-014 | Issues must carry enough detail to be independently actionable | Manual review |
| AG-GH-015 | A narrowing follow-up issue must state explicitly whether it covers the original's full scope | Manual review |
| AG-GH-016 | Diff acceptance criteria before closing an issue as resolved/superseded/duplicate | Manual review |
| AG-GH-017 | Branches must be traceable via PR or linked issue comment at/near creation; check for existing coverage before starting new branch work | Manual review; automated guard tracked in #990 |
| AG-GH-018 | PR titles follow the Conventional-Commit taxonomy (allowed types/scopes, pre-1.0 `!`/`BREAKING CHANGE:` bumps minor not major); `security` intentionally excluded from types pending maintainer decision (#850) | CI (`pr-title-convention-check`/`pr-title-convention-check-hosted` in build-push.yml, blocking on non-draft PRs; draft PRs and `PR_TITLE_LINT_MODE=warn` degrade to a warning) |
| AG-WF-001 | Start branches from fresh base | Manual review (history inspection) |
| AG-WF-002 | Separate worktree per PR | Manual review |
| AG-WF-003 | Fanout for bounded work | Manual review (task delegation context) |
| AG-WF-004 | No direct master push | GitHub branch protection (`master` branch requires PR) |
| AG-WF-005 | Do not merge without explicit ask | Manual review |
| AG-WF-006 | Keep PRs in draft until ready | Manual review (PR draft status + CI sign-off) |
| AG-WF-007 | Review findings must be fixed before resolve | Manual review |
| AG-WF-008 | Fixed findings need factual reply | Manual review |
| AG-WF-009 | Reply on unresolvable threads | Manual review |
| AG-WF-010 | Read full context before acting | Manual review (finding quality inspection) |
| AG-WF-011 | Treat findings as failure classes | Manual review |
| AG-WF-012 | Verify GitHub API calls upload content | Manual review (GitHub object inspection) |
| AG-WF-013 | Consider bigger picture | Manual review (scope and impact assessment) |
| AG-WF-014 | No direct master push (redundant) | GitHub branch protection |
| AG-WF-015 | User is not a programmer; agents decide independently | Manual review (decision log in PR) |
| AG-WF-017 | Agent-authored commits/comments/actions carry an identifying marker (`<PREFIX>-<timestamp>`, e.g. `CLD-`/`CDX-` per AI system) | Manual review (commit message / GitHub object inspection) |
| AG-WF-018 | Search existing issues before filing a new one, even for topics that feel novel | Manual review (`gh issue list --search` before `gh issue create`) |
| AG-WF-019 | Chain `cd "<path>" && pwd && <command>` in one invocation; never trust a bare `cd` to persist across tool calls | Manual review (command history inspection) |
| AG-WF-020 | Fetch/rebase/verify before making readiness, mergeability, or integration-order statements | Manual review |
| AG-WF-021 | Treat subagent results as stale until verified against current remote base and PR head | Manual review |
| AG-WF-022 | Do not block on subagents when non-overlapping work is available; poll sparingly | Manual review |
| AG-WF-023 | Agents must make technical decisions independently; ask only when there is real operational impact | Manual review (decision log in PR) |
| AG-WF-024 | Sub-agents need their own verified-clean working directory; never trust inherited/recycled worktree state; any force-push variant requires immediate pre-action re-verification before proceeding; sub-agents must read+accept governance and report back by name; check back before destructive actions | Manual review |
| AG-VAL-001 | Warnings are errors | CI (all build jobs fail on warnings) + manual review |
| AG-VAL-002 | Standard failures are hard failures | CI (non-zero exit codes block merge) + manual review |
| AG-VAL-003 | Quote search patterns | Manual review (shell command inspection) |
| AG-VAL-004 | Do not hide failures with `\|\| true` | Manual review (fallback inspection) |
| AG-VAL-005 | Use deterministic search (rg/grep) | Manual review |
| AG-VAL-006 | Run narrowest relevant checks | Manual review (PR validation coverage) |
| AG-VAL-007 | Shell validation (bash -n, shellcheck) | CI (shell workflow files: actionlint; shell scripts: shellcheck in build-tools) |
| AG-VAL-008 | Rust validation (fmt, check, clippy, test) | CI (`build-tools` container runs cargo checks; PR checklist guidance) |
| AG-VAL-009 | Docker/Compose validation | CI (`docker compose config` for Compose changes) + manual review |
| AG-VAL-010 | Dev-stack `.env` resolution behavior | Manual review (docs and test guidance) |
| AG-VAL-011 | Workflow syntax and runner labels | CI (actionlint) + manual review |
| AG-VAL-012 | Setup/update migration coverage | Manual review (fixture/dry-run documentation) |
| AG-VAL-013 | DNS real response check | Manual review (`dig` commands required in test/verification guidance) |
| AG-VAL-014 | Proxy/cache behavior check | Manual review (integration test guidance) |
| AG-VAL-015 | Do not weaken checks for green | Manual review |
| AG-VAL-023 | Check a third-party tool's own docs for config options before assuming/building around observed default behavior | Manual review |
| AG-VAL-016 | Build-tools container (only valid path) | Manual review (CI inspection, PR guidelines) |
| AG-VAL-017 | Build-tools image tools/PATH | CI (`build-tools` image build and smoke-test) |
| AG-VAL-018 | DNS health checks use real probes | Manual review + documentation |
| AG-VAL-019 | `ping` alone insufficient for DNS | Manual review + documentation |
| AG-VAL-020 | `ss` alone insufficient for DNS | Manual review + documentation |
| AG-VAL-024 | New scripts: prefer explicit-interpreter invocation over relying on the committed executable bit (unverifiable on Windows/`core.filemode=false`); `set -e` fail-closed branches need a real failing-input CI run, not manual reasoning | Manual review (PR diff inspection for invocation style; CI run inspection for fail-closed branch coverage) |
| AG-VAL-021 | CodeQL #394 carve-out for findings in actually macro-*generated* code | Manual review (requires test-coverage evidence per rule text) |
| AG-VAL-022 | CodeQL #394 carve-out for extraction warnings on ordinary macro *invocations* in human-authored source | Manual review |
| AG-VAL-025 | Local Docker builds proving build/cache performance must mirror CI acceleration wiring (BUILD_TOOLS_IMAGE, CARGO_BUILD_JOBS, BuildKit secrets) | Manual review |
| AG-REL-001 | No new languages without approval, examples, one-off command exception, test-tooling disclosure | Manual review (new file type / import detection) |
| AG-REL-002 | Service builders consume the prebuilt build-tools image via BUILD_TOOLS_IMAGE | Manual review (Dockerfile inspection) |
| AG-REL-003 | TLS in Rust uses rustls, not openssl-sys | Manual review (dependency choice in `Cargo.toml`). **Known gap**: CI runs `cargo-audit` for the DNS and UI crates, but that only scans for known CVEs in already-present dependencies — it does not detect or block adding `openssl-sys` itself. No dependency-ban tooling (e.g. `cargo-deny`) is configured. |
| AG-REL-004 | Project language is Rust | Manual review |
| AG-REL-005 | Retired 2026-07-10, merged into AG-REL-001 (was redundant) | N/A |
| AG-REL-006 | Shell uses Bash by default | Manual review (shebang and syntax inspection) |
| AG-REL-007 | Retired 2026-07-10, merged into AG-REL-001 (was triplicative) | N/A |
| AG-REL-008 | Rust service builders should consume a prebuilt build-tools image; ad-hoc local toolchain compilation needs a documented reason | Manual review (Dockerfile inspection) |
| AG-SEC-001 | Admin-UI auth gate behavior | Manual review (documentation and code inspection) |
| AG-SEC-002 | Placeholders rejected at startup | Manual review (code inspection of `entrypoint.sh` reject paths, e.g. `services/dns/entrypoint.sh`, `services/dhcp/entrypoint.sh`). **Known gap**: no CI job was found that actually starts a service with a `CHANGE_ME_*` placeholder and asserts it fails closed — CI does start the full stack with `ALLOW_INSECURE_UI=true` (an unrelated auth-gate flag, not a placeholder check), which is not the same coverage. |
| AG-SEC-003 | Never commit credentials | **Known gap, not currently enforced by CI** — no secret-scanning job (e.g. truffleHog, gitleaks) exists in `.github/workflows/` today, and the repo's `.gitignore` does not list `ca.key` or `*.env.local` specifically. Enforcement is manual review only. |
| AG-SEC-004 | Use GitHub Secrets/Variables | Manual review |
| AG-SEC-005 | Do not hardcode Redis/distcc/runner IPs | Manual review (grep for hardcoded IPs) |
| AG-SEC-006 | Remove sensitive data from branch | Manual review + process discipline |
| AG-SEC-007 | Do not hardcode LAN IPs | Manual review (grep for hardcoded IPs) |
| AG-CI-001 | Runner baseline: assume no tools | Manual review (workflow inspection) |
| AG-CI-002 | Runner tier routing | Manual review (runner labels inspection) |
| AG-CI-003 | Runner portability (don't depend only on self-hosted) | Manual review (CI job inspection, documentation) |
| AG-CI-004 | sccache configuration | Manual review (environment variable and secrets wiring) |
| AG-CI-005 | distcc/pump configuration | Manual review (Dockerfile and PATH wiring) |
| AG-CI-006 | Build parallelism (CARGO_BUILD_JOBS rule) | Manual review (hardcoded value detection) |
| AG-CI-007 | Build acceleration wiring chain | Manual review (full chain inspection) |
| AG-CI-008 | Dockerfile ARG defaults for tool images are not a real CI consumption path | Manual review (check for an actual --build-arg consumer before treating the default as a bug) |
| AG-CI-009 | Build acceleration scope: sccache/distcc/Buildx cache are Dev/CI-only; production/setup/update stay pull-only | Manual review |
| AG-CI-010 | Tool image rebuilds only when tools/build-tools or the build workflow changed; release tags always build tag-scoped image | Manual review |
| AG-CI-011 | Release-adjacent jobs using build acceleration must document optional/preferred/hard-gate fallback behavior | Manual review |
| AG-OP-001 | Cache key is `$host$uri` | Code review (nginx config inspection) |
| AG-OP-002 | DNS resolver points to 8.8.8.8 | Code review (nginx resolver inspection) |
| AG-OP-003 | Lazy proxy default | Manual review + documentation |
| AG-OP-004 | Strict behavior is opt-in | Manual review + documentation |
| AG-OP-005 | Do not silently invert defaults | Manual review |
| AG-OP-006 | Setup/update idempotence | `tests/bats/setup_update_idempotence.bats` (repeat-run fixture against `migrate_env_for_update`) + `scripts/setup-cli-simulation.sh` Phase 2b (real CLI run twice, live). Covers the `.env`-migration path; watchdog's restart-counter/status-write convergence is covered separately by `tests/bats/watchdog_idempotence.bats` (repeat-cycle fixture against `check_and_maybe_restart`/`write_status`). Kea/PDNS/NATS writers still rely on manual review — see #456/#640 follow-ups. |
| AG-OP-007 | Setup/update convergence | `tests/bats/setup_update_idempotence.bats` (legacy-fixture convergence case) + `scripts/setup-cli-simulation.sh` Phase 2 (legacy `.env` through the real CLI). Same scope note as AG-OP-006. |
| AG-OP-008 | Missing values rejected or generated | Manual review (code inspection) |
| AG-OP-009 | Preserve existing local values | Manual review (code inspection) |
| AG-OP-010 | Validate before restart/pull | Manual review (code inspection and test guidance) |
| AG-OP-011 | Re-running update safe | `tests/bats/setup_update_idempotence.bats` + `scripts/setup-cli-simulation.sh` Phase 2b (second consecutive `setup.sh update`, no input change, asserts a byte-identical `.env` and unrotated secrets) |
| AG-OP-012 | Do not use `proxy_cache_key $request_uri` | Code review (nginx config inspection) |
| AG-OP-013 | Convergence/idempotence PRs answer the 5 questions | Manual review (PR body inspection) |
| AG-OP-014 | DHCP NTP defaults/semantics are a project-wide policy decision, not a per-PR cleanup target | Manual review |
| AG-OP-015 | Domain scope semantics: a leading-dot entry is an explicit wildcard scope, not equivalent to the root domain | Manual review |
| AG-DOC-001 | Documentation drift is a defect | Manual review (docs checked against code change) + **known gap**: no automated drift detection script yet |
| AG-DOC-002 | Precedence: executable checks / current code behavior (item 1) | Manual review |
| AG-DOC-003 | Precedence: `AGENTS.md` general rules, yields to more-specific lower items (item 2) | Manual review |
| AG-DOC-004 | Precedence: area-specific AGENTS files (item 3) | Manual review |
| AG-DOC-005 | Precedence: `SECURITY.md` (item 4) | Manual review |
| AG-DOC-006 | Precedence: architecture/release documentation (item 5) | Manual review |
| AG-DOC-007 | Precedence: `README.md`/user-facing docs (item 6) | Manual review |
| AG-DOC-008 | Do not silently pick a side on a real conflict | Manual review |
| AG-DOC-009 | Surface conflicts explicitly | Manual review |
| AG-DOC-010 | Fix one side of a conflict or ask for guidance | Manual review |
| AG-DOC-011 | Documented exceptions must follow the Scope/Reason/Tracking/Validation/Non-Expansion format | Manual review |
| AG-CODE-001 | Default: no comments | Manual review |
| AG-CODE-002 | Comments document WHY | Manual review |
| AG-CODE-003 | No task/PR refs in comments | Manual review |
| AG-CODE-004 | Structured notes for deferred work | Manual review |
| AG-CODE-005 | Remove TODO markers once implemented | Manual review + grep before finishing PR |
| AG-CODE-006 | Code must stay human-readable | Manual review |
| AG-CODE-007 | Structural/orientation step-comments allowed | Manual review |
| AG-CODE-008 | Touching any part of a file requires checking the entire file for missing WHY-comments | Manual review |
| AG-CODE-009 | A descriptive name/identifier alone is not a valid comment | Manual review |
| AG-CODE-010 | Every `#[test]` function needs at least a short comment | Manual review |
| AG-HDR-001 | Every source/config file should open with the standard `lancache-ng (https://github.com/wiki-mod/lancache-ng)` header, in the comment syntax valid for that file's language | CI (`file-headers` job runs `scripts/check-file-headers.sh` in build-push.yml) |
| AG-HDR-002 | Check what actually parses a `.conf`/`.json`/`.txt` file before adding a header; genuinely JSON content (e.g. the Kea config files) gets no header | CI (`scripts/check-file-headers.sh` exclusion list) |
| AG-HDR-003 | Do not add a header to a file consumed as a single raw value by a strict parser (e.g. the root `VERSION` file) | CI (`scripts/check-file-headers.sh` exclusion list) |
| AG-HDR-004 | Do not add a header to a vendored third-party file or a generated/compiled build artifact | CI (`scripts/check-file-headers.sh` exclusion list) |
| AG-HDR-005 | Scale header detail to the file's actual complexity; do not pad a simple file's header | Manual review |
| AG-HDR-006 | Every technical claim in a header must be verified against the actual file content and git history | Manual review |
| AG-HDR-007 | Excluded file types/paths for headers (`.md`, root `.env`/`.env.example`, lockfiles, `.gitkeep`, `VERSION`, vendored/generated artifacts, JSON-as-`.conf`) | CI (`scripts/check-file-headers.sh`'s `is_excluded()` function) |
| AG-HDR-008 | No license line in headers — the project has not adopted a license yet | Manual review |
| AG-HDR-009 | Repo-wide header backfill is complete; CI fails a PR missing a header on any non-excluded tracked file; add headers immediately for new files | CI (`file-headers` job in build-push.yml) |

**Known Gaps and Planned Improvements:**

- **AG-DOC-001** (Documentation drift): No automated script yet checks whether docs match code. This is a manual review burden. A future CI job could parse documentation headers, extract key terms (e.g., "PowerDNS," "Admin UI authentication required," "console domains excluded from DNS"), and compare them against corresponding code values. Until then, the rule exists as guidance; enforcement is manual.

- **AG-GH-001 and related language rules**: Enforced by human reviewers reading PRs, not by an automated language detector. An automated spell-checker or language-detection tool could help, but none is currently integrated.

- **AG-GH-008**: Enforced by `scripts/check-pr-tracking-metadata.sh`, run as the `pr-tracking-metadata-check` job in `build-push.yml` and gating the `build`/`build-arm64` jobs on pull requests, the same way `pr-template-check` does. It reads labels and milestone directly from the pull-request webhook payload (no extra permissions needed) and fails a non-draft PR missing either. Runs inside the pinned build-tools container (per AG-VAL-016), same as `shellcheck`/`check-governance-guards.sh`, since the script depends on `python3` and `curl`, which must not be treated as guaranteed present on the runner host. The project-board sub-check additionally requires a `PROJECT_AUTOMATION_PAT` repository secret (a classic PAT with the `project` scope) because the default `GITHUB_TOKEN` cannot read or write Projects v2 data for an org-owned board; without that secret configured, the project-board sub-check is skipped with a warning rather than failing the job. This also happens unconditionally for pull requests from forked repositories: GitHub does not pass repository secrets (other than the read-only `GITHUB_TOKEN`) to `pull_request`-triggered runs from forks, so `GH_TOKEN` is empty there even once `PROJECT_AUTOMATION_PAT` is configured for same-repo PRs. The check is told which case it's in via a `PR_IS_FORK` flag computed by the workflow (comparing head/base repo full names) and warns with the correct explanation either way; labels and milestone, read from the webhook payload rather than a secret, are still fully enforced for fork PRs. This is treated as an accepted limitation rather than something to work around with `pull_request_target`: that trigger would need to apply to this entire monolithic workflow (`needs:`-based job gating only works within one workflow file, so the check can't move to a separate `pull_request_target` workflow without losing the ability to gate `build`/`build-arm64`), and `pull_request_target` combined with checking out and building fork-supplied code (as `build-push.yml`'s other jobs do) is a known secret-exfiltration risk this repo does not take. A maintainer must add fork PRs to the project board manually regardless, since external contributors cannot write to an org-owned Projects v2 board themselves. If a token IS configured but is rejected (HTTP 401/403) or the GraphQL response itself carries an `errors` array (expired/revoked/insufficient-scope token), the check fails the job instead of warning -- that is a configuration bug in the secret, not the documented absent-token gap, and warning there would silently disable the project-board gate for the exact misconfiguration case this enforcement exists to catch. `.github/workflows/add-to-project.yml` (using the same secret) and `.github/workflows/labeler.yml` (path-based auto-labeling, no secret needed) reduce how often labels/project placement need to be set by hand in the first place. `add-to-project.yml`'s job is itself skipped outright (`if: secrets.PROJECT_AUTOMATION_PAT != ''`) rather than run-and-fail when that secret is absent, since `actions/add-to-project` errors immediately on a blank `github-token` input -- a hard failure on every new issue/PR before the secret exists, not the harmless no-op that file's header describes. The check requires a milestone unconditionally (it cannot cheaply determine whether the rule's "when one applies" exception genuinely applies to a given PR without an extra API call to inspect the referenced issue); every issue in this project has carried a milestone in practice so far, so this is stricter than the written rule but has not yet rejected a legitimately milestone-less PR. Revisit if that changes. `build-push.yml`'s `pull_request` trigger includes `labeled`/`unlabeled`/`milestoned`/`demilestoned`/`ready_for_review` in addition to the GitHub default `opened`/`synchronize`/`reopened`, so the check (and the rest of this monolithic workflow) reruns whenever metadata that feeds it actually changes, rather than showing a stale result until the next commit; this reruns the whole pipeline, not just this job, which is a deliberate cost/correctness tradeoff since labels/milestones change far less often than commits -- see the `on:` block's own comment in `build-push.yml`.

- Several operational rules (AG-OP-*) and comment style rules (AG-CODE-*) rely entirely on manual code review. No linting tools currently enforce these at CI time.
