#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for issue #1296: watchdog.sh's new NTP_ENABLED-gated alert-only
# monitoring of `ntp`, and get_health()/health_color()'s new "degraded"
# reading -- a container Docker itself reports "healthy" that has also told
# watchdog, through its own healthcheck's captured output, that it is
# intentionally operating with reduced guarantees (first real user: `ntp`'s
# CAP_SYS_TIME graceful degradation, see services/ntp/entrypoint.sh and
# deploy/*/docker-compose.yml's `ntp` healthcheck).
#
# This is also the first of issue #842's originally-proposed alert-only
# services to actually take effect in THIS live bash entrypoint -- the
# other five (ui/dhcp/dhcp-proxy/netdata/syslog) exist only in the
# not-yet-wired-up services/watchdog/src/ Rust scaffold (see that crate's
# own lib.rs module doc comment), so this file is real, live coverage, not
# duplicating tests the Rust crate's health.rs/docker_client.rs tests
# already cover for that (currently dormant) code path.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/watchdog-helpers-extracted.sh"
    status_file="$BATS_TEST_TMPDIR/status.json"

    export SSL_ENABLED=0
    export CACHE_DIR="$BATS_TEST_TMPDIR"
    export STATUS_FILE="$status_file"
    export NTP_ENABLED=1

    # shellcheck source=tests/bats/helpers/watchdog-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/watchdog-helpers.sh"
    load_watchdog_functions "$repo_root" "$helper_file"

    restart_calls=()
    restart_container() {
        restart_calls+=("$1")
    }

    F_NTP=0
    H_NTP="unknown"
}

@test "C_NTP defaults to lancache-ntp when NTP_ENABLED is truthy" {
    [ "$C_NTP" = "lancache-ntp" ]
}

@test "C_NTP is empty when NTP_ENABLED is not set (matches setup.sh's own default)" {
    unset NTP_ENABLED
    load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-ntp-disabled.sh"
    [ -z "$C_NTP" ]
}

@test "C_NTP is empty when NTP_ENABLED=0 explicitly" {
    export NTP_ENABLED=0
    load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-ntp-zero.sh"
    [ -z "$C_NTP" ]
}

@test "get_health reports degraded for a healthy container whose healthcheck log carries a DEGRADED marker" {
    curl() {
        echo '{"State":{"Health":{"Status":"healthy","Log":[{"Output":"Reference ID    : 00000000 ()\nDEGRADED: CAP_SYS_TIME denied -- clock not disciplined (issue #1296)\n"}]}}}'
    }
    result=$(get_health "lancache-ntp")
    [ "$result" = "degraded" ]
}

@test "get_health reports plain healthy when the healthcheck log has no DEGRADED marker" {
    curl() {
        echo '{"State":{"Health":{"Status":"healthy","Log":[{"Output":"Reference ID    : ABCD1234 (some.pool.server)\n"}]}}}'
    }
    result=$(get_health "lancache-ntp")
    [ "$result" = "healthy" ]
}

@test "get_health ignores a stale DEGRADED marker when Status is not healthy" {
    curl() {
        echo '{"State":{"Health":{"Status":"unhealthy","Log":[{"Output":"DEGRADED: leftover text"}]}}}'
    }
    result=$(get_health "lancache-ntp")
    [ "$result" = "unhealthy" ]
}

@test "health_color maps degraded to amber, distinct from yellow and green" {
    [ "$(health_color "degraded")" = "amber" ]
    [ "$(health_color "healthy")" = "green" ]
    [ "$(health_color "starting")" = "yellow" ]
}

# check_alert_only(): the alert-only counterpart to check_and_maybe_restart()
# -- never calls restart_container(), and treats healthy/starting/none/
# degraded as "ok" (matching services/watchdog/src/health.rs's
# HealthReading::is_alert_ok() exactly).
@test "check_alert_only treats a degraded reading as ok (resets counter, no restart)" {
    curl() {
        echo '{"State":{"Health":{"Status":"healthy","Log":[{"Output":"DEGRADED: CAP_SYS_TIME denied"}]}}}'
    }
    F_NTP=2
    check_alert_only "lancache-ntp" F_NTP H_NTP
    [ "$H_NTP" = "degraded" ]
    [ "$F_NTP" -eq 0 ]
    [ "${#restart_calls[@]}" -eq 0 ]
}

@test "check_alert_only increments on unhealthy and never restarts, even past RESTART_AFTER" {
    curl() { echo '{"State":{"Health":{"Status":"unhealthy"}}}'; }

    local i
    for ((i = 0; i < RESTART_AFTER + 5; i++)); do
        check_alert_only "lancache-ntp" F_NTP H_NTP
    done

    [ "$F_NTP" -eq $((RESTART_AFTER + 5)) ]
    [ "${#restart_calls[@]}" -eq 0 ]
}

@test "check_alert_only recovers (resets counter, logs nothing crashy) after a run of unhealthy readings" {
    curl() { echo '{"State":{"Health":{"Status":"unhealthy"}}}'; }
    check_alert_only "lancache-ntp" F_NTP H_NTP
    check_alert_only "lancache-ntp" F_NTP H_NTP
    [ "$F_NTP" -eq 2 ]

    curl() { echo '{"State":{"Health":{"Status":"healthy"}}}'; }
    check_alert_only "lancache-ntp" F_NTP H_NTP
    [ "$H_NTP" = "healthy" ]
    [ "$F_NTP" -eq 0 ]
}

# write_status(): the ntp entry must be present (and correctly colored) when
# C_NTP is set, and absent entirely (not even a placeholder) when it isn't --
# same "key presence is itself meaningful" contract as ssl_services.
@test "write_status includes an amber ntp entry when degraded" {
    H_NTP="degraded"
    F_NTP=0
    write_status
    run jq -e '.services["lancache-ntp"] == {"status":"amber","health":"degraded","failures":0}' "$status_file"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "write_status includes a green ntp entry when genuinely healthy" {
    H_NTP="healthy"
    F_NTP=0
    write_status
    run jq -e '.services["lancache-ntp"] == {"status":"green","health":"healthy","failures":0}' "$status_file"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "write_status omits the ntp key entirely when NTP_ENABLED is not set" {
    unset NTP_ENABLED
    load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-ntp-disabled-2.sh"
    write_status
    # No `-e` here deliberately: `jq -e` treats a `false` RESULT as a
    # command failure (exit 1), which is exactly the value under test --
    # using `-e` would make this assertion pass even if `has()` returned
    # `true` by mistake, as long as jq itself ran without error.
    run jq '.services | has("lancache-ntp")' "$status_file"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
}
