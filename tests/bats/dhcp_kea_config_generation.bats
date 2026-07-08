#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Tests for Kea DHCP config generation logic (services/dhcp/entrypoint.sh).
# Covers JSON validity, config structure, TSIG setup, and NTP resolution.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/dhcp-kea-helpers.sh"

    # shellcheck source=tests/bats/helpers/dhcp-kea-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/dhcp-kea-helpers.sh"
    load_dhcp_kea_functions "$repo_root" "$helper_file"

    # Test fixtures
    test_config_dir="$BATS_TEST_TMPDIR/kea-configs"
    mkdir -p "$test_config_dir"

    # Standard test environment variables
    export DHCP_SUBNET="10.0.0.0/24"
    export DHCP_RANGE_START="10.0.0.128"
    export DHCP_RANGE_END="10.0.0.254"
    export DHCP_GATEWAY="10.0.0.1"
    export DHCP_DOMAIN="lan"
    export DHCP_LEASE_TIME="86400"
    export DHCP_NTP_SERVERS="8.8.8.8 1.1.1.1"
    export DHCP_DNS_PRIMARY="127.0.0.1"
    export DHCP_DNS_SECONDARY="127.0.0.1"
    export DHCP_MAX_LEASE_TIME="172800"
    export DHCP_DNS_SERVER_IP="127.0.0.1"
    export DHCP_DNS_SERVER_IP_SSL="127.0.0.1"
    export DHCP_DDNS_PORT="53"
    export KEA_CTRL_TOKEN="test-secret-token-12345678901234567890"
    export KEA_CTRL_HOST="0.0.0.0"
    export DDNS_TSIG_KEY="dGVzdC10c2lnLWtleS1iYXNlNjQtZW5jb2RlZA=="
    export DHCP_NTP_OPTION=""

    # ENVSUBST_VARS from entrypoint.sh
    export ENVSUBST_VARS='${DHCP_SUBNET}${DHCP_RANGE_START}${DHCP_RANGE_END}${DHCP_GATEWAY}${DHCP_DOMAIN}${DHCP_LEASE_TIME}${DHCP_NTP_OPTION}${DHCP_DNS_PRIMARY}${DHCP_DNS_SECONDARY}${KEA_CTRL_TOKEN}${DHCP_MAX_LEASE_TIME}${DDNS_TSIG_KEY}${DHCP_DNS_SERVER_IP}${DHCP_DNS_SERVER_IP_SSL}${DHCP_DDNS_PORT}${KEA_CTRL_HOST}'
}

@test "IPv4 validation accepts valid addresses" {
    run is_ipv4 "192.168.1.1"
    [ "$status" -eq 0 ]

    run is_ipv4 "8.8.8.8"
    [ "$status" -eq 0 ]

    run is_ipv4 "127.0.0.1"
    [ "$status" -eq 0 ]

    run is_ipv4 "255.255.255.255"
    [ "$status" -eq 0 ]
}

@test "IPv4 validation rejects invalid addresses" {
    run is_ipv4 "256.1.1.1"
    [ "$status" -eq 1 ]

    run is_ipv4 "1.1.1"
    [ "$status" -eq 1 ]

    run is_ipv4 "not-an-ip"
    [ "$status" -eq 1 ]

    run is_ipv4 ""
    [ "$status" -eq 1 ]
}

@test "NTP server resolution returns IPv4 addresses unchanged" {
    run resolve_ntp_server "8.8.8.8"
    [ "$status" -eq 0 ]
    [ "$output" = "8.8.8.8" ]

    run resolve_ntp_server "127.0.0.1"
    [ "$status" -eq 0 ]
    [ "$output" = "127.0.0.1" ]
}

@test "NTP server resolution rejects invalid input" {
    run resolve_ntp_server ""
    [ "$status" -eq 1 ]

    # Invalid IP that's not a valid hostname either
    # (This would normally try to resolve via getent, which will fail)
    run resolve_ntp_server "256.256.256.256"
    [ "$status" -eq 1 ]
}

@test "IPv4 CSV validation accepts valid comma-separated lists" {
    run is_ipv4_csv "192.168.1.1"
    [ "$status" -eq 0 ]

    run is_ipv4_csv "192.168.1.1,8.8.8.8"
    [ "$status" -eq 0 ]

    run is_ipv4_csv "8.8.8.8,1.1.1.1,127.0.0.1"
    [ "$status" -eq 0 ]
}

@test "IPv4 CSV validation rejects invalid comma-separated lists" {
    run is_ipv4_csv ""
    [ "$status" -eq 1 ]

    run is_ipv4_csv "192.168.1.1,not-an-ip"
    [ "$status" -eq 1 ]

    run is_ipv4_csv "256.256.256.256"
    [ "$status" -eq 1 ]
}

@test "NTP CSV resolution resolves multiple IPv4 addresses" {
    export DHCP_NTP_SERVERS="8.8.8.8 1.1.1.1"
    run resolve_ntp_csv "$DHCP_NTP_SERVERS"
    [ "$status" -eq 0 ]
    [ "$output" = "8.8.8.8,1.1.1.1" ]
}

@test "NTP CSV resolution handles empty input" {
    run resolve_ntp_csv ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "build_ntp_option outputs valid NTP JSON fragment for IPv4 addresses" {
    export DHCP_NTP_SERVERS="8.8.8.8 1.1.1.1"
    run build_ntp_option
    [ "$status" -eq 0 ]
    # Output should be a valid JSON fragment starting with comma and newline
    [[ "$output" == *'"ntp-servers"'* ]]
    [[ "$output" == *'"data": "8.8.8.8,1.1.1.1"'* ]]
}

@test "build_ntp_option returns empty string for empty DHCP_NTP_SERVERS" {
    export DHCP_NTP_SERVERS=""
    run build_ntp_option
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "DHCP4 config template can be rendered with valid JSON output" {
    dhcp4_template="$repo_root/services/dhcp/kea-dhcp4.conf"
    dhcp4_output="$test_config_dir/kea-dhcp4.conf"

    # Build NTP option first
    ntp_opt="$(build_ntp_option)" || skip "NTP option building failed"
    export DHCP_NTP_OPTION="$ntp_opt"

    # Render the template
    run envsubst "$ENVSUBST_VARS" < "$dhcp4_template" > "$dhcp4_output"
    [ "$status" -eq 0 ]
    [ -f "$dhcp4_output" ]

    # Verify the output is valid JSON
    run jq empty "$dhcp4_output"
    [ "$status" -eq 0 ]
}

@test "DHCP4 config has expected Dhcp4 top-level structure" {
    dhcp4_template="$repo_root/services/dhcp/kea-dhcp4.conf"
    dhcp4_output="$test_config_dir/kea-dhcp4-struct.conf"

    ntp_opt="$(build_ntp_option)" || skip "NTP option building failed"
    export DHCP_NTP_OPTION="$ntp_opt"

    envsubst "$ENVSUBST_VARS" < "$dhcp4_template" > "$dhcp4_output"

    # Verify Dhcp4 top-level key exists
    run jq -e '.Dhcp4' "$dhcp4_output"
    [ "$status" -eq 0 ]

    # Verify subnet4 array exists
    run jq -e '.Dhcp4.subnet4 | type' "$dhcp4_output"
    [ "$status" -eq 0 ]
    [ "$output" = '"array"' ]

    # Verify first subnet has the expected fields
    run jq -e '.Dhcp4.subnet4[0].subnet' "$dhcp4_output"
    [ "$status" -eq 0 ]
    [[ "$output" == '"10.0.0.0/24"' ]]

    run jq -e '.Dhcp4.subnet4[0].pools[0].pool' "$dhcp4_output"
    [ "$status" -eq 0 ]
    [[ "$output" == '"10.0.0.128 - 10.0.0.254"' ]]
}

@test "DHCP4 config contains NTP server data in option-data" {
    dhcp4_template="$repo_root/services/dhcp/kea-dhcp4.conf"
    dhcp4_output="$test_config_dir/kea-dhcp4-ntp.conf"

    export DHCP_NTP_SERVERS="8.8.8.8 1.1.1.1"
    ntp_opt="$(build_ntp_option)" || skip "NTP option building failed"
    export DHCP_NTP_OPTION="$ntp_opt"

    envsubst "$ENVSUBST_VARS" < "$dhcp4_template" > "$dhcp4_output"

    # Verify NTP option is present in option-data
    run jq '.Dhcp4.subnet4[0]["option-data"] | map(select(.name == "ntp-servers")) | length' "$dhcp4_output"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    # Verify NTP servers are correctly inserted
    run jq -r '.Dhcp4.subnet4[0]["option-data"] | map(select(.name == "ntp-servers") | .data) | .[0]' "$dhcp4_output"
    [ "$status" -eq 0 ]
    [ "$output" = "8.8.8.8,1.1.1.1" ]
}

@test "Control Agent config template can be rendered with valid JSON output" {
    ctrl_agent_template="$repo_root/services/dhcp/kea-ctrl-agent.conf"
    ctrl_agent_output="$test_config_dir/kea-ctrl-agent.conf"

    # Render the template
    run envsubst "$ENVSUBST_VARS" < "$ctrl_agent_template" > "$ctrl_agent_output"
    [ "$status" -eq 0 ]
    [ -f "$ctrl_agent_output" ]

    # Verify the output is valid JSON
    run jq empty "$ctrl_agent_output"
    [ "$status" -eq 0 ]
}

@test "Control Agent config has expected structure with authentication" {
    ctrl_agent_template="$repo_root/services/dhcp/kea-ctrl-agent.conf"
    ctrl_agent_output="$test_config_dir/kea-ctrl-agent-struct.conf"

    envsubst "$ENVSUBST_VARS" < "$ctrl_agent_template" > "$ctrl_agent_output"

    # Verify Control-agent top-level key exists
    run jq -e '.["Control-agent"]' "$ctrl_agent_output"
    [ "$status" -eq 0 ]

    # Verify authentication structure
    run jq -e '.["Control-agent"].authentication.type' "$ctrl_agent_output"
    [ "$status" -eq 0 ]
    [[ "$output" == '"basic"' ]]

    # Verify credentials are present
    run jq -e '.["Control-agent"].authentication.clients[0].user' "$ctrl_agent_output"
    [ "$status" -eq 0 ]
    [[ "$output" == '"admin"' ]]

    run jq -e '.["Control-agent"].authentication.clients[0].password' "$ctrl_agent_output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"test-secret-token"* ]]
}

@test "DHCP-DDNS config template can be rendered with valid JSON output" {
    ddns_template="$repo_root/services/dhcp/kea-dhcp-ddns.conf"
    ddns_output="$test_config_dir/kea-dhcp-ddns.conf"

    # Render the template
    run envsubst "$ENVSUBST_VARS" < "$ddns_template" > "$ddns_output"
    [ "$status" -eq 0 ]
    [ -f "$ddns_output" ]

    # Verify the output is valid JSON
    run jq empty "$ddns_output"
    [ "$status" -eq 0 ]
}

@test "DHCP-DDNS config has DhcpDdns top-level structure" {
    ddns_template="$repo_root/services/dhcp/kea-dhcp-ddns.conf"
    ddns_output="$test_config_dir/kea-dhcp-ddns-struct.conf"

    envsubst "$ENVSUBST_VARS" < "$ddns_template" > "$ddns_output"

    # Verify DhcpDdns top-level key exists
    run jq -e '.DhcpDdns' "$ddns_output"
    [ "$status" -eq 0 ]

    # Verify port is set correctly
    run jq -e '.DhcpDdns.port' "$ddns_output"
    [ "$status" -eq 0 ]
    [ "$output" = "53001" ]
}

@test "DHCP-DDNS config contains TSIG key with correct structure" {
    ddns_template="$repo_root/services/dhcp/kea-dhcp-ddns.conf"
    ddns_output="$test_config_dir/kea-dhcp-ddns-tsig.conf"

    envsubst "$ENVSUBST_VARS" < "$ddns_template" > "$ddns_output"

    # Verify tsig-keys array exists
    run jq -e '.DhcpDdns["tsig-keys"] | type' "$ddns_output"
    [ "$status" -eq 0 ]
    [ "$output" = '"array"' ]

    # Verify first TSIG key structure
    run jq -e '.DhcpDdns["tsig-keys"][0].name' "$ddns_output"
    [ "$status" -eq 0 ]
    [[ "$output" == '"lancache-ddns-key"' ]]

    run jq -e '.DhcpDdns["tsig-keys"][0].algorithm' "$ddns_output"
    [ "$status" -eq 0 ]
    [[ "$output" == '"HMAC-SHA256"' ]]

    # Verify secret is substituted (should match the exported DDNS_TSIG_KEY)
    run jq -r '.DhcpDdns["tsig-keys"][0].secret' "$ddns_output"
    [ "$status" -eq 0 ]
    [ "$output" = "dGVzdC10c2lnLWtleS1iYXNlNjQtZW5jb2RlZA==" ]
}

@test "DHCP-DDNS config forward-ddns references TSIG key" {
    ddns_template="$repo_root/services/dhcp/kea-dhcp-ddns.conf"
    ddns_output="$test_config_dir/kea-dhcp-ddns-forward.conf"

    envsubst "$ENVSUBST_VARS" < "$ddns_template" > "$ddns_output"

    # Verify forward-ddns domains reference the TSIG key
    run jq -e '.DhcpDdns["forward-ddns"]["ddns-domains"][0]["key-name"]' "$ddns_output"
    [ "$status" -eq 0 ]
    [[ "$output" == '"lancache-ddns-key"' ]]

    # Verify DNS servers are configured
    run jq -e '.DhcpDdns["forward-ddns"]["ddns-domains"][0]["dns-servers"] | length' "$ddns_output"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "DHCP-DDNS config has domain suffix set from DHCP_DOMAIN" {
    export DHCP_DOMAIN="example.com"
    ddns_template="$repo_root/services/dhcp/kea-dhcp-ddns.conf"
    ddns_output="$test_config_dir/kea-dhcp-ddns-domain.conf"

    envsubst "$ENVSUBST_VARS" < "$ddns_template" > "$ddns_output"

    # Verify forward-ddns domain name is substituted
    run jq -r '.DhcpDdns["forward-ddns"]["ddns-domains"][0].name' "$ddns_output"
    [ "$status" -eq 0 ]
    [ "$output" = "example.com" ]
}
