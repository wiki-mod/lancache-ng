#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: regression suite for scripts/ci/ci.sh (CI 2.0 engine).
# Why: §66 requires one centralized suite covering every domain.
# From: Issue #1683 | docs/ci-2.0-architecture.md

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/ci/ci.sh
    source "$repo_root/scripts/ci/ci.sh"
}

# ============================================================
# CORE INVARIANTS
# ============================================================

@test "core: full git SHA regex accepts a real 40-char SHA" {
    [[ "569022c2fba37618c6bb41aa4927753af0f762d3" =~ $CI_FULL_GIT_SHA_REGEX ]]
}

@test "core: full git SHA regex rejects an abbreviated SHA" {
    ! [[ "569022c" =~ $CI_FULL_GIT_SHA_REGEX ]]
}

@test "core: full OCI digest regex accepts a real digest" {
    local digest="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    [[ "$digest" =~ $CI_FULL_OCI_DIGEST_REGEX ]]
}

@test "core: full OCI digest regex rejects an abbreviated digest" {
    ! [[ "sha-deadbeef" =~ $CI_FULL_OCI_DIGEST_REGEX ]]
}

# ============================================================
# SERVICE INVENTORY
# ============================================================

@test "service inventory: contains exactly the 11 expected services" {
    local expected=(proxy dns watchdog dhcp dhcp-proxy ntp syslog ui netdata build-tools utilities)
    [ "${#CI_SERVICES[@]}" -eq "${#expected[@]}" ]
    local svc
    for svc in "${expected[@]}"; do
        ci_service_exists "$svc"
    done
}

@test "service inventory: netdata is included (maintainer decision)" {
    ci_service_exists netdata
}

@test "service inventory: every service has a non-empty context" {
    local svc
    for svc in "${CI_SERVICES[@]}"; do
        [ -n "$(ci_service_context "$svc")" ]
    done
}

@test "service inventory: every service context directory exists" {
    local svc ctx
    for svc in "${CI_SERVICES[@]}"; do
        ctx="$(ci_service_context "$svc")"
        [ -d "$repo_root/$ctx" ]
    done
}

@test "service inventory: every service has amd64 and arm64 platforms" {
    local svc platforms
    for svc in "${CI_SERVICES[@]}"; do
        platforms="$(ci_service_platforms "$svc")"
        [[ "$platforms" == *"linux/amd64"* ]]
        [[ "$platforms" == *"linux/arm64"* ]]
    done
}

@test "service inventory: every service has a runner class of heavy or light" {
    local svc class
    for svc in "${CI_SERVICES[@]}"; do
        class="$(ci_service_runner_class "$svc")"
        [[ "$class" == "heavy" || "$class" == "light" ]]
    done
}

@test "service inventory: every service has a known compiler class" {
    local svc class
    for svc in "${CI_SERVICES[@]}"; do
        class="$(ci_service_compiler_class "$svc")"
        [[ "$class" == "none" || "$class" == "rust" || "$class" == "c" ]]
    done
}

@test "service inventory: proxy declares dns as an external context" {
    local ctx
    ctx="$(ci_service_external_contexts proxy)"
    [[ "$ctx" == "dns=services/dns" ]]
}

@test "service inventory: dns has no external context" {
    local ctx
    ctx="$(ci_service_external_contexts dns)"
    [ -z "$ctx" ]
}

@test "service inventory: unknown service is rejected" {
    run ci_service_exists totally-not-a-service
    [ "$status" -ne 0 ]
}

@test "service inventory: ci_require_service dies on unknown service" {
    run ci_require_service totally-not-a-service
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown service"* ]]
}

@test "service inventory: ci_service_context dies on unknown service" {
    run ci_service_context totally-not-a-service
    [ "$status" -ne 0 ]
}

# ============================================================
# DISPATCH
# ============================================================

@test "dispatch: 'services' subcommand prints all 11 services" {
    run bash "$repo_root/scripts/ci/ci.sh" services
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 11 ]
}

@test "dispatch: 'version' subcommand prints a version string" {
    run bash "$repo_root/scripts/ci/ci.sh" version
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "dispatch: unknown subcommand fails" {
    run bash "$repo_root/scripts/ci/ci.sh" totally-not-a-command
    [ "$status" -ne 0 ]
}

@test "dispatch: no subcommand prints usage and fails" {
    run bash "$repo_root/scripts/ci/ci.sh"
    [ "$status" -ne 0 ]
}
