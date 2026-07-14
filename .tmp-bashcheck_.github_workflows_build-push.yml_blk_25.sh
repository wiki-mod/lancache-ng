set -euo pipefail

case "${BUILD_TOOLS_IMAGE:-}" in
  lancache-ng-build-tools-validation:*)
    docker rmi "$BUILD_TOOLS_IMAGE"
    ;;
esac

