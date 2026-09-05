#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Bats helper that loads setup.sh's REAL sync_dhcp_proxy_config_prod_env()
# and its full real dependency chain (is_deploy_prod_install_dir,
# deploy_prod_repo_root, config_prod_dir_for_install_dir,
# sync_config_prod_env_key_from_template, get_env_var/
# _compose_parse_env_value, set_env_key/validate_env_value/env_key_exists/
# write_env_file, die) via awk extraction, mirroring
# tests/bats/helpers/setup-dhcp-helpers.sh's established technique for this
# file. print_ok is intentionally NOT extracted (its single-line
# function-body shape does not fit this extraction technique's
# one-closing-brace-per-line assumption) and is stubbed as a no-op instead,
# since it only affects human-readable output, not the function's actual
# file-write behavior under test.

load_setup_dhcp_proxy_config_prod_sync_helpers() {
    local repo_root="$1" helper_file="$2"

    awk '
        function want(name) {
            return name == "is_deploy_prod_install_dir" \
                || name == "deploy_prod_repo_root" \
                || name == "config_prod_dir_for_install_dir" \
                || name == "sync_config_prod_env_key_from_template" \
                || name == "sync_dhcp_proxy_config_prod_env" \
                || name == "get_env_var" \
                || name == "_compose_parse_env_value" \
                || name == "set_env_key" \
                || name == "env_key_exists" \
                || name == "validate_env_value" \
                || name == "write_env_file" \
                || name == "die"
        }
        !capture && /^[a-z0-9_]+\(\) \{/ {
            fname = $0
            sub(/\(\).*/, "", fname)
            if (want(fname)) { capture = 1; print; next }
        }
        capture {
            print
            if ($0 == "}") { capture = 0 }
        }
    ' "$repo_root/setup.sh" > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"

    print_ok() { :; }
}
