# scripts/untracked/simulations/

Every `*-simulation.sh` script (issue #1095 F-16): real, opt-in end-to-end
proofs that exercise the actual running stack (Docker Compose, live DNS
queries, real DHCP lease exchanges, NATS auth callouts, TLS interception,
syslog forwarding, and similar) rather than unit-testing code in isolation.
These are what `.github/workflows/full-setup-sims.yml` invokes.

Populated 2026-08-07 (post-v0.3.0-release "touch it, move it" scheme
finalized on 2026-07-31, execution deferred until after the release per an
explicit maintainer instruction -- see issue #1095's F-16 discussion). 19
files as of this move (13 at decision time on 2026-07-31; six more
simulation scripts landed on `current_dev` in the interim).
