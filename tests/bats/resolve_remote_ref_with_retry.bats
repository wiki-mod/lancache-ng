#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Proves the remote-ref resolver's success, retry, and exhausted-budget paths offline.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/untracked/resolve-remote-ref-with-retry.sh"
    fake_bin="$BATS_TEST_TMPDIR/bin"
    attempt_log="$BATS_TEST_TMPDIR/attempts"
    mkdir -p "$fake_bin"
    : > "$attempt_log"

    cat > "$fake_bin/git" <<'EOF'
#!/bin/bash
echo attempt >> "$ATTEMPT_LOG"
attempts="$(wc -l < "$ATTEMPT_LOG")"
if ((attempts <= FAIL_COUNT)); then
    exit "${FAIL_EXIT_CODE:-128}"
fi
printf '%s\t%s\n' '0123456789abcdef0123456789abcdef01234567' 'refs/pull/1/head'
EOF
    chmod +x "$fake_bin/git"
}

# A successful lookup must return only the commit SHA expected by workflow comparisons.
@test "returns the exact remote head SHA" {
    run env PATH="$fake_bin:$PATH" ATTEMPT_LOG="$attempt_log" FAIL_COUNT=0 \
        REMOTE_REF_BACKOFF_SECONDS=0 bash "$script" origin refs/pull/1/head

    [ "$status" -eq 0 ]
    [ "$output" = "0123456789abcdef0123456789abcdef01234567" ]
    [ "$(wc -l < "$attempt_log")" -eq 1 ]
}

# Transient failures must consume retries rather than immediately admitting stale work.
@test "retries transient failures before succeeding" {
    run env PATH="$fake_bin:$PATH" ATTEMPT_LOG="$attempt_log" FAIL_COUNT=2 \
        REMOTE_REF_BACKOFF_SECONDS=0 bash "$script" origin refs/pull/1/head

    [ "$status" -eq 0 ]
    [[ "$output" == *"0123456789abcdef0123456789abcdef01234567"* ]]
    [ "$(wc -l < "$attempt_log")" -eq 3 ]
}

# Exhaustion remains fail-open at the workflow call site, but the resolver must report failure.
@test "fails after the bounded retry budget is exhausted" {
    run env PATH="$fake_bin:$PATH" ATTEMPT_LOG="$attempt_log" FAIL_COUNT=9 \
        REMOTE_REF_MAX_ATTEMPTS=4 REMOTE_REF_BACKOFF_SECONDS=0 \
        bash "$script" origin refs/pull/1/head

    [ "$status" -eq 1 ]
    [[ "$output" == *"failed after 4 attempts"* ]]
    [ "$(wc -l < "$attempt_log")" -eq 4 ]
}

# `git ls-remote --exit-code` exits 2 specifically when no ref matches at all
# (a force-deleted branch, a closed PR) -- a permanent result, not a network
# blip, so it must not consume the retry budget or the backoff sleep.
@test "does not retry a permanent 'ref not found' failure (exit code 2)" {
    run env PATH="$fake_bin:$PATH" ATTEMPT_LOG="$attempt_log" FAIL_COUNT=9 \
        FAIL_EXIT_CODE=2 REMOTE_REF_MAX_ATTEMPTS=4 REMOTE_REF_BACKOFF_SECONDS=0 \
        bash "$script" origin refs/pull/1/head

    [ "$status" -eq 2 ]
    [[ "$output" == *"does not exist"* ]]
    [ "$(wc -l < "$attempt_log")" -eq 1 ]
}
