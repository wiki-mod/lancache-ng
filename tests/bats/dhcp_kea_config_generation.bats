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
    # Fake but plausible: matches the real amd64 multiarch path
    # entrypoint.sh's `find /usr/lib -maxdepth 5 -name
    # libdhcp_lease_cmds.so` resolves at container startup. Only the
    # rendering/substitution behavior is under test here, not the `find`
    # discovery itself, so a fixed literal is fine.
    export KEA_LEASE_CMDS_HOOK_PATH="/usr/lib/x86_64-linux-gnu/kea/hooks/libdhcp_lease_cmds.so"

    # Must mirror entrypoint.sh's own ENVSUBST_VARS exactly (see
    # render_kea_config() there). Passing an explicit variable list to
    # envsubst -- instead of calling it with no arguments -- means only
    # these named variables get substituted; every other literal `$` in
    # the Kea JSON templates (there are none today, but a future template
    # edit could add one) is left untouched rather than silently replaced
    # by whatever happens to be in the shell environment. If this list
    # drifts from entrypoint.sh's, the test stops exercising the real
    # rendering behavior.
    export ENVSUBST_VARS='${DHCP_SUBNET}${DHCP_RANGE_START}${DHCP_RANGE_END}${DHCP_GATEWAY}${DHCP_DOMAIN}${DHCP_LEASE_TIME}${DHCP_NTP_OPTION}${DHCP_DNS_PRIMARY}${DHCP_DNS_SECONDARY}${KEA_CTRL_TOKEN}${DHCP_MAX_LEASE_TIME}${DDNS_TSIG_KEY}${DHCP_DNS_SERVER_IP}${DHCP_DNS_SERVER_IP_SSL}${DHCP_DDNS_PORT}${KEA_CTRL_HOST}${KEA_LEASE_CMDS_HOOK_PATH}'
}

# is_ipv4 is the fail-fast address-format gate used by the NTP-resolution
# helpers (resolve_ntp_server / is_ipv4_csv) and by the legacy NTP-servers
# migration path in migrate_dhcp4_config -- it is not invoked for every
# DHCP_*_IP/DHCP_*_SERVER value. DHCP_DNS_PRIMARY, DHCP_DNS_SECONDARY,
# DHCP_DNS_SERVER_IP, and DHCP_DNS_SERVER_IP_SSL are exported straight into
# the Kea templates in services/dhcp/entrypoint.sh with no is_ipv4 call at
# all; these values are not currently validated at startup, so a malformed
# one there would only surface later as a broken DNS/DDNS target, not as a
# fail-fast error here.
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

# Complements the accept-case above: out-of-range octets, truncated
# addresses, and empty strings must all fail closed here rather than reach
# envsubst and get baked into the Kea template as-is, where the only feedback
# would be Kea itself refusing to start on an otherwise-hard-to-diagnose
# config error.
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

# resolve_ntp_server accepts either an IP or a hostname (see the
# reject/hostname-resolution test below). When the input is already a valid
# IPv4 address, it must be returned as-is without attempting a DNS lookup --
# an unnecessary lookup would be pure overhead at best, and a spurious
# failure point (e.g. no resolver configured yet during early boot) at worst.
@test "NTP server resolution returns IPv4 addresses unchanged" {
    run resolve_ntp_server "8.8.8.8"
    [ "$status" -eq 0 ]
    [ "$output" = "8.8.8.8" ]

    run resolve_ntp_server "127.0.0.1"
    [ "$status" -eq 0 ]
    [ "$output" = "127.0.0.1" ]
}

# Both branches must fail closed, not just pass the bad value through: an
# empty NTP entry or an unresolvable garbage string reaching build_ntp_option
# would either produce a broken option-data fragment or silently configure
# clients to sync against nothing.
@test "NTP server resolution rejects invalid input" {
    run resolve_ntp_server ""
    [ "$status" -eq 1 ]

    # "256.256.256.256" is not a valid IPv4 address (octet > 255), and it
    # also isn't a resolvable hostname -- so this exercises the fallback
    # getent lookup path failing, not just the IPv4-format fast path above.
    run resolve_ntp_server "256.256.256.256"
    [ "$status" -eq 1 ]
}

# Operators can configure more than one NTP/DNS server as a comma-separated
# list; is_ipv4_csv is the gate that runs before that list is trusted. A
# single valid entry and a multi-entry list must both pass, since the
# generation logic downstream doesn't special-case list length.
@test "IPv4 CSV validation accepts valid comma-separated lists" {
    run is_ipv4_csv "192.168.1.1"
    [ "$status" -eq 0 ]

    run is_ipv4_csv "192.168.1.1,8.8.8.8"
    [ "$status" -eq 0 ]

    run is_ipv4_csv "8.8.8.8,1.1.1.1,127.0.0.1"
    [ "$status" -eq 0 ]
}

# The whole list must fail closed if even one entry is malformed -- there is
# no per-entry filtering downstream, so silently dropping the bad entry (or
# passing it through) would put an invalid address straight into Kea's JSON.
@test "IPv4 CSV validation rejects invalid comma-separated lists" {
    run is_ipv4_csv ""
    [ "$status" -eq 1 ]

    run is_ipv4_csv "192.168.1.1,not-an-ip"
    [ "$status" -eq 1 ]

    run is_ipv4_csv "256.256.256.256"
    [ "$status" -eq 1 ]
}

# DHCP_NTP_SERVERS is space-separated (matching how operators/setup.sh write
# it), but Kea's option-data "data" field needs a comma-separated string --
# resolve_ntp_csv is the format-conversion step, and it must correctly handle
# more than one entry, not just the single-server case.
@test "NTP CSV resolution resolves multiple IPv4 addresses" {
    export DHCP_NTP_SERVERS="8.8.8.8 1.1.1.1"
    run resolve_ntp_csv "$DHCP_NTP_SERVERS"
    [ "$status" -eq 0 ]
    [ "$output" = "8.8.8.8,1.1.1.1" ]
}

# No NTP servers configured is a common, valid state (e.g. a fresh install
# before an operator sets any), not an error case -- resolve_ntp_csv must
# produce clean empty output here so build_ntp_option can omit the NTP
# option-data entry entirely, rather than emitting a broken/empty fragment.
@test "NTP CSV resolution handles empty input" {
    run resolve_ntp_csv ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# This fragment gets spliced directly into $DHCP_NTP_OPTION inside the Dhcp4
# template via envsubst, not parsed/re-serialized -- so its exact JSON shape
# (the "ntp-servers" option-data entry) has to already be correct here. A
# malformed fragment would only surface later as a JSON syntax error in the
# full rendered template, several tests away from this one.
@test "build_ntp_option outputs valid NTP JSON fragment for IPv4 addresses" {
    export DHCP_NTP_SERVERS="8.8.8.8 1.1.1.1"
    run build_ntp_option
    [ "$status" -eq 0 ]
    [[ "$output" == *'"ntp-servers"'* ]]
    [[ "$output" == *'"data": "8.8.8.8,1.1.1.1"'* ]]
}

# When no NTP servers are configured, DHCP_NTP_OPTION must end up empty so
# envsubst drops the option-data entry cleanly -- an empty-but-present
# "ntp-servers" entry (rather than no entry at all) would fail Kea's own
# schema validation for that option.
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

    # Deliberately NOT `run envsubst ... > "$dhcp4_output"`: Bats' `run`
    # captures a command's stdout internally (via its own command
    # substitution) to populate $output, so an external `>` redirect on a
    # `run`-wrapped command writes an empty file, not the rendered content --
    # the JSON-validity check below would then trivially pass on 0 bytes of
    # input regardless of whether the template is actually valid. Running
    # the command directly (capturing $? by hand) and asserting the output
    # file is genuinely non-empty is what makes this test load-bearing.
    envsubst "$ENVSUBST_VARS" < "$dhcp4_template" > "$dhcp4_output"
    render_status=$?
    [ "$render_status" -eq 0 ]
    [ -s "$dhcp4_output" ]

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

    # `jq -e` fails (nonzero status) if the key is missing OR its value is
    # `null`/`false` -- not just absent -- so a template regression that
    # renders "Dhcp4": null would be caught here too, not just a missing key.
    run jq -e '.Dhcp4' "$dhcp4_output"
    [ "$status" -eq 0 ]

    # Kea requires subnet4 to be a JSON array even with a single subnet
    # defined; a template edit that accidentally collapses it to a bare
    # object would parse as valid JSON but be rejected by Kea at startup.
    run jq -e '.Dhcp4.subnet4 | type' "$dhcp4_output"
    [ "$status" -eq 0 ]
    [ "$output" = '"array"' ]

    # subnet/pool values here must match setup()'s DHCP_SUBNET/RANGE_START/
    # RANGE_END exactly -- this is the actual proof that the template
    # substitutes real operator-configured values, not just static
    # placeholders left over from the template file itself.
    run jq -e '.Dhcp4.subnet4[0].subnet' "$dhcp4_output"
    [ "$status" -eq 0 ]
    [[ "$output" == '"10.0.0.0/24"' ]]

    run jq -e '.Dhcp4.subnet4[0].pools[0].pool' "$dhcp4_output"
    [ "$status" -eq 0 ]
    [[ "$output" == '"10.0.0.128 - 10.0.0.254"' ]]

    # Proves KEA_LEASE_CMDS_HOOK_PATH is actually substituted into
    # hooks-libraries[0].library, not left as the literal
    # "${KEA_LEASE_CMDS_HOOK_PATH}" placeholder string. `jq empty` above only
    # checks JSON syntax -- an unsubstituted placeholder is still valid JSON
    # (just a string containing "$" and "{}"), so without this assertion CI
    # would keep passing even if this variable were dropped from
    # entrypoint.sh's ENVSUBST_VARS (or this test's own mirror above),
    # silently regressing to the arch-hardcoded/missing-hook bug this
    # variable fixed (#694).
    run jq -e '.Dhcp4["hooks-libraries"][0].library' "$dhcp4_output"
    [ "$status" -eq 0 ]
    [ "$output" = '"/usr/lib/x86_64-linux-gnu/kea/hooks/libdhcp_lease_cmds.so"' ]
}

@test "DHCP4 config contains NTP server data in option-data" {
    dhcp4_template="$repo_root/services/dhcp/kea-dhcp4.conf"
    dhcp4_output="$test_config_dir/kea-dhcp4-ntp.conf"

    export DHCP_NTP_SERVERS="8.8.8.8 1.1.1.1"
    ntp_opt="$(build_ntp_option)" || skip "NTP option building failed"
    export DHCP_NTP_OPTION="$ntp_opt"

    envsubst "$ENVSUBST_VARS" < "$dhcp4_template" > "$dhcp4_output"

    # Exactly one ntp-servers entry, not zero (dropped) or duplicated (e.g.
    # by a template edit that adds a second option-data block) -- either
    # failure mode would be silent at the JSON-validity level, since both
    # still parse as valid JSON.
    run jq '.Dhcp4.subnet4[0]["option-data"] | map(select(.name == "ntp-servers")) | length' "$dhcp4_output"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    # This is the true end-to-end check for this test: DHCP_NTP_SERVERS ->
    # build_ntp_option -> envsubst -> rendered JSON must round-trip to the
    # exact same comma-separated value, proving the full NTP pipeline (not
    # just build_ntp_option in isolation, per the tests above) works.
    run jq -r '.Dhcp4.subnet4[0]["option-data"] | map(select(.name == "ntp-servers") | .data) | .[0]' "$dhcp4_output"
    [ "$status" -eq 0 ]
    [ "$output" = "8.8.8.8,1.1.1.1" ]
}

@test "Control Agent config template can be rendered with valid JSON output" {
    ctrl_agent_template="$repo_root/services/dhcp/kea-ctrl-agent.conf"
    ctrl_agent_output="$test_config_dir/kea-ctrl-agent.conf"

    # Same rationale as the DHCP4 template's own "renders as valid JSON"
    # test above: this template carries KEA_CTRL_TOKEN/KEA_CTRL_HOST
    # substitutions of its own, so it needs its own independent JSON-validity
    # check rather than assuming the DHCP4 template's pass implies this one
    # is fine too. Not `run`-wrapped for the same reason as the DHCP4 test:
    # `run cmd > file` would leave $ctrl_agent_output empty and make the
    # jq check below trivially pass on 0 bytes.
    envsubst "$ENVSUBST_VARS" < "$ctrl_agent_template" > "$ctrl_agent_output"
    render_status=$?
    [ "$render_status" -eq 0 ]
    [ -s "$ctrl_agent_output" ]

    run jq empty "$ctrl_agent_output"
    [ "$status" -eq 0 ]
}

@test "Control Agent config has expected structure with authentication" {
    ctrl_agent_template="$repo_root/services/dhcp/kea-ctrl-agent.conf"
    ctrl_agent_output="$test_config_dir/kea-ctrl-agent-struct.conf"

    envsubst "$ENVSUBST_VARS" < "$ctrl_agent_template" > "$ctrl_agent_output"

    # Kea's Control Agent process is what actually listens for the Admin
    # UI's API calls -- if this whole block silently vanished (e.g. a
    # template refactor that renamed the key), the Control Agent would start
    # with no API socket at all, and the UI would fail with a generic
    # connection-refused error miles away from the real cause.
    run jq -e '.["Control-agent"]' "$ctrl_agent_output"
    [ "$status" -eq 0 ]

    # "basic" is required, not optional: without it the Control Agent would
    # accept unauthenticated API calls on $KEA_CTRL_HOST, which matters
    # because that host is deliberately "0.0.0.0" in setup() (and in real
    # deployments) rather than localhost-only.
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

    # Unlike the fixed "admin" username above, the password/token IS the
    # substituted, deployment-specific secret ($KEA_CTRL_TOKEN) -- checking
    # for a substring rather than an exact match tolerates envsubst
    # whitespace handling without weakening the assertion that the real
    # token (not a placeholder) ends up in the rendered config.
    run jq -e '.["Control-agent"].authentication.clients[0].password' "$ctrl_agent_output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"test-secret-token"* ]]
}

@test "DHCP-DDNS config template can be rendered with valid JSON output" {
    ddns_template="$repo_root/services/dhcp/kea-dhcp-ddns.conf"
    ddns_output="$test_config_dir/kea-dhcp-ddns.conf"

    # Third and last template with its own JSON-validity check (DHCP4,
    # Control Agent above) -- this one carries the TSIG/DDNS substitutions
    # (DDNS_TSIG_KEY, DHCP_DNS_SERVER_IP(_SSL), DHCP_DDNS_PORT), the
    # densest set of secrets/networking values of the three templates. Not
    # `run`-wrapped for the same reason as the other two: `run cmd > file`
    # would leave $ddns_output empty and make the jq check below trivially
    # pass on 0 bytes.
    envsubst "$ENVSUBST_VARS" < "$ddns_template" > "$ddns_output"
    render_status=$?
    [ "$render_status" -eq 0 ]
    [ -s "$ddns_output" ]

    run jq empty "$ddns_output"
    [ "$status" -eq 0 ]
}

@test "DHCP-DDNS config has DhcpDdns top-level structure" {
    ddns_template="$repo_root/services/dhcp/kea-dhcp-ddns.conf"
    ddns_output="$test_config_dir/kea-dhcp-ddns-struct.conf"

    envsubst "$ENVSUBST_VARS" < "$ddns_template" > "$ddns_output"

    # If this whole block were missing, kea-dhcp-ddns would start with no
    # DDNS configuration at all -- DHCP leases would still work, but zone
    # updates to PowerDNS would silently never happen, with no error visible
    # anywhere except a DNS record simply never appearing.
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

    # Must be an array even with only one key defined -- same reasoning as
    # Dhcp4.subnet4's array-type check above: Kea's schema requires it, and
    # a collapsed single-object would still be valid JSON but invalid Kea
    # config.
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

    # This is the link that actually makes DDNS updates authenticate: a
    # ddns-domains entry with no key-name (or a key-name that doesn't match
    # tsig-keys[0].name above) would make Kea send unsigned or
    # wrongly-signed updates, which PowerDNS would then reject.
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

@test "DHCP-DDNS config reverse-ddns references TSIG key" {
    ddns_template="$repo_root/services/dhcp/kea-dhcp-ddns.conf"
    ddns_output="$test_config_dir/kea-dhcp-ddns-reverse.conf"

    envsubst "$ENVSUBST_VARS" < "$ddns_template" > "$ddns_output"

    # Same authentication link as forward-ddns above, but for PTR/reverse-zone
    # updates: a reverse-ddns entry with no key-name (or one that drifts from
    # tsig-keys[0].name above) would make Kea send unsigned or wrongly-signed
    # PTR updates, which PowerDNS would then reject -- silently, since a
    # missing/wrong reverse key-name does not affect forward-ddns at all.
    run jq -e '.DhcpDdns["reverse-ddns"]["ddns-domains"][0]["key-name"]' "$ddns_output"
    [ "$status" -eq 0 ]
    [[ "$output" == '"lancache-ddns-key"' ]]

    # Same two-entry invariant as forward-ddns: both the standard-mode and
    # SSL-mode DNS containers are kept in sync for reverse/PTR updates too,
    # regardless of which mode is presently active.
    run jq -e '.DhcpDdns["reverse-ddns"]["ddns-domains"][0]["dns-servers"] | length' "$ddns_output"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "DHCP-DDNS config has domain suffix set from DHCP_DOMAIN" {
    # Overrides setup()'s default "lan" specifically to prove the domain
    # name is a live template substitution, not a value that happens to
    # match by coincidence. Note this is an entrypoint/deploy-time value
    # (DHCP_DOMAIN defaults to "lan" in services/dhcp/entrypoint.sh, set via
    # container env, not the live Admin UI): the UI's subnet-edit path
    # (apply_subnet_value) explicitly preserves ddns-qualifying-suffix
    # unmanaged, so changing the LAN domain in the UI does NOT make DDNS
    # start updating a new zone at runtime -- this test only proves the
    # container-startup substitution itself works, not a live UI-driven
    # DDNS zone change.
    export DHCP_DOMAIN="example.com"
    ddns_template="$repo_root/services/dhcp/kea-dhcp-ddns.conf"
    ddns_output="$test_config_dir/kea-dhcp-ddns-domain.conf"

    envsubst "$ENVSUBST_VARS" < "$ddns_template" > "$ddns_output"

    # Confirms the override above actually took effect in the rendered
    # output, not just in the shell environment -- i.e. this is the assert
    # half of the test, proving envsubst substituted the live value rather
    # than some cached/default one.
    #
    # Expected value has a trailing dot (issue #706), not just the raw
    # DHCP_DOMAIN: the template hardcodes "${DHCP_DOMAIN}." because Kea's
    # D2 daemon matches this "name" field as a DNS-name suffix, and without
    # the trailing dot it's parsed as a bare, non-fully-qualified label that
    # never matches any real (dotted) FQDN D2 tries to update -- see
    # services/dhcp/entrypoint.sh's comment above its kea-dhcp-ddns.conf
    # rendering step for the full empirical finding.
    run jq -r '.DhcpDdns["forward-ddns"]["ddns-domains"][0].name' "$ddns_output"
    [ "$status" -eq 0 ]
    [ "$output" = "example.com." ]
}
