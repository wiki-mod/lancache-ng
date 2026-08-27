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
    # gettext-envsubst, libintl), and some no consumer ever copies at all
    # (nano, coreutils) -- the over-reporting bug this script fixes.
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
    {"name": "nano", "type": "library", "purl": "pkg:apk/alpine/nano@8.5-r0"},
    {"name": "coreutils", "type": "library", "purl": "pkg:apk/alpine/coreutils@9.11-r0"}
  ]
}
EOF
}

teardown() {
    rm -rf "$workdir"
}

component_names() {
    jq -r '.components[].name' <<<"$1" | sort
}

@test "ui keeps only lsof/ripgrep/libgcc/pcre2 from utilities, drops the rest" {
    run bash "$script" ui "$workdir/service.cdx.json" "$workdir/utilities.cdx.json"
    [ "$status" -eq 0 ]
    got="$(component_names "$output")"
    expected=$'lsof\nlibgcc\npcre2\nripgrep\nsvc-own-pkg'
    [ "$got" = "$(sort <<<"$expected")" ]
}

@test "ntp keeps only gettext-envsubst/libintl, drops lsof/ripgrep/findutils" {
    run bash "$script" ntp "$workdir/service.cdx.json" "$workdir/utilities.cdx.json"
    [ "$status" -eq 0 ]
    got="$(component_names "$output")"
    expected=$'gettext-envsubst\nlibintl\nsvc-own-pkg'
    [ "$got" = "$(sort <<<"$expected")" ]
}

@test "dhcp keeps the 7-package findutils/gettext-envsubst/libintl/lsof/ripgrep/libgcc/pcre2 set" {
    run bash "$script" dhcp "$workdir/service.cdx.json" "$workdir/utilities.cdx.json"
    [ "$status" -eq 0 ]
    got="$(component_names "$output")"
    expected=$'findutils\ngettext-envsubst\nlibintl\nlsof\nripgrep\nlibgcc\npcre2\nsvc-own-pkg'
    [ "$got" = "$(sort <<<"$expected")" ]
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
