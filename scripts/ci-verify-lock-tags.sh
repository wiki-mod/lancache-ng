#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Re-resolves every candidate transport tag immediately before acceptance.
# A tag move after testing therefore fails acceptance instead of silently
# changing what the workflow claims to have validated. When the acceptance
# job has already downloaded platform evidence beside the lock, this boundary
# also proves that evidence is an exact one-to-one copy of the lock matrix.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: ci-verify-lock-tags.sh STACK_LOCK" >&2; exit 2; }
lock="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
ci_ai_validate_stack_lock "$lock"

lock_dir="$(cd "$(dirname "$lock")" && pwd)"
lock_parent="$(cd "$lock_dir/.." && pwd)"
release_evidence_dir="$lock_dir/evidence"
candidate_evidence_dir="$lock_parent/evidence"

# Release publish downloads `release-lock.json` and `release/evidence/` into
# the same directory tree. Candidate acceptance downloads `stack-lock.json`
# under `stack-lock/` and its evidence under the parent workspace `evidence/`.
# Other callers use the same tag guard before runtime simulations but do not
# download evidence, so they correctly skip this acceptance-only extension.
if [[ -d "$release_evidence_dir" ]]; then
    shopt -s nullglob
    release_evidence_files=("$release_evidence_dir"/*.evidence.json)
    shopt -u nullglob
    if (( ${#release_evidence_files[@]} > 0 )); then
        bash "$repo_root/scripts/ci-verify-platform-evidence.sh" \
            "$lock" "$release_evidence_dir" release
    fi
fi

if [[ -d "$candidate_evidence_dir" ]]; then
    shopt -s nullglob
    candidate_evidence_files=("$candidate_evidence_dir"/*.json)
    shopt -u nullglob
    candidate_evidence_found=false
    for file in "${candidate_evidence_files[@]}"; do
        if jq -e '.schema == "candidate-evidence/v1"' "$file" >/dev/null 2>&1; then
            candidate_evidence_found=true
            break
        fi
    done
    if [[ "$candidate_evidence_found" == true ]]; then
        bash "$repo_root/scripts/ci-verify-platform-evidence.sh" \
            "$lock" "$candidate_evidence_dir" candidate
    fi
fi

while IFS=$'\t' read -r image digest candidate_ref; do
    ci_ai_require_digest "$digest"
    [[ -n "$candidate_ref" ]] || ci_ai_fail "lock entry for $image has no candidate_ref"
    actual="$(ci_ai_ref_digest "$candidate_ref")"
    [[ "$actual" == "$digest" ]] || ci_ai_fail "$candidate_ref moved: expected $digest, got $actual"
done < <(jq -r '(.runtime + .tooling)[] | [.image, .digest, .candidate_ref] | @tsv' "$lock")
