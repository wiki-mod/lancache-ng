#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads services/proxy/entrypoint.sh's REAL
# _ensure_ca_cert()/_harden_cert_dir() functions via awk extraction, mirroring
# tests/bats/helpers/proxy-cert-helpers.sh's technique for a disjoint range of
# the same file. Both functions live inside the `if [ "${SSL_ENABLED}" = "1" ]; then`
# block and are extracted by name specifically so this real behavior (the
# file-mode hardening: ca.key's chmod 600, CERT_DIR's chmod 2750) can be
# driven directly, instead of adding a third, separately-maintained
# hand-copy of the same logic to a test helper.

load_proxy_cert_dir_permissions_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        awk '
            /^    _ensure_ca_cert\(\) \{/ { in_fn = 1 }
            in_fn { print }
            in_fn && /^    \}$/ { in_fn = 0; next }
            /^    _harden_cert_dir\(\) \{/ { in_fn2 = 1 }
            in_fn2 { print }
            in_fn2 && /^    \}$/ { exit }
        ' "$repo_root/services/proxy/entrypoint.sh"
    } > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
