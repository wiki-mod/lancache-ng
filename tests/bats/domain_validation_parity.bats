#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Cross-language parity coverage for domain-entry validation (issue #822
# pattern audit). services/proxy/entrypoint.sh's bash validator (mirrored
# into services/dns/entrypoint.sh via scripts/lib/domain-validation.sh) and
# services/ui/src/routes/domains.rs's Rust validator are two independent
# implementations of the same rule set, with no compiler or interpreter
# enforcing they agree. This test and domains.rs's own
# is_valid_domain_matches_shared_parity_fixture test both iterate
# tests/fixtures/domain-validation-cases.txt, so the two implementations
# are checked against the exact same cases -- a change to one validator
# that silently starts disagreeing with the other fails here (bash side)
# or in `cargo test` (Rust side), not just by comment convention.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    fixture="$repo_root/tests/fixtures/domain-validation-cases.txt"

    # shellcheck source=scripts/lib/domain-validation.sh
    source "$repo_root/scripts/lib/domain-validation.sh"
}

@test "bash _is_valid_domain agrees with the shared parity fixture on every case" {
    [ -f "$fixture" ] || fail "shared parity fixture not found: $fixture"

    local mismatches=0 total=0
    local expect domain actual

    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        expect="${line%% *}"
        domain="${line#* }"
        total=$((total + 1))

        if _is_valid_domain "$domain"; then actual="valid"; else actual="invalid"; fi

        if [[ "$actual" != "$expect" ]]; then
            echo "MISMATCH: '$domain' expected=$expect actual=$actual" >&2
            mismatches=$((mismatches + 1))
        fi
    done < "$fixture"

    # Fail closed if the fixture itself is empty/unreadable -- a vacuous
    # loop would make this test pass without checking anything.
    [ "$total" -gt 0 ] || fail "shared parity fixture had zero usable cases"
    [ "$mismatches" -eq 0 ] || fail "$mismatches of $total shared parity fixture case(s) disagreed with the bash validator"
}

# Defense against a functional regression the sync/parity tests above can't
# catch: they prove the validator is correct in isolation, not that it
# doesn't reject a domain the real shipped cdn-domains.txt already relies on.
# If any real entry newly fails _is_valid_domain, services/dns/entrypoint.sh's
# RPZ generation would silently drop it from DNS spoofing -- a regression
# that would only surface as "this CDN stopped caching," not a build error.
@test "the real shipped services/dns/cdn-domains.txt fully validates" {
    local domains_file="$repo_root/services/dns/cdn-domains.txt"
    [ -f "$domains_file" ] || fail "services/dns/cdn-domains.txt not found"

    local would_skip=0 domain
    while IFS= read -r domain || [ -n "$domain" ]; do
        domain="${domain#"${domain%%[![:space:]]*}"}"
        domain="${domain%"${domain##*[![:space:]]}"}"
        [[ -z "$domain" || "$domain" == \#* ]] && continue
        # A leading-dot wildcard-only marker is stripped the same way
        # services/dns/entrypoint.sh's RPZ loop strips it before validating,
        # so a legitimate ".example.com" entry isn't misjudged as invalid.
        domain="${domain#.}"
        if ! _is_valid_domain "$domain"; then
            echo "WOULD-SKIP: $domain" >&2
            would_skip=$((would_skip + 1))
        fi
    done < "$domains_file"

    [ "$would_skip" -eq 0 ] || fail "$would_skip real cdn-domains.txt entries would be silently skipped by RPZ generation -- fix the entry or the validator before merging"
}
