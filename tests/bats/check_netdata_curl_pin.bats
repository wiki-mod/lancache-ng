#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: coverage for scripts/untracked/check-netdata-curl-pin.sh's version-parsing,
# comparison, and grace-period logic.
# Why: all tests run offline via the script's own
# BUNDLED_PACKAGES_CONTENT_FILE test hook, no real network needed.
# From: Issue #1304 | PR #1352

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/untracked/check-netdata-curl-pin.sh"
    dockerfile_fixture="$BATS_TEST_TMPDIR/Dockerfile"
    bundled_fixture="$BATS_TEST_TMPDIR/bundled-packages.version"
}

write_dockerfile_fixture() {
    local version="$1"
    cat > "$dockerfile_fixture" <<EOF
FROM mirror.gcr.io/library/alpine:3.24@sha256:deadbeef
ARG NETDATA_VERSION=${version}
ARG NETDATA_X86_64_SHA256=deadbeef
EOF
}

write_bundled_fixture() {
    local curl_tag="$1"
    cat > "$bundled_fixture" <<EOF
PACKAGES=("OPENSSL" "CURL" "BASH" "IOPING" "LIBNETFILTER_ACT")
CURL_VERSION="curl-${curl_tag}"
CURL_SOURCE="https://github.com/curl/curl"
EOF
}

# --- extract_netdata_version -------------------------------------------------

@test "extract_netdata_version parses a real ARG NETDATA_VERSION= line" {
    write_dockerfile_fixture "v2.10.4"
    run bash -c "source '$script'; extract_netdata_version '$dockerfile_fixture'"
    [ "$status" -eq 0 ]
    [ "$output" = "v2.10.4" ]
}

@test "extract_netdata_version fails closed when the ARG line is missing" {
    printf 'FROM alpine:3.24\n' > "$dockerfile_fixture"
    run bash -c "source '$script'; extract_netdata_version '$dockerfile_fixture'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not find"* ]]
}

# --- extract_curl_version_tag ------------------------------------------------

@test "extract_curl_version_tag converts netdata's underscore tag to a dotted version" {
    write_bundled_fixture "8_17_0"
    run bash -c "source '$script'; extract_curl_version_tag \"\$(cat '$bundled_fixture')\""
    [ "$status" -eq 0 ]
    [ "$output" = "8.17.0" ]
}

@test "extract_curl_version_tag fails closed on unparseable content" {
    run bash -c "source '$script'; extract_curl_version_tag 'no curl line here at all'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not find"* ]]
}

# --- version_ge ---------------------------------------------------------------

@test "version_ge: below threshold is false (the real vulnerable case, curl 8.17.0 vs 8.21.0)" {
    run bash -c "source '$script'; version_ge '8.17.0' '8.21.0'"
    [ "$status" -ne 0 ]
}

@test "version_ge: exactly at threshold is true" {
    run bash -c "source '$script'; version_ge '8.21.0' '8.21.0'"
    [ "$status" -eq 0 ]
}

@test "version_ge: above threshold is true" {
    run bash -c "source '$script'; version_ge '8.25.3' '8.21.0'"
    [ "$status" -eq 0 ]
}

@test "version_ge: differing segment counts compare correctly (9.0 vs 8.21.0)" {
    run bash -c "source '$script'; version_ge '9.0' '8.21.0'"
    [ "$status" -eq 0 ]
}

# --- main(): end-to-end via the BUNDLED_PACKAGES_CONTENT_FILE test hook -----
#
# What: tests below use NETDATA_CURL_PIN_TODAY to exercise both sides of
# the ACCEPTED_UNTIL grace-period boundary deterministically.
# Why: avoids depending on (or waiting for) the real wall-clock date.
# From: Issue #1304 | PR #1352

@test "main: a still-vulnerable pinned curl version WARNS (non-blocking) before the grace-period deadline" {
    write_dockerfile_fixture "v2.10.4"
    write_bundled_fixture "8_17_0"
    BUNDLED_PACKAGES_CONTENT_FILE="$bundled_fixture" NETDATA_CURL_PIN_TODAY="2026-08-01" \
        run bash "$script" "$dockerfile_fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"* ]]
    [[ "$output" == *"CVE-2026-12064"* ]]
    [[ "$output" == *"CVE-2026-9545"* ]]
    [[ "$output" == *"BELOW the 8.21.0"* ]]
    [[ "$output" == *"time-boxed acceptance"* ]]
}

@test "main: a still-vulnerable pinned curl version FAILS (blocking) once the grace-period deadline has passed" {
    write_dockerfile_fixture "v2.10.4"
    write_bundled_fixture "8_17_0"
    BUNDLED_PACKAGES_CONTENT_FILE="$bundled_fixture" NETDATA_CURL_PIN_TODAY="2031-01-01" \
        run bash "$script" "$dockerfile_fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"* ]]
    [[ "$output" == *"CVE-2026-12064"* ]]
    [[ "$output" == *"CVE-2026-9545"* ]]
    [[ "$output" == *"grace period"*"PASSED"* ]]
}

@test "main: exactly on the grace-period deadline still WARNS, not fails (deadline is inclusive)" {
    write_dockerfile_fixture "v2.10.4"
    write_bundled_fixture "8_17_0"
    BUNDLED_PACKAGES_CONTENT_FILE="$bundled_fixture" NETDATA_CURL_PIN_TODAY="2030-12-31" \
        run bash "$script" "$dockerfile_fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"* ]]
}

@test "main: a patched pinned curl version (>= 8.21.0) passes cleanly regardless of date" {
    write_dockerfile_fixture "v2.99.0"
    write_bundled_fixture "8_21_0"
    BUNDLED_PACKAGES_CONTENT_FILE="$bundled_fixture" NETDATA_CURL_PIN_TODAY="2027-01-01" \
        run bash "$script" "$dockerfile_fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
    [[ "$output" != *"::warning::"* ]]
}

@test "main: a curl version well past the threshold also passes" {
    write_dockerfile_fixture "v2.99.0"
    write_bundled_fixture "9_2_1"
    BUNDLED_PACKAGES_CONTENT_FILE="$bundled_fixture" run bash "$script" "$dockerfile_fixture"
    [ "$status" -eq 0 ]
}

@test "main: the real services/netdata/Dockerfile currently pins a still-affected curl (documents current, known state)" {
    # What: reads the real Dockerfile, and the real v2.11.0 vendored curl tag.
    # Why: proves the check's current warn behavior against this project's
    # actual real pin, not a stale/unrelated synthetic fixture value.
    # From: Issue #1304 | PR #1662
    real_dockerfile="$BATS_TEST_DIRNAME/../../services/netdata/Dockerfile"
    write_bundled_fixture "8_20_0"
    BUNDLED_PACKAGES_CONTENT_FILE="$bundled_fixture" run bash "$script" "$real_dockerfile"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"* ]]
}

@test "main: the real services/netdata/Dockerfile's pin would hard-fail once the grace period passes" {
    # What: same real Dockerfile+curl tag as above, date hook past ACCEPTED_UNTIL.
    # Why: proves the escalation-to-failure branch actually triggers against
    # this project's real current pin, not a stale/unrelated fixture value.
    # From: Issue #1304 | PR #1662
    real_dockerfile="$BATS_TEST_DIRNAME/../../services/netdata/Dockerfile"
    write_bundled_fixture "8_20_0"
    BUNDLED_PACKAGES_CONTENT_FILE="$bundled_fixture" NETDATA_CURL_PIN_TODAY="2031-01-01" \
        run bash "$script" "$real_dockerfile"
    [ "$status" -ne 0 ]
}
