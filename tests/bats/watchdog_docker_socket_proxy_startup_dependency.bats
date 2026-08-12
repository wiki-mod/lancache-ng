#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Drift guard for the Docker API proxy startup contract. Both watchdog and
# the Admin UI depend on docker-socket-proxy only via `condition:
# service_started`, not `service_healthy` -- both must stay alive and
# available while Docker API access is degraded, not disappear entirely if
# docker-socket-proxy is briefly slow to become healthy at startup.
#
# This was originally `service_healthy` for watchdog specifically (a real
# design mistake corrected 2026-08-12, PR #1489, after being live-verified
# against a real CI run): `service_healthy` means Compose refuses to CREATE
# the watchdog container at all if docker-socket-proxy fails its own
# startup healthcheck -- total monitoring silence for exactly the failure
# mode watchdog exists to surface. watchdog.sh's own get_health() and
# probe_docker_socket_proxy() already treat an unreachable Docker API
# channel as a normal, non-fatal, self-correcting failure state (an
# "unreachable" reading that clears itself once the proxy becomes
# reachable, with RESTART_AFTER=3 consecutive ~CHECK_INTERVAL-second cycles
# meaning one transient unreachable reading at startup is nowhere near
# enough to trigger a false restart) -- so there was never a real need for
# the harder Compose-level gate in the first place. Covers all three
# compose files that define both services: prod, quickstart, and the
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

# A `service_started`-only dependency is useful only if the calling code
# itself tolerates a not-yet-healthy dependency, so verify docker-socket-proxy
# actually carries a real healthcheck (proving readiness is a real, checkable
# state, even though neither caller below hard-gates on it at startup).
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

# watchdog's own dashboard and alert-only monitoring must remain startable
# while Docker API access is degraded -- see this file's own header comment
# for the real incident that established this as a requirement, not merely
# a nice-to-have.
@test "watchdog waits only for docker-socket-proxy to be started, not healthy" {
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
        [[ "$after_dep" == *"condition: service_started"* ]] || {
            echo "watchdog's docker-socket-proxy dependency in $f is not condition: service_started (got: '$after_dep')" >&2
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
