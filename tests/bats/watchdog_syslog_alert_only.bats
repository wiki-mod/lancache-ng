#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for #849 bug-hunt finding observability.md#8: services/watchdog/
# watchdog.sh's syslog-ng healthcheck (part of the combined syslog+fluent-bit
# container's own dual-process HEALTHCHECK) was real but orphaned -- nothing
# in the stack consumed it (no autoheal, and watchdog.sh's own
# check_and_maybe_restart() loop only ever monitored three hardcoded
# containers). This adds alert-only monitoring (never restart-capable --
# scripts/docker-socket-proxy.sh's safe_service_restart ACL does not permit
# a restart POST for this container, see check_alert_only()'s own comment),
# gated on SYSLOG_ENABLED the same way SSL_ENABLED gates C_DNS_SSL monitoring.
#
# Mirrors watchdog_docker_socket_proxy_probe.bats's structure closely, since
# check_alert_only() is the generalized form of that file's
# probe_docker_socket_proxy() for a per-container Docker-API health check
# rather than a bare /_ping reachability probe.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/watchdog-helpers-extracted.sh"
    status_file="$BATS_TEST_TMPDIR/status.json"

    export SSL_ENABLED=0
    export CACHE_DIR="$BATS_TEST_TMPDIR"
    export STATUS_FILE="$status_file"
    # C_SYSLOG is resolved once at source time from SYSLOG_ENABLED (mirrors
    # C_DNS_SSL's own SSL_ENABLED-gated resolution) -- must be exported
    # before load_watchdog_functions sources the extracted range below.
    export SYSLOG_ENABLED=true

    # shellcheck source=tests/bats/helpers/watchdog-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/watchdog-helpers.sh"
    load_watchdog_functions "$repo_root" "$helper_file"

    restart_calls=()
    restart_container() {
        restart_calls+=("$1")
    }

    F_SYSLOG=0
    H_SYSLOG="unknown"
}

@test "C_SYSLOG resolves to lancache-syslog when SYSLOG_ENABLED is truthy" {
    [ "$C_SYSLOG" = "lancache-syslog" ]
}

@test "C_SYSLOG is empty when SYSLOG_ENABLED is unset (no logging profile opted into)" {
    unset SYSLOG_ENABLED
    load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-unset.sh"
    [ -z "$C_SYSLOG" ]
}

@test "C_SYSLOG is empty for every Admin-UI-falsy SYSLOG_ENABLED spelling" {
    for value in false 0 no off ""; do
        SYSLOG_ENABLED="$value" load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-falsy-$RANDOM.sh"
        [ -z "$C_SYSLOG" ] || {
            echo "SYSLOG_ENABLED=$value unexpectedly resolved C_SYSLOG=$C_SYSLOG" >&2
            return 1
        }
    done
}

@test "C_SYSLOG resolves for every Admin-UI-truthy SYSLOG_ENABLED spelling" {
    for value in 1 true TRUE yes On; do
        SYSLOG_ENABLED="$value" load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-truthy-$RANDOM.sh"
        [ "$C_SYSLOG" = "lancache-syslog" ] || {
            echo "SYSLOG_ENABLED=$value did not resolve C_SYSLOG to lancache-syslog (got '$C_SYSLOG')" >&2
            return 1
        }
    done
}

@test "check_alert_only reports healthy and resets the failure counter on success" {
    get_health() { printf 'healthy\n'; }

    F_SYSLOG=2
    check_alert_only "$C_SYSLOG" F_SYSLOG H_SYSLOG
    [ "$H_SYSLOG" = "healthy" ]
    [ "$F_SYSLOG" -eq 0 ]
}

@test "check_alert_only reports unhealthy and increments the failure counter, never calling restart_container" {
    get_health() { printf 'unhealthy\n'; }

    local i
    for ((i = 0; i < RESTART_AFTER + 5; i++)); do
        check_alert_only "$C_SYSLOG" F_SYSLOG H_SYSLOG
    done

    [ "$H_SYSLOG" = "unhealthy" ]
    [ "$F_SYSLOG" -eq $((RESTART_AFTER + 5)) ]
    [ "${#restart_calls[@]}" -eq 0 ]
}

@test "check_alert_only's failure counter does not cap or reset at RESTART_AFTER" {
    get_health() { printf 'unhealthy\n'; }

    local i
    for ((i = 0; i < RESTART_AFTER; i++)); do
        check_alert_only "$C_SYSLOG" F_SYSLOG H_SYSLOG
    done
    [ "$F_SYSLOG" -eq "$RESTART_AFTER" ]

    check_alert_only "$C_SYSLOG" F_SYSLOG H_SYSLOG
    [ "$F_SYSLOG" -eq $((RESTART_AFTER + 1)) ]
}

@test "write_status includes the syslog block when SYSLOG_ENABLED is truthy" {
    H_SYSLOG="unhealthy"
    F_SYSLOG=3
    write_status
    run jq -e '.services["lancache-syslog"] == {"status":"red","health":"unhealthy","failures":3}' "$status_file"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

# The dashboard must never show a permanently "unhealthy"/never-existed
# container for an install that never opted into the logging profile in the
# first place -- omitted entirely, not merely zeroed out, mirrors how
# ssl_services is omitted (not emitted with dummy values) when SSL_ENABLED
# is falsy.
@test "write_status omits the syslog block entirely when SYSLOG_ENABLED is falsy" {
    unset SYSLOG_ENABLED
    load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-omit.sh"
    [ -z "$C_SYSLOG" ]

    write_status
    # `jq -e` exits 1 (not 0) whenever the filter's own output is `false` or
    # `null` -- that is the entire point of `-e`, so a genuinely-absent key
    # (has() itself evaluating to false, asserted via $output below) must be
    # paired with status 1 here, not 0.
    run jq -e '.services | has("lancache-syslog")' "$status_file"
    [ "$status" -eq 1 ]
    [ "$output" = "false" ]
}
