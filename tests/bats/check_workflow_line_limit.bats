#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Exercises scripts/check-workflow-line-limit.sh (issue #1095, 2026-08-01)
# against small, throwaway .github/workflows fixture trees rather than this
# repo's own real build-push.yml, so both the passing and failing path are
# proven -- per AG-VAL-024, a check that only ever runs against an
# already-green tree never actually proves its fail-closed path is reachable.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/check-workflow-line-limit.sh"
    fixture_root="$(mktemp -d)"
    mkdir -p "$fixture_root/.github/workflows"
}

teardown() {
    rm -rf "$fixture_root"
}

fail() {
    echo "$1" >&2
    return 1
}

write_lines() {
    local path="$1" count="$2"
    for ((i = 0; i < count; i++)); do
        echo "# line $i"
    done > "$path"
}

# write_bytes <path> <byte count>: a single long comment line (not many short
# ones) so line count stays trivially low while byte count hits the target --
# keeps the two dimensions independently testable.
write_bytes() {
    local path="$1" count="$2"
    printf '# %*s\n' "$((count - 3))" '' | tr ' ' 'x' > "$path"
}

@test "passes when every workflow file is under both limits" {
    write_lines "$fixture_root/.github/workflows/a.yml" 50
    write_lines "$fixture_root/.github/workflows/b.yml" 99

    MAX_WORKFLOW_LINES=100 MAX_WORKFLOW_BYTES=100000 run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"within the 100-line and 100000-byte hard limits"* ]] || fail "unexpected output: $output"
}

@test "fails and names the offending file(s) when over the line limit" {
    write_lines "$fixture_root/.github/workflows/a.yml" 50
    write_lines "$fixture_root/.github/workflows/too-big.yml" 150

    MAX_WORKFLOW_LINES=100 MAX_WORKFLOW_BYTES=100000 run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"line hard limit"* ]] || fail "did not report the line-limit violation: $output"
    [[ "$output" == *"too-big.yml"* ]] || fail "did not name the offending file: $output"
    [[ "$output" == *"a.yml"* ]] && fail "should not have flagged the file under the limit: $output"
    return 0
}

@test "fails and names the offending file(s) when over the byte limit, even with few lines" {
    write_lines "$fixture_root/.github/workflows/a.yml" 5
    write_bytes "$fixture_root/.github/workflows/too-heavy.yml" 500

    MAX_WORKFLOW_LINES=100 MAX_WORKFLOW_BYTES=200 run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"byte hard limit"* ]] || fail "did not report the byte-limit violation: $output"
    [[ "$output" == *"too-heavy.yml"* ]] || fail "did not name the offending file: $output"
    [[ "$output" == *"a.yml"* ]] && fail "should not have flagged the file under the limit: $output"
    return 0
}

@test "MAX_WORKFLOW_LINES and MAX_WORKFLOW_BYTES are independently overridable via environment" {
    write_lines "$fixture_root/.github/workflows/a.yml" 60

    MAX_WORKFLOW_LINES=50 MAX_WORKFLOW_BYTES=100000 run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"a.yml"* ]] || fail "did not respect the overridden line threshold: $output"
}
