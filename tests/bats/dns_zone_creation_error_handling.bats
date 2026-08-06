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
# surfaced anywhere. The fix checks existence first via a side-effect-free
# `list-zone` probe and only treats `create-zone` failure as fatal once
# that check has ruled out the routine already-exists case.
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

    # Stub log file the stub pdnsutil below writes call-arguments to, so
    # each test can assert exactly what was invoked.
    pdnsutil_calls="$BATS_TEST_TMPDIR/pdnsutil-calls.log"
    : > "$pdnsutil_calls"
}

# Stub pdnsutil covering the two subcommands _dns_ensure_zone_exists calls.
# PDNSUTIL_LIST_ZONE_EXIT_CODE / PDNSUTIL_CREATE_ZONE_EXIT_CODE let each test
# script the exact real-world scenario it's exercising.
pdnsutil() {
    echo "$*" >> "$pdnsutil_calls"
    # Real invocation shape: pdnsutil --config-dir=/etc/pdns/auth <subcommand> <zone>
    case "$2" in
        list-zone) return "${PDNSUTIL_LIST_ZONE_EXIT_CODE:-0}" ;;
        create-zone) return "${PDNSUTIL_CREATE_ZONE_EXIT_CODE:-0}" ;;
    esac
    return 0
}

@test "an already-existing zone is detected via list-zone and create-zone is never called" {
    PDNSUTIL_LIST_ZONE_EXIT_CODE=0
    run _dns_ensure_zone_exists "lan"

    [ "$status" -eq 0 ]
    grep -qF -- "--config-dir=/etc/pdns/auth list-zone lan" "$pdnsutil_calls"
    ! grep -q "create-zone" "$pdnsutil_calls"
}

@test "a genuinely missing zone is created successfully on first boot" {
    PDNSUTIL_LIST_ZONE_EXIT_CODE=1
    PDNSUTIL_CREATE_ZONE_EXIT_CODE=0
    run _dns_ensure_zone_exists "lan"

    [ "$status" -eq 0 ]
    grep -qF -- "--config-dir=/etc/pdns/auth create-zone lan" "$pdnsutil_calls"
}

# This is the core regression case: before the fix, this scenario was
# silently swallowed by a blanket `|| true` and the container kept starting
# with a real zone missing and no diagnostic anywhere.
@test "a real create-zone failure on a genuinely missing zone is fatal, not silently swallowed" {
    PDNSUTIL_LIST_ZONE_EXIT_CODE=1
    PDNSUTIL_CREATE_ZONE_EXIT_CODE=1
    run _dns_ensure_zone_exists "lan"

    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL: failed to create zone 'lan'"* ]]
}
