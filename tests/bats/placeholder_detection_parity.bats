#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Cross-implementation parity coverage for secret/token placeholder detection
# (issue #967). scripts/lib/shared-secret-bootstrap.sh's secret_is_placeholder
# (canonical for shared secrets, embedded byte-identically into the
# dns/dhcp/ui entrypoints -- already guarded by
# tests/bats/shared_secret_bootstrap_sync.bats) and setup.sh's own, separately
# maintained secret_value_is_placeholder are two independent bash
# implementations; services/ui/src/main.rs's
# secondary_registration_token_is_placeholder is a third, independent Rust
# implementation checked the same way by that module's own
# secondary_registration_token_is_placeholder_matches_shared_parity_fixture
# test. The maintainer decided (#967, Option B) to keep all three separate
# rather than unify them into one canonical implementation, so this test does
# NOT assert the three always agree -- it asserts each one matches its OWN
# expected column in tests/fixtures/placeholder-detection-cases.txt, which
# pins down every case this project currently knows about, including the
# cases where they legitimately (and are expected to) disagree.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    fixture="$repo_root/tests/fixtures/placeholder-detection-cases.txt"

    # shellcheck source=/dev/null
    source "$repo_root/scripts/lib/shared-secret-bootstrap.sh"

    # setup.sh's own secret_value_is_placeholder, extracted via awk instead of
    # sourcing the whole script -- the same established pattern
    # tests/bats/helpers/setup-update-helpers.sh uses for
    # migrate_env_for_update, so this test never executes setup.sh's
    # interactive install/update CLI dispatcher. The awk range starts at the
    # function's own opening line and ends at its first column-0 "}", which
    # is exactly (and only) its closing brace -- the function body has no
    # other column-0 lines.
    setup_helper="$BATS_TEST_TMPDIR/setup-secret-placeholder.sh"
    awk '/^secret_value_is_placeholder\(\)/,/^}/' "$repo_root/setup.sh" > "$setup_helper"
    # shellcheck source=/dev/null
    source "$setup_helper"
}

@test "secret_is_placeholder (shared-secret-bootstrap.sh) agrees with its 'shared' fixture column" {
    [ -f "$fixture" ] || fail "shared parity fixture not found: $fixture"

    local mismatches=0 total=0
    local value expect_shared actual

    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Trailing "setup"/"rust" fixture columns are irrelevant to this test
        # (checked by the "setup" test below and by main.rs's own fixture
        # test, respectively) -- discarded into "_" rather than named unused
        # variables.
        read -r value expect_shared _ _ <<< "$line"
        total=$((total + 1))

        if secret_is_placeholder "$value"; then actual="placeholder"; else actual="real"; fi

        if [[ "$actual" != "$expect_shared" ]]; then
            echo "MISMATCH (shared): '$value' expected=$expect_shared actual=$actual" >&2
            mismatches=$((mismatches + 1))
        fi
    done < "$fixture"

    [ "$total" -gt 0 ] || fail "shared parity fixture had zero usable cases"
    [ "$mismatches" -eq 0 ] || fail "$mismatches of $total case(s) disagreed with secret_is_placeholder"
}

@test "secret_value_is_placeholder (setup.sh) agrees with its 'setup' fixture column" {
    [ -f "$fixture" ] || fail "shared parity fixture not found: $fixture"

    local mismatches=0 total=0
    local value expect_setup actual

    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Leading "shared" and trailing "rust" fixture columns are irrelevant
        # to this test -- discarded into "_" rather than named unused
        # variables.
        read -r value _ expect_setup _ <<< "$line"
        total=$((total + 1))

        if secret_value_is_placeholder "$value"; then actual="placeholder"; else actual="real"; fi

        if [[ "$actual" != "$expect_setup" ]]; then
            echo "MISMATCH (setup): '$value' expected=$expect_setup actual=$actual" >&2
            mismatches=$((mismatches + 1))
        fi
    done < "$fixture"

    [ "$total" -gt 0 ] || fail "shared parity fixture had zero usable cases"
    [ "$mismatches" -eq 0 ] || fail "$mismatches of $total case(s) disagreed with secret_value_is_placeholder"
}

# The empty-value case can't be expressed as a fixture line (see the
# fixture's own header comment), so it's asserted directly here for
# setup.sh's implementation. secret_is_placeholder's empty case is already
# covered by tests/bats/shared_secret_bootstrap.bats, and the Rust
# implementation's by main.rs's
# secondary_registration_token_rejects_empty_and_known_placeholders test.
@test "secret_value_is_placeholder (setup.sh) treats an empty value as a placeholder" {
    run secret_value_is_placeholder ""
    [ "$status" -eq 0 ]
}
