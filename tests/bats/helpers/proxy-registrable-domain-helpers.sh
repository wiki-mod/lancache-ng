#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads services/proxy/entrypoint.sh's REAL public-suffix-
# list-driven root-domain derivation (_load_public_suffix_list,
# _suffix_from_end, _registrable_domain) via awk extraction, the same
# pattern tests/bats/helpers/proxy-cert-helpers.sh already uses for a
# different, disjoint range of the same file.
#
# This is deliberately NOT the same _registrable_domain that
# tests/bats/proxy_collect_domain_rows.bats exercises -- that file's own
# helper (proxy-collect-domain-rows-helpers.sh) stubs _registrable_domain as
# a plain identity function on purpose, since it is testing
# _collect_domain_rows' row-handling logic in isolation, not real PSL
# derivation (see that helper's own comment). Before this file, the real,
# PSL-backed _registrable_domain was untested anywhere in the suite for a
# compound-label public suffix (co.uk-style) or the PSL's own exception-rule
# interplay (!city.kawasaki.jp-style) -- bug-hunt #849, finding #9's third
# sub-part.

load_proxy_registrable_domain_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        # Captures the three _PSL_* associative-array declarations plus the
        # _load_public_suffix_list/_suffix_from_end/_registrable_domain
        # function bodies -- everything _registrable_domain needs to run for
        # real. Stops at _registrable_domain's own closing brace, which
        # deliberately excludes the real file's next line: a bare top-level
        # call to _load_public_suffix_list() against the real container path
        # $PUBLIC_SUFFIX_LIST_FILE. This helper's caller loads the list
        # itself (see tests/bats/proxy_registrable_domain.bats's setup()),
        # pointed at the real vendored
        # services/proxy/public_suffix_list.dat fixture path instead, so the
        # exact same parsing code runs against the exact same real PSL data
        # this service ships, not a hand-written fixture list that could
        # drift from upstream's real rule shapes.
        awk '
            /^declare -A _PSL_RULES=\(\)/ { capture = 1 }
            capture { print }
            /^_registrable_domain\(\) \{/ { in_rd = 1 }
            in_rd && /^\}$/ { capture = 0 }
        ' "$repo_root/services/proxy/entrypoint.sh"
    } > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"

    # -g is required here, same reason as
    # tests/bats/helpers/proxy-collect-domain-rows-helpers.sh's own detailed
    # comment on this exact pattern: this function itself is one level of
    # function nesting deeper than that file's setup(), so the awk-extracted
    # `declare -A _PSL_RULES=()` (etc.) lines the `source` above just ran
    # scope to THIS function, not to the caller -- they are destroyed the
    # moment this function returns. Without -g, the next real assignment
    # inside _load_public_suffix_list() implicitly creates a plain (non-
    # associative) global instead, and `_PSL_RULES["$rule"]=1` for a
    # non-numeric key like "com.ac" then fails with bash's "invalid
    # arithmetic operator" (confirmed live: this exact failure was hit and
    # fixed while writing this helper, not merely reasoned about). Declaring
    # the empty maps again here, after sourcing, makes them real globals the
    # caller's later _load_public_suffix_list call can actually populate.
    declare -Ag _PSL_RULES=()
    declare -Ag _PSL_WILDCARDS=()
    declare -Ag _PSL_EXCEPTIONS=()
}
