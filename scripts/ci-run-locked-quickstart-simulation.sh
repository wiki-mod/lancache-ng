#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Runs the existing quickstart/syslog end-to-end simulation with an additional
# final Compose override generated from one immutable stack lock. The existing
# simulation remains the behavioral authority; this wrapper changes only how
# its first-party images are resolved. Every docker compose invocation made by
# the sourced simulation gets a last-wins image override for the currently
# active Compose model, and every successful `compose up` is followed by a
# .Config.Image assertion against that digest-qualified rendered model.
set -euo pipefail

[[ $# -eq 1 ]] || {
    echo "usage: ci-run-locked-quickstart-simulation.sh STACK_LOCK" >&2
    exit 2
}

lock="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/ci-artifact-identity.sh
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
ci_ai_validate_stack_lock "$lock"

CI_LOCKED_QUICKSTART_OVERRIDE="$(mktemp)"
CI_LOCKED_QUICKSTART_OVERRIDE_READY=false
CI_LOCKED_QUICKSTART_ASSERTIONS=0

# Split docker-compose global options from the compose subcommand. The current
# simulation uses only these value-bearing global options. Unknown flag-shaped
# options are preserved as no-value flags; an unknown non-flag becomes the
# subcommand and is passed through unchanged.
ci_locked_quickstart_split_compose_args() {
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

ci_locked_quickstart_build_override() {
    local -a globals=("$@")
    local resolved override service compose_image locked_image locked_digest locked_ref
    local matched=0

    resolved="$(command docker compose "${globals[@]}" config --format json)" \
        || return 1
    override='{"services":{}}'

    while IFS=$'\t' read -r service compose_image; do
        [[ -n "$service" && -n "$compose_image" ]] || continue
        [[ "$compose_image" == ghcr.io/wiki-mod/lancache-ng/* ]] || continue

        locked_ref=""
        while IFS=$'\t' read -r locked_image locked_digest; do
            if [[ "$compose_image" == "$locked_image" \
                || "$compose_image" == "${locked_image}:"* \
                || "$compose_image" == "${locked_image}@"* ]]; then
                ci_ai_require_digest "$locked_digest"
                locked_ref="${locked_image}@${locked_digest}"
                break
            fi
        done < <(jq -r '.runtime[] | [.image, .digest] | @tsv' "$lock")

        [[ -n "$locked_ref" ]] \
            || ci_ai_fail "quickstart service $service uses first-party image $compose_image without a runtime lock entry"
        override="$(jq -c --arg service "$service" --arg image "$locked_ref" '.services[$service].image = $image' <<<"$override")"
        matched=$((matched + 1))
    done < <(jq -r '.services | to_entries[] | [.key, (.value.image // "")] | @tsv' <<<"$resolved")

    (( matched > 0 )) \
        || ci_ai_fail "quickstart compose model contained no first-party runtime images"

    printf '%s\n' "$override" >"$CI_LOCKED_QUICKSTART_OVERRIDE"
    CI_LOCKED_QUICKSTART_OVERRIDE_READY=true
}

ci_locked_quickstart_assert_running_images() {
    local -a globals=("$@")
    local rendered service cid expected actual asserted=0

    rendered="$(command docker compose "${globals[@]}" -f "$CI_LOCKED_QUICKSTART_OVERRIDE" config --format json)"
    while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        expected="$(jq -r --arg service "$service" '.services[$service].image // empty' <<<"$rendered")"
        [[ "$expected" == ghcr.io/wiki-mod/lancache-ng/*@sha256:* ]] || continue

        cid="$(command docker compose "${globals[@]}" -f "$CI_LOCKED_QUICKSTART_OVERRIDE" ps -q "$service")"
        [[ -n "$cid" ]] || ci_ai_fail "locked quickstart service $service has no running container after compose up"
        actual="$(command docker inspect --format '{{.Config.Image}}' "$cid")"
        [[ "$actual" == "$expected" ]] \
            || ci_ai_fail "quickstart service $service started $actual instead of locked $expected"
        asserted=$((asserted + 1))
    done < <(command docker compose "${globals[@]}" -f "$CI_LOCKED_QUICKSTART_OVERRIDE" ps --services --status running)

    (( asserted > 0 )) \
        || ci_ai_fail "compose up produced no running first-party service whose digest identity could be asserted"
    CI_LOCKED_QUICKSTART_ASSERTIONS=$((CI_LOCKED_QUICKSTART_ASSERTIONS + asserted))
}

# The behavioral script performs ordinary docker operations as well as Compose
# operations. Only Compose is rewritten. The final -f override is inserted
# immediately before the subcommand, after every file/profile supplied by the
# original script, so its image values win without changing networks,
# environment, or profile selection.
docker() {
    if [[ "${1:-}" != compose ]]; then
        command docker "$@"
        return
    fi

    shift
    local -a input=("$@") globals=() compose_command=()
    local status
    ci_locked_quickstart_split_compose_args input globals compose_command

    # Re-render for every Compose invocation instead of freezing the first
    # profile set seen by `pull`. The simulation later enables ssl/logging/
    # dhcp profiles before `up`; rebuilding here guarantees newly active
    # first-party services also receive digest-qualified image references.
    # If an already-failing cleanup path is no longer renderable, retain the
    # last successfully generated override. The first real render must always
    # succeed, otherwise no unpinned Compose command is allowed to proceed.
    if ! ci_locked_quickstart_build_override "${globals[@]}"; then
        if [[ "$CI_LOCKED_QUICKSTART_OVERRIDE_READY" != true ]]; then
            return 1
        fi
    fi

    if command docker compose "${globals[@]}" -f "$CI_LOCKED_QUICKSTART_OVERRIDE" "${compose_command[@]}"; then
        status=0
    else
        status=$?
    fi

    if (( status == 0 )) && [[ "${compose_command[0]}" == up ]]; then
        ci_locked_quickstart_assert_running_images "${globals[@]}"
    fi
    return "$status"
}

# The original simulation uses a digest-qualified build-tools container supplied
# by the caller and exercises setup.sh with a unique transport tag. The wrapper
# affects only the containers started by the simulation after setup has rendered
# the quickstart installation.
# shellcheck source=scripts/syslog-forwarding-simulation.sh
source "$repo_root/scripts/syslog-forwarding-simulation.sh"

[[ "$CI_LOCKED_QUICKSTART_OVERRIDE_READY" == true ]] \
    || ci_ai_fail "quickstart simulation never reached a renderable Compose invocation"
(( CI_LOCKED_QUICKSTART_ASSERTIONS > 0 )) \
    || ci_ai_fail "quickstart simulation never proved a running first-party digest identity"

printf 'Quickstart deep validation asserted %d locked first-party container identities.\n' \
    "$CI_LOCKED_QUICKSTART_ASSERTIONS"
