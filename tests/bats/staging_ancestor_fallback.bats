#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Docker-free unit + integration coverage for
# scripts/lib/staging-ancestor-fallback.sh, the shared ancestor-fallback
# recovery path scripts/untracked/ensure-pr-staging-images.sh and build-push.yml's own
# "Ensure PR staging tags exist for full-setup services" step both use.
#
# Each of the properties below is load-bearing for this mechanism's
# fail-closed guarantee, and each has a dedicated case here, so a future
# refactor cannot quietly drop one:
#   - the ancestor walk is bounded at the `git log` SOURCE (`--max-count`),
#     never by piping into `head` -- an early-exiting consumer under
#     `pipefail` can leave the producer killed by SIGPIPE and abort the walk
#     before it examines a single real candidate
#   - the walk is `--first-parent` only: this project does not squash-merge,
#     so a default all-parents walk can surface a built commit that only ever
#     existed on a merge's side branch, never on the target branch itself
#   - a confirmed-zero-push-runs reading is NOT on its own proof of a
#     deliberate skip (a CI outage produces the identical reading for a real
#     change), so every changed path must additionally match
#     build-push.yml's own paths-ignore patterns -- for BASE_SHA and for
#     every mid-walk candidate the walk skips past
#   - the decisive GitHub Actions API query runs under the project's shared
#     ghcr_retry policy (AG-CI-013), never bare
#   - an ancestor candidate's own non-push-triggered run still counts as
#     build proof, symmetric with how BASE_SHA's own image is checked
#   - the build-proof query counts only TAG-PUBLISHING trigger types
#     (push/workflow_dispatch/schedule): a pull_request run's github.sha is a
#     synthetic merge commit, so it never publishes the candidate's own
#     sha-<commit> tag no matter what head_sha the API reports for it
#   - BASE_SHA's own wait, the per-candidate initial check, and the
#     one-time extended retry each get their OWN freshness budget -- only the
#     first can legitimately race a real in-flight build
#   - an ancestor candidate whose own build is positively confirmed still
#     active gets exactly one extended-budget retry, and an inconclusive or
#     confirmed-not-active answer gets none (not a blind timeout bump --
#     AG-CI-013)
#   - every GitHub API call goes through `curl` + `GH_TOKEN` with an explicit
#     `command -v curl` capability check, never the `gh` CLI and never an
#     assumed-present binary: AG-CI-001/AG-CI-002 mean neither can be taken
#     for granted on the bare runner tier this code actually executes on
#   - the token never reaches curl's argv, any file on disk, or ghcr_retry's
#     own diagnostics
#   - the cache directory's EXIT trap preserves both the caller's own
#     pre-existing EXIT trap and the script's real exit status
#
# `run --separate-stderr` (Bats >= 1.5.0) is used for the curl-based query
# tests below: ghcr_retry's own ::warning::/::error:: diagnostics land on
# stderr, and a plain `run` would merge them into $output, making a bare
# `[ "$output" = ... ]`/`[ -z "$output" ]` check against the function's own
# stdout unreliable.
bats_require_minimum_version 1.5.0

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
    # Default token for saf_query_run_count's real curl-based path (see the
    # AG-CI-001 curl-not-gh reasoning in that file's own header) -- tests that need
    # to prove the GH_TOKEN-unset behavior unset/restore this themselves.
    export GH_TOKEN="test-token"
    sleep() { :; }
    export -f sleep
}

# ---------------------------------------------------------------------------
# SAF_ANCESTOR_RUN_CACHE_DIR lifecycle: created once per process via mktemp -d
# at source time, and -- since mktemp's own uniqueness means it is NEVER
# reused by a later, independent process on a long-lived self-hosted runner --
# must actually be removed again when that process exits, not left behind to
# accumulate indefinitely across every CI run that ever sources this file.
# ---------------------------------------------------------------------------

@test "SAF_ANCESTOR_RUN_CACHE_DIR: the process that creates it removes it again on its own exit" {
    # A genuinely separate bash process is required here (not this test's
    # own, which already inherited a cache dir from setup()'s own sourcing):
    # env -u ensures the child creates and registers the trap for a BRAND
    # NEW directory of its own, then this test checks from the outside, once
    # the child has exited, that the directory it reported no longer exists.
    reported_dir_file="$BATS_TEST_TMPDIR/reported_cache_dir.txt"
    env -u SAF_ANCESTOR_RUN_CACHE_DIR bash -c "
        source '$repo_root/scripts/lib/ghcr-retry.sh'
        source '$repo_root/scripts/lib/staging-image-freshness.sh'
        source '$repo_root/scripts/lib/staging-ancestor-fallback.sh'
        printf '%s' \"\$SAF_ANCESTOR_RUN_CACHE_DIR\" > '$reported_dir_file'
    "
    reported_dir="$(cat "$reported_dir_file")"
    [ -n "$reported_dir" ]
    [ ! -e "$reported_dir" ]
}

@test "SAF_ANCESTOR_RUN_CACHE_DIR: cleanup composes with a pre-existing EXIT trap instead of discarding it" {
    # Sourcing this file must never silently replace an EXIT trap the
    # caller script already installed for its own purposes -- verified by
    # setting a distinct marker trap BEFORE sourcing (in the child process,
    # so it does not disturb this test's own shell) and confirming that
    # marker's own side effect (writing to a sentinel file) still happens
    # once the child exits, in addition to the cache directory itself being
    # removed.
    reported_dir_file="$BATS_TEST_TMPDIR/reported_cache_dir.txt"
    sentinel_file="$BATS_TEST_TMPDIR/prior_trap_ran.txt"
    env -u SAF_ANCESTOR_RUN_CACHE_DIR bash -c "
        trap 'echo ran > \"$sentinel_file\"' EXIT
        source '$repo_root/scripts/lib/ghcr-retry.sh'
        source '$repo_root/scripts/lib/staging-image-freshness.sh'
        source '$repo_root/scripts/lib/staging-ancestor-fallback.sh'
        printf '%s' \"\$SAF_ANCESTOR_RUN_CACHE_DIR\" > '$reported_dir_file'
    "
    reported_dir="$(cat "$reported_dir_file")"
    [ -n "$reported_dir" ]
    [ ! -e "$reported_dir" ]
    [ -f "$sentinel_file" ]
    [ "$(cat "$sentinel_file")" = "ran" ]
}

@test "SAF_ANCESTOR_RUN_CACHE_DIR: a pre-existing EXIT trap containing an embedded single quote survives chaining verbatim" {
    # A naive fix would capture the prior trap via \`trap -p EXIT\` and slice
    # off just the outer quote CHARACTERS textually -- that recovers the
    # command's text but does NOT undo bash's own '\'' escaping for a single
    # quote embedded in the original command, silently corrupting it the
    # moment the prior trap's own command contains one (e.g. a real trap
    # running \`printf "%s" "it's ok"\` would become \`it'\''s ok\` once
    # re-embedded that way). The fix must instead let bash's own parser (via
    # \`eval\`) recover the original command exactly, whatever quoting it
    # itself contains. Proven here by making the sentinel file's own content
    # be exactly the marker trap's output, byte for byte, when that marker
    # trap's command itself contains a single quote.
    reported_dir_file="$BATS_TEST_TMPDIR/reported_cache_dir.txt"
    sentinel_file="$BATS_TEST_TMPDIR/prior_trap_output.txt"
    env -u SAF_ANCESTOR_RUN_CACHE_DIR bash -c "
        trap 'printf %s \"it'\''s ok\" > \"$sentinel_file\"' EXIT
        source '$repo_root/scripts/lib/ghcr-retry.sh'
        source '$repo_root/scripts/lib/staging-image-freshness.sh'
        source '$repo_root/scripts/lib/staging-ancestor-fallback.sh'
        printf '%s' \"\$SAF_ANCESTOR_RUN_CACHE_DIR\" > '$reported_dir_file'
    "
    reported_dir="$(cat "$reported_dir_file")"
    [ -n "$reported_dir" ]
    [ ! -e "$reported_dir" ]
    [ -f "$sentinel_file" ]
    # Must be EXACTLY "it's ok" -- not "it'\''s ok" (the escaped form a naive
    # textual slice would have produced) and not truncated at the embedded
    # quote (the failure mode of an even more naive extraction).
    [ "$(cat "$sentinel_file")" = "it's ok" ]
}

@test "SAF_ANCESTOR_RUN_CACHE_DIR: under set -e, a failing script still runs its prior EXIT trap, with the real exit status" {
    # Two distinct properties, both of which the combined EXIT trap has to
    # hold at once, and both of which only break when the script FAILS:
    #
    #   1. The prior trap runs AT ALL. `set -euo pipefail` (which every real
    #      caller of this library sets, and which this case therefore sets
    #      too) aborts a trap body at its first failing command. Any attempt
    #      to force `$?` back to a non-zero value inside the trap -- e.g. an
    #      `(exit "$captured_status")` subshell -- IS such a failing command,
    #      so it kills the trap before the prior trap is ever reached. The
    #      prior trap's sentinel file then never gets written at all.
    #   2. `$?` seen by the prior trap is the SCRIPT's own real exit status,
    #      not some command inside the trap. Running the cache cleanup first
    #      would overwrite it with that cleanup's own successful `rm`, so a
    #      prior trap logging or propagating a genuine CI failure would report
    #      a false "0".
    #
    # Both are satisfied only by invoking the prior trap FIRST and doing the
    # cleanup after it, with no status-restoring command anywhere in between.
    # Without `set -e` here this case cannot observe property 1 at all -- an
    # earlier version of it passed against an implementation that silently
    # skipped the prior trap on every real failure.
    reported_dir_file="$BATS_TEST_TMPDIR/reported_cache_dir.txt"
    sentinel_file="$BATS_TEST_TMPDIR/prior_trap_status.txt"
    run env -u SAF_ANCESTOR_RUN_CACHE_DIR bash -c "
        set -euo pipefail
        trap 'echo \"\$?\" > \"$sentinel_file\"' EXIT
        source '$repo_root/scripts/lib/ghcr-retry.sh'
        source '$repo_root/scripts/lib/staging-image-freshness.sh'
        source '$repo_root/scripts/lib/staging-ancestor-fallback.sh'
        printf '%s' \"\$SAF_ANCESTOR_RUN_CACHE_DIR\" > '$reported_dir_file'
        false
    "
    [ "$status" -eq 1 ]
    reported_dir="$(cat "$reported_dir_file")"
    [ -n "$reported_dir" ]
    # Property 1: the prior trap ran even though the script failed.
    [ -f "$sentinel_file" ]
    # Property 2: it saw the script's own real status, not the cleanup's.
    [ "$(cat "$sentinel_file")" = "1" ]
    # ...and the cache directory is still gone afterwards.
    [ ! -e "$reported_dir" ]
}

@test "SAF_ANCESTOR_RUN_CACHE_DIR: an explicit non-zero exit under set -e also reaches the prior EXIT trap" {
    # Same failure mode as the case above, reached the other way a real
    # script fails: an explicit `exit <n>` rather than an errexit-triggering
    # command. Both must leave the prior trap reachable and the script's own
    # status intact.
    sentinel_file="$BATS_TEST_TMPDIR/prior_trap_status_explicit.txt"
    run env -u SAF_ANCESTOR_RUN_CACHE_DIR bash -c "
        set -euo pipefail
        trap 'echo \"\$?\" > \"$sentinel_file\"' EXIT
        source '$repo_root/scripts/lib/ghcr-retry.sh'
        source '$repo_root/scripts/lib/staging-image-freshness.sh'
        source '$repo_root/scripts/lib/staging-ancestor-fallback.sh'
        exit 7
    "
    [ "$status" -eq 7 ]
    [ -f "$sentinel_file" ]
    [ "$(cat "$sentinel_file")" = "7" ]
}

@test "SAF_ANCESTOR_RUN_CACHE_DIR: the cache directory lives under RUNNER_TEMP when GitHub Actions provides one" {
    # The EXIT trap cannot cover a SIGKILL -- which is exactly what a job-level
    # timeout expiry eventually delivers -- so the directory's PARENT is the
    # real backstop: GitHub Actions wipes RUNNER_TEMP itself between jobs, so
    # anything under it is reclaimed even when this process never runs a line
    # of its own cleanup. This asserts the placement, not the wipe (that half
    # is the Actions runner's own behavior, not this repo's to test).
    runner_temp="$BATS_TEST_TMPDIR/runner-temp"
    mkdir -p "$runner_temp"
    reported_dir_file="$BATS_TEST_TMPDIR/reported_cache_dir_runner_temp.txt"
    RUNNER_TEMP="$runner_temp" env -u SAF_ANCESTOR_RUN_CACHE_DIR bash -c "
        source '$repo_root/scripts/lib/ghcr-retry.sh'
        source '$repo_root/scripts/lib/staging-image-freshness.sh'
        source '$repo_root/scripts/lib/staging-ancestor-fallback.sh'
        printf '%s' \"\$SAF_ANCESTOR_RUN_CACHE_DIR\" > '$reported_dir_file'
    "
    reported_dir="$(cat "$reported_dir_file")"
    [ -n "$reported_dir" ]
    [[ "$reported_dir" == "$runner_temp"/* ]]
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

    # Under services/proxy/ specifically (not a generic scripts/ change): the
    # saf_resolve_untouched_backfill_source tests below resolve for the
    # "proxy" service, and must see this as a real, proxy-AFFECTING change
    # (classify-image-impact.sh's own proxy=true rule), not just "not
    # docs/*.md" -- a generic scripts/ change would be untouched from
    # proxy's own service-scoped perspective and wrongly fast-path instead
    # of exercising the commit-wide fallback path these tests target.
    mkdir -p "$git_dir/services/proxy"
    echo "real change" > "$git_dir/services/proxy/real-change.conf"
    git -C "$git_dir" add services/proxy/real-change.conf
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

@test "saf_base_commit_paths_are_ignorable: a genuinely empty commit (a real parent, zero changed paths) is ignorable, not inconclusive" {
    # Distinguishes the two cases that both produce empty `git diff-tree`
    # stdout: a root commit (no sha^1 to diff against -- diff-tree itself
    # FAILS, exit 128, see the test above) versus a genuine `--allow-empty`
    # commit with a real parent (diff-tree SUCCEEDS, exit 0, simply finds no
    # differences). Only the exit status tells these apart; both look
    # identical if you only look at whether stdout is empty. An empty commit
    # changed nothing at all, so it vacuously matches the ignore list --
    # there is no changed path to violate it -- and must be treated the same
    # as any other confirmed-ignorable commit (status 0), not lumped in with
    # a genuine git failure (status 2, which would incorrectly force the
    # slow path and wait out the full freshness ceiling for an image that
    # will never exist for a commit that changed nothing).
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    git -C "$git_dir" commit -q --allow-empty -m root
    git -C "$git_dir" commit -q --allow-empty -m "genuinely empty"
    empty_sha="$(git -C "$git_dir" rev-parse HEAD)"

    run saf_base_commit_paths_are_ignorable "$empty_sha" "$git_dir"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# saf_base_commit_service_untouched: service-scoped sibling to
# saf_base_commit_paths_are_ignorable -- a real, non-doc commit can still
# leave one specific service untouched (2026-08-02 finding, live-confirmed
# via #1355/b46d81e and ui:sha-c7d42fe never being created after a Step 4
# reuse).

@test "saf_base_commit_service_untouched: a commit touching only a different service leaves the target service untouched" {
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    mkdir -p "$git_dir/services/ui"
    git -C "$git_dir" commit -q --allow-empty -m root
    echo "ui change" > "$git_dir/services/ui/main.rs"
    git -C "$git_dir" add services/ui/main.rs
    git -C "$git_dir" commit -q -m "ui-only change"
    ui_only_sha="$(git -C "$git_dir" rev-parse HEAD)"

    # A real, non-doc change -- confirmed NOT ignorable at the commit-wide
    # level -- yet proxy specifically was never touched by it.
    run saf_base_commit_paths_are_ignorable "$ui_only_sha" "$git_dir"
    [ "$status" -eq 1 ]

    run saf_base_commit_service_untouched "$ui_only_sha" "proxy" "$git_dir"
    [ "$status" -eq 0 ]

    run saf_base_commit_service_untouched "$ui_only_sha" "ui" "$git_dir"
    [ "$status" -eq 1 ]
}

@test "saf_base_commit_service_untouched: a commit touching the target service's own path is confirmed touched" {
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    mkdir -p "$git_dir/services/proxy"
    git -C "$git_dir" commit -q --allow-empty -m root
    echo "proxy change" > "$git_dir/services/proxy/nginx.conf"
    git -C "$git_dir" add services/proxy/nginx.conf
    git -C "$git_dir" commit -q -m "proxy change"
    proxy_sha="$(git -C "$git_dir" rev-parse HEAD)"

    run saf_base_commit_service_untouched "$proxy_sha" "proxy" "$git_dir"
    [ "$status" -eq 1 ]
}

@test "saf_base_commit_service_untouched: a docs-only commit leaves every service untouched, same verdict as the commit-wide check" {
    setup_linear_fixture
    run saf_base_commit_service_untouched "$base_sha" "proxy" "$git_dir"
    [ "$status" -eq 0 ]
}

@test "saf_base_commit_service_untouched: a root commit (no parent) is inconclusive, not falsely untouched" {
    setup_linear_fixture
    run saf_base_commit_service_untouched "$ancestor2_sha" "proxy" "$git_dir"
    [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# saf_query_run_count / saf_query_tag_publishing_run_count /
# saf_base_commit_has_confirmed_run: retry + event scoping, using a fake
# `curl` binary (not the STAGING_BASE_BUILD_RUN_EXISTS_CMD stub hook -- these
# tests exercise the REAL curl-based query path, including retry). No real
# network dependency anywhere in this block: these
# functions talk to the GitHub REST API directly via curl+GH_TOKEN, not the
# `gh` CLI, since AG-CI-001/AG-CI-002 mean `gh` cannot be assumed present on
# the bare `lancache-light` runner both real callers actually run on.
# GH_TOKEN's own default (so the real curl path is actually exercised
# without a live network) is set in setup() above.

# Installs a fake `curl` that fails FAKE_CURL_FAIL_COUNT times (transient,
# simulating a network-level failure -- curl's own exit code nonzero, no `-o`
# file written) before succeeding: writes a `{"total_count":N,...}` body to
# whatever file follows `-o` in its own arguments (parsed generically, not
# assumed to be a fixed positional arg, so this stays correct if
# _saf_github_api_get's own argument order ever changes) and prints
# FAKE_CURL_HTTP_STATUS (default 200) to stdout, matching curl's own
# `-w '%{http_code}'` behavior. FAKE_CURL_RUN_COUNT_FOR_EVENT, if set,
# overrides the count returned specifically when the request URL contains
# `&event=<that value>` -- lets a single fake stand in for
# saf_query_tag_publishing_run_count's three per-event-type sub-queries
# returning different counts.
install_fake_curl_flaky() {
    fake_bin_dir="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$fake_bin_dir"
    fail_count_file="$BATS_TEST_TMPDIR/curl_fail_count"
    echo "${FAKE_CURL_FAIL_COUNT:-0}" > "$fail_count_file"
    call_log="$BATS_TEST_TMPDIR/curl_calls.log"
    : > "$call_log"
    cat > "$fake_bin_dir/curl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$call_log"
remaining=\$(cat "$fail_count_file")
if [ "\$remaining" -gt 0 ]; then
    remaining=\$((remaining - 1))
    echo "\$remaining" > "$fail_count_file"
    exit 1
fi
out_file=""
url=""
prev=""
for arg in "\$@"; do
    if [ "\$prev" = "-o" ]; then
        out_file="\$arg"
    fi
    prev="\$arg"
    url="\$arg"
done
count="${FAKE_CURL_RUN_COUNT:-0}"
case "\$url" in
    *"&event=${FAKE_CURL_RUN_COUNT_FOR_EVENT_NAME:-__none__}"*) count="${FAKE_CURL_RUN_COUNT_FOR_EVENT:-0}" ;;
esac
printf '{"total_count":%s,"workflow_runs":[]}' "\$count" > "\$out_file"
printf '%s' "${FAKE_CURL_HTTP_STATUS:-200}"
STUB
    chmod +x "$fake_bin_dir/curl"
    export PATH="$fake_bin_dir:$PATH"
}

@test "saf_query_run_count: retries a transient network failure and succeeds on a later attempt" {
    export FAKE_CURL_FAIL_COUNT=2
    export FAKE_CURL_RUN_COUNT=1
    install_fake_curl_flaky
    run --separate-stderr saf_query_run_count "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" "push"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    # 2 failures + 1 success = 3 calls, proving the retry actually happened,
    # not that the first attempt happened to succeed.
    [ "$(wc -l < "$call_log")" -eq 3 ]
}

@test "saf_query_run_count: the Authorization header is present via stdin on every retry attempt, not just the first" {
    # _saf_github_api_get is re-invoked as a genuinely fresh function call
    # on every ghcr_retry attempt (ghcr_retry's own loop calls "$@" itself
    # again each iteration, not just re-running a single already-started
    # curl process) -- so the here-string/-K - config it builds should be
    # recomputed fresh each time too, but this is exactly the kind of thing
    # worth proving directly rather than only reasoning about: a stub that
    # actually reads stdin (install_fake_curl_flaky's own stub never does,
    # since it doesn't need to) confirms the Authorization line is genuinely
    # present, unconsumed-elsewhere, and correctly formed on the LAST
    # (successful, third) attempt -- not just on the first one before any
    # retry has happened.
    fake_bin_dir="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$fake_bin_dir"
    call_count_file="$BATS_TEST_TMPDIR/curl_call_count"
    echo 0 > "$call_count_file"
    stdin_capture_dir="$BATS_TEST_TMPDIR/stdin_captures"
    mkdir -p "$stdin_capture_dir"
    cat > "$fake_bin_dir/curl" <<STUB
#!/usr/bin/env bash
count="\$(cat "$call_count_file")"
count=\$((count + 1))
echo "\$count" > "$call_count_file"
cat > "$stdin_capture_dir/attempt_\$count.txt"
out_file=""
prev=""
for arg in "\$@"; do
    if [ "\$prev" = "-o" ]; then
        out_file="\$arg"
    fi
    prev="\$arg"
done
if [ "\$count" -lt 3 ]; then
    exit 1
fi
printf '{"total_count":1,"workflow_runs":[]}' > "\$out_file"
printf '200'
STUB
    chmod +x "$fake_bin_dir/curl"
    export PATH="$fake_bin_dir:$PATH"
    run saf_query_run_count "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" "push"
    [ "$status" -eq 0 ]
    [ "$(cat "$call_count_file")" -eq 3 ]
    # Every attempt (not just the last) must have genuinely received the
    # header config via stdin -- proves the here-string is freshly
    # (re-)supplied on each call, never empty on a retry.
    for attempt_file in "$stdin_capture_dir"/attempt_*.txt; do
        grep -qF 'Authorization: Bearer test-token' "$attempt_file"
    done
}

@test "saf_query_run_count: exhausts retries and fails closed (no output) on a persistent network failure" {
    export FAKE_CURL_FAIL_COUNT=99
    export FAKE_CURL_RUN_COUNT=0
    install_fake_curl_flaky
    run --separate-stderr saf_query_run_count "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" "push"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    # GHCR_RETRY_MAX_ATTEMPTS=4 (set in setup()) -- exactly 4 calls, not an
    # unbounded retry loop.
    [ "$(wc -l < "$call_log")" -eq 4 ]
}

@test "saf_query_run_count: GH_TOKEN never appears in ghcr_retry's own retry/failure diagnostics" {
    # ghcr_retry logs its own wrapped command verbatim via \$* in its
    # ::warning::/::error:: lines on every failed attempt (see
    # scripts/lib/ghcr-retry.sh). If _saf_github_api_get ever took the token
    # as one of ITS OWN positional arguments again, that argument would
    # become part of \$* too -- the token would be echoed into the
    # job log in plain text on every single retry, not just once, relying
    # entirely on GitHub Actions' own best-effort exact-string log masking as
    # the only protection (which does not help at all for a manually-supplied
    # PAT, since neither real caller requires GH_TOKEN to be exactly
    # secrets.GITHUB_TOKEN). Force every attempt to fail so ghcr_retry emits
    # both its per-attempt ::warning:: lines and its final ::error:: line,
    # and confirm none of that stderr output contains the token value at all
    # -- not just that GitHub's masking would have hidden it.
    export FAKE_CURL_FAIL_COUNT=99
    export FAKE_CURL_RUN_COUNT=0
    install_fake_curl_flaky
    run --separate-stderr saf_query_run_count "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" "push"
    [ "$status" -ne 0 ]
    # shellcheck disable=SC2154 # $stderr is populated by Bats itself via
    # `run --separate-stderr` (Bats >= 1.5.0, required above); the Bats
    # dialect support recognizes $status/$output/$lines but not this newer
    # variable, so it misreports it as never assigned.
    [[ "$stderr" == *"::error::"* ]]
    # shellcheck disable=SC2154 # same $stderr, see above
    [[ "$stderr" != *"test-token"* ]]
}

@test "saf_query_run_count: the token never appears in curl's own invoked argv either, not just in ghcr_retry's diagnostics" {
    # Even with the token kept out of ghcr_retry's own \$*-logged diagnostics
    # (the test above), the token must also never be a literal argument TO
    # curl itself -- visible for curl's own process lifetime to any other
    # process running as the same host user (e.g. via /proc/<pid>/cmdline on
    # a shared self-hosted runner), regardless of what ghcr_retry logs.
    # install_fake_curl_flaky's own call_log records curl's REAL argv on
    # every invocation, so this proves the fix at the level that actually
    # matters: the token must never appear there, only the literal,
    # harmless "-K -" (config read from stdin, never from an argument).
    export FAKE_CURL_FAIL_COUNT=0
    export FAKE_CURL_RUN_COUNT=1
    install_fake_curl_flaky
    run saf_query_run_count "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" "push"
    [ "$status" -eq 0 ]
    [[ "$(cat "$call_log")" != *"test-token"* ]]
    [[ "$(cat "$call_log")" != *"Authorization"* ]]
    [[ "$(cat "$call_log")" == *"-K -"* ]]
}

@test "saf_query_run_count: the Authorization header reaches curl without ever being written to a file on disk" {
    # A mode-600 temp file passed via -H @<file> would keep the token out of
    # argv, but not out of reach of another process running as the SAME host
    # user (file permission bits protect against other users, not other
    # processes owned by the identical UID) -- curl's own -K - (config from
    # stdin) closes that gap: the header text is piped in via a bash
    # here-string, which this project's own pinned bash implements as a
    # PIPE, not a temp file, so no file containing the token's actual value
    # ever exists on disk at any point. Proven here by having the fake curl
    # itself recursively grep every file under a disposable $TMPDIR for the
    # literal token value at the moment it runs -- legitimate, unrelated
    # temp files this same call also creates (e.g. saf_query_run_count's own
    # response-body file) are expected to exist and are not what this test
    # cares about; only the SECRET VALUE itself must never appear in any of
    # them.
    fake_tmpdir="$BATS_TEST_TMPDIR/fake_tmpdir"
    mkdir -p "$fake_tmpdir"
    export TMPDIR="$fake_tmpdir"
    export FAKE_CURL_FAIL_COUNT=0
    export FAKE_CURL_RUN_COUNT=1
    install_fake_curl_flaky
    tmpdir_grep_capture="$BATS_TEST_TMPDIR/tmpdir_grep_result.txt"
    cat > "$fake_bin_dir/curl" <<STUB
#!/usr/bin/env bash
grep -rl "test-token" "$fake_tmpdir" > "$tmpdir_grep_capture" 2>/dev/null
echo "\$*" >> "$call_log"
out_file=""
prev=""
for arg in "\$@"; do
    if [ "\$prev" = "-o" ]; then
        out_file="\$arg"
    fi
    prev="\$arg"
done
printf '{"total_count":1,"workflow_runs":[]}' > "\$out_file"
printf '200'
STUB
    chmod +x "$fake_bin_dir/curl"
    run saf_query_run_count "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" "push"
    [ "$status" -eq 0 ]
    [ -f "$tmpdir_grep_capture" ]
    # No file anywhere under $TMPDIR contains the token's value -- proves the
    # secret itself never touches disk, regardless of what other, unrelated
    # temp files this same call legitimately creates.
    [ -z "$(cat "$tmpdir_grep_capture")" ]
}

@test "saf_query_run_count: a non-200 HTTP status is treated as a retryable failure, not a false zero" {
    # curl itself can succeed (exit 0) while the API returns a non-2xx
    # status (rate limit, auth rejection, transient 5xx) -- _saf_github_api_get
    # must treat that as a failure too (ghcr_retry only sees a nonzero exit
    # as retryable), not silently report whatever total_count happens to be
    # in an error response body.
    export FAKE_CURL_FAIL_COUNT=0
    export FAKE_CURL_HTTP_STATUS=403
    export FAKE_CURL_RUN_COUNT=0
    install_fake_curl_flaky
    run --separate-stderr saf_query_run_count "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" "push"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    # Retried the full GHCR_RETRY_MAX_ATTEMPTS times -- a non-200 status is
    # genuinely retried, not accepted on the first attempt.
    [ "$(wc -l < "$call_log")" -eq 4 ]
}

@test "saf_query_run_count: a 401 (invalid token) fails fast on the first attempt instead of exhausting the full retry budget" {
    # A 401 is a permanent, configuration-level failure (an invalid/expired
    # GH_TOKEN) -- retrying with backoff cannot fix it. _saf_github_api_get
    # must classify this into GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE so
    # ghcr_retry stops after one attempt, not GHCR_RETRY_MAX_ATTEMPTS (4)
    # attempts with a 30s-equivalent backoff between each -- both real
    # callers repeat this query once per untouched service, so a genuine
    # auth misconfiguration could otherwise burn a large fraction of the
    # caller's own job timeout before reaching the inevitable failure.
    export FAKE_CURL_FAIL_COUNT=0
    export FAKE_CURL_HTTP_STATUS=401
    export FAKE_CURL_RUN_COUNT=0
    install_fake_curl_flaky
    run --separate-stderr saf_query_run_count "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" "push"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [ "$(wc -l < "$call_log")" -eq 1 ]
    # shellcheck disable=SC2154 # $stderr is populated by Bats itself via
    # `run --separate-stderr` (Bats >= 1.5.0, required above); the Bats
    # dialect support recognizes $status/$output/$lines but not this newer
    # variable, so it misreports it as never assigned.
    [[ "$stderr" == *"permanent (non-retryable) error"* ]]
}

@test "saf_query_run_count: a 404 (wrong endpoint/repository) fails fast on the first attempt instead of exhausting the full retry budget" {
    # Mirror of the 401 test above: a 404 is equally permanent (a genuinely
    # wrong repository/workflow path), not a transient condition retrying
    # could resolve.
    export FAKE_CURL_FAIL_COUNT=0
    export FAKE_CURL_HTTP_STATUS=404
    export FAKE_CURL_RUN_COUNT=0
    install_fake_curl_flaky
    run --separate-stderr saf_query_run_count "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" "push"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [ "$(wc -l < "$call_log")" -eq 1 ]
    # shellcheck disable=SC2154 # $stderr is populated by Bats itself via
    # `run --separate-stderr` (Bats >= 1.5.0, required above); the Bats
    # dialect support recognizes $status/$output/$lines but not this newer
    # variable, so it misreports it as never assigned.
    [[ "$stderr" == *"permanent (non-retryable) error"* ]]
}

@test "saf_base_commit_has_confirmed_run: a persistent failure is treated as inconclusive (2), not confirmed-zero" {
    export FAKE_CURL_FAIL_COUNT=99
    export FAKE_CURL_RUN_COUNT=0
    install_fake_curl_flaky
    unset STAGING_BASE_BUILD_RUN_EXISTS_CMD
    run saf_base_commit_has_confirmed_run "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" "push"
    [ "$status" -eq 2 ]
}

@test "saf_base_commit_has_confirmed_run: GH_TOKEN unset is treated as inconclusive (2), never as a real API check" {
    unset GH_TOKEN
    unset STAGING_BASE_BUILD_RUN_EXISTS_CMD
    # No fake curl installed at all -- if the implementation still shelled
    # out to a real `curl`/`gh` without GH_TOKEN, this would either hang on
    # a real network call or hit whatever curl/gh happens to be on this
    # test runner's real PATH. Failing fast and closed on the missing token
    # is what proves it never gets that far.
    run saf_base_commit_has_confirmed_run "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" "push"
    [ "$status" -eq 2 ]
    export GH_TOKEN="test-token"
}

@test "saf_query_run_count: curl missing is treated as inconclusive, an explicit capability check, not an assumption" {
    # AG-CI-001 does not carve out an exception for curl just because it's
    # a near-universal base-OS utility -- this must be an explicit,
    # fail-closed `command -v curl` check (mirroring the old `command -v gh`
    # check exactly), not a bare assumption that calling curl will work.
    # Simulated by pointing PATH at an empty directory so no `curl` (real
    # or fake) can be found at all.
    empty_path_dir="$BATS_TEST_TMPDIR/empty_path"
    mkdir -p "$empty_path_dir"
    old_path="$PATH"
    export PATH="$empty_path_dir"
    run saf_query_run_count "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" "push"
    export PATH="$old_path"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "saf_query_tag_publishing_run_count: genuinely zero everywhere checks push/workflow_dispatch/schedule, never pull_request" {
    export FAKE_CURL_FAIL_COUNT=0
    export FAKE_CURL_RUN_COUNT=0
    install_fake_curl_flaky
    run saf_query_tag_publishing_run_count "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
    # A genuine zero across every tag-publishing event type must check all
    # three (push, workflow_dispatch, schedule) before concluding zero --
    # not 1 (a single unfiltered query) and not 4+ (accidentally also
    # querying pull_request).
    [ "$(wc -l < "$call_log")" -eq 3 ]
    grep -qF "event=push" "$call_log"
    grep -qF "event=workflow_dispatch" "$call_log"
    grep -qF "event=schedule" "$call_log"
    [[ "$(cat "$call_log")" != *"event=pull_request"* ]]
}

@test "saf_query_tag_publishing_run_count: stops at the first non-zero event type instead of querying all three" {
    # A rate-limit/efficiency concern, not just a correctness one: the exact
    # count is never needed by any caller (only zero vs non-zero), so once
    # push confirms at least one run, workflow_dispatch/schedule must not
    # also be queried.
    export FAKE_CURL_FAIL_COUNT=0
    export FAKE_CURL_RUN_COUNT_FOR_EVENT_NAME="push"
    export FAKE_CURL_RUN_COUNT_FOR_EVENT=1
    export FAKE_CURL_RUN_COUNT=0
    install_fake_curl_flaky
    run saf_query_tag_publishing_run_count "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    # Exactly 1 call -- push is queried first (see the function's own
    # event-order loop) and its non-zero result short-circuits the rest.
    [ "$(wc -l < "$call_log")" -eq 1 ]
    grep -qF "event=push" "$call_log"
}

@test "saf_base_commit_has_confirmed_run: a pull_request-only run for a candidate does NOT count as a confirmed build" {
    # The exact scenario the coordinator's finding describes: an ancestor
    # candidate has a real recorded pull_request-triggered run (e.g. it was
    # itself once a PR head commit), but zero push/workflow_dispatch/schedule
    # runs -- since a pull_request run's github.sha is a synthetic merge
    # commit, not this candidate's own sha, it never published this
    # candidate's own sha-<short> tag. The ancestor-candidate check (event="")
    # must report "confirmed zero" (1), not "a run exists" (0), so
    # saf_find_built_ancestor correctly walks past this candidate instead of
    # wasting a freshness poll on a tag that will never appear.
    export FAKE_CURL_FAIL_COUNT=0
    export FAKE_CURL_RUN_COUNT=0
    install_fake_curl_flaky
    unset STAGING_BASE_BUILD_RUN_EXISTS_CMD
    run saf_base_commit_has_confirmed_run "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead" ""
    [ "$status" -eq 1 ]
    [[ "$(cat "$call_log")" != *"event=pull_request"* ]]
}

# ---------------------------------------------------------------------------
# saf_candidate_run_is_active: direct unit coverage against a fake curl that
# can return runs with real `status` fields (install_fake_curl_flaky above
# always returns an empty workflow_runs array, which can never exercise the
# "found a non-completed status" branch).
# ---------------------------------------------------------------------------

# Installs a fake `curl` returning a fixed JSON body (one workflow run with
# FAKE_CURL_STATUS's own value) for every call, logging each call's args.
install_fake_curl_with_status() {
    fake_bin_dir="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$fake_bin_dir"
    call_log="$BATS_TEST_TMPDIR/curl_calls.log"
    : > "$call_log"
    cat > "$fake_bin_dir/curl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$call_log"
out_file=""
prev=""
for arg in "\$@"; do
    if [ "\$prev" = "-o" ]; then
        out_file="\$arg"
    fi
    prev="\$arg"
done
printf '{"total_count":1,"workflow_runs":[{"status":"${FAKE_CURL_STATUS:-completed}"}]}' > "\$out_file"
printf '200'
STUB
    chmod +x "$fake_bin_dir/curl"
    export PATH="$fake_bin_dir:$PATH"
}

@test "saf_candidate_run_is_active: a non-completed status is reported as active" {
    export FAKE_CURL_STATUS="in_progress"
    install_fake_curl_with_status
    run saf_candidate_run_is_active "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead"
    [ "$status" -eq 0 ]
    # Stops at the first event type (push) that turns up a non-completed
    # status -- not all three.
    [ "$(wc -l < "$call_log")" -eq 1 ]
    grep -qF "event=push" "$call_log"
}

@test "saf_candidate_run_is_active: every run completed across all three event types is confirmed not active" {
    export FAKE_CURL_STATUS="completed"
    install_fake_curl_with_status
    run saf_candidate_run_is_active "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead"
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$call_log")" -eq 3 ]
}

@test "saf_candidate_run_is_active: GH_TOKEN unset is inconclusive (2), not confirmed-inactive" {
    unset GH_TOKEN
    run saf_candidate_run_is_active "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead"
    [ "$status" -eq 2 ]
    export GH_TOKEN="test-token"
}

@test "saf_candidate_run_is_active: curl missing is treated as inconclusive (2), the same explicit capability check as saf_query_run_count" {
    # This function has its own "command -v curl" guard, separate from
    # saf_query_run_count's -- it must fail closed the same way rather than
    # relying on the caller to have already checked. Simulated the same way
    # as the saf_query_run_count curl-missing test: point PATH at an empty
    # directory so no curl (real or fake) can be found at all.
    empty_path_dir="$BATS_TEST_TMPDIR/empty_path_active"
    mkdir -p "$empty_path_dir"
    old_path="$PATH"
    export PATH="$empty_path_dir"
    run saf_candidate_run_is_active "wiki-mod/lancache-ng" "deadbeef0123456789deadbeef0123456789dead"
    export PATH="$old_path"
    [ "$status" -eq 2 ]
    # GH_TOKEN is set (default from setup()), so a 2 here can only come from
    # the curl guard, not the token guard -- and no fake curl was installed
    # in this test at all, so any stdout output would mean the guard was
    # skipped and something further down actually ran.
    [ -z "$output" ]
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

# Freshness stub: only images matching the given commit's own full-SHA
# suffix resolve (the canonical, post-cutover tag format saf_resolve_sha_image_ref's
# primary probe targets); keyed via STAGING_IMAGE_REVISION_CMD. See the
# dedicated legacy-short-tag-only test below for the fallback path's own
# coverage.
install_revision_stub_for() {
    local sha="$1"
    revision_stub="$BATS_TEST_TMPDIR/revision_$sha.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
image="\$1"
suffix="\${image##*:sha-}"
if [ "\$suffix" = "${sha}" ]; then
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
    # Real docs/*.md-touching commits, not --allow-empty: this fixture only
    # needs the walk to reach the configured depth, which real docs-only
    # commits prove regardless of how an empty commit would be classified
    # (see the dedicated --allow-empty tests above for that case).
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
    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 3 0 0 0 0 0 "$git_dir"
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
    "${t1_sha}") echo "$t1_sha" ;;
    "${f1_sha}") echo "$f1_sha" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    # See the SIGPIPE regression test's own comment above for why the LAST
    # line (not $output's full text) is checked -- bats' `run` merges
    # stdout+stderr, and sif_wait_for_fresh_base_image's own ::notice::
    # diagnostics land on stderr ahead of the confirmed sha itself.
    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$merge_sha" "proxy" "proxy" 10 0 0 0 0 0 "$git_dir"
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
    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 10 0 0 0 0 0 "$git_dir"
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

    # Under services/proxy/ specifically (not a generic scripts/ change): both
    # tests below resolve "proxy" as the service, and saf_find_built_ancestor
    # now also checks saf_base_commit_service_untouched for each candidate --
    # a generic scripts/ change would read as untouched-by-proxy and let the
    # walk continue past this candidate instead of exercising the commit-wide
    # paths-gate/direct-image-check behavior these tests actually target.
    mkdir -p "$git_dir/services/proxy"
    echo "real change" > "$git_dir/services/proxy/real-change.conf"
    git -C "$git_dir" add services/proxy/real-change.conf
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

    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 10 0 0 0 0 0 "$git_dir"
    [ "$status" -ne 0 ]
    # Must NOT have substituted grandparent -- confirms this is a genuine
    # fail-closed stop, not a successful (wrong) resolution.
    [[ "$output" != *"$grandparent_sha"* ]]
    # The diagnostic must actually name real_change_parent_sha as the
    # candidate that blocked the walk -- proves the failure is attributed
    # to the right commit, not just "some" failure that happens to also
    # not mention grandparent.
    [[ "$output" == *"$real_change_parent_sha"* ]]
}

@test "saf_find_built_ancestor: a run-less candidate with a real path change but a genuinely existing, correctly-labeled image is used directly, not blocked" {
    # Workflow run history has a finite retention window (GitHub Actions,
    # commonly 90 days), but this project's own durable per-commit
    # sha-<short> image tags are not subject to that retention at all -- a
    # candidate built long enough ago that its run record has since expired
    # would report zero runs here even though it genuinely WAS built and its
    # image still exists. Same fixture shape as the test above (a real,
    # non-doc path change, zero recorded runs), except this candidate's own
    # image genuinely exists and is correctly labeled -- proving that, unlike
    # the test above (where checking the image ALSO comes up empty), a
    # positively confirmed existing image is accepted directly instead of
    # failing closed, since it is stronger, retention-independent proof of a
    # real build than the (here misleadingly empty) run query.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    mkdir -p "$git_dir/docs" "$git_dir/scripts"

    echo "grandparent" > "$git_dir/docs/grandparent.md"
    git -C "$git_dir" add docs/grandparent.md
    git -C "$git_dir" commit -q -m grandparent
    grandparent_sha="$(git -C "$git_dir" rev-parse HEAD)"

    # Under services/proxy/ specifically (not a generic scripts/ change): both
    # tests below resolve "proxy" as the service, and saf_find_built_ancestor
    # now also checks saf_base_commit_service_untouched for each candidate --
    # a generic scripts/ change would read as untouched-by-proxy and let the
    # walk continue past this candidate instead of exercising the commit-wide
    # paths-gate/direct-image-check behavior these tests actually target.
    mkdir -p "$git_dir/services/proxy"
    echo "real change" > "$git_dir/services/proxy/real-change.conf"
    git -C "$git_dir" add services/proxy/real-change.conf
    git -C "$git_dir" commit -q -m "real change parent"
    real_change_parent_sha="$(git -C "$git_dir" rev-parse HEAD)"

    echo "base" > "$git_dir/docs/base.md"
    git -C "$git_dir" add docs/base.md
    git -C "$git_dir" commit -q -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    # Every run query reports zero -- including for real_change_parent_sha,
    # simulating its own genuine run record having since expired from
    # Actions' retention window.
    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    # The image itself, unlike the run record, genuinely still exists and is
    # correctly labeled for real_change_parent_sha specifically.
    install_revision_stub_for "$real_change_parent_sha"

    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 10 0 0 0 0 0 "$git_dir"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "$real_change_parent_sha" ]
}

@test "saf_find_built_ancestor: a run-less candidate that is itself a genuinely empty commit is walked past, not blocked" {
    # The positive counterpart to the test above: a run-less mid-walk
    # candidate is only a walk-blocking failure when its OWN changed paths
    # cannot be positively confirmed safe to skip. A genuinely empty commit
    # (--allow-empty, a real parent, zero changed paths) has nothing that
    # could be missing from a substituted older ancestor, so
    # saf_base_commit_paths_are_ignorable now confirms it ignorable (status
    # 0, not the pre-fix inconclusive status 2) and the walk must continue
    # to the next real, run-bearing candidate instead of failing closed.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    mkdir -p "$git_dir/docs"

    echo "grandparent" > "$git_dir/docs/grandparent.md"
    git -C "$git_dir" add docs/grandparent.md
    git -C "$git_dir" commit -q -m grandparent
    grandparent_sha="$(git -C "$git_dir" rev-parse HEAD)"

    git -C "$git_dir" commit -q --allow-empty -m "empty run-less parent"

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

    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 10 0 0 0 0 0 "$git_dir"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "$grandparent_sha" ]
}

@test "saf_find_built_ancestor: an inconclusive run-check for a candidate fails closed even if its image would otherwise pass freshness" {
    # A candidate's run-check returning inconclusive (status 2 -- gh
    # unavailable, API error after retries) must never be treated the same
    # as a confirmed run: falling through to the freshness check would
    # accept this candidate purely because its image happens to satisfy
    # sif_is_ancestor_or_equal, with no positive proof any build-push.yml
    # run ever produced it. This candidate's own image WOULD resolve
    # correctly if the freshness check were attempted (the revision stub
    # below proves that) -- so if this test passes, it's specifically
    # because the inconclusive run-check itself stopped the walk, not
    # because no usable image existed.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    git -C "$git_dir" commit -q --allow-empty -m ancestor
    ancestor_sha="$(git -C "$git_dir" rev-parse HEAD)"
    git -C "$git_dir" commit -q --allow-empty -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<'STUB'
#!/usr/bin/env bash
exit 2
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    install_revision_stub_for "$ancestor_sha"

    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 10 0 0 0 0 0 "$git_dir"
    [ "$status" -ne 0 ]
    # Fails via the new inconclusive-run-check branch specifically (its own
    # diagnostic legitimately names the candidate, unlike a successful
    # resolution which would print it as the accepted answer on stdout) --
    # checked by requiring the diagnostic text, not by requiring the
    # candidate's sha be absent from $output.
    [[ "$output" == *"could not be positively determined"* ]]
}

@test "saf_find_built_ancestor: caches a definitive run-existence answer across repeated calls for the same candidate -- the redundant-lookups-across-services fix" {
    # Simulates two different untouched services (this test's two separate
    # saf_find_built_ancestor invocations) independently walking the exact
    # same base_sha's ancestor history in the same job run -- the real
    # "long docs-only chain, redundant per-service run lookups against a
    # shared repository-scoped GitHub API rate limit" finding this cache
    # exists to fix. The underlying run-existence check for the SAME
    # candidate must be queried at most once total, not once per call.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    git -C "$git_dir" commit -q --allow-empty -m ancestor
    ancestor_sha="$(git -C "$git_dir" rev-parse HEAD)"
    git -C "$git_dir" commit -q --allow-empty -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    call_count_file="$BATS_TEST_TMPDIR/run_exists_call_count"
    echo 0 > "$call_count_file"
    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
count="\$(cat "$call_count_file")"
count=\$((count + 1))
echo "\$count" > "$call_count_file"
exit 0
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    install_revision_stub_for "$ancestor_sha"

    # Uses bats' `run` deliberately, not despite it: `run` captures output
    # via a command substitution, which forks a subshell -- exactly the same
    # shape both real callers use (`resolved_source="$(saf_resolve_untouched_backfill_source ...)"`
    # once per service, inside a loop). This is precisely why the cache is a
    # real file under $SAF_ANCESTOR_RUN_CACHE_DIR rather than a shell
    # variable/array: a file written inside one `run`-forked subshell is
    # still there for the NEXT `run`-forked subshell to read, unlike shell
    # state, which a subshell can never write back to its parent (an
    # in-memory version of this cache was caught live failing this exact
    # test for that reason -- proof the underlying mechanism, not just this
    # test's own plumbing, is what's being checked here).
    # First "service": a real query, exactly once.
    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 10 0 0 0 0 0 "$git_dir"
    [ "$status" -eq 0 ]
    [ "$(cat "$call_count_file")" -eq 1 ]

    # Second "service", same base_sha/candidate chain -- must hit the cache,
    # not issue a second real query, even though this is a completely
    # separate saf_find_built_ancestor call (a different service in the same
    # process, exactly like scripts/untracked/ensure-pr-staging-images.sh's own loop
    # over full_setup_services).
    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "dns" "dns_image" 10 0 0 0 0 0 "$git_dir"
    [ "$status" -eq 0 ]
    [ "$(cat "$call_count_file")" -eq 1 ]
}

@test "saf_find_built_ancestor: an inconclusive run-check for a candidate is never cached -- a later, independent query can still succeed" {
    # Regression guard for the deliberate "only cache a definitive answer"
    # scoping in the fix above: an inconclusive (status 2) result reflects a
    # query FAILURE, not a historical fact, so caching it could make one
    # transient blip permanently fail every later service's own check too,
    # even ones that would have queried successfully on their own. This
    # proves the opposite: a fresh saf_find_built_ancestor call for the same
    # candidate after an earlier inconclusive result genuinely re-queries
    # (the call count increases) and can still succeed.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    git -C "$git_dir" commit -q --allow-empty -m ancestor
    ancestor_sha="$(git -C "$git_dir" rev-parse HEAD)"
    git -C "$git_dir" commit -q --allow-empty -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    call_count_file="$BATS_TEST_TMPDIR/run_exists_call_count"
    echo 0 > "$call_count_file"
    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
count="\$(cat "$call_count_file")"
count=\$((count + 1))
echo "\$count" > "$call_count_file"
# Inconclusive on the first call ever, a confirmed run on every call after.
if [ "\$count" -eq 1 ]; then
    exit 2
else
    exit 0
fi
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    install_revision_stub_for "$ancestor_sha"

    # Uses bats' `run` deliberately -- see the analogous caching test above
    # for why this file-based cache is specifically designed to survive the
    # subshell `run` (and both real callers' own `$(...)`) forks, unlike an
    # in-memory version would have.
    # First call: inconclusive -> fails closed, per the existing JUDGMENT
    # CALL, and must NOT cache that inconclusive answer.
    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 10 0 0 0 0 0 "$git_dir"
    [ "$status" -ne 0 ]
    [ "$(cat "$call_count_file")" -eq 1 ]

    # Second call, same candidate: must genuinely re-query (call count
    # increases to 2, proving no stale inconclusive answer was cached) and
    # this time succeeds since the stub now reports a confirmed run.
    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "dns" "dns_image" 10 0 0 0 0 0 "$git_dir"
    [ "$status" -eq 0 ]
    [ "$(cat "$call_count_file")" -eq 2 ]
}

@test "saf_find_built_ancestor: a corrupted (empty) cache file is treated as a miss, never as a false has_run == 0" {
    # A cache write that failed partway (e.g. the runner's disk filling up
    # mid-write) could leave an empty regular file behind even with the
    # write's own \`|| true\` swallowing the error. Reading that empty string
    # back into \`(( has_run == 1 ))\`/\`(( has_run == 2 ))\` would silently
    # evaluate it as 0 -- the single MOST PERMISSIVE outcome ("a run
    # positively confirmed to exist"), skipping the required API proof
    # entirely. Simulates exactly that: writes an empty file directly at the
    # cache path a real write would have used, then proves a genuine query
    # still happens (the call count increases) rather than the corrupted
    # entry being trusted.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    git -C "$git_dir" commit -q --allow-empty -m ancestor
    ancestor_sha="$(git -C "$git_dir" rev-parse HEAD)"
    git -C "$git_dir" commit -q --allow-empty -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    cache_file="$(_saf_ancestor_run_cache_key_to_path "wiki-mod/lancache-ng" "$ancestor_sha")"
    : > "$cache_file"
    [ -e "$cache_file" ]
    [ -z "$(cat "$cache_file")" ]

    call_count_file="$BATS_TEST_TMPDIR/run_exists_call_count"
    echo 0 > "$call_count_file"
    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
count="\$(cat "$call_count_file")"
count=\$((count + 1))
echo "\$count" > "$call_count_file"
exit 0
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    install_revision_stub_for "$ancestor_sha"

    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 10 0 0 0 0 0 "$git_dir"
    [ "$status" -eq 0 ]
    # A trusted (but wrong) empty-file read would never have called the real
    # run-exists stub at all (call count stays 0); a correct cache-miss
    # re-query calls it exactly once.
    [ "$(cat "$call_count_file")" -eq 1 ]
}

@test "saf_resolve_untouched_backfill_source: BASE_SHA's own pre/post push-run re-derivation is unaffected by the ancestor-candidate cache" {
    # Regression guard for the fix's own scoping: the ancestor-candidate
    # cache above must never leak into saf_base_commit_has_confirmed_run's
    # OTHER call sites -- specifically BASE_SHA's own pre_run_status/
    # post_run_status pair in saf_resolve_untouched_backfill_source, which is
    # INTENTIONALLY queried twice, independently, so a fast-path bug can only
    # cost time, never safety (that function's own header). Proves the two
    # BASE_SHA push-run checks still both genuinely execute (call count
    # reaches 2), not silently collapsed into one by a cache leaking across
    # this file's other functions.
    setup_linear_fixture
    call_count_file="$BATS_TEST_TMPDIR/run_exists_call_count"
    echo 0 > "$call_count_file"
    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
count="\$(cat "$call_count_file")"
count=\$((count + 1))
echo "\$count" > "$call_count_file"
exit 0
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    # Deliberately an UNRECOGNIZED classify_key ("nonexistent-service", not a
    # real scripts/untracked/classify-image-impact.sh output key): forces
    # saf_base_commit_service_untouched to be inconclusive (status 2) on
    # every call regardless of what base_sha actually touched, so this test
    # still exercises the paths_are_ignorable + has_confirmed_run route this
    # regression guard targets. A real classify_key would make
    # saf_base_commit_service_untouched succeed FIRST for base_sha's
    # genuinely docs-only diff (every real service is untouched by a doc
    # change), short-circuiting before either has_confirmed_run call below is
    # ever reached.
    #
    # base_sha has a confirmed push run every time it's asked (per the stub
    # above) -- the pre-check sees it, and (since the normal-path wait then
    # fails, per the empty revision stub) the post-check re-derives it too.
    run saf_resolve_untouched_backfill_source "wiki-mod/lancache-ng" "proxy" "nonexistent-service" "$base_sha" 0 0 0 0 0 0 0 50 "$git_dir"
    [ "$status" -ne 0 ]
    # Exactly 2 calls: the pre-check and the post-check, both genuinely
    # executed -- not 1, which would mean the second silently reused the
    # first's cached answer.
    [ "$(cat "$call_count_file")" -eq 2 ]
}

@test "saf_find_built_ancestor: a candidate whose own build is confirmed still active gets a second, extended-budget attempt" {
    # Real race this project has confirmed happens: a candidate commit's own
    # push run has not finished yet by the time the ancestor walk reaches
    # it. The short ceiling below (0s -- a single non-polling attempt) must
    # fail first; only because STAGING_CANDIDATE_RUN_ACTIVE_CMD positively
    # confirms activity does this get a second attempt with the extended
    # (10s) budget, which succeeds once the image resolves at ~3 real
    # seconds -- proving the extension is genuinely happening, not that the
    # short attempt happened to eventually succeed on its own.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    git -C "$git_dir" commit -q --allow-empty -m ancestor
    ancestor_sha="$(git -C "$git_dir" rev-parse HEAD)"
    git -C "$git_dir" commit -q --allow-empty -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    active_stub="$BATS_TEST_TMPDIR/active.sh"
    cat > "$active_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$active_stub"
    export STAGING_CANDIDATE_RUN_ACTIVE_CMD="$active_stub"

    start_epoch="$(date +%s)"
    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
now="\$(date +%s)"
elapsed=\$((now - $start_epoch))
if (( elapsed >= 3 )); then
    echo "$ancestor_sha"
else
    exit 1
fi
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    # freshness (short) = 0/0, extended = 10/10 -- image resolves at ~3s,
    # well past the short budget but comfortably inside the extended one.
    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 10 0 0 1 10 10 "$git_dir"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "$ancestor_sha" ]
}

@test "saf_find_built_ancestor: a candidate confirmed NOT active is never retried with the extended budget" {
    # Mirror of the previous test with one flip: STAGING_CANDIDATE_RUN_ACTIVE_CMD
    # confirms the candidate's build is NOT active. Even though the same
    # time-based revision stub WOULD eventually resolve if the extended
    # budget were used, this must fail fast (well under the 10s extended
    # ceiling) -- proving the extended retry is never attempted for a
    # confirmed-inactive candidate, matching the unchanged JUDGMENT CALL.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    git -C "$git_dir" commit -q --allow-empty -m ancestor
    ancestor_sha="$(git -C "$git_dir" rev-parse HEAD)"
    git -C "$git_dir" commit -q --allow-empty -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    inactive_stub="$BATS_TEST_TMPDIR/inactive.sh"
    cat > "$inactive_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$inactive_stub"
    export STAGING_CANDIDATE_RUN_ACTIVE_CMD="$inactive_stub"

    start_epoch="$(date +%s)"
    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
now="\$(date +%s)"
elapsed=\$((now - $start_epoch))
if (( elapsed >= 3 )); then
    echo "$ancestor_sha"
else
    exit 1
fi
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    start_test_epoch="$(date +%s)"
    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 10 0 0 1 10 10 "$git_dir"
    end_test_epoch="$(date +%s)"
    [ "$status" -ne 0 ]
    # Must fail in well under the 10s extended ceiling -- proves no
    # extended retry was attempted at all.
    [ "$((end_test_epoch - start_test_epoch))" -lt 2 ]
}

@test "saf_find_built_ancestor: an inconclusive activity check does not trigger the extended retry either" {
    # Same shape again, but STAGING_CANDIDATE_RUN_ACTIVE_CMD itself fails
    # (status 2, inconclusive) -- must be treated the same as confirmed-
    # not-active here, not as "maybe active, extend anyway".
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    git -C "$git_dir" commit -q --allow-empty -m ancestor
    ancestor_sha="$(git -C "$git_dir" rev-parse HEAD)"
    git -C "$git_dir" commit -q --allow-empty -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    inconclusive_active_stub="$BATS_TEST_TMPDIR/inconclusive_active.sh"
    cat > "$inconclusive_active_stub" <<'STUB'
#!/usr/bin/env bash
exit 2
STUB
    chmod +x "$inconclusive_active_stub"
    export STAGING_CANDIDATE_RUN_ACTIVE_CMD="$inconclusive_active_stub"

    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    start_test_epoch="$(date +%s)"
    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 10 0 0 1 10 10 "$git_dir"
    end_test_epoch="$(date +%s)"
    [ "$status" -ne 0 ]
    [ "$((end_test_epoch - start_test_epoch))" -lt 2 ]
}

@test "saf_find_built_ancestor: a 0/0 extended budget still performs one real re-check, not zero -- succeeds if the image is fresh by then" {
    # build-push.yml's own "Ensure PR staging tags exist for full-setup
    # services" step passes 0 0 for the extended budget specifically (see
    # that step's own comment for why its 30-minute job cannot afford more).
    # A 0/0 budget is "a single immediate re-check", not "the extended retry
    # is skipped entirely" -- this proves that: sif_wait_for_fresh_base_image
    # always performs its freshness check once
    # BEFORE ever consulting the hard ceiling (hard_deadline == start_time
    # when hard_ceiling_seconds is 0, but the check itself runs first every
    # iteration), so even the tightest possible extended budget still gives
    # a confirmed-active candidate one more real chance to be seen fresh --
    # not nothing. Modeled with a call-count-based stub (not elapsed time,
    # which cannot meaningfully distinguish two back-to-back 0-budget checks
    # from each other): the image resolves as stale on the short check's own
    # single attempt, but fresh from the very next call onward -- exactly
    # "not ready yet, then ready a moment later", the scenario this 0/0
    # extended budget must still be able to catch.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    git -C "$git_dir" commit -q --allow-empty -m ancestor
    ancestor_sha="$(git -C "$git_dir" rev-parse HEAD)"
    git -C "$git_dir" commit -q --allow-empty -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    active_stub="$BATS_TEST_TMPDIR/active.sh"
    cat > "$active_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$active_stub"
    export STAGING_CANDIDATE_RUN_ACTIVE_CMD="$active_stub"

    call_count_file="$BATS_TEST_TMPDIR/revision_call_count"
    echo 0 > "$call_count_file"
    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
count="\$(cat "$call_count_file")"
count=\$((count + 1))
echo "\$count" > "$call_count_file"
# First call ever (the short 0/0 check's own single attempt) reports stale;
# every call after that (the extended 0/0 check's own single attempt, and
# any further calls) reports fresh.
if [ "\$count" -eq 1 ]; then
    exit 1
else
    echo "$ancestor_sha"
fi
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    # short = 0/0 (one attempt, sees "stale"), extended = 0/0 (one more
    # attempt, sees "fresh") -- must still succeed via that second attempt.
    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 10 0 0 1 0 0 "$git_dir"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "$ancestor_sha" ]
    # Exactly 2 real revision checks (short + extended), proving the
    # extended budget genuinely ran its own check rather than the short
    # check's single attempt somehow being counted twice or the extended
    # attempt being skipped outright.
    [ "$(cat "$call_count_file")" -eq 2 ]
}

@test "saf_find_built_ancestor: a run-bearing candidate whose service was untouched by it is walked past instead of stopping (2026-08-02 finding)" {
    # Live-confirmed 2026-08-02 (PR #1355, commit c7d42fe): a candidate can
    # have a genuinely confirmed push-triggered run yet never get its own
    # sha-<commit> tag for one specific service, because Step 4
    # reused that service's content from an even earlier commit instead of
    # rebuilding it. Without the service-scoped check, the JUDGMENT CALL
    # treats "run exists, image never resolves" as a broken build and stops
    # immediately, unable to reach a genuinely usable ancestor sitting right
    # behind a legitimate Step 4 reuse. Fixture: nearest candidate (reused_sha) has a
    # confirmed run but its own proxy image never resolves (revision stub
    # only ever answers for built_sha); built_sha, one step further back,
    # has both a confirmed run and a resolving image.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    mkdir -p "$git_dir/services/proxy" "$git_dir/services/ui"

    echo "proxy built here" > "$git_dir/services/proxy/nginx.conf"
    git -C "$git_dir" add services/proxy/nginx.conf
    git -C "$git_dir" commit -q -m "proxy change"
    built_sha="$(git -C "$git_dir" rev-parse HEAD)"

    echo "ui change" > "$git_dir/services/ui/main.rs"
    git -C "$git_dir" add services/ui/main.rs
    git -C "$git_dir" commit -q -m "ui-only change, proxy reused"
    reused_sha="$(git -C "$git_dir" rev-parse HEAD)"

    git -C "$git_dir" commit -q --allow-empty -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    inactive_stub="$BATS_TEST_TMPDIR/inactive.sh"
    cat > "$inactive_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$inactive_stub"
    export STAGING_CANDIDATE_RUN_ACTIVE_CMD="$inactive_stub"

    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
image="\$1"
suffix="\${image##*:sha-}"
case "\$suffix" in
    "${built_sha}") echo "$built_sha" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 10 0 0 1 0 0 "$git_dir"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "$built_sha" ]
    # Confirms reused_sha was genuinely walked PAST (not silently skipped
    # without a trace, and not the candidate actually substituted).
    [[ "$output" == *"$reused_sha"*"was not touched by it"* ]]
}

@test "saf_find_built_ancestor: a run-bearing candidate whose service WAS touched by it still stops instead of walking past (JUDGMENT CALL preserved)" {
    # Same shape as the test above, but reused_sha's own commit genuinely
    # touches services/proxy/ itself -- the service was NOT untouched, so
    # the original JUDGMENT CALL must still apply: a real, seemingly-broken
    # build for a service-affecting commit stops the walk rather than
    # silently substituting an older ancestor.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    mkdir -p "$git_dir/services/proxy"

    echo "proxy built here" > "$git_dir/services/proxy/nginx.conf"
    git -C "$git_dir" add services/proxy/nginx.conf
    git -C "$git_dir" commit -q -m "proxy change (older)"
    built_sha="$(git -C "$git_dir" rev-parse HEAD)"

    echo "proxy changed again" > "$git_dir/services/proxy/nginx.conf"
    git -C "$git_dir" add services/proxy/nginx.conf
    git -C "$git_dir" commit -q -m "proxy change, seemingly broken build"
    broken_sha="$(git -C "$git_dir" rev-parse HEAD)"

    git -C "$git_dir" commit -q --allow-empty -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    inactive_stub="$BATS_TEST_TMPDIR/inactive.sh"
    cat > "$inactive_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$inactive_stub"
    export STAGING_CANDIDATE_RUN_ACTIVE_CMD="$inactive_stub"

    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
image="\$1"
suffix="\${image##*:sha-}"
case "\$suffix" in
    "${built_sha}") echo "$built_sha" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 10 0 0 1 0 0 "$git_dir"
    [ "$status" -ne 0 ]
    [[ "$output" != *"$built_sha"* ]]
    # The diagnostic must name broken_sha as the candidate that actually
    # blocked the walk (proves the failure is attributed to the right
    # commit, not just "some" failure that happens to also not mention
    # built_sha).
    [[ "$output" == *"$broken_sha"* ]]
}

@test "saf_find_built_ancestor: an untouched candidate is skipped via a single probe, never the full poll budget" {
    # The two tests above already prove the OUTCOME (untouched candidate
    # walked past, touched candidate blocks) using a 0/0 freshness budget for
    # the ancestor-candidate check -- which makes the pre-fix and post-fix
    # code paths behave IDENTICALLY (both do at most one attempt when the
    # budget is already zero), so neither test can distinguish "the pre-check
    # short-circuited before the wait" from "the wait ran and immediately hit
    # its own zero-second ceiling." This test uses a REAL, non-zero freshness
    # budget (5s ceiling, 1s poll interval) specifically to make that
    # distinction observable: the revision stub counts how many times it is
    # invoked for the untouched candidate's own image. Pre-fix, the full poll
    # loop would call it repeatedly until the 5s ceiling elapses (bounded by
    # real wall-clock time via bash's $SECONDS, since this file's own
    # setup() stubs `sleep` as a no-op -- see that comment -- so a poll loop
    # here would spin as fast as possible, not literally sleep, but would
    # still call the stub far more than once before $SECONDS crosses the
    # ceiling). Post-fix, the pre-check confirms "untouched"
    # before ever entering that loop and pays for exactly one non-polling
    # (0/0 budget) probe instead, so the stub must be invoked exactly once
    # for this candidate's own image regardless of the 5s budget passed in.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    mkdir -p "$git_dir/services/proxy" "$git_dir/services/ui"

    echo "proxy built here" > "$git_dir/services/proxy/nginx.conf"
    git -C "$git_dir" add services/proxy/nginx.conf
    git -C "$git_dir" commit -q -m "proxy change"
    built_sha="$(git -C "$git_dir" rev-parse HEAD)"

    echo "ui change" > "$git_dir/services/ui/main.rs"
    git -C "$git_dir" add services/ui/main.rs
    git -C "$git_dir" commit -q -m "ui-only change, proxy untouched"
    untouched_sha="$(git -C "$git_dir" rev-parse HEAD)"

    git -C "$git_dir" commit -q --allow-empty -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
    cat > "$run_exists_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    inactive_stub="$BATS_TEST_TMPDIR/inactive.sh"
    cat > "$inactive_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$inactive_stub"
    export STAGING_CANDIDATE_RUN_ACTIVE_CMD="$inactive_stub"

    # Counts every invocation for the untouched candidate's own image
    # (untouched_sha's tag suffix) into a separate file this test reads
    # back afterward -- a real, observable side effect the assertion below
    # verifies, rather than reasoning about call counts from memory.
    probe_count_file="$BATS_TEST_TMPDIR/untouched_probe_count"
    : > "$probe_count_file"
    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
image="\$1"
suffix="\${image##*:sha-}"
case "\$suffix" in
    "${untouched_sha}")
        echo "x" >> "$probe_count_file"
        exit 1
        ;;
    "${built_sha}") echo "$built_sha" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    # 5s ceiling / 1s poll interval for the ancestor-candidate check --
    # deliberately non-zero, unlike every other test in this file exercising
    # this fixture shape, specifically to make the pre-check-skips-the-wait
    # behavior observable (see this test's own header comment).
    run saf_find_built_ancestor "wiki-mod/lancache-ng" "$base_sha" "proxy" "proxy" 10 5 5 1 0 0 "$git_dir"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "$built_sha" ]

    probe_count="$(wc -l < "$probe_count_file" | tr -d ' ')"
    [ "$probe_count" -eq 1 ]
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
    "${ancestor2_sha}") echo "$ancestor2_sha" ;;
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
    run saf_resolve_untouched_backfill_source "wiki-mod/lancache-ng" "proxy" "proxy" "$base_sha" 3 3 3 3 3 3 1 50 "$git_dir"
    end_epoch="$(date +%s)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sha-${ancestor2_sha}" ]]
    # The fast path (reordering) means this must resolve in well under the
    # 3s ceiling above -- proves the long wait was genuinely skipped, not
    # merely fast because the test stubs are instant.
    [ "$((end_epoch - start_epoch))" -lt 2 ]
}

@test "saf_resolve_sha_image_ref: resolves to the canonical full-SHA tag when it already exists" {
    # What: proves the primary probe (the post-cutover, canonical tag) is
    #   used directly when the registry already has it -- no legacy probe.
    # From: Issue #1095 (G2)
    setup_linear_fixture
    install_revision_stub_for "$base_sha"
    run saf_resolve_sha_image_ref "wiki-mod/lancache-ng" "proxy" "$base_sha" "$git_dir"
    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/wiki-mod/lancache-ng/proxy:sha-${base_sha}" ]
}

@test "saf_resolve_sha_image_ref: falls back to the legacy 7-char tag when only that format exists (transition-window coverage)" {
    # What: proves the maintainer-mandated legacy-tag fallback actually
    #   resolves, for a commit whose only published tag is the pre-cutover
    #   7-char short form -- exactly the ~37k already-published GHCR tags
    #   this transition window must keep working against.
    # Why: without this, the previous advisor-flagged gap (a probe miss on
    #   every already-published legacy tag) would ship silently untested.
    # From: Issue #1095 (G2)
    setup_linear_fixture
    legacy_short="$(git -C "$git_dir" rev-parse --short=7 "$base_sha")"
    revision_stub="$BATS_TEST_TMPDIR/revision_legacy.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
image="\$1"
suffix="\${image##*:sha-}"
if [ "\$suffix" = "$legacy_short" ]; then
    echo "$base_sha"
else
    exit 1
fi
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    run saf_resolve_sha_image_ref "wiki-mod/lancache-ng" "proxy" "$base_sha" "$git_dir"
    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/wiki-mod/lancache-ng/proxy:sha-${legacy_short}" ]
}

@test "saf_resolve_sha_image_ref: defaults to the canonical full-SHA tag when neither format exists yet" {
    # What: proves the not-yet-published case still targets the canonical
    #   full-SHA reference (the format any future build actually produces),
    #   never the legacy form, so a caller's own real freshness poll waits
    #   on the right tag rather than one that can never appear.
    # From: Issue #1095 (G2)
    setup_linear_fixture
    revision_stub="$BATS_TEST_TMPDIR/revision_none.sh"
    cat > "$revision_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    run saf_resolve_sha_image_ref "wiki-mod/lancache-ng" "proxy" "$base_sha" "$git_dir"
    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/wiki-mod/lancache-ng/proxy:sha-${base_sha}" ]
}

@test "saf_resolve_untouched_backfill_source: fast path also fires for a real, non-doc commit that only touches a DIFFERENT service" {
    # 2026-08-02 finding: a commit that touches only ui (a real, non-doc
    # change -- saf_base_commit_paths_are_ignorable would say "not
    # ignorable") must still fast-path when resolving PROXY specifically,
    # since proxy's own build-matrix row was never going to run for this
    # commit regardless. Before saf_base_commit_service_untouched existed,
    # this fell through to the slow path and then hard-failed with "a push
    # run exists, so this is a real build problem" -- the wrong verdict.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    mkdir -p "$git_dir/docs" "$git_dir/services/ui"

    echo "ancestor2" > "$git_dir/docs/ancestor2.md"
    git -C "$git_dir" add docs/ancestor2.md
    git -C "$git_dir" commit -q -m ancestor2
    ancestor2_sha="$(git -C "$git_dir" rev-parse HEAD)"

    echo "ui change" > "$git_dir/services/ui/main.rs"
    git -C "$git_dir" add services/ui/main.rs
    git -C "$git_dir" commit -q -m "ui-only change"
    ui_only_sha="$(git -C "$git_dir" rev-parse HEAD)"

    install_run_exists_stub
    printf '%s\tany\n' "$ancestor2_sha" >> "$runs_file"
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
    "$ui_only_sha") exit 0 ;;
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
    "${ancestor2_sha}") echo "$ancestor2_sha" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    # A push run DOES exist for ui_only_sha (unlike the docs-only fast-path
    # test above) -- proving this route does not depend on "no run at all",
    # only on proxy specifically being untouched.
    start_epoch="$(date +%s)"
    run saf_resolve_untouched_backfill_source "wiki-mod/lancache-ng" "proxy" "proxy" "$ui_only_sha" 3 3 3 3 3 3 1 50 "$git_dir"
    end_epoch="$(date +%s)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sha-${ancestor2_sha}" ]]
    [ "$((end_epoch - start_epoch))" -lt 2 ]
}

@test "saf_resolve_untouched_backfill_source: a later base-branch descendant with unchanged service content rescues a docs-only BASE_SHA even when an older touched candidate is broken" {
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    mkdir -p "$git_dir/docs" "$git_dir/services/proxy" "$git_dir/services/ui"

    echo "root" > "$git_dir/docs/root.md"
    git -C "$git_dir" add docs/root.md
    git -C "$git_dir" commit -q -m root
    echo "proxy change" > "$git_dir/services/proxy/nginx.conf"
    git -C "$git_dir" add services/proxy/nginx.conf
    git -C "$git_dir" commit -q -m "proxy change"
    proxy_change_sha="$(git -C "$git_dir" rev-parse HEAD)"

    echo "base docs" > "$git_dir/docs/base.md"
    git -C "$git_dir" add docs/base.md
    git -C "$git_dir" commit -q -m "base docs"
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"

    echo "ui only" > "$git_dir/services/ui/main.rs"
    git -C "$git_dir" add services/ui/main.rs
    git -C "$git_dir" commit -q -m "ui only"
    descendant_sha="$(git -C "$git_dir" rev-parse HEAD)"
    git -C "$git_dir" update-ref refs/remotes/origin/current_dev "$descendant_sha"

    install_run_exists_stub
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
    "$base_sha") exit 1 ;;
    "$proxy_change_sha") exit 0 ;;
    "$descendant_sha") exit 0 ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$run_exists_stub"

    revision_stub="$BATS_TEST_TMPDIR/revision_descendant.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
image="\$1"
suffix="\${image##*:sha-}"
case "\$suffix" in
    "${descendant_sha}") echo "$descendant_sha" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    run --separate-stderr saf_resolve_untouched_backfill_source "wiki-mod/lancache-ng" "proxy" "proxy" "$base_sha" 0 0 0 0 0 0 0 50 "$git_dir" "current_dev"
    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/wiki-mod/lancache-ng/proxy:sha-${descendant_sha}" ]
    [[ "$stderr" == *"Substituting later base-branch descendant ${descendant_sha}"* ]]
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

    run saf_resolve_untouched_backfill_source "wiki-mod/lancache-ng" "proxy" "proxy" "$real_change_sha" 0 0 0 0 0 0 0 50 "$git_dir"
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

    run saf_resolve_untouched_backfill_source "wiki-mod/lancache-ng" "proxy" "proxy" "$base_sha" 0 0 0 0 0 0 0 50 "$git_dir"
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

    run saf_resolve_untouched_backfill_source "wiki-mod/lancache-ng" "proxy" "proxy" "$base_sha" 300 600 300 600 300 600 15 50 "$git_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sha-${base_sha}" ]]
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
    #
    # Uses real_change_sha (a real services/proxy/ change), not base_sha (a
    # docs-only commit) -- proxy IS confirmed touched by real_change_sha, so
    # saf_base_commit_service_untouched correctly does NOT fast-path here,
    # exercising the long-budget wait this test targets. A docs-only base
    # commit would fast-path immediately regardless of any "in-flight run"
    # stub, since proxy's own build-matrix row structurally never runs for
    # it either way -- that is now saf_base_commit_service_untouched's job to
    # recognize, covered by its own dedicated tests above.
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
    echo "$real_change_sha"
else
    exit 1
fi
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    run saf_resolve_untouched_backfill_source "wiki-mod/lancache-ng" "proxy" "proxy" "$real_change_sha" 10 10 2 2 2 2 1 50 "$git_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sha-${real_change_sha}" ]]
}

@test "saf_resolve_untouched_backfill_source: ancestor_extended_freshness_* is independent of base_freshness_* -- a generous base budget never leaks into the ancestor's extended retry" {
    # Regression guard for the reason these two budgets are kept separate
    # (this file's own header, saf_resolve_untouched_backfill_source comment,
    # documents the full reasoning): if ancestor_extended_freshness_* were
    # ever collapsed back into sharing base_freshness_*'s value, ANY caller
    # passing a generous base_freshness pair (scripts/untracked/ensure-pr-staging-images.sh's
    # real 900/5400) would silently force that same generous extension onto
    # the ancestor candidate's extended retry too, regardless of what
    # ancestor_extended_freshness_* itself said -- exactly the shape of bug
    # that would let build-push.yml's 30-minute full-setup-validate job
    # inherit an up-to-90-minute wait it cannot survive. Proven here from the
    # opposite angle: base commit's own base_freshness is set generously
    # (300/600), but ancestor_extended_freshness is 0/0 -- if the two were
    # ever collapsed back together, the ancestor candidate below would
    # resolve at ~3 real seconds, comfortably inside a 600s ceiling, and this
    # call would succeed. With them genuinely independent, the extended retry
    # gets only one immediate (0s) re-check -- too early to see the image --
    # so this must fail closed, and fast, not after actually waiting anywhere
    # close to 3s.
    setup_linear_fixture
    install_run_exists_stub
    # base_sha: confirmed zero push runs (activates the fast path, since its
    # own paths -- docs/base.md -- are also ignorable). older_sha (its
    # immediate first-parent ancestor): a run is confirmed to exist, so the
    # walk proceeds to older_sha's own freshness check instead of walking
    # past it.
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
    "$base_sha") exit 1 ;;
    "$older_sha") exit 0 ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$run_exists_stub"

    active_stub="$BATS_TEST_TMPDIR/active.sh"
    cat > "$active_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$active_stub"
    export STAGING_CANDIDATE_RUN_ACTIVE_CMD="$active_stub"

    start_epoch="$(date +%s)"
    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
image="\$1"
suffix="\${image##*:sha-}"
now="\$(date +%s)"
elapsed=\$((now - $start_epoch))
if [ "\$suffix" = "${older_sha}" ] && (( elapsed >= 3 )); then
    echo "$older_sha"
else
    exit 1
fi
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    run saf_resolve_untouched_backfill_source "wiki-mod/lancache-ng" "proxy" "proxy" "$base_sha" 300 600 0 0 0 0 1 50 "$git_dir"
    end_epoch="$(date +%s)"
    [ "$status" -ne 0 ]
    # Fails within ~2s, not anywhere near the 3s the image needs to appear --
    # proves this was the 0/0 extended budget giving up immediately, not a
    # coincidental failure after actually waiting most of the way there.
    [ "$((end_epoch - start_epoch))" -lt 2 ]
}

@test "saf_resolve_untouched_backfill_source: curl genuinely missing throughout never gets misread as a confirmed answer -- the ancestor substitution is never taken" {
    # AG-CI-001's actual question for this whole file is not "does it check
    # curl's presence" -- it's "does an inconclusive answer (curl missing,
    # GH_TOKEN unset, a query that fails after retries) ever get silently
    # treated as if it were a genuine, POSITIVE confirmation" -- because that
    # would misfire in the unsafe direction: a base commit that just
    # couldn't be checked would look identical to one that was checked and
    # genuinely confirmed as a deliberate skip, silently unlocking the
    # ancestor substitution (the "fast path"/reuse-an-older-built-commit's
    # image outcome) on no real evidence at all.
    #
    # This is an end-to-end proof, not just a unit test of the low-level
    # query functions' own return codes: curl is genuinely absent from PATH
    # (no fake/stub curl installed at all, and STAGING_BASE_BUILD_RUN_EXISTS_CMD
    # is deliberately left UNSET so the real curl-based
    # saf_base_commit_has_confirmed_run path is actually exercised, not
    # bypassed by a test-only indirection hook), for the entire call --
    # covering both the pre-check (fast-path eligibility) and the post-check
    # (step 3's independent re-derivation) that saf_resolve_untouched_backfill_source
    # itself performs.
    #
    # Traced through every call site this file has for
    # saf_base_commit_has_confirmed_run's own return codes (0 = a run
    # exists, 1 = confirmed zero, 2 = inconclusive):
    #   - saf_resolve_untouched_backfill_source's fast-path pre-check only
    #     sets fast_path_confirmed_zero=true when pre_run_status == 1
    #     (confirmed zero) -- 2 (this test's case) leaves it false, so the
    #     fast path is never entered on an inconclusive answer.
    #   - Its post-wait decision treats post_run_status == 2 exactly the
    #     same as == 0 (a confirmed run exists): both refuse the fallback
    #     and fail closed, per that function's own explicit "(( post_run_status == 2 ))"
    #     branch.
    #   - saf_find_built_ancestor's own per-candidate has_run == 2 branch
    #     fails closed immediately too (see the dedicated "an inconclusive
    #     run-check for a candidate fails closed" test above) -- not
    #     exercised in THIS test since the post-check above already stops
    #     the call before the ancestor walk would ever start, but covered on
    #     its own elsewhere.
    # This test proves the outermost, user-visible consequence of all of
    # that: the call fails, and never prints the "Substituting nearest built
    # ancestor" success message that would mean the fast path fired.
    empty_path_dir="$BATS_TEST_TMPDIR/empty_path"
    mkdir -p "$empty_path_dir"
    old_path="$PATH"

    setup_linear_fixture
    unset STAGING_BASE_BUILD_RUN_EXISTS_CMD

    # Force the normal-path wait against BASE_SHA's own image to fail too
    # (no override resolves base_sha's own suffix), so this genuinely
    # reaches step 3's post-wait decision rather than resolving before curl
    # is ever needed.
    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$revision_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"

    export PATH="$empty_path_dir"
    run saf_resolve_untouched_backfill_source "wiki-mod/lancache-ng" "proxy" "proxy" "$base_sha" 0 0 0 0 0 0 0 50 "$git_dir"
    export PATH="$old_path"

    [ "$status" -ne 0 ]
    [[ "$output" != *"Substituting nearest built ancestor"* ]]
    [[ "$output" == *"could not be positively determined"* ]]
}
