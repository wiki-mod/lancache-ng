#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression coverage for issue #1069: setup.sh's "Cache size in GiB" prompt
# used to accept any positive integer with no check against the real free
# space at the chosen CACHE_DIR, so an operator could write a CACHE_MAX_SIZE
# the disk could never satisfy. These tests exercise the extracted pure
# helpers directly (nearest_existing_ancestor_dir, available_space_mib_at,
# cache_size_buffer_mib, cache_size_fits_available_mib,
# largest_valid_cache_gb, is_valid_nginx_time_value) without driving the
# interactive `ask` prompt loop itself.
#
# Reuses tests/bats/helpers/setup-update-helpers.sh's extraction range
# (is_valid_ipv4() through, but excluding, install_missing_tools()) since all
# of the functions under test here live inside that same range, right after
# is_absolute_path().

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-update-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-update-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-update-helpers.sh"
    load_setup_update_helpers "$repo_root" "$helper_file"
}

# ─── nearest_existing_ancestor_dir ───

@test "nearest_existing_ancestor_dir returns the path itself when it already exists" {
    run nearest_existing_ancestor_dir "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR" ]
}

@test "nearest_existing_ancestor_dir walks up past not-yet-created nested directories" {
    # CACHE_DIR is only mkdir -p'd near the end of the install flow, well
    # after the size prompt -- this mirrors that "does not exist yet" case.
    run nearest_existing_ancestor_dir "$BATS_TEST_TMPDIR/lancache-ng/cache"
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR" ]
}

# ─── available_space_mib_at ───

@test "available_space_mib_at returns a positive integer for an existing directory" {
    run available_space_mib_at "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -gt 0 ]
}

@test "available_space_mib_at resolves a not-yet-created path to the same value as its existing ancestor" {
    run available_space_mib_at "$BATS_TEST_TMPDIR"
    ancestor_result="$output"

    run available_space_mib_at "$BATS_TEST_TMPDIR/not/created/yet"
    [ "$status" -eq 0 ]
    [ "$output" = "$ancestor_result" ]
}

# ─── cache_size_buffer_mib ───

@test "cache_size_buffer_mib applies the maintainer's staged buffer bands" {
    run cache_size_buffer_mib 4
    [ "$output" = "512" ]
    run cache_size_buffer_mib 5
    [ "$output" = "1024" ]
    run cache_size_buffer_mib 6
    [ "$output" = "1024" ]
    run cache_size_buffer_mib 7
    [ "$output" = "2048" ]
}

# ─── cache_size_fits_available_mib ───

@test "cache_size_fits_available_mib accepts a size that exactly leaves its required buffer" {
    # 6 GiB requested, 1 GiB buffer required (falls in the 4 < gb <= 6 band):
    # 7168 MiB avail - 1024 MiB buffer == 6144 MiB == 6 GiB requested exactly.
    run cache_size_fits_available_mib 6 7168
    [ "$status" -eq 0 ]
}

@test "cache_size_fits_available_mib rejects the next size up at the same available space" {
    # 7 GiB requested crosses into the > 6 GiB band, which needs a 2 GiB
    # buffer instead of 1 GiB -- the same 7168 MiB that exactly fit 6 GiB no
    # longer fits 7 GiB once the bigger buffer applies.
    run cache_size_fits_available_mib 7 7168
    [ "$status" -ne 0 ]
}

# ─── largest_valid_cache_gb ───

@test "largest_valid_cache_gb finds the true maximum across a buffer-band boundary" {
    # 12 GiB avail: a naive 12 GiB request only leaves a 2 GiB buffer
    # (10 GiB usable), which is exactly the buffer this band requires, so
    # the actual answer is 10, not 12 minus a smaller buffer.
    run largest_valid_cache_gb 12288
    [ "$status" -eq 0 ]
    [ "$output" = "10" ]
}

@test "largest_valid_cache_gb stays inside the low buffer band when avail is small" {
    # 4.5 GiB avail, low band (gb <= 4, 512 MiB buffer): 4 GiB request
    # leaves exactly 512 MiB, which fits without needing to fall back further.
    run largest_valid_cache_gb 4608
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]
}

@test "largest_valid_cache_gb reports failure when even 1 GiB would not leave a buffer" {
    run largest_valid_cache_gb 1000
    [ "$status" -ne 0 ]
    [ "$output" = "0" ]
}

@test "largest_valid_cache_gb boundary: one MiB short of the minimum still fails" {
    # 1 GiB requires a 512 MiB buffer (low band): 1536 MiB is exactly enough,
    # 1535 MiB is one MiB short and must be rejected, not rounded up.
    run largest_valid_cache_gb 1536
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run largest_valid_cache_gb 1535
    [ "$status" -ne 0 ]
    [ "$output" = "0" ]
}

# ─── is_valid_nginx_time_value ───

@test "is_valid_nginx_time_value accepts nginx's own time-value grammar" {
    run is_valid_nginx_time_value "365d"
    [ "$status" -eq 0 ]
    run is_valid_nginx_time_value "30d"
    [ "$status" -eq 0 ]
    run is_valid_nginx_time_value "12h"
    [ "$status" -eq 0 ]
    run is_valid_nginx_time_value "1h30m"
    [ "$status" -eq 0 ]
    run is_valid_nginx_time_value "600"
    [ "$status" -eq 0 ]
}

@test "is_valid_nginx_time_value rejects empty, non-numeric, and malformed values" {
    run is_valid_nginx_time_value ""
    [ "$status" -ne 0 ]
    run is_valid_nginx_time_value "abc"
    [ "$status" -ne 0 ]
    run is_valid_nginx_time_value "-5d"
    [ "$status" -ne 0 ]
    run is_valid_nginx_time_value "5 d"
    [ "$status" -ne 0 ]
}
