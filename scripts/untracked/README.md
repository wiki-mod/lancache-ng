# scripts/untracked/

CI-tooling-only scripts (issue #1095 F-16). A script lives here once it has
been individually verified to have no service/product-code dependency at
all -- specifically, verified to be invoked only from `build-push.yml`'s own
PR-gate jobs, `build-tools-smoke.yml`, `backfill-stack-latest.yml`, or
`orphaned-branches.yml`, and never sourced/invoked/COPYed by anything
`full-setup-deep-validate.yml`/`full-setup-sims.yml`/`full-setup-validate.yml`
(or the simulation scripts they run) exercises.

Any path under this directory is automatically recognized as CI-tooling-only
by `scripts/tracked/detect-full-setup-changes.sh`'s `should_run` logic
(directory-prefix match) -- a script placed here needs no separate array
entry, and `scripts/tracked/detect-full-setup-changes.sh`'s own
`ci_tooling_only_scripts` array is empty as a result (see that script's own
header comment for the full history).

Populated 2026-08-07 (post-v0.3.0-release "touch it, move it" scheme
finalized on 2026-07-31, execution deferred until after the release per an
explicit maintainer instruction -- see issue #1095's F-16 discussion). The
28 scripts here are exactly the ones PR #1341 individually verified and
allowlisted by name before this directory existed; git history preserves
that verification's provenance via `git mv`, not a fresh add.
