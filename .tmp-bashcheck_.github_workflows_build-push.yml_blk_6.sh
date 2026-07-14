set -euo pipefail
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$PWD:/work:ro" \
  -w /work \
  -e PR_LABELS_JSON \
  -e PR_MILESTONE_TITLE \
  -e PR_DRAFT \
  -e PR_NUMBER \
  -e REPO \
  -e GH_TOKEN \
  -e PR_IS_FORK \
  "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}" \
  bash scripts/check-pr-tracking-metadata.sh

