#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for lancache_ui_channel_override_is_valid() (#819) -- the
# pure gate cmd_converge_reconcile uses before ever folding an Admin-UI-
# written LANCACHE_IMAGE_CHANNEL override into .env. Deliberately narrower
# than the wider validate_lancache_image_channel() (which also accepts
# pinned and, once #827 lands, "stable" via a different codepath): this
# control only ever offers the operator "stable" or "nightly" (services/ui/src/
# routes/setup.rs's is_valid_ui_channel; "nightly" was named "edge" before the
# v0.3.0 hard-cut, #1056), and validate_lancache_image_channel
# itself `die`s on an unrecognized value -- unsuitable for a scheduled
# convergence tick, which must silently no-op instead of aborting the whole
# systemd service run over an unexpected value.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-ui-channel-override-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-ui-channel-override-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-ui-channel-override-helpers.sh"
    load_setup_ui_channel_override_helpers "$repo_root" "$helper_file"
}

@test "accepts stable" {
    run lancache_ui_channel_override_is_valid "stable"
    [ "$status" -eq 0 ]
}

@test "accepts nightly" {
    run lancache_ui_channel_override_is_valid "nightly"
    [ "$status" -eq 0 ]
}

# "edge" was renamed to "nightly" and hard-cut in v0.3.0 (#1056): a settings
# volume still holding the old value is treated as unrecognized (no-op'd by the
# convergence tick), not silently accepted as an alias.
@test "rejects the removed edge value" {
    run lancache_ui_channel_override_is_valid "edge"
    [ "$status" -eq 1 ]
}

# "dev" is retired (#825/#1141), not just narrower-scoped here: the wider
# validate_lancache_image_channel() now hard-cuts it too. This gate must
# still reject it independently, since it never offered dev as a UI choice
# to begin with (unlike edge/dev in the wider validator, this one has never
# had to widen and then retire anything).
@test "rejects dev" {
    run lancache_ui_channel_override_is_valid "dev"
    [ "$status" -eq 1 ]
}

@test "rejects pinned" {
    run lancache_ui_channel_override_is_valid "pinned"
    [ "$status" -eq 1 ]
}

@test "rejects latest" {
    run lancache_ui_channel_override_is_valid "latest"
    [ "$status" -eq 1 ]
}

@test "rejects an empty value" {
    run lancache_ui_channel_override_is_valid ""
    [ "$status" -eq 1 ]
}

@test "rejects garbage input without matching by accident" {
    run lancache_ui_channel_override_is_valid "STABLE; rm -rf /"
    [ "$status" -eq 1 ]
}
