#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for RPZ zone file generation (services/dns/entrypoint.sh).
# Tests zone format validity, serial monotonicity, and domain/record handling
# without requiring a running PowerDNS daemon.

# `run !` (used below to correctly fail a test on a negated assertion, see
# the SC2314 comments at each use site) requires Bats >= 1.5.0. Declaring
# this turns a silent BW02 runtime warning into a clear version-mismatch
# failure if this suite ever runs under an older Bats.
bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # generate_rpz_zone() calls _is_valid_domain/_normalize_domain (#822
    # pattern audit fix); source the canonical library first so the helper
    # has them available, matching how services/dns/entrypoint.sh's real
    # embedded copy is available to its own call site.
    # shellcheck source=scripts/lib/domain-validation.sh
    source "$repo_root/scripts/lib/domain-validation.sh"

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

# PowerDNS's RPZ (Response Policy Zone) mechanism requires a specific SOA and NS header structure
# to load the zone file at all; a malformed header results in silent DNS resolution failure,
# not an obvious parse error.
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

# The SOA serial format (10 digits derived from unix timestamp) is critical because PowerDNS
# and downstream secondaries use it to detect zone changes; this test checks the format itself,
# separately from the monotonic-increase invariant (tested in later tests).
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

# This is the core case: each domain generates both a base record and a wildcard record.
# The wildcard-handling, AAAA-generation, and record-order tests below all depend on this behavior.
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
    # A bare "! cmd" does not fail a Bats test on its own (SC2314): Bats runs
    # test bodies under `set -e`, and bash exempts a "!"-negated command from
    # triggering errexit, so a failing assertion here would silently fall
    # through to whatever runs next instead of failing the test.
    run ! grep -q 'AAAA' "$zone_file"
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
    # Should not include comment lines. See the SC2314 comment above: a bare
    # "! cmd" wouldn't fail this test if a comment line leaked into the zone.
    run ! grep -q '^#' "$zone_file"
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
    # Wildcard-only domain should only have wildcard record, not base domain.
    # See the SC2314 comment above: this assertion is followed by more
    # assertions, so a bare "! cmd" here would not fail the test on its own.
    run ! grep -qx 'wildcard\.com 60 IN A 192\.0\.2\.1' "$zone_file"
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

# Verifies the generated zone file is accessible (readable) after generation, since PowerDNS
# may run as a different user and needs to be able to read the zone file to load it.
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

# Keeps the generated zone file easy to read and diff: the base domain record immediately
# followed by its wildcard record, not interleaved with other domains.
@test "zone preserves record order (base domain before wildcard)" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' 'ordered.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    # Extract record lines (skip header) and verify order
    local base_line
    base_line=$(grep -n 'ordered\.com 60 IN A' "$zone_file" | head -1 | cut -d: -f1)
    local wildcard_line
    wildcard_line=$(grep -n '\*\.ordered\.com 60 IN A' "$zone_file" | head -1 | cut -d: -f1)

    # Base domain record should appear before wildcard record
    [ "$base_line" -lt "$wildcard_line" ]
}

# #822 pattern audit: RPZ generation previously had zero domain validation.
# A malformed or overly-broad entry (here, a bare TLD) would generate a
# "*.com"-style wildcard rule matching almost every domain under that TLD --
# a real security gap, not just a cosmetic one. This proves the fix is wired
# into the actual generation path generate_rpz_zone() exercises (not just
# proven correct in isolation by domain_validation_parity.bats), and that
# the WARNING is emitted so an operator notices the entry was dropped.
@test "generate_rpz_zone skips a bare-TLD entry instead of emitting an overly-broad wildcard rule" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' 'com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: skipping invalid domain entry in RPZ zone: com"* ]]
    # A bare "! cmd" would not fail this test on its own (SC2314): the first
    # assertion here is followed by a second one, and Bats' `set -e` does not
    # treat a negated command's failure as fatal, so a real regression (the
    # overly-broad "*.com" rule this test exists to catch) could silently
    # pass if only the second assertion's result determined the outcome.
    run ! grep -q '\*\.com ' "$zone_file"
    run ! grep -q '^com ' "$zone_file"
}

# Same class of gap, for a literal "*" entry (as broad as an RPZ rule can
# get -- would match every domain PowerDNS resolves).
@test "generate_rpz_zone skips a literal '*' entry" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' '*' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: skipping invalid domain entry in RPZ zone: *"* ]]
    run ! grep -q '^\*\.\* ' "$zone_file"
}

# A mixed file (one bad entry alongside good ones) must still process the
# valid entries normally -- one malformed line must not abort the whole
# zone or silently drop unrelated, valid domains too.
@test "generate_rpz_zone processes valid entries normally alongside a skipped invalid one" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    {
        printf '%s\n' 'good.example.com'
        printf '%s\n' 'com'
        printf '%s\n' 'also-good.example.com'
    } > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    grep -q '^good\.example\.com 60 IN A' "$zone_file"
    grep -q '^also-good\.example\.com 60 IN A' "$zone_file"
    [[ "$output" == *"WARNING: skipping invalid domain entry in RPZ zone: com"* ]]
    run ! grep -q '\*\.com ' "$zone_file"
}

# #1073: the Admin UI's per-domain toggle disables an entry by prefixing it
# with "!" instead of deleting the line. RPZ generation must skip such a row
# entirely -- no A/AAAA record at all, and (unlike a genuinely malformed
# entry) no WARNING, since this is a deliberate operator choice, not a
# degraded config.
@test "generate_rpz_zone skips a disabled ('!'-prefixed) entry without emitting a WARNING" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' '!disabled.example.com' 'enabled.example.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    # Checked right after generate_rpz_zone's own run, before any further
    # `run` command -- `run` (including a negated `run !`) always overwrites
    # $output with its own command's output, so asserting this any later
    # would silently check the wrong command's output instead of actually
    # verifying generate_rpz_zone stayed quiet for a disabled entry.
    [[ "$output" != *"WARNING"* ]]
    run ! grep -q 'disabled\.example\.com' "$zone_file"
    grep -qx 'enabled\.example\.com 60 IN A 192\.0\.2\.1' "$zone_file"
}

# Same skip, for a disabled wildcard-only entry ("!." combination) -- the
# disabled check must run before the wildcard-dot marker is stripped, so a
# disabled wildcard entry is skipped just like a disabled plain one, not
# misread as a plain domain literally named "!.disabled-wild.example.com".
@test "generate_rpz_zone skips a disabled wildcard-only ('!.') entry" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' '!.disabled-wild.example.com' 'still-enabled.example.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    run ! grep -q 'disabled-wild' "$zone_file"
    grep -qx '\*\.still-enabled\.example\.com 60 IN A 192\.0\.2\.1' "$zone_file"
}
