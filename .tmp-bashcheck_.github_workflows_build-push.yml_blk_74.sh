set -euo pipefail

read -r -a services <<< "$SERVICES"
for service in "${services[@]}"; do
  image="ghcr.io/${REPOSITORY}/${service}:${TAG_NAME}"
  bash scripts/require-image-platforms.sh "$image" "$REQUIRED_PLATFORMS"
done

