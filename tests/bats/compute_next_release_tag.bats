#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Docker-free, git-free unit coverage for scripts/compute-next-release-tag.sh
# (#819): the pure patch-bump arithmetic the promote job's version-bump step
# relies on. No network/git dependency, so every boundary is pinned directly.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/compute-next-release-tag.sh"
}

@test "simple patch bump" {
    run bash "$script" "v0.2.3"
    [ "$status" -eq 0 ]
    [ "$output" = "v0.2.4" ]
}

@test "bump from zero patch" {
    run bash "$script" "v0.1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "v0.1.1" ]
}

@test "multi-digit patch component" {
    run bash "$script" "v1.4.99"
    [ "$status" -eq 0 ]
    [ "$output" = "v1.4.100" ]
}

@test "leading zero in patch is not misread as octal" {
    # 08/09 are invalid octal literals; a naive $((patch + 1)) without the
    # base-10 prefix would abort bash arithmetic expansion entirely on these.
    run bash "$script" "v0.2.08"
    [ "$status" -eq 0 ]
    [ "$output" = "v0.2.9" ]

    run bash "$script" "v0.2.09"
    [ "$status" -eq 0 ]
    [ "$output" = "v0.2.10" ]
}

@test "major/minor are preserved verbatim, not renormalized" {
    run bash "$script" "v10.20.3"
    [ "$status" -eq 0 ]
    [ "$output" = "v10.20.4" ]
}

@test "rejects a release candidate tag (not auto-bumpable)" {
    run bash "$script" "v0.2.3-rc.1"
    [ "$status" -ne 0 ]
}

@test "rejects a tag missing the v prefix" {
    run bash "$script" "0.2.3"
    [ "$status" -ne 0 ]
}

@test "rejects a two-component version" {
    run bash "$script" "v0.2"
    [ "$status" -ne 0 ]
}

@test "rejects empty input" {
    run bash "$script"
    [ "$status" -ne 0 ]
}

@test "rejects a non-numeric component" {
    run bash "$script" "v0.x.3"
    [ "$status" -ne 0 ]
}
