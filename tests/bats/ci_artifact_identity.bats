#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "canonical catalog includes every current runtime service including ntp and syslog" {
  run bash "$REPO_ROOT/scripts/query-stack-images.sh" runtime
  [ "$status" -eq 0 ]
  catalog="$output"
  for service in proxy dns watchdog dhcp dhcp-proxy ntp ui syslog; do
    run jq -e --arg service "$service" '.include | any(.service == $service)' <<<"$catalog"
    [ "$status" -eq 0 ]
  done
}

@test "canonical catalog derives build-tools from tooling section" {
  run bash "$REPO_ROOT/scripts/query-stack-images.sh" tooling
  [ "$status" -eq 0 ]
  catalog="$output"
  run jq -e '.include | length == 1 and .[0].service == "build-tools"' <<<"$catalog"
  [ "$status" -eq 0 ]
}

@test "catalog has exactly one entry per service and two required platforms" {
  run bash "$REPO_ROOT/scripts/query-stack-images.sh" all
  [ "$status" -eq 0 ]
  catalog="$output"
  run jq -e '
    (.include | length) == (.include | map(.service) | unique | length)
    and ([.include[].platforms | sort == ["linux/amd64","linux/arm64"]] | all)
  ' <<<"$catalog"
  [ "$status" -eq 0 ]
}

@test "source fingerprint is stable and digest-shaped for the same commit" {
  sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  run bash "$REPO_ROOT/scripts/ci-source-fingerprint.sh" proxy "$sha"
  [ "$status" -eq 0 ]
  first="$output"
  [[ "$first" =~ ^sha256:[0-9a-f]{64}$ ]]
  run bash "$REPO_ROOT/scripts/ci-source-fingerprint.sh" proxy "$sha"
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
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
      "source_fingerprint":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
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

@test "stack lock validator rejects missing source fingerprint" {
  source "$REPO_ROOT/scripts/lib/ci-artifact-identity.sh"
  lock="$BATS_TEST_TMPDIR/missing-fingerprint.json"
  cat >"$lock" <<'JSON'
{
  "schema":"stack-lock/v1",
  "source_sha":"1111111111111111111111111111111111111111",
  "candidate_tag":"candidate-v2-test",
  "runtime":{
    "proxy":{
      "image":"ghcr.io/wiki-mod/lancache-ng/proxy",
      "artifact_source_sha":"1111111111111111111111111111111111111111",
      "digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
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

@test "acceptance validator requires every final gate including runtime deep validation" {
  source "$REPO_ROOT/scripts/lib/ci-artifact-identity.sh"
  record="$BATS_TEST_TMPDIR/acceptance.json"
  cat >"$record" <<'JSON'
{
  "schema":"stack-acceptance/v1",
  "accepted":true,
  "source_sha":"1111111111111111111111111111111111111111",
  "stack_lock_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "accepted_tag":"accepted-v2-test",
  "gates":{
    "identity_complete":true,
    "platform_complete":true,
    "provenance":false,
    "exact_digest_security":true,
    "native_platform_smoke":true,
    "exact_locked_stack":true,
    "runtime_deep_validation":false,
    "supplemental_full_setup":true,
    "publication_policy":true
  }
}
JSON
  run ci_ai_validate_acceptance "$record"
  [ "$status" -ne 0 ]
  jq '.gates.provenance = true' "$record" >"$record.tmp"
  mv "$record.tmp" "$record"
  run ci_ai_validate_acceptance "$record"
  [ "$status" -ne 0 ]
  jq '.gates.runtime_deep_validation = true' "$record" >"$record.tmp"
  mv "$record.tmp" "$record"
  run ci_ai_validate_acceptance "$record"
  [ "$status" -eq 0 ]
}
