#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Exercises scripts/check-trivy-action-direct-usage.sh against small,
# throwaway fixture trees rather than only this repo's own real tree, so
# both the passing and failing path are proven -- per AG-VAL-024, a check
# that only ever runs against an already-green tree never actually proves
# its fail-closed path is reachable.
#
# The dockerhub-wiring tests below (issue #1535 follow-up, 2026-08-13)
# additionally cover check_dockerhub_wiring()'s own variation axes per
# AG-VAL-036 -- indentation, key order, interleaved comments, a missing
# with: block, and a call site missing only one of the two keys -- rather
# than a single happy-path fixture, since a real call site's shape in this
# repo already varies across all of those (see the 9 real call sites
# across build-tools.yml/build-push.yml/build-push-hosted-fallback.yml).

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/check-trivy-action-direct-usage.sh"
    fixture_root="$(mktemp -d)"
    mkdir -p "$fixture_root/.github/workflows" "$fixture_root/.github/actions/trivy-scan-retry"
}

teardown() {
    rm -rf "$fixture_root"
}

fail() {
    echo "$1" >&2
    return 1
}

@test "passes when aquasecurity/trivy-action only appears inside the retry wrapper" {
    cat > "$fixture_root/.github/actions/trivy-scan-retry/action.yml" <<'EOF'
name: Trivy scan with retry
runs:
  using: composite
  steps:
    - id: attempt1
      uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
EOF
    cat > "$fixture_root/.github/workflows/build.yml" <<'EOF'
name: build
on: push
jobs:
  scan:
    steps:
      - uses: ./.github/actions/trivy-scan-retry
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ] || fail "expected pass, got status $status: $output"
    [[ "$output" == *"no direct aquasecurity/trivy-action call site"* ]] || fail "missing pass message: $output"
}

@test "fails when a workflow calls aquasecurity/trivy-action directly" {
    cat > "$fixture_root/.github/actions/trivy-scan-retry/action.yml" <<'EOF'
name: Trivy scan with retry
runs:
  using: composite
  steps:
    - id: attempt1
      uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
EOF
    cat > "$fixture_root/.github/workflows/build.yml" <<'EOF'
name: build
on: push
jobs:
  scan:
    steps:
      - name: Scan image with Trivy
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
        with:
          image-ref: example
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ] || fail "expected failure, got status $status: $output"
    [[ "$output" == *".github/workflows/build.yml"* ]] || fail "missing offending file in output: $output"
}

@test "fails when a different composite action calls aquasecurity/trivy-action directly" {
    cat > "$fixture_root/.github/actions/trivy-scan-retry/action.yml" <<'EOF'
name: Trivy scan with retry
runs:
  using: composite
  steps:
    - id: attempt1
      uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
EOF
    mkdir -p "$fixture_root/.github/actions/some-other-action"
    cat > "$fixture_root/.github/actions/some-other-action/action.yml" <<'EOF'
name: Some other action
runs:
  using: composite
  steps:
    - uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ] || fail "expected failure, got status $status: $output"
    [[ "$output" == *"some-other-action/action.yml"* ]] || fail "missing offending file in output: $output"
}

# Every dockerhub-wiring fixture below needs the wrapper action.yml present
# too (check_direct_usage() also scans .github/actions, and an empty/
# missing wrapper file is not what these fixtures are testing).
write_wrapper_fixture() {
    cat > "$fixture_root/.github/actions/trivy-scan-retry/action.yml" <<'EOF'
name: Trivy scan with retry
runs:
  using: composite
  steps:
    - id: attempt1
      uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
EOF
}

@test "passes when a trivy-scan-retry call site sets both dockerhub keys, any order, with an interleaved comment" {
    write_wrapper_fixture
    cat > "$fixture_root/.github/workflows/build.yml" <<'EOF'
name: build
on: push
jobs:
  scan:
    steps:
      - name: Scan image with Trivy
        uses: ./.github/actions/trivy-scan-retry
        with:
          # a comment interleaved inside with: must not confuse the scanner
          dockerhub-password: ${{ secrets.DOCKERHUB_TOKEN }}
          username: ${{ github.actor }}
          dockerhub-username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.GITHUB_TOKEN }}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ] || fail "expected pass, got status $status: $output"
}

@test "fails when a trivy-scan-retry call site's with: block sets neither dockerhub key" {
    write_wrapper_fixture
    cat > "$fixture_root/.github/workflows/build.yml" <<'EOF'
name: build
on: push
jobs:
  scan:
    steps:
      - name: Scan image with Trivy
        uses: ./.github/actions/trivy-scan-retry
        with:
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ] || fail "expected failure, got status $status: $output"
    [[ "$output" == *"missing dockerhub-username and dockerhub-password"* ]] || fail "missing expected message: $output"
}

@test "fails when a trivy-scan-retry call site's with: block sets only one dockerhub key" {
    write_wrapper_fixture
    cat > "$fixture_root/.github/workflows/build.yml" <<'EOF'
name: build
on: push
jobs:
  scan:
    steps:
      - name: Scan image with Trivy
        uses: ./.github/actions/trivy-scan-retry
        with:
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
          dockerhub-username: ${{ secrets.DOCKERHUB_USERNAME }}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ] || fail "expected failure, got status $status: $output"
    [[ "$output" == *"missing dockerhub-password"* ]] || fail "missing expected message: $output"
    [[ "$output" != *"missing dockerhub-username"* ]] || fail "should not also report dockerhub-username missing: $output"
}

@test "fails when a trivy-scan-retry call site has no with: block at all" {
    write_wrapper_fixture
    cat > "$fixture_root/.github/workflows/build.yml" <<'EOF'
name: build
on: push
jobs:
  scan:
    steps:
      - name: Scan image with Trivy
        uses: ./.github/actions/trivy-scan-retry
      - name: Unrelated later step
        run: echo hi
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ] || fail "expected failure, got status $status: $output"
    [[ "$output" == *"has no with: block"* ]] || fail "missing expected message: $output"
}

@test "passes when multiple trivy-scan-retry call sites in one file are all fully wired, at different indentation" {
    write_wrapper_fixture
    cat > "$fixture_root/.github/workflows/build.yml" <<'EOF'
name: build
on: push
jobs:
  scan-a:
    steps:
      - name: Scan A
        uses: ./.github/actions/trivy-scan-retry
        with:
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
          dockerhub-username: ${{ secrets.DOCKERHUB_USERNAME }}
          dockerhub-password: ${{ secrets.DOCKERHUB_TOKEN }}
  scan-b:
    steps:
      -
        name: Scan B (deeper nesting under a matrix step)
        uses: ./.github/actions/trivy-scan-retry
        with:
          username: ${{ github.actor }}
          dockerhub-username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.GITHUB_TOKEN }}
          dockerhub-password: ${{ secrets.DOCKERHUB_TOKEN }}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ] || fail "expected pass, got status $status: $output"
}
