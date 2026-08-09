#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Verifies that an evidence directory is an exact one-to-one representation of
# every service/platform child digest in a stack lock. Count-only checks are not
# sufficient: duplicated evidence for one child must never hide a missing child.
set -euo pipefail

[[ $# -eq 3 ]] || {
    echo "usage: ci-verify-platform-evidence.sh LOCK EVIDENCE_DIR candidate|release" >&2
    exit 2
}
lock="$1"
evidence_dir="$2"
mode="$3"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"

ci_ai_validate_stack_lock "$lock"
[[ -d "$evidence_dir" ]] || ci_ai_fail "evidence directory does not exist: $evidence_dir"
case "$mode" in
    candidate)
        schema="candidate-evidence/v1"
        suffix=".json"
        ;;
    release)
        schema="release-evidence/v1"
        suffix=".evidence.json"
        ;;
    *)
        ci_ai_fail "unsupported evidence mode: $mode"
        ;;
esac

work_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT
expected_file="$work_dir/expected.tsv"
observed_file="$work_dir/observed.tsv"
: >"$expected_file"
: >"$observed_file"

while IFS=$'\t' read -r service platform digest; do
    [[ -n "$service" && -n "$platform" && -n "$digest" ]] \
        || ci_ai_fail "stack lock produced an incomplete expected evidence tuple"
    ci_ai_require_digest "$digest"
    printf '%s\t%s\t%s\n' "$service" "$platform" "$digest" >>"$expected_file"
done < <(
    jq -r '
      (.runtime + .tooling)
      | to_entries[]
      | .key as $service
      | .value.platforms
      | to_entries[]
      | [$service, .key, .value]
      | @tsv
    ' "$lock" | sort
)

mapfile -t files < <(find "$evidence_dir" -maxdepth 1 -type f -name "*${suffix}" -print | sort)
[[ "${#files[@]}" -gt 0 ]] || ci_ai_fail "no $mode evidence files found in $evidence_dir"

for file in "${files[@]}"; do
    [[ "$(jq -r '.schema // empty' "$file")" == "$schema" ]] \
        || ci_ai_fail "unexpected evidence schema in $file"
    service="$(jq -r '.service // empty' "$file")"
    platform="$(jq -r '.platform // empty' "$file")"
    digest="$(jq -r '.digest // empty' "$file")"
    [[ -n "$service" ]] || ci_ai_fail "evidence has no service in $file"
    arch="$(ci_ai_arch_from_platform "$platform")" || ci_ai_fail "evidence has invalid platform in $file"
    ci_ai_require_digest "$digest"

    expected_basename="${service}__${arch}${suffix}"
    [[ "$(basename "$file")" == "$expected_basename" ]] \
        || ci_ai_fail "evidence filename does not match its identity: $file"
    [[ "$(jq -r '.trivy // empty' "$file")" == passed ]] \
        || ci_ai_fail "Trivy evidence is not passed in $file"
    [[ "$(jq -r '.native_smoke // empty' "$file")" == passed ]] \
        || ci_ai_fail "native smoke evidence is not passed in $file"
    if [[ "$mode" == release ]]; then
        [[ "$(jq -r '.sbom_attested // false' "$file")" == true ]] \
            || ci_ai_fail "release SBOM evidence is not attested in $file"
    fi

    printf '%s\t%s\t%s\n' "$service" "$platform" "$digest" >>"$observed_file"
done

sort -o "$observed_file" "$observed_file"
if ! cmp -s "$expected_file" "$observed_file"; then
    echo "::error::Platform evidence is not an exact one-to-one match for the stack lock." >&2
    echo "::group::Expected platform evidence tuples" >&2
    cat "$expected_file" >&2
    echo "::endgroup::" >&2
    echo "::group::Observed platform evidence tuples" >&2
    cat "$observed_file" >&2
    echo "::endgroup::" >&2
    exit 1
fi
