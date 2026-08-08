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

@test "acceptance schema requires every final gate" {
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

  jq '.gates.provenance = true | .gates.runtime_deep_validation = true' "$record" >"$record.tmp"
  mv "$record.tmp" "$record"
  run ci_ai_validate_acceptance "$record"
  [ "$status" -eq 0 ]
}

@test "reusable acceptance is restricted to protected product branch refs" {
  source "$REPO_ROOT/scripts/lib/ci-artifact-identity.sh"
  record="$BATS_TEST_TMPDIR/reusable.json"
  cat >"$record" <<'JSON'
{
  "schema":"stack-acceptance/v1",
  "accepted":true,
  "source_sha":"1111111111111111111111111111111111111111",
  "source_ref":"refs/heads/feature/test",
  "stack_lock_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "accepted_tag":"accepted-v2-test",
  "gates":{
    "identity_complete":true,
    "platform_complete":true,
    "provenance":true,
    "exact_digest_security":true,
    "native_platform_smoke":true,
    "exact_locked_stack":true,
    "runtime_deep_validation":true,
    "supplemental_full_setup":true,
    "publication_policy":true
  }
}
JSON
  run ci_ai_validate_acceptance "$record"
  [ "$status" -eq 0 ]
  run ci_ai_validate_reusable_acceptance "$record"
  [ "$status" -ne 0 ]

  jq '.source_ref = "refs/heads/current_dev"' "$record" >"$record.tmp"
  mv "$record.tmp" "$record"
  run ci_ai_validate_reusable_acceptance "$record"
  [ "$status" -eq 0 ]
}

@test "PR validation cannot create reusable accepted pointer" {
  workflow="$REPO_ROOT/.github/workflows/ci-artifact-v2.yml"
  run grep -F 'name: record non-promotable PR validation proof' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'promotion_eligible:false' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F "github.event_name == 'workflow_dispatch'" "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'github.ref_protected == true' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F -- '--source-ref "$source_ref"' "$REPO_ROOT/scripts/ci-verify-acceptance-attestation.sh"
  [ "$status" -eq 0 ]
  run grep -F -- '--source-digest "$source_sha"' "$REPO_ROOT/scripts/ci-verify-acceptance-attestation.sh"
  [ "$status" -eq 0 ]
}

@test "single-platform build keeps runtime child digest separate from provenance" {
  workflow="$REPO_ROOT/.github/workflows/ci-artifact-v2.yml"
  run grep -F 'provenance: "false"' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'name: Attest build provenance to exact child digest' "$workflow"
  [ "$status" -eq 0 ]
}

@test "locked-stack health loop uses only services that actually started" {
  script="$REPO_ROOT/scripts/ci-validate-locked-stack.sh"
  run grep -F 'mapfile -t active_services < <("${compose[@]}" ps --services)' "$script"
  [ "$status" -eq 0 ]
  run grep -F 'mapfile -t active_services < <("${compose[@]}" config --services)' "$script"
  [ "$status" -ne 0 ]
}

@test "release pointer is attested before mutable release references move" {
  workflow="$REPO_ROOT/.github/workflows/ci-release-accepted-v2.yml"
  pointer_line="$(grep -n 'name: Build immutable release stack pointer before mutable publication' "$workflow" | cut -d: -f1)"
  acceptance_line="$(grep -n 'name: Attest immutable release acceptance before mutable publication' "$workflow" | cut -d: -f1)"
  mutation_line="$(grep -n 'name: Publish release references as one rollback-protected critical section' "$workflow" | cut -d: -f1)"
  [[ "$pointer_line" =~ ^[0-9]+$ ]]
  [[ "$acceptance_line" =~ ^[0-9]+$ ]]
  [[ "$mutation_line" =~ ^[0-9]+$ ]]
  [ "$pointer_line" -lt "$acceptance_line" ]
  [ "$acceptance_line" -lt "$mutation_line" ]
  run grep -F 'promote_lock_acquire_with_retry origin' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'rollback_release_refs' "$workflow"
  [ "$status" -eq 0 ]
}

@test "promotion uses shared mutex rollback and writes stack pointer last" {
  workflow="$REPO_ROOT/.github/workflows/ci-promote-accepted-v2.yml"
  run grep -F 'promote_lock_acquire_with_retry origin' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'rollback_promotions' "$workflow"
  [ "$status" -eq 0 ]
  service_line="$(grep -n 'while IFS=.*read -r image digest' "$workflow" | head -n1 | cut -d: -f1)"
  stack_line="$(grep -n 'stack_target=' "$workflow" | head -n1 | cut -d: -f1)"
  [[ "$service_line" =~ ^[0-9]+$ ]]
  [[ "$stack_line" =~ ^[0-9]+$ ]]
  [ "$service_line" -lt "$stack_line" ]
}
