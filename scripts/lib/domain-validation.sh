#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Domain-entry validation contract, shared by every consumer of
# cdn-domains.txt-style domain lists (proxy wildcard-cert/nginx-map
# generation, DNS RPZ zone generation). Mirrors the label-strict rules from
# the Admin UI's Rust validator (services/ui/src/routes/domains.rs's
# is_valid_domain/is_valid_domain_label) so a malformed or overly-broad entry
# (e.g. a bare TLD, a single label like "localhost", or "*") is rejected the
# same way everywhere a domain list is consumed, not just in the UI that
# writes it. Validation follows RFC 1035 and DNS best practices:
#
#   - Max 253 chars total length
#   - Min 2 labels (no single-label domains like "localhost")
#   - Each label: 1-63 chars, start/end with alphanumeric, contain only a-z/0-9/-
#   - Leading dot is stripped (optional in file notation, marks a
#     wildcard-only entry -- see the "Domain scope semantics" rule in
#     AGENTS.md: a leading-dot entry is NOT equivalent to its root domain)
#   - Input is trimmed and lowercased before validation
#   - Control characters and special chars are rejected
#
# This is the canonical, documented reference implementation. It is NOT
# copied into any container image via a shared Docker build context: each
# service Dockerfile (services/proxy, services/dns) builds from its own
# isolated directory with no shared-file context wired up for it. Instead,
# services/proxy/entrypoint.sh and services/dns/entrypoint.sh each embed a
# byte-identical copy of these functions between the marker comments
#   # BEGIN domain-validation library (scripts/lib/domain-validation.sh)
#   # END domain-validation library
# tests/bats/domain_validation_sync.bats fails the build if either embedded
# copy ever drifts from this file. tests/bats/domain_validation_parity.bats
# and services/ui/src/routes/domains.rs's own
# `is_valid_domain_matches_shared_parity_fixture` test both iterate the same
# shared fixture file (tests/fixtures/domain-validation-cases.txt) so the
# bash and Rust validators can't silently diverge in what they accept or
# reject either.

_is_valid_domain_label() {
    local label="$1"

    # Label must not be empty
    [ -n "$label" ] || return 1

    # Label must be <= 63 chars
    [ ${#label} -le 63 ] || return 1

    # Label must not start or end with hyphen
    [[ "$label" != -* ]] && [[ "$label" != *- ]] || return 1

    # Label must only contain lowercase ASCII a-z, digits 0-9, or hyphen
    [[ "$label" =~ ^[a-z0-9-]+$ ]] || return 1

    return 0
}

# Prints the normalized form (trimmed, lowercased, leading dot stripped) of a
# domain to stdout. Callers must capture this and use it instead of the raw
# input for anything written to disk/config — _is_valid_domain() only reports
# whether a value validates, it does not mutate the caller's variable.
_normalize_domain() {
    local domain="$1"
    # Trim whitespace via pure parameter expansion, not xargs — xargs applies
    # shell-style unquoting/escaping first, which would let malformed manual
    # entries like a quoted "Example.COM" slip through as a clean example.com.
    domain="${domain#"${domain%%[![:space:]]*}"}"
    domain="${domain%"${domain##*[![:space:]]}"}"
    domain="${domain,,}"
    domain="${domain#.}"
    printf '%s' "$domain"
}

_is_valid_domain() {
    local domain
    domain="$(_normalize_domain "$1")"

    # Must not be empty after normalization
    [ -n "$domain" ] || return 1

    # Must be <= 253 chars total (RFC 1035 domain name length limit)
    [ ${#domain} -le 253 ] || return 1

    # Check for trailing dot (RFC 1035 allows it, but we reject it like the Rust validator does)
    [[ "$domain" != *. ]] || return 1

    # Validate each label using a loop to properly handle empty labels
    # (bash word splitting would silently drop trailing empty labels,
    # but we want to reject domains like "example.com." explicitly)
    local label
    local remaining="$domain"

    while [ -n "$remaining" ]; do
        # Extract label up to next dot
        if [[ "$remaining" == *.* ]]; then
            label="${remaining%%.*}"
            remaining="${remaining#*.}"
        else
            label="$remaining"
            remaining=""
        fi

        _is_valid_domain_label "$label" || return 1
    done

    # Must have at least 2 labels (so the loop must execute at least twice)
    # We can check this by ensuring the domain contains at least one dot
    [[ "$domain" == *.* ]] || return 1

    return 0
}
