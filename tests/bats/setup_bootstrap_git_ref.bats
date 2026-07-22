#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for #814: the standalone git-clone bootstrap (the
# documented curl | bash first-run path) previously always checked out
# origin's default branch (master) with no way to pin a different ref, even
# though LANCACHE_IMAGE_CHANNEL already lets an operator pin which *image*
# channel gets pulled. LANCACHE_SETUP_GIT_REF closes that gap for the git
# side: resolve_setup_bootstrap_ref() resolves the operator override (unset
# means "keep today's default-branch behavior", verified explicitly below so
# this stays backward compatible), and sync_repo_to_ref() re-points an
# existing checkout at that specific branch/tag/commit instead of always
# hard-resetting to the remote default branch.
#
# sync_repo_to_ref/sync_repo_to_default_branch are tested against a real
# local bare "origin" repo (branches + a tag), not mocked, since their whole
# job is real git plumbing (fetch, checkout -B, dirty-tree detection) -- see
# promote_lock.bats/staging_image_freshness.bats for the same real-git-repo
# testing pattern used elsewhere in this suite.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-env-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-env-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-env-helpers.sh"
    load_setup_env_helpers "$repo_root" "$helper_file"

    # setup-env-helpers.sh's shared die() stub uses `return 1` (safe for the
    # other suites sharing that file, which only guard-clause-check as their
    # function's last statement). sync_repo_to_ref's dirty-tree guard is NOT
    # the last statement, so a `return`-based die would let execution fall
    # through to the real fetch/checkout below it, masking the guard. `run`
    # (bats-core) executes each command in a forked subshell, so a real
    # `exit 1` here only terminates that subshell -- not the bats test
    # runner -- matching production die()'s real semantics safely.
    die() { printf "%s\n" "$*" >&2; exit 1; }

    unset LANCACHE_SETUP_GIT_REF

    remote="$BATS_TEST_TMPDIR/origin.git"
    src="$BATS_TEST_TMPDIR/src"
    checkout="$BATS_TEST_TMPDIR/checkout"

    git init -q --bare "$remote"
    git init -q "$src"
    git -C "$src" config user.email test@example.com
    git -C "$src" config user.name test
    git -C "$src" remote add origin "$remote"

    git -C "$src" commit -q --allow-empty -m "master c1"
    git -C "$src" push -q origin HEAD:refs/heads/master
    git -C "$src" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master 2>/dev/null || true

    git -C "$src" checkout -q -b dev
    git -C "$src" commit -q --allow-empty -m "dev c1"
    git -C "$src" push -q origin HEAD:refs/heads/dev
    dev_sha="$(git -C "$src" rev-parse HEAD)"

    git -C "$src" checkout -q master
    git -C "$src" tag v0.2.0
    git -C "$src" push -q origin v0.2.0
    v020_sha="$(git -C "$src" rev-parse v0.2.0)"
    master_sha="$(git -C "$src" rev-parse master)"

    export dev_sha v020_sha master_sha remote

    git clone -q "$remote" "$checkout"
    git -C "$checkout" remote set-head origin master 2>/dev/null || true
}

@test "resolve_setup_bootstrap_ref returns empty when LANCACHE_SETUP_GIT_REF is unset (backward-compatible default)" {
    run resolve_setup_bootstrap_ref
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "resolve_setup_bootstrap_ref returns the operator-supplied ref unchanged" {
    # shellcheck disable=SC2030 # subshell export is intentional; run() below reads it in-process via bats
    export LANCACHE_SETUP_GIT_REF="v0.2.0"
    run resolve_setup_bootstrap_ref
    [ "$status" -eq 0 ]
    [ "$output" = "v0.2.0" ]
}

@test "sync_repo_to_ref pins an existing checkout to a release tag, not the default branch" {
    run sync_repo_to_ref "$checkout" "v0.2.0"
    [ "$status" -eq 0 ]
    [ "$(git -C "$checkout" rev-parse HEAD)" = "$v020_sha" ]
}

@test "sync_repo_to_ref pins an existing checkout to a non-default branch" {
    run sync_repo_to_ref "$checkout" "dev"
    [ "$status" -eq 0 ]
    [ "$(git -C "$checkout" rev-parse HEAD)" = "$dev_sha" ]
}

@test "sync_repo_to_ref refuses to run on a dirty tree, matching sync_repo_to_default_branch's safety behavior" {
    printf 'local edit' >> "$checkout/README_LOCAL_EDIT.txt"
    run sync_repo_to_ref "$checkout" "v0.2.0"
    [ "$status" -ne 0 ]
    [[ "$output" == *"local changes"* ]]
    # The dirty tree must be left untouched, not partially reset.
    [ -f "$checkout/README_LOCAL_EDIT.txt" ]
}

@test "sync_repo_to_default_branch behavior is unchanged: still resets to origin's default branch (master)" {
    # Regression guard: introducing the ref-pin path must not alter the
    # existing default-branch sync used whenever no ref is pinned.
    git -C "$checkout" checkout -q -b dev "origin/dev"
    run sync_repo_to_default_branch "$checkout"
    [ "$status" -eq 0 ]
    [ "$(git -C "$checkout" rev-parse HEAD)" = "$master_sha" ]
}
