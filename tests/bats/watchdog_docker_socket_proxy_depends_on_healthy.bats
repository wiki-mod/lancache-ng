#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Drift guard for the Docker API proxy startup contract. The watchdog cannot
# perform health reads or restart calls until HAProxy is genuinely forwarding
# Docker API requests, so it waits for docker-socket-proxy's real healthcheck.
# The Admin UI has a different availability requirement: its HTTP server and
# recovery/dashboard surface must remain startable while Docker API access is
# degraded, so it waits only for the proxy container to be started. Covers all
# three compose files that define both services: prod, quickstart, and the
# full-setup validation harness.
#
# This is a structural text scan of the real compose files, using the same
# service-boundary extraction approach as the other compose drift guards.
# `docker compose config` remains a separate validation layer because these
# deployment files require populated environment values to resolve fully.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    compose_files=(
        "$repo_root/deploy/prod/docker-compose.yml"
        "$repo_root/deploy/quickstart/docker-compose.yml"
        "$repo_root/deploy/full-setup/docker-compose.yml"
    )
    # shellcheck source=tests/bats/helpers/compose-service-block-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/compose-service-block-helpers.sh"
}

# A health-gated watchdog dependency is useful only if the dependency itself
# exposes a real healthcheck, so verify that precondition explicitly.
@test "docker-socket-proxy defines a healthcheck in every compose file" {
    for f in "${compose_files[@]}"; do
        block="$(extract_service_block "$f" docker-socket-proxy)"
        [ -n "$block" ]
        [[ "$block" == *"healthcheck:"* ]] || {
            echo "docker-socket-proxy service block in $f has no healthcheck" >&2
            return 1
        }
    done
}

# The watchdog's Docker API operations are its core job, so startup must wait
# until the proxy is genuinely healthy instead of merely having been created.
@test "watchdog waits for docker-socket-proxy to be healthy" {
    for f in "${compose_files[@]}"; do
        block="$(extract_service_block "$f" watchdog)"
        [ -n "$block" ]
        [[ "$block" == *"docker-socket-proxy:"* ]] || {
            echo "watchdog service block in $f has no map-form docker-socket-proxy dependency entry" >&2
            return 1
        }
        # Read the dependency's immediately following line so an unrelated
        # condition elsewhere in the service block cannot produce a false pass.
        after_dep="$(awk '/docker-socket-proxy:$/{getline; print; exit}' <<< "$block")"
        [[ "$after_dep" == *"condition: service_healthy"* ]] || {
            echo "watchdog's docker-socket-proxy dependency in $f is not condition: service_healthy (got: '$after_dep')" >&2
            return 1
        }
    done
}

# The UI must still come up when Docker API access is broken so operators retain
# its dashboard and recovery surface; only container creation is a prerequisite.
@test "Admin UI waits only for docker-socket-proxy to be started" {
    for f in "${compose_files[@]}"; do
        block="$(extract_service_block "$f" ui)"
        [ -n "$block" ]
        [[ "$block" == *"docker-socket-proxy:"* ]] || {
            echo "ui service block in $f has no map-form docker-socket-proxy dependency entry" >&2
            return 1
        }
        after_dep="$(awk '/docker-socket-proxy:$/{getline; print; exit}' <<< "$block")"
        [[ "$after_dep" == *"condition: service_started"* ]] || {
            echo "ui's docker-socket-proxy dependency in $f is not condition: service_started (got: '$after_dep')" >&2
            return 1
        }
    done
}
