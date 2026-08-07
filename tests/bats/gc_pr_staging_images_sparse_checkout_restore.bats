#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression coverage for the runner-corruption root cause found while
# investigating widespread "No such file or directory" / "Can't find
# 'action.yml'" CI failures on 2026-08-07 (self-hosted runners, several
# unrelated build-push.yml jobs, traced to the runner's own _diag worker
# logs). Root cause: actions/checkout@v7.0.1's sparseCheckoutNonConeMode()
# (the code path .github/workflows/gc-pr-staging-images.yml's
# `sparse-checkout-cone-mode: false` selects) sets core.sparseCheckout via
# `git config` but writes the path patterns by appending directly to
# .git/info/sparse-checkout with a raw file write, never going through the
# `git sparse-checkout set` porcelain command.
#
# Reproduced repeatedly, live, on a self-hosted runner host (git 2.47.3,
# 2026-08-07), both against the real lancache-ng repository and against
# throwaway synthetic repositories of varying size: a sparse-checkout state
# set up that way does not reliably clear on a later job's plain `git
# sparse-checkout disable` call, nor on `git sparse-checkout init`
# immediately followed by `disable` -- both report exit 0, and across
# repeated runs the outcome varied between full recovery and index
# skip-worktree bits staying set on every path outside the narrow set. The
# exact trigger for the variation was not isolated. Self-hosted runners
# reuse one working directory across unrelated jobs/workflows, so whatever
# state a job leaves behind is inherited by the next job scheduled onto the
# same runner instance -- and a lingering core.sparseCheckout=true is
# dangerous even when the tree happens to look complete right now, because
# git re-applies whatever sparse-checkout config is active on every future
# tree-changing operation, so the next job's checkout of a genuinely
# different commit would re-narrow down to the old paths again.
#
# Because `disable`'s own exit code proved unreliable as a success signal,
# the workflow's fix does not trust it: it sweeps any remaining index
# skip-worktree bits directly via `git update-index --no-skip-worktree`, and
# asserts (failing the job loudly) that none remain afterward rather than
# assuming the restore worked. That assertion itself captures `git ls-files
# -v`'s output into a variable before counting matches with awk instead of
# piping straight into `grep -c` -- `grep -c`'s own "no match" exit code
# (1) is indistinguishable from a real git failure once wrapped in `||
# true`, and an empty resulting count would make `[ "$x" -ne 0 ]` a runtime
# error rather than a `set -e`-fatal one inside an `if` condition, silently
# skipping the check instead of failing it. These cases regress the failure
# mode (so a future change to the workflow's checkout step can't silently
# reintroduce it undetected), every stage of the fix (including the case
# where `disable` alone provably does not clear an existing skip-worktree
# bit), and that the step genuinely fails closed -- non-zero exit, not a
# silent no-op -- when git itself is broken. No network access and no real
# lancache-ng clone needed -- a throwaway local `git init` repository
# reproduces the same git plumbing behavior.

setup() {
    if ! command -v git >/dev/null 2>&1; then
        skip "git not available"
    fi

    test_repo="$(mktemp -d)"
    git -C "$test_repo" init --quiet --initial-branch=main
    git -C "$test_repo" config user.email "test@example.invalid"
    git -C "$test_repo" config user.name "Test"

    # A handful of tracked files standing in for the real repo's tree: two
    # inside the narrow set gc-pr-staging-images.yml actually checks out,
    # and two representing everything else (e.g. a workflow-referenced
    # composite action) that a later, unrelated job's checkout step needs.
    mkdir -p "$test_repo/scripts/lib" "$test_repo/.github/actions/some-action"
    echo "narrow-a" >"$test_repo/scripts/narrow-a.sh"
    echo "narrow-b" >"$test_repo/scripts/lib/narrow-b.sh"
    echo "outside-a" >"$test_repo/README.md"
    echo "outside-b" >"$test_repo/.github/actions/some-action/action.yml"
    git -C "$test_repo" add -A
    git -C "$test_repo" commit --quiet -m "seed"

    # gc-pr-staging-images.yml's "Restore full working tree for the next job
    # on this runner" step verbatim (same commands, same order), extracted
    # into its own script file rather than a bash function defined in this
    # test file: bats' own `run` implementation does not reliably preserve
    # `set -e` semantics for a function invoked through it, which masked a
    # real fail-closed bug during development of this test (an in-file
    # function reported exit 0 for a directory that isn't a git repository,
    # while the identical commands run as a standalone script correctly
    # exited non-zero) -- running it as a real external script sidesteps
    # that bats-specific pitfall entirely and is also a closer match to how
    # the workflow itself executes it (a real `bash` process running a
    # `run:` block's script, not a shell function call).
    restore_script="$(mktemp)"
    cat >"$restore_script" <<'RESTORE_SCRIPT'
#!/usr/bin/env bash
cd "$1" || exit 1
set -euo pipefail
git sparse-checkout init || true
git sparse-checkout disable || true
git config --local --unset-all core.sparseCheckout || true
rm -f .git/info/sparse-checkout

# `git ls-files -v` is captured into a variable BEFORE piping to awk, not
# piped to it directly: a real git failure here must trip `set -e`
# immediately via this plain assignment, which a direct pipe into awk would
# instead hide behind awk's own exit code.
ls_files_before="$(git ls-files -v)"
mapfile -t remaining_skip_worktree < <(printf '%s\n' "$ls_files_before" | awk '/^S /{print substr($0,3)}')
if [ "${#remaining_skip_worktree[@]}" -gt 0 ]; then
  git update-index --no-skip-worktree -- "${remaining_skip_worktree[@]}"
fi
git checkout --progress --force HEAD -- .

# Counts with awk rather than `grep -c`: awk's own exit code is 0 regardless
# of match count, so a zero-match "fully restored" result needs no `|| true`
# fallback that could otherwise let remaining_after end up empty/invalid and
# silently skip the check below under `set -e` (an empty `[ "$x" -ne 0 ]`
# comparison is a runtime error, not a fatal one, inside an `if` condition).
ls_files_after="$(git ls-files -v)"
remaining_after="$(printf '%s\n' "$ls_files_after" | awk '/^S /{c++} END{print c+0}')"
if [ "$remaining_after" -ne 0 ]; then
  echo "::error::${remaining_after} path(s) still carry the skip-worktree bit after the restore sequence" >&2
  exit 1
fi
RESTORE_SCRIPT
}

teardown() {
    rm -rf "$test_repo"
    rm -f "$restore_script"
}

# Mirrors actions/checkout's sparseCheckoutNonConeMode(): `git config
# core.sparseCheckout true` plus a raw append to .git/info/sparse-checkout,
# never `git sparse-checkout set`. This is the exact setup path
# gc-pr-staging-images.yml's `sparse-checkout-cone-mode: false` selects.
narrow_via_legacy_manual_append() {
    git -C "$test_repo" config core.sparseCheckout true
    printf '\nscripts/narrow-a.sh\nscripts/lib/narrow-b.sh\n' >>"$test_repo/.git/info/sparse-checkout"
    git -C "$test_repo" checkout --progress --force HEAD >/dev/null 2>&1
}

# Runs the restore script (see setup() above) against the directory given as
# $1 -- a real git repo for the recovery-path tests below, or a non-repo
# directory for the fail-closed test.
run_workflow_restore_step() {
    bash "$restore_script" "$1"
}

@test "legacy manual sparse-checkout setup narrows the working tree as expected" {
    narrow_via_legacy_manual_append
    [ -f "$test_repo/scripts/narrow-a.sh" ]
    [ ! -f "$test_repo/README.md" ]
    [ ! -f "$test_repo/.github/actions/some-action/action.yml" ]
}

@test "plain 'git sparse-checkout disable' does not reliably clear core.sparseCheckout" {
    narrow_via_legacy_manual_append

    run git -C "$test_repo" sparse-checkout disable
    [ "$status" -eq 0 ]
    run git -C "$test_repo" checkout --progress --force HEAD
    [ "$status" -eq 0 ]

    # This is the actual bug: `disable` reports success, but
    # core.sparseCheckout was never actually cleared -- confirmed as the one
    # consistently-reproducible part of this failure across every repetition
    # against both this minimal fixture and the real lancache-ng repository.
    # (Whether files outside the narrow set are also still missing from the
    # working tree at this exact point varied between repetitions in the real
    # reproductions and is deliberately not asserted here -- the config being
    # left dangling is the part proven reliable, and is dangerous on its own.)
    run git -C "$test_repo" config --local --get core.sparseCheckout
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "the workflow's restore step fully restores a legacy-manual narrow checkout and its assertion passes" {
    narrow_via_legacy_manual_append

    run run_workflow_restore_step "$test_repo"
    [ "$status" -eq 0 ]

    [ -f "$test_repo/README.md" ]
    [ -f "$test_repo/.github/actions/some-action/action.yml" ]
    [ -f "$test_repo/scripts/narrow-a.sh" ]
    [ -f "$test_repo/scripts/lib/narrow-b.sh" ]

    # core.sparseCheckout must genuinely be gone, not just report success --
    # a later job's own checkout step never re-sets it, so a lingering true
    # here would keep re-narrowing every future tree-changing operation on
    # this working directory.
    run git -C "$test_repo" config --local --get core.sparseCheckout
    [ "$status" -eq 1 ]

    run git -C "$test_repo" ls-files -v
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\nS '* ]]
    [[ "$output" != S\ * ]]
}

@test "the workflow's restore step's own sweep recovers a skip-worktree bit regardless of how it was set" {
    # Sets a skip-worktree bit directly rather than via the flaky
    # legacy-setup reproduction above, so this test does not depend on
    # reproducing that specific flakiness to prove the step's own
    # sweep+assert logic (the part that does not rely on `disable` or
    # `init` succeeding) is sound on its own.
    git -C "$test_repo" update-index --skip-worktree README.md
    rm -f "$test_repo/README.md"

    run run_workflow_restore_step "$test_repo"
    [ "$status" -eq 0 ]
    [ -f "$test_repo/README.md" ]

    run git -C "$test_repo" ls-files -v
    [[ "$output" != *$'\nS '* ]]
    [[ "$output" != S\ * ]]
}

@test "the workflow's restore step fails closed (non-zero exit) instead of silently succeeding when git itself is broken" {
    # Regression for a subtler hazard the sweep/assert logic itself could
    # introduce: if the final skip-worktree count were computed via
    # `grep -c ... || true` instead of awk, a genuine git failure at that
    # point could leave the count variable empty, and `[ "$x" -ne 0 ]` on an
    # empty string is a *runtime* error inside an `if` condition -- not a
    # fatal one under `set -e` -- so the check would be silently skipped and
    # the step would exit 0 despite never having verified anything. Proves
    # the actual shipped behavior (fails closed) against a directory that
    # is not a git repository at all, rather than reasoning about it.
    not_a_repo="$(mktemp -d)"
    run run_workflow_restore_step "$not_a_repo"
    [ "$status" -ne 0 ]
    rm -rf "$not_a_repo"
}
