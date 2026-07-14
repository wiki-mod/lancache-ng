set -euo pipefail

# shellcheck source=scripts/lib/ghcr-retry.sh
source "$GITHUB_WORKSPACE/scripts/lib/ghcr-retry.sh"

services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)
short_sha="${COMMIT_SHA::7}"
source_tag="sha-${short_sha}"
stack_pointer_image="ghcr.io/${REPOSITORY}/stack:${source_tag}"
channel_tags=()
pointer_context=""
declare -A previous_refs=()
promoted_targets=()

# Wrapped in ghcr_retry (#822): unlike merge-manifests' amd64/arm64
# existence probes, absence is never the expected outcome for any
# caller of this helper in this job -- the "previous digest before
# overwrite" callers below already tolerate absence via `|| true`
# regardless of whether that absence is real (first-ever promotion
# of a channel tag) or a transient read failure, and a retry only
# improves the odds of capturing the real previous digest that
# rollback_promotions needs.
digest_for_image() {
  local image=$1
  local digest

  if ! digest="$(ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- docker buildx imagetools inspect "$image" --format '{{json .Manifest.Digest}}' 2>/dev/null)"; then
    return 1
  fi
  digest="${digest%\"}"
  digest="${digest#\"}"
  [[ -n "$digest" && "$digest" != "null" ]]
  printf '%s\n' "$digest"
}

rollback_promotions() {
  local status=$?
  local target_image previous_digest

  if [[ -n "$pointer_context" ]]; then
    rm -rf "$pointer_context"
  fi

  if [[ "$status" = "0" || "${#promoted_targets[@]}" = "0" ]]; then
    exit "$status"
  fi

  echo "::error::Promotion failed after public tags were moved; attempting best-effort rollback."
  for target_image in "${promoted_targets[@]}"; do
    previous_digest="${previous_refs[$target_image]:-}"
    if [[ -n "$previous_digest" ]]; then
      ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- \
        docker buildx imagetools create --prefer-index=false -t "$target_image" "${target_image%:*}@${previous_digest}" \
        || echo "::error::Could not restore previous digest for $target_image."
    else
      echo "::error::No previous digest existed for $target_image; manual GHCR inspection is required."
    fi
  done
  exit "$status"
}
trap rollback_promotions EXIT

# Debounce/coalesce (#777): mutable channel tags (dev/edge) are
# branch-driven, and giving promote its own concurrency group above
# only stops it competing for the SAME slot as the rest of this
# workflow -- it does not stop several of these runs from queuing
# up back-to-back across a burst of merges, each pointing at a
# moment-in-time commit that a later one will immediately
# supersede. Before actually moving any tag, re-resolve the ref's
# current tip directly from the remote and bail out as a no-op if
# a newer commit already landed: that later commit's own promote
# run (already queued or about to be) will move the tag correctly,
# so this run briefly (and pointlessly) setting dev/edge to an
# already-stale commit would only add churn, not value. This only
# applies to branch refs -- a release/rc tag push targets one
# fixed, immutable ref that cannot "move out from under" this run,
# so vX.Y.Z/latest promotion is never skipped by this check.
if [[ "$GITHUB_REF" == refs/heads/* ]]; then
  current_tip="$(git ls-remote origin "$GITHUB_REF" | cut -f1)"
  if [[ -z "$current_tip" ]]; then
    echo "::error::Could not resolve the current tip of ${GITHUB_REF} via git ls-remote; refusing to promote blind."
    exit 1
  fi
  if [[ "$current_tip" != "$COMMIT_SHA" ]]; then
    echo "::notice::${GITHUB_REF} has already moved to ${current_tip} since this run was triggered for ${COMMIT_SHA}; skipping channel promotion so the run already targeting the current tip can supersede it."
    exit 0
  fi
fi

if [[ "$GITHUB_REF" = "refs/heads/master" ]]; then
  channel_tags+=(edge)
elif [[ "$GITHUB_REF" = refs/heads/v[0-9]* ]]; then
  # Any version-numbered integration branch (v0.2.0, v0.3.0, v0.2.x,
  # ...), not just whichever one happens to be active right now.
  channel_tags+=(dev)
elif [[ "$GITHUB_REF" = refs/tags/v* ]]; then
  channel_tags+=("$GITHUB_REF_NAME")
  if [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]]; then
    :
  elif [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    bash scripts/check-stable-external-images.sh
    channel_tags+=(latest)
  else
    echo "::error::Unsupported release tag '${GITHUB_REF_NAME}'. Use vX.Y.Z or vX.Y.Z-rc.N."
    exit 1
  fi
fi

# workflow_dispatch can additionally request one channel move from
# whatever ref it's dispatched against, independent of the
# automatic branch/tag rule above -- e.g. spot-check a feature
# branch as "dev" without merging it into v0.2.0 first. "none"
# (the default) adds nothing.
if [[ -n "$REQUESTED_CHANNEL" && "$REQUESTED_CHANNEL" != "none" ]]; then
  already_requested=false
  for existing_channel in "${channel_tags[@]}"; do
    [[ "$existing_channel" = "$REQUESTED_CHANNEL" ]] && already_requested=true
  done
  if [[ "$already_requested" = false ]]; then
    channel_tags+=("$REQUESTED_CHANNEL")
  fi
fi

if (( ${#channel_tags[@]} == 0 )); then
  echo "::notice::No public channel tags are configured for $GITHUB_REF."
  exit 0
fi

# Wrapped in ghcr_retry: unlike merge-manifests' per-arch checks,
# a missing source image here is always treated as an error, never
# an expected skip -- retrying protects against a transient read
# failure being reported as a genuinely missing image.
missing=0
for service in "${services[@]}"; do
  source_image="ghcr.io/${REPOSITORY}/${service}:${source_tag}"
  if ! ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- docker buildx imagetools inspect "$source_image" >/dev/null; then
    echo "::error::Cannot promote because required source image is missing: $source_image"
    missing=1
  fi
done
if [[ "$missing" = "1" ]]; then
  exit 1
fi

for service in "${services[@]}"; do
  GHCR_RETRY_USERNAME="$GHCR_RETRY_USERNAME" GHCR_RETRY_PASSWORD="$GHCR_RETRY_PASSWORD" \
    bash scripts/require-image-platforms.sh "ghcr.io/${REPOSITORY}/${service}:${source_tag}" "$REQUIRED_PLATFORMS"
done

pointer_context="$(mktemp -d)"
{
  printf 'LANCACHE_IMAGE_TAG=%s\n' "$source_tag"
  printf 'LANCACHE_IMAGE_COMMIT=%s\n' "$COMMIT_SHA"
  printf 'LANCACHE_IMAGE_SERVICES=%s\n' "${services[*]}"
} > "$pointer_context/stack.env"
# One variable feeds both the per-platform config LABEL below (an
# unquoted heredoc so it can expand) and the index-level OCI
# annotation on the buildx build call right after, so the two never
# drift out of sync with each other.
stack_pointer_description="Resolves a mutable lancache-ng stack channel to one immutable sha-* service image set."
cat > "$pointer_context/Dockerfile" <<DOCKERFILE
FROM busybox:stable-musl@sha256:3c6ae8008e2c2eedd141725c30b20d9c36b026eb796688f88205845ef17aa213
LABEL org.opencontainers.image.title="lancache-ng stack channel pointer"
LABEL org.opencontainers.image.description="${stack_pointer_description}"
COPY stack.env /stack.env
CMD ["true"]
DOCKERFILE
# This build is always genuinely multi-platform ($RELEASE_PLATFORMS
# is always 2+ platforms), so unlike the per-platform service
# builds above, an index already exists here for --annotation to
# attach to -- confirmed live while fixing issue #620. This step
# does not disable provenance, so it already defaults to OCI
# mediatypes without needing an explicit `outputs:` override.
ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- \
  docker buildx build \
  --platform "$RELEASE_PLATFORMS" \
  --push \
  -t "$stack_pointer_image" \
  --annotation "index:org.opencontainers.image.description=${stack_pointer_description}" \
  "$pointer_context"
ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- docker buildx imagetools inspect "$stack_pointer_image" >/dev/null
GHCR_RETRY_USERNAME="$GHCR_RETRY_USERNAME" GHCR_RETRY_PASSWORD="$GHCR_RETRY_PASSWORD" \
  bash scripts/require-image-platforms.sh "$stack_pointer_image" "$REQUIRED_PLATFORMS"
stack_pointer_digest="$(digest_for_image "$stack_pointer_image")"
{
  printf 'stack-pointer-subject=ghcr.io/%s/stack\n' "$REPOSITORY"
  printf 'stack-pointer-digest=%s\n' "$stack_pointer_digest"
} >> "$GITHUB_OUTPUT"

# Neither loop below passes --annotation. $source_image already
# carries the org.opencontainers.image.description index annotation
# from merge-manifests above (and $stack_pointer_image from its own
# build a few lines up), and a plain --prefer-index=false carbon
# copy of an already-annotated OCI index preserves that annotation
# AND produces a byte-identical digest to the source -- confirmed
# live while fixing issue #620. Adding --annotation again here would
# only risk re-serializing the manifest with a different digest,
# which would break the release job's invariant that a channel/
# release tag resolves to the exact same digest as its source
# sha-* tag.
for service in "${services[@]}"; do
  source_image="ghcr.io/${REPOSITORY}/${service}:${source_tag}"
  for channel_tag in "${channel_tags[@]}"; do
    target_image="ghcr.io/${REPOSITORY}/${service}:${channel_tag}"
    previous_refs["$target_image"]="$(digest_for_image "$target_image" || true)"
    ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- \
      docker buildx imagetools create --prefer-index=false -t "$target_image" "$source_image"
    promoted_targets+=("$target_image")
  done
done

for channel_tag in "${channel_tags[@]}"; do
  target_image="ghcr.io/${REPOSITORY}/stack:${channel_tag}"
  previous_refs["$target_image"]="$(digest_for_image "$target_image" || true)"
  ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- \
    docker buildx imagetools create --prefer-index=false -t "$target_image" "$stack_pointer_image"
  promoted_targets+=("$target_image")
done

for service in "${services[@]}"; do
  for channel_tag in "${channel_tags[@]}"; do
    ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- \
      docker buildx imagetools inspect "ghcr.io/${REPOSITORY}/${service}:${channel_tag}" >/dev/null
  done
done

for channel_tag in "${channel_tags[@]}"; do
  ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- \
    docker buildx imagetools inspect "ghcr.io/${REPOSITORY}/stack:${channel_tag}" >/dev/null
done

