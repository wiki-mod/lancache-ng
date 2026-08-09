#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Verifies that candidate/release evidence is a one-to-one proof set for every
# service/platform digest in a stack lock. A file count alone is insufficient:
# duplicate evidence for one tuple must not hide a missing different tuple.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: ci-verify-platform-evidence-set.sh STACK_LOCK EVIDENCE_DIR candidate|release" >&2
    exit 2
fi

lock="$1"
evidence_dir="$2"
mode="$3"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/ci-artifact-identity.sh
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
ci_ai_validate_stack_lock "$lock"
bash "$repo_root/scripts/ci-verify-stack-lock-catalog.sh" "$lock"

case "$mode" in
    candidate)
        schema="candidate-evidence/v1"
        pattern='*.json'
        ;;
    release)
        schema="release-evidence/v1"
        pattern='*.evidence.json'
        ;;
    *)
        ci_ai_fail "unsupported evidence mode: $mode"
        exit 2
        ;;
esac

[[ -d "$evidence_dir" ]] || ci_ai_fail "evidence directory does not exist: $evidence_dir"

if expected_text="$(
    jq -r '
      (.runtime + .tooling)
      | to_entries[]
      | .key as $service
      | .value.platforms
      | to_entries[]
      | [$service,.key,.value]
      | @tsv
    ' "$lock" | LC_ALL=C sort
)"; then
    :
else
    exit $?
fi
mapfile -t expected_rows <<<"$expected_text"
[[ "${#expected_rows[@]}" -gt 0 && -n "${expected_rows[0]}" ]] \
    || ci_ai_fail "stack lock produced no expected platform evidence tuples"

if files_text="$(find "$evidence_dir" -maxdepth 1 -type f -name "$pattern" -print | LC_ALL=C sort)"; then
    :
else
    exit $?
fi
mapfile -t evidence_files <<<"$files_text"
[[ "${#evidence_files[@]}" -eq "${#expected_rows[@]}" ]] \
    || ci_ai_fail "expected ${#expected_rows[@]} $mode evidence files, found ${#evidence_files[@]}"

declare -A seen=()
actual_rows=()
for file in "${evidence_files[@]}"; do
    [[ -n "$file" ]] || continue
    jq -e --arg schema "$schema" '
      .schema == $schema
      and (.service | type == "string" and length > 0)
      and (.platform == "linux/amd64" or .platform == "linux/arm64")
      and (.digest | test("^sha256:[0-9a-f]{64}$"))
      and .trivy == "passed"
      and .native_smoke == "passed"
    ' "$file" >/dev/null \
        || ci_ai_fail "invalid $mode evidence record: $file"
    if [[ "$mode" == release ]]; then
        jq -e '.sbom_attested == true' "$file" >/dev/null \
            || ci_ai_fail "release SBOM evidence is not attested in $file"
    fi

    service="$(jq -r '.service' "$file")"
    platform="$(jq -r '.platform' "$file")"
    digest="$(jq -r '.digest' "$file")"
    tuple="${service}"$'\t'"${platform}"
    [[ -z "${seen[$tuple]:-}" ]] \
        || ci_ai_fail "duplicate $mode evidence tuple: $service/$platform"
    seen["$tuple"]=1
    actual_rows+=("${service}"$'\t'"${platform}"$'\t'"${digest}")
done

expected_sorted="$(printf '%s\n' "${expected_rows[@]}" | LC_ALL=C sort)"
actual_sorted="$(printf '%s\n' "${actual_rows[@]}" | LC_ALL=C sort)"
[[ "$actual_sorted" == "$expected_sorted" ]] \
    || ci_ai_fail "$mode evidence tuple/digest set differs from stack lock"
