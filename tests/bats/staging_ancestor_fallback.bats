#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Docker-free unit + integration coverage for
# scripts/lib/staging-ancestor-fallback.sh, the shared ancestor-fallback
# recovery path scripts/ensure-pr-staging-images.sh and build-push.yml's own
# "Ensure PR staging tags exist for full-setup services" step both use.
#
# Covers several real bugs found during review, each with a dedicated
# regression case:
#   - a SIGPIPE bug (piping `git log` through `head -n N` under `pipefail`
#     aborts the walk before it examines any real candidate once the real
#     ancestor count exceeds the configured depth -- fixed by bounding at
#     the `git log` source with `--max-count` instead)
#   - `git log`'s default all-parents walk finding a built commit on a
#     merge's side branch before reaching its first parent -- fixed with
#     `--first-parent`
#   - a confirmed-zero-push-runs reading alone is not proof of a deliberate
#     skip (an outage could produce the same reading for a real change) --
#     fixed by additionally requiring every changed path to match
#     build-push.yml's own paths-ignore patterns
#   - the decisive GitHub Actions API query having no retry -- fixed by
#     wrapping it in the project's existing ghcr_retry policy
#   - an ancestor candidate's own non-push-triggered run being skipped
#     without a chance, asymmetric with how BASE_SHA's own image is checked
#   - a single shared freshness budget applied to both BASE_SHA's own wait
#     (which can legitimately be racing a real in-flight build) and the
#     ancestor-candidate checks (which never can, since a candidate is
#     already confirmed to be further back in history than BASE_SHA) --
#     fixed by splitting into two independent budget pairs
#   - a run-less ancestor candidate being skipped in favor of an older one
#     without confirming THAT candidate's own changed paths are ignorable --
#     zero runs alone does not prove a deliberate skip for a mid-walk
#     candidate any more than it does for BASE_SHA itself -- fixed by
#     applying the same paths-are-ignorable proof to every skipped candidate

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/lib/ghcr-retry.sh
    source "$repo_root/scripts/lib/ghcr-retry.sh"
    # shellcheck source=scripts/lib/staging-image-freshness.sh
    source "$repo_root/scripts/lib/staging-image-freshness.sh"
    # shellcheck source=scripts/lib/staging-ancestor-fallback.sh
    source "$repo_root/scripts/lib/staging-ancestor-fallback.sh"

    # Fast, deterministic retries in every test below (mirrors
    # tests/bats/ghcr_retry.bats' own convention).
    # shellcheck disable=SC2034 # read by ghcr_retry() in scripts/lib/ghcr-retry.sh,
    # sourced above -- shellcheck cannot see the cross-file read.
    GHCR_RETRY_BACKOFF_SECONDS=0
    # shellcheck disable=SC2034 # read by ghcr_retry(), same cross-file reason.
    GHCR_RETRY_MAX_ATTEMPTS=4
    sleep() { :; }
    export -f sleep
}

# ---------------------------------------------------------------------------
# saf_paths_are_ignorable: pure, no git/network involved.
# ---------------------------------------------------------------------------

@test "saf_paths_are_ignorable: a pure docs/markdown change set is ignorable" {
    run saf_paths_are_ignorable "$(printf 'docs/foo.md\nREADME.md\ndocs/nested/bar.md\n')"
    [ "$status" -eq 0 ]
}

@test "saf_paths_are_ignorable: CHANGELOG.md is explicitly NOT ignorable" {
    run saf_paths_are_ignorable "$(printf 'docs/foo.md\nCHANGELOG.md\n')"
    [ "$status" -ne 0 ]
}

@test "saf_paths_are_ignorable: any real code path makes the whole set NOT ignorable" {
    run saf_paths_are_ignorable "$(printf 'docs/foo.md\nscripts/real-change.sh\n')"
    [ "$status" -ne 0 ]
}

@test "saf_paths_are_ignorable: an empty path list is NOT ignorable (can't distinguish from a failed diff)" {
    run saf_paths_are_ignorable ""
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# saf_base_commit_paths_are_ignorable: real git-repo-backed diff.
#
# Fixture: a linear chain of real commits (not --allow-empty) so
# git diff-tree has something real to report -- ancestor2 (root) -> older
# -> base, each touching its own docs/*.md file, plus a fourth commit
# "real_change" that touches a non-doc path, for the "not ignorable" case.
# ---------------------------------------------------------------------------

setup_linear_fixture() {
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test

    mkdir -p "$git_dir/docs" "$git_dir/scripts"
    echo "ancestor2" > "$git_dir/docs/ancestor2.md"
    git -C "$git_dir" add docs/ancestor2.md
    git -C "$git_dir" commit -q -m ancestor2
    ancestor2_sha="$(git -C "$git_dir" rev-parse HEAD)"

    echo "older" > "$git_dir/docs/older.md"
    git -C "$git_dir" add docs/older.md
    git -C "$git_dir" commit -q -m older
    older_sha="$(git -C "$git_dir" rev-parse HEAD)"

    echo "base" > "$git_dir/docs/base.md"
    git -C "$git_dir" add docs/base.md
    git -C "$git_dir" commit -q -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    echo "real change" > "$git_dir/scripts/real-change.sh"
    git -C "$git_dir" add scripts/real-change.sh
    git -C "$git_dir" commit -q -m "real change"
    real_change_sha="$(git -C "$git_dir" rev-parse HEAD)"
}

@test "saf_base_commit_paths_are_ignorable: a docs-only commit is confirmed ignorable" {
    setup_linear_fixture
    run saf_base_commit_paths_are_ignorable "$base_sha" "$git_dir"
    [ "$status" -eq 0 ]
}

@test "saf_base_commit_paths_are_ignorable: a commit touching a real script is NOT ignorable" {
    setup_linear_fixture
    run saf_base_commit_paths_are_ignorable "$real_change_sha" "$git_dir"
    [ "$status" -eq 1 ]
}

@test "saf_base_commit_paths_are_ignorable: a root commit (no parent) is inconclusive, not falsely ignorable" {
    setup_linear_fixture
    run saf_base_commit_paths_are_ignorable "$ancestor2_sha" "$git_dir"
    [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# saf_query_run_count / saf_base_commit_has_confirmed_run: retry + event
# scoping, using a fake `gh` binary (not the STAGING_BASE_BUILD_RUN_EXISTS_CMD
# stub hook -- these tests exercise the REAL query path, including retry).
# ---------------------------------------------------------------------------

# Installs a fake `gh` that fails FAKE_GH_FAIL_COUNT times (transient
# exit-1s, no output) before succeeding and echoing FAKE_GH_RUN_COUNT
# directly on stdout -- saf_query_run_count's own real `gh api ... --jq
# '.workflow_runs | length'` call expects a bare integer on stdout, so this
# stub emulates that end result directly rather than a real JSON response +
# a real jq filter pass.
install_fake_gh_flaky() {
    fake_bin_dir="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$fake_bin_dir"
    fail_count_file="$BATS_TEST_TMPDIR/gh_fail_count"
    echo "${FAKE_GH_FAIL_COUNT:-0}" > "$fail_count_file"
    call_log="$BATS_TEST_TMPDIR/gh_calls.log"
    : > "$call_log"
    cat > "$fake_bin_dir/gh" <<STUB
#!/usr/bin/env bash
echo "call" >> "$call_log"
remaining=\$(cat "$fail_count_file")
if [ "\$remaining" -gt 0 ]; then
    remaining=\$((remaining - 1))
    echo "\$remaining" > "$fail_count_file"
    exit 1
fi
echo "${FAKE_GH_RUN_COUNT:-0}"
STUB
    chmod +x "$fake_bin_dir/gh"
    export PATH="$fake_bin_dir:$PATH"
}

@test "saf_query_run_count: retries a transient gh failure and succeeds on a later attempt" {
    export FAKE_GH_FAIL_COUNT=2
    export FAKE_GH_RUN_COUNT=1
    install_fake_gh_flaky
    run saf_query_run_count "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" "push"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    # 2 failures + 1 success = 3 calls, proving the retry actually happened,
    # not that the first attempt happened to succeed.
    [ "$(wc -l < "$call_log")" -eq 3 ]
}

@test "saf_query_run_count: exhausts retries and fails closed (no output) on a persistent failure" {
    export FAKE_GH_FAIL_COUNT=99
    export FAKE_GH_RUN_COUNT=0
    install_fake_gh_flaky
    run saf_query_run_count "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" "push"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    # GHCR_RETRY_MAX_ATTEMPTS=4 (set in setup()) -- exactly 4 calls, not an
    # unbounded retry loop.
    [ "$(wc -l < "$call_log")" -eq 4 ]
}

@test "saf_base_commit_has_confirmed_run: a persistent gh failure is treated as inconclusive (2), not confirmed-zero" {
    export FAKE_GH_FAIL_COUNT=99
    export FAKE_GH_RUN_COUNT=0
    install_fake_gh_flaky
    unset STAGING_BASE_BUILD_RUN_EXISTS_CMD
    run saf_base_commit_has_confirmed_run "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" "push"
    [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# saf_find_built_ancestor: --first-parent, SIGPIPE/max-count regression, and
# non-push-run acceptance for candidates.
# ---------------------------------------------------------------------------

# Stub for STAGING_BASE_BUILD_RUN_EXISTS_CMD keyed by a "runs.txt" file
# listing "sha<TAB>event" pairs that should report "a run exists" (exit 0);
# anything else reports "confirmed zero" (exit 1). This mirrors the shape a
# real event-scoped gh api query would answer.
install_run_exists_stub() {
    runs_file="$BATS_TEST_TMPDIR/runs.txt"
    : > "$runs_file"
    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
grep -qxF "\$1	\$2" "$runs_file"
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"
}

# Freshness stub: only images matching the given commit's own short-sha
# suffix resolve; keyed via STAGING_IMAGE_REVISION_CMD.
install_revision_stub_for() {
    local sha="$1"
    revision_stub="$BATS_TEST_TMPDIR/revision_$sha.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
image="\$1"
suffix="\${image##*:sha-}"
if [ "\$suffix" = "${sha:0:7}" ]; then
    echo "$sha"
else
    exit 1
fi
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"
}

@test "saf_find_built_ancestor: SIGPIPE regression -- a real ancestor chain longer than search_depth is still walked correctly" {
    # The pre-fix implementation piped \`git log\` through \`head -n N\` under
    # \`pipefail\`; head closing the pipe early on a chain with MORE than N
    # ancestors triggered SIGPIPE, which pipefail turned into a pipeline
    # failure, aborting the whole walk before it examined a single
    # candidate. This fixture has 8 real ancestor commits with a
    # search_depth of 3 -- deliberately smaller than the total chain length
    # -- so head would have been exercised (and would have broken) here.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    local i
    # Real docs/*.md-touching commits, not --allow-empty: the two skipped
    # candidates nearest base_sha must be positively confirmed
    # paths-ignorable (saf_find_built_ancestor's own "validate every skipped
    # ancestor" safety check), which an empty diff can never satisfy
    # (inconclusive, not confirmed-ignorable -- see
    # saf_base_commit_paths_are_ignorable's own header).
    mkdir -p "$git_dir/docs"
    for i in 1 2 3 4 5 6 7 8; do
        echo "commit-$i" > "$git_dir/docs/commit-$i.md"
        git -C "$git_dir" add "docs/commit-$i.md"
        git -C "$git_dir" commit -q -m "commit-$i"
    done
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"
    # The 3rd ancestor back (search_depth=3's own boundary) is the one with
    # a real run + image; proves the walk actually reaches it rather than
    # aborting immediately with "no candidates" (the SIGPIPE symptom) or
    # silently stopping short of the configured depth.
    third_ancestor_sha="$(git -C "$git_dir" log --format=%H "$base_sha" | sed -n '4p')"

    install_run_exists_stub
    printf '%s\tany\n' "$third_ancestor_sha" >> "$runs_file"
    # STAGING_BASE_BUILD_RUN_EXISTS_CMD stub ignores the event arg entirely
    # here (ancestor candidates query with event="", passed as literal
    # empty string by saf_find_built_ancestor -- match that exactly).
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
[ "\$1" = "$third_ancestor_sha" ]
STUB
    chmod +x "$run_exists_stub"

    install_revision_stub_for "$third_ancestor_sha"

    # Bats' `run` merges stdout+stderr into $output (sif_wait_for_fresh_base_image's
    # own ::notice:: diagnostics go to stderr, per its documented discipline,
    # while saf_find_built_ancestor's own confirmed-sha result is the last
    # line on stdout) -- check the LAST line specifically, not $output's
    # exact full text, which would also contain that diagnostic line.
    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" 3 0 0 0 "$git_dir"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "$third_ancestor_sha" ]
}

@test "saf_find_built_ancestor: --first-parent skips a merged-in side-branch commit that isn't the real prior target-branch state" {
    # This project does not squash-merge, so nearly every real commit on a
    # target branch is itself a merge commit. Build one: a target-branch
    # tip (T1), a divergent feature branch off it with its OWN built commit
    # (F1 -- has a real run+image, but represents a side branch's state, not
    # the target branch's), then a merge commit (M) bringing F1 into the
    # target branch. M's first parent is T1 (the real prior target-branch
    # state); a plain (non-first-parent) \`git log\` would reach F1 before
    # T1. T1 also has a real run+image, so the correct answer is T1, not F1.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test

    git -C "$git_dir" commit -q --allow-empty -m root
    git -C "$git_dir" commit -q --allow-empty -m t1
    t1_sha="$(git -C "$git_dir" rev-parse HEAD)"

    git -C "$git_dir" checkout -q -b feature
    git -C "$git_dir" commit -q --allow-empty -m f1
    f1_sha="$(git -C "$git_dir" rev-parse HEAD)"

    git -C "$git_dir" checkout -q master 2>/dev/null || git -C "$git_dir" checkout -q main
    git -C "$git_dir" merge -q --no-ff -m "merge feature" feature
    merge_sha="$(git -C "$git_dir" rev-parse HEAD)"

    install_run_exists_stub
    printf '%s\tany\n' "$t1_sha" >> "$runs_file"
    printf '%s\tany\n' "$f1_sha" >> "$runs_file"
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
    "$t1_sha") exit 0 ;;
    "$f1_sha") exit 0 ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$run_exists_stub"

    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
image="\$1"
suffix="\${image##*:sha-}"
case "\$suffix" in
    "${t1_sha:0:7}") echo "$t1_sha" ;;
    "${f1_sha:0:7}") echo "$f1_sha" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    # See the SIGPIPE regression test's own comment above for why the LAST
    # line (not $output's full text) is checked -- bats' `run` merges
    # stdout+stderr, and sif_wait_for_fresh_base_image's own ::notice::
    # diagnostics land on stderr ahead of the confirmed sha itself.
    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$merge_sha" "proxy" 10 0 0 0 "$git_dir"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "$t1_sha" ]
}

@test "saf_find_built_ancestor: a non-push-triggered run for an ancestor candidate is still accepted (not skipped)" {
    # Item 7: BASE_SHA's own exact-sha check never cared which trigger built
    # its image; an ancestor candidate must not be held to a stricter
    # standard just because it's being considered as a substitute.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    git -C "$git_dir" commit -q --allow-empty -m ancestor
    ancestor_sha="$(git -C "$git_dir" rev-parse HEAD)"
    git -C "$git_dir" commit -q --allow-empty -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    # The candidate's run exists only for event="" (any event, e.g. a
    # workflow_dispatch) -- not for event="push". saf_find_built_ancestor
    # must query with an empty event filter for ancestor candidates, so this
    # candidate must still be tried (and accepted) rather than skipped.
    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "$ancestor_sha" ] && [ -z "\$2" ]; then
    exit 0
fi
exit 1
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    install_revision_stub_for "$ancestor_sha"

    # See the SIGPIPE regression test's own comment above for why the LAST
    # line (not $output's full text) is checked.
    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" 10 0 0 0 "$git_dir"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "$ancestor_sha" ]
}

@test "saf_find_built_ancestor: a skipped run-less candidate with a real (non-doc) path change blocks the walk instead of substituting an older ancestor" {
    # A run-less candidate is not simply skipped in favor of an older one --
    # zero runs alone does not prove THAT candidate was itself a deliberate
    # skip (e.g. the push trigger could have been disabled for that one
    # push). Fixture: grandparent (docs-only, HAS a real run+image) ->
    # real_change_parent (touches a real script, ZERO runs) -> base_sha
    # (docs-only, ZERO runs). If the walk silently skipped real_change_parent
    # for lacking a run and substituted grandparent instead, the back-fill
    # would omit real_change_parent's own real change -- exactly the
    # #626/#808 class of bug this whole mechanism must not reintroduce.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    mkdir -p "$git_dir/docs" "$git_dir/scripts"

    echo "grandparent" > "$git_dir/docs/grandparent.md"
    git -C "$git_dir" add docs/grandparent.md
    git -C "$git_dir" commit -q -m grandparent
    grandparent_sha="$(git -C "$git_dir" rev-parse HEAD)"

    echo "real change" > "$git_dir/scripts/real-change.sh"
    git -C "$git_dir" add scripts/real-change.sh
    git -C "$git_dir" commit -q -m "real change parent"
    real_change_parent_sha="$(git -C "$git_dir" rev-parse HEAD)"

    echo "base" > "$git_dir/docs/base.md"
    git -C "$git_dir" add docs/base.md
    git -C "$git_dir" commit -q -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
    "$grandparent_sha") exit 0 ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    install_revision_stub_for "$grandparent_sha"

    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" 10 0 0 0 "$git_dir"
    [ "$status" -ne 0 ]
    # Must NOT have substituted grandparent -- confirms this is a genuine
    # fail-closed stop, not a successful (wrong) resolution.
    [[ "$output" != *"$grandparent_sha"* ]]
}

# ---------------------------------------------------------------------------
# saf_resolve_untouched_backfill_source: end-to-end orchestration --
# reordering (fast path), the paths-are-ignorable safety gate, and the
# post-wait decision.
# ---------------------------------------------------------------------------

@test "saf_resolve_untouched_backfill_source: fast path -- confirmed zero push runs + ignorable paths skips the long wait and finds the ancestor" {
    setup_linear_fixture
    install_run_exists_stub
    printf '%s\tany\n' "$ancestor2_sha" >> "$runs_file"
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
    "$base_sha") exit 1 ;;
    "$older_sha") exit 1 ;;
    "$ancestor2_sha") exit 0 ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$run_exists_stub"

    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
image="\$1"
suffix="\${image##*:sha-}"
case "\$suffix" in
    "${ancestor2_sha:0:7}") echo "$ancestor2_sha" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    # Deliberately small but non-zero budgets (3s/3s, not 300s/600s): large
    # enough that "the long wait ran" and "the fast path skipped it" are
    # clearly distinguishable by elapsed time, small enough that a
    # regression reintroducing the slow path fails this assertion in
    # seconds rather than hanging the suite for up to 10 minutes.
    start_epoch="$(date +%s)"
    run saf_resolve_untouched_backfill_source "wiki-mod/lancache-ng" "proxy" "$base_sha" 3 3 3 3 1 50 "$git_dir"
    end_epoch="$(date +%s)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sha-${ancestor2_sha:0:7}" ]]
    # The fast path (reordering) means this must resolve in well under the
    # 3s ceiling above -- proves the long wait was genuinely skipped, not
    # merely fast because the test stubs are instant.
    [ "$((end_epoch - start_epoch))" -lt 2 ]
}

@test "saf_resolve_untouched_backfill_source: paths NOT confirmed ignorable blocks the fallback even with zero push runs" {
    setup_linear_fixture
    install_run_exists_stub
    cat > "$run_exists_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$run_exists_stub"

    # Force the exact-BASE_SHA freshness check to fail too (no override
    # resolves real_change_sha's own suffix).
    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    run saf_resolve_untouched_backfill_source "wiki-mod/lancache-ng" "proxy" "$real_change_sha" 0 0 0 0 0 50 "$git_dir"
    [ "$status" -ne 0 ]
    [[ "$output" != *"Substituting"* ]]
}

@test "saf_resolve_untouched_backfill_source: a confirmed push run on BASE_SHA blocks the fallback regardless of paths" {
    setup_linear_fixture
    install_run_exists_stub
    cat > "$run_exists_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$run_exists_stub"

    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    run saf_resolve_untouched_backfill_source "wiki-mod/lancache-ng" "proxy" "$base_sha" 0 0 0 0 0 50 "$git_dir"
    [ "$status" -ne 0 ]
}

@test "saf_resolve_untouched_backfill_source: BASE_SHA's own image already existing (any trigger) is used directly, fast path never needed" {
    setup_linear_fixture
    install_run_exists_stub
    cat > "$run_exists_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$run_exists_stub"

    install_revision_stub_for "$base_sha"

    run saf_resolve_untouched_backfill_source "wiki-mod/lancache-ng" "proxy" "$base_sha" 300 600 300 600 15 50 "$git_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sha-${base_sha:0:7}" ]]
    [[ "$output" != *"ancestor"* ]]
}

@test "saf_resolve_untouched_backfill_source: a confirmed-in-flight BASE_SHA build gets the long budget, not the short ancestor-candidate one" {
    setup_linear_fixture
    install_run_exists_stub
    # A confirmed push-triggered run exists for BASE_SHA (a real, in-flight
    # build) -- this must always follow the LONG base_freshness_* budget for
    # BASE_SHA's own wait (step 2), never the short ancestor_freshness_*
    # budget saf_find_built_ancestor's own per-candidate checks use. If the
    # two budgets were ever collapsed back into one shared pair, a
    # still-building base commit would hard-fail this gate at the short
    # ceiling well before its image has any chance to appear.
    cat > "$run_exists_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$run_exists_stub"

    start_epoch="$(date +%s)"
    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
now="\$(date +%s)"
elapsed=\$((now - $start_epoch))
# Resolves only once 4 real seconds have elapsed: longer than the short
# ancestor ceiling (2s) below, well inside the long base ceiling (10s).
if (( elapsed >= 4 )); then
    echo "$base_sha"
else
    exit 1
fi
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    run saf_resolve_untouched_backfill_source "wiki-mod/lancache-ng" "proxy" "$base_sha" 10 10 2 2 1 50 "$git_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sha-${base_sha:0:7}" ]]
}
