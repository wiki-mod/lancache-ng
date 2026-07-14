set -euo pipefail
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$PWD:/work:ro" \
  -w /work \
  "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}" \
  bash -lc 'set -euo pipefail; find . -name "*.sh" -not -path "./.git/*" -not -path "*/target/*" -print0 | xargs -0 --no-run-if-empty shellcheck --severity=warning; actionlint .github/workflows/*.yml'

