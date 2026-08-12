#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# extract_service_block <compose-file> <service-name>: prints the exact
# lines of one top-level Compose service's block (from its own "  <name>:"
# line up to, but excluding, the next 2-space-indented service key or
# top-level key). Shared by tests/bats/netdata_network_isolation.bats and
# tests/bats/watchdog_docker_socket_proxy_startup_dependency.bats
# (Rule-Ref: AG-CODE-011) -- both do the same structural text-scan of the
# real deploy/*/docker-compose.yml files that scripts/check-compose-
# healthchecks.sh's own service-block scanning already established this
# boundary rule for; extracted here once so a fix to the extraction logic
# (e.g. the map-form vs list-form network-membership edge case these
# callers' own tests exercise) reaches every caller instead of needing to be
# manually ported between them.
extract_service_block() {
    local file="$1" service="$2"
    awk -v svc="  ${service}:" '
        $0 == svc { capture = 1; print; next }
        capture && /^[A-Za-z]/ { exit }
        capture && /^  [A-Za-z0-9_-]+:$/ { exit }
        capture { print }
    ' "$file"
}
