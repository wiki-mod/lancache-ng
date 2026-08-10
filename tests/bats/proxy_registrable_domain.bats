#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regression tests for services/proxy/entrypoint.sh's REAL, PSL-backed
# _registrable_domain() -- loaded via awk extraction (see
# tests/bats/helpers/proxy-registrable-domain-helpers.sh) and run against
# the actual vendored services/proxy/public_suffix_list.dat this service
# ships, not a hand-written stand-in list. Before this file, the only
# existing coverage (tests/bats/proxy_collect_domain_rows.bats) stubbed
# _registrable_domain as a plain identity function, so this exact PSL
# matching algorithm -- compound-label public suffixes (co.uk-style) and the
# PSL's own exception-rule interplay (!city.kawasaki.jp-style) -- had zero
# real test coverage anywhere.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/proxy-registrable-domain-helpers.sh"

    # shellcheck source=tests/bats/helpers/proxy-registrable-domain-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/proxy-registrable-domain-helpers.sh"
    load_proxy_registrable_domain_helpers "$repo_root" "$helper_file"

    # Real vendored PSL data, not a fixture -- if upstream ever removes or
    # reshapes the specific rules these tests key on (co.uk, kawasaki.jp),
    # that is itself useful signal, not a false failure to work around.
    # ShellCheck cannot see that the dynamically extracted function reads this
    # global after the helper sources it.
    # shellcheck disable=SC2034
    PUBLIC_SUFFIX_LIST_FILE="$repo_root/services/proxy/public_suffix_list.dat"
    _load_public_suffix_list
}

@test "_registrable_domain collapses a compound-label public suffix (co.uk) correctly" {
    run _registrable_domain "cdn.example.co.uk"
    [ "$status" -eq 0 ]
    [ "$output" = "example.co.uk" ]
}

# The naive "last two labels" bug this real algorithm exists to avoid
# (entrypoint.sh's own comment above _load_public_suffix_list names this
# exact failure mode): a two-label guess would wrongly return "co.uk"
# itself, treating the compound public suffix as if it were the root.
@test "_registrable_domain does NOT collapse co.uk itself to a shorter, wrong root" {
    run _registrable_domain "example.co.uk"
    [ "$status" -eq 0 ]
    [ "$output" = "example.co.uk" ]
}

# co.uk with only one label past the suffix has nothing left to be a root
# for -- "co.uk" alone is entirely public suffix, matching this function's
# own documented "no label left over" failure contract.
@test "_registrable_domain rejects a bare compound public suffix with no registrable label" {
    run _registrable_domain "co.uk"
    [ "$status" -ne 0 ]
}

# The PSL exception-rule case this function's own comment names directly:
# "*.kawasaki.jp" is a wildcard rule that would otherwise swallow
# "city.kawasaki.jp" into the public suffix itself, but "!city.kawasaki.jp"
# is an explicit exception carving that one specific name back out as a
# registrable root in its own right. An exception match must win over the
# wildcard match at the same position.
@test "_registrable_domain honors a PSL exception rule over the wildcard it carves out of" {
    run _registrable_domain "city.kawasaki.jp"
    [ "$status" -eq 0 ]
    [ "$output" = "city.kawasaki.jp" ]
}

# A real subdomain one label below the exception-carved name must still
# collapse to that same registrable root, exactly like any other domain.
@test "_registrable_domain collapses a subdomain of an exception-rule root to that root" {
    run _registrable_domain "cdn.city.kawasaki.jp"
    [ "$status" -eq 0 ]
    [ "$output" = "city.kawasaki.jp" ]
}

# Contrast case in the same wildcard family, WITHOUT the exception: under
# the plain "*.kawasaki.jp" wildcard rule (no carve-out), ANY single label
# immediately in front of "kawasaki.jp" is itself entirely public suffix
# (the same shape as "city.kawasaki.jp" would be without its "!" exception)
# -- so a 3-label name at exactly that depth has no label left over to be a
# root, mirroring the bare "co.uk" rejection case above.
@test "_registrable_domain rejects a bare non-excepted kawasaki.jp wildcard-suffix name with no registrable label" {
    run _registrable_domain "example.kawasaki.jp"
    [ "$status" -ne 0 ]
}

# One more label in front of that same wildcard-covered suffix is enough to
# reach a real registrable root -- and a name deeper still must collapse
# down to that same minimum-depth root, not keep the extra label(s) in
# front of it (the actual bug this whole function exists to avoid: a naive
# "last two labels" guess would either under- or over-shoot this boundary
# for a wildcard TLD).
@test "_registrable_domain applies the plain wildcard rule for a non-excepted kawasaki.jp sibling at minimum registrable depth" {
    run _registrable_domain "sub.example.kawasaki.jp"
    [ "$status" -eq 0 ]
    [ "$output" = "sub.example.kawasaki.jp" ]
}

@test "_registrable_domain collapses a deeper subdomain to the same minimum-depth wildcard root" {
    run _registrable_domain "cdn.sub.example.kawasaki.jp"
    [ "$status" -eq 0 ]
    [ "$output" = "sub.example.kawasaki.jp" ]
}

# Simple, non-compound TLD sanity check -- the common case this algorithm
# must keep working correctly alongside the compound/exception edge cases
# above.
@test "_registrable_domain handles a plain single-label public suffix (.com) normally" {
    run _registrable_domain "cdn.steamcontent.com"
    [ "$status" -eq 0 ]
    [ "$output" = "steamcontent.com" ]
}
