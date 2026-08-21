#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fast, Docker-free unit coverage for tools/runner-host/lancache-ci-runner-
# clone-init.sh's own_host_token(), is_foreign_runner_dir(), and
# own_primary_ipv4() -- the functions that decide whether a runner instance
# directory's .runner credential file belongs to THIS host or is leftover
# clone residue from a different, already-registered host (issue #1622:
# confirmed real on this fleet's disk-cloned VMs), and that derive this
# host's own identity for that decision in the first place.
# `cmd_clean` gates every deletion on is_foreign_runner_dir()'s
# classification, so a wrong answer here is directly a deletion-safety bug
# -- this file exists because PR #1624's own review found that the
# destructive fix it added had no executable regression coverage, only a
# "conceptually verified" note in the test plan (Codex review, PR #1624).
# own_primary_ipv4()'s own coverage was added the same way, for the same
# reason, after a separate review round found its own confirmed real bug
# history (a wrong-interface pick on host .88, a silent `set -e` abort on
# host .80) had no regression test either.
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

# Stubs `ip` (the only external command own_primary_ipv4() calls) to return
# a controlled `ip -4 route get 1.1.1.1` line, so tests never depend on the
# real host's routing table.
stub_ip() {
    # shellcheck disable=SC2317 # invoked indirectly as the `ip` command
    ip() { printf '%s\n' "$STUB_IP_ROUTE_GET_OUTPUT"; }
    export -f ip
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

# --- is_foreign_runner_dir(): tri-state return (0=foreign, 1=own/unregistered,
#     2=unresolved) -- rewritten by PR #1624's own review pass (batch-2) to
#     fail CLOSED (foreign, or unresolved) instead of open (NOT foreign)
#     whenever this host cannot actually prove a directory is its own. Every
#     scenario below now also controls own_ip_token via stub_ip, not just
#     own_host_token via stub_hostname, since is_foreign_runner_dir
#     cross-checks BOTH (own_ip_token is live network config a disk clone
#     cannot copy, unlike the OS hostname) and disagreement between them is
#     itself now a distinct outcome (status 2).

@test "is_foreign_runner_dir is NOT foreign when .runner does not exist and no credentials either (unregistered, not a clone artifact)" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 1 ]
}

@test "is_foreign_runner_dir fails closed (foreign) when .credentials exists but .runner does not" {
    # Real fail-open gap found by review: an incomplete clone artifact
    # (credential material copied, .runner not yet written) previously
    # short-circuited to "not foreign" purely because the .runner check ran
    # first, leaving private key material both unflagged by `check` and
    # unremoved by `clean`.
    touch "$fixture_dir/.credentials"
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"carries credential material"* ]]
}

@test "is_foreign_runner_dir fails closed (foreign) when jq is not available" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    write_runner_json '{"agentName": "gh-lancache-heavy-30-84"}'
    # Empty PATH: `command -v jq` must report jq absent regardless of where
    # it happens to live on the real machine running this suite.
    PATH="" run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"'jq' is not available"* ]]
}

@test "is_foreign_runner_dir fails closed (foreign) when .runner has no agentName field" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    write_runner_json '{"foo": "bar"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not read a valid agentName"* ]]
}

@test "is_foreign_runner_dir fails closed (foreign) when .runner is invalid JSON" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    write_runner_json 'this is not json'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not read a valid agentName"* ]]
}

@test "is_foreign_runner_dir fails closed (foreign) when agentName matches no known fleet naming scheme" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    STUB_IP_ROUTE_GET_OUTPUT="1.1.1.1 via 192.168.1.2 dev vmbr0 src 192.168.1.84 uid 1000"
    stub_ip
    write_runner_json '{"agentName": "some-unrelated-runner-name"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"does not match a known fleet naming scheme"* ]]
}

@test "is_foreign_runner_dir fails closed (foreign) when neither hostname nor IP token can be derived" {
    STUB_HOSTNAME="no-digits-here"
    stub_hostname
    STUB_IP_ROUTE_GET_OUTPUT=""
    stub_ip
    write_runner_json '{"agentName": "gh-lancache-heavy-30-84"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not derive this host's own identity"* ]]
}

# --- is_foreign_runner_dir(): own vs foreign identity -----------------------

@test "is_foreign_runner_dir is NOT foreign for this host's own agentName (hostname and IP token agree)" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    STUB_IP_ROUTE_GET_OUTPUT="1.1.1.1 via 192.168.1.2 dev vmbr0 src 192.168.1.84 uid 1000"
    stub_ip
    write_runner_json '{"agentName": "gh-lancache-heavy-30-84"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 1 ]
}

@test "is_foreign_runner_dir IS foreign for a different host's agentName" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    STUB_IP_ROUTE_GET_OUTPUT="1.1.1.1 via 192.168.1.2 dev vmbr0 src 192.168.1.84 uid 1000"
    stub_ip
    write_runner_json '{"agentName": "gh-lancache-heavy-30-85"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 0 ]
}

@test "is_foreign_runner_dir matches the host token as its own hyphen-delimited segment, not a substring" {
    # Documents the exact invariant extract_fleet_host_number's own header
    # comment claims: host token "1" must never match host 240's directory
    # just because "a-lancache-runner-240-1"'s trailing runner-INSTANCE
    # segment happens to also be "1" -- a real false-positive match found
    # by review before extract_fleet_host_number replaced the old loose
    # "any hyphen segment" comparison.
    STUB_HOSTNAME="host-1"
    stub_hostname
    STUB_IP_ROUTE_GET_OUTPUT="1.1.1.1 via 192.168.1.2 dev vmbr0 src 192.168.1.1 uid 1000"
    stub_ip
    write_runner_json '{"agentName": "a-lancache-runner-240-1"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 0 ] # foreign -- host-number segment is 240, not 1
}

@test "is_foreign_runner_dir returns unresolved (2) when this host's own hostname/IP tokens disagree and agentName matches one of them" {
    # A real disk clone can carry the SOURCE host's own OS hostname
    # verbatim (confirmed real on host .80 -- see hostname_mismatch_report),
    # so a hostname-token match alone is not trustworthy when the
    # IP-derived token (live network config, not copyable) disagrees with
    # it. Neither "own" nor "safely foreign" is correct here -- must not be
    # auto-classified either way.
    STUB_HOSTNAME="gh-lancache-heavy-30-1"
    stub_hostname
    STUB_IP_ROUTE_GET_OUTPUT="1.1.1.1 via 192.168.1.2 dev vmbr0 src 192.168.1.99 uid 1000"
    stub_ip
    write_runner_json '{"agentName": "gh-lancache-heavy-30-1"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 2 ]
    [[ "$output" == *"identity is ambiguous"* ]]
}

# --- deletion boundary: cmd_check's classification feeds cmd_clean --------
#
# cmd_clean (not exercised directly here -- it performs real `sudo rm -rf`
# against the classified directory, unsuitable for a fast Docker-free unit
# test) makes every deletion decision by capturing is_foreign_runner_dir()'s
# real exit status and only ever removing on status 0 (confirmed foreign).
# The tests above are this deletion gate's actual boundary: status 1 (own /
# genuinely unregistered) and status 2 (unresolved) are both things
# cmd_clean must never remove -- only status 0 is a removable finding.

@test "deletion boundary: own (status 1) and unregistered (status 1) are never removable; missing-agentName/invalid-JSON are now status 0 (foreign, fail closed)" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    STUB_IP_ROUTE_GET_OUTPUT="1.1.1.1 via 192.168.1.2 dev vmbr0 src 192.168.1.84 uid 1000"
    stub_ip

    # own -> status 1, never removed
    write_runner_json '{"agentName": "gh-lancache-heavy-30-84"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 1 ]

    # unregistered (no .runner, no credentials) -> status 1, never removed
    rm -f "$fixture_dir/.runner"
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 1 ]

    # invalid JSON -> status 0 now (fail CLOSED, i.e. treated as removable
    # foreign residue rather than silently skipped -- the exact behavior
    # change this rewrite exists to make)
    write_runner_json 'garbage'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 0 ]
}

@test "deletion boundary: only a genuinely different host's agentName is classified foreign (status 0)" {
    STUB_HOSTNAME="gh-lancache-heavy-30-84"
    stub_hostname
    STUB_IP_ROUTE_GET_OUTPUT="1.1.1.1 via 192.168.1.2 dev vmbr0 src 192.168.1.84 uid 1000"
    stub_ip
    write_runner_json '{"agentName": "gh-lancache-heavy-30-85"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 0 ]
}

@test "deletion boundary: unresolved identity (status 2) is never removable" {
    STUB_HOSTNAME="gh-lancache-heavy-30-1"
    stub_hostname
    STUB_IP_ROUTE_GET_OUTPUT="1.1.1.1 via 192.168.1.2 dev vmbr0 src 192.168.1.99 uid 1000"
    stub_ip
    write_runner_json '{"agentName": "gh-lancache-heavy-30-1"}'
    run is_foreign_runner_dir "$fixture_dir"
    [ "$status" -eq 2 ]
}

# --- extract_fleet_host_number() --------------------------------------------
#
# Shared by is_foreign_runner_dir and is_foreign_authorized_keys_line so
# both call sites extract the identical host-number segment the identical
# way (see that rewrite's own header comment for the real false-positive
# this replaced).

@test "extract_fleet_host_number extracts the host-number segment, not a runner-instance suffix" {
    run extract_fleet_host_number "a-lancache-runner-240-1"
    [ "$status" -eq 0 ]
    [ "$output" = "240" ]
}

@test "extract_fleet_host_number handles the letter-group gh-lancache scheme" {
    run extract_fleet_host_number "gh-lancache-heavy-30-84"
    [ "$status" -eq 0 ]
    [ "$output" = "84" ]
}

@test "extract_fleet_host_number returns empty for a name matching neither known scheme" {
    run extract_fleet_host_number "discord-bridge-teamspeak-2026-04-01"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- own_primary_ipv4() -----------------------------------------------------
#
# Regression coverage for the two confirmed real bugs this function's own
# header comment documents (host .88: docker0's "scope global" address
# picked over the real LAN interface; host .80: an `onlink` default route
# has no `src` field at all, and the pre-fix pipeline's non-zero grep exit
# silently killed the whole script under `set -e`). This function was
# fixed to use `ip route get <probe>` specifically because that form always
# computes and prints a `src` field for a reachable route; these tests
# cover the function's own remaining edge cases (route lookup fails
# entirely, or unexpectedly returns a line with no `src` field) to prove it
# still exits 0 with empty output rather than propagating a pipeline
# failure through a caller's `my_ip="$(own_primary_ipv4)"` assignment.

@test "own_primary_ipv4 extracts the src address from a real 'ip route get' line" {
    STUB_IP_ROUTE_GET_OUTPUT="1.1.1.1 via 192.168.1.2 dev vmbr0 src 192.168.1.84 uid 1000"
    stub_ip
    run own_primary_ipv4
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.1.84" ]
}

@test "own_primary_ipv4 returns empty (not a failure) when the route line has no src field" {
    # Regression: the pre-fix implementation fed a `src`-less line into a
    # pipeline whose grep then exited non-zero, tripping `set -e` in every
    # caller under pipefail (host .80 incident).
    STUB_IP_ROUTE_GET_OUTPUT="1.1.1.1 via 192.168.1.2 dev vmbr0 proto kernel onlink"
    stub_ip
    run own_primary_ipv4
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "own_primary_ipv4 returns empty (not a failure) when there is no route at all" {
    STUB_IP_ROUTE_GET_OUTPUT=""
    stub_ip
    run own_primary_ipv4
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
