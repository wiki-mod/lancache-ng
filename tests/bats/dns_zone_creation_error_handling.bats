#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
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
#
# Message wording: the real pdnsutil binary's own message is "Zone
# '<name>' exists already" -- "exists already", not "already exists" --
# confirmed empirically against the actual binary, not assumed. The
# reversed wording never matches the real tool and would mask this exact
# never-tolerated-in-practice failure mode.
@test "an already-existing zone (create-zone fails with pdnsutil's real 'exists already' message) is not fatal" {
    PDNSUTIL_CREATE_ZONE_EXIT_CODE=1
    PDNSUTIL_CREATE_ZONE_STDERR="Zone 'lan' exists already"
    run _dns_ensure_zone_exists "lan"

    [ "$status" -eq 0 ]
}

# Case-insensitivity: PowerDNS's own real message casing has varied across
# versions/locales in this project's own experience elsewhere -- the check
# must not be brittle to exact case.
@test "an 'exists already' match is case-insensitive" {
    PDNSUTIL_CREATE_ZONE_EXIT_CODE=1
    PDNSUTIL_CREATE_ZONE_STDERR="EXISTS ALREADY"
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

# The actual regression this guards against: bats' `run` does not run the
# command under `set -e` the way the real entrypoint.sh does (services/dns/
# entrypoint.sh line 11: `set -euo pipefail`), so every test above -- while
# a genuinely correct check of the function's own logic -- could not have
# caught the real bug: a bare `create_output=$(...)` assignment statement
# (not gated by an `if`/`while` condition) is itself a failing simple
# command when the substituted command fails, which `errexit` aborts on
# immediately, before the very next line (let alone the "exists already"
# tolerance check) ever runs. This test (per AG-VAL-030: prove a
# set-e/pipefail-dependent construct by executing it under the exact
# options its real caller uses, not by reasoning about it) builds a real
# standalone script, sources the *actual* extracted function body, enables
# `set -euo pipefail` itself, and calls the function exactly the way
# entrypoint.sh's own zone-creation loop does -- once for a zone that
# already exists (the routine restart case), then once more (a canary
# call) to prove the script is still alive afterward, not merely dead but
# reporting exit 0.
@test "_dns_ensure_zone_exists does not silently abort the whole script under real set -euo pipefail" {
    local script="$BATS_TEST_TMPDIR/set-e-repro.sh"
    cat > "$script" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
pdnsutil() {
    echo "\$*" >&2
    echo "Zone 'lan' exists already" >&2
    return 1
}
source "$BATS_TEST_TMPDIR/dns-zone-helpers-extracted.sh"
_dns_ensure_zone_exists "lan"
echo "CANARY: reached the line after the already-exists call"
SCRIPT
    chmod +x "$script"
    run bash "$script"

    [ "$status" -eq 0 ]
    [[ "$output" == *"CANARY: reached the line after the already-exists call"* ]]
}
