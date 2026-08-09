#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Runs the existing quickstart/syslog end-to-end simulation behind the same
# exact-digest Docker boundary used by the reusable full-setup suite. Keeping
# one Compose-lock implementation is deliberate: default-file discovery,
# project-name flags, profiles, multiple -f files, and runtime digest
# assertions must have identical semantics in every locked runtime gate.
set -euo pipefail

[[ $# -eq 1 ]] || {
    echo "usage: ci-run-locked-quickstart-simulation.sh STACK_LOCK" >&2
    exit 2
}

lock="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/ci-artifact-identity.sh
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
ci_ai_validate_stack_lock "$lock"

real_docker="$(command -v docker || true)"
[[ -n "$real_docker" && -x "$real_docker" ]] \
    || ci_ai_fail "quickstart locked simulation requires a real Docker CLI"

shim_dir="$(mktemp -d)"
launcher="$shim_dir/docker"
cat >"$launcher" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exec "${CI_LOCKED_DOCKER_SHIM_SCRIPT:?CI_LOCKED_DOCKER_SHIM_SCRIPT is required}" "$@"
SH
chmod +x "$launcher"

export GITHUB_WORKSPACE="$repo_root"
export CI_LOCKED_STACK_FILE="$lock"
export CI_LOCKED_DOCKER_SHIM_DIR="$shim_dir"
export CI_LOCKED_DOCKER_SHIM_SCRIPT="$repo_root/scripts/ci-docker-lock-shim.sh"
export CI_LOCKED_REAL_DOCKER="$real_docker"
export PATH="$shim_dir:$PATH"

# The behavioral simulation remains the authority for quickstart/logging
# behavior. Every Docker command it launches now resolves through the same
# executable boundary as the shared full-setup path. Non-Compose Docker
# operations pass through unchanged; Compose operations are rendered to a
# complete canonical model and overlaid with the stack-lock digests before
# execution, with running first-party identities asserted after every `up`.
# shellcheck source=scripts/syslog-forwarding-simulation.sh
source "$repo_root/scripts/syslog-forwarding-simulation.sh"

# Independent final readback from Docker itself. The behavioral script leaves
# its stack running until its EXIT trap fires, so every Compose-owned container
# is still observable here. This does not trust the transport tag or Compose
# source model: it reads .Config.Image from each live container and compares
# every first-party reference to the exact runtime digest in the stack lock.
asserted=0
while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    actual="$(command docker inspect --format '{{.Config.Image}}' "$cid")"
    [[ "$actual" == ghcr.io/wiki-mod/lancache-ng/* ]] || continue
    [[ "$actual" == *@sha256:* ]] \
        || ci_ai_fail "quickstart container $cid is first-party but not digest-qualified: $actual"
    image="${actual%@*}"
    digest="${actual#*@}"
    expected="$(jq -r --arg image "$image" '.runtime[] | select(.image == $image) | .digest' "$lock")"
    ci_ai_require_digest "$expected" \
        || ci_ai_fail "quickstart container $cid uses first-party image $image with no valid lock digest"
    [[ "$digest" == "$expected" ]] \
        || ci_ai_fail "quickstart container $cid runs $actual instead of $image@$expected"
    asserted=$((asserted + 1))
done < <(command docker ps --filter "label=com.docker.compose.project=${compose_project:?compose_project is required}" -q)

(( asserted > 0 )) \
    || ci_ai_fail "quickstart simulation ended with no live first-party container identity to verify"
printf 'Quickstart deep validation final readback asserted %d locked first-party container identities.\n' "$asserted"
