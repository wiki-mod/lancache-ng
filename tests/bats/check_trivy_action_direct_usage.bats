#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Exercises scripts/untracked/check-trivy-action-direct-usage.sh against
# throwaway fixture trees, both passing and failing cases.
# Why: a check proven only against an already-green tree never actually
# proves its fail-closed path is reachable (AG-VAL-024).
# From: PR #1542, Issue #1535

# What: check_dockerhub_wiring()'s tests below cover call-site YAML-shape
#   variation (quoting, indentation, key order, comments, missing with:) in one pass.
# Why: AG-VAL-036 -- enumerate a matcher's real variation axes up front,
#   not one gap per review round.
# From: PR #1543, Issue #1535

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/untracked/check-trivy-action-direct-usage.sh"
    fixture_root="$(mktemp -d)"
    mkdir -p "$fixture_root/.github/workflows" "$fixture_root/.github/actions/trivy-scan-retry"
}

teardown() {
    # What: only removes fixture_root when it is a real, non-empty directory.
    # Why: a silently-empty fixture_root (e.g. a failed mktemp -d in setup())
    #   must not turn rm -rf into a blind delete of an unintended path.
    # From: PR #1546 review, djdomi, 2026-08-16
    [ -n "$fixture_root" ] && [ -d "$fixture_root" ] && rm -rf "$fixture_root"
}


# What: prints a message to stderr and fails the current bats test.
# Why: gives assertion failures a readable message instead of bats' own
#   generic "[ status -eq 0 ]"-style output.
# From: PR #1542, Issue #1535
fail() {
    echo "$1" >&2
    return 1
}

# What: baseline happy path for check_direct_usage().
# Why: the one legitimate call site (inside the wrapper itself) must
#   not be flagged.
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
    # dockerhub-wiring concern has its own dedicated pass/fail fixtures
    # further below.
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

# What: a direct call site bypassing the wrapper.
# Why: fail-closed proof (AG-VAL-024) -- must be caught, not just the
#   passing case above.
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

# What: the same bypass, inside a second composite action instead of a workflow.
# Why: confirms the scan covers .github/actions too, not just workflows.
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

# What: a double-quoted `uses: "aquasecurity/trivy-action@..."` scalar.
# Why: regression proof for check_direct_usage()'s quoted-form fix --
#   must be caught too, not just the unquoted form above.
# From: PR #1543, Issue #1535
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

# What: dockerhub keys set in reverse order with an interleaved YAML comment.
# Why: the scanner must not depend on key order or the absence of a comment.
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

# What: a caller that never wires either dockerhub key at all.
# Why: the exact silent-fallback shape this guard exists to catch.
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

# What: only one of the two dockerhub keys set.
# Why: proves the two missing-key messages don't cross-contaminate
#   (see the second assertion below).
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

# What: a call site with no with: block at all.
# Why: the state machine must treat this distinctly, not as "0 keys found".
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

# What: a double-quoted `uses:` scalar for a trivy-scan-retry call site.
# Why: must be scanned, not silently skipped by the prefilter/regex.
# From: PR #1543, Issue #1535
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

# What: single-quoted `uses:` scalar variant, positive case.
# Why: same quoted-form coverage as the double-quoted test above.
# From: PR #1543, Issue #1535
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

# What: dockerhub-username set to a present-but-empty literal.
# Why: an empty value used to pass the old key-presence-only check;
#   must fail now that values are validated.
# From: PR #1543, Issue #1535
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

# What: dockerhub-username referencing the wrong secret name (DOCKERHUB_USER).
# Why: non-empty but still wrong -- the same value-validation gap as the
#   empty-literal case above.
# From: PR #1543, Issue #1535
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

# What: a longer secret name sharing the expected prefix (DOCKERHUB_USERNAME_OLD).
# Why: an unanchored regex would let this falsely pass as the expected secret.
# From: PR #1543, Issue #1535
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

# What: dockerhub-username set to a hardcoded literal (not secrets.*/inputs.*).
# Why: exercises bad_value_reason()'s last branch, distinct from the
#   wrong-secret-name case above.
# From: PR #1543, Issue #1535
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

# What: dockerhub keys forwarded via inputs.* (a caller-owned pass-through).
# Why: value validation must not false-positive on trivy-scan-with-cache's
#   own real forwarding shape.
# From: PR #1543, Issue #1535
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

# What: a trivy-scan-retry call site nested inside a plain .github/actions
#   wrapper (not a workflow).
# Why: the scan must not be workflows-only -- this is trivy-scan-with-
#   cache/action.yml's real shape.
# From: PR #1543, Issue #1535
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

# What: two call sites in one file at different indentation levels.
# Why: the second sits under a dash-only list-item line -- a real shape
#   a hardcoded-column check would miscompute.
# From: PR #1543, Issue #1535
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
