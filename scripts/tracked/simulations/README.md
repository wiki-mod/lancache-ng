# scripts/tracked/simulations/

Every `*-simulation.sh` script (issue #1095 F-16): real, opt-in end-to-end
proofs that exercise the actual running stack (Docker Compose, live DNS
queries, real DHCP lease exchanges, NATS auth callouts, TLS interception,
syslog forwarding, and similar) rather than unit-testing code in isolation.
These are what `.github/workflows/full-setup-deep-validate.yml` and
`full-setup-sims.yml` invoke, and what
`scripts/tracked/detect-full-setup-changes.sh`'s `should_run` gate exists
to decide whether to run at all for a given PR diff.

No special-case handling exists for this prefix in
`scripts/tracked/detect-full-setup-changes.sh` -- a path here that is not
also matched by `scripts/untracked/`'s directory-prefix rule falls through to
should_run-relevant by default, which is the correct, intended behavior: a
change to a simulation script must always re-run the deep validation suite,
never be treated as CI-tooling-only.

Populated 2026-08-07 (post-v0.3.0-release "touch it, move it" scheme
finalized on 2026-07-31, execution deferred until after the release per an
explicit maintainer instruction -- see issue #1095's F-16 discussion). 19
files as of this move (13 at decision time on 2026-07-31; six more
simulation scripts landed on `current_dev` in the interim).
