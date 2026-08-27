#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: exercises scripts/tracked/check-workflow-line-limit.sh against throwaway
# .github/workflows fixture trees, both passing and failing paths.
# Why: AG-VAL-024 -- a check that only ever runs against an already-green
# tree never proves its fail-closed path is reachable.
# From: Issue #1095 | Issue #1535

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/tracked/check-workflow-line-limit.sh"
    fixture_root="$(mktemp -d)"
    mkdir -p "$fixture_root/.github/workflows"
}

teardown() {
    rm -rf "$fixture_root"
}

# What: prints a message to stderr, then returns non-zero.
# Why: gives a bats assertion failure a readable reason instead of a bare
# false-condition line number.
# From: Issue #1095
fail() {
    echo "$1" >&2
    return 1
}

# What: writes <count> numbered comment lines to a fixture file.
# Why: line-count-only fixture; the fixed "# line N" text keeps byte size
# incidental so the line dimension stays independently testable.
# From: Issue #1095
write_lines() {
    local path="$1" count="$2"
    for ((i = 0; i < count; i++)); do
        echo "# line $i"
    done > "$path"
}

# What: writes a single padded comment line totaling <count> bytes.
# Why: one long line (not many short ones) keeps line count trivially low
# while byte count hits the target, so the two dimensions stay independently
# testable.
# From: Issue #1095
write_bytes() {
    local path="$1" count="$2"
    printf '# %*s\n' "$((count - 3))" '' | tr ' ' 'x' > "$path"
}

# What: appends one padded content line to an already-started run: block.
# Why: exactly <indent> real leading spaces are needed for the byte-walk to
# find the block's end; padding hits the exact <total_line_bytes> target.
# From: Issue #1535
write_run_block_line() {
    local path="$1" indent="$2" total_line_bytes="$3" content_bytes
    content_bytes=$((total_line_bytes - indent - 1))
    {
        printf '%*s' "$indent" ''
        printf '#%*s' "$((content_bytes - 1))" '' | tr ' ' 'x'
        printf '\n'
    } >> "$path"
}

# What: writes a minimal workflow with one run: block scalar (<scalar>,
# e.g. "|" or ">-") totaling exactly <block_bytes>, plus a trailing plain
# run: step.
# Why: the trailing step gives every fixture a real "does the block end
# where it should" boundary, not just EOF.
# From: Issue #1535
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

# What: asserts a passing run when every file is under all three limits.
# Why: proves the non-failing path stays green after adding the third
# (run: block) dimension.
# From: Issue #1535
@test "passes when every workflow file is under all three limits" {
    write_lines "$fixture_root/.github/workflows/a.yml" 50
    write_lines "$fixture_root/.github/workflows/b.yml" 99

    MAX_WORKFLOW_LINES=100 MAX_WORKFLOW_BYTES=100000 MAX_RUN_BLOCK_BYTES=1000 run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"within the 100-line, 100000-byte, and 1000-byte-per-run-block hard limits"* ]] || fail "unexpected output: $output"
}

# What: asserts a red result names only the file over the line limit.
# Why: proves the fail-closed path is reachable and the offending file is
# identified, not just a generic failure.
# From: Issue #1095
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

# What: asserts the byte dimension fails independently of low line count.
# Why: proves a file with few lines but many bytes is still caught.
# From: Issue #1095
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

# What: asserts MAX_WORKFLOW_LINES/BYTES are read from the environment.
# Why: proves the defaults are overridable, not hardcoded.
# From: Issue #1095
@test "MAX_WORKFLOW_LINES and MAX_WORKFLOW_BYTES are independently overridable via environment" {
    write_lines "$fixture_root/.github/workflows/a.yml" 60

    MAX_WORKFLOW_LINES=50 MAX_WORKFLOW_BYTES=100000 run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"a.yml"* ]] || fail "did not respect the overridden line threshold: $output"
}

# What: asserts a run: block under MAX_RUN_BLOCK_BYTES passes.
# Why: proves the new dimensions non-failing path.
# From: Issue #1535
@test "passes when a run: block is under the per-block byte limit" {
    write_workflow_with_run_block "$fixture_root/.github/workflows/a.yml" "|" 10 150

    MAX_RUN_BLOCK_BYTES=200 run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"per-run-block hard limits"* ]] || fail "unexpected output: $output"
}

# What: asserts an oversized run: block fails and names its start line.
# Why: proves the fail-closed path this whole check exists for is real,
# not only asserted in prose.
# From: Issue #1535
@test "fails and names the offending run: block when over the per-block byte limit" {
    write_workflow_with_run_block "$fixture_root/.github/workflows/too-wide.yml" "|" 10 300

    MAX_RUN_BLOCK_BYTES=200 run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"run: block(s) over the 200-byte hard limit"* ]] || fail "did not report the run-block violation: $output"
    [[ "$output" == *"too-wide.yml"* ]] || fail "did not name the offending file: $output"
    [[ "$output" == *"block starting at line"* ]] || fail "did not name the offending block's start line: $output"
}

# What: asserts MAX_RUN_BLOCK_BYTES is read from the environment.
# Why: proves the default is overridable, not hardcoded.
# From: Issue #1535
@test "MAX_RUN_BLOCK_BYTES is independently overridable via environment" {
    write_workflow_with_run_block "$fixture_root/.github/workflows/a.yml" "|" 10 150

    MAX_RUN_BLOCK_BYTES=100 run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"a.yml"* ]] || fail "did not respect the overridden run-block threshold: $output"
}

# What: asserts a folded (>-) block scalar is detected the same as literal.
# Why: proves the header regex covers both YAML block-scalar indicators,
# not only the one this repo's current workflows happen to use.
# From: Issue #1535
@test "detects an oversized folded (>-) block scalar the same as a literal (|) one" {
    write_workflow_with_run_block "$fixture_root/.github/workflows/folded.yml" ">-" 10 300

    MAX_RUN_BLOCK_BYTES=200 run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"folded.yml"* ]] || fail "did not detect the oversized >- block: $output"
}

# What: asserts a plain single-line run: value is never measured as a block.
# Why: proves the header regex only matches a real block-scalar indicator,
# not any run: value regardless of length.
# From: Issue #1535
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

# What: asserts two under-limit blocks in one file are not summed together.
# Why: proves each block is measured and compared independently against
# MAX_RUN_BLOCK_BYTES, not aggregated per file.
# From: Issue #1535
@test "measures multiple run: blocks in one file independently, not as one combined total" {
    write_workflow_with_run_block "$fixture_root/.github/workflows/a.yml" "|" 10 120
    {
        echo "      - name: second big step"
        echo "        run: |"
    } >> "$fixture_root/.github/workflows/a.yml"
    write_run_block_line "$fixture_root/.github/workflows/a.yml" 10 120
    echo "      - name: after second" >> "$fixture_root/.github/workflows/a.yml"

    MAX_RUN_BLOCK_BYTES=150 run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ] || fail "two under-limit run: blocks in one file must not be summed together: $output"
}

# What: runs the real script against this worktree's own current
# .github/workflows/*.yml files, with no fixture involved.
# Why: calibrates the check against real content, not synthetic data alone.
# From: Issue #1535
@test "passes when pointed at this repository's own real .github/workflows directory" {
    run bash "$script" "$repo_root"
    [ "$status" -eq 0 ] || fail "real repo .github/workflows/*.yml files must stay under all three current limits (see issue #1535 / PR #1572): $output"
}
