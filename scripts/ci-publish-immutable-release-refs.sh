#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Publishes immutable release refs from an already-validated release lock.
# Every target is read before any mutation. Existing identical refs are
# idempotent, missing refs may be created, and any existing conflicting ref
# aborts the complete operation before the first write. The coherent stack ref
# is emitted last by ci-release-ref-plan.sh and is therefore the commit point.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: ci-publish-immutable-release-refs.sh RELEASE_LOCK RELEASE_TAG STACK_DIGEST" >&2
    exit 2
fi

lock="$1"
release_tag="$2"
stack_digest="$3"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/ci-artifact-identity.sh
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
# shellcheck source=scripts/lib/ghcr-retry.sh
source "$repo_root/scripts/lib/ghcr-retry.sh"

: "${GHCR_RETRY_USERNAME:?GHCR_RETRY_USERNAME is required}"
: "${GHCR_RETRY_PASSWORD:?GHCR_RETRY_PASSWORD is required}"

mapfile -t desired_rows < <(
    bash "$repo_root/scripts/ci-release-ref-plan.sh" "$lock" "$release_tag" "$stack_digest"
)
[[ "${#desired_rows[@]}" -gt 0 ]] || ci_ai_fail "immutable release ref plan is empty"

declare -A desired_by_target=()
declare -A state_by_target=()

# Phase 1: freeze the complete known registry state before the first write.
# This is what makes a conflicting existing immutable tag fail atomically
# instead of being discovered only after earlier package refs have moved.
for row in "${desired_rows[@]}"; do
    IFS=$'\t' read -r target desired <<<"$row"
    ci_ai_require_digest "$desired"
    desired_by_target["$target"]="$desired"

    if actual="$(ci_ai_ref_digest_optional "$target")"; then
        if [[ "$actual" != "$desired" ]]; then
            ci_ai_fail "immutable release ref $target already exists at $actual, expected $desired"
            exit 1
        fi
        state_by_target["$target"]=existing
    else
        status=$?
        if (( status == CI_AI_REF_ABSENT_STATUS )); then
            state_by_target["$target"]=missing
        else
            ci_ai_fail "could not establish immutable release ref state for $target"
            exit "$status"
        fi
    fi
done

# Phase 2: create only refs proven absent in phase 1. Existing identical refs
# remain untouched. If creation stops part-way, already-created immutable refs
# are valid pieces of the same release and may be reused by an idempotent retry;
# they are never destructively rewritten or deleted. The stack ref is last.
for row in "${desired_rows[@]}"; do
    IFS=$'\t' read -r target desired <<<"$row"
    [[ "${state_by_target[$target]}" == missing ]] || continue

    image="${target%:*}"
    metadata="$(mktemp)"
    if ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- \
        docker buildx imagetools create --prefer-index=false \
          --tag "$target" \
          "${image}@${desired}" \
          --metadata-file "$metadata"; then
        :
    else
        status=$?
        rm -f "$metadata"
        exit "$status"
    fi
    published="$(jq -r '."containerimage.descriptor".digest // empty' "$metadata")"
    rm -f "$metadata"
    [[ "$published" == "$desired" ]] \
        || ci_ai_fail "immutable release publication changed digest for $target"
done

# Phase 3: read every ref back after the complete write sequence. A retry is
# safe after an ambiguous post-write network failure because phase 1 accepts
# only already-identical immutable refs and refuses any conflicting value.
for row in "${desired_rows[@]}"; do
    IFS=$'\t' read -r target desired <<<"$row"
    actual="$(ci_ai_ref_digest "$target")"
    [[ "$actual" == "$desired" ]] \
        || ci_ai_fail "post-publication digest mismatch for immutable release ref $target"
done
