#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Makes the PR-scoped staging images the full-setup deep validation suite
# needs actually present before the sims run, on a pull_request event. This
# is where the deep gate REUSES the #626/#627 pr-<N>-sha-<full> mechanism
# rather than inventing its own:
#
#   1. For every full-setup service this PR TOUCHED (or every service but
#      build-tools if a workflow/CI-contract file changed), POLL the registry
#      until build-push.yml's build/build-arm64/merge-manifests have pushed
#      that service's pr-<N>-sha-<full> tag -- this poll IS the cross-
#      workflow wait, since a separate workflow cannot express `needs:` on
#      build-push's jobs. If the tag never appears within the timeout, FAIL
#      CLOSED: a touched service with no staging image means its build failed
#      (or the registry is unreachable), and silently validating stale
#      base-channel content behind a PR-looking tag is exactly #626's bug.
#   2. For every service this PR did NOT touch, (re)point pr-<N>-sha-<full>
#      at this PR's own base commit's durable per-commit sha-<commit> image
#      (#1254/#1255 -- see the #808 note below for why this is no longer a
#      mutable channel tag) via a cheap registry-side `imagetools create`
#      (never a rebuild) -- the correct image to validate an untouched
#      service against, refreshed every run for defense-in-depth. Mirrors
#      build-push.yml's "Ensure PR staging tags exist" step.
#
# Doing our own back-fill (rather than relying on build-push's own validate
# job to have done it) keeps this workflow self-sufficient: it is correct
# even for a services-only PR where build-push's shallow validate job skips.
#
# SOURCE OF TRUTH NOTE: the touched-vs-untouched decision and the fail-closed
# guard mirror build-push.yml's "validate full-setup image" job (untouched
# per #715 clarification). Keep in sync by hand.
#
# #808: step 2's back-fill no longer blindly trusts "whatever the base
# channel resolves to RIGHT NOW" -- a base-channel tag can be moved by
# `promote` well before that push's own build+scan+promote pipeline for a
# NEWER commit finishes, so "resolves right now" previously meant "resolves
# to whatever was there before this run's own PR's base commit was even
# merged" if the timing was unlucky (confirmed live: PRs #911/#914 each
# validated a `dns` image ~41 minutes stale relative to their own base.sha).
# Before backfilling, scripts/lib/staging-image-freshness.sh's
# sif_wait_for_fresh_base_image() now confirms the back-fill source image's
# own org.opencontainers.image.revision label is at or after this PR's
# `base.sha`, polling (bounded) if it isn't yet, and failing closed --
# mirroring step 1's existing fail-closed guard for touched services -- if it
# never catches up. See that file's own header for the full mechanism and the
# documented judgment call on why this wait is shaped differently from
# wait_for_touched_image()'s congestion probe below.
#
# #1254/#1255 (2026-07-25): the back-fill source itself changed from the
# mutable nightly/latest base-channel tag to this PR's own base commit's
# durable per-commit sha-<commit> image. nightly is
# no longer republished on every current_dev push (it is now a once-daily
# scheduled/dispatch-only green-gated channel -- see nightly-refresh.yml), so
# it could otherwise lag an untouched service's back-fill behind this PR's
# real base by up to a day; the base commit's own sha-* tag is always exactly
# the right commit by construction. sif_wait_for_fresh_base_image() is kept
# as-is (not simplified to a bare existence check): it still doubles as the
# bounded poll for the #808 race (the base commit's own push-triggered build
# may not have pushed this tag yet) and still guards against a corrupted or
# mislabeled image reporting the wrong revision -- both real, not redundant.
#
# #895: a fixed poll timeout does not "scale with runner congestion" -- under
# heavy concurrent load on the self-hosted fleet, build-push's own pipeline
# for a single service can legitimately take longer than any single fixed
# budget, so a slow-but-healthy run failed this gate identically to a truly
# broken one (confirmed live incident: PRs #877/#878/#880/#881/#882/#886 all
# timed out within minutes of each other while 23 orphaned validation
# containers sat on the runner fleet; the #877/watchdog tag existed in GHCR,
# it just arrived ~9 minutes after the 1500s poll gave up). Rather than
# blindly raising the fixed number (which only pushes the same failure mode
# further out and would hide a genuinely stuck build behind a much longer
# silent wait), wait_for_touched_image() now asks a concrete question once
# the normal budget is exceeded: is build-push.yml's OWN run for this exact
# commit still active? If yes, that's real evidence of congestion, not a
# stuck build, so the wait extends (up to a hard, still-finite ceiling). If
# that run has already finished without producing the tag, no amount of
# further waiting will help, so this fails immediately instead of idling out
# the rest of the budget. See build_push_run_active() below.
#
# #975: the question above was answered against the WRONG commit from the
# day #895 shipped, which made it always answer "not active" regardless of
# reality. build_push_run_active() queried the GitHub Actions "list workflow
# runs" API with `head_sha=<BUILD_SHA>`, where BUILD_SHA is `github.sha` --
# for a pull_request event that is the synthetic base+head merge commit (see
# full-setup-deep-validate.yml's own BUILD_SHA comment), which IS the correct
# key for the staging TAG itself, but is NOT what the Actions API's
# `head_sha` field/filter means for a pull_request-triggered run: that field
# always reports the PR's real branch head commit, never the merge commit.
# Querying by the merge commit therefore matched zero runs, always, so the
# probe always concluded "not active" -- confirmed live on PRs
# #948/#949/#960/#962: `ensure-pr-staging-images` failed at the ~1500s normal
# budget every time, and in #960's case build-push's real matching run for
# the exact same push (verified via its own checkout log: same merge commit)
# was still `in_progress` and finished successfully 12 minutes later. This
# was real congestion -- precisely the case #895 was written to tolerate --
# not a stuck build; the probe just could never see it. The fix: query by
# PR_HEAD_SHA (github.event.pull_request.head.sha, the PR's real branch head,
# passed in alongside BUILD_SHA) instead, and check every run the query
# returns rather than only the newest one (`workflow_runs[0]`) -- a single
# push can produce more than one build-push run for the same head_sha (e.g.
# `synchronize` and `labeled` firing close together both trigger it;
# confirmed live: PR #960's push produced 5 separate build-push runs for the
# same head commit), and the newest one finishing quickly (or being
# cancelled) must not hide an older one that is still genuinely building.
#
# The exact-BASE_SHA freshness wait a few lines below
# (sif_wait_for_fresh_base_image against $BASE_SHA itself) can be
# STRUCTURALLY unwinnable, not merely slow: build-push.yml's `push` trigger
# has its own `paths-ignore` (**/*.md, docs/**) so a docs/governance-only
# commit landing on master/current_dev never runs the build pipeline at all
# -- deliberately and correctly, per that trigger's own header comment. If
# this PR's base commit happens to be exactly such a commit, its
# sha-<commit> image will never exist via a push-triggered build, for any
# service, no matter how long this waits: the hard ceiling below was always
# going to fire, with no possible resolution short of a maintainer manually
# re-pointing a registry tag by hand.
#
# scripts/lib/staging-ancestor-fallback.sh's saf_resolve_untouched_backfill_source()
# is the fix: once BASE_SHA's own image is confirmed unavailable, positively
# confirm (via the GitHub Actions API, not an assumption) that build-push.yml
# never ran a push-triggered build for BASE_SHA at all -- not "failed", not
# "still running", genuinely zero runs -- AND that every path BASE_SHA
# changed matches build-push.yml's own paths-ignore list, before considering
# a fallback. Either check failing (a run exists, either check is
# inconclusive, or a real non-doc path was found) preserves the existing
# strict failure exactly as before; no ancestor fallback is attempted. Only
# when both are positively confirmed does this walk BASE_SHA's own ancestor
# history (bounded depth, first-parent only) for the nearest commit that
# both has a recorded build and a freshness-confirmed per-commit image
# (reusing sif_wait_for_fresh_base_image, never skipping that check), and
# substitutes THAT ancestor's per-commit tag for the back-fill -- never the
# mutable nightly/latest channel (the #626 anti-pattern this whole file
# exists to avoid). See scripts/lib/staging-ancestor-fallback.sh's own header
# for the full mechanism, shared identically by build-push.yml's own
# "Ensure PR staging tags exist for full-setup services" step.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/validation-image-tag.sh
source "$script_dir/../lib/validation-image-tag.sh"
# shellcheck source=scripts/lib/ghcr-retry.sh
source "$script_dir/../lib/ghcr-retry.sh"
# shellcheck source=scripts/lib/staging-image-freshness.sh
source "$script_dir/../lib/staging-image-freshness.sh"
# shellcheck source=scripts/lib/staging-ancestor-fallback.sh
source "$script_dir/../lib/staging-ancestor-fallback.sh"
# shellcheck source=scripts/lib/staging-poll-defaults.sh
source "$script_dir/../lib/staging-poll-defaults.sh"

: "${REPOSITORY:?REPOSITORY is required}"
: "${PR_TAG:?PR_TAG (pr-<N>-sha-<full>) is required}"
# #808: the PR's own base commit (github.event.pull_request.base.sha) --
# required unconditionally (unlike BUILD_SHA below, which only feeds a
# best-effort probe): every real caller of this script only ever runs on a
# pull_request event (see full-setup-deep-validate.yml's `ensure-pr-staging-
# images` job `if:`), where this is always present, and the freshness check
# below has no meaningful fallback if it's missing -- backfilling an
# untouched service without it would silently regress to the pre-#808 bug.
# #1254/#1255: also the sole source for the back-fill image's own tag now --
# no separate BASE_CHANNEL_TAG input is read anymore. The 7-hex-char short
# form (matching docker/metadata-action's `type=sha,prefix=sha-,format=short`
# convention every service's real sha-* tag uses) is computed directly inside
# scripts/lib/staging-ancestor-fallback.sh's saf_resolve_untouched_backfill_source(),
# not duplicated here.
: "${BASE_SHA:?BASE_SHA (github.event.pull_request.base.sha) is required}"

workflow_changed="${WORKFLOW_CHANGED:-false}"
# The commit build-push.yml built and tagged for this PR (github.sha on a
# pull_request event -- see full-setup-deep-validate.yml's own BUILD_SHA
# comment in the "plan" job for why this must be the synthetic merge commit,
# not the PR head). Only used in the congestion probe's log/error text below
# (the exact commit PR_TAG's suffix is keyed on) -- NOT for the probe's `gh
# api` query itself, see pr_head_sha and #975 below. Intentionally optional,
# not `:?`-required: a caller that omits it (e.g. an older invocation, or a
# test) must still get the pre-#895 fail-at-baseline behavior, not a hard
# error for a var it never needed before.
build_sha="${BUILD_SHA:-}"
# #975: the PR's real head branch commit (github.event.pull_request.head.sha
# -- see full-setup-deep-validate.yml's own PR_HEAD_SHA comment), used for the
# congestion probe's run-status query. Deliberately a separate variable from
# build_sha above: the Actions "list workflow runs" API's `head_sha` filter
# for a pull_request-triggered run is always the PR's real branch head, never
# the synthetic merge commit build_sha holds, so conflating the two (the
# pre-#975 bug) makes the query permanently match zero runs. Same
# intentionally-optional contract as build_sha: an omitted value just falls
# back to the pre-#895 fail-at-baseline behavior via the empty check in
# build_push_run_active() below.
pr_head_sha="${PR_HEAD_SHA:-}"

# Bounded wait for build-push to finish pushing this PR's touched-service
# staging tags. build/build-arm64 run on the scarce lancache-heavy tier, so
# they can legitimately take many minutes; past this budget we start asking
# whether build-push's own run is still active rather than failing outright
# (see #895 note above). Overridable for tests.
staging_poll_set_defaults_for_workflow_changed "$workflow_changed"
poll_timeout_seconds="${STAGING_POLL_TIMEOUT_SECONDS:-$default_poll_timeout_seconds}"
poll_interval_seconds="${STAGING_POLL_INTERVAL_SECONDS:-15}"

# #895: absolute hard ceiling, independent of the congestion probe -- even a
# genuinely hung build-push run must not hold this runner forever. 1200s:
# maintainer-directed cut from 5400s (2026-08-02); the real fix for how often
# this ceiling gets hit is #1378's Step 4 reuse mechanism cutting unnecessary
# rebuilds, not a bigger number here. (The workflow_changed exception above is
# a different, narrower category, not a reversal of that cut.)
poll_hard_ceiling_seconds="${STAGING_POLL_HARD_CEILING_SECONDS:-$default_poll_hard_ceiling_seconds}"
# Clamp up so a misconfigured ceiling below the timeout can't produce a
# negative wait window.
if (( poll_hard_ceiling_seconds < poll_timeout_seconds )); then
    poll_hard_ceiling_seconds=$poll_timeout_seconds
fi

# How often to actually call the congestion probe once past the normal
# budget, so a long extension doesn't hammer the GitHub API once per
# poll_interval_seconds tick.
congestion_check_interval_seconds="${STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS:-60}"

# #808: bounded wait for the back-fill source image itself to become fresh
# enough (see scripts/lib/staging-image-freshness.sh). Governs ONLY BASE_SHA's
# own image wait (step 2), not the shorter ancestor-candidate budget below.
# Can genuinely race a real still-building push run, so gets the same
# congestion headroom as wait_for_touched_image() above -- a short ceiling
# here would hard-fail on a healthy running build, worse than the
# never-built-base problem this mechanism exists to fix. 1200s: maintainer-
# directed cut from 5400s (2026-08-02), matching the ceiling above; 900s is
# just the "start logging" threshold for the common already-fresh case.
base_freshness_timeout_seconds="${BASE_FRESHNESS_POLL_TIMEOUT_SECONDS:-900}"
base_freshness_hard_ceiling_seconds="${BASE_FRESHNESS_POLL_HARD_CEILING_SECONDS:-1200}"
if (( base_freshness_hard_ceiling_seconds < base_freshness_timeout_seconds )); then
    base_freshness_hard_ceiling_seconds=$base_freshness_timeout_seconds
fi
base_freshness_poll_interval_seconds="${BASE_FRESHNESS_POLL_INTERVAL_SECONDS:-15}"

# Deliberately SHORT budget for saf_find_built_ancestor's own per-candidate
# checks (used once BASE_SHA's own wait fails, or via the fast-path
# pre-check). An ancestor candidate already has a confirmed real build
# further back in history -- if its image isn't there yet, it never will be
# (no "still building" case for an older commit). A long ceiling here would
# only slow every fallback case for no benefit, multiplied across
# ancestor_search_depth candidates.
ancestor_freshness_timeout_seconds="${ANCESTOR_FRESHNESS_POLL_TIMEOUT_SECONDS:-300}"
ancestor_freshness_hard_ceiling_seconds="${ANCESTOR_FRESHNESS_POLL_HARD_CEILING_SECONDS:-600}"
if (( ancestor_freshness_hard_ceiling_seconds < ancestor_freshness_timeout_seconds )); then
    ancestor_freshness_hard_ceiling_seconds=$ancestor_freshness_timeout_seconds
fi

# Separate budget for saf_find_built_ancestor's own one-time extended retry,
# given only when a candidate's build-push.yml run is confirmed still active
# after its short check above failed -- own explicit parameter rather than
# reusing base_freshness_*, even though the defaults match. 1200s:
# maintainer-directed cut from 5400s (2026-08-02), same as above.
ancestor_extended_freshness_timeout_seconds="${ANCESTOR_EXTENDED_FRESHNESS_POLL_TIMEOUT_SECONDS:-900}"
ancestor_extended_freshness_hard_ceiling_seconds="${ANCESTOR_EXTENDED_FRESHNESS_POLL_HARD_CEILING_SECONDS:-1200}"
if (( ancestor_extended_freshness_hard_ceiling_seconds < ancestor_extended_freshness_timeout_seconds )); then
    ancestor_extended_freshness_hard_ceiling_seconds=$ancestor_extended_freshness_timeout_seconds
fi

# How many of BASE_SHA's own ancestor commits (nearest-first, first-parent
# only) scripts/lib/staging-ancestor-fallback.sh's saf_find_built_ancestor()
# will examine before giving up. Bounded rather than unbounded on purpose -- a
# long, unbroken run of docs/governance-only commits is realistic in this
# project's actual history (see this repo's own commit log around any
# governance-doc-heavy period), and walking the entire project history
# looking for a built commit would defeat the "fail closed within a
# reasonable time" property every other wait in this file already has. 50 is
# generous headroom over every real docs-commit-run observed in this
# project's history so far (rarely more than 2-3 consecutive doc-only
# commits) without being large enough to make a genuinely pathological case
# (e.g. a long-dead branch) hang the job for an unreasonable number of GitHub
# API calls.
ancestor_search_depth="${STAGING_ANCESTOR_SEARCH_DEPTH:-50}"

# The services deploy/full-setup/docker-compose.yml references, plus
# build-tools (used by the client-simulation steps, not the compose file
# itself), plus dhcp and dhcp-proxy (#1296): neither is part of the
# full-setup COMPOSE PROJECT (deploy/full-setup/docker-compose.yml has
# neither service), but both are pulled directly by
# scripts/untracked/simulations/syslog-forwarding-simulation.sh's Triggers 7/8 (real DHCP lease
# flows over deploy/quickstart/docker-compose.yml, added by #864) -- this
# script's job is "ensure every staging image any deep-validation job in
# this workflow needs," not "ensure exactly what full-setup's own compose
# file needs," so both belong here despite the name. Confirmed live
# (2026-07-30, issue #1296): PRs #1277/#1294/#1301, none of which touched
# dhcp/dhcp-proxy, still failed "Syslog forwarding + Admin UI visibility
# simulation" with `Error manifest unknown` for both images, because this
# list never ensured (or base-channel-backfilled) either tag. dhcp
# additionally still gets its own from-source coverage via the separate
# dhcp-kea-lease-flow-simulation.sh job; that job is unaffected by this
# change.
#
# ntp (#1296, 2026-07-30, completing the 3-of-3 this issue originally asked
# for): now included too. scripts/untracked/simulations/syslog-forwarding-simulation.sh starts it
# (via --profile ntp, the same explicit-profile pattern already used for
# dhcp-kea/dhcp-proxy above) and verifies its real Docker HEALTHCHECK
# (chronyd's chronyc-tracking probe) the same way it verifies every other
# service's healthcheck -- a genuine consumer, not a name added to this list
# with nothing exercising it. ntp's own log-forwarding-to-Admin-UI path is a
# SEPARATE, already-documented, deliberately-deferred gap
# (docs/architecture-ng.md's logging matrix: "ntp | Not yet wired"), so
# unlike every other service in that script's trigger list, ntp is proven via
# real container start + healthcheck, not a marker-in-/logs assertion --
# fabricating that proof would misrepresent a log path that does not exist
# yet. This is the same "add it here too the day one does" reasoning this
# comment previously applied to dhcp/dhcp-proxy, now exercised for ntp
# instead of left as a standing exclusion.
#
# syslog (#1428, 2026-08): joins this list the same way ntp did above, once
# the combined fluent-bit+syslog-ng first-party image (services/syslog/)
# became a real build-matrix service with its own PR staging tag to ensure.
# scripts/untracked/simulations/syslog-forwarding-simulation.sh already pulls/starts/health-waits on
# the single `syslog` Compose service (updated by the same consolidation PR
# this issue follows up on), so this is a real consumer, not a name added
# with nothing exercising it -- see check-workflow-service-lists.sh's
# FULL_SETUP_EXACT_EXCLUSIONS comment for why this array must equal the
# canonical build-matrix set exactly (no exclusions left) rather than a
# subset.
full_setup_services=(proxy dns watchdog ui build-tools dhcp dhcp-proxy ntp syslog)

declare -A touched_map=(
    [proxy]="${PROXY_TOUCHED:-false}"
    [dns]="${DNS_TOUCHED:-false}"
    [watchdog]="${WATCHDOG_TOUCHED:-false}"
    [ui]="${UI_TOUCHED:-false}"
    [build-tools]="${BUILD_TOOLS_TOUCHED:-false}"
    [dhcp]="${DHCP_TOUCHED:-false}"
    [dhcp-proxy]="${DHCP_PROXY_TOUCHED:-false}"
    [ntp]="${NTP_TOUCHED:-false}"
    [syslog]="${SYSLOG_TOUCHED:-false}"
)

# Maps this file's own matrix-service names to scripts/untracked/classify-image-impact.sh's
# output keys, for saf_resolve_untouched_backfill_source's service-scoped
# check below -- the two naming schemes differ for 3 of 9 services (dns vs
# dns_image, dhcp-proxy vs dhcp_proxy, build-tools vs build_tools), same
# mapping build-push.yml's own decide_one() call sites already hand-pass
# per service (see that job's "determine push reuse scope" step). syslog
# needs no renaming: classify-image-impact.sh's own output key is "syslog" too.
declare -A classify_key_map=(
    [proxy]="proxy"
    [dns]="dns_image"
    [watchdog]="watchdog"
    [ui]="ui"
    [build-tools]="build_tools"
    [dhcp]="dhcp"
    [dhcp-proxy]="dhcp_proxy"
    [ntp]="ntp"
    [syslog]="syslog"
)

# What: Indirection so tests can stub the registry probe without a real
# daemon; the real path delegates to staging-image-freshness.sh's
# _sif_inspect() and returns its tri-state contract: 1 = registry call
# failed without confirming absence (shared retry budget exhausted), 2 =
# registry positively confirmed no such manifest/tag/digest exists. Only
# status 1's stderr is forwarded; a status-2 confirmed absence discards its
# stderr, since _sif_inspect's own "::error::" annotation for that case is a
# false alarm here, not a real registry problem.
# Why: A confirmed absence must stay distinguishable from a real registry
# failure so wait_for_touched_image() can fail fast on the latter instead of
# silently polling it for up to an hour.
# From: PR #1538, Issue #1449
image_exists() {
    local image="$1"
    if [[ -n "${STAGING_IMAGE_EXISTS_CMD:-}" ]]; then
        "$STAGING_IMAGE_EXISTS_CMD" "$image" && return 0
        # What: Stub path preserves its plain-boolean contract: nonzero
        # always means "not found yet, keep polling," mapped onto tri-state
        # status 2 (confirmed absence), never status 1's "retry budget
        # exhausted" meaning.
        # Why: The stub never exercises a real ghcr_retry call, so it cannot
        # produce a genuine status-1 result; mapping it to status 2 keeps
        # every stub-driven test's continued-polling expectation intact.
        # From: PR #1538, Issue #1449
        return 2
    fi
    local err_capture status
    err_capture="$(mktemp 2>/dev/null)" || err_capture=""
    if [[ -n "$err_capture" ]]; then
        _sif_inspect "$image" >/dev/null 2>"$err_capture"
        status=$?
        if (( status != 2 )); then
            cat "$err_capture" >&2
        fi
        rm -f "$err_capture"
        return "$status"
    fi
    # What: mktemp unavailable -- falls back to the original unconditional
    # stderr passthrough (no capture, no status-2 suppression).
    # Why: silently dropping diagnostics in an environment this helper
    # cannot even capture stderr in would be worse than the pre-existing,
    # unfiltered behavior.
    # From: PR #1538, Issue #1449
    _sif_inspect "$image" >/dev/null
}

# What: Retries the imagetools-create registry write via ghcr_retry instead
# of a single unretried attempt; GHCR_RETRY_USERNAME/PASSWORD are optional,
# since ghcr_retry backs off and retries even without them (just without a
# fresh relogin -- see that function's own comment), same as
# scripts/untracked/require-image-platforms.sh.
# Why: An authentication or other transient GHCR write failure must not fail
# the whole gate on a single unretried attempt.
# From: PR #1538, Issue #1449
backfill_from_base() {
    local pr_image="$1" base_image="$2"
    if [[ -n "${STAGING_BACKFILL_CMD:-}" ]]; then
        "$STAGING_BACKFILL_CMD" "$pr_image" "$base_image"
    else
        ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- \
            docker buildx imagetools create --prefer-index=false -t "$pr_image" "$base_image"
    fi
}

# What: Reports whether build-push.yml's own run for this PR's real branch
# head commit (pr_head_sha, not the synthetic merge commit build_sha) is
# still active, delegating the query to saf_event_has_incomplete_run() over
# curl+GH_TOKEN rather than the `gh` CLI, which a bare self-hosted
# `lancache-light` runner is not guaranteed to have. Its tri-state answer is
# flattened to this function's boolean contract: only status 0 (active)
# reports "active"; both status 1 (confirmed no incomplete run) and status 2
# (inconclusive) report "not active".
# Why: An unprovable answer must not let the caller extend its wait
# indefinitely, and this repo's Actions API only ever reports a
# pull_request-triggered run's real branch head under `head_sha` -- querying
# by the merge commit instead would always match zero runs.
# From: PR #1538, Issue #1449
build_push_run_active() {
    if [[ -n "${STAGING_BUILD_RUN_STATUS_CMD:-}" ]]; then
        "$STAGING_BUILD_RUN_STATUS_CMD"
        return $?
    fi
    if [[ -z "$pr_head_sha" ]]; then
        return 1
    fi
    saf_event_has_incomplete_run "$REPOSITORY" "$pr_head_sha" "pull_request"
}

wait_for_touched_image() {
    local pr_image="$1" service="$2"
    local start_time=$SECONDS
    local baseline_deadline=$((start_time + poll_timeout_seconds))
    local hard_deadline=$((start_time + poll_hard_ceiling_seconds))
    local warned_congestion=false
    # Force the first congestion probe (once the baseline is crossed) to
    # fire immediately instead of waiting a full interval -- matters both for
    # real runs (don't waste a whole interval before the first useful check)
    # and for tests that set STAGING_POLL_TIMEOUT_SECONDS=0.
    local last_congestion_check=$((start_time - congestion_check_interval_seconds))

    while true; do
        # What: Uses `image_exists ... && { ...; return 0; }` instead of
        # `if image_exists ...; then ...; fi` so `$?` right after is
        # guaranteed to be image_exists()'s own real exit status.
        # Why: A POSIX `if` with no matching branch (false condition, no
        # `else`) exits the whole if-statement with status 0 unconditionally,
        # silently discarding the 1-vs-2 classification (confirmed live:
        # `f() { return 2; }; if f; then :; fi; echo $?` prints 0, not 2).
        # From: PR #1538, Issue #1449
        image_exists "$pr_image" && {
            echo "::notice::$service staging image is present at $pr_image (waited $((SECONDS - start_time))s)."
            return 0
        }
        # What: Captures image_exists()'s real exit status on the fallthrough
        # path (see the comment above for why this control-flow shape is
        # required for that to hold).
        # Why: The fail-fast check immediately below needs the real 1-vs-2
        # status to decide whether to keep polling.
        # From: PR #1538, Issue #1449
        local exists_status=$?

        # What: Status 1 means image_exists()'s own ghcr_retry-wrapped call
        # already exhausted the shared registry retry budget without the
        # registry confirming absence; only status 2 (confirmed absence)
        # continues to the normal/hard-ceiling polling below.
        # Why: A persistent registry error must fail this wait immediately
        # once the shared retry budget is exhausted, not keep polling on an
        # error that budget could not resolve.
        # From: PR #1538, Issue #1449
        if (( exists_status != 2 )); then
            echo "::error::$service staging image ($pr_image) registry check failed (elapsed $((SECONDS - start_time))s) -- the last registry check did NOT positively confirm absence (network/timeout/rate-limit/auth, or an unrecognized error shape), and the shared GHCR retry budget is already exhausted for this check. Refusing to keep polling on an error that budget could not resolve; if this tag is later found to have existed all along, that is evidence of a registry-call failure being misread as absence, not a real missing build."
            return 1
        fi

        if (( SECONDS >= hard_deadline )); then
            echo "::error::$service staging image ($pr_image) hit the hard ${poll_hard_ceiling_seconds}s ceiling. The registry's last response confirmed no such manifest/tag exists (not a connection/timeout/auth failure) -- this is not a detection blind spot, build-push genuinely never published this tag."
            echo "::error::$service staging image ($pr_image) hit the hard ${poll_hard_ceiling_seconds}s ceiling. Even if build-push's run for this PR's head ($pr_head_sha) is still active, this gate refuses to wait any longer -- a run this slow needs its own investigation rather than an ever-longer poll."
            return 1
        fi

        if (( SECONDS >= baseline_deadline )) && (( SECONDS - last_congestion_check >= congestion_check_interval_seconds )); then
            last_congestion_check=$SECONDS
            if build_push_run_active; then
                if [[ "$warned_congestion" == false ]]; then
                    echo "::warning::$service staging image ($pr_image, tag commit $build_sha) has not appeared within the normal ${poll_timeout_seconds}s budget, but build-push's own run for this PR's head ($pr_head_sha) is still active -- extending the wait (up to ${poll_hard_ceiling_seconds}s total). This is expected under heavy self-hosted runner congestion (#895), not evidence of a stuck build."
                    warned_congestion=true
                fi
            else
                echo "::notice::build-push's run for this PR's head ($pr_head_sha, tag commit $build_sha) has already finished (or could not be found) and $service's staging tag still hasn't appeared -- further waiting cannot help, so treating this as a real failure now instead of idling until the ${poll_hard_ceiling_seconds}s hard ceiling."
                return 1
            fi
        fi

        # What: Single log line; only reached with exists_status == 2, since
        # the fail-fast branch above returns for every other status.
        # Why: Confirmed absence is the only case that reaches this line, so
        # the message states that positively rather than hedging.
        # From: PR #1538, Issue #1449
        echo "Waiting for $service staging image ($pr_image) from build-push (elapsed $((SECONDS - start_time))s, normal budget ${poll_timeout_seconds}s, hard ceiling ${poll_hard_ceiling_seconds}s) -- registry confirms no such manifest/tag yet (not a connection/timeout/auth failure)..."
        sleep "$poll_interval_seconds"
    done
}

for service in "${full_setup_services[@]}"; do
    pr_image="ghcr.io/${REPOSITORY}/${service}:${PR_TAG}"
    should_exist="$(vit_service_should_have_staging_tag "$service" "${touched_map[$service]}" "$workflow_changed")"

    if [[ "$should_exist" == "true" ]]; then
        if wait_for_touched_image "$pr_image" "$service"; then
            continue
        fi
        echo "::error::$service's PR staging tag ($pr_image) never appeared even though this PR touched it (or a workflow/CI-contract file changed) -- waited past the normal ${poll_timeout_seconds}s budget (and, if build-push's own run was still active, up to the ${poll_hard_ceiling_seconds}s hard ceiling; see the notice/warning lines above for which applied). Refusing to fall back to the PR base commit's content for a touched service -- that would silently revalidate the stale image #626 exists to stop testing, behind a tag name that looks PR-specific. Check whether build-push actually built and pushed $service for this commit."
        exit 1
    fi

    # #808: never back-fill without first proving the source image was
    # actually built from base.sha or later -- see scripts/lib/staging-image-freshness.sh
    # for why, and scripts/lib/staging-ancestor-fallback.sh for the full
    # resolution sequence (exact-BASE_SHA wait, then the ancestor fallback
    # when that wait genuinely cannot succeed).
    if ! resolved_source="$(saf_resolve_untouched_backfill_source "$REPOSITORY" "$service" "${classify_key_map[$service]}" "$BASE_SHA" \
        "$base_freshness_timeout_seconds" "$base_freshness_hard_ceiling_seconds" \
        "$ancestor_freshness_timeout_seconds" "$ancestor_freshness_hard_ceiling_seconds" \
        "$ancestor_extended_freshness_timeout_seconds" "$ancestor_extended_freshness_hard_ceiling_seconds" \
        "$base_freshness_poll_interval_seconds" "$ancestor_search_depth" "${STAGING_FRESHNESS_GIT_DIR:-.}")"; then
        exit 1
    fi
    echo "::notice::(re)pointing $PR_TAG at $resolved_source."
    backfill_from_base "$pr_image" "$resolved_source"
done

echo "All full-setup staging images are ready at tag $PR_TAG."
