#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Behavior tests for the shared-secret bootstrap library (issue #858):
# operator-value-wins, first-boot generate, read-existing, and -- the property
# the issue explicitly asks to prove -- that concurrent first-writers converge
# on ONE shared value instead of each generating its own (split-brain).

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

@test "a real configured value wins untouched and never writes the shared file" {
    run resolve_shared_secret pdns-api-key "operator-supplied-real-value" lancache_gen_hex32
    [ "$status" -eq 0 ]
    [ "$output" = "operator-supplied-real-value" ]
    [ ! -e "$LANCACHE_SHARED_SECRET_DIR/pdns-api-key" ]
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
