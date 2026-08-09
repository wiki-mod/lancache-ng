#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for _dns_ensure_zone_exists (services/dns/entrypoint.sh),
# fixing bug-hunt finding #6 (docs/bug-hunt/dns.md, re-verified 2026-08-06):
# LAN/reverse zone creation previously did `pdnsutil ... create-zone "$zone"
# || true`, which swallowed every failure indiscriminately -- not just the
# expected "zone already exists" case on a container restart, but also a
# genuine backend failure (malformed zone name, permissions problem,
# corrupt auth database), leaving the zone silently absent with no error
# surfaced anywhere. The fix inspects `create-zone`'s own real stderr text
# (not a separate `list-zone` existence probe -- PowerDNS's docs/manpage
# don't document that command's exit code for a nonexistent zone, and
# getting that assumption wrong would risk never creating a zone at all on
# a fresh install, see the function's own comment) and only treats a
# failure as fatal when its message does NOT look like the routine
# already-exists case.
#
# Loads the real function from services/dns/entrypoint.sh (not a
# reimplementation) via tests/bats/helpers/dns-zone-helpers.sh's dynamic
# awk-extraction, the same technique tests/bats/dns_zone_generation.bats
# already uses for _dns_generate_rpz_zone in the same file.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=tests/bats/helpers/dns-zone-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/dns-zone-helpers.sh"
    load_dns_zone_helpers "$repo_root" "$BATS_TEST_TMPDIR/dns-zone-helpers-extracted.sh"

    pdnsutil_calls="$BATS_TEST_TMPDIR/pdnsutil-calls.log"
    : > "$pdnsutil_calls"
}

# Stub pdnsutil covering the one subcommand _dns_ensure_zone_exists calls.
# PDNSUTIL_CREATE_ZONE_EXIT_CODE / PDNSUTIL_CREATE_ZONE_STDERR let each test
# script the exact real-world scenario it's exercising -- both the exit
# code and the message text matter now, since the fix distinguishes
# scenarios by message content, not just exit status.
pdnsutil() {
    echo "$*" >> "$pdnsutil_calls"
    if [ -n "${PDNSUTIL_CREATE_ZONE_STDERR:-}" ]; then
        echo "$PDNSUTIL_CREATE_ZONE_STDERR" >&2
    fi
    return "${PDNSUTIL_CREATE_ZONE_EXIT_CODE:-0}"
}

@test "a genuinely missing zone is created successfully on first boot" {
    PDNSUTIL_CREATE_ZONE_EXIT_CODE=0
    run _dns_ensure_zone_exists "lan"

    [ "$status" -eq 0 ]
    grep -qF -- "--config-dir=/etc/pdns/auth create-zone lan" "$pdnsutil_calls"
}

# The routine, expected case on every container restart: create-zone fails
# because the zone is already there. Must stay non-fatal, exactly like the
# old blanket `|| true` was for this specific case.
@test "an already-existing zone (create-zone fails with an 'already exists' message) is not fatal" {
    PDNSUTIL_CREATE_ZONE_EXIT_CODE=1
    PDNSUTIL_CREATE_ZONE_STDERR="Error: Zone 'lan' already exists"
    run _dns_ensure_zone_exists "lan"

    [ "$status" -eq 0 ]
}

# Case-insensitivity: PowerDNS's own real message casing has varied across
# versions/locales in this project's own experience elsewhere -- the check
# must not be brittle to exact case.
@test "an 'already exists' match is case-insensitive" {
    PDNSUTIL_CREATE_ZONE_EXIT_CODE=1
    PDNSUTIL_CREATE_ZONE_STDERR="ALREADY EXISTS"
    run _dns_ensure_zone_exists "lan"

    [ "$status" -eq 0 ]
}

# This is the core regression case: before the fix, a genuine backend
# failure unrelated to "already exists" was silently swallowed by a
# blanket `|| true` and the container kept starting with a real zone
# missing and no diagnostic anywhere.
@test "a real create-zone failure unrelated to 'already exists' is fatal, not silently swallowed" {
    PDNSUTIL_CREATE_ZONE_EXIT_CODE=1
    PDNSUTIL_CREATE_ZONE_STDERR="Error: Unable to open database connection"
    run _dns_ensure_zone_exists "lan"

    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL: failed to create zone 'lan'"* ]]
    [[ "$output" == *"Unable to open database connection"* ]]
}

# load_dns_zone_helpers only extracts this function's own body, never
# entrypoint.sh's top-level `set -euo pipefail` -- every test above runs
# under bats' own default options, NOT the real ones this function executes
# under in production. Worse, bats' own `run` wraps the tested command in a
# subshell that does not propagate a `set -e` set earlier in the same test
# body (verified empirically: a test that does `set -e; run some_function_
# with_an_unguarded_failing_command_substitution` still lets that function
# run to its own end, because `run`'s subshell starts fresh, not inheriting
# -e) -- so simply adding `set -e` before `run` would silently prove
# nothing. A version of _dns_ensure_zone_exists that reads
# `create_status=$?` on a line separate from the create_output assignment
# would pass every test above while still failing under entrypoint.sh's REAL
# option set (a plain script, never bats/run-wrapped), because that
# assignment is the command -e checks there, aborting before create_status
# is ever read. This test instead spawns its OWN literal `bash -c 'set -e;
# ...'` subprocess (bypassing `run` entirely for the -e-sensitive part),
# sources the same extracted helper, and re-declares the stub via
# `export -f` so the child process sees it -- the only way to actually prove
# the already-exists tolerance survives under the exact conditions that
# would otherwise defeat it, per this project's own standing requirement to
# prove a set -e/-u dependent construct empirically rather than reason about
# it.
@test "the already-exists tolerance still holds when set -e is actually active, like in the real entrypoint" {
    export -f pdnsutil
    export PDNSUTIL_CREATE_ZONE_EXIT_CODE=1
    export PDNSUTIL_CREATE_ZONE_STDERR="Error: Zone 'lan' already exists"
    export pdnsutil_calls
    run bash -c "set -euo pipefail; source '$BATS_TEST_TMPDIR/dns-zone-helpers-extracted.sh'; _dns_ensure_zone_exists lan; echo REACHED_AFTER_CALL"

    [ "$status" -eq 0 ]
    [[ "$output" == *"REACHED_AFTER_CALL"* ]]
}
