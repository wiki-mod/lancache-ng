#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Bats helper that loads services/dns/entrypoint.sh's real
# "secret_is_placeholder" and "configure_ddns_tsig" functions without
# executing the full entrypoint. Same single-file dynamic-extraction
# technique as tests/bats/helpers/dns-zone-helpers.sh /
# dns-known-good-snapshot-helpers.sh: awk-extract the real function bodies
# and source them, so a test can never drift from what the real container
# actually runs.

load_dns_ddns_tsig_helpers() {
    local repo_root="$1" helper_file="$2"

    awk '
        /^secret_is_placeholder\(\) \{/ { in_fn = 1 }
        /^configure_ddns_tsig\(\) \{/ { in_fn = 1 }
        /^import_ddns_tsig_key\(\) \{/ { in_fn = 1 }
        /^_dns_set_zone_metadata\(\) \{/ { in_fn = 1 }
        /^_dns_configure_primary_zone_replication\(\) \{/ { in_fn = 1 }
        /^_dns_ensure_secondary_zone\(\) \{/ { in_fn = 1 }
        in_fn { print }
        in_fn && /^\}$/ { in_fn = 0 }
    ' "$repo_root/services/dns/entrypoint.sh" > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
