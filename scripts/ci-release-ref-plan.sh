#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Emits the complete immutable OCI release reference plan. Runtime/tooling
# package refs are listed first and the coherent stack pointer is deliberately
# last, making the stack ref the publication commit point.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: ci-release-ref-plan.sh RELEASE_LOCK RELEASE_TAG STACK_DIGEST" >&2
    exit 2
fi

lock="$1"
release_tag="$2"
stack_digest="$3"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/ci-artifact-identity.sh
source "$repo_root/scripts/lib/ci-artifact-identity.sh"

ci_ai_validate_stack_lock "$lock"
ci_ai_require_digest "$stack_digest"
[[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] \
    || ci_ai_fail "invalid immutable release tag: $release_tag"

# A release lock created by ci-assemble-release-lock.sh must identify the same
# release tag requested for publication. This prevents a valid lock for one
# release from being replayed under a different immutable version label.
[[ "$(jq -r '.release.tag // empty' "$lock")" == "$release_tag" ]] \
    || ci_ai_fail "release lock tag does not match requested release tag"

mapfile -t rows < <(
    jq -r --arg tag "$release_tag" '
      (.runtime + .tooling)
      | to_entries
      | sort_by(.key)
      | .[]
      | [.value.image + ":" + $tag, .value.digest]
      | @tsv
    ' "$lock"
)

[[ "${#rows[@]}" -gt 0 ]] || ci_ai_fail "release lock contains no publishable runtime/tooling refs"

declare -A seen=()
for row in "${rows[@]}"; do
    IFS=$'\t' read -r target digest <<<"$row"
    [[ "$target" == ghcr.io/wiki-mod/lancache-ng/*:"$release_tag" ]] \
        || ci_ai_fail "unexpected release target: $target"
    ci_ai_require_digest "$digest"
    [[ -z "${seen[$target]:-}" ]] || ci_ai_fail "duplicate release target: $target"
    seen["$target"]=1
    printf '%s\t%s\n' "$target" "$digest"
done

stack_target="ghcr.io/wiki-mod/lancache-ng/stack:${release_tag}"
[[ -z "${seen[$stack_target]:-}" ]] || ci_ai_fail "stack release target collides with runtime/tooling plan"
printf '%s\t%s\n' "$stack_target" "$stack_digest"
