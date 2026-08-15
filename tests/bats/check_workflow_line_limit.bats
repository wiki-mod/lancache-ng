#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Exercises scripts/check-workflow-line-limit.sh (issue #1095, 2026-08-01;
# per-run:-block coverage added for issue #1535, 2026-08-15) against small,
# throwaway .github/workflows fixture trees rather than this repo's own real
# build-push.yml, so both the passing and failing path are proven -- per
# AG-VAL-024, a check that only ever runs against an already-green tree never
# actually proves its fail-closed path is reachable.

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

# write_run_block_line <path> <indent> <total_line_bytes>: appends one
# content line to an already-started run: block, with exactly <indent> real
# leading spaces (the structural indentation the byte-walk relies on to find
# the block's end) followed by padding so the whole line, including its
# trailing newline, is exactly <total_line_bytes> long.
write_run_block_line() {
    local path="$1" indent="$2" total_line_bytes="$3" content_bytes
    content_bytes=$((total_line_bytes - indent - 1))
    {
        printf '%*s' "$indent" ''
        printf '#%*s' "$((content_bytes - 1))" '' | tr ' ' 'x'
        printf '\n'
    } >> "$path"
}

# write_workflow_with_run_block <path> <scalar> <block_indent> <block_bytes>:
# a minimal workflow with one job/step whose run: value is a YAML block
# scalar (<scalar>, e.g. "|" or ">-") with a single padded content line
# totaling exactly <block_bytes> raw bytes (indentation included), followed
# by an unrelated plain one-line run: step so a real "does the block end
# where it should" boundary exists in every fixture, not just EOF.
write_workflow_with_run_block() {
    local path="$1" scalar="$2" block_indent="$3" block_bytes="$4"
    mkdir -p "$(dirname "$path")"
    {
        echo "on: push"
        echo "jobs:"
        echo "  test:"
        echo "    steps:"
        echo "      - name: big step"
        echo "        run: $scalar"
    } > "$path"
    write_run_block_line "$path" "$block_indent" "$block_bytes"
    {
        echo "      - name: after"
        echo "        run: echo done"
    } >> "$path"
}

@test "passes when every workflow file is under all three limits" {
    write_lines "$fixture_root/.github/workflows/a.yml" 50
    write_lines "$fixture_root/.github/workflows/b.yml" 99

    MAX_WORKFLOW_LINES=100 MAX_WORKFLOW_BYTES=100000 MAX_RUN_BLOCK_BYTES=1000 run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"within the 100-line, 100000-byte, and 1000-byte-per-run-block hard limits"* ]] || fail "unexpected output: $output"
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

@test "passes when a run: block is under the per-block byte limit" {
    write_workflow_with_run_block "$fixture_root/.github/workflows/a.yml" "|" 10 150

    MAX_RUN_BLOCK_BYTES=200 run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"per-run-block hard limits"* ]] || fail "unexpected output: $output"
}

@test "fails and names the offending run: block when over the per-block byte limit" {
    write_workflow_with_run_block "$fixture_root/.github/workflows/too-wide.yml" "|" 10 300

    MAX_RUN_BLOCK_BYTES=200 run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"run: block(s) over the 200-byte hard limit"* ]] || fail "did not report the run-block violation: $output"
    [[ "$output" == *"too-wide.yml"* ]] || fail "did not name the offending file: $output"
    [[ "$output" == *"block starting at line"* ]] || fail "did not name the offending block's start line: $output"
}

@test "MAX_RUN_BLOCK_BYTES is independently overridable via environment" {
    write_workflow_with_run_block "$fixture_root/.github/workflows/a.yml" "|" 10 150

    MAX_RUN_BLOCK_BYTES=100 run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"a.yml"* ]] || fail "did not respect the overridden run-block threshold: $output"
}

@test "detects an oversized folded (>-) block scalar the same as a literal (|) one" {
    write_workflow_with_run_block "$fixture_root/.github/workflows/folded.yml" ">-" 10 300

    MAX_RUN_BLOCK_BYTES=200 run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"folded.yml"* ]] || fail "did not detect the oversized >- block: $output"
}

@test "does not flag a plain single-line run: value, however long" {
    {
        echo "on: push"
        echo "jobs:"
        echo "  test:"
        echo "    steps:"
        echo "      - name: long one-liner"
    } > "$fixture_root/.github/workflows/a.yml"
    printf '        run: %*s\n' 250 '' | tr ' ' 'x' >> "$fixture_root/.github/workflows/a.yml"

    MAX_RUN_BLOCK_BYTES=200 run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ] || fail "a plain (non-block-scalar) run: line must not be measured as a run: block: $output"
}

@test "measures multiple run: blocks in one file independently, not as one combined total" {
    write_workflow_with_run_block "$fixture_root/.github/workflows/a.yml" "|" 10 120
    {
        echo "      - name: second big step"
        echo "        run: |"
    } >> "$fixture_root/.github/workflows/a.yml"
    write_run_block_line "$fixture_root/.github/workflows/a.yml" 10 120
    echo "      - name: after second" >> "$fixture_root/.github/workflows/a.yml"

    # Each block is 120 bytes (under a 150-byte per-block limit) even though
    # their combined total (240 bytes) would exceed it -- proves the two
    # blocks are measured and compared independently, not summed.
    MAX_RUN_BLOCK_BYTES=150 run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ] || fail "two under-limit run: blocks in one file must not be summed together: $output"
}

@test "passes when pointed at this repository's own real .github/workflows directory" {
    run bash "$script" "$repo_root"
    [ "$status" -eq 0 ] || fail "real repo .github/workflows/*.yml files must stay under all three current limits (see issue #1535 / PR #1572): $output"
}
