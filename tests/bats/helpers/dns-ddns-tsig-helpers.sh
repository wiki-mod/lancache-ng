#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Bats helper that loads secret_is_placeholder (from the canonical
# scripts/lib/shared-secret-bootstrap.sh) plus configure_ddns_tsig and
# its DNS-specific siblings, awk-extracted from services/dns/entrypoint.sh,
# without executing the full entrypoint.

load_dns_ddns_tsig_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        # What: secret_is_placeholder now lives in the shared lib.
        # Why: entrypoint.sh sources it, no longer defines it.
        # From: Issue #1683
        cat "$repo_root/scripts/lib/shared-secret-bootstrap.sh"

        awk '
            /^configure_ddns_tsig\(\) \{/ { in_fn = 1 }
            /^import_ddns_tsig_key\(\) \{/ { in_fn = 1 }
            /^_dns_set_zone_metadata\(\) \{/ { in_fn = 1 }
            /^dns_xfr_primary_endpoint\(\) \{/ { in_fn = 1 }
            /^_dns_configure_primary_zone_replication\(\) \{/ { in_fn = 1 }
            /^_dns_ensure_secondary_zone\(\) \{/ { in_fn = 1 }
            in_fn { print }
            in_fn && /^\}$/ { in_fn = 0 }
        ' "$repo_root/services/dns/entrypoint.sh"
    } > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
