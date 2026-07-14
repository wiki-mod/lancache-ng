set -euo pipefail

docker run --rm \
  -v "$PWD/deploy/full-setup:/validation:ro" \
  -w /validation \
  --env LANCACHE_IMAGE_REGISTRY \
  --env LANCACHE_IMAGE_PREFIX \
  --env LANCACHE_IMAGE_TAG \
  docker:latest \
  docker compose -f docker-compose.yml config >/dev/null

