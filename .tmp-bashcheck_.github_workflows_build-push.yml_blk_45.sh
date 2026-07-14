set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required to publish the coverage badge endpoint}"
: "${BADGE_BRANCH:?BADGE_BRANCH is required}"
: "${BADGE_FILE:?BADGE_FILE is required}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
cp coverage-badge/rust.json "$tmp_dir/rust.json"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Explicit destination refspec, not just "origin $BADGE_BRANCH": actions/checkout's
# sparse fetch config only tracks the ref it originally checked out, so fetching a
# different branch by name alone lands only in FETCH_HEAD, never in
# refs/remotes/origin/$BADGE_BRANCH -- the show-ref check below would then always
# report "not found" and take the orphan-branch path even when badges already exists,
# and the final push would be rejected as non-fast-forward.
git fetch origin "$BADGE_BRANCH:refs/remotes/origin/$BADGE_BRANCH" || true
if git show-ref --verify --quiet "refs/remotes/origin/$BADGE_BRANCH"; then
  # -C (not --create): this is a self-hosted runner, so a local badges branch left
  # over from a previous job on the same workspace makes a plain --create fail with
  # "a branch named 'badges' already exists". -C resets it to origin's tip instead.
  git switch -C "$BADGE_BRANCH" "origin/$BADGE_BRANCH"
else
  git switch --orphan "$BADGE_BRANCH"
  git rm -rf . >/dev/null 2>&1 || true
fi

mkdir -p "$(dirname "$BADGE_FILE")"
cp "$tmp_dir/rust.json" "$BADGE_FILE"
git add "$BADGE_FILE"

if git diff --cached --quiet; then
  echo "::notice::Rust coverage badge endpoint already up to date."
  exit 0
fi

git commit -m "chore: update rust coverage badge"
git push origin "$BADGE_BRANCH"

