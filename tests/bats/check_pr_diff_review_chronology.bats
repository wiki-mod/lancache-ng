#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for scripts/untracked/check-pr-diff-review-chronology.sh:
# exercises the real fetch + NUL-safe diff + check-review-chronology-comments.sh
# pipeline against a small, throwaway local git repo pair (a bare "origin"
# plus a working clone) -- real git operations end to end, never mocked,
# mirroring tests/bats/check_pr_diff_file_headers.bats's own fixture shape.

bats_require_minimum_version 1.5.0

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/untracked/check-pr-diff-review-chronology.sh"
    chronology_script="$BATS_TEST_DIRNAME/../../scripts/untracked/check-review-chronology-comments.sh"
    fixture_root="$(mktemp -d)"
    origin_dir="$fixture_root/origin.git"
    work_dir="$fixture_root/work"

    git init --quiet --bare "$origin_dir"

    git init --quiet -b main "$work_dir"
    mkdir -p "$work_dir/scripts/untracked"
    cp "$chronology_script" "$work_dir/scripts/untracked/check-review-chronology-comments.sh"
    cp "$script" "$work_dir/scripts/untracked/check-pr-diff-review-chronology.sh"
    mkdir -p "$work_dir/scripts/lib"
    cp "$BATS_TEST_DIRNAME/../../scripts/lib/git-fetch-retry.sh" "$work_dir/scripts/lib/git-fetch-retry.sh"

    (
        cd "$work_dir" || exit 1
        git config user.email test@example.invalid
        git config user.name "Test"
        git remote add origin "$origin_dir"
        printf '# A normal, compliant comment.\n' > example.sh
        git add example.sh scripts
        git commit --quiet -m "base commit"
        git push --quiet origin main
    )
    base_sha="$(cd "$work_dir" && git rev-parse HEAD)"
}

teardown() {
    rm -rf "$fixture_root"
}

@test "passes silently when the diff is empty (base and head are the same commit)" {
    head_sha="$base_sha"
    run bash -c "cd '$work_dir' && SPDX_BASE_SHA='$base_sha' SPDX_BASE_REF=main GITHUB_SHA='$head_sha' bash scripts/untracked/check-pr-diff-review-chronology.sh"
    [ "$status" -eq 0 ]
}

@test "fails on a real changed file that introduces a review-chronology violation" {
    (
        cd "$work_dir"
        printf '# caught in review: this line should not exist here.\n' > bad.sh
        git add bad.sh
        git commit --quiet -m "add a file with a chronology violation"
    )
    head_sha="$(cd "$work_dir" && git rev-parse HEAD)"
    run bash -c "cd '$work_dir' && SPDX_BASE_SHA='$base_sha' SPDX_BASE_REF=main GITHUB_SHA='$head_sha' bash scripts/untracked/check-pr-diff-review-chronology.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"bad.sh"* ]]
}

@test "passes on a real changed file with no violation" {
    (
        cd "$work_dir"
        printf '# A second normal, compliant comment.\n' > good.sh
        git add good.sh
        git commit --quiet -m "add a compliant file"
    )
    head_sha="$(cd "$work_dir" && git rev-parse HEAD)"
    run bash -c "cd '$work_dir' && SPDX_BASE_SHA='$base_sha' SPDX_BASE_REF=main GITHUB_SHA='$head_sha' bash scripts/untracked/check-pr-diff-review-chronology.sh"
    [ "$status" -eq 0 ]
}

# What: a violation in a file the diff does NOT touch must not surface.
# Why: this is the entire point of the diff-scoped wrapper -- an unrelated,
#   pre-existing violation elsewhere in the tree must not block this PR.
# From: Issue #1095
@test "a pre-existing violation in a file outside this diff does not block the PR" {
    (
        cd "$work_dir"
        printf '# caught in review: pre-existing, not part of any diff.\n' > pre_existing_violation.sh
        git add pre_existing_violation.sh
        git commit --quiet -m "base commit gains an unrelated pre-existing violation"
        git push --quiet origin main
    )
    new_base_sha="$(cd "$work_dir" && git rev-parse HEAD)"

    (
        cd "$work_dir"
        printf '# A third normal, compliant comment, the actual PR diff.\n' > unrelated_change.sh
        git add unrelated_change.sh
        git commit --quiet -m "the actual PR change, unrelated to the pre-existing violation"
    )
    head_sha="$(cd "$work_dir" && git rev-parse HEAD)"

    run bash -c "cd '$work_dir' && SPDX_BASE_SHA='$new_base_sha' SPDX_BASE_REF=main GITHUB_SHA='$head_sha' bash scripts/untracked/check-pr-diff-review-chronology.sh"
    [ "$status" -eq 0 ] || fail "a violation outside the diff must not fail this PR: $output"
}

@test "fails closed when git diff itself fails after both reachability checks pass" {
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
    run bash -c "cd '$work_dir' && PATH='$fixture_root/bin:$PATH' SPDX_BASE_SHA='$base_sha' SPDX_BASE_REF=main GITHUB_SHA='$base_sha' bash scripts/untracked/check-pr-diff-review-chronology.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"git diff\` itself failed"* ]]
}

@test "fails closed with a clear diagnostic when a required environment variable is missing" {
    run bash -c "cd '$work_dir' && SPDX_BASE_REF=main GITHUB_SHA='$base_sha' bash scripts/untracked/check-pr-diff-review-chronology.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"SPDX_BASE_SHA"* ]]
}

fail() {
    echo "$1" >&2
    return 1
}
