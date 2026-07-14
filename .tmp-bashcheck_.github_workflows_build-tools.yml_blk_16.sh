set -euo pipefail

# shellcheck source=scripts/lib/ghcr-retry.sh
source "$GITHUB_WORKSPACE/scripts/lib/ghcr-retry.sh"

digest="$(ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- docker buildx imagetools inspect "${{ steps.merge.outputs.source-tag }}" --format '{{json .Manifest.Digest}}')"
digest="${digest%\"}"
digest="${digest#\"}"
if [[ -z "$digest" || "$digest" = "null" ]]; then
  echo "::error::Could not read digest for merged manifest ${{ steps.merge.outputs.source-tag }}."
  exit 1
fi
printf 'digest=%s\n' "$digest" >> "$GITHUB_OUTPUT"

