#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/check-idempotence-test-coverage.sh (#640): the CI
# guard that fails a build if a known config-writer entrypoint has no
# repeat-run/idempotence test. This file does NOT merely run the guard
# against the real repo (that would only prove "passes today", not that the
# guard actually catches a regression) -- it builds a small fixture tree
# mirroring the guard's own WRITER_TEST_EVIDENCE pairs and exercises every
# pass/fail branch the script's has_bats_repeat_test/has_rust_repeat_test
# helpers and its file-existence checks are supposed to catch, including
# (added in #732 review) that the guard rejects evasions that LOOK like
# coverage but that `bats`/`cargo test` would never actually execute:
# commented-out `@test`/`#[test]` lines, `#[ignore]`d Rust tests, and (for
# the NATS writer's self-referential evidence file specifically) an
# unrelated pre-existing test whose name happens to match only the generic
# repeat/idempoten/converge marker.
#
# The guard script accepts an optional repo_root argument specifically so
# this fixture-based testing is possible without touching the real repo
# tree.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-idempotence-test-coverage.sh"
    fixture_root="$BATS_TEST_TMPDIR/fixture-repo"
    # bats-core's own preprocessor (tools/build-tools's bats-preprocess,
    # BATS_TEST_PATTERN='^[[:blank:]]*@test[[:blank:]]+...') scans every
    # *line* of a .bats file for a literal `@test "..." {` pattern and
    # rewrites matches into `bats_test_function ...` boilerplate -- and it
    # does this blindly over the whole file's raw text, with no concept of
    # heredocs. Below, seed_passing_fixture() and the "no repeat-run-named
    # test" fixture override both need to write literal `@test "name" {`
    # lines into synthetic fixture files via heredoc; if that text were
    # written directly, bats would transpile THIS file's own heredoc-embedded
    # `@test` line before the heredoc ever runs, silently replacing the
    # fixture's intended content with unrelated bats internals (confirmed via
    # `od -c` on the resulting fixture file: it contained
    # `bats_test_function --description ...`, not `@test "..."`). Building
    # the marker through this variable, and using unquoted heredocs below
    # instead of the usual `<<'EOF'`, keeps the literal string "@test" out of
    # this file's own source so the preprocessor has nothing to match; the
    # variable is expanded back into a real `@test "..." {` line only when
    # the heredoc actually runs and writes the fixture file to disk.
    at_test='@test'
}

# seed_passing_fixture
# Recreates, under $fixture_root, a minimal version of every writer/evidence
# pair the real guard checks -- each evidence file carries at least one test
# name with a repeat-run marker, so the whole fixture is expected to pass.
seed_passing_fixture() {
    mkdir -p "$fixture_root/tests/bats"
    mkdir -p "$fixture_root/services/dns"
    mkdir -p "$fixture_root/services/watchdog"
    mkdir -p "$fixture_root/services/ui/src/routes"

    printf '#!/usr/bin/env bash\n# fixture setup.sh\n' > "$fixture_root/setup.sh"
    cat > "$fixture_root/tests/bats/setup_update_idempotence.bats" <<EOF
${at_test} "migrate_env_for_update is idempotent across repeated runs" {
    true
}
EOF

    printf '#!/usr/bin/env bash\n# fixture dns entrypoint\n' > "$fixture_root/services/dns/entrypoint.sh"
    cat > "$fixture_root/tests/bats/dns_config_snapshot_idempotence.bats" <<EOF
${at_test} "recursor rollback repeats to the same known-good config" {
    true
}
EOF

    printf '#!/usr/bin/env bash\n# fixture watchdog\n' > "$fixture_root/services/watchdog/watchdog.sh"
    cat > "$fixture_root/tests/bats/watchdog_idempotence.bats" <<EOF
${at_test} "write_status converges across repeated writes" {
    true
}
EOF

    printf '// fixture kea snapshots\n' > "$fixture_root/services/ui/src/kea_snapshots.rs"
    cat > "$fixture_root/services/ui/src/routes/dhcp.rs" <<'EOF'
#[cfg(test)]
mod tests {
    #[test]
    fn kea_config_modify_repeat_rollback_lands_on_byte_identical_known_good_config() {
        assert!(true);
    }
}
EOF

    # zone_snapshots.rs (#628) is its own evidence file too, like
    # secondaries.rs below -- self-referential (writer == evidence), no
    # extra_marker needed since it's a brand-new fixture path with nothing
    # unrelated in it that could accidentally satisfy the generic marker.
    mkdir -p "$fixture_root/services/dns/nats-subscriber/src"
    cat > "$fixture_root/services/dns/nats-subscriber/src/zone_snapshots.rs" <<'EOF'
#[cfg(test)]
mod tests {
    #[test]
    fn create_snapshot_repeat_writes_converge_to_retention_limit() {
        assert!(true);
    }
}
EOF

    # The name below deliberately contains both the generic marker
    # ("repeated") AND the NATS-specific extra_marker ("nats_conf") the real
    # WRITER_TEST_EVIDENCE entry requires -- see "fails when the NATS
    # evidence ..." below for the regression this guards (#732 review).
    cat > "$fixture_root/services/ui/src/routes/secondaries.rs" <<'EOF'
#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn nats_conf_write_converges_to_the_same_file_across_repeated_writes() {
        assert!(true);
    }
}
EOF

    mkdir -p "$fixture_root/services/proxy" "$fixture_root/services/dhcp-proxy"
    printf '#!/usr/bin/env bash\n# fixture proxy entrypoint\n' > "$fixture_root/services/proxy/entrypoint.sh"
    cat > "$fixture_root/tests/bats/proxy_known_good_snapshot.bats" <<EOF
${at_test} "retention keeps only KEEP_KNOWN_GOOD_CONFIGS snapshots across repeated valid starts" {
    true
}
EOF

    printf '#!/usr/bin/env bash\n# fixture dhcp-proxy entrypoint\n' > "$fixture_root/services/dhcp-proxy/entrypoint.sh"
    cat > "$fixture_root/tests/bats/dhcp_proxy_known_good_snapshot.bats" <<EOF
${at_test} "retention keeps only KEEP_KNOWN_GOOD_CONFIGS snapshots across repeated valid starts" {
    true
}
EOF
}

@test "passes when every config-writer has a real repeat-run test" {
    seed_passing_fixture
    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails when a bats evidence file is missing entirely" {
    seed_passing_fixture
    rm "$fixture_root/tests/bats/watchdog_idempotence.bats"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"services/watchdog/watchdog.sh"* ]]
    [[ "$output" == *"does not exist"* ]]
}

@test "fails when a bats evidence file exists but has no repeat-run-named test" {
    seed_passing_fixture
    cat > "$fixture_root/tests/bats/dns_config_snapshot_idempotence.bats" <<EOF
${at_test} "recursor validates a config once" {
    true
}
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"services/dns/entrypoint.sh"* ]]
    [[ "$output" == *"repeat/idempoten/converge"* ]]
}

@test "fails when a Rust evidence file has tests but none named for a repeat run" {
    seed_passing_fixture
    cat > "$fixture_root/services/ui/src/routes/secondaries.rs" <<'EOF'
#[cfg(test)]
mod tests {
    #[test]
    fn nats_conf_write_replaces_file_atomically() {
        assert!(true);
    }
}
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"services/ui/src/routes/secondaries.rs"* ]]
}

@test "fails when a known config-writer source file itself no longer exists" {
    seed_passing_fixture
    rm "$fixture_root/services/dns/entrypoint.sh"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no longer exists"* ]]
}

@test "reports every missing pair in one run, not just the first" {
    seed_passing_fixture
    rm "$fixture_root/tests/bats/watchdog_idempotence.bats"
    rm "$fixture_root/tests/bats/setup_update_idempotence.bats"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"setup.sh"* ]]
    [[ "$output" == *"services/watchdog/watchdog.sh"* ]]
}

@test "fails when the NATS evidence file only has a repeat-named test unrelated to the writer" {
    # Regression case from #732 review: secondaries.rs is its own evidence
    # file, so an unrelated pre-existing test (here modelling the real
    # generate_nats_password_is_high_entropy_and_never_repeats, about key
    # generation, not config-writing) whose name merely contains "repeat"
    # must NOT satisfy the NATS entry's extra_marker ("nats_conf") -- before
    # this fix, deleting the real nats_conf_write_converges_... test still
    # left the guard reporting OK because of this test alone.
    seed_passing_fixture
    cat > "$fixture_root/services/ui/src/routes/secondaries.rs" <<'EOF'
#[cfg(test)]
mod tests {
    #[test]
    fn generate_nats_password_is_high_entropy_and_never_repeats() {
        assert!(true);
    }
}
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"services/ui/src/routes/secondaries.rs"* ]]
}

@test "fails when the proxy known-good-snapshot writer loses its repeat-run coverage" {
    # The script's own header documents that it guards the nginx/dnsmasq
    # known-good-snapshot adapters too; before #732's fix, WRITER_TEST_EVIDENCE
    # had no entry for either one, so this fixture would have passed silently.
    seed_passing_fixture
    rm "$fixture_root/tests/bats/proxy_known_good_snapshot.bats"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"services/proxy/entrypoint.sh"* ]]
}

@test "fails when the dhcp-proxy known-good-snapshot writer loses its repeat-run coverage" {
    seed_passing_fixture
    rm "$fixture_root/tests/bats/dhcp_proxy_known_good_snapshot.bats"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"services/dhcp-proxy/entrypoint.sh"* ]]
}

@test "does not count a commented-out bats @test line as evidence" {
    # A leading '#' (with or without indentation) makes a line a bats
    # comment, never an active test declaration -- bats itself never
    # executes it, so the guard must not treat it as proof either.
    seed_passing_fixture
    cat > "$fixture_root/tests/bats/watchdog_idempotence.bats" <<EOF
  # ${at_test} "write_status converges across repeated writes" {
    true
}
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"services/watchdog/watchdog.sh"* ]]
}

@test "does not count a #[ignore]d Rust test as evidence" {
    # Normal CI never runs a #[ignore]d test, so it must not be able to
    # stand in for the writer's enforced repeat-run proof.
    seed_passing_fixture
    cat > "$fixture_root/services/ui/src/routes/secondaries.rs" <<'EOF'
#[cfg(test)]
mod tests {
    #[tokio::test]
    #[ignore]
    async fn nats_conf_write_converges_to_the_same_file_across_repeated_writes() {
        assert!(true);
    }
}
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"services/ui/src/routes/secondaries.rs"* ]]
}

@test "does not count a #[ignore = \"reason\"]d Rust test as evidence" {
    # #[ignore] with a reason string is the common real-world form; the
    # matcher must catch this prefix too, not just the bare #[ignore] line.
    seed_passing_fixture
    cat > "$fixture_root/services/ui/src/routes/secondaries.rs" <<'EOF'
#[cfg(test)]
mod tests {
    #[tokio::test]
    #[ignore = "flaky under CI load"]
    async fn nats_conf_write_converges_to_the_same_file_across_repeated_writes() {
        assert!(true);
    }
}
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"services/ui/src/routes/secondaries.rs"* ]]
}

@test "does not count a commented-out Rust #[test] block as evidence" {
    # A '//'-commented attribute/fn pair is dead code to rustc; it must not
    # satisfy the guard just because the raw text still contains the marker
    # substrings.
    seed_passing_fixture
    cat > "$fixture_root/services/ui/src/routes/secondaries.rs" <<'EOF'
#[cfg(test)]
mod tests {
    // #[tokio::test]
    // async fn nats_conf_write_converges_to_the_same_file_across_repeated_writes() {
    //     assert!(true);
    // }
}
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"services/ui/src/routes/secondaries.rs"* ]]
}

@test "the guard also passes when pointed at the real repository tree" {
    real_repo_root="$BATS_TEST_DIRNAME/../.."
    run "$script" "$real_repo_root"
    [ "$status" -eq 0 ]
}
