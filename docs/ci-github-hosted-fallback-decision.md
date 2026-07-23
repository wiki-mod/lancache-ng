# CI GitHub-Hosted Fallback Decision

This document records the current, re-verified decision on which
`.github/workflows/build-push.yml` job classes can realistically run on
GitHub-hosted runners as a fallback for self-hosted-runner unavailability,
and why the remaining classes do not (yet). It exists to satisfy issue
#509's second acceptance criterion -- "a documented decision for whether/how
Rust build/test jobs and image build/push jobs get a fallback path, even if
the answer is 'not feasible'" -- as a standalone, findable document rather
than only as inline workflow comments, and to give issue #491 ("Add
GitHub-hosted CI fallback for non-LAN self-hosted assumptions") a real
per-class status instead of a single yes/no answer.

## Background

- PR #499 added the first GitHub-hosted fallback job, `file-headers-hosted`,
  as a deliberate proof-of-concept for zero-LAN-dependency lint jobs.
- Issue #509 asked for the rest of the "cheap lint" class to get the same
  treatment, plus a documented decision for the harder classes. It was
  closed (completed) by PR #591, which added `shellcheck-hosted` and
  explicitly decided against a `ci_scope_policy-hosted` job (see the comment
  above the `shellcheck` job in the workflow file).
- Issue #491 is the umbrella issue and stays open: its own acceptance
  criteria ask whether pipeline dead-ends have actually been reduced, not
  just whether a decision has been written down. Closing #509 does not close
  #491.
- Re-checking the current workflow file (not the job list from when #491/#509
  were originally written, which had drifted) found two additional
  zero-LAN-dependency jobs that had never been given a hosted fallback:
  `pr-template-check` and `watchdog_test`. Both are added as
  `pr-template-check-hosted` and `watchdog_test-hosted` in the same change
  that adds this document.
- `pr-title-convention-check` (added by the #850/AG-GH-018 PR-title
  Conventional-Commit lint) is a new job in the same zero-LAN-dependency
  "cheap lint" class as `pr-template-check`/`pr-tracking-metadata-check`,
  and ships its own hosted fallback, `pr-title-convention-check-hosted`,
  from the start rather than as a later catch-up pass. Note: a re-check
  while adding this entry found that `pr-tracking-metadata-check` (added
  after this document was originally written) also already has a
  `pr-tracking-metadata-check-hosted` sibling in the workflow file but was
  never added to the table below -- a pre-existing documentation gap this
  PR did not introduce and left as-is rather than expanding scope; flagged
  here per AG-DOC-009 rather than silently ignored.

## Current job inventory and classification

| Job | Class | Hosted fallback |
|---|---|---|
| `file-headers` | cheap lint | `file-headers-hosted` (PR #499) |
| `line-endings` | cheap lint | `line-endings-hosted` (issue #601) |
| `shellcheck` | cheap lint | `shellcheck-hosted` (PR #591) |
| `pr-template-check` | cheap lint | `pr-template-check-hosted` (this change) |
| `watchdog_test` | cheap lint | `watchdog_test-hosted` (this change) |
| `pr-title-convention-check` | cheap lint | `pr-title-convention-check-hosted` (#850/AG-GH-018) |
| `ci_scope_policy` | policy gate over Rust job results | none -- decided not feasible, see below |
| `detect-changes`, `validate-compose`, `compute-validation-network`, `full-setup-validate` | build-tools image / full Docker Compose stack | none -- see "Other self-hosted-only jobs" below |
| `dns_rust_quality`, `ui_rust_quality`, `dns_test`, `ui_test`, `rust_coverage`, `dns_cargo_audit`, `ui_cargo_audit` | Rust build/test/audit | none -- see "Rust build/test class" below |
| `publish_coverage_badge` | downstream of `rust_coverage`, needs `contents: write` | none, same reasoning as its upstream job |
| `container-scan`, `build`, `build-arm64`, `merge-manifests`, `promote`, `release` | image build/scan/publish | none for amd64/publish; `build-arm64`'s arm64 lane already runs natively on GitHub-hosted `ubuntu-24.04-arm` (issue #592) -- see "Image build/push class" below |

### Why `ci_scope_policy` has no hosted fallback

Documented inline in the workflow file (comment directly above the
`shellcheck` job): `ci_scope_policy` checks the *results* of the
self-hosted-only Rust jobs. A hosted sibling would have to `needs:` those
same self-hosted jobs, so in the one scenario this fallback exists for
(self-hosted runners genuinely unavailable) it would queue forever waiting
on its own dependencies -- not a real fallback. This is the same
transitively-skippable-dependency trap documented for `build`'s and
`promote`'s own `if:` conditions (issues #532/#677): a fallback job must
never gate on a self-hosted-only job's result, or it inherits that job's
availability, defeating the point of the fallback. `pr-template-check-hosted`
and `watchdog_test-hosted` avoid this trap by not using `needs:` on any
self-hosted job at all (see their own comments in the workflow file).

### Other self-hosted-only jobs (`detect-changes`, `validate-compose`, `compute-validation-network`, `full-setup-validate`)

These are not part of the "cheap lint" class #509 scoped in. They all
require either the shared `build-tools` Docker image, a full Docker Compose
stack, or (for `detect-changes`) a `fetch-depth: 0` checkout plus PR base/head
context used purely for path-scoping other jobs -- not itself expensive, but
not a lint check either, and not requested by #509's acceptance criteria.
They are left for a future increment if the project decides path-scoping and
compose validation are worth a hosted fallback; no decision is made here
either way.

## Rust build/test class: not infeasible, but not free

`dns_rust_quality`, `ui_rust_quality`, `dns_test`, `ui_test`, `rust_coverage`,
`dns_cargo_audit`, and `ui_cargo_audit` all run on `lancache-heavy` self-hosted
runners and use the acceleration layer described in AGENTS.md's **AG-CI-003**
("Runner portability") and `docs/self-hosted-actions-runner.md`'s
"Acceleration contract":

- Redis-backed `sccache` (`SCCACHE_REDIS_MODE` / `SCCACHE_REDIS_URL`)
- `sccache-dist` (`SCCACHE_DIST_SCHEDULER_URL` / `SCCACHE_DIST_AUTH_TOKEN`)
- `distcc` / `distcc-pump` for the C/C++ portions of some crates' build
  scripts (`DISTCC_POTENTIAL_HOSTS`)

All three are explicitly LAN-only: the scheduler, Redis instance, and distcc
hosts are not reachable from a GitHub-hosted runner. AG-CI-003 and the
acceleration contract already require every job that uses them to treat the
accelerator as optional/preferred/gate and to keep a documented fallback mode
that does not assume LAN reachability. The
`.github/actions/cargo-with-sccache-fallback` composite action already
implements exactly this for the self-hosted jobs: it detects whether sccache
is enabled and falls back to a plain `cargo` invocation (with a longer
timeout) when it is not.

**This means a GitHub-hosted Rust job is not infeasible.** The building
blocks already assume "sccache/distcc unavailable" as a first-class,
already-implemented code path, because that is also the local-contributor
and CI-degraded-mode story today. A `dns_rust_quality-hosted` /
`ui_rust_quality-hosted` (etc.) job could run
`cargo-with-sccache-fallback` with `LANCACHE_SCCACHE_ENABLED` unset (or
`SCCACHE_REDIS_MODE=off`), same as any environment without Redis access.

**What makes it a real cost, not a mechanical `runs-on:` swap:**

1. **Build time.** Full-fidelity, uncached `cargo build`/`cargo test`/
   `cargo tarpaulin` for the `dns/nats-subscriber` and `ui` crates is
   materially slower without sccache/distcc -- this is the same tradeoff
   already accepted for `build-arm64`'s GitHub-hosted arm64 lane (see
   `docs/self-hosted-actions-runner.md`'s "Native arm64 builds on
   GitHub-hosted runners": "always builds as an uncached, optional-
   acceleration `cargo build --release` -- slower per build than the
   accelerated amd64 lane"). Seven Rust jobs (quality + test + audit +
   coverage, times two crates) running uncached in parallel as a fallback
   would multiply GitHub Actions minutes usage for every PR, not just
   during self-hosted outages, if run unconditionally like the lint
   fallbacks are.
2. **Fallback jobs in this project run unconditionally, in parallel with the
   self-hosted job, every time** (see `file-headers-hosted` and friends).
   That pattern is fine for lint jobs measured in seconds; for Rust jobs
   measured in minutes-to-tens-of-minutes, duplicating every run
   unconditionally is a real, ongoing GitHub Actions minutes cost, not a
   one-time proof-of-concept cost.
3. **Runner-tier resources.** The self-hosted jobs use the `lancache-heavy`
   tier specifically because Rust builds need more CPU/memory than
   `lancache-light`. Standard `ubuntu-latest` hosted runners are the
   equivalent of a light tier (2 cores as of this writing); GitHub also
   offers larger hosted runners, but those are billed, and this is a public
   repository currently relying on the free hosted-runner allowance.
   Committing Rust jobs to hosted runners either accepts slower builds on
   standard hosted runners or requires a paid larger-runner decision -- both
   are real operational/cost calls the project has not made.

**Recommendation:** Rust build/test/audit fallback is **acceptable-but-slow,
not infeasible** -- the mechanism already exists via
`cargo-with-sccache-fallback`. It should not be added as an always-on
parallel job like the lint fallbacks, because of the recurring minutes cost.
Instead, a future increment should scope it as an **opt-in** fallback: either
a `workflow_dispatch` input, or a job that only runs when self-hosted runners
are actually observed to be unavailable, not unconditionally on every push
and PR. A follow-up issue tracks scoping and prototyping this (see below).

## Image build/push class: harder, not attempted here

`container-scan`, `build`, `merge-manifests`, `promote`, and `release` stay
fully self-hosted, with one partial exception already shipped
(`build-arm64`'s native arm64 lane on GitHub-hosted `ubuntu-24.04-arm`,
issue #592). Three independent constraints apply to the rest:

1. **Multi-arch build time.** `build` produces `linux/amd64` images for
   every service, including two Rust services compiled from source
   (`dns`, `ui`) plus the shared `build-tools` publish path. Even with the
   arm64 lane already offloaded to a native hosted runner, the amd64 lane's
   own build time is dominated by the same sccache/distcc-accelerated Rust
   compiles discussed above, at a larger scale (release-mode multi-service
   builds, not single-crate test/quality passes).
2. **GHCR push credentials.** `build`, `merge-manifests`, `promote`, and
   `release` all push to GHCR or move channel tags, which requires
   `packages: write` credentials. `docs/local-runner-docker-performance.md`'s
   "Keep the runner isolated" guidance is explicit that registry push
   credentials should only be exposed where a workflow genuinely needs them;
   widening that exposure to GitHub-hosted runners (which, unlike the
   self-hosted pool, are not physically operator-controlled LAN hardware)
   is a real security posture change, not a mechanical one, and is out of
   scope for a fallback whose entire purpose is "keep validating/publishing
   when self-hosted is down" rather than "change where secrets live."
3. **Runner-tier CPU/memory.** Same constraint as the Rust class, at image-
   build scale: `build`, `merge-manifests`, `promote`, and `release` all run
   on `lancache-heavy`. A full multi-service image build/push fallback on
   standard hosted runners would be both slow and, per point 2, would need a
   credential-exposure decision first.

**Recommendation:** image build/push fallback is **not attempted now**. It
should only be revisited if self-hosted `lancache-heavy` capacity becomes a
recurring, observed availability problem (not a hypothetical one), and any
such follow-up must resolve the GHCR credential-exposure question explicitly
before any hosted job gets `packages: write`. A follow-up issue tracks this
as an investigation, not an implementation commitment.

## Summary

| Class | Status | Fallback path |
|---|---|---|
| Cheap lint (file-headers, line-endings, shellcheck, pr-template-check, watchdog_test) | done | Always-on parallel hosted job |
| `ci_scope_policy` | decided: not feasible | None -- inherits Rust jobs' own unavailability |
| Rust build/test/audit | acceptable-but-slow | Not implemented; needs opt-in scoping, not always-on. Follow-up issue tracks prototyping. |
| Image build/push (amd64/publish) | hard, not attempted | Follow-up issue tracks investigation; blocked on a GHCR credential-exposure decision |
| Image build (arm64) | already done | Native `ubuntu-24.04-arm` lane in `build-arm64` (issue #592) |
