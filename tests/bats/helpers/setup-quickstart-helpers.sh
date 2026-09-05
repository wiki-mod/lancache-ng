#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Bats helper that loads setup.sh's install_deploy_prod_compose_assets()
# without executing setup.sh's install/update entrypoint. Extracts the real
# function by name so tests exercise production logic rather than a
# test-only copy.

load_setup_quickstart_helpers() {
    local repo_root="$1" helper_file="$2"

    # Extract only install_deploy_prod_compose_assets from setup.sh's full
    # source tree, using the same state-machine technique as
    # setup-dhcp-helpers.sh: look for the function's declaration line, then
    # copy every line up to the closing brace on its own line. This avoids
    # sourcing the entire setup.sh (which would run install/update logic and
    # fail on test runners), while still testing the real production
    # function, not a copy.
    awk '
        !capture && /^install_deploy_prod_compose_assets\(\) \{/ { capture = 1; print; next }
        capture {
            print
            if ($0 == "}") { capture = 0 }
        }
    ' "$repo_root/setup.sh" > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"

    # install_deploy_prod_compose_assets() reads these globals (normally set
    # once near the top of setup.sh from $SCRIPT_DIR). Point them at the
    # real repo files so tests exercise the actual shipped assets. shellcheck
    # can't see the read inside the separately-sourced $helper_file, so it
    # flags these as unused (SC2034) even though install_deploy_prod_compose_assets
    # reads both at runtime. DHCP_PROBE_SCRIPT is deliberately not set here
    # any more (issue #1288 retired dhcp-probe.sh and the global along with
    # it -- see setup.sh's own comment where that variable used to be
    # declared). SCRIPT_DIR is also new here (Issue #1095): the function now
    # copies config/prod/*.env, cdn-domains.txt, and netdata-web_log.conf
    # from $SCRIPT_DIR too, not just the three globals below.
    # shellcheck disable=SC2034
    SCRIPT_DIR="$repo_root"
    # shellcheck disable=SC2034
    DEPLOY_PROD_COMPOSE="$repo_root/deploy/prod/docker-compose.yml"
    # shellcheck disable=SC2034
    DOCKER_SOCKET_PROXY_SCRIPT="$repo_root/scripts/untracked/docker-socket-proxy.sh"
    # shellcheck disable=SC2034
    SHARED_SECRET_BOOTSTRAP_SCRIPT="$repo_root/scripts/lib/shared-secret-bootstrap.sh"
}
