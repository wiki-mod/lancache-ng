#!/usr/bin/env bats
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
