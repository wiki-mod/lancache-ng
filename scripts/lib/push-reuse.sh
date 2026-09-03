#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Step 4: per-service build/scan reuse-on-push decision for
# `build-push.yml`'s `build`/`build-arm64` jobs. On a push to a branch ref,
# an unchanged service should retag its already-published channel image
# (nightly/latest) instead of paying for a real rebuild+rescan -- but ONLY
# when that reuse is provably safe, not merely plausible.
#
# WHY a channel image, not the immediately-preceding push's own predecessor
# commit: predecessor-`sha-<before>` reuse is what Step 4 originally
# stalled on (2026-07-23) -- `merge-manifests` has no cross-run lock and push
# runs are deliberately un-throttled (#979/#987), so in a tight burst the
# predecessor image is frequently not published yet, making that design's
# real-world hit rate poor exactly when relief is most needed (see this
# issue's own comment thread). A channel tag (nightly/latest) already
# exists before this run starts, so there is nothing to wait for and no race.
#
# WHY that alone is NOT sufficient (this is the part issue #1290's own first
# implementation got wrong, corrected during this same investigation, 2026-07-30):
# since #1254/#1255, a plain `current_dev` push never moves the `nightly`
# pointer at all (confirmed directly against `promote`'s own channel_tags
# logic in this file -- the `current_dev` branch of that if/elif chain is a
# bare no-op comment) -- `nightly` only advances via nightly-refresh.yml's
# once-daily/on-demand green-gated refresh. So the channel image can be
# hours-to-a-day behind `github.sha`. Trusting "detect-changes says this push
# alone (before..sha) didn't touch this service" and then blindly retagging
# whatever nightly currently points at is the exact #808 stale-image shape:
# a real change to this service could have landed in an EARLIER push, before
# nightly's last refresh, and this push's own before..sha diff would never
# see it.
#
# The fix (what this file actually verifies, all three, every time, no
# shortcuts): (1) the channel image must carry a readable
# org.opencontainers.image.revision label (sif_image_revision) identifying
# the exact commit it was built from; (2) that revision must be a real git
# ancestor of (or equal to) github.sha (sif_is_ancestor_or_equal) -- proves
# ORDERING, i.e. the image cannot have been built from a commit "in the
# future" relative to what we're about to tag it as; (3) a real content diff
# for THIS service's own path, from that revision to github.sha (not from
# detect-changes' before..sha) via scripts/untracked/classify-image-impact.sh -- proves
# CONTENT IDENTITY across the whole span back to the image's actual source
# commit, which ancestry alone does not. Reuse requires all three; anything
# missing, unreadable, ambiguous, or showing a real change fails closed to a
# real rebuild. This mirrors the exact combination of primitives this issue
# names as this design's own correctness requirement (see its "C-7" and
# "Note on Step 4's actual implementation" sections) and issue #1290's
# corrected implementation (in progress in parallel; both are expected to
# converge on this same shape). A fourth check, (4), reads the SAME
# classify-image-impact.sh output (3) already computed for its "workflow"
# key: reuse also requires no build-affecting workflow/composite-action file
# to have changed anywhere in the full revision..github_sha span, not merely
# in the immediately preceding push -- a caller's own before..sha diff
# (build-push.yml's decide_one()) cannot see a workflow change several
# pushes back, before the channel's last refresh.
#
# <channel_image> may be either a mutable channel tag (repo:nightly) or an
# already-resolved immutable digest reference (repo@sha256:...) -- callers
# that need to export the exact digest they verified reuse against (so a
# later job never independently re-resolves the same mutable tag and risks
# racing a channel refresh) resolve the digest once, build the pinned
# reference, and pass that in here instead of the tag. sif_image_revision
# handles both forms.
#
# WHY no polling: unlike scripts/lib/staging-image-freshness.sh's
# sif_wait_for_fresh_base_image (built for a genuinely different situation --
# #808's PR-staging backfill, where the source image's build might still be
# mid-flight and worth a bounded wait), a push-path reuse decision must
# resolve in one shot. A CI job that sleep-polls inside a step can hit its
# own step/job timeout mid-wait during exactly the kind of merge burst this
# whole issue is about (a real near-miss occurred this same day -- see the
# PR that introduces this file for the incident reference). If the channel
# image isn't fresh/verifiable RIGHT NOW, the correct answer is "build for
# real", not "wait and see" -- building from the current tree is always
# correct, so failing closed costs a rebuild, never correctness.
#
# Sourced by build-push.yml's push-only reuse-decision job (needs
# fetch-depth: 0 -- sif_is_ancestor_or_equal requires full history, same
# requirement scripts/untracked/classify-image-impact.sh already documents for its own
# merge-base diff). Deliberately NOT `set -euo pipefail` at the top level,
# matching scripts/lib/ghcr-retry.sh and scripts/lib/staging-image-freshness.sh's
# own convention: this file only defines functions for a caller to invoke
# under the caller's own shell options.

# push_reuse_decide <service_key> <channel_image> <github_sha> [dep_keys] [ignore_workflow_gate]
#
# <service_key> is the exact key.classify-image-impact.sh emits for this
# service on stdout (e.g. "ntp", "watchdog", "dhcp_proxy", "dns_image" for
# the "dns" matrix service -- callers must pass the classify key, not
# necessarily the matrix service name; the two differ for dns/dhcp-proxy).
# <channel_image> is the already-resolved "repo/service:channel" reference
# (e.g. ghcr.io/wiki-mod/lancache-ng/ntp:nightly) -- resolving which channel
# name a given ref maps to is the caller's job (see
# scripts/lib/build-tools-channel.sh's resolve_build_tools_channel, which is
# plain ref-to-channel-name arithmetic with nothing build-tools-specific in
# its actual logic, and is reused as-is here rather than duplicated -- see
# this function's own callers).
# <github_sha> is the full 40-char commit SHA being built.
# [dep_keys] is an optional space-separated list of ADDITIONAL classify keys
# (e.g. "utilities", "utilities build_tools") that must also show unchanged
# across the same revision..github_sha span for reuse to be safe -- for a
# service whose own Dockerfile COPYs from another first-party image
# (proxy/dns/dhcp/dhcp-proxy/ntp/ui/watchdog all depend on utilities;
# dns/ui/watchdog also depend on build-tools), that dependency's own content
# is invisible to <service_key>'s own touched-check, so it must be checked
# here too, or a consumer with no changes of its own would keep retagging a
# now-outdated image forever after its dependency moved on, silently, with
# no bound on how long. Empty/omitted preserves this function's prior
# behavior exactly (no extra keys checked).
#
# [ignore_workflow_gate], when the literal string "true", skips ONLY the
# workflow_reuse_scope disqualifier below -- <service_key>'s own change
# check and every dep_key still apply in full. Empty/omitted (any other
# value) preserves this function's prior behavior exactly. Scoped to
# build-tools/utilities by their one caller (build-push.yml's decide_one()):
# both publish a shared CI-tooling/base-layer image, not a product-stack
# service, so a workflow/composite-action edit that never touches their own
# path or dependencies has no way to change what either image contains --
# unlike the other eight services, where the SAME workflow file also
# contains their own build/push/scan steps.
#
# Always prints exactly "true" or "false" to stdout and returns 0 -- a
# non-zero return means a genuine usage error (missing argument), never an
# ordinary "not safe to reuse" outcome, so callers can rely on capturing
# stdout without also branching on exit status for the ordinary case.
#
# Indirection so tests can stub the one real external call this function
# makes beyond the already-independently-tested sif_* primitives: the
# classify-image-impact.sh invocation. sif_image_revision already has its
# own STAGING_IMAGE_REVISION_CMD stub hook (staging-image-freshness.sh);
# sif_is_ancestor_or_equal runs against a real disposable git repo via
# STAGING_FRESHNESS_GIT_DIR (same file). PUSH_REUSE_CLASSIFY_CMD mirrors that
# same convention for the one primitive genuinely new to this file.
#
# AG-CI-012 note: this function has two real outcomes (fail-closed rebuild,
# or reuse=true retag), and both need independent real-push-event evidence,
# not just code review -- a passing test suite proves the logic is
# internally consistent, not that GitHub Actions actually exercises the
# reuse=true branch end to end on a live push. Current verification status
# for either branch belongs in the PR/issue trail, not here, per this
# project's convention of keeping durable rationale in source comments and
# dated status/evidence out of them.
push_reuse_decide() {
  local service_key="${1:?push_reuse_decide: service_key is required}"
  local channel_image="${2:?push_reuse_decide: channel_image is required}"
  local github_sha="${3:?push_reuse_decide: github_sha is required}"
  local dep_keys="${4:-}"
  local ignore_workflow_gate="${5:-}"

  local revision
  if ! revision="$(sif_image_revision "$channel_image")"; then
    echo "push_reuse_decide: $channel_image has no readable org.opencontainers.image.revision label (missing image, registry error, or absent label) -- failing closed to a real rebuild." >&2
    printf 'false\n'
    return 0
  fi

  local ancestor_status
  set +e
  sif_is_ancestor_or_equal "$revision" "$github_sha"
  ancestor_status=$?
  set -e
  if [[ "$ancestor_status" != "0" ]]; then
    echo "push_reuse_decide: $channel_image's build commit ($revision) is not a real git ancestor of $github_sha (sif_is_ancestor_or_equal returned $ancestor_status) -- failing closed to a real rebuild." >&2
    printf 'false\n'
    return 0
  fi

  local classify_output changed_flag
  if [[ -n "${PUSH_REUSE_CLASSIFY_CMD:-}" ]]; then
    classify_output="$("$PUSH_REUSE_CLASSIFY_CMD" "$revision" "$github_sha" 2>/dev/null)" || {
      echo "push_reuse_decide: classify command failed for ${revision}..${github_sha} -- failing closed to a real rebuild." >&2
      printf 'false\n'
      return 0
    }
  else
    local classify_script="${PUSH_REUSE_CLASSIFY_SCRIPT:-$(dirname "${BASH_SOURCE[0]}")/../untracked/classify-image-impact.sh}"
    classify_output="$(bash "$classify_script" "$revision" "$github_sha" 2>/dev/null)" || {
      echo "push_reuse_decide: $classify_script failed for ${revision}..${github_sha} -- failing closed to a real rebuild." >&2
      printf 'false\n'
      return 0
    }
  fi

  # Fail closed on anything except an explicit "false": a real "true" (this
  # service's own path really changed somewhere between revision and sha --
  # exactly the case ancestry alone cannot detect), a missing key (malformed
  # classify output), or an unexpected value all mean "do not trust this as
  # unchanged".
  # Here-string, not a live pipe into grep -m1 -- $classify_output lists
  # every service classify-image-impact.sh knows about, and a live pipe
  # could SIGPIPE the moment there is more output after the first match
  # (issue #1377's repo-wide pipefail/SIGPIPE audit).
  changed_flag="$(grep -m1 "^${service_key}=" <<<"$classify_output" | cut -d= -f2)"
  if [[ "$changed_flag" != "false" ]]; then
    echo "push_reuse_decide: classify-image-impact.sh reported '${service_key}=${changed_flag:-<missing>}' for ${revision}..${github_sha} -- failing closed to a real rebuild." >&2
    printf 'false\n'
    return 0
  fi

  # What: workflow_reuse_scope covers revision..github_sha span.
  # Why: closes a prior before..sha-only gap.
  # From: Issue #1095 | PR #1378
  if [[ "$ignore_workflow_gate" != "true" ]]; then
    local workflow_flag
    workflow_flag="$(grep -m1 '^workflow_reuse_scope=' <<<"$classify_output" | cut -d= -f2)"
    if [[ "$workflow_flag" != "false" ]]; then
      echo "push_reuse_decide: classify-image-impact.sh reported 'workflow_reuse_scope=${workflow_flag:-<missing>}' for ${revision}..${github_sha} -- a build-affecting workflow/composite-action file changed somewhere in the full revision span (not just the immediately preceding push) -- failing closed to a real rebuild." >&2
      printf 'false\n'
      return 0
    fi
  fi

  # What: also fails closed if any declared dependency key changed.
  # Why: consumer's key can't see first-party base image change.
  # From: Issue #1095
  local dep_key dep_flag
  for dep_key in $dep_keys; do
    dep_flag="$(grep -m1 "^${dep_key}=" <<<"$classify_output" | cut -d= -f2)"
    if [[ "$dep_flag" != "false" ]]; then
      echo "push_reuse_decide: classify-image-impact.sh reported '${dep_key}=${dep_flag:-<missing>}' for ${revision}..${github_sha} -- a declared dependency (${dep_key}) changed in the full revision span -- failing closed to a real rebuild." >&2
      printf 'false\n'
      return 0
    fi
  done

  printf 'true\n'
}
