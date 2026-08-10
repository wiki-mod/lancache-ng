#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Bats helper that loads the dhcp-proxy entrypoint's issue #705 PXE
# boot-pointer rendering function (`_dhcp_proxy_render_pxe_service_directives`)
# and its shared newline guard (`_dhcp_proxy_reject_embedded_newline`)
# directly from services/dhcp-proxy/entrypoint.sh, without executing the
# rest of the entrypoint.

load_dhcp_proxy_pxe_service_directives_helpers() {
    local repo_root="$1" helper_file="$2"

    awk '
        /^_dhcp_proxy_reject_embedded_newline\(\) \{/ { in_fn1 = 1 }
        in_fn1 { print }
        in_fn1 && /^\}$/ { in_fn1 = 0 }
        /^_dhcp_proxy_render_pxe_service_directives\(\) \{/ { in_fn2 = 1 }
        in_fn2 { print }
        in_fn2 && /^\}$/ { in_fn2 = 0 }
    ' "$repo_root/services/dhcp-proxy/entrypoint.sh" > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
