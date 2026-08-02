#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for services/watchdog/retention.sh's maybe_rotate_fluent_bit_selflog()
# (issue #1236, moved here from watchdog.sh by #842's blast-radius-separation
# extraction, 2026-08-01 -- see that file's own header): bounds disk usage of
# fluent-bit's own operational self-log file (/data/fluent-bit.log on the
# syslog-data volume, written via the `syslog` service's `-l`/`--log_file`
# CLI flag) even during a sustained syslog-ng outage, when fluent-bit's own
# connection/flush retry logging grows that file continuously (confirmed
# empirically on a real runner, roughly one line/second at the project's 5s
# flush interval -- see the issue for the full repro).
#
# Unlike maybe_prune_syslog() (tested in retention_syslog_prune.bats), this
# function is NOT gated behind SYSLOG_ENABLED and is NOT rate-limited by a
# daily stamp file -- see the function's own comment in retention.sh for why
# neither fits here. Every test below calls it directly, with no stamp/env
# gate to manage between invocations (besides the numeric knobs under test).
#
# Sources the real function via helpers/retention-helpers.sh's extraction
# range, same as retention_syslog_prune.bats -- this function lives in the
# same captured range (defined before the "Retention daemon started." log
# line), so no helper change was needed beyond retargeting it at retention.sh.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/retention-helpers-extracted.sh"

    selflog_dir="$BATS_TEST_TMPDIR/syslog-data"
    mkdir -p "$selflog_dir"
    selflog_file="$selflog_dir/fluent-bit.log"

    export FLUENT_BIT_SELFLOG_DIR="$selflog_dir"
    export FLUENT_BIT_SELFLOG_MAX_MB=1
    export FLUENT_BIT_SELFLOG_MAX_ROTATIONS=5
    # #842 Teil 1 hardening: validate_retention_dir() only accepts a
    # FLUENT_BIT_SELFLOG_DIR that resolves under this prefix -- see
    # retention_purge.bats's identical comment on CACHE_DIR_ALLOWED_PREFIX.
    export FLUENT_BIT_SELFLOG_DIR_ALLOWED_PREFIX="$BATS_TEST_TMPDIR"

    # shellcheck source=tests/bats/helpers/retention-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/retention-helpers.sh"
    load_retention_functions "$repo_root" "$helper_file"
}

# Reads back a rotated backup's content regardless of whether it was
# compressed -- the test environment (build-tools container) does not ship
# zstd, so the function's own `command -v zstd` check is expected to be
# false here and backups stay plain; a real runner build (services/watchdog/
# Dockerfile installs zstd at build time) would see the .zst variant instead.
# Handling both keeps this test valid in either environment rather than
# assuming the CI container's tool availability.
read_rotated_backup() {
    local base="$1"
    if [ -f "${base}.zst" ]; then
        zstd -d -q -c "${base}.zst"
    else
        cat "$base"
    fi
}

find_rotated_backups() {
    find "$selflog_dir" -maxdepth 1 -type f -name 'fluent-bit.log.*' | sort
}

@test "maybe_rotate_fluent_bit_selflog is a no-op when the self-log file does not exist yet" {
    # Covers both real cases this must not touch: the logging profile was
    # never enabled (mount target never populated), and fluent-bit hasn't
    # written its first line yet.
    run maybe_rotate_fluent_bit_selflog
    [ "$status" -eq 0 ]
    [ ! -f "$selflog_file" ]
    [ -z "$(find_rotated_backups)" ]
}

@test "maybe_rotate_fluent_bit_selflog is a no-op when the file is within the size budget" {
    printf 'small content\n' > "$selflog_file"

    maybe_rotate_fluent_bit_selflog

    [ -f "$selflog_file" ]
    [ "$(cat "$selflog_file")" = "small content" ]
    [ -z "$(find_rotated_backups)" ]
}

# The core acceptance-criteria proof (#1236): once the file exceeds budget,
# it must be rotated -- backup created with the ORIGINAL content preserved
# (never silently dropped, since an operator needs exactly this retry/error
# info during the outage this feature exists to surface), and the live file
# truncated so fluent-bit's growth is capped going forward.
@test "maybe_rotate_fluent_bit_selflog rotates and truncates once the size budget is exceeded, preserving content in the backup" {
    # FLUENT_BIT_SELFLOG_MAX_MB=1 -> budget is 1 MiB (1048576 bytes).
    head -c 1100000 /dev/zero | tr '\0' 'x' > "$selflog_file"
    printf 'MARKER-END-OF-FILE\n' >> "$selflog_file"

    maybe_rotate_fluent_bit_selflog

    [ -f "$selflog_file" ]
    [ "$(stat -c '%s' "$selflog_file")" -eq 0 ]

    local backups; backups="$(find_rotated_backups)"
    [ -n "$backups" ]
    local backup_count; backup_count=$(wc -l <<< "$backups")
    [ "$backup_count" -eq 1 ]

    local backup_base; backup_base="$(echo "$backups" | sed 's/\.zst$//')"
    read_rotated_backup "$backup_base" | grep -q 'MARKER-END-OF-FILE'
}

@test "maybe_rotate_fluent_bit_selflog leaves the live file untouched if the backup copy fails" {
    # Simulate a copy failure by making the directory read-only so `cp`
    # cannot create the backup file -- the live file (with its
    # not-yet-archived content) must be left alone rather than truncated,
    # since truncating here would be an unrecoverable, silent loss of
    # exactly the diagnostics this feature exists to preserve.
    head -c 1100000 /dev/zero | tr '\0' 'x' > "$selflog_file"
    chmod 555 "$selflog_dir"

    run maybe_rotate_fluent_bit_selflog
    chmod 755 "$selflog_dir"

    [ "$status" -eq 0 ]
    [ -s "$selflog_file" ]
    [ "$(stat -c '%s' "$selflog_file")" -gt 0 ]
}

@test "maybe_rotate_fluent_bit_selflog caps total rotated backups at FLUENT_BIT_SELFLOG_MAX_ROTATIONS, deleting oldest first" {
    export FLUENT_BIT_SELFLOG_MAX_ROTATIONS=3

    # Trigger 5 separate rotations. Without a rotation-count cap, an outage
    # long enough to cross the size budget repeatedly would make the
    # ROTATED BACKUPS themselves grow without bound -- defeating the whole
    # point of this function -- so 5 rotations against a cap of 3 must leave
    # exactly the 3 newest.
    for i in 1 2 3 4 5; do
        head -c 1100000 /dev/zero | tr '\0' 'x' > "$selflog_file"
        printf 'rotation-%d\n' "$i" >> "$selflog_file"
        maybe_rotate_fluent_bit_selflog
        # Distinct timestamp suffixes even when this loop runs faster than
        # one second per iteration (the rotation filename's granularity).
        sleep 1.1
    done

    local backups; backups="$(find_rotated_backups)"
    local backup_count; backup_count=$(wc -l <<< "$backups")
    [ "$backup_count" -eq 3 ]

    # Decode every surviving backup's content and confirm it's exactly
    # {rotation-3, rotation-4, rotation-5} -- proving both the count cap AND
    # that oldest-first (not newest-first or arbitrary) deletion order was
    # used, since rotation-1/rotation-2 must be the ones gone.
    local decoded_markers=""
    while IFS= read -r backup; do
        local base="${backup%.zst}"
        decoded_markers="${decoded_markers}$(read_rotated_backup "$base" | tail -n1) "
    done <<< "$backups"

    [[ "$decoded_markers" != *"rotation-1"* ]]
    [[ "$decoded_markers" != *"rotation-2"* ]]
    [[ "$decoded_markers" == *"rotation-3"* ]]
    [[ "$decoded_markers" == *"rotation-4"* ]]
    [[ "$decoded_markers" == *"rotation-5"* ]]
}

# Same class of bug as the FLUENT_BIT_SELFLOG_MAX_MB test above, but for
# the rotation-count cleanup path's `excess=$(( rotation_count -
# max_rotations ))`: that arithmetic only runs once rotation_count actually
# exceeds max_rotations, so this needs enough real rotations to cross a
# leading-zero-with-an-8-or-9 cap (FLUENT_BIT_SELFLOG_MAX_ROTATIONS=08) to
# prove the cleanup pass itself does not abort.
@test "maybe_rotate_fluent_bit_selflog does not abort on a leading-zero FLUENT_BIT_SELFLOG_MAX_ROTATIONS containing an 8 or 9" {
    export FLUENT_BIT_SELFLOG_MAX_ROTATIONS=08

    for i in 1 2 3 4 5 6 7 8 9; do
        head -c 1100000 /dev/zero | tr '\0' 'x' > "$selflog_file"
        printf 'rotation-%d\n' "$i" >> "$selflog_file"
        run maybe_rotate_fluent_bit_selflog
        [ "$status" -eq 0 ] || {
            echo "expected FLUENT_BIT_SELFLOG_MAX_ROTATIONS=08 not to abort on rotation $i; status=$status output=$output" >&2
            return 1
        }
        sleep 1.1
    done
}

@test "maybe_rotate_fluent_bit_selflog clamps invalid FLUENT_BIT_SELFLOG_MAX_MB to the default instead of aborting" {
    printf 'small\n' > "$selflog_file"

    FLUENT_BIT_SELFLOG_MAX_MB='not-a-number' run maybe_rotate_fluent_bit_selflog
    [ "$status" -eq 0 ]
    [ -f "$selflog_file" ]
}

# FLUENT_BIT_SELFLOG_MAX_MB=0 passes a digit-only check unchanged (it is
# all-digits); without a minimum-value floor this would set the budget to 0
# bytes and rotate on every single cycle regardless of actual size -- the
# same SYSLOG_MAX_GB=0 zero-budget bug class issue #757 fixed for
# maybe_prune_syslog() (see watchdog_syslog_prune.bats's matching test).
@test "maybe_rotate_fluent_bit_selflog clamps FLUENT_BIT_SELFLOG_MAX_MB=0 to the default instead of using a zero budget" {
    printf 'small\n' > "$selflog_file"

    FLUENT_BIT_SELFLOG_MAX_MB=0 maybe_rotate_fluent_bit_selflog

    [ -f "$selflog_file" ]
    [ "$(cat "$selflog_file")" = "small" ]
    [ -z "$(find_rotated_backups)" ]
}

@test "maybe_rotate_fluent_bit_selflog clamps an oversized FLUENT_BIT_SELFLOG_MAX_MB instead of overflowing the budget" {
    printf 'small\n' > "$selflog_file"

    FLUENT_BIT_SELFLOG_MAX_MB=99999999999999 run maybe_rotate_fluent_bit_selflog
    [ "$status" -eq 0 ]
    [ -f "$selflog_file" ]
}

# Found live 2026-07-31 (PR #1347's CI, via the sibling bug in
# services/watchdog/healthcheck.sh's CHECK_INTERVAL -- see that script's own
# comment for the full incident): the digit-only guard above accepts a
# leading-zero value like "018" completely unchanged (it is all-digits), but
# Bash's `$(( max_mb * 1024 * 1024 ))` then evaluates a leading-zero operand
# as octal -- "018" is not even valid octal (8 is not an octal digit), so
# this aborts the whole function with "value too great for base" under
# `set -euo pipefail` instead of silently misreading it. Must not abort.
@test "maybe_rotate_fluent_bit_selflog does not abort on a leading-zero FLUENT_BIT_SELFLOG_MAX_MB containing an 8 or 9" {
    printf 'small\n' > "$selflog_file"

    FLUENT_BIT_SELFLOG_MAX_MB=018 run maybe_rotate_fluent_bit_selflog
    [ "$status" -eq 0 ] || {
        echo "expected FLUENT_BIT_SELFLOG_MAX_MB=018 not to abort; status=$status output=$output" >&2
        return 1
    }
}

@test "maybe_rotate_fluent_bit_selflog clamps invalid FLUENT_BIT_SELFLOG_MAX_ROTATIONS to the default" {
    FLUENT_BIT_SELFLOG_MAX_ROTATIONS='garbage'
    head -c 1100000 /dev/zero | tr '\0' 'x' > "$selflog_file"

    run maybe_rotate_fluent_bit_selflog
    [ "$status" -eq 0 ]
}

# Runs every watchdog cycle (no daily rate-limit stamp, unlike
# maybe_prune_syslog()) -- a second consecutive call right after a rotation,
# with the live file still empty/under budget, must be a true no-op and must
# not, for example, delete the just-created backup or error out.
@test "maybe_rotate_fluent_bit_selflog second consecutive call is a no-op once back under budget" {
    head -c 1100000 /dev/zero | tr '\0' 'x' > "$selflog_file"
    maybe_rotate_fluent_bit_selflog
    [ "$(stat -c '%s' "$selflog_file")" -eq 0 ]
    local backups_after_first; backups_after_first="$(find_rotated_backups)"

    run maybe_rotate_fluent_bit_selflog
    [ "$status" -eq 0 ]
    [ "$(find_rotated_backups)" = "$backups_after_first" ]
}
