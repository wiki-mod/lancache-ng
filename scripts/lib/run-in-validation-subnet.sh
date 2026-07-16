#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Reserve a collision-free full-setup validation subnet, export its complete
# VALIDATION_* environment, then run a single command (a *-simulation.sh
# script) inside that reservation -- retrying on a different slot if, and
# only if, the command fails with a Docker subnet/address collision (issue
# #820).
#
# WHY THIS EXISTS separately from full-setup-validate.yml's own inline
# "Reserve a validation subnet and start the stack" step: that step holds
# the slot lock across SEPARATE workflow steps (up -> health -> client sim
# -> teardown), so it must thread the holder PID through $GITHUB_ENV and
# release it in a later teardown step. The simulation scripts this wrapper
# drives are different: each one brings its stack UP, tests it, and tears it
# DOWN within a single invocation (its own EXIT-trap cleanup). So the lock
# only has to be held for the duration of that one command, and the whole
# reserve -> run -> release cycle fits in one step -- no cross-step PID
# threading needed. Sharing the reservation primitives
# (scripts/lib/reserve-validation-subnet.sh) keeps both paths coordinating on
# the SAME host-local /tmp lock root, so a deep-validate run, a manual
# full-setup-validate run, and any other concurrent run on the same
# self-hosted host never fight over the same /27 bridge (see issue #832 --
# each reservation slot is now a /27 within the same already-owned
# 172.30.0.0/16, not a whole /24 per octet).
#
# BACKGROUND: .github/actions/derive-validation-network (#623) derives one
# subnet per run from a hash of the run id/attempt and hands it to every
# full-setup-deep-validate.yml job via job-level env. That alone leaves two
# failure modes on a shared host: (1) two concurrent runs hash to the same
# slot (only 252 buckets pre-#832, ~2,000 since); (2) even when they don't,
# the old per-job "Check for a validation subnet collision" pre-flight step
# could pass and `docker compose up` still lose the check-then-create race
# to another run mid-flight -- confirmed for real (run 29287590206's NATS
# auth-callout job died on `Pool overlaps` for octet 22, back when the
# reservation unit was a whole /24 per octet). #703 already closed this for
# the manual full-setup-validate.yml with a flock + retry loop, but
# full-setup-deep-validate.yml's own stack-starting jobs never adopted it and
# kept flaking. This wrapper is how those jobs adopt it.

set -euo pipefail

usage() {
    echo "usage: $0 <command> [args...]" >&2
    echo "  Reserves a free /27 validation subnet within 172.30.0.0/16, exports the" >&2
    echo "  matching VALIDATION_* env, and runs <command> inside it, retrying on" >&2
    echo "  a subnet/address collision only." >&2
}

if [[ $# -lt 1 ]]; then
    usage
    exit 2
fi

: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"

if ! command -v flock >/dev/null 2>&1; then
    echo "::error::flock is required for safe validation-subnet locking." >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/reserve-validation-subnet.sh
source "$script_dir/reserve-validation-subnet.sh"

# Same host-local lock root the manual full-setup-validate.yml step uses on
# purpose: it is what makes a deep-validate run and a manual run (and two
# deep-validate runs) coordinate on one shared per-slot lock namespace per
# host, rather than each inventing its own and colliding anyway.
lock_root="/tmp/lancache-validation-locks"
max_attempts=10

# The collision-conflict check itself (validation_subnet_conflicts) is
# sourced from reserve-validation-subnet.sh above -- issue #820 consolidated
# what used to be a copy-pasted python block per caller (this wrapper, the
# full-setup-deep-validate.yml reserve step, and now the DHCP simulation
# scripts) into one shared definition in the lib.

reserved=0
next_attempt=1
cmd_status=0

while [[ "$next_attempt" -le "$max_attempts" ]]; do
    reservation="$(validation_subnet_reserve "$lock_root" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$next_attempt" "$max_attempts")" || {
        echo "::error::Could not lock a free validation subnet slot after $max_attempts attempts." >&2
        exit 1
    }
    attempt="$(printf '%s\n' "$reservation" | sed -n 's/^attempt=//p')"
    slot="$(printf '%s\n' "$reservation" | sed -n 's/^slot=//p')"
    holder_pid="$(printf '%s\n' "$reservation" | sed -n 's/^holder_pid=//p')"

    # Export the FULL VALIDATION_* set for THIS slot before the conflict
    # check, so validation_subnet_conflicts reads the correct
    # COMPOSE_PROJECT_NAME (which decides which existing networks count as
    # "ours") and so the command below inherits a self-consistent address set.
    # #832: <slot> is no longer a literal IP octet (it can run past 255), so
    # unlike before this file must NOT recompute a "172.30.<slot>.0/24"-style
    # string locally -- $VALIDATION_SUBNET (the one export_env just set) is
    # the only correct value.
    validation_subnet_export_env "$slot"

    conflict="$(validation_subnet_conflicts "$VALIDATION_SUBNET" "$COMPOSE_PROJECT_NAME")"
    if [[ -n "$conflict" ]]; then
        echo "Slot $slot's subnet $VALIDATION_SUBNET overlaps existing host/Docker state ($conflict); releasing and trying the next candidate."
        validation_subnet_release "$holder_pid"
        next_attempt=$((attempt + 1))
        continue
    fi

    echo "== Running '$*' on locked, pre-checked validation subnet $VALIDATION_SUBNET (project $COMPOSE_PROJECT_NAME, attempt $attempt) =="

    # Capture combined output while still streaming it live: tee mirrors it to
    # the log for debugging AND to a buffer the collision classifier reads.
    # `set +e`/PIPESTATUS is what lets a failing command be inspected here
    # rather than aborting the whole wrapper under `set -e` before we can
    # decide whether the failure is a retryable collision.
    out_file="$(mktemp)"
    set +e
    "$@" 2>&1 | tee "$out_file"
    cmd_status="${PIPESTATUS[0]}"
    set -e
    output="$(cat "$out_file")"
    rm -f "$out_file"

    # The command owns its own teardown (EXIT trap), so the network is already
    # gone by the time it returns -- release the slot lock unconditionally
    # now, whatever the outcome, so a concurrent run can claim it immediately
    # instead of waiting for this job's whole process tree to exit. This
    # assumption only holds because each wrapped script's own cleanup trap
    # calls validation_project_networks_teardown (reserve-validation-
    # subnet.sh) after `docker compose down`, which waits for every
    # container to actually detach before returning -- `down`'s own exit
    # alone is not sufficient proof (confirmed in CI: a container-removal API
    # call can report success before its network endpoint is actually
    # unwired, leaving the network non-empty for whichever run reserves this
    # same slot next).
    validation_subnet_release "$holder_pid"

    if [[ "$cmd_status" -eq 0 ]]; then
        reserved=1
        break
    fi

    if validation_subnet_output_is_collision "$output"; then
        echo "Command failed with a subnet/address collision on attempt $attempt; retrying with a different slot."
        next_attempt=$((attempt + 1))
        continue
    fi

    # A non-collision failure fails identically on every slot (bad image,
    # missing env var, real test assertion) -- surface it now with the
    # command's own exit code instead of wasting the remaining retry budget.
    echo "::error::Command failed for a reason unrelated to a subnet collision (exit $cmd_status); not retrying." >&2
    exit "$cmd_status"
done

if [[ "$reserved" -ne 1 ]]; then
    echo "::error::Could not reserve a free validation subnet and run the command after $max_attempts attempts." >&2
    exit 1
fi
