#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Drift guard for the domain-validation library (issue #822 pattern audit:
# services/dns/entrypoint.sh's RPZ zone generation had zero domain
# validation while services/proxy/entrypoint.sh already had one; the fix
# extracted the proxy's validator into a canonical shared library so both
# services stay identical instead of one being fixed and the other drifting
# again later).
#
# scripts/lib/domain-validation.sh is the single documented, tested
# contract, but it is not baked into the proxy/dns container images via a
# shared Docker build context (each Dockerfile builds from its own isolated
# service directory). Instead, services/proxy/entrypoint.sh and
# services/dns/entrypoint.sh each embed a byte-identical copy of its
# function definitions between "# BEGIN domain-validation library" and
# "# END domain-validation library" markers. This test fails loudly the
# moment either embedded copy drifts from the canonical file, so a future
# edit to one copy can't silently leave the other behind -- the same class
# of guard tests/bats/known_good_snapshots_sync.bats already provides for
# the known-good-snapshot library.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    canonical_file="$repo_root/scripts/lib/domain-validation.sh"
}

# extract_canonical_functions
# Prints scripts/lib/domain-validation.sh with its file-level header comment
# stripped, keeping only the function definitions -- the same content each
# entrypoint embeds between its BEGIN/END markers.
extract_canonical_functions() {
    awk '/^_is_valid_domain_label\(\)/ { capture = 1 } capture { print }' "$canonical_file"
}

# extract_embedded_block <entrypoint_file>
# Prints the content strictly between the BEGIN/END marker comment lines in
# an entrypoint script (exclusive of the marker lines themselves).
extract_embedded_block() {
    awk '
        /^# END domain-validation library/ { capture = 0 }
        capture { print }
        /^# BEGIN domain-validation library/ { capture = 1 }
    ' "$1"
}

@test "services/proxy/entrypoint.sh embeds the canonical domain-validation library verbatim" {
    diff <(extract_canonical_functions) <(extract_embedded_block "$repo_root/services/proxy/entrypoint.sh")
}

@test "services/dns/entrypoint.sh embeds the canonical domain-validation library verbatim" {
    diff <(extract_canonical_functions) <(extract_embedded_block "$repo_root/services/dns/entrypoint.sh")
}

@test "both entrypoint copies are identical to each other" {
    diff <(extract_embedded_block "$repo_root/services/proxy/entrypoint.sh") \
         <(extract_embedded_block "$repo_root/services/dns/entrypoint.sh")
}
