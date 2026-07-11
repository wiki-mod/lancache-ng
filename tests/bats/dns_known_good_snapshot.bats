#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Adapter-level tests for the DNS (PowerDNS) known-good-snapshot integration
# in services/dns/entrypoint.sh (#615). Loads the real
# _dns_recursor_validate_snapshot_or_rollback / _dns_auth_probe /
# _dns_auth_validate_snapshot_or_rollback functions (not a
# reimplementation) and exercises them against stub `pdns_recursor` /
# `pdns_server` / `pdns_control` binaries on PATH, so these tests don't
# require a real PowerDNS install and stay deterministic regardless of the
# bats runner's available packages. The stub behavior was validated against
# the real Debian Trixie pdns-server (4.9.x) / pdns-recursor (5.2.x)
# packages on a self-hosted runner before this PR (see PR description):
# `pdns_recursor --config=check` is a genuine pure pre-start validator, and
# an invalid pdns_server config makes the real binary exit well under a
# second without ever creating the control socket -- the stubs below
# reproduce exactly that shape.

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

    # Stub pdns_server + pdns_control emulate the real start-then-verify
    # shape: pdns_server, given a config directory whose pdns.conf contains
    # "BROKEN", exits immediately without creating a "ready" marker; a valid
    # config makes it create the marker and then sleep (simulating a
    # listening daemon) until killed. Stub pdns_control's "rping" reports
    # PONG only if the marker exists, matching real rping's role as a
    # liveness check on the control socket.
    ready_marker_dir="$BATS_TEST_TMPDIR/ready-markers"
    mkdir -p "$ready_marker_dir"
    cat > "$stub_bin/pdns_server" <<STUB
#!/bin/bash
config_dir=""
for arg in "\$@"; do
    case "\$arg" in
        --config-dir=*) config_dir="\${arg#--config-dir=}" ;;
    esac
done
if grep -q "BROKEN" "\${config_dir}/pdns.conf" 2>/dev/null; then
    echo "pdns_server: Fatal error: invalid configuration" >&2
    exit 1
fi
touch "$ready_marker_dir/ready"
# Trapping EXIT only (not TERM/INT) is deliberate: trapping TERM/INT
# overrides bash's default signal action (immediate termination) with
# "run this handler, then keep executing the script" -- so the
# still-running "while true" loop below would survive _dns_auth_probe's
# kill entirely and hang the test forever. Trapping only EXIT lets the
# default SIGTERM action actually terminate the process, and the EXIT
# trap still fires during that termination to clean up the marker file.
trap 'rm -f "$ready_marker_dir/ready"' EXIT
while true; do sleep 0.1; done
STUB
    chmod +x "$stub_bin/pdns_server"

    cat > "$stub_bin/pdns_control" <<STUB
#!/bin/bash
if [ -f "$ready_marker_dir/ready" ]; then
    echo "PONG"
    exit 0
fi
echo "pdns_control: Unable to connect to remote" >&2
exit 1
STUB
    chmod +x "$stub_bin/pdns_control"

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

# ── pdns.conf (start-then-verify probe) ──────────────────────────────────────

@test "auth: valid candidate config passes the probe and is snapshotted" {
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
    [[ "$output" == *"failed the start-then-verify probe"* ]]
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

@test "auth: the probe process is torn down after a valid check (no leaked ready marker)" {
    # Regression guard for _dns_auth_probe leaking its background pdns_server
    # stand-in: after a successful probe, the "ready" marker the stub uses to
    # answer rping must be gone, proving the probe process was actually
    # killed rather than left running in the background.
    printf 'OK pdns config\n' > "$pdns_conf"
    _dns_auth_validate_snapshot_or_rollback "$pdns_conf" >/dev/null
    [ ! -f "$ready_marker_dir/ready" ]
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
