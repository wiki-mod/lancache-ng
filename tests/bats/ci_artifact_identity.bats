#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "canonical catalog includes every current runtime service including ntp and syslog" {
  run bash "$REPO_ROOT/scripts/query-stack-images.sh" runtime
  [ "$status" -eq 0 ]
  for service in proxy dns watchdog dhcp dhcp-proxy ntp ui syslog; do
    run jq -e --arg service "$service" '.include | any(.service == $service)' <<<"$output"
    [ "$status" -eq 0 ]
  done
}

@test "canonical catalog derives build-tools from tooling section" {
  run bash "$REPO_ROOT/scripts/query-stack-images.sh" tooling
  [ "$status" -eq 0 ]
  run jq -e '.include | length == 1 and .[0].service == "build-tools"' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "catalog has exactly one entry per service and two required platforms" {
  run bash "$REPO_ROOT/scripts/query-stack-images.sh" all
  [ "$status" -eq 0 ]
  run jq -e '
    (.include | length) == (.include | map(.service) | unique | length)
    and ([.include[].platforms | sort == ["linux/amd64","linux/arm64"]] | all)
  ' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "stack lock validator rejects a tag in place of a digest" {
  source "$REPO_ROOT/scripts/lib/ci-artifact-identity.sh"
  lock="$BATS_TEST_TMPDIR/lock.json"
  cat >"$lock" <<'JSON'
{
  "schema":"stack-lock/v1",
  "source_sha":"1111111111111111111111111111111111111111",
  "candidate_tag":"candidate-v2-test",
  "runtime":{
    "proxy":{
      "image":"ghcr.io/wiki-mod/lancache-ng/proxy",
      "artifact_source_sha":"1111111111111111111111111111111111111111",
      "digest":"latest",
      "platforms":{
        "linux/amd64":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "linux/arm64":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      }
    }
  },
  "tooling":{}
}
JSON
  run ci_ai_validate_stack_lock "$lock"
  [ "$status" -ne 0 ]
}
