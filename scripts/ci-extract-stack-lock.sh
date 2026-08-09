#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Extracts a stack lock only from a positively accepted, reusable stack-pointer
# image. Existence of a package/tag alone is never treated as acceptance
# evidence. The input tag is first frozen to its exact OCI digest, then the
# embedded record/hash relationship, protected-branch reuse policy, and the
# GitHub-signed final-acceptance predicate are all verified before any lock is
# returned to a caller.
set -euo pipefail

if [[ $# -ne 2 && $# -ne 3 ]]; then
    echo "usage: ci-extract-stack-lock.sh STACK_REF OUTPUT [DIGEST_OUTPUT]" >&2
    exit 2
fi
stack_ref="$1"
output="$2"
digest_output="${3:-}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
source "$repo_root/scripts/lib/ghcr-retry.sh"

case "$stack_ref" in
  ghcr.io/wiki-mod/lancache-ng/stack@sha256:*)
    image_name="${stack_ref%@*}"
    stack_digest="${stack_ref#*@}"
    ci_ai_require_digest "$stack_digest"
    ;;
  ghcr.io/wiki-mod/lancache-ng/stack:*)
    image_name="${stack_ref%:*}"
    stack_digest="$(ci_ai_ref_digest "$stack_ref")"
    ;;
  *)
    ci_ai_fail "unsupported stack pointer reference: $stack_ref"
    ;;
esac

frozen_ref="${image_name}@${stack_digest}"
ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- docker pull "$frozen_ref" >/dev/null
cid="$(docker create "$frozen_ref")"
work_dir="$(mktemp -d)"
cleanup() {
    docker rm -f "$cid" >/dev/null 2>&1 || true
    rm -rf "$work_dir"
}
trap cleanup EXIT

docker cp "$cid:/stack-lock.json" "$work_dir/stack-lock.json"
docker cp "$cid:/acceptance.json" "$work_dir/acceptance.json"
ci_ai_validate_stack_lock "$work_dir/stack-lock.json"
ci_ai_validate_reusable_acceptance "$work_dir/acceptance.json"

expected_hash="$(jq -r '.stack_lock_sha256' "$work_dir/acceptance.json")"
actual_hash="$(sha256sum "$work_dir/stack-lock.json" | awk '{print $1}')"
[[ "$actual_hash" == "$expected_hash" ]] || ci_ai_fail "stack lock hash does not match acceptance record"
[[ "$(jq -r '.source_sha' "$work_dir/stack-lock.json")" == "$(jq -r '.source_sha' "$work_dir/acceptance.json")" ]] \
    || ci_ai_fail "stack lock and acceptance source SHA differ"

# This is the cryptographic trust boundary: a self-consistent JSON record can
# still be forged by anyone able to replace a package tag. Verify the custom
# predicate against GitHub's attestation trust root, pin the signer workflow,
# source branch and source commit, and require the signed predicate to equal
# the embedded acceptance.json before exposing the lock to the caller.
bash "$repo_root/scripts/ci-verify-acceptance-attestation.sh" \
  "$frozen_ref" "$work_dir/acceptance.json"

mkdir -p "$(dirname "$output")"
cp "$work_dir/stack-lock.json" "$output"
if [[ -n "$digest_output" ]]; then
    mkdir -p "$(dirname "$digest_output")"
    printf '%s\n' "$stack_digest" >"$digest_output"
fi
