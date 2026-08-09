#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Fixture coverage for tools/runner-host/lancache-ci-docker-daemon-config.sh's
# pure merge logic (daemon_config_additions_json/merge_daemon_config) -- the
# go-gated AG-CI-016 daemon.json rollout tracked in issue #1255 section 7 and
# PR #1251's own "Scope Boundaries" (bounding the docker build cache +
# log-driver at the daemon level; not done in that PR because it requires a
# coordinated dockerd restart on the self-hosted runner hosts).
#
# What this suite proves without needing a real Docker daemon or root:
#   - the additions this rollout applies are exactly what's documented in
#     tools/runner-host/README.md and reproducible via env overrides;
#   - merging onto an EXISTING daemon.json preserves its unrelated keys
#     (verified against a fixture matching the real content confirmed on
#     runner hosts .229/.240/.241 via direct SSH inspection, 2026-07-31:
#     max-concurrent-downloads/-uploads + storage-driver);
#   - merging onto a MISSING daemon.json (host .243's real, confirmed state)
#     produces exactly the additions, not an error;
#   - an existing daemon.json that is not valid JSON is a hard, fail-closed
#     error -- this script must never silently discard or clobber content it
#     cannot parse.
# Uses `defaultReservedSpace` (not the earlier draft's `defaultKeepStorage`)
# for `builder.gc`'s size-bound key -- verified against moby/moby's current
# `BuilderGCConfig` struct and, empirically, against the real compiled
# `/usr/bin/dockerd` binary on a runner host (`strings $(which dockerd) |
# grep -i keepstorage`) that `defaultKeepStorage` is only a deprecated,
# still-functional alias for `defaultReservedSpace`; this rollout emits the
# current, non-deprecated key name going forward. See the script's own
# header comment for the full finding.
#
# The disruptive `restart` mode and the file-writing `apply`/`stage` modes
# are intentionally NOT covered here (they require root and a real dockerd);
# those were instead verified manually against copies of the real per-host
# daemon.json on a runner host, recorded in the introducing PR's validation
# section, per this project's existing manual-review pattern for the sibling
# lancache-ci-cleanup.sh (also untested by bats, for the same reason).

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/tools/runner-host/lancache-ci-docker-daemon-config.sh"
    # shellcheck source=tools/runner-host/lancache-ci-docker-daemon-config.sh
    source "$script"
}

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
    # Pre-existing keys must survive untouched.
    [ "$(jq -r '."max-concurrent-downloads"' <<<"$output")" = "20" ]
    [ "$(jq -r '."max-concurrent-uploads"' <<<"$output")" = "20" ]
    [ "$(jq -r '."storage-driver"' <<<"$output")" = "overlay2" ]
    # And the new additions must be present alongside them.
    [ "$(jq -r '.builder.gc.defaultReservedSpace' <<<"$output")" = "20GB" ]
    [ "$(jq -r '."log-driver"' <<<"$output")" = "json-file" ]
}

@test "merge_daemon_config: a missing daemon.json (matches real .243 state) produces exactly the additions" {
    missing="$BATS_TEST_TMPDIR/does-not-exist.json"
    run merge_daemon_config "$missing"
    [ "$status" -eq 0 ]
    expected="$(daemon_config_additions_json | jq -S '.')"
    actual="$(jq -S '.' <<<"$output")"
    [ "$actual" = "$expected" ]
}

@test "merge_daemon_config: an unparseable existing daemon.json is a hard, fail-closed error" {
    fixture="$BATS_TEST_TMPDIR/daemon.json"
    printf '{ this is not valid json' > "$fixture"
    run merge_daemon_config "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not valid JSON"* ]]
}

@test "merge_daemon_config: an existing 'builder' key with unrelated sub-keys is deep-merged, not replaced" {
    fixture="$BATS_TEST_TMPDIR/daemon.json"
    cat > "$fixture" <<'EOF'
{
  "builder": { "cache": { "something-unrelated": true } }
}
EOF
    run merge_daemon_config "$fixture"
    [ "$status" -eq 0 ]
    # The pre-existing unrelated builder.cache sub-key must survive ...
    [ "$(jq -r '.builder.cache."something-unrelated"' <<<"$output")" = "true" ]
    # ... alongside the new builder.gc this rollout adds.
    [ "$(jq -r '.builder.gc.defaultReservedSpace' <<<"$output")" = "20GB" ]
}
