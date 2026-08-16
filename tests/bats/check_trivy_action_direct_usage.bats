#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Exercises scripts/untracked/check-trivy-action-direct-usage.sh against
# throwaway fixture trees, both passing and failing cases.
# Why: a check proven only against an already-green tree never actually
# proves its fail-closed path is reachable (AG-VAL-024).
# From: PR #1542, Issue #1535

# What: The dockerhub-wiring tests below additionally cover
# check_dockerhub_wiring()'s variation axes (AG-VAL-036).
# Why: a real call site's shape already varies on indentation, key order,
# comments, and a missing with: block across this repo's real call sites.
# From: PR #1543, Issue #1535

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/untracked/check-trivy-action-direct-usage.sh"
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

# Baseline happy path for check_direct_usage(): the one legitimate call
# site (inside the wrapper itself) must not be flagged.
@test "passes when aquasecurity/trivy-action only appears inside the retry wrapper" {
    cat > "$fixture_root/.github/actions/trivy-scan-retry/action.yml" <<'EOF'
name: Trivy scan with retry
runs:
  using: composite
  steps:
    - id: attempt1
      uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
EOF
    # with: block is fully wired (both dockerhub keys) so this fixture tests
    # only the direct-usage concern its own name describes -- the separate
    # dockerhub-wiring concern (issue #1535 follow-up) has its own dedicated
    # pass/fail fixtures further below.
    cat > "$fixture_root/.github/workflows/build.yml" <<'EOF'
name: build
on: push
jobs:
  scan:
    steps:
      - uses: ./.github/actions/trivy-scan-retry
        with:
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
          dockerhub-username: ${{ secrets.DOCKERHUB_USERNAME }}
          dockerhub-password: ${{ secrets.DOCKERHUB_TOKEN }}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ] || fail "expected pass, got status $status: $output"
    [[ "$output" == *"no direct aquasecurity/trivy-action call site"* ]] || fail "missing pass message: $output"
}

# Fail-closed proof (AG-VAL-024): a direct call site bypassing the
# wrapper must be caught, not just the passing case above.
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

# Same as above, but the bypass sits in a second composite action rather
# than a workflow -- confirms the scan covers .github/actions too.
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

# Regression proof for check_direct_usage()'s own quoted-form fix: a
# double-quoted `uses: "aquasecurity/trivy-action@..."` scalar must be
# caught too, not just the unquoted form the two tests above use.
@test "fails when a workflow calls aquasecurity/trivy-action directly with a quoted uses: scalar" {
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
        uses: "aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25"
        with:
          image-ref: example
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ] || fail "expected failure, got status $status: $output"
    [[ "$output" == *".github/workflows/build.yml"* ]] || fail "quoted uses: call site was not scanned: $output"
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

# Order/comment-agnostic happy path: the scanner must not depend on key
# order or on the absence of an interleaved YAML comment.
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

# The exact silent-fallback shape this guard exists to catch: a caller
# that never wires either dockerhub key at all.
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

# Asymmetric miss: only one key set. Also proves the two missing-key
# messages don't cross-contaminate (see the second assertion below).
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

# Edge case the state machine must treat distinctly (not as "0 keys
# found"): a call site with no with: block at all.
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

# Regression proof for the Codex P1 finding: a double-quoted `uses:`
# scalar must be scanned, not silently skipped by the prefilter/regex.
@test "fails when a double-quoted trivy-scan-retry call site is missing dockerhub wiring" {
    write_wrapper_fixture
    cat > "$fixture_root/.github/workflows/build.yml" <<'EOF'
name: build
on: push
jobs:
  scan:
    steps:
      - name: Scan image with Trivy
        uses: "./.github/actions/trivy-scan-retry"
        with:
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ] || fail "expected failure, got status $status: $output"
    [[ "$output" == *"missing dockerhub-username and dockerhub-password"* ]] || fail "quoted uses: call site was not scanned: $output"
}

# Same quoted-form coverage, single-quote variant, positive case.
@test "passes when a single-quoted trivy-scan-retry call site sets both dockerhub keys" {
    write_wrapper_fixture
    cat > "$fixture_root/.github/workflows/build.yml" <<'EOF'
name: build
on: push
jobs:
  scan:
    steps:
      - name: Scan image with Trivy
        uses: './.github/actions/trivy-scan-retry'
        with:
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
          dockerhub-username: ${{ secrets.DOCKERHUB_USERNAME }}
          dockerhub-password: ${{ secrets.DOCKERHUB_TOKEN }}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ] || fail "expected pass, got status $status: $output"
}

# Regression proof for the Codex P2 finding: a present-but-empty value
# used to pass the old key-presence-only check; it must fail now.
@test "fails when a trivy-scan-retry call site sets dockerhub-username to an empty literal" {
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
          dockerhub-username: ""
          dockerhub-password: ${{ secrets.DOCKERHUB_TOKEN }}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ] || fail "expected failure, got status $status: $output"
    [[ "$output" == *"dockerhub-username empty value"* ]] || fail "missing expected message: $output"
}

# Same P2 finding, the typo'd-secret-name variant (e.g. DOCKERHUB_USER
# instead of DOCKERHUB_USERNAME) -- non-empty but still wrong.
@test "fails when a trivy-scan-retry call site references the wrong secret name" {
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
          dockerhub-username: ${{ secrets.DOCKERHUB_USER }}
          dockerhub-password: ${{ secrets.DOCKERHUB_TOKEN }}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ] || fail "expected failure, got status $status: $output"
    [[ "$output" == *"references the wrong secret (expected secrets.DOCKERHUB_USERNAME)"* ]] || fail "missing expected message: $output"
}

# Regression proof for the wrong-secret regex's own word-boundary fix: an
# unanchored match would let a longer name sharing the same prefix
# (DOCKERHUB_USERNAME_OLD) falsely pass as the expected secret.
@test "fails when a trivy-scan-retry call site references a longer secret name sharing the expected prefix" {
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
          dockerhub-username: ${{ secrets.DOCKERHUB_USERNAME_OLD }}
          dockerhub-password: ${{ secrets.DOCKERHUB_TOKEN }}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ] || fail "expected failure, got status $status: $output"
    [[ "$output" == *"references the wrong secret (expected secrets.DOCKERHUB_USERNAME)"* ]] || fail "missing expected message: $output"
}

# bad_value_reason()'s last branch: a value that is neither a secrets.*
# nor an inputs.* reference at all (a hardcoded literal), distinct from
# the wrong-secret-name case above.
@test "fails when a trivy-scan-retry call site sets dockerhub-username to a hardcoded literal" {
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
          dockerhub-username: some-hardcoded-user
          dockerhub-password: ${{ secrets.DOCKERHUB_TOKEN }}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ] || fail "expected failure, got status $status: $output"
    [[ "$output" == *"does not reference secrets.DOCKERHUB_USERNAME or a forwarded inputs.* value"* ]] || fail "missing expected message: $output"
}

# Value validation must not false-positive on trivy-scan-with-cache's own
# real forwarding shape (inputs.* pass-through, not a literal secret).
@test "passes when a trivy-scan-retry call site forwards a caller-owned inputs.* value" {
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
          dockerhub-username: ${{ inputs.dockerhub-username }}
          dockerhub-password: ${{ inputs.dockerhub-password }}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ] || fail "expected pass, got status $status: $output"
}

# Regression proof for the Codex finding that the scan is workflows-only:
# a call site one level down, inside a plain .github/actions wrapper,
# must be found too (real shape: trivy-scan-with-cache/action.yml).
@test "fails when a nested composite action (not a workflow) calls trivy-scan-retry without dockerhub wiring" {
    write_wrapper_fixture
    mkdir -p "$fixture_root/.github/actions/some-wrapper-action"
    cat > "$fixture_root/.github/actions/some-wrapper-action/action.yml" <<'EOF'
name: Some wrapper action
runs:
  using: composite
  steps:
    - name: Scan image with Trivy
      uses: ./.github/actions/trivy-scan-retry
      with:
        username: ${{ inputs.registry-username }}
        password: ${{ inputs.registry-password }}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ] || fail "expected failure, got status $status: $output"
    [[ "$output" == *"some-wrapper-action/action.yml"* ]] || fail "nested .github/actions call site was not scanned: $output"
    [[ "$output" == *"missing dockerhub-username and dockerhub-password"* ]] || fail "missing expected message: $output"
}

# Indentation independence: the second call site sits under a dash-only
# list-item line (`- \n  name: ...`), a real shape a hardcoded-column
# check would miscompute.
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
