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

# The real entrypoint.sh call site passes multiple candidate files
# (PROXY_CANDIDATE_FILES: nginx.conf, proxy-params.conf, the ssl-map, and
# the stream-targets map -- four as of this commit), but every test above
# this point exercises the function with only ONE. This left the multi-file
# "incomplete snapshot" rejection branch (kgs_snapshot_apply's own "missing
# at least one candidate file" check) completely untested for the proxy
# adapter. Exercised here with two files rather than all four: enough to
# prove the rejection/fallback branch itself, without needing this test to
# track PROXY_CANDIDATE_FILES's exact real-world size (a future addition to
# that list needs no update here).
@test "a snapshot missing a candidate file (taken before it existed) is rejected during rollback, falling back to an earlier complete snapshot" {
    params_conf="$live_dir/proxy-params.conf"

    # Snapshot 1 (older): both files valid -- a complete two-file candidate
    # set, sufficient to prove the rejection/fallback branch regardless of
    # PROXY_CANDIDATE_FILES's own real, larger size.
    printf 'OK nginx v1\n' > "$nginx_conf"
    printf 'OK params v1\n' > "$params_conf"
    run _proxy_validate_snapshot_or_rollback "$nginx_conf" "$params_conf"
    [ "$status" -eq 0 ]

    # Snapshot 2 (newer): only nginx_conf is passed as a candidate this
    # time -- the real-world shape this mirrors is a snapshot taken while
    # temporarily validating with a narrower candidate list than today's
    # (e.g. mid-upgrade, or a future generated file not present yet); the
    # completeness check itself is agnostic to WHY a snapshot has fewer
    # files, it only cares whether every file today's call needs is present.
    printf 'OK nginx v2\n' > "$nginx_conf"
    run _proxy_validate_snapshot_or_rollback "$nginx_conf"
    [ "$status" -eq 0 ]

    run kgs_list_snapshots "$PROXY_CONFIG_SNAPSHOT_DIR"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 2 ]

    # Both files now go invalid, validated against today's full two-file
    # candidate list -- rollback tries the newest snapshot (2) first, must
    # reject it as incomplete (missing proxy-params.conf entirely), then
    # fall back to snapshot 1, which has both files.
    printf 'BROKEN nginx v3\n' > "$nginx_conf"
    printf 'BROKEN params v3\n' > "$params_conf"
    run _proxy_validate_snapshot_or_rollback "$nginx_conf" "$params_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rejected known-good snapshot"*"incomplete (missing at least one candidate file)"* ]]
    [[ "$output" == *"[known-good-snapshot][proxy][SELECT]"* ]]

    [ "$(cat "$nginx_conf")" = "OK nginx v1" ]
    [ "$(cat "$params_conf")" = "OK params v1" ]
}

# Contrast case: when the ONLY existing snapshot is incomplete and no
# earlier complete one exists to fall back to, rollback must refuse to
# start rather than silently mixing a stale complete file with a newly
# rolled-back-but-still-missing one.
@test "an incomplete snapshot with no complete alternative refuses to start" {
    params_conf="$live_dir/proxy-params.conf"

    printf 'OK nginx v1\n' > "$nginx_conf"
    run _proxy_validate_snapshot_or_rollback "$nginx_conf"
    [ "$status" -eq 0 ]

    printf 'BROKEN nginx v2\n' > "$nginx_conf"
    printf 'BROKEN params v2\n' > "$params_conf"
    run _proxy_validate_snapshot_or_rollback "$nginx_conf" "$params_conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"rejected known-good snapshot"*"incomplete (missing at least one candidate file)"* ]]
    [[ "$output" == *"no known-good nginx config snapshot is available"* ]]
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
