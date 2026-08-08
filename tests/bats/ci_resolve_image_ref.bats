#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    fake_bin="$BATS_TEST_TMPDIR/bin"
    count_file="$BATS_TEST_TMPDIR/count"
    mkdir -p "$fake_bin"
}

@test "external image resolver retries recognized transient registry failures" {
    cat >"$fake_bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ -f "${FAKE_COUNT_FILE:?}" ]] && count="$(cat "$FAKE_COUNT_FILE")"
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_COUNT_FILE"
if (( count < 3 )); then
    echo 'unexpected EOF while reading registry response' >&2
    exit 1
fi
printf '%s\n' '"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
SH
    chmod +x "$fake_bin/docker"

    run env PATH="$fake_bin:$PATH" FAKE_COUNT_FILE="$count_file" \
        NETWORK_RETRY_BACKOFF_SECONDS=0 NETWORK_RETRY_MAX_ATTEMPTS=4 \
        bash "$REPO_ROOT/scripts/ci-resolve-image-ref.sh" golang:latest

    [ "$status" -eq 0 ]
    # Bats captures stderr together with stdout. Retry diagnostics are part of
    # the desired operator-visible behavior, so assert the final identity is
    # present instead of silencing those diagnostics to make an equality test
    # convenient.
    [[ "$output" == *'golang@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'* ]]
    [[ "$output" == *'unexpected EOF while reading registry response'* ]]
    [ "$(cat "$count_file")" -eq 3 ]
}

@test "external image resolver fails fast on deterministic registry error" {
    cat >"$fake_bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ -f "${FAKE_COUNT_FILE:?}" ]] && count="$(cat "$FAKE_COUNT_FILE")"
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_COUNT_FILE"
echo 'manifest unknown' >&2
exit 1
SH
    chmod +x "$fake_bin/docker"

    run env PATH="$fake_bin:$PATH" FAKE_COUNT_FILE="$count_file" \
        NETWORK_RETRY_BACKOFF_SECONDS=0 NETWORK_RETRY_MAX_ATTEMPTS=4 \
        bash "$REPO_ROOT/scripts/ci-resolve-image-ref.sh" rust:latest

    [ "$status" -eq 99 ]
    [ "$(cat "$count_file")" -eq 1 ]
}

@test "each manifest probe has its own kill timeout" {
    run grep -F 'timeout --kill-after=10 45' "$REPO_ROOT/scripts/ci-resolve-image-ref.sh"
    [ "$status" -eq 0 ]
}
