set -euo pipefail

# shellcheck source=scripts/lib/ghcr-retry.sh
source "$GITHUB_WORKSPACE/scripts/lib/ghcr-retry.sh"

sanitized_ref="$(printf '%s' "$REF_NAME" | tr '/:@' '---' | tr -cd 'A-Za-z0-9_.-')"
if [ -z "$sanitized_ref" ]; then
  echo "::error::Could not derive a safe mutable build-tools branch tag from '$REF_NAME'."
  exit 1
fi

# Always "-tc"-suffixed ("test candidate"), never the bare
# sanitized ref name: this job runs for whichever ref triggered
# the workflow, and this repo already has a branch literally
# named "v0.2.0" (the long-lived integration branch touched on
# every patch/hotfix). A bare branch tag from that branch would
# publish ghcr.io/<repo>/build-tools:v0.2.0 -- the exact same tag
# string build-push.yml's own promote job writes as the real,
# immutable vX.Y.Z stable-release tag for this same GHCR package
# the moment that version is actually tagged
# (release/stack-images.yml declares that tag `mutable: false`),
# silently overwriting it on the next
# tools/build-tools/**-touching commit. None of this project's
# real release-channel tags for build-tools (`edge`, `dev`,
# `latest`, `vX.Y.Z`, `vX.Y.Z-rc.N` -- see build-push.yml's
# promote job) end with "-tc", so suffixing every branch-triggered
# tag this way is collision-proof by construction against the
# whole channel-tag shape, not just today's `v0.2.0` branch name.
# A "-dev" suffix was considered and rejected: `dev` is already a
# real, standalone channel tag written by build-push.yml's promote
# job (release/stack-images.yml's `dev` channel), so appending
# "-dev" here would create a second, different thing that also
# reads as "dev"-something and could be mistaken for that real
# channel. An "-rc" suffix was rejected for the same reason:
# `vX.Y.Z-rc.N` is already this project's real, reserved release-
# candidate tag shape (release/stack-images.yml's
# `release_candidate` channel), so reusing "-rc" here would make a
# branch-triggered ad-hoc build look like an actual release
# candidate. "-tc" doesn't collide with any of this project's
# reserved tag shapes. build-push.yml's "Validate compose files"
# step asserts this derivation can never emit a release-shaped
# tag, so this can't silently regress.
branch_tag="${sanitized_ref}-tc"

source_ref="${BUILD_TOOLS_IMAGE}@${MERGED_DIGEST}"

# Deliberately one line each (no backslash continuation): the
# validate-compose contract job in build-push.yml extracts this
# step's derivation logic verbatim by scanning up to (but not
# including) the first line containing "docker buildx imagetools
# create" -- a continued line here would splice into whatever that
# extraction appends next. See that job's own comment.
ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- docker buildx imagetools create --prefer-index=false -t "${BUILD_TOOLS_IMAGE}:${branch_tag}" "$source_ref"
if [ "$REF_NAME" = "$DEFAULT_BRANCH" ]; then
  ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- docker buildx imagetools create --prefer-index=false -t "${BUILD_TOOLS_IMAGE}:latest" "$source_ref"
fi
