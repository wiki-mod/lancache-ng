set -euo pipefail

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$PWD:/work:ro" \
  -w /work \
  "${BUILD_TOOLS_SCAN_IMAGE_AMD64:?BUILD_TOOLS_SCAN_IMAGE_AMD64 is required}" \
  bash -lc 'set -euo pipefail; bats tests/bats'

