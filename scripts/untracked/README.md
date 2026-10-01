# scripts/untracked/

Every `scripts/` file that is NOT CI-tooling-only (issue #1095 F-16):
release/setup/runtime utilities. `scripts/untracked/simulations/` holds the
`*-simulation.sh` files specifically (see that subdirectory's own README).
`scripts/lib/` stays where it is, outside both `scripts/tracked/` and
`scripts/untracked/`. No CI 2.0 decision reads these directory prefixes;
impact is decided by build identity in `.github/scripts/ci.sh`.

Populated 2026-08-07 (post-v0.3.0-release "touch it, move it" scheme
finalized on 2026-07-31, execution deferred until after the release per an
explicit maintainer instruction -- see issue #1095's F-16 discussion).
