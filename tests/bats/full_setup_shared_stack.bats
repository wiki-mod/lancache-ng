#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/full-setup-sims.yml"
}

@test "compatible full-setup simulations live in one shared heavy job" {
  run grep -Ec '^  shared-full-setup-stack:$' "$WORKFLOW"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]

  for retired_job in \
    full-setup-validate \
    ssl-mitm-cache-simulation \
    ui-nats-dns-integration-simulation \
    nats-auth-callout-simulation \
    ui-reachability-crash-loop-simulation \
    setup-reset-dns-config-simulation; do
    run grep -Ec "^  ${retired_job}:$" "$WORKFLOW"
    [ "$status" -eq 1 ]
    [ "$output" -eq 0 ]
  done

  run grep -F 'FULL_SETUP_SHARED_STACK: "1"' "$WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -F 'uses: ./.github/actions/reserve-validation-subnet-stack' "$WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "shared stack starts profile-gated passthrough shim from the initial compose up" {
  run grep -F 'COMPOSE_PROFILES: ssl-mitm-proof' "$WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -F 'docker compose ps -q standard-passthrough-shim' "$WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "shared simulations execute directly and crash-loop proof is last" {
  scripts=(
    full-setup-client-simulation.sh
    ssl-mitm-cache-simulation.sh
    ui-nats-dns-integration-simulation.sh
    dns-zone-rollback-simulation.sh
    setup-reset-dns-config-simulation.sh
    nats-secondary-auth-callout-simulation.sh
    ui-reachability-crash-loop-simulation.sh
  )

  previous=0
  for script in "${scripts[@]}"; do
    line="$(grep -nF "bash scripts/$script" "$WORKFLOW" | cut -d: -f1)"
    [ -n "$line" ]
    [ "$line" -gt "$previous" ]
    previous="$line"
  done

  teardown_line="$(grep -nF -- '- name: Tear down shared validation stack and release subnet lock' "$WORKFLOW" | cut -d: -f1)"
  [ -n "$teardown_line" ]
  [ "$previous" -lt "$teardown_line" ]
}

@test "shareable simulations are not wrapped in per-test subnet reservations" {
  for script in \
    ssl-mitm-cache-simulation.sh \
    ui-nats-dns-integration-simulation.sh \
    dns-zone-rollback-simulation.sh \
    setup-reset-dns-config-simulation.sh \
    nats-secondary-auth-callout-simulation.sh; do
    run grep -F "run-in-validation-subnet.sh bash scripts/$script" "$WORKFLOW"
    [ "$status" -eq 1 ]
  done
}

@test "shareable scripts preserve standalone mode but cannot tear down caller-owned stack" {
  for script in \
    ssl-mitm-cache-simulation.sh \
    ui-nats-dns-integration-simulation.sh \
    dns-zone-rollback-simulation.sh \
    setup-reset-dns-config-simulation.sh \
    nats-secondary-auth-callout-simulation.sh; do
    file="$REPO_ROOT/scripts/$script"
    run grep -F 'shared_stack="${FULL_SETUP_SHARED_STACK:-0}"' "$file"
    [ "$status" -eq 0 ]
    run grep -F 'if [[ "$shared_stack" != 1 ]]; then' "$file"
    [ "$status" -eq 0 ]
  done
}

@test "DNS rollback is shared for explicit and immutable-stack callers" {
  run grep -F 'run_dns_zone_rollback:' "$WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -F "if: inputs.run_dns_zone_rollback == 'true' || inputs.stack_lock_artifact != ''" "$WORKFLOW"
  [ "$status" -eq 0 ]
}
