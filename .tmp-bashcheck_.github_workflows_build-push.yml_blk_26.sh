set -euo pipefail

if [[ "$BASE_REF" == "master" ]]; then
  base_channel_tag=edge
elif [[ "$BASE_REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  base_channel_tag=dev
else
  base_channel_tag=latest
fi
echo "base-channel-tag=$base_channel_tag" >> "$GITHUB_OUTPUT"

pr_staging_available=false
if [[ "$EVENT_NAME" == "pull_request" && "$ACTOR" != "dependabot[bot]" && "$HEAD_REPO" == "$REPOSITORY" ]]; then
  pr_staging_available=true
fi
echo "pr-staging-available=$pr_staging_available" >> "$GITHUB_OUTPUT"

if [[ "$pr_staging_available" == "true" ]]; then
  short_sha="${BUILD_SHA::7}"
  tag="pr-${PR_NUMBER}-sha-${short_sha}"
  echo "Validating against this PR's own staging tag '$tag' (built commit $BUILD_SHA, PR head $PR_HEAD_SHA; base-channel fallback for untouched services: '$base_channel_tag')."
else
  tag="$base_channel_tag"
  if [[ "$EVENT_NAME" == "pull_request" ]]; then
    echo "::notice::$ACTOR's pull_request runs get a read-only GITHUB_TOKEN (Dependabot, or a fork PR), so build/build-arm64 could not push a PR staging tag. Validating against the '$tag' base channel instead -- the same behavior this job always had before #626."
  fi
  echo "Validating against the '$tag' channel (base ref: $BASE_REF)."
fi
echo "tag=$tag" >> "$GITHUB_OUTPUT"

