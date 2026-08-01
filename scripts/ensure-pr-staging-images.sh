#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Makes the PR-scoped staging images the full-setup deep validation suite
# needs actually present before the sims run, on a pull_request event. This
# is where the deep gate REUSES the #626/#627 pr-<N>-sha-<short> mechanism
# rather than inventing its own:
#
#   1. For every full-setup service this PR TOUCHED (or every service but
#      build-tools if a workflow/CI-contract file changed), POLL the registry
#      until build-push.yml's build/build-arm64/merge-manifests have pushed
#      that service's pr-<N>-sha-<short> tag -- this poll IS the cross-
#      workflow wait, since a separate workflow cannot express `needs:` on
#      build-push's jobs. If the tag never appears within the timeout, FAIL
#      CLOSED: a touched service with no staging image means its build failed
#      (or the registry is unreachable), and silently validating stale
#      base-channel content behind a PR-looking tag is exactly #626's bug.
#   2. For every service this PR did NOT touch, (re)point pr-<N>-sha-<short>
#      at this PR's own base commit's durable per-commit sha-<short> image
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
# durable per-commit sha-<short> image. nightly is
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
# sha-<short> image will never exist via a push-triggered build, for any
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
source "$script_dir/lib/validation-image-tag.sh"
# shellcheck source=scripts/lib/ghcr-retry.sh
source "$script_dir/lib/ghcr-retry.sh"
# shellcheck source=scripts/lib/staging-image-freshness.sh
source "$script_dir/lib/staging-image-freshness.sh"
# shellcheck source=scripts/lib/staging-ancestor-fallback.sh
source "$script_dir/lib/staging-ancestor-fallback.sh"

: "${REPOSITORY:?REPOSITORY is required}"
: "${PR_TAG:?PR_TAG (pr-<N>-sha-<short>) is required}"
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
# congestion probe's `gh api` query. Deliberately a separate variable from
# build_sha above: the Actions "list workflow runs" API's `head_sha` filter
# for a pull_request-triggered run is always the PR's real branch head, never
# the synthetic merge commit build_sha holds, so conflating the two (the
# pre-#975 bug) makes the query permanently match zero runs. Same
# intentionally-optional contract as build_sha: an omitted value just falls
# back to the pre-#895 fail-at-baseline behavior via the empty check in
# build_push_run_active() below.
pr_head_sha="${PR_HEAD_SHA:-}"

# Bounded wait for build-push to finish pushing this PR's touched-service
# staging tags. build/build-arm64 run on the scarce lancache-heavy tier
# (Rust compile + multi-arch image builds) and merge-manifests after them, so
# they can legitimately take many minutes; this is the "normal" budget past
# which we start asking whether build-push's own run is still active rather
# than failing outright (see #895 note above). Overridable for tests.
poll_timeout_seconds="${STAGING_POLL_TIMEOUT_SECONDS:-1500}"
poll_interval_seconds="${STAGING_POLL_INTERVAL_SECONDS:-15}"

# #895: absolute hard ceiling, independent of what the congestion probe
# reports. Even a build-push run that genuinely never stops (a hung job, a
# runner that died without ever marking its run failed) must not be allowed
# to hold this runner forever -- this is what keeps the fix "bounded and
# reasoned about" rather than an unbounded wait. 5400s/90min is chosen as
# generous headroom over the confirmed real-world worst case so far (#895's
# incident: ~34min actual end-to-end build-push time against the old 25min
# budget), not an arbitrary large number picked to make failures rarer.
poll_hard_ceiling_seconds="${STAGING_POLL_HARD_CEILING_SECONDS:-5400}"
# A misconfigured ceiling below the normal budget would make the extension
# logic self-contradicting (deadline already past hard ceiling on entry), so
# clamp it up rather than silently produce a negative wait window.
if (( poll_hard_ceiling_seconds < poll_timeout_seconds )); then
    poll_hard_ceiling_seconds=$poll_timeout_seconds
fi

# How often to actually call the congestion probe once past the normal
# budget, so a long extension doesn't hammer the GitHub API once per
# poll_interval_seconds tick.
congestion_check_interval_seconds="${STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS:-60}"

# #808: bounded wait for the back-fill source image itself to become fresh
# enough (see scripts/lib/staging-image-freshness.sh for the mechanism). This
# governs ONLY the wait against BASE_SHA's own image
# (saf_resolve_untouched_backfill_source's "normal path", step 2) -- NOT the
# separate, much shorter ancestor-candidate budget below. This wait can
# genuinely be racing a real, still-building push run: it is reached whenever
# a confirmed push-triggered build-push.yml run for BASE_SHA exists (or its
# status could not be positively ruled out), which is exactly the case where
# the image may simply not have finished pushing yet, the same congestion
# scenario wait_for_touched_image() above already gets headroom for. A short
# ceiling here would hard-fail this gate on a perfectly healthy,
# still-running build, which is strictly worse than the never-built-base-
# commit problem this whole mechanism exists to fix. 5400s/90min matches the
# touched-image hard ceiling above (same worst-case build-push runtime, since
# this is fundamentally the same pipeline building the same commit); 900s/
# 15min is, as before, purely the "start logging that we're still waiting"
# threshold for the common case where the image is already fresh and this
# resolves on the first poll.
base_freshness_timeout_seconds="${BASE_FRESHNESS_POLL_TIMEOUT_SECONDS:-900}"
base_freshness_hard_ceiling_seconds="${BASE_FRESHNESS_POLL_HARD_CEILING_SECONDS:-5400}"
if (( base_freshness_hard_ceiling_seconds < base_freshness_timeout_seconds )); then
    base_freshness_hard_ceiling_seconds=$base_freshness_timeout_seconds
fi
base_freshness_poll_interval_seconds="${BASE_FRESHNESS_POLL_INTERVAL_SECONDS:-15}"

# Separate, deliberately SHORT budget for saf_find_built_ancestor's own
# per-candidate freshness checks (used only once BASE_SHA's own wait above
# has failed AND both fail-closed gates confirm a genuine deliberate skip, or
# via the fast-path pre-check). An ancestor candidate is, by construction,
# already confirmed (via saf_base_commit_has_confirmed_run) to have a REAL
# recorded build-push.yml run further back in history than BASE_SHA -- if its
# image doesn't already exist by the time this mechanism looks, it never
# will, since there is no "still building" scenario for a commit further in
# the past than one already checked. A long, congestion-scale ceiling here
# would only slow down every ancestor-fallback case for no correctness
# benefit, and would multiply badly across up to ancestor_search_depth
# candidates if an early one's run somehow never produced an image.
ancestor_freshness_timeout_seconds="${ANCESTOR_FRESHNESS_POLL_TIMEOUT_SECONDS:-300}"
ancestor_freshness_hard_ceiling_seconds="${ANCESTOR_FRESHNESS_POLL_HARD_CEILING_SECONDS:-600}"
if (( ancestor_freshness_hard_ceiling_seconds < ancestor_freshness_timeout_seconds )); then
    ancestor_freshness_hard_ceiling_seconds=$ancestor_freshness_timeout_seconds
fi

# Separate budget for saf_find_built_ancestor's own ONE-TIME extended retry,
# given only to a candidate whose own build-push.yml run is positively
# confirmed still active (saf_candidate_run_is_active) after its initial
# short-budget check above already failed -- see
# scripts/lib/staging-ancestor-fallback.sh's saf_resolve_untouched_backfill_source
# header for why this is now its own explicit parameter rather than reusing
# base_freshness_*, even though this caller happens to pass the identical
# 900/5400 value for both. That reuse is safe HERE specifically because this
# job's own "ensure PR staging images" step (full-setup-deep-validate.yml) has
# a 100-minute job timeout explicitly sized to clear exactly this ~90-minute
# worst case with headroom (see that job's own timeout-minutes comment) --
# unlike build-push.yml's own equivalent step, whose full-setup-validate job
# has only a 30-minute timeout and therefore passes a much smaller value for
# this same parameter (see that step's own comment for why).
ancestor_extended_freshness_timeout_seconds="${ANCESTOR_EXTENDED_FRESHNESS_POLL_TIMEOUT_SECONDS:-900}"
ancestor_extended_freshness_hard_ceiling_seconds="${ANCESTOR_EXTENDED_FRESHNESS_POLL_HARD_CEILING_SECONDS:-5400}"
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
# scripts/syslog-forwarding-simulation.sh's Triggers 7/8 (real DHCP lease
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
# for): now included too. scripts/syslog-forwarding-simulation.sh starts it
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
full_setup_services=(proxy dns watchdog ui build-tools dhcp dhcp-proxy ntp)

declare -A touched_map=(
    [proxy]="${PROXY_TOUCHED:-false}"
    [dns]="${DNS_TOUCHED:-false}"
    [watchdog]="${WATCHDOG_TOUCHED:-false}"
    [ui]="${UI_TOUCHED:-false}"
    [build-tools]="${BUILD_TOOLS_TOUCHED:-false}"
    [dhcp]="${DHCP_TOUCHED:-false}"
    [dhcp-proxy]="${DHCP_PROXY_TOUCHED:-false}"
    [ntp]="${NTP_TOUCHED:-false}"
)

# Indirection so tests can stub the registry probe without a real daemon.
image_exists() {
    local image="$1"
    if [[ -n "${STAGING_IMAGE_EXISTS_CMD:-}" ]]; then
        "$STAGING_IMAGE_EXISTS_CMD" "$image"
    else
        docker buildx imagetools inspect "$image" >/dev/null 2>&1
    fi
}

# #822 ("Pattern D"): this real `imagetools create` write is the exact
# operation observed failing live three times in one day with
# "401 Unauthorized: unauthenticated" (PRs #804/#817/#824, "ensure PR staging
# images" job) -- it previously ran once with no retry at all. GHCR_RETRY_
# USERNAME/PASSWORD are optional (ghcr_retry backs off and retries even
# without them, just without a fresh relogin -- see that function's own
# comment), so this still works if a caller runs the script without setting
# them, same as scripts/require-image-platforms.sh.
backfill_from_base() {
    local pr_image="$1" base_image="$2"
    if [[ -n "${STAGING_BACKFILL_CMD:-}" ]]; then
        "$STAGING_BACKFILL_CMD" "$pr_image" "$base_image"
    else
        ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- \
            docker buildx imagetools create --prefer-index=false -t "$pr_image" "$base_image"
    fi
}

# #895 congestion probe: reports whether build-push.yml's own run for this
# PR's current push is still active (any status other than "completed" --
# verified live against this repo's real Actions API that an in-flight run
# can report "pending", not only "queued"/"in_progress", so this
# deliberately checks for the one terminal state rather than enumerating
# non-terminal ones). Indirection so tests can stub the GitHub API call.
# Intentionally fail-safe: if PR_HEAD_SHA is unset, `gh` isn't available, or
# the API call fails for any reason, this returns non-zero (treated as "not
# active") so the caller falls back to the original pre-#895
# fail-at-baseline behavior instead of ever hanging on a broken probe.
#
# #975: queries by pr_head_sha (the PR's real branch head), NOT build_sha
# (the synthetic merge commit) -- the Actions "list workflow runs" API's
# `head_sha` field/filter for a pull_request-triggered run is always the real
# branch head, so querying by the merge commit (the pre-#975 bug) matched
# zero runs, always, making this probe permanently report "not active"
# regardless of whether build-push was genuinely still running. Also checks
# EVERY run the query returns (`any(...)`), not just the newest one: a single
# push can produce more than one build-push run for the same head_sha (e.g.
# `synchronize` and `labeled` firing close together), and the newest one
# completing or being cancelled must not hide an older one still building.
build_push_run_active() {
    if [[ -n "${STAGING_BUILD_RUN_STATUS_CMD:-}" ]]; then
        "$STAGING_BUILD_RUN_STATUS_CMD"
        return $?
    fi
    if [[ -z "$pr_head_sha" ]] || ! command -v gh >/dev/null 2>&1; then
        return 1
    fi
    local any_active
    any_active="$(gh api "repos/${REPOSITORY}/actions/workflows/build-push.yml/runs?head_sha=${pr_head_sha}&event=pull_request&per_page=20" \
        --jq 'any(.workflow_runs[]?; .status != "completed")' 2>/dev/null)" || return 1
    [[ "$any_active" == "true" ]]
}

# base_commit_has_confirmed_push_run() and find_built_ancestor() used to
# live here as this file's own private functions. They are now
# saf_base_commit_has_confirmed_run()/saf_find_built_ancestor() in
# scripts/lib/staging-ancestor-fallback.sh, sourced above, so build-push.yml's
# own equivalent step can share the identical implementation instead of
# carrying a second, independent copy of the same recovery logic.

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
        if image_exists "$pr_image"; then
            echo "::notice::$service staging image is present at $pr_image (waited $((SECONDS - start_time))s)."
            return 0
        fi

        if (( SECONDS >= hard_deadline )); then
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

        echo "Waiting for $service staging image ($pr_image) from build-push (elapsed $((SECONDS - start_time))s, normal budget ${poll_timeout_seconds}s, hard ceiling ${poll_hard_ceiling_seconds}s)..."
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
    if ! resolved_source="$(saf_resolve_untouched_backfill_source "$REPOSITORY" "$service" "$BASE_SHA" \
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
