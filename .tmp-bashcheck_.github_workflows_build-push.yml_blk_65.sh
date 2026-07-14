set -euo pipefail

if [ ! -d "$BUILDX_CACHE_DEST" ]; then
  exit 0
fi

cache_dir="$BUILDX_CACHE_ROOT/${{ matrix.service }}"
lock_file="$BUILDX_CACHE_ROOT/${{ matrix.service }}.lock"

mkdir -p "$BUILDX_CACHE_ROOT"
(
  flock -x 9
  rm -rf "$BUILDX_CACHE_ROOT/${{ matrix.service }}"
  mv "$BUILDX_CACHE_DEST" "$cache_dir"
) 9>"$lock_file"

