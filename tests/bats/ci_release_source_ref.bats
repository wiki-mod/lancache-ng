#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"
}

write_git_mock() {
  local body="$1"
  cat >"$BIN_DIR/git" <<SH
#!/usr/bin/env bash
set -euo pipefail
$body
SH
  chmod +x "$BIN_DIR/git"
}

@test "release source verifier accepts a lightweight tag at the frozen commit" {
  write_git_mock 'printf "%s\\t%s\\n" "1111111111111111111111111111111111111111" "refs/tags/v0.4.0"'

  run env PATH="$BIN_DIR:$PATH" NETWORK_RETRY_BACKOFF_SECONDS=0 \
    bash "$REPO_ROOT/scripts/ci-verify-release-source-ref.sh" \
      v0.4.0 1111111111111111111111111111111111111111
  [ "$status" -eq 0 ]
}

@test "release source verifier uses the peeled commit for an annotated tag" {
  write_git_mock 'printf "%s\\t%s\\n%s\\t%s\\n" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "refs/tags/v0.4.0" "1111111111111111111111111111111111111111" "refs/tags/v0.4.0^{}"'

  run env PATH="$BIN_DIR:$PATH" NETWORK_RETRY_BACKOFF_SECONDS=0 \
    bash "$REPO_ROOT/scripts/ci-verify-release-source-ref.sh" \
      v0.4.0 1111111111111111111111111111111111111111
  [ "$status" -eq 0 ]
}

@test "release source verifier fails when the remote tag moved" {
  write_git_mock 'printf "%s\\t%s\\n" "2222222222222222222222222222222222222222" "refs/tags/v0.4.0"'

  run env PATH="$BIN_DIR:$PATH" NETWORK_RETRY_BACKOFF_SECONDS=0 \
    bash "$REPO_ROOT/scripts/ci-verify-release-source-ref.sh" \
      v0.4.0 1111111111111111111111111111111111111111
  [ "$status" -ne 0 ]
  [[ "$output" == *"release tag v0.4.0 moved"* ]]
}

@test "missing remote release tag is a permanent failure and is not retried" {
  counter="$BATS_TEST_TMPDIR/git-count"
  write_git_mock "printf 'x' >> '$counter'; exit 2"

  run env PATH="$BIN_DIR:$PATH" NETWORK_RETRY_BACKOFF_SECONDS=0 \
    bash "$REPO_ROOT/scripts/ci-verify-release-source-ref.sh" \
      v0.4.0 1111111111111111111111111111111111111111
  [ "$status" -ne 0 ]
  [ "$(wc -c < "$counter" | tr -d ' ')" -eq 1 ]
  [[ "$output" == *"Release tag v0.4.0 no longer exists on origin"* ]]
}
