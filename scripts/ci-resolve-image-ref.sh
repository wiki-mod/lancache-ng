#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Resolves one deliberately mutable external image tag to the exact index
# digest that the candidate build must consume. Transient transport/service
# failures get bounded retry; deterministic reference/auth failures fail fast.
set -euo pipefail

[[ $# -eq 1 ]] || {
    echo "usage: ci-resolve-image-ref.sh IMAGE:TAG" >&2
    exit 2
}
ref="$1"
[[ "$ref" != *@* && "$ref" == *:* ]] || {
    echo "ci-resolve-image-ref: expected a tagged image reference, got '$ref'" >&2
    exit 2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/network-retry.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

_inspect_once() {
    local output_file="$1" error_file="$2" image_ref="$3" status=0
    : >"$output_file"
    : >"$error_file"
    if docker buildx imagetools inspect "$image_ref" --format '{{json .Manifest.Digest}}' >"$output_file" 2>"$error_file"; then
        return 0
    else
        status=$?
    fi

    # Retry only transport, throttling, timeout and server-side failure shapes.
    # Unknown errors are deterministic until proven otherwise and therefore
    # fail fast instead of spending the complete retry budget repeatedly.
    if grep -Eqi '(^|[^0-9])(408|425|429|500|502|503|504)([^0-9]|$)|too many requests|rate.?limit|timeout|timed out|temporary failure|connection (reset|refused)|unexpected EOF|TLS handshake|i/o timeout|server misbehaving|service unavailable|bad gateway|gateway timeout' "$error_file"; then
        cat "$error_file" >&2
        return "$status"
    fi

    cat "$error_file" >&2
    return 99
}

raw_file="$tmp_dir/digest"
error_file="$tmp_dir/error"
NETWORK_RETRY_MAX_ATTEMPTS="${NETWORK_RETRY_MAX_ATTEMPTS:-4}" \
NETWORK_RETRY_BACKOFF_SECONDS="${NETWORK_RETRY_BACKOFF_SECONDS:-30}" \
    network_retry -- _inspect_once "$raw_file" "$error_file" "$ref"

digest="$(tr -d '"[:space:]' <"$raw_file")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "ci-resolve-image-ref: invalid manifest digest returned for $ref: ${digest:-<empty>}" >&2
    exit 1
}

image="${ref%:*}"
printf '%s@%s\n' "$image" "$digest"
