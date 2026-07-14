set -euo pipefail

if ! command -v flock >/dev/null 2>&1; then
  echo "::error::flock is required for safe local Buildx cache locking."
  exit 1
fi

cache_dir="$BUILDX_CACHE_ROOT/build-tools-amd64"
lock_file="$BUILDX_CACHE_ROOT/build-tools-amd64.lock"

mkdir -p "$BUILDX_CACHE_ROOT"
rm -rf "$BUILDX_CACHE_READ" "$BUILDX_CACHE_DEST"
mkdir -p "$BUILDX_CACHE_READ" "$(dirname "$BUILDX_CACHE_DEST")"

(
  flock -x 9
  mkdir -p "$cache_dir"
  cp -a "$cache_dir/." "$BUILDX_CACHE_READ/"
) 9>"$lock_file"

{
  echo "cache-from=$BUILDX_CACHE_READ"
  echo "cache-to=$BUILDX_CACHE_DEST"
} >> "$GITHUB_OUTPUT"

