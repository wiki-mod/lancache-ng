#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: Exercises check-deny-short-sha.sh with fixture trees
# Why: Verifies fail-closed path and false-positive coverage
# From: Issue #1095

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/untracked/check-deny-short-sha.sh"
    fixture_root="$(mktemp -d)"
    mkdir -p "$fixture_root/.github/workflows" "$fixture_root/scripts/lib"
}

teardown() {
    rm -rf "$fixture_root"
}

fail() {
    echo "$1" >&2
    return 1
}

@test "fails on a ::7} slice in a workflow file" {
    # What: Detects ::N slice patterns in workflow files
    # Why: Validates detection in .github/workflows files
    # From: Issue #1095
    cat > "$fixture_root/.github/workflows/example.yml" <<'EOF'
jobs:
  example:
    steps:
      - run: |
          short_sha="${COMMIT_SHA::7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.yml:5"* ]] || fail "did not name the offending file:line: $output"
    [[ "$output" == *"G2"* ]] || fail "did not cite the governing gap: $output"
}

@test "fails on a :0:7 slice in a scripts/lib file" {
    # What: Detects :0:N slice patterns in scripts/lib files
    # Why: Validates detection in scripts/lib directory
    # From: Issue #1095
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short_sha="${BUILD_SHA:0:7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a differently-lengthed slice too, not only 7" {
    # What: Verifies pattern banning applies to all slice lengths
    # Why: Ensures detection works for any slice length
    # From: Issue #1095
    cat > "$fixture_root/.github/workflows/example.yml" <<'EOF'
jobs:
  example:
    steps:
      - run: |
          short_sha="${COMMIT_SHA::12}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
}

@test "fails on a variable-length slice too, not only a literal length (no exemption)" {
    # What: Detects variable-length slices like ${sha:0:length}
    # Why: No exemptions exist for variable-length slice patterns
    # From: Issue #1095
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short_sha() {
    local full_sha="$1"
    local length="${DOCKER_METADATA_SHORT_SHA_LENGTH:-7}"
    printf '%s\n' "${full_sha:0:length}"
}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh"* ]] || fail "did not name the offending file: $output"
}

@test "fails on a *_sha_short-named assignment, not only short_sha itself" {
    # What: Detects any *_sha_short naming patterns in slices
    # Why: Prevents false negatives from varied SHA patterns
    # From: Issue #1095
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
base_sha_short="${base_sha:0:7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a bare interpolation, not only a dedicated assignment" {
    # What: Detects slices embedded in string interpolation
    # Why: Catches slices outside dedicated variable assignments
    # From: Issue #1095
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
candidate_tag="ghcr.io/example/svc:sha-${ancestor_sha:0:7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a commit/candidate/revision-named slice, not only sha-named ones" {
    # What: Detects slices on commit/candidate/revision variables
    # Why: Covers staging-ancestor-fallback.sh SHA variables
    # From: Issue #1095 | PR #1611
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short="${commit:0:7}"
short2="${candidate::7}"
short3="${revision:0:8}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not catch the commit-named slice: $output"
    [[ "$output" == *"example.sh:3"* ]] || fail "did not catch the candidate-named slice: $output"
    [[ "$output" == *"example.sh:4"* ]] || fail "did not catch the revision-named slice: $output"
}

@test "fails on a digit before sha in the variable name, e.g. commit1_sha" {
    # What: Detects digit-prefixed SHA patterns like commit1_sha
    # Why: Validates complex prefix patterns in slice detection
    # From: Issue #1095
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
candidate="${commit1_sha:0:7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a whitespace-padded :0:7 slice, e.g. \${GITHUB_SHA: 0 : 7}" {
    # What: Detects whitespace-padded slices like :0:7
    # Why: Bash substring expansion tolerates format variations
    # From: Issue #1095
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short_sha="${GITHUB_SHA: 0 : 7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a whitespace-padded ::7 slice too" {
    # What: Detects whitespace in ::N form slices
    # Why: Confirms whitespace tolerance extends to ::N patterns
    # From: Issue #1095
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short_sha="${GITHUB_SHA : : 7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
}

@test "propagates a real grep failure instead of folding it into a clean pass" {
    # What: Verifies grep failure doesn't result in false pass
    # Why: Distinguishes grep failure from no-match status code
    # From: Issue #1095
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short_sha="${COMMIT_SHA::7}"
EOF
    chmod 000 "$fixture_root/scripts/lib/example.sh"

    run bash "$script" "$fixture_root"
    chmod 644 "$fixture_root/scripts/lib/example.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"grep"*"failed"* ]] || fail "did not diagnose the grep failure: $output"
    [[ "$output" != *"No short-SHA slices"* ]] || fail "reported a false clean pass despite the unreadable file: $output"
}

@test "does not flag a bare full-SHA interpolation (no slice at all)" {
    # What: Bare full-SHA references don't trigger false positives
    # Why: Proves full-SHA references never trigger the guard
    # From: Issue #1095
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
full_image="ghcr.io/${repository}/${service}:sha-${commit}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No short-SHA slices"* ]] || fail "did not report a clean pass: $output"
}

@test "does not flag scripts/lib/staging-ancestor-fallback.sh's own legacy-tag fallback (git rev-parse, not a bash slice)" {
    # What: Exempts git rev-parse --short fallback mechanism
    # Why: Real transition-compat mechanism must remain shippable
    # From: Issue #1095
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
legacy_short="$(git -C "$git_dir" rev-parse --short=7 "$commit" 2>/dev/null)"
legacy_image="ghcr.io/${repository}/${service}:sha-${legacy_short}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "does not flag a file outside the scoped workflow/scripts-lib paths" {
    # What: Only scans .github/workflows and scripts/lib paths
    # Why: Prevents false positives from documentation examples
    # From: Issue #1095
    mkdir -p "$fixture_root/docs"
    cat > "$fixture_root/docs/example.md" <<'EOF'
A commit SHA is often shown truncated, e.g. `short_sha="${COMMIT_SHA::7}"`
as an illustrative example in documentation prose.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "passes on an empty fixture tree" {
    # What: Empty fixture tree is treated as clean pass
    # Why: Ensures no false failures on minimal input
    # From: Issue #1095
    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "fails closed, with a diagnostic, when git ls-files itself fails" {
    # What: Fail-closed behavior when git ls-files itself fails
    # Why: Mapfile can't detect git ls-files failures directly
    # From: Issue #1095
    rm -rf "$fixture_root/.git"
    mkdir -p "$fixture_root/.git"
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short_sha="${GITHUB_SHA::7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"git ls-files"*"failed"* ]] || fail "did not diagnose the git ls-files failure: $output"
    [[ "$output" != *"No short-SHA slices"* ]] || fail "reported a false clean pass despite git ls-files failing: $output"
}
