#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Extracts a stack lock only from a positively accepted stack-pointer image.
# Existence of a package/tag alone is never treated as acceptance evidence.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: ci-extract-stack-lock.sh STACK_REF OUTPUT" >&2; exit 2; }
stack_ref="$1"; output="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
source "$repo_root/scripts/lib/ghcr-retry.sh"

ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- docker pull "$stack_ref" >/dev/null
cid="$(docker create "$stack_ref")"
work_dir="$(mktemp -d)"
cleanup() {
    docker rm -f "$cid" >/dev/null 2>&1 || true
    rm -rf "$work_dir"
}
trap cleanup EXIT

docker cp "$cid:/stack-lock.json" "$work_dir/stack-lock.json"
docker cp "$cid:/acceptance.json" "$work_dir/acceptance.json"
ci_ai_validate_stack_lock "$work_dir/stack-lock.json"
ci_ai_validate_acceptance "$work_dir/acceptance.json"

expected_hash="$(jq -r '.stack_lock_sha256' "$work_dir/acceptance.json")"
actual_hash="$(sha256sum "$work_dir/stack-lock.json" | awk '{print $1}')"
[[ "$actual_hash" == "$expected_hash" ]] || ci_ai_fail "stack lock hash does not match acceptance record"
[[ "$(jq -r '.source_sha' "$work_dir/stack-lock.json")" == "$(jq -r '.source_sha' "$work_dir/acceptance.json")" ]] \
    || ci_ai_fail "stack lock and acceptance source SHA differ"

mkdir -p "$(dirname "$output")"
cp "$work_dir/stack-lock.json" "$output"
