#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LOCK="$BATS_TEST_TMPDIR/release-lock.json"
  cat >"$LOCK" <<'JSON'
{
  "schema":"stack-lock/v1",
  "source_sha":"1111111111111111111111111111111111111111",
  "candidate_tag":"release-v2-test",
  "runtime":{
    "proxy":{
      "image":"ghcr.io/wiki-mod/lancache-ng/proxy",
      "artifact_source_sha":"1111111111111111111111111111111111111111",
      "source_fingerprint":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "build_inputs":{"build_args":{},"build_contexts":{}},
      "digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "platforms":{
        "linux/amd64":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        "linux/arm64":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      }
    }
  },
  "tooling":{
    "build-tools":{
      "image":"ghcr.io/wiki-mod/lancache-ng/build-tools",
      "artifact_source_sha":"1111111111111111111111111111111111111111",
      "source_fingerprint":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      "build_inputs":{"build_args":{},"build_contexts":{}},
      "digest":"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "platforms":{
        "linux/amd64":"sha256:1212121212121212121212121212121212121212121212121212121212121212",
        "linux/arm64":"sha256:3434343434343434343434343434343434343434343434343434343434343434"
      }
    }
  },
  "release":{
    "tag":"v0.4.0",
    "runtime_origin":"accepted-stack",
    "accepted_runtime_pointer_digest":"sha256:5656565656565656565656565656565656565656565656565656565656565656",
    "accepted_runtime_lock_sha256":"7878787878787878787878787878787878787878787878787878787878787878",
    "build_tools_origin":"fresh-release-build"
  }
}
JSON
}

@test "immutable release plan emits package refs before coherent stack commit point" {
  stack_digest="sha256:9090909090909090909090909090909090909090909090909090909090909090"
  run bash "$REPO_ROOT/scripts/ci-release-ref-plan.sh" "$LOCK" v0.4.0 "$stack_digest"
  [ "$status" -eq 0 ]

  mapfile -t rows <<<"$output"
  [ "${#rows[@]}" -eq 3 ]
  [[ "${rows[0]}" == $'ghcr.io/wiki-mod/lancache-ng/build-tools:v0.4.0\tsha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' ]]
  [[ "${rows[1]}" == $'ghcr.io/wiki-mod/lancache-ng/proxy:v0.4.0\tsha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ]]
  [[ "${rows[2]}" == $'ghcr.io/wiki-mod/lancache-ng/stack:v0.4.0\tsha256:9090909090909090909090909090909090909090909090909090909090909090' ]]
}

@test "release plan refuses to replay a lock under a different immutable version" {
  stack_digest="sha256:9090909090909090909090909090909090909090909090909090909090909090"
  run bash "$REPO_ROOT/scripts/ci-release-ref-plan.sh" "$LOCK" v0.4.1 "$stack_digest"
  [ "$status" -ne 0 ]
  [[ "$output" == *"release lock tag does not match requested release tag"* ]]
}

@test "release plan rejects a non-release version label" {
  stack_digest="sha256:9090909090909090909090909090909090909090909090909090909090909090"
  run bash "$REPO_ROOT/scripts/ci-release-ref-plan.sh" "$LOCK" latest "$stack_digest"
  [ "$status" -ne 0 ]
}
