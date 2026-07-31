#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for lancache_ui_cache_max_gb_override_is_valid() (issue
# #1069 part 3) -- the pure gate cmd_converge_reconcile uses before ever
# folding an Admin-UI-written CACHE_MAX_GB override into .env. Mirrors
# setup_ui_channel_override.bats's structure for the same class of value
# (services/ui/src/routes/cache.rs's resize_cache already validated the
# requested size against real free disk space before writing this override;
# this gate only guards against a malformed/corrupt settings-file value
# reaching cmd_converge_reconcile, it does not re-run that disk check).

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-cache-resize-override-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-cache-resize-override-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-cache-resize-override-helpers.sh"
    load_setup_cache_resize_override_helpers "$repo_root" "$helper_file"
}

@test "accepts a plain positive integer" {
    run lancache_ui_cache_max_gb_override_is_valid "50"
    [ "$status" -eq 0 ]
}

@test "accepts a single-digit value" {
    run lancache_ui_cache_max_gb_override_is_valid "1"
    [ "$status" -eq 0 ]
}

@test "accepts a large value" {
    run lancache_ui_cache_max_gb_override_is_valid "2000"
    [ "$status" -eq 0 ]
}

# A leading zero must be treated as decimal, not octal -- "008" parsed by a
# plain `(( ))` without the `10#` base prefix would abort on the invalid
# octal digit '8' instead of validating as decimal 8.
@test "accepts a value with a leading zero without an octal parse error" {
    run lancache_ui_cache_max_gb_override_is_valid "008"
    [ "$status" -eq 0 ]
}

@test "rejects zero" {
    run lancache_ui_cache_max_gb_override_is_valid "0"
    [ "$status" -eq 1 ]
}

@test "rejects a negative value" {
    run lancache_ui_cache_max_gb_override_is_valid "-5"
    [ "$status" -eq 1 ]
}

@test "rejects a decimal value" {
    run lancache_ui_cache_max_gb_override_is_valid "50.5"
    [ "$status" -eq 1 ]
}

@test "rejects an empty value" {
    run lancache_ui_cache_max_gb_override_is_valid ""
    [ "$status" -eq 1 ]
}

@test "rejects non-numeric garbage without matching by accident" {
    run lancache_ui_cache_max_gb_override_is_valid "50; rm -rf /"
    [ "$status" -eq 1 ]
}

@test "rejects a value with surrounding whitespace" {
    run lancache_ui_cache_max_gb_override_is_valid " 50 "
    [ "$status" -eq 1 ]
}
