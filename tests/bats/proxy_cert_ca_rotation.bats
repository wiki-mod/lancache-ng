#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression guard: CERT_DIR's move to a named, persistent volume means a
# leaf cert signed by a since-replaced CA is no longer flushed by the
# anonymous-volume reset a container-removing recreate used to cause
# incidentally. _purge_stale_leaf_certs_on_ca_change() must invalidate every
# leaf when the mounted CA's fingerprint changes, and leave them alone
# otherwise, so the docs/backup-restore.md CA-rotation procedure ("generate
# a new CA... and restart the proxy stack") actually results in clients
# being served certs the new CA can validate.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/proxy-cert-ca-rotation-helpers.sh"

    # shellcheck source=tests/bats/helpers/proxy-cert-ca-rotation-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/proxy-cert-ca-rotation-helpers.sh"
    load_proxy_cert_ca_rotation_helpers "$repo_root" "$helper_file"

    CA_DIR="$BATS_TEST_TMPDIR/ca"
    CERT_DIR="$BATS_TEST_TMPDIR/certs"
    mkdir -p "$CA_DIR" "$CERT_DIR"
    export CA_DIR CERT_DIR
}

_generate_ca() {
    openssl req -new -newkey rsa:2048 -days 1 -nodes -x509 \
        -subj "/CN=Test CA/O=Test/C=DE" \
        -keyout "$CA_DIR/ca.key" -out "$CA_DIR/ca.crt" 2>/dev/null
}

@test "purges every leaf cert/key on first run against a CERT_DIR with no fingerprint recorded yet" {
    _generate_ca
    printf 'stale cert bytes' > "$CERT_DIR/example.com.crt"
    printf 'stale key bytes' > "$CERT_DIR/example.com.key"

    run _purge_stale_leaf_certs_on_ca_change
    [ "$status" -eq 0 ]
    [ ! -f "$CERT_DIR/example.com.crt" ]
    [ ! -f "$CERT_DIR/example.com.key" ]
    [ -f "$CERT_DIR/.ca-fingerprint" ]
}

@test "leaves leaf certs alone on a second run against the same, unchanged CA" {
    _generate_ca
    _purge_stale_leaf_certs_on_ca_change
    printf 'real cert bytes' > "$CERT_DIR/example.com.crt"
    printf 'real key bytes' > "$CERT_DIR/example.com.key"

    run _purge_stale_leaf_certs_on_ca_change
    [ "$status" -eq 0 ]
    [ -f "$CERT_DIR/example.com.crt" ]
    [ -f "$CERT_DIR/example.com.key" ]
}

@test "purges every leaf cert/key once the mounted CA is replaced (rotation scenario)" {
    _generate_ca
    _purge_stale_leaf_certs_on_ca_change
    printf 'old-ca-signed cert bytes' > "$CERT_DIR/example.com.crt"
    printf 'old-ca-signed key bytes' > "$CERT_DIR/example.com.key"
    old_fingerprint="$(cat "$CERT_DIR/.ca-fingerprint")"

    # Simulate an operator replacing the CA per docs/backup-restore.md's
    # rotation procedure.
    _generate_ca

    run _purge_stale_leaf_certs_on_ca_change
    [ "$status" -eq 0 ]
    [ ! -f "$CERT_DIR/example.com.crt" ]
    [ ! -f "$CERT_DIR/example.com.key" ]
    new_fingerprint="$(cat "$CERT_DIR/.ca-fingerprint")"
    [ "$old_fingerprint" != "$new_fingerprint" ]
}

@test "does not touch unrelated files in CERT_DIR" {
    _generate_ca
    printf 'unrelated' > "$CERT_DIR/.some-other-marker"

    run _purge_stale_leaf_certs_on_ca_change
    [ "$status" -eq 0 ]
    [ -f "$CERT_DIR/.some-other-marker" ]
}
