#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads the dhcp-proxy entrypoint's issue #450
# optional-directive rendering functions
# (`_dhcp_proxy_render_optional_directives`,
# `_dhcp_proxy_render_custom_options`) directly from
# services/dhcp-proxy/entrypoint.sh, without executing the rest of the
# entrypoint (env var requirements, dnsmasq --test, known-good-snapshot
# rollback, etc.).

load_dhcp_proxy_optional_directives_helpers() {
    local repo_root="$1" helper_file="$2"

    awk '
        /^_dhcp_proxy_render_optional_directives\(\) \{/ { in_fn1 = 1 }
        in_fn1 { print }
        in_fn1 && /^\}$/ { in_fn1 = 0 }
        /^_dhcp_proxy_render_custom_options\(\) \{/ { in_fn2 = 1 }
        in_fn2 { print }
        in_fn2 && /^\}$/ { in_fn2 = 0 }
    ' "$repo_root/services/dhcp-proxy/entrypoint.sh" > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
