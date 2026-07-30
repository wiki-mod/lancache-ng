#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for services/proxy/entrypoint.sh's _sign_cert() and
# _bounded_cert_name(), exercised against a real openssl CA (not a stub) so
# these tests actually catch what _collect_domain_rows-only coverage cannot:
# whether the deep leading-dot wildcard/exact-host cert path (issue #1272)
# can complete real certificate issuance for a domain long enough to hit
# OpenSSL's 64-byte commonName limit or Linux's 255-byte NAME_MAX filename
# limit, both of which _is_valid_domain's own 253-byte ceiling allows.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=tests/bats/helpers/proxy-sign-cert-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/proxy-sign-cert-helpers.sh"

    CA_DIR="$BATS_TEST_TMPDIR/ca"
    CERT_DIR="$BATS_TEST_TMPDIR/certs"
    SERIAL_FILE="$BATS_TEST_TMPDIR/ca.srl"
    mkdir -p "$CA_DIR" "$CERT_DIR"
    _make_test_ca

    # 4 labels of 60 bytes each + 3 dots = 243 bytes -- past the 64-byte CN
    # limit, and (combined with a filename suffix) past NAME_MAX too. Not
    # required to be a real, resolvable, or even DNS-label-valid domain:
    # _sign_cert/_bounded_cert_name never call _is_valid_domain themselves
    # (that check happens upstream, in _collect_domain_rows), so this only
    # needs to be long, not well-formed.
    label="$(printf 'a%.0s' $(seq 1 60))"
    long_domain="${label}.${label}.${label}.${label}"
    [ "${#long_domain}" -eq 243 ]
}

@test "_sign_cert succeeds for a domain past OpenSSL's 64-byte CN limit" {
    run _sign_cert "$long_domain" "$CERT_DIR/test.key" "$CERT_DIR/test.crt" \
        "subjectAltName=DNS:*.${long_domain}"
    [ "$status" -eq 0 ]
    [ -f "$CERT_DIR/test.crt" ]
    [ -f "$CERT_DIR/test.key" ]
}

@test "_sign_cert's issued certificate carries the real hostname in SAN, not CN" {
    _sign_cert "$long_domain" "$CERT_DIR/test.key" "$CERT_DIR/test.crt" \
        "subjectAltName=DNS:*.${long_domain}"

    run openssl x509 -in "$CERT_DIR/test.crt" -noout -text
    [ "$status" -eq 0 ]
    [[ "$output" == *"DNS:*.${long_domain}"* ]]
    [[ "$output" != *"CN = ${long_domain}"* ]]
    [[ "$output" == *"CN = lancache-ng"* ]]
}

@test "_bounded_cert_name produces a filename that stays within NAME_MAX once suffixed" {
    cert_name="$(_bounded_cert_name "$long_domain" exact)"
    filename="${cert_name}.exact-host.crt"
    [ "${#filename}" -lt 255 ]
    # sha256sum -c1-32 hex chars, deterministic for the same input.
    [ "${#cert_name}" -eq 32 ]
}

@test "_bounded_cert_name gives a bare and a leading-dot entry for the same base different names" {
    wildcard_name="$(_bounded_cert_name "$long_domain" wildcard)"
    exact_name="$(_bounded_cert_name "$long_domain" exact)"
    [ "$wildcard_name" != "$exact_name" ]
}

@test "_bounded_cert_name is deterministic across repeated calls (existence-check skip relies on this)" {
    first="$(_bounded_cert_name "$long_domain" wildcard)"
    second="$(_bounded_cert_name "$long_domain" wildcard)"
    [ "$first" = "$second" ]
}
