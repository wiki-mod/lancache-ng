#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads setup.sh's DHCP-mode helper functions without
# executing setup.sh's install/update entrypoint. Extracts the real functions
# by name so tests exercise production logic rather than test-only copies.

load_setup_dhcp_helpers() {
    local repo_root="$1" helper_file="$2"

    # Extract only the 4 wanted production helper functions from setup.sh's full
    # source tree. The awk script below parses setup.sh and extracts just the
    # bodies of is_valid_ipv4, is_dnsmasq_subnet_start, is_valid_dhcp_mode, and
    # compose_profiles_for_runtime by matching their declarations and copying
    # lines until a closing brace is found. This avoids sourcing the entire
    # setup.sh (which would run install/update logic and fail on test runners),
    # while ensuring tests exercise the real production functions, not copies.
    awk '
        # want(name): filter that returns 1 only for the 4 functions we need
        function want(name) {
            return name == "is_valid_ipv4" \
                || name == "is_dnsmasq_subnet_start" \
                || name == "is_valid_dhcp_mode" \
                || name == "compose_profiles_for_runtime"
        }
        # State machine: when NOT in capture mode, look for function declarations
        # (lines matching /^[a-z0-9_]+\(\) \{/). Extract the function name and
        # check if it is wanted. If yes, enter capture mode and print the line.
        !capture && /^[a-z0-9_]+\(\) \{/ {
            fname = $0
            sub(/\(\).*/, "", fname)
            if (want(fname)) { capture = 1; print; next }
        }
        # In capture mode, print every line until we hit a closing brace (on a
        # line by itself), which ends the current function body.
        capture {
            print
            if ($0 == "}") { capture = 0 }
        }
    ' "$repo_root/setup.sh" > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
