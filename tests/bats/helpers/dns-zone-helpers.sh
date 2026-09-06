#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: Loads real function bodies from entrypoint.sh at test time
# Why: Eliminates drift risk vs. independently-maintained copy

load_dns_zone_helpers() {
    local repo_root="$1" helper_file="$2"

    awk '
        /^_dns_generate_rpz_zone\(\) \{/ { in_fn = 1 }
        /^_dns_ensure_zone_exists\(\) \{/ { in_fn = 1 }
        /^_dns_soa_maintain_zone\(\) \{/ { in_fn = 1 }
        in_fn { print }
        in_fn && /^\}$/ { in_fn = 0 }
    ' "$repo_root/services/dns/entrypoint.sh" > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}

# generate_rpz_zone <domains_file> <output_file> <proxy_ip> [proxy_ipv6]
# What: Wrapper around the real _dns_generate_rpz_zone implementation
# Why: Stable interface keeps existing callers unchanged
generate_rpz_zone() {
    _dns_generate_rpz_zone "$@"
}
