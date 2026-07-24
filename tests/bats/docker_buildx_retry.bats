#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Fast, Docker-free unit coverage for scripts/lib/docker-buildx-retry.sh.
# The real BuildKit/containerd layer-lock race ("(*service).Write failed:
# rpc error: code = Unavailable desc = ref ... locked for <N>ms (since
# <timestamp>): unavailable", confirmed live at least 4 times on 2026-07-24
# across PRs #1117, #1179, #1206, #1209) is host-contention-dependent and not
# reproducible on demand in CI, so this drives docker_buildx_retry with a
# stub command that prints controlled output and fails a controlled number
# of times, then asserts on attempt count, backoff, and the final exit code
# -- same approach tests/bats/ghcr_retry.bats already established for
# scripts/lib/ghcr-retry.sh.
#
# The single most important property under test here is the one that does
# NOT apply to ghcr_retry: a command that fails WITHOUT the transient
# signature in its output (a stand-in for a real Dockerfile syntax error or
# compile failure) must fail after exactly ONE attempt, never retried --
# retrying it would only delay real feedback, since no amount of retrying
# fixes a real failure.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/lib/docker-buildx-retry.sh
    source "$repo_root/scripts/lib/docker-buildx-retry.sh"

    sleep() { :; }
    export -f sleep

    DOCKER_BUILDX_RETRY_BACKOFF_SECONDS=0
    DOCKER_BUILDX_RETRY_MAX_ATTEMPTS=4
    attempt_log="$BATS_TEST_TMPDIR/attempts"
    : > "$attempt_log"
}

attempt_count() {
    wc -l < "$attempt_log"
}

# The exact historical error line from the live 2026-07-24 failures (#1117,
# #1179, #1206, #1209), with just the digest/duration/timestamp varied --
# this is what proves the pattern matches the real payload, not a
# hand-simplified stand-in for it.
transient_error_line='ERROR: (*service).Write failed: rpc error: code = Unavailable desc = ref layer-sha256:4f4fb700ef54461cfa02571ae0db9a0dc1e0cdb5577484a6d75e68dc38e8acc1 locked for 5023ms (since 2026-07-24T03:14:07Z): unavailable'

# Fails FAKE_FAIL_COUNT times printing the real transient signature, then
# succeeds.
flaky_transient_cmd() {
    echo "attempt" >> "$attempt_log"
    local calls
    calls=$(wc -l < "$attempt_log")
    if (( calls <= "${FAKE_FAIL_COUNT:-0}" )); then
        echo "$transient_error_line"
        return 1
    fi
    echo "build succeeded"
    return 0
}

always_fail_transient_cmd() {
    echo "attempt" >> "$attempt_log"
    echo "$transient_error_line"
    return 1
}

# Stand-in for a real, non-transient build failure (Dockerfile syntax error,
# compile failure, etc.) -- deliberately does NOT contain any of the
# transient pattern's tokens.
real_failure_cmd() {
    echo "attempt" >> "$attempt_log"
    echo "ERROR: failed to solve: process \"/bin/sh -c false\" did not complete successfully: exit code: 1"
    return 1
}

@test "docker_buildx_retry succeeds immediately when the command succeeds on the first try" {
    FAKE_FAIL_COUNT=0
    run docker_buildx_retry -- flaky_transient_cmd
    [ "$status" -eq 0 ]
    [ "$(attempt_count)" -eq 1 ]
}

@test "docker_buildx_retry retries on the exact historical transient signature and succeeds once the command stops failing" {
    FAKE_FAIL_COUNT=2
    run docker_buildx_retry -- flaky_transient_cmd
    [ "$status" -eq 0 ]
    # 2 failed attempts + 1 successful attempt = 3 total.
    [ "$(attempt_count)" -eq 3 ]
    [[ "$output" == *"transient layer-lock error detected"* ]]
    [[ "$output" == *"waiting 0s before retry"* ]]
    [[ "$output" == *"build succeeded"* ]]
}

@test "docker_buildx_retry gives up after DOCKER_BUILDX_RETRY_MAX_ATTEMPTS consecutive transient failures" {
    run docker_buildx_retry -- always_fail_transient_cmd
    [ "$status" -ne 0 ]
    [ "$(attempt_count)" -eq "$DOCKER_BUILDX_RETRY_MAX_ATTEMPTS" ]
    [[ "$output" == *"still failing with the transient layer-lock signature after ${DOCKER_BUILDX_RETRY_MAX_ATTEMPTS} attempts"* ]]
}

@test "docker_buildx_retry does NOT retry a real failure that lacks the transient signature (no-masking property)" {
    run docker_buildx_retry -- real_failure_cmd
    [ "$status" -ne 0 ]
    # Exactly one attempt: a real Dockerfile/compile failure must fail
    # immediately, not be retried and delayed.
    [ "$(attempt_count)" -eq 1 ]
    [[ "$output" == *"not retrying (real failure)"* ]]
    [[ "$output" != *"waiting"* ]]
}

@test "docker_buildx_retry streams the wrapped command's own output to the caller (nothing hidden)" {
    FAKE_FAIL_COUNT=0
    run docker_buildx_retry -- flaky_transient_cmd
    [[ "$output" == *"build succeeded"* ]]
}

@test "docker_buildx_retry requires -- before the wrapped command" {
    run docker_buildx_retry flaky_transient_cmd
    [ "$status" -eq 2 ]
    [[ "$output" == *"expected -- before the command to run"* ]]
}
