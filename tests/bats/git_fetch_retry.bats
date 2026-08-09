#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/lib/git-fetch-retry.sh's git_fetch_retry(): a fake
# `git` function stands in for the real binary so each case can script an
# exact sequence of successes/failures without depending on real network
# conditions, mirroring this project's existing fake-external-command
# pattern for other retry wrappers and CLI mocks.

setup() {
    lib="$BATS_TEST_DIRNAME/../../scripts/lib/git-fetch-retry.sh"
    # shellcheck source=/dev/null
    source "$lib"
    GIT_FETCH_RETRY_BACKOFF_SECONDS=0
}

@test "succeeds immediately when git fetch succeeds on the first attempt, no retry logged" {
    git() { echo "already up to date"; return 0; }
    run git_fetch_retry origin main
    [ "$status" -eq 0 ]
    [[ "$output" != *"retrying"* ]]
}

@test "retries a known-transient failure and succeeds once the underlying call recovers" {
    call_count_file="$BATS_TEST_TMPDIR/calls"
    printf '0' > "$call_count_file"
    git() {
        local n; n=$(<"$call_count_file")
        n=$((n + 1))
        printf '%s' "$n" > "$call_count_file"
        if [ "$n" -lt 3 ]; then
            echo "fatal: unable to access 'https://example.invalid/': Connection reset by peer" >&2
            return 1
        fi
        echo "ok"
        return 0
    }
    run git_fetch_retry origin main
    [ "$status" -eq 0 ]
    [ "$(cat "$call_count_file")" -eq 3 ]
    [[ "$output" == *"retrying"* ]]
}

@test "retries transient GitHub HTTP status failures and succeeds after recovery" {
    call_count_file="$BATS_TEST_TMPDIR/calls"
    printf '0' > "$call_count_file"
    git() {
        local n; n=$(<"$call_count_file")
        n=$((n + 1))
        printf '%s' "$n" > "$call_count_file"
        case "$n" in
            1)
                echo "fatal: unable to access 'https://github.com/example/repo/': The requested URL returned error: 502" >&2
                return 1
                ;;
            2)
                echo "error: RPC failed; HTTP 503 curl 22 The requested URL returned error: 503" >&2
                return 1
                ;;
        esac
        echo "ok"
        return 0
    }
    run git_fetch_retry origin main
    [ "$status" -eq 0 ]
    [ "$(cat "$call_count_file")" -eq 3 ]
    [[ "$output" == *"retrying"* ]]
}

@test "retries a rate-limit response but leaves permanent HTTP 4xx failures immediate" {
    call_count_file="$BATS_TEST_TMPDIR/calls"
    printf '0' > "$call_count_file"
    git() {
        local n; n=$(<"$call_count_file")
        n=$((n + 1))
        printf '%s' "$n" > "$call_count_file"
        if [ "$n" -eq 1 ]; then
            echo "fatal: unable to access 'https://github.com/example/repo/': The requested URL returned error: 429" >&2
        else
            echo "fatal: unable to access 'https://github.com/example/repo/': The requested URL returned error: 404" >&2
        fi
        return 1
    }
    run git_fetch_retry origin main
    [ "$status" -eq 1 ]
    [ "$(cat "$call_count_file")" -eq 2 ]
    [ "$(grep -c 'retrying' <<<"$output")" -eq 1 ]
}

@test "does not retry a non-transient failure -- fails immediately on attempt 1" {
    call_count_file="$BATS_TEST_TMPDIR/calls"
    printf '0' > "$call_count_file"
    git() {
        local n; n=$(<"$call_count_file")
        n=$((n + 1))
        printf '%s' "$n" > "$call_count_file"
        echo "fatal: couldn't find remote ref refs/heads/does-not-exist" >&2
        return 1
    }
    run git_fetch_retry origin does-not-exist
    [ "$status" -eq 1 ]
    [ "$(cat "$call_count_file")" -eq 1 ]
    [[ "$output" != *"retrying"* ]]
}

@test "gives up and returns failure once GIT_FETCH_RETRY_MAX_ATTEMPTS is exhausted" {
    GIT_FETCH_RETRY_MAX_ATTEMPTS=3
    call_count_file="$BATS_TEST_TMPDIR/calls"
    printf '0' > "$call_count_file"
    git() {
        local n; n=$(<"$call_count_file")
        n=$((n + 1))
        printf '%s' "$n" > "$call_count_file"
        echo "fatal: The remote end hung up unexpectedly" >&2
        return 1
    }
    run git_fetch_retry origin main
    [ "$status" -eq 1 ]
    [ "$(cat "$call_count_file")" -eq 3 ]
}
