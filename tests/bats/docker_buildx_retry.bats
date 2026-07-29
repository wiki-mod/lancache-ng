#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Fast, Docker-free unit coverage for scripts/lib/docker-buildx-retry.sh
# (issue #1223, AG-CI-013), mirroring tests/bats/build_retry.bats's approach
# for the analogous build-tools.yml wrapper: drives docker_buildx_retry()
# with a stub command that fails a controlled number of times before
# succeeding (or never succeeds) and asserts on attempt count and exit code,
# since the real transient BuildKit content-store layer-lock race is
# host-contention-dependent and not reproducible on demand.
#
# This suite exists specifically because scripts/lib/build-retry.sh shipped
# with the identical pipe+status bug this file's docker_buildx_retry() also
# had (both use `if "$@" 2>&1 | tee "$log_file"; then status=0; else
# status=${PIPESTATUS[0]}; fi`, which silently records status=0 whenever
# pipefail is not active in the sourcing shell -- e.g. exactly a bats test
# harness) -- build-retry.sh had test coverage that caught it; this file did
# not, so the bug shipped undetected in PR #1238. This suite closes that gap.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/lib/docker-buildx-retry.sh
    source "$repo_root/scripts/lib/docker-buildx-retry.sh"

    sleep() { :; }
    export -f sleep

    # shellcheck disable=SC2034 # read by docker_buildx_retry() in
    # scripts/lib/docker-buildx-retry.sh, sourced above -- shellcheck cannot
    # see the cross-file read.
    DOCKER_BUILDX_RETRY_MAX_ATTEMPTS=3
    # shellcheck disable=SC2034
    DOCKER_BUILDX_RETRY_BACKOFF_SECONDS=0

    attempt_log="$BATS_TEST_TMPDIR/attempts"
    : > "$attempt_log"
}

# Number of times the stub command below was actually invoked.
attempt_count() {
    wc -l < "$attempt_log"
}

# The exact error text from issue #1222/#1223's real failures -- only the
# digest/duration/timestamp varied between occurrences; one real occurrence
# verbatim.
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

# The exact error text from the second confirmed transient signature
# (2026-07-29, current_dev's own Build & Push run for the #1272 merge
# commit): a golang:latest-toolchain-internal panic inside build-tools'
# actionlint-builder stage, verbatim.
real_go_panic_error() {
    cat <<'EOF'
#10 108.6 panic: methodref has no signature
#10 ERROR: process "/bin/bash -o pipefail -c set -euo pipefail; ..." did not complete successfully: exit code: 1
EOF
}

# Fails FAKE_FAIL_COUNT times printing the go-panic transient signature, then
# succeeds. Appends one line per invocation to $attempt_log.
flaky_go_panic_cmd() {
    echo "attempt" >> "$attempt_log"
    local calls
    calls=$(wc -l < "$attempt_log")
    if (( calls <= "${FAKE_FAIL_COUNT:-0}" )); then
        real_go_panic_error
        return 1
    fi
    echo "build succeeded"
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

@test "docker_buildx_retry succeeds immediately when the command succeeds on the first try" {
    FAKE_FAIL_COUNT=0
    run docker_buildx_retry -- flaky_transient_cmd
    [ "$status" -eq 0 ]
    [ "$(attempt_count)" -eq 1 ]
}

@test "docker_buildx_retry retries a transient failure and succeeds once the command stops failing" {
    FAKE_FAIL_COUNT=2
    run docker_buildx_retry -- flaky_transient_cmd
    [ "$status" -eq 0 ]
    # 2 failed attempts + 1 successful attempt = 3 total.
    [ "$(attempt_count)" -eq 3 ]
    [[ "$output" == *"transient layer-lock error detected"* ]]
}

@test "docker_buildx_retry gives up and returns nonzero after DOCKER_BUILDX_RETRY_MAX_ATTEMPTS consecutive transient failures" {
    run docker_buildx_retry -- always_fail_transient_cmd
    [ "$status" -ne 0 ]
    [ "$(attempt_count)" -eq "$DOCKER_BUILDX_RETRY_MAX_ATTEMPTS" ]
    [[ "$output" == *"still failing with the transient layer-lock signature after ${DOCKER_BUILDX_RETRY_MAX_ATTEMPTS} attempts"* ]]
}

@test "docker_buildx_retry retries the golang:latest-toolchain-panic transient signature and succeeds once it stops recurring" {
    FAKE_FAIL_COUNT=2
    run docker_buildx_retry -- flaky_go_panic_cmd
    [ "$status" -eq 0 ]
    # 2 failed attempts + 1 successful attempt = 3 total.
    [ "$(attempt_count)" -eq 3 ]
    [[ "$output" == *"transient layer-lock error detected"* ]]
}

@test "docker_buildx_retry fails fast on a real Dockerfile error without retrying" {
    run docker_buildx_retry -- always_fail_dockerfile_cmd
    [ "$status" -ne 0 ]
    # Must NOT have retried -- exactly one attempt, and the real error text
    # must still be visible, not swallowed.
    [ "$(attempt_count)" -eq 1 ]
    [[ "$output" == *"without the known transient layer-lock signature"* ]]
    [[ "$output" == *"this-package-does-not-exist"* ]]
}

@test "docker_buildx_retry propagates a real failure through a caller's set -e instead of silently reporting success" {
    run bash -c "
        set -e
        source '$repo_root/scripts/lib/docker-buildx-retry.sh'
        DOCKER_BUILDX_RETRY_MAX_ATTEMPTS=1
        always_fail_dockerfile_cmd() { echo 'attempt'; $(declare -f real_dockerfile_error); real_dockerfile_error; return 1; }
        docker_buildx_retry -- always_fail_dockerfile_cmd
        echo 'UNREACHABLE: set -e should have aborted on the nonzero return above'
    "
    [ "$status" -ne 0 ]
    [[ "$output" != *"UNREACHABLE"* ]]
}

@test "docker_buildx_retry rejects a call missing the -- separator" {
    run docker_buildx_retry flaky_transient_cmd
    [ "$status" -eq 2 ]
    [[ "$output" == *"expected -- before the command to run"* ]]
}
