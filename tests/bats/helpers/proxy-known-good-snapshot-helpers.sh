#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads the proxy entrypoint's known-good-snapshot library,
# its `_migrate_legacy_proxy_snapshots_for_stream_acl` one-time backfill, and
# its `_proxy_validate_snapshot_or_rollback` adapter function without
# executing the full entrypoint (CA generation, cdn-domains.txt parsing,
# iptables, etc.).

load_proxy_known_good_snapshot_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        # Three disjoint ranges, mirroring the technique in
        # proxy-cert-helpers.sh: the known-good-snapshot library functions
        # (between the BEGIN/END marker comments), the
        # _migrate_legacy_proxy_snapshots_for_stream_acl backfill, and the
        # _proxy_validate_snapshot_or_rollback function further down.
        awk '
            /^# BEGIN known-good-snapshot library/ { capture = 1; next }
            /^# END known-good-snapshot library/ { capture = 0 }
            capture { print }
            /^_migrate_legacy_proxy_snapshots_for_stream_acl\(\) \{/ { in_migrate = 1 }
            in_migrate { print }
            in_migrate && /^\}$/ { in_migrate = 0 }
            /^_proxy_validate_snapshot_or_rollback\(\) \{/ { in_fn = 1 }
            in_fn { print }
            in_fn && /^\}$/ { exit }
        ' "$repo_root/services/proxy/entrypoint.sh"
    } > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
