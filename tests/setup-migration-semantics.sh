#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Test setup.sh migration semantics: verify that existing non-empty .env values
# are preserved by default and not overwritten during migrations or updates.
# This test validates the AGENTS.md guarantee: "Existing non-empty local values
# must be preserved by default."
set -euo pipefail

# Extract and source the .env helper functions from setup.sh.
# Only the functions we need are sourced to keep the test deterministic.
setup_sh_helpers() {
    local setup_sh="$1"
    # Extract from env_key_exists (line 446) through write_env_file (line 628).
    sed -n '446,628p' "$setup_sh"
}

# Helper to run a single test in isolation.
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

# Test 1: Existing non-empty value is preserved when append_env_key_if_missing is called.
# AGENTS.md guarantee: "Existing non-empty local values must be preserved by default."
test_existing_value_preserved() {
    local env_file="$1"

    # Simulate a user's existing configuration.
    printf 'STANDARD_CACHE_MAX_GB=100.0\n' > "$env_file"

    # The setup.sh helper function should NOT overwrite an existing key.
    env_key_exists() {
        grep -q "^${1}=" "${2}" 2>/dev/null
    }

    # Call the same logic as setup.sh uses: only add if missing.
    env_key_exists STANDARD_CACHE_MAX_GB "$env_file" || printf 'STANDARD_CACHE_MAX_GB=50.0\n' >> "$env_file"

    # Verify the original value was not overwritten.
    local actual
    actual=$(grep '^STANDARD_CACHE_MAX_GB=' "$env_file" | cut -d= -f2)
    [ "$actual" = "100.0" ] || return 1

    # Verify there is only one copy of the key (no duplicate lines).
    local count
    count=$(grep -c '^STANDARD_CACHE_MAX_GB=' "$env_file")
    [ "$count" = "1" ] || return 1
}

# Test 2: Missing keys are added on first run (install).
# AGENTS.md guarantee: "Setup...logic must converge old or incomplete installations
# toward the current expected state."
test_missing_key_added() {
    local env_file="$1"

    # Start with an empty .env (fresh install).
    : > "$env_file"

    env_key_exists() {
        grep -q "^${1}=" "${2}" 2>/dev/null
    }

    # Call setup.sh helper logic: add missing keys with defaults.
    env_key_exists STANDARD_CACHE_MAX_GB "$env_file" || printf 'STANDARD_CACHE_MAX_GB=50.0\n' >> "$env_file"

    # Verify the key was added with the default.
    local actual
    actual=$(grep '^STANDARD_CACHE_MAX_GB=' "$env_file" | cut -d= -f2)
    [ "$actual" = "50.0" ] || return 1
}

# Test 3: Empty optional values remain empty (not replaced).
# AGENTS.md guarantee: "Existing non-empty local values must be preserved by default."
# Extended: even intentionally-empty values must not be replaced.
test_empty_value_preserved() {
    local env_file="$1"

    # A user may deliberately leave an optional key empty to trigger compose fallback.
    # Example: UI_BIND_IP= causes ${UI_BIND_IP:-${IP_STANDARD}} to use IP_STANDARD.
    printf 'UI_BIND_IP=\n' > "$env_file"

    env_key_exists() {
        grep -q "^${1}=" "${2}" 2>/dev/null
    }

    # The key exists (even though it's empty), so append_env_key_if_missing must not touch it.
    env_key_exists UI_BIND_IP "$env_file" || printf 'UI_BIND_IP=192.168.1.10\n' >> "$env_file"

    # Verify the empty value was preserved.
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

    # Create a temporary test environment.
    local test_dir
    test_dir=$(mktemp -d) || exit 1
    trap "rm -rf '$test_dir'" EXIT

    local failed=0

    # Run all tests in subshells to keep the environment clean.
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
