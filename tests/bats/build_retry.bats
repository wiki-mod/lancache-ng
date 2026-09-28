#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fast, Docker-free unit coverage for scripts/lib/build-retry.sh (issue
# #1222, AG-CI-013). The real transient BuildKit content-store layer-lock
# race is host-contention-dependent and not reproducible on demand (see the
# issue's own acceptance criteria), so this drives build_retry() with a stub
# command that fails a controlled number of times before succeeding (or
# never succeeds) and asserts on attempt count, backoff, and exit code --
# same approach tests/bats/ghcr_retry.bats already uses for ghcr_retry().
#
# What this suite is specifically here to prove, per #1222's acceptance
# criteria: the retry-detection logic (build_retry_is_transient_failure)
# correctly classifies the real historical error text from the four actual
# failures (#1117, #1179, #1206, #1209) as transient, and correctly
# classifies ordinary Dockerfile/compile failure text as NOT transient --
# and that build_retry() itself only retries in the former case, never the
# latter.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/lib/build-retry.sh
    source "$repo_root/scripts/lib/build-retry.sh"

    sleep() { :; }
    export -f sleep

    # shellcheck disable=SC2034 # read by build_retry() in scripts/lib/build-retry.sh,
    # sourced above -- shellcheck cannot see the cross-file read.
    BUILD_RETRY_MAX_ATTEMPTS=3
    # shellcheck disable=SC2034
    BUILD_RETRY_BASE_BACKOFF_SECONDS=0

    attempt_log="$BATS_TEST_TMPDIR/attempts"
    : > "$attempt_log"
}

# Number of times the stub command below was actually invoked.
attempt_count() {
    wc -l < "$attempt_log"
}

# The exact error text from issue #1222's four real failures (#1117, #1179,
# #1206, #1209) -- only the digest/duration/timestamp varied between
# occurrences; this is one real occurrence verbatim.
real_transient_error() {
    cat <<'EOF'
#14 exporting to docker image format
#14 sending tarball
ERROR: (*service).Write failed: rpc error: code = Unavailable desc = ref layer-sha256:4f4fb700ef54461cfa02571ae0db9a0dc1e0cdb5577484a6d75e68dc38e8acc1 locked for 3241ms (since 2026-07-24T02:14:07Z): unavailable
EOF
}

# Fails FAKE_FAIL_COUNT times printing the real transient signature, then
# succeeds. Appends one line per invocation to $attempt_log.
flaky_transient_cmd() {
    echo "attempt" >> "$attempt_log"
    local calls
    calls=$(wc -l < "$attempt_log")
    if (( calls <= "${FAKE_FAIL_COUNT:-0}" )); then
        real_transient_error
        return 1
    fi
    echo "build succeeded"
}

always_fail_transient_cmd() {
    echo "attempt" >> "$attempt_log"
    real_transient_error
    return 1
}

# A real Dockerfile error never contains the transient signature -- this is
# representative of what buildx actually prints for a bad RUN instruction.
real_dockerfile_error() {
    cat <<'EOF'
#8 [4/9] RUN apt-get install -y this-package-does-not-exist
#8 1.203 E: Unable to locate package this-package-does-not-exist
#8 ERROR: process "/bin/sh -c apt-get install -y this-package-does-not-exist" did not complete successfully: exit code: 100
EOF
}

always_fail_dockerfile_cmd() {
    echo "attempt" >> "$attempt_log"
    real_dockerfile_error
    return 1
}

@test "build_retry_is_transient_failure matches the real #1222 error text" {
    logfile="$BATS_TEST_TMPDIR/log"
    real_transient_error > "$logfile"
    run build_retry_is_transient_failure "$logfile"
    [ "$status" -eq 0 ]
}

@test "build_retry_is_transient_failure does not match a real Dockerfile/compile error" {
    logfile="$BATS_TEST_TMPDIR/log"
    real_dockerfile_error > "$logfile"
    run build_retry_is_transient_failure "$logfile"
    [ "$status" -ne 0 ]
}

@test "build_retry_is_transient_failure does not match an unrelated generic failure" {
    logfile="$BATS_TEST_TMPDIR/log"
    echo "some unrelated network hiccup" > "$logfile"
    run build_retry_is_transient_failure "$logfile"
    [ "$status" -ne 0 ]
}

@test "build_retry succeeds immediately when the command succeeds on the first try" {
    FAKE_FAIL_COUNT=0
    run build_retry -- flaky_transient_cmd
    [ "$status" -eq 0 ]
    [ "$(attempt_count)" -eq 1 ]
}

@test "build_retry retries a transient failure and succeeds once the command stops failing" {
    FAKE_FAIL_COUNT=2
    run build_retry -- flaky_transient_cmd
    [ "$status" -eq 0 ]
    # 2 failed attempts + 1 successful attempt = 3 total.
    [ "$(attempt_count)" -eq 3 ]
    [[ "$output" == *"transient BuildKit content-store layer-lock signature"* ]]
    [[ "$output" == *"waiting 10s before retry"* || "$output" == *"waiting 0s before retry"* ]]
}

@test "build_retry gives up and returns nonzero after BUILD_RETRY_MAX_ATTEMPTS consecutive transient failures" {
    run build_retry -- always_fail_transient_cmd
    [ "$status" -ne 0 ]
    [ "$(attempt_count)" -eq "$BUILD_RETRY_MAX_ATTEMPTS" ]
    [[ "$output" == *"failed after ${BUILD_RETRY_MAX_ATTEMPTS} attempts"* ]]
}

@test "build_retry fails fast on a real Dockerfile error without retrying" {
    run build_retry -- always_fail_dockerfile_cmd
    [ "$status" -ne 0 ]
    # Must NOT have retried -- exactly one attempt, and the real error text
    # must still be visible, not swallowed.
    [ "$(attempt_count)" -eq 1 ]
    [[ "$output" == *"non-transient error"* ]]
    [[ "$output" == *"failing fast without retry"* ]]
    [[ "$output" == *"this-package-does-not-exist"* ]]
}

@test "build_retry propagates a real failure through a caller's set -e instead of silently reporting success" {
    # Regression test mirroring tests/bats/ghcr_retry.bats's identical case:
    # build_retry's own internal pipeline (`"$@" 2>&1 | tee ...`) must not
    # look like a bare failing statement under the caller's `set -e`, and
    # must not silently report success after exhausting every attempt.
    run bash -c '
        set -euo pipefail
        source "'"$repo_root"'/scripts/lib/build-retry.sh"
        sleep() { :; }
        export -f sleep
        BUILD_RETRY_MAX_ATTEMPTS=2
        BUILD_RETRY_BASE_BACKOFF_SECONDS=0
        always_fail() {
            echo "ERROR: (*service).Write failed: rpc error: code = Unavailable desc = ref layer-sha256:deadbeef locked for 100ms (since now): unavailable"
            return 1
        }
        if build_retry -- always_fail; then
            echo "BUG: reported success"
            exit 1
        fi
        echo "correctly observed failure"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"correctly observed failure"* ]]
    [[ "$output" != *"BUG"* ]]
}

@test "build_retry rejects a call missing the -- separator" {
    run build_retry flaky_transient_cmd
    [ "$status" -eq 2 ]
    [[ "$output" == *"expected -- before the command"* ]]
}
