set -euo pipefail
bash scripts/require-image-platforms.sh "${{ steps.merge.outputs.source-tag }}" linux/amd64,linux/arm64

