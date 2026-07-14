set -euo pipefail

docker build \
  --build-arg LANCACHE_IMAGE_REGISTRY=ghcr.io \
  --build-arg LANCACHE_IMAGE_PREFIX=wiki-mod/lancache-ng \
  --build-arg LANCACHE_IMAGE_TAG="$IMAGE_TAG" \
  -t lancache-ng-full-setup:validation \
  deploy/full-setup

