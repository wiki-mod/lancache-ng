#!/bin/bash
set -euo pipefail
cd /tmp/lancache-1176-val/repo
source scripts/lib/quickstart-compose-lock.sh
quickstart_compose_lock_acquire
BUILD_TOOLS_IMAGE='ghcr.io/wiki-mod/lancache-ng/build-tools:nightly'
docker run --rm \
    --network host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$PWD:$PWD" \
    -w "$PWD" \
    -e SETUP_SIM_IMAGE_CHANNEL=nightly \
    -e SETUP_SIM_IMAGE_TAG= \
    "$BUILD_TOOLS_IMAGE" \
    bash scripts/setup-cli-simulation.sh
