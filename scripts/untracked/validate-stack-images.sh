#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: validates stack-images: schema, platforms, compose.
# Why: asserts manifest and workflow/compose state agreement.
# From: PR #1501.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
manifest=${1:-"$repo_root/release/stack-images.yml"}
# What: sources sha-retention-audit.sh's shared parsing library.
# Why: both checks must share one canonical rollback_anchors rule.
# From: Issue #1095 | PR #1501.
# shellcheck source=scripts/lib/sha-retention-audit.sh
source "$repo_root/scripts/lib/sha-retention-audit.sh"

# fail <message>
# What: prints a prefixed error to stderr and exits 1.
# Why: centralizes exit path so failures are immediately visible.
# From: PR #1501.
fail() {
  printf 'validate-stack-images: %s\n' "$1" >&2
  exit 1
}

# What: require_file() fails if a repo-relative path is missing.
# Why: catches manifest field errors before build failures.
# From: PR #1501.
require_file() {
  local path=$1
  [[ -f "$repo_root/$path" ]] || fail "missing required file: $path"
}

# What: require_grep() fails unless pattern matches a file.
# Why: pairs each pattern with contract it proves in one line.
# From: PR #1501.
require_grep() {
  local pattern=$1 path=$2 message=$3
  grep -Eq -- "$pattern" "$repo_root/$path" || fail "$message"
}

# What: collect_names() prints every `- name:` in a section.
# Why: manifest lacks per-section index, parses raw YAML directly.
# From: PR #1501.
collect_names() {
  local section=$1
  awk -v section="$section" '
    $0 == section ":" { in_section=1; next }
    in_section && /^[[:alnum:]_-]+:/ { in_section=0 }
    in_section && /^  - name: / { sub(/^  - name: /, ""); print }
  ' "$manifest"
}

# What: require_name() fails unless name appears exactly in list.
# Why: exact match prevents typos and renames silently passing.
# From: PR #1501.
require_name() {
  local names=$1 name=$2 section=$3
  grep -Fxq "$name" <<<"$names" || fail "missing $section image: $name"
}

# What: require_manifest_platform() validates platform coverage.
# Why: platform gaps silently under-declare build capabilities.
# From: PR #1501.
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
require_grep '^  accepted_ordinary_roots_per_package: 30$' "${manifest#$repo_root/}" 'retention must keep exactly thirty accepted ordinary root identities per first-party package'
require_grep '^  channel_buffer_versions: 5$' "${manifest#$repo_root/}" 'retention must keep exactly five buffered non-ordinary/non-channel versions per package (issue #1585 v1.2)'
require_grep '^  protect_release_and_rollback_digests: true$' "${manifest#$repo_root/}" 'retention must protect release and rollback digests'
require_grep '^  rollback_anchors:$' "${manifest#$repo_root/}" 'retention must define a rollback_anchors list (may be empty)'
# What: validates rollback_anchors format via shared library.
# Why: static format check only; existence is gc-sha-retention.sh.
# From: Issue #1095 | PR #1501.
require_rollback_anchors_format() {
  local anchors_raw error_message
  if anchors_raw="$(sra_read_rollback_anchors "$manifest")"; then
    :
  else
    fail 'retention rollback_anchors must be a well-formed manifest list (no duplicate header)'
  fi
  if error_message="$(sra_validate_rollback_anchors_list "$anchors_raw")"; then
    :
  else
    fail "retention rollback_anchors ${error_message}"
  fi
}
require_rollback_anchors_format
require_grep '^  deletion_policy: manual-or-approved-automation-only$' "${manifest#$repo_root/}" 'retention deletion policy must be explicit'
require_grep '^concurrency:$' .github/workflows/build-push.yml 'build workflow must serialize write-capable package publishing'

runtime_names=$(collect_names runtime)
tooling_names=$(collect_names tooling)
metadata_names=$(collect_names metadata)
external_names=$(collect_names external)

runtime_images=(proxy dns watchdog dhcp dhcp-proxy ntp ui syslog)
# runtime_images is a hand-maintained copy of the manifest's own runtime:
# section (collected into runtime_names above) -- nothing keeps the two in
# sync mechanically otherwise. A service present in the manifest but missing
# from this array would silently never get checked against the manifest,
# compose files, or the build matrix below, so assert the two sets are
# identical rather than only ever iterating over this array's own (possibly
# incomplete) contents.
runtime_images_sorted="$(printf '%s\n' "${runtime_images[@]}" | sort)"
runtime_names_sorted="$(sort <<<"$runtime_names")"
[[ "$runtime_images_sorted" == "$runtime_names_sorted" ]] || fail "runtime_images must match every runtime image declared by release/stack-images.yml"
for image in "${runtime_images[@]}"; do
  require_name "$runtime_names" "$image" runtime
  require_manifest_platform "$image" linux/amd64
  require_manifest_platform "$image" linux/arm64
done
require_name "$tooling_names" build-tools tooling
require_manifest_platform build-tools linux/amd64
require_manifest_platform build-tools linux/arm64
require_name "$tooling_names" utilities tooling
require_manifest_platform utilities linux/amd64
require_manifest_platform utilities linux/arm64
require_name "$metadata_names" stack metadata
require_manifest_platform stack linux/amd64
require_manifest_platform stack linux/arm64
# What: skips fluent-bit/syslog-ng check (moved to legacy section).
# Why: syslog image bundles both internally, not pulled standalone.
# From: PR #1501.
for image in docker-socket-proxy nats netdata busybox; do
  require_name "$external_names" "$image" external
done

for dockerfile in \
  services/proxy/Dockerfile \
  services/dns/Dockerfile \
  services/watchdog/Dockerfile \
  services/dhcp/Dockerfile \
  services/dhcp-proxy/Dockerfile \
  services/ntp/Dockerfile \
  services/ui/Dockerfile \
  services/syslog/Dockerfile \
  tools/build-tools/Dockerfile \
  services/utilities/Dockerfile
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
# What: explicitly checks dhcp/dhcp-proxy/ntp/syslog in quickstart.
# Why: quickstart differs from runtime; needs explicit list.
# From: PR #1501.
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
  services/ntp/Dockerfile \
  services/ui/Dockerfile \
  services/syslog/Dockerfile \
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
# What: requires build-tools.yml OCI mediatypes and annotations.
# Why: build-tools.yml publishes independently from build-push.
# From: PR #1501.
require_grep 'outputs: type=image,oci-mediatypes=true' \
  .github/workflows/build-tools.yml \
  'build-tools.yml per-platform builds must force OCI mediatypes so its own merge step can actually attach index annotations'
require_grep 'annotation "index:org\.opencontainers\.image\.description=' \
  .github/workflows/build-tools.yml \
  'build-tools.yml must publish an OCI image description index annotation on its merged multi-platform manifest'
# Promotion and release jobs now all read the shared CI_BUILD_SERVICES env
# scalar (read -ra services <<< "$CI_BUILD_SERVICES") rather than each
# carrying its own hand-duplicated services=(...) literal -- this check was
# updated in lockstep with that consolidation so it keeps verifying a real,
# still-present pattern instead of a literal array shape build-push.yml no
# longer contains. #1428 (syslog) and #1556 (utilities) both joined the
# first-party service set after this consolidation landed; both are covered
# here because CI_BUILD_SERVICES already carries them.
require_grep 'CI_BUILD_SERVICES: "proxy dns watchdog dhcp dhcp-proxy ntp syslog ui build-tools utilities"' \
  .github/workflows/build-push.yml \
  'promotion and release jobs must share the full first-party service set'
# release-sbom's own `service: [...]` flow-sequence matrix is a fourth,
# independent copy of the same service-list class: it is neither a `-
# service:` build-matrix entry (so scripts/tracked/check-workflow-service-lists.sh's
# canonical extraction never sees it) nor a `services=(...)`/
# `full_setup_services=(...)` bash array (so that same guard's own array
# checks don't reach it either) -- syslog silently missing from just this
# one copy (while every other released first-party image already got a
# CycloneDX SBOM) is exactly the drift shape this narrower literal check
# exists to catch mechanically instead of relying on manual review to
# notice a fifth recurrence.
require_grep 'service: \[proxy, dns, watchdog, dhcp, dhcp-proxy, ntp, syslog, ui, build-tools, utilities\]' \
  .github/workflows/build-push.yml \
  'release-sbom must cover every Trivy-scanned first-party image (mirrors container-scan matrix)'

forbidden_latest_default_branch='type=raw,value=latest,enable={{is_default'
forbidden_latest_default_branch="${forbidden_latest_default_branch}_branch}}"
if grep -Fq "$forbidden_latest_default_branch" "$repo_root/.github/workflows/build-push.yml"; then
  fail 'default branch must not publish latest via an unaudited build-time tag; latest may only move through the gated promote job'
fi
# What: checks channel_tags+=(latest) in master's if/elif arm.
# Why: flat grep fails if wrong branch; arm scope catches it.
# From: PR #1501.
if ! awk '
  /if \[\[ "\$GITHUB_REF" = "refs\/heads\/master" \]\]; then/ { in_branch=1; next }
  in_branch && /^ *elif/ { in_branch=0 }
  in_branch && /channel_tags\+=\(latest\)/ { found=1 }
  END { exit found ? 0 : 1 }
' "$repo_root/.github/workflows/build-push.yml"; then
  fail 'master branch promotion must publish the latest channel'
fi
# What: fails if current_dev auto-publishes nightly (dispatch only).
# Why: nightly is dispatch-only via nightly-refresh.yml.
# From: PR #1501.
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
require_grep 'source_tag_digest="\$\(digest_for_image "\$source_tag_image"\)"' \
  .github/workflows/build-push.yml \
  'promotion must verify the sha-* record still resolves to the exact producer digest before moving a public channel'
require_grep 'imagetools inspect "\$image" --format' \
  scripts/untracked/require-image-platforms.sh \
  'the shared platform coverage guard must inspect single-platform image metadata before falling back to text Platform lines'
if awk '!/^[[:space:]]*#/ && /(^|[^[:alnum:]_])jq([[:space:]]|$)/ { found=1 } END { exit found ? 0 : 1 }' "$repo_root/scripts/untracked/require-image-platforms.sh"; then
  fail 'the shared platform coverage guard must not require host jq'
fi
# CI 1.1: the promotion step verifies platform coverage against the exact
# same-repo PR image digest (`@${expected_digest}`) it is about to promote,
# not a moving `:${source_tag}` tag reference -- scanning the tag would risk
# checking a different image than the one actually promoted if the tag moved
# between the scan and the promotion step.
require_grep 'bash scripts/untracked/require-image-platforms\.sh "ghcr\.io/\$\{REPOSITORY\}/\$\{service\}@\$\{expected_digest\}" "\$REQUIRED_PLATFORMS"' \
  .github/workflows/build-push.yml \
  'promotion must verify every exact service digest platform before moving public tags'
require_grep 'rollback_promotions\(\)' \
  .github/workflows/build-push.yml \
  'promotion must attempt rollback if a public channel move fails midway'
require_grep 'previous_refs\["\$target_image"\]' \
  .github/workflows/build-push.yml \
  'promotion must remember previous channel digests before moving public tags'
require_grep 'stack_pointer_image="ghcr\.io/\$\{REPOSITORY\}/stack@\$\{STACK_DIGEST\}"' \
  .github/workflows/build-push.yml \
  'promotion must consume the immutable stack pointer digest created before validation'
# CI 1.1 deliberately keeps the existing immutable stack pointer/stack.env
# contract rather than introducing a separate stack-bom.json artifact (that
# BOM/Stack-Lock design is out of scope here, tracked under the broader V2
# work) -- so this validator only asserts stack.env's own presence
# below, not a stack-bom.json file build-push.yml no longer builds.
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
# What: checks actions/attest in centralized pin-owner wrapper.
# Why: ghcr-attest-retry calls wrapper instead of actions/attest.
# From: Issue #1095 | PR #1501.
require_grep 'uses: \./\.github/actions/ghcr-attest-retry' \
  .github/workflows/build-push.yml \
  'release workflow must create provenance attestations for published first-party images through the shared GHCR retry wrapper'
require_grep 'actions/attest@' \
  .github/actions/actions-attest-centralized-version/action.yml \
  'the centralized attest wrapper must still call the real actions/attest action'
require_grep 'push-to-registry: true' \
  .github/actions/actions-attest-centralized-version/action.yml \
  'provenance attestations must be pushed to the registry'
# What: checks steps.build.outputs.digest via push-retry wrapper.
# Why: build/build-arm64 "Build and push" uses retry wrapper.
# From: PR #1501.
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
# What: checks pushed scans use the exact-digest action.
# Why: container-scan no longer scans locally.
# From: Issue #1095
require_grep 'uses: \./\.github/actions/trivy-scan-exact-digest' \
  .github/workflows/build-push.yml \
  'the pushed per-service digest scan must use the shared trivy-scan-exact-digest action, not a bespoke scan invocation'
# What: checks the amd64 scan is its own hosted job.
# Why: no self-hosted job may own that scan again.
# From: Issue #1095
require_grep '^  trivy-scan-amd64:' \
  .github/workflows/build-push.yml \
  'the amd64 pushed-digest scan must run in its own GitHub-hosted job (trivy-scan-amd64), not inline inside the self-hosted build job'
# Keep release verification aligned with the canonical first-party service
# set plus the immutable stack pointer (#1428 added syslog, #1556 added
# utilities, both for the same reason the runtime_images/Dockerfile loops
# above cover them).
require_grep 'SERVICES: proxy dns watchdog dhcp dhcp-proxy ntp syslog ui build-tools utilities stack' \
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
