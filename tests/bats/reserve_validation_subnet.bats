#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Fast, Docker-free unit coverage for scripts/lib/reserve-validation-subnet.sh
# (issue #703). The real race this closes -- two genuinely concurrent
# workflow runs on the same self-hosted host -- cannot be exercised directly
# in a bats run (there is no second, truly concurrent GitHub Actions run to
# provoke here). Instead this: (1) proves the derivation stays deterministic
# and backward-compatible with .github/actions/derive-validation-network's
# own pre-#703 formula for the common, uncontested attempt-1 case, so a
# single, uncontested run still derives the exact octet it always did; (2)
# proves the actual mechanism this issue adds -- pre-holding an octet's lock
# and confirming a second, independent attempt to claim the SAME octet is
# correctly refused while it's held, and correctly succeeds again once
# released -- using two real flock-backed processes against a throwaway
# $BATS_TEST_TMPDIR lock root, which is the same mechanism a genuinely
# concurrent second workflow run would hit on the real, shared /tmp lock
# root.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/lib/reserve-validation-subnet.sh
    source "$repo_root/scripts/lib/reserve-validation-subnet.sh"

    lock_root="$BATS_TEST_TMPDIR/validation-locks"
}

teardown() {
    # Belt-and-suspenders: kill any holder processes a test forgot to
    # release, so a leaked background process can never outlive its test
    # (each test gets a fresh $BATS_TEST_TMPDIR, but a leaked process is not
    # scoped to that directory and would otherwise just keep running).
    [[ -n "${holder_pid:-}" ]] && kill "$holder_pid" 2>/dev/null
    [[ -n "${holder_pid_2:-}" ]] && kill "$holder_pid_2" 2>/dev/null
    true
}

@test "attempt 1's seed matches derive-validation-network's own pre-#703 formula exactly" {
    seed="$(validation_subnet_seed_for_attempt 123456 1 1)"
    [ "$seed" = "123456-1" ]
}

@test "retry attempts salt the seed so they never re-derive attempt 1's seed" {
    seed1="$(validation_subnet_seed_for_attempt 123456 1 1)"
    seed2="$(validation_subnet_seed_for_attempt 123456 1 2)"
    [ "$seed1" != "$seed2" ]
}

@test "octet derivation is deterministic for the same seed" {
    octet_a="$(validation_subnet_derive_octet "123456-1")"
    octet_b="$(validation_subnet_derive_octet "123456-1")"
    [ "$octet_a" = "$octet_b" ]
}

@test "derived octet always falls in the reserved pool, excluding 0, 1, 28, and 99" {
    for seed in "run-1" "run-2" "run-3" "run-4" "run-5" "another-seed" "yet-another"; do
        octet="$(validation_subnet_derive_octet "$seed")"
        [ "$octet" -ge 2 ]
        [ "$octet" -le 253 ]
        [ "$octet" -ne 28 ]
        [ "$octet" -ne 99 ]
    done
}

@test "try_lock succeeds on a free octet and the same octet is refused while held" {
    holder_pid="$(validation_subnet_try_lock "$lock_root" 42)"
    [ -n "$holder_pid" ]
    kill -0 "$holder_pid"

    run validation_subnet_try_lock "$lock_root" 42
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "releasing a lock lets a later attempt claim the same octet again" {
    holder_pid="$(validation_subnet_try_lock "$lock_root" 77)"
    [ -n "$holder_pid" ]

    validation_subnet_release "$holder_pid"
    run kill -0 "$holder_pid"
    [ "$status" -ne 0 ]

    holder_pid_2="$(validation_subnet_try_lock "$lock_root" 77)"
    [ -n "$holder_pid_2" ]
    kill -0 "$holder_pid_2"
}

@test "release is a silent no-op for an empty/unset holder pid" {
    run validation_subnet_release ""
    [ "$status" -eq 0 ]

    run validation_subnet_release
    [ "$status" -eq 0 ]
}

@test "reserve skips an already-locked candidate and lands on a different, unlocked octet" {
    # Pin the FIRST candidate validation_subnet_reserve would try (attempt 1
    # for this run_id/run_attempt) and pre-lock it directly, simulating a
    # second, genuinely concurrent workflow run that got there first -- this
    # is #703's exact scenario, reproduced with two real flock-backed
    # processes instead of two real GitHub Actions runs.
    run_id="run-abc"
    run_attempt="1"
    first_seed="$(validation_subnet_seed_for_attempt "$run_id" "$run_attempt" 1)"
    first_octet="$(validation_subnet_derive_octet "$first_seed")"

    holder_pid="$(validation_subnet_try_lock "$lock_root" "$first_octet")"
    [ -n "$holder_pid" ]

    result="$(validation_subnet_reserve "$lock_root" "$run_id" "$run_attempt" 1 20)"
    [ -n "$result" ]

    won_octet="$(printf '%s\n' "$result" | sed -n 's/^octet=//p')"
    holder_pid_2="$(printf '%s\n' "$result" | sed -n 's/^holder_pid=//p')"

    [ "$won_octet" != "$first_octet" ]
    [ -n "$holder_pid_2" ]
    kill -0 "$holder_pid_2"
}

@test "reserve returns failure once every attempt in range is already locked" {
    run_id="run-xyz"
    run_attempt="1"

    # Lock the only two attempt numbers this call is allowed to try (1 and
    # 2), so the range is fully exhausted and reserve must fail cleanly
    # rather than loop forever or silently reuse a locked octet.
    seed1="$(validation_subnet_seed_for_attempt "$run_id" "$run_attempt" 1)"
    octet1="$(validation_subnet_derive_octet "$seed1")"
    seed2="$(validation_subnet_seed_for_attempt "$run_id" "$run_attempt" 2)"
    octet2="$(validation_subnet_derive_octet "$seed2")"

    holder_pid="$(validation_subnet_try_lock "$lock_root" "$octet1")"
    [ -n "$holder_pid" ]

    # Extremely unlikely (~1/252) but possible: both attempt seeds hash to
    # the same octet. Locking it once already covers that case, so only
    # lock octet2 separately when it's actually different.
    if [ "$octet2" != "$octet1" ]; then
        holder_pid_2="$(validation_subnet_try_lock "$lock_root" "$octet2")"
        [ -n "$holder_pid_2" ]
    fi

    run validation_subnet_reserve "$lock_root" "$run_id" "$run_attempt" 1 2
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}
