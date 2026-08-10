#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Bats helper that extracts services/proxy/entrypoint.sh's real
# _purge_stale_leaf_certs_on_ca_change() so its CA-fingerprint-tracked leaf
# invalidation can be driven directly against real openssl-generated certs,
# without executing the rest of the entrypoint.

load_proxy_cert_ca_rotation_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        awk '
            /^    _purge_stale_leaf_certs_on_ca_change\(\) \{/ { in_fn = 1 }
            in_fn { print }
            in_fn && /^    \}$/ { exit }
        ' "$repo_root/services/proxy/entrypoint.sh"
    } > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
