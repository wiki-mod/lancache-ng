set -euo pipefail

secret_args=()
if [ -n "$SCCACHE_REDIS_FILE" ]; then
  secret_args+=(--secret "id=sccache_redis_url,src=$SCCACHE_REDIS_FILE")
fi
if [ -n "$SCCACHE_DIST_CONFIG_FILE" ]; then
  secret_args+=(--secret "id=sccache_dist_config,src=$SCCACHE_DIST_CONFIG_FILE")
fi
if [ -n "$DISTCC_HOSTS_FILE" ]; then
  secret_args+=(--secret "id=distcc_potential_hosts,src=$DISTCC_HOSTS_FILE")
fi

build_context_args=()
if [ -n "${MATRIX_BUILD_CONTEXTS:-}" ]; then
  build_context_args+=(--build-context "$MATRIX_BUILD_CONTEXTS")
fi

scan_build_network="${RUST_BUILDX_NETWORK:-default}"
if [ "$scan_build_network" = "bridge" ]; then
  scan_build_network=default
fi
allow_args=()
if [ "$scan_build_network" = "host" ]; then
  allow_args+=(--allow network.host)
fi

docker buildx build \
  --load \
  --pull \
  --platform ${{ matrix.platform }} \
  --network "$scan_build_network" \
  "${allow_args[@]}" \
  --build-arg "BUILD_TOOLS_IMAGE=$BUILD_TOOLS_IMAGE" \
  --build-arg "CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS" \
  "${secret_args[@]}" \
  "${build_context_args[@]}" \
  -t lancache-ng-scan:${{ matrix.service }}-${{ matrix.platform_tag }}-${{ github.run_id }} \
  ${{ matrix.context }}
