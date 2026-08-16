#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: exercises scripts/untracked/check-short-sha-truncation.sh against throwaway
#   fixture trees (mirrors check_review_chronology_comments.bats's fixture
#   shape), proving both the passing and the fail-closed path.
# Why: a check that only ever runs against an already-green tree never
#   proves its fail-closed path is reachable (AG-VAL-024).
# From: Issue #1095 (G2) | PR #1503

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/untracked/check-short-sha-truncation.sh"
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

@test "fails on a hardcoded ::7} truncation in a workflow file" {
    # What: proves the base ::N shape is caught in a workflow file.
    # From: PR #1503
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

@test "fails on a hardcoded :0:7 truncation in a scripts/lib file" {
    # What: proves the :0:N shape is caught in a scripts/lib file.
    # From: PR #1503
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short_sha="${BUILD_SHA:0:7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a differently-lengthed hardcode too, not only 7" {
    # What: proves the guard bans the literal-length pattern itself, not
    #   specifically the number 7.
    # From: PR #1503
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

@test "fails on a *_sha_short-named assignment, not only short_sha itself" {
    # What: proves an exact-match-only guard on the identifier "short_sha"
    #   would miss this real shape (e.g. base_sha_short/ancestor_sha_short).
    # From: PR #1503
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
base_sha_short="${base_sha:0:7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a bare interpolation, not only a dedicated assignment" {
    # What: proves a hardcoded slice embedded directly inside a larger
    #   string (not assigned to its own variable first) is still caught.
    # From: PR #1503
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
candidate_tag="ghcr.io/example/svc:sha-${ancestor_sha:0:7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a digit before sha in the variable name, e.g. commit1_sha" {
    # What: proves a prefix containing a digit (commit1_sha) is still caught,
    #   even though a naive [A-Za-z_]* prefix class would reject it.
    # From: PR #1503
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
candidate="${commit1_sha:0:7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a whitespace-padded :0:7 slice, e.g. \${GITHUB_SHA: 0 : 7}" {
    # What: proves whitespace around the colon/number is still caught.
    # Why: bash's substring-expansion grammar tolerates that whitespace, so
    #   an exact-`:0:7`-only pattern would let this reformatted hardcode by.
    # From: PR #1503
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short_sha="${GITHUB_SHA: 0 : 7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a whitespace-padded ::7 slice too" {
    # What: proves the whitespace-tolerant match also covers the ::N form.
    # From: PR #1503
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short_sha="${GITHUB_SHA : : 7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
}

@test "propagates a real grep failure instead of folding it into a clean pass" {
    # What: makes the scanned file unreadable (still containing a violation)
    #   and proves the guard fails closed instead of reporting clean.
    # Why: a bare `grep ... || true` cannot distinguish "no match" (status 1)
    #   from "grep itself failed" (status >1).
    # From: PR #1503
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short_sha="${COMMIT_SHA::7}"
EOF
    chmod 000 "$fixture_root/scripts/lib/example.sh"

    run bash "$script" "$fixture_root"
    chmod 644 "$fixture_root/scripts/lib/example.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"grep"*"failed"* ]] || fail "did not diagnose the grep failure: $output"
    [[ "$output" != *"No hardcoded"* ]] || fail "reported a false clean pass despite the unreadable file: $output"
}

@test "passes when the site reads dmeta_short_sha() instead" {
    # What: proves the guard passes once the site reads the shared helper.
    # From: PR #1503
    cat > "$fixture_root/.github/workflows/example.yml" <<'EOF'
jobs:
  example:
    steps:
      - run: |
          source "$GITHUB_WORKSPACE/scripts/lib/docker-metadata.sh"
          short_sha="$(dmeta_short_sha "$COMMIT_SHA")"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No hardcoded"* ]] || fail "did not report a clean pass: $output"
}

@test "does not flag docker-metadata.sh's own implementation (variable length, not a literal)" {
    # What: proves a variable-length slice (the guard's own exemption target)
    #   is not flagged as a literal-length hardcode.
    # From: PR #1503
    cat > "$fixture_root/scripts/lib/docker-metadata.sh" <<'EOF'
#!/usr/bin/env bash
dmeta_short_sha() {
    local full_sha="$1"
    local length="${DOCKER_METADATA_SHORT_SHA_LENGTH:-7}"
    printf '%s\n' "${full_sha:0:length}"
}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "does not flag a file outside the scoped workflow/scripts-lib paths" {
    # What: proves the guard's scope is limited to workflow/scripts-lib paths.
    # From: PR #1503
    mkdir -p "$fixture_root/docs"
    cat > "$fixture_root/docs/example.md" <<'EOF'
A commit SHA is often shown truncated, e.g. `short_sha="${COMMIT_SHA::7}"`
as an illustrative example in documentation prose.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "passes on an empty fixture tree" {
    # What: proves an empty tree is a clean pass, not a false failure.
    # From: PR #1503
    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "fails closed, with a diagnostic, when git ls-files itself fails" {
    # What: creates an empty ".git" directory (a real "not a git repository"
    #   failure) and proves the guard fails closed instead of scanning zero
    #   files silently.
    # Why: a process-substitution-based `mapfile` cannot see this failure,
    #   even under `set -euo pipefail`.
    # From: PR #1503
    rm -rf "$fixture_root/.git"
    mkdir -p "$fixture_root/.git"
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short_sha="${GITHUB_SHA::7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"git ls-files"*"failed"* ]] || fail "did not diagnose the git ls-files failure: $output"
    [[ "$output" != *"No hardcoded"* ]] || fail "reported a false clean pass despite git ls-files failing: $output"
}
