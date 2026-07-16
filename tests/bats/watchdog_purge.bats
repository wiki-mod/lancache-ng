#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for services/watchdog/watchdog.sh's maybe_purge() (#872): before
# this fix, a missing CACHE_DIR left the purge silently skipped with no log
# line, yet the rate-limit stamp file was still written unconditionally --
# the daily purge silently never ran again, believed to have run. `find`
# errors were also swallowed via `2>/dev/null`, unlike the sibling
# maybe_prune_syslog() (see watchdog_syslog_prune.bats), which logs them.
#
# No dedicated test file existed for maybe_purge() before this PR (only a
# passing mention in watchdog_syslog_prune.bats's header comment) -- this
# closes that gap as well as proving the specific fixes.
#
# Sources the real function via helpers/watchdog-helpers.sh; maybe_purge()
# is pure filesystem I/O (find/rm against a real directory tree, plus a
# stamp file), so every test here runs it completely unmodified against a
# real BATS_TEST_TMPDIR fixture, same approach as watchdog_syslog_prune.bats
# uses for its sibling function.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/watchdog-helpers-extracted.sh"

    # shellcheck source=tests/bats/helpers/watchdog-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/watchdog-helpers.sh"
    load_watchdog_functions "$repo_root" "$helper_file"

    cache_dir="$BATS_TEST_TMPDIR/cache"
    mkdir -p "$cache_dir"

    export CACHE_DIR="$cache_dir"
    export CACHE_VALID_DAYS=30
    # Own stamp file per test, matching the project's per-test isolation
    # convention for rate-limited stamp files elsewhere in this suite.
    export PURGE_STAMP="$BATS_TEST_TMPDIR/purge.stamp"
}

make_cache_file() {
    local name="$1" age_days="$2"
    local path="$cache_dir/$name"
    truncate -s 1M "$path"
    touch -d "-${age_days} days" "$path"
}

@test "maybe_purge removes files older than CACHE_VALID_DAYS and spares newer ones" {
    make_cache_file old.bin 40
    make_cache_file new.bin 1

    maybe_purge

    [ ! -f "$cache_dir/old.bin" ]
    [ -f "$cache_dir/new.bin" ]
    [ -f "$PURGE_STAMP" ]
}

@test "maybe_purge is rate-limited by PURGE_STAMP within 24h" {
    make_cache_file old.bin 40
    echo "$(date +%s)" > "$PURGE_STAMP"

    maybe_purge

    # The stamp says a purge already ran within the last 24h, so this call
    # must be a no-op even though old.bin is well past CACHE_VALID_DAYS.
    [ -f "$cache_dir/old.bin" ]
}

# Core fix #1: a missing CACHE_DIR used to fall through to the unconditional
# stamp write at the bottom of the function with no log line at all -- the
# daily purge silently never ran again, and nothing on disk or in the logs
# told an operator that. The fixed behavior must both skip cleanly (no
# crash under `set -e`) and leave the stamp untouched so the next cycle
# retries instead of believing a purge happened.
@test "maybe_purge does not stamp success when CACHE_DIR does not exist" {
    export CACHE_DIR="$BATS_TEST_TMPDIR/does-not-exist"

    run maybe_purge

    [ "$status" -eq 0 ]
    [ ! -f "$PURGE_STAMP" ]
    [[ "$output" == *"does not exist"* ]]
}

# Complements the test above across a real restart cycle: a watchdog that
# starts with CACHE_DIR briefly unmounted, then has it appear (volume
# mount finishing, disk coming online, etc.), must still purge once the
# directory becomes available instead of having already "used up" its daily
# stamp on the earlier no-op.
@test "maybe_purge purges normally once CACHE_DIR appears after an earlier missing-dir cycle" {
    export CACHE_DIR="$BATS_TEST_TMPDIR/appears-later"
    run maybe_purge
    [ "$status" -eq 0 ]
    [ ! -f "$PURGE_STAMP" ]

    mkdir -p "$CACHE_DIR"
    cache_dir="$CACHE_DIR"
    make_cache_file old.bin 40

    maybe_purge
    [ ! -f "$cache_dir/old.bin" ]
    [ -f "$PURGE_STAMP" ]
}

# Core fix #2: `find ... 2>/dev/null` used to hide real find errors (e.g.
# permission denied), unlike maybe_prune_syslog()'s equivalent pass, which
# logs them. Stubs `find` itself to fail with a distinctive stderr message,
# isolating the "does maybe_purge surface and not paper over a real find
# failure" behavior from whatever conditions actually make find fail on a
# given filesystem.
@test "maybe_purge logs a real find error instead of swallowing it, and does not stamp success" {
    find() { echo "simulated permission denied" >&2; return 1; }

    run maybe_purge

    [ "$status" -eq 0 ]
    [ ! -f "$PURGE_STAMP" ]
    [[ "$output" == *"ERROR: find failed while scanning"* ]]
    [[ "$output" == *"simulated permission denied"* ]]
}

@test "maybe_purge only stamps success after a real purge completes" {
    make_cache_file old.bin 40
    [ ! -f "$PURGE_STAMP" ]
    maybe_purge
    [ -f "$PURGE_STAMP" ]
}
