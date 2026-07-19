#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/check-validation-subnet-wrapper-coverage.sh (#896):
# the standing CI guard that fails a build if a job in full-setup-validate.yml
# or full-setup-deep-validate.yml consumes compute-validation-network's raw
# per-run subnet output without going through the collision-safe
# run-in-validation-subnet.sh wrapper (or an equivalent inline reservation
# loop). Like check_idempotence_test_coverage.bats, this file builds small
# synthetic workflow-file fixtures under a scratch repo_root rather than only
# running the guard against today's real repo (a happy-path check alone
# cannot prove the guard actually CATCHES a regression -- it can only prove
# it currently passes). The guard script accepts an optional repo_root
# argument for exactly this reason.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-validation-subnet-wrapper-coverage.sh"
    fixture_root="$BATS_TEST_TMPDIR/fixture-repo"
    mkdir -p "$fixture_root/.github/workflows"
}

# write_validate_yml <content>
# Writes a minimal full-setup-validate.yml fixture: a `jobs:` key followed by
# whatever job block(s) the caller supplies. full-setup-deep-validate.yml is
# always written as a trivial single-job stub (no raw-output reference) so
# each test can exercise full-setup-validate.yml's shape in isolation without
# the guard's "found zero jobs across both files" self-check firing (the
# stub still needs at least one job overall; only ONE of the two files needs
# to carry a raw-output-referencing job for that self-check to stay quiet).
write_validate_yml() {
    printf 'name: Full-Setup Validate\njobs:\n%s' "$1" > "$fixture_root/.github/workflows/full-setup-validate.yml"
}

write_trivial_deep_validate_yml() {
    cat > "$fixture_root/.github/workflows/full-setup-deep-validate.yml" <<'EOF'
name: Full-Setup Deep Validate
jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - run: echo plan
EOF
}

@test "passes when a job is wrapped via run-in-validation-subnet.sh" {
    write_trivial_deep_validate_yml
    write_validate_yml '  compute-validation-network:
    runs-on: ubuntu-latest
    outputs:
      subnet: ${{ steps.derive.outputs.subnet }}
    steps:
      - run: echo derive

  ssl-mitm-cache-simulation:
    needs: compute-validation-network
    runs-on: ubuntu-latest
    steps:
      - name: Run simulation
        env:
          FOO: bar
        run: |
          bash scripts/lib/run-in-validation-subnet.sh bash scripts/ssl-mitm-cache-simulation.sh
'
    # This job never actually references the raw output itself, so it should
    # not even be counted -- add a second, real consumer below to exercise
    # the pass path meaningfully.
    write_validate_yml '  compute-validation-network:
    runs-on: ubuntu-latest
    outputs:
      subnet: ${{ steps.derive.outputs.subnet }}
    steps:
      - run: echo derive

  ssl-mitm-cache-simulation:
    needs: compute-validation-network
    runs-on: ubuntu-latest
    env:
      VALIDATION_SUBNET: ${{ needs.compute-validation-network.outputs.subnet }}
    steps:
      - name: Run simulation
        run: |
          bash scripts/lib/run-in-validation-subnet.sh bash scripts/ssl-mitm-cache-simulation.sh
'

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    [[ "$output" == *"1 job"* ]]
}

@test "passes when a job re-derives its own reservation inline instead of using the wrapper" {
    write_trivial_deep_validate_yml
    write_validate_yml '  compute-validation-network:
    runs-on: ubuntu-latest
    outputs:
      subnet: ${{ steps.derive.outputs.subnet }}
    steps:
      - run: echo derive

  full-setup-validate:
    needs: compute-validation-network
    runs-on: ubuntu-latest
    env:
      VALIDATION_SUBNET: ${{ needs.compute-validation-network.outputs.subnet }}
    steps:
      - name: Reserve a validation subnet and start the stack
        run: |
          source "$GITHUB_WORKSPACE/scripts/lib/reserve-validation-subnet.sh"
          reservation="$(validation_subnet_reserve_slot "$lock_root" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$next_attempt" "$max_attempts")"
          docker compose up -d
'

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails when a job consumes the raw subnet output with neither the wrapper nor inline reservation" {
    # The exact #896/#907 bug class: a job threads compute-validation-network's
    # outputs at job level and starts its own stack directly, with no lock and
    # no retry.
    write_trivial_deep_validate_yml
    write_validate_yml '  compute-validation-network:
    runs-on: ubuntu-latest
    outputs:
      subnet: ${{ steps.derive.outputs.subnet }}
    steps:
      - run: echo derive

  ui-reachability-crash-loop-simulation:
    needs: compute-validation-network
    runs-on: ubuntu-latest
    env:
      COMPOSE_PROJECT_NAME: ${{ needs.compute-validation-network.outputs.project_name }}
      VALIDATION_UI_PORT: ${{ needs.compute-validation-network.outputs.ui_port }}
    steps:
      - name: Run simulation
        run: |
          bash scripts/ui-reachability-crash-loop-simulation.sh
'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ui-reachability-crash-loop-simulation"* ]]
    [[ "$output" == *"full-setup-validate.yml"* ]]
    [[ "$output" == *"neither a"* ]]
}

@test "fails when the raw output is referenced in GitHub Actions bracket-notation form" {
    # `needs['compute-validation-network'].outputs.subnet` is an equally
    # valid GitHub Actions expression to `needs.compute-validation-network.
    # outputs.subnet` -- and bracket form already has real precedent in this
    # exact file: full-setup-deep-validate.yml's own `if:` conditions use
    # `needs['compute-validation-network'].result`. A guard matching only
    # dot form would silently pass a job that threads the raw subnet through
    # bracket notation instead, which is exactly the failure mode this test
    # guards against.
    write_trivial_deep_validate_yml
    write_validate_yml '  compute-validation-network:
    runs-on: ubuntu-latest
    outputs:
      subnet: ${{ steps.derive.outputs.subnet }}
    steps:
      - run: echo derive

  ui-reachability-crash-loop-simulation:
    needs: compute-validation-network
    runs-on: ubuntu-latest
    env:
      VALIDATION_SUBNET: ${{ needs['"'"'compute-validation-network'"'"'].outputs.subnet }}
    steps:
      - run: bash scripts/ui-reachability-crash-loop-simulation.sh
'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ui-reachability-crash-loop-simulation"* ]]
}

@test "does not count a comment merely mentioning the wrapper filename as protection" {
    # Several real header comments in this repo mention
    # "run-in-validation-subnet.sh" in prose while describing OTHER jobs,
    # without invoking it themselves -- the guard must require the actual
    # invocation string, not just the bare filename anywhere in the job body.
    write_trivial_deep_validate_yml
    write_validate_yml '  compute-validation-network:
    runs-on: ubuntu-latest
    outputs:
      subnet: ${{ steps.derive.outputs.subnet }}
    steps:
      - run: echo derive

  ui-reachability-crash-loop-simulation:
    # Every OTHER job in this file already goes through
    # run-in-validation-subnet.sh, see its own header comment.
    needs: compute-validation-network
    runs-on: ubuntu-latest
    env:
      VALIDATION_SUBNET: ${{ needs.compute-validation-network.outputs.subnet }}
    steps:
      - name: Run simulation
        run: |
          bash scripts/ui-reachability-crash-loop-simulation.sh
'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ui-reachability-crash-loop-simulation"* ]]
}

@test "does not count a comment merely naming the reservation function as protection" {
    write_trivial_deep_validate_yml
    write_validate_yml '  compute-validation-network:
    runs-on: ubuntu-latest
    outputs:
      subnet: ${{ steps.derive.outputs.subnet }}
    steps:
      - run: echo derive

  setup-reset-kea-config-simulation:
    # Unlike full-setup-validate, this job does NOT call
    # validation_subnet_reserve_slot itself.
    needs: compute-validation-network
    runs-on: ubuntu-latest
    env:
      VALIDATION_SUBNET: ${{ needs.compute-validation-network.outputs.subnet }}
    steps:
      - name: Run simulation
        run: |
          bash scripts/setup-reset-kea-config-simulation.sh
'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"setup-reset-kea-config-simulation"* ]]
}

@test "reports every violating job in one run, not just the first" {
    write_trivial_deep_validate_yml
    write_validate_yml '  compute-validation-network:
    runs-on: ubuntu-latest
    outputs:
      subnet: ${{ steps.derive.outputs.subnet }}
    steps:
      - run: echo derive

  ui-reachability-crash-loop-simulation:
    needs: compute-validation-network
    runs-on: ubuntu-latest
    env:
      VALIDATION_SUBNET: ${{ needs.compute-validation-network.outputs.subnet }}
    steps:
      - run: bash scripts/ui-reachability-crash-loop-simulation.sh

  setup-reset-kea-config-simulation:
    needs: compute-validation-network
    runs-on: ubuntu-latest
    env:
      VALIDATION_SUBNET: ${{ needs.compute-validation-network.outputs.subnet }}
    steps:
      - run: bash scripts/setup-reset-kea-config-simulation.sh
'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ui-reachability-crash-loop-simulation"* ]]
    [[ "$output" == *"setup-reset-kea-config-simulation"* ]]
}

@test "does not flag a job that never references the raw compute-validation-network output" {
    # setup-cli-simulation-style jobs: independent isolation (their own flock
    # on a fixed-name compose stack), no needs on compute-validation-network,
    # no wrapper call needed -- must not be flagged just for lacking the
    # wrapper string. A genuinely protected job is included alongside them so
    # the overall fixture passes and this test isolates exactly one thing:
    # that the two unrelated jobs are never named in the (empty) violation
    # report, not the separate "found zero jobs at all" self-check case
    # (covered on its own below).
    write_trivial_deep_validate_yml
    write_validate_yml '  compute-validation-network:
    runs-on: ubuntu-latest
    outputs:
      subnet: ${{ steps.derive.outputs.subnet }}
    steps:
      - run: echo derive

  ssl-mitm-cache-simulation:
    needs: compute-validation-network
    runs-on: ubuntu-latest
    env:
      VALIDATION_SUBNET: ${{ needs.compute-validation-network.outputs.subnet }}
    steps:
      - run: |
          bash scripts/lib/run-in-validation-subnet.sh bash scripts/ssl-mitm-cache-simulation.sh

  setup-cli-simulation:
    runs-on: ubuntu-latest
    steps:
      - run: |
          exec {lock_fd}>/tmp/lancache-setup-cli-simulation.lock
          flock "$lock_fd"
          bash scripts/setup-cli-simulation.sh

  dhcp-kea-lease-flow-simulation:
    needs: setup-cli-simulation
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/dhcp-kea-lease-flow-simulation.sh
'

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    [[ "$output" != *"setup-cli-simulation"* ]]
    [[ "$output" != *"dhcp-kea-lease-flow-simulation"* ]]
}

@test "fails with a self-diagnostic when neither workflow file references the raw output at all" {
    # Guards the guard: both real workflow files have carried several
    # protected raw-output consumers since #820/#907, so finding none is
    # itself treated as a likely parsing break, not a clean pass.
    write_trivial_deep_validate_yml
    write_validate_yml '  compute-validation-network:
    runs-on: ubuntu-latest
    outputs:
      subnet: ${{ steps.derive.outputs.subnet }}
    steps:
      - run: echo derive
'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"found zero jobs"* ]]
}

@test "fails when a required workflow file no longer exists" {
    write_trivial_deep_validate_yml
    write_validate_yml '  compute-validation-network:
    runs-on: ubuntu-latest
    steps:
      - run: echo derive
'
    rm "$fixture_root/.github/workflows/full-setup-deep-validate.yml"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"full-setup-deep-validate.yml"* ]]
    [[ "$output" == *"no longer exists"* ]]
}

@test "does not mistake an on: block's own 2-space-indented keys for job names" {
    # workflow_dispatch/pull_request under `on:` are also indented by two
    # spaces, same as a real job name under `jobs:` -- the guard must only
    # start recognizing job names after the literal top-level `jobs:` line,
    # or it would try to treat "workflow_dispatch:" itself as a job and
    # silently misparse everything that follows.
    cat > "$fixture_root/.github/workflows/full-setup-validate.yml" <<'EOF'
name: Full-Setup Validate
on:
  workflow_dispatch:
    inputs:
      image_tag:
        default: nightly
jobs:
  compute-validation-network:
    runs-on: ubuntu-latest
    outputs:
      subnet: ${{ steps.derive.outputs.subnet }}
    steps:
      - run: echo derive

  ssl-mitm-cache-simulation:
    needs: compute-validation-network
    runs-on: ubuntu-latest
    env:
      VALIDATION_SUBNET: ${{ needs.compute-validation-network.outputs.subnet }}
    steps:
      - run: |
          bash scripts/lib/run-in-validation-subnet.sh bash scripts/ssl-mitm-cache-simulation.sh
EOF
    write_trivial_deep_validate_yml

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "the guard also passes when pointed at the real repository tree" {
    real_repo_root="$BATS_TEST_DIRNAME/../.."
    run "$script" "$real_repo_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
