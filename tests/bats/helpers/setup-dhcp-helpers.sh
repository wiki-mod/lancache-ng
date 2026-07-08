#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads setup.sh's DHCP-mode helper functions without
# executing setup.sh's install/update entrypoint. Extracts the real functions
# by name so tests exercise production logic rather than test-only copies.

load_setup_dhcp_helpers() {
    local repo_root="$1" helper_file="$2"

    awk '
        function want(name) {
            return name == "is_valid_ipv4" \
                || name == "is_dnsmasq_subnet_start" \
                || name == "is_valid_dhcp_mode" \
                || name == "compose_profiles_for_runtime"
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

    # shellcheck source=/dev/null
    source "$helper_file"
}
