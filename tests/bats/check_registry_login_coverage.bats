#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for scripts/tracked/check-registry-login-coverage.sh (#1095): the
# standing CI guard that fails a build if a job in full-setup-validate.yml,
# full-setup-deep-validate.yml, or full-setup-sims.yml pulls a docker.io-
# backed service (derived from deploy/full-setup/docker-compose.yml and
# deploy/quickstart/docker-compose.yml) without a
# ghcr-then-dockerhub-login step. Like check_validation_subnet_wrapper_
# coverage.bats, this file builds small synthetic workflow-file and
# compose-file fixtures under a scratch repo_root rather than only running
# the guard against today's real repo -- a happy-path check alone cannot
# prove the guard actually CATCHES a regression. The guard script accepts an
# optional repo_root argument for exactly this reason.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/tracked/check-registry-login-coverage.sh"
    fixture_root="$BATS_TEST_TMPDIR/fixture-repo"
    mkdir -p "$fixture_root/.github/workflows" \
        "$fixture_root/deploy/full-setup" \
        "$fixture_root/deploy/quickstart" \
        "$fixture_root/scripts/untracked/simulations"
    write_dockerhub_backed_compose_files
    write_trivial_sims_yml
    write_trivial_deep_validate_yml
}

# A minimal compose pair carrying one ghcr.io-backed service (never flagged)
# and one bare, docker.io-backed service (nats) -- enough to exercise the
# guard's own image-prefix classification without needing the real,
# much larger compose files.
write_dockerhub_backed_compose_files() {
    for f in "$fixture_root/deploy/full-setup/docker-compose.yml" "$fixture_root/deploy/quickstart/docker-compose.yml"; do
        cat > "$f" <<'EOF'
services:
  proxy:
    image: "${LANCACHE_IMAGE_REGISTRY:-ghcr.io}/wiki-mod/lancache-ng/proxy:latest"
  nats:
    image: nats:2-alpine@sha256:deadbeef
networks:
  validation:
volumes:
  shared-secrets:
EOF
    done
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

# write_validate_yml <content>
# Mirrors check_validation_subnet_wrapper_coverage.bats's own helper: a
# minimal full-setup-validate.yml fixture, letting each test exercise one
# job shape in isolation.
write_validate_yml() {
    printf 'name: Full-Setup Validate\njobs:\n%s' "$1" > "$fixture_root/.github/workflows/full-setup-validate.yml"
}

@test "passes when a job pulling a docker.io service has the login step" {
    write_validate_yml '  ssl-mitm-cache-simulation:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/ghcr-then-dockerhub-login
        with:
          ghcr-username: x
      - run: |
          docker compose -f deploy/full-setup/docker-compose.yml up -d proxy nats
'

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails when a job pulls a docker.io service with no login step" {
    write_validate_yml '  ssl-mitm-cache-simulation:
    runs-on: ubuntu-latest
    steps:
      - run: |
          docker compose -f deploy/full-setup/docker-compose.yml up -d proxy nats
'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ssl-mitm-cache-simulation"* ]]
    [[ "$output" == *"full-setup-validate.yml"* ]]
}

@test "does not flag a job that only pulls ghcr.io-backed services" {
    write_validate_yml '  full-setup-validate:
    runs-on: ubuntu-latest
    steps:
      - run: |
          docker compose -f deploy/full-setup/docker-compose.yml up -d proxy
'

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    [[ "$output" != *"full-setup-validate"* || "$output" == *"OK"* ]]
}

@test "does not count a comment merely mentioning the service name as a pull" {
    # A header comment naming "nats" while explaining something else must not
    # be mistaken for a real `up -d`/`pull --quiet` invocation.
    write_validate_yml '  dhcp-relay-flow-simulation:
    # This job, unlike nats-auth-callout-simulation, never touches nats.
    runs-on: ubuntu-latest
    steps:
      - run: docker build -q -t relay services/dhcp-proxy
'

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "treats the reserve-validation-subnet-stack composite action as an unconditional trigger" {
    write_validate_yml '  full-setup-validate:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/reserve-validation-subnet-stack
        with:
          image-tag: dev
'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"full-setup-validate"* ]]

    write_validate_yml '  full-setup-validate:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/ghcr-then-dockerhub-login
      - uses: ./.github/actions/reserve-validation-subnet-stack
        with:
          image-tag: dev
'

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "treats a named opaque setup.sh-driving script as an unconditional trigger" {
    # setup-cli-simulation.sh installs a real stack via setup.sh itself, not a
    # statically grep-able `docker compose up` line -- see the guard's own
    # header comment for why this is a named exception, not a generic rule.
    write_validate_yml '  setup-cli-simulation:
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/untracked/simulations/setup-cli-simulation.sh
'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"setup-cli-simulation"* ]]

    write_validate_yml '  setup-cli-simulation:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/ghcr-then-dockerhub-login
      - run: bash scripts/untracked/simulations/setup-cli-simulation.sh
'

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "follows a referenced simulation script to find the pulling line" {
    # The job body itself never mentions "up -d"/"nats" -- only the script it
    # names does. The guard must resolve that reference, not just scan the
    # job's own inline YAML text.
    cat > "$fixture_root/scripts/untracked/simulations/ui-nats-dns-integration-simulation.sh" <<'EOF'
#!/usr/bin/env bash
compose=(docker compose -f deploy/full-setup/docker-compose.yml)
"${compose[@]}" up -d proxy docker-socket-proxy nats ui
EOF
    write_validate_yml '  ui-nats-dns-integration-simulation:
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/untracked/simulations/ui-nats-dns-integration-simulation.sh
'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ui-nats-dns-integration-simulation"* ]]
}

@test "reports every violating job in one run, not just the first" {
    write_validate_yml '  ssl-mitm-cache-simulation:
    runs-on: ubuntu-latest
    steps:
      - run: docker compose -f deploy/full-setup/docker-compose.yml up -d nats

  another-nats-puller:
    runs-on: ubuntu-latest
    steps:
      - run: docker compose -f deploy/full-setup/docker-compose.yml up -d nats
'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ssl-mitm-cache-simulation"* ]]
    [[ "$output" == *"another-nats-puller"* ]]
}

@test "fails with a self-diagnostic when no docker.io-backed service is found" {
    for f in "$fixture_root/deploy/full-setup/docker-compose.yml" "$fixture_root/deploy/quickstart/docker-compose.yml"; do
        cat > "$f" <<'EOF'
services:
  proxy:
    image: "${LANCACHE_IMAGE_REGISTRY:-ghcr.io}/wiki-mod/lancache-ng/proxy:latest"
EOF
    done
    write_validate_yml '  full-setup-validate:
    runs-on: ubuntu-latest
    steps:
      - run: echo noop
'

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"zero docker.io-backed services"* ]]
}

@test "fails when a required workflow file no longer exists" {
    write_validate_yml '  full-setup-validate:
    runs-on: ubuntu-latest
    steps:
      - run: echo noop
'
    rm "$fixture_root/.github/workflows/full-setup-deep-validate.yml"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"full-setup-deep-validate.yml"* ]]
    [[ "$output" == *"no longer exists"* ]]
}

@test "handles CRLF line endings in the workflow file without silently passing" {
    # Real incident during this guard's own development: a CRLF-encoded
    # workflow file silently defeated every `read -r`-based line match,
    # making every job in that file invisible to the scan instead of
    # correctly flagging it.
    write_validate_yml '  ssl-mitm-cache-simulation:
    runs-on: ubuntu-latest
    steps:
      - run: docker compose -f deploy/full-setup/docker-compose.yml up -d nats
'
    sed -i 's/$/\r/' "$fixture_root/.github/workflows/full-setup-validate.yml"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ssl-mitm-cache-simulation"* ]]
}

@test "the guard also passes when pointed at the real repository tree" {
    real_repo_root="$BATS_TEST_DIRNAME/../.."
    run "$script" "$real_repo_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
