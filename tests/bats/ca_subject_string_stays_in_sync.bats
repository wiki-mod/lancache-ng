#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Sync-guard test to ensure the CA subject string (CN/O) stays consistent
# between certs/generate-ca.sh and services/proxy/entrypoint.sh.
# Both paths generate CA certificates, and their subject strings must remain
# identical to avoid cosmetic divergence in newly-generated installations.
# See issue #968.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    generate_ca_script="$repo_root/certs/generate-ca.sh"
    proxy_entrypoint="$repo_root/services/proxy/entrypoint.sh"
}

@test "CA subject string stays in sync between generate-ca.sh and services/proxy/entrypoint.sh" {
    # Extract the -subj argument value from both files using grep.
    # Both use the form: -subj "/CN=...../O=...../C=DE"

    local generate_ca_subj
    local proxy_subj

    # Extract from generate-ca.sh: grep for the line with -subj, extract the quoted string
    generate_ca_subj=$(grep -oP '(?<=-subj ")[^"]*' "$generate_ca_script")
    [ -n "$generate_ca_subj" ] || skip "Could not extract -subj from generate-ca.sh"

    # Extract from proxy entrypoint: same pattern
    proxy_subj=$(grep -oP '(?<=-subj ")[^"]*' "$proxy_entrypoint")
    [ -n "$proxy_subj" ] || skip "Could not extract -subj from proxy entrypoint.sh"

    # They must match exactly
    [ "$generate_ca_subj" = "$proxy_subj" ] || {
        echo "CA subject string mismatch:"
        echo "  generate-ca.sh:    $generate_ca_subj"
        echo "  proxy entrypoint:  $proxy_subj"
        return 1
    }

    # Verify they contain the expected canonical "LanCache-NG" naming
    [[ "$generate_ca_subj" == *"LanCache-NG"* ]] || {
        echo "CA subject does not contain expected 'LanCache-NG' naming: $generate_ca_subj"
        return 1
    }
}
