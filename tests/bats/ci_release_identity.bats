#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "release lock preserves accepted runtime and replaces only build-tools identity" {
  accepted="$BATS_TEST_TMPDIR/accepted.json"
  tooling="$BATS_TEST_TMPDIR/build-tools-index.json"
  release="$BATS_TEST_TMPDIR/release.json"

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
  "digest":"sha256:7878787878787878787878787878787878787878787878787878787878787878",
  "candidate_ref":"ghcr.io/wiki-mod/lancache-ng/build-tools:release-v2-test",
  "platforms":{
    "linux/amd64":"sha256:9090909090909090909090909090909090909090909090909090909090909090",
    "linux/arm64":"sha256:abababababababababababababababababababababababababababababababab"
  }
}
JSON

  run bash "$REPO_ROOT/scripts/ci-assemble-release-lock.sh" \
    "$accepted" "$tooling" v0.4.0 release-v2-test "$release"
  [ "$status" -eq 0 ]

  run jq -e '
    .runtime.proxy.digest == "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    and .runtime.proxy.platforms["linux/amd64"] == "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    and .runtime.proxy.candidate_ref == "ghcr.io/wiki-mod/lancache-ng/proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    and .tooling["build-tools"].digest == "sha256:7878787878787878787878787878787878787878787878787878787878787878"
    and .tooling["build-tools"].source_fingerprint == "sha256:5656565656565656565656565656565656565656565656565656565656565656"
    and .release.tag == "v0.4.0"
    and .release.runtime_origin == "accepted-stack"
    and .release.build_tools_origin == "fresh-release-build"
  ' "$release"
  [ "$status" -eq 0 ]
}

@test "release acceptance requires tag source and release-specific evidence gates" {
  source "$REPO_ROOT/scripts/lib/ci-artifact-identity.sh"
  record="$BATS_TEST_TMPDIR/release-acceptance.json"
  cat >"$record" <<'JSON'
{
  "schema":"stack-acceptance/v1",
  "accepted":true,
  "source_sha":"1111111111111111111111111111111111111111",
  "source_ref":"refs/tags/v0.4.0",
  "stack_lock_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "accepted_tag":"accepted-v2-release-v0.4.0-test",
  "release_tag":"v0.4.0",
  "gates":{
    "identity_complete":true,
    "platform_complete":true,
    "provenance":true,
    "exact_digest_security":true,
    "native_platform_smoke":true,
    "exact_locked_stack":true,
    "runtime_deep_validation":true,
    "supplemental_full_setup":true,
    "publication_policy":true,
    "accepted_runtime_identity_preserved":true,
    "release_build_tools_built":true,
    "release_build_tools_provenance":true,
    "release_exact_digest_evidence":false
  }
}
JSON

  run ci_ai_validate_release_acceptance "$record"
  [ "$status" -ne 0 ]

  jq '.gates.release_exact_digest_evidence = true' "$record" >"$record.tmp"
  mv "$record.tmp" "$record"
  run ci_ai_validate_release_acceptance "$record"
  [ "$status" -eq 0 ]

  jq '.source_ref = "refs/heads/current_dev"' "$record" >"$record.tmp"
  mv "$record.tmp" "$record"
  run ci_ai_validate_release_acceptance "$record"
  [ "$status" -ne 0 ]
}
