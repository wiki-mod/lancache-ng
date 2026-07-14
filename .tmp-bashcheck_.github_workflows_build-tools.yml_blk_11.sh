set -euo pipefail

short_sha="${GITHUB_SHA::7}"
printf 'image=%s:sha-%s-standalone-arm64\n' "$BUILD_TOOLS_IMAGE" "$short_sha" >> "$GITHUB_OUTPUT"

