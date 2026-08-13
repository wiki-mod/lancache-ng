#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Exercises scripts/check-review-chronology-comments.sh's three checks
# (review-chronology comments/AG-CODE-003, fragile "(line ~N)" self-
# references/AG-CODE-002, and issue/PR references duplicated outside their
# own From: pointer/AG-CODE-012) against small, throwaway fixture trees
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
    script="$repo_root/scripts/check-review-chronology-comments.sh"
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
    [[ "$output" == *"No review-chronology comments"* ]] || fail "unexpected output: $output"
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
    mkdir -p "$fixture_root/scripts" "$fixture_root/tests/bats"
    cp "$script" "$fixture_root/scripts/check-review-chronology-comments.sh"
    cp "$BATS_TEST_DIRNAME/check_review_chronology_comments.bats" \
        "$fixture_root/tests/bats/check_review_chronology_comments.bats"

    run bash "$fixture_root/scripts/check-review-chronology-comments.sh" "$fixture_root"
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

## Check 2: check_fragile_line_references() -- "(line ~N)" self-references

@test "fails and names the file:line when a comment says '(line ~890)'" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# secret_value_is_placeholder (line ~890) is reused here so a still-default
# placeholder is never treated as a real secret.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
    [[ "$output" == *"AG-CODE-002"* ]] || fail "did not cite the governing rule: $output"
}

@test "fails when a comment says '(see line 42 above)'" {
    cat > "$fixture_root/example.rs" <<'EOF'
// The retry budget is already exhausted by this point (see line 42 above),
// so no further attempts happen here.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.rs:1"* ]] || fail "did not name the offending line: $output"
}

@test "passes on prose mentioning 'line' without an adjacent parenthesized number" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# Every command line argument is validated up front, and the pipeline
# rejects anything that does not match, well before the 200th line of
# input is ever reached.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

## Check 3: check_bare_issue_ref_duplicates_from() -- redundant #NNN outside From:

@test "fails when a comment repeats a number already declared by this file's own From: pointer" {
    cat > "$fixture_root/example.dockerfile" <<'EOF'
# What: ccache preprocesses locally instead of shelling through distcc.
# Why: sccache always shells its own -E pass, which crashes against a
#      ,cpp-tagged distcc host list (the structural cause of issue #887).
# From: Issue #887
RUN true
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.dockerfile:3"* ]] || fail "did not name the offending line: $output"
    [[ "$output" == *"AG-CODE-012"* ]] || fail "did not cite the governing rule: $output"
}

@test "does not flag the From: pointer line itself" {
    cat > "$fixture_root/example.dockerfile" <<'EOF'
# What: normalizes a bare host:port to a redis:// URL before use.
# Why: ccache's manual requires an explicit scheme.
# From: Issue #887
RUN true
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "passes when a comment cites a DIFFERENT number than this file's own From: pointer (historical WHY-grounding stays legal)" {
    cat > "$fixture_root/example.dockerfile" <<'EOF'
# What: installs findutils so `find -printf` works under BusyBox.
# Why: the same BusyBox gap already hit and fixed for services/watchdog,
#      see issue #1346 and issue #1347 for the prior two instances.
# From: Issue #887
RUN true
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "passes on bare #NNN references in a file with no From: pointer at all (repo-wide historical-citation convention stays legal)" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# always()-teardown to release (#623/#703/#820/#932); see issue #1014 for the
# original subnet-reservation design this extends.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "passes when the duplicate-looking number is actually a different, longer number (#8871 does not match a From: #887)" {
    cat > "$fixture_root/example.dockerfile" <<'EOF'
# What: retries the upload once on a transient failure.
# Why: mirrors the retry budget introduced for issue #8871's flaky-mirror fix.
# From: Issue #887
RUN true
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "the guard also passes when pointed at the real repository tree" {
    run bash "$script" "$repo_root"
    [ "$status" -eq 0 ] || fail "real repo tree is not clean per this guard: $output"
}
