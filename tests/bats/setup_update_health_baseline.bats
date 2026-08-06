#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression coverage for the pre-update health-baseline gate (issue #1391's
# post-merge-verification finding): setup.sh update's post-update health gate
# used to fail on ANY currently-unhealthy non-UI service, with no way to tell
# "this service regressed because of what the update just did" apart from
# "this service was already broken before the update started, for a reason
# the update did not cause or change." Real-world consequence: an opt-in
# service that can never become healthy in a given environment (e.g. ntp
# crash-looping under this project's LXC-hosted CI runners' CAP_SYS_TIME
# limitation, issue #1296) permanently blocked every future update, including
# unrelated security fixes, until the operator manually disabled it.
#
# capture_stack_health_baseline + wait_for_stack_health's baseline-aware gate
# fix that: only a service that WAS healthy pre-update (or has no baseline at
# all -- a brand-new service, or a fresh install) counts as a gate failure
# when it is unhealthy afterward. A service already unhealthy pre-update does
# not block the gate, but a REAL regression (healthy -> unhealthy) still does.
#
# Uses fake dc_update/docker shell functions (redefined after sourcing the
# real setup.sh range via load_setup_functional_health_helpers) instead of a
# real Docker daemon, so this suite is fast and fully deterministic -- see
# each test's own FAKE_* table setup for the exact container states it
# simulates. This mirrors setup_functional_health_gate.bats's existing use of
# the same helper for the neighboring verify_stack_functional_health gate.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-functional-health-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-functional-health-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-functional-health-helpers.sh"
    load_setup_functional_health_helpers "$repo_root" "$helper_file"

    # The captured setup.sh range's own `declare -A _UPDATE_HEALTH_BASELINE=()`
    # (see setup.sh's "update / auto-update shared internals" section) runs as
    # part of the `source` call above -- but that `source` executes inside
    # THIS function (bats' own setup()), so a plain `declare` without `-g`
    # scopes the array LOCAL to setup() and it evaporates the moment setup()
    # returns. A later plain reassignment in the @test body / in
    # capture_stack_health_baseline itself would then create a fresh, un-
    # declared global that bash defaults to an INDEXED array -- silently
    # turning `_UPDATE_HEALTH_BASELINE[ntp]="0"` into an arithmetic-subscript
    # assignment (unset bareword "ntp" evaluates to 0), colliding with
    # `_UPDATE_HEALTH_BASELINE[proxy]="1"` at the very same index 0. Only
    # matters for this test harness's re-use of `source`-inside-a-function;
    # setup.sh's own real top-level `source`/execution never hits this, since
    # it is never itself inside a function. Re-declaring with an explicit
    # `-g` here forces true global+associative scope regardless of the
    # function context the sourcing happened in, closing the gap for good.
    declare -gA _UPDATE_HEALTH_BASELINE=()

    # verify_stack_functional_health's own curl/dig probes are covered by
    # setup_functional_health_gate.bats; stubbed out here to a plain success
    # so these tests isolate the per-container baseline/regression logic.
    verify_stack_functional_health() { return 0; }

    # Fake container tables, keyed by service name / container id. Each test
    # populates only the entries it needs; an unset lookup reads as empty,
    # which the fakes below treat the same way real `docker`/`dc_update`
    # would treat a container that doesn't exist.
    declare -gA FAKE_CONTAINER_ID=()
    declare -gA FAKE_HEALTH=()          # container id -> "" (no healthcheck) | healthy | unhealthy | starting
    declare -gA FAKE_STATUS=()          # container id -> running | exited | restarting
    declare -gA FAKE_RESTART_POLICY=()  # container id -> no | always
    declare -gA FAKE_EXIT_CODE=()       # container id -> exit code string
    # Per-service scripted health sequence, used by the "flaky single sample"
    # test to return a different reading on successive calls -- simulating a
    # container's real state changing between capture_stack_health_baseline's
    # own samples, exactly like a genuinely crash-looping container would.
    # The position within the sequence is tracked via a file under
    # BATS_TEST_TMPDIR (see the fake docker() function below), not a bash
    # variable -- a subshell-persistence requirement, not a style choice.
    declare -gA FAKE_HEALTH_SEQUENCE=() # service -> space-separated sequence of health readings, consumed one per call

    # Speed up capture_stack_health_baseline's own multi-sample wait and
    # wait_for_stack_health's poll interval so these tests run in a second or
    # two rather than the real several-second production intervals.
    _UPDATE_HEALTH_BASELINE_SAMPLES=3
    _UPDATE_HEALTH_BASELINE_SAMPLE_INTERVAL=0

    # Overrides the real dc_update (docker compose --env-file ... "$@"):
    # only the one call shape service_container_id actually issues
    # ("ps -a -q <service>") is handled.
    dc_update() {
        if [[ "$1" = "ps" ]]; then
            local svc="$4"
            printf '%s' "${FAKE_CONTAINER_ID[$svc]-}"
        fi
        return 0
    }

    # Overrides the real `docker` binary: only the three `docker inspect
    # --format '...'` shapes service_container_is_healthy actually issues are
    # handled, dispatched on which field the format string asks for. A
    # service listed in FAKE_HEALTH_SEQUENCE consumes one reading per call
    # (simulating a flapping container); everything else reads a fixed value
    # from the FAKE_* tables above.
    #
    # The per-service call counter is a FILE under BATS_TEST_TMPDIR, not a
    # bash associative-array entry: service_container_is_healthy invokes this
    # function via `health=$(docker inspect ...)` -- a command substitution,
    # which forks a subshell. Any in-memory variable this function mutated
    # (including an associative-array element) would be a copy-on-write
    # change local to that subshell and silently discarded the moment it
    # exits, so a would-be counter would read back as 0 forever no matter how
    # many samples ran. A real file's content survives past the subshell
    # exit, since it is a genuine filesystem side effect, not process memory.
    docker() {
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
                    # Once the scripted sequence is exhausted, keep returning
                    # its last entry rather than reading an unset index as
                    # empty (which would misrepresent "no healthcheck
                    # declared" instead of continuing the scripted state).
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
    # Simulates issue #1391's exact hazard: a crash-looping container with no
    # declared HEALTHCHECK can transiently read .State.Health empty / status
    # "running" for an instant between one restart and the next crash. A
    # single-sample baseline would misread this as healthy; requiring
    # _UPDATE_HEALTH_BASELINE_SAMPLES consecutive healthy reads must not.
    FAKE_CONTAINER_ID[flaky]="c-flaky"
    # Sample 1 (mid-restart-window): healthcheck reports healthy once...
    # Sample 2: ...but the container has already crashed and restarted by
    # the time the next sample is taken, so this must fail the streak.
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
    # No FAKE_CONTAINER_ID entry at all for "watchdog" -- service_container_id
    # returns empty, exactly like docker compose ps -a -q would for a service
    # this update is introducing for the first time.
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
    # The already-broken, non-regressed service must be named as forgiven,
    # not folded into the regression failure message.
    [[ "$output" != *"regressed"*"ntp"* ]]
}
