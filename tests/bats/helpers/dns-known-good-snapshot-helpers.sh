#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads the DNS (PowerDNS) entrypoint's known-good-snapshot
# library and its `_dns_recursor_validate_snapshot_or_rollback` /
# `_dns_auth_probe` / `_dns_auth_validate_snapshot_or_rollback` adapter
# functions without executing the full entrypoint (PDNS_API_KEY placeholder
# checks, zone creation, RPZ generation, etc.).

load_dns_known_good_snapshot_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        # Three disjoint ranges: the known-good-snapshot library functions
        # (between the BEGIN/END marker comments), render_template_atomic
        # (needed by tests that render candidate configs the same way the
        # real entrypoint does), and the three DNS-specific adapter
        # functions further down. Mirrors the technique in
        # proxy-known-good-snapshot-helpers.sh /
        # dhcp-proxy-known-good-snapshot-helpers.sh.
        awk '
            /^# BEGIN known-good-snapshot library/ { capture = 1; next }
            /^# END known-good-snapshot library/ { capture = 0 }
            capture { print }

            /^render_template_atomic\(\) \{/ { in_fn = 1 }
            /^_dns_recursor_validate_snapshot_or_rollback\(\) \{/ { in_fn = 1 }
            /^_dns_auth_probe\(\) \{/ { in_fn = 1 }
            /^_dns_auth_validate_snapshot_or_rollback\(\) \{/ { in_fn = 1 }
            in_fn { print }
            in_fn && /^\}$/ { in_fn = 0 }
        ' "$repo_root/services/dns/entrypoint.sh"
    } > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
