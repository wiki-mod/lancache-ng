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

# === CLUSTER 3: SERVICE INVENTORY + IMPACT DETECTION (Issue #1095) ===

# What: A throw-away git repo for real base_sha comparisons.
# Why: ci_semantic_changed runs real git, not a stub.
# From: Issue #1095
init_impact_repo() {
  local dir="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "ci@lancache-ng.test"
  git -C "$dir" config user.name "lancache-ng ci"
  printf '%s' "$dir"
}

@test "CI_SERVICES is the frozen 11-service inventory (10 + netdata, nats excluded)" {
  [ "${#CI_SERVICES[@]}" -eq 11 ]
  local svc found_netdata=0 found_nats=0
  for svc in "${CI_SERVICES[@]}"; do
    [ "$svc" = "netdata" ] && found_netdata=1
    [ "$svc" = "nats" ] && found_nats=1
  done
  [ "$found_netdata" -eq 1 ]
  [ "$found_nats" -eq 0 ]
}

@test "ci_known_service accepts every CI_SERVICES member and rejects an unknown name" {
  local svc
  for svc in "${CI_SERVICES[@]}"; do
    run ci_known_service "$svc"
    [ "$status" -eq 0 ]
  done
  run ci_known_service "bogus-service"
  [ "$status" -ne 0 ]
}

@test "ci_service_meta returns the recorded context/platforms/runner/external-context" {
  run ci_service_meta proxy context
  [ "$output" = "services/proxy" ]
  run ci_service_meta proxy external-context
  [ "$output" = "dns-domains=services/dns shared-scripts=scripts/lib" ]
  run ci_service_meta netdata platforms
  # What: netdata pins amd64 only, no arm64 build.
  # Why: doc 8 metadata must match the real Dockerfile.
  # From: Issue #1095
  [ "$output" = "linux/amd64" ]
  run ci_service_meta netdata runner
  [ "$output" = "light" ]
  run ci_service_meta dns runner
  [ "$output" = "heavy" ]
  run ci_service_meta cachehamster external-context
  [ "$output" = "" ]
}

@test "ci_service_meta fails closed on an unknown service and an unknown field" {
  run --separate-stderr ci_service_meta bogus context
  [ "$status" -ne 0 ]
  run --separate-stderr ci_service_meta proxy bogus-field
  [ "$status" -ne 0 ]
}

@test "ci_impact_classify maps the verified cross-service dependency edges" {
  run ci_impact_classify services/dns/cdn-domains.txt
  [ "$output" = "dns proxy" ]
  run ci_impact_classify scripts/lib/verify-version-banner.sh
  [ "$output" = "proxy dns watchdog dhcp dhcp-proxy ui" ]
  run ci_impact_classify Cargo.toml
  [ "$output" = "dns watchdog ui" ]
  run ci_impact_classify Cargo.lock
  [ "$output" = "dns watchdog ui" ]
}

# What: cachehamster builds from its own isolated context.
# Why: its Dockerfile never copies the workspace lockfile.
# From: Issue #1095
@test "ci_impact_classify excludes cachehamster from the root workspace lockfile edge" {
  run ci_impact_classify Cargo.lock
  [[ "$output" != *cachehamster* ]]
  run ci_impact_classify services/cachehamster/Cargo.toml
  [ "$output" = "cachehamster" ]
}

@test "ci_impact_classify treats every markdown path as NONE regardless of location" {
  run ci_impact_classify README.md
  [ "$output" = "NONE" ]
  run ci_impact_classify docs/ci-2.0-architecture.md
  [ "$output" = "NONE" ]
  run ci_impact_classify services/dns/README.md
  [ "$output" = "NONE" ]
}

@test "ci_impact_classify maps each service's own context prefix to itself only" {
  run ci_impact_classify services/ntp/chrony.conf
  [ "$output" = "ntp" ]
  run ci_impact_classify tools/build-tools/Dockerfile
  [ "$output" = "build-tools" ]
  run ci_impact_classify services/netdata/entrypoint.sh
  [ "$output" = "netdata" ]
}

@test "ci_impact_classify fails closed to ALL for an unclassified path" {
  run ci_impact_classify some/unknown/new-top-level-file.sh
  [ "$output" = "ALL" ]
  run ci_impact_classify deploy/prod/docker-compose.yml
  [ "$output" = "ALL" ]
}

@test "ci_semantic_changed is false for a comment-only change and true for a real change" {
  local repo; repo="$(init_impact_repo)"
  mkdir -p "$repo/services/dns"
  printf 'cmd1\n# old comment\ncmd2\n' > "$repo/services/dns/entrypoint.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  local base; base="$(git -C "$repo" rev-parse HEAD)"

  cd "$repo"
  printf 'cmd1\n# a totally different comment\ncmd2\n\n' \
    > services/dns/entrypoint.sh
  run ci_semantic_changed "$base" services/dns/entrypoint.sh
  [ "$status" -eq 1 ]

  printf 'cmd1\ncmd3\n' > services/dns/entrypoint.sh
  run ci_semantic_changed "$base" services/dns/entrypoint.sh
  [ "$status" -eq 0 ]
}

@test "ci_semantic_changed is true when the path is new or was removed" {
  local repo; repo="$(init_impact_repo)"
  printf 'unrelated\n' > "$repo/keep.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  local base; base="$(git -C "$repo" rev-parse HEAD)"

  cd "$repo"
  # What: a path absent from base_sha has no baseline.
  # Why: a brand-new build input is never a silent NOOP.
  # From: Issue #1095
  printf 'new\n' > brand-new.sh
  run ci_semantic_changed "$base" brand-new.sh
  [ "$status" -eq 0 ]

  # What: a missing working-tree file is a real change too.
  # Why: a removed build input is never a silent NOOP.
  # From: Issue #1095
  run ci_semantic_changed "$base" keep.sh
  [ "$status" -eq 1 ]
  rm -f keep.sh
  run ci_semantic_changed "$base" keep.sh
  [ "$status" -eq 0 ]
}

@test "ci_service_impact: comment-only dns change is NOOP, real dns change is IMPACTED" {
  local repo; repo="$(init_impact_repo)"
  mkdir -p "$repo/services/dns"
  printf 'cmd1\n# old\ncmd2\n' > "$repo/services/dns/entrypoint.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  local base; base="$(git -C "$repo" rev-parse HEAD)"
  cd "$repo"

  printf 'cmd1\n# new wording only\ncmd2\n' > services/dns/entrypoint.sh
  run ci_service_impact "$base" dns services/dns/entrypoint.sh
  [ "$status" -eq 0 ]
  [ "$output" = "NOOP" ]

  printf 'cmd1\ncmd_changed\n' > services/dns/entrypoint.sh
  run ci_service_impact "$base" dns services/dns/entrypoint.sh
  [ "$status" -eq 0 ]
  [ "$output" = "IMPACTED" ]
}

@test "ci_service_impact: cdn-domains.txt change impacts dns and proxy, not an unrelated service" {
  local repo; repo="$(init_impact_repo)"
  mkdir -p "$repo/services/dns"
  printf 'cdn.example.com\n' > "$repo/services/dns/cdn-domains.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  local base; base="$(git -C "$repo" rev-parse HEAD)"
  cd "$repo"
  printf 'cdn.example.com\nnew.example.com\n' > services/dns/cdn-domains.txt

  run ci_service_impact "$base" dns services/dns/cdn-domains.txt
  [ "$output" = "IMPACTED" ]
  run ci_service_impact "$base" proxy services/dns/cdn-domains.txt
  [ "$output" = "IMPACTED" ]
  run ci_service_impact "$base" ntp services/dns/cdn-domains.txt
  [ "$output" = "NOOP" ]
}

@test "ci_service_impact: shared-scripts change impacts all 6 consumers, not a non-consumer" {
  local repo; repo="$(init_impact_repo)"
  mkdir -p "$repo/scripts/lib"
  printf 'echo v1\n' > "$repo/scripts/lib/verify-version-banner.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  local base; base="$(git -C "$repo" rev-parse HEAD)"
  cd "$repo"
  printf 'echo v2 changed\n' > scripts/lib/verify-version-banner.sh

  local svc
  for svc in proxy dns watchdog dhcp dhcp-proxy ui; do
    run ci_service_impact "$base" "$svc" scripts/lib/verify-version-banner.sh
    [ "$output" = "IMPACTED" ]
  done
  for svc in ntp syslog build-tools cachehamster netdata; do
    run ci_service_impact "$base" "$svc" scripts/lib/verify-version-banner.sh
    [ "$output" = "NOOP" ]
  done
}

@test "ci_service_impact: root Cargo.lock change excludes cachehamster" {
  local repo; repo="$(init_impact_repo)"
  printf 'lockfile v1\n' > "$repo/Cargo.lock"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  local base; base="$(git -C "$repo" rev-parse HEAD)"
  cd "$repo"
  printf 'lockfile v2\n' > Cargo.lock

  local svc
  for svc in dns watchdog ui; do
    run ci_service_impact "$base" "$svc" Cargo.lock
    [ "$output" = "IMPACTED" ]
  done
  run ci_service_impact "$base" cachehamster Cargo.lock
  [ "$output" = "NOOP" ]
}

@test "ci_service_impact: a pure documentation path is NOOP for every service" {
  local repo; repo="$(init_impact_repo)"
  printf '# old\n' > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  local base; base="$(git -C "$repo" rev-parse HEAD)"
  cd "$repo"
  printf '# completely rewritten heading\nmore text\n' > README.md

  local svc
  for svc in "${CI_SERVICES[@]}"; do
    run ci_service_impact "$base" "$svc" README.md
    [ "$output" = "NOOP" ]
  done
}

# What: Proves the AG-INT-002 fail-closed floor per service.
# Why: An unmapped path must never silently NOOP anywhere.
# From: Issue #1095
@test "ci_service_impact: an unknown path fails closed to IMPACTED for every service" {
  local repo; repo="$(init_impact_repo)"
  printf 'x\n' > "$repo/keep.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  local base; base="$(git -C "$repo" rev-parse HEAD)"
  cd "$repo"

  local svc
  for svc in "${CI_SERVICES[@]}"; do
    run ci_service_impact "$base" "$svc" some/unmapped/new-path.sh
    [ "$status" -eq 0 ]
    [ "$output" = "IMPACTED" ]
  done
}

@test "ci_service_impact fails closed on an unknown service name" {
  local repo; repo="$(init_impact_repo)"
  git -C "$repo" commit -q -m base --allow-empty
  local base; base="$(git -C "$repo" rev-parse HEAD)"
  cd "$repo"
  run --separate-stderr ci_service_impact "$base" bogus-service some/path.sh
  [ "$status" -ne 0 ]
}

@test "ci_service_impact reads CHANGED_FILES from the environment when no paths are given" {
  local repo; repo="$(init_impact_repo)"
  mkdir -p "$repo/services/proxy" "$repo/services/ntp"
  printf 'old\n' > "$repo/services/proxy/nginx.conf"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  local base; base="$(git -C "$repo" rev-parse HEAD)"
  cd "$repo"
  printf 'new content\n' > services/proxy/nginx.conf

  CHANGED_FILES=$'services/proxy/nginx.conf\nservices/ntp/missing.conf' \
    run ci_service_impact "$base" proxy
  [ "$output" = "IMPACTED" ]
  CHANGED_FILES="services/proxy/nginx.conf" \
    run ci_service_impact "$base" ntp
  [ "$output" = "NOOP" ]
}

@test "ci_impact prints one NOOP/IMPACTED line per service for the full CI_SERVICES set" {
  local repo; repo="$(init_impact_repo)"
  mkdir -p "$repo/services/dns"
  printf 'x\n' > "$repo/services/dns/cdn-domains.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  local base; base="$(git -C "$repo" rev-parse HEAD)"
  cd "$repo"
  printf 'x\ny\n' > services/dns/cdn-domains.txt

  run ci_impact "$base" services/dns/cdn-domains.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"dns=IMPACTED"* ]]
  [[ "$output" == *"proxy=IMPACTED"* ]]
  [[ "$output" == *"ntp=NOOP"* ]]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 11 ]
}

@test "dispatch service-meta via executed ci.sh" {
  run_ci service-meta dns runner
  [ "$status" -eq 0 ]
  [ "$output" = "heavy" ]
  run_ci service-meta bogus context
  [ "$status" -ne 0 ]
}

@test "dispatch impact-classify via executed ci.sh" {
  run_ci impact-classify services/dns/cdn-domains.txt
  [ "$status" -eq 0 ]
  [ "$output" = "dns proxy" ]
}

# What: Real executed proof of the fail-closed floor.
# Why: Coordinator-required evidence, not only a unit call.
# From: Issue #1095
@test "dispatch service-impact via executed ci.sh fails closed to IMPACTED on an unknown path under real strict mode" {
  local repo; repo="$(init_impact_repo)"
  git -C "$repo" commit -q -m base --allow-empty
  local base; base="$(git -C "$repo" rev-parse HEAD)"
  cd "$repo"
  run_ci service-impact "$base" ntp some/unmapped/path.sh
  [ "$status" -eq 0 ]
  [ "$output" = "IMPACTED" ]
}

@test "dispatch impact via executed ci.sh reports every service under real strict mode" {
  local repo; repo="$(init_impact_repo)"
  printf 'x\n' > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  local base; base="$(git -C "$repo" rev-parse HEAD)"
  cd "$repo"
  printf 'y\n' >> README.md

  run_ci impact "$base" README.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"proxy=NOOP"* ]]
  [[ "$output" == *"netdata=NOOP"* ]]
}
