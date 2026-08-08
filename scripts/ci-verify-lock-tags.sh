#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Re-resolves every candidate transport tag immediately before acceptance.
# A tag move after testing therefore fails acceptance instead of silently
# changing what the workflow claims to have validated.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: ci-verify-lock-tags.sh STACK_LOCK" >&2; exit 2; }
lock="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
ci_ai_validate_stack_lock "$lock"

while IFS=$'\t' read -r image digest candidate_ref; do
    ci_ai_require_digest "$digest"
    [[ -n "$candidate_ref" ]] || ci_ai_fail "lock entry for $image has no candidate_ref"
    actual="$(ci_ai_ref_digest "$candidate_ref")"
    [[ "$actual" == "$digest" ]] || ci_ai_fail "$candidate_ref moved: expected $digest, got $actual"
done < <(jq -r '(.runtime + .tooling)[] | [.image, .digest, .candidate_ref] | @tsv' "$lock")
