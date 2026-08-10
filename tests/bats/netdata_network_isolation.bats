#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Drift guard: netdata's own HTTP API (port 19999) is never published to
# the host in any real
# deployment, but leaving it without an explicit `networks:` entry would
# put it on the same implicit shared `default` Compose network as every
# other real service (dns, proxy, dhcp, nats, ...) -- any one of them could
# then reach netdata's full, unauthenticated API directly, not just the two
# endpoints the Admin UI's own outbound proxy allowlist restricts itself to.
# Scoping netdata to a dedicated `netdata-net` network shared only with the
# Admin UI (the sole real caller, via NETDATA_URL) closes that exposure.
# This is a structural text scan of the real
# deploy/{prod,quickstart}/docker-compose.yml files (not a fixture) --
# `docker compose config` needs a populated `.env` and Docker to run at all
# (see scripts/check-compose-healthchecks.sh's identical reasoning for why
# it also avoids that path), so this mirrors that script's own
# service-block-extraction approach instead.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    compose_files=(
        "$repo_root/deploy/prod/docker-compose.yml"
        "$repo_root/deploy/quickstart/docker-compose.yml"
    )
}

# extract_service_block <compose-file> <service-name>
# Prints the exact lines of one top-level service's block (from its own
# "  <name>:" line up to, but excluding, the next 2-space-indented service
# key or top-level key) -- same boundary rule
# scripts/check-compose-healthchecks.sh's check_file() already established
# and relies on for this repo's real compose file indentation shape.
extract_service_block() {
    local file="$1" service="$2"
    awk -v svc="  ${service}:" '
        $0 == svc { capture = 1; print; next }
        capture && /^[A-Za-z]/ { exit }
        capture && /^  [A-Za-z0-9_-]+:$/ { exit }
        capture { print }
    ' "$file"
}

@test "both deploy files declare a dedicated netdata-net top-level network" {
    for f in "${compose_files[@]}"; do
        grep -qE '^  netdata-net:' "$f" || {
            echo "missing top-level 'netdata-net:' network entry in $f" >&2
            return 1
        }
    done
}

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
        # Docker Compose accepts network membership in either list form
        # (`- default`) or map form (`default: {}`/`default:` with nested
        # keys) -- both must be rejected, or a map-form rewrite could
        # silently reconnect netdata to the shared network while this test
        # still passed.
        if grep -qE '^      (- default$|default:)' <<< "$block"; then
            echo "netdata service block in $f still lists the shared 'default' network (list or map form) -- isolation regressed" >&2
            return 1
        fi
    done
}

@test "the Admin UI's service block joins netdata-net (the only real caller of NETDATA_URL)" {
    for f in "${compose_files[@]}"; do
        block="$(extract_service_block "$f" ui)"
        [ -n "$block" ]
        [[ "$block" == *"netdata-net"* ]] || {
            echo "ui service block in $f does not list netdata-net -- it would lose access to NETDATA_URL" >&2
            return 1
        }
    done
}

@test "nats does not join netdata-net (no real collector needs it, checked against the pinned image)" {
    # Regression guard for a real incident: a prior revision of this stack
    # put `nats` on both `default` and `netdata-net`, on the premise that
    # netdata's go.d.plugin runs an active NATS collector against
    # `nats:8222` that would otherwise lose its route once netdata was
    # scoped off the shared network. That premise was checked directly
    # against the real pinned netdata image (netdata/netdata@sha256:
    # a130dbbf...) and found false: /usr/lib/netdata/conf.d/go.d/nats.conf
    # ships with every job commented out by default (no active job at all),
    # and even an operator-enabled default job targets `127.0.0.1`, never
    # the `nats` Compose DNS name, so it could never reach this container
    # over any network regardless. Putting `nats` on `netdata-net` would
    # only widen the access surface this file's other tests exist to close
    # (bridge-network membership is bidirectional), so it must stay off
    # that network.
    for f in "${compose_files[@]}"; do
        block="$(extract_service_block "$f" nats)"
        [ -n "$block" ]
        # Matches the real YAML membership shapes only (list-item or
        # map-key), not a bare substring -- this service's own block
        # carries an explanatory comment that mentions "netdata-net" in
        # prose several times (documenting exactly why it must NOT be a
        # member), which a naive substring check would misread as the
        # network entry itself.
        if grep -qE '^      (- netdata-net$|netdata-net:)' <<< "$block"; then
            echo "nats service block in $f lists netdata-net -- this is an unnecessary widening of netdata's isolated network, not a required route (checked against the real pinned netdata image, see this test's own comment)" >&2
            return 1
        fi
    done
}

@test "the default-network rejection catches map-form membership, not only list form" {
    # Regression case: Docker Compose accepts networks: as either a list
    # (- default) or a map (default: {}). A guard that only greps for the
    # list-item spelling would pass a map-form rewrite that silently
    # reconnects netdata to the shared network -- reproduced here against a
    # small throwaway fixture, not this repo's real compose files, since
    # neither real file currently uses map form and this test exists to
    # prove the guard's own regex, not the real files' current content.
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
