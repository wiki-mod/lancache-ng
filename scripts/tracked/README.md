# scripts/tracked/

Every `scripts/` file that is NOT CI-tooling-only (issue #1095 F-16):
release/setup/runtime utilities, plus the small set of scripts that
themselves decide or influence CI behavior (`detect-full-setup-changes.sh`,
`plan-deep-validation.sh`, `classify-image-impact.sh`,
`select-build-tools-image.sh`) and must therefore keep triggering real
validation when touched rather than being exempted. `scripts/tracked/
simulations/` holds the `*-simulation.sh` files specifically (see that
subdirectory's own README).

No special-case handling exists for this prefix in
`scripts/tracked/detect-full-setup-changes.sh` -- none is needed, since any
path here that isn't also matched by `scripts/untracked/`'s directory-prefix
rule already falls through to should_run-relevant by default, exactly like
an unclassified script. `scripts/lib/` is treated the same way (its
changes are should_run-relevant too, i.e. not exempted) and stays where it
is, outside both `scripts/untracked/` and `scripts/tracked/`.

Populated 2026-08-07 (post-v0.3.0-release "touch it, move it" scheme
finalized on 2026-07-31, execution deferred until after the release per an
explicit maintainer instruction -- see issue #1095's F-16 discussion).
