#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "release lock preserves accepted runtime and binds its verified origin" {
  accepted="$BATS_TEST_TMPDIR/accepted.json"
  tooling="$BATS_TEST_TMPDIR/build-tools-index.json"
  release="$BATS_TEST_TMPDIR/release.json"
  accepted_pointer_digest="sha256:0101010101010101010101010101010101010101010101010101010101010101"

  cat >"$accepted" <<'JSON'
{
  "schema":"stack-lock/v1",
  "source_sha":"1111111111111111111111111111111111111111",
  "candidate_tag":"candidate-v2-old",
  "runtime":{
    "proxy":{
      "image":"ghcr.io/wiki-mod/lancache-ng/proxy",
      "artifact_source_sha":"1111111111111111111111111111111111111111",
      "source_fingerprint":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "build_inputs":{"build_args":{},"build_contexts":{}},
      "digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "candidate_ref":"ghcr.io/wiki-mod/lancache-ng/proxy:candidate-v2-old",
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
      "candidate_ref":"ghcr.io/wiki-mod/lancache-ng/build-tools:candidate-v2-old",
      "platforms":{
        "linux/amd64":"sha256:1212121212121212121212121212121212121212121212121212121212121212",
        "linux/arm64":"sha256:3434343434343434343434343434343434343434343434343434343434343434"
      }
    }
  }
}
JSON

  cat >"$tooling" <<'JSON'
{
  "schema":"image-candidate-index/v1",
  "scope":"tooling",
  "service":"build-tools",
  "image":"ghcr.io/wiki-mod/lancache-ng/build-tools",
  "candidate_source_sha":"1111111111111111111111111111111111111111",
  "artifact_source_sha":"1111111111111111111111111111111111111111",
  "source_fingerprint":"sha256:5656565656565656565656565656565656565656565656565656565656565656",
  "build_inputs":{"build_args":{},"build_contexts":{}},
  "digest":"sha256:7878787878787878787878787878787878787878787878787878787878787878",
  "candidate_ref":"ghcr.io/wiki-mod/lancache-ng/build-tools:release-v2-test",
  "platforms":{
    "linux/amd64":"sha256:9090909090909090909090909090909090909090909090909090909090909090",
    "linux/arm64":"sha256:abababababababababababababababababababababababababababababababab"
  }
}
JSON

  accepted_lock_hash="$(sha256sum "$accepted" | awk '{print $1}')"
  run bash "$REPO_ROOT/scripts/ci-assemble-release-lock.sh" \
    "$accepted" "$accepted_pointer_digest" "$tooling" \
    v0.4.0 release-v2-test "$release"
  [ "$status" -eq 0 ]

  run jq -e \
    --arg pointer_digest "$accepted_pointer_digest" \
    --arg accepted_lock_hash "$accepted_lock_hash" '
    .runtime.proxy.digest == "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    and .runtime.proxy.platforms["linux/amd64"] == "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    and .runtime.proxy.candidate_ref == "ghcr.io/wiki-mod/lancache-ng/proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    and .tooling["build-tools"].digest == "sha256:7878787878787878787878787878787878787878787878787878787878787878"
    and .tooling["build-tools"].source_fingerprint == "sha256:5656565656565656565656565656565656565656565656565656565656565656"
    and .tooling["build-tools"].build_inputs == {build_args:{},build_contexts:{}}
    and .release.tag == "v0.4.0"
    and .release.runtime_origin == "accepted-stack"
    and .release.accepted_runtime_pointer_digest == $pointer_digest
    and .release.accepted_runtime_lock_sha256 == $accepted_lock_hash
    and .release.build_tools_origin == "fresh-release-build"
  ' "$release"
  [ "$status" -eq 0 ]
}

@test "release acceptance proves inherited runtime and fresh tooling without claiming rerun stack gates" {
  source "$REPO_ROOT/scripts/lib/ci-artifact-identity.sh"
  record="$BATS_TEST_TMPDIR/release-acceptance.json"
  cat >"$record" <<'JSON'
{
  "schema":"release-acceptance/v1",
  "accepted":true,
  "source_sha":"1111111111111111111111111111111111111111",
  "source_ref":"refs/tags/v0.4.0",
  "release_lock_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "accepted_tag":"accepted-v2-release-v0.4.0-test",
  "release_tag":"v0.4.0",
  "accepted_runtime_pointer_digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "accepted_runtime_lock_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  "gates":{
    "accepted_runtime_acceptance_verified":true,
    "accepted_runtime_identity_preserved":true,
    "release_build_tools_built":true,
    "release_build_tools_provenance":true,
    "release_exact_digest_security":true,
    "release_native_platform_smoke":true,
    "release_sbom_attested":true,
    "release_build_tools_validation_contract":false,
    "publication_policy":true
  }
}
JSON

  run ci_ai_validate_release_acceptance "$record"
  [ "$status" -ne 0 ]

  jq '.gates.release_build_tools_validation_contract = true' "$record" >"$record.tmp"
  mv "$record.tmp" "$record"
  run ci_ai_validate_release_acceptance "$record"
  [ "$status" -eq 0 ]

  jq '.source_ref = "refs/heads/current_dev"' "$record" >"$record.tmp"
  mv "$record.tmp" "$record"
  run ci_ai_validate_release_acceptance "$record"
  [ "$status" -ne 0 ]
}

@test "release acceptance schema cannot impersonate reusable stack acceptance" {
  source "$REPO_ROOT/scripts/lib/ci-artifact-identity.sh"
  record="$BATS_TEST_TMPDIR/release-only.json"
  cat >"$record" <<'JSON'
{
  "schema":"release-acceptance/v1",
  "accepted":true,
  "source_sha":"1111111111111111111111111111111111111111",
  "source_ref":"refs/tags/v0.4.0",
  "release_lock_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "accepted_tag":"accepted-v2-release-v0.4.0-test",
  "release_tag":"v0.4.0",
  "accepted_runtime_pointer_digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "accepted_runtime_lock_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  "gates":{
    "accepted_runtime_acceptance_verified":true,
    "accepted_runtime_identity_preserved":true,
    "release_build_tools_built":true,
    "release_build_tools_provenance":true,
    "release_exact_digest_security":true,
    "release_native_platform_smoke":true,
    "release_sbom_attested":true,
    "release_build_tools_validation_contract":true,
    "publication_policy":true
  }
}
JSON

  run ci_ai_validate_release_acceptance "$record"
  [ "$status" -eq 0 ]
  run ci_ai_validate_acceptance "$record"
  [ "$status" -ne 0 ]
  run ci_ai_validate_reusable_acceptance "$record"
  [ "$status" -ne 0 ]
}

@test "release evidence artifacts are collision-free and SBOM JSON cannot be counted as gate evidence" {
  workflow="$REPO_ROOT/.github/workflows/ci-release-accepted-v2.yml"

  run grep -F 'output: sbom-${{ matrix.service }}-${{ matrix.arch }}.spdx.json' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'evidence/${{ matrix.service }}__${{ matrix.arch }}.evidence.json' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F "find release/evidence -type f -name '*.evidence.json'" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F 'output: sbom.spdx.json' "$workflow"
  [ "$status" -ne 0 ]
  run grep -F "find release/evidence -type f -name '*.json'" "$workflow"
  [ "$status" -ne 0 ]
}
