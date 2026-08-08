#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Exercises scripts/check-short-sha-truncation.sh (issue #1095 G2) against
# small, throwaway fixture trees rather than only this repo's own real tree,
# so both the passing and failing path are proven -- per AG-VAL-024, a check
# that only ever runs against an already-green tree never actually proves
# its fail-closed path is reachable. Mirrors
# tests/bats/check_review_chronology_comments.bats's fixture shape (a plain
# `mktemp -d` tree, not BATS_TEST_TMPDIR), for the same reason: this script
# also switches its file-listing strategy on whether ".git" exists directly
# under the root it is pointed at.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/check-short-sha-truncation.sh"
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
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short_sha="${BUILD_SHA:0:7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a differently-lengthed hardcode too, not only 7" {
    # The guard bans the pattern itself (an independent literal length),
    # not specifically the number 7 -- a future widened length hardcoded
    # independently at a new site would be exactly the same divergence risk.
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

@test "passes when the site reads dmeta_short_sha() instead" {
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
    mkdir -p "$fixture_root/docs"
    cat > "$fixture_root/docs/example.md" <<'EOF'
A commit SHA is often shown truncated, e.g. `short_sha="${COMMIT_SHA::7}"`
as an illustrative example in documentation prose.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "passes on an empty fixture tree" {
    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}
