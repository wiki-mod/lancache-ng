# scripts/untracked/

Every `scripts/` file that is NOT CI-tooling-only (issue #1095 F-16):
release/setup/runtime utilities, plus the small set of scripts that
themselves decide or influence CI behavior (`detect-full-setup-changes.sh`,
`plan-deep-validation.sh`, `classify-image-impact.sh`,
`select-build-tools-image.sh`) and must therefore keep triggering real
validation when touched rather than being exempted. `scripts/untracked/
simulations/` holds the `*-simulation.sh` files specifically (see that
subdirectory's own README).

No special-case handling exists for this prefix in
`scripts/untracked/detect-full-setup-changes.sh` -- none is needed, since any
path here that isn't also matched by `scripts/tracked/`'s directory-prefix
rule already falls through to should_run-relevant by default, exactly like
an unclassified script. `scripts/lib/` is treated the same way (also not
tracked) and stays where it is, outside both `scripts/tracked/` and
`scripts/untracked/`.

Populated 2026-08-07 (post-v0.3.0-release "touch it, move it" scheme
finalized on 2026-07-31, execution deferred until after the release per an
explicit maintainer instruction -- see issue #1095's F-16 discussion).
