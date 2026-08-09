#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# The reusable full-setup workflow intentionally centralizes repeated setup
# logic. This guard keeps that deduplication from silently deleting a mature
# simulation while allowing compatible simulations to share one stack job.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/full-setup-sims.yml"
}

@test "reusable suite retains the shared-stack owner and isolated topology jobs" {
  required_jobs=(
    shared-full-setup-stack
    proxy-deep-wildcard-tls-simulation
    proxy-standard-mode-sni-routing-simulation
    proxy-ssl-mode-two-relay-dispatch-simulation
    setup-cli-simulation
    dhcp-kea-lease-flow-simulation
    setup-reset-kea-config-simulation
  )

  for job in "${required_jobs[@]}"; do
    run grep -Eq "^  ${job}:$" "$WORKFLOW"
    [ "$status" -eq 0 ]
  done
}

@test "mature compatible simulations remain present inside the shared-stack job" {
  required_scripts=(
    full-setup-client-simulation.sh
    ssl-mitm-cache-simulation.sh
    ui-nats-dns-integration-simulation.sh
    setup-reset-dns-config-simulation.sh
    nats-secondary-auth-callout-simulation.sh
    ui-reachability-crash-loop-simulation.sh
  )

  for script in "${required_scripts[@]}"; do
    run grep -F "bash scripts/$script" "$WORKFLOW"
    [ "$status" -eq 0 ]
  done
}

@test "stack-lock mode remains optional for normal reusable-workflow callers" {
  run grep -F 'stack_lock_artifact:' "$WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -F 'default: ""' "$WORKFLOW"
  [ "$status" -eq 0 ]
}
