#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Behavior tests for the shared-secret bootstrap library (issue #858):
# configured-value seeds the shared file, first-boot generate, read-existing,
# and -- the property the issue explicitly asks to prove -- that concurrent
# first-writers converge on ONE shared value instead of each generating its own
# (split-brain).

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=/dev/null
    . "$repo_root/scripts/lib/shared-secret-bootstrap.sh"
    TEST_DIR="$(mktemp -d)"
    export LANCACHE_SHARED_SECRET_DIR="$TEST_DIR/secrets"
    # No gid 10001 exists in CI; chgrp is best-effort in the library, so point
    # it at the current gid to keep the test hermetic.
    # Declared and exported separately (SC2155): combining them would mask
    # a real failure exit status from `id -g` behind the export builtin's
    # own (always-successful-here) return value.
    LANCACHE_SHARED_SECRET_GID="$(id -g)"
    export LANCACHE_SHARED_SECRET_GID
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "a real configured value seeds the shared file and returns untouched" {
    run resolve_shared_secret pdns-api-key "operator-supplied-real-value" lancache_gen_hex32
    [ "$status" -eq 0 ]
    [ "$output" = "operator-supplied-real-value" ]
    [ -s "$LANCACHE_SHARED_SECRET_DIR/pdns-api-key" ]
    file_content="$(cat "$LANCACHE_SHARED_SECRET_DIR/pdns-api-key")"
    [ "$file_content" = "$output" ]
}

@test "a seeded real value is readable later through the file-backed path" {
    run resolve_shared_secret pdns-api-key "operator-supplied-real-value" lancache_gen_hex32
    [ "$status" -eq 0 ]
    [ "$output" = "operator-supplied-real-value" ]

    run resolve_shared_secret pdns-api-key "" lancache_gen_hex32
    [ "$status" -eq 0 ]
    [ "$output" = "operator-supplied-real-value" ]
}

@test "a real configured value still wins when the shared-secrets volume cannot be created" {
    # What: a regular file as parent -> mkdir -p fails for any uid.
    # Why: immune to root/CAP_DAC_OVERRIDE, unlike a chmod-based test.
    # From: PR #1775
    : > "$TEST_DIR/not-a-directory"
    export LANCACHE_SHARED_SECRET_DIR="$TEST_DIR/not-a-directory/secrets"
    run resolve_shared_secret nats-ui-password "operator-supplied-real-value" lancache_gen_hex32
    [ "$status" -eq 0 ]
    [ "$output" = "operator-supplied-real-value" ]
}

@test "a stale conflicting value fails closed when it cannot be refreshed" {
    # What: stubs mktemp to fail deterministically, for any uid.
    # Why: a stale on-disk value must not split-brain other readers.
    # From: PR #1775
    mkdir -p "$LANCACHE_SHARED_SECRET_DIR"
    printf '%s' "old-value" > "$LANCACHE_SHARED_SECRET_DIR/nats-ui-password"
    mktemp() { return 1; }
    run resolve_shared_secret nats-ui-password "new-operator-value" lancache_gen_hex32
    [ "$status" -ne 0 ]
    [ "$(cat "$LANCACHE_SHARED_SECRET_DIR/nats-ui-password")" = "old-value" ]
}

@test "the operator-value fallback survives a real set -euo pipefail caller" {
    # What: reproduces the entrypoints' VAR="$(resolve_shared_secret ...)".
    # Why: proves the || fallback works under the callers' own shell opts.
    # From: PR #1775
    : > "$TEST_DIR/not-a-directory"
    export LANCACHE_SHARED_SECRET_DIR="$TEST_DIR/not-a-directory/secrets"
    run bash -c '
        set -euo pipefail
        . "$1/scripts/lib/shared-secret-bootstrap.sh"
        if ! val="$(resolve_shared_secret nats-ui-password "operator-supplied-real-value" lancache_gen_hex32)"; then
            val="FAILED"
        fi
        printf "%s" "$val"
    ' _ "$repo_root"
    [ "$status" -eq 0 ]
    [ "$output" = "operator-supplied-real-value" ]
}

@test "an empty value on first boot generates a strong hex value and persists it" {
    run resolve_shared_secret pdns-api-key "" lancache_gen_hex32
    [ "$status" -eq 0 ]
    # 64 hex chars from 32 random bytes.
    [[ "$output" =~ ^[0-9a-f]{64}$ ]]
    [ -s "$LANCACHE_SHARED_SECRET_DIR/pdns-api-key" ]
    # File content equals what was returned, with no trailing newline.
    file_content="$(cat "$LANCACHE_SHARED_SECRET_DIR/pdns-api-key")"
    [ "$file_content" = "$output" ]
}

@test "a second empty-value call reads the already-generated value (no rotation)" {
    first="$(resolve_shared_secret pdns-api-key "" lancache_gen_hex32)"
    second="$(resolve_shared_secret pdns-api-key "" lancache_gen_hex32)"
    [ -n "$first" ]
    [ "$first" = "$second" ]
}

@test "base64 generator produces a non-empty TSIG-shaped key" {
    run resolve_shared_secret ddns-tsig-key "" lancache_gen_base64_32
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    # base64 of 32 bytes decodes back to exactly 32 bytes.
    decoded_len="$(printf '%s' "$output" | base64 -d | wc -c)"
    [ "$decoded_len" -eq 32 ]
}

@test "secret_is_placeholder matches empty and universal placeholders, not real values" {
    for p in "" "CHANGE_ME_X" "changeme-thing" "YOUR_TOKEN_HERE" "anything_HERE"; do
        run secret_is_placeholder "$p"
        [ "$status" -eq 0 ] || { echo "expected placeholder: '$p'"; false; }
    done
    for real in "a-real-64-hex-value" "lancache-nats-ui-dev-secret" "validation-ui-password"; do
        run secret_is_placeholder "$real"
        [ "$status" -ne 0 ] || { echo "wrongly flagged real value as placeholder: '$real'"; false; }
    done
}

# Case-insensitivity and "-"/"_" equivalence (issue #967): a deliberate
# fail-safe widening of the same pattern set above, not a new pattern family.
# The full cross-implementation case list (including documented divergences
# from setup.sh's and the Rust implementation's own pattern sets) lives in
# tests/fixtures/placeholder-detection-cases.txt, exercised by
# tests/bats/placeholder_detection_parity.bats; this test only proves the
# normalization itself works for THIS implementation in isolation.
@test "secret_is_placeholder is case-insensitive and treats - and _ as equivalent" {
    for p in "CHANGE-ME-X" "change_me_x" "Change-Me-X" "CHANGEME-THING" "your-token-here" "YOUR-TOKEN-HERE" "anything-HERE"; do
        run secret_is_placeholder "$p"
        [ "$status" -eq 0 ] || { echo "expected placeholder after normalization: '$p'"; false; }
    done
    # Real values must stay real even with mixed-case/dash content that
    # doesn't actually match a placeholder pattern once normalized.
    for real in "A-Real-64-Hex-Value" "VALIDATION-UI-PASSWORD" "acme-service-token"; do
        run secret_is_placeholder "$real"
        [ "$status" -ne 0 ] || { echo "wrongly flagged real value as placeholder: '$real'"; false; }
    done
}

@test "concurrent first-writers converge on ONE shared value (no split-brain)" {
    mkdir -p "$TEST_DIR/out"
    workers=20
    for i in $(seq 1 "$workers"); do
        (
            v="$(resolve_shared_secret pdns-api-key "" lancache_gen_hex32)"
            # Trailing newline is required here: without it, cat concatenates
            # all 20 workers' output with no delimiter at all, so sort/wc see
            # one giant unterminated record instead of 20 lines -- `wc -l`
            # would then report 1 even if the workers resolved 20 DIFFERENT
            # values, silently defeating the split-brain check below.
            printf '%s\n' "$v" > "$TEST_DIR/out/$i"
        ) &
    done
    wait

    # Exactly one secret file was created (the losing racers reused it).
    secret_file_count="$(find "$LANCACHE_SHARED_SECRET_DIR" -maxdepth 1 -type f -name 'pdns-api-key' | wc -l)"
    [ "$secret_file_count" -eq 1 ]
    # No leftover temp files from losing racers.
    tmp_count="$(find "$LANCACHE_SHARED_SECRET_DIR" -maxdepth 1 -name '.secret.*' | wc -l)"
    [ "$tmp_count" -eq 0 ]

    # Every worker resolved the exact same non-empty value.
    canonical="$(cat "$LANCACHE_SHARED_SECRET_DIR/pdns-api-key")"
    [ -n "$canonical" ]
    distinct="$(cat "$TEST_DIR"/out/* | sort -u | wc -l)"
    [ "$distinct" -eq 1 ]
    [ "$(cat "$TEST_DIR/out/1")" = "$canonical" ]
}
