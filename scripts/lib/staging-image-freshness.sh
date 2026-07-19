#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# #808: shared "is this base-channel image actually fresh enough to validate
# an untouched service against" check. scripts/ensure-pr-staging-images.sh
# (full-setup-deep-validate.yml) and build-push.yml's own "Ensure PR staging
# tags exist for full-setup services" step both back-fill any full-setup
# service a PR did NOT touch by re-pointing that PR's staging tag at whatever
# the base channel (dev/nightly/latest) resolves to AT THE MOMENT THE JOB RUNS --
# with no check that the base branch's own post-merge build for the exact
# base commit has actually finished. Confirmed live (#808): PRs #911/#914 each
# backfilled `dns` from a `dev` tag that was still ~41 minutes stale relative
# to their own `base.sha`, because another PR's build+scan+promote pipeline
# for a newer base-branch commit was still in flight when the backfill ran.
#
# The fix: read the `org.opencontainers.image.revision` OCI label off the
# base-channel image (set by docker/metadata-action's default label set in
# build-push.yml's "Extract metadata" step -- see that step; the custom
# `labels:` input there only overrides `.description`, so the default
# `.revision=<github.sha>` label is untouched) and confirm, via real git
# ancestry, that the commit it was built from is at or after the PR's own
# `base.sha`. Labels live in the image config blob, which `docker buildx
# imagetools create` (used by both `promote` and this back-fill) copies
# byte-for-byte when moving a tag -- retagging never rewrites them, so the
# label on a `dev`/`nightly`/`latest` tag always reflects the real commit that
# channel image's underlying build actually compiled.
#
# Pure-ish functions (one intentional side effect: sif_image_revision shells
# out to the registry). Sourced directly by scripts/ensure-pr-staging-images.sh
# and by build-push.yml's "Ensure PR staging tags exist for full-setup
# services" step (via "$GITHUB_WORKSPACE/scripts/lib/staging-image-freshness.sh",
# the same sourcing convention scripts/lib/ghcr-retry.sh already uses for the
# identical script-vs-workflow-step dual-caller situation) so the freshness
# rule is defined in exactly one place instead of drifting between a script
# and an inline YAML `run:` block -- the SOURCE OF TRUTH NOTE at the top of
# ensure-pr-staging-images.sh already flags that hand-kept-in-sync duplication
# as a known risk for the touched-vs-untouched decision; this file avoids
# repeating that mistake for the new freshness check.
#
# Deliberately NOT `set -euo pipefail` at the top level, for the same reason
# ghcr-retry.sh isn't: this file only defines functions for a caller to invoke
# under the caller's own shell options.

# sif_image_revision <image>
#
# Echoes the full git commit SHA the image at <image> was built from (its
# org.opencontainers.image.revision label), or returns non-zero with no
# output if the image doesn't exist, the registry call fails, or the label is
# absent.
#
# EVERY full-setup service's dev/nightly/latest/pr-<N>-sha-<short> tag is a
# multi-platform OCI index (amd64+arm64, combined by merge-manifests) --
# confirmed live against ghcr.io/wiki-mod/lancache-ng/dns:dev via the plain
# registry HTTP API while building this fix: its manifest has a top-level
# "manifests" array, not a "config" object. `docker buildx imagetools
# inspect --format '{{.Image...}}'` only populates `.Image` for a genuinely
# single-platform manifest -- scripts/require-image-platforms.sh's own
# `{{if .Image}}...{{end}}` guard exists for exactly this reason (that
# script's images happen to be amd64-only single manifests today, so the
# guard is usually true there, but it would be EMPTY for a real
# multi-platform index like the ones this function reads). Relying on
# `.Image` directly against a multi-platform tag would make
# sif_image_revision silently fail to read a real, present label on every
# real invocation -- turning this whole #808 fix into an unconditional
# poll-then-fail-closed on every PR. So this resolves the index down to one
# specific platform's manifest DIGEST first (`repo@sha256:...`, not a tag),
# which is unambiguous and DOES populate `.Image` via `--format` (confirmed
# against the real per-platform manifest+config blob for the same tag).
# Every platform built by the same build-push.yml run for the same commit
# carries an identical revision label (build/build-arm64 both stamp the same
# docker/metadata-action labels for the same github.sha -- see that
# workflow's "Extract metadata" step), so which platform is picked does not
# matter; the first `"digest"` found in the raw index is used -- today that
# is always the first real amd64/arm64 platform entry (confirmed against the
# real dev index), on the assumption that every entry in the index is a real
# platform manifest. If this project ever enables inline buildx provenance/
# SBOM attestations, the index would additionally carry attestation
# manifests (`platform: unknown/unknown`) ahead of or alongside the platform
# ones, and this could grab an attestation digest instead of a real platform
# manifest's. That is not a silent-pass risk either way: an attestation
# manifest's config has no org.opencontainers.image.revision label, so the
# second inspect call below would still just report "no label" and this
# function fails the same way it already does for any other missing-label
# case -- fail-closed (poll, then error), never a false "fresh".
#
# Deliberately does NOT use jq for this: build-push.yml's own coverage-badge
# step explicitly refuses bare host jq ("Coverage merge must use the
# selected build-tools image instead of bare host jq/bc", issue #566) and
# always runs jq inside the pinned build-tools container instead --
# self-hosted runners are not assumed to have jq (AG-CI-001/AG-VAL-017 list
# the build-tools image's bundled tools, and jq is not among them). Wrapping
# this registry read in a full `docker run ... build-tools ...` invocation
# just to get jq would be a much larger change than this fix's scope, so
# `--raw`'s JSON is parsed with grep/sed against the narrow, verified shape
# above (a top-level "manifests" array vs. a top-level "config" object)
# instead.
#
# Indirection so tests (and callers without a real registry) can stub this.
sif_image_revision() {
  local image="${1:?sif_image_revision: image is required}"
  local revision
  if [[ -n "${STAGING_IMAGE_REVISION_CMD:-}" ]]; then
    revision="$("$STAGING_IMAGE_REVISION_CMD" "$image")" || return 1
  else
    local raw target digest
    raw="$(docker buildx imagetools inspect "$image" --raw 2>/dev/null)" || return 1
    target="$image"
    if printf '%s' "$raw" | grep -q '"manifests"[[:space:]]*:'; then
      digest="$(printf '%s' "$raw" \
        | grep -o '"digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-f]\{64\}"' \
        | head -1 \
        | sed -E 's/.*"(sha256:[0-9a-f]+)"/\1/')"
      if [[ -z "$digest" ]]; then
        return 1
      fi
      # Repo-without-tag + "@digest": images in this project never use a
      # registry host with an explicit port, so the LAST colon in $image is
      # always the tag separator and safe to strip this way.
      target="${image%:*}@${digest}"
    fi
    revision="$(docker buildx imagetools inspect "$target" \
      --format '{{index .Image.Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null)" || return 1
  fi
  # A missing label renders as the literal string "<no value>" in a Go
  # template (index on a nil/short map doesn't error, it just yields the
  # zero value) rather than failing the command -- treat that the same as
  # "no label at all" instead of accidentally treating the literal text
  # "<no value>" as a commit SHA.
  if [[ -z "$revision" || "$revision" == "<no value>" ]]; then
    return 1
  fi
  printf '%s\n' "$revision"
}

# sif_is_ancestor_or_equal <base_sha> <candidate_sha>
#
# Returns 0 if <base_sha> is <candidate_sha> itself or an ancestor of it (i.e.
# the image built at <candidate_sha> was built from a commit at or after
# <base_sha>) -- the exact question #808 needs answered. Returns 1 if
# <candidate_sha> is older (stale). Returns 2 -- distinct from "stale" -- if
# <base_sha> itself is not present in the local git history at all: <base_sha>
# is this PR's own base commit, known from the very start (before the
# checkout even ran), so its absence means the CALLER'S checkout is
# genuinely misconfigured (needs `fetch-depth: 0`, same as
# scripts/classify-image-impact.sh and detect-full-setup-changes.sh already
# require for their own merge-base diffs) -- a caller should fail immediately
# on 2 instead of polling, since no amount of waiting fixes a shallow clone.
#
# <candidate_sha> (the base-channel image's build commit) is treated
# differently: it can legitimately be a commit that landed on the base
# branch AFTER this job's own checkout ran (exactly the #808 race -- another
# PR's merge+promote finishing mid-poll), so it may genuinely not be in the
# checkout's object database YET even though the checkout itself is perfectly
# fine. Before giving up, this does ONE recovery `git fetch` (no refspec
# argument -- reuses whatever refspec the checkout already configured, which
# for a fetch-depth: 0 checkout covers `+refs/heads/*:refs/remotes/origin/*`;
# confirmed live against a disposable bare remote while building this fix
# that a plain `git fetch origin` after such a clone does pick up a commit
# pushed to the remote afterward) and retries once. If <candidate_sha> is
# STILL missing after that, returns 3 -- NOT the same as 2 -- so the caller
# treats it as "not resolvable yet" (keep polling, bounded by its own
# ceiling) rather than a hard configuration failure.
#
# Honors STAGING_FRESHNESS_GIT_DIR (default ".") so tests can point this at a
# disposable git repo with synthetic commits instead of the real project
# history -- production callers never set it, since they always run with cwd
# already at the checked-out repo root (see full-setup-deep-validate.yml's
# and build-push.yml's own checkout steps).
sif_is_ancestor_or_equal() {
  local base_sha="${1:?sif_is_ancestor_or_equal: base_sha is required}"
  local candidate_sha="${2:?sif_is_ancestor_or_equal: candidate_sha is required}"
  local git_dir="${STAGING_FRESHNESS_GIT_DIR:-.}"

  if ! git -C "$git_dir" cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
    echo "::error::Base commit $base_sha is not present in the local git history. This check requires a full-history checkout (fetch-depth: 0); a shallow checkout cannot prove commit ancestry." >&2
    return 2
  fi
  if ! git -C "$git_dir" cat-file -e "${candidate_sha}^{commit}" 2>/dev/null; then
    echo "Base-channel image's build commit $candidate_sha is not yet in the local git history; attempting one recovery fetch (it may have landed on the base branch after this job's own checkout)." >&2
    git -C "$git_dir" fetch --no-tags --quiet origin >/dev/null 2>&1 || true
    if ! git -C "$git_dir" cat-file -e "${candidate_sha}^{commit}" 2>/dev/null; then
      echo "$candidate_sha is still not present in the local git history after the recovery fetch." >&2
      return 3
    fi
  fi
  git -C "$git_dir" merge-base --is-ancestor "$base_sha" "$candidate_sha"
}

# sif_wait_for_fresh_base_image <base_image> <base_sha> <service_label> <normal_budget_seconds> <hard_ceiling_seconds> <poll_interval_seconds>
#
# Polls <base_image>'s org.opencontainers.image.revision label until it is at
# or after <base_sha> (see sif_is_ancestor_or_equal), echoing the confirmed
# commit on success. Bounded: <normal_budget_seconds> is the quiet baseline
# (no extra logging), <hard_ceiling_seconds> is the absolute cutoff (must be
# >= <normal_budget_seconds>; the caller is expected to clamp this the same
# way ensure-pr-staging-images.sh already clamps its own touched-image
# ceiling). Returns 1 on a normal "still stale at the hard ceiling" timeout,
# 2 if sif_is_ancestor_or_equal ever reports base_sha itself is missing (a
# checkout/config problem -- fails immediately, see that function's own
# comment for why polling cannot fix it). A candidate_sha that is merely
# not-yet-fetched (status 3 from sif_is_ancestor_or_equal) is treated the
# same as ordinary staleness here, not as a hard failure -- see that
# function's own comment for why the two must not be conflated.
#
# All human-readable progress/diagnostic output goes to stderr (`>&2`).
# Only the confirmed-fresh commit SHA (on success) is written to stdout, so a
# caller that captures this function's output via `$(...)` (as both real
# call sites do, to get the confirmed revision) does not lose every
# ::notice::/::warning::/::error:: line the way it would if this function
# mixed log lines into stdout and the caller discarded stdout with
# `>/dev/null` (as both real call sites also do, since they only want the
# revision when they explicitly ask for it, not always) -- ghcr-retry.sh's
# own `ghcr_relogin` comment documents the same stdout/stderr discipline for
# the same reason.
#
# JUDGMENT CALL (flagged for maintainer review, not guessed silently): this
# deliberately does NOT reuse wait_for_touched_image()'s exact
# congestion-probe shape (#895: "is build-push's OWN run for this commit
# still active, and if it already finished without producing the tag, fail
# immediately instead of idling"). That shortcut relies on there being
# exactly one specific, already-triggered run to ask about (the PR's own
# build-push run for its own build_sha, which starts at roughly the same
# time as the caller). Here there is no single such run: the base channel can
# be stale because ANOTHER PR's build+scan+promote pipeline for some newer
# base-branch commit is mid-flight (the exact #808 scenario), or because that
# pipeline hasn't even been scheduled yet at the moment this check first
# runs -- "no matching run is currently active" does NOT reliably prove
# "nothing will ever fix this" the way it does for the touched-image case, so
# a fail-fast-on-inactive branch here would risk false-failing a case that
# would have resolved itself moments later. This function therefore always
# waits out the full bounded window (bounded still, per this project's
# require-a-finite-ceiling rule -- see AGENTS.md "Required Validation" and
# the touched-image ceiling comment above), it just does not shortcut early
# on an inactive-run signal. Revisit if this proves to make failures slower
# to surface than desired in practice.
sif_wait_for_fresh_base_image() {
  local base_image="${1:?sif_wait_for_fresh_base_image: base_image is required}"
  local base_sha="${2:?sif_wait_for_fresh_base_image: base_sha is required}"
  local service_label="${3:?sif_wait_for_fresh_base_image: service_label is required}"
  local normal_budget_seconds="${4:?sif_wait_for_fresh_base_image: normal_budget_seconds is required}"
  local hard_ceiling_seconds="${5:?sif_wait_for_fresh_base_image: hard_ceiling_seconds is required}"
  local poll_interval_seconds="${6:?sif_wait_for_fresh_base_image: poll_interval_seconds is required}"

  local start_time=$SECONDS
  local hard_deadline=$((start_time + hard_ceiling_seconds))
  local warned_past_budget=false
  local revision="" ancestor_status

  while true; do
    if revision="$(sif_image_revision "$base_image")"; then
      set +e
      sif_is_ancestor_or_equal "$base_sha" "$revision"
      ancestor_status=$?
      set -e
      if (( ancestor_status == 0 )); then
        echo "::notice::$service_label base image ($base_image) was built from commit $revision, which is at or after base commit $base_sha (waited $((SECONDS - start_time))s). Safe to back-fill from." >&2
        printf '%s\n' "$revision"
        return 0
      fi
      if (( ancestor_status == 2 )); then
        echo "::error::$service_label base image ($base_image) freshness could not be determined due to a git-history/checkout problem (see the error above). Failing immediately -- this is a configuration bug, not staleness, and no amount of waiting fixes it." >&2
        return 2
      fi
      if (( ancestor_status == 3 )); then
        echo "$service_label base image ($base_image) was built from commit $revision, which could not yet be resolved in local git history even after a recovery fetch (elapsed $((SECONDS - start_time))s) -- treating this the same as staleness for now, not as a hard failure." >&2
      else
        echo "$service_label base image ($base_image) was built from commit $revision, which predates base commit $base_sha (elapsed $((SECONDS - start_time))s)." >&2
      fi
    else
      echo "$service_label base image ($base_image) has no readable org.opencontainers.image.revision label yet (elapsed $((SECONDS - start_time))s) -- either it does not exist at all yet (e.g. first build ever for this channel) or the registry call failed transiently." >&2
    fi

    if (( SECONDS >= hard_deadline )); then
      echo "::error::$service_label base image ($base_image) never became fresh enough (built from a commit at or after $base_sha) within the ${hard_ceiling_seconds}s hard ceiling. Refusing to back-fill from a base-channel image that cannot be confirmed to include this PR's own base commit -- that is exactly the #808 stale-backfill bug this check exists to stop. Check whether the base branch's own Build & Push pipeline for a commit at or after $base_sha has finished (or started at all)." >&2
      return 1
    fi

    if (( SECONDS - start_time >= normal_budget_seconds )) && [[ "$warned_past_budget" == false ]]; then
      echo "::warning::$service_label base image ($base_image) has not become fresh enough within the normal ${normal_budget_seconds}s budget; continuing to wait up to the ${hard_ceiling_seconds}s hard ceiling. This is expected while the base branch's own build+scan+promote pipeline for a newer commit is still in flight (#808) -- see that base branch's Build & Push runs if this persists." >&2
      warned_past_budget=true
    fi

    sleep "$poll_interval_seconds"
  done
}
