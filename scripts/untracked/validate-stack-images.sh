#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Validates release/stack-images.yml (the release manifest) against the
# actual repo: required schema/retention fields, that every first-party
# runtime/tooling/metadata image and Dockerfile is declared with the right
# platforms, that compose files reference images only through the
# registry/prefix/tag variables, and that .github/workflows/build-push.yml
# implements the promotion/release/provenance/rollback contract the manifest
# describes. Intended as a CI gate on release infrastructure changes.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
manifest=${1:-"$repo_root/release/stack-images.yml"}

fail() {
  printf 'validate-stack-images: %s\n' "$1" >&2
  exit 1
}

require_file() {
  local path=$1
  [[ -f "$repo_root/$path" ]] || fail "missing required file: $path"
}

require_grep() {
  local pattern=$1 path=$2 message=$3
  grep -Eq -- "$pattern" "$repo_root/$path" || fail "$message"
}

collect_names() {
  local section=$1
  awk -v section="$section" '
    $0 == section ":" { in_section=1; next }
    in_section && /^[[:alnum:]_-]+:/ { in_section=0 }
    in_section && /^  - name: / { sub(/^  - name: /, ""); print }
  ' "$manifest"
}

require_name() {
  local names=$1 name=$2 section=$3
  grep -Fxq "$name" <<<"$names" || fail "missing $section image: $name"
}

require_manifest_platform() {
  local name=$1 platform=$2
  awk -v name="$name" -v platform="$platform" '
    $0 == "  - name: " name { in_image=1; next }
    in_image && /^  - name: / { in_image=0 }
    in_image && /^    platforms:/ { in_platforms=1; next }
    in_platforms && $0 == "      - " platform { found=1 }
    in_platforms && /^    [^ ]/ { in_platforms=0 }
    END { exit found ? 0 : 1 }
  ' "$manifest" || fail "manifest must declare $platform platform support for $name"
}

require_file "${manifest#$repo_root/}"
require_grep '^schema: stack-images/v1$' "${manifest#$repo_root/}" 'manifest schema must be stack-images/v1'
require_grep '^registry: ghcr\.io$' "${manifest#$repo_root/}" 'manifest registry must be ghcr.io'
require_grep '^image_prefix: wiki-mod/lancache-ng$' "${manifest#$repo_root/}" 'manifest image_prefix must be wiki-mod/lancache-ng'
require_grep '^retention:$' "${manifest#$repo_root/}" 'manifest must define retention rules'
require_grep '^  minimum_stable_releases: 3$' "${manifest#$repo_root/}" 'retention must keep at least current plus two previous stable releases'
require_grep '^  protect_release_and_rollback_digests: true$' "${manifest#$repo_root/}" 'retention must protect release and rollback digests'
require_grep '^  deletion_policy: manual-or-approved-automation-only$' "${manifest#$repo_root/}" 'retention deletion policy must be explicit'
require_grep '^concurrency:$' .github/workflows/build-push.yml 'build workflow must serialize write-capable package publishing'

runtime_names=$(collect_names runtime)
tooling_names=$(collect_names tooling)
metadata_names=$(collect_names metadata)
external_names=$(collect_names external)

runtime_images=(proxy dns watchdog dhcp dhcp-proxy ui syslog)
for image in "${runtime_images[@]}"; do
  require_name "$runtime_names" "$image" runtime
  require_manifest_platform "$image" linux/amd64
  require_manifest_platform "$image" linux/arm64
done
require_name "$tooling_names" build-tools tooling
require_manifest_platform build-tools linux/amd64
require_manifest_platform build-tools linux/arm64
require_name "$metadata_names" stack metadata
require_manifest_platform stack linux/amd64
require_manifest_platform stack linux/arm64
# fluent-bit and syslog-ng are deliberately NOT checked here anymore (moved
# to the `legacy:` section, see release/stack-images.yml): the syslog+
# fluent-bit consolidation PR replaced both separate third-party-pinned
# images with one first-party `syslog` image (added to runtime_images
# above) that bundles fluent-bit's own exact pinned binary and Alpine's own
# stable-repo syslog-ng package internally -- neither is pulled as its own
# top-level image anymore.
for image in docker-socket-proxy nats netdata busybox; do
  require_name "$external_names" "$image" external
done

for dockerfile in \
  services/proxy/Dockerfile \
  services/dns/Dockerfile \
  services/watchdog/Dockerfile \
  services/dhcp/Dockerfile \
  services/dhcp-proxy/Dockerfile \
  services/ui/Dockerfile \
  services/syslog/Dockerfile \
  tools/build-tools/Dockerfile
do
  require_file "$dockerfile"
done

first_party_ref='\$\{LANCACHE_IMAGE_REGISTRY:-ghcr\.io\}/\$\{LANCACHE_IMAGE_PREFIX:-wiki-mod/lancache-ng\}'
for image in "${runtime_images[@]}"; do
  require_grep "image: ${first_party_ref}/${image}:\\$\\{LANCACHE_IMAGE_TAG:-latest\\}" \
    deploy/prod/docker-compose.yml \
    "prod compose must use registry/prefix/tag variables for $image"
done

require_grep "image: ${first_party_ref}/proxy:\\$\\{LANCACHE_IMAGE_TAG:-latest\\}" \
  deploy/quickstart/docker-compose.yml \
  'quickstart compose must use registry/prefix/tag variables for proxy'
require_grep "image: ${first_party_ref}/dns:\\$\\{LANCACHE_IMAGE_TAG:-latest\\}" \
  deploy/quickstart/docker-compose.yml \
  'quickstart compose must use registry/prefix/tag variables for dns'
require_grep "image: ${first_party_ref}/watchdog:\\$\\{LANCACHE_IMAGE_TAG:-latest\\}" \
  deploy/quickstart/docker-compose.yml \
  'quickstart compose must use registry/prefix/tag variables for watchdog'
require_grep "image: ${first_party_ref}/ui:\\$\\{LANCACHE_IMAGE_TAG:-latest\\}" \
  deploy/quickstart/docker-compose.yml \
  'quickstart compose must use registry/prefix/tag variables for ui'
# dhcp/dhcp-proxy/ntp/syslog all define a real service in
# deploy/quickstart/docker-compose.yml (confirmed 2026-08-06 by reading that
# file directly), same as the four checked above, but had no check here --
# release/stack-images.yml's own dhcp/dhcp-proxy/ntp `compose:` lists were
# separately found missing the quickstart entry entirely (issue #849
# dhcp-proxy.md finding #12) and fixed alongside this; syslog's manifest
# entry already listed quickstart correctly, it just had no check. Unlike
# the prod-level loop above (over runtime_images, already generalized),
# this quickstart list stays one require_grep per service rather than a
# blanket loop: not every runtime image is actually deployed by the
# quickstart profile (dns's own two prod instances collapse to a single
# dns-standard/dns-ssl pair there, for example), so a loop over
# runtime_images would need its own per-service exclusion list to stay
# correct -- no cheaper than the explicit list this already is.
require_grep "image: ${first_party_ref}/dhcp:\\$\\{LANCACHE_IMAGE_TAG:-latest\\}" \
  deploy/quickstart/docker-compose.yml \
  'quickstart compose must use registry/prefix/tag variables for dhcp'
require_grep "image: ${first_party_ref}/dhcp-proxy:\\$\\{LANCACHE_IMAGE_TAG:-latest\\}" \
  deploy/quickstart/docker-compose.yml \
  'quickstart compose must use registry/prefix/tag variables for dhcp-proxy'
require_grep "image: ${first_party_ref}/ntp:\\$\\{LANCACHE_IMAGE_TAG:-latest\\}" \
  deploy/quickstart/docker-compose.yml \
  'quickstart compose must use registry/prefix/tag variables for ntp'
require_grep "image: ${first_party_ref}/syslog:\\$\\{LANCACHE_IMAGE_TAG:-latest\\}" \
  deploy/quickstart/docker-compose.yml \
  'quickstart compose must use registry/prefix/tag variables for syslog'
require_grep "image: ${first_party_ref}/dns:\\$\\{LANCACHE_IMAGE_TAG:-latest\\}" \
  deploy/secondary/docker-compose.yml \
  'secondary compose must use registry/prefix/tag variables for dns'

if grep -RIn 'ghcr.io/wiki-mod/lancache-ng/.*:\${LANCACHE_IMAGE_TAG:-latest}' \
  "$repo_root"/deploy/prod \
  "$repo_root"/deploy/quickstart \
  "$repo_root"/deploy/secondary; then
  fail 'first-party compose image references must go through LANCACHE_IMAGE_REGISTRY and LANCACHE_IMAGE_PREFIX'
fi

if grep -RIn 'proxy-standard' "$repo_root"/deploy "$repo_root"/setup.sh "$repo_root"/README.md; then
  fail 'retired proxy-standard package must not appear in active runtime paths'
fi

for image in "${runtime_images[@]}" build-tools; do
  require_grep "- service: ${image}$" .github/workflows/build-push.yml "build matrix must include $image"
done
for dockerfile in \
  services/proxy/Dockerfile \
  services/dns/Dockerfile \
  services/watchdog/Dockerfile \
  services/dhcp/Dockerfile \
  services/dhcp-proxy/Dockerfile \
  services/ui/Dockerfile \
  tools/build-tools/Dockerfile
do
  require_grep 'LABEL org\.opencontainers\.image\.description=' \
    "$dockerfile" \
    "$dockerfile must define an OCI image description label"
done
require_grep 'description: .+' \
  .github/workflows/build-push.yml \
  'build matrix entries must define OCI image descriptions'
require_grep 'org\.opencontainers\.image\.description=\$\{\{ matrix\.description \}\}' \
  .github/workflows/build-push.yml \
  'build workflow must publish OCI image description labels'
require_grep 'annotation "index:org\.opencontainers\.image\.description=' \
  .github/workflows/build-push.yml \
  'build workflow must publish OCI image description index annotations'
require_grep 'outputs: type=image,oci-mediatypes=true' \
  .github/workflows/build-push.yml \
  'per-platform service builds must force OCI mediatypes so downstream imagetools create can actually attach index annotations'
# build-tools.yml is a second, independent publisher of the build-tools
# image (weekly cron/push/dispatch, moving build-tools:latest and mutable
# branch tags) -- most CI/dev paths actually consume its tags, not
# build-push.yml's own build-tools matrix row's sha-<commit>-only output.
# It needs the identical OCI-mediatype/annotation fix, not just
# build-push.yml (issue #620).
require_grep 'outputs: type=image,oci-mediatypes=true' \
  .github/workflows/build-tools.yml \
  'build-tools.yml per-platform builds must force OCI mediatypes so its own merge step can actually attach index annotations'
require_grep 'annotation "index:org\.opencontainers\.image\.description=' \
  .github/workflows/build-tools.yml \
  'build-tools.yml must publish an OCI image description index annotation on its merged multi-platform manifest'
# #1428: syslog joined build-push.yml's own promotion/release
# services=(...) arrays alongside ntp -- this pattern must stay byte-for-byte
# in sync with those arrays (see check-workflow-service-lists.sh for the
# broader, build-matrix-derived guard that keeps every OTHER services=(...)
# copy in this repo in sync; this one specific literal is a narrower,
# release/promotion-scoped check that guard does not reach).
require_grep 'services=\(proxy dns watchdog dhcp dhcp-proxy ntp syslog ui build-tools\)' \
  .github/workflows/build-push.yml \
  'promotion and release jobs must share the full first-party service set'

forbidden_latest_default_branch='type=raw,value=latest,enable={{is_default'
forbidden_latest_default_branch="${forbidden_latest_default_branch}_branch}}"
if grep -Fq "$forbidden_latest_default_branch" "$repo_root/.github/workflows/build-push.yml"; then
  fail 'default branch must not publish latest via an unaudited build-time tag; latest may only move through the gated promote job'
fi
# #825/#1141 branch-model decision: master -> latest, archived vY.X.Z
# branches -> no live channel. current_dev's own mapping was SUPERSEDED by
# #1254/#1255 below. Scoped to each branch's own if/elif arm (not a flat grep
# for the channel_tags line alone) so a regression that keeps both literal
# strings in the file but ties them to the wrong branch would still be
# caught -- mirrors the equivalent guard in build-push.yml's own
# governance-guards job.
if ! awk '
  /if \[\[ "\$GITHUB_REF" = "refs\/heads\/master" \]\]; then/ { in_branch=1; next }
  in_branch && /^ *elif/ { in_branch=0 }
  in_branch && /channel_tags\+=\(latest\)/ { found=1 }
  END { exit found ? 0 : 1 }
' "$repo_root/.github/workflows/build-push.yml"; then
  fail 'master branch promotion must publish the latest channel'
fi
# #1254/#1255 (2026-07-25): current_dev push must NOT auto-publish nightly
# anymore (nightly is now a real once-daily scheduled/dispatch-only,
# green-gated channel -- see nightly-refresh.yml). Mirror image of the old
# check above: fails if the auto-publish regresses back in.
if awk '
  /elif \[\[ "\$GITHUB_REF" = "refs\/heads\/current_dev" \]\]; then/ { in_branch=1; next }
  in_branch && /^ *elif/ { in_branch=0 }
  in_branch && /channel_tags\+=\(nightly\)/ { found=1 }
  END { exit found ? 0 : 1 }
' "$repo_root/.github/workflows/build-push.yml"; then
  fail 'current_dev push must no longer auto-publish the nightly channel (#1254/#1255); nightly is promoted only via the scheduled/manual channel-input dispatch path (see nightly-refresh.yml)'
fi
require_file '.github/workflows/nightly-refresh.yml'
if ! { grep -Fq 'build-push.yml' "$repo_root/.github/workflows/nightly-refresh.yml" \
    && grep -Fq 'current_dev' "$repo_root/.github/workflows/nightly-refresh.yml" \
    && grep -Fq 'channel=nightly' "$repo_root/.github/workflows/nightly-refresh.yml"; }; then
  fail 'nightly-refresh.yml must dispatch build-push.yml against current_dev with channel=nightly (#1254/#1255)'
fi
if ! awk '
  /^ *channel_tags=\(\)$/ { in_scope=1; next }
  in_scope && /if \(\( \$\{#channel_tags\[@\]\} == 0 \)\)/ { in_scope=0 }
  in_scope && /elif \[\[ "\$GITHUB_REF" = refs\/heads\/v\[0-9\]\* \]\]; then/ { found=1 }
  END { exit found ? 1 : 0 }
' "$repo_root/.github/workflows/build-push.yml"; then
  fail "archived vY.X.Z release branches must not publish a live channel tag; the old 'dev' channel mapping was retired (#825/#1141)"
fi
require_grep 'channel_tags\+=\(latest\)' \
  .github/workflows/build-push.yml \
  'stable release promotion must publish latest'
require_grep 'docker buildx imagetools inspect "\$source_image"' \
  .github/workflows/build-push.yml \
  'promotion must verify every sha-* source image before moving a public channel'
require_grep 'imagetools inspect "\$image" --format' \
  scripts/untracked/require-image-platforms.sh \
  'the shared platform coverage guard must inspect single-platform image metadata before falling back to text Platform lines'
if awk '!/^[[:space:]]*#/ && /(^|[^[:alnum:]_])jq([[:space:]]|$)/ { found=1 } END { exit found ? 0 : 1 }' "$repo_root/scripts/untracked/require-image-platforms.sh"; then
  fail 'the shared platform coverage guard must not require host jq'
fi
require_grep 'bash scripts/untracked/require-image-platforms\.sh "ghcr\.io/\$\{REPOSITORY\}/\$\{service\}:\$\{source_tag\}" "\$REQUIRED_PLATFORMS"' \
  .github/workflows/build-push.yml \
  'promotion must verify every sha-* service image platform before moving public tags'
require_grep 'rollback_promotions\(\)' \
  .github/workflows/build-push.yml \
  'promotion must attempt rollback if a public channel move fails midway'
require_grep 'previous_refs\["\$target_image"\]' \
  .github/workflows/build-push.yml \
  'promotion must remember previous channel digests before moving public tags'
require_grep 'stack_pointer_image="ghcr\.io/\$\{REPOSITORY\}/stack:\$\{source_tag\}"' \
  .github/workflows/build-push.yml \
  'promotion must create an immutable stack pointer image for the source commit'
require_grep 'LANCACHE_IMAGE_TAG=%s\\n' \
  .github/workflows/build-push.yml \
  'stack pointer image must contain the resolved immutable service image tag'
require_grep 'FROM busybox:stable-musl' \
  .github/workflows/build-push.yml \
  'stack pointer image must use an explicit minimal runtime base so docker create can read stack.env'
require_grep 'CMD \["true"\]' \
  .github/workflows/build-push.yml \
  'stack pointer image must have a harmless command so docker create works consistently'
require_grep 'docker buildx imagetools create --prefer-index=false -t "\$target_image" "\$stack_pointer_image"' \
  .github/workflows/build-push.yml \
  'promotion must preserve single-platform manifest metadata when moving the stack channel pointer'
require_grep 'docker buildx imagetools create --prefer-index=false -t "\$target_image" "\$source_image"' \
  .github/workflows/build-push.yml \
  'promotion must preserve single-platform service image metadata when moving channel tags'
# #822: every actions/attest invocation now goes through the
# ghcr-attest-retry composite action (retry + fresh re-login on a transient
# GHCR 401) instead of a bare `uses: actions/attest@...` step, so the literal
# "actions/attest@" pin and its `push-to-registry: true` input live in that
# composite action's own action.yml, not in build-push.yml.
require_grep 'uses: \./\.github/actions/ghcr-attest-retry' \
  .github/workflows/build-push.yml \
  'release workflow must create provenance attestations for published first-party images through the shared GHCR retry wrapper'
require_grep 'actions/attest@' \
  .github/actions/ghcr-attest-retry/action.yml \
  'the attestation retry wrapper must still call the real actions/attest action'
require_grep 'push-to-registry: true' \
  .github/actions/ghcr-attest-retry/action.yml \
  'provenance attestations must be pushed to the registry'
# build/build-arm64's "Build and push" step (#822) now runs through
# ghcr-build-push-retry instead of a bare docker/build-push-action + inline
# "retry-build" sibling step, so steps.build.outputs.digest already resolves
# to whichever internal attempt succeeded -- there is no separate
# "retry-build" step id left to fall back to.
require_grep 'subject-digest: \$\{\{ steps\.build\.outputs\.digest \}\}' \
  .github/workflows/build-push.yml \
  'provenance attestations must bind to the pushed image digest'
require_grep 'digest_for_image\(\)' \
  .github/workflows/build-push.yml \
  'release notes must read immutable image digests'
require_grep 'tag_digest.*!=.*sha_digest|sha_digest.*!=.*tag_digest' \
  .github/workflows/build-push.yml \
  'release notes must verify release tags and sha-* tags resolve to the same digest'
require_grep 'Published image tags and digests' \
  .github/workflows/build-push.yml \
  'release notes must include published image digests'
require_grep 'Resolved build-tools base image digests' \
  .github/workflows/build-push.yml \
  'release notes must include resolved build-tools base image digests'
require_grep 'Stack channel pointer' \
  .github/workflows/build-push.yml \
  'release notes must include the stack channel pointer digest'
require_grep 'Provenance and SBOM status' \
  .github/workflows/build-push.yml \
  'release notes must explicitly state provenance and SBOM status'
require_grep 'Provenance attestations are pushed to GHCR for every first-party' \
  .github/workflows/build-push.yml \
  'release notes must state where first-party provenance attestations are published'
require_grep 'CycloneDX SBOMs are generated per released first-party image digest' \
  .github/workflows/build-push.yml \
  'release notes must state that per-image CycloneDX SBOMs are generated and attached as release assets'
require_grep 'An OpenVEX document generated from .trivyignore.yaml is attached to this release' \
  .github/workflows/build-push.yml \
  'release notes must state that the OpenVEX document is attached as a release asset'
require_grep 'rust:latest ->' \
  .github/workflows/build-push.yml \
  'release notes must include the resolved rust:latest base digest for build-tools'
require_grep 'golang:latest ->' \
  .github/workflows/build-push.yml \
  'release notes must include the resolved golang:latest base digest for build-tools'
require_grep 'stable releases require external images in supported profiles to be pinned by digest, mirrored, or explicitly removed from the stable profile' \
  scripts/tracked/check-stable-external-images.sh \
  'stable release promotion must fail closed while release-relevant external images are floating'
require_grep 'bash scripts/tracked/check-stable-external-images.sh' \
  .github/workflows/build-push.yml \
  'stable release promotion must call the external image gate before moving latest'
require_grep 'expected_prerelease=' \
  .github/workflows/build-push.yml \
  'release job must derive RC prerelease status from the tag'
require_grep '^  RELEASE_PLATFORMS: linux/amd64,linux/arm64$' \
  .github/workflows/build-push.yml \
  'build workflow must publish every platform declared by the stack manifest'
require_grep 'bash scripts/untracked/require-image-platforms\.sh "\$image" "\$REQUIRED_PLATFORMS"' \
  .github/workflows/build-push.yml \
  'release workflow must verify every published release image via the shared platform coverage guard'
require_grep 'is missing required platform' \
  scripts/untracked/require-image-platforms.sh \
  'the shared platform coverage guard must fail closed when a release image misses a required platform'
# container-scan's OWN per-run local-build cache dir (the same literal pattern this
# check used to require) was removed along with the local-build branch it belonged to
# (issue #1095): container-scan no longer builds or scans anything locally for a
# changed service, so there is no cache dir left to key. The surviving check below (the
# pushed-digest scan's cache dir, in build/build-arm64) still enforces #904's real
# invariant for the one Trivy cache directory that still exists.
require_grep 'cache_dir="/var/tmp/lancache-ng-trivy-cache/\$\{MATRIX_SERVICE\}-pushed-\$\{sanitized_ref\}"' \
  .github/workflows/build-push.yml \
  'the pushed per-service digest scan must use a service- and ref-specific Trivy cache directory too (see #904; widened from build-tools-only to every service by Step 3, issue #1095)'
# #904 follow-through: a cache-dir key only needs to be as fine as its job's
# own concurrency-group key, but must be at least that fine -- container-scan
# and build's pushed-service-digest-scan step both suffix run_id onto the
# cache dir in exactly the workflow_dispatch/rerun condition their own
# concurrency groups already use that suffix for (see those groups' `group:`
# expressions a few checks up). An earlier revision of the #904 fix keyed the
# cache dir on ref alone, which was still coarser than the concurrency-group
# key for the dispatch/rerun case and left that race open; this guard exists
# so that specific regression can't come back silently. Step 3 (issue
# #1095) widened the pushed-digest cache dir from build-tools-only to every
# service, so this guard was updated in lockstep to check for the
# matrix.service-scoped key rather than the old hardcoded "build-tools-"
# prefix -- otherwise this guard itself would have silently stopped
# verifying anything real for 7 of 8 services.
require_grep 'cache_dir="\$\{cache_dir\}-\$\{GITHUB_RUN_ID\}"' \
  .github/workflows/build-push.yml \
  'Trivy cache-dir keys must mirror their concurrency groups run_id suffix for workflow_dispatch/rerun, not just the ref component (see #904)'
# #1428: syslog joined this SERVICES scalar too, same reason as line 180's
# services=(...) pattern above.
require_grep 'SERVICES: proxy dns watchdog dhcp dhcp-proxy ntp syslog ui build-tools stack' \
  .github/workflows/build-push.yml \
  'release workflow must verify the stack pointer platform coverage too'
require_grep 'assert_prebuilt_image_platform_supported' \
  setup.sh \
  'setup must fail closed on unsupported prebuilt-image platforms'
require_grep 'resolve_lancache_stack_channel_tag\(\)' \
  setup.sh \
  'setup must resolve mutable stack channels through the stack pointer image'
require_grep 'docker pull "\$stack_image"' \
  setup.sh \
  'setup must pull the stack pointer image before resolving a mutable channel'
require_grep 'docker cp "\$\{container_id\}:/stack.env" -' \
  setup.sh \
  'setup must read stack.env from the stack pointer image'
require_grep 'LANCACHE_IMAGE_CHANNEL=\$\{LANCACHE_IMAGE_CHANNEL\}' \
  setup.sh \
  'setup must persist the selected image channel separately from the resolved immutable tag'
require_grep 'pub image_registry: String' \
  services/ui/src/routes/secondaries.rs \
  'secondary registration response must expose image_registry for mirror/private-registry setups'
require_grep 'pub image_prefix: String' \
  services/ui/src/routes/secondaries.rs \
  'secondary registration response must expose image_prefix for mirror/private-registry setups'
require_grep 'pub image_channel: String' \
  services/ui/src/routes/secondaries.rs \
  'secondary registration response must expose image_channel for mutable-channel setup'
require_grep 'image_registry: state.config.lancache_image_registry.clone\(\)' \
  services/ui/src/routes/secondaries.rs \
  'secondary registration response must use the primary LANCACHE_IMAGE_REGISTRY'
require_grep 'image_prefix: state.config.lancache_image_prefix.clone\(\)' \
  services/ui/src/routes/secondaries.rs \
  'secondary registration response must use the primary LANCACHE_IMAGE_PREFIX'
require_grep 'image_channel: state.config.lancache_image_channel.clone\(\)' \
  services/ui/src/routes/secondaries.rs \
  'secondary registration response must use the primary LANCACHE_IMAGE_CHANNEL'
require_grep 'response_image_registry=\$\(echo "\$response"' \
  setup.sh \
  'setup.sh secondary must parse the primary image_registry'
require_grep 'response_image_prefix=\$\(echo "\$response"' \
  setup.sh \
  'setup.sh secondary must parse the primary image_prefix'
require_grep 'response_image_channel=\$\(echo "\$response"' \
  setup.sh \
  'setup.sh secondary must parse the primary image_channel'
require_grep 'LANCACHE_IMAGE_REGISTRY=\$\{lancache_image_registry\}' \
  setup.sh \
  'setup.sh secondary must write the resolved registry instead of a hard-coded default'
require_grep 'LANCACHE_IMAGE_PREFIX=\$\{lancache_image_prefix\}' \
  setup.sh \
  'setup.sh secondary must write the resolved image prefix instead of a hard-coded default'

printf 'validate-stack-images: %s looks good\n' "$manifest"
