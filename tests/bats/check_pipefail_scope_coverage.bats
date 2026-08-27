#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for scripts/untracked/check-pipefail-scope-coverage.sh: verifies it
# correctly derives check-pipefail-early-exit-grep.sh's own scan_files
# prefixes, independently enforces this project's own pinned minimum
# required scope, and flags a bats file that doesn't exercise one of the
# prefixes actually scanned. Each fixture recreates the exact directory
# shape the script under
# test expects at its (fixture-root)/scripts/tracked/check-pipefail-early-exit-grep.sh
# and (fixture-root)/tests/bats/check_pipefail_early_exit_grep.bats paths,
# using the script's own directory-argument override so no test here ever
# touches this repository's real guard script or its real bats file.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/untracked/check-pipefail-scope-coverage.sh"
    fixture="$BATS_TEST_TMPDIR/fx"
    mkdir -p "$fixture/scripts/untracked" "$fixture/tests/bats"
}

# write_guard: writes a stand-in check-pipefail-early-exit-grep.sh whose
# `git ls-files --` block always covers scripts/**, tools/**, setup.sh, plus
# any extra pathspec lines passed in (verbatim, already backslash-continued).
write_guard() {
    {
        printf '#!/usr/bin/env bash\n'
        printf 'if ! tracked_scan_files="$(git ls-files -- \\\n'
        printf "  'scripts/*.sh' 'scripts/**/*.sh' \\\\\n"
        printf "  'tools/*.sh' 'tools/**/*.sh' 'tools/*/Dockerfile*' \\\\\n"
        local line
        for line in "$@"; do
            printf '%s\n' "$line"
        done
        printf "  'setup.sh')\"; then\n"
        printf '  exit 1\n'
        printf 'fi\n'
    } > "$fixture/scripts/tracked/check-pipefail-early-exit-grep.sh"
}

write_bats() {
    printf '%s\n' "$@" > "$fixture/tests/bats/check_pipefail_early_exit_grep.bats"
}

@test "passes when every required prefix (scripts, tools, setup.sh, services) has a matching fixture" {
    write_guard "  'services/*.sh' 'services/**/*.sh' 'services/*/Dockerfile*' \\\\"
    write_bats \
        'write_script "scripts/example.sh"' \
        'write_dockerfile "tools/build-tools/Dockerfile"' \
        'write_script "setup.sh"' \
        'write_script "services/example-service/entrypoint.sh"' \
        'write_dockerfile "services/example-service/Dockerfile"'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails when the guard's own scope is missing a required prefix entirely -- not just uncovered by a fixture" {
    # REQUIRED_PREFIXES is pinned independently of the guard's own source
    # specifically so a guard that does not scan services/ at all fails
    # loudly instead of silently agreeing with whatever
    # the guard's own current text happens to say. A guard genuinely
    # missing a required prefix is a materially different, more serious
    # problem than merely lacking a bats fixture for a prefix it does
    # scan, so this must be a distinct error message, not conflated with
    # the "no fixture exercising" case below.
    write_guard
    write_bats \
        'write_script "scripts/example.sh"' \
        'write_dockerfile "tools/build-tools/Dockerfile"' \
        'write_script "setup.sh"'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no longer scans these required pathspec classes"* ]]
    [[ "$output" == *"services/"* ]]
}

@test "fails when a newly-widened scope prefix (services/) has no fixture -- the confirmed real gap" {
    write_guard "  'services/*.sh' 'services/**/*.sh' 'services/*/Dockerfile*' \\\\"
    write_bats \
        'write_script "scripts/example.sh"' \
        'write_dockerfile "tools/build-tools/Dockerfile"' \
        'write_script "setup.sh"'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/"* ]]
}

@test "passes once the services/ fixture is added alongside the widened scope" {
    write_guard "  'services/*.sh' 'services/**/*.sh' 'services/*/Dockerfile*' \\\\"
    write_bats \
        'write_script "scripts/example.sh"' \
        'write_dockerfile "tools/build-tools/Dockerfile"' \
        'write_script "setup.sh"' \
        'write_script "services/example-service/entrypoint.sh"' \
        'write_dockerfile "services/example-service/Dockerfile"'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "does not count a prefix only mentioned in a comment line as covered" {
    write_guard "  'services/*.sh' 'services/**/*.sh' 'services/*/Dockerfile*' \\\\"
    write_bats \
        '# services/ coverage is intentionally not implemented yet' \
        'write_script "scripts/example.sh"' \
        'write_dockerfile "tools/build-tools/Dockerfile"' \
        'write_script "setup.sh"'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/"* ]]
}

@test "reports missing prefixes (not a silent abort) when the bats file has only comment lines" {
    # `grep -v '^[[:space:]]*#' "$guard_bats"` exits 1 (not just empty
    # output) when every line matched the excluded comment pattern -- a
    # plain top-level `var=$(cmd)` assignment's failure aborts the whole
    # script under `set -e` before any of this check's own diagnostics can
    # run, silently exiting 1 with no explanation at all instead of the
    # real "missing scripts/, tools/, setup.sh, services/" report this test
    # asserts on.
    write_guard "  'services/*.sh' 'services/**/*.sh' 'services/*/Dockerfile*' \\\\"
    write_bats '# no real fixtures here, only this comment line'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no fixture exercising"* ]]
    [[ "$output" == *"scripts/"* ]]
}

@test "fails when service shell paths remain but the service Dockerfile class is removed" {
    write_guard "  'services/*.sh' 'services/**/*.sh' \\"
    write_bats \
        'write_script "scripts/example.sh"' \
        'write_dockerfile "tools/build-tools/Dockerfile"' \
        'write_script "setup.sh"' \
        'write_script "services/example-service/entrypoint.sh"' \
        'write_dockerfile "services/example-service/Dockerfile"'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/*/Dockerfile*"* ]]
}

@test "fails closed when the guard script itself is missing from the given directory" {
    rm -f "$fixture/scripts/tracked/check-pipefail-early-exit-grep.sh"
    write_bats 'write_script "scripts/example.sh"'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}
