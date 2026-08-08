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
        # _proxy_validate_snapshot_or_rollback function, and (defined further
        # down, AFTER it, in entrypoint.sh's own real file order)
        # _migrate_legacy_proxy_snapshots_for_stream_acl. Exits only once the
        # LAST of these three ranges closes -- exiting right after
        # _proxy_validate_snapshot_or_rollback's own closing brace would stop
        # before ever reaching _migrate_legacy_proxy_snapshots_for_stream_acl
        # later in the file.
        awk '
            /^# BEGIN known-good-snapshot library/ { capture = 1; next }
            /^# END known-good-snapshot library/ { capture = 0 }
            capture { print }
            /^_proxy_validate_snapshot_or_rollback\(\) \{/ { in_fn = 1 }
            in_fn { print }
            in_fn && /^\}$/ { in_fn = 0 }
            /^_migrate_legacy_proxy_snapshots_for_stream_acl\(\) \{/ { in_migrate = 1 }
            in_migrate { print }
            in_migrate && /^\}$/ { exit }
        ' "$repo_root/services/proxy/entrypoint.sh"
    } > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
