#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: coverage for scripts/lib/trivy-db-lock.sh
# Why: both call sites depend on its exit-code contract
# From: Issue #1780 | Issue #1095

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    lock_lib="$repo_root/scripts/lib/trivy-db-lock.sh"
    cache_dir="$BATS_TEST_TMPDIR/cache"
    mkdir -p "$cache_dir"
}

@test "a successful wrapped command returns 0 and releases the lock" {
    run bash -c '
        set -euo pipefail
        source "'"$lock_lib"'"
        if trivy_db_locked_run "'"$cache_dir"'" 5 60 -- true; then
            echo "status=0"
        else
            echo "status=$?"
        fi
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=0"* ]]
    [ ! -d "$cache_dir/.trivy-db-update.lock" ]
}

@test "a wrapped command's failure propagates its real exit code, releases the lock, and does not abort the caller's own set -e script" {
    run bash -c '
        set -euo pipefail
        source "'"$lock_lib"'"
        if trivy_db_locked_run "'"$cache_dir"'" 5 60 -- bash -c "exit 42"; then
            echo "status=0"
        else
            echo "status=$?"
        fi
        echo "reached-end"
    '
    # The outer script itself must exit 0 -- if errexit had torn it down
    # mid-call, "reached-end" below would never print and $status would
    # reflect bash's own abrupt termination instead.
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=42"* ]]
    [[ "$output" == *"reached-end"* ]]
    [ ! -d "$cache_dir/.trivy-db-update.lock" ]
}

@test "a held, non-stale lock times out with status 2 and never runs the wrapped command" {
    mkdir -p "$cache_dir/.trivy-db-update.lock"
    marker="$BATS_TEST_TMPDIR/should-not-run"
    run bash -c '
        set -euo pipefail
        source "'"$lock_lib"'"
        if trivy_db_locked_run "'"$cache_dir"'" 1 60 -- touch "'"$marker"'"; then
            echo "status=0"
        else
            echo "status=$?"
        fi
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=2"* ]]
    [ ! -e "$marker" ]
    # The pre-held lock is untouched -- a timeout must never delete a lock
    # this caller does not own.
    [ -d "$cache_dir/.trivy-db-update.lock" ]
}

@test "a stale lock (older than stale_after) is reclaimed and the wrapped command runs" {
    mkdir -p "$cache_dir/.trivy-db-update.lock"
    past="$(( $(date +%s) - 120 ))"
    touch -d "@$past" "$cache_dir/.trivy-db-update.lock"
    run bash -c '
        set -euo pipefail
        source "'"$lock_lib"'"
        if trivy_db_locked_run "'"$cache_dir"'" 5 60 -- true; then
            echo "status=0"
        else
            echo "status=$?"
        fi
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=0"* ]]
    [[ "$output" == *"Reclaiming stale"* ]]
    [ ! -d "$cache_dir/.trivy-db-update.lock" ]
}

@test "both real call sites source the helper and invoke it as an if condition, never a bare statement" {
    ensure_fresh="$repo_root/.github/actions/trivy-db-ensure-fresh/action.yml"
    scheduled_refresh="$repo_root/.github/workflows/trivy-db-scheduled-refresh.yml"
    [ -f "$ensure_fresh" ] || fail "$ensure_fresh not found"
    [ -f "$scheduled_refresh" ] || fail "$scheduled_refresh not found"

    grep -q 'source "\$GITHUB_WORKSPACE/scripts/lib/trivy-db-lock.sh"' "$ensure_fresh" \
        || fail "trivy-db-ensure-fresh/action.yml does not source trivy-db-lock.sh"
    grep -q 'source "\$GITHUB_WORKSPACE/scripts/lib/trivy-db-lock.sh"' "$scheduled_refresh" \
        || fail "trivy-db-scheduled-refresh.yml does not source trivy-db-lock.sh"

    # Regression guard: neither call site may call the function as a bare
    # statement (that would silently reopen the errexit/RETURN-trap bug
    # this suite's second test above exists to catch).
    ! grep -qE '^\s*trivy_db_locked_run ' "$ensure_fresh" \
        || fail "trivy-db-ensure-fresh/action.yml calls trivy_db_locked_run as a bare statement, not an if condition"
    ! grep -qE '^\s*trivy_db_locked_run ' "$scheduled_refresh" \
        || fail "trivy-db-scheduled-refresh.yml calls trivy_db_locked_run as a bare statement, not an if condition"
}
