#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Fast, Docker-free unit coverage for scripts/lib/quickstart-compose-lock.sh
# (issue #838). Unlike scripts/lib/promote-lock.sh's bats coverage (a git-ref
# compare-and-swap exercised against a local bare repo), this file's
# primitive is a plain host-local flock, so contention is proven with real,
# genuinely separate `bash` processes racing over a throwaway
# $BATS_TEST_TMPDIR lock file -- the same mechanism two real CI jobs on the
# same runner host would hit on the real /tmp lock path.
#
# The design point this suite exists to prove empirically (not just assert
# by reasoning) is the file header's central claim: `exec {fd}>...; flock`
# inside a function keeps the descriptor -- and the lock -- open for the
# rest of the CALLING shell's life when this file is `source`d, but releases
# it immediately if the acquire happens inside a subprocess that then exits.
# Getting this backwards would silently defeat the whole point of the lock
# (the protected `docker compose up` work would run completely unguarded),
# so both the positive (sourced, held across the shell's later commands) and
# negative (subprocess, released the instant it exits) cases are exercised
# below, not just the happy "acquire once" path.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    lock_lib="$repo_root/scripts/lib/quickstart-compose-lock.sh"

    # shellcheck source=scripts/lib/quickstart-compose-lock.sh
    source "$lock_lib"

    # Throwaway per-test lock path -- never the real
    # /tmp/lancache-setup-cli-simulation.lock constant, so this suite can
    # never contend with (or be contended by) a real concurrent CI job or
    # another test run on the same host.
    test_lock_path="$BATS_TEST_TMPDIR/quickstart-compose.lock"
    ready_marker="$BATS_TEST_TMPDIR/holder-ready"
}

teardown() {
    # Belt-and-suspenders, same convention as reserve_validation_subnet.bats:
    # kill any holder process a test forgot to release so a leaked
    # background process can never outlive its test. Process-GROUP kill
    # (see the "held lock" test's own comment for why): under bats' own
    # test-execution wrapper, bash does not exec-replace itself for a
    # backgrounded holder's final `sleep`, so the holder's `sleep` runs as
    # a genuine child process that a plain `kill "$holder_pid"` would never
    # touch, leaking it (and its inherited copy of the locked fd) past this
    # test.
    [[ -n "${holder_pid:-}" ]] && kill -- "-${holder_pid}" 2>/dev/null
    true
}

# wait_for_marker <path> -- polls up to ~5s for a marker file a background
# holder process writes AFTER it has actually acquired the flock (not just
# after it was forked), so the contention assertions below never race
# against the holder's own startup time.
wait_for_marker() {
    local marker="$1" waited=0
    while [[ ! -f "$marker" ]] && (( waited < 50 )); do
        sleep 0.1
        waited=$((waited + 1))
    done
    [[ -f "$marker" ]]
}

@test "sourcing defines the function and preserves the original hardcoded lock path" {
    # The literal path the original 3-copy inline pattern used
    # (exec {lock_fd}>/tmp/lancache-setup-cli-simulation.lock) must be
    # unchanged by this refactor -- a different default here would silently
    # stop this helper from serializing against any leftover job still on
    # the old inline form.
    [ "$QUICKSTART_COMPOSE_LOCK_PATH" = "/tmp/lancache-setup-cli-simulation.lock" ]
    declare -f quickstart_compose_lock_acquire >/dev/null
}

@test "acquiring locks the overridden path, not the real hardcoded default" {
    # Prefix assignment, not a positional argument: the function takes none
    # (see its own header for why -- SC2119/actionlint), so this suite
    # overrides the variable instead, scoped to just this one call (confirmed
    # empirically that it reverts to the outer value once the call returns).
    QUICKSTART_COMPOSE_LOCK_PATH="$test_lock_path" quickstart_compose_lock_acquire
    [ -e "$test_lock_path" ]

    # A non-blocking probe against the REAL default path must still succeed
    # (nothing this test does should ever touch it).
    run flock -n "$QUICKSTART_COMPOSE_LOCK_PATH" -c true
    [ "$status" -eq 0 ]
}

@test "a held lock blocks a genuinely separate process's non-blocking probe, and releases when the holder exits" {
    # Real, independent holder process (not a subshell of this test): a `(...)`
    # subshell would inherit this shell's own open file descriptors,
    # including one this test acquired directly, which would make a probe
    # from inside that subshell falsely "succeed" against a lock it never
    # actually opened itself. `bash -c` here is a fresh process that must
    # open (and therefore genuinely contend for) the lock file itself.
    #
    # `setsid` (own process group), not a plain `bash -c ... &`: confirmed
    # empirically (bats run with debug tracing) that under bats' own test
    # runner, bash does NOT apply its usual last-command exec-optimization
    # to the holder's trailing `sleep 30` -- it stays a genuine forked CHILD
    # of the holder shell, with its own independent copy of the inherited,
    # locked fd (fork duplicates file descriptors; the flock itself is
    # attached to the shared open-file-description behind them, so the
    # child alone holding a copy is enough to keep the lock held). A plain
    # `kill "$holder_pid"` below would only terminate the parent shell,
    # leaving that `sleep` child running (and the lock still held) for the
    # rest of its 30s, which is exactly the failure this comment is here to
    # prevent someone from reintroducing: it looked like a correct release
    # in a plain manual repro (where the exec-optimization DOES fire and
    # collapses parent+child into one process), and only broke under bats.
    # `setsid` puts the whole holder (parent and any child it forks) in its
    # own process group, so `kill -- "-$holder_pid"` below (negative PID =
    # process GROUP, not just the one PID) reaches all of it -- matching
    # how a real CI runner actually tears down a step's whole process tree
    # at step end, not just its top-level shell.
    setsid bash -c '
        source "'"$lock_lib"'"
        QUICKSTART_COMPOSE_LOCK_PATH="'"$test_lock_path"'" quickstart_compose_lock_acquire
        touch "'"$ready_marker"'"
        sleep 30
    ' &
    holder_pid=$!

    wait_for_marker "$ready_marker" || fail "holder never reported ready"

    # Held: a non-blocking probe from a third, independent process must fail.
    run flock -n "$test_lock_path" -c true
    [ "$status" -ne 0 ]

    # Simulates the workflow step's shell (and everything it forked) exiting
    # at the end of a `run:` step -- the original inline pattern never
    # released explicitly either, relying on process exit to close the
    # descriptor and drop the flock.
    kill -- "-${holder_pid}"
    wait "$holder_pid" 2>/dev/null || true

    # Released: the same non-blocking probe must now succeed.
    run flock -n "$test_lock_path" -c true
    [ "$status" -eq 0 ]
}

@test "a second acquirer blocks (no -n) until the first holder releases, then proceeds -- matches the original inline flock's semantics" {
    bash -c '
        source "'"$lock_lib"'"
        QUICKSTART_COMPOSE_LOCK_PATH="'"$test_lock_path"'" quickstart_compose_lock_acquire
        touch "'"$ready_marker"'"
        sleep 2
    ' &
    holder_pid=$!

    wait_for_marker "$ready_marker" || fail "holder never reported ready"

    start_epoch="$(date +%s)"
    # Blocking acquire (this function's actual production call, not a `-n`
    # probe): must wait for the holder's sleep 2 to finish, not fail fast.
    QUICKSTART_COMPOSE_LOCK_PATH="$test_lock_path" quickstart_compose_lock_acquire
    elapsed=$(( $(date +%s) - start_epoch ))

    wait "$holder_pid" 2>/dev/null || true
    # Generous lower bound (holder sleeps 2s) with headroom for test-host
    # scheduling jitter -- this only needs to prove "waited for the holder",
    # not measure precise timing.
    [ "$elapsed" -ge 1 ]
}

@test "acquiring inside a subprocess that then exits does NOT hold the lock for the caller -- the reason this file must be sourced, not executed" {
    # Deliberately the WRONG usage this file's header warns against: running
    # the acquire in a subprocess (bash -c ...) that returns before the
    # caller's own protected work would run. Synchronous (no `&`): by the
    # time this command returns, the subprocess has already exited.
    bash -c '
        source "'"$lock_lib"'"
        QUICKSTART_COMPOSE_LOCK_PATH="'"$test_lock_path"'" quickstart_compose_lock_acquire
    '

    # If the fd/lock had somehow survived past the subprocess's exit, this
    # probe would fail -- it must succeed, proving the acquire gave this
    # caller (the bats test shell, standing in for a workflow step that
    # mistakenly ran the helper as a subprocess) no protection at all.
    run flock -n "$test_lock_path" -c true
    [ "$status" -eq 0 ]
}

@test "all 3 real call sites source the helper and call the function, none re-rolls the inline exec/flock pattern" {
    for workflow in \
        "$repo_root/.github/workflows/full-setup-deep-validate.yml" \
        "$repo_root/.github/workflows/full-setup-validate.yml"; do
        [ -f "$workflow" ] || fail "$workflow not found"
    done

    # full-setup-deep-validate.yml carries 2 call sites (setup-cli-simulation
    # and syslog-forwarding-simulation), full-setup-validate.yml carries 1 --
    # 3 total, matching the original 3-copy inline pattern this replaces.
    deep_count="$(grep -c 'quickstart_compose_lock_acquire' "$repo_root/.github/workflows/full-setup-deep-validate.yml")"
    validate_count="$(grep -c 'quickstart_compose_lock_acquire' "$repo_root/.github/workflows/full-setup-validate.yml")"
    [ "$deep_count" -eq 2 ]
    [ "$validate_count" -eq 1 ]

    # Regression guard: the old hand-rolled inline form must not reappear in
    # either workflow -- its presence would mean a new call site re-added the
    # exact copy-paste mistake this helper exists to stop.
    ! grep -q 'exec {lock_fd}>/tmp/lancache-setup-cli-simulation.lock' "$repo_root/.github/workflows/full-setup-deep-validate.yml" \
        || fail "full-setup-deep-validate.yml still contains the old inline exec/flock pattern"
    ! grep -q 'exec {lock_fd}>/tmp/lancache-setup-cli-simulation.lock' "$repo_root/.github/workflows/full-setup-validate.yml" \
        || fail "full-setup-validate.yml still contains the old inline exec/flock pattern"
}
