#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

write_platform_record() {
  local path="$1" platform="$2" digest="$3"
  cat >"$path" <<JSON
{
  "schema": "image-candidate-platform/v1",
  "scope": "runtime",
  "service": "dns",
  "image": "ghcr.io/wiki-mod/lancache-ng/dns",
  "candidate_source_sha": "1111111111111111111111111111111111111111",
  "artifact_source_sha": "1111111111111111111111111111111111111111",
  "source_fingerprint": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  "build_inputs": {"build_args": {}, "build_contexts": {}},
  "platform": "$platform",
  "digest": "$digest",
  "mode": "built",
  "reused_index_digest": ""
}
JSON
}

@test "index assembly rejects missing required external build inputs before registry access" {
  record_dir="$BATS_TEST_TMPDIR/platforms"
  output="$BATS_TEST_TMPDIR/index.json"
  mkdir -p "$record_dir"
  write_platform_record \
    "$record_dir/dns__amd64.json" linux/amd64 \
    sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  write_platform_record \
    "$record_dir/dns__arm64.json" linux/arm64 \
    sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

  run env GHCR_RETRY_MAX_ATTEMPTS=1 \
    bash "$REPO_ROOT/scripts/ci-assemble-service-index.sh" \
      dns ghcr.io/wiki-mod/lancache-ng/dns \
      1111111111111111111111111111111111111111 candidate-v2-test \
      "$record_dir" "$output"

  [ "$status" -ne 0 ]
  [[ "$output" == *"dns must carry exactly BUILD_TOOLS_IMAGE as external build arg"* ]]
  [[ "$output" == *"invalid build inputs for dns"* ]]
  [ ! -e "$output" ]
}
