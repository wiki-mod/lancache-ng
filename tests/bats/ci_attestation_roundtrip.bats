#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ACTION="$REPO_ROOT/.github/actions/ghcr-custom-attest-retry/action.yml"
}

@test "custom attestation wrapper roundtrips both final acceptance predicate types" {
  run grep -F "inputs.predicate-type == 'https://wiki-mod.github.io/lancache-ng/attestations/acceptance/v1'" "$ACTION"
  [ "$status" -eq 0 ]
  run grep -F "inputs.predicate-type == 'https://wiki-mod.github.io/lancache-ng/attestations/release/v1'" "$ACTION"
  [ "$status" -eq 0 ]
  run grep -F -- '--signer-workflow "$signer_workflow"' "$ACTION"
  [ "$status" -eq 0 ]
  run grep -F -- '--source-ref "$GITHUB_REF"' "$ACTION"
  [ "$status" -eq 0 ]
  run grep -F -- '--source-digest "$GITHUB_SHA"' "$ACTION"
  [ "$status" -eq 0 ]
  run grep -F 'any(.[]; .verificationResult.statement.predicate == $expected)' "$ACTION"
  [ "$status" -eq 0 ]
}

@test "security-smoke custom predicates are not forced through final-acceptance roundtrip branch" {
  run grep -F "inputs.predicate-type == 'https://wiki-mod.github.io/lancache-ng/attestations/security-smoke/v1'" "$ACTION"
  [ "$status" -ne 0 ]
}
