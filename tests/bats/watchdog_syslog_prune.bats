#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for services/watchdog/watchdog.sh's maybe_prune_syslog() (#633
# retention engine): the storage-budget/age-based pruning of syslog-ng's
# rotated/compressed output under SYSLOG_LOG_ROOT.
#
# Sources the real function via helpers/watchdog-helpers.sh's extraction
# range (same range watchdog_idempotence.bats uses -- maybe_prune_syslog()
# lives inside that range, right after maybe_purge(), so no helper change
# was needed). This function is pure filesystem I/O (find/du/stat/rm against
# a real directory tree) with no Docker/network boundary to stub, unlike
# check_and_maybe_restart()'s get_health()/restart_container() -- every test
# here runs the function completely unmodified against a real BATS_TEST_TMPDIR
# fixture tree.
#
# The issue's explicit requirement is an exact priority ordering: age-based
# deletion (retention-days floor) runs FIRST, then -- only if still over the
# size budget -- oldest-first deletion runs regardless of age. Proving this
# ordering requires more than "age pruning works" + "size pruning works"
# tested in isolation; a fixture is included ("combined priority ordering")
# where a file that survives the age pass (within the retention floor) is
# still removed by the size pass because it is the oldest survivor -- if the
# implementation ran size-then-age, or age-only, or size-only, this exact
# fixture's surviving file set would differ.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/watchdog-helpers-extracted.sh"

    # shellcheck source=tests/bats/helpers/watchdog-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/watchdog-helpers.sh"
    load_watchdog_functions "$repo_root" "$helper_file"

    log_root="$BATS_TEST_TMPDIR/syslog-root"
    mkdir -p "$log_root/hostA"

    export SYSLOG_ENABLED=true
    export SYSLOG_RETENTION_DAYS=30
    export SYSLOG_MAX_GB=10
    export SYSLOG_LOG_ROOT="$log_root"
    # Own stamp file per test, matching PURGE_STAMP's per-test isolation
    # convention elsewhere in this suite -- a shared/real stamp path would
    # make the rate-limit leak state across tests.
    export SYSLOG_PRUNE_STAMP="$BATS_TEST_TMPDIR/syslog-prune.stamp"
}

# Creates a file of the given size (in whole megabytes) at $log_root/hostA/$1
# with mtime backdated by $3 days. truncate makes a sparse file -- fast, and
# `du -sb`/`stat -c '%s'` both report the logical (allocated-size) byte count
# for a sparse file identically to a real one, which is all this function's
# size-budget arithmetic depends on.
make_log_file() {
    local name="$1" size_mb="$2" age_days="$3"
    local path="$log_root/hostA/$name"
    truncate -s "${size_mb}M" "$path"
    touch -d "-${age_days} days" "$path"
}

@test "maybe_prune_syslog is a fail-closed no-op when SYSLOG_ENABLED is not true" {
    make_log_file old.log 1 999
    SYSLOG_ENABLED=false maybe_prune_syslog
    [ -f "$log_root/hostA/old.log" ]
    # Unset entirely (not just "false") must also stay a no-op.
    unset SYSLOG_ENABLED
    maybe_prune_syslog
    [ -f "$log_root/hostA/old.log" ]
}

@test "maybe_prune_syslog age pass deletes files older than SYSLOG_RETENTION_DAYS and spares newer ones" {
    make_log_file old.log 1 40
    make_log_file new.log 1 1

    maybe_prune_syslog

    [ ! -f "$log_root/hostA/old.log" ]
    [ -f "$log_root/hostA/new.log" ]
}

@test "maybe_prune_syslog size pass is a no-op when total usage is under SYSLOG_MAX_GB" {
    make_log_file a.log 1 1
    make_log_file b.log 1 1

    maybe_prune_syslog

    [ -f "$log_root/hostA/a.log" ]
    [ -f "$log_root/hostA/b.log" ]
}

# The priority-ordering proof: day2.log is within the 30-day retention floor
# (20 days old) so the AGE pass must spare it, but it is the oldest survivor
# once day1.log (45 days old) is removed by the age pass, and the tree is
# still over the 1GB budget after that -- so the SIZE pass must remove it
# despite it being "within retention." day3.log (newest, 1 day old) must
# survive, proving deletion order is oldest-first, not newest-first or
# unordered. If age and size were not run in this exact sequence (or size
# pruning ran newest-first, or ignored the age pass's floor), this exact
# surviving set would differ.
@test "maybe_prune_syslog age-then-size ordering: size budget prunes an in-retention file the age pass spared" {
    make_log_file day1.log 100 45   # older than retention -> removed by age pass
    make_log_file day2.log 500 20   # within retention, but oldest survivor
    make_log_file day3.log 700 1    # within retention, newest

    SYSLOG_MAX_GB=1 maybe_prune_syslog

    [ ! -f "$log_root/hostA/day1.log" ]
    [ ! -f "$log_root/hostA/day2.log" ]
    [ -f "$log_root/hostA/day3.log" ]

    run du -sb "$log_root"
    [ "$status" -eq 0 ]
    local size_bytes; size_bytes=$(awk '{print $1}' <<< "$output")
    [ "$size_bytes" -le $((1 * 1024 * 1024 * 1024)) ]
}

# Complements the ordering test above: even when every file is within the
# retention floor, the size pass alone must still enforce the budget
# oldest-first. This isolates the size-pass behavior from any interaction
# with the age pass (nothing here is old enough for Pass 1 to touch).
@test "maybe_prune_syslog size pass alone deletes oldest-first regardless of age when all files are within retention" {
    make_log_file a.log 400 5
    make_log_file b.log 400 3
    make_log_file c.log 400 1

    SYSLOG_MAX_GB=1 maybe_prune_syslog

    # a.log (oldest) must go first; c.log (newest) must survive.
    [ ! -f "$log_root/hostA/a.log" ]
    [ -f "$log_root/hostA/c.log" ]
}

# Second invocation in the same run must be a true no-op: the stamp file
# rate-limits re-scanning, so nothing further is deleted or altered even if
# the tree would otherwise still be eligible for pruning (e.g. a file backdated
# after the first run, simulating what a naive unconditional rescan would
# catch).
@test "maybe_prune_syslog second run within the rate-limit window is a true no-op" {
    make_log_file old.log 1 40
    make_log_file new.log 1 1

    maybe_prune_syslog
    [ ! -f "$log_root/hostA/old.log" ]
    [ -f "$log_root/hostA/new.log" ]

    # If the stamp-file rate limit did not hold, this backdate would make
    # new.log eligible for age-based deletion on a second scan.
    touch -d '-999 days' "$log_root/hostA/new.log"
    maybe_prune_syslog
    [ -f "$log_root/hostA/new.log" ]
}

@test "maybe_prune_syslog clamps invalid SYSLOG_RETENTION_DAYS and SYSLOG_MAX_GB to safe defaults instead of aborting" {
    make_log_file a.log 1 1

    SYSLOG_RETENTION_DAYS='not-a-number' SYSLOG_MAX_GB='' run maybe_prune_syslog
    [ "$status" -eq 0 ]
    [ -f "$log_root/hostA/a.log" ]
}

@test "maybe_prune_syslog skips cleanly when SYSLOG_LOG_ROOT does not exist yet" {
    SYSLOG_LOG_ROOT="$BATS_TEST_TMPDIR/does-not-exist" run maybe_prune_syslog
    [ "$status" -eq 0 ]
}

# #757 review: the size pass must never unlink today's per-host active file
# (syslog-ng's live write target), even when it is the oldest/only file over
# budget. Deleting an open file only unlinks the directory entry -- the
# space is not reclaimed until syslog-ng itself closes/reopens it, and new
# log lines would keep going to the now-nameless inode.
@test "maybe_prune_syslog size pass never deletes today's active per-host log file" {
    local today; today="$(date -u +%Y%m%d).log"
    local path="$log_root/hostA/$today"
    # Must exceed the 1GB budget by itself (SYSLOG_MAX_GB is GiB, 1024^3
    # bytes) so the size pass actually attempts pruning -- otherwise this
    # test would pass trivially with no deletion attempted at all.
    truncate -s 2000M "$path"
    touch -d "-1 hours" "$path"

    SYSLOG_MAX_GB=1 maybe_prune_syslog

    [ -f "$path" ]
}

# Complements the test above: the active file is skipped, but older,
# non-active files must still be pruned oldest-first to work toward budget.
@test "maybe_prune_syslog size pass prunes older files around a protected active file" {
    local today; today="$(date -u +%Y%m%d).log"
    make_log_file old.log 500 5
    local active_path="$log_root/hostA/$today"
    truncate -s 900M "$active_path"
    touch -d "-1 hours" "$active_path"

    SYSLOG_MAX_GB=1 maybe_prune_syslog

    [ ! -f "$log_root/hostA/old.log" ]
    [ -f "$active_path" ]
}

# #757 review: a digit-only-but-huge SYSLOG_MAX_GB must not overflow the
# `max_gb * 1024^3` arithmetic into a negative budget, which would make the
# size pass treat any tree as over budget and delete everything it can.
@test "maybe_prune_syslog clamps an oversized SYSLOG_MAX_GB instead of overflowing the budget" {
    make_log_file a.log 1 1

    SYSLOG_MAX_GB=9999999999 run maybe_prune_syslog
    [ "$status" -eq 0 ]
    [ -f "$log_root/hostA/a.log" ]
}
