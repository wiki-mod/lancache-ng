#!/usr/bin/env python3
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, got {count}")
    return text.replace(old, new, 1)


build_path = Path('.github/workflows/build-push.yml')
build = build_path.read_text(encoding='utf-8')

build = replace_once(
    build,
    "    needs: [detect-changes, merge-manifests, compute-validation-network]\n",
    "    needs: [detect-changes, merge-manifests, compute-validation-network, validate-compose]\n",
    'build-push full-setup direct immutable-toolchain dependency',
)

old_build_compose = '''      - name: Validate compose configuration\n        env:\n          LANCACHE_IMAGE_REGISTRY: ghcr.io\n          LANCACHE_IMAGE_PREFIX: wiki-mod/lancache-ng\n          LANCACHE_IMAGE_TAG: ${{ steps.channel.outputs.tag }}\n          FULL_SETUP_COMPOSE_OVERRIDE: ${{ env.FULL_SETUP_COMPOSE_OVERRIDE }}\n        run: |\n          set -euo pipefail\n\n          docker run --rm \\\n            -v "$PWD/deploy/full-setup:/validation:ro" \\\n            -w /validation \\\n            --env LANCACHE_IMAGE_REGISTRY \\\n            --env LANCACHE_IMAGE_PREFIX \\\n            --env LANCACHE_IMAGE_TAG \\\n            docker:latest \\\n            docker compose -f docker-compose.yml -f "${FULL_SETUP_COMPOSE_OVERRIDE:?FULL_SETUP_COMPOSE_OVERRIDE is required}" config >/dev/null\n'''
new_build_compose = '''      - name: Validate compose configuration\n        env:\n          BUILD_TOOLS_IMAGE: ${{ needs['validate-compose'].outputs.build_tools_image }}\n          LANCACHE_IMAGE_REGISTRY: ghcr.io\n          LANCACHE_IMAGE_PREFIX: wiki-mod/lancache-ng\n          LANCACHE_IMAGE_TAG: ${{ steps.channel.outputs.tag }}\n          FULL_SETUP_COMPOSE_OVERRIDE: ${{ env.FULL_SETUP_COMPOSE_OVERRIDE }}\n        run: |\n          set -euo pipefail\n          : "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"\n\n          # Reuse validate-compose's already smoke-tested, digest-qualified CI toolchain.\n          docker run --rm \\\n            -v "$PWD/deploy/full-setup:/validation:ro" \\\n            -w /validation \\\n            --env LANCACHE_IMAGE_REGISTRY \\\n            --env LANCACHE_IMAGE_PREFIX \\\n            --env LANCACHE_IMAGE_TAG \\\n            "$BUILD_TOOLS_IMAGE" \\\n            timeout --kill-after=30 --signal=KILL 300 \\\n            docker compose -f docker-compose.yml -f "${FULL_SETUP_COMPOSE_OVERRIDE:?FULL_SETUP_COMPOSE_OVERRIDE is required}" config >/dev/null\n'''
build = replace_once(build, old_build_compose, new_build_compose, 'build-push mutable compose helper')
build_path.write_text(build, encoding='utf-8')


sims_path = Path('.github/workflows/full-setup-sims.yml')
sims = sims_path.read_text(encoding='utf-8')

checkout_marker = '''      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n\n      - name: Build full-setup validation image\n'''
checkout_replacement = '''      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n\n      - name: Resolve immutable build-tools image\n        id: build-tools\n        run: |\n          set -euo pipefail\n          build_tools_image="$(BUILD_TOOLS_REQUIRE_PUBLISHED=true bash scripts/select-build-tools-image.sh)"\n          case "$build_tools_image" in\n            *@sha256:*) ;;\n            *)\n              echo "::error::Expected digest-qualified build-tools image, got '$build_tools_image'."\n              exit 1\n              ;;\n          esac\n          printf 'image=%s\\n' "$build_tools_image" >> "$GITHUB_OUTPUT"\n\n      - name: Build full-setup validation image\n'''
sims = replace_once(sims, checkout_marker, checkout_replacement, 'full-setup-sims immutable toolchain selector')

old_sims_compose = '''      - name: Validate compose configuration\n        env:\n          LANCACHE_IMAGE_REGISTRY: ghcr.io\n          LANCACHE_IMAGE_PREFIX: wiki-mod/lancache-ng\n        run: |\n          set -euo pipefail\n          docker run --rm \\\n            -v "$PWD/deploy/full-setup:/validation:ro" \\\n            -w /validation \\\n            --env LANCACHE_IMAGE_REGISTRY \\\n            --env LANCACHE_IMAGE_PREFIX \\\n            --env LANCACHE_IMAGE_TAG \\\n            docker:latest \\\n            docker compose -f docker-compose.yml config >/dev/null\n'''
new_sims_compose = '''      - name: Validate compose configuration\n        env:\n          BUILD_TOOLS_IMAGE: ${{ steps.build-tools.outputs.image }}\n          LANCACHE_IMAGE_REGISTRY: ghcr.io\n          LANCACHE_IMAGE_PREFIX: wiki-mod/lancache-ng\n        run: |\n          set -euo pipefail\n          : "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"\n\n          docker run --rm \\\n            -v "$PWD/deploy/full-setup:/validation:ro" \\\n            -w /validation \\\n            --env LANCACHE_IMAGE_REGISTRY \\\n            --env LANCACHE_IMAGE_PREFIX \\\n            --env LANCACHE_IMAGE_TAG \\\n            "$BUILD_TOOLS_IMAGE" \\\n            timeout --kill-after=30 --signal=KILL 300 \\\n            docker compose -f docker-compose.yml config >/dev/null\n'''
sims = replace_once(sims, old_sims_compose, new_sims_compose, 'full-setup-sims mutable compose helper')
sims_path.write_text(sims, encoding='utf-8')
