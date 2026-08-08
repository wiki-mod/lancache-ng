#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Runs the existing NTP clock-discipline simulation while replacing only its
# candidate transport-tag image argument with the exact stack-lock digest.
# This keeps the long-standing real-clock/CAP_SYS_TIME test implementation as
# the single behavioral test, while removing the mutable tag from the actual
# container start path. The wrapper is intentionally narrow: every other
# docker command and argument is delegated byte-for-byte to the real CLI.
set -euo pipefail

[[ $# -eq 1 ]] || {
    echo "usage: ci-run-locked-ntp-simulation.sh STACK_LOCK" >&2
    exit 2
}

lock="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/ci-artifact-identity.sh
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
ci_ai_validate_stack_lock "$lock"

CI_LOCKED_NTP_IMAGE="$(jq -r '.runtime.ntp.image // empty' "$lock")"
CI_LOCKED_NTP_DIGEST="$(jq -r '.runtime.ntp.digest // empty' "$lock")"
CI_LOCKED_NTP_CANDIDATE_TAG="$(jq -r '.candidate_tag // empty' "$lock")"
ci_ai_require_digest "$CI_LOCKED_NTP_DIGEST"
[[ "$CI_LOCKED_NTP_IMAGE" == "ghcr.io/wiki-mod/lancache-ng/ntp" ]] \
    || ci_ai_fail "stack lock does not identify the expected first-party NTP image"
[[ -n "$CI_LOCKED_NTP_CANDIDATE_TAG" ]] \
    || ci_ai_fail "stack lock has no candidate transport tag"

CI_LOCKED_NTP_TRANSPORT_REF="${CI_LOCKED_NTP_IMAGE}:${CI_LOCKED_NTP_CANDIDATE_TAG}"
CI_LOCKED_NTP_DIGEST_REF="${CI_LOCKED_NTP_IMAGE}@${CI_LOCKED_NTP_DIGEST}"
CI_LOCKED_NTP_REPLACEMENTS=0

# The behavioral simulation constructs exactly one image reference from
# REPOSITORY + IMAGE_TAG and then passes that value to its docker run calls.
# Intercepting that exact argument lets the existing test stay unchanged while
# proving the containers themselves are created from the immutable digest.
docker() {
    local arg
    local -a rewritten=()
    for arg in "$@"; do
        if [[ "$arg" == "$CI_LOCKED_NTP_TRANSPORT_REF" ]]; then
            rewritten+=("$CI_LOCKED_NTP_DIGEST_REF")
            CI_LOCKED_NTP_REPLACEMENTS=$((CI_LOCKED_NTP_REPLACEMENTS + 1))
        else
            rewritten+=("$arg")
        fi
    done
    command docker "${rewritten[@]}"
}

repository_path="${CI_LOCKED_NTP_IMAGE#ghcr.io/}"
repository_path="${repository_path%/ntp}"
export REPOSITORY="$repository_path"
export IMAGE_TAG="$CI_LOCKED_NTP_CANDIDATE_TAG"

# shellcheck source=scripts/ntp-cap-sys-time-simulation.sh
source "$repo_root/scripts/ntp-cap-sys-time-simulation.sh"

(( CI_LOCKED_NTP_REPLACEMENTS > 0 )) \
    || ci_ai_fail "NTP simulation never attempted to start the locked image"

printf 'NTP deep validation used exact image identity %s\n' "$CI_LOCKED_NTP_DIGEST_REF"
