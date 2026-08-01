#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Shared recovery path for the untouched-service back-fill's PR base commit
# freshness wait: a PR's base commit can be one that build-push.yml's own
# `push` trigger `paths-ignore` deliberately never builds (a docs/governance-
# only commit). When that happens, the base commit's own per-commit image can
# never appear no matter how long the freshness wait runs, so this file adds
# a narrow, provably-safe fallback that walks the base commit's own ancestor
# history for the nearest commit that both has a real build and a freshness-
# confirmed per-commit image, and substitutes THAT ancestor's own immutable
# per-commit tag for the back-fill -- never falling back to the mutable
# nightly/latest channel, matching the fail-closed design
# scripts/lib/staging-image-freshness.sh's own header already documents.
#
# Sourced by scripts/ensure-pr-staging-images.sh and by build-push.yml's
# "Ensure PR staging tags exist for full-setup services" step, so the two
# independent copies this recovery path used to require stay a single
# implementation instead of drifting -- same reasoning, and the same
# sourcing convention, as scripts/lib/validation-image-tag.sh's own
# SOURCE OF TRUTH note.
#
# Depends on scripts/lib/staging-image-freshness.sh (sif_wait_for_fresh_base_image,
# for the actual per-commit freshness proof) and scripts/lib/ghcr-retry.sh
# (a generic retry loop this file reuses for the GitHub Actions API query
# below, not just GHCR registry operations -- see saf_query_run_count's own
# comment for why reusing that exact function, rather than writing a second
# near-identical retry loop, is the right call here). Callers must source
# both of those files before this one.
#
# Deliberately NOT `set -euo pipefail` at the top level, for the same reason
# ghcr-retry.sh/staging-image-freshness.sh aren't: this file only defines
# functions for a caller to invoke under the caller's own shell options.

# saf_paths_are_ignorable <newline-separated-paths>
#
# Pure function: returns 0 if every path in the given newline-separated list
# matches build-push.yml's own `push` trigger `paths-ignore` patterns
# (`**/*.md`, `docs/**`, with `CHANGELOG.md` explicitly un-ignored -- mirrors
# that trigger's own `paths-ignore:` block exactly; keep both in sync by hand
# if that block ever changes). Returns 1 if any path does not match (a real,
# non-doc change was present). An empty input list is NOT treated as
# "everything ignorable" -- it returns 1, since an empty diff most likely
# means the diff itself could not be computed (see saf_base_commit_diff_paths
# below), and this function has no way to distinguish "genuinely zero
# changed paths" from "diff failed silently" -- callers that already know
# the diff succeeded and legitimately found zero paths should not call this
# function with an empty string in the first place.
saf_paths_are_ignorable() {
  local paths="$1"
  if [[ -z "$paths" ]]; then
    return 1
  fi
  local path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    # `!CHANGELOG.md`: explicitly un-ignored by build-push.yml's own
    # paths-ignore block (so its own shellcheck/PR-body-scan guardrails still
    # see a CHANGELOG-only push) -- a change here is never a safe "deliberate
    # skip" signal on its own.
    if [[ "$path" == "CHANGELOG.md" ]]; then
      return 1
    fi
    # `**/*.md`: any path ending in .md, at any depth.
    if [[ "$path" == *.md ]]; then
      continue
    fi
    # `docs/**`: any path under a top-level docs/ directory.
    if [[ "$path" == docs/* ]]; then
      continue
    fi
    return 1
  done <<< "$paths"
  return 0
}

# saf_base_commit_diff_paths <sha> [git_dir]
#
# Echoes the newline-separated list of paths <sha> changed relative to its
# FIRST parent (`git diff-tree --no-commit-id --name-only -r <sha>^1 <sha>`),
# or returns non-zero with no output if <sha> has no parent (a root commit)
# or the diff otherwise fails. Using the first parent specifically (not a
# plain two-argument diff against every parent, and not `git show`'s default
# combined-diff behavior for a merge commit) matters because this project
# does not squash-merge: a PR merge commit's first parent is the target
# branch's own tip immediately before that merge landed, so this is "what did
# this push actually introduce relative to the branch's prior state" -- the
# same question GitHub's own `paths-ignore` evaluation answers for a push
# event. A second/later parent is the merged-in feature branch's own tip,
# which is not what either "should this push have been skipped" or
# "what commit represents the target branch just before this one" mean.
saf_base_commit_diff_paths() {
  local sha="${1:?saf_base_commit_diff_paths: sha is required}"
  local git_dir="${2:-.}"
  git -C "$git_dir" diff-tree --no-commit-id --name-only -r "${sha}^1" "$sha" 2>/dev/null
}

# saf_base_commit_paths_are_ignorable <sha> [git_dir]
#
# Answers "did <sha> only change paths build-push.yml's own push trigger
# would skip?" -- the missing half of the "was this commit deliberately
# skipped, or did it just never get a chance to build" question. A confirmed
# absence of any push-triggered run (saf_base_commit_has_confirmed_run below)
# is NOT enough on its own to unlock the ancestor fallback: it proves GitHub
# never created a run, but not that the commit's own changed paths actually
# matched the ignore list. If build-push.yml's `push` trigger were ever
# temporarily disabled while a real, service-changing commit landed and was
# later re-enabled, a bare "zero runs" reading would misidentify that outage
# as a deliberate skip and back-fill an untouched service from a stale
# ancestor -- silently validating content that omits the real base change.
# This is exactly the #626/#808 class of bug the whole ancestor-fallback
# mechanism must not reintroduce, so this positive path-level confirmation is
# a hard requirement before any caller treats "zero runs" as safe to act on.
#
# Returns 0 if every changed path matches the ignore patterns (a genuine
# deliberate-skip candidate). Returns 1 if at least one path does not (a real
# change was present -- the confirmed-zero-runs reading must NOT be trusted;
# callers must treat this the same as "a run exists", i.e. no fallback).
# Returns 2 if the diff itself could not be computed (root commit, missing
# object, or any other git failure) -- also NOT safe to unlock the fallback
# on, for the same "can't prove it, don't act on it" reasoning
# saf_base_commit_has_confirmed_run's own header documents for its own
# inconclusive case.
saf_base_commit_paths_are_ignorable() {
  local sha="${1:?saf_base_commit_paths_are_ignorable: sha is required}"
  local git_dir="${2:-.}"
  local paths
  paths="$(saf_base_commit_diff_paths "$sha" "$git_dir")"
  if [[ -z "$paths" ]]; then
    return 2
  fi
  if saf_paths_are_ignorable "$paths"; then
    return 0
  fi
  return 1
}

# _saf_github_api_get <url> <body_file> <token>
#
# Internal helper: performs the actual HTTP GET and writes the response body
# to <body_file>, returning 0 only for a real HTTP 200. Called via
# ghcr_retry (see saf_query_run_count below) rather than passed bare curl
# directly: curl's OWN exit code stays 0 for a non-2xx HTTP response (only a
# network-level failure -- DNS, connection refused, timeout -- makes curl
# itself fail), so wrapping the status-code check in this function is what
# actually makes ghcr_retry's retry loop retry on a bad response, not just
# on a dropped connection.
_saf_github_api_get() {
  local url="$1" body_file="$2" token="$3"
  local status
  status="$(curl -sS -o "$body_file" -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${token}" \
    "$url" 2>/dev/null)" || return 1
  [[ "$status" == "200" ]]
}

# saf_query_run_count <repository> <sha> <event-or-empty>
#
# Low-level GitHub Actions API query: echoes the number of build-push.yml
# runs recorded for <sha>, optionally filtered to a specific <event> type
# (e.g. "push"; pass an empty string for "any event"). Requires the FULL
# 40-character commit SHA -- the API silently matches nothing for an
# abbreviated short SHA.
#
# Talks to the GitHub REST API directly via `curl` + `GH_TOKEN`, never the
# `gh` CLI: AG-CI-001 requires assuming self-hosted runners do not provide
# project validation tools, and both real callers of this file
# (full-setup-deep-validate.yml's "ensure PR staging images" job,
# build-push.yml's own "Ensure PR staging tags exist" step) run this code
# directly on a bare `lancache-light` runner (AG-CI-002), not inside the
# pinned build-tools image -- `gh` is not guaranteed present there, and
# depending on it would make this whole file's ancestor-fallback mechanism
# silently unreachable on the real fleet whenever it's absent (every query
# would immediately report "inconclusive", which every caller must then
# treat as "a run exists" -- see saf_base_commit_has_confirmed_run's own
# header -- permanently blocking the exact fallback this file exists to
# provide). `curl` matches this project's own established precedent for
# exactly this situation (scripts/check-action-node-versions.sh's
# fetch_external_action_yaml(), scripts/check-pr-tracking-metadata.sh's
# project-board lookup -- both curl+GH_TOKEN specifically because `gh`
# cannot be assumed present either). Response parsing uses a bare `grep` on
# the `total_count` field, not `jq`/`python3`, for the same reason
# scripts/lib/staging-image-freshness.sh's sif_image_revision() already
# avoids jq -- neither is guaranteed present on this runner tier either (see
# that function's own header for the confirmed AG-CI-001/AG-VAL-017
# reasoning).
#
# Wrapped in scripts/lib/ghcr-retry.sh's ghcr_retry: this query's result is
# load-bearing -- turning a transient API hiccup into a hard "confirmed zero
# runs" or a false "a run exists" would either wrongly unlock or wrongly
# block the ancestor fallback. Reusing ghcr_retry directly (rather than
# writing a second near-identical backoff loop) is deliberate: this
# project's established retry-wrapper policy (bounded attempts, fixed
# backoff, ::warning::/::error:: logging) is exactly the right policy for
# any transient-failure-prone external call, GHCR-specific or not, and
# scripts/lib/ghcr-retry.sh's own header already documents that AG-CI-013
# requires reusing one documented wrapper rather than inventing a bespoke
# retry per call site. The registry/username/password parameters are unused
# here (this call needs no docker login) -- passing empty username/password
# means ghcr_retry's own "no credentials -- retry without a fresh login"
# branch applies, and the registry argument is a non-empty placeholder only
# because ghcr_retry's own required-argument check rejects an empty string;
# it is never actually used for anything when username/password are both
# empty.
#
# Returns non-zero with no output if the query fails even after retries
# (GH_TOKEN unset, network error, non-200 response after retries, or a
# malformed response body with no parseable total_count).
saf_query_run_count() {
  local repository="${1:?saf_query_run_count: repository is required}"
  local sha="${2:?saf_query_run_count: sha is required}"
  local event="${3-}"
  if [[ -z "${GH_TOKEN:-}" ]]; then
    return 1
  fi
  local url="https://api.github.com/repos/${repository}/actions/workflows/build-push.yml/runs?head_sha=${sha}&per_page=1"
  if [[ -n "$event" ]]; then
    url="${url}&event=${event}"
  fi
  local body
  body="$(mktemp)"
  if ! ghcr_retry "n/a-not-a-real-registry" "" "" -- _saf_github_api_get "$url" "$body" "$GH_TOKEN"; then
    rm -f "$body"
    return 1
  fi
  local run_count
  run_count="$(grep -o '"total_count"[[:space:]]*:[[:space:]]*[0-9]\+' "$body" | head -1 | grep -o '[0-9]\+$')"
  rm -f "$body"
  if [[ ! "$run_count" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  printf '%s\n' "$run_count"
}

# saf_query_tag_publishing_run_count <repository> <sha>
#
# Like saf_query_run_count, but counts only runs whose trigger event
# actually publishes a per-commit sha-<sha> tag KEYED BY THIS EXACT COMMIT --
# push, workflow_dispatch, and schedule all check out <sha> itself as
# github.sha for that run (docker/metadata-action's `type=sha` tag in
# build-push.yml's "Extract metadata" step is therefore sha-<sha>), but a
# pull_request-triggered run's github.sha is the SYNTHETIC MERGE COMMIT for
# that specific PR event (see build-push.yml's own "Compute PR staging tag"
# step comment), a DIFFERENT value from <sha> even when <sha> is the exact
# head_sha the Actions API reports for that run (head_sha for a
# pull_request-triggered run is always the PR's real branch head -- see
# #975's own note on this same field/event distinction -- but github.sha
# inside that run is the merge commit, not head_sha). A pull_request run
# recorded against <sha> therefore proves nothing about whether
# ghcr.io/.../sha-<sha short> was ever published, and must not count as
# proof an ancestor candidate was built.
#
# Issues one saf_query_run_count call per allowed event type (push,
# workflow_dispatch, schedule) and sums the results, rather than one
# unfiltered query filtered client-side by each run's own `event` field:
# the Actions API's own `event=` filter already narrows server-side to
# exactly the trigger types that matter, so this reuses saf_query_run_count
# (and its curl/grep/retry machinery) unchanged three times instead of
# parsing an array of per-run event strings out of an unfiltered response
# with the same jq-free tooling constraint saf_query_run_count's own header
# documents. Three queries per candidate is a deliberate, minor efficiency
# trade against a much simpler and more robust implementation.
#
# Returns non-zero with no output if any of the three underlying queries
# fails (this function has no way to distinguish "genuinely zero
# tag-publishing runs" from "one of the three sub-queries failed", so a
# failure anywhere must propagate as inconclusive, not as a partial count).
saf_query_tag_publishing_run_count() {
  local repository="${1:?saf_query_tag_publishing_run_count: repository is required}"
  local sha="${2:?saf_query_tag_publishing_run_count: sha is required}"
  local event total=0 count
  for event in push workflow_dispatch schedule; do
    count="$(saf_query_run_count "$repository" "$sha" "$event")" || return 1
    total=$((total + count))
  done
  printf '%s\n' "$total"
}

# saf_base_commit_has_confirmed_run <repository> <sha> <event-or-empty>
#
# Answers "does at least one build-push.yml run (optionally filtered to
# <event>) exist for <sha>?", used two different ways by the two callers in
# this file:
#   - Passed "push": asks specifically about a push-triggered run, for the
#     PR base-commit decision (paired with saf_base_commit_paths_are_ignorable
#     above -- see that function's header for why event=push alone is not
#     sufercient proof of a deliberate skip on its own).
#   - Passed "" (any TAG-PUBLISHING event): asks whether any run exists
#     whose trigger type actually publishes a per-commit sha-<sha> tag KEYED
#     BY <sha> ITSELF, for the ancestor-candidate pre-filter in
#     saf_find_built_ancestor below. Backed by
#     saf_query_tag_publishing_run_count (push, workflow_dispatch, schedule),
#     NOT a bare unfiltered "any event at all" query -- see that function's
#     own header for why a pull_request-triggered run must be excluded: its
#     github.sha is a synthetic merge commit, not <sha>, so it can never
#     have published the sha-<sha> tag this whole mechanism depends on,
#     regardless of what the Actions API's head_sha field reports for that
#     run. Treating a pull_request run as proof here would make the walk
#     wait out the full freshness ceiling against a tag a pull_request run
#     never produces, then give up (per saf_find_built_ancestor's own
#     JUDGMENT CALL) instead of correctly skipping past this candidate to an
#     older, genuinely push/dispatch/schedule-built ancestor.
#
# IMPORTANT SCOPING NOTE when called with "push": a "1" here means "no
# push-triggered run", not "this commit was never built by any means" --
# a non-push-triggered run for the exact same commit can independently exist
# and can have already produced a perfectly valid image, entirely regardless
# of whether a push-triggered run ever fired. This is why callers only ever
# consult this function (with "push") AFTER first trying the direct
# freshness/existence check against the commit's own image (see the exact-
# BASE_SHA wait in each caller) -- if that image already exists via any
# trigger, the direct check already succeeds and this function is never
# reached for that commit at all. A "1" is therefore never a false positive
# for "safe to fall back": it only ever fires once the commit's own image
# has already been confirmed unavailable by a real, direct check.
#
# Returns 0 if at least one matching run exists (regardless of conclusion --
# success, failure, or still in progress all count as "a real attempt
# happened"). Returns 1 ONLY when the query positively confirms zero
# matching runs -- the sole condition under which a caller may treat the
# commit as "no run of this kind was ever attempted". Returns 2 when the
# query itself could not be completed (GH_TOKEN unset, API error after
# retries, malformed response) -- deliberately NOT collapsed into "confirmed
# zero": this function's whole purpose (when checking the PR base commit
# specifically) is proving ABSENCE, and a failed query proves nothing about
# that. Every caller must treat 2 the same as 0 for that specific decision --
# collapsing 2 into "confirmed zero" would let a transient failure silently
# unlock a fallback path that requires positive proof.
#
# Indirection so tests can stub this without a real network call.
saf_base_commit_has_confirmed_run() {
  local repository="$1" sha="$2" event="${3-}"
  if [[ -n "${STAGING_BASE_BUILD_RUN_EXISTS_CMD:-}" ]]; then
    "$STAGING_BASE_BUILD_RUN_EXISTS_CMD" "$sha" "$event"
    return $?
  fi
  local run_count
  if [[ -n "$event" ]]; then
    run_count="$(saf_query_run_count "$repository" "$sha" "$event")" || return 2
  else
    run_count="$(saf_query_tag_publishing_run_count "$repository" "$sha")" || return 2
  fi
  if (( run_count == 0 )); then
    return 1
  fi
  return 0
}

# saf_find_built_ancestor <repository> <base_sha> <service> <search_depth> \
#     <freshness_timeout_seconds> <freshness_hard_ceiling_seconds> \
#     <freshness_poll_interval_seconds> [git_dir]
#
# Only meaningful to call once the caller has already confirmed <base_sha>'s
# own image is unavailable via a direct check. Walks <base_sha>'s own
# FIRST-PARENT ancestor history (nearest-first), bounded to <search_depth>
# commits, for the nearest ancestor that both has at least one recorded
# build-push.yml run (any event -- see saf_base_commit_has_confirmed_run's
# header for why non-push runs count here) and a freshness-confirmed
# per-commit image for <service> (reusing sif_wait_for_fresh_base_image,
# never skipping that proof).
#
# A candidate with zero recorded runs is not simply skipped in favor of an
# older one: exactly the same "zero runs alone does not prove a deliberate
# skip" reasoning saf_base_commit_paths_are_ignorable's own header documents
# for <base_sha> applies to every candidate walked here too. Before walking
# past a run-less candidate, this positively confirms that candidate's own
# changed paths also all match the ignore list; if that check is anything
# other than a positive confirmation (a real non-doc path, or an
# inconclusive diff), this stops and fails rather than silently substituting
# an older ancestor that could omit a real, unbuilt change at that
# candidate.
#
# A candidate whose run-check itself is INCONCLUSIVE (saf_base_commit_has_confirmed_run
# returns 2 -- GH_TOKEN unset, API error after retries, malformed response)
# is likewise never treated as safe to act on: it fails closed immediately,
# the same discipline BASE_SHA's own push-run check already applies. Falling
# through to the freshness check for an unconfirmed candidate would accept
# it as the resolved source purely because its image happens to satisfy
# sif_is_ancestor_or_equal, with no positive proof any build-push.yml run
# ever produced it -- exactly the missing proof this whole mechanism exists
# to require before substituting anything.
#
# `--first-parent`: this project does not squash-merge, so nearly every
# commit on a target branch is itself a merge commit. A plain `git log <sha>`
# walks EVERY parent of every merge commit it encounters, which can surface a
# built commit that only ever existed on a side/feature branch before
# reaching the actual previous target-branch state (<base_sha>^1). That
# side-branch commit's image does not represent "the target branch
# immediately before this commit" and can omit real target-branch changes --
# exactly the kind of stale-content risk this whole mechanism exists to
# avoid. `--first-parent` walks only the same first-parent chain
# saf_base_commit_diff_paths already uses, so "nearest built ancestor" and
# "what changed to get to this commit" stay consistent with each other.
#
# `--max-count=$((search_depth + 1))` at the `git log` SOURCE, piped through
# only `tail -n +2` (never `head`): piping `git log`'s output through
# `head -n N` under `set -o pipefail` is a real SIGPIPE hazard -- `head`
# closes its read end once it has read N lines, and the writer (`tail`, or
# `git log` itself) can be signaled SIGPIPE for writing to a closed pipe,
# which `pipefail` then reports as pipeline failure. A small bats fixture
# with fewer real ancestors than `search_depth` never exercises this path,
# but any `BASE_SHA` with more than `search_depth` ancestors -- the common
# case for a mature branch -- would abort this function before it examines a
# single real candidate, always reporting "no usable ancestor" even when a
# perfectly good one sits a few commits back. Bounding at the `git log`
# source with `--max-count` avoids ever needing to close the pipe early.
#
# JUDGMENT CALL (flagged for maintainer review, matching this project's own
# convention for calling these out explicitly -- see
# scripts/lib/staging-image-freshness.sh's own JUDGMENT CALL comment): if a
# run-bearing candidate's freshness proof itself fails (the run existed, but
# no confirmed-fresh image ever appeared within budget), this function stops
# and reports failure immediately; it does NOT keep walking further back.
# Stacking many bounded waits (each up to <freshness_hard_ceiling_seconds>)
# across up to <search_depth> candidates would be a worse failure mode than
# the structural problem this mechanism exists to solve, and reaching
# further and further back in history for a substitute risks the same
# stale-content class of bug this file exists to avoid. A commit with a
# real, seemingly-broken build is a genuine CI problem worth surfacing on
# its own, not a reason to keep hunting for an even older substitute.
#
# Echoes the confirmed-good ancestor's full commit SHA on stdout on success;
# returns non-zero with no output if no usable ancestor is found within the
# bounded depth. All human-readable diagnostic output goes to stderr, same
# discipline as sif_wait_for_fresh_base_image.
saf_find_built_ancestor() {
  local repository="$1" base_sha="$2" service="$3" search_depth="$4"
  local freshness_timeout_seconds="$5" freshness_hard_ceiling_seconds="$6"
  local freshness_poll_interval_seconds="$7"
  local git_dir="${8:-.}"
  # sif_wait_for_fresh_base_image (called below) delegates its own ancestry
  # check to sif_is_ancestor_or_equal, which reads STAGING_FRESHNESS_GIT_DIR
  # from the environment rather than taking a git_dir argument -- exporting
  # it here bridges this function's own explicit <git_dir> parameter through
  # to that mechanism, so a caller of THIS function never needs to know
  # about that env-var-based convention itself.
  export STAGING_FRESHNESS_GIT_DIR="$git_dir"

  local candidates
  candidates="$(git -C "$git_dir" log --first-parent --max-count=$((search_depth + 1)) --format=%H "$base_sha" 2>/dev/null | tail -n +2)" || return 1
  if [[ -z "$candidates" ]]; then
    return 1
  fi

  local candidate has_run ancestor_image candidate_paths_status
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue

    has_run=0
    # Empty event filter ("any event"): see saf_base_commit_has_confirmed_run's
    # own header for why non-push-triggered runs must count for an ancestor
    # candidate, unlike the stricter push-only check used for BASE_SHA itself.
    saf_base_commit_has_confirmed_run "$repository" "$candidate" "" || has_run=$?
    if (( has_run == 1 )); then
      # Positively confirmed zero runs of any kind for THIS candidate -- but
      # zero runs alone is not proof this candidate was itself a deliberate
      # skip, exactly the same reasoning saf_base_commit_paths_are_ignorable's
      # own header documents for BASE_SHA. A candidate with zero runs could
      # be a genuine, unbuilt service change (e.g. build-push.yml's push
      # trigger was temporarily disabled for that one push, or some other
      # real CI outage), and silently walking past it to substitute an
      # older, built ancestor would back-fill content that omits that real
      # change -- the exact #626/#808 class of bug this whole mechanism must
      # not reintroduce. So before skipping this candidate and continuing
      # further back, positively confirm ITS OWN changed paths also all
      # match the ignore list; only then is walking past it actually safe.
      candidate_paths_status=0
      saf_base_commit_paths_are_ignorable "$candidate" "$git_dir" || candidate_paths_status=$?
      if (( candidate_paths_status != 0 )); then
        echo "::error::Ancestor candidate $candidate (between $base_sha and its own ancestor history) has zero recorded build-push.yml runs, but its changed paths could not be positively confirmed to all match build-push.yml's own paths-ignore list (status $candidate_paths_status -- see this file's own header for why an inconclusive result must not be treated as safe either). Refusing to silently walk past it to an older substitute -- that could back-fill content omitting a real, unbuilt change at $candidate. This needs a maintainer look at $candidate's own build-push.yml history." >&2
        return 1
      fi
      continue
    fi
    if (( has_run == 2 )); then
      # Whether a run exists at all for this candidate could not be
      # positively determined (GH_TOKEN unset, API error after retries, a
      # malformed response) -- the same inconclusive outcome
      # saf_base_commit_has_confirmed_run's own header documents for
      # BASE_SHA's push-run check, and it must be handled with the same
      # "can't prove it, don't act on it" discipline here: falling through
      # to the freshness check below would accept this candidate as the
      # resolved source on nothing more than its image happening to satisfy
      # sif_is_ancestor_or_equal, with no positive proof a real
      # build-push.yml run ever produced it at all. Fail closed instead of
      # walking further or attempting the freshness check on an unconfirmed
      # candidate.
      echo "::error::Whether any build-push.yml run exists for ancestor candidate $candidate could not be positively determined (see the error above). Refusing to treat this candidate as usable without positive proof of a recorded run, and refusing to walk past it to an older substitute either -- failing closed rather than guessing." >&2
      return 1
    fi

    # has_run == 0 here: a build-push.yml run (any event) is positively
    # confirmed to exist for this candidate -- proceed to the freshness
    # check, the only remaining question being whether that run actually
    # produced a confirmed-fresh image for <service>.
    ancestor_image="ghcr.io/${repository}/${service}:sha-${candidate:0:7}"
    # Deliberately NOT redirecting stderr here (only stdout): the
    # ::notice::/::warning::/::error:: diagnostic lines
    # sif_wait_for_fresh_base_image writes to stderr must still reach the job
    # log even though this function's own stdout is captured by its caller
    # via `$(...)`.
    if sif_wait_for_fresh_base_image "$ancestor_image" "$candidate" "$service" \
      "$freshness_timeout_seconds" "$freshness_hard_ceiling_seconds" "$freshness_poll_interval_seconds" >/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi

    # Found a run-bearing candidate whose image never became confirmed-fresh
    # -- per the JUDGMENT CALL above, stop here instead of walking further
    # back.
    return 1
  done <<< "$candidates"

  return 1
}

# saf_resolve_untouched_backfill_source <repository> <service> <base_sha> \
#     <base_freshness_timeout_seconds> <base_freshness_hard_ceiling_seconds> \
#     <ancestor_freshness_timeout_seconds> <ancestor_freshness_hard_ceiling_seconds> \
#     <freshness_poll_interval_seconds> <ancestor_search_depth> [git_dir]
#
# The single shared orchestrator both callers (scripts/ensure-pr-staging-images.sh
# and build-push.yml's own "Ensure PR staging tags exist for full-setup
# services" step) use to decide what to back-fill an untouched service's PR
# staging tag from. Neither caller reimplements this decision independently:
# both need the identical exact-BASE_SHA wait, the identical positive-proof
# gate before any fallback, and the identical bounded ancestor walk, so a
# workflow/deploy-changing PR based on a never-built commit must not hit an
# unwinnable wait in one caller's job while the other caller has already
# been fixed -- reimplementing this logic a second time anywhere is a defect
# in itself, not just a maintenance inconvenience.
#
# TWO SEPARATE budget pairs on purpose, not one shared pair:
#   - <base_freshness_timeout_seconds>/<base_freshness_hard_ceiling_seconds>
#     govern ONLY the wait against BASE_SHA's own image (the NORMAL PATH,
#     step 2 below). This is the one wait in this whole mechanism that can
#     legitimately be racing a real, still-building push run -- exactly the
#     scenario a confirmed push-triggered run (pre_run_status/post_run_status
#     == 0 below) describes -- so it needs the same congestion-scale headroom
#     wait_for_touched_image() in scripts/ensure-pr-staging-images.sh already
#     gets for the identical reason, not a short ceiling tuned for "this
#     should already exist or never will".
#   - <ancestor_freshness_timeout_seconds>/<ancestor_freshness_hard_ceiling_seconds>
#     govern ONLY saf_find_built_ancestor's per-candidate checks (both the
#     fast-path and step-3 call sites below). An ancestor candidate is, by
#     construction, a commit further back in history than BASE_SHA that
#     saf_base_commit_has_confirmed_run already confirmed has a REAL recorded
#     run -- if that run's image doesn't already exist by the time this
#     mechanism looks, it never will (there is no "still building" case for a
#     commit further in the past than one already checked), so a short ceiling
#     here is a deliberate tuning choice, not a correctness gap.
#   Collapsing these into one shared pair is a real failure mode, not a
#   theoretical one: a short ceiling tuned for "an already-checked historical
#   ancestor commit's image either exists now or never will" is far too short
#   for BASE_SHA's own wait, where a confirmed push-triggered run can still
#   legitimately be mid-build -- applying the short ceiling there would
#   hard-fail this gate on a perfectly healthy, still-running build, which is
#   strictly worse than the "unwinnable wait on a never-built base commit"
#   bug this whole file exists to fix.
#
# Sequence:
#   1. FAST PATH (reordering): before running the full bounded freshness
#      wait, check whether
#      BASE_SHA can already be POSITIVELY confirmed as a deliberate skip --
#      both that its changed paths all match the ignore-list
#      (saf_base_commit_paths_are_ignorable) AND that no push-triggered run
#      exists for it (saf_base_commit_has_confirmed_run, event=push). Only
#      when BOTH are true does this skip the long wait: try one single,
#      non-polling existence/freshness attempt against BASE_SHA's own image
#      first (a non-push trigger may already have produced a valid image for
#      this exact commit despite the confirmed absence of a push run -- see
#      saf_base_commit_has_confirmed_run's own scoping note), and only if
#      that also comes up empty, go straight to the ancestor walk. This
#      turns a never-going-to-build base commit into a fast, seconds-scale
#      failure/fallback instead of waiting out the full freshness ceiling
#      first for no reason.
#   2. NORMAL PATH: whenever the fast path's preconditions are not BOTH
#      confirmed (a run exists, the run-check is inconclusive, the paths
#      check is inconclusive, or not every path matches the ignore-list),
#      run the full bounded sif_wait_for_fresh_base_image wait exactly as
#      before. This is the conservative default: it is what actually
#      protects the #626/#808 fail-closed property for a real, in-flight, or
#      broken build, and for a paths-check that could not positively rule
#      out a genuine service change riding along with the docs change.
#   3. POST-WAIT DECISION: if the normal wait fails, re-derive (independently
#      of whatever the fast path found, so a fast-path bug can only cost
#      time, never safety) whether BASE_SHA has a confirmed push run and
#      whether its paths are confirmed ignorable. Only when a push run is
#      positively confirmed ABSENT and the paths are positively confirmed
#      ignorable does this proceed to the ancestor walk; any other outcome
#      (a run exists, either check is inconclusive, or a real path was
#      found) preserves today's strict failure with no fallback attempted.
#
# Echoes the resolved source image ref (e.g.
# ghcr.io/org/repo/service:sha-abc1234) on stdout on success -- this may be
# BASE_SHA's own image (the common case) or a substituted ancestor's image
# (the fallback case). All human-readable diagnostic output goes to stderr.
# Returns 0 on success, 1 on fail-closed (the caller must not back-fill
# anything and must treat this as a hard failure for the service, exactly as
# before this mechanism existed).
saf_resolve_untouched_backfill_source() {
  local repository="$1" service="$2" base_sha="$3"
  local base_freshness_timeout_seconds="$4" base_freshness_hard_ceiling_seconds="$5"
  local ancestor_freshness_timeout_seconds="$6" ancestor_freshness_hard_ceiling_seconds="$7"
  local freshness_poll_interval_seconds="$8" ancestor_search_depth="$9"
  local git_dir="${10:-.}"
  # See saf_find_built_ancestor's own comment for why this export is needed:
  # sif_wait_for_fresh_base_image (called directly below, and indirectly via
  # saf_find_built_ancestor) reads STAGING_FRESHNESS_GIT_DIR from the
  # environment, not a parameter.
  export STAGING_FRESHNESS_GIT_DIR="$git_dir"

  local base_sha_short="${base_sha:0:7}"
  local base_image="ghcr.io/${repository}/${service}:sha-${base_sha_short}"
  local ancestor_sha

  # Step 1: fast-path pre-check (see this function's own header). Both
  # conditions must be independently confirmed before skipping the long
  # wait; a failure or inconclusive result on EITHER falls through to the
  # normal (slow, but always-safe) path below unchanged.
  local fast_path_confirmed_zero=false
  local pre_paths_status=0
  saf_base_commit_paths_are_ignorable "$base_sha" "$git_dir" || pre_paths_status=$?
  if (( pre_paths_status == 0 )); then
    local pre_run_status=0
    saf_base_commit_has_confirmed_run "$repository" "$base_sha" "push" || pre_run_status=$?
    if (( pre_run_status == 1 )); then
      fast_path_confirmed_zero=true
    fi
  fi

  if [[ "$fast_path_confirmed_zero" == true ]]; then
    echo "::notice::$base_sha has no push-triggered build-push.yml run, and every path it changed matches build-push.yml's own push paths-ignore -- skipping the long freshness wait for $service and checking directly for a usable image instead." >&2
    # Single non-polling attempt (0/0 budget): a non-push trigger may
    # already have produced a valid image for this exact commit despite the
    # confirmed absence of a push run (see saf_base_commit_has_confirmed_run's
    # own scoping note) -- worth one direct check before assuming the
    # ancestor walk is needed at all. If it's not already there, waiting
    # longer cannot help: no push run exists, and the paths are confirmed
    # ignorable, so there is no in-flight push build to wait out.
    if sif_wait_for_fresh_base_image "$base_image" "$base_sha" "$service" 0 0 "$freshness_poll_interval_seconds" >/dev/null; then
      printf '%s\n' "$base_image"
      return 0
    fi
    if ! ancestor_sha="$(saf_find_built_ancestor "$repository" "$base_sha" "$service" "$ancestor_search_depth" \
      "$ancestor_freshness_timeout_seconds" "$ancestor_freshness_hard_ceiling_seconds" "$freshness_poll_interval_seconds" "$git_dir")"; then
      echo "::error::No usable ancestor of $base_sha was found within $ancestor_search_depth commits with both a recorded build-push.yml run and a freshness-confirmed $service image. Refusing to back-fill $service's PR staging tag -- this needs a maintainer look at $base_sha's own ancestor history." >&2
      return 1
    fi
    echo "::notice::Substituting nearest built ancestor $ancestor_sha for base commit $base_sha ($service was never built for $base_sha itself). (re)pointing at ghcr.io/${repository}/${service}:sha-${ancestor_sha:0:7}, its own immutable per-commit tag -- never the mutable nightly/latest channel." >&2
    printf '%s\n' "ghcr.io/${repository}/${service}:sha-${ancestor_sha:0:7}"
    return 0
  fi

  # Step 2: normal path -- the full bounded wait against BASE_SHA's own
  # image, unchanged from this mechanism's pre-fallback behavior. Uses the
  # LONG (base_freshness_*) budget deliberately -- see this function's own
  # header for why this specific wait, unlike the ancestor-candidate checks,
  # needs congestion-scale headroom.
  echo "::notice::$service is untouched by this PR; waiting for its PR-base per-commit image ($base_image) to exist and be confirmed built at $base_sha before backfilling..." >&2
  if sif_wait_for_fresh_base_image "$base_image" "$base_sha" "$service" \
    "$base_freshness_timeout_seconds" "$base_freshness_hard_ceiling_seconds" "$freshness_poll_interval_seconds" >/dev/null; then
    printf '%s\n' "$base_image"
    return 0
  fi

  # Step 3: post-wait decision -- re-derive both statuses independently of
  # the fast-path pre-check above (a stale/incorrect fast-path result must
  # never be able to unlock the fallback; only a fresh, positive
  # confirmation right here does).
  local post_run_status=0
  saf_base_commit_has_confirmed_run "$repository" "$base_sha" "push" || post_run_status=$?
  if (( post_run_status == 0 )); then
    echo "::error::Refusing to back-fill $service's PR staging tag from $base_image -- its base commit could not be confirmed fresh enough (see the error above), AND a push-triggered build-push.yml run does exist for $base_sha (so this is a real build problem, not an unbuildable commit -- no ancestor fallback applies here). Silently validating a stale base-channel image here is exactly the #626/#808 bug this mechanism must not reintroduce." >&2
    return 1
  fi
  if (( post_run_status == 2 )); then
    echo "::error::Refusing to back-fill $service's PR staging tag from $base_image -- its base commit could not be confirmed fresh enough, and whether build-push.yml ever ran for $base_sha on a push event could not be positively determined either (see above). Failing closed rather than assuming the ancestor-fallback path is safe." >&2
    return 1
  fi

  local post_paths_status=0
  saf_base_commit_paths_are_ignorable "$base_sha" "$git_dir" || post_paths_status=$?
  if (( post_paths_status != 0 )); then
    echo "::error::Refusing to back-fill $service's PR staging tag from $base_image -- its base commit could not be confirmed fresh enough, and its changed paths could not be positively confirmed to all match build-push.yml's own push paths-ignore list either (see this file's own header for why that distinction matters). Failing closed rather than assuming the ancestor-fallback path is safe -- a real, non-doc change riding along with this commit must not be silently skipped." >&2
    return 1
  fi

  echo "::notice::$base_sha has no push-triggered build-push.yml run, and every path it changed matches build-push.yml's own push paths-ignore -- not a broken build. Searching up to $ancestor_search_depth ancestor commits for the nearest one with both a recorded build-push.yml run and a freshness-confirmed $service image to back-fill from instead." >&2
  if ! ancestor_sha="$(saf_find_built_ancestor "$repository" "$base_sha" "$service" "$ancestor_search_depth" \
    "$ancestor_freshness_timeout_seconds" "$ancestor_freshness_hard_ceiling_seconds" "$freshness_poll_interval_seconds" "$git_dir")"; then
    echo "::error::No usable ancestor of $base_sha was found within $ancestor_search_depth commits with both a recorded build-push.yml run and a freshness-confirmed $service image. Refusing to back-fill $service's PR staging tag -- this needs a maintainer look at $base_sha's own ancestor history." >&2
    return 1
  fi
  echo "::notice::Substituting nearest built ancestor $ancestor_sha for base commit $base_sha ($service was never built for $base_sha itself). (re)pointing at ghcr.io/${repository}/${service}:sha-${ancestor_sha:0:7}, its own immutable per-commit tag -- never the mutable nightly/latest channel." >&2
  printf '%s\n' "ghcr.io/${repository}/${service}:sha-${ancestor_sha:0:7}"
  return 0
}
