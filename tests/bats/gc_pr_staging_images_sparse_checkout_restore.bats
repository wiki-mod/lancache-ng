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
# Reproduced repeatedly, live, on git 2.47.3 (2026-08-07, three independent
# runner hosts, both against the real lancache-ng repository and against
# throwaway synthetic ones of varying size): a sparse-checkout state set up
# that way does not reliably clear on a later job's plain `git
# sparse-checkout disable` call, nor on `git sparse-checkout init`
# immediately followed by `disable` -- both report exit 0, and across
# repeated runs the actual outcome varied (sometimes core.sparseCheckout
# stayed true with paths outside the narrow set missing from the working
# tree entirely; sometimes only the config value and the stale
# .git/info/sparse-checkout file lingered while the working tree itself
# looked fully populated). What stayed consistent across every repetition:
# core.sparseCheckout itself was never reliably cleared by git's own
# sparse-checkout subcommands alone. Self-hosted runners reuse one working
# directory across unrelated jobs/workflows, so whatever state this job
# leaves behind is inherited by the next job scheduled onto the same runner
# instance -- and a lingering core.sparseCheckout=true is dangerous even
# when the tree happens to look complete right now, because git re-applies
# whatever sparse-checkout config is active on every future tree-changing
# operation, so the next job's checkout of a genuinely different commit
# would re-narrow down to the old paths again.
#
# These cases regress both the failure mode (so a future change to the
# workflow's checkout step can't silently reintroduce it undetected) and the
# fix this project applies in gc-pr-staging-images.yml's "Restore full
# working tree for the next job on this runner" step: since git's own
# sparse-checkout subcommands don't reliably undo this, that step clears the
# state directly (unset the config, remove the stale pattern file, force a
# full re-checkout) instead of trusting `disable` alone. No network access
# and no real lancache-ng clone needed -- a throwaway local `git init`
# repository reproduces the same git plumbing behavior.

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
}

teardown() {
    rm -rf "$test_repo"
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

@test "the workflow's explicit restore sequence fully restores a legacy-manual narrow checkout" {
    narrow_via_legacy_manual_append

    # This mirrors gc-pr-staging-images.yml's "Restore full working tree for
    # the next job on this runner" step verbatim. `git sparse-checkout
    # init`/`disable` alone were confirmed unreliable at fully clearing
    # core.sparseCheckout across repeated live reproductions, so the fix does
    # not trust them alone -- it explicitly unsets the config, removes the
    # stale pattern file, and forces a real re-checkout.
    git -C "$test_repo" sparse-checkout init || true
    git -C "$test_repo" sparse-checkout disable || true
    git -C "$test_repo" config --local --unset-all core.sparseCheckout || true
    rm -f "$test_repo/.git/info/sparse-checkout"
    run git -C "$test_repo" checkout --progress --force HEAD -- .
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
