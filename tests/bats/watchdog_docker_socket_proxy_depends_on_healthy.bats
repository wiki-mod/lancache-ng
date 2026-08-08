#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Drift guard for #849 bug-hunt finding watchdog.md#14: the `watchdog` and
# `ui` services' `depends_on` for `docker-socket-proxy` used the plain list
# form, which only waits for that container to *start*, not for HAProxy
# inside it to actually be accepting connections on :2375 -- even though
# docker-socket-proxy has carried a real HTTP healthcheck since #1169 (see
# its own service block in each compose file). Covers all three real
# compose files that define a `watchdog` service (prod, quickstart, and
# full-setup's CI validation harness -- the finding's own text explicitly
# scopes to "all three real compose files", and full-setup's
# docker-socket-proxy carries the identical healthcheck, so leaving it on
# the old ordering-only form would just be the same gap in a third file).
# This is a structural text scan of the real compose files, same extraction
# approach as tests/bats/netdata_network_isolation.bats and
# scripts/check-compose-healthchecks.sh (docker compose config needs a
# populated .env/Docker to run at all).

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    compose_files=(
        "$repo_root/deploy/prod/docker-compose.yml"
        "$repo_root/deploy/quickstart/docker-compose.yml"
        "$repo_root/deploy/full-setup/docker-compose.yml"
    )
}

# extract_service_block <compose-file> <service-name>
# See tests/bats/netdata_network_isolation.bats's identical helper for the
# boundary-rule rationale (matches scripts/check-compose-healthchecks.sh's
# own service-block scanning approach).
extract_service_block() {
    local file="$1" service="$2"
    awk -v svc="  ${service}:" '
        $0 == svc { capture = 1; print; next }
        capture && /^[A-Za-z]/ { exit }
        capture && /^  [A-Za-z0-9_-]+:$/ { exit }
        capture { print }
    ' "$file"
}

# docker-socket-proxy itself must actually carry a healthcheck in every file
# -- this is the precondition that makes `condition: service_healthy`
# meaningful at all rather than a dependency that can never start; verified
# explicitly rather than assumed, since the other tests in this file only
# check that watchdog/ui reference `condition: service_healthy` and would
# stay green even if that condition could never actually be satisfied.
@test "docker-socket-proxy's own service block defines a healthcheck in every compose file" {
    for f in "${compose_files[@]}"; do
        block="$(extract_service_block "$f" docker-socket-proxy)"
        [ -n "$block" ]
        [[ "$block" == *"healthcheck:"* ]] || {
            echo "docker-socket-proxy service block in $f has no healthcheck: -- condition: service_healthy would never be satisfiable" >&2
            return 1
        }
    done
}

@test "watchdog waits for docker-socket-proxy to be healthy, not merely started" {
    for f in "${compose_files[@]}"; do
        block="$(extract_service_block "$f" watchdog)"
        [ -n "$block" ]
        [[ "$block" == *"docker-socket-proxy:"* ]] || {
            echo "watchdog service block in $f has no map-form docker-socket-proxy dependency entry" >&2
            return 1
        }
        # Assert the condition sits on the line immediately after the
        # docker-socket-proxy dependency key, not merely present somewhere
        # in the block -- proves it is that dependency's own condition, not
        # an unrelated healthcheck's condition line coincidentally present.
        after_dep="$(printf '%s\n' "$block" | awk '/docker-socket-proxy:$/{getline; print; exit}')"
        [[ "$after_dep" == *"condition: service_healthy"* ]] || {
            echo "watchdog's docker-socket-proxy dependency in $f is not condition: service_healthy (got: '$after_dep')" >&2
            return 1
        }
    done
}

@test "the Admin UI waits for docker-socket-proxy to be healthy, not merely started" {
    for f in "${compose_files[@]}"; do
        block="$(extract_service_block "$f" ui)"
        [ -n "$block" ]
        [[ "$block" == *"docker-socket-proxy:"* ]] || {
            echo "ui service block in $f has no map-form docker-socket-proxy dependency entry" >&2
            return 1
        }
        after_dep="$(printf '%s\n' "$block" | awk '/docker-socket-proxy:$/{getline; print; exit}')"
        [[ "$after_dep" == *"condition: service_healthy"* ]] || {
            echo "ui's docker-socket-proxy dependency in $f is not condition: service_healthy (got: '$after_dep')" >&2
            return 1
        }
    done
}
