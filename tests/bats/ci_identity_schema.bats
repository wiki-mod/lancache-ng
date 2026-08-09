#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/scripts/lib/ci-artifact-identity.sh"
}

write_valid_index() {
  local file="$1"
  cat >"$file" <<'JSON'
{
  "schema":"image-candidate-index/v1",
  "scope":"runtime",
  "service":"proxy",
  "image":"ghcr.io/wiki-mod/lancache-ng/proxy",
  "candidate_source_sha":"1111111111111111111111111111111111111111",
  "artifact_source_sha":"1111111111111111111111111111111111111111",
  "source_fingerprint":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  "build_inputs":{"build_args":{},"build_contexts":{}},
  "digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
  "candidate_ref":"ghcr.io/wiki-mod/lancache-ng/proxy:candidate-v2-test",
  "platforms":{
    "linux/amd64":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "linux/arm64":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
}
JSON
}

write_valid_lock() {
  local file="$1"
  cat >"$file" <<'JSON'
{
  "schema":"stack-lock/v1",
  "source_sha":"1111111111111111111111111111111111111111",
  "candidate_tag":"candidate-v2-test",
  "runtime":{
    "proxy":{
      "image":"ghcr.io/wiki-mod/lancache-ng/proxy",
      "artifact_source_sha":"1111111111111111111111111111111111111111",
      "source_fingerprint":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "build_inputs":{"build_args":{},"build_contexts":{}},
      "digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
      "candidate_ref":"ghcr.io/wiki-mod/lancache-ng/proxy:candidate-v2-test",
      "platforms":{
        "linux/amd64":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "linux/arm64":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      }
    }
  },
  "tooling":{}
}
JSON
}

@test "index schema requires a transport ref from the recorded image identity" {
  record="$BATS_TEST_TMPDIR/index.json"
  write_valid_index "$record"

  run ci_ai_validate_index_record "$record"
  [ "$status" -eq 0 ]

  jq '.candidate_ref = "ghcr.io/wiki-mod/lancache-ng/dns:candidate-v2-test"' "$record" >"$record.tmp"
  mv "$record.tmp" "$record"
  run ci_ai_validate_index_record "$record"
  [ "$status" -ne 0 ]
}

@test "stack-lock schema binds mutable transport refs to its own candidate tag" {
  lock="$BATS_TEST_TMPDIR/lock.json"
  write_valid_lock "$lock"

  run ci_ai_validate_stack_lock "$lock"
  [ "$status" -eq 0 ]

  jq '.runtime.proxy.candidate_ref = "ghcr.io/wiki-mod/lancache-ng/proxy:candidate-v2-other"' "$lock" >"$lock.tmp"
  mv "$lock.tmp" "$lock"
  run ci_ai_validate_stack_lock "$lock"
  [ "$status" -ne 0 ]

  jq '.runtime.proxy.candidate_ref = "ghcr.io/wiki-mod/lancache-ng/proxy@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"' "$lock" >"$lock.tmp"
  mv "$lock.tmp" "$lock"
  run ci_ai_validate_stack_lock "$lock"
  [ "$status" -eq 0 ]
}
