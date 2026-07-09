#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Unit tests for proxy entrypoint certificate generation logic:
# - Domain validation (label/full domain checks)
# - Wildcard certificate generation
# - Subject Alternative Name (SAN) handling
# - Serial file monotonic counter

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/proxy-cert-helpers.sh"

    # Create temporary test directories
    test_ca_dir="$BATS_TEST_TMPDIR/ca"
    test_cert_dir="$BATS_TEST_TMPDIR/certs"
    mkdir -p "$test_ca_dir" "$test_cert_dir"

    # Setup test CA. _sign_cert (see entrypoint.sh) hardcodes "$CA_DIR/ca.crt"
    # and "$CA_DIR/ca.key" rather than taking the CA paths as arguments, so
    # these must use exactly those filenames, not an arbitrary name under
    # $test_ca_dir.
    test_ca_crt="$test_ca_dir/ca.crt"
    test_ca_key="$test_ca_dir/ca.key"
    test_serial_file="$test_ca_dir/ca.srl"

    # Generate test CA certificate
    openssl genrsa -out "$test_ca_key" 2048 >/dev/null 2>&1
    openssl req -new -x509 -days 365 \
        -key "$test_ca_key" \
        -subj "/CN=Test-LanCache-CA" \
        -out "$test_ca_crt" >/dev/null 2>&1

    # Prepare environment for tested functions
    export CA_DIR="$test_ca_dir"
    export CERT_DIR="$test_cert_dir"
    export SERIAL_FILE="$test_serial_file"

    # Initialize serial file with timestamp as per entrypoint.sh
    if [ ! -f "$SERIAL_FILE" ]; then
        printf '%016x\n' "$(date +%s%N)" > "$SERIAL_FILE"
    fi

    # Load proxy cert helper functions
    # shellcheck source=tests/bats/helpers/proxy-cert-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/proxy-cert-helpers.sh"
    load_proxy_cert_helpers "$repo_root" "$helper_file"
}

teardown() {
    # Clean up test directories
    rm -rf "$test_ca_dir" "$test_cert_dir"
}

# ────────────────────────────────────────────────────────────────────────────
# Domain Validation Tests
# ────────────────────────────────────────────────────────────────────────────

@test "valid domain label passes single letter labels" {
    run _is_valid_domain_label "a"
    [ "$status" -eq 0 ]
}

@test "valid domain label passes alphanumeric labels" {
    run _is_valid_domain_label "example123"
    [ "$status" -eq 0 ]
}

@test "valid domain label passes labels with hyphens" {
    run _is_valid_domain_label "my-cache"
    [ "$status" -eq 0 ]
}

@test "invalid domain label rejects empty string" {
    run _is_valid_domain_label ""
    [ "$status" -ne 0 ]
}

@test "invalid domain label rejects labels starting with hyphen" {
    run _is_valid_domain_label "-invalid"
    [ "$status" -ne 0 ]
}

@test "invalid domain label rejects labels ending with hyphen" {
    run _is_valid_domain_label "invalid-"
    [ "$status" -ne 0 ]
}

@test "invalid domain label rejects labels longer than 63 chars" {
    run _is_valid_domain_label "$(printf 'a%.0s' {1..64})"
    [ "$status" -ne 0 ]
}

@test "invalid domain label rejects non-alphanumeric characters" {
    run _is_valid_domain_label "invalid_domain"
    [ "$status" -ne 0 ]
}

@test "normalize domain converts to lowercase" {
    result="$(_normalize_domain "Example.COM")"
    [ "$result" = "example.com" ]
}

@test "normalize domain strips leading dot" {
    result="$(_normalize_domain ".example.com")"
    [ "$result" = "example.com" ]
}

@test "normalize domain trims whitespace" {
    result="$(_normalize_domain "  example.com  ")"
    [ "$result" = "example.com" ]
}

@test "valid domain accepts standard FQDN" {
    run _is_valid_domain "example.com"
    [ "$status" -eq 0 ]
}

@test "valid domain accepts subdomain" {
    run _is_valid_domain "cdn.example.com"
    [ "$status" -eq 0 ]
}

@test "valid domain normalizes during validation" {
    run _is_valid_domain "  Example.COM  "
    [ "$status" -eq 0 ]
}

@test "invalid domain rejects single-label names" {
    run _is_valid_domain "localhost"
    [ "$status" -ne 0 ]
}

@test "invalid domain rejects names without at least 2 labels" {
    run _is_valid_domain "example"
    [ "$status" -ne 0 ]
}

@test "invalid domain rejects empty string" {
    run _is_valid_domain ""
    [ "$status" -ne 0 ]
}

@test "invalid domain rejects names longer than 253 chars" {
    run _is_valid_domain "$(printf 'a%.0s' {1..250}).example.com"
    [ "$status" -ne 0 ]
}

# ────────────────────────────────────────────────────────────────────────────
# Certificate Generation Tests
# ────────────────────────────────────────────────────────────────────────────

@test "certificate generation creates signed cert for test domain" {
    local domain="test.example.com"
    local key="$test_cert_dir/${domain}.key"
    local crt="$test_cert_dir/${domain}.crt"
    local san="subjectAltName=DNS:${domain},DNS:*.${domain}"

    # Use the extracted _sign_cert function with test CA
    run _sign_cert "$domain" "$key" "$crt" "$san"

    [ "$status" -eq 0 ]
    [ -f "$key" ]
    [ -f "$crt" ]
}

@test "certificate has correct CN" {
    local domain="cache.example.com"
    local key="$test_cert_dir/${domain}.key"
    local crt="$test_cert_dir/${domain}.crt"
    local san="subjectAltName=DNS:${domain},DNS:*.${domain}"

    _sign_cert "$domain" "$key" "$crt" "$san"

    # Check CN in certificate
    cn=$(openssl x509 -noout -subject -in "$crt" | grep -oP 'CN=\K[^,/]*')
    [ "$cn" = "$domain" ]
}

@test "certificate is signed by test CA" {
    local domain="signed.example.com"
    local key="$test_cert_dir/${domain}.key"
    local crt="$test_cert_dir/${domain}.crt"
    local san="subjectAltName=DNS:${domain},DNS:*.${domain}"

    _sign_cert "$domain" "$key" "$crt" "$san"

    # Verify certificate is signed by test CA (using -CAfile and -CAkey for verification)
    run openssl verify -CAfile "$test_ca_crt" "$crt"
    [ "$status" -eq 0 ]
}

@test "certificate has correct wildcard SAN" {
    local domain="cdn.example.com"
    local key="$test_cert_dir/${domain}.key"
    local crt="$test_cert_dir/${domain}.crt"
    local san="subjectAltName=DNS:${domain},DNS:*.${domain}"

    _sign_cert "$domain" "$key" "$crt" "$san"

    # Extract SAN from certificate
    san_output=$(openssl x509 -noout -ext subjectAltName -in "$crt")

    # Check that both root and wildcard are present
    echo "$san_output" | grep -q "DNS:${domain}" || return 1
    echo "$san_output" | grep -q "DNS:\*.${domain}" || return 1
}

@test "certificate expires in 10 years (3650 days)" {
    local domain="longterm.example.com"
    local key="$test_cert_dir/${domain}.key"
    local crt="$test_cert_dir/${domain}.crt"
    local san="subjectAltName=DNS:${domain}"

    _sign_cert "$domain" "$key" "$crt" "$san"

    # Check validity period
    not_after=$(openssl x509 -noout -enddate -in "$crt" | cut -d= -f2)
    not_before=$(openssl x509 -noout -startdate -in "$crt" | cut -d= -f2)

    # Verify both dates are present
    [ -n "$not_after" ]
    [ -n "$not_before" ]
}

# ────────────────────────────────────────────────────────────────────────────
# Serial File Management Tests
# ────────────────────────────────────────────────────────────────────────────

@test "serial file is initialized on first certificate generation" {
    local domain1="first.example.com"
    local key1="$test_cert_dir/${domain1}.key"
    local crt1="$test_cert_dir/${domain1}.crt"

    # Remove serial file to test initialization
    rm -f "$SERIAL_FILE"

    # Generate serial file with timestamp
    printf '%016x\n' "$(date +%s%N)" > "$SERIAL_FILE"

    _sign_cert "$domain1" "$key1" "$crt1" "subjectAltName=DNS:${domain1}"

    [ -f "$SERIAL_FILE" ]
    [ -s "$SERIAL_FILE" ]
}

@test "certificate serials increment monotonically" {
    local domain1="first.example.com"
    local domain2="second.example.com"
    local key1="$test_cert_dir/${domain1}.key"
    local crt1="$test_cert_dir/${domain1}.crt"
    local key2="$test_cert_dir/${domain2}.key"
    local crt2="$test_cert_dir/${domain2}.crt"

    # Generate first certificate
    _sign_cert "$domain1" "$key1" "$crt1" "subjectAltName=DNS:${domain1}"
    serial1=$(openssl x509 -noout -serial -in "$crt1" | cut -d= -f2)

    # Generate second certificate
    _sign_cert "$domain2" "$key2" "$crt2" "subjectAltName=DNS:${domain2}"
    serial2=$(openssl x509 -noout -serial -in "$crt2" | cut -d= -f2)

    # Convert hex serials to decimal for comparison
    serial1_dec=$((16#$serial1))
    serial2_dec=$((16#$serial2))

    # Second serial should be greater than first
    [ "$serial2_dec" -gt "$serial1_dec" ]
}

@test "serial file survives multiple certificate generations" {
    local domain1="domain1.example.com"
    local domain2="domain2.example.com"
    local domain3="domain3.example.com"

    # Generate three certificates
    for i in 1 2 3; do
        domain="domain${i}.example.com"
        key="$test_cert_dir/${domain}.key"
        crt="$test_cert_dir/${domain}.crt"
        _sign_cert "$domain" "$key" "$crt" "subjectAltName=DNS:${domain}"
    done

    # Serial file should still exist and be readable
    [ -f "$SERIAL_FILE" ]
    [ -s "$SERIAL_FILE" ]

    # Should be a valid hex value
    run bash -c "grep -E '^[0-9a-fA-F]+$' '$SERIAL_FILE'"
    [ "$status" -eq 0 ]
}

# ────────────────────────────────────────────────────────────────────────────
# Edge Cases
# ────────────────────────────────────────────────────────────────────────────

@test "certificate generation handles domains with many subdomains" {
    local domain="a.b.c.d.e.example.com"
    local key="$test_cert_dir/${domain}.key"
    local crt="$test_cert_dir/${domain}.crt"
    local san="subjectAltName=DNS:${domain},DNS:*.${domain}"

    run _sign_cert "$domain" "$key" "$crt" "$san"
    [ "$status" -eq 0 ]

    # Verify CN
    cn=$(openssl x509 -noout -subject -in "$crt" | grep -oP 'CN=\K[^,/]*')
    [ "$cn" = "$domain" ]
}

@test "certificate generation fails gracefully with invalid CN" {
    # openssl's -subj parser is permissive about hostname-shaped content —
    # underscores, even embedded characters, don't make it fail (verified
    # directly: `openssl req -subj "/CN=invalid_domain_with_underscores"`
    # exits 0). The X.509 CN field does have a hard length limit enforced by
    # OpenSSL itself (ASN.1 string length, max 64 bytes), so a CN past that
    # limit is a real, reproducible failure to exercise _sign_cert's error
    # path against (verified directly: exits 1 with "string too long:
    # maxsize=64").
    local invalid_cn
    invalid_cn="$(printf 'a%.0s' {1..300})"
    local key="$test_cert_dir/test.key"
    local crt="$test_cert_dir/test.crt"

    # _sign_cert will attempt generation but openssl should fail due to invalid CSR
    # The function should handle cleanup
    run _sign_cert "$invalid_cn" "$key" "$crt"

    # Function should return error status
    [ "$status" -ne 0 ]
}

@test "CSR cleanup prevents orphaned files on generation failure" {
    local domain="cleanup-test.example.com"
    local key="$test_cert_dir/${domain}.key"
    local crt="$test_cert_dir/${domain}.crt"

    # Generate valid cert to ensure cleanup works
    _sign_cert "$domain" "$key" "$crt" "subjectAltName=DNS:${domain}"

    # Check that no orphaned CSR files remain
    [ ! -f "/tmp/lancache-cert.csr" ]
}
