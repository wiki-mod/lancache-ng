#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Shared host-local flock for CI jobs that drive a compose file with FIXED
# `container_name:` values (issue #838). Today that is only
# deploy/quickstart/docker-compose.yml, whose names (lancache-nats,
# lancache-ui, ...) are deliberately NOT project-name-scoped for a real
# operator's single-host install (#669 item 6) -- `COMPOSE_PROJECT_NAME`
# does not override `container_name:`, so two jobs that both bring this
# compose file up on the SAME physical runner host fight over the exact
# same containers, regardless of which workflow run or PR triggered either
# one.
#
# HISTORY THIS FILE REPLACES: `setup-cli-simulation.sh`'s job
# (full-setup-deep-validate.yml, full-setup-validate.yml) and
# `syslog-forwarding-simulation.sh`'s job (full-setup-deep-validate.yml)
# each hit this collision independently and were fixed ad-hoc, inline, with
# a hand-rolled `exec {lock_fd}>/tmp/lancache-setup-cli-simulation.lock;
# flock "$lock_fd"` copy-pasted into each `run:` step (3 copies total,
# confirmed via `git grep -n lancache-setup-cli-simulation.lock --
# .github/workflows`). `syslog-forwarding-simulation.sh`'s FIRST fix attempt
# gave itself its OWN separate lock file -- wrong, because its `needs:` is
# deliberately hoisted ahead of the serial sim chain so it runs genuinely
# CONCURRENTLY with setup-cli-simulation within the same PR's own CI run;
# docker-socket-proxy's access log showed a `POST
# /containers/lancache-nats/restart` mid-run, i.e. two sims fighting over
# the same container even after that first "fix". This file exists so the
# NEXT new job that drives this compose file calls one shared function
# instead of re-deriving (or mis-deriving, the same way, a second time) the
# lock file path by hand.
#
# WHY A SINGLE HARDCODED LOCK PATH, NOT A CALLER-SUPPLIED ONE: the whole
# point is that every job driving this SAME compose file serializes against
# every OTHER such job, not just against other runs of itself -- exactly
# the property syslog-forwarding-simulation.sh's own separate-lock-file
# mistake violated. Keeping one constant here (rather than letting each
# call site pass its own path) makes that shared scope structurally
# impossible to accidentally narrow again. The optional override parameter
# on the function below exists only so this file's own bats coverage can
# point at a throwaway test path instead of the real one -- production
# call sites must always call it with no argument.
#
# WHY THIS MUST BE `source`d, NEVER EXECUTED AS A SUBPROCESS (`bash
# quickstart-compose-lock.sh`): `exec {fd}>path` opens a file descriptor in
# the CURRENT shell. A function is not a subshell -- calling one does not
# fork a new shell -- so when a workflow `run:` step does `source
# scripts/lib/quickstart-compose-lock.sh` and then calls
# `quickstart_compose_lock_acquire`, the `exec`/`flock` inside that function
# still redirect and lock a descriptor that belongs to the step's own
# shell, and it stays open (and therefore locked) for the rest of that
# shell's life -- across the `docker run ... docker compose up` work that
# follows, until the step's shell process exits and the kernel closes the
# descriptor for it. If this file were instead invoked as a subprocess
# (`bash scripts/lib/quickstart-compose-lock.sh`), the fd and the flock
# would belong to THAT subprocess and be released the instant it returned
# -- before the protected `docker compose up`/simulation work even started,
# silently defeating the whole point. Mirrors
# scripts/lib/promote-lock.sh's own sourced-functions convention, though
# that file's actual lock primitive (a git-ref compare-and-swap) is
# unrelated to this one (a plain host-local flock is sufficient here
# because the collision this guards against can only happen between two
# runs sharing the same Docker daemon, i.e. the same physical runner host --
# unlike promote/backfill's cross-host race, see promote-lock.sh's own
# header for why a flock was NOT sufficient there).
#
# Pure function definitions, no top-level executable code, so sourcing this
# file has no side effects of its own until the caller actually invokes the
# function below. Deliberately NOT `set -euo pipefail` at the top level,
# same reasoning as promote-lock.sh/ghcr-retry.sh: this file only defines a
# function for the caller to invoke under the caller's own shell options.

# Single, well-known, shared lock file. Unchanged from the original inline
# 3-copy pattern's literal path so this refactor is behavior-preserving --
# a different path here would silently stop serializing against any CI job
# still running the old inline form (there should be none left after this
# change, but the path itself carries no reason to move).
QUICKSTART_COMPOSE_LOCK_PATH="/tmp/lancache-setup-cli-simulation.lock"

# quickstart_compose_lock_acquire [lock_path]
# Blocks (like the original inline `flock` with no `-n`) until the lock at
# <lock_path> (default: $QUICKSTART_COMPOSE_LOCK_PATH) is free, then holds
# it for the remainder of the caller's shell -- see the file header for why
# that requires this function to run in the caller's own shell via `source`
# rather than as a subprocess. There is no matching "release" function: the
# original inline pattern never released explicitly either, relying on the
# workflow step's shell exiting at the end of the step to close the
# descriptor and drop the flock, and this refactor preserves that same
# implicit-release behavior rather than changing it.
quickstart_compose_lock_acquire() {
    local lock_path="${1:-$QUICKSTART_COMPOSE_LOCK_PATH}"

    exec {QUICKSTART_COMPOSE_LOCK_FD}>"$lock_path"
    flock "$QUICKSTART_COMPOSE_LOCK_FD"
}
