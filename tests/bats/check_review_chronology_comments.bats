#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Exercises scripts/untracked/check-review-chronology-comments.sh (AG-CODE-003's
# review-chronology sub-pattern) against small, throwaway fixture trees
# rather than only this repo's own real tree, so both the passing and
# failing path are proven -- per AG-VAL-024, a check that only ever runs
# against an already-green tree never actually proves its fail-closed path
# is reachable. Mirrors tests/bats/check_workflow_line_limit.bats's fixture
# shape (a plain `mktemp -d` tree, not BATS_TEST_TMPDIR) so there is no
# ambiguity about whether the fixture root sits inside this repository's own
# git working tree -- a real concern for this specific script, since it
# switches its file-listing strategy on whether ".git" exists directly under
# the root it is pointed at.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/untracked/check-review-chronology-comments.sh"
    fixture_root="$(mktemp -d)"
}

teardown() {
    rm -rf "$fixture_root"
}

fail() {
    echo "$1" >&2
    return 1
}

@test "fails and names the file:line when a comment says 'caught in review'" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# These are NOT the same thing, and collapsing them was a real bug
# caught in review: something something.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:3"* ]] || fail "did not name the offending file:line: $output"
    [[ "$output" == *"AG-CODE-003"* ]] || fail "did not cite the governing rule: $output"
}

@test "fails when a comment says 'before this fix'" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# Feeding it the original spec here made every candidate host unresolvable,
# so it did not resolve to usable remote hosts before this fix -- use the
# bare base instead.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:3"* ]] || fail "did not name the offending line: $output"
}

@test "fails when a comment says 'flagged in review on PR #743'" {
    cat > "$fixture_root/example.rs" <<'EOF'
// register a secondary against it (flagged in review on PR #743). The
// first five checks mirror setup.sh's own pattern set case-for-case.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.rs:1"* ]] || fail "did not name the offending line: $output"
}

@test "fails on the reverse order 'a PR review (#765) found ...'" {
    cat > "$fixture_root/example.yml" <<'EOF'
on:
  push:
    # a PR review (#765) found the quickstart Compose environment allowlist
    # silently stopped before these three keys.
    branches: [master]
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.yml:3"* ]] || fail "did not name the offending line: $output"
}

@test "fails when a comment says 'prior to this change'" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# This value was never resolved generically per matrix.service prior to this change -- only this branch was narrowed.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "fails when a comment says 'caught during self-review'" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# An earlier version of this function did exactly that and was caught during self-review.
# Putting the assignment directly in the if condition makes it a tested context.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

@test "passes on a plain 'manual review' mention with no adjacent discovery verb" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# This also checks explicit compose passthrough (not just env-file presence)
# so that specific class of regression is caught here mechanically instead
# of relying on manual review to notice it.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No review-chronology comments found"* ]] || fail "unexpected output: $output"
}

@test "passes on 'remembered during review' (a process note, not a discovery verb)" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# This script makes "no repeat-run coverage" a CI failure instead of
# something that has to be remembered during review.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "passes on 'regression pin' alone with no nearby discovery verb" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# configured, not regenerate. Kept as a regression pin (see the test below).
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "passes on 'after this PR merges' / 'until this PR's OWN builds' (a live-CI referent, not a historical one)" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# workflow rebuilds and republishes it after this PR merges. Making this
# job never requests a heavy slot until this PR's OWN builds have already
# finished.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "does not scan excluded file types (e.g. *.md) even when they contain the banned phrasing" {
    cat > "$fixture_root/NOTES.md" <<'EOF'
This bug was caught in review before merge, per the closed-issue write-up.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "does not flag itself: the script's own file and its bats test are excluded from the scan" {
    # This script's header comment, and this very test file, legitimately
    # quote the banned phrasing verbatim as documentation of what they
    # detect -- if the self-reference exclusion were missing or broken, the
    # guard would fail against its own repository the moment this file (or
    # the script) were added, since both literally contain e.g. "caught in
    # review" as example text.
    mkdir -p "$fixture_root/scripts/untracked" "$fixture_root/tests/bats"
    cp "$script" "$fixture_root/scripts/untracked/check-review-chronology-comments.sh"
    cp "$BATS_TEST_DIRNAME/check_review_chronology_comments.bats" \
        "$fixture_root/tests/bats/check_review_chronology_comments.bats"

    run bash "$fixture_root/scripts/untracked/check-review-chronology-comments.sh" "$fixture_root"
    [ "$status" -eq 0 ] || fail "guard flagged its own documentation/test file: $output"
}

@test "multiple violations are all reported, each with its own file:line" {
    cat > "$fixture_root/a.sh" <<'EOF'
#!/usr/bin/env bash
# caught in review: first offender.
EOF
    cat > "$fixture_root/b.sh" <<'EOF'
#!/usr/bin/env bash
# Before this fix, second offender.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"a.sh:2"* ]] || fail "missing first offender: $output"
    [[ "$output" == *"b.sh:2"* ]] || fail "missing second offender: $output"
}

@test "the guard also passes when pointed at the real repository tree" {
    run bash "$script" "$repo_root"
    [ "$status" -eq 0 ] || fail "real repo tree is not clean per this guard: $output"
}
