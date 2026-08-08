#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Adapter-level tests for the proxy (nginx) known-good-snapshot integration
# in services/proxy/entrypoint.sh (#415). Loads the real
# _proxy_validate_snapshot_or_rollback function (not a reimplementation) and
# exercises it against a stub `nginx` binary on PATH, so these tests don't
# require a real nginx install and stay deterministic regardless of the
# bats runner's available packages.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/proxy-known-good-snapshot-helpers.sh"

    # shellcheck source=tests/bats/helpers/proxy-known-good-snapshot-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/proxy-known-good-snapshot-helpers.sh"
    load_proxy_known_good_snapshot_helpers "$repo_root" "$helper_file"

    PROXY_CONFIG_SNAPSHOT_DIR="$BATS_TEST_TMPDIR/snapshots"
    KEEP_KNOWN_GOOD_CONFIGS=3
    export PROXY_CONFIG_SNAPSHOT_DIR KEEP_KNOWN_GOOD_CONFIGS

    live_dir="$BATS_TEST_TMPDIR/live"
    mkdir -p "$live_dir"
    nginx_conf="$live_dir/nginx.conf"
    export NGINX_TEST_CONFIG_FILE="$nginx_conf"

    stub_bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$stub_bin"
    cat > "$stub_bin/nginx" <<'STUB'
#!/bin/bash
# Stub nginx: "-t" reads $NGINX_TEST_CONFIG_FILE and fails if it contains
# the literal marker "BROKEN", so tests control validity without a real
# nginx install.
if grep -q "BROKEN" "$NGINX_TEST_CONFIG_FILE" 2>/dev/null; then
    echo "nginx: configuration file test failed" >&2
    exit 1
fi
echo "nginx: configuration file test is successful"
exit 0
STUB
    chmod +x "$stub_bin/nginx"
    PATH="$stub_bin:$PATH"
    export PATH
}

@test "valid candidate config is snapshotted and nginx starts normally" {
    printf 'OK config\n' > "$nginx_conf"

    run _proxy_validate_snapshot_or_rollback "$nginx_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[known-good-snapshot][proxy][CREATE]"* ]]

    run kgs_list_snapshots "$PROXY_CONFIG_SNAPSHOT_DIR"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 1 ]
    # The live file is untouched (still the newly generated candidate).
    [ "$(cat "$nginx_conf")" = "OK config" ]
}

@test "invalid candidate falls back to the newest known-good snapshot" {
    printf 'OK config v1\n' > "$nginx_conf"
    _proxy_validate_snapshot_or_rollback "$nginx_conf" >/dev/null

    printf 'BROKEN config v2\n' > "$nginx_conf"
    run _proxy_validate_snapshot_or_rollback "$nginx_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"generated nginx config failed validation"* ]]
    [[ "$output" == *"[known-good-snapshot][proxy][SELECT]"* ]]
    [[ "$output" == *"NOT the newly generated config"* ]]

    # The live nginx.conf was rolled back to the last known-good content.
    [ "$(cat "$nginx_conf")" = "OK config v1" ]
}

@test "invalid candidate with no known-good snapshot refuses to start" {
    printf 'BROKEN config\n' > "$nginx_conf"

    run _proxy_validate_snapshot_or_rollback "$nginx_conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no known-good nginx config snapshot is available"* ]]
    [ "$(cat "$nginx_conf")" = "BROKEN config" ]
}

@test "legacy pre-upgrade snapshot missing the stream-ACL file is backfilled and becomes usable for rollback again" {
    # Simulates an install that already has a known-good snapshot from
    # before this PR added STREAM_CLIENT_ACL_FILE (00-stream-client-acl.conf)
    # to the candidate list -- only the two older candidate files exist in
    # the snapshot, exactly as kgs_snapshot_create would have left it under
    # the old 4-file (here reduced to 2 for test brevity) candidate set.
    local params_conf="$live_dir/proxy-params.conf"
    printf 'legacy nginx.conf v1\n' > "$nginx_conf"
    printf 'legacy proxy-params v1\n' > "$params_conf"
    kgs_snapshot_create "$PROXY_CONFIG_SNAPSHOT_DIR" "$KEEP_KNOWN_GOOD_CONFIGS" "proxy" "$nginx_conf" "$params_conf"

    legacy_id="$(kgs_list_snapshots "$PROXY_CONFIG_SNAPSHOT_DIR")"
    [ -n "$legacy_id" ]
    [ ! -f "$PROXY_CONFIG_SNAPSHOT_DIR/$legacy_id/00-stream-client-acl.conf" ]

    # This boot's freshly-generated ACL file (deterministic from
    # PROXY_ALLOWED_CLIENT_CIDRS, unrelated to whether the legacy snapshot's
    # own nginx.conf/proxy-params.conf are still valid).
    local acl_file="$live_dir/00-stream-client-acl.conf"
    printf 'allow 10.0.0.0/8;\ndeny all;\n' > "$acl_file"

    _migrate_legacy_proxy_snapshots_for_stream_acl "$PROXY_CONFIG_SNAPSHOT_DIR" "$acl_file"

    [ -f "$PROXY_CONFIG_SNAPSHOT_DIR/$legacy_id/00-stream-client-acl.conf" ]
    [ "$(cat "$PROXY_CONFIG_SNAPSHOT_DIR/$legacy_id/00-stream-client-acl.conf")" = "$(cat "$acl_file")" ]

    # The migrated snapshot's original two files are untouched byte-for-byte
    # (the backfill must not re-derive or alter what was already validated
    # together).
    [ "$(cat "$PROXY_CONFIG_SNAPSHOT_DIR/$legacy_id/nginx.conf")" = "legacy nginx.conf v1" ]
    [ "$(cat "$PROXY_CONFIG_SNAPSHOT_DIR/$legacy_id/proxy-params.conf")" = "legacy proxy-params v1" ]

    # Now a full 5-candidate-style rollback (nginx.conf + proxy-params.conf +
    # the newly-backfilled ACL file) can actually select this migrated
    # snapshot instead of finding zero usable snapshots.
    printf 'BROKEN config\n' > "$nginx_conf"
    printf 'BROKEN proxy-params\n' > "$params_conf"
    printf 'BROKEN acl\n' > "$acl_file"
    run kgs_snapshot_apply "$PROXY_CONFIG_SNAPSHOT_DIR" "proxy" "true" "$nginx_conf" "$params_conf" "$acl_file"
    [ "$status" -eq 0 ]
    [ "$(cat "$acl_file")" = "allow 10.0.0.0/8;
deny all;" ]
}

@test "migration is a no-op for a snapshot that already has the stream-ACL file" {
    local params_conf="$live_dir/proxy-params.conf"
    local acl_file="$live_dir/00-stream-client-acl.conf"
    printf 'proxy-params v1\n' > "$params_conf"
    printf 'allow 10.0.0.0/8;\ndeny all;\n' > "$acl_file"
    kgs_snapshot_create "$PROXY_CONFIG_SNAPSHOT_DIR" "$KEEP_KNOWN_GOOD_CONFIGS" "proxy" "$nginx_conf" "$params_conf" "$acl_file"
    already_migrated_id="$(kgs_list_snapshots "$PROXY_CONFIG_SNAPSHOT_DIR")"
    original_mtime="$(stat -c '%Y' "$PROXY_CONFIG_SNAPSHOT_DIR/$already_migrated_id/00-stream-client-acl.conf")"

    printf 'allow 172.16.0.0/12;\ndeny all;\n' > "$acl_file"
    run _migrate_legacy_proxy_snapshots_for_stream_acl "$PROXY_CONFIG_SNAPSHOT_DIR" "$acl_file"
    [ "$status" -eq 0 ]

    # Untouched: still the ORIGINAL snapshotted content, not overwritten by
    # this later, unrelated live edit to $acl_file.
    [ "$(cat "$PROXY_CONFIG_SNAPSHOT_DIR/$already_migrated_id/00-stream-client-acl.conf")" = "allow 10.0.0.0/8;
deny all;" ]
    [ "$(stat -c '%Y' "$PROXY_CONFIG_SNAPSHOT_DIR/$already_migrated_id/00-stream-client-acl.conf")" = "$original_mtime" ]
}

@test "retention keeps only KEEP_KNOWN_GOOD_CONFIGS snapshots across repeated valid starts" {
    KEEP_KNOWN_GOOD_CONFIGS=2
    for i in 1 2 3 4; do
        printf 'OK config v%s\n' "$i" > "$nginx_conf"
        _proxy_validate_snapshot_or_rollback "$nginx_conf" >/dev/null
    done

    run kgs_list_snapshots "$PROXY_CONFIG_SNAPSHOT_DIR"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 2 ]
}
