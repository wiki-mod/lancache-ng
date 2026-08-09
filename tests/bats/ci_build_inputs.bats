#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    bootstrap="ghcr.io/wiki-mod/lancache-ng/build-tools@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    golang="golang@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    rust="rust@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
}

@test "dns and ui consume the exact bootstrap build-tools digest through the documented build arg" {
    for service in dns ui; do
        run env CI_BOOTSTRAP_BUILD_TOOLS_IMAGE="$bootstrap" \
            bash "$REPO_ROOT/scripts/ci-build-inputs.sh" "$service" json
        [ "$status" -eq 0 ]
        json="$output"
        run jq -e --arg ref "$bootstrap" '
            .build_args.BUILD_TOOLS_IMAGE == $ref
            and (.build_args | length == 1)
            and (.build_contexts | length == 0)
        ' <<<"$json"
        [ "$status" -eq 0 ]
    done
}

@test "build-tools replaces both mutable Dockerfile bases with digest contexts" {
    run env CI_GOLANG_BASE_IMAGE="$golang" CI_RUST_BASE_IMAGE="$rust" \
        bash "$REPO_ROOT/scripts/ci-build-inputs.sh" build-tools json
    [ "$status" -eq 0 ]
    json="$output"
    run jq -e --arg golang "docker-image://$golang" --arg rust "docker-image://$rust" '
        (.build_args | length == 0)
        and .build_contexts["golang:latest"] == $golang
        and .build_contexts["rust:latest"] == $rust
    ' <<<"$json"
    [ "$status" -eq 0 ]
}

@test "services without external mutable build dependencies emit empty inputs" {
    run bash "$REPO_ROOT/scripts/ci-build-inputs.sh" proxy json
    [ "$status" -eq 0 ]
    [ "$output" = '{"build_args":{},"build_contexts":{}}' ]
}

@test "required external build inputs fail closed when not digest-qualified" {
    run env CI_BOOTSTRAP_BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools:latest \
        bash "$REPO_ROOT/scripts/ci-build-inputs.sh" dns json
    [ "$status" -ne 0 ]

    run env CI_GOLANG_BASE_IMAGE=golang:latest CI_RUST_BASE_IMAGE="$rust" \
        bash "$REPO_ROOT/scripts/ci-build-inputs.sh" build-tools json
    [ "$status" -ne 0 ]
}

@test "source fingerprint changes when exact external build input changes" {
    sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    one_json='{"build_args":{"BUILD_TOOLS_IMAGE":"ghcr.io/wiki-mod/lancache-ng/build-tools@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"build_contexts":{}}'
    two_json='{"build_args":{"BUILD_TOOLS_IMAGE":"ghcr.io/wiki-mod/lancache-ng/build-tools@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"build_contexts":{}}'

    one="$(env CI_SOURCE_BUILD_INPUTS_JSON="$one_json" CI_SOURCE_APT_CACHE_BUST=2026-W31 bash "$REPO_ROOT/scripts/ci-source-fingerprint.sh" dns "$sha")"
    two="$(env CI_SOURCE_BUILD_INPUTS_JSON="$two_json" CI_SOURCE_APT_CACHE_BUST=2026-W31 bash "$REPO_ROOT/scripts/ci-source-fingerprint.sh" dns "$sha")"
    [ "$one" != "$two" ]
}

@test "mutable package repositories participate in the weekly source fingerprint" {
    sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    inputs='{"build_args":{},"build_contexts":{}}'

    one="$(env CI_SOURCE_BUILD_INPUTS_JSON="$inputs" CI_SOURCE_APT_CACHE_BUST=2026-W31 bash "$REPO_ROOT/scripts/ci-source-fingerprint.sh" proxy "$sha")"
    two="$(env CI_SOURCE_BUILD_INPUTS_JSON="$inputs" CI_SOURCE_APT_CACHE_BUST=2026-W32 bash "$REPO_ROOT/scripts/ci-source-fingerprint.sh" proxy "$sha")"
    [ "$one" != "$two" ]
}

@test "package refresh policy keeps build-tools surgical but marks legacy runtime layers no-cache" {
    sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"

    run bash "$REPO_ROOT/scripts/ci-package-refresh-policy.sh" build-tools "$sha"
    [ "$status" -eq 0 ]
    run jq -e '.refresh_required == true and .native_cache_bust == true and .force_no_cache == false' <<<"$output"
    [ "$status" -eq 0 ]

    run bash "$REPO_ROOT/scripts/ci-package-refresh-policy.sh" proxy "$sha"
    [ "$status" -eq 0 ]
    run jq -e '.refresh_required == true and .native_cache_bust == false and .force_no_cache == true' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "build-once action forces no-cache only when refresh bucket is not consumed natively" {
    action="$REPO_ROOT/.github/actions/ghcr-build-once-push-retry/action.yml"
    run grep -F 'no-cache: ${{ steps.cache-policy.outputs.no_cache }}' "$action"
    [ "$status" -eq 0 ]
    run grep -F 'if ! grep -Eq' "$action"
    [ "$status" -eq 0 ]
    run grep -F 'Building this candidate with no-cache so stale package layers cannot be reused.' "$action"
    [ "$status" -eq 0 ]
}

@test "Trivy clean-result reuse and local vulnerability DB are bounded to a six-hour epoch" {
    action="$REPO_ROOT/.github/actions/trivy-scan-with-cache/action.yml"
    run grep -F 'slot=$((10#$hour / 6 * 6))' "$action"
    [ "$status" -eq 0 ]
    run grep -F 'db_dir="${db_root}/${bucket}"' "$action"
    [ "$status" -eq 0 ]
    run grep -F 'cache-dir: ${{ steps.freshness.outputs.db_dir }}' "$action"
    [ "$status" -eq 0 ]
    run grep -F '${{ steps.freshness.outputs.bucket }}' "$action"
    [ "$status" -eq 0 ]
    run grep -F 'cache-dir: ${{ inputs.vuln-db-cache-dir }}' "$action"
    [ "$status" -ne 0 ]
}

@test "candidate workflow freezes external inputs and records the same matrix object" {
    workflow="$REPO_ROOT/.github/workflows/ci-artifact-v2.yml"
    run grep -F 'CI_BOOTSTRAP_BUILD_TOOLS_IMAGE=%s' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'ci-resolve-image-ref.sh golang:latest' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'ci-resolve-image-ref.sh rust:latest' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'MATRIX_BUILD_ARGS: ${{ matrix.build_args }}' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'build-contexts: ${{ matrix.build_contexts }}' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'CI_SOURCE_BUILD_INPUTS_JSON: ${{ toJSON(matrix.build_inputs) }}' "$workflow"
    [ "$status" -eq 0 ]
}

@test "release workflow freezes tooling bases and records the same build-input object" {
    workflow="$REPO_ROOT/.github/workflows/ci-release-accepted-v2.yml"
    run grep -F 'ci-resolve-image-ref.sh golang:latest' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'ci-resolve-image-ref.sh rust:latest' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'build-contexts: ${{ matrix.build_contexts }}' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'CI_SOURCE_BUILD_INPUTS_JSON: ${{ toJSON(matrix.build_inputs) }}' "$workflow"
    [ "$status" -eq 0 ]
}

write_dns_platform_record() {
    local path="$1" platform="$2" digest="$3"
    cat >"$path" <<JSON
{
  "schema": "image-candidate-platform/v1",
  "scope": "runtime",
  "service": "dns",
  "image": "ghcr.io/wiki-mod/lancache-ng/dns",
  "candidate_source_sha": "1111111111111111111111111111111111111111",
  "artifact_source_sha": "1111111111111111111111111111111111111111",
  "source_fingerprint": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
  "build_inputs": {"build_args": {}, "build_contexts": {}},
  "platform": "$platform",
  "digest": "$digest",
  "mode": "built",
  "reused_index_digest": ""
}
JSON
}

@test "index assembly rejects missing required external build inputs before registry access" {
    record_dir="$BATS_TEST_TMPDIR/platforms"
    output_file="$BATS_TEST_TMPDIR/index.json"
    mkdir -p "$record_dir"
    write_dns_platform_record \
        "$record_dir/dns__amd64.json" linux/amd64 \
        sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    write_dns_platform_record \
        "$record_dir/dns__arm64.json" linux/arm64 \
        sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

    run env GHCR_RETRY_MAX_ATTEMPTS=1 \
        bash "$REPO_ROOT/scripts/ci-assemble-service-index.sh" \
        dns ghcr.io/wiki-mod/lancache-ng/dns \
        1111111111111111111111111111111111111111 candidate-v2-test \
        "$record_dir" "$output_file"

    [ "$status" -ne 0 ]
    [[ "$output" == *"dns must carry exactly BUILD_TOOLS_IMAGE as external build arg"* ]]
    [[ "$output" == *"invalid build inputs for dns"* ]]
    [ ! -e "$output_file" ]
}

@test "built candidate record rejects a planned fingerprint that differs from producer evidence" {
    sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    digest="sha256:9999999999999999999999999999999999999999999999999999999999999999"
    marker_dir="$BATS_TEST_TMPDIR/lancache-build-inputs"
    output_file="$BATS_TEST_TMPDIR/proxy-built.json"
    mkdir -p "$marker_dir"
    printf 'APT_CACHE_BUST=2026-W31\n' >"$marker_dir/${digest#sha256:}.env"

    run env \
        RUNNER_TEMP="$BATS_TEST_TMPDIR" \
        CI_SOURCE_BUILD_INPUTS_JSON='{"build_args":{},"build_contexts":{}}' \
        bash "$REPO_ROOT/scripts/ci-write-candidate-record.sh" \
        runtime proxy ghcr.io/wiki-mod/lancache-ng/proxy \
        "$sha" "$sha" \
        sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
        linux/amd64 "$digest" built "$output_file"

    [ "$status" -ne 0 ]
    [[ "$output" == *"effective source fingerprint changed after planning for built proxy"* ]]
    [ ! -e "$output_file" ]
}
