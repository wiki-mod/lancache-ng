#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: Unit coverage for scripts/ci/ci.sh (Cluster 1).
# Why: Prove digest identity and fail-closed 3-state read.
# From: Issue #1095

bats_require_minimum_version 1.5.0

setup() {
  repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # shellcheck source=scripts/ci/ci.sh
  source "$repo_root/scripts/ci/ci.sh"

  sha40="0123456789abcdef0123456789abcdef01234567"
  a64="$(printf 'a%.0s' {1..64})"
  b64="$(printf 'b%.0s' {1..64})"
  c64="$(printf 'c%.0s' {1..64})"
  d64="$(printf 'd%.0s' {1..64})"
  image="ghcr.io/wiki-mod/lancache-ng/dns"

  # What: A PATH docker stub steered by STUB_MODE.
  # Why: Exercises the real set -e executed path.
  # From: Issue #1095
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "${STUB_MODE:-ambiguous}" in
  present)   printf '"%s"\n' "$STUB_DIGEST"; exit 0 ;;
  malformed) printf '"%s"\n' "sha256:notavaliddigest"; exit 0 ;;
  absent)    echo "ERROR: ghcr.io/x/y:tag: not found" >&2; exit 1 ;;
  *)         echo "dial tcp: i/o timeout" >&2; exit 1 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
}

write_platform_record() {
  local file="$1" platform="$2"
  jq -n --arg p "linux/$platform" --arg sha "$sha40" \
    --arg fp "sha256:$a64" --arg dg "sha256:$b64" --arg img "$image" '{
      schema: "image-candidate-platform/v1", scope: "runtime",
      service: "dns", image: $img, platform: $p, source_sha: $sha,
      source_fingerprint: $fp, digest: $dg, mode: "built",
      reused_index_digest: ""
    }' > "$file"
}

write_index_record() {
  local file="$1"
  jq -n --arg sha "$sha40" --arg fp "sha256:$a64" --arg dg "sha256:$b64" \
    --arg da "sha256:$c64" --arg dr "sha256:$d64" --arg img "$image" '{
      schema: "image-candidate-index/v1", scope: "runtime",
      service: "dns", image: $img, source_sha: $sha,
      source_fingerprint: $fp, digest: $dg,
      candidate_ref: ($img + "@" + $dg),
      platforms: { "linux/amd64": $da, "linux/arm64": $dr }
    }' > "$file"
}

run_ci() {
  # What: Runs the executed script with the docker stub.
  # Why: Proves ci_main strict mode plus the real dispatch.
  # From: Issue #1095
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
  GHCR_RETRY_BACKOFF_SECONDS=0 GHCR_RETRY_MAX_ATTEMPTS=1 \
  run --separate-stderr bash "$repo_root/scripts/ci/ci.sh" "$@"
}

@test "require-digest accepts a strict sha256 digest" {
  run ci_require_digest "sha256:$a64"
  [ "$status" -eq 0 ]
}

@test "require-digest rejects every non-strict form" {
  local bad
  for bad in "" "nightly" "sha256:${a64}x" "sha256:${a64:0:63}" \
      "sha256:${a64}a" "$a64" "SHA256:$a64" \
      "sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; do
    run ci_require_digest "$bad"
    [ "$status" -ne 0 ]
  done
}

@test "require-source-sha accepts a 40-hex commit sha" {
  run ci_require_source_sha "$sha40"
  [ "$status" -eq 0 ]
}

@test "require-source-sha rejects wrong lengths, case, and empty" {
  local bad
  for bad in "" "${sha40:0:39}" "${sha40}a" "0123456789ABCDEF0123456789abcdef01234567"; do
    run ci_require_source_sha "$bad"
    [ "$status" -ne 0 ]
  done
}

@test "validate-platform-record accepts each arch with its own platform arg" {
  local platform
  for platform in amd64 arm64; do
    write_platform_record "$BATS_TEST_TMPDIR/p.json" "$platform"
    run ci_validate_platform_record "$BATS_TEST_TMPDIR/p.json" "$platform"
    [ "$status" -eq 0 ]
  done
}

@test "validate-platform-record rejects an arch mismatch against its record" {
  write_platform_record "$BATS_TEST_TMPDIR/amd.json" amd64
  run ci_validate_platform_record "$BATS_TEST_TMPDIR/amd.json" arm64
  [ "$status" -ne 0 ]
  write_platform_record "$BATS_TEST_TMPDIR/arm.json" arm64
  run ci_validate_platform_record "$BATS_TEST_TMPDIR/arm.json" amd64
  [ "$status" -ne 0 ]
}

@test "validate-platform-record rejects a bad platform argument" {
  write_platform_record "$BATS_TEST_TMPDIR/p.json" amd64
  run ci_validate_platform_record "$BATS_TEST_TMPDIR/p.json" x86
  [ "$status" -ne 0 ]
}

@test "validate-platform-record rejects wrong schema, missing field, bad digest" {
  local platform
  for platform in amd64 arm64; do
    write_platform_record "$BATS_TEST_TMPDIR/base.json" "$platform"
    jq '.schema = "image-candidate-platform/v2"' \
      "$BATS_TEST_TMPDIR/base.json" > "$BATS_TEST_TMPDIR/s.json"
    run ci_validate_platform_record "$BATS_TEST_TMPDIR/s.json" "$platform"
    [ "$status" -ne 0 ]
    jq 'del(.digest)' \
      "$BATS_TEST_TMPDIR/base.json" > "$BATS_TEST_TMPDIR/m.json"
    run ci_validate_platform_record "$BATS_TEST_TMPDIR/m.json" "$platform"
    [ "$status" -ne 0 ]
    jq '.digest = "sha256:xyz"' \
      "$BATS_TEST_TMPDIR/base.json" > "$BATS_TEST_TMPDIR/d.json"
    run ci_validate_platform_record "$BATS_TEST_TMPDIR/d.json" "$platform"
    [ "$status" -ne 0 ]
  done
}

@test "validate-platform-record rejects malformed json and a missing file" {
  printf '{not json' > "$BATS_TEST_TMPDIR/bad.json"
  run ci_validate_platform_record "$BATS_TEST_TMPDIR/bad.json" amd64
  [ "$status" -ne 0 ]
  run ci_validate_platform_record "$BATS_TEST_TMPDIR/nope.json" amd64
  [ "$status" -ne 0 ]
}

@test "validate-platform-record enforces the built vs reused invariant" {
  write_platform_record "$BATS_TEST_TMPDIR/base.json" amd64
  jq --arg r "sha256:$c64" '.mode = "built" | .reused_index_digest = $r' \
    "$BATS_TEST_TMPDIR/base.json" > "$BATS_TEST_TMPDIR/bad1.json"
  run ci_validate_platform_record "$BATS_TEST_TMPDIR/bad1.json" amd64
  [ "$status" -ne 0 ]
  jq '.mode = "reused" | .reused_index_digest = ""' \
    "$BATS_TEST_TMPDIR/base.json" > "$BATS_TEST_TMPDIR/bad2.json"
  run ci_validate_platform_record "$BATS_TEST_TMPDIR/bad2.json" amd64
  [ "$status" -ne 0 ]
  jq --arg r "sha256:$c64" '.mode = "reused" | .reused_index_digest = $r' \
    "$BATS_TEST_TMPDIR/base.json" > "$BATS_TEST_TMPDIR/ok.json"
  run ci_validate_platform_record "$BATS_TEST_TMPDIR/ok.json" amd64
  [ "$status" -eq 0 ]
}

@test "validate-index-record accepts a digest ref and a tag ref" {
  write_index_record "$BATS_TEST_TMPDIR/idx.json"
  run ci_validate_index_record "$BATS_TEST_TMPDIR/idx.json"
  [ "$status" -eq 0 ]
  jq --arg t "$image:nightly" '.candidate_ref = $t' \
    "$BATS_TEST_TMPDIR/idx.json" > "$BATS_TEST_TMPDIR/tag.json"
  run ci_validate_index_record "$BATS_TEST_TMPDIR/tag.json"
  [ "$status" -eq 0 ]
}

@test "validate-index-record rejects a candidate_ref digest mismatch" {
  write_index_record "$BATS_TEST_TMPDIR/idx.json"
  jq --arg r "$image@sha256:$c64" '.candidate_ref = $r' \
    "$BATS_TEST_TMPDIR/idx.json" > "$BATS_TEST_TMPDIR/bad.json"
  run ci_validate_index_record "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -ne 0 ]
}

@test "validate-index-record rejects wrong platform key sets and bad child digests" {
  write_index_record "$BATS_TEST_TMPDIR/idx.json"
  jq 'del(.platforms."linux/arm64")' \
    "$BATS_TEST_TMPDIR/idx.json" > "$BATS_TEST_TMPDIR/miss.json"
  run ci_validate_index_record "$BATS_TEST_TMPDIR/miss.json"
  [ "$status" -ne 0 ]
  jq '.platforms."linux/ppc64le" = "sha256:x"' \
    "$BATS_TEST_TMPDIR/idx.json" > "$BATS_TEST_TMPDIR/extra.json"
  run ci_validate_index_record "$BATS_TEST_TMPDIR/extra.json"
  [ "$status" -ne 0 ]
  jq '.platforms."linux/amd64" = "sha256:xyz"' \
    "$BATS_TEST_TMPDIR/idx.json" > "$BATS_TEST_TMPDIR/child.json"
  run ci_validate_index_record "$BATS_TEST_TMPDIR/child.json"
  [ "$status" -ne 0 ]
}

@test "validate-index-record rejects wrong schema and malformed json" {
  write_index_record "$BATS_TEST_TMPDIR/idx.json"
  jq '.schema = "image-candidate-index/v2"' \
    "$BATS_TEST_TMPDIR/idx.json" > "$BATS_TEST_TMPDIR/s.json"
  run ci_validate_index_record "$BATS_TEST_TMPDIR/s.json"
  [ "$status" -ne 0 ]
  printf '{not json' > "$BATS_TEST_TMPDIR/bad.json"
  run ci_validate_index_record "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -ne 0 ]
}

# What: Exercise validators via the executed dispatcher.
# Why: Proves fail-closed under ci_main's set -euo pipefail.
# From: Issue #1095
@test "dispatch require-digest via executed ci.sh accepts and rejects" {
  run_ci require-digest "sha256:$a64"
  [ "$status" -eq 0 ]
  run_ci require-digest "nightly"
  [ "$status" -ne 0 ]
}

@test "dispatch require-source-sha via executed ci.sh accepts and rejects" {
  run_ci require-source-sha "$sha40"
  [ "$status" -eq 0 ]
  run_ci require-source-sha "zzzz"
  [ "$status" -ne 0 ]
}

@test "dispatch validate-platform-record via executed ci.sh fails closed" {
  write_platform_record "$BATS_TEST_TMPDIR/p.json" amd64
  run_ci validate-platform-record "$BATS_TEST_TMPDIR/p.json" amd64
  [ "$status" -eq 0 ]
  printf '{not json' > "$BATS_TEST_TMPDIR/bad.json"
  run_ci validate-platform-record "$BATS_TEST_TMPDIR/bad.json" amd64
  [ "$status" -ne 0 ]
}

@test "dispatch validate-index-record via executed ci.sh fails closed" {
  write_index_record "$BATS_TEST_TMPDIR/idx.json"
  run_ci validate-index-record "$BATS_TEST_TMPDIR/idx.json"
  [ "$status" -eq 0 ]
  printf '{not json' > "$BATS_TEST_TMPDIR/bad.json"
  run_ci validate-index-record "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -ne 0 ]
}

@test "dispatch rejects an empty and an unknown command with usage code 2" {
  run_ci
  [ "$status" -eq 2 ]
  run_ci bogus-command
  [ "$status" -eq 2 ]
}

@test "resolve-ref-state returns present and prints the digest" {
  STUB_MODE=present STUB_DIGEST="sha256:$a64" run_ci resolve-ref-state "$image:tag"
  [ "$status" -eq 0 ]
  [ "$output" = "sha256:$a64" ]
}

@test "resolve-ref-state returns absent only on a confirmed registry 404" {
  STUB_MODE=absent run_ci resolve-ref-state "$image:tag"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "resolve-ref-state fails closed to ambiguous on network trouble" {
  STUB_MODE=ambiguous run_ci resolve-ref-state "$image:tag"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "resolve-ref-state fails closed when a present ref yields a bad digest" {
  STUB_MODE=malformed run_ci resolve-ref-state "$image:tag"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
