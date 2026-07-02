#!/usr/bin/env bash
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

require_file "${manifest#$repo_root/}"
require_grep '^schema: stack-images/v1$' "${manifest#$repo_root/}" 'manifest schema must be stack-images/v1'
require_grep '^registry: ghcr\.io$' "${manifest#$repo_root/}" 'manifest registry must be ghcr.io'
require_grep '^image_prefix: wiki-mod/lancache-ng$' "${manifest#$repo_root/}" 'manifest image_prefix must be wiki-mod/lancache-ng'

runtime_names=$(collect_names runtime)
tooling_names=$(collect_names tooling)
external_names=$(collect_names external)

runtime_images=(proxy dns watchdog dhcp dhcp-proxy ui)
for image in "${runtime_images[@]}"; do
  require_name "$runtime_names" "$image" runtime
done
require_name "$tooling_names" build-tools tooling
for image in docker-socket-proxy nats fluent-bit netdata watchtower; do
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
require_grep 'services=\(proxy dns watchdog dhcp dhcp-proxy ui build-tools\)' \
  .github/workflows/build-push.yml \
  'promotion and release jobs must share the full first-party service set'

forbidden_latest_default_branch='type=raw,value=latest,enable={{is_default'
forbidden_latest_default_branch="${forbidden_latest_default_branch}_branch}}"
if grep -Fq "$forbidden_latest_default_branch" "$repo_root/.github/workflows/build-push.yml"; then
  fail 'default branch must not publish latest; latest is stable-release only'
fi
require_grep 'channel_tags\+=\(edge\)' \
  .github/workflows/build-push.yml \
  'default branch promotion must publish the tested edge channel'
require_grep 'channel_tags\+=\(latest\)' \
  .github/workflows/build-push.yml \
  'stable release promotion must publish latest'
require_grep 'docker buildx imagetools inspect "\$source_image"' \
  .github/workflows/build-push.yml \
  'promotion must verify every sha-* source image before moving a public channel'
require_grep 'digest_for_image\(\)' \
  .github/workflows/build-push.yml \
  'release notes must read immutable image digests'
require_grep 'tag_digest.*!=.*sha_digest|sha_digest.*!=.*tag_digest' \
  .github/workflows/build-push.yml \
  'release notes must verify release tags and sha-* tags resolve to the same digest'
require_grep 'Published image tags and digests' \
  .github/workflows/build-push.yml \
  'release notes must include published image digests'
require_grep 'Stable releases must pin, mirror, or explicitly exclude release-relevant external images before moving latest' \
  .github/workflows/build-push.yml \
  'stable release promotion must fail closed while release-relevant external images are floating'
require_grep 'expected_prerelease=' \
  .github/workflows/build-push.yml \
  'release job must derive RC prerelease status from the tag'

printf 'validate-stack-images: %s looks good\n' "$manifest"
