#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Fast, Docker-free unit coverage for scripts/lib/promote-lock.sh (issue
# #897). Unlike scripts/lib/reserve-validation-subnet.sh's bats coverage
# (which uses real flock-backed processes against a throwaway local /tmp
# lock root), this file exercises the functions against a REAL local bare
# git repository standing in for the GitHub remote -- these functions only
# ever call plain `git` (ls-remote/fetch/commit-tree/push/log), so a local
# bare repo is a faithful, network-free substitute that still proves the
# actual atomic-ref-update semantics the whole design depends on, rather
# than mocking `git` and only proving this file calls it with the right
# arguments.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/lib/promote-lock.sh
    source "$repo_root/scripts/lib/promote-lock.sh"

    # A bare repo stands in for the GitHub remote; two ordinary clones of it
    # stand in for two independent runner hosts, each with their own
    # checkout and their own "origin" remote pointing at the same bare repo
    # -- exactly the topology two concurrent promote/backfill jobs on two
    # different self-hosted hosts would have.
    bare_repo="$BATS_TEST_TMPDIR/bare.git"
    clone_a="$BATS_TEST_TMPDIR/clone-a"
    clone_b="$BATS_TEST_TMPDIR/clone-b"

    git init --quiet --bare "$bare_repo"

    git clone --quiet "$bare_repo" "$clone_a"
    (cd "$clone_a" && git commit --quiet --allow-empty -m init && git push --quiet origin HEAD:refs/heads/master)

    git clone --quiet "$bare_repo" "$clone_b"
}

@test "holder_note is deterministic and encodes run id, attempt, and runner name" {
    note_a="$(promote_lock_holder_note 12345 1 runner-x)"
    note_b="$(promote_lock_holder_note 12345 1 runner-x)"
    [ "$note_a" = "$note_b" ]
    [[ "$note_a" == *"run=12345"* ]]
    [[ "$note_a" == *"attempt=1"* ]]
    [[ "$note_a" == *"runner=runner-x"* ]]
}

@test "remote_sha returns 1 (absent) when the lock ref does not exist yet" {
    cd "$clone_a"
    run promote_lock_remote_sha origin "$PROMOTE_LOCK_REF"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "try_acquire creates the ref on a free lock and remote_sha then reports it" {
    cd "$clone_a"
    note="$(promote_lock_holder_note run-a 1 host-a)"
    run promote_lock_try_acquire origin "$PROMOTE_LOCK_REF" "$note" 600
    [ "$status" -eq 0 ]

    run promote_lock_remote_sha origin "$PROMOTE_LOCK_REF"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "a second host sees an actively-held, non-stale lock and is refused (status 1)" {
    cd "$clone_a"
    note_a="$(promote_lock_holder_note run-a 1 host-a)"
    run promote_lock_try_acquire origin "$PROMOTE_LOCK_REF" "$note_a" 600
    [ "$status" -eq 0 ]

    cd "$clone_b"
    note_b="$(promote_lock_holder_note run-b 1 host-b)"
    run promote_lock_try_acquire origin "$PROMOTE_LOCK_REF" "$note_b" 600
    [ "$status" -eq 1 ]
}

@test "release lets a later attempt from a different host claim the lock" {
    cd "$clone_a"
    note_a="$(promote_lock_holder_note run-a 1 host-a)"
    promote_lock_try_acquire origin "$PROMOTE_LOCK_REF" "$note_a" 600

    run promote_lock_release origin "$note_a"
    [ "$status" -eq 0 ]

    run promote_lock_remote_sha origin "$PROMOTE_LOCK_REF"
    [ "$status" -eq 1 ]

    cd "$clone_b"
    note_b="$(promote_lock_holder_note run-b 1 host-b)"
    run promote_lock_try_acquire origin "$PROMOTE_LOCK_REF" "$note_b" 600
    [ "$status" -eq 0 ]
}

@test "release is a safe no-op when the current holder does not match (never deletes someone else's lock)" {
    cd "$clone_a"
    note_a="$(promote_lock_holder_note run-a 1 host-a)"
    promote_lock_try_acquire origin "$PROMOTE_LOCK_REF" "$note_a" 600

    cd "$clone_b"
    run promote_lock_release origin "not-the-real-holder"
    [ "$status" -eq 0 ]

    # The lock must still be exactly where clone_a's acquire left it.
    run promote_lock_remote_sha origin "$PROMOTE_LOCK_REF"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "release on an already-absent lock is a silent no-op" {
    cd "$clone_a"
    run promote_lock_release origin "some-holder-note"
    [ "$status" -eq 0 ]
}

@test "a stale lock (older than stale_after) is taken over by a waiting host" {
    cd "$clone_a"
    note_a="$(promote_lock_holder_note run-a 1 host-a)"
    promote_lock_try_acquire origin "$PROMOTE_LOCK_REF" "$note_a" 600

    # Real wall-clock age, same technique reserve-validation-subnet.sh's own
    # bats coverage uses (a short real sleep rather than mocking time) --
    # the function reads the commit's real committer timestamp via `git
    # log`, so there is no clock to fake without faking git itself.
    sleep 2

    cd "$clone_b"
    note_b="$(promote_lock_holder_note run-b 1 host-b)"
    run promote_lock_try_acquire origin "$PROMOTE_LOCK_REF" "$note_b" 1
    [ "$status" -eq 0 ]

    cd "$clone_a"
    git fetch --quiet origin "$PROMOTE_LOCK_REF"
    current_holder="$(git log -1 --format=%s FETCH_HEAD)"
    [ "$current_holder" = "$note_b" ]
}

@test "a genuinely concurrent create race has exactly one winner" {
    # Two independent clones (hosts) both attempting to CREATE the lock ref
    # at the same time -- the exact race this whole design must resolve
    # without both sides believing they hold it. Using real backgrounded
    # subshells against the same bare-repo remote, not a mock, since the
    # atomicity being tested is a property of git's own ref-update
    # protocol, not of this project's code.
    result_a="$BATS_TEST_TMPDIR/result-a"
    result_b="$BATS_TEST_TMPDIR/result-b"

    # `set +e` inside each backgrounded subshell (bats runs test bodies under
    # `set -e`, which a `(...)` subshell inherits): promote_lock_try_acquire
    # returning non-zero is the EXPECTED outcome for whichever side loses the
    # race, not a real error -- without neutralizing errexit here first, the
    # losing subshell would abort at that command and never reach its own
    # `echo "$?" > ...` line, corrupting the very result this test reads.
    (
        set +e
        cd "$clone_a" || exit 1
        # shellcheck source=scripts/lib/promote-lock.sh
        source "$repo_root/scripts/lib/promote-lock.sh"
        promote_lock_try_acquire origin "$PROMOTE_LOCK_REF" "race-a" 600
        echo "$?" > "$result_a"
    ) &
    pid_a=$!

    (
        set +e
        cd "$clone_b" || exit 1
        # shellcheck source=scripts/lib/promote-lock.sh
        source "$repo_root/scripts/lib/promote-lock.sh"
        promote_lock_try_acquire origin "$PROMOTE_LOCK_REF" "race-b" 600
        echo "$?" > "$result_b"
    ) &
    pid_b=$!

    # `|| true`: like the subshells themselves, `wait`'s own exit status here
    # reflects one side's non-zero "lost the race" outcome, which this test
    # deliberately inspects via the result files below rather than via
    # `wait`'s return value -- letting a genuinely expected 2 abort the test
    # via bats' errexit would be indistinguishable from a real failure.
    wait "$pid_a" "$pid_b" || true

    status_a="$(cat "$result_a")"
    status_b="$(cat "$result_b")"

    # Exactly one of the two must have acquired (0) and the other must have
    # lost the race (2, "someone else is actively creating/taking it right
    # now") -- never both 0 (both think they hold it, defeating the whole
    # point) and never both non-zero (a real bug would have left the lock
    # unclaimed by anyone).
    if [ "$status_a" = "0" ]; then
        [ "$status_b" = "2" ]
    else
        [ "$status_a" = "2" ]
        [ "$status_b" = "0" ]
    fi
}

@test "acquire_with_retry succeeds immediately when the lock is free" {
    cd "$clone_a"
    note="$(promote_lock_holder_note run-a 1 host-a)"
    run promote_lock_acquire_with_retry origin "$note" 5 1 600
    [ "$status" -eq 0 ]
}

@test "acquire_with_retry fails closed (::error:: + non-zero) once every attempt is exhausted against a permanently held lock" {
    cd "$clone_a"
    note_a="$(promote_lock_holder_note run-a 1 host-a)"
    promote_lock_try_acquire origin "$PROMOTE_LOCK_REF" "$note_a" 600

    cd "$clone_b"
    note_b="$(promote_lock_holder_note run-b 1 host-b)"
    # stale_after=600 keeps clone_a's fresh lock from ever looking stale
    # within this short test, so every one of these 3 attempts must fail.
    run promote_lock_acquire_with_retry origin "$note_b" 3 1 600
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::promote-lock: could not acquire"* ]]
}
