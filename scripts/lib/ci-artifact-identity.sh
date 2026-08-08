#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Shared fail-closed validation helpers for the digest-identity CI path.
# OCI digests are the candidate identity. Tags are transport/promotion
# references only and never count as proof that an artifact was validated.
ci_ai_fail() {
    printf 'ci-artifact-identity: %s\n' "$1" >&2
    return 1
}

ci_ai_require_digest() {
    local digest="${1:-}"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
        || ci_ai_fail "invalid sha256 digest: ${digest:-<empty>}"
}

ci_ai_require_sha() {
    local sha="${1:-}"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] \
        || ci_ai_fail "invalid git commit SHA: ${sha:-<empty>}"
}

ci_ai_arch_from_platform() {
    case "${1:-}" in
        linux/amd64) printf '%s\n' amd64 ;;
        linux/arm64|linux/arm64/v8) printf '%s\n' arm64 ;;
        *) ci_ai_fail "unsupported platform: ${1:-<empty>}" ;;
    esac
}

ci_ai_validate_platform_record() {
    local file="$1"
    jq -e '
      .schema == "image-candidate-platform/v1"
      and (.service | type == "string" and length > 0)
      and (.scope == "runtime" or .scope == "tooling")
      and (.image | type == "string" and startswith("ghcr.io/"))
      and (.candidate_source_sha | test("^[0-9a-f]{40}$"))
      and (.artifact_source_sha | test("^[0-9a-f]{40}$"))
      and (.source_fingerprint | test("^sha256:[0-9a-f]{64}$"))
      and (.platform == "linux/amd64" or .platform == "linux/arm64")
      and (.digest | test("^sha256:[0-9a-f]{64}$"))
      and (.mode == "built" or .mode == "reused")
      and (
        if .mode == "reused" then
          (.reused_index_digest | test("^sha256:[0-9a-f]{64}$"))
        else
          (.reused_index_digest == "")
        end
      )
    ' "$file" >/dev/null || ci_ai_fail "invalid platform candidate record: $file"
}

ci_ai_validate_index_record() {
    local file="$1"
    jq -e '
      .schema == "image-candidate-index/v1"
      and (.service | type == "string" and length > 0)
      and (.scope == "runtime" or .scope == "tooling")
      and (.image | type == "string" and startswith("ghcr.io/"))
      and (.candidate_source_sha | test("^[0-9a-f]{40}$"))
      and (.artifact_source_sha | test("^[0-9a-f]{40}$"))
      and (.source_fingerprint | test("^sha256:[0-9a-f]{64}$"))
      and (.digest | test("^sha256:[0-9a-f]{64}$"))
      and (.platforms | type == "object" and (keys | sort) == ["linux/amd64","linux/arm64"])
      and (.platforms["linux/amd64"] | test("^sha256:[0-9a-f]{64}$"))
      and (.platforms["linux/arm64"] | test("^sha256:[0-9a-f]{64}$"))
    ' "$file" >/dev/null || ci_ai_fail "invalid image index candidate record: $file"
}

ci_ai_validate_stack_lock() {
    local file="$1"
    jq -e '
      .schema == "stack-lock/v1"
      and (.source_sha | test("^[0-9a-f]{40}$"))
      and (.candidate_tag | type == "string" and length > 0)
      and (.runtime | type == "object" and length > 0)
      and (.tooling | type == "object")
      and (
        [(.runtime + .tooling)[] |
          (.image | type == "string" and startswith("ghcr.io/"))
          and (.artifact_source_sha | test("^[0-9a-f]{40}$"))
          and (.source_fingerprint | test("^sha256:[0-9a-f]{64}$"))
          and (.digest | test("^sha256:[0-9a-f]{64}$"))
          and (.platforms | type == "object" and (keys | sort) == ["linux/amd64","linux/arm64"])
          and (.platforms["linux/amd64"] | test("^sha256:[0-9a-f]{64}$"))
          and (.platforms["linux/arm64"] | test("^sha256:[0-9a-f]{64}$"))
        ] | all
      )
    ' "$file" >/dev/null || ci_ai_fail "invalid stack lock: $file"
}

# Structural acceptance schema. A release pointer and a reusable branch
# acceptance share the same base gate set, but they do not share the same
# trust policy. In particular, only candidate acceptances from protected
# product branches may be reused/promoted as a baseline. Keep that stronger
# rule in ci_ai_validate_reusable_acceptance rather than making release
# records pretend they were signed from a product branch ref.
ci_ai_validate_acceptance() {
    local file="$1"
    jq -e '
      .schema == "stack-acceptance/v1"
      and .accepted == true
      and (.source_sha | test("^[0-9a-f]{40}$"))
      and (
        (.source_ref == null)
        or (.source_ref | type == "string" and test("^refs/(heads|tags)/[A-Za-z0-9._/-]+$"))
      )
      and (.stack_lock_sha256 | test("^[0-9a-f]{64}$"))
      and (.accepted_tag | type == "string" and startswith("accepted-v2-"))
      and .gates.identity_complete == true
      and .gates.platform_complete == true
      and .gates.provenance == true
      and .gates.exact_digest_security == true
      and .gates.native_platform_smoke == true
      and .gates.exact_locked_stack == true
      and .gates.runtime_deep_validation == true
      and .gates.supplemental_full_setup == true
      and .gates.publication_policy == true
    ' "$file" >/dev/null || ci_ai_fail "invalid acceptance record: $file"
}

ci_ai_validate_reusable_acceptance() {
    local file="$1"
    ci_ai_validate_acceptance "$file" || return 1
    jq -e '
      .source_ref == "refs/heads/current_dev"
      or .source_ref == "refs/heads/master"
    ' "$file" >/dev/null || ci_ai_fail "acceptance is not reusable from a protected product branch: $file"
}

# A release acceptance inherits the already-proven runtime gates only because
# the runtime digests are copied unchanged from the accepted stack. It has an
# additional producer boundary for the governance-required release build-tools
# artifact, so its record must explicitly prove that fresh tooling build and
# the release-wide exact-digest evidence. This record is never a candidate
# reuse credential.
ci_ai_validate_release_acceptance() {
    local file="$1"
    ci_ai_validate_acceptance "$file" || return 1
    jq -e '
      (.release_tag | type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+(-rc\\.[0-9]+)?$"))
      and .source_ref == ("refs/tags/" + .release_tag)
      and .gates.accepted_runtime_identity_preserved == true
      and .gates.release_build_tools_built == true
      and .gates.release_build_tools_provenance == true
      and .gates.release_exact_digest_evidence == true
    ' "$file" >/dev/null || ci_ai_fail "invalid release acceptance record: $file"
}

# Registry identity reads are correctness-critical and are inherently network
# operations. Use the repository's established GHCR retry wrapper rather than
# letting a transient registry/login failure masquerade as a missing/moved
# digest. The helper is loaded lazily so sourcing this library remains side
# effect free for tests that never touch the registry.
ci_ai_manifest_json() {
    local ref="$1"
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if ! declare -F ghcr_retry >/dev/null 2>&1; then
        # shellcheck source=scripts/lib/ghcr-retry.sh
        source "$lib_dir/ghcr-retry.sh"
    fi
    ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- \
        docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}'
}

ci_ai_ref_digest() {
    local ref="$1" manifest digest
    manifest="$(ci_ai_manifest_json "$ref")" || return 1
    digest="$(jq -r '.digest // empty' <<<"$manifest")"
    ci_ai_require_digest "$digest" || return 1
    printf '%s\n' "$digest"
}

ci_ai_platform_digest() {
    local ref="$1" platform="$2" manifest digest
    manifest="$(ci_ai_manifest_json "$ref")" || return 1
    digest="$(
      jq -r --arg platform "$platform" '
        .manifests[]
        | select((.platform.os + "/" + .platform.architecture) == $platform)
        | .digest
      ' <<<"$manifest"
    )"
    [[ "$(wc -l <<<"$digest" | tr -d ' ')" -eq 1 ]] \
        || ci_ai_fail "expected exactly one $platform manifest in $ref"
    ci_ai_require_digest "$digest" || return 1
    printf '%s\n' "$digest"
}