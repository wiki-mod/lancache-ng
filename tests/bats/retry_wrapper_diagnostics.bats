#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Guards the retry wrappers against regressing back to single-line "all
# attempts failed" exits without raw attempt-state diagnostics.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

fail() {
    echo "$1" >&2
    return 1
}

assert_contains() {
    file="$1"
    needle="$2"
    grep -F "$needle" "$file" >/dev/null || fail "$file does not contain: $needle"
}

@test "buildx-setup-retry prints raw attempt outputs before its final failure" {
    action_file="$repo_root/.github/actions/buildx-setup-retry/action.yml"
    assert_contains "$action_file" "dump_retry_diagnostics()"
    assert_contains "$action_file" "attempt%s.nodes<<BUILDX_NODES"
    assert_contains "$action_file" "attempt%s.flags=%s"
}

@test "ghcr-build-push-retry prints raw attempt digests before its final failure" {
    action_file="$repo_root/.github/actions/ghcr-build-push-retry/action.yml"
    assert_contains "$action_file" "dump_retry_diagnostics()"
    assert_contains "$action_file" "attempt1.digest=%s"
    assert_contains "$action_file" "attempt4.digest=%s"
}

@test "ghcr-attest-retry prints raw subject and attempt outcomes before its final failure" {
    action_file="$repo_root/.github/actions/ghcr-attest-retry/action.yml"
    assert_contains "$action_file" "dump_retry_diagnostics()"
    assert_contains "$action_file" "subject-name=%s"
    assert_contains "$action_file" "attempt4.outcome=%s"
}

@test "trivy-scan-retry prints raw attempt classification before its final failure" {
    action_file="$repo_root/.github/actions/trivy-scan-retry/action.yml"
    assert_contains "$action_file" "dump_retry_diagnostics()"
    assert_contains "$action_file" "report-path=%s"
    assert_contains "$action_file" "attempt1.error-kind=%s"
    assert_contains "$action_file" "attempt4.retryable=%s"
}
