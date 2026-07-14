set -euo pipefail
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$PWD:/work:ro" \
  -w /work \
  "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}" \
  bash -lc 'set -euo pipefail; bash scripts/check-line-endings.sh'

