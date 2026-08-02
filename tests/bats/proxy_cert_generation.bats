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
#
# _is_valid_domain_label enforces RFC 1035's DNS label grammar (letters,
# digits, hyphens; must not start/end with a hyphen; max 63 octets) before a
# domain is trusted enough to get a signed wildcard cert. These tests pin
# down that boundary precisely, both sides of each rule, rather than just
# checking a handful of "looks fine"/"looks broken" examples.
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

# A leading hyphen is specifically excluded by RFC 1035 even though a hyphen
# is otherwise a legal label character -- this and the next test each check
# one side of that asymmetry rather than assuming "no hyphens at the edges"
# is a single symmetric rule.
@test "invalid domain label rejects labels starting with hyphen" {
    run _is_valid_domain_label "-invalid"
    [ "$status" -ne 0 ]
}

@test "invalid domain label rejects labels ending with hyphen" {
    run _is_valid_domain_label "invalid-"
    [ "$status" -ne 0 ]
}

# 63 octets is DNS's hard per-label ceiling (RFC 1035 section 2.3.4); one
# character over that limit must be rejected, not silently truncated.
@test "invalid domain label rejects labels longer than 63 chars" {
    run _is_valid_domain_label "$(printf 'a%.0s' {1..64})"
    [ "$status" -ne 0 ]
}

@test "invalid domain label rejects non-alphanumeric characters" {
    run _is_valid_domain_label "invalid_domain"
    [ "$status" -ne 0 ]
}

# _normalize_domain exists because entries in cdn-domains.txt come from
# operators typing/pasting them by hand -- case, a stray leading dot (from
# copying a wildcard-style ".example.com" entry), and surrounding whitespace
# are all realistic input, and each must collapse to the same canonical form
# so the same domain isn't accidentally treated as two different entries.
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

# _is_valid_domain must normalize before validating, not just after -- an
# operator-pasted domain with stray case/whitespace should be accepted, not
# rejected for a formatting problem _normalize_domain already knows how to fix.
@test "valid domain normalizes during validation" {
    run _is_valid_domain "  Example.COM  "
    [ "$status" -eq 0 ]
}

# A single label (no dot at all) is rejected regardless of content -- this
# service only ever proxies real internet domains, so "localhost" is a
# realistic operator typo to guard against, not just an arbitrary example.
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

# 253 octets is the overall FQDN ceiling (RFC 1035 section 3.1), separate
# from and in addition to the 63-octet per-label ceiling already covered
# above -- a domain can fail this check even if every individual label is
# well under 63 characters.
@test "invalid domain rejects names longer than 253 chars" {
    run _is_valid_domain "$(printf 'a%.0s' {1..250}).example.com"
    [ "$status" -ne 0 ]
}

# ────────────────────────────────────────────────────────────────────────────
# Certificate Generation Tests
#
# _sign_cert produces the wildcard certs the SSL-mode proxy presents during
# MITM interception (see services/proxy/entrypoint.sh and the "How SSL
# Interception Works" section of CLAUDE.md). A client's TLS stack will only
# accept the impersonated cert if its SAN and issuing CA are exactly right
# (CN is a fixed placeholder the client never validates against, per RFC
# 6125 -- see "certificate has correct CN" below), so these tests check that
# output structure directly against real openssl output rather than just
# asserting `_sign_cert` returned success.
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

    # CN is a fixed, short placeholder ("lancache-ng"), never the real
    # hostname (see _sign_cert's own comment in entrypoint.sh): OpenSSL's
    # default CN policy caps commonName at 64 bytes, well under the
    # 253-byte domains cdn-domains.txt can otherwise contain, so deriving
    # CN from the domain would break certificate issuance for any
    # long-enough hostname. TLS clients validate against subjectAltName, not
    # CN (RFC 6125 / CA/Browser Forum baseline) -- the real hostname must
    # still land in SAN, checked separately below.
    cn=$(openssl x509 -noout -subject -in "$crt" | grep -oP 'CN=\K[^,/]*')
    [ "$cn" = "lancache-ng" ]

    san_output=$(openssl x509 -noout -ext subjectAltName -in "$crt")
    echo "$san_output" | grep -q "DNS:${domain}"
}

@test "certificate is signed by test CA" {
    local domain="signed.example.com"
    local key="$test_cert_dir/${domain}.key"
    local crt="$test_cert_dir/${domain}.crt"
    local san="subjectAltName=DNS:${domain},DNS:*.${domain}"

    _sign_cert "$domain" "$key" "$crt" "$san"

    # A client only trusts the impersonated cert because it chains to the
    # LAN's own CA (which the operator installed once, per
    # docs/install-ca-cert.md) -- this is the one assertion that actually
    # exercises that trust chain end-to-end via openssl's own verifier,
    # rather than just inspecting fields on the cert in isolation.
    run openssl verify -CAfile "$test_ca_crt" "$crt"
    [ "$status" -eq 0 ]
}

# CLAUDE.md's design covers one root domain per wildcard cert (e.g.
# *.steamcontent.com covers every subdomain), but the root domain itself
# also needs to resolve -- so _sign_cert always requests both the bare
# domain and its wildcard in one SAN, and this checks both landed, not just
# whichever one a looser substring match would find first.
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

# _sign_cert hardcodes `-days 3650` (see entrypoint.sh) so operators never
# have to notice or renew per-domain certs -- the CA itself is the only
# thing they manage. This test asserts the actual ~3650-day span between
# notBefore/notAfter (via `date -d`, which parses openssl's "Mon DD
# HH:MM:SS YYYY GMT" format directly), not just that both date fields are
# non-empty, which would also pass for a cert expiring tomorrow.
@test "certificate expires in 10 years (3650 days)" {
    local domain="longterm.example.com"
    local key="$test_cert_dir/${domain}.key"
    local crt="$test_cert_dir/${domain}.crt"
    local san="subjectAltName=DNS:${domain}"

    _sign_cert "$domain" "$key" "$crt" "$san"

    not_after=$(openssl x509 -noout -enddate -in "$crt" | cut -d= -f2)
    not_before=$(openssl x509 -noout -startdate -in "$crt" | cut -d= -f2)

    [ -n "$not_after" ]
    [ -n "$not_before" ]

    local not_after_epoch not_before_epoch validity_days
    not_after_epoch="$(date -d "$not_after" +%s)"
    not_before_epoch="$(date -d "$not_before" +%s)"
    validity_days=$(( (not_after_epoch - not_before_epoch) / 86400 ))

    # Allow a 1-day slack for the test's own clock skew relative to when
    # openssl computed the validity window, not for any real tolerance in
    # entrypoint.sh's own `-days 3650` value.
    [ "$validity_days" -ge 3649 ]
    [ "$validity_days" -le 3650 ]
}

# ────────────────────────────────────────────────────────────────────────────
# Serial File Management Tests
#
# X.509 requires every certificate issued by the same CA to carry a unique
# serial number; a repeat serial from the same issuer is grounds for a
# client to distrust the cert outright. _sign_cert relies on openssl's
# `-CAserial` to bump a shared counter file per signing, so these tests
# check that file's lifecycle directly (created, incrementing, surviving
# repeated use) rather than only checking each individual cert in isolation.
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

# A serial that merely differs between two certs isn't enough to prove the
# counter is well-behaved (a random/hash-based scheme would also produce
# different-looking values) -- this specifically checks the second serial is
# numerically greater, matching the monotonic counter `-CAserial` actually
# implements.
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

# Beyond just "increments" (the previous test), the counter file itself must
# stay a single valid hex value across many signings in the same process --
# this is the regression case for a serial file that gets truncated,
# corrupted, or replaced instead of updated in place.
@test "serial file survives multiple certificate generations" {
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

# Real CDN hostnames aren't always `cdn.example.com` -- some are several
# labels deep (e.g. a regional edge node under a vendor's own subdomain
# structure). This checks _sign_cert doesn't have a hidden assumption about
# label count baked in anywhere (e.g. in how it builds the CN or SAN string).
@test "certificate generation handles domains with many subdomains" {
    local domain="a.b.c.d.e.example.com"
    local key="$test_cert_dir/${domain}.key"
    local crt="$test_cert_dir/${domain}.crt"
    local san="subjectAltName=DNS:${domain},DNS:*.${domain}"

    run _sign_cert "$domain" "$key" "$crt" "$san"
    [ "$status" -eq 0 ]

    # CN stays the fixed placeholder regardless of label count -- see
    # "certificate has correct CN" above for why CN is never domain-derived.
    # The real, many-label hostname must still land in SAN.
    cn=$(openssl x509 -noout -subject -in "$crt" | grep -oP 'CN=\K[^,/]*')
    [ "$cn" = "lancache-ng" ]

    san_output=$(openssl x509 -noout -ext subjectAltName -in "$crt")
    echo "$san_output" | grep -q "DNS:${domain}"
}

@test "certificate generation succeeds for an over-length CN-shaped argument" {
    # _sign_cert no longer derives CN directly from this argument, so an
    # over-length value here doesn't hit OpenSSL's 64-byte CN limit
    # (ASN1_mbstring_ncopy's "string too long: maxsize=64") the way it once
    # would have. CN is now a fixed, short placeholder ("lancache-ng")
    # regardless of this argument's length or shape; the real hostname
    # belongs only in the SAN extension passed via $4 (not exercised here,
    # since this test's whole point is the CSR step in isolation), which has
    # no such length limit. This asserts the CSR step no longer fails for
    # the exact input shape that used to break it -- see
    # tests/bats/proxy_sign_cert.bats for the dedicated deep-wildcard/
    # exact-host regression coverage of this same fix against domains long
    # enough to also hit Linux's NAME_MAX limit.
    local invalid_cn
    invalid_cn="$(printf 'a%.0s' {1..300})"
    local key="$test_cert_dir/test.key"
    local crt="$test_cert_dir/test.crt"

    run _sign_cert "$invalid_cn" "$key" "$crt"

    [ "$status" -eq 0 ]
    [ -f "$key" ]
    [ -f "$crt" ]

    cn=$(openssl x509 -noout -subject -in "$crt" | grep -oP 'CN=\K[^,/]*')
    [ "$cn" = "lancache-ng" ]
}

# The test above removed this file's only remaining coverage of _sign_cert's
# *first* `openssl req` (CSR-generation) failure branch and its
# `rm -f "$BATS_TEST_TMPDIR/lancache-cert.csr"` cleanup on that path --
# "signing failure cleans up the orphaned private key, not just the CSR" and
# "signing failure removes a partially-written crt output file" below both
# force the *second* (`openssl x509 -req` sign) step to fail instead, which
# never reaches this branch. Force the CSR step itself to fail (a directory
# can never be openssl's -keyout target, mirroring how the sign-step tests
# below use a directory for their own forced-failure target) so this
# coverage isn't lost just because CN-length can no longer trigger it.
@test "CSR-generation failure returns an error and leaves no orphaned CSR or crt" {
    local key_as_dir="$test_cert_dir/keydir"
    local crt="$test_cert_dir/test.crt"
    mkdir -p "$key_as_dir"

    run _sign_cert "csr-fail.example.com" "$key_as_dir" "$crt" "subjectAltName=DNS:csr-fail.example.com"

    [ "$status" -ne 0 ]
    [ ! -f "/tmp/lancache-cert.csr" ]
    [ ! -f "$crt" ]

    rmdir "$key_as_dir"
}

# _sign_cert writes its intermediate CSR to a single hardcoded path,
# /tmp/lancache-cert.csr (see entrypoint.sh), rather than a per-call
# temp file, and removes it with `rm -f` on both the success and every
# failure path. This test's name says "on generation failure" but exercises
# the success path (a real deployment signs many domains back-to-back, so
# a leftover CSR after a *successful* sign is just as real a leak as one
# left behind by a failure); "signing failure cleans up the orphaned private
# key, not just the CSR" and "signing failure removes a partially-written crt
# output file" below cover the failure path for the same cleanup behavior
# (the over-length-CN test above no longer fails at all, by design -- see its
# own comment -- so it can no longer serve as the failure-path example).
@test "CSR cleanup prevents orphaned files on generation failure" {
    local domain="cleanup-test.example.com"
    local key="$test_cert_dir/${domain}.key"
    local crt="$test_cert_dir/${domain}.crt"

    # Generate valid cert to ensure cleanup works
    _sign_cert "$domain" "$key" "$crt" "subjectAltName=DNS:${domain}"

    # Check that no orphaned CSR files remain
    [ ! -f "/tmp/lancache-cert.csr" ]
}

# ────────────────────────────────────────────────────────────────────────────
# Regression tests for #655
#
# Two latent bugs, both originally flagged in the PR #172/#173 reviews and
# re-verified still present on v0.2.0:
#   1. _default_cert_needs_regen's IP SAN check used an unanchored substring
#      match, so a migrated IP_SSL could still "match" a longer stale IP.
#   2. _sign_cert only removed the CSR temp file on a failed sign, leaving
#      the private key (and any partially-written $crt) behind on disk.
# ────────────────────────────────────────────────────────────────────────────

# _sign_cert's key-generation step (`openssl req`) always writes $key before
# the later `openssl x509` signing step can fail, so any signing failure
# necessarily leaves an orphaned private key unless _sign_cert cleans it up
# itself. This forces that second step to fail (an unwritable $crt path)
# while leaving the first step's inputs otherwise valid, so the failure is
# specifically in signing, not key/CSR generation.
@test "signing failure cleans up the orphaned private key, not just the CSR" {
    local domain="sign-fail.example.com"
    local key="$test_cert_dir/${domain}.key"
    # A directory can never be openssl's -out target, forcing the sign step
    # (not the earlier req/CSR step) to fail.
    local crt="$test_cert_dir/${domain}.crt.d"
    mkdir -p "$crt"

    run _sign_cert "$domain" "$key" "$crt" "subjectAltName=DNS:${domain}"

    [ "$status" -ne 0 ]
    # Before the #655 fix, the key from the successful `openssl req` step
    # would still be sitting on disk here even though signing failed.
    [ ! -f "$key" ]
    [ ! -f "/tmp/lancache-cert.csr" ]

    rmdir "$crt"
}

# Same failure path as above, but for a partially-written $crt rather than
# the key: pre-seed $crt with leftover bytes from a hypothetically
# interrupted prior write, then force the sign step to fail, and check the
# partial file doesn't survive as a false "certificate exists" signal for
# whatever next reads it.
@test "signing failure removes a partially-written crt output file" {
    local domain="partial-crt.example.com"
    local key="$test_cert_dir/${domain}.key"
    local crt="$test_cert_dir/${domain}.crt"
    printf 'partial garbage from an interrupted write' > "$crt"

    # An over-length CN-shaped argument used to fail at the CSR step before
    # ever reaching the sign step (see "certificate generation succeeds for
    # an over-length CN-shaped argument" above for why that's no longer true
    # now that CN is a fixed placeholder), so it can't exercise this path.
    # Instead, force the sign step itself to fail by pointing -CA at a CA
    # file that doesn't exist, which openssl x509 rejects only once it
    # actually attempts to sign.
    CA_DIR="$BATS_TEST_TMPDIR/missing-ca-dir"
    run _sign_cert "$domain" "$key" "$crt" "subjectAltName=DNS:${domain}"

    [ "$status" -ne 0 ]
    [ ! -f "$crt" ]
    [ ! -f "/tmp/lancache-cert.csr" ]
}

# Reproduces #655's exact scenario: IP_SSL migrates from 192.168.1.11 to
# 192.168.1.1, a prefix of the old address. An unanchored
# `grep -q "IP Address:${IP_SSL}"` still finds the old, longer IP inside the
# stale SAN and wrongly reports "no regen needed", so a client connecting to
# the new IP would keep getting served a cert without that IP in its SAN.
@test "default cert needs regen when IP_SSL is a prefix of the stale SAN IP" {
    local domain="lancache-default"
    local key="$test_cert_dir/default.key"
    local crt="$test_cert_dir/default.crt"

    IP_SSL="192.168.1.11"
    _sign_cert "$domain" "$key" "$crt" "subjectAltName=DNS:${domain},IP:${IP_SSL}"

    # Operator migrates to a shorter IP that is a textual prefix of the old one.
    IP_SSL="192.168.1.1"
    run _default_cert_needs_regen
    [ "$status" -eq 0 ]
}

# Inverse of the above: once the cert is actually regenerated for the new
# IP, _default_cert_needs_regen must recognize the exact match and report
# "no regen needed" -- otherwise the anchoring fix would just be trading a
# false negative for a false positive that regenerates on every start.
@test "default cert does not need regen when SAN IP exactly matches IP_SSL" {
    local domain="lancache-default"
    local key="$test_cert_dir/default.key"
    local crt="$test_cert_dir/default.crt"

    IP_SSL="192.168.1.1"
    _sign_cert "$domain" "$key" "$crt" "subjectAltName=DNS:${domain},IP:${IP_SSL}"

    run _default_cert_needs_regen
    [ "$status" -eq 1 ]
}

# A cert whose SAN doesn't contain the new IP_SSL at all (not even as a
# prefix/substring collision) must also be flagged for regen -- this is the
# baseline "obviously different IP" case the anchoring fix must not break
# while fixing the more subtle prefix-collision case above.
@test "default cert needs regen when SAN IP is unrelated to IP_SSL" {
    local domain="lancache-default"
    local key="$test_cert_dir/default.key"
    local crt="$test_cert_dir/default.crt"

    IP_SSL="10.0.0.5"
    _sign_cert "$domain" "$key" "$crt" "subjectAltName=DNS:${domain},IP:${IP_SSL}"

    IP_SSL="192.168.1.1"
    run _default_cert_needs_regen
    [ "$status" -eq 0 ]
}

# _bounded_cert_name must be defined unconditionally, before the
# `if [ "${SSL_ENABLED}" = "1" ]` block -- entrypoint.sh's unconditional
# map-generation section (see "2. Generate request-time access policy maps")
# calls it for every _EXTRA_WILDCARD_BASES/_EXTRA_EXACT_HOSTS entry
# regardless of SSL_ENABLED, since those maps exist even when SSL mode is
# off. A real regression shipped exactly this: _bounded_cert_name was
# defined only inside the SSL_ENABLED=1 branch, so any SSL_ENABLED=0 install
# with a deep cdn-domains.txt entry hit "_bounded_cert_name: command not
# found" and a blank map value, failing nginx -t at startup -- confirmed
# live against a real built proxy image and the real cdn-domains.txt.
# Exercising that end-to-end (SSL_ENABLED=0, a real container, real
# nginx -t) isn't practical from this bats suite (no Docker/nginx here), so
# this instead asserts the cheap, deterministic invariant that actually
# prevents the regression: the function's definition must appear before the
# SSL_ENABLED conditional in the source, not verify runtime behavior a unit
# test can't reach.
@test "_bounded_cert_name is defined before the SSL_ENABLED conditional block" {
    local entrypoint="$repo_root/services/proxy/entrypoint.sh"
    local def_line ssl_if_line

    def_line="$(grep -n '^_bounded_cert_name() {' "$entrypoint" | head -1 | cut -d: -f1)"
    ssl_if_line="$(grep -n 'if \[ "\${SSL_ENABLED}" = "1" \]; then' "$entrypoint" | head -1 | cut -d: -f1)"

    [ -n "$def_line" ]
    [ -n "$ssl_if_line" ]
    [ "$def_line" -lt "$ssl_if_line" ]
}
