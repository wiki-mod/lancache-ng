#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regression test for scripts/untracked/require-image-platforms.sh: a
# transient GHCR failure on the first `docker buildx imagetools inspect`
# attempt, recovered by ghcr_retry's own retry loop on a later attempt, must
# not corrupt the platform-detection result. Before this fix, the script
# captured the whole ghcr_retry invocation's stdout+stderr together (`2>&1`)
# into the value it then compared for platform detection -- ghcr_retry's own
# retry/relogin diagnostics (written to stderr on the failed first attempt)
# got spliced into that value even though a later attempt succeeded, so a
# present platform was reported as missing. Caught live on PR #1500's CI: a
# single transient GHCR 403 on the "merge multi-platform manifests" job
# failed the job with "is missing required platform linux/amd64" despite
# both platform legs having just been pushed successfully seconds earlier.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/untracked/require-image-platforms.sh"
    fake_bin_dir="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$fake_bin_dir"
    call_log="$BATS_TEST_TMPDIR/docker_calls.log"
    : > "$call_log"

    # No credentials: ghcr_retry skips its own relogin step between
    # attempts (scripts/lib/ghcr-retry.sh), keeping the fake `docker` above
    # the only stub these tests need.
    unset GHCR_RETRY_USERNAME GHCR_RETRY_PASSWORD
    export GHCR_RETRY_BACKOFF_SECONDS=0
}

# A fake `docker buildx imagetools inspect ... --format ...` that fails on
# its first invocation with a 403-shaped stderr message (the exact failure
# mode observed live), then succeeds on every subsequent invocation with a
# multi-platform index's own "<no value>/<no value>" --format output, and a
# real "Platform:" line dump on the plain (no --format) fallback call.
write_fake_docker_retry_then_multi_platform_success() {
    cat > "$fake_bin_dir/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$call_log"
calls=\$(wc -l < "$call_log")
if [[ "\$*" == *"--format"* ]]; then
  if [[ "\$calls" -eq 1 ]]; then
    echo "ERROR: failed to authorize: failed to fetch oauth token: unexpected status from GET request to https://ghcr.io/token: 403 Forbidden" >&2
    exit 1
  fi
  printf '<no value>/<no value>\n'
  exit 0
fi
printf 'Platform:  linux/amd64\n'
printf 'Platform:  linux/arm64\n'
exit 0
STUB
    chmod +x "$fake_bin_dir/docker"
    export PATH="$fake_bin_dir:$PATH"
}

@test "require-image-platforms.sh: a transient failure recovered by ghcr_retry does not corrupt platform detection" {
    write_fake_docker_retry_then_multi_platform_success

    run bash "$script" "ghcr.io/wiki-mod/lancache-ng/watchdog:pr-1500-sha-b13f668" "linux/amd64,linux/arm64"
    [ "$status" -eq 0 ]
    [[ "$output" == *"has all required platforms"* ]]
    [[ "$output" != *"is missing required platform"* ]]
    [[ "$output" != *"403 Forbidden"* ]]
}

@test "require-image-platforms.sh: a genuinely missing platform still fails closed" {
    cat > "$fake_bin_dir/docker" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"--format"* ]]; then
  printf '<no value>/<no value>\n'
  exit 0
fi
printf 'Platform:  linux/amd64\n'
exit 0
STUB
    chmod +x "$fake_bin_dir/docker"
    export PATH="$fake_bin_dir:$PATH"

    run bash "$script" "ghcr.io/wiki-mod/lancache-ng/watchdog:pr-1500-sha-b13f668" "linux/amd64,linux/arm64"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is missing required platform linux/arm64"* ]]
}

@test "require-image-platforms.sh: total inspect failure across every retry still fails closed with real diagnostics" {
    cat > "$fake_bin_dir/docker" <<STUB
#!/usr/bin/env bash
echo "ERROR: manifest unknown" >&2
exit 1
STUB
    chmod +x "$fake_bin_dir/docker"
    export PATH="$fake_bin_dir:$PATH"
    export GHCR_RETRY_MAX_ATTEMPTS=1

    run bash "$script" "ghcr.io/wiki-mod/lancache-ng/watchdog:pr-1500-sha-b13f668" "linux/amd64,linux/arm64"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to inspect image platform"* ]]
    [[ "$output" == *"manifest unknown"* ]]
}
