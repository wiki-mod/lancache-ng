#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Reaps GHCR container package versions for this project's own images
# (services/* plus build-tools) that are no longer needed: closed-PR
# `pr-<N>-sha-<short>` staging tags (the original #626 mechanism this file
# replaces the former inline workflow logic for) AND genuinely orphaned
# untagged versions (the per-platform manifests and Buildx attestation/SBOM
# sub-manifests every multi-arch push creates automatically). Invoked by
# .github/workflows/gc-pr-staging-images.yml -- see that file's own header
# for the two triggers (pull_request: closed, and a periodic full sweep) and
# scripts/lib/gc-pr-staging-images.sh's own header for the two defects this
# extraction fixes.
#
# EXTRACTED (2026-08-06, issue #1095) from that workflow's own inline `run:`
# block into this standalone script for two reasons: (1) AG-CI-021's
# workflow-file line/byte ceiling makes every line moved out of YAML a small
# but real safety margin against the "self-modifying pull_request event
# creates zero runs" failure mode that ceiling exists to prevent; (2) a
# standalone script's pure classification logic (scripts/lib/gc-pr-staging-images.sh)
# can be sourced directly by a bats suite with mocked `gh`/`curl`/`jq`
# responses (tests/bats/gc_pr_staging_images.bats), which an inline YAML
# `run:` block cannot be, satisfying AG-VAL-029's "a confirmed real CI defect
# needs a durable, repeatable check" requirement for the classification-gap
# defect this file fixes.
#
# NOT in scope here: the concurrency fix for the OTHER confirmed root cause
# (two simultaneous full sweeps sharing one PAT's rate-limit budget) lives
# entirely in the calling workflow's own `concurrency:` block -- nothing in
# this script can fix a problem that is about how many COPIES of it GitHub
# Actions schedules, only the workflow YAML controls that.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ghcr-retry.sh
source "$script_dir/lib/ghcr-retry.sh"
# shellcheck source=scripts/lib/gc-pr-staging-images.sh
source "$script_dir/lib/gc-pr-staging-images.sh"

org="wiki-mod"
repo="wiki-mod/lancache-ng"
# Every service build-push.yml's build/build-arm64 jobs can push a PR staging
# tag for. dhcp/dhcp-proxy aren't used by full-setup validate, but a PR
# touching them still gets a staging tag pushed (see #626's build-job
# change), so they need reaping too. build-tools is included: full-setup-
# validate's client-simulation step pulls it at the PR staging tag as well.
# syslog added while this PR was in progress (merged in from current_dev,
# #1428/#1431's fluent-bit+syslog-ng combined container): it is a real entry
# in build-push.yml's own build/build-arm64 matrix like every other service
# here, so scripts/check-workflow-service-lists.sh's REQUIRES_SERVICES_ARRAY
# entry for this file (equal to the FULL canonical set, not a subset) would
# fail this file the moment syslog landed in the matrix without this array
# following it -- this is that follow-along update, done as part of merging
# current_dev's own unrelated syslog-matrix-array fix (which had updated the
# OLD inline copy of this array, in .github/workflows/gc-pr-staging-images.
# yml itself, before this PR moved it here) into this branch.
services=(proxy dns watchdog dhcp dhcp-proxy ntp syslog ui build-tools)

# Bounded, PER-SERVICE (not global) reaper cap: a single global cap shared
# across services in a fixed iteration order would let the first service in
# the list (proxy) consume the entire run's budget against the ~13,600-
# version untagged backlog this PR deliberately does NOT clean up (that is a
# separate, maintainer-supervised one-time pass -- see this repo's issue
# tracker for the dedicated backlog-drain effort), starving every later
# service in the same run. 40 per service x 9 services (see the
# services=(...) array below; stale "8 services" corrected 2026-08-14 --
# syslog joined the array in #1428/#1431, this comment's own arithmetic just
# never followed) = at most 360 deletions attempted per run: comfortably
# inside the classic PAT's
# 5000-requests/hour REST budget even counting the paginated listing calls,
# the closed-PR-tag `gh api DELETE` calls, and (new in this PR) one anonymous
# registry manifest GET per tagged version plus up to one more per
# about-to-delete orphan candidate. Hitting this cap is logged as a
# `::notice::`, not an error -- there is always a next scheduled/close-
# triggered run to keep draining the same service further.
max_deletions_per_service="${GC_MAX_DELETIONS_PER_SERVICE:-40}"

# 24-hour safety margin (maintainer-directed, explicit): applies to EVERY
# deletion category below (closed-PR tagged versions and orphaned untagged
# versions alike), not just the new orphan path -- a version that looks
# deletable by tag/reference state alone can still be the direct output of a
# build, promotion, or backfill that is still actively in flight elsewhere in
# the pipeline (e.g. scripts/ensure-pr-staging-images.sh's own back-fill
# `imagetools create` calls, which briefly create a fresh untagged manifest
# before the tag move lands). Giving every deletion candidate a fixed window
# to "prove" it is not mid-flight is far simpler and more robust than trying
# to positively enumerate every possible concurrent producer.
min_age_seconds="${GC_MIN_AGE_SECONDS:-86400}"

now_epoch="$(date -u +%s)"

# Confirmed PR states are cached across services (a PR number is unique
# repo-wide, so a state looked up while processing "proxy" is still valid
# while processing "dns" moments later) -- kept as a plain top-level
# associative array (not per-service) so this exact cross-service reuse
# happens automatically via gcps_pr_lookup_state's nameref parameter. It IS
# used -- passed by bare name (not "$pr_state_cache") to gcps_pr_lookup_state
# below, which binds it via `local -n cache_ref=...`. build-push.yml's static
# analysis job runs per-file with no cross-file (-x) mode, so it never sees
# that indirect-by-name consumer and can't trace this usage across the
# source boundary.
# shellcheck disable=SC2034
declare -A pr_state_cache=()

# A single ambiguous PR-state lookup (LOOKUP_FAILED) is deliberately safe
# on its own -- it just keeps that one version, exactly like an open PR (see
# gcps_pr_lookup_state's own header). But if EVERY (or nearly every) lookup
# in a run fails -- e.g. GHCR_PACKAGE_DELETE_PAT losing the `repo`/
# `public_repo` scope its `gh api repos/.../pulls/<N>` calls need, a scope
# with nothing to do with the read:packages/delete:packages this token is
# documented to need for the package-version calls, or the pulls API being
# rate-limited independently of the packages API on the same token -- the
# closed-PR tagged-version reap path would silently do nothing that entire
# run while the workflow still reports a healthy-looking "GC complete"
# summary, with no signal anywhere that anything was wrong. This threshold
# turns that specific silent-no-op shape into a real, run-failing error
# instead. 10 is a deliberately low bar: a handful of transient lookup
# failures in a run processing thousands of tagged versions is unremarkable
# background noise, but double digits is already far more consistent with a
# systemic credential/scope/rate-limit problem than with isolated blips, and
# catching it loudly costs nothing on a genuinely healthy run.
max_pr_lookup_failures="${GC_MAX_PR_LOOKUP_FAILURES:-10}"
pr_lookup_failures=0

# A single service reporting "no GHCR package yet" (a genuine HTTP 404 on
# the versions-listing call) is deliberately NOT an error on its own -- see
# process_service's own comment at that check for the real, live-verified
# case this protects (a service newly added to build-push.yml's matrix
# ahead of its first real push). But GitHub's own REST API documentation
# for this exact endpoint says some resources return 404 instead of 403
# when the caller lacks access, so a bare 404 is not a generally valid
# proof of absence either (issue #1557, item 72 of PR #1501's whole-file
# audit). Live-checked during this fix (2026-08-14): the package-metadata
# endpoint (`GET orgs/<org>/packages/container/<package>`, no `/versions`)
# and this versions-listing endpoint return an IDENTICAL 404 body/message
# for a genuinely nonexistent package -- there is no separate metadata call
# that discriminates a real-absence 404 from an access-denied one, so
# probing a second endpoint per candidate 404 (an earlier draft of this fix)
# would not actually have told the two cases apart. This project has no
# credential with read:packages deliberately stripped to test the
# access-denied side of that claim directly; it rests on GitHub's own
# general REST documentation for the endpoint family, not on a live
# reproduction of the ambiguous case itself. The same class of problem already
# has an established, working answer in this file for PR-state lookups
# (see max_pr_lookup_failures above): an isolated occurrence is normal and
# must not fail the run, but nearly every configured service hitting this
# same code path in one run is far more consistent with a systemic
# credential/scope problem than with several services all genuinely
# launching in the same run. Threshold is computed from the real service
# count rather than hardcoded, so it stays correct as services are
# added/removed from the services=(...) array below.
services_not_found=0

had_errors=0
deleted=0
kept=0

# process_service <service>
#
# Runs entirely in the CURRENT shell (called as a plain statement, never
# wrapped in `$(...)`), so every update this function makes to the
# top-level had_errors/deleted/kept/pr_state_cache variables above is
# immediately visible to the next service's own call and to this script's
# final summary -- deliberately avoiding the exact "$(...) always forks a
# subshell, so in-memory state changes made inside it vanish the instant it
# exits" trap scripts/lib/staging-ancestor-fallback.sh's own header
# documents hitting for real while building that file's cache.
process_service() {
  local service="$1"
  local package="lancache-ng%2F${service}"
  local versions_json version_list

  # had_errors turns a listing or delete failure into a failed GC run
  # instead of a silently "successful" one. Without this, a broken
  # GHCR_PACKAGE_DELETE_PAT (missing read:packages or delete:packages), a
  # rate limit, or a missing `gh` binary would make every listing/delete
  # call fail, the loop below would just see empty results or failed
  # deletes, and this workflow would report success having inspected or
  # removed nothing -- exactly the kind of "looks healthy but does nothing"
  # failure mode that would let staging tags accumulate in GHCR forever
  # undetected. A single service's listing failure doesn't abort the whole
  # run immediately: other services still get processed (so a per-package
  # hiccup doesn't block cleanup everywhere else), but the run still exits
  # non-zero at the end so CI reflects reality.
  # Deliberately NOT `2>&1` here (unlike most other `gh api`/jq captures in
  # this file, where merging streams into the error message is harmless): a
  # SUCCESSFUL `gh api --paginate` call can still write deprecation/rate-
  # limit notices to stderr, and merging those into `versions_json` would
  # silently corrupt the JSON array `jq -c '.[]'` below depends on -- turning
  # a healthy run into a same-shaped "failed to enumerate" error for a
  # completely different, spurious reason. stderr is captured to a scratch
  # file instead, purely for the error message on a genuine failure.
  local versions_stderr
  versions_stderr="$(mktemp)"
  if ! versions_json="$(gh api --paginate "orgs/${org}/packages/container/${package}/versions" 2>"$versions_stderr")"; then
    local list_error
    list_error="$(cat "$versions_stderr")"
    rm -f "$versions_stderr"
    # A real 404 here means the package itself does not exist yet -- e.g. a
    # service that just joined build-push.yml's build matrix (see this
    # file's own `services=(...)` comment: syslog, #1428/#1431) but has not
    # had its first image pushed yet. Confirmed live (2026-08-06) this is a
    # real, not merely hypothetical, transient state: `gh api` on a genuinely
    # missing package exits non-zero and writes "gh: Package not found.
    # (HTTP 404)" to stderr (the raw JSON error body itself goes to STDOUT,
    # which is why this check reads $list_error -- the stderr capture --
    # not $versions_json). This is NOT a reaper error: there is nothing to
    # list, and nothing to reap, for a service with no images published yet
    # -- it becomes real work again the moment the first image lands, with
    # no code change needed. Treating it as `had_errors=1` (this function's
    # ORIGINAL, inherited behavior -- confirmed the pre-extraction workflow's
    # own inline copy had the exact same defect) would fail this workflow's
    # every single run the moment any new service is added to the build
    # matrix ahead of its first real push, for a reason that has nothing to
    # do with GHCR_PACKAGE_DELETE_PAT, rate limits, or a real listing
    # failure -- exactly the kind of spurious, confusing red build this
    # project's own AG-CI-013/related rules exist to prevent.
    if [[ "$list_error" == *"HTTP 404"* ]]; then
      echo "::notice::lancache-ng/${service} has no GHCR package yet (HTTP 404 listing its versions) -- nothing to reap for a service with no images published. Not treated as an error."
      # Counted, not just logged: see this variable's own declaration above
      # for why a single occurrence must stay a safe notice, but nearly
      # every configured service hitting this path in the same run must not
      # still read as a healthy summary (issue #1557, item 72).
      services_not_found=$((services_not_found + 1))
      return
    fi
    echo "::error::Failed to list package versions for lancache-ng/${service}: $list_error"
    had_errors=1
    return
  fi
  rm -f "$versions_stderr"

  # `gh api --paginate` against this exact array-shaped endpoint was
  # verified live during this PR (2026-08-06, against the real
  # lancache-ng/proxy package, which has 3678 versions across 37 pages at
  # per_page=100 per its own real `Link: ...; rel="last"` response header):
  # a plain (non-paginated) call returns exactly 100 entries (page 1 only),
  # while `gh api --paginate ... | jq -c '.[]' | wc -l` -- the identical
  # command shape used below -- returned the full 3678, proving `--paginate`
  # really does merge every page into one continuous array rather than
  # silently truncating to page 1. No sanity-check heuristic is needed here
  # as a result; an earlier draft of this function warned on an exact
  # multiple-of-100 count as a possible truncation signal, but that would
  # have fired constantly on the one case (a real, large count landing on a
  # round page boundary) that is actually normal, while staying silent on
  # genuine truncation at any other count -- a heuristic that trains a
  # reader to ignore its own warnings is worse than no heuristic at all.
  #
  # jq's exit status inside a process substitution (`< <(... | jq ...)`) is
  # NOT checked by `set -e` -- bash simply never looks at it, so a
  # missing/broken `jq` or malformed input here would make the loop
  # silently see zero versions and this service would report as "nothing to
  # clean" instead of "couldn't be inspected." Capturing jq's output via a
  # checked command substitution first, then feeding a plain variable to
  # `read` via a here-string, makes a jq failure visible and fails the run,
  # exactly like every other failure mode in this script.
  if ! version_list="$(printf '%s' "$versions_json" | jq -c '.[]' 2>&1)"; then
    echo "::error::Failed to enumerate package versions for lancache-ng/${service} via jq: $version_list"
    had_errors=1
    return
  fi

  local orphan_phase_ok=1
  local registry_token=""
  local -A children_digests=()
  local -A all_digest_set=()
  local service_deletions=0

  # Pass 0: validate every version's `.name` really is the digest the orphan
  # phase's digest-set comparisons assume it is, and build that digest set.
  # ONE malformed entry disables orphan (untagged-version) classification for
  # the WHOLE service this run -- see gcps_version_name_is_digest's own
  # comment for why a partially-populated digest set is strictly more
  # dangerous than an empty one (it would make some still-referenced
  # manifest silently fail to match, looking exactly like a genuine orphan).
  # Closed-PR tagged-version reaping below does not depend on this pass at
  # all and is unaffected either way.
  local version_entry name
  while IFS= read -r version_entry; do
    [[ -z "$version_entry" ]] && continue
    if ! name="$(printf '%s' "$version_entry" | jq -r '.name' 2>&1)"; then
      echo "::error::Failed to read a package version's name/digest for $service via jq: $name"
      had_errors=1
      orphan_phase_ok=0
      continue
    fi
    if ! gcps_version_name_is_digest "$name"; then
      # AG-VAL-001 (issue #1557, item 79 of PR #1501's whole-file audit):
      # this used to be `::warning::`-only with no had_errors=1, unlike the
      # near-identical jq-read-failure case immediately above, which already
      # sets had_errors=1. Both are "required classification evidence for
      # this service is unavailable" states -- a malformed digest shape
      # disables orphan classification exactly like a jq failure does, so a
      # run hitting this must not still exit 0 and report a clean summary.
      echo "::error::A $service package version's .name ('$name') is not the expected sha256:<64-hex> digest shape -- disabling orphan (untagged-version) classification for this service this run. Closed-PR tagged-version reaping is unaffected."
      had_errors=1
      orphan_phase_ok=0
      continue
    fi
    all_digest_set["$name"]=1
  done <<< "$version_list"

  # Fetch the anonymous registry pull token ONCE per service, before Pass 1,
  # regardless of whether this service turns out to have any tagged versions
  # at all -- deliberately NOT deferred to "the first tagged version Pass 1
  # happens to see", which would leave registry_token empty (and every
  # subsequent manifest fetch silently unauthenticated) for the edge case of
  # a service with zero currently-tagged versions, since Pass 1's own loop
  # body never reaches the token-fetch code for an untagged entry (it
  # `continue`s out before that point). A wholly untagged service is
  # unlikely for any of these 9 always-actively-published services in
  # practice, but Pass 2 still needs a working token to check orphan
  # candidates' own manifests either way, so fetching it here once keeps the
  # token's lifetime independent of Pass 1's per-entry tag shape.
  if [[ "$orphan_phase_ok" == "1" ]]; then
    if ! registry_token="$(ghcr_retry ghcr.io "" "" -- gcps_registry_anon_token "$service" "$repo")" || [[ -z "$registry_token" ]]; then
      echo "::error::Failed to obtain an anonymous registry pull token for $service -- disabling orphan classification for this service this run."
      had_errors=1
      orphan_phase_ok=0
    fi
  fi

  # Pass 1: closed-PR tagged-version classification (the original #626
  # logic, unchanged in substance) PLUS -- when orphan_phase_ok -- collecting
  # every tagged version's own manifest children into children_digests, so
  # Pass 2 below can tell a genuinely orphaned untagged version apart from
  # one still referenced by a live tag's image index.
  local version_id tag_list
  while IFS= read -r version_entry; do
    [[ -z "$version_entry" ]] && continue
    if ! version_id="$(printf '%s' "$version_entry" | jq -r '.id' 2>&1)"; then
      echo "::error::Failed to read a package version's id for $service via jq: $version_id"
      had_errors=1
      continue
    fi
    [[ -z "$version_id" || "$version_id" == "null" ]] && continue

    if ! tag_list="$(printf '%s' "$version_entry" | jq -r '(.metadata.container.tags // [])[]' 2>&1)"; then
      echo "::error::Failed to enumerate tags for $service version $version_id via jq: $tag_list"
      had_errors=1
      continue
    fi

    if [[ -z "$tag_list" ]]; then
      continue # untagged -- classified in Pass 2 below, not here
    fi

    # sha256-<64-hex> attestation-reference tags (see the full live-verified
    # rationale below, at the tag this shape is actually classified under)
    # are scanned in their OWN pass over every one of this version's tags,
    # BEFORE the protected/has_closed_pr_tag decision loop below -- NOT
    # folded into that loop's own per-tag branch, even though a
    # sha256-<hex> tag would also be caught there. That decision loop
    # `break`s as soon as it reaches a decisive tag (protected=1), which is
    # correct and harmless for a decision (the outcome doesn't change by
    # looking at more tags once one of them already says "keep"), but WRONG
    # for data collection: a hypothetical multi-tag version like
    # ["latest", "sha256-<hex>"] would hit "latest" first, set protected=1,
    # `break`, and never reach the sha256-<hex> tag at all -- silently
    # under-populating children_digests, which is exactly the dangerous
    # direction (a still-referenced manifest looking orphaned) this whole
    # orphan phase exists to prevent. Every real version sampled live
    # (2026-08-06) carried exactly one tag, so this ordering bug cannot
    # currently fire in practice -- but that observation was drawn from a
    # sample, not a guarantee about every version this reaper will ever see,
    # so the loop is still written to not depend on it.
    local attestation_tag
    while IFS= read -r attestation_tag; do
      [[ -z "$attestation_tag" ]] && continue
      if [[ "$attestation_tag" =~ ^sha256-([0-9a-f]{64})$ ]]; then
        children_digests["sha256:${BASH_REMATCH[1]}"]=1
      fi
    done <<< "$tag_list"

    local protected=0 has_closed_pr_tag=0 tag
    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue
      if [[ "$tag" =~ ^pr-([0-9]+)-sha-[0-9a-f]{7,}(-amd64|-arm64)?$ ]]; then
        local pr_number="${BASH_REMATCH[1]}"
        # Called as a PLAIN STATEMENT with a result-variable argument, NOT
        # wrapped in `$(...)`: command substitution forks a subshell, and
        # gcps_pr_lookup_state's own pr_state_cache nameref writes would then
        # land on that subshell's private copy of the array and vanish the
        # instant it exits -- silently defeating the whole point of passing
        # a cache through in the first place (issue #1557, item 74 of PR
        # #1501's whole-file audit: this exact call site is what the bug was
        # in, even though gcps_pr_lookup_state's own direct unit tests never
        # caught it, since they invoke it as a plain statement too).
        local pr_state
        gcps_pr_lookup_state "$pr_number" "$repo" pr_state_cache pr_state
        case "$pr_state" in
          OPEN)
            protected=1
            ;;
          LOOKUP_FAILED)
            # An ambiguous lookup is treated exactly like an open PR: keep,
            # don't delete. See gcps_pr_lookup_state's own comment for why
            # collapsing these was the actual bug this reaper already fixed
            # once before. Counted separately from a real OPEN, though: see
            # max_pr_lookup_failures' own comment at its declaration for why
            # a run where this happens pervasively must not report success.
            protected=1
            pr_lookup_failures=$((pr_lookup_failures + 1))
            ;;
          CLOSED)
            has_closed_pr_tag=1
            ;;
        esac
        [[ "$protected" == "1" ]] && break
      else
        # Any non pr-* tag (nightly, dev, latest, vX.Y.Z, sha-<commit>, ...)
        # is a real published channel/source tag. Never delete it -- this
        # includes sha-<commit> tags specifically, for every deletion
        # mechanism this project runs, present and future, regardless of
        # git-branch reachability or age: scripts/lib/staging-ancestor-
        # fallback.sh's saf_find_built_ancestor() (called from
        # saf_resolve_untouched_backfill_source()) walks back from a PR's
        # base commit looking for a usable sha-<commit> image, but only up to
        # ancestor_search_depth commits deep -- NOT literally unbounded.
        # ensure-pr-staging-images.sh defaults that depth to 50
        # (STAGING_ANCESTOR_SEARCH_DEPTH), overridable via env var, so in
        # today's default configuration a sha-<commit> tag more than 50
        # commits behind some future PR's base could never actually be
        # selected by this specific fallback. That bound does not make any
        # sha-<commit> tag a safe deletion target from THIS reaper's side,
        # for two reasons: (1) the depth is an env-var override, not a
        # constant this script can assume stays 50 forever, and (2) even
        # within the current bound, this reaper has no way to know in
        # advance which past commit some future PR's base will land on, so
        # it cannot tell "more than 50 commits back from every future PR"
        # apart from "still within reach of the next one" -- the set of
        # sha-<commit> tags is small (roughly one per commit actually built),
        # so blanket-protecting all of them costs nothing worth trading for
        # that fragile inference.
        #
        # CORRECTED (issue #1095 G8 follow-up): the real invariant this branch
        # protects is "successfully-scanned sha-<commit> tags stay tabu," not
        # every sha-<commit> tag unconditionally regardless of outcome -- a
        # scan-failed image was never a valid backfill candidate in the first
        # place, since saf_resolve_untouched_backfill_source() exists to find
        # a genuinely usable built image, not a disqualified one. This branch
        # still protects every sha-<commit> tag it encounters with no
        # per-tag distinction, but that is safe, not merely convenient: a
        # scan-failed tag is deleted immediately, upstream of this reaper
        # entirely, by build-push.yml's own "Delete GHCR package version
        # pushed by a failed scan" step (build/build-arm64 jobs) the moment
        # "Scan pushed service digest with Trivy" fails against that exact
        # pushed digest -- so a scan-failed sha-<commit> tag should never
        # exist by the time any reaper run could see it. This reaper has no
        # reliable signal of its own to tell a passed-scan tag apart from a
        # failed one after the fact (GHCR's package-version metadata carries
        # no scan-result marker), so it deliberately does not attempt that
        # distinction here -- it relies entirely on the upstream immediate-
        # delete fix to keep a failed tag from ever reaching this decision in
        # the first place, rather than trying to re-derive scan outcome from
        # data this script was never given.
        #
        # `sha256-<64-hex>` tags (GHCR/Buildx's legacy referrers-fallback
        # attestation-association convention) also fall into this branch --
        # a real one, protected the same as any other non pr-* tag -- but
        # their target-digest EXTRACTION into children_digests happens in
        # the dedicated pass above this decision loop, not here: see that
        # pass's own comment for the full live-verified rationale and for
        # why it must not be gated by this loop's `break`.
        protected=1
        break
      fi
    done <<< "$tag_list"

    if [[ "$orphan_phase_ok" == "1" ]]; then
      local version_digest manifest_json
      # `if ! version_digest=...` (not a bare assignment): under this
      # script's own `set -euo pipefail`, an unguarded `x="$(jq ...)"`
      # statement that fails would exit the ENTIRE script right here -- no
      # summary line, no had_errors exit path, no remaining services --
      # exactly the failure mode this function's own gcps_pr_lookup_state
      # header comment already warns about for the identical shape.
      if ! version_digest="$(printf '%s' "$version_entry" | jq -r '.name' 2>&1)"; then
        echo "::error::Failed to read $service version $version_id's own digest via jq: $version_digest"
        had_errors=1
        orphan_phase_ok=0
        version_digest=""
      fi
      if [[ -n "$version_digest" ]]; then
        if ! manifest_json="$(ghcr_retry ghcr.io "" "" -- gcps_fetch_manifest "$service" "$version_digest" "$repo" "$registry_token")" \
            || [[ -z "$manifest_json" ]] || ! gcps_manifest_looks_valid "$manifest_json"; then
          echo "::error::Failed to fetch (or received an unrecognizable body for) $service digest $version_digest's own manifest -- disabling orphan classification for this service this run, since a partially-populated protected-digest set is more dangerous than none."
          had_errors=1
          orphan_phase_ok=0
        else
          local child_digest children_output
          # gcps_extract_manifest_children itself now fails (non-zero exit)
          # rather than silently printing nothing when jq genuinely errors on
          # a WELL-FORMED manifest body (as opposed to legitimately having no
          # children) -- treated the same as a fetch failure above, since an
          # incompletely-collected children set is what actually protects a
          # live platform manifest from being misclassified as an orphan.
          if ! children_output="$(gcps_extract_manifest_children "$manifest_json")"; then
            echo "::error::Failed to extract manifest children for $service digest $version_digest -- disabling orphan classification for this service this run."
            had_errors=1
            orphan_phase_ok=0
          else
            while IFS= read -r child_digest; do
              [[ -z "$child_digest" ]] && continue
              children_digests["$child_digest"]=1
            done <<< "$children_output"
          fi
        fi
      fi
    fi

    if [[ "$protected" == "1" || "$has_closed_pr_tag" == "0" ]]; then
      kept=$((kept + 1))
      continue
    fi

    local created_at created_epoch
    # AG-VAL-001 (issue #1557, item 79): a malformed/unreadable .created_at
    # is required evidence GHCR should always be returning -- unlike an
    # isolated ambiguous PR-state lookup (a transient network/rate-limit
    # blip this reaper already deliberately tolerates up to
    # max_pr_lookup_failures before failing the run), a bad timestamp on a
    # real GHCR record is a "should never happen" data-integrity signal.
    # The candidate is still kept (fail-closed, unchanged), but per this
    # project's own PR-1501 review finding, the run's exit code must also
    # reflect that required evidence was unavailable rather than silently
    # reporting a clean summary.
    if ! created_at="$(printf '%s' "$version_entry" | jq -r '.created_at' 2>&1)"; then
      echo "::error::Failed to read created_at for $service version $version_id via jq: $created_at -- keeping it this run (fail closed)."
      had_errors=1
      kept=$((kept + 1))
      continue
    fi
    if ! created_epoch="$(gcps_created_at_to_epoch "$created_at")"; then
      echo "::error::Could not parse created_at ('$created_at') for $service version $version_id -- keeping it this run (fail closed) rather than risk deleting something mid-flight."
      had_errors=1
      kept=$((kept + 1))
      continue
    fi
    if ! gcps_is_old_enough_to_delete "$created_epoch" "$now_epoch" "$min_age_seconds"; then
      kept=$((kept + 1))
      continue
    fi

    if (( service_deletions >= max_deletions_per_service )); then
      echo "::notice::$service hit its per-run deletion cap ($max_deletions_per_service) while processing closed-PR tagged versions; the rest are left for a later run."
      kept=$((kept + 1))
      continue
    fi

    # Cosmetic (log message only, the tags this version already has were
    # fully resolved via tag_list above) -- a jq failure here degrades the
    # message instead of aborting or failing the run over something that
    # isn't actually blocking the delete.
    local tags_display
    tags_display="$(printf '%s' "$version_entry" | jq -rc '.metadata.container.tags // []' 2>&1)" || tags_display="<jq error: $tags_display>"
    echo "Deleting $service version $version_id (only closed-PR staging tags: $tags_display)."
    local delete_output
    if delete_output="$(gh api -X DELETE "orgs/${org}/packages/container/${package}/versions/${version_id}" 2>&1)"; then
      deleted=$((deleted + 1))
      service_deletions=$((service_deletions + 1))
    else
      # Logged and counted, not just warned: this is exactly the "PAT can
      # list but lacks delete:packages" case (or GitHub rejecting one
      # specific delete) -- if every delete in a run failed this way,
      # deleted would stay 0 forever while the job still exited 0 unless
      # had_errors makes it fail below.
      echo "::error::Failed to delete $service version $version_id (tags: $tags_display): $delete_output"
      had_errors=1
    fi
  done <<< "$version_list"

  if [[ "$orphan_phase_ok" != "1" ]]; then
    return
  fi

  # Pass 2: orphan (untagged, unreferenced, old enough) classification --
  # the new mechanism this PR adds. Re-reads the SAME version_list captured
  # once at the top of this function (not a fresh listing call), so Pass 1's
  # children_digests reflects a single, internally consistent snapshot of
  # this service's manifest graph.
  while IFS= read -r version_entry; do
    [[ -z "$version_entry" ]] && continue
    if ! version_id="$(printf '%s' "$version_entry" | jq -r '.id' 2>&1)"; then
      had_errors=1
      continue
    fi
    [[ -z "$version_id" || "$version_id" == "null" ]] && continue

    if ! tag_list="$(printf '%s' "$version_entry" | jq -r '(.metadata.container.tags // [])[]' 2>&1)"; then
      had_errors=1
      continue
    fi
    [[ -n "$tag_list" ]] && continue # tagged -- already handled in Pass 1

    if ! name="$(printf '%s' "$version_entry" | jq -r '.name' 2>&1)"; then
      echo "::error::Failed to read a package version's name/digest for $service via jq: $name"
      had_errors=1
      continue
    fi
    if [[ -n "${children_digests[$name]:-}" ]]; then
      # Still referenced as a child (a platform manifest, or a Buildx-
      # embedded attestation/SBOM manifest) by at least one currently-tagged
      # image index. Deleting it would break that live tag.
      kept=$((kept + 1))
      continue
    fi

    local created_at created_epoch
    # AG-VAL-001 (issue #1557, item 79): same required-evidence reasoning as
    # Pass 1's identical check above -- both a jq read failure and an
    # unparseable timestamp must flag had_errors, and (this branch used to
    # have NO message at all, unlike Pass 1's equivalent) both must actually
    # report why via a log line, not fail silently.
    if ! created_at="$(printf '%s' "$version_entry" | jq -r '.created_at' 2>&1)"; then
      echo "::error::Failed to read created_at for $service version $version_id via jq: $created_at -- keeping it this run (fail closed)."
      had_errors=1
      kept=$((kept + 1))
      continue
    fi
    if ! created_epoch="$(gcps_created_at_to_epoch "$created_at")"; then
      echo "::error::Could not parse created_at ('$created_at') for $service version $version_id -- keeping it this run (fail closed) rather than risk deleting something mid-flight."
      had_errors=1
      kept=$((kept + 1))
      continue
    fi
    if ! gcps_is_old_enough_to_delete "$created_epoch" "$now_epoch" "$min_age_seconds"; then
      kept=$((kept + 1))
      continue
    fi

    if (( service_deletions >= max_deletions_per_service )); then
      echo "::notice::$service hit its per-run deletion cap ($max_deletions_per_service) while processing orphan candidates; the rest are left for a later run."
      kept=$((kept + 1))
      continue
    fi

    # This candidate has no tag of its own and is not listed as a child in
    # any currently-tagged manifest's own `manifests[]` array -- but that
    # array alone does not cover a REFERRERS-API attestation (the shape
    # actions/attest / .github/actions/ghcr-attest-retry produces, confirmed
    # in real use by this project's own build-push.yml "Attest image build
    # provenance" steps): such an attestation is its own separate,
    # permanently untagged package version that is NEVER listed inside any
    # index's manifests[] array, and can only be identified by fetching ITS
    # OWN manifest and reading its top-level `subject` field. One extra
    # registry GET per about-to-delete candidate (bounded by
    # max_deletions_per_service, never by the full untagged backlog) is
    # cheap insurance against deleting a still-relevant attestation whose
    # subject image is still alive.
    local candidate_manifest
    # AG-VAL-001 (issue #1557, item 79): required evidence (whether this
    # candidate is a live referrers-API attestation) was unavailable -- the
    # candidate is correctly kept either way (fail closed, unchanged), but
    # this must also flag had_errors so the run's exit code reflects that a
    # required check could not be completed, matching the identical
    # reasoning already applied to Pass 1's own manifest-fetch failure above.
    if ! candidate_manifest="$(ghcr_retry ghcr.io "" "" -- gcps_fetch_manifest "$service" "$name" "$repo" "$registry_token")" || [[ -z "$candidate_manifest" ]]; then
      echo "::error::Could not fetch $service candidate orphan $name's own manifest to check for a subject reference -- keeping it this run rather than risk deleting a live attestation."
      had_errors=1
      kept=$((kept + 1))
      continue
    fi
    local subject_digest
    subject_digest="$(printf '%s' "$candidate_manifest" | jq -r '.subject.digest // empty' 2>/dev/null)" || subject_digest=""
    if [[ -n "$subject_digest" ]] && [[ -n "${all_digest_set[$subject_digest]:-}" ]]; then
      # A live referrers-API attestation: its subject digest is still a
      # version that exists in this service's package right now.
      kept=$((kept + 1))
      continue
    fi

    echo "Deleting $service version $version_id (untagged, unreferenced orphan digest $name)."
    local delete_output
    if delete_output="$(gh api -X DELETE "orgs/${org}/packages/container/${package}/versions/${version_id}" 2>&1)"; then
      deleted=$((deleted + 1))
      service_deletions=$((service_deletions + 1))
    else
      echo "::error::Failed to delete $service orphan version $version_id (digest $name): $delete_output"
      had_errors=1
    fi
  done <<< "$version_list"
}

# main
#
# Everything that must NOT happen just from sourcing this file (requiring a
# real GH_TOKEN, checking for real tools, and actually sweeping every
# service) lives here rather than at plain top level, specifically so
# tests/bats/gc_pr_staging_images.bats can `source` this script -- getting
# process_service() and every config variable above for free -- and call
# process_service() directly against a mocked `gh`/`curl` without needing a
# real credential or tripping the capability checks. The BASH_SOURCE guard
# at the bottom of this file is what decides whether main ever actually
# runs.
main() {
  # No apostrophes or single quotes in this message (shellcheck SC1011): an
  # apostrophe inside a ${var:?message} expansion gets misparsed by static
  # analysis as opening a single-quoted string, which then desyncs on the
  # next real quote character it meets -- this message was rewritten to
  # avoid both, not just to silence the warning; the actual bash behavior
  # was never affected.
  : "${GH_TOKEN:?GH_TOKEN (the GHCR_PACKAGE_DELETE_PAT secret configured on this repository) is required -- see the calling workflow, specifically its Check for GHCR deletion credentials step, which must gate whether this script ever runs.}"

  # AG-CI-001: self-hosted runners (this job runs on lancache-light, not
  # inside the pinned build-tools container -- see the calling workflow's
  # `runs-on:`) must not be assumed to carry any tool beyond the bare OS.
  # Fail loud and early rather than let a missing tool surface as a
  # confusing mid-run parse error partway through the first service. `date`
  # specifically must be a GNU `date` for gcps_created_at_to_epoch's `-d`
  # flag to parse an ISO-8601 timestamp -- this project's self-hosted
  # runners are Linux hosts (GNU coreutils `date` is the default there), and
  # `date -d` is already an established pattern elsewhere in this repo (see
  # scripts/ntp-cap-sys-time-simulation.sh), but this check alone cannot
  # distinguish a present-but-non-GNU `date` from a working one.
  local required_cmd
  for required_cmd in gh jq curl date; do
    if ! command -v "$required_cmd" >/dev/null 2>&1; then
      echo "::error::Required tool '$required_cmd' was not found on this runner. This script cannot run without it."
      exit 1
    fi
  done

  for service in "${services[@]}"; do
    process_service "$service"
  done

  echo "::notice::PR staging-tag GC complete: deleted $deleted version(s), kept $kept."

  if (( pr_lookup_failures > 0 )); then
    echo "::warning::$pr_lookup_failures PR-state lookup(s) could not be confirmed this run (ambiguous gh api result, not a real 404) -- every one of those tagged versions was kept as a precaution, per gcps_pr_lookup_state's own fail-safe design."
  fi
  if (( pr_lookup_failures >= max_pr_lookup_failures )); then
    echo "::error::$pr_lookup_failures PR-state lookups failed this run (threshold: $max_pr_lookup_failures) -- this many ambiguous lookups is far more consistent with a systemic problem (GHCR_PACKAGE_DELETE_PAT missing its repo/public_repo scope, or the pulls API being rate-limited) than with isolated transient blips. Every one of those versions was still kept safely, but reporting this run as a plain success would hide that the closed-PR tagged-version reap path likely did far less real work than it should have. Investigated live during this mechanism's own 2026-08-06 root-cause pass: the one prior real scheduled run with a suspiciously low delete count (2026-08-02, 10 deleted/21919 kept) was confirmed, via its own actual GitHub Actions log, to have hit ZERO real LOOKUP_FAILED occurrences -- that run's low count was fully explained by the classification-gap defect this whole file's extraction fixes, not by this failure mode. This threshold exists so a FUTURE occurrence of this different failure shape is caught loudly instead of requiring another manual log audit to notice."
    had_errors=1
  fi

  # A single service reporting "no GHCR package yet" is a safe, expected
  # notice (see services_not_found's own declaration above). But GitHub's
  # own REST docs say a 404 here can also hide an authorization failure
  # this reaper cannot positively distinguish from genuine absence per
  # call, so more than half of the currently-configured services hitting
  # this path in the SAME run is treated the same way pr_lookup_failures'
  # own threshold already treats pervasive ambiguous PR lookups: not proof
  # of a real problem, but far more consistent with one (GHCR_PACKAGE_DELETE_
  # PAT losing read:packages, or the packages API being rate-limited) than
  # with several services all genuinely launching in the same run (issue
  # #1557, item 72).
  local max_services_not_found=$(( (${#services[@]} / 2) + 1 ))
  if (( services_not_found >= max_services_not_found )); then
    echo "::error::$services_not_found of ${#services[@]} configured services reported no GHCR package yet this run (threshold: $max_services_not_found) -- this many simultaneous 404s is far more consistent with GHCR_PACKAGE_DELETE_PAT losing its read:packages scope (which GitHub's own REST docs say can also surface as 404, not just 403) than with that many services genuinely never having published an image. Each one was still safely treated as nothing-to-reap, but reporting this run as a plain success would hide that the reap path likely did far less real work than it should have across the whole services list, not just one service."
    had_errors=1
  fi

  if [[ "$had_errors" == "1" ]]; then
    echo "::error::One or more package-version listings, manifest fetches, or deletions failed (see errors above). Failing this run instead of reporting success -- GHCR_PACKAGE_DELETE_PAT may be missing read:packages/delete:packages scopes, the API may be rate-limited, or GitHub rejected a delete for another reason. A GC run that looks healthy while silently doing nothing would let PR staging tags and orphaned manifests accumulate in GHCR forever undetected."
    exit 1
  fi
}

# `"${BASH_SOURCE[0]}" == "${0}"` is true only when this file is EXECUTED
# directly (as the calling workflow does: `bash scripts/gc-pr-staging-images.sh`),
# not when it is `source`d by something else -- the bats suite sources this
# file to reuse process_service() and its config variables under mocked
# gh/curl, and must not have main() (which hard-requires a real GH_TOKEN and
# real tools) run out from under it just from the `source` line.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
