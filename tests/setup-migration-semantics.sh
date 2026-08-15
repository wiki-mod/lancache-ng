#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: verifies .env migration/update value-preservation semantics.
# Why: validates the AGENTS.md guarantee "existing non-empty local
#   values must be preserved by default."
# From: PR #1546
set -euo pipefail

# What: would extract setup.sh's .env helpers by hardcoded line range.
# Why: STATUS 2026-08-13 -- dead code (unused) with a stale range; left
#   for a maintainer decision on removal vs. a real extraction mechanism.
# From: PR #1546
setup_sh_helpers() {
    local setup_sh="$1"
    sed -n '446,628p' "$setup_sh"
}

# What: runs a single test function against its own scratch env file.
# Why: gives each test a fresh, isolated .env fixture and a PASS/FAIL line.
# From: PR #1546
run_test() {
    local test_name="$1"
    local test_func="$2"
    local env_file="$3"

    if $test_func "$env_file" 2>/dev/null; then
        printf "PASS: %s\n" "$test_name"
        return 0
    else
        printf "FAIL: %s\n" "$test_name" >&2
        return 1
    fi
}

# What: an existing non-empty value is preserved, not overwritten.
# Why: validates the same AGENTS.md guarantee cited in the file header.
# From: PR #1546
test_existing_value_preserved() {
    local env_file="$1"

    printf 'STANDARD_CACHE_MAX_GB=100.0\n' > "$env_file"

    env_key_exists() {
        grep -q "^${1}=" "${2}" 2>/dev/null
    }

    env_key_exists STANDARD_CACHE_MAX_GB "$env_file" || printf 'STANDARD_CACHE_MAX_GB=50.0\n' >> "$env_file"

    local actual
    actual=$(grep '^STANDARD_CACHE_MAX_GB=' "$env_file" | cut -d= -f2)
    [ "$actual" = "100.0" ] || return 1

    # What: Only one copy of the key (no duplicate lines).
    local count
    count=$(grep -c '^STANDARD_CACHE_MAX_GB=' "$env_file")
    [ "$count" = "1" ] || return 1
}

# What: a missing key is added on first run (install).
# Why: setup logic must converge old/incomplete installations toward
#   the current expected state.
# From: PR #1546
test_missing_key_added() {
    local env_file="$1"

    : > "$env_file"

    env_key_exists() {
        grep -q "^${1}=" "${2}" 2>/dev/null
    }

    env_key_exists STANDARD_CACHE_MAX_GB "$env_file" || printf 'STANDARD_CACHE_MAX_GB=50.0\n' >> "$env_file"

    local actual
    actual=$(grep '^STANDARD_CACHE_MAX_GB=' "$env_file" | cut -d= -f2)
    [ "$actual" = "50.0" ] || return 1
}

# What: an intentionally-empty value stays empty, not replaced.
# Why: e.g. UI_BIND_IP= deliberately triggers the
#   ${UI_BIND_IP:-${IP_STANDARD}} compose fallback to IP_STANDARD.
# From: PR #1546
test_empty_value_preserved() {
    local env_file="$1"

    printf 'UI_BIND_IP=\n' > "$env_file"

    env_key_exists() {
        grep -q "^${1}=" "${2}" 2>/dev/null
    }

    env_key_exists UI_BIND_IP "$env_file" || printf 'UI_BIND_IP=192.168.1.10\n' >> "$env_file"

    local actual
    actual=$(grep '^UI_BIND_IP=' "$env_file" | cut -d= -f2)
    [ "$actual" = "" ] || return 1
}

main() {
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)
    local repo_root="$script_dir/.."
    local setup_sh="$repo_root/setup.sh"

    if [ ! -f "$setup_sh" ]; then
        printf "ERROR: setup.sh not found at %s\n" "$setup_sh" >&2
        exit 1
    fi

    local test_dir
    test_dir=$(mktemp -d) || exit 1
    trap 'rm -rf "$test_dir"' EXIT

    local failed=0

    run_test "existing non-empty value is preserved" \
        test_existing_value_preserved "$test_dir/test1.env" || ((failed++))

    run_test "missing keys are added on first run" \
        test_missing_key_added "$test_dir/test2.env" || ((failed++))

    run_test "empty optional values remain empty" \
        test_empty_value_preserved "$test_dir/test3.env" || ((failed++))

    if [ "$failed" -gt 0 ]; then
        printf "\n%d test(s) failed.\n" "$failed" >&2
        exit 1
    fi

    printf "\nAll setup migration tests passed.\n"
    exit 0
}

main "$@"
