#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/check-changelog-direct-edit.sh (#893): the warn-only CI
# guard that flags a PR editing CHANGELOG.md directly, since #899 that file is
# normally written by an automated bot commit (update-changelog.yaml), never
# through a PR. This suite invokes the real script by path (per AG-VAL-024:
# `run bash "$script"`, not relying on the committed executable bit) against
# fixture changed-files/labels files, mirroring check_workflow_service_lists.bats's
# pattern of pointing the guard at fixtures instead of the real repo state.
#
# The central property every test here must hold, per #893's explicit
# "warn-only, not a hard failure" design and this repo's Required Validation
# rule for warn-only checks: the script's exit status is ALWAYS 0, regardless
# of what it finds or how malformed its input is. Only stdout content (a
# `::warning::`, a `::notice::`, or nothing) differs.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-changelog-direct-edit.sh"
    changed_files="$BATS_TEST_TMPDIR/changed-files.txt"
    labels_file="$BATS_TEST_TMPDIR/labels.txt"
    unset CHANGELOG_GUARD_PR_LABELS
}

@test "stays silent and exits 0 when CHANGELOG.md is not among the changed files" {
    printf 'setup.sh\nREADME.md\n' > "$changed_files"
    run bash "$script" --changed-files-file "$changed_files"
    [ "$status" -eq 0 ]
    [[ "$output" != *"CHANGELOG.md"* ]]
}

@test "warns (but exits 0) when CHANGELOG.md is edited without the release label" {
    printf 'CHANGELOG.md\nsetup.sh\n' > "$changed_files"
    run bash "$script" --changed-files-file "$changed_files"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"* ]]
    [[ "$output" == *"CHANGELOG.md"* ]]
}

@test "prints a notice instead of a warning when the PR carries the release label (env var form)" {
    printf 'CHANGELOG.md\n' > "$changed_files"
    CHANGELOG_GUARD_PR_LABELS="documentation,release" run bash "$script" --changed-files-file "$changed_files"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::notice::"* ]]
    [[ "$output" != *"::warning::"* ]]
}

@test "prints a notice instead of a warning when the PR carries the release label (fixture file form)" {
    printf 'CHANGELOG.md\n' > "$changed_files"
    printf 'documentation\nrelease\n' > "$labels_file"
    run bash "$script" --changed-files-file "$changed_files" --labels-file "$labels_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::notice::"* ]]
    [[ "$output" != *"::warning::"* ]]
}

@test "does not treat a partial label match as the release label" {
    printf 'CHANGELOG.md\n' > "$changed_files"
    CHANGELOG_GUARD_PR_LABELS="pre-release,release-notes" run bash "$script" --changed-files-file "$changed_files"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"* ]]
}

@test "does not treat a path merely ending in CHANGELOG.md as a direct root edit" {
    printf 'docs/some/nested/OTHER_CHANGELOG.md\n' > "$changed_files"
    run bash "$script" --changed-files-file "$changed_files"
    [ "$status" -eq 0 ]
    [[ "$output" != *"::warning::"* ]]
    [[ "$output" != *"::notice::"* ]]
}

@test "never fails even with a missing changed-files file (warn-only, exit 0 always)" {
    run bash "$script" --changed-files-file "$BATS_TEST_TMPDIR/does-not-exist.txt"
    [ "$status" -eq 0 ]
}

@test "never fails with no changed-files source configured at all" {
    run bash "$script"
    [ "$status" -eq 0 ]
}

@test "--help prints usage and exits 0" {
    run bash "$script" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: check-changelog-direct-edit.sh"* ]]
}

@test "an unknown argument is a warn-only no-op, not a failure" {
    run bash "$script" --bogus-flag
    [ "$status" -eq 0 ]
}
