#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for the "stable"/"edge" operator-facing channel picker
# (#819). "stable" is a new accepted LANCACHE_IMAGE_CHANNEL value that must
# resolve through the exact same published stack:latest pointer image "latest"
# already uses -- there is no separate stack:stable GHCR tag. These tests pin
# that mapping directly (via a mocked `docker`/`tar`, since
# resolve_lancache_stack_channel_tag talks to a real registry otherwise), plus
# the plain validation/inference logic that does not need Docker at all.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-env-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-env-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-env-helpers.sh"
    load_setup_env_helpers "$repo_root" "$helper_file"

    unset LANCACHE_IMAGE_CHANNEL LANCACHE_IMAGE_TAG LANCACHE_IMAGE_REGISTRY LANCACHE_IMAGE_PREFIX
}

@test "validate_lancache_image_channel accepts stable" {
    run validate_lancache_image_channel "stable"
    [ "$status" -eq 0 ]
}

@test "validate_lancache_image_channel still accepts latest, dev, edge, pinned" {
    for channel in latest dev edge pinned; do
        run validate_lancache_image_channel "$channel"
        [ "$status" -eq 0 ]
    done
}

@test "validate_lancache_image_channel rejects an unknown channel and names stable in the error" {
    run validate_lancache_image_channel "bogus"
    [ "$status" -ne 0 ]
    [[ "$output" == *"stable"* ]]
}

@test "resolve_lancache_image_channel returns an explicit stable channel unchanged" {
    missing_env="$BATS_TEST_TMPDIR/missing.env"
    LANCACHE_IMAGE_CHANNEL="stable"
    run resolve_lancache_image_channel "$missing_env"
    [ "$status" -eq 0 ]
    [ "$output" = "stable" ]
}

@test "resolve_lancache_image_channel infers stable from a LANCACHE_IMAGE_TAG=stable convenience value" {
    missing_env="$BATS_TEST_TMPDIR/missing.env"
    LANCACHE_IMAGE_TAG="stable"
    run resolve_lancache_image_channel "$missing_env"
    [ "$status" -eq 0 ]
    [ "$output" = "stable" ]
}

@test "resolve_lancache_image_channel still defaults to latest, not stable, with nothing configured" {
    # The hardcoded fallback intentionally stays "latest" (the name that has
    # always existed); "stable" is only ever written explicitly by the new
    # interactive picker, never silently substituted as a bare default.
    missing_env="$BATS_TEST_TMPDIR/missing.env"
    run resolve_lancache_image_channel "$missing_env"
    [ "$status" -eq 0 ]
    [ "$output" = "latest" ]
}

# Mocks docker (pull/create/cp/rm) and tar so resolve_lancache_stack_channel_tag
# can run end to end without a real registry, and records which stack image
# reference it actually requested. Uses real fake-executable files on a
# prepended PATH rather than `export -f` shell-function shadowing: `run`
# invokes the target command in a genuinely separate bash process, and
# exported-function inheritance (the BASH_FUNC_*%% mechanism) is not reliably
# available in every environment (some hardened/post-Shellshock bash builds
# disable it outright) -- confirmed the hard way: export -f worked in a local
# interactive shell but silently fell through to the real system docker/tar in
# CI, since neither exists there this manifested as the pipeline reading real
# empty/error output instead of the fake stack.env content. A PATH-based fake
# executable has no such environment-inheritance dependency.
stub_stack_pointer_docker() {
    fake_bin_dir="$BATS_TEST_TMPDIR/fake-bin"
    mkdir -p "$fake_bin_dir"

    cat > "$fake_bin_dir/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
case "$1" in
    pull)
        printf '%s\n' "$2" > "$FAKE_STACK_POINTER_LOG/requested_stack_image"
        exit 0
        ;;
    create)
        printf 'fake-container-id\n'
        exit 0
        ;;
    cp)
        printf 'fake-tar-stream'
        exit 0
        ;;
    rm)
        exit 0
        ;;
esac
FAKE_DOCKER

    cat > "$fake_bin_dir/tar" <<'FAKE_TAR'
#!/usr/bin/env bash
# The real pipeline is `docker cp ... - | tar -xO | awk ...`; this fake
# ignores its real stdin/args and emits the stack.env line the awk
# extraction in resolve_lancache_stack_channel_tag expects.
printf 'LANCACHE_IMAGE_TAG=sha-abc1234\n'
FAKE_TAR

    chmod +x "$fake_bin_dir/docker" "$fake_bin_dir/tar"
    export FAKE_STACK_POINTER_LOG="$BATS_TEST_TMPDIR"
    export PATH="$fake_bin_dir:$PATH"
}

@test "resolve_lancache_stack_channel_tag maps channel=stable onto the stack:latest pointer image" {
    stub_stack_pointer_docker
    run resolve_lancache_stack_channel_tag "$BATS_TEST_TMPDIR/missing.env" "stable"
    [ "$status" -eq 0 ]
    [ "$output" = "sha-abc1234" ]
    [ "$(cat "$BATS_TEST_TMPDIR/requested_stack_image")" = "ghcr.io/wiki-mod/lancache-ng/stack:latest" ]
}

@test "resolve_lancache_stack_channel_tag still requests stack:latest for channel=latest" {
    stub_stack_pointer_docker
    run resolve_lancache_stack_channel_tag "$BATS_TEST_TMPDIR/missing.env" "latest"
    [ "$status" -eq 0 ]
    [ "$output" = "sha-abc1234" ]
    [ "$(cat "$BATS_TEST_TMPDIR/requested_stack_image")" = "ghcr.io/wiki-mod/lancache-ng/stack:latest" ]
}

@test "resolve_lancache_stack_channel_tag requests stack:edge unchanged for channel=edge" {
    stub_stack_pointer_docker
    run resolve_lancache_stack_channel_tag "$BATS_TEST_TMPDIR/missing.env" "edge"
    [ "$status" -eq 0 ]
    [ "$output" = "sha-abc1234" ]
    [ "$(cat "$BATS_TEST_TMPDIR/requested_stack_image")" = "ghcr.io/wiki-mod/lancache-ng/stack:edge" ]
}

@test "resolve_lancache_image_tag resolves LANCACHE_IMAGE_CHANNEL=stable through the pointer" {
    stub_stack_pointer_docker
    LANCACHE_IMAGE_CHANNEL="stable"
    run resolve_lancache_image_tag "$BATS_TEST_TMPDIR/missing.env"
    [ "$status" -eq 0 ]
    [ "$output" = "sha-abc1234" ]
    [ "$(cat "$BATS_TEST_TMPDIR/requested_stack_image")" = "ghcr.io/wiki-mod/lancache-ng/stack:latest" ]
}
