#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: fail-closed reuse: revision+ancestor+content-diff
# Why: a stale channel tag can lag github_sha for days
# From: Issue #1095 | PR #1331
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

  # What: fails closed if a declared dependency key changed.
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
