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

@test "fresh pinned release install carries derived VERSION tag into image tag resolution" {
    release_dir="$BATS_TEST_TMPDIR/release-archive"
    missing_env="$BATS_TEST_TMPDIR/missing.env"
    mkdir -p "$release_dir"
    printf '%s\n' '0.2.0' > "$release_dir/VERSION"

    SCRIPT_DIR="$release_dir"
    export SCRIPT_DIR
    unset LANCACHE_IMAGE_CHANNEL LANCACHE_IMAGE_TAG

    channel=$(resolve_lancache_image_channel "$missing_env")

    run env SCRIPT_DIR="$release_dir" LANCACHE_IMAGE_CHANNEL="$channel" LANCACHE_IMAGE_TAG= \
        bash -c '. "$1"; resolve_lancache_image_tag "$2"' _ "$helper_file" "$missing_env"

    [ "$status" -eq 0 ]
    [ "$channel" = "pinned" ]
    [ "$output" = "v0.2.0" ]
}

@test "git dubious-ownership rejection does not silently fall back to a stale VERSION tag" {
    # Regression test for #595: a directory owned by a different user/UID
    # than the current process makes git's CVE-2022-24765 "dubious
    # ownership" check reject `rev-parse --is-inside-work-tree` with a
    # non-zero exit -- exactly the same exit code as "there is no .git here
    # at all". derive_release_archive_image_tag must not conflate the two:
    # a real .git checkout that git merely refuses (for ownership reasons)
    # must still resolve its real tag, not silently fall back to whatever
    # stale/unpublished version happens to be in the VERSION file.
    repo_dir="$BATS_TEST_TMPDIR/dubious-ownership-repo"
    mkdir -p "$repo_dir"
    : > "$repo_dir/.git"
    # A VERSION file deliberately present and deliberately wrong: if the fix
    # regresses back to the old behavior, this is the value it would wrongly
    # resolve to instead of the real "v2.0.0" tag below.
    printf '%s\n' '1.0.1' > "$repo_dir/VERSION"

    SCRIPT_DIR="$repo_dir"
    export SCRIPT_DIR

    # Stub out `git` to reproduce real git's behavior under dubious
    # ownership: reject a plain invocation, but succeed once the caller
    # scopes trust to this exact path via a per-invocation
    # `-c safe.directory=...` (never a global/persistent config change).
    git() {
        local arg saw_safe_dir=0
        for arg in "$@"; do
            [[ "$arg" == "safe.directory=$repo_dir" ]] && saw_safe_dir=1
        done
        if [[ "$saw_safe_dir" -eq 0 ]]; then
            printf "fatal: detected dubious ownership in repository at '%s'\n" "$repo_dir" >&2
            return 128
        fi
        case "$*" in
            *"rev-parse --is-inside-work-tree"*) return 0 ;;
            *"describe --tags --exact-match"*) printf 'v2.0.0\n'; return 0 ;;
        esac
        return 1
    }

    tag=$(derive_release_archive_image_tag)
    status=$?

    [ "$status" -eq 0 ]
    [ "$tag" = "v2.0.0" ]
}

@test "git dubious-ownership rejection on a branch with no exact tag still does not fall back to VERSION" {
    # This is the precise scenario from the #595 bug report: a checkout on a
    # branch (not sitting exactly on a release tag) whose directory has
    # dubious ownership. Before the fix, the dubious-ownership rejection of
    # `rev-parse --is-inside-work-tree` was indistinguishable from "no .git
    # at all", so this fell through to the VERSION file and produced a
    # confusing `v1.0.1` tag/404 instead of the caller correctly seeing "no
    # tag available" and defaulting to the latest/edge channel. Once trusted
    # via the scoped override, git itself has a real, correct answer here
    # ("no tag matches HEAD exactly") -- the function must surface that
    # (return 1, no output) rather than reach for the unrelated VERSION file.
    repo_dir="$BATS_TEST_TMPDIR/dubious-ownership-branch-repo"
    mkdir -p "$repo_dir"
    : > "$repo_dir/.git"
    printf '%s\n' '1.0.1' > "$repo_dir/VERSION"

    SCRIPT_DIR="$repo_dir"
    export SCRIPT_DIR

    git() {
        local arg saw_safe_dir=0
        for arg in "$@"; do
            [[ "$arg" == "safe.directory=$repo_dir" ]] && saw_safe_dir=1
        done
        if [[ "$saw_safe_dir" -eq 0 ]]; then
            printf "fatal: detected dubious ownership in repository at '%s'\n" "$repo_dir" >&2
            return 128
        fi
        case "$*" in
            *"rev-parse --is-inside-work-tree"*) return 0 ;;
            # Real git's behavior on a branch with no tag exactly on HEAD:
            # non-zero exit, nothing on stdout.
            *"describe --tags --exact-match"*) return 128 ;;
        esac
        return 1
    }

    # A non-zero return here is the expected, correct outcome (see comment
    # above) -- guard the assignment as an `if` condition so bats' own
    # `set -e` doesn't abort the test on that expected failure.
    if tag=$(derive_release_archive_image_tag); then
        status=0
    else
        status=$?
    fi

    [ "$status" -eq 1 ]
    [ -z "$tag" ]
    [ "$tag" != "v1.0.1" ]
}

@test "proxy security migration restores lazy default for legacy strict without allowlist" {
    printf '%s\n' \
        'PROXY_SECURITY_MODE=strict' \
        'PROXY_ALLOWED_CLIENT_CIDRS=' > "$env_file"

    run migrate_proxy_security_mode_for_update "$env_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c '^PROXY_SECURITY_MODE=' "$env_file")" -eq 1 ]
    grep -qx 'PROXY_SECURITY_MODE=lazy' "$env_file"
}

@test "proxy security migration preserves explicit strict mode with allowlist" {
    printf '%s\n' \
        'PROXY_SECURITY_MODE=strict' \
        'PROXY_ALLOWED_CLIENT_CIDRS=192.168.1.0/24' > "$env_file"

    run migrate_proxy_security_mode_for_update "$env_file"

    [ "$status" -eq 0 ]
    [ "$(grep -c '^PROXY_SECURITY_MODE=' "$env_file")" -eq 1 ]
    grep -qx 'PROXY_SECURITY_MODE=strict' "$env_file"
    grep -qx 'PROXY_ALLOWED_CLIENT_CIDRS=192.168.1.0/24' "$env_file"
}
