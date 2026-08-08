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
      and (.platform == "linux/amd64" or .platform == "linux/arm64")
      and (.digest | test("^sha256:[0-9a-f]{64}$"))
      and (.mode == "built" or .mode == "reused")
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
      and (.digest | test("^sha256:[0-9a-f]{64}$"))
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
          and (.digest | test("^sha256:[0-9a-f]{64}$"))
          and (.platforms["linux/amd64"] | test("^sha256:[0-9a-f]{64}$"))
          and (.platforms["linux/arm64"] | test("^sha256:[0-9a-f]{64}$"))
        ] | all
      )
    ' "$file" >/dev/null || ci_ai_fail "invalid stack lock: $file"
}

ci_ai_validate_acceptance() {
    local file="$1"
    jq -e '
      .schema == "stack-acceptance/v1"
      and .accepted == true
      and (.source_sha | test("^[0-9a-f]{40}$"))
      and (.stack_lock_sha256 | test("^[0-9a-f]{64}$"))
      and (.accepted_tag | type == "string" and startswith("accepted-v2-"))
      and .gates.identity_complete == true
      and .gates.platform_complete == true
      and .gates.provenance == true
      and .gates.exact_digest_security == true
      and .gates.native_platform_smoke == true
      and .gates.exact_locked_stack == true
      and .gates.supplemental_full_setup == true
      and .gates.publication_policy == true
    ' "$file" >/dev/null || ci_ai_fail "invalid acceptance record: $file"
}

ci_ai_manifest_json() {
    local ref="$1"
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
