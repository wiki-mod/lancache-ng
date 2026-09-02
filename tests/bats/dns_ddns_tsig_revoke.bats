#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regression tests for configure_ddns_tsig() (services/dns/entrypoint.sh),
# fixing bug-hunt finding #9 (docs/bug-hunt/dns.md, re-verified 2026-08-06):
# unsetting DDNS_TSIG_KEY after a previous run had it set used to just log a
# message and return, leaving the TSIG-ALLOW-DNSUPDATE authorization from
# that previous run active on every LAN/reverse zone -- an operator who
# unsets the var believing they've disabled DDNS would find DNS UPDATE
# requests signed with the old key still accepted. The fix revokes the
# per-zone authorization and deletes the now-orphaned key whenever the var
# is unset, unconditionally (safe even when DDNS was never configured).
#
# Loads the real functions via tests/bats/helpers/dns-ddns-tsig-helpers.sh's
# dynamic awk-extraction rather than reimplementing them.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=tests/bats/helpers/dns-ddns-tsig-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/dns-ddns-tsig-helpers.sh"
    load_dns_ddns_tsig_helpers "$repo_root" "$BATS_TEST_TMPDIR/dns-ddns-tsig-helpers-extracted.sh"

    # shellcheck disable=SC2034 # read by configure_ddns_tsig(), sourced dynamically via load_dns_ddns_tsig_helpers() -- invisible to shellcheck's static analysis
    DDNS_TSIG_NAME="lancache-ddns-key"
    # shellcheck disable=SC2034 # read by configure_ddns_tsig(), sourced dynamically via load_dns_ddns_tsig_helpers() -- invisible to shellcheck's static analysis
    DDNS_TSIG_ALGORITHM="hmac-sha256"
    # shellcheck disable=SC2034 # read by configure_ddns_tsig(), sourced dynamically via load_dns_ddns_tsig_helpers() -- invisible to shellcheck's static analysis
    DDNS_UPDATE_ZONES=("lan" "1.168.192.in-addr.arpa")

    pdnsutil_calls="$BATS_TEST_TMPDIR/pdnsutil-calls.log"
    : > "$pdnsutil_calls"
}

# Stub pdnsutil recording every invocation; all subcommands succeed by
# default (PDNSUTIL_FAIL_ALL lets the revoke-path-is-best-effort test force
# failures to prove they don't block the function).
pdnsutil() {
    echo "$*" >> "$pdnsutil_calls"
    [ "${PDNSUTIL_FAIL_ALL:-0}" = "1" ] && return 1
    if [ "${PDNSUTIL_CREATE_SECONDARY_EXISTS:-0}" = "1" ] \
        && [ "${2:-}" = "zone" ] \
        && [ "${3:-}" = "create-secondary" ]; then
        echo "Zone '${4:-unknown}' exists already" >&2
        return 1
    fi
    return 0
}

@test "an unset DDNS_TSIG_KEY revokes TSIG-ALLOW-DNSUPDATE on every configured zone" {
    unset DDNS_TSIG_KEY
    run configure_ddns_tsig

    [ "$status" -eq 0 ]
    grep -qF -- "--config-dir=/etc/pdns/auth set-meta lan TSIG-ALLOW-DNSUPDATE" "$pdnsutil_calls"
    grep -qF -- "--config-dir=/etc/pdns/auth set-meta 1.168.192.in-addr.arpa TSIG-ALLOW-DNSUPDATE" "$pdnsutil_calls"
}

@test "an unset DDNS_TSIG_KEY also deletes the now-orphaned TSIG key" {
    unset DDNS_TSIG_KEY
    run configure_ddns_tsig

    [ "$status" -eq 0 ]
    grep -qF -- "--config-dir=/etc/pdns/auth delete-tsig-key lancache-ddns-key" "$pdnsutil_calls"
}

@test "the revoke path is best-effort: it never fails the container even if pdnsutil errors" {
    unset DDNS_TSIG_KEY
    PDNSUTIL_FAIL_ALL=1
    run configure_ddns_tsig

    # Every pdnsutil call in the revoke path is deliberately non-fatal (the
    # zone/key may legitimately never have existed, e.g. a fresh install
    # that never enabled DDNS) -- unlike bug-hunt finding #6's zone-creation
    # fix, which made an equivalent-looking blanket swallow fatal, this one
    # stays soft on purpose because there is no "should exist" invariant
    # here to enforce.
    [ "$status" -eq 0 ]
}

@test "a configured DDNS_TSIG_KEY still authorizes zones normally (no regression)" {
    DDNS_TSIG_KEY="a-real-generated-shared-secret-not-a-placeholder"
    run configure_ddns_tsig

    [ "$status" -eq 0 ]
    grep -qF -- "--config-dir=/etc/pdns/auth import-tsig-key lancache-ddns-key hmac-sha256 a-real-generated-shared-secret-not-a-placeholder" "$pdnsutil_calls"
    grep -qF -- "--config-dir=/etc/pdns/auth set-meta lan TSIG-ALLOW-DNSUPDATE lancache-ddns-key" "$pdnsutil_calls"
    ! grep -q "delete-tsig-key" "$pdnsutil_calls"
}

@test "a placeholder DDNS_TSIG_KEY is still rejected as fatal (no regression)" {
    # shellcheck disable=SC2034 # read by configure_ddns_tsig(), sourced dynamically via load_dns_ddns_tsig_helpers() -- invisible to shellcheck's static analysis
    DDNS_TSIG_KEY="CHANGE_ME"
    run configure_ddns_tsig

    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL: DDNS_TSIG_KEY is still set to a default placeholder"* ]]
}

@test "import_ddns_tsig_key imports the shared key without granting DDNS writes" {
    export DDNS_TSIG_KEY="a-real-generated-shared-secret-not-a-placeholder"
    run import_ddns_tsig_key

    [ "$status" -eq 0 ]
    grep -qF -- "--config-dir=/etc/pdns/auth import-tsig-key lancache-ddns-key hmac-sha256 a-real-generated-shared-secret-not-a-placeholder" "$pdnsutil_calls"
    ! grep -qF "TSIG-ALLOW-DNSUPDATE" "$pdnsutil_calls"
}

# What: stubs getent so dns-ssl resolves to a real IP.
# Why: dns_xfr_primary_endpoint needs an IP, not a name.
# From: PR #1775
getent() {
    if [ "$1" = "ahostsv4" ] && [ "$2" = "dns-ssl" ]; then
        echo "10.0.0.5 STREAM dns-ssl"
        return 0
    fi
    return 1
}

@test "_dns_configure_primary_zone_replication sets serial and notify metadata for a primary zone" {
    export DNS_XFR_NOTIFY_TARGETS="dns-ssl:5300,192.0.2.53:5300"
    run _dns_configure_primary_zone_replication lan

    [ "$status" -eq 0 ]
    grep -qF -- "--config-dir=/etc/pdns/auth zone set-kind lan primary" "$pdnsutil_calls"
    grep -qF -- "--config-dir=/etc/pdns/auth set-meta lan SOA-EDIT-DNSUPDATE INCREASE" "$pdnsutil_calls"
    grep -qF -- "--config-dir=/etc/pdns/auth set-meta lan SOA-EDIT-API INCREASE" "$pdnsutil_calls"
    grep -qF -- "--config-dir=/etc/pdns/auth set-meta lan NOTIFY-DNSUPDATE 1" "$pdnsutil_calls"
    grep -qF -- "--config-dir=/etc/pdns/auth tsigkey activate lan lancache-ddns-key primary" "$pdnsutil_calls"
    # What: ALSO-NOTIFY receives resolved IPs, not hostnames.
    # Why: matches the fake IP the getent stub returns.
    # From: PR #1775
    grep -qF -- "--config-dir=/etc/pdns/auth set-meta lan ALSO-NOTIFY 10.0.0.5:5300 192.0.2.53:5300" "$pdnsutil_calls"
    [ "$(grep -cF -- "--config-dir=/etc/pdns/auth set-meta lan ALSO-NOTIFY" "$pdnsutil_calls")" -eq 1 ]
}

# What: getent fails twice, resolves on the third attempt.
# Why: proves the retry loop, not just the happy path.
# From: PR #1775
@test "dns_xfr_primary_endpoint retries a sibling that isn't resolvable yet" {
    getent_attempts="$BATS_TEST_TMPDIR/getent-attempts"
    : > "$getent_attempts"
    getent() {
        echo x >> "$getent_attempts"
        if [ "$(wc -l < "$getent_attempts")" -lt 3 ]; then
            return 1
        fi
        echo "10.0.0.5 STREAM dns-ssl"
    }

    run dns_xfr_primary_endpoint "dns-ssl:5300" DNS_XFR_NOTIFY_TARGETS
    [ "$status" -eq 0 ]
    [ "$output" = "10.0.0.5:5300" ]
    [ "$(wc -l < "$getent_attempts")" -eq 3 ]
}

@test "_dns_ensure_secondary_zone creates a secondary without granting local DDNS writes" {
    run _dns_ensure_secondary_zone lan 192.0.2.10:5300

    [ "$status" -eq 0 ]
    grep -qF -- "--config-dir=/etc/pdns/auth zone create-secondary lan 192.0.2.10:5300" "$pdnsutil_calls"
    grep -qF -- "--config-dir=/etc/pdns/auth tsigkey activate lan lancache-ddns-key secondary" "$pdnsutil_calls"
    ! grep -qF "TSIG-ALLOW-DNSUPDATE" "$pdnsutil_calls"
}

@test "_dns_ensure_secondary_zone repairs an existing zone back to the primary" {
    PDNSUTIL_CREATE_SECONDARY_EXISTS=1
    run _dns_ensure_secondary_zone lan 192.0.2.10:5300

    [ "$status" -eq 0 ]
    grep -qF -- "--config-dir=/etc/pdns/auth zone create-secondary lan 192.0.2.10:5300" "$pdnsutil_calls"
    grep -qF -- "--config-dir=/etc/pdns/auth zone set-kind lan secondary" "$pdnsutil_calls"
    grep -qF -- "--config-dir=/etc/pdns/auth zone change-primary lan 192.0.2.10:5300" "$pdnsutil_calls"
    grep -qF -- "--config-dir=/etc/pdns/auth tsigkey activate lan lancache-ddns-key secondary" "$pdnsutil_calls"
}
