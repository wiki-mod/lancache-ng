#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for setup.sh .env migration helpers.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    env_file="$BATS_TEST_TMPDIR/.env"
    helper_file="$BATS_TEST_TMPDIR/setup-env-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-env-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-env-helpers.sh"
    load_setup_env_helpers "$repo_root" "$helper_file"
}

@test "migrated assignment preserves an existing empty optional target" {
    printf '%s\n' \
        'IP_STANDARD=192.0.2.10' \
        'UI_BIND_IP=' > "$env_file"

    run append_env_migrated_assignment_if_missing UI_BIND_IP IP_STANDARD 192.0.2.10 "$env_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c '^UI_BIND_IP=' "$env_file")" -eq 1 ]
    grep -qx 'UI_BIND_IP=' "$env_file"
}

@test "migrated assignment copies existing Compose assignment syntax" {
    printf '%s\n' \
        'CACHE_DIR="/opt/lancache cache" # fast disk' > "$env_file"

    run append_env_migrated_assignment_if_missing CACHE_DIR_STANDARD CACHE_DIR /opt/lancache-ng/cache "$env_file"

    [ "$status" -eq 0 ]
    grep -qx 'CACHE_DIR_STANDARD="/opt/lancache cache" # fast disk' "$env_file"
}

@test "migrated assignment keeps an existing non-empty target" {
    printf '%s\n' \
        'CACHE_DIR=/legacy/cache' \
        'CACHE_DIR_STANDARD=/custom/cache' > "$env_file"

    run append_env_migrated_assignment_if_missing CACHE_DIR_STANDARD CACHE_DIR /opt/lancache-ng/cache "$env_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c '^CACHE_DIR_STANDARD=' "$env_file")" -eq 1 ]
    grep -qx 'CACHE_DIR_STANDARD=/custom/cache' "$env_file"
}

@test "migrated assignment uses fallback when source is empty" {
    printf '%s\n' 'CACHE_DIR=' > "$env_file"

    run append_env_migrated_assignment_if_missing CACHE_DIR_STANDARD CACHE_DIR /opt/lancache-ng/cache "$env_file"

    [ "$status" -eq 0 ]
    grep -qx 'CACHE_DIR_STANDARD=/opt/lancache-ng/cache' "$env_file"
}
