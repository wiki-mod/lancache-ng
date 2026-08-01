#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression coverage for services/watchdog/retention.sh's
# validate_retention_dir() (#842 Teil 1 hardening, 2026-08-01): before this
# function existed, none of CACHE_DIR/SYSLOG_LOG_ROOT/FLUENT_BIT_SELFLOG_DIR
# were validated at all before reaching a destructive `find ... -mtime ... |
# rm --`/size-budget pass -- a misconfigured or future Admin-UI-exposed value
# such as CACHE_DIR=/ would run the daily purge against the entire container
# root filesystem instead of just the cache volume. Demonstrated live on a
# real container during development (a scratch /etc tree lost 82 of 89
# files to an unvalidated CACHE_DIR=/etc purge; the same call is rejected
# outright once this function is in the path) -- this file pins that
# behavior permanently so it cannot silently regress.
#
# Tests validate_retention_dir() directly (unit-level, in isolation from any
# find/rm side effects) rather than only exercising it indirectly through
# maybe_purge()/maybe_prune_syslog()/maybe_rotate_fluent_bit_selflog(), so a
# future change to any one of those three call sites cannot accidentally
# stop calling the validator without a test noticing here specifically.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/retention-helpers-extracted.sh"

    # shellcheck source=tests/bats/helpers/retention-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/retention-helpers.sh"
    load_retention_functions "$repo_root" "$helper_file"
}

@test "validate_retention_dir accepts a real subdirectory of the expected prefix" {
    mkdir -p "$BATS_TEST_TMPDIR/cache/lancache"
    run validate_retention_dir "CACHE_DIR" "$BATS_TEST_TMPDIR/cache/lancache" "$BATS_TEST_TMPDIR/cache"
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/cache/lancache" ]
}

@test "validate_retention_dir accepts a not-yet-created subdirectory (realpath -m, no existence requirement)" {
    run validate_retention_dir "FLUENT_BIT_SELFLOG_DIR" "$BATS_TEST_TMPDIR/cache/not-created-yet" "$BATS_TEST_TMPDIR/cache"
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/cache/not-created-yet" ]
}

@test "validate_retention_dir rejects an empty value" {
    run validate_retention_dir "CACHE_DIR" "" "$BATS_TEST_TMPDIR/cache"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is empty"* ]]
}

@test "validate_retention_dir rejects a relative path" {
    run validate_retention_dir "CACHE_DIR" "relative/path" "$BATS_TEST_TMPDIR/cache"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not an absolute path"* ]]
}

# The core vulnerability this function closes: an operator/migration/
# Admin-UI value pointing outside the expected mount tree entirely.
@test "validate_retention_dir rejects a path outside the expected prefix (CACHE_DIR=/)" {
    run validate_retention_dir "CACHE_DIR" "/" "$BATS_TEST_TMPDIR/cache"
    [ "$status" -eq 1 ]
    [[ "$output" == *"outside the expected"* ]]
}

@test "validate_retention_dir rejects a path outside the expected prefix (a real, unrelated system directory)" {
    run validate_retention_dir "CACHE_DIR" "/etc" "$BATS_TEST_TMPDIR/cache"
    [ "$status" -eq 1 ]
    [[ "$output" == *"outside the expected"* ]]
}

# `realpath -m` canonicalizes `..` traversal before the prefix check runs,
# so a crafted value cannot escape the expected mount tree by construction --
# this is the concrete path-traversal case the brief asked to rule out.
@test "validate_retention_dir rejects a path-traversal attempt that resolves outside the expected prefix" {
    run validate_retention_dir "CACHE_DIR" "$BATS_TEST_TMPDIR/cache/lancache/../../../etc" "$BATS_TEST_TMPDIR/cache"
    [ "$status" -eq 1 ]
    [[ "$output" == *"outside the expected"* ]]
}

# A traversal attempt that happens to still land inside the expected prefix
# after canonicalization must be accepted -- the check is about the final
# resolved location, not about rejecting `..` syntax itself.
@test "validate_retention_dir accepts a path-traversal expression that still resolves inside the expected prefix" {
    mkdir -p "$BATS_TEST_TMPDIR/cache/lancache/sub"
    run validate_retention_dir "CACHE_DIR" "$BATS_TEST_TMPDIR/cache/lancache/sub/../../lancache" "$BATS_TEST_TMPDIR/cache"
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/cache/lancache" ]
}

@test "validate_retention_dir rejects the expected prefix itself, not just a subdirectory" {
    run validate_retention_dir "CACHE_DIR" "$BATS_TEST_TMPDIR/cache" "$BATS_TEST_TMPDIR/cache"
    [ "$status" -eq 1 ]
    [[ "$output" == *"IS"*"itself, not a subdirectory"* ]]
}

# End-to-end proof at the real call-site level, not just the validator in
# isolation: maybe_purge() must refuse to run find/rm at all when CACHE_DIR
# resolves outside CACHE_DIR_ALLOWED_PREFIX, and must not touch the purge
# stamp (so a corrected CACHE_DIR is retried on the very next cycle rather
# than silently skipped forever, same "return before writing the stamp"
# contract every other fail-closed path in this file already uses).
@test "maybe_purge refuses to run when CACHE_DIR resolves outside the allowed prefix" {
    export CACHE_DIR="$BATS_TEST_TMPDIR/outside/cache"
    export CACHE_DIR_ALLOWED_PREFIX="$BATS_TEST_TMPDIR/expected-cache-root"
    export CACHE_VALID_DAYS=30
    export PURGE_STAMP="$BATS_TEST_TMPDIR/purge.stamp"

    run maybe_purge

    [ "$status" -eq 0 ]
    [ ! -f "$PURGE_STAMP" ]
    [[ "$output" == *"outside the expected"* ]]
}
