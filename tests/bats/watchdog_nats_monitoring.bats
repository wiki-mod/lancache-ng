#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for #842: services/watchdog/watchdog.sh now polls and
# auto-restarts `nats` (via C_NATS/CONTAINER_NATS) the same way it already
# did for proxy/dns-standard/dns-ssl. This file proves two things the
# existing watchdog_idempotence.bats / watchdog_config_validation.bats
# suites don't already cover for this specific container:
#
#   1. check_and_maybe_restart() actually fires a restart for nats after
#      RESTART_AFTER consecutive "unhealthy" reads, exactly like it already
#      does for lancache-proxy -- proving the new main-loop wiring, not just
#      that the (container-agnostic) function itself works.
#   2. write_status()'s nats entry is unconditional, unlike the SSL-gated
#      dns-ssl entry -- it must appear regardless of SSL_ENABLED, since the
#      nats compose service has no profile/flag gate at all.
#
# Uses the same sourced-function + stubbed-boundary pattern as
# watchdog_idempotence.bats (see that file's own header comment for the
# full rationale): get_health()/restart_container() are redefined after
# sourcing, everything else is the real, unmodified watchdog.sh code.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/watchdog-helpers-extracted.sh"
    status_file="$BATS_TEST_TMPDIR/status.json"

    export SSL_ENABLED=0
    export CACHE_DIR="$BATS_TEST_TMPDIR"
    export STATUS_FILE="$status_file"

    # shellcheck source=tests/bats/helpers/watchdog-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/watchdog-helpers.sh"
    load_watchdog_functions "$repo_root" "$helper_file"

    health_queue=()
    health_cursor=0
    get_health() {
        printf '%s\n' "${health_queue[$health_cursor]}"
    }

    restart_calls=()
    restart_container() {
        restart_calls+=("$1")
    }

    F_NATS=0
    H_NATS="unknown"
}

drive_nats_health_sequence() {
    health_queue=("$@")
    health_cursor=0
    while [ "$health_cursor" -lt "${#health_queue[@]}" ]; do
        check_and_maybe_restart "$C_NATS" F_NATS H_NATS
        health_cursor=$((health_cursor + 1))
    done
}

@test "C_NATS defaults to lancache-nats" {
    [ "$C_NATS" = "lancache-nats" ]
}

@test "check_and_maybe_restart restarts nats after RESTART_AFTER consecutive unhealthy reads" {
    local i seq=()
    for ((i = 0; i < RESTART_AFTER; i++)); do
        seq+=("unhealthy")
    done
    drive_nats_health_sequence "${seq[@]}"

    [ "${#restart_calls[@]}" -eq 1 ]
    [ "${restart_calls[0]}" = "lancache-nats" ]
    [ "$F_NATS" -eq 0 ]
}

@test "check_and_maybe_restart does not restart nats on a near-miss unhealthy streak" {
    drive_nats_health_sequence unhealthy unhealthy healthy
    [ "${#restart_calls[@]}" -eq 0 ]
    [ "$F_NATS" -eq 0 ]
    [ "$H_NATS" = "healthy" ]
}

# The load-bearing assertion for #842's specific design decision: nats has
# no SSL_ENABLED-style gate, so its status.json entry must appear whether or
# not SSL mode is active -- unlike dns-ssl, which only appears when
# SSL_ENABLED=1 (see watchdog_idempotence.bats's dedicated SSL test).
@test "write_status includes an unconditional nats block regardless of SSL_ENABLED" {
    H_NATS="healthy"
    write_status
    run jq -e '.services["lancache-nats"] == {"status":"green","health":"healthy","failures":0}' "$status_file"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]

    export SSL_ENABLED=1
    # shellcheck disable=SC2034 # read by write_status() (sourced from
    # services/watchdog/watchdog.sh) -- cross-file dynamic-scope read.
    export C_DNS_SSL="lancache-dns-ssl"
    F_DNS_SSL=0
    H_DNS_SSL="healthy"
    write_status
    run jq -e '.services["lancache-nats"] == {"status":"green","health":"healthy","failures":0}' "$status_file"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
    # dns-ssl now also appears -- confirms the two gates are independent of
    # each other, not that nats accidentally piggybacked on the SSL branch.
    run jq -e '.services["lancache-dns-ssl"]' "$status_file"
    [ "$status" -eq 0 ]
}
