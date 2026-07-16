#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Drift guard for the shared-secret bootstrap library (issue #858).
#
# scripts/lib/shared-secret-bootstrap.sh is the single documented contract, but
# it is not baked into the dns/dhcp/ui container images through a shared Docker
# build context (each of those Dockerfiles builds from its own service directory,
# the same constraint the known-good-snapshot library documents). Instead,
# services/dns/entrypoint.sh, services/dhcp/entrypoint.sh, and
# services/ui/docker-entrypoint.sh each embed a byte-identical copy of the
# function definitions between "# BEGIN shared-secret-bootstrap library" and
# "# END shared-secret-bootstrap library" markers. This test fails loudly the
# moment any embedded copy drifts from the canonical file, so a future edit to
# one copy can't silently leave the others behind.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    canonical_file="$repo_root/scripts/lib/shared-secret-bootstrap.sh"
}

# extract_canonical_functions
# Prints scripts/lib/shared-secret-bootstrap.sh from its first function's doc
# comment to EOF, stripping the file-level header -- the same content each
# entrypoint embeds between its BEGIN/END markers.
extract_canonical_functions() {
    awk '/^# lancache_shared_secret_dir/ { capture = 1 } capture { print }' "$canonical_file"
}

# extract_embedded_block <entrypoint_file>
# Prints the content strictly between the BEGIN/END marker comment lines in an
# entrypoint script (exclusive of the marker lines themselves).
extract_embedded_block() {
    awk '
        /^# END shared-secret-bootstrap library/ { capture = 0 }
        capture { print }
        /^# BEGIN shared-secret-bootstrap library/ { capture = 1 }
    ' "$1"
}

@test "services/dns/entrypoint.sh embeds the canonical shared-secret bootstrap library verbatim" {
    diff <(extract_canonical_functions) <(extract_embedded_block "$repo_root/services/dns/entrypoint.sh")
}

@test "services/dhcp/entrypoint.sh embeds the canonical shared-secret bootstrap library verbatim" {
    diff <(extract_canonical_functions) <(extract_embedded_block "$repo_root/services/dhcp/entrypoint.sh")
}

@test "services/ui/docker-entrypoint.sh embeds the canonical shared-secret bootstrap library verbatim" {
    diff <(extract_canonical_functions) <(extract_embedded_block "$repo_root/services/ui/docker-entrypoint.sh")
}

@test "all three embedded copies are identical to each other" {
    diff <(extract_embedded_block "$repo_root/services/dns/entrypoint.sh") \
         <(extract_embedded_block "$repo_root/services/dhcp/entrypoint.sh")
    diff <(extract_embedded_block "$repo_root/services/dns/entrypoint.sh") \
         <(extract_embedded_block "$repo_root/services/ui/docker-entrypoint.sh")
}
