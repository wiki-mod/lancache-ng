#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Exercises scripts/check-trivy-action-direct-usage.sh against small,
# throwaway fixture trees rather than only this repo's own real tree, so
# both the passing and failing path are proven -- per AG-VAL-024, a check
# that only ever runs against an already-green tree never actually proves
# its fail-closed path is reachable.

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
