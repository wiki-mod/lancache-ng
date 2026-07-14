set -euo pipefail

if [ "${{ github.event_name }}" != "push" ]; then
  # workflow_dispatch and the weekly schedule are explicit,
  # intentional rebuild requests; always publish. pull_request
  # never publishes regardless (gated separately below).
  echo "should-publish=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

before_sha="${{ github.event.before }}"
if [ -z "$before_sha" ] || [ "$before_sha" = "0000000000000000000000000000000000000000" ]; then
  # No usable base to diff (e.g. the branch's first push): fail
  # safe by publishing rather than silently skipping a real change.
  echo "should-publish=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

# The default checkout is shallow; fetch just the one missing base
# commit on demand instead of a full-history clone (fetch-depth: 0
# on this repo hit real "inflate: data stream error" checkout
# failures on the runner -- confirmed by actually running this).
if ! git cat-file -e "${before_sha}^{commit}" 2>/dev/null; then
  git fetch --quiet --depth=1 origin "$before_sha" 2>/dev/null || true
fi

if ! git cat-file -e "${before_sha}^{commit}" 2>/dev/null; then
  echo "::notice::Could not fetch base commit $before_sha to diff against; publishing to be safe."
  echo "should-publish=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

if git diff --name-only "$before_sha" "${{ github.sha }}" -- tools/build-tools .github/workflows/build-tools.yml | grep -q .; then
  echo "should-publish=true" >> "$GITHUB_OUTPUT"
else
  echo "::notice::Only test-only paths (tests/bats/**, tests/shellspec/**, setup.sh) changed; skipping build-tools image rebuild/publish."
  echo "should-publish=false" >> "$GITHUB_OUTPUT"
fi

