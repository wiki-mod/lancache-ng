#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/check-pr-title-convention.sh (#850, AG-GH-018): the
# CI guard that validates a pull request's TITLE against this repo's
# Conventional-Commit taxonomy. This repo merges (not squashes) pull
# requests, so the PR title is the enforcement unit -- these fixtures write
# a title to a temp file and invoke the script the same way build-push.yml's
# pr-title-convention-check job does (a live-fetched `gh pr view --json
# title` value written to a file, then passed as the script's file
# argument).
#
# Per AG-VAL-024, the script is invoked via explicit `bash "$script"`
# rather than relying on the committed executable bit, and the fail-closed
# (non-draft, blocking-mode) path is exercised with a real failing input,
# not just reasoned about.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-pr-title-convention.sh"
    title_file="$BATS_TEST_TMPDIR/pr-title.txt"
}

write_title() {
    printf '%s' "$1" > "$title_file"
}

# --- Pass cases -------------------------------------------------------------

@test "passes: feat(dhcp): x -- standard type with a documented scope" {
    write_title 'feat(dhcp): x'
    run bash "$script" "$title_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"passed"* ]]
}

@test "passes: fix: y -- standard type with no scope (scope is optional)" {
    write_title 'fix: y'
    run bash "$script" "$title_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"passed"* ]]
}

@test "passes: feat!: z -- breaking-change marker with no scope" {
    write_title 'feat!: z'
    run bash "$script" "$title_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"passed"* ]]
}

@test "passes: fix(build-tools)!: w -- scope and breaking marker together" {
    write_title 'fix(build-tools)!: w'
    run bash "$script" "$title_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"passed"* ]]
}

# --- Fail cases (non-draft, default blocking mode) --------------------------

@test "fails: Feature: x -- capitalized, non-conventional type" {
    write_title 'Feature: x'
    PR_DRAFT=false run bash "$script" "$title_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"AG-GH-018"* ]]
}

@test "fails: harden(ci): y -- 'harden' is not an allowed type" {
    write_title 'harden(ci): y'
    PR_DRAFT=false run bash "$script" "$title_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not one of the allowed types"* ]]
}

@test "fails: fix(bogus-scope): z -- scope not in the documented area list" {
    write_title 'fix(bogus-scope): z'
    PR_DRAFT=false run bash "$script" "$title_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not one of the documented areas"* ]]
}

@test "fails: no-conventional-commit-prefix -- plain title with no type at all" {
    write_title 'update the readme with new instructions'
    PR_DRAFT=false run bash "$script" "$title_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not start with a Conventional-Commit prefix"* ]]
}

@test "fails: security: x -- non-standard type gets the pending-decision explanation" {
    write_title 'security: harden the docker socket proxy'
    PR_DRAFT=false run bash "$script" "$title_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pending maintainer decision"* ]]
    [[ "$output" == *"#850"* ]]
}

# --- Draft-PR non-blocking behavior ------------------------------------------

@test "draft PR: a non-conforming title warns but exits 0 (non-blocking)" {
    write_title 'harden(ci): y'
    PR_DRAFT=true run bash "$script" "$title_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"draft PR"* ]]
}

# --- Grace-period warn-only mode ---------------------------------------------

@test "PR_TITLE_LINT_MODE=warn: a non-conforming title on a non-draft PR warns but exits 0" {
    write_title 'harden(ci): y'
    PR_DRAFT=false PR_TITLE_LINT_MODE=warn run bash "$script" "$title_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"grace-period mode"* ]]
}

# --- dependabot exemption -----------------------------------------------------

@test "dependabot[bot] PRs are exempt regardless of title content" {
    write_title 'Bump some-crate from 1.0.0 to 1.1.0'
    PR_AUTHOR='dependabot[bot]' run bash "$script" "$title_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped"* ]]
}

# --- Environment-variable input path ------------------------------------------

@test "reads the title from PR_TITLE when no file argument is given" {
    PR_TITLE='docs(governance): tighten a rule' run bash "$script"
    [ "$status" -eq 0 ]
    [[ "$output" == *"passed"* ]]
}

# --- CRLF handling -------------------------------------------------------------

@test "strips a trailing CRLF from a gh-pr-view-style title before matching" {
    printf 'feat(ui): add a toggle\r\n' > "$title_file"
    run bash "$script" "$title_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"passed"* ]]
}
