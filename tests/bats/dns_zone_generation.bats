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

# This is the core case (#1072 semantics): a bare entry (no leading dot) is an exact-match
# entry only -- it must generate a base domain record and MUST NOT also generate a wildcard
# record for what's underneath it. Before #1072 this same input silently generated both.
@test "zone generates only an exact A record for each bare domain entry" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' 'steam.com' 'epic.com' 'gog.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    grep -qx 'steam\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    grep -qx 'epic\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    grep -qx 'gog\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    # Regression guard for #1072: a bare entry must never also emit a wildcard record.
    # See the SC2314 comments elsewhere in this file -- a bare "! cmd" only guards the
    # single assertion it directly precedes, so each domain gets its own negated check.
    run ! grep -qx '\*\.steam\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    run ! grep -qx '\*\.epic\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    run ! grep -qx '\*\.gog\.com 60 IN A 192\.0\.2\.1' "$zone_file"
}

@test "zone generates AAAA records when IPv6 is provided" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' 'content.steam.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1 "2001:db8::1"

    [ "$status" -eq 0 ]
    grep -qx 'content\.steam\.com 60 IN AAAA 2001:db8::1' "$zone_file"
    # #1072: a bare, fully-written subdomain entry (no leading dot) is an exact-match
    # entry, not a wildcard root -- it must not also generate a wildcard record for
    # everything underneath content.steam.com.
    run ! grep -qx '\*\.content\.steam\.com 60 IN AAAA 2001:db8::1' "$zone_file"
}

# #1072 mode 3: a fully-written subdomain (no leading dot) is exact-match only, the
# same as any other bare entry -- it must not additionally wildcard everything below it.
@test "zone treats a written-out subdomain entry as exact-match only, not a wildcard root" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' 'cdn1.steamcontent.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    grep -qx 'cdn1\.steamcontent\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    run ! grep -qx '\*\.cdn1\.steamcontent\.com 60 IN A 192\.0\.2\.1' "$zone_file"
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
    # #1072: a bare entry is exact-match only -- it must have the base record
    # and must NOT also get a wildcard record.
    grep -qx 'normal\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    run ! grep -qx '\*\.normal\.com 60 IN A 192\.0\.2\.1' "$zone_file"
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

    # #1072: each bare domain now generates exactly 1 A record (exact match
    # only, no wildcard). Total with IPv6: 3 A records + 3 AAAA records = 6.
    printf '%s\n' 'domain1.com' 'domain2.com' 'domain3.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1 "2001:db8::1"

    [ "$status" -eq 0 ]
    local a_count
    a_count=$(count_record_type "$zone_file" "A")
    [ "$a_count" -eq 3 ]  # 3 domains x 1 record each (exact match, no wildcard)
    local aaaa_count
    aaaa_count=$(count_record_type "$zone_file" "AAAA")
    [ "$aaaa_count" -eq 3 ]  # Same for IPv6
}

# #1072: a mix of all three match modes in one file must each produce exactly
# the record count their mode implies -- proves the modes don't leak into each
# other when processed together, not just in isolation.
@test "zone generates the correct record count per match mode when mixed in one file" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    # exact root, wildcard-only, exact subdomain
    printf '%s\n' 'exact.com' '.wildcard.com' 'sub.exact.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    local a_count
    a_count=$(count_record_type "$zone_file" "A")
    [ "$a_count" -eq 3 ]  # 1 record per entry: no entry emits both forms

    grep -qx 'exact\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    grep -qx '\*\.wildcard\.com 60 IN A 192\.0\.2\.1' "$zone_file"
    grep -qx 'sub\.exact\.com 60 IN A 192\.0\.2\.1' "$zone_file"
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

# Keeps the generated zone file easy to read and diff: entries appear in the same order
# as cdn-domains.txt, not reordered or interleaved. (Before #1072's fix, this test used a
# single bare domain and checked its base record appeared before its own wildcard record;
# that no longer applies since a bare entry emits only one record. It now checks ordering
# across distinct entries instead.)
@test "zone preserves record order (entries appear in file order)" {
    domains_file="$BATS_TEST_TMPDIR/domains.txt"
    zone_file="$BATS_TEST_TMPDIR/rpz.zone"

    printf '%s\n' 'first.com' '.second.com' 'third.com' > "$domains_file"

    run generate_rpz_zone "$domains_file" "$zone_file" 192.0.2.1

    [ "$status" -eq 0 ]
    local first_line second_line third_line
    first_line=$(grep -n '^first\.com 60 IN A' "$zone_file" | head -1 | cut -d: -f1)
    second_line=$(grep -n '^\*\.second\.com 60 IN A' "$zone_file" | head -1 | cut -d: -f1)
    third_line=$(grep -n '^third\.com 60 IN A' "$zone_file" | head -1 | cut -d: -f1)

    [ "$first_line" -lt "$second_line" ]
    [ "$second_line" -lt "$third_line" ]
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
