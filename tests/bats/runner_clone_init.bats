#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Fast, Docker-free unit coverage for tools/runner-host/lancache-ci-runner-
# clone-init.sh's own_host_token() and is_foreign_runner_dir() -- the two
# functions that decide whether a runner instance directory's .runner
# credential file belongs to THIS host or is leftover clone residue from a
# different, already-registered host (issue #1622: confirmed real on this
# fleet's disk-cloned VMs). `cmd_clean` gates every deletion on
# is_foreign_runner_dir()'s classification, so a wrong answer here is
# directly a deletion-safety bug -- this file exists because PR #1624's own
# review found that the destructive fix it added had no executable
# regression coverage, only a "conceptually verified" note in the test
# plan (Codex review, PR #1624).
#
# The script under test also `set -euo pipefail`s at its own top level
# (it doubles as a directly-runnable script, guarded at the bottom so
# sourcing it here does not also invoke main() -- see that guard's own
# comment). setup() neutralizes those options again right after sourcing:
# bats already isolates each @test and captures failures via `run`, and
# leaving strict mode live in the actual bats shell risks an unrelated
# helper command elsewhere in a test body aborting the whole file instead
# of just failing one assertion.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    target_script="$repo_root/tools/runner-host/lancache-ci-runner-clone-init.sh"

    # shellcheck source=tools/runner-host/lancache-ci-runner-clone-init.sh
    source "$target_script"
    set +e
    set +u
    set +o pipefail

    fixture_dir="$BATS_TEST_TMPDIR/runner-instance"
    mkdir -p "$fixture_dir"
}

# Stubs `hostname` (the only external command own_host_token() calls) to
# return a controlled value, so tests never depend on the real host this
# suite happens to run on.
stub_hostname() {
    # shellcheck disable=SC2317 # invoked indirectly as the `hostname` command
    hostname() { printf '%s\n' "$STUB_HOSTNAME"; }
    export -f hostname
}

write_runner_json() {
    printf '%s' "$1" > "$fixture_dir/.runner"
}

# --- own_host_token() ------------------------------------------------------

@test "own_host_token extracts the LAST run of digits from hostname" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    run own_host_token
    [ "$status" -eq 0 ]
    [ "$output" = "84" ]
}

@test "own_host_token returns empty (not a failure) when hostname has no digits at all" {
    STUB_HOSTNAME="lancache-runner-nodigits"
    stub_hostname
    run own_host_token
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- is_foreign_runner_dir(): missing / invalid .runner --------------------

@test "is_foreign_runner_dir is NOT foreign when .runner does not exist (unregistered, not a clone artifact)" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 1 ]
}

@test "is_foreign_runner_dir is NOT foreign when .runner has no agentName field" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    write_runner_json '{"foo": "bar"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 1 ]
}

@test "is_foreign_runner_dir is NOT foreign when .runner is invalid JSON" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    write_runner_json 'this is not json'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 1 ]
}

@test "is_foreign_runner_dir fails closed (NOT foreign) when own_host_token cannot be derived" {
    STUB_HOSTNAME="no-digits-here"
    stub_hostname
    write_runner_json '{"agentName": "gh-lancache-heavy-30-84"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot safely classify"* ]]
}

# --- is_foreign_runner_dir(): own vs foreign identity -----------------------

@test "is_foreign_runner_dir is NOT foreign for this host's own agentName" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    write_runner_json '{"agentName": "gh-lancache-heavy-30-84"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 1 ]
}

@test "is_foreign_runner_dir IS foreign for a different host's agentName" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    write_runner_json '{"agentName": "gh-lancache-heavy-30-85"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 0 ]
}

@test "is_foreign_runner_dir matches the host token as its own hyphen-delimited segment, not a substring" {
    # Documents the exact invariant this function's own header comment
    # claims: host token "1" must never match host 41's directory just
    # because "41" contains the character "1".
    STUB_HOSTNAME="host-1"
    stub_hostname
    write_runner_json '{"agentName": "d-lancache-runner-241-2"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 0 ] # foreign -- "1" is not a standalone segment of "241-2"
}

# --- deletion boundary: cmd_check's classification feeds cmd_clean --------
#
# cmd_clean (not exercised directly here -- it performs real `sudo rm -rf`
# against the classified directory, unsuitable for a fast Docker-free unit
# test) makes every deletion decision by calling is_foreign_runner_dir()
# first and only acting when it returns foreign (0). The tests above are
# this deletion gate's actual boundary: anything they assert is
# NOT foreign is exactly what cmd_clean must never remove.

@test "deletion boundary: an own, unregistered, and invalid-JSON directory are all classified NOT foreign" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname

    # own
    write_runner_json '{"agentName": "gh-lancache-heavy-30-84"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 1 ]

    # unregistered
    rm -f "$fixture_dir/.runner"
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 1 ]

    # invalid JSON
    write_runner_json 'garbage'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 1 ]
}

@test "deletion boundary: only a genuinely different host's agentName is classified foreign" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    write_runner_json '{"agentName": "gh-lancache-heavy-30-85"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 0 ]
}
