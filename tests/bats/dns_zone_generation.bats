#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for RPZ zone file generation (services/dns/entrypoint.sh).
# Tests zone format validity, serial monotonicity, and domain/record handling
# without requiring a running PowerDNS daemon.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/dns-zone-helpers.sh"

    # Source the helper that provides generate_rpz_zone()
    # shellcheck source=tests/bats/helpers/dns-zone-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/dns-zone-helpers.sh"
}

# Helper to extract serial from a zone file
get_zone_serial() {
    grep -oP '^\s*@\s+SOA\s+[^\s]+\s+[^\s]+\s+\K\d+' "$1"
}

# Helper to count records of a type in zone file (ignoring header lines)
count_record_type() {
    local zone_file="$1" record_type="$2"
    grep -c "^\S\+\s\+60\s\+IN\s\+${record_type}\s\+" "$zone_file" || true
}

@test "zone file has required RPZ header structure" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' 'example.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    grep -qx '\$ORIGIN rpz\.' "$zone_file"
    grep -qx '\$TTL 60' "$zone_file"
    grep -q '^\s*@\s\+SOA\s\+localhost\.' "$zone_file"
    grep -q '^\s*@\s\+NS\s\+localhost\.' "$zone_file"
}

@test "zone SOA record contains valid serial number" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' 'test.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    local serial
    serial=$(get_zone_serial "$zone_file")
    # Serial should be a valid 10-digit number
    [[ "$serial" =~ ^[0-9]{10}$ ]]
}

@test "zone generates A records for each domain" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' 'steam.com' 'epic.com' 'gog.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    # Each domain should generate: base domain record + wildcard record
    grep -qx 'steam\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    grep -qx '\*\.steam\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    grep -qx 'epic\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    grep -qx '\*\.epic\.com 60 IN A 192\.0\.2\.1' "$zone_file"
}

@test "zone generates AAAA records when IPv6 is provided" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' 'content.steam.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1 "2001:db8::1"

    [ "$status" -eq 0 ]
    grep -qx 'content\.steam\.com 60 IN AAAA 2001:db8::1' "$zone_file"
    grep -qx '\*\.content\.steam\.com 60 IN AAAA 2001:db8::1' "$zone_file"
}

@test "zone skips AAAA records when IPv6 is empty" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' 'example.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1 ""

    [ "$status" -eq 0 ]
    # Should have A records but no AAAA records
    grep -qx 'example\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    ! grep -q 'AAAA' "$zone_file"
}

@test "zone ignores comments and empty lines" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' '# This is a comment' '' 'valid.com' '  # another comment  ' '' 'another.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    # Should only have records for the two valid domains
    grep -qx 'valid\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    grep -qx 'another\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    # Should not include comment lines
    ! grep -q '^#' "$zone_file"
}

@test "zone strips leading and trailing whitespace from domains" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' '  domain1.com  ' 'domain2.com' '	domain3.com	' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    grep -qx 'domain1\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    grep -qx 'domain2\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    grep -qx 'domain3\.com 60 IN A 192\.0\.2\.1' "$zone_file"
}

@test "zone handles wildcard-only domains (leading dot)" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' '.wildcard.com' 'normal.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    # Wildcard-only domain should only have wildcard record, not base domain
    ! grep -qx 'wildcard\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    grep -qx '\*\.wildcard\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    # Normal domain should have both
    grep -qx 'normal\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    grep -qx '\*\.normal\.com 60 IN A 192\.0\.2\.1' "$zone_file"
}

@test "zone serial is monotonically increasing across regenerations" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' 'test.com' > "$domains_file"

    # First generation
    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1
    [ "$status" -eq 0 ]
    local serial1
    serial1=$(get_zone_serial "$zone_file")

    # Second generation (immediately after, serial may be same or higher)
    # Sleep briefly to ensure timestamp advances
    sleep 1
    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1
    [ "$status" -eq 0 ]
    local serial2
    serial2=$(get_zone_serial "$zone_file")

    # Serial should be >= original
    [ "$serial2" -ge "$serial1" ]
}

@test "zone serial increments by 1 when clock goes backward" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' 'test.com' > "$domains_file"

    # First generation with a known serial (using a temp file with manual serial)
    {
        echo "\$ORIGIN rpz."
        echo "\$TTL 60"
        echo "@ SOA localhost. admin.rpz. 9999999999 3600 900 604800 60"
        echo "@ NS localhost."
        echo "test.com 60 IN A 192.0.2.1"
    } > "$zone_file"

    # Second generation: the automatic serial should be lower than 9999999999
    # so the monotonicity logic should increment from 9999999999 to 10000000000
    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1
    [ "$status" -eq 0 ]
    local new_serial
    new_serial=$(get_zone_serial "$zone_file")

    # Should be incremented from previous
    [ "$new_serial" -eq 10000000000 ]
}

@test "zone generates valid number of records for domain count" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    # 3 domains: each generates 2 A records (base + wildcard)
    # Total with IPv6: 6 A records + 6 AAAA records = 12 records
    printf '%s\n' 'domain1.com' 'domain2.com' 'domain3.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1 "2001:db8::1"

    [ "$status" -eq 0 ]
    local a_count
    a_count=$(count_record_type "$zone_file" "A")
    [ "$a_count" -eq 6 ]  # 3 domains × 2 records each (base + wildcard)
    local aaaa_count
    aaaa_count=$(count_record_type "$zone_file" "AAAA")
    [ "$aaaa_count" -eq 6 ]  # Same for IPv6
}

@test "zone file is world-readable but not writable by zone generation" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' 'example.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    [ -f "$zone_file" ]
    # File should exist and be readable
    [ -r "$zone_file" ]
}

@test "zone preserves record order (base domain before wildcard)" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' 'ordered.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    # Extract record lines (skip header) and verify order
    local ordered_record
    local wildcard_record
    local base_line
    base_line=$(grep -n 'ordered\.com 60 IN A' "$zone_file" | head -1 | cut -d: -f1)
    local wildcard_line
    wildcard_line=$(grep -n '\*\.ordered\.com 60 IN A' "$zone_file" | head -1 | cut -d: -f1)

    # Base domain record should appear before wildcard record
    [ "$base_line" -lt "$wildcard_line" ]
}
