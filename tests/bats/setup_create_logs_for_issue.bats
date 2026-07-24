#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for #762's `setup.sh create-logs-for-issue` diagnostic bundle,
# driving the real setup.sh functions (logbundle_key_looks_like_secret,
# logbundle_secret_env_keys, logbundle_collect_secret_values,
# logbundle_redact_stream, logbundle_redact_env_file,
# logbundle_select_compressor, logbundle_named_volume_listing, and
# cmd_create_logs_for_issue itself) rather than a re-implementation of them.
# Docker is mocked as a shell function per test (no real Docker daemon
# needed), matching setup_backup_restore_safety.bats's own convention.
#
# Redaction gets the strongest coverage here on purpose (#762 review): this
# feature exists specifically to hand a maintainer real diagnostic data, so
# a redaction gap is a credential leak, not a cosmetic bug.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-create-logs-for-issue-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-create-logs-for-issue-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-create-logs-for-issue-helpers.sh"
    load_setup_create_logs_for_issue_helpers "$repo_root" "$helper_file"

    install_dir="$BATS_TEST_TMPDIR/install"
    mkdir -p "$install_dir"
    cat > "$install_dir/docker-compose.yml" <<'EOF'
name: lancache-ng

services:
  proxy:
    image: foo
EOF
}

teardown() {
    unset -f docker command 2>/dev/null || true
}

# ── logbundle_key_looks_like_secret ───────────────────────────────────────────

@test "logbundle_key_looks_like_secret matches every credential-shaped key name this script manages" {
    for key in KEA_CTRL_TOKEN DDNS_TSIG_KEY PDNS_API_KEY NATS_UI_PASSWORD \
        NATS_DNS_WRITER_PASSWORD NATS_DNS_REPLICA_PASSWORD NATS_CALLOUT_PASSWORD \
        NATS_SYS_PASSWORD SECONDARY_REGISTRATION_TOKEN UI_AUTH_PASSWORD; do
        run logbundle_key_looks_like_secret "$key"
        [ "$status" -eq 0 ]
    done
}

@test "logbundle_key_looks_like_secret does not flag ordinary operational keys" {
    for key in IP_STANDARD SSL_ENABLED CACHE_DIR NATS_UI_USER DHCP_MODE COMPOSE_PROFILES; do
        run logbundle_key_looks_like_secret "$key"
        [ "$status" -eq 1 ]
    done
}

# ── logbundle_secret_env_keys ─────────────────────────────────────────────────

@test "logbundle_secret_env_keys lists the ten keys this script generates/manages" {
    run logbundle_secret_env_keys
    [ "$status" -eq 0 ]
    expected=$(printf '%s\n' KEA_CTRL_TOKEN DDNS_TSIG_KEY PDNS_API_KEY \
        NATS_UI_PASSWORD NATS_DNS_WRITER_PASSWORD NATS_DNS_REPLICA_PASSWORD \
        NATS_CALLOUT_PASSWORD NATS_SYS_PASSWORD SECONDARY_REGISTRATION_TOKEN UI_AUTH_PASSWORD)
    [ "$(echo "$output" | sort)" = "$(echo "$expected" | sort)" ]
}

# ── logbundle_collect_secret_values ───────────────────────────────────────────

@test "logbundle_collect_secret_values returns only real, non-placeholder secret values" {
    env_file="$BATS_TEST_TMPDIR/.env"
    cat > "$env_file" <<'EOF'
IP_STANDARD=192.168.1.10
PDNS_API_KEY=abc123deadbeef
UI_AUTH_PASSWORD=CHANGE_ME_please
NATS_UI_PASSWORD=supersecretvaluelong123456
SECONDARY_REGISTRATION_TOKEN=
EOF
    run logbundle_collect_secret_values "$env_file"
    [ "$status" -eq 0 ]
    # Placeholder (CHANGE_ME_*) and empty values must never be emitted.
    [[ "$output" != *"CHANGE_ME"* ]]
    [[ "$output" == *"abc123deadbeef"* ]]
    [[ "$output" == *"supersecretvaluelong123456"* ]]
}

@test "logbundle_collect_secret_values also catches a pattern-matched key not on the explicit list" {
    env_file="$BATS_TEST_TMPDIR/.env"
    cat > "$env_file" <<'EOF'
A_FUTURE_CUSTOM_TOKEN=zzz789tokenvalue
EOF
    run logbundle_collect_secret_values "$env_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"zzz789tokenvalue"* ]]
}

@test "logbundle_collect_secret_values orders values longest-first" {
    env_file="$BATS_TEST_TMPDIR/.env"
    cat > "$env_file" <<'EOF'
PDNS_API_KEY=short
UI_AUTH_PASSWORD=averyveryverylongsecretvalue
EOF
    run logbundle_collect_secret_values "$env_file"
    [ "$status" -eq 0 ]
    first_line=$(echo "$output" | head -1)
    [ "$first_line" = "averyveryverylongsecretvalue" ]
}

# ── logbundle_redact_stream ───────────────────────────────────────────────────

@test "logbundle_redact_stream scrubs a secret value embedded mid-string, not just on its own line" {
    secrets_file="$BATS_TEST_TMPDIR/secrets.txt"
    printf '%s\n' "supersecretvaluelong123456" > "$secrets_file"
    input_file="$BATS_TEST_TMPDIR/input.txt"
    printf "connect nats://user:supersecretvaluelong123456@host:4222\nother line untouched\n" > "$input_file"

    # Redirect from a file rather than piping from a `bash -c` subshell: a
    # subshell doesn't inherit this function (only sourced, never `export -f`'d),
    # matching the real call sites in setup.sh (e.g. the .env redaction call),
    # which also redirect from a file rather than pipe into this function.
    run logbundle_redact_stream "$secrets_file" < "$input_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nats://user:[REDACTED]@host:4222"* ]]
    [[ "$output" == *"other line untouched"* ]]
    [[ "$output" != *"supersecretvaluelong123456"* ]]
}

@test "logbundle_redact_stream is a no-op copy when no secrets are configured" {
    secrets_file="$BATS_TEST_TMPDIR/empty-secrets.txt"
    : > "$secrets_file"
    input_file="$BATS_TEST_TMPDIR/input.txt"
    printf "plain text, nothing to redact\n" > "$input_file"

    run logbundle_redact_stream "$secrets_file" < "$input_file"
    [ "$status" -eq 0 ]
    [ "$output" = "plain text, nothing to redact" ]
}

# ── logbundle_redact_env_file ─────────────────────────────────────────────────

@test "logbundle_redact_env_file redacts every credential-shaped line and leaves the rest untouched" {
    src="$BATS_TEST_TMPDIR/src.env"
    dst="$BATS_TEST_TMPDIR/dst.env"
    cat > "$src" <<'EOF'
IP_STANDARD=192.168.1.10
PDNS_API_KEY=abc123deadbeef
SECONDARY_REGISTRATION_TOKEN=
EOF
    run logbundle_redact_env_file "$src" "$dst"
    [ "$status" -eq 0 ]
    content=$(cat "$dst")
    [[ "$content" == *"IP_STANDARD=192.168.1.10"* ]]
    [[ "$content" == *"PDNS_API_KEY=[REDACTED]"* ]]
    # Even an empty/placeholder secret value is redacted for a consistent
    # "this field is a secret" view, rather than leaking which credentials
    # are still unset.
    [[ "$content" == *"SECONDARY_REGISTRATION_TOKEN=[REDACTED]"* ]]
    [[ "$content" != *"abc123deadbeef"* ]]
}

# ── logbundle_select_compressor ───────────────────────────────────────────────

@test "logbundle_select_compressor prefers zstd when available" {
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "zstd" ]; then return 0; fi
        builtin command "$@"
    }
    run logbundle_select_compressor
    [ "$status" -eq 0 ]
    [ "$output" = "zst" ]
}

@test "logbundle_select_compressor falls back to bzip2 when zstd is unavailable" {
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "zstd" ]; then return 1; fi
        if [ "$1" = "-v" ] && [ "$2" = "bzip2" ]; then return 0; fi
        builtin command "$@"
    }
    run logbundle_select_compressor
    [ "$status" -eq 0 ]
    [ "$output" = "bz2" ]
}

@test "logbundle_select_compressor falls back to gzip when neither zstd nor bzip2 is available" {
    command() {
        if [ "$1" = "-v" ] && { [ "$2" = "zstd" ] || [ "$2" = "bzip2" ]; }; then return 1; fi
        builtin command "$@"
    }
    run logbundle_select_compressor
    [ "$status" -eq 0 ]
    [ "$output" = "gz" ]
}

# ── logbundle_named_volume_listing ────────────────────────────────────────────

@test "logbundle_named_volume_listing reports a missing volume instead of failing" {
    docker() {
        case "$1" in
            volume) return 1 ;;
        esac
    }
    out="$BATS_TEST_TMPDIR/listing.txt"
    run logbundle_named_volume_listing "$install_dir" "$install_dir/.env" proxy-config-snapshots config-snapshots "$out"
    [ "$status" -eq 0 ]
    [[ "$(cat "$out")" == *"not found"* ]]
}

@test "logbundle_named_volume_listing lists via a throwaway container when the volume exists" {
    docker() {
        case "$1" in
            volume) return 0 ;;
            run)
                shift
                printf 'docker run: %s\n' "$*"
                ;;
        esac
    }
    out="$BATS_TEST_TMPDIR/listing.txt"
    run logbundle_named_volume_listing "$install_dir" "$install_dir/.env" proxy-config-snapshots config-snapshots "$out"
    [ "$status" -eq 0 ]
    [[ "$(cat "$out")" == *"lancache-ng_proxy-config-snapshots"* ]]
    [[ "$(cat "$out")" == *"config-snapshots"* ]]
}

# ── cmd_create_logs_for_issue (end-to-end, Docker mocked) ────────────────────

@test "cmd_create_logs_for_issue refuses a directory with no stack" {
    run cmd_create_logs_for_issue "$BATS_TEST_TMPDIR/does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No stack found"* ]]
}

@test "cmd_create_logs_for_issue produces one archive with every secret redacted and the working directory cleaned up" {
    secret="deadbeef1234567890secretvalue"
    cat > "$install_dir/.env" <<EOF
IP_STANDARD=192.168.1.10
SSL_ENABLED=0
PDNS_API_KEY=$secret
UI_AUTH_PASSWORD=CHANGE_ME_x
LANCACHE_STATE_DIR=$install_dir/state
EOF
    install_missing_tools() { :; }
    export secret

    docker() {
        case "$1" in
            --version) printf 'Docker version 26.1.4, build abc\n' ;;
            compose)
                shift
                [ "$1" = "--env-file" ] && shift 2
                case "$1" in
                    ps) printf 'CONTAINER proxy running, key=%s\n' "$secret" ;;
                    config)
                        if [ "${2:-}" = "--services" ]; then
                            printf 'proxy\n'
                        else
                            printf 'services: {proxy: {environment: {PDNS_API_KEY: %s}}}\n' "$secret"
                        fi
                        ;;
                    logs) printf 'proxy startup used key %s in connection string\n' "$secret" ;;
                    version) printf 'Docker Compose version v2.29.1\n' ;;
                esac
                ;;
            volume) return 1 ;;
            run)
                shift
                printf 'docker run: %s\n' "$*"
                ;;
        esac
    }

    dest_root="$BATS_TEST_TMPDIR/dest"
    run cmd_create_logs_for_issue "$install_dir" --dest "$dest_root"
    [ "$status" -eq 0 ]

    archive=$(find "$dest_root" -maxdepth 1 -name 'lancache-ng-issue-logs-*.tar.*')
    [ -n "$archive" ]
    [ "$(find "$dest_root" -maxdepth 1 -name 'lancache-ng-issue-logs-*.tar.*' | wc -l)" -eq 1 ]

    # No working directory should survive next to the archive.
    leftover=$(find "$dest_root" -maxdepth 1 -type d -name '.create-logs-for-issue-*')
    [ -z "$leftover" ]

    extract_dir="$BATS_TEST_TMPDIR/extract"
    mkdir -p "$extract_dir"
    tar -C "$extract_dir" -xf "$archive"

    # The raw secret must not survive anywhere in the extracted bundle.
    run grep -R "$secret" "$extract_dir"
    [ "$status" -ne 0 ]

    bundle_dir=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d)
    [[ "$(cat "$bundle_dir/env/.env")" == *"PDNS_API_KEY=[REDACTED]"* ]]
    [[ "$(cat "$bundle_dir/compose-config.txt")" == *"[REDACTED]"* ]]
    [[ "$(cat "$bundle_dir/compose-ps.txt")" == *"[REDACTED]"* ]]
    [[ "$(cat "$bundle_dir/logs/proxy.log")" == *"[REDACTED]"* ]]
}
