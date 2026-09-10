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
  # What: Ledger tests write fixture records directly.
  # Why: ci_ledger_read only lazy-loads it on demand.
  # From: Issue #1095
  # shellcheck source=scripts/lib/promote-lock.sh
  source "$repo_root/scripts/lib/promote-lock.sh"

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

# === CLUSTER 2: SOURCE FINGERPRINT ===

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

# === CLUSTER 3: SERVICE INVENTORY + IMPACT DETECTION ===

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

# What: cross-checked against classify-image-impact.sh.
# Why: narrows ALL to the 3 real Rust-builder consumers.
# From: Issue #1095
@test "ci_impact_classify maps the shared rust-acceleration actions" {
  run ci_impact_classify .github/actions/rust-acceleration-preflight/action.yml
  [ "$output" = "dns watchdog ui" ]
  run ci_impact_classify .github/actions/configure-rust-sccache/action.yml
  [ "$output" = "dns watchdog ui" ]
  run ci_impact_classify .github/actions/cargo-with-sccache-fallback/action.yml
  [ "$output" = "dns watchdog ui" ]
  run ci_impact_classify .github/actions/build-tools-candidate-smoke/action.yml
  [ "$output" = "build-tools" ]
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

# What: regression for a real reviewed defect: an unextended
#   mktemp baseline broke ci_normalize's *.md short-circuit.
# Why: the baseline copy must keep $path's real basename.
# From: Issue #1095
@test "ci_semantic_changed applies the markdown NOOP rule to the baseline copy too" {
  local repo; repo="$(init_impact_repo)"
  printf '# Heading\nSome text\n' > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  local base; base="$(git -C "$repo" rev-parse HEAD)"
  cd "$repo"

  # What: byte-identical markdown reports no change.
  # Why: proves the baseline normalizes as markdown too.
  # From: Issue #1095
  printf '# Heading\nSome text\n' > README.md
  run ci_semantic_changed "$base" README.md
  [ "$status" -eq 1 ]

  printf '# Heading\nCompletely different prose\n' > README.md
  run ci_semantic_changed "$base" README.md
  [ "$status" -eq 1 ]
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

# What: distinguishes no diff info at all from empty diff.
# Why: doc 2.3; unset is UNKNOWN, fails closed, not NOOP.
# From: Issue #1095
@test "ci_service_impact: unset CHANGED_FILES fails closed, empty CHANGED_FILES is a real NOOP" {
  local repo; repo="$(init_impact_repo)"
  git -C "$repo" commit -q -m base --allow-empty
  local base; base="$(git -C "$repo" rev-parse HEAD)"
  cd "$repo"

  unset CHANGED_FILES
  run ci_service_impact "$base" ntp
  [ "$status" -eq 0 ]
  [ "$output" = "IMPACTED" ]

  CHANGED_FILES="" run ci_service_impact "$base" ntp
  [ "$output" = "NOOP" ]
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

# What: pins the tri-state exit contract via real dispatch.
# Why: exit 1 (unchanged) under set -e aborts a bare caller.
# From: Issue #1095
@test "dispatch semantic-changed via executed ci.sh returns 0=changed, 1=unchanged" {
  local repo; repo="$(init_impact_repo)"
  printf 'cmd1\n# old\n' > "$repo/f.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  local base; base="$(git -C "$repo" rev-parse HEAD)"
  cd "$repo"

  printf 'cmd1\n# new wording only\n' > f.sh
  run_ci semantic-changed "$base" f.sh
  [ "$status" -eq 1 ]

  printf 'cmd_changed\n' > f.sh
  run_ci semantic-changed "$base" f.sh
  [ "$status" -eq 0 ]
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

# === CLUSTER 4: ACCEPTANCE LEDGER + ATTESTATION BOUNDARY ===

# What: A bare repo + clone, promote_lock.bats topology.
# Why: only plain git calls; a bare repo is faithful.
# From: Issue #1095
init_ledger_repo() {
  local bare="$BATS_TEST_TMPDIR/ledger-bare-$RANDOM.git"
  local clone="$BATS_TEST_TMPDIR/ledger-clone-$RANDOM"
  git init --quiet --bare "$bare" >/dev/null
  git clone --quiet "$bare" "$clone" >/dev/null
  printf '%s' "$clone"
}

# What: Builds one compact, single-line record fixture.
# Why: A commit message payload must have no embedded LF.
# From: Issue #1095
ledger_record_json() {
  local service="$1" platform="$2" build_identity="$3"
  local artifact_digest="$4" verdict="$5" attestation="$6"
  jq -nc --arg svc "$service" --arg plat "$platform" \
    --arg bid "$build_identity" --arg adg "$artifact_digest" \
    --arg sha "$sha40" --arg verdict "$verdict" --arg att "$attestation" '{
      schema: "ci-acceptance-ledger-record/v1", service: $svc,
      platform: $plat, build_identity: $bid, artifact_digest: $adg,
      source_sha: $sha, verdict: $verdict, attestation: $att,
      recorded_at: 1700000000
    }'
}

# What: Pushes one raw ledger fixture record by hand.
# Why: v1 has no writer; tests forge CAS state directly.
# From: Issue #1095
push_ledger_fixture() {
  local clone="$1" ref="$2" message="$3"
  local commit_sha
  commit_sha="$(cd "$clone" && promote_lock_create_commit "$message")"
  (cd "$clone" && git push --quiet origin "${commit_sha}:${ref}")
}

@test "ci_post_build_readback: SUCCESS when the registry digest matches expected" {
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
  STUB_MODE=present STUB_DIGEST="sha256:$a64" \
    run --separate-stderr ci_post_build_readback "sha256:$a64" "$image:tag"
  [ "$status" -eq "$CI_ARTIFACT_READBACK_SUCCESS" ]
  [ "$output" = "SUCCESS" ]
}

@test "ci_post_build_readback: MISMATCH when the registry digest differs" {
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
  STUB_MODE=present STUB_DIGEST="sha256:$b64" \
    run --separate-stderr ci_post_build_readback "sha256:$a64" "$image:tag"
  [ "$status" -eq "$CI_ARTIFACT_READBACK_MISMATCH" ]
  [ "$output" = "MISMATCH" ]
}

# What: ghcr_retry logs its own error on a 404.
# Why: --separate-stderr keeps stdout NOT_FOUND clean.
# From: Issue #1095
@test "ci_post_build_readback: NOT_FOUND on a confirmed registry absence, never a rebuild" {
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
  STUB_MODE=absent \
    run --separate-stderr ci_post_build_readback "sha256:$a64" "$image:tag"
  [ "$status" -eq "$CI_ARTIFACT_READBACK_NOT_FOUND" ]
  [ "$output" = "NOT_FOUND" ]
}

@test "ci_post_build_readback: UNKNOWN on registry ambiguity, never a rebuild" {
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
  STUB_MODE=ambiguous \
    run --separate-stderr ci_post_build_readback "sha256:$a64" "$image:tag"
  [ "$status" -eq "$CI_ARTIFACT_READBACK_UNKNOWN" ]
  [ "$output" = "UNKNOWN" ]
}

@test "ci_post_build_readback fails closed to UNKNOWN on a malformed expected_digest" {
  run --separate-stderr ci_post_build_readback "not-a-digest" "$image:tag"
  [ "$status" -eq "$CI_ARTIFACT_READBACK_UNKNOWN" ]
  [ -z "$output" ]
}

# What: Real executed proof of every readback outcome.
# Why: Coordinator-required evidence, not only a unit call.
# From: Issue #1095
@test "dispatch post-build-readback via executed ci.sh proves all 4 terminal exit codes" {
  STUB_MODE=present STUB_DIGEST="sha256:$a64" \
    run_ci post-build-readback "sha256:$a64" "$image:tag"
  [ "$status" -eq 0 ]
  [ "$output" = "SUCCESS" ]

  STUB_MODE=present STUB_DIGEST="sha256:$b64" \
    run_ci post-build-readback "sha256:$a64" "$image:tag"
  [ "$status" -eq 1 ]
  [ "$output" = "MISMATCH" ]

  STUB_MODE=absent run_ci post-build-readback "sha256:$a64" "$image:tag"
  [ "$status" -eq 2 ]
  [ "$output" = "NOT_FOUND" ]

  STUB_MODE=ambiguous run_ci post-build-readback "sha256:$a64" "$image:tag"
  [ "$status" -eq 3 ]
  [ "$output" = "UNKNOWN" ]
}

@test "ci_attestation_state always reports unverifiable in v1" {
  run ci_attestation_state
  [ "$status" -eq 0 ]
  [ "$output" = "unverifiable" ]
}

@test "ci_artifact_admission: ACCEPTED only for readback=SUCCESS, any attestation state" {
  local att
  for att in verified absent_confirmed unverifiable; do
    run ci_artifact_admission SUCCESS "$att"
    [ "$status" -eq 0 ]
    [ "$output" = "verdict=ACCEPTED attestation=$att" ]
  done
}

# What: Proves REJECTED (doc 25) never gets reused.
# Why: A wrong digest stays permanently rejected.
# From: Issue #1095
@test "ci_artifact_admission: MISMATCH is always REJECTED, never ACCEPTED" {
  local att
  for att in verified absent_confirmed unverifiable; do
    run --separate-stderr ci_artifact_admission MISMATCH "$att"
    [ "$status" -ne 0 ]
    [ "$output" = "verdict=REJECTED attestation=$att" ]
  done
}

@test "ci_artifact_admission: NOT_FOUND and UNKNOWN are BLOCK, never ACCEPTED" {
  local readback att
  for readback in NOT_FOUND UNKNOWN; do
    for att in verified absent_confirmed unverifiable; do
      run --separate-stderr ci_artifact_admission "$readback" "$att"
      [ "$status" -ne 0 ]
      [ "$output" = "verdict=BLOCK attestation=$att" ]
    done
  done
}

@test "ci_artifact_admission fails closed to BLOCK on an unrecognized attestation state" {
  run --separate-stderr ci_artifact_admission SUCCESS "totally-bogus"
  [ "$status" -ne 0 ]
  [ "$output" = "verdict=BLOCK attestation=totally-bogus" ]
}

@test "ci_artifact_admission fails closed to BLOCK on an unrecognized readback verdict" {
  run --separate-stderr ci_artifact_admission "totally-bogus" verified
  [ "$status" -ne 0 ]
  [ "$output" = "verdict=BLOCK attestation=verified" ]
}

# What: A bad attestation must never mask a real MISMATCH.
# Why: REJECTED is the stronger, more honest finding here.
# From: Issue #1095
@test "ci_artifact_admission: MISMATCH stays REJECTED even with a garbage attestation input" {
  run --separate-stderr ci_artifact_admission MISMATCH "totally-bogus"
  [ "$status" -ne 0 ]
  [ "$output" = "verdict=REJECTED attestation=totally-bogus" ]
}

# What: Proof that no input combination yields BUILD.
# Why: doc 24; build never auto-grants ARTIFACT ACK.
# From: Issue #1095
@test "ci_artifact_admission: no readback/attestation combination ever yields BUILD" {
  local readback att
  for readback in SUCCESS MISMATCH NOT_FOUND UNKNOWN garbage-readback; do
    for att in verified absent_confirmed unverifiable garbage-attestation; do
      run ci_artifact_admission "$readback" "$att"
      [[ "$output" != *"verdict=BUILD"* ]]
      [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
    done
  done
}

# What: unverifiable must never print as verified.
# Why: Overclaiming is worse than an honest open gap.
# From: Issue #1095
@test "ci_artifact_admission never overclaims: unverifiable never renders as verified" {
  run ci_artifact_admission SUCCESS unverifiable
  [[ "$output" != *"attestation=verified"* ]]
  [[ "$output" == *"attestation=unverifiable"* ]]
}

@test "dispatch artifact-admission via executed ci.sh fails closed under real strict mode" {
  run_ci artifact-admission MISMATCH unverifiable
  [ "$status" -ne 0 ]
  [ "$output" = "verdict=REJECTED attestation=unverifiable" ]

  run_ci artifact-admission SUCCESS unverifiable
  [ "$status" -eq 0 ]
  [ "$output" = "verdict=ACCEPTED attestation=unverifiable" ]
}

@test "ci_ledger_encode_digest / ci_ledger_decode_digest round-trip losslessly" {
  run ci_ledger_encode_digest "sha256:$a64"
  [ "$status" -eq 0 ]
  local encoded="$output"
  [ "$encoded" = "sha256-$a64" ]
  run ci_ledger_decode_digest "$encoded"
  [ "$status" -eq 0 ]
  [ "$output" = "sha256:$a64" ]
}

@test "ci_ledger_encode_digest fails closed on a non-digest input" {
  run --separate-stderr ci_ledger_encode_digest "not-a-digest"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "ci_ledger_decode_digest fails closed on every malformed encoded form" {
  local bad
  for bad in "sha256:$a64" "sha256-${a64:0:63}" "sha256-${a64}a" \
      "SHA256-$a64" "${a64}" "sha256-$(printf 'A%.0s' {1..64})"; do
    run --separate-stderr ci_ledger_decode_digest "$bad"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

@test "ci_ledger_ref builds the expected git-ref-CAS path for a known key" {
  run ci_ledger_ref dns linux/amd64 "sha256:$a64"
  [ "$status" -eq 0 ]
  [ "$output" = "refs/ci-acceptance-ledger/dns/amd64/sha256-$a64" ]
  run ci_ledger_ref ui linux/arm64 "sha256:$b64"
  [ "$output" = "refs/ci-acceptance-ledger/ui/arm64/sha256-$b64" ]
}

@test "ci_ledger_ref fails closed on an unknown service, bad platform, or bad digest" {
  run --separate-stderr ci_ledger_ref bogus-service linux/amd64 "sha256:$a64"
  [ "$status" -ne 0 ]
  run --separate-stderr ci_ledger_ref dns linux/x86 "sha256:$a64"
  [ "$status" -ne 0 ]
  run --separate-stderr ci_ledger_ref dns linux/amd64 "not-a-digest"
  [ "$status" -ne 0 ]
}

write_ledger_fixture_file() {
  local file="$1"
  ledger_record_json dns linux/amd64 "sha256:$a64" "sha256:$b64" \
    ACCEPTED unverifiable > "$file"
}

@test "ci_validate_ledger_record accepts every legal verdict/attestation pair" {
  local verdict att
  for verdict in ACCEPTED REJECTED BLOCK; do
    for att in verified absent_confirmed unverifiable; do
      ledger_record_json dns linux/amd64 "sha256:$a64" "sha256:$b64" \
        "$verdict" "$att" > "$BATS_TEST_TMPDIR/rec.json"
      run ci_validate_ledger_record "$BATS_TEST_TMPDIR/rec.json"
      [ "$status" -eq 0 ]
    done
  done
}

# What: Defense-in-depth: BUILD is never a verdict.
# Why: doc 24; a ledger record can never hide BUILD.
# From: Issue #1095
@test "ci_validate_ledger_record rejects a BUILD verdict outright" {
  ledger_record_json dns linux/amd64 "sha256:$a64" "sha256:$b64" \
    BUILD unverifiable > "$BATS_TEST_TMPDIR/rec.json"
  run ci_validate_ledger_record "$BATS_TEST_TMPDIR/rec.json"
  [ "$status" -ne 0 ]
}

@test "ci_validate_ledger_record rejects a missing attestation field" {
  write_ledger_fixture_file "$BATS_TEST_TMPDIR/base.json"
  jq 'del(.attestation)' "$BATS_TEST_TMPDIR/base.json" \
    > "$BATS_TEST_TMPDIR/missing.json"
  run ci_validate_ledger_record "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -ne 0 ]
}

@test "ci_validate_ledger_record rejects wrong schema and malformed json" {
  write_ledger_fixture_file "$BATS_TEST_TMPDIR/base.json"
  jq '.schema = "ci-acceptance-ledger-record/v2"' \
    "$BATS_TEST_TMPDIR/base.json" > "$BATS_TEST_TMPDIR/s.json"
  run ci_validate_ledger_record "$BATS_TEST_TMPDIR/s.json"
  [ "$status" -ne 0 ]
  printf '{not json' > "$BATS_TEST_TMPDIR/bad.json"
  run ci_validate_ledger_record "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -ne 0 ]
}

@test "dispatch validate-ledger-record via executed ci.sh fails closed" {
  write_ledger_fixture_file "$BATS_TEST_TMPDIR/ok.json"
  run_ci validate-ledger-record "$BATS_TEST_TMPDIR/ok.json"
  [ "$status" -eq 0 ]
  printf '{not json' > "$BATS_TEST_TMPDIR/bad.json"
  run_ci validate-ledger-record "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -ne 0 ]
}

@test "ci_ledger_read: ABSENT when no record exists for the key, v1 has no writer" {
  local clone; clone="$(init_ledger_repo)"
  cd "$clone"
  run ci_ledger_read origin dns linux/amd64 "sha256:$a64"
  [ "$status" -eq "$CI_LEDGER_ABSENT" ]
  [ -z "$output" ]
}

@test "ci_ledger_read: PRESENT returns the exact validated record for a real fixture" {
  local clone; clone="$(init_ledger_repo)"
  local ref; ref="$(ci_ledger_ref dns linux/amd64 "sha256:$a64")"
  local json
  json="$(ledger_record_json dns linux/amd64 "sha256:$a64" "sha256:$b64" \
    ACCEPTED unverifiable)"
  push_ledger_fixture "$clone" "$ref" "$json"

  cd "$clone"
  run ci_ledger_read origin dns linux/amd64 "sha256:$a64"
  [ "$status" -eq "$CI_LEDGER_PRESENT" ]
  [ "$output" = "$json" ]
}

# What: A corrupted/foreign ref never reads as accepted.
# Why: doc 26; unreadable state never becomes BUILD=ACK.
# From: Issue #1095
@test "ci_ledger_read: UNKNOWN on a malformed record, never PRESENT nor ABSENT" {
  local clone; clone="$(init_ledger_repo)"
  local ref; ref="$(ci_ledger_ref dns linux/amd64 "sha256:$a64")"
  push_ledger_fixture "$clone" "$ref" "not valid json at all"

  cd "$clone"
  run --separate-stderr ci_ledger_read origin dns linux/amd64 "sha256:$a64"
  [ "$status" -eq "$CI_LEDGER_UNKNOWN" ]
  [ -z "$output" ]
}

@test "ci_ledger_read fails closed to UNKNOWN on bad input, never claims ABSENT" {
  local clone; clone="$(init_ledger_repo)"
  cd "$clone"
  run --separate-stderr ci_ledger_read origin bogus-service linux/amd64 "sha256:$a64"
  [ "$status" -eq "$CI_LEDGER_UNKNOWN" ]
  run --separate-stderr ci_ledger_read origin dns linux/amd64 "not-a-digest"
  [ "$status" -eq "$CI_LEDGER_UNKNOWN" ]
}

# What: A record at the right ref path, wrong payload key.
# Why: A misplaced record must never leak a wrong digest.
# From: Issue #1095
@test "ci_ledger_read: UNKNOWN when the record's own key differs from the one queried" {
  local clone; clone="$(init_ledger_repo)"
  local ref; ref="$(ci_ledger_ref dns linux/amd64 "sha256:$a64")"
  # What: a valid ui/arm64 record at dns/amd64's ref.
  # Why: proves the key cross-check, not only schema shape.
  # From: Issue #1095
  local json
  json="$(ledger_record_json ui linux/arm64 "sha256:$b64" "sha256:$c64" \
    ACCEPTED unverifiable)"
  push_ledger_fixture "$clone" "$ref" "$json"

  cd "$clone"
  run --separate-stderr ci_ledger_read origin dns linux/amd64 "sha256:$a64"
  [ "$status" -eq "$CI_LEDGER_UNKNOWN" ]
  [ -z "$output" ]
}

# What: A REJECTED record must never read back as reusable.
# Why: doc 25; a permanent finding is not "no record found".
# From: Issue #1095
@test "ci_ledger_read: a matching-key REJECTED record is CI_LEDGER_REJECTED, never PRESENT" {
  local clone; clone="$(init_ledger_repo)"
  local ref; ref="$(ci_ledger_ref dns linux/amd64 "sha256:$a64")"
  local json
  json="$(ledger_record_json dns linux/amd64 "sha256:$a64" "sha256:$b64" \
    REJECTED unverifiable)"
  push_ledger_fixture "$clone" "$ref" "$json"

  cd "$clone"
  run ci_ledger_read origin dns linux/amd64 "sha256:$a64"
  [ "$status" -eq "$CI_LEDGER_REJECTED" ]
  [ "$status" -ne "$CI_LEDGER_PRESENT" ]
  [ "$output" = "$json" ]
}

# What: A missing CAS library must never read as ABSENT.
# Why: an infra gap is not proof no record exists (doc 26).
# From: Issue #1095
@test "ci_ledger_read fails closed to UNKNOWN when promote-lock.sh cannot be sourced" {
  local isolated="$BATS_TEST_TMPDIR/isolated-ci/scripts/ci"
  mkdir -p "$isolated"
  cp "$repo_root/scripts/ci/ci.sh" "$isolated/ci.sh"
  local clone; clone="$(init_ledger_repo)"
  cd "$clone"
  run --separate-stderr bash "$isolated/ci.sh" \
    ledger-read origin dns linux/amd64 "sha256:$a64"
  [ "$status" -eq "$CI_LEDGER_UNKNOWN" ]
}

# What: Real executed proof under strict mode, both states.
# Why: Coordinator-required evidence, not only a unit call.
# From: Issue #1095
@test "dispatch ledger-read via executed ci.sh proves ABSENT and PRESENT under real strict mode" {
  local clone; clone="$(init_ledger_repo)"
  cd "$clone"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
  run --separate-stderr bash "$repo_root/scripts/ci/ci.sh" \
    ledger-read origin dns linux/amd64 "sha256:$a64"
  [ "$status" -eq 1 ]
  [ -z "$output" ]

  local ref; ref="$(ci_ledger_ref dns linux/amd64 "sha256:$a64")"
  local json
  json="$(ledger_record_json dns linux/amd64 "sha256:$a64" "sha256:$b64" \
    ACCEPTED unverifiable)"
  push_ledger_fixture "$clone" "$ref" "$json"

  PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
  run --separate-stderr bash "$repo_root/scripts/ci/ci.sh" \
    ledger-read origin dns linux/amd64 "sha256:$a64"
  [ "$status" -eq 0 ]
  [ "$output" = "$json" ]
}

# === ci_push_reuse_decide (NOOP-first reuse) ===

# What: Stubs the sif_* + classify inject seams only.
# Why: unit-tests the verdict logic, not the real registry.
# From: Issue #1095 | Issue #1835
reuse_stubs() {
  # What: a present _sif_inspect skips the lib source.
  # Why: keeps our sif_* stubs; no real lib override.
  # From: Issue #1095
  _sif_inspect() { return 0; }
  sif_image_revision() {
    if [ -n "${STUB_REVISION:-}" ]; then
      printf '%s\n' "$STUB_REVISION"
      return 0
    fi
    return 1
  }
  sif_is_ancestor_or_equal() { return "${STUB_ANCESTOR_STATUS:-0}"; }
  fake_classify() { printf '%s\n' "${STUB_CLASSIFY:-}"; }
  fail_classify() { return 7; }
  PUSH_REUSE_CLASSIFY_CMD=fake_classify
}

@test "push-reuse-decide reuses build-tools when tools/build-tools is unchanged (#1835 core property)" {
  reuse_stubs
  STUB_REVISION="$sha40"
  STUB_ANCESTOR_STATUS=0
  STUB_CLASSIFY=$'build_tools=false\nworkflow_reuse_scope=true'
  # build-tools' real call: dep_keys empty, ignore_workflow_gate=true.
  run --separate-stderr ci_push_reuse_decide build_tools \
    "$image:trixie" "$sha40" "" true
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "push-reuse-decide reports UNKNOWN (2) when the revision label is unreadable" {
  reuse_stubs
  STUB_REVISION=""
  run --separate-stderr ci_push_reuse_decide build_tools "$image:trixie" "$sha40" "" true
  [ "$status" -eq 2 ]
  [ "$output" = "false" ]
}

@test "push-reuse-decide reports a real rebuild (1) when the revision is not an ancestor" {
  reuse_stubs
  STUB_REVISION="$sha40"
  STUB_ANCESTOR_STATUS=1
  run --separate-stderr ci_push_reuse_decide build_tools "$image:trixie" "$sha40" "" true
  [ "$status" -eq 1 ]
  [ "$output" = "false" ]
}

@test "push-reuse-decide reports UNKNOWN (2) when ancestry is unprovable (shallow history)" {
  reuse_stubs
  STUB_REVISION="$sha40"
  STUB_ANCESTOR_STATUS=2
  run --separate-stderr ci_push_reuse_decide build_tools "$image:trixie" "$sha40" "" true
  [ "$status" -eq 2 ]
  [ "$output" = "false" ]
}

@test "push-reuse-decide reports a real rebuild (1) when the service's own key changed" {
  reuse_stubs
  STUB_REVISION="$sha40"
  STUB_ANCESTOR_STATUS=0
  STUB_CLASSIFY=$'build_tools=true\nworkflow_reuse_scope=false'
  run --separate-stderr ci_push_reuse_decide build_tools "$image:trixie" "$sha40" "" true
  [ "$status" -eq 1 ]
  [ "$output" = "false" ]
}

@test "push-reuse-decide reports UNKNOWN (2) when the classifier fails to run" {
  reuse_stubs
  STUB_REVISION="$sha40"
  STUB_ANCESTOR_STATUS=0
  PUSH_REUSE_CLASSIFY_CMD=fail_classify
  run --separate-stderr ci_push_reuse_decide build_tools "$image:trixie" "$sha40" "" true
  [ "$status" -eq 2 ]
  [ "$output" = "false" ]
}

@test "push-reuse-decide honors the workflow gate when it is not ignored" {
  reuse_stubs
  STUB_REVISION="$sha40"
  STUB_ANCESTOR_STATUS=0
  STUB_CLASSIFY=$'dns_image=false\nworkflow_reuse_scope=true'
  run --separate-stderr ci_push_reuse_decide dns_image "$image:trixie" "$sha40" "" ""
  [ "$status" -eq 1 ]
  [ "$output" = "false" ]
}

@test "push-reuse-decide skips the workflow gate when ignore_workflow_gate=true" {
  reuse_stubs
  STUB_REVISION="$sha40"
  STUB_ANCESTOR_STATUS=0
  STUB_CLASSIFY=$'build_tools=false\nworkflow_reuse_scope=true'
  run --separate-stderr ci_push_reuse_decide build_tools "$image:trixie" "$sha40" "" true
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "push-reuse-decide fails closed to rebuild (1) when a declared dependency changed" {
  reuse_stubs
  STUB_REVISION="$sha40"
  STUB_ANCESTOR_STATUS=0
  STUB_CLASSIFY=$'dns_image=false\nworkflow_reuse_scope=false\nbuild_tools=true'
  run --separate-stderr ci_push_reuse_decide dns_image "$image:trixie" "$sha40" build_tools true
  [ "$status" -eq 1 ]
  [ "$output" = "false" ]
}

@test "push-reuse-decide reuses (0) when the service and its dependency are both unchanged" {
  reuse_stubs
  STUB_REVISION="$sha40"
  STUB_ANCESTOR_STATUS=0
  STUB_CLASSIFY=$'dns_image=false\nworkflow_reuse_scope=false\nbuild_tools=false'
  run --separate-stderr ci_push_reuse_decide dns_image "$image:trixie" "$sha40" build_tools true
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "dispatch push-reuse-decide via executed ci.sh requires a service_key" {
  run_ci push-reuse-decide
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"service_key is required"* ]]
}

# === build-tools image selection (channel + trust) ===

@test "build-tools-channel maps master to latest, every other ref to nightly" {
  [ "$(ci_build_tools_channel master)" = "latest" ]
  local ref
  for ref in v0.2.0 current_dev claude/issue1035-x ""; do
    [ "$(ci_build_tools_channel "$ref")" = "nightly" ]
  done
}

@test "build-tools-channel equals resolve_build_tools_channel across refs (no drift)" {
  # What: pins the ci.sh port to the live lib it replaces.
  # Why: a transitional copy must not drift until dedup.
  # From: Issue #1095 | Issue #1153
  source "$repo_root/scripts/lib/build-tools-channel.sh"
  local ref
  for ref in master v0.2.0 current_dev claude/issue1035-x ""; do
    [ "$(ci_build_tools_channel "$ref")" = "$(resolve_build_tools_channel "$ref")" ]
  done
}

@test "dispatch build-tools-channel via executed ci.sh prints latest and nightly" {
  run_ci build-tools-channel master
  [ "$status" -eq 0 ]
  [ "$output" = "latest" ]
  run_ci build-tools-channel current_dev
  [ "$status" -eq 0 ]
  [ "$output" = "nightly" ]
}

@test "build-tools-fallback-allowed: same-repo PR trusted, fork/empty denied, push trusted" {
  run ci_build_tools_fallback_allowed pull_request wiki-mod/lancache-ng wiki-mod/lancache-ng
  [ "$status" -eq 0 ]
  run ci_build_tools_fallback_allowed pull_request fork/lancache-ng wiki-mod/lancache-ng
  [ "$status" -ne 0 ]
  run ci_build_tools_fallback_allowed pull_request "" wiki-mod/lancache-ng
  [ "$status" -ne 0 ]
  run ci_build_tools_fallback_allowed push "" wiki-mod/lancache-ng
  [ "$status" -eq 0 ]
}

@test "build-tools-fallback-allowed: case-insensitive same-repo trusted, fork not laundered" {
  run ci_build_tools_fallback_allowed pull_request wiki-mod/LanCache-NG wiki-mod/lancache-ng
  [ "$status" -eq 0 ]
  run ci_build_tools_fallback_allowed pull_request fork/LanCache-NG wiki-mod/lancache-ng
  [ "$status" -ne 0 ]
}

@test "build-tools-fallback-allowed equals select_build_tools_trusted_fallback_allowed (no drift)" {
  source "$repo_root/tests/bats/helpers/select-build-tools-image-helpers.sh"
  load_select_build_tools_image_functions "$repo_root" \
    "$BATS_TEST_TMPDIR/sbti-fns.sh"
  local c ev hd bs a b
  local cases=(
    "pull_request|wiki-mod/lancache-ng|wiki-mod/lancache-ng"
    "pull_request|fork/lancache-ng|wiki-mod/lancache-ng"
    "pull_request||wiki-mod/lancache-ng"
    "push||wiki-mod/lancache-ng"
    "pull_request|wiki-mod/LanCache-NG|wiki-mod/lancache-ng"
    "pull_request|fork/LanCache-NG|wiki-mod/lancache-ng"
  )
  for c in "${cases[@]}"; do
    IFS='|' read -r ev hd bs <<<"$c"
    a=0; ci_build_tools_fallback_allowed "$ev" "$hd" "$bs" || a=$?
    b=0; select_build_tools_trusted_fallback_allowed "$ev" "$hd" "$bs" || b=$?
    [ "$a" -eq "$b" ]
  done
}

@test "dispatch build-tools-fallback-allowed via executed ci.sh: trusted 0, fork non-zero" {
  run_ci build-tools-fallback-allowed pull_request wiki-mod/lancache-ng wiki-mod/lancache-ng
  [ "$status" -eq 0 ]
  run_ci build-tools-fallback-allowed pull_request fork/lancache-ng wiki-mod/lancache-ng
  [ "$status" -ne 0 ]
}

# === full-setup suite gate (should_run) ===

@test "full-setup-should-run: services change runs, docs-only and ci.sh-only do not" {
  local f="$BATS_TEST_TMPDIR/fs-dir.txt"
  printf 'services/proxy/nginx.conf\n' > "$f"
  run ci_full_setup_should_run "$f"
  [ "$status" -eq 0 ]
  printf '%s\n' "docs/x.md" "README.md" > "$f"
  run ci_full_setup_should_run "$f"
  [ "$status" -eq 1 ]
  printf 'scripts/ci/ci.sh\n' > "$f"
  run ci_full_setup_should_run "$f"
  [ "$status" -eq 1 ]
}

@test "full-setup-should-run: an unclassified scripts/ path fails safe to run" {
  local f="$BATS_TEST_TMPDIR/fs-unc.txt"
  printf 'scripts/lib/ghcr-retry.sh\n' > "$f"
  run ci_full_setup_should_run "$f"
  [ "$status" -eq 0 ]
}

@test "full-setup-should-run: missing changed-files input is an error (2)" {
  run ci_full_setup_should_run "$BATS_TEST_TMPDIR/does-not-exist.txt"
  [ "$status" -eq 2 ]
}

@test "full-setup-should-run matches detect-full-setup-changes.sh should_run (no drift)" {
  # What: pins the ci.sh gate to the live script.
  # Why: GITHUB_OUTPUT='' or the original emits nothing.
  # From: Issue #1095 | Issue #1153
  local f="$BATS_TEST_TMPDIR/fs-eq.txt"
  local detector="$repo_root/scripts/untracked/detect-full-setup-changes.sh"
  local cases=(
    "scripts/ci/ci.sh"
    "scripts/tracked/some-guard.sh"
    "scripts/lib/ghcr-retry.sh"
    "scripts/ci/ci.sh|scripts/brand-new-unclassified.sh"
    "docs/x.md|README.md"
    "services/proxy/nginx.conf"
    "setup.sh"
    ".github/actions/derive-validation-network/action.yml"
    "EMPTY"
  )
  local c orig a
  for c in "${cases[@]}"; do
    if [ "$c" = "EMPTY" ]; then
      : > "$f"
    else
      # shellcheck disable=SC2086
      printf '%s\n' ${c//|/ } > "$f"
    fi
    orig="$(CHANGED_FILES="$f" GITHUB_OUTPUT="" bash "$detector" 2>/dev/null \
      | grep -m1 '^should_run=' | cut -d= -f2)"
    a=0
    ci_full_setup_should_run "$f" || a=$?
    if [ "$orig" = "true" ]; then
      [ "$a" -eq 0 ]
    else
      [ "$a" -eq 1 ]
    fi
  done
}

@test "full-setup tooling-script allowlist equals the detector's array (no drift)" {
  [ "${#CI_FULL_SETUP_TOOLING_SCRIPTS[@]}" -eq 1 ]
  [ "${CI_FULL_SETUP_TOOLING_SCRIPTS[0]}" = "scripts/ci/ci.sh" ]
  local empty="$BATS_TEST_TMPDIR/empty-allow.txt"
  local orig
  orig="$(bash -c '
    : > "$1"
    # shellcheck disable=SC1090
    CHANGED_FILES="$1" source "'"$repo_root"'/scripts/untracked/detect-full-setup-changes.sh" >/dev/null
    printf "%d\n" "${#ci_tooling_only_scripts[@]}"
    printf "%s\n" "${ci_tooling_only_scripts[@]}"
  ' _ "$empty")"
  [ "$(sed -n 1p <<<"$orig")" = "${#CI_FULL_SETUP_TOOLING_SCRIPTS[@]}" ]
  [ "$(sed -n 2p <<<"$orig")" = "${CI_FULL_SETUP_TOOLING_SCRIPTS[0]}" ]
}

@test "dispatch full-setup-should-run via executed ci.sh: run 0, no-run 1, missing input 2" {
  local f="$BATS_TEST_TMPDIR/fs-disp.txt"
  printf 'services/proxy/nginx.conf\n' > "$f"
  run_ci full-setup-should-run "$f"
  [ "$status" -eq 0 ]
  printf 'scripts/ci/ci.sh\n' > "$f"
  run_ci full-setup-should-run "$f"
  [ "$status" -eq 1 ]
  run_ci full-setup-should-run "$BATS_TEST_TMPDIR/does-not-exist.txt"
  [ "$status" -eq 2 ]
}

# === validation image tag (channel + pr-staging + resolve) ===

@test "validation-* equal their validation-image-tag.sh originals (no drift)" {
  source "$repo_root/scripts/lib/validation-image-tag.sh"
  local r
  for r in current_dev master v0.2.0 some-feature-branch ""; do
    [ "$(ci_validation_channel "$r")" = "$(vit_base_channel_tag "$r")" ]
  done
  local c ev ac hd rp
  local pcases=(
    "pull_request|someuser|wiki-mod/lancache-ng|wiki-mod/lancache-ng"
    "pull_request|dependabot[bot]|wiki-mod/lancache-ng|wiki-mod/lancache-ng"
    "pull_request|someuser|fork/lancache-ng|wiki-mod/lancache-ng"
    "pull_request|someuser|wiki-mod/LanCache-NG|wiki-mod/lancache-ng"
    "pull_request|someuser|fork/LanCache-NG|wiki-mod/lancache-ng"
    "workflow_dispatch|someuser||wiki-mod/lancache-ng"
    "push|someuser||wiki-mod/lancache-ng"
  )
  for c in "${pcases[@]}"; do
    IFS='|' read -r ev ac hd rp <<<"$c"
    [ "$(ci_validation_pr_staging_available "$ev" "$ac" "$hd" "$rp")" \
      = "$(vit_pr_staging_available "$ev" "$ac" "$hd" "$rp")" ]
  done
  local a1 a2 a3 a4 a5 a6 a7 a8
  local rcases=(
    "pull_request|master|715|abcdef0123456789abcdef0123456789abcdef01|someuser|wiki-mod/lancache-ng|wiki-mod/lancache-ng|"
    "pull_request|master|715|abcdef0123456789|dependabot[bot]|wiki-mod/lancache-ng|wiki-mod/lancache-ng|"
    "pull_request|v0.2.0|715|abcdef0123456789|someuser|fork/lancache-ng|wiki-mod/lancache-ng|"
    "workflow_dispatch|||||||nightly"
    "workflow_dispatch||||someuser||wiki-mod/lancache-ng|"
  )
  for c in "${rcases[@]}"; do
    IFS='|' read -r a1 a2 a3 a4 a5 a6 a7 a8 <<<"$c"
    [ "$(ci_validation_resolve_tag "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8")" \
      = "$(vit_resolve_tag "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8")" ]
  done
  [ "$(ci_validation_service_staging_expected proxy true)" \
    = "$(vit_service_should_have_staging_tag proxy true)" ]
  [ "$(ci_validation_service_staging_expected dns false)" \
    = "$(vit_service_should_have_staging_tag dns false)" ]
}

@test "validation-resolve-tag: eligible PR resolves to pr-<N>-sha-<full>" {
  run ci_validation_resolve_tag pull_request master 715 \
    abcdef0123456789abcdef0123456789abcdef01 someuser \
    wiki-mod/lancache-ng wiki-mod/lancache-ng ""
  [ "$status" -eq 0 ]
  [ "$output" = "pr-715-sha-abcdef0123456789abcdef0123456789abcdef01" ]
}

@test "dispatch validation-channel and validation-resolve-tag via executed ci.sh" {
  run_ci validation-channel current_dev
  [ "$status" -eq 0 ]
  [ "$output" = "nightly" ]
  run_ci validation-resolve-tag workflow_dispatch "" "" "" someuser "" \
    wiki-mod/lancache-ng nightly
  [ "$status" -eq 0 ]
  [ "$output" = "nightly" ]
}

# === release tag (next patch bump) ===

@test "next-release-tag bumps the patch and preserves major/minor" {
  run ci_next_release_tag v10.20.3
  [ "$status" -eq 0 ]
  [ "$output" = "v10.20.4" ]
  # leading-zero patch is base-10, not octal
  run ci_next_release_tag v0.2.09
  [ "$status" -eq 0 ]
  [ "$output" = "v0.2.10" ]
}

@test "next-release-tag equals compute-next-release-tag.sh (no drift)" {
  local script="$repo_root/scripts/untracked/compute-next-release-tag.sh"
  local x a b
  for x in v0.2.3 v0.1.0 v1.4.99 v0.2.08 v0.2.09 v10.20.3; do
    run ci_next_release_tag "$x"
    [ "$status" -eq 0 ]
    a="$output"
    run bash "$script" "$x"
    [ "$status" -eq 0 ]
    b="$output"
    [ "$a" = "$b" ]
  done
  for x in v0.2.3-rc.1 0.2.3 v0.2 v0.x.3; do
    run ci_next_release_tag "$x"
    [ "$status" -ne 0 ]
    run bash "$script" "$x"
    [ "$status" -ne 0 ]
  done
}

@test "dispatch next-release-tag via executed ci.sh: bump, reject malformed, require arg" {
  run_ci next-release-tag v0.2.3
  [ "$status" -eq 0 ]
  [ "$output" = "v0.2.4" ]
  run_ci next-release-tag v0.2.3-rc.1
  [ "$status" -ne 0 ]
  run_ci next-release-tag
  [ "$status" -ne 0 ]
}
