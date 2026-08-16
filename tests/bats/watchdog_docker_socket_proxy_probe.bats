#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for issue #1170 Part 1: services/watchdog/watchdog.sh's new
# probe_docker_socket_proxy() function, an alert-only detector for a hung
# (process alive, HAProxy unresponsive) docker-socket-proxy. Absent this
# probe, nothing in the stack could detect that failure mode -- watchdog's
# only restart channel goes THROUGH docker-socket-proxy, so it structurally
# cannot restart docker-socket-proxy itself, and there was no probe of any
# kind against it either.
#
# This file proves the three properties that matter for an alert-only
# detector specifically (as opposed to check_and_maybe_restart()'s
# restart-capable services, already covered by watchdog_idempotence.bats/
# watchdog_nats_monitoring.bats):
#
#   1. It uses the already-allowlisted GET /_ping endpoint with the same
#      --max-time budget as every other Docker-proxy call in this file (zero
#      new privilege, matching watchdog_curl_timeout.bats's coverage style
#      for get_health()/restart_container()).
#   2. It NEVER triggers a restart, regardless of how many consecutive
#      failures accumulate -- this is the load-bearing difference from
#      check_and_maybe_restart(), and the entire point of #1170 Part 1 vs.
#      Part 2 (self-healing, not implemented here).
#   3. write_status() surfaces its result as an unconditional services map
#      entry (not SSL-gated, like C_NATS), so the Admin UI dashboard renders
#      it via the existing generic per-service loop with no UI code changes.
#
# Uses the same sourced-function + stubbed-curl-boundary pattern as
# watchdog_curl_timeout.bats: curl itself is stubbed (not
# probe_docker_socket_proxy() or a higher-level helper), so the real function
# body -- including which curl flags/URL it uses -- is what's under test.

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

    curl_calls_file="$BATS_TEST_TMPDIR/curl-calls.txt"
    : > "$curl_calls_file"

    restart_calls=()
    restart_container() {
        restart_calls+=("$1")
    }

    F_DOCKER_PROXY=0
    H_DOCKER_PROXY="unknown"
}

@test "C_DOCKER_PROXY defaults to lancache-docker-socket-proxy" {
    [ "$C_DOCKER_PROXY" = "lancache-docker-socket-proxy" ]
}

@test "probe_docker_socket_proxy hits GET /_ping with --max-time, not a /containers/... path" {
    curl() {
        printf '%s\n' "$*" >> "$curl_calls_file"
        return 0
    }

    probe_docker_socket_proxy F_DOCKER_PROXY H_DOCKER_PROXY
    run cat "$curl_calls_file"
    [[ "$output" == *"--max-time"* ]]
    [[ "$output" == *"/_ping"* ]]
    [[ "$output" != *"/containers/"* ]]
}

@test "probe_docker_socket_proxy reports healthy and resets the failure counter on success" {
    curl() { return 0; }

    F_DOCKER_PROXY=2
    probe_docker_socket_proxy F_DOCKER_PROXY H_DOCKER_PROXY
    [ "$H_DOCKER_PROXY" = "healthy" ]
    [ "$F_DOCKER_PROXY" -eq 0 ]
}

@test "probe_docker_socket_proxy reports unhealthy and increments the failure counter on curl failure" {
    curl() { return 1; }

    probe_docker_socket_proxy F_DOCKER_PROXY H_DOCKER_PROXY
    [ "$H_DOCKER_PROXY" = "unhealthy" ]
    [ "$F_DOCKER_PROXY" -eq 1 ]

    probe_docker_socket_proxy F_DOCKER_PROXY H_DOCKER_PROXY
    [ "$F_DOCKER_PROXY" -eq 2 ]
}

# The load-bearing behavioral guarantee of this whole issue: unlike every
# monitored service in check_and_maybe_restart(), this probe must never call
# restart_container(), no matter how many consecutive failures accumulate --
# watchdog's restart channel goes through docker-socket-proxy itself, so
# attempting a restart here would be the exact circular dependency #1170
# documents. RESTART_AFTER (default 3) is used here specifically to prove
# that even crossing that threshold changes nothing for this probe.
@test "probe_docker_socket_proxy never calls restart_container, even after many consecutive failures" {
    curl() { return 1; }

    local i
    for ((i = 0; i < RESTART_AFTER + 5; i++)); do
        probe_docker_socket_proxy F_DOCKER_PROXY H_DOCKER_PROXY
    done

    [ "$F_DOCKER_PROXY" -eq $((RESTART_AFTER + 5)) ]
    [ "${#restart_calls[@]}" -eq 0 ]
}

# Unlike check_and_maybe_restart()'s services (whose counter resets to 0 once
# RESTART_AFTER triggers an actual restart), this probe has no restart to
# reset the counter -- it must keep climbing indefinitely while unhealthy,
# since that count is itself the only operator-visible signal of how long
# docker-socket-proxy has been unreachable.
@test "probe_docker_socket_proxy's failure counter does not cap or reset at RESTART_AFTER" {
    curl() { return 1; }

    local i
    for ((i = 0; i < RESTART_AFTER; i++)); do
        probe_docker_socket_proxy F_DOCKER_PROXY H_DOCKER_PROXY
    done
    [ "$F_DOCKER_PROXY" -eq "$RESTART_AFTER" ]

    probe_docker_socket_proxy F_DOCKER_PROXY H_DOCKER_PROXY
    [ "$F_DOCKER_PROXY" -eq $((RESTART_AFTER + 1)) ]
}

# write_status's docker-socket-proxy entry must be unconditional (same shape
# as the C_NATS coverage in watchdog_nats_monitoring.bats), since the probe
# always runs regardless of SSL_ENABLED -- there is no profile/flag gate on
# docker-socket-proxy itself.
@test "write_status includes an unconditional docker-socket-proxy block, mapped unhealthy to red" {
    H_DOCKER_PROXY="unhealthy"
    F_DOCKER_PROXY=4
    write_status
    run jq -e '.services["lancache-docker-socket-proxy"] == {"status":"red","health":"unhealthy","failures":4}' "$status_file"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]

    export SSL_ENABLED=1
    # shellcheck disable=SC2034 # read by write_status() via cross-file
    # dynamic scope, same pattern as watchdog_idempotence.bats's SSL test.
    export C_DNS_SSL="lancache-dns-ssl"
    # shellcheck disable=SC2034 # see comment above
    F_DNS_SSL=0
    # shellcheck disable=SC2034 # see comment above
    H_DNS_SSL="healthy"
    write_status
    run jq -e '.services["lancache-docker-socket-proxy"] == {"status":"red","health":"unhealthy","failures":4}' "$status_file"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "write_status maps a healthy docker-socket-proxy probe to green with zero failures" {
    H_DOCKER_PROXY="healthy"
    F_DOCKER_PROXY=0
    write_status
    run jq -e '.services["lancache-docker-socket-proxy"] == {"status":"green","health":"healthy","failures":0}' "$status_file"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}
