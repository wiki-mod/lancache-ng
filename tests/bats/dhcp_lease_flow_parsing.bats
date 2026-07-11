#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Fast, Docker-free unit coverage for scripts/lib/dhcp-lease-parse.sh (issue
# #448). Feeds canned dhclient .leases fixtures and asserts the extracted
# offered-address/server-identifier/router/DNS/NTP/lease-time/domain fields
# -- this is what actually keeps the option-parsing logic honest between
# real, Docker-based runs of scripts/dhcp-kea-lease-flow-simulation.sh
# (which only runs via workflow_dispatch and needs a runner with Docker), so
# a regression in the parser itself is still caught by normal, fast bats CI.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/lib/dhcp-lease-parse.sh
    source "$repo_root/scripts/lib/dhcp-lease-parse.sh"

    fixtures_dir="$BATS_TEST_TMPDIR/leases"
    mkdir -p "$fixtures_dir"
}

write_lease_fixture() {
    local target="$1"
    shift
    printf '%s\n' "$@" > "$target"
}

@test "parses a single lease block with all common options" {
    write_lease_fixture "$fixtures_dir/single.leases" \
        'lease {' \
        '  interface "eth0";' \
        '  fixed-address 10.0.0.130;' \
        '  option subnet-mask 255.255.255.0;' \
        '  option dhcp-lease-time 3600;' \
        '  option routers 10.0.0.1;' \
        '  option dhcp-message-type 5;' \
        '  option dhcp-server-identifier 10.0.0.1;' \
        '  option domain-name-servers 10.0.0.1,10.0.0.2;' \
        '  option domain-search "lan.";' \
        '  option ntp-servers 8.8.8.8,1.1.1.1;' \
        '  option host-name "dhcp-10-0-0-130.lan";' \
        '  option domain-name "lan";' \
        '  renew 6 2026/07/11 16:24:45;' \
        '  rebind 6 2026/07/11 16:47:32;' \
        '  expire 6 2026/07/11 16:55:02;' \
        '}'

    run dhcp_lease_parse_latest "$fixtures_dir/single.leases"
    [ "$status" -eq 0 ]
    parsed="$output"

    [ "$(dhcp_lease_field "$parsed" address)" = "10.0.0.130" ]
    [ "$(dhcp_lease_field "$parsed" server_identifier)" = "10.0.0.1" ]
    [ "$(dhcp_lease_field "$parsed" router)" = "10.0.0.1" ]
    [ "$(dhcp_lease_field "$parsed" dns_servers)" = "10.0.0.1,10.0.0.2" ]
    [ "$(dhcp_lease_field "$parsed" ntp_servers)" = "8.8.8.8,1.1.1.1" ]
    [ "$(dhcp_lease_field "$parsed" lease_time)" = "3600" ]
    [ "$(dhcp_lease_field "$parsed" domain_name)" = "lan" ]
    [ "$(dhcp_lease_field "$parsed" domain_search)" = "lan." ]
    [ "$(dhcp_lease_field "$parsed" host_name)" = "dhcp-10-0-0-130.lan" ]
    [ "$(dhcp_lease_field "$parsed" subnet_mask)" = "255.255.255.0" ]
}

@test "uses only the LAST lease block when a file has several" {
    write_lease_fixture "$fixtures_dir/multi.leases" \
        'lease {' \
        '  interface "eth0";' \
        '  fixed-address 10.0.0.128;' \
        '  option dhcp-lease-time 3600;' \
        '  option routers 10.0.0.1;' \
        '  option dhcp-server-identifier 10.0.0.1;' \
        '  option domain-name-servers 10.0.0.1;' \
        '  renew 6 2026/07/11 16:22:00;' \
        '  rebind 6 2026/07/11 16:52:00;' \
        '  expire 6 2026/07/11 16:59:00;' \
        '}' \
        'lease {' \
        '  interface "eth0";' \
        '  fixed-address 10.0.0.130;' \
        '  option dhcp-lease-time 7200;' \
        '  option routers 10.0.0.1;' \
        '  option dhcp-server-identifier 10.0.0.1;' \
        '  option domain-name-servers 10.0.0.1;' \
        '  renew 6 2026/07/11 17:22:00;' \
        '  rebind 6 2026/07/11 17:52:00;' \
        '  expire 6 2026/07/11 17:59:00;' \
        '}'

    run dhcp_lease_parse_latest "$fixtures_dir/multi.leases"
    [ "$status" -eq 0 ]
    parsed="$output"

    # Must reflect the SECOND (latest) block, not the first.
    [ "$(dhcp_lease_field "$parsed" address)" = "10.0.0.130" ]
    [ "$(dhcp_lease_field "$parsed" lease_time)" = "7200" ]
}

@test "does not truncate multi-token quoted values" {
    write_lease_fixture "$fixtures_dir/multiword.leases" \
        'lease {' \
        '  interface "eth0";' \
        '  fixed-address 10.0.0.130;' \
        '  option domain-search "corp.lan.", "lan.";' \
        '  option host-name "some-long-client-hostname";' \
        '}'

    run dhcp_lease_parse_latest "$fixtures_dir/multiword.leases"
    [ "$status" -eq 0 ]
    parsed="$output"

    [ "$(dhcp_lease_field "$parsed" domain_search)" = "corp.lan., lan." ]
    [ "$(dhcp_lease_field "$parsed" host_name)" = "some-long-client-hostname" ]
}

@test "fields never configured are simply absent, not empty-but-present" {
    write_lease_fixture "$fixtures_dir/nontp.leases" \
        'lease {' \
        '  interface "eth0";' \
        '  fixed-address 10.0.0.130;' \
        '  option dhcp-lease-time 3600;' \
        '  option routers 10.0.0.1;' \
        '  option dhcp-server-identifier 10.0.0.1;' \
        '  option domain-name-servers 10.0.0.1;' \
        '}'

    run dhcp_lease_parse_latest "$fixtures_dir/nontp.leases"
    [ "$status" -eq 0 ]
    parsed="$output"

    ! printf '%s\n' "$parsed" | grep -q '^ntp_servers='
    run dhcp_lease_field "$parsed" ntp_servers
    [ "$status" -eq 1 ]
}

@test "returns failure for a file with no complete lease block" {
    write_lease_fixture "$fixtures_dir/incomplete.leases" \
        'lease {' \
        '  interface "eth0";' \
        '  fixed-address 10.0.0.130;'

    run dhcp_lease_parse_latest "$fixtures_dir/incomplete.leases"
    [ "$status" -eq 1 ]
}

@test "returns failure for an empty file" {
    : > "$fixtures_dir/empty.leases"

    run dhcp_lease_parse_latest "$fixtures_dir/empty.leases"
    [ "$status" -eq 1 ]
}

@test "returns failure for a missing file" {
    run dhcp_lease_parse_latest "$fixtures_dir/does-not-exist.leases"
    [ "$status" -eq 1 ]
}
