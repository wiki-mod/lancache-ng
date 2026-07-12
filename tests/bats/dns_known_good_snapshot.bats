#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Adapter-level tests for the DNS (PowerDNS) known-good-snapshot integration
# in services/dns/entrypoint.sh (#615). Loads the real
# _dns_recursor_validate_snapshot_or_rollback /
# _dns_auth_validate_snapshot_or_rollback functions (not a reimplementation)
# and exercises them against stub `pdns_recursor` / `pdns_server` binaries
# on PATH, so these tests don't require a real PowerDNS install and stay
# deterministic regardless of the bats runner's available packages. The
# stub behavior was validated against the real Debian Trixie pdns-server
# (4.9.x) / pdns-recursor (5.2.x) packages on a self-hosted runner before
# this PR (see PR description): both `pdns_recursor --config=check` and
# `pdns_server --config=check` are genuine pure pre-start validators that
# parse the candidate config and exit non-zero on error (unknown/malformed
# setting, unloadable `launch=` backend) without binding any port or
# leaving a process running -- the stubs below reproduce exactly that
# shape.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/dns-known-good-snapshot-helpers.sh"

    # shellcheck source=tests/bats/helpers/dns-known-good-snapshot-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/dns-known-good-snapshot-helpers.sh"
    load_dns_known_good_snapshot_helpers "$repo_root" "$helper_file"

    DNS_CONFIG_SNAPSHOT_DIR="$BATS_TEST_TMPDIR/snapshots"
    KEEP_KNOWN_GOOD_CONFIGS=3
    export DNS_CONFIG_SNAPSHOT_DIR KEEP_KNOWN_GOOD_CONFIGS

    live_dir="$BATS_TEST_TMPDIR/live"
    mkdir -p "$live_dir"
    recursor_conf="$live_dir/recursor.conf"
    pdns_conf="$live_dir/pdns.conf"

    stub_bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$stub_bin"

    # Stub pdns_recursor: "--config=check --config-dir=<dir>" fails if
    # <dir>/recursor.conf contains the literal marker "BROKEN", mirroring
    # the real --config=check flag confirmed on pdns-recursor 5.2.x.
    cat > "$stub_bin/pdns_recursor" <<'STUB'
#!/bin/bash
config_dir=""
for arg in "$@"; do
    case "$arg" in
        --config-dir=*) config_dir="${arg#--config-dir=}" ;;
    esac
done
if grep -q "BROKEN" "${config_dir}/recursor.conf" 2>/dev/null; then
    echo "pdns_recursor: unable to parse configuration file" >&2
    exit 1
fi
echo "pdns_recursor: config check successful"
exit 0
STUB
    chmod +x "$stub_bin/pdns_recursor"

    # Stub pdns_server: "--config=check --config-dir=<dir>" fails the same
    # way, mirroring the real --config=check flag confirmed on the real
    # pdns-server 4.9.x package (its --help doesn't spell out "check" as a
    # value the way pdns_recursor's --help does, but it is a genuine,
    # working, side-effect-free check-only invocation -- verified live
    # against valid and invalid configs on a self-hosted runner before this
    # PR).
    cat > "$stub_bin/pdns_server" <<'STUB'
#!/bin/bash
config_dir=""
for arg in "$@"; do
    case "$arg" in
        --config-dir=*) config_dir="${arg#--config-dir=}" ;;
    esac
done
if grep -q "BROKEN" "${config_dir}/pdns.conf" 2>/dev/null; then
    echo "pdns_server: Fatal error: Trying to set unknown setting 'BROKEN'" >&2
    exit 1
fi
echo "pdns_server: config check successful"
exit 0
STUB
    chmod +x "$stub_bin/pdns_server"

    PATH="$stub_bin:$PATH"
    export PATH
}

# ── recursor.conf (pure pre-start check) ─────────────────────────────────────

@test "recursor: valid candidate config is snapshotted, no rollback needed" {
    printf 'OK recursor config\n' > "$recursor_conf"

    run _dns_recursor_validate_snapshot_or_rollback "$recursor_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[known-good-snapshot][dns-recursor][CREATE]"* ]]

    run kgs_list_snapshots "${DNS_CONFIG_SNAPSHOT_DIR}/recursor"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 1 ]
    [ "$(cat "$recursor_conf")" = "OK recursor config" ]
}

@test "recursor: invalid candidate falls back to the newest known-good snapshot" {
    printf 'OK recursor config v1\n' > "$recursor_conf"
    _dns_recursor_validate_snapshot_or_rollback "$recursor_conf" >/dev/null

    printf 'BROKEN recursor config v2\n' > "$recursor_conf"
    run _dns_recursor_validate_snapshot_or_rollback "$recursor_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"generated recursor.conf failed validation"* ]]
    [[ "$output" == *"[known-good-snapshot][dns-recursor][SELECT]"* ]]
    [[ "$output" == *"NOT the newly generated config"* ]]

    [ "$(cat "$recursor_conf")" = "OK recursor config v1" ]
}

@test "recursor: invalid candidate with no known-good snapshot refuses to start" {
    printf 'BROKEN recursor config\n' > "$recursor_conf"

    run _dns_recursor_validate_snapshot_or_rollback "$recursor_conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no known-good recursor.conf snapshot is available"* ]]
    [ "$(cat "$recursor_conf")" = "BROKEN recursor config" ]
}

@test "recursor: retention keeps only KEEP_KNOWN_GOOD_CONFIGS snapshots" {
    KEEP_KNOWN_GOOD_CONFIGS=2
    for i in 1 2 3 4; do
        printf 'OK recursor config v%s\n' "$i" > "$recursor_conf"
        _dns_recursor_validate_snapshot_or_rollback "$recursor_conf" >/dev/null
    done

    run kgs_list_snapshots "${DNS_CONFIG_SNAPSHOT_DIR}/recursor"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 2 ]
}

# ── pdns.conf (pure pre-start check) ─────────────────────────────────────────

@test "auth: valid candidate config passes the check and is snapshotted" {
    printf 'OK pdns config\n' > "$pdns_conf"

    run _dns_auth_validate_snapshot_or_rollback "$pdns_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[known-good-snapshot][dns-auth][CREATE]"* ]]

    run kgs_list_snapshots "${DNS_CONFIG_SNAPSHOT_DIR}/auth"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 1 ]
    [ "$(cat "$pdns_conf")" = "OK pdns config" ]
}

@test "auth: invalid candidate falls back to the newest known-good snapshot" {
    printf 'OK pdns config v1\n' > "$pdns_conf"
    _dns_auth_validate_snapshot_or_rollback "$pdns_conf" >/dev/null

    printf 'BROKEN pdns config v2\n' > "$pdns_conf"
    run _dns_auth_validate_snapshot_or_rollback "$pdns_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"generated pdns.conf failed validation"* ]]
    [[ "$output" == *"[known-good-snapshot][dns-auth][SELECT]"* ]]
    [[ "$output" == *"NOT the newly generated config"* ]]

    [ "$(cat "$pdns_conf")" = "OK pdns config v1" ]
}

@test "auth: invalid candidate with no known-good snapshot refuses to start" {
    printf 'BROKEN pdns config\n' > "$pdns_conf"

    run _dns_auth_validate_snapshot_or_rollback "$pdns_conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no known-good pdns.conf snapshot is available"* ]]
    [ "$(cat "$pdns_conf")" = "BROKEN pdns config" ]
}

@test "auth: retention keeps only KEEP_KNOWN_GOOD_CONFIGS snapshots" {
    KEEP_KNOWN_GOOD_CONFIGS=2
    for i in 1 2 3 4; do
        printf 'OK pdns config v%s\n' "$i" > "$pdns_conf"
        _dns_auth_validate_snapshot_or_rollback "$pdns_conf" >/dev/null
    done

    run kgs_list_snapshots "${DNS_CONFIG_SNAPSHOT_DIR}/auth"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 2 ]
}

# ── recursor.conf independence from auth ─────────────────────────────────────

@test "recursor and auth snapshots are tracked independently" {
    printf 'OK recursor config\n' > "$recursor_conf"
    printf 'OK pdns config\n' > "$pdns_conf"
    _dns_recursor_validate_snapshot_or_rollback "$recursor_conf" >/dev/null
    _dns_auth_validate_snapshot_or_rollback "$pdns_conf" >/dev/null

    # A broken recursor.conf must not affect the still-valid pdns.conf
    # snapshot history, and vice versa -- they are two independent
    # components with two independent validators.
    printf 'BROKEN recursor config\n' > "$recursor_conf"
    run _dns_recursor_validate_snapshot_or_rollback "$recursor_conf"
    [ "$status" -eq 0 ]

    run kgs_list_snapshots "${DNS_CONFIG_SNAPSHOT_DIR}/auth"
    [ "$(echo "$output" | wc -l)" -eq 1 ]
}
