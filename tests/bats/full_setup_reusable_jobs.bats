#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# The reusable full-setup workflow intentionally centralizes repeated setup
# logic. This guard keeps that deduplication from silently deleting a mature
# simulation job while still allowing new jobs to be added without maintaining
# another exact-count constant.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/full-setup-sims.yml"
}

@test "reusable full-setup suite retains every established simulation job" {
  required_jobs=(
    compute-validation-network
    full-setup-validate
    ssl-mitm-cache-simulation
    proxy-deep-wildcard-tls-simulation
    proxy-standard-mode-sni-routing-simulation
    proxy-ssl-mode-two-relay-dispatch-simulation
    ui-nats-dns-integration-simulation
    setup-cli-simulation
    dhcp-kea-lease-flow-simulation
    nats-auth-callout-simulation
    ui-reachability-crash-loop-simulation
    setup-reset-kea-config-simulation
    setup-reset-dns-config-simulation
  )

  for job in "${required_jobs[@]}"; do
    run grep -Eq "^  ${job}:$" "$WORKFLOW"
    [ "$status" -eq 0 ]
  done
}

@test "stack-lock mode remains optional for normal reusable-workflow callers" {
  run grep -F 'stack_lock_artifact:' "$WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -F 'default: ""' "$WORKFLOW"
  [ "$status" -eq 0 ]
}
