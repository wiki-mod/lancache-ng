#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LOCK="$BATS_TEST_TMPDIR/stack-lock.json"
  EVIDENCE="$BATS_TEST_TMPDIR/evidence"
  mkdir -p "$EVIDENCE"

  cat >"$LOCK" <<'JSON'
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
    },
    "watchdog":{
      "image":"ghcr.io/wiki-mod/lancache-ng/watchdog",
      "artifact_source_sha":"1111111111111111111111111111111111111111",
      "source_fingerprint":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      "build_inputs":{"build_args":{},"build_contexts":{}},
      "digest":"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "candidate_ref":"ghcr.io/wiki-mod/lancache-ng/watchdog:candidate-v2-test",
      "platforms":{
        "linux/amd64":"sha256:1212121212121212121212121212121212121212121212121212121212121212",
        "linux/arm64":"sha256:3434343434343434343434343434343434343434343434343434343434343434"
      }
    }
  },
  "tooling":{}
}
JSON
}

write_candidate_evidence() {
  local service="$1" platform="$2" digest="$3" file="$4"
  jq -n \
    --arg service "$service" \
    --arg platform "$platform" \
    --arg digest "$digest" \
    '{schema:"candidate-evidence/v1",service:$service,platform:$platform,digest:$digest,trivy:"passed",native_smoke:"passed"}' \
    >"$file"
}

write_complete_candidate_set() {
  write_candidate_evidence proxy linux/amd64 \
    sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    "$EVIDENCE/proxy__amd64.json"
  write_candidate_evidence proxy linux/arm64 \
    sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    "$EVIDENCE/proxy__arm64.json"
  write_candidate_evidence watchdog linux/amd64 \
    sha256:1212121212121212121212121212121212121212121212121212121212121212 \
    "$EVIDENCE/watchdog__amd64.json"
  write_candidate_evidence watchdog linux/arm64 \
    sha256:3434343434343434343434343434343434343434343434343434343434343434 \
    "$EVIDENCE/watchdog__arm64.json"
}

@test "candidate evidence must exactly cover every locked service and platform once" {
  write_complete_candidate_set
  run bash "$REPO_ROOT/scripts/ci-verify-platform-evidence.sh" "$LOCK" "$EVIDENCE" candidate
  [ "$status" -eq 0 ]

  rm "$EVIDENCE/watchdog__arm64.json"
  run bash "$REPO_ROOT/scripts/ci-verify-platform-evidence.sh" "$LOCK" "$EVIDENCE" candidate
  [ "$status" -ne 0 ]
  [[ "$output" == *"Platform evidence is not an exact one-to-one match"* ]]
}

@test "duplicate identity cannot substitute for a missing platform evidence record" {
  write_complete_candidate_set
  rm "$EVIDENCE/watchdog__arm64.json"
  write_candidate_evidence proxy linux/amd64 \
    sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    "$EVIDENCE/watchdog__arm64.json"

  run bash "$REPO_ROOT/scripts/ci-verify-platform-evidence.sh" "$LOCK" "$EVIDENCE" candidate
  [ "$status" -ne 0 ]
  [[ "$output" == *"evidence filename does not match its identity"* ]]
}

@test "release evidence additionally requires an attested SBOM" {
  jq -n \
    '{schema:"release-evidence/v1",service:"proxy",platform:"linux/amd64",digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",trivy:"passed",native_smoke:"passed",sbom_attested:false}' \
    >"$EVIDENCE/proxy__amd64.evidence.json"

  run bash "$REPO_ROOT/scripts/ci-verify-platform-evidence.sh" "$LOCK" "$EVIDENCE" release
  [ "$status" -ne 0 ]
  [[ "$output" == *"release SBOM evidence is not attested"* ]]
}
