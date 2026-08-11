#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Regression coverage for the protect-only SHA retention audit and its
# read-only GitHub REST helper.

setup() {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=scripts/lib/github-api-retry.sh
  source "$repo_root/scripts/lib/github-api-retry.sh"
  # shellcheck source=scripts/lib/sha-retention-audit.sh
  source "$repo_root/scripts/lib/sha-retention-audit.sh"
  tmp_dir="$(mktemp -d "${BATS_TEST_TMPDIR}/sha-retention-audit.XXXXXX")"
}

teardown() {
  rm -rf -- "$tmp_dir"
}

# The manifest value is the single machine-readable ordinary-root budget.
@test "retention manifest defines exactly ten accepted ordinary roots" {
  run sra_read_retention_keep "$repo_root/release/stack-images.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "10" ]
}

# A duplicate key would create two competing retention values, so parsing must fail.
@test "retention parser rejects duplicate budget declarations" {
  cat >"$tmp_dir/manifest.yml" <<'EOF'
retention:
  accepted_ordinary_roots_per_package: 10
  accepted_ordinary_roots_per_package: 11
EOF
  run sra_read_retention_keep "$tmp_dir/manifest.yml"
  [ "$status" -ne 0 ]
}

# Runtime and tooling retention must follow the same publisher inventory as build-push.
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

# GHCR version objects are deletion units, so every required field must be valid before classification.
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

# Missing tag metadata must never collapse into an apparently untagged version.
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

# A missing/null version id cannot be used as a stable package-version identity.
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

# A malformed digest must not enter the identity graph as if it were an OCI digest.
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

# Multiple SHA aliases on one package version are one stored root identity, not multiple slots.
@test "tag facts preserve multiple root aliases on one version" {
  version='{"metadata":{"container":{"tags":["sha-abcdef1","sha-1234567"]}}}'
  run sra_version_tag_facts "$version"
  [ "$status" -eq 0 ]
  [ "$output" = $'2\t0\t0' ]
}

# A protected non-SHA identity attached to the version must be visible to the classifier.
@test "tag facts classify protected non-SHA tags separately" {
  version='{"metadata":{"container":{"tags":["sha-abcdef1","nightly"]}}}'
  run sra_version_tag_facts "$version"
  [ "$status" -eq 0 ]
  [ "$output" = $'1\t0\t1' ]
}

# Platform child tags are closure, not ordinary root-history slots.
@test "tag facts distinguish architecture child tags" {
  version='{"metadata":{"container":{"tags":["sha-abcdef1-amd64","sha-abcdef1-arm64"]}}}'
  run sra_version_tag_facts "$version"
  [ "$status" -eq 0 ]
  [ "$output" = $'0\t2\t0' ]
}

# Ambiguous or absent REST resources are not positive proof of package absence.
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

# Recovered transient failures are notices, not warnings, under the warnings-as-errors contract.
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
  GITHUB_API_RETRY_ATTEMPTS=2
  GITHUB_API_RETRY_DELAY_SECONDS=0
  run github_api_get_with_retry "https://api.github.invalid/example" "$tmp_dir/body.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"* ]]
  [[ "$output" != *"::warning::"* ]]
}

# SHA abbreviation handling must resolve through Git itself and reject unknown prefixes.
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

# The retention audit surface must remain structurally incapable of package deletion.
@test "retention audit code and workflow contain no destructive package path" {
  run grep -ER --line-number -- '-X[[:space:]]+DELETE|delete:packages|GHCR_PACKAGE_DELETE_PAT' \
    "$repo_root/scripts/untracked/gc-sha-retention-audit.sh" \
    "$repo_root/scripts/lib/sha-retention-audit.sh" \
    "$repo_root/scripts/lib/github-api-retry.sh" \
    "$repo_root/.github/workflows/gc-sha-retention-audit.yml"
  [ "$status" -eq 1 ]
}
