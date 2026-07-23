#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for services/proxy/entrypoint.sh's _collect_domain_rows(),
# specifically the leading-"!" disabled-entry skip added for #1073 (the
# Admin UI's per-domain toggle for pre-shipped "Default CDN" entries). See
# tests/bats/helpers/proxy-collect-domain-rows-helpers.sh's own comment for
# why root-domain derivation (_registrable_domain) is stubbed here rather
# than exercised for real -- that is a separate, pre-existing, untested
# concern this file does not take on.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/lib/domain-validation.sh
    source "$repo_root/scripts/lib/domain-validation.sh"
    # shellcheck source=tests/bats/helpers/proxy-collect-domain-rows-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/proxy-collect-domain-rows-helpers.sh"
}

@test "_collect_domain_rows excludes a disabled ('!'-prefixed) entry from _UNIQUE_DOMAINS" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' '!disabled.example.com' 'enabled.example.com' > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "${#_UNIQUE_DOMAINS[@]}" -eq 1 ]
    [ "${_UNIQUE_DOMAINS[0]}" = "enabled.example.com" ]
    [ -z "${_DOMAIN_IS_ROOT[disabled.example.com]+set}" ]
    [ -n "${_DOMAIN_IS_ROOT[enabled.example.com]+set}" ]
}

@test "_collect_domain_rows excludes a disabled wildcard-only ('!.') entry" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' '!.disabled-wild.example.com' 'still-enabled.example.com' > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "${#_UNIQUE_DOMAINS[@]}" -eq 1 ]
    [ "${_UNIQUE_DOMAINS[0]}" = "still-enabled.example.com" ]
}

# A disabled row is a deliberate operator choice, not a malformed or
# degraded cdn-domains.txt row -- it must not trip the known-good-snapshot
# gate (#415) the way a genuinely invalid entry does (see
# _DOMAIN_ROWS_SKIPPED's own doc comment in entrypoint.sh).
@test "_collect_domain_rows does not set _DOMAIN_ROWS_SKIPPED for a disabled entry" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' '!disabled.example.com' 'enabled.example.com' > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "$_DOMAIN_ROWS_SKIPPED" -eq 0 ]
}

# Contrast case: a genuinely invalid entry (not disabled, just malformed)
# must still set _DOMAIN_ROWS_SKIPPED, proving the new "!" check didn't
# accidentally swallow the pre-existing #822 validation-skip signal too.
@test "_collect_domain_rows still sets _DOMAIN_ROWS_SKIPPED for a genuinely invalid entry" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' 'com' 'enabled.example.com' > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "$_DOMAIN_ROWS_SKIPPED" -eq 1 ]
    [ "${#_UNIQUE_DOMAINS[@]}" -eq 1 ]
    [ "${_UNIQUE_DOMAINS[0]}" = "enabled.example.com" ]
}

@test "_collect_domain_rows collects only enabled entries from a mixed file" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    {
        printf '%s\n' '# comment'
        printf '%s\n' ''
        printf '%s\n' 'steamcontent.com'
        printf '%s\n' '!disabled-one.example.com'
        printf '%s\n' '.epicgames.com'
        printf '%s\n' '!.disabled-two.example.com'
    } > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "${#_UNIQUE_DOMAINS[@]}" -eq 2 ]
    [ -n "${_DOMAIN_IS_ROOT[steamcontent.com]+set}" ]
    [ -n "${_DOMAIN_IS_ROOT[epicgames.com]+set}" ]
    [ -z "${_DOMAIN_IS_ROOT[disabled-one.example.com]+set}" ]
    [ -z "${_DOMAIN_IS_ROOT[disabled-two.example.com]+set}" ]
}
