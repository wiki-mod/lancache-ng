#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: Verifies existing non-empty .env values are preserved by default,
#   not overwritten during migrations/updates.
# Why: Validates the AGENTS.md guarantee "Existing non-empty local values
#   must be preserved by default."
# From: PR #1546
set -euo pipefail

# What: Would extract setup.sh's .env helper functions by hardcoded line range.
# Why: STATUS as of 2026-08-13: unused (nothing calls it) and its range no
#   longer matches env_key_exists()/write_env_file()'s real current location
#   -- left unfixed pending a maintainer decision on removing this helper
#   vs. a non-line-number extraction mechanism.
setup_sh_helpers() {
    local setup_sh="$1"
    sed -n '446,628p' "$setup_sh"
}

# What: Runs a single test function against its own scratch env file.
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

# What: Existing non-empty value is preserved when append_env_key_if_missing is called.
# Why: Validates the same AGENTS.md guarantee cited in the file header.
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

# What: Missing keys are added on first run (install).
# Why: AGENTS.md guarantee: setup logic must converge old/incomplete
#   installations toward the current expected state.
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

# What: Empty optional values remain empty (not replaced) -- extends the
#   preserve-by-default guarantee to intentionally-empty values too.
# Why: e.g. UI_BIND_IP= deliberately triggers the
#   ${UI_BIND_IP:-${IP_STANDARD}} compose fallback to IP_STANDARD.
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
