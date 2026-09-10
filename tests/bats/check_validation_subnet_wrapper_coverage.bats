#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for scripts/tracked/check-validation-subnet-wrapper-coverage.sh (#896):
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
    script="$BATS_TEST_DIRNAME/../../scripts/tracked/check-validation-subnet-wrapper-coverage.sh"
    fixture_root="$BATS_TEST_TMPDIR/fixture-repo"
    mkdir -p "$fixture_root/.github/workflows"
    # full-setup-sims.yml is one of the guard's scanned files (#1014), so every
    # fixture needs it present or the guard's "file no longer exists" path fires.
    # Default to a trivial stub with no raw-output job; tests exercising the
    # reusable-workflow's own shape overwrite it.
    write_trivial_sims_yml
    # Same reasoning, for the script-level check (#822): a fixture with zero
    # subnet-pinning scripts would trip the guard's own "found zero scripts"
    # self-check exactly like a missing workflow file would. Every test gets
    # one always-compliant baseline script by default; only the test
    # exercising that self-check removes it.
    mkdir -p "$fixture_root/scripts/untracked/simulations"
    write_baseline_protected_simulation_script
}

# write_baseline_protected_simulation_script
# A trivial always-compliant fixture script (sources reserve-validation-
# subnet.sh directly, one of the two accepted protection forms) that keeps
# scripts_examined_with_subnet_creation non-zero by default, the same role
# write_trivial_sims_yml plays for jobs_examined_with_raw_output.
write_baseline_protected_simulation_script() {
    cat > "$fixture_root/scripts/untracked/simulations/baseline-protected-simulation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"
docker network create --subnet "172.30.5.0/24" baseline-net
EOF
}

write_trivial_sims_yml() {
    cat > "$fixture_root/.github/workflows/full-setup-sims.yml" <<'EOF'
name: Full-Setup Simulations (reusable)
on:
  workflow_call:
jobs:
  noop:
    runs-on: ubuntu-latest
    steps:
      - run: echo noop
EOF
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
          bash scripts/lib/run-in-validation-subnet.sh bash scripts/untracked/simulations/ssl-mitm-cache-simulation.sh
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
          bash scripts/lib/run-in-validation-subnet.sh bash scripts/untracked/simulations/ssl-mitm-cache-simulation.sh
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
          bash scripts/untracked/simulations/ui-reachability-crash-loop-simulation.sh
'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ui-reachability-crash-loop-simulation"* ]]
    [[ "$output" == *"full-setup-validate.yml"* ]]
    [[ "$output" == *"none of:"* ]]
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
      - run: bash scripts/untracked/simulations/ui-reachability-crash-loop-simulation.sh
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
          bash scripts/untracked/simulations/ui-reachability-crash-loop-simulation.sh
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
          bash scripts/untracked/simulations/setup-reset-kea-config-simulation.sh
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
      - run: bash scripts/untracked/simulations/ui-reachability-crash-loop-simulation.sh

  setup-reset-kea-config-simulation:
    needs: compute-validation-network
    runs-on: ubuntu-latest
    env:
      VALIDATION_SUBNET: ${{ needs.compute-validation-network.outputs.subnet }}
    steps:
      - run: bash scripts/untracked/simulations/setup-reset-kea-config-simulation.sh
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
          bash scripts/lib/run-in-validation-subnet.sh bash scripts/untracked/simulations/ssl-mitm-cache-simulation.sh

  setup-cli-simulation:
    runs-on: ubuntu-latest
    steps:
      - run: |
          exec {lock_fd}>/tmp/lancache-setup-cli-simulation.lock
          flock "$lock_fd"
          bash scripts/untracked/simulations/setup-cli-simulation.sh

  dhcp-kea-lease-flow-simulation:
    needs: setup-cli-simulation
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/untracked/simulations/dhcp-kea-lease-flow-simulation.sh
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
          bash scripts/lib/run-in-validation-subnet.sh bash scripts/untracked/simulations/ssl-mitm-cache-simulation.sh
EOF
    write_trivial_deep_validate_yml

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "passes when a full-setup-sims.yml job reserves via the reserve-validation-subnet-stack composite action" {
    # #1014 shape: full-setup-validate's cross-several-steps inline reservation
    # loop was extracted into a composite action. A job that references the raw
    # output but reserves through `uses: ./.github/actions/
    # reserve-validation-subnet-stack` holds the same flock-locked reservation
    # and must count as protected, not flagged.
    write_validate_yml '  compute-validation-network:
    runs-on: ubuntu-latest
    outputs:
      subnet: ${{ steps.derive.outputs.subnet }}
    steps:
      - run: echo derive
'
    write_trivial_deep_validate_yml
    cat > "$fixture_root/.github/workflows/full-setup-sims.yml" <<'EOF'
name: Full-Setup Simulations (reusable)
on:
  workflow_call:
jobs:
  full-setup-validate:
    runs-on: ubuntu-latest
    env:
      VALIDATION_SUBNET: ${{ needs.compute-validation-network.outputs.subnet }}
    steps:
      - uses: ./.github/actions/reserve-validation-subnet-stack
        with:
          image-tag: dev
EOF

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails when a full-setup-sims.yml job consumes the raw output with no protection" {
    # The #896/#907 collision class in the reusable workflow's new home: a job
    # threads the raw subnet at job level and starts its stack directly, with
    # none of the wrapper / inline reservation / composite-action protections.
    # This is the regression the guard must still catch after #1014 moved the
    # jobs into full-setup-sims.yml.
    write_validate_yml '  compute-validation-network:
    runs-on: ubuntu-latest
    outputs:
      subnet: ${{ steps.derive.outputs.subnet }}
    steps:
      - run: echo derive
'
    write_trivial_deep_validate_yml
    cat > "$fixture_root/.github/workflows/full-setup-sims.yml" <<'EOF'
name: Full-Setup Simulations (reusable)
on:
  workflow_call:
jobs:
  rogue-simulation:
    runs-on: ubuntu-latest
    env:
      VALIDATION_SUBNET: ${{ needs.compute-validation-network.outputs.subnet }}
    steps:
      - run: docker compose up -d
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"rogue-simulation"* ]]
    [[ "$output" == *"full-setup-sims.yml"* ]]
}

@test "the guard also passes when pointed at the real repository tree" {
    real_repo_root="$BATS_TEST_DIRNAME/../.."
    run "$script" "$real_repo_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails when a simulation script hardcodes a subnet with no reservation protection" {
    # The actual #822 bug shape: proxy-ssl-mode-two-relay-dispatch-
    # simulation.sh used to do exactly this -- a literal --subnet, no
    # source of reserve-validation-subnet.sh, no $VALIDATION_SUBNET read --
    # and no job anywhere ever referenced compute-validation-network's raw
    # output, so the job-level check above could never have caught it.
    cat > "$fixture_root/scripts/untracked/simulations/rogue-hardcoded-subnet-simulation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
docker network create --subnet 172.29.77.0/24 "rogue-net"
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"rogue-hardcoded-subnet-simulation.sh"* ]]
    [[ "$output" == *"neither protection form"* ]]
}

@test "passes when a simulation script sources reserve-validation-subnet.sh directly" {
    # Same reasoning as write_trivial_sims_yml/write_baseline_protected_
    # simulation_script: both required workflow files must exist and the
    # job-level check needs its own non-zero raw-output job, or unrelated
    # "file no longer exists"/"found zero jobs" failures from THAT check
    # would mask what this test actually verifies.
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
          bash scripts/lib/run-in-validation-subnet.sh bash scripts/untracked/simulations/ssl-mitm-cache-simulation.sh
'
    cat > "$fixture_root/scripts/untracked/simulations/dhcp-style-simulation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/reserve-validation-subnet.sh
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"
docker network create --subnet "172.29.5.0/24" dhcp-style-net
EOF

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "passes when a simulation script reads \$VALIDATION_SUBNET from its wrapping job" {
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
          bash scripts/lib/run-in-validation-subnet.sh bash scripts/untracked/simulations/ssl-mitm-cache-simulation.sh
'
    cat > "$fixture_root/scripts/untracked/simulations/wrapped-style-simulation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
validation_subnet="${VALIDATION_SUBNET:-172.30.99.0/27}"
docker network create --subnet "$validation_subnet" wrapped-style-net
EOF

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "does not flag a simulation script that never pins an explicit subnet" {
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
          bash scripts/lib/run-in-validation-subnet.sh bash scripts/untracked/simulations/ssl-mitm-cache-simulation.sh
'
    cat > "$fixture_root/scripts/untracked/simulations/auto-assigned-simulation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
docker network create "auto-net-$$"
EOF

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    [[ "$output" != *"auto-assigned-simulation.sh"* ]]
}

@test "does not count a shellcheck source= directive comment alone as protection" {
    # Mirrors "does not count a comment merely mentioning the wrapper
    # filename as protection" above, at the script level: several real
    # protected scripts carry a `# shellcheck source=...` directive
    # immediately above their real `source "..."` line -- the directive
    # comment alone, with no real source line, must not count.
    cat > "$fixture_root/scripts/untracked/simulations/fake-sourced-simulation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/reserve-validation-subnet.sh
docker network create --subnet 172.29.88.0/24 "fake-sourced-net"
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"fake-sourced-simulation.sh"* ]]
}

@test "fails with a self-diagnostic when zero simulation scripts pin a subnet" {
    rm "$fixture_root/scripts/untracked/simulations/baseline-protected-simulation.sh"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"found zero scripts"* ]]
}

write_ippin_context() {
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
          bash scripts/lib/run-in-validation-subnet.sh bash scripts/untracked/simulations/ssl-mitm-cache-simulation.sh
'
}

@test "ip-pin: fails when a non-DHCP subnet sim mixes a pinned and an unpinned container" {
    write_ippin_context
    cat > "$fixture_root/scripts/untracked/simulations/ippin-mix-simulation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"
docker network create --subnet "172.29.80.0/24" ippin-net
docker run -d --name server --network ippin-net --ip 172.29.80.2 img
docker run -d --name other --network ippin-net img
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ippin-mix-simulation.sh"* ]]
    [[ "$output" == *"#1850"* ]]
}

@test "ip-pin: passes when a non-DHCP subnet sim pins every container" {
    write_ippin_context
    cat > "$fixture_root/scripts/untracked/simulations/ippin-allpinned-simulation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"
docker network create --subnet "172.29.80.0/24" ippin-net
docker run -d --name a --network ippin-net --ip 172.29.80.2 img
docker run -d --name b --network ippin-net --ip 172.29.80.3 img
EOF

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "ip-pin: passes when a non-DHCP subnet sim pins no container" {
    write_ippin_context
    cat > "$fixture_root/scripts/untracked/simulations/ippin-allauto-simulation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"
docker network create --subnet "172.29.80.0/24" ippin-net
docker run -d --name a --network ippin-net img
docker run -d --name b --network ippin-net img
EOF

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "ip-pin: exempts a DHCP simulation (building services/dhcp) from the mix rule" {
    write_ippin_context
    cat > "$fixture_root/scripts/untracked/simulations/ippin-dhcp-simulation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"
docker network create --subnet "172.29.81.0/24" dhcpmix-net
docker build -q services/dhcp -t kea >/dev/null
docker run -d --name kea --network dhcpmix-net --ip 172.29.81.2 kea
docker run -d --name client --network dhcpmix-net kea
EOF

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "ip-pin: a comment mentioning services/dhcp does not exempt a non-DHCP mixed sim (#7)" {
    write_ippin_context
    cat > "$fixture_root/scripts/untracked/simulations/ippin-comment-simulation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"
# this sim references services/dhcp in a comment but never builds it
docker network create --subnet "172.29.82.0/24" fake-net
docker run -d --name server --network fake-net --ip 172.29.82.2 img
docker run -d --name other --network fake-net img
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ippin-comment-simulation.sh"* ]]
    [[ "$output" == *"#1850"* ]]
}

@test "ip-pin: an echo mentioning docker run --network is not counted as a container (#8)" {
    write_ippin_context
    cat > "$fixture_root/scripts/untracked/simulations/ippin-echo-simulation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"
docker network create --subnet "172.29.83.0/24" ippin-net
docker run -d --name a --network ippin-net --ip 172.29.83.2 img
docker run -d --name b --network ippin-net --ip 172.29.83.3 img
echo "example: docker run -d --network review-net image-b"
EOF

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "ip-pin: does not combine a pinned and unpinned container on different networks (#A)" {
    write_ippin_context
    cat > "$fixture_root/scripts/untracked/simulations/ippin-multinet-simulation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"
docker network create --subnet "172.29.84.0/24" ippin-net
docker run -d --name server --network ippin-net --ip 172.29.84.2 img
docker run -d --name aux --network other-net img
EOF

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}
