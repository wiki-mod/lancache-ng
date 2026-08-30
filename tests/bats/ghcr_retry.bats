#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
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
    # relogin_calls is tracked via a file, not a plain shell variable: this
    # stub is invoked as `printf ... | docker login ...` inside
    # ghcr_relogin, and the right-hand side of a pipeline runs in its own
    # subshell in bash by default (no `lastpipe`), so a variable increment
    # here would be invisible to the test's own shell once the pipe exits --
    # a real bug caught by CI (see "re-authenticates once per retry" below).
    # Appends survive across subshells the same way $attempt_log already
    # relies on for counting flaky_cmd invocations.
    docker() {
        if [[ "$1" = "login" ]]; then
            echo "relogin" >> "$relogin_log"
            return "${FAKE_RELOGIN_EXIT:-0}"
        fi
        return 0
    }
    export -f sleep docker

    # shellcheck disable=SC2034 # read by ghcr_retry() in scripts/lib/ghcr-retry.sh,
    # sourced above -- shellcheck cannot see the cross-file read.
    GHCR_RETRY_BACKOFF_SECONDS=0
    GHCR_RETRY_MAX_ATTEMPTS=4
    relogin_log="$BATS_TEST_TMPDIR/relogins"
    : > "$relogin_log"
    attempt_log="$BATS_TEST_TMPDIR/attempts"
    : > "$attempt_log"
}

# Number of times the docker() stub above observed a `docker login` call.
relogin_calls() {
    wc -l < "$relogin_log"
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
    [ "$(relogin_calls)" -eq 0 ]
}

@test "ghcr_retry re-authenticates once per retry, not once total" {
    FAKE_FAIL_COUNT=3
    ghcr_retry ghcr.io testuser testpass -- flaky_cmd
    # 3 failed attempts -> 3 re-logins before the 4th (successful) attempt.
    [ "$(relogin_calls)" -eq 3 ]
}

@test "ghcr_retry retries without a fresh login when no credentials are given" {
    FAKE_FAIL_COUNT=1
    run ghcr_retry ghcr.io "" "" -- flaky_cmd
    [ "$status" -eq 0 ]
    [ "$(relogin_calls)" -eq 0 ]
    [[ "$output" == *"retrying without a fresh login"* ]]
}

@test "ghcr_retry returns immediately on GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE, without retrying, backing off, or re-authenticating" {
    # A wrapped command can signal "this is a permanent failure, retrying
    # cannot help" (e.g. scripts/lib/staging-ancestor-fallback.sh's
    # _saf_github_api_get classifying a 401/404 GitHub API response) by
    # exiting with this specific reserved code. ghcr_retry must stop right
    # there -- one attempt total, no backoff sleep, no relogin -- rather than
    # spending its whole retry budget on an error no amount of retrying or
    # re-authenticating can fix.
    permanent_fail_cmd() {
        echo "attempt" >> "$attempt_log"
        return "$GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE"
    }
    export -f permanent_fail_cmd
    run ghcr_retry ghcr.io testuser testpass -- permanent_fail_cmd
    [ "$status" -eq "$GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE" ]
    [ "$(wc -l < "$attempt_log")" -eq 1 ]
    [ "$(relogin_calls)" -eq 0 ]
    [[ "$output" == *"permanent (non-retryable) error"* ]]
}

@test "ghcr_retry still retries an ordinary (non-permanent) failure exactly as before, unaffected by the new exit-code check" {
    # Regression guard: adding the permanent-failure early exit must not
    # change behavior for every OTHER nonzero exit code -- only the one
    # specific reserved code short-circuits the retry loop.
    FAKE_FAIL_COUNT=2
    run ghcr_retry ghcr.io testuser testpass -- flaky_cmd
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$attempt_log")" -eq 3 ]
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

@test "ghcr_retry's captured stdout stays clean when a mid-retry relogin writes to stdout" {
    # Real `docker login` prints "Login Succeeded" to STDOUT, not stderr (only
    # its credential-store warning goes to stderr). The earlier stub in
    # setup() diverged from that reality by writing nothing to stdout, which
    # let this bug hide: a caller that captures ghcr_retry's output via
    # `$(...)` (e.g. `digest="$(ghcr_retry ... -- docker buildx imagetools
    # inspect ...)"`) would get "Login Succeeded" spliced into the captured
    # value on any retry firing mid-substitution -- corrupting the digest on
    # exactly the transient-401-then-retry case this file exists to survive.
    docker() {
        if [[ "$1" = "login" ]]; then
            echo "Login Succeeded"
            return 0
        fi
        return 0
    }
    export -f docker
    FAKE_FAIL_COUNT=1
    real_cmd() {
        echo "attempt" >> "$attempt_log"
        local calls
        calls=$(wc -l < "$attempt_log")
        if (( calls <= "${FAKE_FAIL_COUNT:-0}" )); then
            return 1
        fi
        echo "sha256:cleanvalue"
    }
    export -f real_cmd
    captured="$(ghcr_retry ghcr.io testuser testpass -- real_cmd 2>/dev/null)"
    [ "$captured" = "sha256:cleanvalue" ]
}

# Coverage for resolve_manifest_digest (PR #1523, AG-CODE-013): extracted out
# of near-identical duplicate digest-strip logic previously copied between
# scripts/render-full-setup-digest-override.sh and
# scripts/select-build-tools-image.sh.

@test "resolve_manifest_digest prints the stripped digest on a clean inspect result, no credentials" {
    docker() {
        if [[ "$1" = "buildx" && "$2" = "imagetools" && "$3" = "inspect" ]]; then
            echo '"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
            return 0
        fi
        return 1
    }
    export -f docker
    run resolve_manifest_digest "ghcr.io/wiki-mod/lancache-ng/build-tools:nightly"
    [ "$status" -eq 0 ]
    [ "$output" = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]
}

@test "resolve_manifest_digest fails on an unparsable/missing digest" {
    docker() {
        if [[ "$1" = "buildx" ]]; then
            return 1
        fi
        return 1
    }
    export -f docker
    run resolve_manifest_digest "ghcr.io/wiki-mod/lancache-ng/build-tools:nightly"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "resolve_manifest_digest rejects an uppercase-hex digest instead of silently accepting it" {
    # Regression test for the real drift this consolidation fixed:
    # render-full-setup-digest-override.sh's original pattern accepted
    # [0-9a-fA-F], which would have let a value no real registry call can
    # legitimately produce pass validation.
    docker() {
        if [[ "$1" = "buildx" ]]; then
            echo '"sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"'
            return 0
        fi
        return 1
    }
    export -f docker
    run resolve_manifest_digest "ghcr.io/wiki-mod/lancache-ng/build-tools:nightly"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "resolve_manifest_digest routes through ghcr_retry (with relogin) when credentials are given" {
    FAKE_FAIL_COUNT=1
    docker() {
        if [[ "$1" = "login" ]]; then
            echo "relogin" >> "$relogin_log"
            return 0
        fi
        if [[ "$1" = "buildx" ]]; then
            echo "attempt" >> "$attempt_log"
            local calls
            calls=$(wc -l < "$attempt_log")
            if (( calls <= "${FAKE_FAIL_COUNT:-0}" )); then
                return 1
            fi
            echo '"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
            return 0
        fi
        return 1
    }
    export -f docker
    run resolve_manifest_digest "ghcr.io/wiki-mod/lancache-ng/build-tools:nightly" testuser testpass
    [ "$status" -eq 0 ]
    [ "$output" = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]
    [ "$(relogin_calls)" -eq 1 ]
}

@test "resolve_manifest_digest does not retry when no credentials are given (single unwrapped attempt)" {
    docker() {
        if [[ "$1" = "buildx" ]]; then
            echo "attempt" >> "$attempt_log"
            return 1
        fi
        return 1
    }
    export -f docker
    run resolve_manifest_digest "ghcr.io/wiki-mod/lancache-ng/build-tools:nightly"
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$attempt_log")" -eq 1 ]
}

# What: the registry argument defaults to ghcr.io when omitted.
# Why: every pre-existing caller passes three args and must not change.
# From: PR #1742 | Refs #1683
@test "resolve_manifest_digest relogs in against ghcr.io by default" {
    FAKE_FAIL_COUNT=1
    docker() {
        if [[ "$1" = "login" ]]; then
            echo "$2" >> "$relogin_log"
            return 0
        fi
        if [[ "$1" = "buildx" ]]; then
            echo "attempt" >> "$attempt_log"
            local calls
            calls=$(wc -l < "$attempt_log")
            if (( calls <= "${FAKE_FAIL_COUNT:-0}" )); then
                return 1
            fi
            echo '"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"'
            return 0
        fi
        return 1
    }
    export -f docker
    run resolve_manifest_digest "ghcr.io/wiki-mod/lancache-ng/build-tools:nightly" testuser testpass
    [ "$status" -eq 0 ]
    [ "$(cat "$relogin_log")" = "ghcr.io" ]
}

# What: an explicit registry is the one re-authenticated against.
# Why: Docker Hub creds must never produce a docker login to ghcr.io.
# From: PR #1742 | Refs #1683
@test "resolve_manifest_digest relogs in against an explicitly given registry" {
    FAKE_FAIL_COUNT=1
    docker() {
        if [[ "$1" = "login" ]]; then
            echo "$2" >> "$relogin_log"
            return 0
        fi
        if [[ "$1" = "buildx" ]]; then
            echo "attempt" >> "$attempt_log"
            local calls
            calls=$(wc -l < "$attempt_log")
            if (( calls <= "${FAKE_FAIL_COUNT:-0}" )); then
                return 1
            fi
            echo '"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"'
            return 0
        fi
        return 1
    }
    export -f docker
    run resolve_manifest_digest "rust:latest" hubuser hubtoken docker.io
    [ "$status" -eq 0 ]
    [ "$(cat "$relogin_log")" = "docker.io" ]
}
