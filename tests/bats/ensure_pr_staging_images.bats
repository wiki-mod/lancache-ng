#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Docker-free coverage for scripts/ensure-pr-staging-images.sh (#715) -- the
# fail-closed staging guard + untouched-service back-fill that reuses the
# #626/#627 pr-<N>-sha-<short> mechanism. The registry probe and the
# imagetools back-fill are stubbed via STAGING_IMAGE_EXISTS_CMD /
# STAGING_BACKFILL_CMD so the touched-vs-untouched decision and the
# fail-closed behaviour are exercised without a real daemon or registry. This
# is the safety property that keeps the deep gate from ever silently
# validating stale content behind a PR-looking tag.
#
# #895 congestion-probe coverage: the tests below stub
# STAGING_BUILD_RUN_STATUS_CMD (build_push_run_active()'s indirection) the
# same way the tests above stub the registry probe, so the extend-past-
# baseline / fail-fast-when-confirmed-dead / hard-ceiling behavior is
# exercised without a real `gh` CLI, network access, or a real build-push
# run. The default setup() below deliberately leaves BUILD_SHA unset, which
# proves the pre-#895 tests still get the original fail-at-baseline
# behavior unchanged (build_push_run_active() short-circuits on an empty
# BUILD_SHA without needing `gh` to be installed at all).
#
# #975 congestion-probe SHA-key coverage: the #895 tests above all stub
# STAGING_BUILD_RUN_STATUS_CMD, which bypasses build_push_run_active()'s real
# `gh api` query entirely -- exactly why the #975 bug (querying by BUILD_SHA,
# the synthetic merge commit, instead of PR_HEAD_SHA, the PR's real branch
# head that the Actions API's `head_sha` field actually means) shipped
# untested. The tests further down instead leave STAGING_BUILD_RUN_STATUS_CMD
# unset and put a fake `gh` executable on PATH, so the real query construction
# is exercised and would fail against the pre-#975 implementation.
#
# #808 base-image freshness coverage: every real backfill now first calls
# scripts/lib/staging-image-freshness.sh's sif_wait_for_fresh_base_image().
# The default setup() below makes that check pass immediately for every
# pre-#808 test (a disposable two-commit git repo, BASE_SHA set to the newer
# commit, and a revision stub that always echoes it back -- "equal" is
# "fresh") so their existing touched/untouched back-fill-count assertions
# stay meaningful without being coupled to the freshness mechanism itself.
# Dedicated staleness/failure coverage for that mechanism lives in
# staging_image_freshness.bats; the tests further down in THIS file only add
# the integration point (a stale base image blocks the back-fill here too).
#
# #1254/#1255 (2026-07-25): the back-fill source itself is no longer the
# mutable nightly/latest channel tag -- it is this PR's own base commit's
# durable per-commit sha-<short> image (base_sha_short, derived from BASE_SHA
# by the script itself). setup() below no longer sets BASE_CHANNEL_TAG (the
# script no longer reads it at all); base_sha_short is computed here purely
# for the tests' own assertions about which tag was backfilled from.
#
# Ancestor-fallback coverage (scripts/lib/staging-ancestor-fallback.sh):
# setup()'s disposable repo now has THREE commits, not two -- ancestor2 (the
# repo's own root commit) -> older -> base -- so the tests further down have
# real ancestor commits 1 and 2 steps back from base_sha to walk through.
# older_sha/base_sha keep the exact same immediate-parent relationship as
# before (older_sha is still base_sha's direct parent), so every pre-existing
# test and assertion above is unaffected by the two added commits.
# saf_base_commit_has_confirmed_run's own indirection hook
# (STAGING_BASE_BUILD_RUN_EXISTS_CMD) defaults to "a run exists" for any sha,
# so every pre-existing test -- most of which never even reach this check,
# since their default freshness stub already succeeds on BASE_SHA itself --
# keeps today's strict fail-closed behavior deterministically and without any
# real `gh`/network dependency, unless a test below explicitly overrides it
# to exercise the new ancestor-fallback path.
#
# `run !` (used below, per SC2314's own recommendation, in place of a bare
# `!` that Bats would otherwise silently fail to treat as a test failure
# unless it happened to be the last statement) requires Bats >= 1.5.0's
# flag-parsing for `run` to actually be enabled -- without this directive,
# `run !` runs a literal `!` command (which doesn't exist) instead of
# inverting the following command's exit status. This project's build-tools
# image pins bats 1.11.1 (confirmed via `bats --version`), well above this
# floor.
bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/ensure-pr-staging-images.sh"
    backfill_log="$BATS_TEST_TMPDIR/backfill.log"
    : > "$backfill_log"

    # Registry-probe stub: an image "exists" iff its ref appears in the
    # newline-separated EXISTING_IMAGES env. Written as a tiny inline script.
    exists_stub="$BATS_TEST_TMPDIR/exists.sh"
    cat > "$exists_stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${EXISTING_IMAGES:-}" | grep -qxF "$1"
STUB
    chmod +x "$exists_stub"

    # Back-fill stub: just records "pr_image<TAB>base_image" so the test can
    # assert which services were back-filled from the base channel.
    backfill_stub="$BATS_TEST_TMPDIR/backfill.sh"
    cat > "$backfill_stub" <<STUB
#!/usr/bin/env bash
printf '%s\t%s\n' "\$1" "\$2" >> "$backfill_log"
STUB
    chmod +x "$backfill_stub"

    # #808: disposable repo (older_sha -> base_sha) + a revision stub that
    # always echoes base_sha back, so sif_is_ancestor_or_equal sees
    # "candidate == base" (fresh) for every test that doesn't override it
    # below. older_sha exists so staleness tests have a real, genuinely
    # older commit to report instead of needing to fabricate one.
    #
    # One MORE commit (ancestor2) added BEFORE older_sha, giving the
    # ancestor-fallback tests further down a real commit 2 steps back from
    # base_sha to walk through. ancestor2_sha is
    # this disposable repo's own root commit (no parent needed -- the first
    # commit in any repo stands on its own), so no separate throwaway "root"
    # commit is needed just to give it one. older_sha/base_sha keep the
    # exact same immediate-parent relationship every pre-existing test above
    # already relies on.
    #
    # Every commit here touches a real docs/*.md file (not --allow-empty):
    # saf_base_commit_paths_are_ignorable() needs a REAL diff to confirm
    # "every changed path matches build-push.yml's own paths-ignore
    # patterns" against -- an empty diff (what --allow-empty produces) is
    # inconclusive, not confirmed-ignorable, which would silently block the
    # ancestor-fallback tests further down from ever reaching their intended
    # scenario. Keeping every commit's own change under docs/ means the
    # default fixture always reads as "a deliberate docs-only skip", which
    # is exactly the shape every ancestor-fallback test below wants BASE_SHA
    # (and its own ancestors) to have unless a test deliberately overrides
    # it (see the dedicated "real (non-doc) path" test further down).
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    mkdir -p "$git_dir/docs"
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
    # #1254/#1255: the back-fill source image is now tagged sha-<this>, not a
    # channel tag -- matches scripts/lib/staging-ancestor-fallback.sh's own
    # internal base_sha_short computation.
    base_sha_short="${base_sha:0:7}"
    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
echo "$base_sha"
STUB
    chmod +x "$revision_stub"

    # saf_base_commit_has_confirmed_run's indirection hook. Defaults to "a
    # run exists" (exit 0) for any sha, so
    # every pre-existing/unrelated test's untouched-service path keeps
    # today's strict fail-closed behavior deterministically -- with no real
    # `gh`/network dependency -- unless a test below explicitly overrides
    # this to exercise the ancestor-fallback path itself.
    base_run_exists_stub="$BATS_TEST_TMPDIR/base_run_exists.sh"
    cat > "$base_run_exists_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$base_run_exists_stub"

    export STAGING_IMAGE_EXISTS_CMD="$exists_stub"
    export STAGING_BACKFILL_CMD="$backfill_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"
    export STAGING_FRESHNESS_GIT_DIR="$git_dir"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$base_run_exists_stub"
    export BASE_SHA="$base_sha"
    # Keep the fail path fast: no real waiting in tests.
    export STAGING_POLL_TIMEOUT_SECONDS=0
    export STAGING_POLL_INTERVAL_SECONDS=0
    export BASE_FRESHNESS_POLL_TIMEOUT_SECONDS=0
    export BASE_FRESHNESS_POLL_HARD_CEILING_SECONDS=0
    export BASE_FRESHNESS_POLL_INTERVAL_SECONDS=0
    # Separate short-budget pair for saf_find_built_ancestor's own
    # per-candidate checks (see scripts/lib/staging-ancestor-fallback.sh's
    # saf_resolve_untouched_backfill_source header for why this is now a
    # second, independent pair rather than sharing the BASE_FRESHNESS_* pair
    # above) -- kept at 0 here for the same "no real waiting in tests" reason.
    export ANCESTOR_FRESHNESS_POLL_TIMEOUT_SECONDS=0
    export ANCESTOR_FRESHNESS_POLL_HARD_CEILING_SECONDS=0
    # Third, independent budget pair for saf_find_built_ancestor's own
    # ONE-TIME extended retry (an ancestor candidate whose run is confirmed
    # still active) -- see this script's own ANCESTOR_EXTENDED_FRESHNESS_POLL_*
    # comment and scripts/lib/staging-ancestor-fallback.sh's
    # saf_resolve_untouched_backfill_source header for why this is no longer
    # the same parameter as BASE_FRESHNESS_POLL_* (the Codex P1 finding this
    # third budget exists to fix). Kept at 0 here for the same
    # "no real waiting in tests" reason as the other two pairs.
    export ANCESTOR_EXTENDED_FRESHNESS_POLL_TIMEOUT_SECONDS=0
    export ANCESTOR_EXTENDED_FRESHNESS_POLL_HARD_CEILING_SECONDS=0
    export REPOSITORY="wiki-mod/lancache-ng"
    export PR_TAG="pr-715-sha-abcdef0"
}

@test "untouched services are all back-filled from the PR base commit's own per-commit image" {
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export DHCP_TOUCHED="false" DHCP_PROXY_TOUCHED="false" NTP_TOUCHED="false"
    run bash "$script"
    [ "$status" -eq 0 ]
    # All eight full-setup services get a base-commit back-fill (#1296: dhcp/
    # dhcp-proxy joined the five original services first, ntp completes the
    # 3-of-3 this issue asked for).
    [ "$(wc -l < "$backfill_log")" -eq 8 ]
    grep -qF "ghcr.io/wiki-mod/lancache-ng/proxy:pr-715-sha-abcdef0	ghcr.io/wiki-mod/lancache-ng/proxy:sha-${base_sha_short}" "$backfill_log"
}

@test "a touched service already present passes without a back-fill" {
    export EXISTING_IMAGES="ghcr.io/wiki-mod/lancache-ng/proxy:pr-715-sha-abcdef0"
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export DHCP_TOUCHED="false" DHCP_PROXY_TOUCHED="false" NTP_TOUCHED="false"
    run bash "$script"
    [ "$status" -eq 0 ]
    # proxy was touched+present (no back-fill); the other seven are
    # back-filled. Leading slash disambiguates from
    # ".../dhcp-proxy:pr-715-sha-abcdef0", which is one of those seven and
    # would otherwise substring-match "proxy:...".
    [ "$(wc -l < "$backfill_log")" -eq 7 ]
    # SC2314: a bare `!` never triggers Bats' own failure detection unless it
    # happens to be the test's last statement (the `!`-exemption from
    # `errexit` means a failing negation earlier in the body would silently
    # fall through instead of failing the test) -- `run !` (Bats >= 1.5.0,
    # this project pins 1.11.1) is position-independent and correct
    # regardless of what gets added after it later. `run !` is a
    # self-contained assertion (it fails the test immediately if the wrapped
    # command unexpectedly succeeds) -- no separate `[ "$status" ... ]`
    # check is needed or correct afterward; $status after a successful
    # `run !` holds the command's own (nonzero) exit code, not an inverted
    # value.
    run ! grep -qF "/proxy:pr-715-sha-abcdef0" "$backfill_log"
}

@test "fail-closed: a touched service whose staging tag never appears aborts" {
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "never appeared"
}

@test "workflow change forces every service but build-tools to be treated as touched" {
    # build-tools present (its narrower scoping keeps it touched only if built);
    # proxy/dns/watchdog/ui are forced-touched by the workflow change but none
    # exist -> must fail closed on the first one.
    export EXISTING_IMAGES="ghcr.io/wiki-mod/lancache-ng/build-tools:pr-715-sha-abcdef0"
    export WORKFLOW_CHANGED="true"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "never appeared"
}

@test "workflow change: build-tools untouched is still back-filled, not required" {
    # Every forced-touched service present (#1296: dhcp/dhcp-proxy joined
    # first, ntp completes the set); build-tools untouched -> back-fill.
    # Declared and exported separately (SC2155): combining them would mask a
    # real failure exit status from the command substitution behind the
    # export builtin's own (always-successful-here) return value.
    EXISTING_IMAGES="$(printf '%s\n' \
        ghcr.io/wiki-mod/lancache-ng/proxy:pr-715-sha-abcdef0 \
        ghcr.io/wiki-mod/lancache-ng/dns:pr-715-sha-abcdef0 \
        ghcr.io/wiki-mod/lancache-ng/watchdog:pr-715-sha-abcdef0 \
        ghcr.io/wiki-mod/lancache-ng/ui:pr-715-sha-abcdef0 \
        ghcr.io/wiki-mod/lancache-ng/dhcp:pr-715-sha-abcdef0 \
        ghcr.io/wiki-mod/lancache-ng/dhcp-proxy:pr-715-sha-abcdef0 \
        ghcr.io/wiki-mod/lancache-ng/ntp:pr-715-sha-abcdef0)"
    export EXISTING_IMAGES
    export WORKFLOW_CHANGED="true"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export DHCP_TOUCHED="false" DHCP_PROXY_TOUCHED="false" NTP_TOUCHED="false"
    run bash "$script"
    [ "$status" -eq 0 ]
    # Only build-tools is back-filled.
    [ "$(wc -l < "$backfill_log")" -eq 1 ]
    grep -qF "build-tools:pr-715-sha-abcdef0" "$backfill_log"
}

@test "#895: past the normal budget, a still-active build-push run extends the wait until the tag appears" {
    # A counter-backed exists stub: the tag is "missing" for the first two
    # probes, then "appears" -- simulating a slow-but-healthy build finishing
    # while the congestion probe reports build-push's run as still active.
    # Proves the extension is real (the script keeps polling instead of
    # failing at the normal budget), not just a no-op past baseline.
    counter_file="$BATS_TEST_TMPDIR/exists_calls"
    : > "$counter_file"
    exists_slow_stub="$BATS_TEST_TMPDIR/exists_slow.sh"
    cat > "$exists_slow_stub" <<STUB
#!/usr/bin/env bash
calls=\$(wc -l < "$counter_file")
printf 'x\n' >> "$counter_file"
[ "\$calls" -ge 2 ]
STUB
    chmod +x "$exists_slow_stub"

    active_stub="$BATS_TEST_TMPDIR/active.sh"
    cat > "$active_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$active_stub"

    export STAGING_IMAGE_EXISTS_CMD="$exists_slow_stub"
    export STAGING_BUILD_RUN_STATUS_CMD="$active_stub"
    export BUILD_SHA="deadbeef0123"
    export STAGING_POLL_TIMEOUT_SECONDS=0
    export STAGING_POLL_HARD_CEILING_SECONDS=5
    export STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS=0
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q "extending the wait"
    printf '%s\n' "$output" | grep -q "staging image is present"
}

@test "#895: a confirmed-finished build-push run fails immediately instead of waiting for the hard ceiling" {
    # The hard ceiling is set generously large (100s); a passing test that
    # completes quickly proves the script did NOT idle out that ceiling once
    # the congestion probe confirmed build-push's run already finished.
    inactive_stub="$BATS_TEST_TMPDIR/inactive.sh"
    cat > "$inactive_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$inactive_stub"

    export STAGING_BUILD_RUN_STATUS_CMD="$inactive_stub"
    export BUILD_SHA="deadbeef0123"
    export STAGING_POLL_TIMEOUT_SECONDS=0
    export STAGING_POLL_HARD_CEILING_SECONDS=100
    export STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS=0
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"

    start_epoch="$(date +%s)"
    run bash "$script"
    end_epoch="$(date +%s)"

    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "already finished"
    printf '%s\n' "$output" | grep -q "never appeared"
    # Must not have waited anywhere near the 100s hard ceiling.
    [ "$((end_epoch - start_epoch))" -lt 10 ]
}

@test "#895: the hard ceiling still fails closed even while the congestion probe keeps reporting an active run" {
    # Proves the extension is bounded: even a build-push run that never stops
    # reporting "active" must not be allowed to wait forever.
    active_stub="$BATS_TEST_TMPDIR/active.sh"
    cat > "$active_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$active_stub"

    export STAGING_BUILD_RUN_STATUS_CMD="$active_stub"
    export BUILD_SHA="deadbeef0123"
    export STAGING_POLL_TIMEOUT_SECONDS=0
    export STAGING_POLL_HARD_CEILING_SECONDS=1
    export STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS=0
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "hard 1s ceiling"
}

# Fake `gh` used by the #975 tests below: emulates `gh api <url> --jq <expr>`
# by logging the requested URL (so a test can assert exactly which SHA was
# queried) and rendering a per-head_sha JSON fixture through the real `jq`
# binary, the same way the real `gh api --jq` flag renders its response.
# Returns an empty workflow_runs list for any head_sha with no fixture file,
# mirroring what the real API returns for a SHA it has never seen.
install_fake_gh() {
    fake_bin_dir="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$fake_bin_dir"
    fake_gh_call_log="$BATS_TEST_TMPDIR/gh_calls.log"
    : > "$fake_gh_call_log"
    fake_gh_runs_dir="$BATS_TEST_TMPDIR/gh_runs_fixtures"
    mkdir -p "$fake_gh_runs_dir"
    cat > "$fake_bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "api" ]]; then
    exit 1
fi
url="$2"
shift 2
jq_expr=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --jq) jq_expr="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\n' "$url" >> "$GH_FAKE_CALL_LOG"
head_sha="${url#*head_sha=}"
head_sha="${head_sha%%&*}"
fixture="$GH_FAKE_RUNS_DIR/$head_sha.json"
if [[ -f "$fixture" ]]; then
    jq -r "$jq_expr" "$fixture"
else
    printf '{"workflow_runs":[]}' | jq -r "$jq_expr"
fi
STUB
    chmod +x "$fake_bin_dir/gh"
    export PATH="$fake_bin_dir:$PATH"
    export GH_FAKE_CALL_LOG="$fake_gh_call_log"
    export GH_FAKE_RUNS_DIR="$fake_gh_runs_dir"
}

@test "#975: the congestion probe queries build-push runs by the PR's real head SHA, checking every returned run" {
    install_fake_gh
    real_head_sha="realhead1234567890"
    merge_sha="mergecommit0987654321"

    # The NEWEST run (workflow_runs[0], as the real API returns it) is already
    # completed, but an OLDER run for the same head_sha is still in_progress.
    # A query keyed on the wrong SHA (the pre-#975 bug) would never find this
    # fixture at all; a fix that only inspected workflow_runs[0] would still
    # wrongly report "not active" and fail this test.
    cat > "$fake_gh_runs_dir/$real_head_sha.json" <<JSON
{"workflow_runs":[{"status":"completed"},{"status":"in_progress"}]}
JSON

    counter_file="$BATS_TEST_TMPDIR/exists_calls"
    : > "$counter_file"
    exists_slow_stub="$BATS_TEST_TMPDIR/exists_slow.sh"
    cat > "$exists_slow_stub" <<STUB
#!/usr/bin/env bash
calls=\$(wc -l < "$counter_file")
printf 'x\n' >> "$counter_file"
[ "\$calls" -ge 2 ]
STUB
    chmod +x "$exists_slow_stub"

    unset STAGING_BUILD_RUN_STATUS_CMD
    export STAGING_IMAGE_EXISTS_CMD="$exists_slow_stub"
    export BUILD_SHA="$merge_sha"
    export PR_HEAD_SHA="$real_head_sha"
    export STAGING_POLL_TIMEOUT_SECONDS=0
    export STAGING_POLL_HARD_CEILING_SECONDS=5
    export STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS=0
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q "extending the wait"
    printf '%s\n' "$output" | grep -q "staging image is present"
    # The query used PR_HEAD_SHA, never the merge-commit BUILD_SHA.
    grep -qF "head_sha=$real_head_sha" "$fake_gh_call_log"
    # SC2314: see the "touched service already present" test's comment above
    # (`run !` is a self-contained assertion; no follow-up status check).
    run ! grep -qF "head_sha=$merge_sha" "$fake_gh_call_log"
}

@test "#975: a head_sha with only completed runs is correctly reported as not active" {
    install_fake_gh
    real_head_sha="realhead1234567890"
    cat > "$fake_gh_runs_dir/$real_head_sha.json" <<JSON
{"workflow_runs":[{"status":"completed"},{"status":"completed"}]}
JSON

    unset STAGING_BUILD_RUN_STATUS_CMD
    export BUILD_SHA="mergecommit0987654321"
    export PR_HEAD_SHA="$real_head_sha"
    export STAGING_POLL_TIMEOUT_SECONDS=0
    export STAGING_POLL_HARD_CEILING_SECONDS=100
    export STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS=0
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"

    start_epoch="$(date +%s)"
    run bash "$script"
    end_epoch="$(date +%s)"

    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "already finished"
    printf '%s\n' "$output" | grep -q "never appeared"
    [ "$((end_epoch - start_epoch))" -lt 10 ]
}

@test "#808: an untouched service is NOT back-filled from a base-channel image that is stale relative to BASE_SHA" {
    # Overrides setup()'s default "always fresh" revision stub with one that
    # always reports older_sha -- a real commit that predates BASE_SHA
    # (base_sha) in the disposable repo's own history. Proves the freshness
    # gate actually blocks the back-fill end-to-end, not just in isolation.
    stale_stub="$BATS_TEST_TMPDIR/stale_revision.sh"
    cat > "$stale_stub" <<STUB
#!/usr/bin/env bash
echo "$older_sha"
STUB
    chmod +x "$stale_stub"
    export STAGING_IMAGE_REVISION_CMD="$stale_stub"

    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "#808"
    # No service was actually back-filled: the freshness gate blocked all of
    # them before backfill_from_base ever ran (fail-fast on the first one).
    [ "$(wc -l < "$backfill_log")" -eq 0 ]
}

@test "#808: an untouched service IS back-filled once the base-channel image is fresh (equal to BASE_SHA)" {
    # setup()'s default stub already returns BASE_SHA itself (equal ->
    # fresh) -- this test just asserts the previously-existing behavior
    # (back-fill happens) still holds now that the freshness gate sits in
    # front of it, i.e. the gate does not accidentally block the good case.
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export DHCP_TOUCHED="false" DHCP_PROXY_TOUCHED="false" NTP_TOUCHED="false"
    run bash "$script"
    [ "$status" -eq 0 ]
    # #1296: eight full-setup services now, not five (dhcp/dhcp-proxy joined
    # first, ntp completes the 3-of-3 this issue asked for).
    [ "$(wc -l < "$backfill_log")" -eq 8 ]
}

@test "#808: BASE_SHA is required -- an omitted BASE_SHA fails closed instead of silently skipping the freshness check" {
    unset BASE_SHA
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "BASE_SHA"
}

# Integration coverage for the ancestor-fallback path
# (scripts/lib/staging-ancestor-fallback.sh), exercised through the full
# script rather than the library's own direct unit tests (see
# tests/bats/staging_ancestor_fallback.bats for those). A docs/governance-
# only BASE_SHA can never get a push-triggered sha-<short> image built,
# because build-push.yml's own push trigger paths-ignore deliberately skips
# it. These tests stub saf_base_commit_has_confirmed_run (via
# STAGING_BASE_BUILD_RUN_EXISTS_CMD) and drive the freshness-revision stub
# per-image (keyed off the image ref's own sha-<short> suffix) so the
# ancestor walk's real logic -- not a mocked shortcut -- is exercised
# end-to-end against setup()'s three-commit disposable repo
# (ancestor2 -> older -> base), each commit touching a real docs/*.md file
# so the paths-are-ignorable gate reads them as a genuine deliberate skip.

@test "#1095 ancestor fallback: BASE_SHA never built, nearest ancestor 2 commits back (with a real run+image) is used" {
    # base_sha and older_sha (1 commit back) both report ZERO push runs;
    # ancestor2_sha (2 commits back) is the first one that DOES -- proves the
    # walk actually skips ahead past a run-less immediate parent instead of
    # trivially picking whatever is nearest.
    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
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
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    # Per-image revision stub: only ancestor2's own per-commit tag resolves
    # to a real, matching revision (itself) -- base_image and older_image
    # both report "no label" (simulating "image doesn't exist"), which is
    # moot for older_image anyway since the run-exists stub above already
    # skips it before any freshness check is attempted.
    revision_map_stub="$BATS_TEST_TMPDIR/revision_map.sh"
    cat > "$revision_map_stub" <<STUB
#!/usr/bin/env bash
image="\$1"
suffix="\${image##*:sha-}"
case "\$suffix" in
    "${ancestor2_sha:0:7}") echo "$ancestor2_sha" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$revision_map_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_map_stub"

    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export DHCP_TOUCHED="false" DHCP_PROXY_TOUCHED="false" NTP_TOUCHED="false"
    run bash "$script"
    [ "$status" -eq 0 ]
    # Captured immediately, before any further `run` calls below overwrite
    # bats' shared $output/$status -- see the SC2314 comment a few lines down.
    script_output="$output"
    # All eight services back-filled, every one from ancestor2's tag, never
    # from base_sha's or older_sha's.
    [ "$(wc -l < "$backfill_log")" -eq 8 ]
    grep -qF "ghcr.io/wiki-mod/lancache-ng/proxy:pr-715-sha-abcdef0	ghcr.io/wiki-mod/lancache-ng/proxy:sha-${ancestor2_sha:0:7}" "$backfill_log"
    # SC2314: a bare `!` never triggers Bats' own failure detection unless it
    # happens to be the test's last statement -- `run !` (Bats >= 1.5.0, this
    # project pins 1.11.1) is position-independent and correct regardless of
    # what's added after it later. `run !` is a self-contained assertion (no
    # follow-up status check needed or correct); `run` overwrites
    # $output/$status as a side effect regardless, which is exactly why
    # script_output was captured above first.
    run ! grep -qF "sha-${base_sha_short}" "$backfill_log"
    run ! grep -qF "sha-${older_sha:0:7}" "$backfill_log"
    printf '%s\n' "$script_output" | grep -q "Substituting nearest built ancestor"
    printf '%s\n' "$script_output" | grep -qF "$ancestor2_sha"
    printf '%s\n' "$script_output" | grep -q "no push-triggered build-push.yml run"
}

@test "#1095 ancestor fallback: bounded search depth stops before reaching a usable ancestor further back" {
    # Same stubs as above (ancestor2, 2 commits back, has a real run+image),
    # but the search depth is clamped to 1 -- only older_sha (1 commit back,
    # confirmed zero runs) gets examined, proving the bound is real and
    # enforced rather than decorative: a genuinely usable ancestor sitting
    # just one step further back must NOT be found once the budget is spent.
    export STAGING_ANCESTOR_SEARCH_DEPTH=1

    run_exists_stub="$BATS_TEST_TMPDIR/run_exists.sh"
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
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    revision_map_stub="$BATS_TEST_TMPDIR/revision_map.sh"
    cat > "$revision_map_stub" <<STUB
#!/usr/bin/env bash
image="\$1"
suffix="\${image##*:sha-}"
case "\$suffix" in
    "${ancestor2_sha:0:7}") echo "$ancestor2_sha" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$revision_map_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_map_stub"

    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export DHCP_TOUCHED="false" DHCP_PROXY_TOUCHED="false" NTP_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "No usable ancestor"
    [ "$(wc -l < "$backfill_log")" -eq 0 ]
    # SC2314: a bare `!` before a simple command never triggers Bats' own
    # failure detection unless it happens to be the test's last statement (a
    # documented Bats/bash-`errexit` interaction). A plain `[[ ... != *...* ]]`
    # substring test avoids the whole class -- it's an ordinary conditional,
    # not a `!`-negated simple command, so it fails the test correctly
    # regardless of position, with no need to route through `run` (which
    # would otherwise overwrite $output/$status as a side effect).
    [[ "$output" != *"Substituting nearest built ancestor"* ]]
}

@test "#1095 ancestor fallback: no ancestor anywhere has a usable run -> fails closed with a distinct error" {
    # Every commit in the disposable repo (base, older, ancestor2 -- the
    # repo's own root commit) reports zero runs -- simulating a long
    # unbroken run of docs-only commits with no real build anywhere in
    # reach. Must fail closed with a clearly distinct message, not silently
    # succeed or loop forever.
    #
    # The SPECIFIC internal reason the walk stops here is
    # saf_find_built_ancestor's own "validate every skipped ancestor" check
    # (see scripts/lib/staging-ancestor-fallback.sh): older_sha (1 commit
    # back) is walked past cleanly (its own docs/older.md-only diff is
    # confirmed ignorable), but ancestor2_sha (2 commits back, this
    # fixture's own root commit) has no parent to diff against at all, so
    # its own paths-ignorable check is INCONCLUSIVE (status 2, not
    # confirmed) rather than positively confirmed -- and an inconclusive
    # result must fail closed here exactly as it does for BASE_SHA itself,
    # not be treated as safe to walk past. This is a genuinely different
    # internal stopping point than "search_depth was exhausted with no
    # candidate anywhere having a run" (covered instead by the dedicated
    # "bounded search depth" test above with search_depth=1, and by
    # tests/bats/staging_ancestor_fallback.bats' own direct unit coverage of
    # both saf_find_built_ancestor's skip-validation and the root-commit
    # inconclusive case) -- both are real, distinct failure paths this test
    # suite covers separately; this test's own assertions below only check
    # the externally-visible fail-closed CONTRACT (a clear error, zero
    # back-fills), which holds either way.
    run_exists_stub="$BATS_TEST_TMPDIR/run_exists_none.sh"
    cat > "$run_exists_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    # Must also force the exact-BASE_SHA freshness check to fail first --
    # otherwise setup()'s default revision stub (always fresh at BASE_SHA)
    # would let the ordinary backfill succeed before this scenario is even
    # reached, the same reason the dedicated "confirmed run" test below needs
    # this override too.
    stale_stub="$BATS_TEST_TMPDIR/stale_revision_no_ancestor.sh"
    cat > "$stale_stub" <<STUB
#!/usr/bin/env bash
echo "$older_sha"
STUB
    chmod +x "$stale_stub"
    export STAGING_IMAGE_REVISION_CMD="$stale_stub"

    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export DHCP_TOUCHED="false" DHCP_PROXY_TOUCHED="false" NTP_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "No usable ancestor"
    # Confirms the specific internal path this comment describes actually
    # fired (not just some other, differently-worded failure).
    printf '%s\n' "$output" | grep -q "changed paths could not be positively confirmed"
    [ "$(wc -l < "$backfill_log")" -eq 0 ]
}

@test "#1095 ancestor fallback: BASE_SHA has a confirmed run -> no fallback, existing strict failure preserved" {
    # A stub that logs its own argument and always reports "a run exists" --
    # proves the check is actually wired to BASE_SHA specifically (not merely
    # ignored, and not accidentally checked against the wrong sha, the exact
    # bug class #975 was), and that a real/broken/in-progress build for the
    # base commit itself must never trigger the ancestor fallback.
    run_exists_log="$BATS_TEST_TMPDIR/run_exists_calls.log"
    : > "$run_exists_log"
    run_exists_stub="$BATS_TEST_TMPDIR/run_exists_logging.sh"
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$run_exists_log"
exit 0
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    # Force the exact-BASE_SHA freshness check to fail first (same
    # older_sha-reports-stale pattern the pre-existing "#808 stale" test
    # already uses), so the script actually reaches the new fallback
    # decision point instead of succeeding earlier.
    stale_stub="$BATS_TEST_TMPDIR/stale_revision_run_exists.sh"
    cat > "$stale_stub" <<STUB
#!/usr/bin/env bash
echo "$older_sha"
STUB
    chmod +x "$stale_stub"
    export STAGING_IMAGE_REVISION_CMD="$stale_stub"

    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export DHCP_TOUCHED="false" DHCP_PROXY_TOUCHED="false" NTP_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$backfill_log")" -eq 0 ]
    # SC2314: see the "bounded search depth" test's comment above for why a
    # plain `[[ ... != *...* ]]` substring test is used instead of a bare `!`.
    [[ "$output" != *"Substituting nearest built ancestor"* ]]
    printf '%s\n' "$output" | grep -q "a push-triggered build-push.yml run does exist for"
    # The check was actually invoked with BASE_SHA itself, not ignored or
    # called against the wrong value.
    grep -qxF "$base_sha" "$run_exists_log"
}

@test "#1095 ancestor fallback: BASE_SHA run-check is indeterminate (e.g. gh unavailable) -> fails closed same as a confirmed run" {
    # Proving absence is the ONLY condition allowed to unlock the fallback --
    # an inconclusive check (gh missing, API error) must fail exactly like a
    # confirmed run, never be treated as "confirmed zero".
    indeterminate_stub="$BATS_TEST_TMPDIR/indeterminate.sh"
    cat > "$indeterminate_stub" <<'STUB'
#!/usr/bin/env bash
exit 2
STUB
    chmod +x "$indeterminate_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$indeterminate_stub"

    stale_stub="$BATS_TEST_TMPDIR/stale_revision_indeterminate.sh"
    cat > "$stale_stub" <<STUB
#!/usr/bin/env bash
echo "$older_sha"
STUB
    chmod +x "$stale_stub"
    export STAGING_IMAGE_REVISION_CMD="$stale_stub"

    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export DHCP_TOUCHED="false" DHCP_PROXY_TOUCHED="false" NTP_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$backfill_log")" -eq 0 ]
    # SC2314: see the "bounded search depth" test's comment above for why a
    # plain `[[ ... != *...* ]]` substring test is used instead of a bare `!`.
    [[ "$output" != *"Substituting nearest built ancestor"* ]]
    printf '%s\n' "$output" | grep -q "could not be positively determined"
}

@test "#1095 ancestor fallback: BASE_SHA changed a real (non-doc) path -> paths gate blocks the fallback even with zero push runs" {
    # The single most important regression guard for this mechanism: a
    # confirmed-zero-push-runs reading alone is not proof of a deliberate
    # skip -- it only proves GitHub never created a run, not that BASE_SHA's
    # own changed paths actually matched build-push.yml's paths-ignore list.
    # If that trigger were ever temporarily disabled while a real,
    # service-changing commit landed, a bare "zero runs" reading would
    # misidentify that outage as a deliberate skip and back-fill an
    # untouched service from a stale ancestor -- silently validating
    # content that omits the real base change. Adds one more commit on top
    # of setup()'s docs-only chain that touches a real script file, and
    # points BASE_SHA at it instead of the default fixture's base_sha.
    echo "real change" > "$git_dir/scripts_real_change.sh"
    git -C "$git_dir" add scripts_real_change.sh
    git -C "$git_dir" commit -q -m "real change"
    real_change_sha="$(git -C "$git_dir" rev-parse HEAD)"
    export BASE_SHA="$real_change_sha"

    # Confirmed zero push runs for this exact commit -- the same reading a
    # real trigger outage would also produce.
    run_exists_stub="$BATS_TEST_TMPDIR/run_exists_real_change.sh"
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
[ "\$1" = "$real_change_sha" ] && exit 1
exit 0
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    # The exact-BASE_SHA freshness check must also fail first (no stub
    # resolves this commit's own tag), so the script actually reaches the
    # fallback decision instead of succeeding earlier.
    stale_stub="$BATS_TEST_TMPDIR/stale_revision_real_change.sh"
    cat > "$stale_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$stale_stub"
    export STAGING_IMAGE_REVISION_CMD="$stale_stub"

    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export DHCP_TOUCHED="false" DHCP_PROXY_TOUCHED="false" NTP_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$backfill_log")" -eq 0 ]
    [[ "$output" != *"Substituting nearest built ancestor"* ]]
    printf '%s\n' "$output" | grep -q "paths could not be positively confirmed"
}
