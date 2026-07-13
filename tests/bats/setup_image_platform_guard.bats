#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for setup.sh's prebuilt-image platform guards (#665):
# host_image_platform, assert_prebuilt_image_platform_supported (host
# architecture only), and assert_resolved_image_tag_platform_supported (the
# specific resolved tag/channel's actually-published platforms). Without the
# second guard, a host pinned to a pre-arm64 tag or a channel missing an
# arm64 leg would pass the host-only check and only fail deep inside
# `docker compose pull`, after setup.sh had already written install state.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-platform-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-platform-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-platform-helpers.sh"
    load_setup_platform_helpers "$repo_root" "$helper_file"

    # Fake `uname -m`: assert_resolved_image_tag_platform_supported and
    # assert_prebuilt_image_platform_supported both call `uname -m` directly
    # (it is not a function parameter), so the only way to exercise every
    # architecture branch is to shadow the builtin with a controllable stub.
    uname() {
        if [[ "$1" = "-m" ]]; then
            printf '%s\n' "${FAKE_ARCH:-x86_64}"
            return 0
        fi
        command uname "$@"
    }

    # Fake `docker`: simulates buildx presence/absence and
    # `imagetools inspect` output without touching a real registry. Controlled
    # per-test via FAKE_NO_BUILDX / FAKE_INSPECT_FAIL / FAKE_SINGLE_PLATFORM /
    # FAKE_MULTI_PLATFORMS.
    docker() {
        if [[ "$1" = "buildx" && "$2" = "version" ]]; then
            [[ "${FAKE_NO_BUILDX:-0}" = "1" ]] && return 1
            return 0
        fi
        if [[ "$1" = "buildx" && "$2" = "imagetools" && "$3" = "inspect" ]]; then
            shift 3
            if [[ "${FAKE_INSPECT_FAIL:-0}" = "1" ]]; then
                printf 'fake registry unreachable\n' >&2
                return 1
            fi
            if [[ "$*" == *--format* ]]; then
                printf '%s\n' "${FAKE_SINGLE_PLATFORM:-<no value>/<no value>}"
                return 0
            fi
            local platform
            for platform in ${FAKE_MULTI_PLATFORMS//,/ }; do
                printf 'Platform:  %s\n' "$platform"
            done
            return 0
        fi
        command docker "$@"
    }
}

# ─── host_image_platform ───

@test "host_image_platform maps recognized architectures" {
    run host_image_platform x86_64
    [ "$status" -eq 0 ]
    [ "$output" = "linux/amd64" ]

    run host_image_platform amd64
    [ "$status" -eq 0 ]
    [ "$output" = "linux/amd64" ]

    run host_image_platform aarch64
    [ "$status" -eq 0 ]
    [ "$output" = "linux/arm64" ]

    run host_image_platform arm64
    [ "$status" -eq 0 ]
    [ "$output" = "linux/arm64" ]
}

@test "host_image_platform rejects an unrecognized architecture" {
    run host_image_platform riscv64
    [ "$status" -ne 0 ]
}

# ─── assert_prebuilt_image_platform_supported (host architecture only) ───

@test "assert_prebuilt_image_platform_supported accepts amd64 and arm64 hosts" {
    FAKE_ARCH=x86_64
    run assert_prebuilt_image_platform_supported
    [ "$status" -eq 0 ]

    FAKE_ARCH=aarch64
    run assert_prebuilt_image_platform_supported
    [ "$status" -eq 0 ]
}

@test "assert_prebuilt_image_platform_supported dies on an unsupported host" {
    FAKE_ARCH=riscv64
    run assert_prebuilt_image_platform_supported
    [ "$status" -ne 0 ]
    [[ "$output" == *"linux/amd64 and linux/arm64"* ]]
}

# ─── assert_resolved_image_tag_platform_supported (the resolved tag itself) ───

# This is the core #665 regression case: a host whose architecture setup.sh
# recognizes in general, paired with a tag that does not actually publish a
# manifest for that architecture (e.g. an amd64-only pre-#395 tag on an arm64
# host). Must fail closed, matching AG-VAL-002 (treat registry-unreachable /
# missing-platform as a hard failure, never silently proceed).
@test "assert_resolved_image_tag_platform_supported dies when the resolved tag lacks this host's platform" {
    FAKE_ARCH=aarch64
    FAKE_SINGLE_PLATFORM="linux/amd64"

    run assert_resolved_image_tag_platform_supported ghcr.io wiki-mod/lancache-ng sha-abc1234
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not publish a linux/arm64 image"* ]]
}

@test "assert_resolved_image_tag_platform_supported succeeds for a single-platform manifest matching the host" {
    FAKE_ARCH=x86_64
    FAKE_SINGLE_PLATFORM="linux/amd64"

    run assert_resolved_image_tag_platform_supported ghcr.io wiki-mod/lancache-ng sha-abc1234
    [ "$status" -eq 0 ]
}

# Multi-platform index manifests (what release/stack-images.yml actually
# publishes today) report no single .Image field, so the guard must fall back
# to parsing the plain "Platform:" lines -- this is the same fallback
# scripts/require-image-platforms.sh uses.
@test "assert_resolved_image_tag_platform_supported succeeds via the multi-platform index fallback" {
    FAKE_ARCH=aarch64
    FAKE_SINGLE_PLATFORM="<no value>/<no value>"
    FAKE_MULTI_PLATFORMS="linux/amd64,linux/arm64"

    run assert_resolved_image_tag_platform_supported ghcr.io wiki-mod/lancache-ng latest
    [ "$status" -eq 0 ]
}

@test "assert_resolved_image_tag_platform_supported dies on an unrecognized host architecture" {
    FAKE_ARCH=riscv64

    run assert_resolved_image_tag_platform_supported ghcr.io wiki-mod/lancache-ng latest
    [ "$status" -ne 0 ]
    [[ "$output" == *"linux/amd64 and linux/arm64"* ]]
}

@test "assert_resolved_image_tag_platform_supported dies when docker buildx is unavailable" {
    FAKE_ARCH=x86_64
    FAKE_NO_BUILDX=1

    run assert_resolved_image_tag_platform_supported ghcr.io wiki-mod/lancache-ng latest
    [ "$status" -ne 0 ]
    [[ "$output" == *"docker buildx is required"* ]]
}

# Registry/network unavailability must be a hard failure (AG-VAL-002), not a
# silently skipped check -- an operator who cannot reach GHCR must be told to
# fix that, not have setup.sh proceed as if the tag were fine.
@test "assert_resolved_image_tag_platform_supported dies when the registry is unreachable" {
    FAKE_ARCH=x86_64
    FAKE_INSPECT_FAIL=1

    run assert_resolved_image_tag_platform_supported ghcr.io wiki-mod/lancache-ng latest
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to inspect"* ]]
}

@test "assert_resolved_image_tag_platform_supported dies when docker is not installed" {
    FAKE_ARCH=x86_64
    unset -f docker
    # Empty PATH (rather than a real-but-empty directory) is enough to make
    # `command -v docker` fail without needing any external command to set it
    # up -- important here because this test is deliberately simulating "no
    # usable PATH", so it must not depend on external commands itself.
    # Set as a temporary assignment on the `run` line (not a standalone
    # statement) so it only applies to this one command: a bare `PATH=""`
    # persists in this test's own shell afterward and breaks bats-core's own
    # per-test cleanup (which needs a working PATH to find `rm`), causing the
    # *next* test to fail with an unrelated "rm: No such file or directory".
    PATH="" run assert_resolved_image_tag_platform_supported ghcr.io wiki-mod/lancache-ng latest
    [ "$status" -ne 0 ]
    [[ "$output" == *"docker is required"* ]]
}
