#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: coverage for services/utilities/verify-version-banner.sh (the shared
# copied-tool smoke check) plus the six migrated Dockerfiles' real usage of it.
# Why: AG-CODE-013 search found no existing file owning this conceptual class
# -- services/utilities/ had zero test coverage before this script existed,
# and no sibling bats file tests Dockerfile-copied-tool smoke checks for any
# of the six migrated services -- so this is the first, not an added, file
# for that responsibility (issue #1613 review, lsof-block dedup thread).
# From: Issue #1613

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/services/utilities/verify-version-banner.sh"
}

# --- Script logic (fixture binaries, no real repo state needed) ------------

@test "passes when the tool's output contains the expected banner" {
    run sh "$script" "hello banner" printf "hello banner\n"
    [ "$status" -eq 0 ]
}

@test "fails when the tool's output lacks the expected banner" {
    run sh "$script" "hello banner" printf "goodnight\n"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR"* ]]
    [[ "$output" == *"goodnight"* ]]
}

@test "ignores the checked tool's own exit code (the lsof -v convention)" {
    # What: a fixture 'tool' that prints the banner but exits non-zero.
    # Why: reproduces lsof's own unreliable -v exit-code contract (PR #1613,
    #   commit b832d0dc) -- the banner text alone must decide pass/fail.
    fixture_bin="$BATS_TEST_TMPDIR/fake-lsof"
    {
        printf '#!/bin/sh\n'
        printf "printf 'lsof version information: fake\\\\n'\n"
        printf 'exit 1\n'
    } > "$fixture_bin"
    chmod +x "$fixture_bin"
    run sh "$script" "lsof version information" "$fixture_bin" -v
    [ "$status" -eq 0 ]
}

@test "fails closed when called with fewer than 2 arguments" {
    run sh "$script" "only-one-arg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage:"* ]]
}

# --- Real repository wiring: the six migrated Dockerfiles -------------------

@test "the utilities image itself ships and COPYs the script into the final stage" {
    grep -qF 'COPY verify-version-banner.sh /usr/local/bin/verify-version-banner.sh' \
        "$repo_root/services/utilities/Dockerfile"
}

@test "each of the five lsof-copying consumers invokes the shared script, not an inline banner check" {
    for f in dhcp-proxy dhcp dns proxy ui; do
        dockerfile="$repo_root/services/$f/Dockerfile"
        grep -qF 'COPY --from=utilities-tools /usr/local/bin/verify-version-banner.sh /usr/local/bin/verify-version-banner.sh' "$dockerfile" \
            || fail "services/$f/Dockerfile does not COPY the shared verify-version-banner.sh"
        grep -qF 'sh /usr/local/bin/verify-version-banner.sh "lsof version information" lsof -v' "$dockerfile" \
            || fail "services/$f/Dockerfile does not invoke the shared lsof banner check"
        ! grep -qF 'lsof_out="$(lsof -v 2>&1)"' "$dockerfile" \
            || fail "services/$f/Dockerfile still has the old inline lsof banner check"
    done
}

fail() {
    echo "$1" >&2
    return 1
}
