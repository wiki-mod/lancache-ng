#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Emits the non-source-controlled inputs that must be frozen for one image
# build. The JSON is part of the artifact fingerprint and also drives the
# actual Buildx build arguments/named-context overrides.
set -euo pipefail

[[ $# -eq 2 ]] || {
    echo "usage: ci-build-inputs.sh SERVICE json|build-args|build-contexts" >&2
    exit 2
}
service="$1"
mode="$2"

require_digest_ref() {
    local name="$1" value="$2"
    [[ "$value" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] || {
        echo "ci-build-inputs: $name must be an exact digest-qualified image reference, got '${value:-<empty>}'" >&2
        exit 1
    }
}

build_args='{}'
build_contexts='{}'
case "$service" in
    dns|ui)
        bootstrap="${CI_BOOTSTRAP_BUILD_TOOLS_IMAGE:-}"
        require_digest_ref CI_BOOTSTRAP_BUILD_TOOLS_IMAGE "$bootstrap"
        build_args="$(jq -cn --arg value "$bootstrap" '{BUILD_TOOLS_IMAGE:$value}')"
        ;;
    build-tools)
        golang="${CI_GOLANG_BASE_IMAGE:-}"
        rust="${CI_RUST_BASE_IMAGE:-}"
        require_digest_ref CI_GOLANG_BASE_IMAGE "$golang"
        require_digest_ref CI_RUST_BASE_IMAGE "$rust"
        build_contexts="$(jq -cn \
            --arg golang "docker-image://$golang" \
            --arg rust "docker-image://$rust" \
            '{"golang:latest":$golang,"rust:latest":$rust}')"
        ;;
    *) ;;
esac

case "$mode" in
    json)
        jq -cnS --argjson build_args "$build_args" --argjson build_contexts "$build_contexts" \
            '{build_args:$build_args,build_contexts:$build_contexts}'
        ;;
    build-args)
        jq -r '. | to_entries | sort_by(.key)[] | "\(.key)=\(.value)"' <<<"$build_args"
        ;;
    build-contexts)
        jq -r '. | to_entries | sort_by(.key)[] | "\(.key)=\(.value)"' <<<"$build_contexts"
        ;;
    *)
        echo "ci-build-inputs: unsupported mode: $mode" >&2
        exit 2
        ;;
esac
