set -euo pipefail
# tests/setup-migration-semantics.sh only reads setup.sh and writes to
# mktemp -d (container /tmp), so the read-only repo mount is sufficient.
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$PWD:/work:ro" \
  -w /work \
  "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}" \
  bash tests/setup-migration-semantics.sh

