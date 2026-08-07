#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Drift guard for #849 bug-hunt finding observability.md#20: netdata's own
# HTTP API (port 19999) is never published to the host in any real
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
        [[ "$block" != *$'\n      - default'* ]] || {
            echo "netdata service block in $f still lists the shared 'default' network -- isolation regressed" >&2
            return 1
        }
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
