#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Docker CLI boundary for exact-identity validation. The reusable simulation
# suite deliberately keeps its existing behavioral scripts; this shim changes
# only how first-party image references reach Docker. Every direct first-party
# image reference must resolve to the digest recorded in the stack lock, and
# every Compose model is overlaid with those same runtime digests.
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
    if [[ -z "$candidate" || ! -x "$candidate" || "$candidate" == "$shim_dir/docker" ]]; then
        ci_ai_fail "could not locate the real Docker CLI outside $shim_dir"
        return 1
    fi
    printf '%s\n' "$candidate"
}

if real_docker="$(ci_lock_real_docker)"; then
    :
else
    exit $?
fi
if candidate_tag="$(jq -r '.candidate_tag' "$lock")"; then
    :
else
    exit $?
fi
if [[ -z "$candidate_tag" ]]; then
    ci_ai_fail "stack lock has no candidate tag"
    exit 1
fi

ci_lock_expected_digest() {
    local image="$1" digest count
    if digest="$(jq -r --arg image "$image" '[((.runtime + .tooling)[] | select(.image == $image) | .digest)] | .[]' "$lock")"; then
        :
    else
        return $?
    fi
    count="$(printf '%s\n' "$digest" | sed '/^$/d' | wc -l | tr -d ' ')"
    [[ "$count" == 1 ]] || return 1
    ci_ai_require_digest "$digest" || return 1
    printf '%s\n' "$digest"
}

ci_lock_rewrite_first_party_ref() {
    local ref="$1" image supplied expected tag
    [[ "$ref" == ghcr.io/wiki-mod/lancache-ng/* ]] || return 2

    if [[ "$ref" == *@sha256:* ]]; then
        image="${ref%@*}"
        supplied="${ref#*@}"
        if expected="$(ci_lock_expected_digest "$image")"; then
            :
        else
            ci_ai_fail "first-party digest reference is not present in the stack lock: $ref"
            return 1
        fi
        if [[ "$supplied" != "$expected" ]]; then
            ci_ai_fail "first-party digest differs from stack lock for $image: expected $expected, got $supplied"
            return 1
        fi
        printf '%s@%s\n' "$image" "$expected"
        return 0
    fi

    # ghcr.io has no port component here, so the final colon unambiguously
    # separates an image name from its tag. Unqualified first-party names are
    # rejected rather than allowing Docker's implicit `latest` to enter a
    # stack-lock validation run.
    if [[ "$ref" != *:* ]]; then
        ci_ai_fail "unqualified first-party image is forbidden under stack lock: $ref"
        return 1
    fi
    image="${ref%:*}"
    tag="${ref##*:}"
    if expected="$(ci_lock_expected_digest "$image")"; then
        :
    else
        ci_ai_fail "first-party tagged reference is not present in the stack lock: $ref"
        return 1
    fi
    if [[ "$tag" != "$candidate_tag" ]]; then
        ci_ai_fail "mutable first-party tag is forbidden under stack lock: $ref"
        return 1
    fi
    printf '%s@%s\n' "$image" "$expected"
}

ci_lock_rewrite_direct_args() {
    local -n input_ref=$1
    local -n output_ref=$2
    local arg locked status
    output_ref=()
    for arg in "${input_ref[@]}"; do
        if locked="$(ci_lock_rewrite_first_party_ref "$arg")"; then
            output_ref+=("$locked")
            continue
        else
            status=$?
        fi
        if (( status == 2 )); then
            output_ref+=("$arg")
            continue
        fi
        return "$status"
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
                if (( i + 1 >= ${#input_ref[@]} )); then
                    ci_ai_fail "docker compose option $arg is missing its value"
                    return 1
                fi
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
    if (( ${#command_ref[@]} == 0 )); then
        ci_ai_fail "docker compose invocation has no subcommand"
        return 1
    fi
}

ci_lock_compose_override() {
    local output="$1"
    shift
    local -a globals=("$@")
    local rendered override compose_rows service compose_image image digest locked_ref status
    local matched=0

    if rendered="$("$real_docker" compose "${globals[@]}" config --format json)"; then
        :
    else
        status=$?
        echo "ci-artifact-identity: could not render Compose model before applying stack lock (exit $status)" >&2
        return "$status"
    fi
    if compose_rows="$(jq -r '.services | to_entries[] | [.key,(.value.image // "")] | @tsv' <<<"$rendered")"; then
        :
    else
        return $?
    fi
    override='{"services":{}}'

    while IFS=$'\t' read -r service compose_image; do
        [[ -n "$service" && -n "$compose_image" ]] || continue
        [[ "$compose_image" == ghcr.io/wiki-mod/lancache-ng/* ]] || continue

        locked_ref=""
        while IFS=$'\t' read -r image digest; do
            if [[ "$compose_image" == "$image" \
                || "$compose_image" == "${image}:"* \
                || "$compose_image" == "${image}@"* ]]; then
                ci_ai_require_digest "$digest" || return 1
                locked_ref="${image}@${digest}"
                break
            fi
        done < <(jq -r '.runtime[] | [.image,.digest] | @tsv' "$lock")

        if [[ -z "$locked_ref" ]]; then
            ci_ai_fail "Compose service $service uses first-party image $compose_image without a runtime lock entry"
            return 1
        fi
        if override="$(jq -c --arg service "$service" --arg image "$locked_ref" '.services[$service].image=$image' <<<"$override")"; then
            :
        else
            return $?
        fi
        matched=$((matched + 1))
    done <<<"$compose_rows"

    if (( matched == 0 )); then
        ci_ai_fail "Compose model contains no first-party runtime image to lock"
        return 1
    fi
    printf '%s\n' "$override" >"$output"
}

ci_lock_assert_compose_runtime() {
    local override="$1"
    shift
    local -a globals=("$@")
    local rendered running_services service cid expected actual status asserted=0

    if rendered="$("$real_docker" compose "${globals[@]}" -f "$override" config --format json)"; then
        :
    else
        return $?
    fi
    if running_services="$("$real_docker" compose "${globals[@]}" -f "$override" ps --services --status running)"; then
        :
    else
        return $?
    fi

    while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        if expected="$(jq -r --arg service "$service" '.services[$service].image // empty' <<<"$rendered")"; then
            :
        else
            return $?
        fi
        [[ "$expected" == ghcr.io/wiki-mod/lancache-ng/*@sha256:* ]] || continue

        if cid="$("$real_docker" compose "${globals[@]}" -f "$override" ps -q "$service")"; then
            :
        else
            status=$?
            return "$status"
        fi
        if [[ -z "$cid" ]]; then
            ci_ai_fail "Compose service $service has no running container after up"
            return 1
        fi
        if actual="$("$real_docker" inspect --format '{{.Config.Image}}' "$cid")"; then
            :
        else
            status=$?
            return "$status"
        fi
        if [[ "$actual" != "$expected" ]]; then
            ci_ai_fail "Compose service $service runs $actual instead of locked $expected"
            return 1
        fi
        asserted=$((asserted + 1))
    done <<<"$running_services"

    if (( asserted == 0 )); then
        ci_ai_fail "Compose up produced no running first-party identity assertion"
        return 1
    fi
}

ci_lock_run_compose() {
    # shellcheck disable=SC2034 -- consumed through nameref by ci_lock_split_compose_args.
    local -a input=("$@") globals=() compose_command=()
    local override status

    if ci_lock_split_compose_args input globals compose_command; then
        :
    else
        return $?
    fi
    if override="$(mktemp)"; then
        :
    else
        return $?
    fi

    if ci_lock_compose_override "$override" "${globals[@]}"; then
        :
    else
        status=$?
        rm -f "$override"
        return "$status"
    fi

    if "$real_docker" compose "${globals[@]}" -f "$override" "${compose_command[@]}"; then
        status=0
    else
        status=$?
    fi
    if (( status == 0 )) && [[ "${compose_command[0]}" == up ]]; then
        if ci_lock_assert_compose_runtime "$override" "${globals[@]}"; then
            :
        else
            status=$?
        fi
    fi
    rm -f "$override"
    return "$status"
}

if [[ "${1:-}" == compose ]]; then
    shift
    if ci_lock_run_compose "$@"; then
        exit 0
    else
        exit $?
    fi
fi

# shellcheck disable=SC2034 -- consumed through nameref by ci_lock_rewrite_direct_args.
args=("$@")
rewritten=()
if ci_lock_rewrite_direct_args args rewritten; then
    :
else
    exit $?
fi
exec "$real_docker" "${rewritten[@]}"
