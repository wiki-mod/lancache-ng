#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: regression coverage for the read-only SHA retention planner and API helper.
# Why: destructive GC consumes planner output, so its protection decisions
# must remain independently testable without any DELETE capability here.
# From: Issue #1095.

# What: sources both libraries and creates a per-test scratch directory.
# Why: sourcing (not executing) pulls in every sra_* function without
# running any live audit.
# From: Issue #1585 | PR #1586
setup() {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=scripts/lib/github-api-retry.sh
  source "$repo_root/scripts/lib/github-api-retry.sh"
  # shellcheck source=scripts/lib/sha-retention-audit.sh
  source "$repo_root/scripts/lib/sha-retention-audit.sh"
  tmp_dir="$(mktemp -d "${BATS_TEST_TMPDIR}/sha-retention-audit.XXXXXX")"
}

# What: removes the per-test scratch directory created by setup().
# Why: runs after every test regardless of outcome, keeping BATS_TEST_TMPDIR clean.
# From: Issue #1585 | PR #1586
teardown() {
  rm -rf -- "$tmp_dir"
}

# What: reads the manifest's single accepted_ordinary_roots_per_package value.
# Why: the machine-readable ordinary-root storage-retention budget.
# From: Issue #1585 | PR #1586
@test "retention manifest defines exactly thirty accepted ordinary roots" {
  run sra_read_retention_keep "$repo_root/release/stack-images.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "30" ]
}

# What: rejects a manifest with a duplicated retention budget key.
# Why: a duplicate key creates two competing retention values, so parsing
# must fail rather than silently pick one.
# From: Issue #1585 | PR #1586
@test "retention parser rejects duplicate budget declarations" {
  cat >"$tmp_dir/manifest.yml" <<'EOF'
retention:
  accepted_ordinary_roots_per_package: 10
  accepted_ordinary_roots_per_package: 11
EOF
  run sra_read_retention_keep "$tmp_dir/manifest.yml"
  [ "$status" -ne 0 ]
}

# What: reads the manifest's single minimum_stable_releases value.
# Why: feeds sra_select_supported_release_tags's "how many recent stable
# releases stay protected" question.
# From: Issue #1585 | PR #1586
@test "retention manifest defines exactly three minimum stable releases" {
  run sra_read_minimum_stable_releases "$repo_root/release/stack-images.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

# What: reads the manifest's single channel_buffer_versions value.
# Why: the v1.2 per-package buffer for a non-ordinary-version
# candidate that matches no protected channel.
# From: Issue #1585.
@test "retention manifest defines exactly five channel buffer versions" {
  run sra_read_channel_buffer_versions "$repo_root/release/stack-images.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

# What: retention keep and minimum stable releases parse independently.
# Why: both share _sra_read_manifest_positive_integer -- the two keys'
# values must never bleed into each other.
# From: Issue #1585 | PR #1586
@test "retention keep and minimum stable releases parse independently" {
  cat >"$tmp_dir/manifest.yml" <<'EOF'
retention:
  accepted_ordinary_roots_per_package: 30
  minimum_stable_releases: 3
EOF
  run sra_read_retention_keep "$tmp_dir/manifest.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "30" ]

  run sra_read_minimum_stable_releases "$tmp_dir/manifest.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

# What: rollback_anchors reader succeeds with empty output on the real manifest.
# Why: the real manifest's steady state is an empty rollback_anchors list.
# From: Issue #1585 | PR #1586
@test "rollback_anchors reader succeeds with empty output on the real manifest" {
  run sra_read_rollback_anchors "$repo_root/release/stack-images.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# What: rollback_anchors reader succeeds with empty output when the header is absent.
# Why: an entirely absent header must read the same as an empty list -- the
# manifest's steady state before the key ever existed at all.
# From: Issue #1585 | PR #1586
@test "rollback_anchors reader succeeds with empty output when the header is entirely absent" {
  cat >"$tmp_dir/manifest.yml" <<'EOF'
retention:
  minimum_stable_releases: 3
EOF
  run sra_read_rollback_anchors "$tmp_dir/manifest.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# What: rollback_anchors reader rejects a duplicate list header.
# Why: two competing list declarations are a malformed manifest in every case.
# From: Issue #1585 | PR #1586
@test "rollback_anchors reader rejects a duplicate list header" {
  cat >"$tmp_dir/manifest.yml" <<'EOF'
retention:
  rollback_anchors:
    - sha256:1111111111111111111111111111111111111111111111111111111111111111
  rollback_anchors:
EOF
  run sra_read_rollback_anchors "$tmp_dir/manifest.yml"
  [ "$status" -ne 0 ]
}

# What: rollback_anchors reader returns declared digest entries, one per line.
# Why: entries must come back in manifest order for reproducible reporting.
# From: Issue #1585 | PR #1586
@test "rollback_anchors reader returns declared digest entries" {
  cat >"$tmp_dir/manifest.yml" <<'EOF'
retention:
  rollback_anchors:
    - sha256:1111111111111111111111111111111111111111111111111111111111111111
    - sha256:2222222222222222222222222222222222222222222222222222222222222222
EOF
  run sra_read_rollback_anchors "$tmp_dir/manifest.yml"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "sha256:1111111111111111111111111111111111111111111111111111111111111111" ]
  [ "${lines[1]}" = "sha256:2222222222222222222222222222222222222222222222222222222222222222" ]
}

# What: rollback anchor digest format accepts only an exact sha256:<64-hex> value.
# Why: a rollback anchor is deliberately digest-only -- a tag/ref must never pass.
# From: Issue #1585 | PR #1586
@test "rollback anchor digest format accepts only an exact sha256:<64-hex> value" {
  run sra_is_rollback_anchor_digest "sha256:$(printf 'a%.0s' {1..64})"
  [ "$status" -eq 0 ]

  run sra_is_rollback_anchor_digest "nightly"
  [ "$status" -ne 0 ]

  run sra_is_rollback_anchor_digest "sha256:tooshort"
  [ "$status" -ne 0 ]
}

# What: rollback anchor membership check is exact, not a prefix match.
# Why: a substring/prefix match would let an unrelated digest sharing a
# prefix falsely match a declared anchor.
# From: Issue #1585 | PR #1586
@test "rollback anchor membership check is exact, not a prefix match" {
  anchor="sha256:$(printf 'a%.0s' {1..64})"
  prefixed="sha256:$(printf 'a%.0s' {1..63})b"

  run sra_digest_is_rollback_anchor "$anchor" "$anchor"
  [ "$status" -eq 0 ]

  run sra_digest_is_rollback_anchor "$prefixed" "$anchor"
  [ "$status" -ne 0 ]
}

# What: rollback anchor list validator accepts a well-formed digest list.
# Why: this validator is what both the CI static check and the live audit share.
# From: Issue #1585 | PR #1586
@test "rollback anchor list validator accepts a well-formed digest list" {
  list="$(printf 'sha256:%s\nsha256:%s\n' "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..64})")"
  run sra_validate_rollback_anchors_list "$list"
  [ "$status" -eq 0 ]
}

# What: rollback anchor list validator accepts an empty list.
# Why: the empty steady state must validate cleanly too, never as an error.
# From: Issue #1585 | PR #1586
@test "rollback anchor list validator accepts an empty list" {
  run sra_validate_rollback_anchors_list ""
  [ "$status" -eq 0 ]
}

# What: rollback anchor list validator rejects a git tag/ref in place of a digest.
# Why: a tag/ref in place of a digest defeats the whole point of an immutable anchor.
# From: Issue #1585 | PR #1586
@test "rollback anchor list validator rejects a git tag/ref in place of a digest" {
  run sra_validate_rollback_anchors_list "nightly"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not an exact sha256"* ]]
}

# What: rollback anchor list validator rejects a blank entry.
# Why: a blank line in the list must be caught explicitly, not silently accepted.
# From: Issue #1585 | PR #1586
@test "rollback anchor list validator rejects a blank entry" {
  list="$(printf 'sha256:%s\n\nsha256:%s\n' "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..64})")"
  run sra_validate_rollback_anchors_list "$list"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blank entry"* ]]
}

# What: manifest runtime and tooling packages match the real build matrix.
# Why: retention must follow the same publisher inventory build-push.yml uses.
# From: Issue #1585 | PR #1586
@test "manifest runtime and tooling packages match the build matrix" {
  package_inventory="$(sra_manifest_packages "$repo_root/release/stack-images.yml")"
  manifest_services="$(awk -F '\t' '$1 == "runtime" || $1 == "tooling" { print $2 }' <<<"$package_inventory" | sort -u)"
  matrix_services="$(awk '/^[[:space:]]+- service: / { line=$0; sub(/^.*- service: /, "", line); print line }' "$repo_root/.github/workflows/build-push.yml" | sort -u)"
  [ -n "$manifest_services" ]
  [ "$manifest_services" = "$matrix_services" ]
  [[ "$manifest_services" == *"ntp"* ]]
  [[ "$manifest_services" == *"syslog"* ]]
  [[ "$manifest_services" == *"build-tools"* ]]
}

# What: manifest package parser exposes legacy packages only when explicitly requested.
# Why: the destructive GC may retire manifest-declared historical packages,
# while the standalone audit must retain its original first-party scope.
# From: Issue #1095 | PR #1586
@test "manifest package parser exposes legacy only when explicitly requested" {
  default_inventory="$(sra_manifest_packages "$repo_root/release/stack-images.yml")"
  legacy_inventory="$(sra_manifest_packages "$repo_root/release/stack-images.yml" "legacy")"
  [[ "$default_inventory" != *$'legacy\tproxy-standard'* ]]
  [[ "$legacy_inventory" == *$'legacy\tproxy-standard'* ]]
  [[ "$legacy_inventory" == *$'legacy\tfluent-bit'* ]]
}

# What: package-version page schema accepts a complete, well-formed object.
# Why: GHCR version objects are deletion units -- every required field must
# be valid before classification runs at all.
# From: Issue #1585 | PR #1586
@test "package-version page schema accepts complete objects" {
  cat >"$tmp_dir/page.json" <<'EOF'
[
  {
    "id": 42,
    "name": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "metadata": {"container": {"tags": ["sha-abcdef1", "nightly"]}}
  }
]
EOF
  run sra_validate_version_page "$tmp_dir/page.json"
  [ "$status" -eq 0 ]
}

# What: package-version page schema rejects control characters in tags.
# Why: tag text is emitted into line-oriented audit output; a control
# character (e.g. an embedded tab) would corrupt that format.
# From: Issue #1585 | PR #1586
@test "package-version page schema rejects control characters in tags" {
  cat >"$tmp_dir/page.json" <<'EOF'
[
  {
    "id": 42,
    "name": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "metadata": {"container": {"tags": ["bad\tseparator"]}}
  }
]
EOF
  run sra_validate_version_page "$tmp_dir/page.json"
  [ "$status" -ne 0 ]
}

# What: package-version page schema rejects missing tag metadata.
# Why: missing tag metadata must never collapse into an apparently untagged version.
# From: Issue #1585 | PR #1586
@test "package-version page schema rejects missing tag metadata" {
  cat >"$tmp_dir/page.json" <<'EOF'
[
  {
    "id": 42,
    "name": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "metadata": {"container": {}}
  }
]
EOF
  run sra_validate_version_page "$tmp_dir/page.json"
  [ "$status" -ne 0 ]
}

# What: package-version page schema rejects a null version id.
# Why: a missing/null id cannot be used as a stable package-version identity.
# From: Issue #1585 | PR #1586
@test "package-version page schema rejects null version ids" {
  cat >"$tmp_dir/page.json" <<'EOF'
[
  {
    "id": null,
    "name": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "metadata": {"container": {"tags": ["sha-abcdef1"]}}
  }
]
EOF
  run sra_validate_version_page "$tmp_dir/page.json"
  [ "$status" -ne 0 ]
}

# What: package-version page schema rejects a malformed digest.
# Why: a malformed digest must not enter the identity graph as if it were a real OCI digest.
# From: Issue #1585 | PR #1586
@test "package-version page schema rejects malformed digests" {
  cat >"$tmp_dir/page.json" <<'EOF'
[
  {
    "id": 42,
    "name": "not-a-digest",
    "metadata": {"container": {"tags": ["sha-abcdef1"]}}
  }
]
EOF
  run sra_validate_version_page "$tmp_dir/page.json"
  [ "$status" -ne 0 ]
}

# What: tag facts preserve multiple root aliases on one version.
# Why: multiple SHA aliases on one version are one stored root identity, not
# multiple counted slots.
# From: Issue #1585 | PR #1586
@test "tag facts preserve multiple root aliases on one version" {
  version='{"metadata":{"container":{"tags":["sha-abcdef1","sha-1234567"]}}}'
  run sra_version_tag_facts "$version"
  [ "$status" -eq 0 ]
  [ "$output" = $'2\t0\t0' ]
}

# What: tag facts classify protected non-SHA tags separately.
# Why: a protected non-SHA identity attached to the version must be visible
# to the orchestrator's classifier, not folded into the root/child counts.
# From: Issue #1585 | PR #1586
@test "tag facts classify protected non-SHA tags separately" {
  version='{"metadata":{"container":{"tags":["sha-abcdef1","nightly"]}}}'
  run sra_version_tag_facts "$version"
  [ "$status" -eq 0 ]
  [ "$output" = $'1\t0\t1' ]
}

# What: tag facts distinguish architecture child tags from root tags.
# Why: platform child tags are closure, not ordinary root-history slots.
# From: Issue #1585 | PR #1586
@test "tag facts distinguish architecture child tags" {
  version='{"metadata":{"container":{"tags":["sha-abcdef1-amd64","sha-abcdef1-arm64"]}}}'
  run sra_version_tag_facts "$version"
  [ "$status" -eq 0 ]
  [ "$output" = $'0\t2\t0' ]
}

# What: GitHub REST retry treats 404 as a hard unknown failure, not empty.
# Why: an ambiguous or absent REST resource is not positive proof of package
# absence, so it must not be silently treated as an empty result.
# From: Issue #1585 | PR #1586
@test "GitHub REST retry treats 404 as a hard unknown failure" {
  _github_api_get_once() {
    GITHUB_API_HTTP_STATUS="404"
    printf '{"message":"Not Found"}\n' >"$2"
    return 0
  }
  GITHUB_API_RETRY_ATTEMPTS=4
  GITHUB_API_RETRY_DELAY_SECONDS=0
  run github_api_get_with_retry "https://api.github.invalid/example" "$tmp_dir/body.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to interpret this response as an empty result"* ]]
}

# What: GitHub REST retry recovers a transient status without warning output.
# Why: a recovered transient failure is a notice, not a warning, under the
# repo's warnings-as-errors contract.
# From: Issue #1585 | PR #1586
@test "GitHub REST retry recovers transient status without warning output" {
  retry_state="$tmp_dir/retry-state"
  _github_api_get_once() {
    if [[ ! -e "$retry_state" ]]; then
      : >"$retry_state"
      GITHUB_API_HTTP_STATUS="500"
      printf '{"message":"transient"}\n' >"$2"
    else
      GITHUB_API_HTTP_STATUS="200"
      printf '[]\n' >"$2"
    fi
    return 0
  }
  export GITHUB_API_RETRY_ATTEMPTS=2
  export GITHUB_API_RETRY_DELAY_SECONDS=0
  run github_api_get_with_retry "https://api.github.invalid/example" "$tmp_dir/body.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"* ]]
  [[ "$output" != *"::warning::"* ]]
}

# What: commit-prefix resolution is exact and history-aware.
# Why: SHA abbreviation handling must resolve through Git itself and reject
# an unknown/unresolvable prefix, not guess.
# From: Issue #1585 | PR #1586
@test "commit-prefix resolution is exact and history-aware" {
  git_dir="$tmp_dir/repo"
  git init -q "$git_dir"
  git -C "$git_dir" config user.name Test
  git -C "$git_dir" config user.email test@example.invalid
  printf 'one\n' >"$git_dir/file"
  git -C "$git_dir" add file
  git -C "$git_dir" commit -q -m one
  first="$(git -C "$git_dir" rev-parse HEAD)"
  printf 'two\n' >>"$git_dir/file"
  git -C "$git_dir" commit -q -am two
  git -C "$git_dir" update-ref refs/remotes/origin/current_dev HEAD

  run sra_resolve_commit_prefix "$git_dir" "${first:0:7}"
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]

  run sra_commit_is_on_history_ref "$git_dir" "$first" origin/current_dev
  [ "$status" -eq 0 ]

  run sra_resolve_commit_prefix "$git_dir" deadbee
  [ "$status" -ne 0 ]
}

# What: created_at string validator accepts only the exact GHCR timestamp shape.
# Why: split out so the orchestrator's hot loop can validate an
# already-extracted value without a second jq subprocess per version.
# From: Issue #1585 | PR #1586
@test "created_at string validator accepts only the exact GHCR shape" {
  run sra_validate_created_at_string "2026-08-01T12:00:00Z"
  [ "$status" -eq 0 ]

  run sra_validate_created_at_string ""
  [ "$status" -ne 0 ]

  run sra_validate_created_at_string "2026-08-01 12:00:00"
  [ "$status" -ne 0 ]
}

# What: version created_at is extracted for display when well-formed.
# Why: the dry-run report shows a real build date per candidate; created_at
# must never feed ranking itself.
# From: Issue #1585 | PR #1586
@test "version created_at is extracted for display when well-formed" {
  version='{"created_at":"2026-08-01T12:00:00Z","metadata":{"container":{"tags":["sha-abcdef1"]}}}'
  run sra_version_created_at "$version"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-08-01T12:00:00Z" ]
}

# What: version created_at fails closed when missing or malformed.
# Why: a missing/malformed build date is a real build-pipeline defect, and
# the caller must be able to detect and report it separately.
# From: Issue #1585 | PR #1586
@test "version created_at fails closed when missing or malformed" {
  run sra_version_created_at '{"metadata":{"container":{"tags":["sha-abcdef1"]}}}'
  [ "$status" -ne 0 ]

  run sra_version_created_at '{"created_at":"not-a-timestamp","metadata":{"container":{"tags":["sha-abcdef1"]}}}'
  [ "$status" -ne 0 ]
}

# What: emit_record labels a within-budget candidate as protect.
# Why: a within-budget ordinary root stays a plain protect decision.
# From: Issue #1585 | PR #1586
@test "emit_record labels a within-budget candidate as protect" {
  run sra_emit_record runtime proxy 1 sha256:aa sha-abcdef1 2026-08-01T12:00:00Z 3 within-30 protect acceptance-evidence-unavailable
  [ "$status" -eq 0 ]
  [[ "$output" == *"budget=within-30"* ]]
  [[ "$output" == *"decision=protect"* ]]
  [[ "$output" == *"built=2026-08-01T12:00:00Z"* ]]
}

# What: emit_record labels a beyond-budget candidate as would-delete.
# Why: this is the dry-run "I would delete this" report line the destructive
# GC later consumes.
# From: Issue #1585 | PR #1586
@test "emit_record labels a beyond-budget candidate as would-delete" {
  run sra_emit_record runtime proxy 2 sha256:bb sha-1234567 2026-01-01T00:00:00Z 31 beyond-30 would-delete acceptance-evidence-unavailable
  [ "$status" -eq 0 ]
  [[ "$output" == *"budget=beyond-30"* ]]
  [[ "$output" == *"decision=would-delete"* ]]
}

# What: emit_record accepts a legitimately empty tags value.
# Why: an untagged version (e.g. an attestation manifest) has a legitimately
# empty tags string; a naive "${5:?}" guard would reject it as missing.
# From: Issue #1585 | PR #1586
@test "emit_record accepts a legitimately empty tags value" {
  run sra_emit_record runtime proxy 3 sha256:cc "" unknown n/a protected protect non-ordinary-version
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\ttags=\t'* ]]
}

# What: GitHub REST retry performs a real GET when no cache directory is set.
# Why: a cold cache (no directory configured) must fall through to a real
# GET, exactly matching this helper's pre-caching behavior.
# From: Issue #1585 | PR #1586
@test "GitHub REST retry performs a real GET when no cache directory is set" {
  calls=0
  _github_api_get_once() {
    calls=$(( calls + 1 ))
    # shellcheck disable=SC2034 # read by github_api_get_with_retry() after this stub returns
    GITHUB_API_HTTP_STATUS="200"
    printf '[]\n' >"$2"
    return 0
  }
  GITHUB_API_CACHE_DIR=""
  github_api_get_with_retry "https://api.github.invalid/example" "$tmp_dir/body.json" >/dev/null
  [ "$calls" -eq 1 ]
}

# What: GitHub REST retry serves a fresh cache hit without a real GET, and expires it.
# Why: a fresh cached response must be served without a second real GET, and
# a response older than the TTL must not be trusted as current; the cache
# entry's mtime is force-set into the past rather than sleeping for real.
# From: Issue #1585 | PR #1586
@test "GitHub REST retry serves a fresh cache hit without a real GET, and expires it" {
  calls=0
  _github_api_get_once() {
    calls=$(( calls + 1 ))
    # shellcheck disable=SC2034 # read by github_api_get_with_retry() after this stub returns
    GITHUB_API_HTTP_STATUS="200"
    printf '[]\n' >"$2"
    return 0
  }
  GITHUB_API_CACHE_DIR="$tmp_dir/api-cache"
  export GITHUB_API_CACHE_TTL_SECONDS=600
  mkdir -p "$GITHUB_API_CACHE_DIR"

  github_api_get_with_retry "https://api.github.invalid/example" "$tmp_dir/first.json" >/dev/null
  github_api_get_with_retry "https://api.github.invalid/example" "$tmp_dir/second.json" >/dev/null
  [ "$calls" -eq 1 ]

  touch -d "@$(( $(date +%s) - 700 ))" "$GITHUB_API_CACHE_DIR"/*.json
  github_api_get_with_retry "https://api.github.invalid/example" "$tmp_dir/third.json" >/dev/null
  [ "$calls" -eq 2 ]
}

# What: stable release tag shape accepts vX.Y.Z and rejects rc/other shapes.
# Why: only a genuine stable release counts toward minimum_stable_releases --
# a release-candidate tag must not be mistaken for one.
# From: Issue #1585 | PR #1586
@test "stable release tag shape accepts vX.Y.Z and rejects rc/other shapes" {
  run sra_is_stable_release_tag "v1.2.3"
  [ "$status" -eq 0 ]

  run sra_is_stable_release_tag "v1.2.3-rc.1"
  [ "$status" -ne 0 ]

  run sra_is_stable_release_tag "nightly"
  [ "$status" -ne 0 ]

  run sra_is_stable_release_tag "v1.2"
  [ "$status" -ne 0 ]
}

# What: release sort key orders newer releases ahead of older ones.
# Why: bash has no native semver comparator; the zero-padded key must order
# releases correctly even across differing digit widths (v2.0.0 > v1.20.0).
# From: Issue #1585 | PR #1586
@test "release sort key orders newer releases ahead of older ones" {
  key_low="$(sra_release_sort_key "v1.20.0")"
  key_high="$(sra_release_sort_key "v2.0.0")"
  [[ "$key_high" > "$key_low" ]]
}

# What: release sort key rejects a non-stable-release tag.
# Why: an rc/other-shaped tag has no defined sort position and must fail closed.
# From: Issue #1585 | PR #1586
@test "release sort key rejects a non-stable-release tag" {
  run sra_release_sort_key "v1.2.3-rc.1"
  [ "$status" -ne 0 ]
}

# What: select supported release tags picks the newest N by semver.
# Why: retention.minimum_stable_releases (3) must select by real semver
# order, not by input/file order.
# From: Issue #1585 | PR #1586
@test "select supported release tags picks the newest N by semver" {
  supported="$(printf 'v1.0.0\nv1.2.0\nv1.10.0\nv2.0.0\n' | sra_select_supported_release_tags 3)"
  [ "$supported" = $'v2.0.0\nv1.10.0\nv1.2.0' ]
}

# What: select supported release tags returns empty for a package with no releases yet.
# Why: an empty release-tag set (a brand-new package) is a legitimate empty
# result, not a failure.
# From: Issue #1585 | PR #1586
@test "select supported release tags returns empty for a package with no releases yet" {
  supported="$(printf '' | sra_select_supported_release_tags 3)"
  [ -z "$supported" ]
}

# What: channel tag classifier recognizes nightly, latest, and stable release shapes.
# Why: each protected channel must be individually distinguishable from an
# ordinary or unrecognized tag.
# From: Issue #1585 | PR #1586
@test "channel tag classifier recognizes nightly, latest, and stable release shapes" {
  run sra_classify_channel_tag "nightly"
  [ "$status" -eq 0 ]
  [ "$output" = "nightly" ]

  run sra_classify_channel_tag "latest"
  [ "$status" -eq 0 ]
  [ "$output" = "latest" ]

  run sra_classify_channel_tag "v0.4.1"
  [ "$status" -eq 0 ]
  [ "$output" = "stable-release" ]

  run sra_classify_channel_tag "v0.4.1-rc.2"
  [ "$status" -eq 0 ]
  [ "$output" = "other" ]

  run sra_classify_channel_tag "pr-1501-staging"
  [ "$status" -eq 0 ]
  [ "$output" = "other" ]
}

# What: other tags from csv excludes sha root and child aliases.
# Why: the orchestrator's root_count==0/other_count>0 branches need the
# actual "other"-kind tag text, not just sra_version_tag_facts's count.
# From: Issue #1585 | PR #1586
@test "other tags from csv excludes sha root and child aliases" {
  other_tags="$(sra_other_tags_from_csv "sha-abcdef1,sha-abcdef1-amd64,nightly,v0.4.1")"
  [[ "$other_tags" == *"nightly"* ]]
  [[ "$other_tags" == *"v0.4.1"* ]]
  [[ "$other_tags" != *"sha-abcdef1"* ]]
}

# What: protected reference reason combines every channel that applies.
# Why: a digest can legitimately be nightly AND latest AND a just-cut stable
# release at once -- all applicable reasons must be reported, not just one.
# From: Issue #1585 | PR #1586
@test "protected reference reason combines every channel that applies" {
  other_tags=$'nightly\nlatest\nv0.4.1'
  supported="v0.4.1"
  run sra_protected_reference_reason "$other_tags" "$supported"
  [ "$status" -eq 0 ]
  [ "$output" = "nightly-channel-protected+latest-channel-protected+stable-release-protected" ]
}

# What: protected reference reason reports only the channel that actually applies.
# Why: a single-channel digest must not be over-reported with unrelated reasons.
# From: Issue #1585 | PR #1586
@test "protected reference reason reports only the channel that actually applies" {
  run sra_protected_reference_reason "nightly" ""
  [ "$status" -eq 0 ]
  [ "$output" = "nightly-channel-protected" ]
}

# What: protected reference reason does not credit an unsupported old release tag.
# Why: a tag past minimum_stable_releases is real history, not one of the
# currently supported releases, and must not be mislabeled as protected.
# From: Issue #1585 | PR #1586
@test "protected reference reason does not credit an unsupported old release tag" {
  supported=$'v0.5.0\nv0.4.2\nv0.4.1'
  run sra_protected_reference_reason "v0.1.0" "$supported"
  [ "$status" -ne 0 ]
}

# What: an unrecognized extra tag must not be mislabeled as a protected channel.
# Why: the orchestrator's other_count>0 branch relies on this exact failure
# to fall through to ordinary root-candidate ranking instead of protecting.
# From: Issue #1095 | PR #1586
@test "protected reference reason fails for an unrecognized tag" {
  run sra_protected_reference_reason "pr-1501-staging" ""
  [ "$status" -ne 0 ]
}

# What: budget decision protects a position at or within the budget.
# Why: shared arithmetic used by both the ordinary-root and the v1.2
# non-ordinary-version buffer loops; wrong-direction off-by-one here would
# silently over- or under-protect every package audited.
# From: Issue #1585.
@test "budget decision protects within budget" {
  run sra_budget_decision 5 5
  [ "$status" -eq 0 ]
  [ "$output" = $'protect\twithin-5' ]
}

# What: budget decision marks a position beyond the budget would-delete.
# Why: confirms the off-by-one boundary the "within" case above establishes.
# From: Issue #1585.
@test "budget decision marks beyond-budget positions would-delete" {
  run sra_budget_decision 6 5
  [ "$status" -eq 0 ]
  [ "$output" = $'would-delete\tbeyond-5' ]
}

# What: budget decision fails closed on a non-numeric position or budget.
# Why: a caller passing a malformed rank must not silently default to a
# spuriously-protective or spuriously-deletable decision.
# From: Issue #1585.
@test "budget decision fails closed on non-numeric input" {
  run sra_budget_decision "abc" 5
  [ "$status" -ne 0 ]
  run sra_budget_decision 5 "abc"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Incremental classification cache (v1.2 point 4)
# ---------------------------------------------------------------------------

# What: the schema declares the cache's primary key and required columns.
# Why: a pure string check -- catches an accidental column rename/drop
# without needing a live sqlite3 invocation.
# From: Issue #1585.
@test "cache schema declares the version_cache_v2 table with its primary key" {
  run sra_cache_schema_sql
  [ "$status" -eq 0 ]
  [[ "$output" == *"CREATE TABLE IF NOT EXISTS version_cache_v2"* ]]
  [[ "$output" == *"PRIMARY KEY (package, version_id, history_fingerprint)"* ]]
  [[ "$output" == *"history_fingerprint TEXT NOT NULL"* ]]
  [[ "$output" == *"history_ref_names TEXT NOT NULL"* ]]
}

# What: doubles an embedded single quote, SQL's own escape for that literal.
# Why: every cache write builds its statement string this way -- a wrong
# escape here is a SQL-injection-shaped correctness bug, not just cosmetic.
# From: Issue #1585.
@test "sql quote doubles an embedded single quote" {
  run sra_sql_quote "pr-1's-sha-abc"
  [ "$status" -eq 0 ]
  [ "$output" = "pr-1''s-sha-abc" ]
}

# What: init/write/read round-trips a real row through a real sqlite3 db.
# Why: the pure-string/escaping tests above cannot catch a real SQL syntax
# error; only an actual sqlite3 invocation can. Skips (not fails) when
# sqlite3 is unavailable -- expected on a host outside the pinned
# build-tools container (AG-VAL-016), where this dependency was added.
# From: Issue #1585.
@test "cache init/write/read round-trips a real row through sqlite3" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available on this host"
  db_path="$tmp_dir/cache.db"
  rows_file="$tmp_dir/rows.tsv"
  digest="sha256:$(printf 'a%.0s' {1..64})"
  printf '42\t%s\tsha-abc1234\trank:7\n' "$digest" >"$rows_file"

  fingerprint="origin/current_dev@$(printf 'c%.0s' {1..40})"
  run sra_cache_init "$db_path"
  [ "$status" -eq 0 ]
  run sra_cache_write_package "$db_path" "proxy" "$rows_file" "$fingerprint"
  [ "$status" -eq 0 ]
  run sra_cache_read_package "$db_path" "proxy" "$fingerprint"
  [ "$status" -eq 0 ]
  [[ "$output" == *"42"* ]]
  [[ "$output" == *"$digest"* ]]
  [[ "$output" == *"sha-abc1234"* ]]
  [[ "$output" == *"rank:7"* ]]
}

# What: an inherited old-schema (pre-Issue-#1095) cache db does not break a
# new-schema write.
# Why: a restored actions/cache blob can predate the version_cache_v2
# rename; CREATE TABLE IF NOT EXISTS must not be fooled by an old table of
# the same old name, and a real deployment must self-heal, not warn forever.
# From: Issue #1095.
@test "cache write self-heals against an inherited old-schema database" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available on this host"
  db_path="$tmp_dir/cache.db"
  rows_file="$tmp_dir/rows.tsv"
  sqlite3 "$db_path" "CREATE TABLE IF NOT EXISTS version_cache (package TEXT NOT NULL, version_id INTEGER NOT NULL, digest TEXT NOT NULL, tags TEXT NOT NULL, resolution TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY (package, version_id));"

  fingerprint="origin/current_dev@$(printf 'c%.0s' {1..40})"
  printf '42\tsha256:%s\tsha-abc1234\trank:7\n' "$(printf 'a%.0s' {1..64})" >"$rows_file"
  run sra_cache_init "$db_path"
  [ "$status" -eq 0 ]
  run sra_cache_write_package "$db_path" "proxy" "$rows_file" "$fingerprint"
  [ "$status" -eq 0 ]
  run sra_cache_read_package "$db_path" "proxy" "$fingerprint"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sha-abc1234"* ]]
}

# What: a cache write with no history fingerprint argument fails closed.
# Why: history_fingerprint is a required column, not optional -- a caller
# that forgets it must get a loud failure, never a silently written row.
# From: Issue #1095.
@test "cache write fails closed without a history fingerprint argument" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available on this host"
  db_path="$tmp_dir/cache.db"
  rows_file="$tmp_dir/rows.tsv"
  printf '42\tsha256:%s\tsha-abc1234\trank:7\n' "$(printf 'a%.0s' {1..64})" >"$rows_file"
  run sra_cache_init "$db_path"
  [ "$status" -eq 0 ]
  run sra_cache_write_package "$db_path" "proxy" "$rows_file"
  [ "$status" -ne 0 ]
}

# What: a fresh, never-initialized database path is a clean read miss.
# Why: this is the exact "cache miss falls back to a full scan" case the
# v1.2 plan calls its own required self-verification -- must degrade,
# never error the caller.
# From: Issue #1585.
@test "cache read on a nonexistent database fails closed without erroring the caller" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available on this host"
  run sra_cache_read_package "$tmp_dir/does-not-exist.db" "proxy" "origin/current_dev@$(printf 'c%.0s' {1..40})"
  [ "$status" -ne 0 ]
}

# What: re-writing the same (package, version_id, fingerprint) replaces.
# Why: INSERT OR REPLACE is load-bearing -- a version reclassified again
# under the same ref set must overwrite its stale row, not duplicate it.
# From: Issue #1585 | Issue #1095.
@test "cache write replaces an existing row for the same package, version id, and fingerprint" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available on this host"
  db_path="$tmp_dir/cache.db"
  rows_file="$tmp_dir/rows.tsv"
  fingerprint="origin/current_dev@$(printf 'c%.0s' {1..40})"
  run sra_cache_init "$db_path"
  [ "$status" -eq 0 ]

  printf '42\tsha256:%s\told-tag\trank:9\n' "$(printf 'a%.0s' {1..64})" >"$rows_file"
  run sra_cache_write_package "$db_path" "proxy" "$rows_file" "$fingerprint"
  [ "$status" -eq 0 ]

  printf '42\tsha256:%s\tnew-tag\trank:3\n' "$(printf 'b%.0s' {1..64})" >"$rows_file"
  run sra_cache_write_package "$db_path" "proxy" "$rows_file" "$fingerprint"
  [ "$status" -eq 0 ]

  run sra_cache_read_package "$db_path" "proxy" "$fingerprint"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<<"$output")" -eq 1 ]
  [[ "$output" == *"new-tag"* ]]
  [[ "$output" != *"old-tag"* ]]
}

# What: two callers with different fingerprints keep independent rows.
# Why: this is the property that makes cross-caller sharing safe instead of
# each caller's write evicting the other's (Issue #1095) -- a read for one
# fingerprint must never see the other's row for the same version id.
# From: Issue #1095.
@test "cache rows for different history fingerprints coexist and do not evict each other" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available on this host"
  db_path="$tmp_dir/cache.db"
  rows_file="$tmp_dir/rows.tsv"
  narrow_fp="origin/current_dev@$(printf 'c%.0s' {1..40})"
  wide_fp="origin/current_dev@$(printf 'c%.0s' {1..40});origin/master@$(printf 'd%.0s' {1..40})"
  run sra_cache_init "$db_path"
  [ "$status" -eq 0 ]

  printf '42\tsha256:%s\tsha-abc1234\toutside-managed-history\n' "$(printf 'a%.0s' {1..64})" >"$rows_file"
  run sra_cache_write_package "$db_path" "proxy" "$rows_file" "$narrow_fp"
  [ "$status" -eq 0 ]

  printf '42\tsha256:%s\tsha-abc1234\trank:3\n' "$(printf 'a%.0s' {1..64})" >"$rows_file"
  run sra_cache_write_package "$db_path" "proxy" "$rows_file" "$wide_fp"
  [ "$status" -eq 0 ]

  run sra_cache_read_package "$db_path" "proxy" "$narrow_fp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"outside-managed-history"* ]]

  run sra_cache_read_package "$db_path" "proxy" "$wide_fp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rank:3"* ]]
}

# What: a same-ref-name-set generation is pruned when its exact fingerprint
# changes (tip advance), but a different caller's generation is untouched.
# Why: without pruning, every tip advance adds a permanent new generation
# instead of replacing the prior one from the same caller -- unbounded
# growth (Issue #1095); pruning must not cross ref-name-set boundaries.
# From: Issue #1095.
@test "cache write prunes a superseded same-caller generation but not a different caller's" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available on this host"
  db_path="$tmp_dir/cache.db"
  rows_file="$tmp_dir/rows.tsv"
  old_fp="origin/current_dev@$(printf 'c%.0s' {1..40})"
  new_fp="origin/current_dev@$(printf 'e%.0s' {1..40})"
  other_caller_fp="origin/current_dev@$(printf 'c%.0s' {1..40});origin/master@$(printf 'd%.0s' {1..40})"
  run sra_cache_init "$db_path"
  [ "$status" -eq 0 ]

  printf '42\tsha256:%s\told-tag\trank:9\n' "$(printf 'a%.0s' {1..64})" >"$rows_file"
  run sra_cache_write_package "$db_path" "proxy" "$rows_file" "$old_fp"
  [ "$status" -eq 0 ]
  run sra_cache_write_package "$db_path" "proxy" "$rows_file" "$other_caller_fp"
  [ "$status" -eq 0 ]

  printf '42\tsha256:%s\tnew-tag\trank:3\n' "$(printf 'b%.0s' {1..64})" >"$rows_file"
  run sra_cache_write_package "$db_path" "proxy" "$rows_file" "$new_fp"
  [ "$status" -eq 0 ]

  run sra_cache_read_package "$db_path" "proxy" "$old_fp"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run sra_cache_read_package "$db_path" "proxy" "$new_fp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"new-tag"* ]]

  run sra_cache_read_package "$db_path" "proxy" "$other_caller_fp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"old-tag"* ]]
}

# What: the fingerprint differs when the managed ref set changes.
# Why: this is the mechanism the v1.2 cache's ref-set safety depends on
# (Issue #1095) -- it must actually change, not just exist unused.
# From: Issue #1095.
@test "history refs fingerprint changes when the ref set changes" {
  git_dir="$tmp_dir/repo"
  git init -q "$git_dir"
  git -C "$git_dir" config user.name Test
  git -C "$git_dir" config user.email test@example.invalid
  printf 'one\n' >"$git_dir/file"
  git -C "$git_dir" add file
  git -C "$git_dir" commit -q -m one
  git -C "$git_dir" update-ref refs/remotes/origin/current_dev HEAD
  printf 'two\n' >>"$git_dir/file"
  git -C "$git_dir" commit -q -am two
  git -C "$git_dir" update-ref refs/remotes/origin/master HEAD

  run sra_history_refs_fingerprint "$git_dir" origin/current_dev
  [ "$status" -eq 0 ]
  narrow_fingerprint="$output"

  run sra_history_refs_fingerprint "$git_dir" origin/current_dev origin/master
  [ "$status" -eq 0 ]
  wide_fingerprint="$output"

  [ "$narrow_fingerprint" != "$wide_fingerprint" ]
  [[ "$narrow_fingerprint" == *"origin/current_dev@"* ]]
  [[ "$wide_fingerprint" == *"origin/current_dev@"* ]]
  [[ "$wide_fingerprint" == *"origin/master@"* ]]

  # What: the same ref set, recomputed, is byte-identical.
  # Why: stable across repeated same-input runs, not just "usually similar."
  # From: Issue #1095.
  run sra_history_refs_fingerprint "$git_dir" origin/current_dev
  [ "$status" -eq 0 ]
  [ "$output" = "$narrow_fingerprint" ]
}

# What: an unresolvable ref, or an empty ref list, fails closed.
# Why: mirrors the fail-closed style already used by sra_budget_decision --
# never silently proceed with an empty/partial fingerprint.
# From: Issue #1095.
@test "history refs fingerprint fails closed on an unknown ref or an empty ref list" {
  git_dir="$tmp_dir/repo"
  git init -q "$git_dir"
  git -C "$git_dir" config user.name Test
  git -C "$git_dir" config user.email test@example.invalid
  printf 'one\n' >"$git_dir/file"
  git -C "$git_dir" add file
  git -C "$git_dir" commit -q -m one

  run sra_history_refs_fingerprint "$git_dir" origin/does-not-exist
  [ "$status" -ne 0 ]

  run sra_history_refs_fingerprint "$git_dir"
  [ "$status" -ne 0 ]
}

# What: the classification cache read passes history_fingerprint, not just
# package, before trusting any cached row.
# Why: a structural regression check -- catches a future edit that
# reintroduces the fixed gap by dropping this argument.
# From: Issue #1095.
@test "gc-sha-retention-audit.sh passes the history fingerprint into the cache read" {
  run grep -F 'sra_cache_read_package "$cache_db" "$package" "$history_fingerprint"' "$repo_root/scripts/untracked/gc-sha-retention-audit.sh"
  [ "$status" -eq 0 ]
}

# What: rollback anchors must precede tag/history classification for every class.
# Why: metadata stack roots now use the same bounded history policy instead
# of an unconditional class exemption, but rollback remains absolute.
# From: Issue #1095 | PR #1586
@test "gc-sha-retention-audit.sh checks rollback_anchors before tag/history classification" {
  anchor_line="$(grep -n 'sra_digest_is_rollback_anchor "\$digest"' "$repo_root/scripts/untracked/gc-sha-retention-audit.sh" | cut -d: -f1)"
  facts_line="$(grep -n 'sra_version_tag_facts "\$version_json"' "$repo_root/scripts/untracked/gc-sha-retention-audit.sh" | cut -d: -f1)"
  [ -n "$anchor_line" ]
  [ -n "$facts_line" ]
  [ "$anchor_line" -lt "$facts_line" ]
  run grep -F 'metadata-stack-identity' "$repo_root/scripts/untracked/gc-sha-retention-audit.sh"
  [ "$status" -eq 1 ]
}

# What: a truly untagged rootless version (other_count==0) must still emit an
# unconditional protect BEFORE the v1.2 buffer-candidate line is reachable.
# Why: a completely untagged version (the common case for a manifest list's
# own untagged amd64/arm64 platform children) must never share the
# channel_buffer_versions buffer with a version that has an unrecognized tag
# FORMAT -- doing so would make a live-manifest platform child a
# would-delete candidate past a 5-slot buffer. The plan's own wording
# targets "any historical or otherwise-unanticipated tag format" -- an
# absent tag has no format, so it
# must stay on the unconditional-protect path, never reach
# other_tag_candidates at all. This is a structural/ordering check (the
# orchestrator's own live GHCR pagination is not mocked here); it can only
# assert source-code shape, not runtime behavior -- see the plan's own
# request for real CI verification.
# From: Issue #1585.
@test "gc-sha-retention-audit.sh protects a truly untagged rootless version before any buffer routing" {
  untagged_protect_line="$(grep -n 'root_count == 0 && other_count == 0' "$repo_root/scripts/untracked/gc-sha-retention-audit.sh" | cut -d: -f1)"
  buffer_write_line="$(grep -n '>>"\$other_tag_candidates"' "$repo_root/scripts/untracked/gc-sha-retention-audit.sh" | head -1 | cut -d: -f1)"
  [ -n "$untagged_protect_line" ]
  [ -n "$buffer_write_line" ]
  [ "$untagged_protect_line" -lt "$buffer_write_line" ]
}

# What: filtered mode is the package-parallel planner entry point used by GC.
# Why: it must exist without adding DELETE capability to the audit itself.
# From: Issue #1095 | PR #1586
@test "gc-sha-retention-audit.sh exposes a read-only package filter and reusable snapshot for GC workers" {
  run grep -F 'SRA_PACKAGE_FILTER' "$repo_root/scripts/untracked/gc-sha-retention-audit.sh"
  [ "$status" -eq 0 ]
  run grep -F 'SRA_VERSION_SNAPSHOT_FILE' "$repo_root/scripts/untracked/gc-sha-retention-audit.sh"
  [ "$status" -eq 0 ]
  run grep -F 'ordinary-root-beyond-retention-budget' "$repo_root/scripts/untracked/gc-sha-retention-audit.sh"
  [ "$status" -eq 0 ]
}

# What: audit concurrency rejects zero before any registry request can run.
# Why: an invalid worker bound must fail closed instead of disabling the audit
# loop or creating an unbounded package fan-out.
# From: Issue #1585
@test "gc-sha-retention-audit.sh rejects invalid package concurrency" {
  run env GITHUB_REPOSITORY=wiki-mod/lancache-ng GH_TOKEN=test SRA_CONCURRENCY=0 \
    bash "$repo_root/scripts/untracked/gc-sha-retention-audit.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SRA_CONCURRENCY must be a positive integer"* ]]
}

# What: package workers use bounded batches and file-backed result handoff.
# Why: background shells cannot return audit output, failure state, or observed
# rollback anchors through parent variables; all three channels must survive.
# From: Issue #1585
@test "gc-sha-retention-audit.sh preserves concurrent worker results" {
  script="$repo_root/scripts/untracked/gc-sha-retention-audit.sh"
  run grep -F 'offset+=audit_concurrency' "$script"
  [ "$status" -eq 0 ]
  run grep -F 'wait "${worker_pids[$worker_index]}"' "$script"
  [ "$status" -eq 0 ]
  run grep -F 'done <"${worker_anchors[$worker_index]}"' "$script"
  [ "$status" -eq 0 ]
}

# What: retention audit code and workflow contain no destructive package path.
# Why: the read-only audit surface must remain structurally incapable of
# package deletion, verified by grepping for any DELETE-capable pattern.
# From: Issue #1585 | PR #1586
@test "retention audit code and workflow contain no destructive package path" {
  run grep -ER --line-number -- '-X[[:space:]]+DELETE|delete:packages|GHCR_PACKAGE_DELETE_PAT' \
    "$repo_root/scripts/untracked/gc-sha-retention-audit.sh" \
    "$repo_root/scripts/lib/sha-retention-audit.sh" \
    "$repo_root/scripts/lib/github-api-retry.sh" \
    "$repo_root/.github/workflows/gc-sha-retention-audit.yml"
  [ "$status" -eq 1 ]
}
