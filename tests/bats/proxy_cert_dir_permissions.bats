#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regression tests for services/proxy/entrypoint.sh's _ensure_ca_cert() and
# _harden_cert_dir(): the ca.key chmod 600 hardening and the
# CERT_DIR chgrp/chmod 2750 hardening. Both are security-relevant file-mode
# invariants with no other guard against a future accidental deletion, so
# they need their own regression coverage. Uses the real functions
# (extracted via tests/bats/helpers/proxy-cert-dir-permissions-helpers.sh),
# a real `openssl req` call, and real `stat`/`chmod`/`chgrp` -- not a
# reimplementation.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/proxy-cert-dir-permissions-helpers.sh"

    # shellcheck source=tests/bats/helpers/proxy-cert-dir-permissions-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/proxy-cert-dir-permissions-helpers.sh"
    load_proxy_cert_dir_permissions_helpers "$repo_root" "$helper_file"

    CA_DIR="$BATS_TEST_TMPDIR/ca"
    CERT_DIR="$BATS_TEST_TMPDIR/certs"
    export CA_DIR CERT_DIR
}

@test "_ensure_ca_cert generates a fresh CA with a private key that is not world/group-readable" {
    run _ensure_ca_cert
    [ "$status" -eq 0 ]
    [ -f "$CA_DIR/ca.key" ]
    [ -f "$CA_DIR/ca.crt" ]

    mode="$(stat -c '%a' "$CA_DIR/ca.key")"
    [ "$mode" = "600" ]
}

# Stub certificate generation with an intentionally insecure key mode so
# this test depends on the production chmod rather than OpenSSL's version-
# specific key-creation default.
@test "_ensure_ca_cert hardens an insecure generated ca.key to mode 600" {
    openssl() {
        local key_path="" cert_path="" previous=""
        for argument in "$@"; do
            case "$previous" in
                -keyout) key_path="$argument" ;;
                -out) cert_path="$argument" ;;
            esac
            previous="$argument"
        done
        printf 'insecure test key\n' > "$key_path"
        printf 'test certificate\n' > "$cert_path"
        chmod 644 "$key_path"
    }

    _ensure_ca_cert
    mode="$(stat -c '%a' "$CA_DIR/ca.key")"
    [ "$mode" = "600" ]
}

# Idempotence: a second call against an already-generated CA must be a
# silent no-op (the real entrypoint calls this unconditionally on every
# boot, not just first-time setup) and must not touch the existing key's
# mode a second time either.
@test "_ensure_ca_cert does nothing when the CA already exists" {
    _ensure_ca_cert
    # Content hash, not stat -c '%Y' (whole-second resolution): a
    # regression that rewrites ca.key within the same wall-clock second as
    # the first generation would otherwise leave both mtimes equal and this
    # test still green. sha256sum over the actual bytes catches a rewrite
    # regardless of timing.
    first_key_hash="$(sha256sum "$CA_DIR/ca.key" | awk '{print $1}')"

    run _ensure_ca_cert
    [ "$status" -eq 0 ]

    second_key_hash="$(sha256sum "$CA_DIR/ca.key" | awk '{print $1}')"
    [ "$first_key_hash" = "$second_key_hash" ]
    mode="$(stat -c '%a' "$CA_DIR/ca.key")"
    [ "$mode" = "600" ]
}

@test "_harden_cert_dir creates CERT_DIR with mode 2750 (setgid, owner rwx, group rx, no other access)" {
    # Use the current process's own real GID: chgrp only needs a group that
    # actually exists on this host, not specifically the real "nginx" worker
    # user this runs as in the container -- the mode bits this test checks
    # are independent of which group was requested.
    local test_group
    test_group="$(id -g)"

    run _harden_cert_dir "$test_group"
    [ "$status" -eq 0 ]
    [ -d "$CERT_DIR" ]

    mode="$(stat -c '%a' "$CERT_DIR")"
    [ "$mode" = "2750" ]
}

@test "_harden_cert_dir chgrps CERT_DIR to the requested group" {
    local test_group
    test_group="$(id -g)"

    mkdir -p "$CERT_DIR"
    chgrp() {
        printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/chgrp-requested-group"
        command chgrp "$@"
    }

    _harden_cert_dir "$test_group"

    [ "$(cat "$BATS_TEST_TMPDIR/chgrp-requested-group")" = "$test_group" ]
    actual_gid="$(stat -c '%g' "$CERT_DIR")"
    [ "$actual_gid" = "$test_group" ]
}

# Idempotence, same reasoning as _ensure_ca_cert above: the real entrypoint
# calls this unconditionally on every boot, and a pre-existing CERT_DIR full
# of already-issued wildcard certs must not lose its contents.
@test "_harden_cert_dir is safe to call again against an already-hardened, populated CERT_DIR" {
    local test_group
    test_group="$(id -g)"
    _harden_cert_dir "$test_group"
    printf 'fake cert bytes' > "$CERT_DIR/example.com.crt"

    run _harden_cert_dir "$test_group"
    [ "$status" -eq 0 ]
    [ -f "$CERT_DIR/example.com.crt" ]
    mode="$(stat -c '%a' "$CERT_DIR")"
    [ "$mode" = "2750" ]
}
