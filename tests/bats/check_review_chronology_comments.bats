#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: test guards for positive/negative comment cases.
# Why: mktemp fixture location affects detection strategy.
# From: PR #1546 | Issue #1095

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/untracked/check-review-chronology-comments.sh"
    fixture_root="$(mktemp -d)"
}

teardown() {
    # What: only removes real, non-empty fixture_root
    # Why: protects against rm -rf on empty/failed mktemp
    # From: PR #1546
    [ -n "$fixture_root" ] && [ -d "$fixture_root" ] && rm -rf "$fixture_root"
}

# What: prints $1 to stderr and fails the current test.
# Why: gives real diagnostic instead of bats' bare
# From: PR #1546
fail() {
    echo "$1" >&2
    return 1
}

# What: a comment containing 'caught in review'.
# Why: baseline positive case for check_review_chronology()'
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
# Why: covers deictic self-reference alternation, not just
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
# Why: covers pattern's second alternation (review ... <verb
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
# Why: covers other two nouns (change/commit/patch)
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
# Why: covers optional (self-)review suffix on discovery-ver
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
# Why: proves pattern doesn't false-positive on any
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
# Why: 'remembered' is not in DISCOVERY_VERBS, so this
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
# Why: guards against naive substring match on 'regression'.
# From: PR #1546
@test "passes on 'regression pin' alone with no nearby discovery verb" {
    cat > "$fixture_root/example.sh" <<'EOF'
#!/usr/bin/env bash
# configured, not regenerate. Kept as a regression pin (see the test below).
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

# What: 'after this PR merges' & 'until this PR's own
# Why: these describe live CI behavior, not review history -
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
# Why: is_excluded() must skip documentation files even
# From: PR #1546
@test "does not scan excluded file types (e.g. *.md) even when they contain the banned phrasing" {
    cat > "$fixture_root/NOTES.md" <<'EOF'
This bug was caught in review before merge, per the closed-issue write-up.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

# What: copies script & this test file into fixture, scans
# Why: both quote banned phrasing verbatim; without self-
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
# Why: covers noun form, no adjacent discovery verb
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

# What: 'review finding' split across two adjacent comment
# Why: proves adjacent-comment-line join pass catches
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
# Why: baseline positive case for
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
# Why: covers optional 'see'/'above' wording, not just
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

# What: 'line' used in ordinary prose, no parenthesized
# Why: proves pattern requires specific parenthesized-number
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

# What: Why: line repeating same #N as file's own From:
# Why: baseline positive case for
# From: PR #1546
@test "fails when a comment repeats a number already declared by this file's own From: pointer" {
    cat > "$fixture_root/example.dockerfile" <<'EOF'
# What: ccache preprocesses locally instead of shelling through distcc.
# Why: shells own -E pass, which crashes ,cpp-tagged distcc host list
# From: Issue #887
RUN true
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.dockerfile:3"* ]] || fail "did not name the offending line: $output"
    [[ "$output" == *"AG-CODE-012"* ]] || fail "did not cite the governing rule: $output"
}

# What: From: line, which necessarily contains number.
# Why: From: line itself must never count as duplicate of
# From: PR #1546
@test "does not flag the From: pointer line itself" {
    cat > "$fixture_root/example.dockerfile" <<'EOF'
# What: normalizes bare host:port to redis:// URL before
# Why: ccache's manual requires an explicit scheme.
# From: Issue #887
RUN true
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

# What: comment citing different issue number for
# Why: citing an unrelated issue for context (e.g. prior
# From: PR #1546
@test "passes when a comment cites a DIFFERENT number than this file's own From: pointer (historical WHY-grounding stays legal)" {
    cat > "$fixture_root/example.dockerfile" <<'EOF'
# What: installs findutils so `find -printf` works under
# Why: same BusyBox gap already hit & fixed for services/wat
# From: Issue #887
RUN true
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

# What: bare #NNN references with no From: line anywhere
# Why: check must no-op entirely when there's no
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
# Why: naive substring match would wrongly treat #8871 as
# From: PR #1546
@test "passes when the duplicate-looking number is actually a different, longer number (#8871 does not match a From: #887)" {
    cat > "$fixture_root/example.dockerfile" <<'EOF'
# What: retries the upload once on a transient failure.
# Why: mirrors retry budget introduced for issue #8871's
# From: Issue #887
RUN true
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

# What: number appearing only inside an echo string, not
# Why: #N inside program output text is not governed
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

# What: string-literal mention followed by real duplicate
# Why: string match must not swallow rest of line & hide
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

# What: single-quote variant of double-quote test above.
# Why: single & double quotes must both be tracked as
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

# What: contraction (fluent-bit's) before real duplicate
# Why: bare apostrophe must only open string when not
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

# What: contraction with no duplicate number anywhere on
# Why: confirms apostrophe-adjacency rule doesn't itself
# From: PR #1546
@test "passes on a comment with a contraction apostrophe and no real duplicate reference" {
    cat > "$fixture_root/example.yml" <<'EOF'
volumes:
  # From: Issue #453
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

# What: runs real guard against real repo tree, not fixture.
# Why: an exact-status assertion here (not substring
# From: PR #1546
@test "the guard also passes when pointed at the real repository tree" {
    run bash "$script" "$repo_root"
    [ "$status" -eq 0 ] || fail "real repo tree is not clean per this guard: $output"
}

# What: explicit file args after target_root restrict scan
# Why: proves mode restricts scope before diff-mode tests
# From: Issue #1095
@test "explicit file args scan only those files, ignoring an unlisted violation in the same tree" {
    cat > "$fixture_root/violating.sh" <<'EOF'
# caught in review: this one should be ignored, it is not in the file list.
EOF
    cat > "$fixture_root/clean.sh" <<'EOF'
# A normal, compliant comment.
EOF

    run bash "$script" "$fixture_root" clean.sh
    [ "$status" -eq 0 ] || fail "explicit-file-list mode must not see violating.sh: $output"
}

# What: explicit file args still catch violation in listed
# Why: proves mode restricts scope, it does not disable
# From: Issue #1095
@test "explicit file args still fail on a violation in a listed file" {
    cat > "$fixture_root/violating.sh" <<'EOF'
# caught in review: this one is explicitly listed and must still fail.
EOF

    run bash "$script" "$fixture_root" violating.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *"violating.sh"* ]]
}

# What: CHRONOLOGY_WARN_ONLY=1 reports real violation
# Why: lets repo-wide baseline pass stay informational,
# From: Issue #1095
@test "CHRONOLOGY_WARN_ONLY=1 reports a violation as a warning and exits 0" {
    cat > "$fixture_root/example.sh" <<'EOF'
# caught in review: something something.
EOF

    CHRONOLOGY_WARN_ONLY=1 run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ] || fail "warn-only mode must exit 0 despite a real violation: $output"
    [[ "$output" == *"::warning::"* ]]
    [[ "$output" == *"example.sh"* ]]
}

# What: without CHRONOLOGY_WARN_ONLY, same violation still
# Why: confirms warn-only is opt-in, not the new default.
# From: Issue #1095
@test "the same violation still fails closed when CHRONOLOGY_WARN_ONLY is unset" {
    cat > "$fixture_root/example.sh" <<'EOF'
# caught in review: something something.
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
}

# What: sets up real bare-origin + work-dir git pair for
# Why: diff-mode env vars need real fetch/diff behavior,
# From: Issue #1095
setup_diff_fixture() {
    diff_origin_dir="$fixture_root/origin.git"
    diff_work_dir="$fixture_root/work"
    git init --quiet --bare "$diff_origin_dir"
    git init --quiet -b main "$diff_work_dir"
    mkdir -p "$diff_work_dir/scripts/untracked" "$diff_work_dir/scripts/lib"
    cp "$script" "$diff_work_dir/scripts/untracked/check-review-chronology-comments.sh"
    cp "$repo_root/scripts/lib/git-fetch-retry.sh" "$diff_work_dir/scripts/lib/git-fetch-retry.sh"
    (
        cd "$diff_work_dir" || exit 1
        git config user.email test@example.invalid
        git config user.name "Test"
        git remote add origin "$diff_origin_dir"
        printf '# A normal, compliant comment.\n' > example.sh
        git add example.sh scripts
        git commit --quiet -m "base commit"
        git push --quiet origin main
    )
    diff_base_sha="$(cd "$diff_work_dir" && git rev-parse HEAD)"
}

# What: diff-mode env vars, empty diff, must pass silently.
# Why: base case for CHRONOLOGY_DIFF_BASE_SHA/CHRONOLOGY_DIF
# From: Issue #1095
@test "diff mode passes silently when the diff is empty (base and head are the same commit)" {
    setup_diff_fixture
    run bash -c "cd '$diff_work_dir' && CHRONOLOGY_DIFF_BASE_SHA='$diff_base_sha' CHRONOLOGY_DIFF_BASE_REF=main GITHUB_SHA='$diff_base_sha' bash scripts/untracked/check-review-chronology-comments.sh"
    [ "$status" -eq 0 ]
}

# What: diff mode fails on real changed file that
# Why: proves diff-scoped path still detects real, in-diff
# From: Issue #1095
@test "diff mode fails on a real changed file that introduces a violation" {
    setup_diff_fixture
    (
        cd "$diff_work_dir"
        printf '# caught in review: this line should not exist here.\n' > bad.sh
        git add bad.sh
        git commit --quiet -m "add a file with a chronology violation"
    )
    diff_head_sha="$(cd "$diff_work_dir" && git rev-parse HEAD)"
    run bash -c "cd '$diff_work_dir' && CHRONOLOGY_DIFF_BASE_SHA='$diff_base_sha' CHRONOLOGY_DIFF_BASE_REF=main GITHUB_SHA='$diff_head_sha' bash scripts/untracked/check-review-chronology-comments.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"bad.sh"* ]]
}

# What: violation in file diff does NOT touch must not
# Why: this is entire point of diff mode -- an unrelated,
# From: Issue #1095
@test "diff mode: a pre-existing violation in a file outside this diff does not block the PR" {
    setup_diff_fixture
    (
        cd "$diff_work_dir"
        printf '# caught in review: pre-existing, not part of any diff.\n' > pre_existing_violation.sh
        git add pre_existing_violation.sh
        git commit --quiet -m "base commit gains an unrelated pre-existing violation"
        git push --quiet origin main
    )
    diff_new_base_sha="$(cd "$diff_work_dir" && git rev-parse HEAD)"
    (
        cd "$diff_work_dir"
        printf '# A second normal, compliant comment, the actual PR diff.\n' > unrelated_change.sh
        git add unrelated_change.sh
        git commit --quiet -m "the actual PR change, unrelated to the pre-existing violation"
    )
    diff_head_sha="$(cd "$diff_work_dir" && git rev-parse HEAD)"
    run bash -c "cd '$diff_work_dir' && CHRONOLOGY_DIFF_BASE_SHA='$diff_new_base_sha' CHRONOLOGY_DIFF_BASE_REF=main GITHUB_SHA='$diff_head_sha' bash scripts/untracked/check-review-chronology-comments.sh"
    [ "$status" -eq 0 ] || fail "a violation outside the diff must not fail this PR: $output"
}

# What: diff mode fails closed when required environment
# Why: mirrors check-pr-diff-file-headers.sh's own required-
# From: Issue #1095
@test "diff mode fails closed with a clear diagnostic when a required environment variable is missing" {
    setup_diff_fixture
    run bash -c "cd '$diff_work_dir' && CHRONOLOGY_DIFF_BASE_SHA='$diff_base_sha' GITHUB_SHA='$diff_base_sha' bash scripts/untracked/check-review-chronology-comments.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHRONOLOGY_DIFF_BASE_REF"* ]]
}

# What: diff mode fails closed when git diff itself fails
# Why: mirrors check-pr-diff-file-headers.sh's own
# From: Issue #1095
@test "diff mode fails closed when git diff itself fails after both reachability checks pass" {
    setup_diff_fixture
    real_git="$(command -v git)"
    mkdir -p "$fixture_root/bin"
    cat > "$fixture_root/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\${1-}" = diff ]; then
    echo "synthetic git diff failure" >&2
    exit 73
fi
exec "$real_git" "\$@"
EOF
    chmod +x "$fixture_root/bin/git"
    run bash -c "cd '$diff_work_dir' && PATH='$fixture_root/bin:$PATH' CHRONOLOGY_DIFF_BASE_SHA='$diff_base_sha' CHRONOLOGY_DIFF_BASE_REF=main GITHUB_SHA='$diff_base_sha' bash scripts/untracked/check-review-chronology-comments.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"git diff\` itself failed"* ]]
}
