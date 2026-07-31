#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads services/ntp/entrypoint.sh's pure config-rendering
# functions (`is_ip_literal`, `render_ntp_config`, `validate_ntp_config`,
# `_cleanup_stale_ntp_pidfile_core`, `cleanup_stale_ntp_pidfile`,
# `_fix_chrony_dir_ownership_core`, `fix_chrony_dir_ownership`) directly,
# without executing the rest of the entrypoint (the fail-closed
# empty-upstream-list check that would `exit 1` under bats, and the final
# `exec chronyd`, which does not exist in the test environment).

load_ntp_entrypoint_helpers() {
    local repo_root="$1" helper_file="$2"

    awk '
        /^is_ip_literal\(\) \{/ { in_fn1 = 1 }
        in_fn1 { print }
        in_fn1 && /^\}$/ { in_fn1 = 0 }
        /^render_ntp_config\(\) \{/ { in_fn2 = 1 }
        in_fn2 { print }
        in_fn2 && /^\}$/ { in_fn2 = 0 }
        /^validate_ntp_config\(\) \{/ { in_fn3 = 1 }
        in_fn3 { print }
        in_fn3 && /^\}$/ { in_fn3 = 0 }
        /^_cleanup_stale_ntp_pidfile_core\(\) \{/ { in_fn4 = 1 }
        in_fn4 { print }
        in_fn4 && /^\}$/ { in_fn4 = 0 }
        /^cleanup_stale_ntp_pidfile\(\) \{/ { in_fn5 = 1 }
        in_fn5 { print }
        in_fn5 && /^\}$/ { in_fn5 = 0 }
        /^_fix_chrony_dir_ownership_core\(\) \{/ { in_fn6 = 1 }
        in_fn6 { print }
        in_fn6 && /^\}$/ { in_fn6 = 0 }
        /^fix_chrony_dir_ownership\(\) \{/ { in_fn7 = 1 }
        in_fn7 { print }
        in_fn7 && /^\}$/ { in_fn7 = 0 }
    ' "$repo_root/services/ntp/entrypoint.sh" > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
