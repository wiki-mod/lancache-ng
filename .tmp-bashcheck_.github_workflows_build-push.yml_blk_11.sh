set -euo pipefail

changed_files="$(mktemp "$PWD/.governance-changed-files.XXXXXX")"
trap 'rm -f "$changed_files"' EXIT
git fetch --no-tags --depth=1 origin \
  "+refs/heads/${GOVERNANCE_BASE_REF}:refs/remotes/origin/${GOVERNANCE_BASE_REF}"
git cat-file -e "${GOVERNANCE_BASE_SHA}^{commit}"
git cat-file -e "${GITHUB_SHA}^{commit}"
git diff --name-only --diff-filter=ACMRTUXB "$GOVERNANCE_BASE_SHA" "$GITHUB_SHA" > "$changed_files"

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$PWD:/work:ro" \
  -w /work \
  -e GITHUB_REPOSITORY \
  -e GOVERNANCE_PR_TITLE \
  -e GOVERNANCE_PR_BODY \
  "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}" \
  bash scripts/check-governance-guards.sh --changed-files-file "/work/$(basename "$changed_files")"

