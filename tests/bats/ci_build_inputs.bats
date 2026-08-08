#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    bootstrap="ghcr.io/wiki-mod/lancache-ng/build-tools@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    golang="golang@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    rust="rust@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
}

@test "dns and ui consume the exact bootstrap build-tools digest through a context override" {
    key='ghcr.io/wiki-mod/lancache-ng/build-tools:latest'
    for service in dns ui; do
        run env CI_BOOTSTRAP_BUILD_TOOLS_IMAGE="$bootstrap" \
            bash "$REPO_ROOT/scripts/ci-build-inputs.sh" "$service" json
        [ "$status" -eq 0 ]
        json="$output"
        run jq -e --arg key "$key" --arg ref "docker-image://$bootstrap" '
            (.build_args | length == 0)
            and .build_contexts[$key] == $ref
            and (.build_contexts | length == 1)
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
    key='ghcr.io/wiki-mod/lancache-ng/build-tools:latest'
    one_json="$(jq -cn --arg key "$key" --arg value 'docker-image://ghcr.io/wiki-mod/lancache-ng/build-tools@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' '{build_args:{},build_contexts:{($key):$value}}')"
    two_json="$(jq -cn --arg key "$key" --arg value 'docker-image://ghcr.io/wiki-mod/lancache-ng/build-tools@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' '{build_args:{},build_contexts:{($key):$value}}')"

    one="$(env CI_SOURCE_BUILD_INPUTS_JSON="$one_json" bash "$REPO_ROOT/scripts/ci-source-fingerprint.sh" dns "$sha")"
    two="$(env CI_SOURCE_BUILD_INPUTS_JSON="$two_json" bash "$REPO_ROOT/scripts/ci-source-fingerprint.sh" dns "$sha")"
    [ "$one" != "$two" ]
}
