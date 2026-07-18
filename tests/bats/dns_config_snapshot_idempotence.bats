#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Repeat-run idempotence fixture tests for the PowerDNS known-good-snapshot
# adapter functions in services/dns/entrypoint.sh
# (_dns_recursor_validate_snapshot_or_rollback /
# _dns_auth_validate_snapshot_or_rollback), the DNS equivalent of
# setup_update_idempotence.bats for `setup.sh update`.
#
# #615's own done-criteria (tracked in #640) call for proving the
# validate-or-rollback path lands on a *stable fixed point* across repeated
# container starts, not just that a single rollback works once. The other
# adapter suites (proxy_known_good_snapshot.bats,
# dhcp_proxy_known_good_snapshot.bats) and dns_known_good_snapshot.bats each
# assert one-shot behavior; none drives the real function twice in a row and
# diffs the result. This file closes that gap for both PowerDNS roles.
#
# It loads the REAL adapter functions (via the same awk-extraction helper the
# one-shot suite uses -- not a re-implementation) and drives them against
# stub pdns_recursor/pdns_server binaries whose --config=check behavior
# mirrors the real Debian Trixie packages (exit non-zero iff the candidate
# holds the literal marker "BROKEN"), the identical stub shape validated live
# against the real binaries before this PR (see dns_known_good_snapshot.bats).

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

    # Stubs mirror the real `--config=check` failure surface exactly: parse
    # <config-dir>/<name>.conf, exit non-zero iff it holds the "BROKEN"
    # marker (the realistic failure mode -- a corrupt env-var substitution
    # producing an unknown/malformed setting), never binding a socket. Kept
    # byte-for-byte consistent with dns_known_good_snapshot.bats so both
    # suites exercise the same contract.
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

# snapshot_fingerprint <snapshot_root>
# A stable fingerprint of a snapshot store: the sorted list of snapshot
# directory ids plus a content hash of every file they hold. Two runs that
# produce byte-identical fingerprints have neither created/pruned a snapshot
# nor mutated an existing one -- exactly the fixed-point property #640 asks
# for. Uses `find`+`sha256sum` (both in the bats build-tools image) rather
# than diffing whole trees so the assertion message stays a single value.
snapshot_fingerprint() {
    local root="$1"
    # Directory ids first (proves no snapshot was added or pruned), then
    # per-file content hashes with repo-relative paths (proves no snapshot's
    # bytes changed). `sort` makes the order independent of readdir order.
    ( cd "$root" 2>/dev/null && find . -mindepth 1 -maxdepth 1 -type d | sort )
    ( cd "$root" 2>/dev/null && find . -type f | sort | xargs -r sha256sum )
}

# ── recursor.conf rollback path is a stable fixed point ──────────────────────

@test "recursor: repeating the rollback path lands on the same known-good config and never snapshots the broken candidate" {
    # Seed exactly one known-good snapshot from a valid v1 config.
    printf 'OK recursor config v1\n' > "$recursor_conf"
    _dns_recursor_validate_snapshot_or_rollback "$recursor_conf" >/dev/null

    run kgs_list_snapshots "${DNS_CONFIG_SNAPSHOT_DIR}/recursor"
    [ "$(echo "$output" | wc -l)" -eq 1 ]

    # First restart with a broken candidate: render regenerates the bad
    # config, validation fails, rollback restores v1.
    printf 'BROKEN recursor config v2\n' > "$recursor_conf"
    run _dns_recursor_validate_snapshot_or_rollback "$recursor_conf"
    [ "$status" -eq 0 ]
    [ "$(cat "$recursor_conf")" = "OK recursor config v1" ]
    live_hash_1="$(sha256sum "$recursor_conf" | awk '{print $1}')"
    fp_1="$(snapshot_fingerprint "${DNS_CONFIG_SNAPSHOT_DIR}/recursor")"

    # Second restart: the same broken candidate is regenerated again (the
    # underlying bad env var was never fixed). A correct fixed point rolls
    # back to the identical v1 config and leaves the snapshot store byte-for-
    # byte unchanged -- crucially, the broken candidate must never be
    # snapshotted, or a later rollback could select it.
    printf 'BROKEN recursor config v2\n' > "$recursor_conf"
    run _dns_recursor_validate_snapshot_or_rollback "$recursor_conf"
    [ "$status" -eq 0 ]
    [ "$(cat "$recursor_conf")" = "OK recursor config v1" ]
    live_hash_2="$(sha256sum "$recursor_conf" | awk '{print $1}')"
    fp_2="$(snapshot_fingerprint "${DNS_CONFIG_SNAPSHOT_DIR}/recursor")"

    [ "$live_hash_1" = "$live_hash_2" ]
    [ "$fp_1" = "$fp_2" ]

    run kgs_list_snapshots "${DNS_CONFIG_SNAPSHOT_DIR}/recursor"
    [ "$(echo "$output" | wc -l)" -eq 1 ]
}

# ── pdns.conf rollback path is a stable fixed point ──────────────────────────

@test "auth: repeating the rollback path lands on the same known-good config and never snapshots the broken candidate" {
    printf 'OK pdns config v1\n' > "$pdns_conf"
    _dns_auth_validate_snapshot_or_rollback "$pdns_conf" >/dev/null

    run kgs_list_snapshots "${DNS_CONFIG_SNAPSHOT_DIR}/auth"
    [ "$(echo "$output" | wc -l)" -eq 1 ]

    printf 'BROKEN pdns config v2\n' > "$pdns_conf"
    run _dns_auth_validate_snapshot_or_rollback "$pdns_conf"
    [ "$status" -eq 0 ]
    [ "$(cat "$pdns_conf")" = "OK pdns config v1" ]
    live_hash_1="$(sha256sum "$pdns_conf" | awk '{print $1}')"
    fp_1="$(snapshot_fingerprint "${DNS_CONFIG_SNAPSHOT_DIR}/auth")"

    printf 'BROKEN pdns config v2\n' > "$pdns_conf"
    run _dns_auth_validate_snapshot_or_rollback "$pdns_conf"
    [ "$status" -eq 0 ]
    [ "$(cat "$pdns_conf")" = "OK pdns config v1" ]
    live_hash_2="$(sha256sum "$pdns_conf" | awk '{print $1}')"
    fp_2="$(snapshot_fingerprint "${DNS_CONFIG_SNAPSHOT_DIR}/auth")"

    [ "$live_hash_1" = "$live_hash_2" ]
    [ "$fp_1" = "$fp_2" ]

    run kgs_list_snapshots "${DNS_CONFIG_SNAPSHOT_DIR}/auth"
    [ "$(echo "$output" | wc -l)" -eq 1 ]
}

# ── valid-config repeat runs keep the live file byte-stable ──────────────────

@test "recursor: repeating a valid config keeps the live file byte-stable (snapshot growth is expected, not drift)" {
    # Unlike the rollback path, a valid config records a fresh known-good
    # snapshot every start by design, so the snapshot COUNT grows (bounded by
    # retention) -- that is not drift and must not be asserted stable. The
    # meaningful idempotence property here is that the operator's intended,
    # validated config is what stays live on every run, unchanged.
    printf 'OK recursor config\n' > "$recursor_conf"
    run _dns_recursor_validate_snapshot_or_rollback "$recursor_conf"
    [ "$status" -eq 0 ]
    live_hash_1="$(sha256sum "$recursor_conf" | awk '{print $1}')"

    printf 'OK recursor config\n' > "$recursor_conf"
    run _dns_recursor_validate_snapshot_or_rollback "$recursor_conf"
    [ "$status" -eq 0 ]
    live_hash_2="$(sha256sum "$recursor_conf" | awk '{print $1}')"

    [ "$live_hash_1" = "$live_hash_2" ]
    [ "$(cat "$recursor_conf")" = "OK recursor config" ]

    # The accumulated snapshots must all still be genuinely known-good: a
    # subsequent broken candidate rolls back cleanly to the valid config.
    printf 'BROKEN recursor config\n' > "$recursor_conf"
    run _dns_recursor_validate_snapshot_or_rollback "$recursor_conf"
    [ "$status" -eq 0 ]
    [ "$(cat "$recursor_conf")" = "OK recursor config" ]
}
