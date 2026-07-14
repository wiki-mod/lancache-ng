set -euo pipefail

digest_for_image() {
  local image=$1 digest
  digest="$(docker buildx imagetools inspect "$image" --format '{{json .Manifest.Digest}}')"
  digest="${digest%\"}"
  digest="${digest#\"}"
  if [[ -z "$digest" || "$digest" = "null" ]]; then
    echo "::error::Could not read digest for $image."
    exit 1
  fi
  printf '%s\n' "$digest"
}

{
  printf 'rust=%s\n' "$(digest_for_image rust:latest)"
  printf 'golang=%s\n' "$(digest_for_image golang:latest)"
} >> "$GITHUB_OUTPUT"

