#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for scripts/tracked/check-build-tools-smoke-coverage.sh (issues #790/#791
# / #822 Pattern G): the guard that fails CI when tools/build-tools/
# Dockerfile's final verification list gains a tool that
# scripts/untracked/select-build-tools-image.sh's smoke_test_image() neither checks nor
# explicitly excludes.
#
# Each scenario writes a minimal fixture pair (a Dockerfile with a
# required_tools=() array + docker buildx/compose checks, and a smoke script
# with its own required_tools=() array + version checks) under
# $BATS_TEST_TMPDIR and points the guard at it, so the suite runs fully
# offline and does not depend on the real files' current contents -- except
# the final self-consistency test, which deliberately runs against the real
# repo. The guard is invoked as `bash "$script"` per Rule-Ref: AG-VAL-024.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/tracked/check-build-tools-smoke-coverage.sh"
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    fixture="$BATS_TEST_TMPDIR/fx"
    mkdir -p "$fixture/tools/build-tools" "$fixture/scripts/untracked"
}

fail() {
    echo "$1" >&2
    return 1
}

# write_dockerfile <tool>...
# Writes a fixture build-tools Dockerfile whose final required_tools=() array
# is exactly the given tools, and which verifies docker buildx/compose.
write_dockerfile() {
    {
        printf 'FROM scratch\n'
        printf 'RUN set -euo pipefail; \\\n'
        printf '    required_tools=( \\\n'
        local t
        for t in "$@"; do
            printf '      %s \\\n' "$t"
        done
        printf '    ); \\\n'
        printf '    for t in "${required_tools[@]}"; do command -v "$t"; done; \\\n'
        printf '    docker --version; \\\n'
        printf '    docker compose version; \\\n'
        printf '    docker buildx version\n'
    } > "$fixture/tools/build-tools/Dockerfile"
}

# write_dockerfile_no_array
# A Dockerfile with no required_tools array at all (parser must fail closed).
write_dockerfile_no_array() {
    printf 'FROM scratch\nRUN echo no array here\n' > "$fixture/tools/build-tools/Dockerfile"
}

# write_smoke <tool>...
# Writes a fixture select-build-tools-image.sh whose smoke_test_image()
# required_tools=() array is the given tools. The guard only parses this file
# (never executes it), so the fixture reproduces just the parseable structure
# -- the array and the version-check lines -- not the real script's full
# `docker run ... bash -lc '...'` wrapper. Set NO_BUILDX=1 to omit the docker
# buildx check (to exercise the #791 special-capability path); a comment
# still mentions buildx, to prove the guard matches the `<cap> version`
# invocation and not mere prose.
write_smoke() {
    local include_buildx=1
    if [ "${NO_BUILDX:-0}" = 1 ]; then include_buildx=0; fi
    {
        echo '#!/usr/bin/env bash'
        echo 'smoke_test_image() {'
        echo '  required_tools=('
        local t
        for t in "$@"; do
            echo "    $t"
        done
        echo '  )'
        echo '  docker --version >/dev/null'
        echo '  docker compose version >/dev/null'
        if [ "$include_buildx" = 1 ]; then
            echo '  docker buildx version >/dev/null'
        else
            echo '  # docker buildx is verified elsewhere (prose mention only)'
        fi
        echo '}'
    } > "$fixture/scripts/untracked/select-build-tools-image.sh"
}

@test "passes when the smoke test covers every Dockerfile-verified tool" {
    # Baseline: identical tool sets on both sides, both verify buildx/compose.
    write_dockerfile bash cargo sccache
    write_smoke bash cargo sccache
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails when the Dockerfile verifies a tool the smoke test omits (the #790 drift shape)" {
    # The core Pattern G defect: a newly-installed-and-verified tool that the
    # smoke test never learned about. 'newtool' is not a documented
    # exclusion, so it must be flagged by name.
    write_dockerfile bash cargo newtool
    write_smoke bash cargo
    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"newtool"* ]]
}

@test "passes when the uncovered Dockerfile tool is a documented exclusion (git)" {
    # git is real build toolchain in EXCLUDED_TOOLS: the Dockerfile installs
    # and verifies it, but no consumer script invokes it directly, so the
    # smoke test legitimately does not gate on it. This proves the exclusion
    # mechanism actually suppresses a would-be failure.
    write_dockerfile bash cargo git
    write_smoke bash cargo
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
}

@test "fails when the Dockerfile verifies 'docker buildx version' but the smoke test does not (the #791 shape)" {
    # docker buildx is a subcommand capability, not a required_tools entry,
    # so the array comparison cannot see it -- the dedicated special-
    # capability check must catch it. Reproduces exactly what #791 asked for.
    write_dockerfile bash cargo
    NO_BUILDX=1 write_smoke bash cargo
    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"docker buildx version"* ]]
}

@test "fails closed when the Dockerfile has no required_tools array to parse" {
    # A refactor that renames/removes the array must not make this guard
    # silently pass on an empty set (Rule-Ref: AG-VAL-002 -- empty required
    # output is a hard failure), which would let real drift through unseen.
    write_dockerfile_no_array
    write_smoke bash cargo
    run bash "$script" "$fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not extract"* ]]
}

@test "the real repository's smoke test and Dockerfile are consistent" {
    # Defense-in-depth self-check: the shipped select-build-tools-image.sh
    # smoke list and tools/build-tools/Dockerfile verification list must
    # actually satisfy this guard, so a future edit to either that breaks the
    # invariant is caught by this suite too, not only by the CI guard step.
    run bash "$script" "$repo_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

# --- scripts/lib/verify-version-banner.sh -----------------------------------
#
# What: coverage for the shared version-banner smoke check.
# Why: colocated here per maintainer decision (AG-CODE-013).
# From: Issue #1613 | Issue #1781 | PR #1783

@test "verify-version-banner.sh passes when the tool's output contains the expected banner" {
    run sh "$repo_root/scripts/lib/verify-version-banner.sh" "hello banner" printf "hello banner\n"
    [ "$status" -eq 0 ]
}

@test "verify-version-banner.sh fails when the tool's output lacks the expected banner" {
    run sh "$repo_root/scripts/lib/verify-version-banner.sh" "hello banner" printf "goodnight\n"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR"* ]]
    [[ "$output" == *"goodnight"* ]]
}

@test "verify-version-banner.sh ignores the checked tool's own exit code (the lsof -v convention)" {
    # What: fixture tool prints the banner, exits non-zero.
    # Why: lsof's -v exit code is unreliable; banner text decides.
    # From: Issue #1613
    fixture_bin="$BATS_TEST_TMPDIR/fake-lsof"
    {
        printf '#!/bin/sh\n'
        printf "printf 'lsof version information: fake\\\\n'\n"
        printf 'exit 1\n'
    } > "$fixture_bin"
    chmod +x "$fixture_bin"
    run sh "$repo_root/scripts/lib/verify-version-banner.sh" "lsof version information" "$fixture_bin" -v
    [ "$status" -eq 0 ]
}

@test "verify-version-banner.sh fails closed when called with fewer than 2 arguments" {
    run sh "$repo_root/scripts/lib/verify-version-banner.sh" "only-one-arg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage:"* ]]
}

@test "the shared verify-version-banner.sh file itself exists in its new scripts/lib home" {
    [ -f "$repo_root/scripts/lib/verify-version-banner.sh" ]
}

@test "each of the six lsof-copying consumers invokes the shared verify-version-banner.sh via the shared-scripts build context, not an inline banner check" {
    for f in dhcp-proxy dhcp dns proxy ui watchdog; do
        consumer_dockerfile="$repo_root/services/$f/Dockerfile"
        grep -qF 'COPY --from=shared-scripts verify-version-banner.sh /usr/local/bin/verify-version-banner.sh' "$consumer_dockerfile" \
            || fail "services/$f/Dockerfile does not COPY the shared verify-version-banner.sh from the shared-scripts build context"
        grep -qF 'sh /usr/local/bin/verify-version-banner.sh "lsof version information" lsof -v' "$consumer_dockerfile" \
            || fail "services/$f/Dockerfile does not invoke the shared lsof banner check"
        ! grep -qF 'lsof_out="$(lsof -v 2>&1)"' "$consumer_dockerfile" \
            || fail "services/$f/Dockerfile still has the old inline lsof banner check"
        ! grep -qF 'utilities-tools' "$consumer_dockerfile" \
            || fail "services/$f/Dockerfile still references the removed utilities-tools stage"
    done
}
