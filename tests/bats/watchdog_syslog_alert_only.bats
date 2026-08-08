#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
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
# gated on LOGGING_ENABLED the same way SSL_ENABLED gates C_DNS_SSL
# monitoring -- NOT on SYSLOG_ENABLED, a deliberately separate, narrower
# flag that only gates the storage-budget retention/pruning engine (see
# deploy/prod/.env's own comment on it and watchdog.sh's C_SYSLOG
# assignment for the full reasoning this file's own tests below prove).
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
    # C_SYSLOG is resolved once at source time from LOGGING_ENABLED (mirrors
    # C_DNS_SSL's own SSL_ENABLED-gated resolution) -- must be exported
    # before load_watchdog_functions sources the extracted range below.
    export LOGGING_ENABLED=1

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

@test "C_SYSLOG resolves to lancache-syslog when LOGGING_ENABLED is truthy" {
    [ "$C_SYSLOG" = "lancache-syslog" ]
}

@test "C_SYSLOG is empty when LOGGING_ENABLED is unset (no logging profile opted into)" {
    unset LOGGING_ENABLED
    load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-unset.sh"
    [ -z "$C_SYSLOG" ]
}

@test "C_SYSLOG is empty for every falsy LOGGING_ENABLED spelling" {
    for value in false 0 no off ""; do
        LOGGING_ENABLED="$value" load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-falsy-$RANDOM.sh"
        [ -z "$C_SYSLOG" ] || {
            echo "LOGGING_ENABLED=$value unexpectedly resolved C_SYSLOG=$C_SYSLOG" >&2
            return 1
        }
    done
}

@test "C_SYSLOG resolves for every truthy LOGGING_ENABLED spelling" {
    for value in 1 true TRUE yes On; do
        LOGGING_ENABLED="$value" load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-truthy-$RANDOM.sh"
        [ "$C_SYSLOG" = "lancache-syslog" ] || {
            echo "LOGGING_ENABLED=$value did not resolve C_SYSLOG to lancache-syslog (got '$C_SYSLOG')" >&2
            return 1
        }
    done
}

@test "C_SYSLOG stays empty when LOGGING_ENABLED is truthy but SYSLOG_ENABLED is falsy (the real Codex finding)" {
    # Real bug this test guards against: LOGGING_ENABLED and SYSLOG_ENABLED
    # are deliberately separate flags (see this file's header and
    # watchdog.sh's own C_SYSLOG comment) -- a normal install with central
    # logging on but retention/pruning never separately opted into runs the
    # syslog container with SYSLOG_ENABLED left at its default "false".
    # C_SYSLOG must resolve purely from LOGGING_ENABLED and must not be
    # affected by SYSLOG_ENABLED's own value either way.
    LOGGING_ENABLED=1 SYSLOG_ENABLED=false \
        load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-logging-only.sh"
    [ "$C_SYSLOG" = "lancache-syslog" ] || {
        echo "expected C_SYSLOG=lancache-syslog with LOGGING_ENABLED=1/SYSLOG_ENABLED=false, got '$C_SYSLOG'" >&2
        return 1
    }
}

@test "C_SYSLOG carries LANCACHE_CONTAINER_SUFFIX when one is set (issue #1415 coordinated-suffix shape)" {
    # Real bug this test guards against: deploy/quickstart/docker-compose.yml
    # and the syslog-forwarding simulation both name this container
    # lancache-syslog${LANCACHE_CONTAINER_SUFFIX:-}, and
    # scripts/docker-socket-proxy.sh's own generated HAProxy allowlist
    # rewrites its lancache-syslog ACL entry with the identical suffix at
    # startup -- C_SYSLOG must match, or every watchdog inspect request in
    # a suffixed deployment targets a container that does not exist.
    # The FATAL guards further down this file's own sourced range require a
    # COORDINATED suffix -- every CONTAINER_* override must carry the same
    # suffix as LANCACHE_CONTAINER_SUFFIX itself, or this correctly refuses
    # to start (see EXPECTED_PROXY/etc. and their own FATAL checks). Setting
    # only LANCACHE_CONTAINER_SUFFIX without the matching CONTAINER_*
    # overrides is the mismatched-suffix case those guards exist to reject,
    # not the scenario this test is exercising.
    LANCACHE_CONTAINER_SUFFIX="ci7x9q" \
    CONTAINER_PROXY="lancache-proxyci7x9q" \
    CONTAINER_DNS_STANDARD="lancache-dns-standardci7x9q" \
    CONTAINER_NATS="lancache-natsci7x9q" \
    load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-suffix.sh"
    [ "$C_SYSLOG" = "lancache-syslogci7x9q" ] || {
        echo "expected C_SYSLOG=lancache-syslogci7x9q, got '$C_SYSLOG'" >&2
        return 1
    }
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

@test "check_alert_only treats 'unreachable' as a failure, the same as 'unhealthy'" {
    # Real bug this test guards against: get_health() returns "unreachable"
    # (not "unhealthy") when the container is absent, unresponsive, or the
    # docker-socket-proxy call itself fails -- exactly the "enabled but not
    # actually running" outage this alert-only monitoring exists to
    # surface. An earlier version of check_alert_only() only matched the
    # literal string "unhealthy", silently ignoring this case entirely: no
    # failure-counter increment, no UNHEALTHY log line, ever.
    get_health() { printf 'unreachable\n'; }

    check_alert_only "$C_SYSLOG" F_SYSLOG H_SYSLOG
    [ "$H_SYSLOG" = "unreachable" ]
    [ "$F_SYSLOG" -eq 1 ] || {
        echo "expected F_SYSLOG=1 after one 'unreachable' reading, got $F_SYSLOG" >&2
        return 1
    }
}

@test "check_alert_only still treats 'starting' and 'none' as non-failures, not just 'healthy'" {
    # 'starting' (Docker's own healthcheck grace period) and 'none' (no
    # healthcheck configured/reported yet) are normal transient states, not
    # outages -- the 'unreachable' fix above must not overreach into
    # flagging these too.
    for state in starting none; do
        F_SYSLOG=0
        get_health() { printf '%s\n' "$state"; }
        check_alert_only "$C_SYSLOG" F_SYSLOG H_SYSLOG
        [ "$F_SYSLOG" -eq 0 ] || {
            echo "health=$state unexpectedly incremented the failure counter to $F_SYSLOG" >&2
            return 1
        }
    done
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

@test "write_status includes the syslog block when LOGGING_ENABLED is truthy" {
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
@test "write_status omits the syslog block entirely when LOGGING_ENABLED is falsy" {
    unset LOGGING_ENABLED
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
