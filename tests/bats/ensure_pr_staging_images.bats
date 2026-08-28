#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Docker-free coverage for scripts/untracked/ensure-pr-staging-images.sh (#715) -- the
# fail-closed staging guard + untouched-service back-fill that reuses the
# pr-<N>-sha-<full> mechanism. The registry probe and the
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
# exercised without network access or a real build-push run. The default
# setup() below deliberately leaves BUILD_SHA unset, which proves the
# pre-#895 tests still get the original fail-at-baseline behavior unchanged
# (build_push_run_active() short-circuits on an empty BUILD_SHA before it
# reaches any API call at all).
#
# #975 congestion-probe SHA-key coverage: the #895 tests above all stub
# STAGING_BUILD_RUN_STATUS_CMD, which bypasses build_push_run_active()'s real
# API query entirely -- exactly why the #975 bug (querying by BUILD_SHA, the
# synthetic merge commit, instead of PR_HEAD_SHA, the PR's real branch head
# that the Actions API's `head_sha` field actually means) shipped untested.
# The tests further down instead leave STAGING_BUILD_RUN_STATUS_CMD unset and
# put a fake `curl` on PATH, so the real query construction is exercised and
# would fail against the pre-#975 implementation.
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
# durable per-commit sha-<commit> image, derived from BASE_SHA by
# scripts/lib/staging-ancestor-fallback.sh's own resolver. setup() below no
# longer sets BASE_CHANNEL_TAG (the script no longer reads it at all);
# base_sha_short is computed here purely for the tests' own assertions about
# which tag was backfilled from.
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
# real network dependency, unless a test below explicitly overrides it
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
    script="$repo_root/scripts/untracked/ensure-pr-staging-images.sh"
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
    # channel tag. base_sha_short is a same-value alias kept for every
    # existing assertion below that already reads it (the real resolver's
    # primary probe now targets the full commit SHA, never a locally-derived
    # short form -- see
    # scripts/lib/staging-ancestor-fallback.sh's saf_resolve_sha_image_ref).
    base_sha_short="${base_sha}"
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
    # network dependency -- unless a test below explicitly overrides
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
    export BASE_REF="current_dev"
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
    # saf_resolve_untouched_backfill_source header for why this is its own
    # parameter rather than sharing BASE_FRESHNESS_POLL_*'s value. Kept at 0
    # here for the same "no real waiting in tests" reason as the other two
    # pairs.
    export ANCESTOR_EXTENDED_FRESHNESS_POLL_TIMEOUT_SECONDS=0
    export ANCESTOR_EXTENDED_FRESHNESS_POLL_HARD_CEILING_SECONDS=0
    export REPOSITORY="wiki-mod/lancache-ng"
    export PR_TAG="pr-715-sha-abcdef0"
    git -C "$git_dir" update-ref "refs/remotes/origin/${BASE_REF}" "$base_sha"
}

@test "untouched services are all back-filled from the PR base commit's own per-commit image" {
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export DHCP_TOUCHED="false" DHCP_PROXY_TOUCHED="false" NTP_TOUCHED="false"
    run bash "$script"
    [ "$status" -eq 0 ]
    # All nine full-setup services get a base-commit back-fill (#1296: dhcp/
    # dhcp-proxy joined the five original services first, ntp completed the
    # 3-of-3 that issue asked for; #1428 then added syslog as the ninth).
    [ "$(wc -l < "$backfill_log")" -eq 9 ]
    grep -qF "ghcr.io/wiki-mod/lancache-ng/proxy:pr-715-sha-abcdef0	ghcr.io/wiki-mod/lancache-ng/proxy:sha-${base_sha_short}" "$backfill_log"
}

@test "a touched service already present passes without a back-fill" {
    export EXISTING_IMAGES="ghcr.io/wiki-mod/lancache-ng/proxy:pr-715-sha-abcdef0"
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export DHCP_TOUCHED="false" DHCP_PROXY_TOUCHED="false" NTP_TOUCHED="false"
    run bash "$script"
    [ "$status" -eq 0 ]
    # proxy was touched+present (no back-fill); the other eight are
    # back-filled. Leading slash disambiguates from
    # ".../dhcp-proxy:pr-715-sha-abcdef0", which is one of those eight and
    # would otherwise substring-match "proxy:...".
    [ "$(wc -l < "$backfill_log")" -eq 8 ]
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

# What: Real (non-stubbed) coverage for image_exists()'s _sif_inspect() call
# path, using a fake `docker` executable ahead of the real one on PATH (no
# real registry/daemon), mirroring staging_image_freshness.bats's own
# fake_docker_returning_stderr helper.
# Why: Every other test in this file drives image_exists() through the
# STAGING_IMAGE_EXISTS_CMD stub hook, which never exercises the real
# docker-calling branch, so a regression there would go undetected.
# From: PR #1538, Issue #1449
fake_docker_returning_stderr() {
    local stderr_text="$1"
    local fake_bin_dir="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$fake_bin_dir"
    cat > "$fake_bin_dir/docker" <<STUB
#!/usr/bin/env bash
echo "$stderr_text" >&2
exit 1
STUB
    chmod +x "$fake_bin_dir/docker"
    PATH="$fake_bin_dir:$PATH"
}

@test "image_exists real docker path: a confirmed-absence registry error is reported as confirmed absent" {
    unset STAGING_IMAGE_EXISTS_CMD
    fake_docker_returning_stderr "Error response from daemon: manifest unknown"
    export PATH
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export STAGING_POLL_TIMEOUT_SECONDS=0
    export STAGING_POLL_HARD_CEILING_SECONDS=1
    export STAGING_POLL_INTERVAL_SECONDS=0
    export STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS=0
    active_stub="$BATS_TEST_TMPDIR/active.sh"
    cat > "$active_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$active_stub"
    export STAGING_BUILD_RUN_STATUS_CMD="$active_stub"
    export BUILD_SHA="deadbeef0123"
    run bash "$script"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "confirmed no such manifest"
    # What: asserts the "did NOT positively confirm absence" wording is absent.
    # Why: proves the confirmed-absence branch was actually selected, not merely appended alongside the other wording.
    # From: PR #1538, Issue #1449
    ! printf '%s\n' "$output" | grep -q "did NOT positively confirm absence"
}

# What: exercises wait_for_touched_image()'s fail-fast branch through the real script, not just the classifier tested above.
# Why: proves the confirmed-absence path is taken instead of hard-failing at ~95s for this exact wording.
# From: Issue #1581, PR #1538
@test "image_exists real docker path: buildx's real GHCR \"not found\" wording is reported as confirmed absent, not a hard fail (Issue #1581)" {
    unset STAGING_IMAGE_EXISTS_CMD
    fake_docker_returning_stderr "ERROR: ghcr.io/wiki-mod/lancache-ng/proxy:pr-1532-sha-4c308b3: not found"
    export PATH
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export STAGING_POLL_TIMEOUT_SECONDS=0
    export STAGING_POLL_HARD_CEILING_SECONDS=1
    export STAGING_POLL_INTERVAL_SECONDS=0
    export STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS=0
    active_stub="$BATS_TEST_TMPDIR/active.sh"
    cat > "$active_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$active_stub"
    export STAGING_BUILD_RUN_STATUS_CMD="$active_stub"
    export BUILD_SHA="deadbeef0123"
    run bash "$script"
    [ "$status" -ne 0 ]
    # Confirmed-absence branch reached (poll continued to the hard ceiling,
    # the same outcome the "manifest unknown" test above asserts) --
    # pre-fix, this wording hit the exists_status!=2 fail-fast branch
    # instead and never reached this wording at all.
    printf '%s\n' "$output" | grep -q "confirmed no such manifest"
    ! printf '%s\n' "$output" | grep -q "did NOT positively confirm absence"
}

# What: fake `docker` yields an unrecognized/transient error, not a
# confirmed-absence one, for image_exists()'s other branch.
# Why: exercises the exists_status==1 path (registry call failed,
# not confirmed absent) so both halves of the tri-state contract are covered
# by a real docker-calling test, not just the confirmed-absence half above.
# From: PR #1538, Issue #1449
@test "image_exists real docker path: a transient/unrecognized registry error is reported as NOT confirmed absent" {
    unset STAGING_IMAGE_EXISTS_CMD
    fake_docker_returning_stderr "dial tcp: lookup ghcr.io: connection refused"
    export PATH
    # What: pins ghcr_retry to a single attempt (no 30s backoff sleep)
    # instead of inheriting its production default of 4 attempts.
    # Why: this test's fake `docker` fails identically every attempt, so
    # without this override _sif_inspect's ghcr_retry wrapper would burn its
    # full default retry budget (4 attempts, 30s backoff between each) on
    # every run, adding ~90s to this single test -- the analogous real-docker
    # transient-error test in staging_image_freshness.bats
    # (sif_image_revision, "an unrecognized/transient registry error returns
    # status 1") already pins the same override for the identical reason,
    # here exported (not a plain assignment) because this test drives the
    # script via `run bash "$script"`, a separate subprocess that only
    # inherits exported variables.
    # From: PR #1538, Issue #1449
    export GHCR_RETRY_MAX_ATTEMPTS=1
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export STAGING_POLL_TIMEOUT_SECONDS=0
    export STAGING_POLL_HARD_CEILING_SECONDS=1
    export STAGING_POLL_INTERVAL_SECONDS=0
    export STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS=0
    active_stub="$BATS_TEST_TMPDIR/active.sh"
    cat > "$active_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$active_stub"
    export STAGING_BUILD_RUN_STATUS_CMD="$active_stub"
    export BUILD_SHA="deadbeef0123"
    run bash "$script"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "did NOT positively confirm absence"
    ! printf '%s\n' "$output" | grep -q "confirmed no such manifest"
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
    # first, ntp completed that set; #1428 then added syslog); build-tools
    # untouched -> back-fill.
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
        ghcr.io/wiki-mod/lancache-ng/ntp:pr-715-sha-abcdef0 \
        ghcr.io/wiki-mod/lancache-ng/syslog:pr-715-sha-abcdef0)"
    export EXISTING_IMAGES
    export WORKFLOW_CHANGED="true"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    export DHCP_TOUCHED="false" DHCP_PROXY_TOUCHED="false" NTP_TOUCHED="false" SYSLOG_TOUCHED="false"
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

# Fake `curl` for the #975 congestion-probe tests below. The probe reaches the
# Actions "list workflow runs" endpoint through
# scripts/lib/staging-ancestor-fallback.sh's saf_event_has_incomplete_run(),
# which uses plain `curl` + `GH_TOKEN` and parses the body with `grep`,
# because AG-CI-001/AG-CI-002 mean neither the `gh` CLI nor its bundled `jq`
# can be assumed present on the bare `lancache-light` runner this script
# actually runs on. This stub therefore emulates that exact call shape
# (`-o <body_file> -w '%{http_code}'`, config supplied on stdin via `-K -`):
# it logs the requested URL, so a test can assert precisely which SHA was
# queried, and copies a per-head_sha JSON fixture into the requested body
# file, printing the HTTP status on stdout the way a real
# `-w '%{http_code}'` does. A head_sha with no fixture gets an empty
# workflow_runs list, mirroring what the real API returns for a SHA it has
# never seen.
install_fake_runs_api() {
    fake_bin_dir="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$fake_bin_dir"
    fake_gh_call_log="$BATS_TEST_TMPDIR/gh_calls.log"
    : > "$fake_gh_call_log"
    fake_gh_runs_dir="$BATS_TEST_TMPDIR/gh_runs_fixtures"
    mkdir -p "$fake_gh_runs_dir"
    cat > "$fake_bin_dir/curl" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
# Drain stdin so the caller's `-K -` here-string never blocks on a full pipe.
cat >/dev/null 2>&1 || true
out_file=""
url=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-o" ]]; then
        out_file="$arg"
    fi
    prev="$arg"
    url="$arg"
done
printf '%s\n' "$url" >> "$GH_FAKE_CALL_LOG"
head_sha="${url#*head_sha=}"
head_sha="${head_sha%%&*}"
fixture="$GH_FAKE_RUNS_DIR/$head_sha.json"
if [[ -f "$fixture" ]]; then
    cat "$fixture" > "$out_file"
else
    printf '{"workflow_runs":[]}' > "$out_file"
fi
printf '200'
STUB
    chmod +x "$fake_bin_dir/curl"
    export PATH="$fake_bin_dir:$PATH"
    export GH_FAKE_CALL_LOG="$fake_gh_call_log"
    export GH_FAKE_RUNS_DIR="$fake_gh_runs_dir"
    # saf_event_has_incomplete_run() fails closed with "inconclusive" when no
    # token is set, before it ever reaches curl -- so the probe must have one
    # for these tests to exercise the query itself at all.
    export GH_TOKEN="test-token"
}

@test "#975: the congestion probe queries build-push runs by the PR's real head SHA, checking every returned run" {
    install_fake_runs_api
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
    # What: STAGING_POLL_INTERVAL_SECONDS=0, like sibling tests.
    # Why: the real 15s default outlasts this test's 5s ceiling
    #   below, so the loop always hits the error path.
    # From: Issue #1095
    export STAGING_POLL_INTERVAL_SECONDS=0
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
    install_fake_runs_api
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
    # never resolves anything -- proves the freshness gate blocks the
    # back-fill end-to-end when nothing can be verified, not just in
    # isolation. (A stub that always echoed a real, older-but-genuinely-built
    # ancestor commit would now be legitimately accepted by the
    # ancestor-fallback walk instead of refused -- that IS this mechanism's
    # own intended behavior once saf_base_commit_service_untouched confirms
    # proxy specifically was untouched by base_sha, so this test is scoped to
    # the case where NOTHING resolves, not merely "resolves to something
    # older".)
    stale_stub="$BATS_TEST_TMPDIR/stale_revision.sh"
    cat > "$stale_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$stale_stub"
    export STAGING_IMAGE_REVISION_CMD="$stale_stub"

    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "Refusing to back-fill"
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
    # #1296: eight full-setup services (dhcp/dhcp-proxy joined first, ntp
    # completed the 3-of-3 that issue asked for); #1428 then added syslog as
    # a ninth.
    [ "$(wc -l < "$backfill_log")" -eq 9 ]
}

@test "BASE_SHA's own image with a push-reuse-retagged (older) revision label is accepted directly, no ancestor substitution" {
    # Discriminating test for the two allow_reverse_ancestry=true call sites
    # added inside saf_resolve_untouched_backfill_source() (Step 1's
    # fast path here, since every service is untouched by default per
    # setup()'s docs-only fixture -- Step 2's normal-path call site carries
    # the identical fix and reasoning, see that call site's own comment).
    #
    # Simulates the real push-reuse shape (Step 4): base_sha's own
    # per-commit tag exists, but imagetools create copied the label from the
    # older commit whose content it reused -- so the revision label reads
    # older_sha, a genuine strict ancestor of base_sha, not base_sha itself.
    # Only base_sha's own tag resolves to anything at all; every other tag
    # (including any ancestor candidate's) reports "no image" -- this makes
    # the pass/fail outcome unambiguous: if allow_reverse_ancestry is not
    # honored here, the freshness check rejects older_sha as stale, falls
    # through to saf_find_built_ancestor, and that walk finds nothing usable
    # either (every ancestor's own tag is also stubbed absent) -- a hard
    # failure, not a quieter wrong-answer. Verified this test fails against
    # the earlier baseline for exactly that reason (status non-zero, "No
    # usable ancestor" error) before writing this comment.
    revision_map_stub="$BATS_TEST_TMPDIR/revision_map.sh"
    cat > "$revision_map_stub" <<STUB
#!/usr/bin/env bash
image="\$1"
suffix="\${image##*:sha-}"
case "\$suffix" in
    "$base_sha_short") echo "$older_sha" ;;
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
    # Captured immediately, before the `run !` call below overwrites bats'
    # shared $output/$status (see the SC2314 comment used by the analogous
    # ancestor-fallback test above for why).
    script_output="$output"
    # Every service back-filled straight from base_sha's own tag -- never
    # substituted for an ancestor's, and never refused as stale.
    [ "$(wc -l < "$backfill_log")" -eq 9 ]
    grep -qF "ghcr.io/wiki-mod/lancache-ng/proxy:pr-715-sha-abcdef0	ghcr.io/wiki-mod/lancache-ng/proxy:sha-${base_sha_short}" "$backfill_log"
    run ! grep -qF "sha-${older_sha}" "$backfill_log"
    [[ "$script_output" != *"Substituting nearest built ancestor"* ]]
    [[ "$script_output" != *"No usable ancestor"* ]]
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

@test "retag-reuse: an ancestor CANDIDATE's per-commit image whose revision label predates the candidate itself is accepted (Schritt 4 signature)" {
    # Simulates build-push.yml's own Schritt 4 retag-unchanged-image path
    # landing on an ANCESTOR CANDIDATE (not BASE_SHA itself -- that call site
    # deliberately stays strict, see the dedicated #808 stale test above):
    # BASE_SHA itself is a docs-only skip (zero runs), older_sha (1 commit
    # back) has a confirmed run, but older_sha's own per-commit tag
    # (sha-<older_sha short>) reports a revision label of ancestor2_sha (an
    # even earlier commit) because that image's content was retagged forward
    # rather than rebuilt when older_sha itself was pushed. Before
    # allow_reverse_ancestry, this was indistinguishable from a broken/
    # mislabeled image and the ancestor walk would fail closed instead of
    # substituting older_sha; it must now succeed.
    run_exists_stub="$BATS_TEST_TMPDIR/run_exists_retag.sh"
    cat > "$run_exists_stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
    "$base_sha") exit 1 ;;
    "$older_sha") exit 0 ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$run_exists_stub"
    export STAGING_BASE_BUILD_RUN_EXISTS_CMD="$run_exists_stub"

    revision_map_stub="$BATS_TEST_TMPDIR/revision_map_retag.sh"
    cat > "$revision_map_stub" <<STUB
#!/usr/bin/env bash
image="\$1"
suffix="\${image##*:sha-}"
case "\$suffix" in
    "${older_sha}") echo "$ancestor2_sha" ;;
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
    script_output="$output"
    [ "$(wc -l < "$backfill_log")" -eq 9 ]
    grep -qF "ghcr.io/wiki-mod/lancache-ng/proxy:pr-715-sha-abcdef0	ghcr.io/wiki-mod/lancache-ng/proxy:sha-${older_sha}" "$backfill_log"
    printf '%s\n' "$script_output" | grep -q "PREDATES base commit"
    printf '%s\n' "$script_output" | grep -q "Schritt 4 retag-unchanged-image path"
}

# Integration coverage for the ancestor-fallback path
# (scripts/lib/staging-ancestor-fallback.sh), exercised through the full
# script rather than the library's own direct unit tests (see
# tests/bats/staging_ancestor_fallback.bats for those). A docs/governance-
# only BASE_SHA can never get a push-triggered sha-<commit> image built,
# because build-push.yml's own push trigger paths-ignore deliberately skips
# it. These tests stub saf_base_commit_has_confirmed_run (via
# STAGING_BASE_BUILD_RUN_EXISTS_CMD) and drive the freshness-revision stub
# per-image (keyed off the image ref's own sha-<commit> suffix) so the
# ancestor walk's real logic -- not a mocked shortcut -- is exercised
# end-to-end against setup()'s three-commit disposable repo
# (ancestor2 -> older -> base), each commit touching a real docs/*.md file
# so the paths-are-ignorable gate reads them as a genuine deliberate skip.

@test "ancestor fallback: BASE_SHA never built, nearest ancestor 2 commits back (with a real run+image) is used" {
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
    "${ancestor2_sha}") echo "$ancestor2_sha" ;;
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
    # All nine services back-filled, every one from ancestor2's tag, never
    # from base_sha's or older_sha's.
    [ "$(wc -l < "$backfill_log")" -eq 9 ]
    grep -qF "ghcr.io/wiki-mod/lancache-ng/proxy:pr-715-sha-abcdef0	ghcr.io/wiki-mod/lancache-ng/proxy:sha-${ancestor2_sha}" "$backfill_log"
    # SC2314: a bare `!` never triggers Bats' own failure detection unless it
    # happens to be the test's last statement -- `run !` (Bats >= 1.5.0, this
    # project pins 1.11.1) is position-independent and correct regardless of
    # what's added after it later. `run !` is a self-contained assertion (no
    # follow-up status check needed or correct); `run` overwrites
    # $output/$status as a side effect regardless, which is exactly why
    # script_output was captured above first.
    run ! grep -qF "sha-${base_sha_short}" "$backfill_log"
    run ! grep -qF "sha-${older_sha}" "$backfill_log"
    printf '%s\n' "$script_output" | grep -q "Substituting nearest built ancestor"
    printf '%s\n' "$script_output" | grep -qF "$ancestor2_sha"
    # base_sha is docs-only, so saf_base_commit_service_untouched confirms
    # every service (including proxy) untouched by it directly -- this fires
    # before, and independent of, the commit-wide "no push-triggered run"
    # route, hence the "was not touched by ... itself" wording rather than
    # that route's own message.
    printf '%s\n' "$script_output" | grep -q "was not touched by $base_sha itself"
}

@test "ancestor fallback: bounded search depth stops before reaching a usable ancestor further back" {
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
    "${ancestor2_sha}") echo "$ancestor2_sha" ;;
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

@test "ancestor fallback: no ancestor anywhere has a usable run -> fails closed with a distinct error" {
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
    # this override too. `exit 1` for every image, not "echo an older
    # ancestor's sha": since
    # saf_resolve_untouched_backfill_source's own BASE_SHA-level checks now
    # pass allow_reverse_ancestry=true (the same push-reuse-retag-aware
    # acceptance saf_find_built_ancestor's own candidate checks already used),
    # echoing a genuine ancestor of base_sha here would now be LEGITIMATELY
    # accepted as fresh instead of refused -- see the "#808: ... is NOT
    # back-filled ... stale relative to BASE_SHA" test's own comment a few
    # hundred lines up in this same file for the identical reasoning, written
    # before this fixture needed to catch up to it. This test's own fixture
    # name ("no ancestor anywhere has a usable run") means every image query
    # -- BASE_SHA's own and every ancestor candidate's -- must correctly
    # report "no such image" for the scenario to hold at all, so a single
    # unconditional `exit 1` is not just simpler than the old per-tag `case`,
    # it is the only shape that still means what this test's name says.
    stale_stub="$BATS_TEST_TMPDIR/stale_revision_no_ancestor.sh"
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
    printf '%s\n' "$output" | grep -q "No usable ancestor"
    # Confirms the specific internal path this comment describes actually
    # fired (not just some other, differently-worded failure).
    printf '%s\n' "$output" | grep -q "service-scoped diff nor its changed paths"
    [ "$(wc -l < "$backfill_log")" -eq 0 ]
}

@test "ancestor fallback: BASE_SHA has a confirmed run -> no fallback, existing strict failure preserved" {
    # A real services/proxy/ change (not setup()'s docs-only base_sha):
    # proxy IS confirmed touched by this commit, so
    # saf_base_commit_service_untouched correctly falls through to the
    # commit-wide run-status check this test targets, instead of
    # short-circuiting via the service-scoped route (which a docs-only
    # BASE_SHA would always do here regardless of "a run exists").
    mkdir -p "$git_dir/services/proxy"
    echo "proxy change" > "$git_dir/services/proxy/real-change.conf"
    git -C "$git_dir" add services/proxy/real-change.conf
    git -C "$git_dir" commit -q -m "proxy change"
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"
    export BASE_SHA="$base_sha"

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

    # Force the exact-BASE_SHA freshness check to fail first, so the script
    # actually reaches the new fallback decision point instead of succeeding
    # earlier. `exit 1` (no such image), not "echo an older ancestor's sha"
    # saf_resolve_untouched_backfill_source's own
    # BASE_SHA-level checks now pass allow_reverse_ancestry=true, so echoing
    # a genuine ancestor of base_sha here would now be legitimately accepted
    # as fresh instead of refused -- see the "#808: ... is NOT back-filled
    # ... stale relative to BASE_SHA" test's own comment for the identical
    # reasoning.
    stale_stub="$BATS_TEST_TMPDIR/stale_revision_run_exists.sh"
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
    # SC2314: see the "bounded search depth" test's comment above for why a
    # plain `[[ ... != *...* ]]` substring test is used instead of a bare `!`.
    [[ "$output" != *"Substituting nearest built ancestor"* ]]
    printf '%s\n' "$output" | grep -q "a push-triggered build-push.yml run does exist for"
    # The check was actually invoked with BASE_SHA itself, not ignored or
    # called against the wrong value.
    grep -qxF "$base_sha" "$run_exists_log"
}

@test "ancestor fallback: BASE_SHA run-check is indeterminate (e.g. the API query failed) -> fails closed same as a confirmed run" {
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

    # Force the exact-BASE_SHA freshness check to fail first. `exit 1` (no
    # such image), not "echo an older ancestor's sha":
    # saf_resolve_untouched_backfill_source's own BASE_SHA-level
    # checks now pass allow_reverse_ancestry=true, so echoing a genuine
    # ancestor of base_sha here would now be legitimately accepted as fresh
    # instead of refused -- see the "#808: ... is NOT back-filled ... stale
    # relative to BASE_SHA" test's own comment for the identical reasoning.
    stale_stub="$BATS_TEST_TMPDIR/stale_revision_indeterminate.sh"
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
    # SC2314: see the "bounded search depth" test's comment above for why a
    # plain `[[ ... != *...* ]]` substring test is used instead of a bare `!`.
    [[ "$output" != *"Substituting nearest built ancestor"* ]]
    printf '%s\n' "$output" | grep -q "could not be positively determined"
}

@test "ancestor fallback: BASE_SHA changed a real (non-doc) path -> paths gate blocks the fallback even with zero push runs" {
    # The single most important regression guard for this mechanism: a
    # confirmed-zero-push-runs reading alone is not proof of a deliberate
    # skip -- it only proves GitHub never created a run, not that BASE_SHA's
    # own changed paths actually matched build-push.yml's paths-ignore list.
    # If that trigger were ever temporarily disabled while a real,
    # service-changing commit landed, a bare "zero runs" reading would
    # misidentify that outage as a deliberate skip and back-fill an
    # untouched service from a stale ancestor -- silently validating
    # content that omits the real base change. Adds one more commit on top
    # of setup()'s docs-only chain that touches a real proxy-affecting path
    # (not a generic top-level script -- classify-image-impact.sh would
    # class that as untouched-by-proxy, which would let
    # saf_base_commit_service_untouched short-circuit past the very paths
    # gate this test targets), and points BASE_SHA at it instead of the
    # default fixture's base_sha.
    mkdir -p "$git_dir/services/proxy"
    echo "real change" > "$git_dir/services/proxy/real-change.conf"
    git -C "$git_dir" add services/proxy/real-change.conf
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

# scripts/lib/staging-poll-defaults.sh coverage: sourced directly (not via a
# full run of $script) so these two cases run instantly instead of actually
# waiting out a real 3600s poll to observe the workflow_changed=true default.
@test "staging poll defaults: normal (workflow_changed=false) case is unchanged" {
    # shellcheck source=scripts/lib/staging-poll-defaults.sh
    source "$repo_root/scripts/lib/staging-poll-defaults.sh"
    staging_poll_set_defaults_for_workflow_changed "false"
    [ "$default_poll_timeout_seconds" -eq 1500 ]
    [ "$default_poll_hard_ceiling_seconds" -eq 1200 ]
}

@test "staging poll defaults: workflow_changed=true widens the full-rebuild budget to 3600s" {
    # shellcheck source=scripts/lib/staging-poll-defaults.sh
    source "$repo_root/scripts/lib/staging-poll-defaults.sh"
    staging_poll_set_defaults_for_workflow_changed "true"
    [ "$default_poll_timeout_seconds" -eq 3600 ]
    [ "$default_poll_hard_ceiling_seconds" -eq 3600 ]
}
