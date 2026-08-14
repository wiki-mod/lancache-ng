#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: Coverage for setup.sh's pre-update health-baseline gate --
#   capture_stack_health_baseline + wait_for_stack_health only fail the gate
#   on a real regression (healthy pre-update, unhealthy after), not a
#   service already unhealthy before the update started.
# Why: Without a baseline, one permanently-unhealthy opt-in service (e.g.
#   ntp under this project's CI runners) blocked every future update.
#   Fake dc_update/docker functions keep this deterministic and fast.
# From: Issue #1391 | PR #1546

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-functional-health-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-functional-health-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-functional-health-helpers.sh"
    load_setup_functional_health_helpers "$repo_root" "$helper_file"

    # What: Re-declares the sourced _UPDATE_HEALTH_BASELINE as global+associative.
    # Why: `source` runs inside this function, so a plain (non -g) `declare`
    #   scopes it local to setup() and it evaporates on return; a later
    #   reassignment would then silently create an INDEXED global instead,
    #   colliding keys via arithmetic-subscript coercion. Test-harness-only;
    #   setup.sh's own top-level source never runs inside a function.
    declare -gA _UPDATE_HEALTH_BASELINE=()

    # What: Stubs verify_stack_functional_health to a plain success.
    # Why: Its curl/dig probes are covered by setup_functional_health_gate.bats;
    #   stubbing isolates the per-container baseline/regression logic here.
    verify_stack_functional_health() { return 0; }

    # What: Fake container tables, keyed by service name / container id.
    # Why: An unset lookup reads empty, same as the fakes below treat a
    #   container that doesn't exist for real docker/dc_update.
    declare -gA FAKE_CONTAINER_ID=()
    declare -gA FAKE_HEALTH=()          # container id -> "" (no healthcheck) | healthy | unhealthy | starting
    declare -gA FAKE_STATUS=()          # container id -> running | exited | restarting
    declare -gA FAKE_RESTART_POLICY=()  # container id -> no | always
    declare -gA FAKE_EXIT_CODE=()       # container id -> exit code string
    # What: Per-service scripted health sequence (one reading consumed per call).
    # Why: Simulates a flapping container's state changing between samples;
    #   tracked via a file (see fake docker() below), not a bash variable,
    #   since a subshell copy would discard an in-memory counter.
    declare -gA FAKE_HEALTH_SEQUENCE=() # service -> space-separated sequence of health readings, consumed one per call

    # What: Shortens the baseline sample count/interval for fast test runs.
    _UPDATE_HEALTH_BASELINE_SAMPLES=3
    _UPDATE_HEALTH_BASELINE_SAMPLE_INTERVAL=0

    # What: Overrides dc_update; only the "ps -a -q <service>" shape used by
    #   service_container_id is handled.
    dc_update() {
        if [[ "$1" = "ps" ]]; then
            local svc="$4"
            printf '%s' "${FAKE_CONTAINER_ID[$svc]-}"
        fi
        return 0
    }

    # What: Overrides `docker`; dispatches the three `inspect --format` shapes
    #   service_container_is_healthy issues, plus `docker logs`.
    # Why: The per-service call counter for FAKE_HEALTH_SEQUENCE is a file
    #   under BATS_TEST_TMPDIR, not an associative-array entry -- this
    #   function runs via `$(docker inspect ...)`, a subshell whose in-memory
    #   mutations are discarded on exit, so only a real file survives across
    #   calls to track "which reading is next."
    docker() {
        # What: Fakes `docker logs --tail 50` with a recognizable line, or a
        #   failure when FAKE_LOGS_SHOULD_FAIL=1 (container already gone).
        # Why: Proves the `|| print_warn` fallback fires under real
        #   `set -euo pipefail`, not just that the dump doesn't crash.
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
                    # What: Clamps idx to the last entry once the sequence is exhausted.
                    # Why: An unset index would read empty, misrepresenting
                    #   "no healthcheck declared" instead of the scripted state.
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
    # What: A crash-looping container reads healthy once, then unhealthy.
    # Why: A single sample would misread the healthy blip as stable; only
    #   _UPDATE_HEALTH_BASELINE_SAMPLES consecutive healthy reads may count.
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
    # What: No FAKE_CONTAINER_ID entry for "watchdog".
    # Why: Mirrors `docker compose ps -a -q` for a service the update is
    #   introducing for the first time.
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
    # What: Enables set -euo pipefail (bats isolates each @test's process).
    # Why: The `docker logs ... | sed ... || print_warn` fallback is only
    #   reachable when a failing producer's status propagates through the
    #   pipe, which plain `set -e` alone does not provide.
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
# What: nats/dhcp-proxy/syslog have no dual stdout+file log mode; once
#   LOGGING_ENABLED redirects them to file, `docker logs` alone goes quiet.
# Why: Tests point INSTALL_DIR/_UPDATE_ENV_FILE at a throwaway tmp tree,
#   needing no root/real-install access.
# From: PR #1546

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
    # What: File exists and would match if read.
    # Why: Proves this is a real LOGGING_ENABLED=0 skip, not a wrong-path miss.
    [[ "$output" != *"Last 50 forwarded log lines"* ]]
    [[ "$output" != *"FAKE_NATS_SYSLOG_LINE"* ]]
}

@test "wait_for_stack_health warns instead of crashing when no syslog-ng file exists yet for a known-quiet service" {
    INSTALL_DIR="$BATS_TEST_TMPDIR/install"
    _UPDATE_ENV_FILE="$BATS_TEST_TMPDIR/.env"
    : > "$_UPDATE_ENV_FILE"
    # What: No mkdir/file created.
    # Why: Simulates a fresh stack whose syslog-ng bind mount has not
    #   received any forwarded lines for this service yet.

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
    # What: No FAKE_CONTAINER_ID entry for "ghost".
    # Why: Mirrors a container docker compose can no longer find (already
    #   removed/recreated by the time the gate's failure path runs).
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
    # What: ntp must be named as forgiven, not folded into the regression message.
    [[ "$output" != *"regressed"*"ntp"* ]]
}
