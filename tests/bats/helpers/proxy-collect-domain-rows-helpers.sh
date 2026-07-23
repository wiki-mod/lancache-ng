#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper exposing a hand-extracted copy of services/proxy/entrypoint.sh's
# _collect_domain_rows(), the loop that reads cdn-domains.txt and populates
# _UNIQUE_DOMAINS/_DOMAIN_IS_ROOT/_DOMAIN_ROWS_SKIPPED for proxy cert/nginx-map
# generation. This function is NOT part of tests/bats/helpers/proxy-cert-
# helpers.sh's awk extraction on purpose (see that file's own comment: its
# capture ranges deliberately stop before _collect_domain_rows to avoid
# pulling in entrypoint.sh's executable startup-script body). No existing
# bats suite exercised _collect_domain_rows before #1073; this helper adds
# focused coverage for the new leading-"!" disabled-entry skip it introduced,
# without taking on the larger, separate, pre-existing gap of unit-testing
# real public-suffix-list root-domain derivation (_registrable_domain) --
# that stays untested here on purpose, and this stub is why: real root
# derivation needs $PUBLIC_SUFFIX_LIST_FILE loaded via
# _load_public_suffix_list, which is unrelated to what this helper checks
# (whether a disabled row is excluded at all). The real _registrable_domain
# is stubbed as an identity function below so this file can assert
# _collect_domain_rows' skip behavior in isolation.
#
# Body kept in sync by hand with services/proxy/entrypoint.sh's real
# _collect_domain_rows() (declared just above the `_collect_domain_rows`
# top-level call in that file) -- including the leading-"!" disabled-entry
# skip added for #1073 (the Admin UI's per-domain toggle). One deliberate
# signature difference from the real function: the real one reads the
# global $DOMAINS_FILE, this test copy takes the domains file as its $1 for
# test-fixture convenience -- everything inside the loop body is otherwise
# identical. Requires scripts/lib/domain-validation.sh to already be sourced
# by the caller (see tests/bats/proxy_collect_domain_rows.bats's setup()).

# Stand-in for the real _registrable_domain (services/proxy/entrypoint.sh),
# which needs the vendored public suffix list loaded to compute a true
# registrable root. Returning the input unchanged is sufficient for these
# tests: they only assert which rows make it into _UNIQUE_DOMAINS/
# _DOMAIN_IS_ROOT at all, not what the derived root looks like.
_registrable_domain() {
    printf '%s' "$1"
    return 0
}

# -g is required here: this file is sourced from inside bats' setup()
# function (see tests/bats/proxy_collect_domain_rows.bats), and plain
# `declare` inside a function scopes the variable to that function --
# without -g, both arrays are destroyed the moment setup() returns, so by
# the time a @test body calls _collect_domain_rows(), `_DOMAIN_IS_ROOT` is
# gone entirely. The next plain assignment to it inside the function
# (`_DOMAIN_IS_ROOT=()`) then silently recreates it as an ordinary (non-
# associative) variable, so `_DOMAIN_IS_ROOT[$root]` is parsed as an
# arithmetic array subscript instead of a string key -- which fails with
# "invalid arithmetic operator" the moment $root contains a "." character.
# The real services/proxy/entrypoint.sh does not have this problem: it
# declares these at the actual top level of the executed script, never
# inside a function, so they are genuinely global there already.
declare -ag _UNIQUE_DOMAINS=()
declare -Ag _DOMAIN_IS_ROOT=()
_DOMAIN_ROWS_SKIPPED=0

_collect_domain_rows() {
    local domains_file="$1"
    _UNIQUE_DOMAINS=()
    _DOMAIN_IS_ROOT=()
    _DOMAIN_ROWS_SKIPPED=0
    local raw_domain domain root

    while IFS= read -r raw_domain || [ -n "$raw_domain" ]; do
        domain="${raw_domain#"${raw_domain%%[![:space:]]*}"}"
        domain="${domain%"${domain##*[![:space:]]}"}"
        [[ -z "$domain" || "$domain" == \#* ]] && continue

        # A leading "!" marks a deliberately disabled entry (#1073) -- skip
        # it silently (no _DOMAIN_ROWS_SKIPPED, no WARNING), same as the real
        # services/proxy/entrypoint.sh loop.
        [[ "$domain" == !* ]] && continue

        # Validate and normalize domain before using it anywhere
        if ! _is_valid_domain "$domain"; then
            echo "[lancache] WARNING: skipping invalid domain entry: $domain" >&2
            _DOMAIN_ROWS_SKIPPED=1
            continue
        fi
        domain="$(_normalize_domain "$domain")"
        [[ -z "$domain" ]] && continue

        if ! root="$(_registrable_domain "$domain")" || [[ -z "$root" ]]; then
            echo "[lancache] WARNING: could not derive a root domain for: $domain" >&2
            _DOMAIN_ROWS_SKIPPED=1
            continue
        fi

        if [[ -z "${_DOMAIN_IS_ROOT[$root]+set}" ]]; then
            _UNIQUE_DOMAINS+=("$root")
        fi
        _DOMAIN_IS_ROOT["$root"]=1
    done < "$domains_file"
}
