#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Tests for the generic known-good configuration snapshot contract
# (scripts/lib/known-good-snapshots.sh, issue #415). Covers retention
# (oldest pruned beyond the configured limit), invalid-snapshot rejection,
# and a successful rollback path, independent of any one service adapter.
#
# kgs_snapshot_apply's validator_cmd is `eval`-ed, so these tests use a
# small self-contained shell one-liner (grep for a literal "OK" marker line
# in the live file) as the validator instead of an external stub binary.
# That keeps these tests independent of whether the bats environment has a
# real nginx/dnsmasq/Kea binary installed — see
# tests/bats/proxy_known_good_snapshot.bats and
# tests/bats/dhcp_proxy_known_good_snapshot.bats for adapter-level tests
# that exercise the real entrypoint wiring against stub binaries instead.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/lib/known-good-snapshots.sh
    source "$repo_root/scripts/lib/known-good-snapshots.sh"

    snapshot_root="$BATS_TEST_TMPDIR/snapshots"
    dest_dir="$BATS_TEST_TMPDIR/live"
    mkdir -p "$dest_dir"
    config_file="$dest_dir/service.conf"
    valid_validator="grep -q '^OK$' '$config_file'"
}

write_config() {
    printf '%s\n' "$1" > "$config_file"
}

@test "kgs_snapshot_create creates a snapshot containing the given files" {
    write_config "OK"
    run kgs_snapshot_create "$snapshot_root" 3 "test" "$config_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[known-good-snapshot][test][CREATE]"* ]]
    [[ "$output" == *"created known-good snapshot"* ]]

    run kgs_list_snapshots "$snapshot_root"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 1 ]

    snap_id="$output"
    [ -f "$snapshot_root/$snap_id/service.conf" ]
    [ "$(cat "$snapshot_root/$snap_id/service.conf")" = "OK" ]
}

@test "kgs_snapshot_create refuses to snapshot a missing candidate file" {
    run kgs_snapshot_create "$snapshot_root" 3 "test" "$dest_dir/does-not-exist.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"candidate file missing"* ]]

    run kgs_list_snapshots "$snapshot_root"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "retention prunes the oldest snapshots beyond the configured limit" {
    for i in 1 2 3 4 5; do
        write_config "OK $i"
        kgs_snapshot_create "$snapshot_root" 3 "test" "$config_file" >/dev/null
    done

    run kgs_list_snapshots "$snapshot_root"
    [ "$status" -eq 0 ]
    # Exactly 3 survive (keep_n=3), even though 5 were created.
    [ "$(echo "$output" | wc -l)" -eq 3 ]

    # The two oldest snapshots (created from "OK 1" and "OK 2") are gone;
    # the three newest ("OK 3".."OK 5") remain, oldest-first.
    newest_three_contents=()
    while IFS= read -r snap_id; do
        newest_three_contents+=("$(cat "$snapshot_root/$snap_id/service.conf")")
    done <<< "$output"
    [ "${newest_three_contents[0]}" = "OK 3" ]
    [ "${newest_three_contents[1]}" = "OK 4" ]
    [ "${newest_three_contents[2]}" = "OK 5" ]
}

@test "retention clamps a non-numeric KEEP_KNOWN_GOOD_CONFIGS to the default of 3" {
    for i in 1 2 3 4 5; do
        write_config "OK $i"
        kgs_snapshot_create "$snapshot_root" "not-a-number" "test" "$config_file" >/dev/null
    done

    run kgs_list_snapshots "$snapshot_root"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 3 ]
}

@test "retention clamps an empty/zero KEEP_KNOWN_GOOD_CONFIGS instead of pruning everything" {
    write_config "OK 1"
    kgs_snapshot_create "$snapshot_root" "" "test" "$config_file" >/dev/null
    write_config "OK 2"
    kgs_snapshot_create "$snapshot_root" 0 "test" "$config_file" >/dev/null

    run kgs_list_snapshots "$snapshot_root"
    [ "$status" -eq 0 ]
    # Neither call pruned everything to zero; both snapshots survive because
    # the bad keep_n values were clamped to the default of 3.
    [ "$(echo "$output" | wc -l)" -eq 2 ]
}

@test "kgs_snapshot_apply refuses an invalid snapshot and leaves live config untouched" {
    write_config "BROKEN"
    kgs_snapshot_create "$snapshot_root" 3 "test" "$config_file" >/dev/null

    write_config "CANDIDATE-STILL-BROKEN"
    run kgs_snapshot_apply "$snapshot_root" "test" "$valid_validator" "$config_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"[known-good-snapshot][test][REJECT]"* ]]
    [[ "$output" == *"failed validation"* ]]
    [[ "$output" == *"[known-good-snapshot][test][FATAL]"* ]]

    # Rollback failed, so the live file must be exactly what it was before
    # kgs_snapshot_apply was called, not the (also invalid) snapshot content.
    [ "$(cat "$config_file")" = "CANDIDATE-STILL-BROKEN" ]
}

@test "kgs_snapshot_apply rolls back to the newest valid snapshot and skips newer invalid ones" {
    write_config "OK oldest"
    kgs_snapshot_create "$snapshot_root" 3 "test" "$config_file" >/dev/null

    # A second, newer snapshot is captured while genuinely valid, then the
    # file on disk is corrupted afterwards to simulate a snapshot directory
    # that later fails re-validation (e.g. a stale binary now rejects
    # previously-valid syntax) -- kgs_snapshot_apply must still fall through
    # to the older, still-valid snapshot rather than stopping at the first
    # rejection.
    write_config "OK newest"
    kgs_snapshot_create "$snapshot_root" 3 "test" "$config_file" >/dev/null
    newest_id="$(kgs_list_snapshots "$snapshot_root" | tail -n1)"
    printf 'BROKEN\n' > "$snapshot_root/$newest_id/service.conf"

    write_config "CANDIDATE-BROKEN"
    run kgs_snapshot_apply "$snapshot_root" "test" "$valid_validator" "$config_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[known-good-snapshot][test][REJECT]"* ]]
    [[ "$output" == *"[known-good-snapshot][test][SELECT]"* ]]

    [ "$(cat "$config_file")" = "OK oldest" ]
}

@test "kgs_snapshot_apply refuses to roll back when no snapshots exist" {
    write_config "CANDIDATE-BROKEN"
    run kgs_snapshot_apply "$snapshot_root" "test" "$valid_validator" "$config_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no known-good snapshots available"* ]]
    [ "$(cat "$config_file")" = "CANDIDATE-BROKEN" ]
}

@test "kgs_snapshot_create is atomic-enough: no partial snapshot directory survives a failed copy" {
    write_config "OK"
    second_file="$dest_dir/second.conf"
    # second_file deliberately does not exist, so the loop over candidate
    # files fails partway through -- after nginx.conf/service.conf would
    # already have been copied into staging, but before the directory is
    # ever mv-ed into its final <id> name.
    run kgs_snapshot_create "$snapshot_root" 3 "test" "$config_file" "$second_file"
    [ "$status" -ne 0 ]

    run kgs_list_snapshots "$snapshot_root"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # No leftover .staging.* directory should remain visible either.
    [ -z "$(find "$snapshot_root" -mindepth 1 -maxdepth 1 2>/dev/null)" ]
}
