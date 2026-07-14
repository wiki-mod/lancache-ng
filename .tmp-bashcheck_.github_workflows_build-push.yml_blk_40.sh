set -euo pipefail
image="$(bash scripts/select-build-tools-image.sh)"
printf 'BUILD_TOOLS_IMAGE=%s\n' "$image" >> "$GITHUB_ENV"
