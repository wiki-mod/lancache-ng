#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Host-local, per-octet locking for the full-setup-validate validation
# Docker subnet (issue #703). Pure functions plus small side-effecting
# helpers, no top-level executable code, so this can be sourced directly
# both by .github/workflows/full-setup-validate.yml's own "Reserve a
# validation subnet and start the stack" step and by
# tests/bats/reserve_validation_subnet.bats (fast, Docker-free unit coverage
# of the derivation and lock-contention logic).
#
# Background: .github/actions/derive-validation-network (#623) derives a
# 172.30.<n>.0/24 subnet from a hash of the run id/attempt, which makes
# same-subnet collisions between two different, genuinely concurrent
# workflow runs on the same self-hosted host RARE but not impossible -- pure
# hashing has no coordination between runs at all. #703's own linked run
# confirmed this for real: two concurrent runs derived the same octet, both
# passed the old `docker network ls`-based pre-flight check (which only
# catches a leftover Docker network from a previous run, not another run
# mid-way through its own check-then-create window), and only one of them
# won the kernel race to actually create the bridge.
#
# This closes that gap with the same host-local `flock` idiom already used
# elsewhere in this project for a shared-per-host resource
# (build-tools.yml/build-push.yml's own Buildx cache lock): before a run is
# allowed to touch Docker at all, it must hold an exclusive, non-blocking
# flock on a well-known per-octet path. flock's lock is tied to an open file
# descriptor, not to a marker file's mere existence, so a crashed or
# cancelled run can never leave a stale lock behind -- the kernel releases
# it the instant the holding process dies, whatever kills it (an explicit
# release, or the runner tearing down the whole job's process tree on
# cancellation).

# validation_subnet_derive_octet <raw_seed>
# Prints the third octet (2..253, excluding 28 and 99) of a
# 172.30.<octet>.0/24 candidate subnet, deterministically derived from
# <raw_seed>. Hashing rather than using the seed mod N directly: nothing
# guarantees the seed's low-order digits are evenly distributed, and
# back-to-back runs (the common case: consecutive pushes/PRs) hashing on raw
# low bits could cluster near each other instead of spreading across the
# available range.
validation_subnet_derive_octet() {
    local raw_seed="$1"
    local digest decimal octet

    digest="$(printf '%s' "$raw_seed" | sha256sum | cut -c1-8)"
    decimal=$((16#$digest))

    # Reserve the third octet of 172.30.0.0/16 as the per-run pool. 0 and 1
    # are excluded outright; 28 is deploy/dev's docker-compose subnet
    # (172.28.0.0/16, see deploy/dev/docker-compose.yml) so a derived run
    # can never reproduce that unrelated network's third octet; 99 was the
    # old fixed value, kept excluded so a derived pool stays visibly
    # distinct from the previous hardcoded default.
    octet=$(( (decimal % 252) + 2 )) # 2..253
    case "$octet" in
        28|99) octet=$(( octet + 100 )) ;;
    esac

    printf '%s\n' "$octet"
}

# validation_subnet_seed_for_attempt <run_id> <run_attempt> <attempt_number>
# Prints the hash seed for the given retry attempt. attempt_number 1 uses
# the exact same seed .github/actions/derive-validation-network's own
# formula does (<run_id>-<run_attempt>, no extra suffix), so the common,
# uncontested case -- the overwhelming majority of runs, which never hit a
# lock or a real Docker collision -- derives the IDENTICAL octet that
# action already independently computes for the compose-project-name/UI-port
# outputs it exposes to this workflow's other jobs. Only a genuine retry
# (attempt_number > 1) salts the seed, so it can never re-derive the very
# candidate that was just found to be locked or in use.
validation_subnet_seed_for_attempt() {
    local run_id="$1" run_attempt="$2" attempt_number="$3"

    if [[ "$attempt_number" -eq 1 ]]; then
        printf '%s-%s\n' "$run_id" "$run_attempt"
    else
        printf '%s-%s-retry%s\n' "$run_id" "$run_attempt" "$attempt_number"
    fi
}

# validation_subnet_try_lock <lock_root> <octet>
# Attempts to atomically claim <octet> by holding a non-blocking exclusive
# flock on "<lock_root>/<octet>.lock" for as long as the returned holder
# process stays alive. On success, prints the holder PID on stdout and
# returns 0; on failure (another process already holds this octet's lock),
# prints nothing and returns 1.
#
# The lock is acquired directly on an fd owned by the very process that
# stays alive to hold it (`exec 9>...; flock -n 9; exec sleep infinity`, the
# same fd-based pattern build-tools.yml's Buildx cache lock uses for its own
# synchronous, single-step flock), not by a wrapper process that forks a
# separate child to sleep -- a fork there would let the lock survive
# `kill`ing the wrapper alone, since the child would inherit a duplicate of
# the same locked open file description. Using `exec` twice in the same
# backgrounded subshell means the PID this function returns is the literal
# process holding the lock: killing exactly that PID always releases it
# immediately, with no orphaned child left holding it behind.
validation_subnet_try_lock() {
    local lock_root="$1" octet="$2"
    local lock_file="$lock_root/${octet}.lock"
    local holder_pid

    mkdir -p "$lock_root"

    (
        exec 9>"$lock_file"
        flock -n 9 || exit 1
        exec sleep infinity
    ) &
    holder_pid=$!

    # Give the backgrounded subshell time to either acquire the lock and
    # reach `exec sleep infinity`, or fail `flock -n` and exit -- both
    # settle well within this margin in practice. This is the same
    # probe-after-a-brief-sleep technique this project's other CI scripts
    # already use to confirm a backgrounded process is genuinely still
    # running (e.g. health-check polling loops), applied here to a
    # near-instant flock attempt instead of a slow-starting service.
    sleep 0.3

    if kill -0 "$holder_pid" 2>/dev/null; then
        printf '%s\n' "$holder_pid"
        return 0
    fi

    wait "$holder_pid" 2>/dev/null || true
    return 1
}

# validation_subnet_release <holder_pid>
# Releases a lock previously acquired by validation_subnet_try_lock by
# killing its holder process. Safe to call with an empty/unset argument (no
# lock was ever held) or a PID that's already gone (e.g. the runner already
# tore down this job's process tree on cancellation) -- both are silent
# no-ops.
validation_subnet_release() {
    local holder_pid="${1:-}"
    [[ -n "$holder_pid" ]] || return 0
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
}

# validation_subnet_reserve <lock_root> <run_id> <run_attempt> <start_attempt> <max_attempts>
# Tries attempt numbers from <start_attempt> up to <max_attempts> (inclusive),
# deriving each one's candidate octet via validation_subnet_seed_for_attempt
# + validation_subnet_derive_octet and attempting to lock it via
# validation_subnet_try_lock. On the first attempt number whose octet locks
# successfully, prints three lines -- "attempt=<n>", "octet=<n>",
# "holder_pid=<n>" -- and returns 0. If every attempt number in the range is
# already locked by another concurrent run, prints nothing and returns 1.
#
# This function only arbitrates HOST-LOCAL LOCK contention -- it has no
# Docker dependency at all, deliberately, so it can be unit tested without a
# Docker daemon. A caller that also needs to validate the candidate against
# Docker's own network state or an actual `docker compose up` failure (see
# the workflow step that calls this) should call validation_subnet_release
# on a reservation that fails its own check, then call this function again
# with start_attempt set one past the attempt number that just failed -- so
# a subsequent call never re-tries (and re-fails identically on) the same
# already-rejected candidate.
validation_subnet_reserve() {
    local lock_root="$1" run_id="$2" run_attempt="$3" start_attempt="$4" max_attempts="$5"
    local attempt seed octet holder_pid

    for (( attempt = start_attempt; attempt <= max_attempts; attempt++ )); do
        seed="$(validation_subnet_seed_for_attempt "$run_id" "$run_attempt" "$attempt")"
        octet="$(validation_subnet_derive_octet "$seed")"

        if holder_pid="$(validation_subnet_try_lock "$lock_root" "$octet")"; then
            printf 'attempt=%s\noctet=%s\nholder_pid=%s\n' "$attempt" "$octet" "$holder_pid"
            return 0
        fi
    done

    return 1
}
