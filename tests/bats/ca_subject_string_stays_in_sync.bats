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
    # Extract the CA -subj argument value from both files using grep.
    # The CA distinguished name has the form: -subj "/CN=...../O=...../C=DE"
    #
    # services/proxy/entrypoint.sh has TWO `-subj` invocations: the CA cert
    # (full DN with /O= and /C=) and a per-domain wildcard cert that is CN-only
    # (`-subj "/CN=${cn}"`). A bare `grep -oP` for `-subj` therefore returns two
    # lines for the proxy entrypoint, which never string-equals generate-ca.sh's
    # single CA line. Filter to the /O= line to isolate the CA DN and exclude the
    # CN-only per-domain template. Do not drop this filter or the sync check will
    # always compare a two-line value against a one-line value and fail.

    local generate_ca_subj
    local proxy_subj

    # Extract the CA subject from generate-ca.sh (its only -subj is the CA DN).
    generate_ca_subj=$(grep -oP '(?<=-subj ")[^"]*' "$generate_ca_script" | grep -F '/O=')
    [ -n "$generate_ca_subj" ] || skip "Could not extract CA -subj from generate-ca.sh"

    # Extract only the CA-DN -subj from the proxy entrypoint, skipping the CN-only per-domain cert.
    proxy_subj=$(grep -oP '(?<=-subj ")[^"]*' "$proxy_entrypoint" | grep -F '/O=')
    [ -n "$proxy_subj" ] || skip "Could not extract CA -subj from proxy entrypoint.sh"

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
