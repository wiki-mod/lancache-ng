#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper exposing hand-extracted copies of services/proxy/entrypoint.sh's
# _sign_cert() and _bounded_cert_name(), the two functions the deep leading-dot
# wildcard/exact-host cert path depends on. Not part of
# tests/bats/helpers/proxy-cert-helpers.sh's awk extraction range (same reason
# as proxy-collect-domain-rows-helpers.sh: both stop before the executable
# startup-script body). Kept in sync by hand with the real functions.

# Real self-signed CA, generated fresh per test in a tmp dir (see setup() in
# the .bats file) -- exercising the actual `openssl req`/`openssl x509 -req`
# calls _sign_cert makes, not a stub, is the whole point of this test: a stub
# would not have caught either the CN-length or filename-length regression
# this file's tests guard against.
_sign_cert() {
    local cn="$1" key="$2" crt="$3" ext="${4:-}"
    if ! openssl req -new -newkey rsa:2048 -nodes -subj "/CN=lancache-ng" \
        -keyout "$key" -out "$BATS_TEST_TMPDIR/lancache-cert.csr" 2>/dev/null; then
        rm -f "$BATS_TEST_TMPDIR/lancache-cert.csr"
        echo "[lancache] ERROR: Failed to generate certificate request for ${cn}" >&2
        return 1
    fi
    if [ -n "$ext" ]; then
        if ! openssl x509 -req -days 3650 \
            -in "$BATS_TEST_TMPDIR/lancache-cert.csr" \
            -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAserial "$SERIAL_FILE" \
            -extfile <(printf "%s" "$ext") \
            -out "$crt" 2>/dev/null; then
            rm -f "$BATS_TEST_TMPDIR/lancache-cert.csr" "$key" "$crt"
            echo "[lancache] ERROR: Failed to sign certificate for ${cn}" >&2
            return 1
        fi
    else
        if ! openssl x509 -req -days 3650 \
            -in "$BATS_TEST_TMPDIR/lancache-cert.csr" \
            -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAserial "$SERIAL_FILE" \
            -out "$crt" 2>/dev/null; then
            rm -f "$BATS_TEST_TMPDIR/lancache-cert.csr" "$key" "$crt"
            echo "[lancache] ERROR: Failed to sign certificate for ${cn}" >&2
            return 1
        fi
    fi
    rm -f "$BATS_TEST_TMPDIR/lancache-cert.csr"
}

_bounded_cert_name() {
    printf '%s' "${2}:${1}" | sha256sum | cut -c1-32
}

# Generates a throwaway CA (ca.crt/ca.key) plus an empty serial file under
# $CA_DIR/$SERIAL_FILE, both already exported by the calling test's setup().
_make_test_ca() {
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj "/CN=lancache-ng-test-ca" \
        -keyout "$CA_DIR/ca.key" -out "$CA_DIR/ca.crt" 2>/dev/null
    printf '%s\n' "1000" > "$SERIAL_FILE"
}
