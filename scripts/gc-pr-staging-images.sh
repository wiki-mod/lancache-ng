#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Reaps GHCR container package versions for this project's own images
# (services/* plus build-tools) that are no longer needed: closed-PR
# `pr-<N>-sha-<short>` staging tags (the original #626 mechanism this file
# replaces the former inline workflow logic for), genuinely orphaned
# untagged versions (the per-platform manifests and Buildx attestation/SBOM
# sub-manifests every multi-arch push creates automatically), AND (added for
# F-17, issue #1095) sha-<commit> tags beyond a per-service retention count,
# for commits that are current_dev-exclusive (never promoted to master or a
# release tag) -- see process_service_sha_retention()'s own header for the
# full policy. Invoked by .github/workflows/gc-pr-staging-images.yml -- see
# that file's own header for the two triggers (pull_request: closed, and a
# periodic full sweep) and scripts/lib/gc-pr-staging-images.sh's own header
# for the classification defects and primitives this file builds on.
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
# service in the same run. 40 per service x 8 services = at most 320
# deletions attempted per run: comfortably inside the classic PAT's
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

# F-17 (issue #1095): retention/pruning for sha-<commit> image tags, which
# were previously unconditionally protected forever regardless of age or
# count -- see this file's own tag-loop comment below (the "any non pr-*
# tag" branch) for the pre-F-17 reasoning this policy narrows, and
# scripts/lib/gc-pr-staging-images.sh's gcps_commit_branch_relation() for
# the ancestry-check primitive this pass is built on.
#
# Maintainer decision (issue #1095, 2026-08-07): keep at most this many
# previous sha-<commit> versions per service, for current_dev specifically
# -- release/master provenance images stay protected regardless of count
# (see process_service_sha_retention()'s own header for the full policy).
sha_retention_keep="${GC_SHA_RETENTION_KEEP:-10}"
#
# Real deletion under this new policy stays OFF by default on purpose: F-17
# was scoped, per the coordinating task that implemented it, to ship
# classification/dry-run only in this PR, with actual deletion needing its
# own separate, later, explicit maintainer approval -- not bundled into the
# same approval as "does the retention count/scope design make sense."
# GC_SHA_RETENTION_ENABLED=true is the one-line flip a maintainer can set as
# a repository variable once that separate approval is given; nothing else
# in this file needs to change.
sha_retention_enabled="${GC_SHA_RETENTION_ENABLED:-false}"
#
# A distinct (lower) cap from max_deletions_per_service above, not a reuse
# of it: this is a brand-new deletion category on its first rollout, and
# each candidate costs up to 3 extra `gh api compare` calls (current_dev,
# master, and however many release tags exist) on top of the existing
# per-version work, so a smaller per-run budget is a deliberate extra
# caution while this policy is still new, independent of whichever cap the
# pre-existing categories use.
sha_retention_max_deletions_per_service="${GC_SHA_RETENTION_MAX_DELETIONS_PER_SERVICE:-20}"

now_epoch="$(date -u +%s)"

# Every vX.Y.Z release tag this repository has ever cut -- populated by
# main() (see main()'s own comment for why the real listing call lives
# there and not here) for process_service_sha_retention()'s "not also
# reachable from a release tag" protection check. Declared (empty) at this
# top level, not inside main(), so tests/bats/gc_pr_staging_images.bats can
# `source` this whole file -- which reaches every line at this top level,
# including this one -- without needing a real `gh` binary or network
# access: main() is the only place that performs the actual `gh api`
# listing call, exactly mirroring this file's own GH_TOKEN check and
# required-tool check, which live inside main() for the identical reason.
#
# `-g` is not cosmetic here: `declare` (without `-g`) inside a function
# scopes its target LOCAL to that function, even when the `declare` line
# itself lives at another file's top level and is only reached via `source`
# -- `source` does not open a new scope, so a `source` call made FROM
# inside a function (exactly what tests/bats/gc_pr_staging_images.bats's own
# `setup()` does) runs this file's top-level code AS PART OF that function's
# body. Confirmed live (2026-08-07) with a minimal reproduction: a plain
# `declare -A foo=()` at a sourced file's top level is provably gone
# (`declare -p foo` reports "not found") the moment the function that
# sourced it returns -- exactly what caused this array's original
# non-`-g` declaration to silently fail bats' own per-test `setup()`/`@test`
# boundary: `commit_relation_cache` (see below) did not exist at all by the
# time a `@test` body ran, and a `local -n` nameref to a not-yet-existing
# name falls back to indexed-array (arithmetic-subscript) semantics instead
# of associative-array (string-subscript) semantics, producing exactly the
# `<hex-string>: unbound variable` failures this fix resolves.
declare -ag release_tags=()
sha_retention_lookup_ok=1

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
#
# CORRECTED (F-17, issue #1095): this was declared without `-g` before this
# PR. Empirically, its own existing tests (gcps_pr_lookup_state's caching
# test, and every process_service() test exercising a pr-* tag) still pass
# either way in practice -- plausible because every one of THOSE call paths
# writes to the cache (via a confirmed OPEN/CLOSED/LOOKUP_FAILED answer)
# before anything else in the same test needs to read a PRE-POPULATED
# entry back, so a freshly auto-vivified (if oddly-typed) variable never
# actually gets exercised on its read path the same way this PR's own
# sha-tag retention pass does (multiple distinct (commit, ref) pairs
# checked, cached, and re-read for the SAME commit across gates, within one
# test). Not a proven-safe distinction to keep relying on, though -- fixed
# here defensively alongside commit_relation_cache below, both for
# consistency and because a future test shape could hit the exact same
# latent gap this PR's own tests just did.
# shellcheck disable=SC2034
declare -Ag pr_state_cache=()

# Same cross-service, per-run caching rationale as pr_state_cache above,
# applied to gcps_commit_branch_relation()'s ANCESTOR/NOT_ANCESTOR/
# LOOKUP_FAILED answers: a commit's relation to current_dev/master/a release
# tag is a repo-wide fact, not a per-service one, so a commit checked while
# processing "proxy" does not need re-checking while processing "dns". See
# `release_tags`'s own comment above for why `-g` is required, not optional,
# here -- this exact array is what exposed the gap `-g`'s absence caused.
# shellcheck disable=SC2034
declare -Ag commit_relation_cache=()

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

had_errors=0
deleted=0
kept=0
# Counted separately from `deleted` (real deletions) so the final summary
# distinguishes "actually removed" from "would have been removed under the
# F-17 retention policy, but GC_SHA_RETENTION_ENABLED is not set" -- folding
# this into `deleted` would misreport a dry run as having done real work.
sha_retention_would_delete=0

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
      echo "::warning::A $service package version's .name ('$name') is not the expected sha256:<64-hex> digest shape -- disabling orphan (untagged-version) classification for this service this run. Closed-PR tagged-version reaping is unaffected."
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
  # unlikely for any of these 8 always-actively-published services in
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
        case "$(gcps_pr_lookup_state "$pr_number" "$repo" pr_state_cache)" in
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
        # is a real published channel/source tag. Never delete it via THIS
        # pass (the closed-PR-tag reap) -- this includes sha-<commit> tags,
        # unconditionally, regardless of git-branch reachability or age.
        #
        # CORRECTED (F-17, issue #1095): sha-<commit> tags are no longer
        # unconditionally protected forever by every mechanism this script
        # runs -- process_service_sha_retention() (called from
        # process_service() right after this Pass 1 loop) is a second,
        # separate deletion mechanism that CAN and does prune a sha-<commit>
        # tag, but only when it can positively confirm the commit is
        # current_dev-exclusive (never promoted to master or a release tag)
        # AND ranked beyond the newest $sha_retention_keep for that service.
        # This Pass 1 branch's own blanket protection is unaffected and
        # still correct on its own terms: the reasoning below (about
        # ancestor_search_depth, and about scan-failed tags) explains why
        # blanket protection was the right STARTING default, not why it must
        # stay unconditional forever -- see process_service_sha_retention's
        # own header for the narrower, provably-safe carve-out F-17 adds on
        # top of it.
        #
        # scripts/lib/staging-ancestor-fallback.sh's saf_find_built_ancestor() (called from
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
    if ! created_at="$(printf '%s' "$version_entry" | jq -r '.created_at' 2>&1)"; then
      echo "::warning::Failed to read created_at for $service version $version_id via jq: $created_at -- keeping it this run (fail closed)."
      kept=$((kept + 1))
      continue
    fi
    if ! created_epoch="$(gcps_created_at_to_epoch "$created_at")"; then
      echo "::warning::Could not parse created_at ('$created_at') for $service version $version_id -- keeping it this run (fail closed) rather than risk deleting something mid-flight."
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

  # Pass 1.5: sha-<commit> tag retention (F-17, issue #1095) -- deliberately
  # called regardless of orphan_phase_ok below: it only ever needs each
  # version's own tags/created_at (already available on version_list), never
  # the manifest-children graph orphan_phase_ok/children_digests exist for,
  # so a manifest-fetch problem that disables Pass 2 for this service has no
  # bearing on whether sha-tag retention can still run safely.
  process_service_sha_retention "$service" "$version_list"

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
    if ! created_at="$(printf '%s' "$version_entry" | jq -r '.created_at' 2>&1)"; then
      echo "::warning::Failed to read created_at for $service version $version_id via jq: $created_at -- keeping it this run (fail closed)."
      kept=$((kept + 1))
      continue
    fi
    if ! created_epoch="$(gcps_created_at_to_epoch "$created_at")"; then
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
    if ! candidate_manifest="$(ghcr_retry ghcr.io "" "" -- gcps_fetch_manifest "$service" "$name" "$repo" "$registry_token")" || [[ -z "$candidate_manifest" ]]; then
      echo "::warning::Could not fetch $service candidate orphan $name's own manifest to check for a subject reference -- keeping it this run rather than risk deleting a live attestation."
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

# process_service_sha_retention <service> <version_list>
#
# F-17 (issue #1095): prunes sha-<commit> image tags (and their -amd64/
# -arm64 legs) beyond the newest $sha_retention_keep per service, but ONLY
# for a commit confirmed to be current_dev-exclusive -- reachable from
# current_dev's tip, and NOT also reachable from master's tip or any release
# tag. Before this pass existed, every sha-<commit> tag was unconditionally
# protected forever (see process_service()'s own Pass 1 tag-loop comment for
# the original reasoning) because a blanket "protect everything" default is
# always safe, just unbounded -- this pass narrows that default only where
# it can prove narrowing is safe, and leaves the blanket protection in place
# everywhere it can't prove that (ambiguous ancestry, no confirmed
# current_dev membership, release/master membership, a release-tag-listing
# failure disabling the whole pass via sha_retention_lookup_ok). Real
# deletion additionally requires sha_retention_enabled=true (see that
# variable's own comment at its declaration) -- until then this pass only
# classifies and logs what it WOULD delete, exactly like a dry run.
#
# Runs entirely in the CURRENT shell (called as a plain statement from
# process_service(), never wrapped in `$(...)`), for the identical reason
# process_service() itself is called that way from main()'s loop: so this
# function's updates to the top-level had_errors/deleted/kept/
# sha_retention_would_delete/commit_relation_cache variables are immediately
# visible afterward, not lost to a subshell.
#
# Grouping is per COMMIT, not per individual tag/version: a single commit
# can carry up to three real tags (the merged multi-platform sha-<short>,
# plus sha-<short>-amd64 and sha-<short>-arm64 legs -- see build-push.yml's
# own merge-manifests job), each a SEPARATE GHCR package version with its
# own version id. Ranking and pruning per-tag independently could keep one
# leg of a commit while pruning another, leaving an inconsistent partial
# state; this function ranks by commit (using the newest created_at seen
# among that commit's own tag versions) and, if a commit is pruned, prunes
# every one of its known tag versions together.
process_service_sha_retention() {
  local service="$1"
  local version_list="$2"
  local package="lancache-ng%2F${service}"

  if [[ "$sha_retention_lookup_ok" != "1" ]]; then
    # Already warned once, at the top-level release-tag fetch that set this
    # flag -- not re-warning per service here to avoid 8x duplicate noise.
    return
  fi

  local version_entry version_id tag_list created_at created_epoch tag
  local -A commit_created_at=()   # commit-short-sha -> newest created_at epoch seen
  local -A commit_version_ids=()  # commit-short-sha -> space-separated version id list

  while IFS= read -r version_entry; do
    [[ -z "$version_entry" ]] && continue
    if ! version_id="$(printf '%s' "$version_entry" | jq -r '.id' 2>&1)"; then
      echo "::error::Failed to read a package version's id for $service (sha-tag retention pass) via jq: $version_id"
      had_errors=1
      continue
    fi
    [[ -z "$version_id" || "$version_id" == "null" ]] && continue

    if ! tag_list="$(printf '%s' "$version_entry" | jq -r '(.metadata.container.tags // [])[]' 2>&1)"; then
      echo "::error::Failed to enumerate tags for $service version $version_id (sha-tag retention pass) via jq: $tag_list"
      had_errors=1
      continue
    fi
    [[ -z "$tag_list" ]] && continue # untagged -- not a sha-<commit> tag, nothing for this pass

    local matched_commit=""
    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue
      # Matches the merged multi-platform tag (sha-<short>) and both
      # per-arch legs (sha-<short>-amd64, sha-<short>-arm64) -- see
      # build-push.yml's build/build-arm64/merge-manifests jobs for where
      # each of these three real tag shapes gets pushed. Deliberately does
      # NOT match sha256-<64-hex> (the Buildx attestation-fallback TAG
      # shape, a completely different namespace already handled elsewhere
      # in process_service()'s Pass 1) -- the hyphen after "sha" plus a
      # short (not 64-char) hex run is what distinguishes them.
      if [[ "$tag" =~ ^sha-([0-9a-f]{7,40})(-amd64|-arm64)?$ ]]; then
        matched_commit="${BASH_REMATCH[1]}"
        break
      fi
    done <<< "$tag_list"
    [[ -z "$matched_commit" ]] && continue

    if ! created_at="$(printf '%s' "$version_entry" | jq -r '.created_at' 2>&1)"; then
      echo "::warning::Failed to read created_at for $service version $version_id (sha-tag retention pass) via jq: $created_at -- excluding it from ranking this run (fail closed: it stays exactly as protected as before this pass existed)."
      continue
    fi
    if ! created_epoch="$(gcps_created_at_to_epoch "$created_at")"; then
      echo "::warning::Could not parse created_at ('$created_at') for $service version $version_id (sha-tag retention pass) -- excluding it from ranking this run (fail closed)."
      continue
    fi

    commit_version_ids["$matched_commit"]="${commit_version_ids[$matched_commit]:-}${commit_version_ids[$matched_commit]:+ }$version_id"
    if [[ -z "${commit_created_at[$matched_commit]:-}" ]] || (( created_epoch > commit_created_at[$matched_commit] )); then
      commit_created_at["$matched_commit"]="$created_epoch"
    fi
  done <<< "$version_list"

  local commit_count="${#commit_created_at[@]}"
  if (( commit_count == 0 )); then
    return # nothing sha-<commit>-tagged for this service this run
  fi

  # Rank commits newest-first by their own newest-seen created_at (ties
  # broken arbitrarily by sort -- commits created the same second are
  # equally "new" for this purpose, so tie order does not affect
  # correctness). "epoch:commit" pairs, sorted numerically descending on
  # the epoch field; commit-short-shas are hex only, so the ":" separator
  # cannot collide with either field's own content.
  local commit entry
  local -a ranked=()
  for commit in "${!commit_created_at[@]}"; do
    ranked+=("${commit_created_at[$commit]}:${commit}")
  done
  mapfile -t ranked < <(printf '%s\n' "${ranked[@]}" | sort -t: -k1,1nr)

  local rank=0
  local service_sha_retention_deletions=0
  for entry in "${ranked[@]}"; do
    commit="${entry#*:}"
    rank=$((rank + 1))

    if (( rank <= sha_retention_keep )); then
      continue # within the newest-N window -- always kept, no ancestry check needed
    fi

    if (( service_sha_retention_deletions >= sha_retention_max_deletions_per_service )); then
      echo "::notice::$service hit its sha-tag retention deletion cap ($sha_retention_max_deletions_per_service) this run while processing commits beyond the newest $sha_retention_keep; the rest are left for a later run."
      continue
    fi
    if ! gcps_is_old_enough_to_delete "${commit_created_at[$commit]}" "$now_epoch" "$min_age_seconds"; then
      continue
    fi

    # Fail-closed eligibility chain: EVERY check below must positively
    # confirm "safe to prune" for this commit to become a deletion
    # candidate. Any LOOKUP_FAILED (ambiguous) or "still protected" result
    # at any step leaves the commit exactly as protected as it was before
    # this pass existed -- see gcps_commit_branch_relation's own comment for
    # why the caller (here) must apply the correct fail-closed direction
    # per question rather than trusting a single boolean.
    local relation
    relation="$(gcps_commit_branch_relation "$repo" "$commit" "current_dev" commit_relation_cache)"
    if [[ "$relation" != "ANCESTOR" ]]; then
      continue # not confirmed reachable from current_dev at all -- don't touch it
    fi
    relation="$(gcps_commit_branch_relation "$repo" "$commit" "master" commit_relation_cache)"
    if [[ "$relation" != "NOT_ANCESTOR" ]]; then
      continue # confirmed reachable from master, OR ambiguous -- protect either way
    fi

    local release_tag protected_by_release=0
    for release_tag in "${release_tags[@]}"; do
      relation="$(gcps_commit_branch_relation "$repo" "$commit" "$release_tag" commit_relation_cache)"
      if [[ "$relation" != "NOT_ANCESTOR" ]]; then
        protected_by_release=1
        break
      fi
    done
    if (( protected_by_release == 1 )); then
      continue
    fi

    # Eligible: current_dev-exclusive, ranked beyond the retention window,
    # old enough, under this run's dedicated deletion cap.
    service_sha_retention_deletions=$((service_sha_retention_deletions + 1))
    local vid
    for vid in ${commit_version_ids[$commit]}; do
      if [[ "$sha_retention_enabled" == "true" ]]; then
        echo "Deleting $service version $vid (sha-<commit> retention: commit $commit ranked #$rank, beyond the newest $sha_retention_keep, current_dev-exclusive)."
        local delete_output
        if delete_output="$(gh api -X DELETE "orgs/${org}/packages/container/${package}/versions/${vid}" 2>&1)"; then
          deleted=$((deleted + 1))
        else
          echo "::error::Failed to delete $service sha-retention version $vid (commit $commit): $delete_output"
          had_errors=1
        fi
      else
        echo "::notice::[dry-run, GC_SHA_RETENTION_ENABLED not set] Would delete $service version $vid (sha-<commit> retention: commit $commit ranked #$rank, beyond the newest $sha_retention_keep, current_dev-exclusive)."
        sha_retention_would_delete=$((sha_retention_would_delete + 1))
      fi
    done
  done
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
  for required_cmd in gh jq curl date sort; do
    if ! command -v "$required_cmd" >/dev/null 2>&1; then
      echo "::error::Required tool '$required_cmd' was not found on this runner. This script cannot run without it."
      exit 1
    fi
  done

  # F-17 (issue #1095): list every vX.Y.Z release tag ONCE for the whole
  # run (not per service -- a commit's release-tag membership does not
  # depend on which service's images are being processed right now), into
  # the top-level release_tags array process_service_sha_retention() reads.
  # Deliberately performed here inside main(), not at this file's top
  # level, so that `source`-ing this script (as
  # tests/bats/gc_pr_staging_images.bats does, to reuse process_service()
  # under mocked gh/curl without a real credential) never makes a real,
  # unmocked network call as a side effect of sourcing -- the exact same
  # reasoning this function's own GH_TOKEN check and required-tool loop
  # above are already built on.
  #
  # A listing failure here must NOT be silently read as "no release tags
  # exist, therefore nothing is release-protected" -- that is exactly the
  # dangerous direction (a real release commit's sha-* tag looking safe to
  # prune when it is not) -- so sha_retention_lookup_ok gates the entire
  # sha-tag retention pass off for this run instead, leaving every
  # sha-<commit> tag exactly as protected as it was before this policy
  # existed. The pre-existing closed-PR-tag and orphan reap passes are
  # entirely unaffected either way; this flag only gates the new pass.
  local release_tags_raw
  if ! release_tags_raw="$(gh api --paginate "repos/${repo}/tags" 2>&1)"; then
    echo "::warning::Failed to list release tags for $repo -- disabling sha-<commit> tag retention (F-17) for this entire run, since it cannot prove a retention candidate isn't also a release. Every closed-PR-tag and orphan reap pass is unaffected: $release_tags_raw"
    sha_retention_lookup_ok=0
  else
    # A real, successful listing that simply contains zero vX.Y.Z-shaped
    # tags is not a failure (this repository could in principle have none
    # yet) -- `grep -E ... || true` here only exists to keep a genuinely
    # empty match set from tripping this script's own `set -e` (grep's own
    # exit code is 1, not an error, for "found nothing"), which is exactly
    # the AG-VAL-004 "optional fallback with a documented reason" case, not
    # a hidden required-command failure. Confirmed live (2026-08-07,
    # `gh api --paginate repos/wiki-mod/lancache-ng/tags`) this repository
    # actually has three: v0.1.0, v0.2.0, v0.3.0 -- and confirmed, via
    # `gh api repos/wiki-mod/lancache-ng/compare/<tag>...master`, that a
    # real release tag's own commit is NOT always a simple linear ancestor
    # of every OTHER release tag's or current_dev's tip (this project's
    # actual release history includes divergent lines, e.g. v0.2.0 vs the
    # current v0.3.0-based master) -- process_service_sha_retention()'s
    # per-commit, per-ref compare calls handle this correctly regardless,
    # since each check is independent and fails closed on its own.
    mapfile -t release_tags < <(printf '%s' "$release_tags_raw" | jq -r '.[].name' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' || true)
  fi

  for service in "${services[@]}"; do
    process_service "$service"
  done

  echo "::notice::PR staging-tag GC complete: deleted $deleted version(s), kept $kept."

  if [[ "$sha_retention_lookup_ok" != "1" ]]; then
    echo "::warning::sha-<commit> tag retention (F-17) was disabled for this entire run (release-tag listing failed at startup -- see the warning above). Every sha-<commit> tag was left exactly as protected as before this policy existed."
  elif [[ "$sha_retention_enabled" == "true" ]]; then
    echo "::notice::sha-<commit> tag retention (F-17): deleted $deleted version(s) counted above under this policy this run (GC_SHA_RETENTION_ENABLED=true)."
  else
    echo "::notice::sha-<commit> tag retention (F-17) ran in dry-run mode (GC_SHA_RETENTION_ENABLED is not 'true'): $sha_retention_would_delete version(s) across all services would have been deleted under the current retention policy (keep newest $sha_retention_keep per service, current_dev-exclusive commits only). Nothing was actually deleted by this policy this run."
  fi

  if (( pr_lookup_failures > 0 )); then
    echo "::warning::$pr_lookup_failures PR-state lookup(s) could not be confirmed this run (ambiguous gh api result, not a real 404) -- every one of those tagged versions was kept as a precaution, per gcps_pr_lookup_state's own fail-safe design."
  fi
  if (( pr_lookup_failures >= max_pr_lookup_failures )); then
    echo "::error::$pr_lookup_failures PR-state lookups failed this run (threshold: $max_pr_lookup_failures) -- this many ambiguous lookups is far more consistent with a systemic problem (GHCR_PACKAGE_DELETE_PAT missing its repo/public_repo scope, or the pulls API being rate-limited) than with isolated transient blips. Every one of those versions was still kept safely, but reporting this run as a plain success would hide that the closed-PR tagged-version reap path likely did far less real work than it should have. Investigated live during this mechanism's own 2026-08-06 root-cause pass: the one prior real scheduled run with a suspiciously low delete count (2026-08-02, 10 deleted/21919 kept) was confirmed, via its own actual GitHub Actions log, to have hit ZERO real LOOKUP_FAILED occurrences -- that run's low count was fully explained by the classification-gap defect this whole file's extraction fixes, not by this failure mode. This threshold exists so a FUTURE occurrence of this different failure shape is caught loudly instead of requiring another manual log audit to notice."
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
