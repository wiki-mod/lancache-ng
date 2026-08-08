#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Verifies the custom final-acceptance attestation for one digest-qualified
# stack-pointer image. The verifier is checksum-pinned by
# ci-install-gh-attestation-verifier.sh. Verification is restricted to this
# repository, the final-acceptance predicate type, and the workflow that is
# allowed to sign candidate acceptance. The signed predicate must also equal
# the acceptance.json embedded in the stack pointer byte-for-byte as JSON data
# after canonical jq parsing; merely finding some valid attestation for the
# same digest is not sufficient.
set -euo pipefail

[[ $# -eq 2 ]] || {
  echo "usage: ci-verify-acceptance-attestation.sh DIGEST_QUALIFIED_STACK_REF ACCEPTANCE_JSON" >&2
  exit 2
}
stack_ref="$1"
acceptance_file="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ "$stack_ref" =~ ^ghcr\.io/wiki-mod/lancache-ng/stack@sha256:[0-9a-f]{64}$ ]] || {
  echo "ci-verify-acceptance-attestation: stack ref is not the expected digest-qualified GHCR stack image: $stack_ref" >&2
  exit 1
}
[[ -f "$acceptance_file" ]] || {
  echo "ci-verify-acceptance-attestation: acceptance record not found: $acceptance_file" >&2
  exit 1
}

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
gh_bin="$(bash "$repo_root/scripts/ci-install-gh-attestation-verifier.sh" "$work_dir/gh")"

verification_json="$work_dir/verification.json"
"$gh_bin" attestation verify "oci://${stack_ref}" \
  --repo wiki-mod/lancache-ng \
  --predicate-type https://wiki-mod.github.io/lancache-ng/attestations/acceptance/v1 \
  --signer-workflow wiki-mod/lancache-ng/.github/workflows/ci-artifact-v2.yml \
  --bundle-from-oci \
  --format json >"$verification_json"

expected="$(jq -cS '.' "$acceptance_file")"
if ! jq -e --argjson expected "$expected" '
  length > 0
  and any(.[]; .verificationResult.statement.predicate == $expected)
' "$verification_json" >/dev/null; then
  echo "ci-verify-acceptance-attestation: no cryptographically verified acceptance predicate exactly matches embedded acceptance.json" >&2
  exit 1
fi

printf 'Verified final acceptance attestation for %s\n' "$stack_ref"
