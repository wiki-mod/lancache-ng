set -euo pipefail

# Default to bridge so GitHub-hosted or otherwise non-accelerated paths stay valid.
# Secret-backed jobs switch to host only when the acceleration inputs exist.
rust_network=bridge
buildx_network=default
if [ -n "$SECRET_FILES" ]; then
  rust_network=host
  buildx_network=host
fi
printf 'RUST_ACCELERATION_NETWORK=%s\n' "$rust_network" >> "$GITHUB_ENV"
printf 'RUST_BUILDX_NETWORK=%s\n' "$buildx_network" >> "$GITHUB_ENV"

