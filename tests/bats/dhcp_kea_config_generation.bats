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

    # Must mirror entrypoint.sh's own ENVSUBST_VARS exactly (see
    # render_kea_config() there). Passing an explicit variable list to
    # envsubst -- instead of calling it with no arguments -- means only
    # these named variables get substituted; every other literal `$` in
    # the Kea JSON templates (there are none today, but a future template
    # edit could add one) is left untouched rather than silently replaced
    # by whatever happens to be in the shell environment. If this list
    # drifts from entrypoint.sh's, the test stops exercising the real
    # rendering behavior.
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

    # `jq empty` parses without producing output -- it's the standard way to
    # check "is this syntactically valid JSON" without asserting on content.
    # This matters because Kea refuses to start on malformed config; a
    # template edit that breaks JSON syntax (e.g. a stray trailing comma)
    # should fail here, in CI, not at container boot on a real deployment.
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

    # The username is a fixed literal "admin" in the template, not
    # substituted from an env var -- Kea's Basic-Auth scheme requires *a*
    # username, but this deployment only ever has one caller (the Admin UI's
    # Kea client), so the real secret is the password/token below, not the
    # username. Asserting the literal here catches a template edit that
    # accidentally parameterizes or renames it, which would break the UI's
    # hardcoded Kea API client credentials.
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

    # 53001 is DhcpDdns's own fixed internal control-channel port (where
    # kea-dhcp4 sends it NameChangeRequests), hardcoded in the template --
    # it is NOT the same thing as $DHCP_DDNS_PORT below, which configures
    # the *outbound* port DhcpDdns forwards those updates to on the
    # DNS/PowerDNS side. Confusing the two would silently misroute DDNS
    # updates, so this asserts the internal port never becomes accidentally
    # parameterized.
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

    # "lancache-ddns-key" is a fixed literal, referenced by name from both
    # forward-ddns and reverse-ddns below -- Kea matches DDNS domains to
    # TSIG keys purely by this string, so if the name here ever drifted from
    # what forward-ddns/reverse-ddns reference, DDNS updates would fail
    # signature verification at the PowerDNS side with no obvious error
    # pointing back to this template.
    run jq -e '.DhcpDdns["tsig-keys"][0].name' "$ddns_output"
    [ "$status" -eq 0 ]
    [[ "$output" == '"lancache-ddns-key"' ]]

    # HMAC-SHA256 is required, not a stylistic choice: PowerDNS's own TSIG
    # keys for the same zone (services/dns) must use the identical algorithm
    # and secret, or DDNS updates signed by Kea are rejected as invalid on
    # arrival -- this asserts Kea's side of that shared contract.
    run jq -e '.DhcpDdns["tsig-keys"][0].algorithm' "$ddns_output"
    [ "$status" -eq 0 ]
    [[ "$output" == '"HMAC-SHA256"' ]]

    # The secret is a pre-base64-encoded value (generated once by setup.sh
    # and shared verbatim with PowerDNS) -- envsubst must not alter it in
    # any way (no re-encoding, no whitespace/newline trimming beyond what
    # the shell already does), since PowerDNS decodes it independently and
    # any mismatch breaks DDNS auth silently rather than erroring loudly.
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

    # Two entries, not one: the template always lists both the standard-mode
    # and SSL-mode DNS containers ($DHCP_DNS_SERVER_IP /
    # $DHCP_DNS_SERVER_IP_SSL) as DDNS targets, regardless of which mode is
    # actually active, so Kea keeps both DNS instances' zone data in sync
    # even if only one is presently serving traffic.
    run jq -e '.DhcpDdns["forward-ddns"]["ddns-domains"][0]["dns-servers"] | length' "$ddns_output"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "DHCP-DDNS config has domain suffix set from DHCP_DOMAIN" {
    # Overrides setup()'s default "lan" specifically to prove the domain
    # name is a live template substitution, not a value that happens to
    # match by coincidence -- an operator who changes their LAN domain in
    # the UI must see DDNS start updating that new zone, not silently keep
    # writing to "lan.".
    export DHCP_DOMAIN="example.com"
    ddns_template="$repo_root/services/dhcp/kea-dhcp-ddns.conf"
    ddns_output="$test_config_dir/kea-dhcp-ddns-domain.conf"

    envsubst "$ENVSUBST_VARS" < "$ddns_template" > "$ddns_output"

    # Verify forward-ddns domain name is substituted
    run jq -r '.DhcpDdns["forward-ddns"]["ddns-domains"][0].name' "$ddns_output"
    [ "$status" -eq 0 ]
    [ "$output" = "example.com" ]
}
