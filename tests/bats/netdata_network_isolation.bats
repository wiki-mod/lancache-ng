#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Drift guard for Netdata network isolation in the real deployment profiles.
# Netdata's unauthenticated HTTP API is scoped to a dedicated `netdata-net`
# bridge shared only with the Admin UI among bridge-networked services.
# Host-networked DHCP services are a deliberate boundary of that mechanism:
# `network_mode: host` bypasses Compose bridge membership entirely, so their
# route to Docker bridge addresses cannot be removed by omitting netdata-net.
# These checks keep both the isolation and that explicit limitation visible.
#
# This is a structural text scan of the real
# deploy/{prod,quickstart}/docker-compose.yml files (not a fixture).
# `docker compose config` remains a separate validation layer because these
# deployment files need populated environment values to resolve fully.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    compose_files=(
        "$repo_root/deploy/prod/docker-compose.yml"
        "$repo_root/deploy/quickstart/docker-compose.yml"
    )
}

# The helper stops at the next top-level service so network declarations from
# neighboring services cannot accidentally satisfy the target assertion.
extract_service_block() {
    local file="$1" service="$2"
    awk -v svc="  ${service}:" '
        $0 == svc { capture = 1; print; next }
        capture && /^[A-Za-z]/ { exit }
        capture && /^  [A-Za-z0-9_-]+:$/ { exit }
        capture { print }
    ' "$file"
}

# Isolation requires an explicit dedicated network in each real deployment;
# an undeclared name would make the service-level membership invalid.
@test "both deploy files declare a dedicated netdata-net top-level network" {
    for f in "${compose_files[@]}"; do
        grep -qE '^  netdata-net:' "$f" || {
            echo "missing top-level 'netdata-net:' network entry in $f" >&2
            return 1
        }
    done
}

# Netdata must not regain implicit or explicit membership in the application
# bridge, because that would expose its unauthenticated API to every sibling
# container on that bridge.
@test "netdata's own service block is scoped to netdata-net, not the shared default network" {
    for f in "${compose_files[@]}"; do
        block="$(extract_service_block "$f" netdata)"
        [ -n "$block" ]
        [[ "$block" == *"networks:"* ]] || {
            echo "netdata service block in $f has no networks: key at all" >&2
            return 1
        }
        [[ "$block" == *"netdata-net"* ]] || {
            echo "netdata service block in $f does not list netdata-net" >&2
            return 1
        }
        # Docker Compose accepts network membership in either list form or
        # map form, so both representations must be rejected here.
        if grep -qE '^      (- default$|default:)' <<< "$block"; then
            echo "netdata service block in $f still lists the shared 'default' network (list or map form) -- isolation regressed" >&2
            return 1
        fi
    done
}

# The UI is the bridge-networked consumer of NETDATA_URL, so removing this
# membership would turn isolation into an availability regression.
@test "the Admin UI's service block joins netdata-net (the only bridge-networked caller of NETDATA_URL)" {
    for f in "${compose_files[@]}"; do
        block="$(extract_service_block "$f" ui)"
        [ -n "$block" ]
        [[ "$block" == *"netdata-net"* ]] || {
            echo "ui service block in $f does not list netdata-net -- it would lose access to NETDATA_URL" >&2
            return 1
        }
    done
}

# The pinned Netdata image has no active NATS go.d job in this stack, and its
# stock NATS job targets loopback rather than the Compose DNS name. Giving NATS
# netdata-net membership would therefore only widen access to Netdata's API.
@test "nats does not join netdata-net because no active collector route requires it" {
    for f in "${compose_files[@]}"; do
        block="$(extract_service_block "$f" nats)"
        [ -n "$block" ]
        # Match YAML membership shapes rather than a bare substring because
        # explanatory comments may legitimately contain the network name.
        if grep -qE '^      (- netdata-net$|netdata-net:)' <<< "$block"; then
            echo "nats service block in $f lists netdata-net -- this unnecessarily widens Netdata API reachability" >&2
            return 1
        fi
    done
}

# Host networking shares the host routing table and is not constrained by
# Compose bridge membership. Keep this topology explicit so a future change
# cannot silently turn a documented isolation limitation into a false claim.
@test "host-network DHCP services remain an explicit boundary of Compose Netdata isolation" {
    local service
    for f in "${compose_files[@]}"; do
        for service in dhcp dhcp-proxy dhcp-probe; do
            block="$(extract_service_block "$f" "$service")"
            [ -n "$block" ] || {
                echo "$service service block is missing from $f" >&2
                return 1
            }
            [[ "$block" == *"network_mode: host"* ]] || {
                echo "$service in $f no longer uses network_mode: host; update the Netdata isolation boundary and its documentation together" >&2
                return 1
            }
            if grep -qE '^      (- netdata-net$|netdata-net:)' <<< "$block"; then
                echo "$service in $f declares netdata-net despite using host networking; Compose network membership cannot provide isolation in this mode" >&2
                return 1
            fi
        done
    done
}

# Compose accepts both list and map syntax, so the guard itself needs a
# negative fixture proving map-form default membership cannot bypass it.
@test "the default-network rejection catches map-form membership, not only list form" {
    local fixture; fixture="$(mktemp)"
    cat > "$fixture" <<'EOF'
  netdata:
    container_name: lancache-netdata
    networks:
      default: {}
      netdata-net: {}
EOF

    block="$(extract_service_block "$fixture" netdata)"
    [ -n "$block" ]
    if ! grep -qE '^      (- default$|default:)' <<< "$block"; then
        echo "map-form 'default: {}' membership was not detected as a network-isolation regression" >&2
        rm -f "$fixture"
        return 1
    fi

    rm -f "$fixture"
}
