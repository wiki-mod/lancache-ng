#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/check-pipefail-scope-coverage.sh (issue #1510):
# verifies it correctly derives check-pipefail-early-exit-grep.sh's own
# scan_files prefixes and flags a bats file that doesn't exercise one of
# them. Each fixture recreates the exact directory shape the script under
# test expects at its (fixture-root)/scripts/check-pipefail-early-exit-grep.sh
# and (fixture-root)/tests/bats/check_pipefail_early_exit_grep.bats paths,
# using the script's own directory-argument override so no test here ever
# touches this repository's real guard script or its real bats file.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-pipefail-scope-coverage.sh"
    fixture="$BATS_TEST_TMPDIR/fx"
    mkdir -p "$fixture/scripts" "$fixture/tests/bats"
}

# write_guard: writes a stand-in check-pipefail-early-exit-grep.sh whose
# `git ls-files --` block always covers scripts/**, tools/**, setup.sh, plus
# any extra pathspec lines passed in (verbatim, already backslash-continued).
write_guard() {
    {
        printf '#!/usr/bin/env bash\n'
        printf 'if ! tracked_scan_files="$(git ls-files -- \\\n'
        printf "  'scripts/*.sh' 'scripts/**/*.sh' \\\\\n"
        printf "  'tools/*.sh' 'tools/**/*.sh' \\\\\n"
        local line
        for line in "$@"; do
            printf '%s\n' "$line"
        done
        printf "  'setup.sh')\"; then\n"
        printf '  exit 1\n'
        printf 'fi\n'
    } > "$fixture/scripts/check-pipefail-early-exit-grep.sh"
}

write_bats() {
    printf '%s\n' "$@" > "$fixture/tests/bats/check_pipefail_early_exit_grep.bats"
}

@test "passes when every derived prefix (scripts, tools, setup.sh) has a matching fixture" {
    write_guard
    write_bats \
        'write_script "scripts/example.sh"' \
        'write_dockerfile "tools/build-tools/Dockerfile"' \
        'write_script "setup.sh"'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails when a newly-widened scope prefix (services/) has no fixture -- the confirmed real gap" {
    write_guard "  'services/*.sh' 'services/**/*.sh' \\\\"
    write_bats \
        'write_script "scripts/example.sh"' \
        'write_dockerfile "tools/build-tools/Dockerfile"' \
        'write_script "setup.sh"'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/"* ]]
}

@test "passes once the services/ fixture is added alongside the widened scope" {
    write_guard "  'services/*.sh' 'services/**/*.sh' \\\\"
    write_bats \
        'write_script "scripts/example.sh"' \
        'write_dockerfile "tools/build-tools/Dockerfile"' \
        'write_script "setup.sh"' \
        'write_script "services/example-service/entrypoint.sh"'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "does not count a prefix only mentioned in a comment line as covered" {
    write_guard "  'services/*.sh' 'services/**/*.sh' \\\\"
    write_bats \
        '# services/ coverage is intentionally not implemented yet' \
        'write_script "scripts/example.sh"' \
        'write_dockerfile "tools/build-tools/Dockerfile"' \
        'write_script "setup.sh"'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/"* ]]
}

@test "fails closed when the guard script itself is missing from the given directory" {
    rm -f "$fixture/scripts/check-pipefail-early-exit-grep.sh"
    write_bats 'write_script "scripts/example.sh"'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}
