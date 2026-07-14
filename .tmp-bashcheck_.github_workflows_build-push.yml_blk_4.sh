set -euo pipefail
printf 'BUILD_TOOLS_IMAGE=%s\n' "$(BUILD_TOOLS_REQUIRE_PUBLISHED=true bash scripts/select-build-tools-image.sh)" >> "$GITHUB_ENV"
