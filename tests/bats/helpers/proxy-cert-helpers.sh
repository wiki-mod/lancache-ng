#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads proxy entrypoint's certificate generation functions
# without executing the full entrypoint.

load_proxy_cert_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        # Extract domain validation and certificate signing functions from entrypoint.sh
        # Start from the first domain validation function through the end of _sign_cert
        awk '
            /^_is_valid_domain_label\(\)/ { capture = 1 }
            capture { print }
            /^    _sign_cert\(\) {/{in_sign_cert = 1}
            in_sign_cert && /^    \}$/{print; exit}
        ' "$repo_root/services/proxy/entrypoint.sh"
    } > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
