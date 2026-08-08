#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/check-pipefail-early-exit-grep.sh (AG-VAL-029 standing
# check for the confirmed real CI failure on issue #815's PR #1374, job
# 91393831566: `rustup target list --installed | grep -qx ...` /
# `rustc -vV | grep -qE ...` failed with exit 141/SIGPIPE under
# `set -euo pipefail`, because `grep -q` exits as soon as it finds a match,
# closing the pipe while the producer may still be writing).
#
# The guard's own `scan_files` is repo-wide (`git ls-files` over
# scripts/**, tools/**, setup.sh, per issue #1377's audit widening it past
# PR #1374's original tools/build-tools/Dockerfile-only scope), so each
# fixture here is its own minimal git repository (`git init` + `git add`)
# rather than a bare directory -- `git ls-files` only sees tracked files
# inside a real working tree, and a fixture that is never `git add`-ed
# would silently be invisible to the guard, making every "fails on ..."
# test below a false negative instead of exercising the real code path.
#
# The guard is invoked as `bash "$script"` per Rule-Ref: AG-VAL-024.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-pipefail-early-exit-grep.sh"
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    fixture="$BATS_TEST_TMPDIR/fx"
    mkdir -p "$fixture/tools/build-tools"
    git -C "$fixture" init -q
    # A fixture-local identity: this repo's own real git config (name/email,
    # signing) must never leak into a throwaway test repository.
    git -C "$fixture" -c user.email="test@example.invalid" -c user.name="test" \
        commit -q --allow-empty -m "empty root commit"
}

# fixture_add: stage and commit every file currently under $fixture, so
# `git ls-files` (what the real guard uses to discover scan_files) actually
# sees it.
fixture_add() {
    git -C "$fixture" add -A
    git -C "$fixture" -c user.email="test@example.invalid" -c user.name="test" \
        commit -q -m "fixture update"
}

# write_dockerfile <line>...
# Writes a fixture Dockerfile with a pipefail RUN step containing the given
# extra lines verbatim (one per argument, each terminated with '; \'), then
# commits it into the fixture repo so `git ls-files` picks it up.
write_dockerfile() {
    {
        printf 'FROM scratch\n'
        printf 'RUN set -euo pipefail; \\\n'
        local line
        for line in "$@"; do
            printf '    %s; \\\n' "$line"
        done
        printf '    true\n'
    } > "$fixture/tools/build-tools/Dockerfile"
    fixture_add
}

# write_script <relative-path> <line>...
# Writes a fixture scripts/**-style shell file with a pipefail preamble
# containing the given extra lines verbatim, then commits it.
write_script() {
    local rel="$1"
    shift
    mkdir -p "$(dirname "$fixture/$rel")"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        local line
        for line in "$@"; do
            printf '%s\n' "$line"
        done
    } > "$fixture/$rel"
    fixture_add
}

@test "passes on a Dockerfile with no pipefail usage at all" {
    printf 'FROM scratch\nRUN rustc -vV | grep -qE "host"\n' > "$fixture/tools/build-tools/Dockerfile"
    fixture_add
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "passes on a pipefail Dockerfile using the capture-into-variable pattern" {
    write_dockerfile \
        'installed_targets="$(rustup target list --installed)"' \
        'grep -qx "x86_64-unknown-linux-musl" <<<"${installed_targets}"' \
        'rustc_host_line="$(rustc -vV)"' \
        'grep -qE "^host: .*-gnu\$" <<<"${rustc_host_line}"'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails on the exact real-incident pattern: grep -qx piped from a live producer under pipefail" {
    write_dockerfile 'rustup target list --installed | grep -qx "x86_64-unknown-linux-musl"'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"pipes a live command into an early-exiting consumer"* ]]
}

@test "fails on grep -qE piped from a live producer under pipefail" {
    write_dockerfile 'rustc -vV | grep -qE "^host: .*-gnu\$"'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"grep -qE"* ]] || [[ "$output" == *"early-exiting consumer"* ]]
}

@test "fails on a live pipe into head" {
    write_dockerfile 'some_command | head -n1'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "fails on a live pipe into sed -n" {
    write_dockerfile "some_command | sed -n '1p'"
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "does not flag grep -F reading a file argument (not a live pipe)" {
    write_dockerfile 'grep -F "some-token" "some-file" >/dev/null'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "does not self-trigger on a comment line quoting the dangerous pattern as prose" {
    {
        printf 'FROM scratch\n'
        printf '# This RUN previously used `producer | grep -q pattern` and failed.\n'
        printf 'RUN set -euo pipefail; true\n'
    } > "$fixture/tools/build-tools/Dockerfile"
    fixture_add
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "an inline trailing comment on a real bad line does not suppress the finding" {
    write_dockerfile 'rustup target list --installed | grep -qx "x86_64-unknown-linux-musl" # some unrelated comment'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "a line marked pipefail-safe is not flagged" {
    write_dockerfile 'rustup target list --installed | grep -qx "x86_64-unknown-linux-musl" # pipefail-safe: reviewed, output is a single short line'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

# --- Repo-wide scope coverage (issue #1377) -------------------------------
# The tests above only ever wrote into tools/build-tools/Dockerfile, which
# would still pass even if scan_files had silently stayed hardcoded to that
# one path -- these prove the widened scan_files genuinely reaches a
# scripts/**-style file too, not just the original Dockerfile.

@test "fails on the exact real-incident shape reproduced in a scripts/**-style file" {
    write_script "scripts/example-check.sh" \
        'result="$(some_producer_command)"' \
        'if some_other_producer | grep -q "needle"; then' \
        '  echo found' \
        'fi'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"scripts/example-check.sh"* ]]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "passes on a scripts/**-style file using the capture-into-here-string pattern" {
    write_script "scripts/example-check.sh" \
        'producer_output="$(some_producer_command)"' \
        'if grep -q "needle" <<<"$producer_output"; then' \
        '  echo found' \
        'fi'
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails on the same pattern in a scripts/lib/**-style file" {
    write_script "scripts/lib/example-lib.sh" \
        'if docker logs some_container 2>&1 | grep -q "ready"; then' \
        '  echo ready' \
        'fi'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"scripts/lib/example-lib.sh"* ]]
}

@test "fails on the same pattern in a setup.sh-style file at the fixture root" {
    write_script "setup.sh" \
        'if some_producer | head -1 | grep -q "x"; then' \
        '  echo yes' \
        'fi'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"setup.sh"* ]]
}

@test "fails on the same pattern in a services/**-style entrypoint file" {
    # Pins the services/** pathspec itself: this is the exact class of real
    # bug found in services/dns/entrypoint.sh (a set -e script silently
    # dying on an unguarded printf | grep -qi). Without this fixture, an
    # accidental narrowing of scan_files that dropped 'services/*.sh'
    # 'services/**/*.sh' would leave the whole suite green.
    write_script "services/example-service/entrypoint.sh" \
        'if printf "%s" "$captured_value" | grep -qi "needle"; then' \
        '  echo found' \
        'fi'
    run bash "$script" "$fixture"
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/example-service/entrypoint.sh"* ]]
    [[ "$output" == *"early-exiting consumer"* ]]
}

@test "an untracked scripts/**-style file (never git add-ed) is invisible to the guard" {
    # Documents scan_files' own real discovery mechanism (git ls-files): a
    # file that exists on disk but was never committed to the fixture repo
    # is not part of the scan, the same way a real untracked scratch file
    # in the actual repository would not be scanned either.
    mkdir -p "$fixture/scripts"
    printf '#!/usr/bin/env bash\nset -euo pipefail\nsome_producer | grep -q "needle"\n' \
        > "$fixture/scripts/untracked-check.sh"
    run bash "$script" "$fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails closed (does not silently report OK) when pointed at a directory that is not a git work tree" {
    # A naive `mapfile -t scan_files < <(git ls-files ...)` would not
    # propagate the process substitution's own failure -- a broken
    # discovery (no .git here, or git itself missing) would otherwise
    # silently leave scan_files empty, the scan loop would iterate zero
    # times, and the script would report a false "OK" with exit 0. The
    # real script instead captures `git ls-files`'s own exit status
    # explicitly first. A non-git directory is the simplest real
    # reproduction of that failure mode (advisor review, issue #1377).
    non_git="$BATS_TEST_TMPDIR/not-a-git-repo"
    mkdir -p "$non_git/scripts"
    printf '#!/usr/bin/env bash\nset -euo pipefail\nsome_producer | grep -q "needle"\n' \
        > "$non_git/scripts/some-check.sh"
    run bash "$script" "$non_git"
    [ "$status" -ne 0 ]
    [[ "$output" != *"OK"* ]]
    [[ "$output" == *"git ls-files\` itself failed"* ]]
}

@test "the real repository passes this guard repo-wide (scripts/**, tools/**, setup.sh)" {
    # Defense-in-depth self-check: every file the real, repo-wide scan_files
    # discovers today must actually satisfy this guard, so a future edit
    # that reintroduces the incident pattern anywhere in scope is caught by
    # this suite too, not only by the CI guard step.
    run bash "$script" "$repo_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
