#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Docker CLI boundary for exact-identity validation. The reusable simulation
# suite deliberately keeps its existing behavioral scripts; this shim changes
# only how first-party image references reach Docker. A first-party candidate
# transport tag is replaced with its recorded OCI digest, and every Compose
# model is overlaid with the exact runtime digests from the same stack lock.
#
# The override is rendered for every Compose invocation instead of being cached
# once. Several simulations enable profiles only on later commands; a cached
# model from an earlier pull/config invocation would otherwise leave those
# newly-active services on mutable tags.
set -euo pipefail

lock="${CI_LOCKED_STACK_FILE:?CI_LOCKED_STACK_FILE is required}"
shim_dir="${CI_LOCKED_DOCKER_SHIM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
repo_root="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/lib/ci-artifact-identity.sh
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
ci_ai_validate_stack_lock "$lock"

ci_lock_real_docker() {
    local configured="${CI_LOCKED_REAL_DOCKER:-}"
    if [[ -n "$configured" && -x "$configured" && "$configured" != "$shim_dir/docker" ]]; then
        printf '%s\n' "$configured"
        return 0
    fi

    local clean_path="" dir candidate
    IFS=: read -r -a path_parts <<<"$PATH"
    for dir in "${path_parts[@]}"; do
        [[ -n "$dir" && "$dir" != "$shim_dir" ]] || continue
        clean_path="${clean_path:+${clean_path}:}${dir}"
    done
    candidate="$(PATH="$clean_path" command -v docker || true)"
    [[ -n "$candidate" && -x "$candidate" && "$candidate" != "$shim_dir/docker" ]] \
        || ci_ai_fail "could not locate the real Docker CLI outside $shim_dir"
    printf '%s\n' "$candidate"
}

real_docker="$(ci_lock_real_docker)"
candidate_tag="$(jq -r '.candidate_tag' "$lock")"
[[ -n "$candidate_tag" ]] || ci_ai_fail "stack lock has no candidate tag"

ci_lock_digest_ref_for_transport() {
    local ref="$1" image digest transport
    while IFS=$'\t' read -r image digest; do
        transport="${image}:${candidate_tag}"
        if [[ "$ref" == "$transport" ]]; then
            ci_ai_require_digest "$digest"
            printf '%s@%s\n' "$image" "$digest"
            return 0
        fi
    done < <(jq -r '(.runtime + .tooling)[] | [.image,.digest] | @tsv' "$lock")
    return 1
}

ci_lock_rewrite_direct_args() {
    local -n input_ref=$1
    local -n output_ref=$2
    local arg locked
    output_ref=()
    for arg in "${input_ref[@]}"; do
        if locked="$(ci_lock_digest_ref_for_transport "$arg" 2>/dev/null)"; then
            output_ref+=("$locked")
        else
            output_ref+=("$arg")
        fi
    done
}

ci_lock_split_compose_args() {
    local -n input_ref=$1
    local -n globals_ref=$2
    local -n command_ref=$3
    local i=0 arg
    globals_ref=()

    while (( i < ${#input_ref[@]} )); do
        arg="${input_ref[$i]}"
        case "$arg" in
            -f|--file|--project-directory|--env-file|--project-name|--profile|--ansi|--progress)
                (( i + 1 < ${#input_ref[@]} )) \
                    || ci_ai_fail "docker compose option $arg is missing its value"
                globals_ref+=("$arg" "${input_ref[$((i + 1))]}")
                i=$((i + 2))
                ;;
            --file=*|--project-directory=*|--env-file=*|--project-name=*|--profile=*|--ansi=*|--progress=*)
                globals_ref+=("$arg")
                i=$((i + 1))
                ;;
            --compatibility|--dry-run|--all-resources)
                globals_ref+=("$arg")
                i=$((i + 1))
                ;;
            -*)
                globals_ref+=("$arg")
                i=$((i + 1))
                ;;
            *)
                break
                ;;
        esac
    done

    command_ref=("${input_ref[@]:$i}")
    (( ${#command_ref[@]} > 0 )) \
        || ci_ai_fail "docker compose invocation has no subcommand"
}

ci_lock_compose_override() {
    local output="$1"
    shift
    local -a globals=("$@")
    local rendered override service compose_image image digest locked_ref
    local matched=0

    rendered="$("$real_docker" compose "${globals[@]}" config --format json)" \
        || ci_ai_fail "could not render Compose model before applying stack lock"
    override='{"services":{}}'

    while IFS=$'\t' read -r service compose_image; do
        [[ -n "$service" && -n "$compose_image" ]] || continue
        [[ "$compose_image" == ghcr.io/wiki-mod/lancache-ng/* ]] || continue

        locked_ref=""
        while IFS=$'\t' read -r image digest; do
            if [[ "$compose_image" == "$image" \
                || "$compose_image" == "${image}:"* \
                || "$compose_image" == "${image}@"* ]]; then
                ci_ai_require_digest "$digest"
                locked_ref="${image}@${digest}"
                break
            fi
        done < <(jq -r '.runtime[] | [.image,.digest] | @tsv' "$lock")

        [[ -n "$locked_ref" ]] \
            || ci_ai_fail "Compose service $service uses first-party image $compose_image without a runtime lock entry"
        override="$(jq -c --arg service "$service" --arg image "$locked_ref" '.services[$service].image=$image' <<<"$override")"
        matched=$((matched + 1))
    done < <(jq -r '.services | to_entries[] | [.key,(.value.image // "")] | @tsv' <<<"$rendered")

    (( matched > 0 )) \
        || ci_ai_fail "Compose model contains no first-party runtime image to lock"
    printf '%s\n' "$override" >"$output"
}

ci_lock_assert_compose_runtime() {
    local override="$1"
    shift
    local -a globals=("$@")
    local rendered service cid expected actual asserted=0

    rendered="$("$real_docker" compose "${globals[@]}" -f "$override" config --format json)"
    while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        expected="$(jq -r --arg service "$service" '.services[$service].image // empty' <<<"$rendered")"
        [[ "$expected" == ghcr.io/wiki-mod/lancache-ng/*@sha256:* ]] || continue
        cid="$("$real_docker" compose "${globals[@]}" -f "$override" ps -q "$service")"
        [[ -n "$cid" ]] || ci_ai_fail "Compose service $service has no running container after up"
        actual="$("$real_docker" inspect --format '{{.Config.Image}}' "$cid")"
        [[ "$actual" == "$expected" ]] \
            || ci_ai_fail "Compose service $service runs $actual instead of locked $expected"
        asserted=$((asserted + 1))
    done < <("$real_docker" compose "${globals[@]}" -f "$override" ps --services --status running)

    (( asserted > 0 )) \
        || ci_ai_fail "Compose up produced no running first-party identity assertion"
}

ci_lock_run_compose() {
    local -a input=("$@") globals=() compose_command=()
    local override status
    ci_lock_split_compose_args input globals compose_command
    override="$(mktemp)"
    trap 'rm -f "$override"' RETURN
    ci_lock_compose_override "$override" "${globals[@]}"

    if "$real_docker" compose "${globals[@]}" -f "$override" "${compose_command[@]}"; then
        status=0
    else
        status=$?
    fi
    if (( status == 0 )) && [[ "${compose_command[0]}" == up ]]; then
        ci_lock_assert_compose_runtime "$override" "${globals[@]}"
    fi
    rm -f "$override"
    trap - RETURN
    return "$status"
}

if [[ "${1:-}" == compose ]]; then
    shift
    ci_lock_run_compose "$@"
    exit $?
fi

args=("$@")
rewritten=()
ci_lock_rewrite_direct_args args rewritten
exec "$real_docker" "${rewritten[@]}"
