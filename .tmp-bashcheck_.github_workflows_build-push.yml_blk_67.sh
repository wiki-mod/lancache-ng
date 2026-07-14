set -euo pipefail

should_build=true
if [ "$GITHUB_EVENT_NAME" = "pull_request" ]; then
  if [ "$DETECT_CHANGES_RESULT" != "success" ]; then
    echo "::error::Pull request build scoping requires detect-changes to succeed, got '$DETECT_CHANGES_RESULT'."
    exit 1
  fi
  case "$MATRIX_SERVICE" in
    proxy) should_build="${{ needs['detect-changes'].outputs.proxy }}" ;;
    dns) should_build="${{ needs['detect-changes'].outputs.dns_image }}" ;;
    watchdog) should_build="${{ needs['detect-changes'].outputs.watchdog }}" ;;
    dhcp) should_build="${{ needs['detect-changes'].outputs.dhcp }}" ;;
    dhcp-proxy) should_build="${{ needs['detect-changes'].outputs.dhcp_proxy }}" ;;
    ui) should_build="${{ needs['detect-changes'].outputs.ui }}" ;;
    build-tools) should_build="${{ needs['detect-changes'].outputs.build_tools }}" ;;
    *)
      echo "::error::Unknown matrix service '$MATRIX_SERVICE' has no path-scoping mapping."
      exit 1
      ;;
  esac
  if [ "${{ needs['detect-changes'].outputs.workflow }}" = "true" ] && [ "$MATRIX_SERVICE" != "build-tools" ]; then
    should_build=true
  fi
elif [ "$MATRIX_SERVICE" = "build-tools" ]; then
  should_build=true
fi

case "$should_build" in
  true|false)
    ;;
  *)
    echo "::error::Build scope for $MATRIX_SERVICE must resolve to true or false, got '${should_build:-<empty>}'."
    exit 1
    ;;
esac

if [ "$should_build" = "true" ]; then
  echo "::notice::$MATRIX_SERVICE inputs changed (or this is not a pull request); image build remains enabled."
else
  echo "::notice::$MATRIX_SERVICE inputs did not change in this pull request; skipping routine image rebuild."
fi
echo "should-build=$should_build" >> "$GITHUB_OUTPUT"

