#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Exact-digest full-stack gate. The outer invocation reserves a collision-free
# validation subnet. The inner invocation starts only the digest-rendered
# Compose model, verifies the running containers retained those exact refs, and
# executes the existing client simulation against that same rendered file.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: ci-validate-locked-stack.sh STACK_LOCK" >&2; exit 2; }
lock="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
ci_ai_validate_stack_lock "$lock"

if [[ "${CI_LOCKED_STACK_INNER:-false}" != true ]]; then
    exec bash "$repo_root/scripts/lib/run-in-validation-subnet.sh" \
      env CI_LOCKED_STACK_INNER=true bash "$0" "$lock"
fi

work_dir="$(mktemp -d)"
rendered="$work_dir/locked-compose.yml"
"$repo_root/scripts/ci-render-locked-compose.sh" "$lock" "$rendered"
compose=(docker compose -f "$rendered")
project_name="${COMPOSE_PROJECT_NAME:?COMPOSE_PROJECT_NAME is required from validation subnet reservation}"

cleanup() {
    local status=$?
    timeout --kill-after=30 180 "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

timeout --kill-after=30 600 "${compose[@]}" pull --quiet
timeout --kill-after=30 300 "${compose[@]}" up -d

# `config --services` also describes profile-gated services that a plain
# `compose up -d` did not start. Query the real compose project after bring-up
# so the health loop cannot wait forever for an intentionally inactive profile.
mapfile -t active_services < <("${compose[@]}" ps --services)
[[ "${#active_services[@]}" -gt 0 ]] || ci_ai_fail "compose started no services"

rendered_json="$("${compose[@]}" config --format json)"
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
    all_ready=true
    for service in "${active_services[@]}"; do
        if ! cid="$("${compose[@]}" ps -q "$service")"; then
            echo "::error::Could not resolve container id for $service." >&2
            exit 1
        fi
        [[ -n "$cid" ]] || { all_ready=false; continue; }
        state="$(docker inspect --format '{{.State.Status}}' "$cid")"
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
        if [[ "$state" != running || ( "$health" != none && "$health" != healthy ) ]]; then
            all_ready=false
        fi
    done
    [[ "$all_ready" == true ]] && break
    sleep 5
done

for service in "${active_services[@]}"; do
    cid="$("${compose[@]}" ps -q "$service")"
    [[ -n "$cid" ]] || ci_ai_fail "$service has no running container"
    state="$(docker inspect --format '{{.State.Status}}' "$cid")"
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
    [[ "$state" == running ]] || ci_ai_fail "$service is not running (state=$state)"
    [[ "$health" == none || "$health" == healthy ]] || ci_ai_fail "$service is not healthy (health=$health)"

    expected_ref="$(jq -r --arg service "$service" '.services[$service].image // empty' <<<"$rendered_json")"
    if [[ "$expected_ref" == ghcr.io/wiki-mod/lancache-ng/*@sha256:* ]]; then
        actual_ref="$(docker inspect --format '{{.Config.Image}}' "$cid")"
        [[ "$actual_ref" == "$expected_ref" ]] \
            || ci_ai_fail "$service running image ref differs from locked ref: expected $expected_ref, got $actual_ref"
    fi
done

build_tools_image="$(jq -r '.tooling["build-tools"] | .image + "@" + .digest' "$lock")"
[[ "$build_tools_image" == *@sha256:* ]] || ci_ai_fail "stack lock has no digest-qualified build-tools image"

FULL_SETUP_COMPOSE_FILE="$rendered" \
FULL_SETUP_CLIENT_TOOLS_IMAGE="$build_tools_image" \
timeout --kill-after=30 600 bash "$repo_root/scripts/full-setup-client-simulation.sh"

echo "Exact locked-stack validation passed for project $project_name."
