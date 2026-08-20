#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: exercises scripts/untracked/check-deny-short-sha.sh against throwaway
#   fixture trees (mirrors check_review_chronology_comments.bats's fixture
#   shape), proving both the passing and the fail-closed path.
# Why: a check that only ever runs against an already-green tree never
#   proves its fail-closed path is reachable (AG-VAL-024); the guard was
#   repurposed from "enforce one consistent truncation length" to "deny any
#   slice outright" (maintainer decision, issue #1095: short SHAs are
#   banned, not merely required to stay consistent), so its own coverage
#   must prove the new full-SHA world produces zero false positives, not
#   only that the old hardcode shape is still caught.
# From: Issue #1095 (G2)

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
    # What: proves the base ::N shape is caught in a workflow file.
    # From: Issue #1095 (G2)
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
    # What: proves the :0:N shape is caught in a scripts/lib file.
    # From: Issue #1095 (G2)
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short_sha="${BUILD_SHA:0:7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a differently-lengthed slice too, not only 7" {
    # What: proves the guard bans the slice pattern itself, not specifically 7.
    # From: Issue #1095 (G2)
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
    # What: proves a variable-length slice (the shape dmeta_short_sha() used
    #   to have, e.g. \${full_sha:0:length}) is caught just like a literal
    #   length -- the guard's old carve-out for this exact shape is gone.
    # Why: maintainer decision, issue #1095: "Kurzformat ist verboten. Das
    #   war noch nie von mir genehmigt." -- no named exemption in the guard,
    #   for any reason, including its own former single declared derivation.
    # From: Issue #1095 (G2)
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
    # What: proves an exact-match-only guard on the identifier "short_sha"
    #   would miss this real shape (e.g. base_sha_short/ancestor_sha_short).
    # From: Issue #1095 (G2)
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
base_sha_short="${base_sha:0:7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a bare interpolation, not only a dedicated assignment" {
    # What: proves a slice embedded directly inside a larger string (not
    #   assigned to its own variable first) is still caught.
    # From: Issue #1095 (G2)
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
    # From: Issue #1095 (G2)
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
    #   an exact-`:0:7`-only pattern would let this reformatted slice by.
    # From: Issue #1095 (G2)
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
    # From: Issue #1095 (G2)
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
    # From: Issue #1095 (G2)
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
    # What: proves the new full-SHA world produces zero false positives --
    #   a bare `\${full_sha}`/`\${commit}` reference with no slice syntax at
    #   all must never be flagged, regardless of the runtime value's length.
    # Why: the guard matches source-level slice SYNTAX, not runtime length;
    #   this is the exact shape every real call site now uses (e.g.
    #   scripts/lib/staging-ancestor-fallback.sh's own
    #   saf_resolve_sha_image_ref, build-push.yml's `sha-${BUILD_SHA}`).
    # From: Issue #1095 (G2)
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
full_image="ghcr.io/${repository}/${service}:sha-${commit}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No short-SHA slices"* ]] || fail "did not report a clean pass: $output"
}

@test "does not flag scripts/lib/staging-ancestor-fallback.sh's own legacy-tag fallback (git rev-parse, not a bash slice)" {
    # What: proves the real, maintainer-mandated transition-compat mechanism
    #   (probing GHCR for the ~37k already-published legacy 7-char tags via
    #   `git rev-parse --short=7`, never a local bash slice) is not itself
    #   flagged by the guard it must coexist with.
    # Why: this is the exact shape saf_resolve_sha_image_ref uses; a false
    #   positive here would make the real fallback mechanism unshippable.
    # From: Issue #1095 (G2)
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
legacy_short="$(git -C "$git_dir" rev-parse --short=7 "$commit" 2>/dev/null)"
legacy_image="ghcr.io/${repository}/${service}:sha-${legacy_short}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "does not flag a file outside the scoped workflow/scripts-lib paths" {
    # What: proves the guard's scope is limited to workflow/scripts-lib paths.
    # From: Issue #1095 (G2)
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
    # From: Issue #1095 (G2)
    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "fails closed, with a diagnostic, when git ls-files itself fails" {
    # What: creates an empty ".git" directory (a real "not a git repository"
    #   failure) and proves the guard fails closed instead of scanning zero
    #   files silently.
    # Why: a process-substitution-based `mapfile` cannot see this failure,
    #   even under `set -euo pipefail`.
    # From: Issue #1095 (G2)
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
