#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Fast, Docker-free unit coverage for scripts/lib/ghcr-retry.sh (issue #822,
# "Pattern D": transient GHCR 401s guarded only in build-push.yml's
# build/build-arm64 jobs, everywhere else a single bare attempt). The real
# 401 is not reproducible on demand, so this drives ghcr_retry with a stub
# command that fails a controlled number of times before succeeding (or
# never succeeds), and asserts on attempt count, backoff, and the final
# exit code -- per the maintainer's own instruction on #822 ("confirm each
# step under a forced-401 test rather than assume").
#
# Also directly regresses a real bug caught while writing these tests:
# `if "$@"; then return 0; fi` followed by a bare `status=$?` always read 0
# for `status` when the tested command failed, because bash defines an
# `if` with no taken branch as exiting 0 regardless of the condition's real
# result -- ghcr_retry silently reported success even after every attempt
# was exhausted. Fixed by capturing the real exit status inside an explicit
# else branch instead of after the closing `fi`.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/lib/ghcr-retry.sh
    source "$repo_root/scripts/lib/ghcr-retry.sh"

    # Stub out sleep/docker so the suite runs fast and never touches the
    # network or a real registry session.
    sleep() { :; }
    docker() {
        if [[ "$1" = "login" ]]; then
            relogin_calls=$((${relogin_calls:-0} + 1))
            return "${FAKE_RELOGIN_EXIT:-0}"
        fi
        return 0
    }
    export -f sleep docker

    GHCR_RETRY_BACKOFF_SECONDS=0
    GHCR_RETRY_MAX_ATTEMPTS=4
    relogin_calls=0
    attempt_log="$BATS_TEST_TMPDIR/attempts"
    : > "$attempt_log"
}

# Fails FAKE_FAIL_COUNT times (default from caller env), then succeeds.
# Appends one line per invocation to $attempt_log so tests can assert the
# exact number of attempts ghcr_retry actually made.
flaky_cmd() {
    echo "attempt" >> "$attempt_log"
    local calls
    calls=$(wc -l < "$attempt_log")
    (( calls <= "${FAKE_FAIL_COUNT:-0}" )) && return 1
    return 0
}

always_fail_cmd() {
    echo "attempt" >> "$attempt_log"
    return 1
}

@test "ghcr_retry succeeds immediately when the command succeeds on the first try" {
    FAKE_FAIL_COUNT=0
    run ghcr_retry ghcr.io testuser testpass -- flaky_cmd
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$attempt_log")" -eq 1 ]
}

@test "ghcr_retry retries and succeeds once the command stops failing, re-authenticating between attempts" {
    FAKE_FAIL_COUNT=2
    run ghcr_retry ghcr.io testuser testpass -- flaky_cmd
    [ "$status" -eq 0 ]
    # 2 failed attempts + 1 successful attempt = 3 total.
    [ "$(wc -l < "$attempt_log")" -eq 3 ]
    [[ "$output" == *"waiting 0s before retry"* ]]
}

@test "ghcr_retry gives up and returns nonzero after GHCR_RETRY_MAX_ATTEMPTS consecutive failures" {
    run ghcr_retry ghcr.io testuser testpass -- always_fail_cmd
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$attempt_log")" -eq "$GHCR_RETRY_MAX_ATTEMPTS" ]
    [[ "$output" == *"failed after ${GHCR_RETRY_MAX_ATTEMPTS} attempts"* ]]
}

@test "ghcr_retry propagates a real failure through a caller's set -e instead of silently reporting success" {
    # Regression test for the exact bug described in this file's header
    # comment: without the fix, this whole function body would abort at the
    # `ghcr_retry` line under `set -e` because it looked like a bare failing
    # statement, OR (with the original buggy `if`/bare `status=$?`) it would
    # incorrectly report success and let the `||` branch never run.
    run bash -c '
        set -euo pipefail
        source "'"$repo_root"'/scripts/lib/ghcr-retry.sh"
        sleep() { :; }
        docker() { return 0; }
        export -f sleep docker
        GHCR_RETRY_BACKOFF_SECONDS=0
        GHCR_RETRY_MAX_ATTEMPTS=2
        always_fail() { return 1; }
        if ghcr_retry ghcr.io u p -- always_fail; then
            echo "BUG: reported success"
            exit 1
        fi
        echo "correctly observed failure"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"correctly observed failure"* ]]
    [[ "$output" != *"BUG"* ]]
}

@test "ghcr_retry does not re-authenticate before the first attempt" {
    FAKE_FAIL_COUNT=0
    ghcr_retry ghcr.io testuser testpass -- flaky_cmd
    [ "$relogin_calls" -eq 0 ]
}

@test "ghcr_retry re-authenticates once per retry, not once total" {
    FAKE_FAIL_COUNT=3
    ghcr_retry ghcr.io testuser testpass -- flaky_cmd
    # 3 failed attempts -> 3 re-logins before the 4th (successful) attempt.
    [ "$relogin_calls" -eq 3 ]
}

@test "ghcr_retry retries without a fresh login when no credentials are given" {
    FAKE_FAIL_COUNT=1
    run ghcr_retry ghcr.io "" "" -- flaky_cmd
    [ "$status" -eq 0 ]
    [ "$relogin_calls" -eq 0 ]
    [[ "$output" == *"retrying without a fresh login"* ]]
}

@test "ghcr_retry rejects a call missing the -- separator" {
    run ghcr_retry ghcr.io testuser testpass flaky_cmd
    [ "$status" -eq 2 ]
    [[ "$output" == *"expected -- before the command"* ]]
}

@test "ghcr_relogin fails closed when the registry login itself fails" {
    docker() { [[ "$1" = "login" ]] && return 1; return 0; }
    export -f docker
    run ghcr_relogin ghcr.io testuser testpass
    [ "$status" -ne 0 ]
}
