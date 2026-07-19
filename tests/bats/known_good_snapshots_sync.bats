#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Drift guard for the known-good configuration snapshot library (#415, #615).
#
# scripts/lib/known-good-snapshots.sh is the single documented, tested
# contract, but it is not baked into the proxy/dhcp-proxy/dns container
# images via a shared Docker build context (see
# docs/known-good-config-snapshots.md for why). Instead,
# services/proxy/entrypoint.sh, services/dhcp-proxy/entrypoint.sh, and
# services/dns/entrypoint.sh each embed a byte-identical copy of its
# function definitions between "# BEGIN known-good-snapshot library" and
# "# END known-good-snapshot library" markers. This test fails loudly the
# moment any embedded copy drifts from the canonical file, so a future
# edit to one copy can't silently leave the others behind.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    canonical_file="$repo_root/scripts/lib/known-good-snapshots.sh"
}

# extract_canonical_functions
# Prints scripts/lib/known-good-snapshots.sh with its file-level header
# comment stripped, keeping only the function definitions -- the same
# content each entrypoint embeds between its BEGIN/END markers.
extract_canonical_functions() {
    awk '/^# kgs_log <level>/ { capture = 1 } capture { print }' "$canonical_file"
}

# extract_embedded_block <entrypoint_file>
# Prints the content strictly between the BEGIN/END marker comment lines in
# an entrypoint script (exclusive of the marker lines themselves).
extract_embedded_block() {
    awk '
        /^# END known-good-snapshot library/ { capture = 0 }
        capture { print }
        /^# BEGIN known-good-snapshot library/ { capture = 1 }
    ' "$1"
}

@test "services/proxy/entrypoint.sh embeds the canonical known-good-snapshot library verbatim" {
    diff <(extract_canonical_functions) <(extract_embedded_block "$repo_root/services/proxy/entrypoint.sh")
}

@test "services/dhcp-proxy/entrypoint.sh embeds the canonical known-good-snapshot library verbatim" {
    diff <(extract_canonical_functions) <(extract_embedded_block "$repo_root/services/dhcp-proxy/entrypoint.sh")
}

@test "services/dns/entrypoint.sh embeds the canonical known-good-snapshot library verbatim" {
    diff <(extract_canonical_functions) <(extract_embedded_block "$repo_root/services/dns/entrypoint.sh")
}

@test "all three entrypoint copies are identical to each other" {
    diff <(extract_embedded_block "$repo_root/services/proxy/entrypoint.sh") \
         <(extract_embedded_block "$repo_root/services/dhcp-proxy/entrypoint.sh")
    diff <(extract_embedded_block "$repo_root/services/proxy/entrypoint.sh") \
         <(extract_embedded_block "$repo_root/services/dns/entrypoint.sh")
}
