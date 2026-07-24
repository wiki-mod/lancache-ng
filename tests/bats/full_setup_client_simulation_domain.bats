#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Docker-free, git-free unit coverage for
# scripts/lib/full-setup-domain-probe.sh's resolve_full_setup_probe_domain()
# (issue #1140): scripts/full-setup-client-simulation.sh used to pass a
# leading-dot cdn-domains.txt entry (e.g. ".steamcontent.com", the
# wildcard-only scope form from #1072/#1073/#1074) straight to `dig`, which
# rejects it as an illegal empty-label name and fails the dns-standard check
# on every full-setup validation run. Also sources scripts/lib/domain-
# validation.sh to prove the resolved probe name is genuinely dig-legal, not
# just superficially non-empty, and re-derives the real first
# cdn-domains.txt entry the same way scripts/full-setup-client-simulation.sh
# itself does, so this test breaks loudly (rather than silently passing) if
# that entry's leading-dot form is ever removed or the file's first line
# changes shape.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/lib/full-setup-domain-probe.sh
    source "$repo_root/scripts/lib/full-setup-domain-probe.sh"
    # shellcheck source=scripts/lib/domain-validation.sh
    source "$repo_root/scripts/lib/domain-validation.sh"
}

@test "a leading-dot entry becomes a legal full-setup-test subdomain of the wildcard scope" {
    result="$(resolve_full_setup_probe_domain ".steamcontent.com")"
    [ "$result" = "full-setup-test.steamcontent.com" ]
    # Not an illegal empty-label name per the shared domain validator.
    _is_valid_domain "$result"
    # Genuinely a subdomain of the wildcard scope's root, not an unrelated name.
    [[ "$result" == *".steamcontent.com" ]]
}

@test "a bare (non-dot) entry is left unchanged" {
    result="$(resolve_full_setup_probe_domain "content1.steampowered.com")"
    [ "$result" = "content1.steampowered.com" ]
    _is_valid_domain "$result"
}

@test "a multi-label leading-dot entry resolves correctly too" {
    result="$(resolve_full_setup_probe_domain ".sub.example.com")"
    [ "$result" = "full-setup-test.sub.example.com" ]
    _is_valid_domain "$result"
}

@test "the real cdn-domains.txt file's first entry resolves to a legal probe name" {
    domain_file="$repo_root/services/dns/cdn-domains.txt"
    first_entry="$(awk 'NF && $1 !~ /^#/ { print $1; exit }' "$domain_file")"
    [ -n "$first_entry" ]

    result="$(resolve_full_setup_probe_domain "$first_entry")"
    _is_valid_domain "$result"

    # Regression guard for #1140: the real file's first entry is expected to
    # still be the leading-dot wildcard-only form today (#1072); if that ever
    # changes back to a bare entry, this assertion fails loudly instead of
    # this test quietly stopping to exercise the exact leading-dot path the
    # fix targets.
    [[ "$first_entry" == .* ]]
    [ "$result" = "full-setup-test${first_entry}" ]
}
