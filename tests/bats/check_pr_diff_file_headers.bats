#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for scripts/untracked/check-pr-diff-file-headers.sh: exercises the real
# fetch + NUL-safe diff + check-file-headers.sh pipeline against a small,
# throwaway local git repo pair (a bare "origin" plus a working clone) --
# real git operations end to end, never mocked, since the exact bug classes
# this script guards against (a stripped-NUL command substitution, a
# process-substitution's invisible exit status) only reproduce under real
# git behavior, not a stubbed one.

bats_require_minimum_version 1.5.0

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/untracked/check-pr-diff-file-headers.sh"
    check_file_headers_script="$BATS_TEST_DIRNAME/../../scripts/untracked/check-file-headers.sh"
    fixture_root="$(mktemp -d)"
    origin_dir="$fixture_root/origin.git"
    work_dir="$fixture_root/work"

    git init --quiet --bare "$origin_dir"

    git init --quiet -b main "$work_dir"
    # A stand-in for the real script this repo's own scripts/untracked/
    # directory points at, so check-pr-diff-file-headers.sh's own
    # `bash "$script_dir/check-file-headers.sh"` call resolves to something
    # real without needing the actual repo's own scripts/ tree present in
    # this throwaway fixture.
    mkdir -p "$work_dir/scripts/tracked"
    cp "$check_file_headers_script" "$work_dir/scripts/untracked/check-file-headers.sh"
    cp "$script" "$work_dir/scripts/untracked/check-pr-diff-file-headers.sh"
    mkdir -p "$work_dir/scripts/lib"
    cp "$BATS_TEST_DIRNAME/../../scripts/lib/git-fetch-retry.sh" "$work_dir/scripts/lib/git-fetch-retry.sh"

    (
        cd "$work_dir" || exit 1
        git config user.email test@example.invalid
        git config user.name "Test"
        git remote add origin "$origin_dir"
        printf '#!/usr/bin/env bash\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\necho hi\n' > example.sh
        git add example.sh scripts
        git commit --quiet -m "base commit"
        git push --quiet origin main
    )
    base_sha="$(cd "$work_dir" && git rev-parse HEAD)"
}

teardown() {
    rm -rf "$fixture_root"
}

@test "passes silently when the diff is empty (base and head are the same commit)" {
    head_sha="$base_sha"
    run bash -c "cd '$work_dir' && SPDX_BASE_SHA='$base_sha' SPDX_BASE_REF=main GITHUB_SHA='$head_sha' bash scripts/untracked/check-pr-diff-file-headers.sh"
    [ "$status" -eq 0 ]
    # Not asserting fully empty output: `git fetch` itself prints an
    # informational "From ... -> FETCH_HEAD" line even for a real, expected,
    # no-op fetch of an already-present ref/SHA. The actual contract is "no
    # header-violation diagnostic," not total silence.
    [[ "$output" != *"Invalid repository file header layout"* ]]
}

@test "checks a real changed file and fails on one missing the required header" {
    (
        cd "$work_dir"
        printf 'echo no header at all\n' > bad.sh
        git add bad.sh
        git commit --quiet -m "add a file missing the header"
    )
    head_sha="$(cd "$work_dir" && git rev-parse HEAD)"
    run bash -c "cd '$work_dir' && SPDX_BASE_SHA='$base_sha' SPDX_BASE_REF=main GITHUB_SHA='$head_sha' bash scripts/untracked/check-pr-diff-file-headers.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"bad.sh"* ]]
    [[ "$output" == *"Invalid repository file header layout"* ]]
}

@test "passes on a real changed file that carries the canonical three-line header" {
    (
        cd "$work_dir"
        printf '#!/usr/bin/env bash\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\necho compliant\n' > good.sh
        git add good.sh
        git commit --quiet -m "add a compliant file"
    )
    head_sha="$(cd "$work_dir" && git rev-parse HEAD)"
    run bash -c "cd '$work_dir' && SPDX_BASE_SHA='$base_sha' SPDX_BASE_REF=main GITHUB_SHA='$head_sha' bash scripts/untracked/check-pr-diff-file-headers.sh"
    [ "$status" -eq 0 ]
}

@test "correctly captures and checks a changed file whose name Git C-quotes" {
    # `git diff --name-only`'s default output C-quotes an unusual pathname,
    # which `mapfile -t x < <(...)` would store as the literal quoted string
    # rather than the real path -- `-z` plus NUL-delimited reading must
    # produce the real, usable filename instead.
    (
        cd "$work_dir"
        quoted_name=$'file\twith-tab.sh'
        printf 'echo no header\n' > "$quoted_name"
        git add "$quoted_name"
        git commit --quiet -m "add a file with a tab in its name"
    )
    head_sha="$(cd "$work_dir" && git rev-parse HEAD)"
    run bash -c "cd '$work_dir' && SPDX_BASE_SHA='$base_sha' SPDX_BASE_REF=main GITHUB_SHA='$head_sha' bash scripts/untracked/check-pr-diff-file-headers.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *$'file\twith-tab.sh'* ]]
}

@test "fails closed when git diff itself fails after both reachability checks pass" {
    real_git="$(command -v git)"
    mkdir -p "$fixture_root/bin"
    cat > "$fixture_root/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\${1-}" = diff ]; then
    echo "synthetic git diff failure" >&2
    exit 73
fi
exec "$real_git" "\$@"
EOF
    chmod +x "$fixture_root/bin/git"
    run bash -c "cd '$work_dir' && PATH='$fixture_root/bin:$PATH' SPDX_BASE_SHA='$base_sha' SPDX_BASE_REF=main GITHUB_SHA='$base_sha' bash scripts/untracked/check-pr-diff-file-headers.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"git diff\` itself failed"* ]]
}

@test "fails closed with a clear diagnostic when a required environment variable is missing" {
    run bash -c "cd '$work_dir' && SPDX_BASE_REF=main GITHUB_SHA='$base_sha' bash scripts/untracked/check-pr-diff-file-headers.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"SPDX_BASE_SHA"* ]]
}
