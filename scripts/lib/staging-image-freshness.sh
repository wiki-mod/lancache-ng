#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# #808: shared "is this back-fill source image actually fresh enough to
# validate an untouched service against" check. scripts/untracked/ensure-pr-staging-images.sh
# (full-setup-deep-validate.yml) and build-push.yml's own "Ensure PR staging
# tags exist for full-setup services" step both back-fill any full-setup
# service a PR did NOT touch by re-pointing that PR's staging tag at a source
# image, with no check (originally) that the source's own post-merge build
# for the exact base commit had actually finished. Confirmed live (#808): PRs
# #911/#914 each backfilled `dns` from a `dev` channel tag that was still ~41
# minutes stale relative to their own `base.sha`, because another PR's
# build+scan+promote pipeline for a newer base-branch commit was still in
# flight when the backfill ran.
#
# The fix: read the `org.opencontainers.image.revision` OCI label off the
# source image (set by docker/metadata-action's default label set in
# build-push.yml's "Extract metadata" step -- see that step; the custom
# `labels:` input there only overrides `.description`, so the default
# `.revision=<github.sha>` label is untouched) and confirm, via real git
# ancestry, that the commit it was built from is at or after the PR's own
# `base.sha`. Labels live in the image config blob, which `docker buildx
# imagetools create` (used by both `promote` and this back-fill) copies
# byte-for-byte when moving a tag -- retagging never rewrites them, so the
# label always reflects the real commit the image's underlying build actually
# compiled.
#
# CALL-SITE HISTORY: originally (#808) both real callers passed a mutable
# channel tag (`dev`/`nightly`/`latest`) as `base_image`, so this ancestry
# check answered a genuine ">= base.sha" question against a moving target.
# Since #1254/#1255 (2026-07-25, nightly decoupled from current_dev push),
# both callers instead pass the PR base commit's own durable per-commit
# `sha-<short>` image -- the check now normally resolves to an exact equality
# rather than a real ">"; it is kept rather than simplified to a bare
# existence probe because it still doubles as the bounded poll for the #808
# race (that base-commit image may not have been pushed yet) and still
# guards against a corrupted/mislabeled image reporting the wrong revision.
# This function itself is agnostic to which kind of tag `base_image` is --
# only its callers' choice of tag changed.
#
# Pure-ish functions (one intentional side effect: sif_image_revision shells
# out to the registry). Sourced directly by scripts/untracked/ensure-pr-staging-images.sh
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
# single-platform manifest -- scripts/untracked/require-image-platforms.sh's own
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

# _sif_inspect_failure_is_confirmed_absence <stderr_text>
#
# Classifies a failed `docker buildx imagetools inspect` invocation's own
# stderr text as either "the registry positively confirmed no such
# manifest/tag/digest exists" (returns 0) or "everything else" (returns 1 --
# network/DNS/TLS timeout, a stalled connection, a 5xx, a rate limit, an auth
# failure, `docker` itself missing from PATH, or any other shape this hasn't
# seen yet). `docker buildx imagetools inspect` (backed by BuildKit's own
# registry client) reports a missing manifest/tag/digest as "manifest
# unknown" (the distribution-spec error code name, verified against
# docker/buildx's own issue tracker and multiple independent troubleshooting
# writeups for this exact command) or "no such manifest" -- both
# registry-level, not connection-level, so they only ever appear once a
# response was actually received and parsed, unlike a timeout/DNS/TLS/5xx
# failure, which reports its own distinct wording (e.g. "context deadline
# exceeded", "connection refused", "i/o timeout", "500 Internal Server
# Error").
#
# Deliberately does NOT match a bare "not found": AG-CI-001 requires
# assuming self-hosted runners do not provide project tooling, and
# scripts/untracked/ensure-pr-staging-images.sh (one of this file's two real callers)
# runs directly on a bare `lancache-light` runner, not inside the pinned
# build-tools image -- so `docker` itself being absent from PATH is a real,
# reachable failure mode here, and its shell-level error ("docker: command
# not found" / "bash: docker: command not found") also contains the
# substring "not found". Matching that as a confirmed registry absence would
# have this function tell a job log the registry positively confirmed
# something it was never even asked, which is a worse failure than the
# original ambiguous wording this whole classifier exists to improve on.
# Anchoring to "manifest"/"no such manifest"/NAME_UNKNOWN, or to buildx's own
# `^ERROR: ...: not found$` line shape (see the dedicated comment right above
# that alternative in the pattern below), keeps the match specific to an
# actual registry response instead of any shell-level "not found" text.
#
# What: Added a 4th alternative, `^ERROR:.*: not found$`.
# Why: buildx's real wording for a missing GHCR tag is `ERROR: <ref>: not
# found`, not "manifest unknown" -- verified live on two real buildx builds;
# this misclassification made every touched-service wait hard-fail at ~95s.
# From: Issue #1581
#
# Deliberately conservative in the other direction too: text this hasn't
# seen before falls through to "everything else" (return 1, the original
# ambiguous wording) rather than being guessed as either -- this is a
# diagnostic-accuracy improvement for the cases it CAN classify, not a claim
# that every failure shape is now enumerated; matches this project's own
# posture elsewhere for a similarly single-purpose classifier
# (saf_query_run_count's own header documents the same "specific known
# failure text -> permanent, everything else -> retry" split for HTTP
# 401/404).
#
# `-i`: registries and BuildKit versions have been observed to vary the exact
# capitalization ("Manifest Unknown" from some proxying registries per the
# search evidence gathered while writing this). Here-string, not a live pipe
# (issue #1377's own repo-wide SIGPIPE audit) -- moot for `grep -q` against an
# already-captured variable, but kept for consistency with every other
# grep-against-captured-text call in this file.
_sif_inspect_failure_is_confirmed_absence() {
  local stderr_text="$1"
  # `name[ _]unknown`: the distribution-spec error CODE is NAME_UNKNOWN
  # (underscore, all-caps), but a human-readable message wrapping it can
  # render the same words space-separated -- match both rather than only the
  # shape this project has actually observed so far.
  # `^ERROR:.*: not found$`: buildx's own real wording for a missing GHCR
  # tag/manifest (see the comment above) -- anchored to buildx's
  # "ERROR: " line prefix, never matching a bare shell "command not found".
  grep -qi 'manifest unknown\|no such manifest\|name[ _]unknown\|^ERROR:.*: not found$' <<<"$stderr_text"
}

# _sif_inspect_attempt <err_file> <args...>
#
# One single, unwrapped `docker buildx imagetools inspect "$@"` attempt --
# the actual command _sif_inspect below hands to ghcr_retry so retries can
# re-run exactly this and nothing more. Writes stdout on success. On
# failure, classifies its own stderr (captured in <err_file>, overwritten
# fresh on every attempt so the caller always sees the LAST attempt's text)
# via _sif_inspect_failure_is_confirmed_absence: a confirmed registry
# absence ("manifest unknown" and friends) exits with
# GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE so ghcr_retry stops immediately
# instead of burning its full retry budget on a manifest that positively
# does not exist (retrying cannot make a real 404 not-exist); everything
# else (network/timeout/rate-limit/auth/unrecognized) returns a plain 1,
# which ghcr_retry treats as retryable.
_sif_inspect_attempt() {
  local err_file="$1"
  shift
  local out status
  out="$(docker buildx imagetools inspect "$@" 2>"$err_file")"
  status=$?
  if (( status == 0 )); then
    printf '%s\n' "$out"
    return 0
  fi
  local err_text=""
  err_text="$(cat "$err_file" 2>/dev/null)"
  if [[ -n "$err_text" ]] && _sif_inspect_failure_is_confirmed_absence "$err_text"; then
    return "${GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE:-99}"
  fi
  # What: Echoes the real stderr instead of only returning 1 (discarding it).
  # Why: previously undiagnosable from the job log alone -- the root cause
  #   needed live reproduction against a real runner to find.
  # From: Issue #1581
  if [[ -n "$err_text" ]]; then
    echo "docker buildx imagetools inspect failed with stderr not recognized as a confirmed absence: $err_text" >&2
  fi
  return 1
}

# _sif_inspect <args...>
#
# Internal helper: runs `docker buildx imagetools inspect "$@"` through the
# project's shared ghcr_retry wrapper (scripts/lib/ghcr-retry.sh) instead of
# a single bare attempt (issue #1095: PR #1378 widened this function's real
# callers from 2 to 8 services -- 12 more unprotected registry reads per
# eligible push -- without retry coverage, so a single transient GHCR error
# on any one of them was read as "revision undeterminable" and silently
# triggered a full rebuild+scan, erasing the whole point of the push-reuse
# mechanism on registry-flaky days). ghcr_retry needs GHCR_RETRY_USERNAME/
# GHCR_RETRY_PASSWORD in the environment to re-login between retries (both
# optional -- see ghcr_retry's own header for the credential-less case) and
# must already be sourced by the caller (scripts/lib/ghcr-retry.sh, the same
# convention every other dual script/workflow-step caller in this project
# already follows -- see e.g. scripts/untracked/require-image-platforms.sh).
#
# Echoes stdout on success (return 0). On failure, echoes nothing and
# returns 2 for a confirmed absence, 1 for everything else -- this is the
# function's own stable external contract, independent of the underlying
# registry-call mechanism; sif_image_revision below
# propagates whichever of these two its own failing call produced, so a
# caller several frames up (sif_wait_for_fresh_base_image) can tell the two
# cases apart in its own log line instead of always printing the same
# both-cases-at-once wording. Internally this now means: ghcr_retry returns
# GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE for a confirmed absence (translated
# back to 2 here) or the last attempt's plain 1 after exhausting its retry
# budget for everything else (passed through as 1).
#
# stderr is captured to a scratch file, not a variable via a second `2>&1`
# command substitution: mixing stdout and stderr into one stream would lose
# which bytes were which, and this function's contract requires stdout
# (the manifest JSON / label value) to remain exactly the registry's own
# payload -- untouched by whatever the registry wrote to stderr. `mktemp`
# failing (a full/read-only $TMPDIR) degrades to the pre-existing
# "everything else" classification (no retry-vs-permanent distinction
# possible without a file to classify) rather than aborting -- the
# classification is a diagnostic nicety, never a reason to fail a call that
# would otherwise have succeeded or to change which exit code a genuine
# inspect failure already produced.
_sif_inspect() {
  local err_file stdout_output inspect_status
  err_file="$(mktemp 2>/dev/null)" || err_file=""
  if [[ -n "$err_file" ]]; then
    stdout_output="$(ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- _sif_inspect_attempt "$err_file" "$@")"
    inspect_status=$?
    rm -f "$err_file"
  else
    stdout_output="$(ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- docker buildx imagetools inspect "$@" 2>/dev/null)"
    inspect_status=$?
  fi
  if (( inspect_status == 0 )); then
    printf '%s\n' "$stdout_output"
    return 0
  fi
  if (( inspect_status == "${GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE:-99}" )); then
    return 2
  fi
  return 1
}

# Indirection so tests (and callers without a real registry) can stub this.
#
# Return codes on failure (the STAGING_IMAGE_REVISION_CMD stub path always
# returns 1 -- it has no real registry stderr to classify, and every existing
# test/caller of that hook already only checks "zero vs non-zero", so this
# does not change its contract): 1 means the underlying registry call failed
# for a reason that is NOT confirmed to be "does not exist" (network/timeout/
# rate-limit/auth/an unrecognized error shape) -- the original, ambiguous
# case. 2 means the registry positively reported no such manifest/tag/digest
# exists (see _sif_inspect_failure_is_confirmed_absence above) -- confirmed
# absence, not a registry hiccup. Both are still simply "non-zero" to any
# existing caller that only checks success/failure (e.g. push-reuse.sh's own
# push_reuse_decide, which never needed this distinction); only
# sif_wait_for_fresh_base_image below reads the specific code.
sif_image_revision() {
  local image="${1:?sif_image_revision: image is required}"
  local revision
  if [[ -n "${STAGING_IMAGE_REVISION_CMD:-}" ]]; then
    revision="$("$STAGING_IMAGE_REVISION_CMD" "$image")" || return 1
  else
    local raw target digest digest_lines raw_status
    raw="$(_sif_inspect "$image" --raw)"
    raw_status=$?
    if (( raw_status != 0 )); then
      return "$raw_status"
    fi
    target="$image"
    # Here-strings, not live pipes: $raw is a manifest-list JSON blob that
    # can carry several platform entries, and a live `producer | grep -q`
    # or `grep -o | head -1` pipe can SIGPIPE the producer once there is
    # more matching output than the consumer reads (issue #1377's
    # repo-wide pipefail/SIGPIPE audit).
    if grep -q '"manifests"[[:space:]]*:' <<<"$raw"; then
      digest_lines="$(grep -o '"digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-f]\{64\}"' <<<"$raw")"
      digest="$(head -1 <<<"$digest_lines" | sed -E 's/.*"(sha256:[0-9a-f]+)"/\1/')"
      if [[ -z "$digest" ]]; then
        return 1
      fi
      # Strip whatever reference form $image already carries before
      # appending the resolved child "@digest" -- $image can now be either
      # a mutable tag (repo:nightly) or an already-pinned digest reference
      # (repo@sha256:...; issue #1095's digest-TOCTOU fix passes this form so
      # a caller can verify and export the exact same immutable reference,
      # see scripts/lib/push-reuse.sh's own header). A single
      # "${image%:*}" strip (the original form of this line) is only
      # correct for the tag case: for a digest-ref input, the LAST colon in
      # $image sits INSIDE "sha256:..." itself, so that strip would cut the
      # digest in half instead of removing a tag that was never there.
      # Stripping "@..." first (a no-op for a tag-ref input, which has no
      # "@") then ":..." (a no-op for a digest-ref input, which -- images in
      # this project never using a registry host with an explicit port --
      # has no colon left once the "@digest" suffix is gone) handles both
      # forms with the same two lines.
      local repo="${image%@*}"
      repo="${repo%:*}"
      target="${repo}@${digest}"
    fi
    local format_status
    revision="$(_sif_inspect "$target" --format '{{index .Image.Config.Labels "org.opencontainers.image.revision"}}')"
    format_status=$?
    if (( format_status != 0 )); then
      return "$format_status"
    fi
  fi
  # A missing label renders as the literal string "<no value>" in a Go
  # template (index on a nil/short map doesn't error, it just yields the
  # zero value) rather than failing the command -- treat that the same as
  # "no label at all" instead of accidentally treating the literal text
  # "<no value>" as a commit SHA. This is a different case from "the image
  # doesn't exist" (the manifest/config WAS read successfully; it simply
  # never carried this label -- e.g. an image predating docker/metadata-
  # action's revision label being added), so it deliberately keeps returning
  # the original ambiguous 1, not the new confirmed-absence 2.
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
# scripts/untracked/classify-image-impact.sh and detect-full-setup-changes.sh already
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

# sif_wait_for_fresh_base_image <base_image> <base_sha> <service_label> <normal_budget_seconds> <hard_ceiling_seconds> <poll_interval_seconds> [allow_reverse_ancestry]
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
# The per-poll "no readable label yet" log line (in the loop body below)
# distinguishes a confirmed-absent manifest/tag/digest from every other
# registry-call failure -- see sif_image_revision/_sif_inspect's own headers
# for the classification itself. A 2026-08-06 root-cause pass across several
# days of full-setup-deep-validate.yml logs found several real occurrences
# of this branch whose OUTCOME could be reconstructed behaviourally (the
# per-commit tag in question never existed for that commit at all, or a
# later ancestor candidate resolved within seconds) -- every one of those was
# consistent with a confirmed absence, none with a genuinely transient
# registry failure. That is evidence about the cases this classifier can
# now resolve, not a claim that a transient registry failure never happens
# here: the PRE-EXISTING logs from before this classification existed never
# recorded the registry's own error text at all (the whole reason this
# function's message used to be unable to tell the two cases apart), so
# whether any past occurrence of the OTHER case ever happened is genuinely
# unknowable in retrospect. This function's own RETURN CODE contract is
# unchanged by any of this (still a plain 1 at the hard ceiling regardless
# of which case applied): the classification is a diagnostic improvement
# for whoever reads the job log while it is still running, not a new
# caller-visible outcome, so no caller needed updating.
#
# <allow_reverse_ancestry> (optional, any non-empty value means "true";
# default off -- unset/empty preserves the exact pre-existing behavior for
# every caller that doesn't pass it): also accept the label predating
# <base_sha> (base_sha being a DESCENDANT of the label's commit, the reverse
# of the normal check), instead of only ever accepting base_sha being at or
# before the label. This must stay opt-in, never the default, because it is
# only safe when <base_image> is known to be an IMMUTABLE per-commit
# `sha-<base_sha>` tag -- never a mutable channel tag (`dev`/`nightly`/
# `latest`), which is exactly what this whole check exists to catch as
# genuinely stale (#808). For a per-commit tag specifically, there are only
# two ways it can exist at all: a real build-push.yml build AT that exact
# commit (label == base_sha, the ordinary case), or build-push.yml's own
# Schritt 4 "Retag unchanged service image" step (label == an ancestor of
# base_sha) -- which only ever runs after determine-push-reuse-scope has
# already positively verified content-equivalence between that ancestor and
# base_sha for this exact service (scripts/lib/push-reuse.sh). There is no
# third way a per-commit tag's label ends up predating its own tag name, so
# accepting that combination is exactly as safe as accepting an exact match
# -- it is not a weaker freshness bar, just recognizing a second legitimate
# shape the proof can take. scripts/lib/staging-ancestor-fallback.sh's own
# callers are the only ones that pass this (see that file), because they are
# the only callers that always pass a per-commit tag; the shared #808/#895
# touched-image mutable-channel-tag path this file's own header still
# describes must never opt in.
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
  local allow_reverse_ancestry="${7:-}"

  # Scope ghcr_retry's own internal retry/backoff (added to sif_image_revision's
  # underlying _sif_inspect calls per issue #1095) to match THIS call's own
  # budget shape, rather than letting either extreme apply everywhere:
  #
  # - A genuine multi-iteration poll (hard_ceiling_seconds > 0) already IS a
  #   retry loop -- that is what "wait" means here, and its own budget/
  #   ceiling contract is load-bearing (issue #1095's incident measured
  #   several services burning ~612s each against this exact ceiling).
  #   Letting ghcr_retry's own up-to-90s internal retry-with-backoff run
  #   silently inside a single poll iteration would eat into that same
  #   ceiling in a way this loop's own budget arithmetic does not expect,
  #   without buying anything the loop's own sleep-and-repeat does not
  #   already provide -- so this case scopes down to exactly one attempt
  #   (no internal retry at all; a transient blip just becomes another "keep
  #   polling" iteration, the same outer-loop-driven recovery this function
  #   always relies on for any other transient condition).
  # - A single non-polling probe (hard_ceiling_seconds == 0 -- e.g. issue
  #   #1095's "one direct check before assuming the ancestor walk is needed" fast
  #   path, scripts/lib/staging-ancestor-fallback.sh's saf_find_built_ancestor())
  #   gets exactly ONE iteration of this outer loop, so it has ZERO
  #   redundancy of its own against a transient GHCR error -- confirmed live
  #   (2026-08-07, PR #1440's "ensure PR staging images" check): the 0s
  #   fast-path probe for proxy:sha-f5f991b failed on a single transient
  #   registry-read error even though the image demonstrably existed
  #   (verified directly afterward via `docker buildx imagetools inspect` on
  #   a runner), because this exact case had no retry margin anywhere. A
  #   short, bounded retry (2 attempts, 5s backoff -- cheap next to a real
  #   rebuild+scan, unlike the full 4-attempt/30s-backoff default) gives
  #   this specific shape the resilience its own zero-iteration budget
  #   cannot provide any other way, without reintroducing the full poll-path
  #   cost concern above.
  #
  # `local` here shadows the global for this function's entire dynamic
  # extent (including every function it calls, transitively through
  # sif_image_revision/_sif_inspect/ghcr_retry) and is automatically
  # restored on any of this function's several return points -- no explicit
  # save/restore needed.
  if (( hard_ceiling_seconds > 0 )); then
    # shellcheck disable=SC2034 # read by ghcr_retry() in scripts/lib/ghcr-retry.sh,
    # a cross-file dynamic-scope read shellcheck cannot see.
    local GHCR_RETRY_MAX_ATTEMPTS=1
    # shellcheck disable=SC2034 # same cross-file reason.
    local GHCR_RETRY_BACKOFF_SECONDS=0
  else
    # shellcheck disable=SC2034 # same cross-file reason.
    local GHCR_RETRY_MAX_ATTEMPTS=2
    # shellcheck disable=SC2034 # same cross-file reason.
    local GHCR_RETRY_BACKOFF_SECONDS=5
  fi

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
      if (( ancestor_status == 1 )) && [[ -n "$allow_reverse_ancestry" ]]; then
        set +e
        sif_is_ancestor_or_equal "$revision" "$base_sha"
        local reverse_status=$?
        set -e
        if (( reverse_status == 0 )); then
          echo "::notice::$service_label base image ($base_image) was built from commit $revision, which PREDATES base commit $base_sha -- but this is a per-commit tag, so the only way that combination exists is build-push.yml's Schritt 4 retag-unchanged-image path, which already verified $service_label is content-equivalent between $revision and $base_sha before writing this tag (waited $((SECONDS - start_time))s). Safe to back-fill from." >&2
          printf '%s\n' "$revision"
          return 0
        fi
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
      # $? here is sif_image_revision's own real exit status: entering this
      # `else` branch is the very next thing that happens after the failed
      # assignment above, with nothing in between that could have changed it.
      # 2 vs. "anything else" is the confirmed-absence classification
      # sif_image_revision/_sif_inspect propagate (see those functions' own
      # headers). Distinguishing the two here matters because a repeating
      # "no readable label yet" line across many poll intervals in a live job
      # log reads as one undifferentiated case to whoever is watching it,
      # when it can actually be either "genuinely does not exist" or "the
      # registry call itself failed" -- two very different things to act on.
      # `docker buildx imagetools inspect`'s own stderr is the one signal
      # that tells them apart, and _sif_inspect only classifies it (rather
      # than discarding it outright) for the confirmed-absence shape; every
      # other failure text still falls through to the fallback wording below
      # for revision_status 1, since THAT case's own ambiguity is genuine: a
      # network/DNS/TLS/5xx/rate-limit failure really does look the same,
      # from this function's vantage point, as an image that simply has not
      # been pushed yet moments before this exact poll.
      local revision_status=$?
      if (( revision_status == 2 )); then
        echo "$service_label base image ($base_image) has no matching manifest/tag/digest in the registry yet (elapsed $((SECONDS - start_time))s) -- confirmed absent: the registry itself reported no such manifest (not a connection/timeout/auth failure), most likely because it has not been built or retagged for this commit yet (e.g. first build ever for this channel, or a Step 4 push-reuse-eligible service whose per-commit tag for this exact commit was never written)." >&2
      else
        echo "$service_label base image ($base_image) has no readable org.opencontainers.image.revision label yet (elapsed $((SECONDS - start_time))s) -- the registry call itself failed (network/timeout/rate-limit/auth, or an error shape this check does not yet recognize as a confirmed absence), not a positively confirmed absence; retrying." >&2
      fi
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
