#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Proves that a stack lock contains exactly the first-party runtime/tooling
# catalog declared by release/stack-images.yml. A schema-valid extra service is
# still unsafe because promotion/release iterate lock entries; therefore extras,
# omissions, duplicate catalog names and scope drift all fail closed.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: ci-verify-stack-lock-catalog.sh STACK_LOCK" >&2
    exit 2
fi

lock="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/ci-artifact-identity.sh
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
ci_ai_validate_stack_lock "$lock"

catalog="$(bash "$repo_root/scripts/query-stack-images.sh" all)"

# The catalog itself must be unambiguous before it can authorize a lock.
catalog_count="$(jq '.include | length' <<<"$catalog")"
catalog_unique="$(jq '[.include[].service] | unique | length' <<<"$catalog")"
[[ "$catalog_count" -eq "$catalog_unique" ]] \
    || ci_ai_fail "canonical image catalog contains duplicate service names"

expected_runtime="$(jq -cS '[.include[] | select(.scope == "runtime") | .service] | sort' <<<"$catalog")"
expected_tooling="$(jq -cS '[.include[] | select(.scope == "tooling") | .service] | sort' <<<"$catalog")"
actual_runtime="$(jq -cS '.runtime | keys | sort' "$lock")"
actual_tooling="$(jq -cS '.tooling | keys | sort' "$lock")"

[[ "$actual_runtime" == "$expected_runtime" ]] \
    || ci_ai_fail "stack lock runtime service set differs from canonical catalog: expected $expected_runtime, got $actual_runtime"
[[ "$actual_tooling" == "$expected_tooling" ]] \
    || ci_ai_fail "stack lock tooling service set differs from canonical catalog: expected $expected_tooling, got $actual_tooling"

# Keys alone are insufficient: each lock entry must also retain the image and
# scope declared for that canonical service.
while IFS=$'\t' read -r scope service expected_image; do
    [[ -n "$service" ]] || continue
    case "$scope" in
        runtime) actual_image="$(jq -r --arg service "$service" '.runtime[$service].image // empty' "$lock")" ;;
        tooling) actual_image="$(jq -r --arg service "$service" '.tooling[$service].image // empty' "$lock")" ;;
        *) ci_ai_fail "unsupported canonical scope for $service: $scope"; exit 1 ;;
    esac
    [[ "$actual_image" == "$expected_image" ]] \
        || ci_ai_fail "stack lock image for $service differs from canonical catalog: expected $expected_image, got ${actual_image:-<empty>}"
done < <(jq -r '.include[] | [.scope,.service,.image] | @tsv' <<<"$catalog")
