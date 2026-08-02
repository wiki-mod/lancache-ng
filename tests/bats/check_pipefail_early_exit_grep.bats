#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/check-pipefail-early-exit-grep.sh (AG-VAL-029 standing
# check for the confirmed real CI failure on issue #815's PR #1374, job
# 91393831566: `rustup target list --installed | grep -qx ...` /
# `rustc -vV | grep -qE ...` failed with exit 141/SIGPIPE under
# `set -euo pipefail`, because `grep -q` exits as soon as it finds a match,
# closing the pipe while the producer may still be writing).
#
# Each scenario writes a minimal fixture tools/build-tools/Dockerfile under
# $BATS_TEST_TMPDIR and points the guard at it (deliberately narrow scope --
# see that script's own header comment for why it only scans this one file),
# so the suite runs fully offline and does not depend on the real
# Dockerfile's current contents, except the final self-consistency test.
# The guard is invoked as `bash "$script"` per Rule-Ref: AG-VAL-024.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-pipefail-early-exit-grep.sh"
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    fixture="$BATS_TEST_TMPDIR/fx"
    mkdir -p "$fixture/tools/build-tools"
}

# write_dockerfile <line>...
# Writes a fixture Dockerfile with a pipefail RUN step containing the given
# extra lines verbatim (one per argument, each terminated with '; \').
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
}

@test "passes on a Dockerfile with no pipefail usage at all" {
    printf 'FROM scratch\nRUN rustc -vV | grep -qE "host"\n' > "$fixture/tools/build-tools/Dockerfile"
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

@test "the real repository's tools/build-tools/Dockerfile passes this guard" {
    # Defense-in-depth self-check: the shipped Dockerfile must actually
    # satisfy this guard, so a future edit that reintroduces the incident
    # pattern is caught by this suite too, not only by the CI guard step.
    run bash "$script" "$repo_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
