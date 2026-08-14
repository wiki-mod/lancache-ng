#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: validates release/stack-images.yml (the release manifest) against
# the actual repo -- schema/retention fields, per-image platform coverage,
# compose files' registry/prefix/tag variable usage, and that
# build-push.yml implements the manifest's promotion/release/provenance/
# rollback contract.
# Why: a CI gate on release infrastructure changes -- these checks assert
# the manifest and the real workflow/compose/Dockerfile state agree, since
# nothing else enforces that agreement structurally.
# From: PR #1501.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
manifest=${1:-"$repo_root/release/stack-images.yml"}

# fail <message>
# What: prints a prefixed error to stderr and exits 1.
# Why: every check below shares one exit path, so a failing assertion's
# message is always immediately visible without hunting for which check ran.
# From: PR #1501.
fail() {
  printf 'validate-stack-images: %s\n' "$1" >&2
  exit 1
}

# require_file <repo-relative-path>
# What: fails unless the given path exists under repo_root.
# From: PR #1501.
require_file() {
  local path=$1
  [[ -f "$repo_root/$path" ]] || fail "missing required file: $path"
}

# require_grep <pattern> <repo-relative-path> <failure-message>
# What: fails with the given message unless an extended-regex pattern
# matches the given file.
# Why: shared by every substantive check below so each one is a single
# line pairing the pattern with the specific real-world contract it proves.
# From: PR #1501.
require_grep() {
  local pattern=$1 path=$2 message=$3
  grep -Eq -- "$pattern" "$repo_root/$path" || fail "$message"
}

# collect_names <manifest-section>
# What: prints every `- name:` value under a top-level manifest section
# (e.g. runtime, tooling, metadata, external).
# From: PR #1501.
collect_names() {
  local section=$1
  awk -v section="$section" '
    $0 == section ":" { in_section=1; next }
    in_section && /^[[:alnum:]_-]+:/ { in_section=0 }
    in_section && /^  - name: / { sub(/^  - name: /, ""); print }
  ' "$manifest"
}

# require_name <names> <name> <section-label>
# What: fails unless <name> appears exactly among the given newline-joined
# names (used with collect_names's output).
# From: PR #1501.
require_name() {
  local names=$1 name=$2 section=$3
  grep -Fxq "$name" <<<"$names" || fail "missing $section image: $name"
}

# require_manifest_platform <image-name> <platform>
# What: fails unless the manifest's entry for <image-name> declares
# <platform> under its own `platforms:` list.
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
require_grep '^  protect_release_and_rollback_digests: true$' "${manifest#$repo_root/}" 'retention must protect release and rollback digests'
require_grep '^  deletion_policy: manual-or-approved-automation-only$' "${manifest#$repo_root/}" 'retention deletion policy must be explicit'
require_grep '^concurrency:$' .github/workflows/build-push.yml 'build workflow must serialize write-capable package publishing'

runtime_names=$(collect_names runtime)
tooling_names=$(collect_names tooling)
metadata_names=$(collect_names metadata)
external_names=$(collect_names external)

runtime_images=(proxy dns watchdog dhcp dhcp-proxy ntp ui syslog)
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
# What: does not check fluent-bit/syslog-ng here anymore (moved to
# release/stack-images.yml's `legacy:` section).
# Why: the first-party `syslog` image (in runtime_images above) bundles
# fluent-bit's pinned binary and Alpine's syslog-ng package internally, so
# neither is pulled as its own top-level image anymore.
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
# What: checks dhcp/dhcp-proxy/ntp/syslog against
# deploy/quickstart/docker-compose.yml as an explicit per-service list, not
# a loop over runtime_images.
# Why: not every runtime image is deployed by the quickstart profile (dns's
# two prod instances collapse to one dns-standard/dns-ssl pair there), so a
# loop would need its own exclusion list -- no cheaper than this explicit
# list (issue #849 finding #12).
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
# What: requires build-tools.yml to force OCI mediatypes and publish index
# annotations too, not just build-push.yml.
# Why: build-tools.yml is a second, independent publisher of the
# build-tools image (weekly cron/push/dispatch, moving build-tools:latest
# and mutable branch tags), and most CI/dev paths consume its tags rather
# than build-push.yml's own sha-<commit>-only output (issue #620).
# From: PR #1501.
require_grep 'outputs: type=image,oci-mediatypes=true' \
  .github/workflows/build-tools.yml \
  'build-tools.yml per-platform builds must force OCI mediatypes so its own merge step can actually attach index annotations'
require_grep 'annotation "index:org\.opencontainers\.image\.description=' \
  .github/workflows/build-tools.yml \
  'build-tools.yml must publish an OCI image description index annotation on its merged multi-platform manifest'
# What: checks this one literal services=(...) array byte-for-byte, rather
# than relying on check-workflow-service-lists.sh's broader guard.
# Why: that broader, build-matrix-derived guard keeps every OTHER
# services=(...) copy in the repo in sync but does not reach this
# narrower, release/promotion-scoped array (issue #1428).
# From: PR #1501.
require_grep 'services=\(proxy dns watchdog dhcp dhcp-proxy ntp syslog ui build-tools\)' \
  .github/workflows/build-push.yml \
  'promotion and release jobs must share the full first-party service set'

forbidden_latest_default_branch='type=raw,value=latest,enable={{is_default'
forbidden_latest_default_branch="${forbidden_latest_default_branch}_branch}}"
if grep -Fq "$forbidden_latest_default_branch" "$repo_root/.github/workflows/build-push.yml"; then
  fail 'default branch must not publish latest via an unaudited build-time tag; latest may only move through the gated promote job'
fi
# What: checks that `channel_tags+=(latest)` sits inside master's own
# if/elif arm specifically, not a flat grep for the line anywhere in the
# file.
# Why: a flat grep would still pass if the line existed but were tied to
# the wrong branch; scoping to the arm catches that regression (branch-model
# decision, issue #825/#1141).
# From: PR #1501.
if ! awk '
  /if \[\[ "\$GITHUB_REF" = "refs\/heads\/master" \]\]; then/ { in_branch=1; next }
  in_branch && /^ *elif/ { in_branch=0 }
  in_branch && /channel_tags\+=\(latest\)/ { found=1 }
  END { exit found ? 0 : 1 }
' "$repo_root/.github/workflows/build-push.yml"; then
  fail 'master branch promotion must publish the latest channel'
fi
# What: fails if current_dev's if/elif arm still auto-publishes nightly.
# Why: nightly is a real once-daily scheduled/dispatch-only, green-gated
# channel now (see nightly-refresh.yml), the mirror image of the check
# above (issue #1254/#1255).
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
# What: checks for `actions/attest@` and `push-to-registry: true` inside
# the ghcr-attest-retry composite action's own action.yml, not build-push.yml.
# Why: every actions/attest invocation goes through that composite action
# (retry + fresh re-login on a transient GHCR 401), so those literals live
# there now (issue #822).
# From: PR #1501.
require_grep 'uses: \./\.github/actions/ghcr-attest-retry' \
  .github/workflows/build-push.yml \
  'release workflow must create provenance attestations for published first-party images through the shared GHCR retry wrapper'
require_grep 'actions/attest@' \
  .github/actions/ghcr-attest-retry/action.yml \
  'the attestation retry wrapper must still call the real actions/attest action'
require_grep 'push-to-registry: true' \
  .github/actions/ghcr-attest-retry/action.yml \
  'provenance attestations must be pushed to the registry'
# What: checks `steps.build.outputs.digest`, not a separate "retry-build"
# step id.
# Why: build/build-arm64's "Build and push" step runs through
# ghcr-build-push-retry, so that one output already resolves to whichever
# internal attempt succeeded (issue #822).
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
# What: checks only build/build-arm64's pushed-digest scan cache dir now,
# not container-scan's former local-build cache dir.
# Why: container-scan no longer builds or scans anything locally for a
# changed service (issue #1095 G8 fix), so that cache dir no longer exists
# to key; the surviving check still enforces #904's invariant for the one
# Trivy cache directory that remains.
# From: Issue #1095 | PR #1501.
require_grep 'cache_dir="/var/tmp/lancache-ng-trivy-cache/\$\{MATRIX_SERVICE\}-pushed-\$\{sanitized_ref\}"' \
  .github/workflows/build-push.yml \
  'the pushed per-service digest scan must use a service- and ref-specific Trivy cache directory too (see #904; widened from build-tools-only to every service by Step 3, issue #1095)'
# What: checks that the Trivy cache-dir key suffixes GITHUB_RUN_ID for the
# matrix.service-scoped key, not the old hardcoded "build-tools-" prefix.
# Why: a cache-dir key must be at least as fine as its job's own
# concurrency-group key; an earlier revision keyed on ref alone, which was
# coarser than the concurrency-group key for workflow_dispatch/rerun and
# left a real race open (issue #904, widened to every service by issue
# #1095 Step 3).
# From: Issue #1095 | PR #1501.
require_grep 'cache_dir="\$\{cache_dir\}-\$\{GITHUB_RUN_ID\}"' \
  .github/workflows/build-push.yml \
  'Trivy cache-dir keys must mirror their concurrency groups run_id suffix for workflow_dispatch/rerun, not just the ref component (see #904)'
# What: checks that syslog is included in this SERVICES scalar too.
# Why: same reason as the services=(...) array check above (issue #1428).
# From: PR #1501.
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
