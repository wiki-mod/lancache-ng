#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Docker-free, network-free unit coverage for
# scripts/untracked/merge-utilities-sbom-components.sh: asserts the
# per-service utilities-package allowlist filters out packages a given
# service's Dockerfile does not COPY, and that allowed packages plus the
# service's own components still merge/dedupe correctly. Fixture CycloneDX
# documents below mirror real Trivy output shape (bare apk package names
# in `components[].name`).

# Required for `run !` (used below to correctly fail a test on a negated
# assertion, see the SC2314 comment inline) -- same requirement as
# dns_zone_generation.bats.
bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/untracked/merge-utilities-sbom-components.sh"
    workdir="$(mktemp -d)"

    cat >"$workdir/service.cdx.json" <<'EOF'
{
  "bomFormat": "CycloneDX",
  "components": [
    {"name": "svc-own-pkg", "type": "library", "purl": "pkg:apk/alpine/svc-own-pkg@1.0-r0"}
  ]
}
EOF

    # Mirrors the real utilities image's full apk package set: some packages
    # every consumer that copies from utilities-tools should keep (ripgrep,
    # lsof, libgcc, pcre2), some only specific services copy (findutils,
    # gettext-envsubst, libintl), curl's own 12-package apk dependency set
    # (Issue #1781 -- confirmed live via `apk info --who-owns` against a
    # real alpine:3.24 + apk add curl), and some no consumer ever copies at
    # all (nano, coreutils) -- the over-reporting bug this script fixes.
    cat >"$workdir/utilities.cdx.json" <<'EOF'
{
  "bomFormat": "CycloneDX",
  "components": [
    {"name": "ripgrep", "type": "library", "purl": "pkg:apk/alpine/ripgrep@15.1.0-r0"},
    {"name": "lsof", "type": "library", "purl": "pkg:apk/alpine/lsof@4.99.6-r0"},
    {"name": "libgcc", "type": "library", "purl": "pkg:apk/alpine/libgcc@15.2.0-r5"},
    {"name": "pcre2", "type": "library", "purl": "pkg:apk/alpine/pcre2@10.47-r1"},
    {"name": "findutils", "type": "library", "purl": "pkg:apk/alpine/findutils@4.10.0-r1"},
    {"name": "gettext-envsubst", "type": "library", "purl": "pkg:apk/alpine/gettext-envsubst@1.0-r0"},
    {"name": "libintl", "type": "library", "purl": "pkg:apk/alpine/libintl@1.0-r0"},
    {"name": "curl", "type": "library", "purl": "pkg:apk/alpine/curl@8.21.0-r0"},
    {"name": "libcurl", "type": "library", "purl": "pkg:apk/alpine/libcurl@8.21.0-r0"},
    {"name": "zlib", "type": "library", "purl": "pkg:apk/alpine/zlib@1.3.2-r0"},
    {"name": "c-ares", "type": "library", "purl": "pkg:apk/alpine/c-ares@1.34.8-r0"},
    {"name": "nghttp2-libs", "type": "library", "purl": "pkg:apk/alpine/nghttp2-libs@1.69.0-r0"},
    {"name": "libidn2", "type": "library", "purl": "pkg:apk/alpine/libidn2@2.3.8-r0"},
    {"name": "libpsl", "type": "library", "purl": "pkg:apk/alpine/libpsl@0.21.5-r3"},
    {"name": "libssl3", "type": "library", "purl": "pkg:apk/alpine/libssl3@3.5.7-r0"},
    {"name": "libcrypto3", "type": "library", "purl": "pkg:apk/alpine/libcrypto3@3.5.7-r0"},
    {"name": "zstd-libs", "type": "library", "purl": "pkg:apk/alpine/zstd-libs@1.5.7-r2"},
    {"name": "brotli-libs", "type": "library", "purl": "pkg:apk/alpine/brotli-libs@1.2.0-r1"},
    {"name": "libunistring", "type": "library", "purl": "pkg:apk/alpine/libunistring@1.4.2-r0"},
    {"name": "nano", "type": "library", "purl": "pkg:apk/alpine/nano@8.5-r0"},
    {"name": "coreutils", "type": "library", "purl": "pkg:apk/alpine/coreutils@9.11-r0"}
  ]
}
EOF
}

curl_packages="curl libcurl zlib c-ares nghttp2-libs libidn2 libpsl libssl3 libcrypto3 zstd-libs brotli-libs libunistring"

teardown() {
    rm -rf "$workdir"
}

component_names() {
    jq -r '.components[].name' <<<"$1" | sort
}

@test "ui keeps lsof/ripgrep/libgcc/pcre2 plus curl's own package set from utilities" {
    run bash "$script" ui "$workdir/service.cdx.json" "$workdir/utilities.cdx.json"
    [ "$status" -eq 0 ]
    got="$(component_names "$output")"
    expected="lsof libgcc pcre2 ripgrep svc-own-pkg $curl_packages"
    [ "$got" = "$(tr ' ' '\n' <<<"$expected" | sort)" ]
}

@test "ntp keeps gettext-envsubst/libintl plus curl's own package set, drops lsof/ripgrep/findutils" {
    run bash "$script" ntp "$workdir/service.cdx.json" "$workdir/utilities.cdx.json"
    [ "$status" -eq 0 ]
    got="$(component_names "$output")"
    expected="gettext-envsubst libintl svc-own-pkg $curl_packages"
    [ "$got" = "$(tr ' ' '\n' <<<"$expected" | sort)" ]
}

@test "dhcp keeps the findutils/gettext-envsubst/libintl/lsof/ripgrep/libgcc/pcre2 set plus curl's own package set" {
    run bash "$script" dhcp "$workdir/service.cdx.json" "$workdir/utilities.cdx.json"
    [ "$status" -eq 0 ]
    got="$(component_names "$output")"
    expected="findutils gettext-envsubst libintl lsof ripgrep libgcc pcre2 svc-own-pkg $curl_packages"
    [ "$got" = "$(tr ' ' '\n' <<<"$expected" | sort)" ]
}

@test "dhcp-proxy keeps the same 7-package set as dhcp/dns/proxy but WITHOUT curl (never copies it)" {
    run bash "$script" dhcp-proxy "$workdir/service.cdx.json" "$workdir/utilities.cdx.json"
    [ "$status" -eq 0 ]
    merged_output="$output"
    got="$(component_names "$merged_output")"
    expected=$'findutils\ngettext-envsubst\nlibintl\nlsof\nripgrep\nlibgcc\npcre2\nsvc-own-pkg'
    [ "$got" = "$(sort <<<"$expected")" ]

    # SC2314: a bare `! cmd` mid-test never fails the test (see the fuller
    # explanation in dhcp_lease_flow_parsing.bats). `run !` (Bats >= 1.5.0)
    # makes Bats assert the wrapped command's exit status itself.
    run ! grep -q '"curl"' <<<"$merged_output"
    run ! grep -q '"libcurl"' <<<"$merged_output"
}

@test "nano and coreutils never survive the filter for any consumer service" {
    for svc in proxy dhcp dhcp-proxy dns ntp ui watchdog; do
        run bash "$script" "$svc" "$workdir/service.cdx.json" "$workdir/utilities.cdx.json"
        [ "$status" -eq 0 ]
        ! grep -q '"nano"' <<<"$output"
        ! grep -q '"coreutils"' <<<"$output"
    done
}

@test "the service's own component always survives regardless of allowlist" {
    run bash "$script" watchdog "$workdir/service.cdx.json" "$workdir/utilities.cdx.json"
    [ "$status" -eq 0 ]
    grep -q '"svc-own-pkg"' <<<"$output"
}

@test "unknown service exits non-zero instead of silently merging everything" {
    run bash "$script" not-a-real-service "$workdir/service.cdx.json" "$workdir/utilities.cdx.json"
    [ "$status" -ne 0 ]
}

@test "duplicate components between service and utilities SBOMs are deduped" {
    cat >"$workdir/service-with-dup.cdx.json" <<'EOF'
{
  "bomFormat": "CycloneDX",
  "components": [
    {"name": "svc-own-pkg", "type": "library", "purl": "pkg:apk/alpine/svc-own-pkg@1.0-r0"},
    {"name": "lsof", "type": "library", "purl": "pkg:apk/alpine/lsof@4.99.6-r0"}
  ]
}
EOF
    run bash "$script" ui "$workdir/service-with-dup.cdx.json" "$workdir/utilities.cdx.json"
    [ "$status" -eq 0 ]
    count="$(jq '[.components[] | select(.name == "lsof")] | length' <<<"$output")"
    [ "$count" -eq 1 ]
}

@test "missing input file fails closed with a clear error" {
    run bash "$script" ui "$workdir/does-not-exist.cdx.json" "$workdir/utilities.cdx.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing or empty"* ]]
}
