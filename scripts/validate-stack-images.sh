#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Validates release/stack-images.yml (the release manifest) against the
# actual repo: required schema/retention fields, that every first-party
# runtime/tooling/metadata image and Dockerfile is declared with the right
# platforms, that compose files reference images only through the
# registry/prefix/tag variables, and that .github/workflows/build-push.yml
# implements the promotion/release/provenance/rollback contract the manifest
# describes. Intended as a CI gate on release infrastructure changes.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
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

runtime_images=(proxy dns watchdog dhcp dhcp-proxy ui)
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
for image in docker-socket-proxy nats fluent-bit syslog-ng netdata busybox; do
  require_name "$external_names" "$image" external
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
require_grep 'services=\(proxy dns watchdog dhcp dhcp-proxy ui build-tools\)' \
  .github/workflows/build-push.yml \
  'promotion and release jobs must share the full first-party service set'

forbidden_latest_default_branch='type=raw,value=latest,enable={{is_default'
forbidden_latest_default_branch="${forbidden_latest_default_branch}_branch}}"
if grep -Fq "$forbidden_latest_default_branch" "$repo_root/.github/workflows/build-push.yml"; then
  fail 'default branch must not publish latest; latest is stable-release only'
fi
require_grep 'channel_tags\+=\(nightly\)' \
  .github/workflows/build-push.yml \
  'default branch promotion must publish the tested nightly channel'
require_grep 'channel_tags\+=\(latest\)' \
  .github/workflows/build-push.yml \
  'stable release promotion must publish latest'
require_grep 'docker buildx imagetools inspect "\$source_image"' \
  .github/workflows/build-push.yml \
  'promotion must verify every sha-* source image before moving a public channel'
require_grep 'imagetools inspect "\$image" --format' \
  scripts/require-image-platforms.sh \
  'the shared platform coverage guard must inspect single-platform image metadata before falling back to text Platform lines'
if awk '!/^[[:space:]]*#/ && /(^|[^[:alnum:]_])jq([[:space:]]|$)/ { found=1 } END { exit found ? 0 : 1 }' "$repo_root/scripts/require-image-platforms.sh"; then
  fail 'the shared platform coverage guard must not require host jq'
fi
require_grep 'bash scripts/require-image-platforms\.sh "ghcr\.io/\$\{REPOSITORY\}/\$\{service\}:\$\{source_tag\}" "\$REQUIRED_PLATFORMS"' \
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
require_grep 'SBOM artifacts are not generated by this workflow yet' \
  .github/workflows/build-push.yml \
  'release notes must not imply SBOM coverage until SBOM generation exists'
require_grep 'rust:latest ->' \
  .github/workflows/build-push.yml \
  'release notes must include the resolved rust:latest base digest for build-tools'
require_grep 'golang:latest ->' \
  .github/workflows/build-push.yml \
  'release notes must include the resolved golang:latest base digest for build-tools'
require_grep 'stable releases require external images in supported profiles to be pinned by digest, mirrored, or explicitly removed from the stable profile' \
  scripts/check-stable-external-images.sh \
  'stable release promotion must fail closed while release-relevant external images are floating'
require_grep 'bash scripts/check-stable-external-images.sh' \
  .github/workflows/build-push.yml \
  'stable release promotion must call the external image gate before moving latest'
require_grep 'expected_prerelease=' \
  .github/workflows/build-push.yml \
  'release job must derive RC prerelease status from the tag'
require_grep '^  RELEASE_PLATFORMS: linux/amd64,linux/arm64$' \
  .github/workflows/build-push.yml \
  'build workflow must publish every platform declared by the stack manifest'
require_grep 'bash scripts/require-image-platforms\.sh "\$image" "\$REQUIRED_PLATFORMS"' \
  .github/workflows/build-push.yml \
  'release workflow must verify every published release image via the shared platform coverage guard'
require_grep 'is missing required platform' \
  scripts/require-image-platforms.sh \
  'the shared platform coverage guard must fail closed when a release image misses a required platform'
require_grep 'cache_dir="/var/tmp/lancache-ng-trivy-cache/\$\{\{ matrix\.service \}\}-\$\{\{ matrix\.platform_tag \}\}-\$\{sanitized_ref\}"' \
  .github/workflows/build-push.yml \
  'container scans must use platform- and ref-specific Trivy cache directories (see #904 -- ref-parallel scans must never share a cache dir)'
require_grep 'cache_dir="/var/tmp/lancache-ng-trivy-cache/build-tools-pushed-\$\{sanitized_ref\}"' \
  .github/workflows/build-push.yml \
  'the pushed build-tools digest scan must use a ref-specific Trivy cache directory too (see #904)'
# #904 follow-through: a cache-dir key only needs to be as fine as its job's
# own concurrency-group key, but must be at least that fine -- container-scan
# and build's build-tools-pushed step both suffix run_id onto the cache dir
# in exactly the workflow_dispatch/rerun condition their own concurrency
# groups already use that suffix for (see those groups' `group:` expressions
# a few checks up). An earlier revision of the #904 fix keyed the cache dir
# on ref alone, which was still coarser than the concurrency-group key for
# the dispatch/rerun case and left that race open; this guard exists so that
# specific regression can't come back silently.
require_grep 'cache_dir="\$\{cache_dir\}-\$\{GITHUB_RUN_ID\}"' \
  .github/workflows/build-push.yml \
  'Trivy cache-dir keys must mirror their concurrency groups run_id suffix for workflow_dispatch/rerun, not just the ref component (see #904)'
require_grep 'SERVICES: proxy dns watchdog dhcp dhcp-proxy ui build-tools stack' \
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
