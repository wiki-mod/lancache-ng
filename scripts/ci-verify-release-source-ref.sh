#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Re-reads an existing release tag from the Git remote and requires its peeled
# commit identity to remain equal to the source SHA frozen at release planning.
set -euo pipefail

[[ $# -eq 2 ]] || {
    echo "usage: ci-verify-release-source-ref.sh RELEASE_TAG EXPECTED_SHA" >&2
    exit 2
}
release_tag="$1"
expected_sha="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
source "$repo_root/scripts/lib/network-retry.sh"

[[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] \
    || ci_ai_fail "invalid release tag: $release_tag"
ci_ai_require_sha "$expected_sha"

read_release_tag_once() {
    local output_file="$1" error_file="$2" status
    if git ls-remote --exit-code origin \
        "refs/tags/${release_tag}" "refs/tags/${release_tag}^{}" \
        >"$output_file" 2>"$error_file"; then
        return 0
    else
        status=$?
    fi

    if [[ "$status" -eq 2 ]]; then
        echo "::error::Release tag $release_tag no longer exists on origin." >&2
        return "$NETWORK_RETRY_PERMANENT_FAILURE_EXIT_CODE"
    fi

    cat "$error_file" >&2
    return "$status"
}

work_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT
output_file="$work_dir/ls-remote.out"
error_file="$work_dir/ls-remote.err"
network_retry -- read_release_tag_once "$output_file" "$error_file"

peeled_sha="$(awk -v ref="refs/tags/${release_tag}^{}" '$2 == ref { print $1 }' "$output_file")"
direct_sha="$(awk -v ref="refs/tags/${release_tag}" '$2 == ref { print $1 }' "$output_file")"
if [[ -n "$peeled_sha" ]]; then
    actual_sha="$peeled_sha"
else
    actual_sha="$direct_sha"
fi
ci_ai_require_sha "$actual_sha"
[[ "$actual_sha" == "$expected_sha" ]] || {
    ci_ai_fail "release tag $release_tag moved: expected commit $expected_sha, got $actual_sha"
    exit 1
}
