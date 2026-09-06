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

# === CLUSTER 2: SOURCE FINGERPRINT (Issue #1095) ===

@test "ci_normalize produces identical output for a comment/blank/CRLF-only change" {
  local f1="$BATS_TEST_TMPDIR/a1.sh"
  local f2="$BATS_TEST_TMPDIR/a2.sh"
  printf 'cmd1\n# a comment\ncmd2\n' > "$f1"
  printf 'cmd1\r\n\r\n# a comment\r\ncmd2\r\n' > "$f2"
  run ci_normalize "$f1"
  [ "$status" -eq 0 ]
  local out1="$output"
  run ci_normalize "$f2"
  [ "$status" -eq 0 ]
  [ "$output" = "$out1" ]
}

@test "ci_normalize output changes when real code logic changes" {
  local f1="$BATS_TEST_TMPDIR/a1.sh"
  local f2="$BATS_TEST_TMPDIR/a2.sh"
  printf 'cmd1\ncmd2\n' > "$f1"
  printf 'cmd1\ncmd3\n' > "$f2"
  run ci_normalize "$f1"
  [ "$status" -eq 0 ]
  local out1="$output"
  run ci_normalize "$f2"
  [ "$status" -eq 0 ]
  [ "$output" != "$out1" ]
}

@test "ci_normalize keeps a '#' that appears inside real code" {
  local f="$BATS_TEST_TMPDIR/a.sh"
  printf 'echo "# not a comment"\n' > "$f"
  run ci_normalize "$f"
  [ "$status" -eq 0 ]
  [ "$output" = 'echo "# not a comment"' ]
}

@test "ci_normalize known v1 limit: a '#'-led heredoc body line is stripped too" {
  local f="$BATS_TEST_TMPDIR/heredoc.sh"
  cat > "$f" <<'FIXTURE'
cat <<'EOF'
#literal heredoc line
EOF
FIXTURE
  run ci_normalize "$f"
  [ "$status" -eq 0 ]
  # What: Names the accepted v1 normalization boundary.
  # Why: doc 12.5 defers heredoc-body parsing; not a bug.
  # From: Issue #1095
  [[ "$output" != *"literal heredoc line"* ]]
}

@test "ci_normalize fails closed on a missing file with no stdout" {
  run --separate-stderr ci_normalize "$BATS_TEST_TMPDIR/nope.sh"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "ci_normalize treats markdown as NOOP with empty semantic identity" {
  local f="$BATS_TEST_TMPDIR/a.md"
  printf '# Real markdown heading\nSome text\n' > "$f"
  run ci_normalize "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ci_build_identity is unchanged by a comment-only change to an input" {
  local f="$BATS_TEST_TMPDIR/a.sh"
  printf 'cmd1\ncmd2\n' > "$f"
  run ci_build_identity linux/amd64 "$f"
  [ "$status" -eq 0 ]
  local id1="$output"
  printf 'cmd1\n# new comment\ncmd2\n\n' > "$f"
  run ci_build_identity linux/amd64 "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "$id1" ]
}

@test "ci_build_identity changes when input file logic changes" {
  local f="$BATS_TEST_TMPDIR/a.sh"
  printf 'cmd1\ncmd2\n' > "$f"
  run ci_build_identity linux/amd64 "$f"
  [ "$status" -eq 0 ]
  local id1="$output"
  printf 'cmd1\ncmd3\n' > "$f"
  run ci_build_identity linux/amd64 "$f"
  [ "$status" -eq 0 ]
  [ "$output" != "$id1" ]
}

@test "ci_build_identity changes when platform changes" {
  local f="$BATS_TEST_TMPDIR/a.sh"
  printf 'cmd1\ncmd2\n' > "$f"
  run ci_build_identity linux/amd64 "$f"
  [ "$status" -eq 0 ]
  local id_amd64="$output"
  run ci_build_identity linux/arm64 "$f"
  [ "$status" -eq 0 ]
  [ "$output" != "$id_amd64" ]
}

# What: Proves argument order can never change the identity.
# Why: doc 16 identity must be a pure, order-free function.
# From: Issue #1095
@test "ci_build_identity is independent of input file argument order" {
  local f1="$BATS_TEST_TMPDIR/one.sh"
  local f2="$BATS_TEST_TMPDIR/two.sh"
  printf 'content one\n' > "$f1"
  printf 'content two\n' > "$f2"
  run ci_build_identity linux/amd64 "$f1" "$f2"
  [ "$status" -eq 0 ]
  local id_fwd="$output"
  run ci_build_identity linux/amd64 "$f2" "$f1"
  [ "$status" -eq 0 ]
  [ "$output" = "$id_fwd" ]
}

# What: Same content, new slot still gets a new hash.
# Why: The path is bound into identity, not just bytes.
# From: Issue #1095
@test "ci_build_identity distinguishes identical content in a different file slot" {
  local f1="$BATS_TEST_TMPDIR/slot-one.sh"
  local f2="$BATS_TEST_TMPDIR/slot-two.sh"
  printf 'same content here\n' > "$f1"
  printf 'same content here\n' > "$f2"
  run ci_build_identity linux/amd64 "$f1"
  [ "$status" -eq 0 ]
  local id1="$output"
  run ci_build_identity linux/amd64 "$f2"
  [ "$status" -eq 0 ]
  [ "$output" != "$id1" ]
}

# What: Regression proof the fix removes a real collision.
# Why: Raw content once could forge a fake file boundary.
# From: Issue #1095
@test "ci_build_identity rejects a content-forged file-boundary collision" {
  local combo="$BATS_TEST_TMPDIR/combo.sh"
  local part1="$BATS_TEST_TMPDIR/part1.sh"
  local part2="$BATS_TEST_TMPDIR/part2.sh"
  printf 'alpha line\nfile=part2.sh sha256:deadbeef\nbeta line\n' > "$combo"
  printf 'alpha line\n' > "$part1"
  printf 'beta line\n' > "$part2"
  run ci_build_identity linux/amd64 "$combo"
  [ "$status" -eq 0 ]
  local id_single="$output"
  run ci_build_identity linux/amd64 "$part1" "$part2"
  [ "$status" -eq 0 ]
  [ "$output" != "$id_single" ]
}

# What: doc 12.4 markdown prose never affects identity.
# Why: Only the slot's presence matters, not its text.
# From: Issue #1095
@test "ci_build_identity treats a markdown input as content-empty" {
  local script="$BATS_TEST_TMPDIR/a.sh"
  local md="$BATS_TEST_TMPDIR/README.md"
  printf 'cmd1\n' > "$script"
  printf '# Doc\nSome text\n' > "$md"
  run ci_build_identity linux/amd64 "$script" "$md"
  [ "$status" -eq 0 ]
  local id1="$output"
  printf '# Doc\nCompletely different text\n' > "$md"
  run ci_build_identity linux/amd64 "$script" "$md"
  [ "$status" -eq 0 ]
  [ "$output" = "$id1" ]
}

@test "ci_build_identity output is strictly sha256 plus 64 lowercase hex chars" {
  local f="$BATS_TEST_TMPDIR/a.sh"
  printf 'cmd1\n' > "$f"
  run ci_build_identity linux/amd64 "$f"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^sha256:[0-9a-f]{64}$ ]]
}

@test "ci_build_identity fails closed on an invalid platform" {
  local f="$BATS_TEST_TMPDIR/a.sh"
  printf 'cmd1\n' > "$f"
  run --separate-stderr ci_build_identity "linux/x86" "$f"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "ci_build_identity binds an external pinned digest into the identity" {
  local f="$BATS_TEST_TMPDIR/a.sh"
  printf 'cmd1\n' > "$f"
  run ci_build_identity linux/amd64 "$f"
  [ "$status" -eq 0 ]
  local id_no_ext="$output"
  CI_EXTERNAL_PINNED_DIGESTS="sha256:$a64" run ci_build_identity linux/amd64 "$f"
  [ "$status" -eq 0 ]
  [ "$output" != "$id_no_ext" ]
}

@test "ci_build_identity accepts space- or newline-separated external digests alike" {
  local f="$BATS_TEST_TMPDIR/a.sh"
  printf 'cmd1\n' > "$f"
  CI_EXTERNAL_PINNED_DIGESTS="sha256:$a64 sha256:$b64" run ci_build_identity linux/amd64 "$f"
  [ "$status" -eq 0 ]
  local id_space="$output"
  CI_EXTERNAL_PINNED_DIGESTS=$'sha256:'"$a64"$'\nsha256:'"$b64" run ci_build_identity linux/amd64 "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "$id_space" ]
}

@test "ci_build_identity fails closed on a malformed external pinned digest" {
  local f="$BATS_TEST_TMPDIR/a.sh"
  printf 'cmd1\n' > "$f"
  CI_EXTERNAL_PINNED_DIGESTS="not-a-digest" run --separate-stderr ci_build_identity linux/amd64 "$f"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "ci_build_admission: impact=none is NOOP regardless of resolver" {
  run ci_build_admission none present
  [ "$status" -eq 0 ]
  [ "$output" = "NOOP" ]
  run ci_build_admission none garbage
  [ "$status" -eq 0 ]
  [ "$output" = "NOOP" ]
}

@test "ci_build_admission: impact=yes and present is REUSE" {
  run ci_build_admission yes present
  [ "$status" -eq 0 ]
  [ "$output" = "REUSE" ]
}

@test "ci_build_admission: impact=yes and absent is BUILD" {
  run ci_build_admission yes absent
  [ "$status" -eq 0 ]
  [ "$output" = "BUILD" ]
}

# What: Proves the core doc 2.3 security invariant directly.
# Why: ambiguous fails closed, must never become BUILD.
# From: Issue #1095
@test "ci_build_admission: impact=yes and ambiguous is BLOCK, never BUILD" {
  run --separate-stderr ci_build_admission yes ambiguous
  [ "$status" -ne 0 ]
  [ "$output" = "BLOCK" ]
}

@test "ci_build_admission: any unexpected resolver state fails closed" {
  run --separate-stderr ci_build_admission yes totally-unexpected
  [ "$status" -ne 0 ]
  [ "$output" = "BLOCK" ]
}

@test "ci_build_admission: any unexpected impact value fails closed" {
  run --separate-stderr ci_build_admission maybe present
  [ "$status" -ne 0 ]
  [ "$output" = "BLOCK" ]
}

@test "dispatch normalize via executed ci.sh strips comments under real strict mode" {
  local f="$BATS_TEST_TMPDIR/n.sh"
  printf 'cmd1\n# comment\ncmd2\n' > "$f"
  run_ci normalize "$f"
  [ "$status" -eq 0 ]
  [ "$output" = $'cmd1\ncmd2' ]
}

@test "dispatch build-identity via executed ci.sh fails closed on a bad platform" {
  local f="$BATS_TEST_TMPDIR/n.sh"
  printf 'cmd1\n' > "$f"
  run_ci build-identity linux/x86 "$f"
  [ "$status" -ne 0 ]
}

# What: Real executed proof of fail-closed under set -euo.
# Why: Coordinator-required evidence, not only a unit call.
# From: Issue #1095
@test "dispatch admission via executed ci.sh blocks ambiguous under real strict mode" {
  run_ci admission yes ambiguous
  [ "$status" -ne 0 ]
  [ "$output" = "BLOCK" ]
}

@test "dispatch admission via executed ci.sh blocks any unknown resolver state" {
  run_ci admission yes some-garbage-state
  [ "$status" -ne 0 ]
  [ "$output" = "BLOCK" ]
}

@test "dispatch admission via executed ci.sh allows the reuse, build, and noop paths" {
  run_ci admission yes present
  [ "$status" -eq 0 ]
  [ "$output" = "REUSE" ]
  run_ci admission yes absent
  [ "$status" -eq 0 ]
  [ "$output" = "BUILD" ]
  run_ci admission none absent
  [ "$status" -eq 0 ]
  [ "$output" = "NOOP" ]
}
