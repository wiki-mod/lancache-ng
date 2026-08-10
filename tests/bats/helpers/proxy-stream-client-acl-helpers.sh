#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads services/proxy/entrypoint.sh's REAL
# _render_stream_client_acl() via awk extraction, mirroring the technique
# already used by the other tests/bats/helpers/proxy-*.sh files. This is the
# ngx_stream_access_module allow/deny generator for the stream-level
# externally-facing listeners (standard mode's 8443, SSL mode's 443
# dispatcher), enforcing PROXY_ALLOWED_CLIENT_CIDRS at the TCP level ahead
# of ssl_preread.

load_proxy_stream_client_acl_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        awk '
            /^_render_stream_client_acl\(\) \{/ { in_fn = 1 }
            in_fn { print }
            in_fn && /^\}$/ { exit }
        ' "$repo_root/services/proxy/entrypoint.sh"
    } > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
