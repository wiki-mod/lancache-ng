#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Repeat-cycle convergence tests for services/watchdog/watchdog.sh's stateful
# functions: check_and_maybe_restart() (per-container failure counter +
# restart trigger) and write_status() (atomic dashboard status JSON writer).
#
# The #456 audit reviewed this file and concluded the design "looks
# convergent/idempotent by construction" (the failure counter resets after a
# restart, and write_status uses a .tmp + rename) but found no fixture or
# simulation test actually proving that repeated unhealthy/healthy cycles
# converge to the same restart/status behavior every time, rather than e.g.
# an ever-incrementing counter that never resets, or a restart threshold that
# silently drifts across cycles. This file closes that gap: it sources the
# real functions from watchdog.sh (not a reimplementation) via
# helpers/watchdog-helpers.sh, drives them through realistic multi-cycle
# health sequences, and asserts the counter/restart/status behavior on a
# second identical cycle is indistinguishable from the first.
#
# get_health() and restart_container() are the only two functions redefined
# after sourcing (see setup() below) -- both are pure I/O boundaries in the
# real script (a curl call to the Docker socket proxy), not stateful logic
# under test here, matching the project's existing pattern of stubbing
# boundary calls (e.g. die()/print_ok() in setup-update-helpers.sh) while
# sourcing the real stateful function bodies unmodified.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/watchdog-helpers-extracted.sh"
    status_file="$BATS_TEST_TMPDIR/status.json"

    # SSL_ENABLED=0 keeps every cycle test focused on a single monitored
    # container (C_PROXY) instead of also juggling the conditional DNS-SSL
    # branch; write_status's SSL-enabled branch gets its own dedicated test
    # below instead.
    export SSL_ENABLED=0
    export CACHE_DIR="$BATS_TEST_TMPDIR"
    export STATUS_FILE="$status_file"

    # shellcheck source=tests/bats/helpers/watchdog-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/watchdog-helpers.sh"
    load_watchdog_functions "$repo_root" "$helper_file"

    # Deterministic health-check stand-in: get_health() normally curls the
    # Docker socket proxy's health endpoint. Tests drive a scripted sequence
    # of health values through health_queue, read one per call based on
    # health_cursor. get_health() itself must NOT advance health_cursor: the
    # real check_and_maybe_restart() invokes it via command substitution
    # (`health=$(get_health "$name")`), which forks a subshell -- any
    # mutation of a shell variable inside get_health would be discarded when
    # that subshell exits. drive_health_sequence() (below) advances the
    # cursor itself, in the parent shell, after each call.
    health_queue=()
    health_cursor=0
    get_health() {
        printf '%s\n' "${health_queue[$health_cursor]}"
    }

    # restart_container() normally POSTs to the Docker socket proxy. Tests
    # only need to know how many times and for which container it fired.
    restart_calls=()
    restart_container() {
        restart_calls+=("$1")
    }

    F_PROXY=0
    H_PROXY="unknown"
}

# Feeds an explicit ordered list of health values through the real
# check_and_maybe_restart(), one per call, advancing health_cursor in this
# (parent) shell after each call -- see the health_cursor comment in setup()
# for why the cursor cannot be advanced inside get_health() itself.
drive_health_sequence() {
    health_queue=("$@")
    health_cursor=0
    while [ "$health_cursor" -lt "${#health_queue[@]}" ]; do
        check_and_maybe_restart "lancache-proxy" F_PROXY H_PROXY
        health_cursor=$((health_cursor + 1))
    done
}

# Drives one unhealthy/restart/healthy cycle (the shape check_and_maybe_restart
# is actually built around: RESTART_AFTER consecutive "unhealthy" results
# trigger exactly one restart and reset the counter, then a "healthy" result
# confirms recovery) through the real, sourced function.
run_one_cycle() {
    local i seq=()
    for ((i = 0; i < RESTART_AFTER; i++)); do
        seq+=("unhealthy")
    done
    seq+=("healthy")
    drive_health_sequence "${seq[@]}"
}

# This is the core convergence guarantee the #456 audit flagged as unproven:
# if the failure counter did NOT reset after triggering a restart (or reset
# to the wrong value), a second identical unhealthy/healthy cycle would
# either restart on a different failure count than the first cycle, restart
# more than once per cycle, or never restart again -- any of which would be a
# real operational bug (e.g. a container stuck unhealthy forever without ever
# getting restarted again after its first recovery-restart).
@test "check_and_maybe_restart restarts exactly once per unhealthy cycle and resets identically across repeated cycles" {
    run_one_cycle
    [ "${#restart_calls[@]}" -eq 1 ]
    [ "${restart_calls[0]}" = "lancache-proxy" ]
    [ "$F_PROXY" -eq 0 ]
    [ "$H_PROXY" = "healthy" ]

    # Second, identical cycle from the same post-recovery state (F_PROXY=0)
    # must behave exactly like the first: one more restart call, counter back
    # to 0. A driftier implementation (e.g. a counter that failed to fully
    # reset, or that kept accumulating across restarts) would either restart
    # early/late here or fail to restart at all.
    run_one_cycle
    [ "${#restart_calls[@]}" -eq 2 ]
    [ "${restart_calls[1]}" = "lancache-proxy" ]
    [ "$F_PROXY" -eq 0 ]
    [ "$H_PROXY" = "healthy" ]

    # A third cycle proves the second run's convergence wasn't a coincidence.
    run_one_cycle
    [ "${#restart_calls[@]}" -eq 3 ]
    [ "$F_PROXY" -eq 0 ]
}

# Complements the full-cycle test above: recovering *before* hitting
# RESTART_AFTER must reset the counter without ever calling
# restart_container, and this near-miss behavior must repeat identically
# every time it happens -- a bug where a near-miss counter silently carried
# over into the next cycle would eventually cause a spurious restart after
# only one or two real failures instead of a full RESTART_AFTER streak.
@test "check_and_maybe_restart resets on early recovery without restarting, identically across repeated near-miss cycles" {
    drive_health_sequence unhealthy unhealthy healthy
    [ "${#restart_calls[@]}" -eq 0 ]
    [ "$F_PROXY" -eq 0 ]

    # Repeat the exact same near-miss shape. If the counter had leaked
    # anything from the first near-miss cycle, this second cycle would reach
    # RESTART_AFTER (3) with only 2 fresh failures plus 1 leftover, triggering
    # a restart that must not happen.
    drive_health_sequence unhealthy unhealthy healthy
    [ "${#restart_calls[@]}" -eq 0 ]
    [ "$F_PROXY" -eq 0 ]
}

# write_status is documented (in watchdog.sh's own comment) as writing
# atomically via a .tmp file + rename specifically so a concurrent reader
# never observes a half-written file. This test proves both halves of that
# claim hold across repeated writes: no .tmp file is ever left behind, and
# the JSON emitted for an unchanged input state is structurally identical
# run to run (only the "updated" timestamp field is expected to differ) --
# not just "some JSON came out," which would miss a bug where repeated writes
# drift (e.g. a stale failure count from a previous call leaking through).
@test "write_status converges to structurally identical JSON across repeated writes of unchanged state" {
    F_PROXY=0
    H_PROXY="healthy"

    write_status
    [ -f "$status_file" ]
    [ ! -f "${status_file}.tmp" ]
    run jq empty "$status_file"
    [ "$status" -eq 0 ]
    first_without_ts=$(jq 'del(.updated)' "$status_file")

    write_status
    [ ! -f "${status_file}.tmp" ]
    run jq empty "$status_file"
    [ "$status" -eq 0 ]
    second_without_ts=$(jq 'del(.updated)' "$status_file")

    [ "$first_without_ts" = "$second_without_ts" ]

    run jq -e '.services["lancache-proxy"].health == "healthy"' "$status_file"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
    run jq -e '.services["lancache-proxy"].failures == 0' "$status_file"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

# write_status's SSL-enabled branch (services/watchdog/watchdog.sh's
# `ssl_services` fragment) is only exercised when SSL_ENABLED=1, unlike every
# other test in this file which fixes SSL_ENABLED=0 in setup(). A drift bug
# specific to that branch (e.g. the DNS-SSL block appearing once but not
# reappearing identically on a second write) would not be caught by the
# SSL-disabled test above.
@test "write_status with SSL enabled includes a stable DNS-SSL block across repeated writes" {
    export SSL_ENABLED=1
    export C_DNS_SSL="lancache-dns-ssl"
    F_DNS_SSL=0
    H_DNS_SSL="healthy"

    write_status
    run jq empty "$status_file"
    [ "$status" -eq 0 ]
    first_without_ts=$(jq 'del(.updated)' "$status_file")
    run jq -e '.services["lancache-dns-ssl"]' "$status_file"
    [ "$status" -eq 0 ]

    write_status
    second_without_ts=$(jq 'del(.updated)' "$status_file")
    [ "$first_without_ts" = "$second_without_ts" ]
}

# End-to-end convergence across the full monitor+status pipeline: two
# consecutive unhealthy/restart/healthy cycles (see run_one_cycle above) must
# each leave the on-disk status JSON in the same converged shape --
# "healthy" with zero failures -- rather than accumulating stale failure
# counts from a previous cycle into the persisted status file an operator or
# the Admin UI dashboard would actually read.
@test "status file converges to the same healthy/zero-failure state after repeated restart cycles" {
    run_one_cycle
    write_status
    run jq -e '.services["lancache-proxy"] == {"status":"green","health":"healthy","failures":0}' "$status_file"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]

    run_one_cycle
    write_status
    run jq -e '.services["lancache-proxy"] == {"status":"green","health":"healthy","failures":0}' "$status_file"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]

    [ "${#restart_calls[@]}" -eq 2 ]
}
