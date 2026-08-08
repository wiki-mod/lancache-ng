#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Emits or validates the non-source-controlled inputs that must be frozen for
# one image build. The canonical JSON is part of the artifact fingerprint and
# also drives the actual Buildx build arguments/named-context overrides.
set -euo pipefail

[[ $# -ge 2 && $# -le 3 ]] || {
    echo "usage: ci-build-inputs.sh SERVICE json|build-args|build-contexts|validate [BUILD_INPUTS_JSON]" >&2
    exit 2
}
service="$1"
mode="$2"

require_digest_ref() {
    local name="$1" value="$2"
    [[ "$value" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] || {
        echo "ci-build-inputs: $name must be an exact digest-qualified image reference, got '${value:-<empty>}'" >&2
        return 1
    }
}

validate_json() {
    local value="$1"
    jq -e '
        type == "object"
        and (keys | sort) == ["build_args","build_contexts"]
        and (.build_args | type == "object")
        and (.build_contexts | type == "object")
        and ([.build_args[], .build_contexts[]] | all(type == "string"))
    ' <<<"$value" >/dev/null || {
        echo "ci-build-inputs: invalid build-input JSON schema for $service" >&2
        return 1
    }

    case "$service" in
        dns|ui)
            [[ "$(jq '.build_args | length' <<<"$value")" -eq 0 ]] || return 1
            key='ghcr.io/wiki-mod/lancache-ng/build-tools:latest'
            [[ "$(jq -r '.build_contexts | keys | join(",")' <<<"$value")" == "$key" ]] || {
                echo "ci-build-inputs: $service must carry exactly the build-tools:latest context override" >&2
                return 1
            }
            context="$(jq -r --arg key "$key" '.build_contexts[$key]' <<<"$value")"
            [[ "$context" == docker-image://* ]] || return 1
            require_digest_ref BUILD_TOOLS_IMAGE "${context#docker-image://}"
            ;;
        build-tools)
            [[ "$(jq '.build_args | length' <<<"$value")" -eq 0 ]] || return 1
            [[ "$(jq -r '.build_contexts | keys | sort | join(",")' <<<"$value")" == 'golang:latest,rust:latest' ]] || {
                echo "ci-build-inputs: build-tools must carry exactly golang:latest and rust:latest context overrides" >&2
                return 1
            }
            for key in 'golang:latest' 'rust:latest'; do
                context="$(jq -r --arg key "$key" '.build_contexts[$key]' <<<"$value")"
                [[ "$context" == docker-image://* ]] || {
                    echo "ci-build-inputs: $key override must use docker-image://" >&2
                    return 1
                }
                require_digest_ref "$key" "${context#docker-image://}" || return 1
            done
            ;;
        *)
            [[ "$(jq '(.build_args | length) + (.build_contexts | length)' <<<"$value")" -eq 0 ]] || {
                echo "ci-build-inputs: $service has unexpected external build inputs" >&2
                return 1
            }
            ;;
    esac
}

if [[ "$mode" == validate ]]; then
    [[ $# -eq 3 ]] || {
        echo "ci-build-inputs: validate requires BUILD_INPUTS_JSON" >&2
        exit 2
    }
    validate_json "$3"
    exit 0
fi
[[ $# -eq 2 ]] || {
    echo "ci-build-inputs: $mode does not accept a third argument" >&2
    exit 2
}

build_args='{}'
build_contexts='{}'
case "$service" in
    dns|ui)
        bootstrap="${CI_BOOTSTRAP_BUILD_TOOLS_IMAGE:-}"
        require_digest_ref CI_BOOTSTRAP_BUILD_TOOLS_IMAGE "$bootstrap"
        build_contexts="$(jq -cn --arg value "docker-image://$bootstrap" \
            '{"ghcr.io/wiki-mod/lancache-ng/build-tools:latest":$value}')"
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

value="$(jq -cnS --argjson build_args "$build_args" --argjson build_contexts "$build_contexts" \
    '{build_args:$build_args,build_contexts:$build_contexts}')"
validate_json "$value"

case "$mode" in
    json)
        printf '%s\n' "$value"
        ;;
    build-args)
        jq -r '.build_args | to_entries | sort_by(.key)[] | "\(.key)=\(.value)"' <<<"$value"
        ;;
    build-contexts)
        jq -r '.build_contexts | to_entries | sort_by(.key)[] | "\(.key)=\(.value)"' <<<"$value"
        ;;
    *)
        echo "ci-build-inputs: unsupported mode: $mode" >&2
        exit 2
        ;;
esac
