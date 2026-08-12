#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
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

@test "fails on a *_sha_short-named assignment, not only short_sha itself" {
    # Real shape this widening exists to catch: scripts/lib/staging-ancestor-
    # fallback.sh named its own local variables base_sha_short/
    # ancestor_sha_short rather than short_sha, which an earlier, narrower
    # version of this guard (exact-match on the identifier "short_sha") could
    # not see at all.
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
base_sha_short="${base_sha:0:7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a bare interpolation, not only a dedicated assignment" {
    # Real shape this widening exists to catch: a hardcoded slice embedded
    # directly inside a larger string (e.g. a candidate tag) rather than
    # assigned to its own short_sha-named variable first.
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
candidate_tag="ghcr.io/example/svc:sha-${ancestor_sha:0:7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a digit before sha in the variable name, e.g. commit1_sha" {
    # A multi-candidate comparison naming its variables
    # commit1_sha/commit2_sha (or similarly base2_sha) is still a valid bash
    # identifier despite the digit, but a prefix class of [A-Za-z_]* only
    # rejects any digit anywhere before "sha", so this exact shape would pass
    # the guard silently even though it independently hardcodes the
    # truncation length just like every other flagged shape.
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
candidate="${commit1_sha:0:7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a whitespace-padded :0:7 slice, e.g. \${GITHUB_SHA: 0 : 7}" {
    # Bash's substring-expansion grammar evaluates offset/length as
    # arithmetic expressions, so it tolerates embedded whitespace around
    # either colon and either number: `${GITHUB_SHA: 0 : 7}` slices
    # identically to `${GITHUB_SHA:0:7}`. A pattern that only matched the
    # exact `:0:7` shape (no whitespace) would let this reformatted
    # hardcode bypass the guard entirely.
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short_sha="${GITHUB_SHA: 0 : 7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails on a whitespace-padded ::7 slice too" {
    cat > "$fixture_root/scripts/lib/example.sh" <<'EOF'
#!/usr/bin/env bash
short_sha="${GITHUB_SHA : : 7}"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
}

@test "propagates a real grep failure instead of folding it into a clean pass" {
    # A bare `grep ... || true` cannot distinguish grep's exit status 1
    # ("no match", the normal outcome for most scanned files) from any
    # status greater than 1 (grep itself failed, e.g. an unreadable file
    # from corrupted runner permissions) -- both collapse to a silently
    # accepted "no violations here". Reproduced by making the scanned file
    # itself unreadable while it still contains a banned slice, so a
    # false "No hardcoded ... found" would be observably wrong, not just
    # theoretically possible.
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

@test "fails closed, with a diagnostic, when git ls-files itself fails" {
    # `mapfile -t files < <(git ls-files ...)` cannot see a failure inside
    # its own process substitution -- not even under `set -euo pipefail`,
    # since pipefail only covers `|` pipelines, not `<(...)`. A broken
    # `.git` (present as a path, satisfying the `[ -e "$target_root/.git" ]`
    # branch check, but not a real repository) makes `git ls-files` fail
    # with "fatal: not a git repository" -- reproduced here with a plain
    # empty directory named `.git` (no real git metadata inside it), the
    # exact minimal shape that triggers this. A process-substitution-based
    # implementation would silently scan zero files and report a false
    # clean pass instead of failing loudly; the command-substitution form
    # below must not.
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
