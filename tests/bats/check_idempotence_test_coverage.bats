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
# helpers and its file-existence checks are supposed to catch.
#
# The guard script accepts an optional repo_root argument specifically so
# this fixture-based testing is possible without touching the real repo
# tree.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-idempotence-test-coverage.sh"
    fixture_root="$BATS_TEST_TMPDIR/fixture-repo"
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
    cat > "$fixture_root/tests/bats/setup_update_idempotence.bats" <<'EOF'
@test "migrate_env_for_update is idempotent across repeated runs" {
    true
}
EOF

    printf '#!/usr/bin/env bash\n# fixture dns entrypoint\n' > "$fixture_root/services/dns/entrypoint.sh"
    cat > "$fixture_root/tests/bats/dns_config_snapshot_idempotence.bats" <<'EOF'
@test "recursor rollback repeats to the same known-good config" {
    true
}
EOF

    printf '#!/usr/bin/env bash\n# fixture watchdog\n' > "$fixture_root/services/watchdog/watchdog.sh"
    cat > "$fixture_root/tests/bats/watchdog_idempotence.bats" <<'EOF'
@test "write_status converges across repeated writes" {
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

    cat > "$fixture_root/services/ui/src/routes/secondaries.rs" <<'EOF'
#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn nats_conf_write_converges_to_the_same_file_across_repeated_writes() {
        assert!(true);
    }
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
    cat > "$fixture_root/tests/bats/dns_config_snapshot_idempotence.bats" <<'EOF'
@test "recursor validates a config once" {
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

@test "the guard also passes when pointed at the real repository tree" {
    real_repo_root="$BATS_TEST_DIRNAME/../.."
    run "$script" "$real_repo_root"
    [ "$status" -eq 0 ]
}
