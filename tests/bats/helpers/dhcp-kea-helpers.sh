#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads services/dhcp/entrypoint.sh's config-generation
# functions without executing the full entrypoint.

load_dhcp_kea_functions() {
    local repo_root="$1" helper_file="$2"

    {
        # Extract config generation functions from entrypoint.sh using awk.
        # Each function is captured from its definition to the closing brace at column 0.
        awk '
            # Match function definitions that we want to extract
            /^(is_ipv4|is_ipv4_csv|resolve_ntp_server|resolve_ntp_csv|build_ntp_option|render_kea_config|render_kea_dhcp4_config)\(\)/ {
                capture = 1
            }

            # Print lines while capturing
            capture {
                print
            }

            # Stop capturing at closing brace at column 0
            /^}$/ && capture {
                capture = 0
            }
        ' "$repo_root/services/dhcp/entrypoint.sh"
    } > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
