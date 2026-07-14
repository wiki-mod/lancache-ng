set -euo pipefail

short_sha="${BUILD_SHA::7}"
tag="pr-${PR_NUMBER}-sha-${short_sha}-amd64"
echo "::notice::This PR's linux/amd64 staging tag for $MATRIX_SERVICE is $tag."
{
  printf 'tag=%s\n' "$tag"
  printf 'image=ghcr.io/%s/%s:%s\n' "${{ github.repository }}" "$MATRIX_SERVICE" "$tag"
} >> "$GITHUB_OUTPUT"

