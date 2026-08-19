#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: exercises the script's three checks against fixture trees.
# Why: `mktemp -d` (not BATS_TEST_TMPDIR) keeps the fixture root
#   unambiguously outside this repo's own .git, since the script
#   switches its file-listing strategy on that.
# From: PR #1546

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/untracked/check-review-chronology-comments.sh"
    fixture_root="$(mktemp -d)"
}

teardown() {
    # What: only removes fixture_root when it is a real, non-empty directory.
    # Why: a silently-empty fixture_root must not turn rm -rf into a blind
    #   delete of an unintended path.
    [ -n "$fixture_root" ] && [ -d "$fixture_root" ] && rm -rf "$fixture_root"
}

# What: prints $1 to stderr and fails the current test.
# Why: gives a real diagnostic instead of bats' bare assertion failure.
# From: PR #1546
fail() {
    echo "$1" >&2
    return 1
}

# What: a comment containing 'caught in review'.
# Why: baseline positive case for check_review_chronology()'s discovery-verb pattern.
# From: PR #1546
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

# What: a comment containing 'before this fix'.
# Why: covers the deictic self-reference alternation, not just the discovery-verb one.
# From: PR #1546
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

# What: 'flagged in review' inside a Rust // comment.
# Why: proves the pattern isn't shell-comment-specific.
# From: PR #1546
@test "fails when a comment says 'flagged in review on PR #743'" {
    cat > "$fixture_root/example.rs" <<'EOF'
// register a secondary against it (flagged in review on PR #743). The
// first five checks mirror setup.sh's own pattern set case-for-case.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.rs:1"* ]] || fail "did not name the offending line: $output"
}

# What: the verb AFTER 'review' instead of before it.
# Why: covers the pattern's second alternation (review ... <verb>), not just <verb> ... review.
# From: PR #1546
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

# What: 'prior to this change' instead of 'before this fix'.
# Why: covers the other two nouns (change/commit/patch) the deictic alternation accepts.
# From: PR #1546
@test "fails when a comment says 'prior to this change'" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# This value was never resolved generically per matrix.service prior to this change -- only this branch was narrowed.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:2"* ]] || fail "did not name the offending line: $output"
}

# What: 'caught during self-review'.
# Why: covers the optional (self-)review suffix on the discovery-verb alternation.
# From: PR #1546
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

# What: 'manual review' with no discovery verb nearby.
# Why: proves the pattern doesn't false-positive on any mention of the word review.
# From: PR #1546
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

# What: 'remembered' next to review.
# Why: 'remembered' is not in DISCOVERY_VERBS, so this must not match.
# From: PR #1546
@test "passes on 'remembered during review' (a process note, not a discovery verb)" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# This script makes "no repeat-run coverage" a CI failure instead of
# something that has to be remembered during review.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

# What: the word 'regression' with no discovery verb.
# Why: guards against a naive substring match on 'regression'.
# From: PR #1546
@test "passes on 'regression pin' alone with no nearby discovery verb" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# configured, not regenerate. Kept as a regression pin (see the test below).
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

# What: 'after this PR merges' and 'until this PR's own builds'.
# Why: these describe live CI behavior, not review history -- the deictic pattern must not fire on them.
# From: PR #1546
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

# What: a banned phrase inside a *.md file.
# Why: is_excluded() must skip documentation files even when their prose happens to match.
# From: PR #1546
@test "does not scan excluded file types (e.g. *.md) even when they contain the banned phrasing" {
    cat > "$fixture_root/NOTES.md" <<'EOF'
This bug was caught in review before merge, per the closed-issue write-up.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

# What: copies the script and this test file into the fixture, scans it.
# Why: both quote the banned phrasing verbatim; without the self-
#   reference exclusion, the guard would fail against its own repo.
# From: PR #1546
@test "does not flag itself: the script's own file and its bats test are excluded from the scan" {
    mkdir -p "$fixture_root/scripts/untracked" "$fixture_root/tests/bats"
    cp "$script" "$fixture_root/scripts/untracked/check-review-chronology-comments.sh"
    cp "$BATS_TEST_DIRNAME/check_review_chronology_comments.bats" \
        "$fixture_root/tests/bats/check_review_chronology_comments.bats"

    run bash "$fixture_root/scripts/untracked/check-review-chronology-comments.sh" "$fixture_root"
    [ "$status" -eq 0 ] || fail "guard flagged its own documentation/test file: $output"
}

# What: two separate files, each with one violation.
# Why: proves the guard doesn't stop at the first match.
# From: PR #1546
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

# What: a comment saying 'a review finding on PR #764'.
# Why: covers the noun form, no adjacent discovery verb required.
# From: PR #1546
@test "fails on the noun form 'review finding'" {
    cat > "$fixture_root/example.yml" <<'EOF'
on:
  push:
    # The isolation gap was a review finding on PR #764.
    branches: [master]
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.yml:3"* ]] || fail "did not name the offending line: $output"
}

# What: 'review finding' split across two adjacent comment lines.
# Why: proves the adjacent-comment-line join pass catches a wrapped phrase.
# From: PR #1385, PR #1546
@test "fails when 'review finding' is wrapped across adjacent comment lines" {
    cat > "$fixture_root/example.yml" <<'EOF'
on:
  push:
    # The isolation gap was a review
    # finding on PR #764 and must not survive line wrapping.
    branches: [master]
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.yml:3"* ]] || fail "did not catch the wrapped phrase: $output"
}

## Check 2: check_fragile_line_references() -- "(line ~N)" self-references

# What: a comment containing '(line ~890)'.
# Why: baseline positive case for check_fragile_line_references().
# From: PR #1546
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

# What: the '(see line N above)' variant.
# Why: covers the optional 'see'/'above' wording, not just the bare '(line N)' form.
# From: PR #1546
@test "fails when a comment says '(see line 42 above)'" {
    cat > "$fixture_root/example.rs" <<'EOF'
// The retry budget is already exhausted by this point (see line 42 above),
// so no further attempts happen here.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.rs:1"* ]] || fail "did not name the offending line: $output"
}

# What: 'line' used in ordinary prose, no parenthesized number.
# Why: proves the pattern requires the specific parenthesized-number shape, not any use of the word.
# From: PR #1546
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

# What: a Why: line repeating the same #N as the file's own From: pointer.
# Why: baseline positive case for check_bare_issue_ref_duplicates_from().
# From: PR #1546
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

# What: the From: line, which necessarily contains the number.
# Why: the From: line itself must never count as a duplicate of itself.
# From: PR #1546
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

# What: a comment citing a different issue number for historical grounding.
# Why: citing an unrelated issue for context (e.g. a prior fix for the same bug class) stays legal.
# From: PR #1546
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

# What: bare #NNN references with no From: line anywhere in the file.
# Why: the check must no-op entirely when there's no established number to duplicate.
# From: PR #1546
@test "passes on bare #NNN references in a file with no From: pointer at all (repo-wide historical-citation convention stays legal)" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# always()-teardown to release (#623/#703/#820/#932); see issue #1014 for the
# original subnet-reservation design this extends.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

# What: #8871 in a file whose From: is #887.
# Why: a naive substring match would wrongly treat #8871 as containing #887.
# From: PR #1546
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

# What: the number appearing only inside an echo string, not a real comment.
# Why: a #N inside program output text is not a governed comment.
# From: PR #1546
@test "passes when the only mention of the number is inside a double-quoted string literal, not a real comment" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# From: Issue #887
echo "checking issue #887's tracked state again here"
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

# What: a string-literal mention followed by a real duplicate comment on the same line.
# Why: the string match must not swallow the rest of the line and hide the real violation after it.
# From: PR #1546
@test "fails when a line has both a string-literal mention AND a real trailing comment repeating the number" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# From: Issue #887
echo "some string with #887 inside" # duplicate real comment ref to issue #887
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.sh:3"* ]] || fail "did not name the offending line (first occurrence in a string must not swallow a later real comment on the same line): $output"
}

# What: the single-quote variant of the double-quote test above.
# Why: single and double quotes must both be tracked as string delimiters.
# From: PR #1546
@test "passes when the only mention of the number is inside a single-quoted string literal" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# From: Issue #887
echo 'some string with #887 inside single quotes'
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

# What: a contraction (fluent-bit's) before a real duplicate reference on the same line.
# Why: a bare apostrophe must only open a string when not preceded by a word character, or the contraction would wrongly swallow the real duplicate after it.
# From: PR #1546
@test "fails on a real comment duplicate even when an earlier English contraction/possessive apostrophe appears on the same line" {
    cat > "$fixture_root/example.yml" <<'EOF'
volumes:
  # From: Issue #453
  ui-data:
  # fluent-bit's local file-output target (#453) and its own storage buffer.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.yml:4"* ]] || fail "a contraction apostrophe ('fluent-bit's') must not be misread as an unterminated string that swallows the real duplicate later on the line: $output"
}

# What: a contraction with no duplicate number anywhere on the line.
# Why: confirms the apostrophe-adjacency rule doesn't itself cause a false positive.
# From: PR #1546
@test "passes on a comment with a contraction apostrophe and no real duplicate reference" {
    cat > "$fixture_root/example.yml" <<'EOF'
volumes:
  # From: Issue #453
  # it's a plain comment with no other issue number mentioned here at all.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

# What: runs the real guard against the real repo tree, not a fixture.
# Why: an exact-status assertion here (not substring matching) is the only
#   thing that catches a real, repo-wide regression, not just fixture bugs.
# From: PR #1546
@test "the guard also passes when pointed at the real repository tree" {
    run bash "$script" "$repo_root"
    [ "$status" -eq 0 ] || fail "real repo tree is not clean per this guard: $output"
}
