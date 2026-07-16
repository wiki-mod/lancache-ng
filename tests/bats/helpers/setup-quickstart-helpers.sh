#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads setup.sh's install_quickstart_compose_assets()
# without executing setup.sh's install/update entrypoint. Extracts the real
# function by name so tests exercise production logic rather than a
# test-only copy.

load_setup_quickstart_helpers() {
    local repo_root="$1" helper_file="$2"

    # Extract only install_quickstart_compose_assets from setup.sh's full
    # source tree, using the same state-machine technique as
    # setup-dhcp-helpers.sh: look for the function's declaration line, then
    # copy every line up to the closing brace on its own line. This avoids
    # sourcing the entire setup.sh (which would run install/update logic and
    # fail on test runners), while still testing the real production
    # function, not a copy.
    awk '
        !capture && /^install_quickstart_compose_assets\(\) \{/ { capture = 1; print; next }
        capture {
            print
            if ($0 == "}") { capture = 0 }
        }
    ' "$repo_root/setup.sh" > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"

    # install_quickstart_compose_assets() reads these three globals (normally
    # set once near the top of setup.sh from $SCRIPT_DIR). Point them at the
    # real repo files so tests exercise the actual shipped assets. shellcheck
    # can't see the read inside the separately-sourced $helper_file, so it
    # flags these as unused (SC2034) even though install_quickstart_compose_assets
    # reads all three at runtime.
    # shellcheck disable=SC2034
    QUICKSTART_COMPOSE="$repo_root/deploy/quickstart/docker-compose.yml"
    # shellcheck disable=SC2034
    DOCKER_SOCKET_PROXY_SCRIPT="$repo_root/scripts/docker-socket-proxy.sh"
    # shellcheck disable=SC2034
    DHCP_PROBE_SCRIPT="$repo_root/services/ui/dhcp-probe.sh"
    # shellcheck disable=SC2034
    SHARED_SECRET_BOOTSTRAP_SCRIPT="$repo_root/scripts/lib/shared-secret-bootstrap.sh"
}
