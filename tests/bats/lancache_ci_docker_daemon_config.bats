#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: bats tests for daemon config defaults and merge
# Why: restart/apply/stage need root and a real dockerd
# From: Issue #1255 | PR #1349

bats_require_minimum_version 1.5.0

setup() {
    # What: locates the script and sources it
    # Why: main is guarded; sourcing only defines functions
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/tools/runner-host/lancache-ci-docker-daemon-config.sh"
    # shellcheck source=tools/runner-host/lancache-ci-docker-daemon-config.sh
    source "$script"
}

# What: asserts default additions emitted by the helper
# Why: defaults must match the documented README rollout
@test "daemon_config_additions_json: default values match documented README.md rollout" {
    run daemon_config_additions_json
    [ "$status" -eq 0 ]
    reserved_space="$(jq -r '.builder.gc.defaultReservedSpace' <<<"$output")"
    enabled="$(jq -r '.builder.gc.enabled' <<<"$output")"
    log_driver="$(jq -r '."log-driver"' <<<"$output")"
    max_size="$(jq -r '."log-opts"."max-size"' <<<"$output")"
    max_file="$(jq -r '."log-opts"."max-file"' <<<"$output")"
    [ "$reserved_space" = "20GB" ]
    [ "$enabled" = "true" ]
    [ "$log_driver" = "json-file" ]
    [ "$max_size" = "10m" ]
    [ "$max_file" = "3" ]
}

# What: asserts env overrides change the emitted values
# Why: env overrides are a path separate from defaults
@test "daemon_config_additions_json: env overrides change the emitted values" {
    BUILDER_GC_RESERVED_SPACE="5GB" LOG_MAX_SIZE="1m" LOG_MAX_FILE="1" run daemon_config_additions_json
    [ "$status" -eq 0 ]
    reserved_space="$(jq -r '.builder.gc.defaultReservedSpace' <<<"$output")"
    max_size="$(jq -r '."log-opts"."max-size"' <<<"$output")"
    max_file="$(jq -r '."log-opts"."max-file"' <<<"$output")"
    [ "$reserved_space" = "5GB" ]
    [ "$max_size" = "1m" ]
    [ "$max_file" = "1" ]
}

# What: asserts pre-existing keys survive the merge
# Why: unrelated host settings must not be clobbered
@test "merge_daemon_config: existing keys survive the merge (matches real .229/.240/.241 content)" {
    fixture="$BATS_TEST_TMPDIR/daemon.json"
    cat > "$fixture" <<'EOF'
{
  "max-concurrent-downloads": 20,
  "max-concurrent-uploads": 20,
  "storage-driver": "overlay2"
}
EOF
    run merge_daemon_config "$fixture"
    [ "$status" -eq 0 ]
    # What: pre-existing keys keep their values
    # Why: the merge must not overwrite host settings
    [ "$(jq -r '."max-concurrent-downloads"' <<<"$output")" = "20" ]
    [ "$(jq -r '."max-concurrent-uploads"' <<<"$output")" = "20" ]
    [ "$(jq -r '."storage-driver"' <<<"$output")" = "overlay2" ]
    # What: asserts builder.gc and log-driver are added
    # Why: additions merge next to the existing keys
    [ "$(jq -r '.builder.gc.defaultReservedSpace' <<<"$output")" = "20GB" ]
    [ "$(jq -r '."log-driver"' <<<"$output")" = "json-file" ]
}

# What: asserts a missing daemon.json yields additions only
# Why: a missing file must not be an error case
@test "merge_daemon_config: a missing daemon.json (matches real .243 state) produces exactly the additions" {
    missing="$BATS_TEST_TMPDIR/does-not-exist.json"
    run merge_daemon_config "$missing"
    [ "$status" -eq 0 ]
    expected="$(daemon_config_additions_json | jq -S '.')"
    actual="$(jq -S '.' <<<"$output")"
    [ "$actual" = "$expected" ]
}

# What: asserts unparseable daemon.json fails the merge
# Why: invalid input must not be silently discarded
@test "merge_daemon_config: an unparseable existing daemon.json is a hard, fail-closed error" {
    fixture="$BATS_TEST_TMPDIR/daemon.json"
    printf '{ this is not valid json' > "$fixture"
    run merge_daemon_config "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not valid JSON"* ]]
}

# What: asserts unrelated builder sub-keys are kept
# Why: builder is deep-merged, not replaced
@test "merge_daemon_config: an existing 'builder' key with unrelated sub-keys is deep-merged, not replaced" {
    fixture="$BATS_TEST_TMPDIR/daemon.json"
    cat > "$fixture" <<'EOF'
{
  "builder": { "cache": { "something-unrelated": true } }
}
EOF
    run merge_daemon_config "$fixture"
    [ "$status" -eq 0 ]
    # What: builder.cache sub-keys survive the merge
    # Why: builder is deep-merged, not replaced wholesale
    [ "$(jq -r '.builder.cache."something-unrelated"' <<<"$output")" = "true" ]
    # What: asserts builder.gc.defaultReservedSpace is added
    # Why: deep merge keeps both builder sub-keys
    [ "$(jq -r '.builder.gc.defaultReservedSpace' <<<"$output")" = "20GB" ]
}
