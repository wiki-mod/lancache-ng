#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads the proxy entrypoint's known-good-snapshot library
# and its `_proxy_validate_snapshot_or_rollback` adapter function without
# executing the full entrypoint (CA generation, cdn-domains.txt parsing,
# iptables, etc.).

load_proxy_known_good_snapshot_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        # Two disjoint ranges, mirroring the technique in
        # proxy-cert-helpers.sh: the known-good-snapshot library functions
        # (between the BEGIN/END marker comments), and the
        # _proxy_validate_snapshot_or_rollback function further down.
        awk '
            /^# BEGIN known-good-snapshot library/ { capture = 1; next }
            /^# END known-good-snapshot library/ { capture = 0 }
            capture { print }
            /^_proxy_validate_snapshot_or_rollback\(\) \{/ { in_fn = 1 }
            in_fn { print }
            in_fn && /^\}$/ { exit }
        ' "$repo_root/services/proxy/entrypoint.sh"
    } > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
