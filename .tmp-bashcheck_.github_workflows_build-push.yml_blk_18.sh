set -euo pipefail

# Resolve the required published image FIRST. If it's unavailable or fails
# smoke checks, this exits before the permissive selector below ever builds
# the (large) local fallback image, so there's nothing left to clean up.
downstream_build_tools_image="$(BUILD_TOOLS_REQUIRE_PUBLISHED=true bash scripts/select-build-tools-image.sh)"

case "$downstream_build_tools_image" in
  *@sha256:*)
    ;;
  *)
    echo "::error::Expected a digest-qualified build-tools image from the published build-tools selector, got '$downstream_build_tools_image'."
    exit 1
    ;;
esac

# validate-compose runs on the light tier, so it must not trigger the
# selector's trusted-ref fallback Docker build. Reuse the already
# smoke-tested published digest for this job and for downstream jobs.
validation_build_tools_image="$downstream_build_tools_image"

printf 'BUILD_TOOLS_IMAGE=%s\n' "$validation_build_tools_image" >> "$GITHUB_ENV"
printf 'build_tools_image=%s\n' "$downstream_build_tools_image" >> "$GITHUB_OUTPUT"

