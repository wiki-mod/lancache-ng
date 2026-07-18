#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Adapter-level tests for the dhcp-proxy (dnsmasq) known-good-snapshot
# integration in services/dhcp-proxy/entrypoint.sh (#415). Loads the real
# _dhcp_proxy_validate_snapshot_or_rollback function (not a
# reimplementation) and exercises it against a stub `dnsmasq` binary on
# PATH, so these tests don't require a real dnsmasq install.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/dhcp-proxy-known-good-snapshot-helpers.sh"

    # shellcheck source=tests/bats/helpers/dhcp-proxy-known-good-snapshot-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/dhcp-proxy-known-good-snapshot-helpers.sh"
    load_dhcp_proxy_known_good_snapshot_helpers "$repo_root" "$helper_file"

    DHCP_PROXY_CONFIG_SNAPSHOT_DIR="$BATS_TEST_TMPDIR/snapshots"
    KEEP_KNOWN_GOOD_CONFIGS=3
    export DHCP_PROXY_CONFIG_SNAPSHOT_DIR KEEP_KNOWN_GOOD_CONFIGS

    live_dir="$BATS_TEST_TMPDIR/live"
    mkdir -p "$live_dir"
    dnsmasq_conf="$live_dir/dnsmasq.conf"

    stub_bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$stub_bin"
    cat > "$stub_bin/dnsmasq" <<'STUB'
#!/bin/bash
# Stub dnsmasq: "--test -C <path>" fails if <path> contains the literal
# marker "BROKEN", so tests control validity without a real dnsmasq install.
conf_path=""
while [ $# -gt 0 ]; do
    case "$1" in
        -C) conf_path="$2"; shift 2 ;;
        --test) shift ;;
        *) shift ;;
    esac
done
if grep -q "BROKEN" "$conf_path" 2>/dev/null; then
    echo "dnsmasq: syntax check failed" >&2
    exit 1
fi
echo "dnsmasq: syntax check OK"
exit 0
STUB
    chmod +x "$stub_bin/dnsmasq"
    PATH="$stub_bin:$PATH"
    export PATH
}

@test "valid candidate config is snapshotted and dnsmasq starts normally" {
    printf 'OK config\n' > "$dnsmasq_conf"

    run _dhcp_proxy_validate_snapshot_or_rollback "$dnsmasq_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[known-good-snapshot][dhcp-proxy][CREATE]"* ]]

    run kgs_list_snapshots "$DHCP_PROXY_CONFIG_SNAPSHOT_DIR"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 1 ]
    [ "$(cat "$dnsmasq_conf")" = "OK config" ]
}

@test "invalid candidate falls back to the newest known-good snapshot" {
    printf 'OK config v1\n' > "$dnsmasq_conf"
    _dhcp_proxy_validate_snapshot_or_rollback "$dnsmasq_conf" >/dev/null

    printf 'BROKEN config v2\n' > "$dnsmasq_conf"
    run _dhcp_proxy_validate_snapshot_or_rollback "$dnsmasq_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"generated dnsmasq config failed validation"* ]]
    [[ "$output" == *"[known-good-snapshot][dhcp-proxy][SELECT]"* ]]
    [[ "$output" == *"NOT the newly generated config"* ]]

    [ "$(cat "$dnsmasq_conf")" = "OK config v1" ]
}

@test "invalid candidate with no known-good snapshot refuses to start" {
    printf 'BROKEN config\n' > "$dnsmasq_conf"

    run _dhcp_proxy_validate_snapshot_or_rollback "$dnsmasq_conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no known-good dnsmasq config snapshot is available"* ]]
    [ "$(cat "$dnsmasq_conf")" = "BROKEN config" ]
}

@test "retention keeps only KEEP_KNOWN_GOOD_CONFIGS snapshots across repeated valid starts" {
    KEEP_KNOWN_GOOD_CONFIGS=2
    for i in 1 2 3 4; do
        printf 'OK config v%s\n' "$i" > "$dnsmasq_conf"
        _dhcp_proxy_validate_snapshot_or_rollback "$dnsmasq_conf" >/dev/null
    done

    run kgs_list_snapshots "$DHCP_PROXY_CONFIG_SNAPSHOT_DIR"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 2 ]
}
