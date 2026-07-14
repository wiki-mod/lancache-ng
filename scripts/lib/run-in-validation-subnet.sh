#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Reserve a collision-free full-setup validation subnet, export its complete
# VALIDATION_* environment, then run a single command (a *-simulation.sh
# script) inside that reservation -- retrying on a different octet if, and
# only if, the command fails with a Docker subnet/address collision (issue
# #820).
#
# WHY THIS EXISTS separately from full-setup-validate.yml's own inline
# "Reserve a validation subnet and start the stack" step: that step holds
# the octet lock across SEPARATE workflow steps (up -> health -> client sim
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
# self-hosted host never fight over the same 172.30.<octet>.0/24 bridge.
#
# BACKGROUND: .github/actions/derive-validation-network (#623) derives one
# 172.30.<octet>.0/24 subnet per run from a hash of the run id/attempt and
# hands it to every full-setup-deep-validate.yml job via job-level env. That
# alone leaves two failure modes on a shared host: (1) two concurrent runs
# hash to the same octet (only 252 buckets); (2) even when they don't, the
# old per-job "Check for a validation subnet collision" pre-flight step could
# pass and `docker compose up` still lose the check-then-create race to
# another run mid-flight -- confirmed for real (run 29287590206's NATS
# auth-callout job died on `Pool overlaps` for octet 22). #703 already closed
# this for the manual full-setup-validate.yml with a flock + retry loop, but
# full-setup-deep-validate.yml's own stack-starting jobs never adopted it and
# kept flaking. This wrapper is how those jobs adopt it.

set -euo pipefail

usage() {
    echo "usage: $0 <command> [args...]" >&2
    echo "  Reserves a free 172.30.<octet>.0/24 validation subnet, exports the" >&2
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
# deep-validate runs) coordinate on one shared per-octet lock namespace per
# host, rather than each inventing its own and colliding anyway.
lock_root="/tmp/lancache-validation-locks"
max_attempts=10

# subnet_conflicts <target_subnet>
# Prints a human-readable description of every EXISTING Docker network or host
# interface whose subnet overlaps <target_subnet>, ignoring networks that
# belong to THIS run's own Compose project (docker compose reuses/recreates
# those by name -- a leftover from an aborted earlier attempt is not a real
# collision). Empty output means the candidate looks free. This is
# defense-in-depth ahead of `docker compose up`: a leftover bridge interface
# from something outside Docker's own bookkeeping (another NIC, a VPN, a
# bridge orphaned by a killed container that `docker network ls` no longer
# lists) still makes the kernel refuse an overlapping bridge, so checking the
# live `ip addr` view here lets the retry skip that octet cleanly instead of
# discovering it only via a `docker compose up` failure. This is exactly why
# the wrapper self-heals around leaked bridge interfaces regardless of any
# host-side cleanup hook's completeness.
#
# python3 is used purely as an inline, uncommitted-behaviour CIDR-overlap
# calculator (stdlib `ipaddress`); nothing from it is imported into the
# project runtime (Rust + shell), consistent with AG-REL-001's local-one-off
# allowance and with the identical inline check the workflows already carry.
subnet_conflicts() {
    local target_subnet="$1"
    python3 - "$target_subnet" <<'PYEOF'
import ipaddress, os, subprocess, sys

target = ipaddress.ip_network(sys.argv[1])
own_prefix = os.environ.get("COMPOSE_PROJECT_NAME", "lancache-ng-validation")

# Match our OWN networks exactly, or a well-delimited child of our project
# name ("<prefix>_validation", "<prefix>-auth-callout_validation", ...) --
# NOT a bare startswith, which would wrongly treat another run's octet-220
# project ("lancache-ng-validation-220...") as "ours" when this run holds
# octet 22. Those never share a subnet in practice (the flock stops two runs
# holding the same octet at once), but the delimiter check keeps the "is this
# network ours" test honest instead of relying on that backstop.
def is_ours(name: str) -> bool:
    return name == own_prefix or name.startswith(own_prefix + "-") or name.startswith(own_prefix + "_")

ids = subprocess.run(["docker", "network", "ls", "-q"], capture_output=True, text=True, check=True).stdout.split()
for network_id in ids:
    fmt = "{{.Name}}|{{range .IPAM.Config}}{{.Subnet}} {{end}}"
    line = subprocess.run(["docker", "network", "inspect", network_id, "--format", fmt], capture_output=True, text=True, check=True).stdout.strip()
    name, _, subnets_str = line.partition("|")
    if is_ours(name):
        continue
    for subnet_str in subnets_str.split():
        try:
            existing = ipaddress.ip_network(subnet_str)
        except ValueError:
            continue
        if target.overlaps(existing):
            print(f"docker network {name} ({subnet_str})")

route_output = subprocess.run(["ip", "-4", "-o", "addr", "show"], capture_output=True, text=True, check=True).stdout
for line in route_output.splitlines():
    parts = line.split()
    try:
        inet_index = parts.index("inet")
        iface = parts[1]
        cidr = parts[inet_index + 1]
    except (ValueError, IndexError):
        continue
    try:
        existing = ipaddress.ip_interface(cidr).network
    except ValueError:
        continue
    if target.overlaps(existing):
        print(f"host interface {iface} ({cidr})")
PYEOF
}

reserved=0
next_attempt=1
cmd_status=0

while [[ "$next_attempt" -le "$max_attempts" ]]; do
    reservation="$(validation_subnet_reserve "$lock_root" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$next_attempt" "$max_attempts")" || {
        echo "::error::Could not lock a free validation subnet octet after $max_attempts attempts." >&2
        exit 1
    }
    attempt="$(printf '%s\n' "$reservation" | sed -n 's/^attempt=//p')"
    octet="$(printf '%s\n' "$reservation" | sed -n 's/^octet=//p')"
    holder_pid="$(printf '%s\n' "$reservation" | sed -n 's/^holder_pid=//p')"

    # Export the FULL VALIDATION_* set for THIS octet before the conflict
    # check, so subnet_conflicts() reads the correct COMPOSE_PROJECT_NAME
    # (which decides which existing networks count as "ours") and so the
    # command below inherits a self-consistent address set.
    validation_subnet_export_env "$octet"
    target_subnet="172.30.${octet}.0/24"

    conflict="$(subnet_conflicts "$target_subnet")"
    if [[ -n "$conflict" ]]; then
        echo "Octet $octet's subnet $target_subnet overlaps existing host/Docker state ($conflict); releasing and trying the next candidate."
        validation_subnet_release "$holder_pid"
        next_attempt=$((attempt + 1))
        continue
    fi

    echo "== Running '$*' on locked, pre-checked validation subnet $target_subnet (project $COMPOSE_PROJECT_NAME, attempt $attempt) =="

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
    # gone by the time it returns -- release the octet lock unconditionally
    # now, whatever the outcome, so a concurrent run can claim it immediately
    # instead of waiting for this job's whole process tree to exit.
    validation_subnet_release "$holder_pid"

    if [[ "$cmd_status" -eq 0 ]]; then
        reserved=1
        break
    fi

    if validation_subnet_output_is_collision "$output"; then
        echo "Command failed with a subnet/address collision on attempt $attempt; retrying with a different octet."
        next_attempt=$((attempt + 1))
        continue
    fi

    # A non-collision failure fails identically on every octet (bad image,
    # missing env var, real test assertion) -- surface it now with the
    # command's own exit code instead of wasting the remaining retry budget.
    echo "::error::Command failed for a reason unrelated to a subnet collision (exit $cmd_status); not retrying." >&2
    exit "$cmd_status"
done

if [[ "$reserved" -ne 1 ]]; then
    echo "::error::Could not reserve a free validation subnet and run the command after $max_attempts attempts." >&2
    exit 1
fi
