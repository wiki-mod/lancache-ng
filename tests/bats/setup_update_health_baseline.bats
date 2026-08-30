#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: coverage for setup.sh's pre-update health-baseline g
# Why: without a baseline, one permanently-unhealthy opt-in
#   ntp under this project's CI runners) blocked every future update;
#   the gate must only fail on a real regression, never a pre-existing one.
# From: Issue #1391 | PR #1546

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-functional-health-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-functional-health-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-functional-health-helpers.sh"
    load_setup_functional_health_helpers "$repo_root" "$helper_file"

    # What: re-declares sourced _UPDATE_HEALTH_BASELINE as g
    # Why: a plain (non -g) `declare` inside setup() scopes
    #   evaporates on return; test-harness-only, setup.sh's own top-level
    #   source never runs inside a function.
    # From: Issue #1391 | PR #1546
    declare -gA _UPDATE_HEALTH_BASELINE=()

    # What: stubs verify_stack_functional_health to a plain
    # Why: its curl/dig probes are covered by setup_function
    #   stubbing isolates the per-container baseline/regression logic here.
    # From: Issue #1391 | PR #1546
    verify_stack_functional_health() { return 0; }

    # What: fake container tables, keyed by service name / c
    # Why: an unset lookup reads empty, same as fakes below
    #   container that doesn't exist for real docker/dc_update.
    # From: Issue #1391 | PR #1546
    declare -gA FAKE_CONTAINER_ID=()
    declare -gA FAKE_HEALTH=()          # container id -> "" (no healthcheck) | healthy | unhealthy | starting
    declare -gA FAKE_STATUS=()          # container id -> running | exited | restarting
    declare -gA FAKE_RESTART_POLICY=()  # container id -> no | always
    declare -gA FAKE_EXIT_CODE=()       # container id -> exit code string
    # What: per-service scripted health sequence (one readin
    # Why: simulates a flapping container's state changing b
    #   tracked via a file (see fake docker() below), a subshell copy of an
    #   in-memory counter would not survive across calls.
    # From: Issue #1391 | PR #1546
    declare -gA FAKE_HEALTH_SEQUENCE=() # service -> space-separated sequence of health readings, consumed one per call

    # What: shortens baseline sample count/interval for fast
    # Why: keeps this suite fast without changing gate's rea
    # From: Issue #1391 | PR #1546
    _UPDATE_HEALTH_BASELINE_SAMPLES=3
    _UPDATE_HEALTH_BASELINE_SAMPLE_INTERVAL=0

    # What: overrides dc_update; only its "ps -a -q <service
    # Why: keeps fake minimal, matching only what code under
    # From: Issue #1391 | PR #1546
    dc_update() {
        if [[ "$1" = "ps" ]]; then
            local svc="$4"
            printf '%s' "${FAKE_CONTAINER_ID[$svc]-}"
        fi
        return 0
    }

    # What: overrides `docker`; dispatches its `inspect --fo
    # Why: FAKE_HEALTH_SEQUENCE's call counter is a file und
    #   BATS_TEST_TMPDIR, since `$(docker inspect ...)` runs in a subshell
    #   whose in-memory state would not survive across calls.
    # From: Issue #1391 | PR #1546
    docker() {
        # What: fakes `docker logs --tail 50`, or fails if F
        # Why: proves `|| print_warn` fallback fires under r
        #   `set -euo pipefail`, not just that the dump doesn't crash.
        # From: Issue #1391 | PR #1546
        if [[ "$1" = "logs" ]]; then
            if [[ "${FAKE_LOGS_SHOULD_FAIL:-0}" = "1" ]]; then
                return 1
            fi
            printf 'FAKE_CRASH_LINE\n'
            return 0
        fi
        [[ "$1" = "inspect" ]] || return 0
        local fmt="$3" cid="$4" svc_for_cid=""
        for svc_for_cid in "${!FAKE_CONTAINER_ID[@]}"; do
            [[ "${FAKE_CONTAINER_ID[$svc_for_cid]}" = "$cid" ]] && break
        done

        case "$fmt" in
            *'.State.Health'*)
                if [[ -n "${FAKE_HEALTH_SEQUENCE[$svc_for_cid]-}" ]]; then
                    local -a sequence
                    read -ra sequence <<< "${FAKE_HEALTH_SEQUENCE[$svc_for_cid]}"
                    local count_file="$BATS_TEST_TMPDIR/callcount-$svc_for_cid"
                    local idx=0
                    [[ -f "$count_file" ]] && idx=$(<"$count_file")
                    printf '%s' "$(( idx + 1 ))" > "$count_file"
                    # What: clamps idx to last entry once se
                    # Why: an unset index would read empty,
                    #   healthcheck declared" instead of the scripted state.
                    # From: Issue #1391 | PR #1546
                    (( idx >= ${#sequence[@]} )) && idx=$(( ${#sequence[@]} - 1 ))
                    printf '%s' "${sequence[$idx]}"
                else
                    printf '%s' "${FAKE_HEALTH[$cid]-}"
                fi
                ;;
            *'.State.Status'*) printf '%s' "${FAKE_STATUS[$cid]-}" ;;
            *'RestartPolicy'*) printf '%s' "${FAKE_RESTART_POLICY[$cid]-}" ;;
            *'ExitCode'*) printf '%s' "${FAKE_EXIT_CODE[$cid]-}" ;;
        esac
        return 0
    }
}

# ── capture_stack_health_baseline ─────────────────────────────────────────────

@test "capture_stack_health_baseline records a stably-healthy service as baseline 1" {
    FAKE_CONTAINER_ID[proxy]="c-proxy"
    FAKE_HEALTH[c-proxy]="healthy"

    capture_stack_health_baseline proxy

    [ "${_UPDATE_HEALTH_BASELINE[proxy]}" = "1" ]
}

@test "capture_stack_health_baseline records a permanently crash-looping service (with a healthcheck) as baseline 0" {
    FAKE_CONTAINER_ID[ntp]="c-ntp"
    FAKE_HEALTH[c-ntp]="unhealthy"
    FAKE_STATUS[c-ntp]="restarting"

    capture_stack_health_baseline ntp

    [ "${_UPDATE_HEALTH_BASELINE[ntp]}" = "0" ]
}

@test "capture_stack_health_baseline does not mistake a single lucky sample of a flapping container for stable health" {
    # What: a crash-looping container reads healthy once, th
    # Why: a single sample would misread healthy blip as sta
    #   _UPDATE_HEALTH_BASELINE_SAMPLES consecutive healthy reads may count.
    # From: Issue #1391 | PR #1546
    FAKE_CONTAINER_ID[flaky]="c-flaky"
    FAKE_HEALTH_SEQUENCE[flaky]="healthy unhealthy unhealthy"

    capture_stack_health_baseline flaky

    [ "${_UPDATE_HEALTH_BASELINE[flaky]}" = "0" ]
}

@test "capture_stack_health_baseline records a genuinely stable service across all required samples as baseline 1" {
    FAKE_CONTAINER_ID[nats]="c-nats"
    FAKE_HEALTH_SEQUENCE[nats]="healthy healthy healthy"

    capture_stack_health_baseline nats

    [ "${_UPDATE_HEALTH_BASELINE[nats]}" = "1" ]
}

@test "capture_stack_health_baseline leaves a brand-new service (no pre-existing container) out of the baseline map entirely" {
    # What: no FAKE_CONTAINER_ID entry for "watchdog".
    # Why: mirrors `docker compose ps -a -q` for a service u
    #   introducing for the first time.
    # From: Issue #1391 | PR #1546
    capture_stack_health_baseline watchdog

    run bash -c '[[ -v _UPDATE_HEALTH_BASELINE[watchdog] ]]'
    [ "$status" -ne 0 ]
}

@test "capture_stack_health_baseline handles a one-shot exited-0 service (no healthcheck) as baseline 1" {
    FAKE_CONTAINER_ID[dhcp-probe]="c-probe"
    FAKE_STATUS[c-probe]="exited"
    FAKE_RESTART_POLICY[c-probe]="no"
    FAKE_EXIT_CODE[c-probe]="0"

    capture_stack_health_baseline dhcp-probe

    [ "${_UPDATE_HEALTH_BASELINE[dhcp-probe]}" = "1" ]
}

# ── wait_for_stack_health baseline-aware gate ─────────────────────────────────

@test "wait_for_stack_health passes when a baseline-unhealthy service stays unhealthy (not a regression)" {
    FAKE_CONTAINER_ID[ntp]="c-ntp"
    FAKE_HEALTH[c-ntp]="unhealthy"
    _UPDATE_HEALTH_BASELINE=([ntp]="0")

    run wait_for_stack_health 2 ntp
    [ "$status" -eq 0 ]
    [[ "$output" == *"Proceeding despite service(s) unhealthy before this update started too"* ]]
    [[ "$output" == *"ntp"* ]]
}

@test "wait_for_stack_health fails when a baseline-healthy service regresses to unhealthy" {
    FAKE_CONTAINER_ID[proxy]="c-proxy"
    FAKE_HEALTH[c-proxy]="unhealthy"
    _UPDATE_HEALTH_BASELINE=([proxy]="1")

    run wait_for_stack_health 2 proxy
    [ "$status" -eq 1 ]
    [[ "$output" == *"regressed from healthy to unhealthy"* ]]
    [[ "$output" == *"proxy"* ]]
    [[ "$output" == *"Last 50 log lines for regressed service 'proxy' (container c-proxy)"* ]]
    [[ "$output" == *"    FAKE_CRASH_LINE"* ]]
}

@test "wait_for_stack_health's log-dump fallback fires when docker logs itself fails, under real set -euo pipefail" {
    # What: enables set -euo pipefail (bats isolates each @t
    # Why: the `docker logs ... | sed ... || print_warn` fal
    #   reachable when pipefail propagates a failing producer's status.
    # From: Issue #1391 | PR #1546
    set -euo pipefail
    FAKE_CONTAINER_ID[proxy]="c-proxy"
    FAKE_HEALTH[c-proxy]="unhealthy"
    _UPDATE_HEALTH_BASELINE=([proxy]="1")
    FAKE_LOGS_SHOULD_FAIL=1

    run wait_for_stack_health 2 proxy
    [ "$status" -eq 1 ]
    [[ "$output" == *"regressed from healthy to unhealthy"* ]]
    [[ "$output" == *"Last 50 log lines for regressed service 'proxy' (container c-proxy)"* ]]
    [[ "$output" == *"Could not retrieve logs for 'proxy' (container may already be gone)."* ]]
    [[ "$output" != *"FAKE_CRASH_LINE"* ]]
}

# ── _REGRESSED_SERVICE_SYSLOG_HOST / dump_service_syslog_ng_tail ──────────────
# What: nats/dhcp-proxy/syslog only log to file once LOGGING
# Why: `docker logs` alone goes quiet for them; tests point
#   INSTALL_DIR/_UPDATE_ENV_FILE at a throwaway tmp tree instead.
# From: Issue #1391 | PR #1546

@test "wait_for_stack_health also tails today's forwarded syslog-ng file for a known-quiet regressed service" {
    INSTALL_DIR="$BATS_TEST_TMPDIR/install"
    _UPDATE_ENV_FILE="$BATS_TEST_TMPDIR/.env"
    : > "$_UPDATE_ENV_FILE"
    local today; today="$(date -u +%Y%m%d)"
    mkdir -p "$INSTALL_DIR/syslog-ng/lancache-nats"
    printf 'FAKE_NATS_SYSLOG_LINE\n' > "$INSTALL_DIR/syslog-ng/lancache-nats/$today.log"

    FAKE_CONTAINER_ID[nats]="c-nats"
    FAKE_HEALTH[c-nats]="unhealthy"
    _UPDATE_HEALTH_BASELINE=([nats]="1")

    run wait_for_stack_health 2 nats
    [ "$status" -eq 1 ]
    [[ "$output" == *"Last 50 forwarded log lines for 'nats'"* ]]
    [[ "$output" == *"    FAKE_NATS_SYSLOG_LINE"* ]]
}

@test "wait_for_stack_health skips the syslog-ng tail entirely when LOGGING_ENABLED is 0" {
    INSTALL_DIR="$BATS_TEST_TMPDIR/install"
    _UPDATE_ENV_FILE="$BATS_TEST_TMPDIR/.env"
    printf 'LOGGING_ENABLED=0\n' > "$_UPDATE_ENV_FILE"
    local today; today="$(date -u +%Y%m%d)"
    mkdir -p "$INSTALL_DIR/syslog-ng/lancache-nats"
    printf 'FAKE_NATS_SYSLOG_LINE\n' > "$INSTALL_DIR/syslog-ng/lancache-nats/$today.log"

    FAKE_CONTAINER_ID[nats]="c-nats"
    FAKE_HEALTH[c-nats]="unhealthy"
    _UPDATE_HEALTH_BASELINE=([nats]="1")

    run wait_for_stack_health 2 nats
    [ "$status" -eq 1 ]
    # What: file exists and would match if read.
    # Why: proves this is a real LOGGING_ENABLED=0 skip, not
    # From: Issue #1391 | PR #1546
    [[ "$output" != *"Last 50 forwarded log lines"* ]]
    [[ "$output" != *"FAKE_NATS_SYSLOG_LINE"* ]]
}

@test "wait_for_stack_health warns instead of crashing when no syslog-ng file exists yet for a known-quiet service" {
    INSTALL_DIR="$BATS_TEST_TMPDIR/install"
    _UPDATE_ENV_FILE="$BATS_TEST_TMPDIR/.env"
    : > "$_UPDATE_ENV_FILE"
    # What: no mkdir/file created.
    # Why: simulates a fresh stack whose syslog-ng bind moun
    #   received any forwarded lines for this service yet.
    # From: Issue #1391 | PR #1546

    FAKE_CONTAINER_ID[nats]="c-nats"
    FAKE_HEALTH[c-nats]="unhealthy"
    _UPDATE_HEALTH_BASELINE=([nats]="1")

    run wait_for_stack_health 2 nats
    [ "$status" -eq 1 ]
    [[ "$output" == *"No forwarded syslog-ng log file found for 'nats' yet at"* ]]
}

@test "wait_for_stack_health does not attempt a syslog-ng tail for a service outside the known-quiet set" {
    INSTALL_DIR="$BATS_TEST_TMPDIR/install"
    _UPDATE_ENV_FILE="$BATS_TEST_TMPDIR/.env"
    : > "$_UPDATE_ENV_FILE"

    FAKE_CONTAINER_ID[proxy]="c-proxy"
    FAKE_HEALTH[c-proxy]="unhealthy"
    _UPDATE_HEALTH_BASELINE=([proxy]="1")

    run wait_for_stack_health 2 proxy
    [ "$status" -eq 1 ]
    [[ "$output" != *"forwarded"* ]]
}

@test "wait_for_stack_health reports no container found when a regressed service's container is already gone" {
    # What: no FAKE_CONTAINER_ID entry for "ghost".
    # Why: mirrors a container docker compose can no longer
    #   removed/recreated by the time the gate's failure path runs).
    # From: Issue #1391 | PR #1546
    _UPDATE_HEALTH_BASELINE=([ghost]="1")

    run wait_for_stack_health 2 ghost
    [ "$status" -eq 1 ]
    [[ "$output" == *"regressed from healthy to unhealthy"* ]]
    [[ "$output" == *"No container found for regressed service 'ghost'; cannot dump its logs."* ]]
    [[ "$output" != *"Last 50 log lines"* ]]
}

@test "wait_for_stack_health fails closed on a service with no baseline entry at all (fresh install / brand-new service)" {
    FAKE_CONTAINER_ID[newsvc]="c-new"
    FAKE_HEALTH[c-new]="unhealthy"
    _UPDATE_HEALTH_BASELINE=()

    run wait_for_stack_health 2 newsvc
    [ "$status" -eq 1 ]
    [[ "$output" == *"regressed from healthy to unhealthy"* ]]
}

@test "wait_for_stack_health passes and ignores baseline entirely once every service is actually healthy" {
    FAKE_CONTAINER_ID[proxy]="c-proxy"
    FAKE_HEALTH[c-proxy]="healthy"
    _UPDATE_HEALTH_BASELINE=([proxy]="1")

    run wait_for_stack_health 2 proxy
    [ "$status" -eq 0 ]
    [[ "$output" != *"Proceeding despite"* ]]
}

@test "wait_for_stack_health handles a mix: one real regression blocks the gate even though another service was already broken" {
    FAKE_CONTAINER_ID[ntp]="c-ntp"
    FAKE_HEALTH[c-ntp]="unhealthy"
    FAKE_CONTAINER_ID[proxy]="c-proxy"
    FAKE_HEALTH[c-proxy]="unhealthy"
    _UPDATE_HEALTH_BASELINE=([ntp]="0" [proxy]="1")

    run wait_for_stack_health 2 ntp proxy
    [ "$status" -eq 1 ]
    [[ "$output" == *"proxy"* ]]
    # What: ntp is named as forgiven, not folded into regres
    # Why: proves mix case reports two services independentl
    # From: Issue #1391 | PR #1546
    [[ "$output" != *"regressed"*"ntp"* ]]
}
