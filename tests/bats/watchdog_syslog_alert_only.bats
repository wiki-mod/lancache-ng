#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for alert-only monitoring of the combined syslog and fluent-bit
# container. Its own dual-process Docker HEALTHCHECK proves both processes,
# while watchdog consumes that health state without ever making the service
# restart-capable. LOGGING_ENABLED controls whether this optional container
# exists; SYSLOG_ENABLED is deliberately narrower and only gates the storage
# retention/pruning engine, so it must not control health monitoring.
#
# The helper-level tests mirror the Docker proxy alert probe's structure while
# exercising the generalized per-container health path used by syslog.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/watchdog-helpers-extracted.sh"
    status_file="$BATS_TEST_TMPDIR/status.json"

    export SSL_ENABLED=0
    export CACHE_DIR="$BATS_TEST_TMPDIR"
    export STATUS_FILE="$status_file"
    # C_SYSLOG is resolved once at source time from LOGGING_ENABLED, so the
    # gate must be exported before the helper range is sourced below.
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

@test "C_SYSLOG stays non-empty when LOGGING_ENABLED is truthy but SYSLOG_ENABLED is falsy" {
    # A normal deployment may enable central logging while leaving the
    # independent retention/pruning opt-in disabled. Health monitoring must
    # therefore derive solely from LOGGING_ENABLED.
    LOGGING_ENABLED=1 SYSLOG_ENABLED=false \
        load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-logging-only.sh"
    [ "$C_SYSLOG" = "lancache-syslog" ] || {
        echo "expected C_SYSLOG=lancache-syslog with LOGGING_ENABLED=1/SYSLOG_ENABLED=false, got '$C_SYSLOG'" >&2
        return 1
    }
}

@test "C_SYSLOG carries LANCACHE_CONTAINER_SUFFIX when one is set (issue #1415 coordinated-suffix shape)" {
    # Isolated validation stacks suffix every coordinated container name and
    # the Docker proxy allowlist with the same value. C_SYSLOG must match that
    # contract or watchdog would inspect a container name that does not exist.
    # The FATAL guards in watchdog.sh require every explicit CONTAINER_* name
    # to carry the same suffix, so this fixture supplies the coordinated set.
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
    # get_health() reports "unreachable" when the container is absent,
    # unresponsive, or the Docker proxy request fails. That is a real outage
    # for an enabled alert-only service and must increment the same counter as
    # Docker's explicit "unhealthy" state.
    get_health() { printf 'unreachable\n'; }

    check_alert_only "$C_SYSLOG" F_SYSLOG H_SYSLOG
    [ "$H_SYSLOG" = "unreachable" ]
    [ "$F_SYSLOG" -eq 1 ] || {
        echo "expected F_SYSLOG=1 after one 'unreachable' reading, got $F_SYSLOG" >&2
        return 1
    }
}

@test "check_alert_only still treats 'starting' and 'none' as non-failures, not just 'healthy'" {
    # Docker's starting grace period and a service without a reported health
    # state are not failures. Treating them as outages would create false alerts.
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

@test "check_alert_only resets the failure counter on an intervening 'starting'/'none' reading, not only 'healthy'" {
    # A consecutive-failure counter must reset on every non-failure reading.
    # Otherwise unhealthy -> starting -> unhealthy would be counted as two
    # consecutive failures even though the observations are not consecutive.
    # This matches the Rust AlertCounter::record() is_alert_ok() semantics.
    for intervening in starting none; do
        F_SYSLOG=0
        get_health() { printf 'unhealthy\n'; }
        check_alert_only "$C_SYSLOG" F_SYSLOG H_SYSLOG
        [ "$F_SYSLOG" -eq 1 ]

        get_health() { printf '%s\n' "$intervening"; }
        check_alert_only "$C_SYSLOG" F_SYSLOG H_SYSLOG
        [ "$F_SYSLOG" -eq 0 ] || {
            echo "intervening health=$intervening did not reset F_SYSLOG (got $F_SYSLOG)" >&2
            return 1
        }

        get_health() { printf 'unhealthy\n'; }
        check_alert_only "$C_SYSLOG" F_SYSLOG H_SYSLOG
        [ "$F_SYSLOG" -eq 1 ] || {
            echo "expected F_SYSLOG=1 after a fresh failure post-$intervening, got $F_SYSLOG (counter was not reset)" >&2
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

# An install that never enabled central logging has no syslog container to
# report. Omitting the service entirely avoids a permanent false dashboard
# alarm and mirrors the optional SSL service behavior.
@test "write_status omits the syslog block entirely when LOGGING_ENABLED is falsy" {
    unset LOGGING_ENABLED
    load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-omit.sh"
    [ -z "$C_SYSLOG" ]

    write_status
    # `jq -e` exits 1 when the filter evaluates to false or null. A genuinely
    # absent key therefore has status 1 while the captured output is `false`.
    run jq -e '.services | has("lancache-syslog")' "$status_file"
    [ "$status" -eq 1 ]
    [ "$output" = "false" ]
}
