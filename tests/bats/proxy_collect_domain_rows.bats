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

# These four tests exercise the "domain != root" branch, which the shared
# identity _registrable_domain stub (see the helper file's own comment) can
# never trigger on its own -- each locally overrides it to collapse its
# specific multi-label fixture to a shorter root, the same way real
# PSL-based derivation collapses "cdn.ea.com" to "ea.com", without touching
# the shared default every other test in this file still relies on.
@test "_collect_domain_rows tracks a deep leading-dot entry as an extra wildcard base" {
    _registrable_domain() { [ "$1" = "cdn.ea.com" ] && printf 'ea.com' || printf '%s' "$1"; }
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' '.cdn.ea.com' > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "${#_UNIQUE_DOMAINS[@]}" -eq 1 ]
    [ "${_UNIQUE_DOMAINS[0]}" = "ea.com" ]
    [ "${#_EXTRA_WILDCARD_BASES[@]}" -eq 1 ]
    [ "${_EXTRA_WILDCARD_BASES[0]}" = "cdn.ea.com" ]
}

@test "_collect_domain_rows does NOT track a root-level leading-dot entry as an extra wildcard base" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' '.steamcontent.com' > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "${#_UNIQUE_DOMAINS[@]}" -eq 1 ]
    [ "${#_EXTRA_WILDCARD_BASES[@]}" -eq 0 ]
}

@test "_collect_domain_rows does NOT track a bare (non-leading-dot) deep entry as an extra wildcard base" {
    _registrable_domain() { [ "$1" = "download2.cdn.ea.com" ] && printf 'ea.com' || printf '%s' "$1"; }
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' 'download2.cdn.ea.com' > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "${#_EXTRA_WILDCARD_BASES[@]}" -eq 0 ]
}

@test "_collect_domain_rows collects distinct extra wildcard bases" {
    _registrable_domain() {
        case "$1" in
            cdn.ea.com) printf 'ea.com' ;;
            secure.dyn.riotcdn.net) printf 'riotcdn.net' ;;
            *) printf '%s' "$1" ;;
        esac
    }
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' '.cdn.ea.com' '.secure.dyn.riotcdn.net' > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "${#_EXTRA_WILDCARD_BASES[@]}" -eq 2 ]
    [ "${_EXTRA_WILDCARD_BASES[0]}" = "cdn.ea.com" ]
    [ "${_EXTRA_WILDCARD_BASES[1]}" = "secure.dyn.riotcdn.net" ]
}

# Distinct from the test above: this feeds the SAME base twice (once via a
# leading-dot entry, once as a descendant of that same base under a
# different entry), which is the actual duplicate-key case
# _SEEN_EXTRA_WILDCARD_BASE exists to guard against -- a duplicate wildcard
# map key makes nginx reject the generated stream/https config outright, so
# a regression here is a real startup failure, not just a cosmetic one.
@test "_collect_domain_rows deduplicates a genuinely repeated extra wildcard base" {
    _registrable_domain() { [ "$1" = "cdn.ea.com" ] && printf 'ea.com' || printf '%s' "$1"; }
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' '.cdn.ea.com' '.cdn.ea.com' > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "${#_EXTRA_WILDCARD_BASES[@]}" -eq 1 ]
    [ "${_EXTRA_WILDCARD_BASES[0]}" = "cdn.ea.com" ]
}

@test "_collect_domain_rows tracks a deep bare entry as an extra exact host" {
    _registrable_domain() { [ "$1" = "tlu.dl.delivery.mp.microsoft.com" ] && printf 'microsoft.com' || printf '%s' "$1"; }
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' 'tlu.dl.delivery.mp.microsoft.com' > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "${#_UNIQUE_DOMAINS[@]}" -eq 1 ]
    [ "${_UNIQUE_DOMAINS[0]}" = "microsoft.com" ]
    [ "${#_EXTRA_EXACT_HOSTS[@]}" -eq 1 ]
    [ "${_EXTRA_EXACT_HOSTS[0]}" = "tlu.dl.delivery.mp.microsoft.com" ]
    [ "${#_EXTRA_WILDCARD_BASES[@]}" -eq 0 ]
}

# The "no fundamental limit" case explicitly requested by the maintainer:
# an absurdly deep bare entry must still get its own exact-host cert,
# regardless of how many labels separate it from its registrable root.
@test "_collect_domain_rows tracks an arbitrarily deep bare entry (many labels past root)" {
    long_host="a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p.example.com"
    _registrable_domain() { [ "$1" = "$long_host" ] && printf 'example.com' || printf '%s' "$1"; }
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' "$long_host" > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "${#_EXTRA_EXACT_HOSTS[@]}" -eq 1 ]
    [ "${_EXTRA_EXACT_HOSTS[0]}" = "$long_host" ]
}

@test "_collect_domain_rows does NOT track a bare entry exactly one label past root as an extra exact host" {
    _registrable_domain() { [ "$1" = "cdn.ea.com" ] && printf 'ea.com' || printf '%s' "$1"; }
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' 'cdn.ea.com' > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "${#_EXTRA_EXACT_HOSTS[@]}" -eq 0 ]
}

@test "_collect_domain_rows does NOT track a bare root-level entry as an extra exact host" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' 'steamcontent.com' > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "${#_EXTRA_EXACT_HOSTS[@]}" -eq 0 ]
}

@test "_collect_domain_rows does NOT track a deep leading-dot entry as an extra exact host" {
    _registrable_domain() { [ "$1" = "cdn.ea.com" ] && printf 'ea.com' || printf '%s' "$1"; }
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' '.cdn.ea.com' > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "${#_EXTRA_EXACT_HOSTS[@]}" -eq 0 ]
    [ "${#_EXTRA_WILDCARD_BASES[@]}" -eq 1 ]
}

# The same base can legitimately appear once bare and once wildcard-only
# ("x.cdn.ea.com" plus ".x.cdn.ea.com") -- these need two DIFFERENT certs
# (exact-only SAN vs wildcard-only SAN), which is exactly why the real
# entrypoint.sh gives the exact-host cert file its own ".exact-host"
# suffix. This test only asserts both tracking arrays end up populated
# independently for the same base string; the cert-file-naming collision
# itself is a real-file concern verified separately (not unit-testable
# through this stubbed helper, which never touches $CERT_DIR).
@test "_collect_domain_rows tracks the same base in both extra arrays when listed both ways" {
    _registrable_domain() { [ "$1" = "x.cdn.ea.com" ] && printf 'ea.com' || printf '%s' "$1"; }
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' 'x.cdn.ea.com' '.x.cdn.ea.com' > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "${#_EXTRA_EXACT_HOSTS[@]}" -eq 1 ]
    [ "${_EXTRA_EXACT_HOSTS[0]}" = "x.cdn.ea.com" ]
    [ "${#_EXTRA_WILDCARD_BASES[@]}" -eq 1 ]
    [ "${_EXTRA_WILDCARD_BASES[0]}" = "x.cdn.ea.com" ]
}

@test "_collect_domain_rows deduplicates repeated extra exact hosts" {
    _registrable_domain() { [ "$1" = "tlu.dl.delivery.mp.microsoft.com" ] && printf 'microsoft.com' || printf '%s' "$1"; }
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    printf '%s\n' 'tlu.dl.delivery.mp.microsoft.com' 'tlu.dl.delivery.mp.microsoft.com' > "$domains_file"

    _collect_domain_rows "$domains_file"

    [ "${#_EXTRA_EXACT_HOSTS[@]}" -eq 1 ]
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
