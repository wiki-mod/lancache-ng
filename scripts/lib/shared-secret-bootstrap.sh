#!/bin/sh
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Shared-secret bootstrap helper (issue #858).
#
# Some secrets in this stack are HANDSHAKE secrets: more than one independent
# container has to arrive at the exact same value (e.g. PDNS_API_KEY is used by
# both PowerDNS and the Admin UI's PowerDNS REST client; KEA_CTRL_TOKEN by both
# Kea's control-agent and the Admin UI; DDNS_TSIG_KEY by both PowerDNS and Kea;
# the NATS_*_PASSWORD values by nats-server and its clients). setup.sh generates
# these once and writes them into a single shared .env, so every container reads
# an identical value. But if a shared secret is ever left empty/placeholder for
# any reason outside setup.sh (a partially-completed migration, an operator
# blanking a value in .env by hand, a bug in the generation step), there is no
# self-healing path: the affected containers either fail closed at compose
# interpolation or crash-loop, with no way to converge.
#
# This helper generalizes the single-consumer load_or_create pattern already in
# services/ui/src/main.rs to MULTIPLE independent consumers coordinating through
# a shared Docker volume. The invariant it protects is not "no crash-loop", it
# is "no split-brain": every consumer of a given secret must resolve the exact
# same value. It does that with one rule -- an operator/setup.sh-supplied value
# always wins untouched; only when the value is missing/placeholder does the
# container fall back to a first-writer-wins atomic read-or-create on the shared
# volume, so whichever container boots first generates the value and every other
# container reads that same value.
#
# It is not baked into the dns/dhcp/ui images through a shared Docker build
# context (each of those Dockerfiles builds from its own service directory, the
# same constraint documented for the known-good-snapshot library). Instead this
# file is the single canonical copy, and services/dns/entrypoint.sh,
# services/dhcp/entrypoint.sh, and services/ui/docker-entrypoint.sh each embed a
# byte-identical copy of the function definitions below between
# "# BEGIN shared-secret-bootstrap library" and "# END shared-secret-bootstrap
# library" markers. tests/bats/shared_secret_bootstrap_sync.bats fails loudly if
# any copy drifts. The nats service resolves the same way but inline in its
# compose command (it has no service image/entrypoint of its own, and its
# BusyBox shell escapes `$` as `$$` in YAML, so it cannot be byte-identical).

# lancache_shared_secret_dir
# Directory holding the cross-container shared secrets, mounted from the
# `shared-secrets` named volume into every container that must agree on a
# generated value. Overridable for tests via LANCACHE_SHARED_SECRET_DIR.
lancache_shared_secret_dir() {
    printf '%s' "${LANCACHE_SHARED_SECRET_DIR:-/var/lib/lancache-secrets}"
}

# lancache_shared_secret_gid
# The Admin UI process runs as this gid (services/ui/Dockerfile pins uid/gid
# 10001); dns/dhcp/nats run as root. Shared secret files are created group-owned
# by this gid and mode 0640 so the unprivileged UI can read a root-created file
# without the secret becoming world-readable -- the same cross-uid model the
# nats.conf bootstrap already uses. Overridable for tests.
lancache_shared_secret_gid() {
    printf '%s' "${LANCACHE_SHARED_SECRET_GID:-10001}"
}

# lancache_gen_hex32
# 64 hex characters from 32 random bytes. Uses od + /dev/urandom rather than
# `openssl rand -hex 32` because this runs unchanged in the Debian dns/dhcp/ui
# images AND the BusyBox nats:2-alpine image, and nats:2-alpine ships no openssl.
lancache_gen_hex32() {
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

# lancache_gen_base64_32
# base64 of 32 random bytes, for the DDNS TSIG key (PowerDNS/Kea expect a
# base64-encoded HMAC key, matching setup.sh's `openssl rand -base64 32`).
lancache_gen_base64_32() {
    head -c 32 /dev/urandom | base64 | tr -d '\n'
}

# secret_is_placeholder <value>
# True (returns 0) when the value is empty or one of the universal checked-in
# placeholders that must never run live (CHANGE_ME*, changeme*, YOUR_*, *_HERE).
# The split-brain invariant requires every consumer of a given secret to decide
# placeholder-or-real identically; the NATS_*_PASSWORD values are read by three
# separate services (the nats bootstrap, the dns entrypoint, the ui entrypoint),
# so routing their placeholder decision through this one definition keeps them in
# lockstep. Callers that also have secret-specific placeholders (e.g. the dhcp
# dev tokens) match those in addition to this.
#
# Matching is case-insensitive and treats "-"/"_" as equivalent (issue #967:
# e.g. "change-me", "CHANGE_ME", and "Change-Me" are all recognized) --
# normalize first, then match against lowercase/underscore patterns. This is a
# deliberate fail-safe widening: it can only make MORE values match as a
# placeholder, never fewer, so a real randomly-generated hex/base64 secret is
# not realistically affected.
#
# This is one of three independently-maintained placeholder detectors in this
# repo (the others: setup.sh's secret_value_is_placeholder, and
# services/ui/src/main.rs's secondary_registration_token_is_placeholder), kept
# deliberately separate per the maintainer decision recorded in issue #967
# (Option B: cross-validate, don't unify). Known, intentional divergences from
# the other two -- this function does NOT recognize the legacy
# "lancache-*-secret" template-default shape (deploy/dev/docker-compose.yml
# and deploy/dev/.env ship real, working dev secrets in exactly that shape,
# e.g. lancache-nats-ui-dev-secret, that this read path must accept, not
# regenerate) or a bare "change-me"/"change_me" infix without a CHANGE_ME/
# changeme prefix, but it DOES recognize a bare YOUR_* prefix without a
# trailing _HERE suffix, wider than the other two. See
# tests/fixtures/placeholder-detection-cases.txt and
# tests/bats/placeholder_detection_parity.bats for the full cross-validated
# case list, including every documented divergence.
secret_is_placeholder() {
    _sip_norm=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
    case "$_sip_norm" in
        "" | change_me* | changeme* | your_* | *_here) return 0 ;;
    esac
    return 1
}

# resolve_shared_secret <name> <current_value_or_empty> <gen_func>
# Resolves a shared secret and prints it on stdout with no trailing newline.
#   - If <current_value_or_empty> is non-empty, prints it and returns 0: an
#     operator/setup.sh-supplied real value always wins and is never persisted
#     to the shared volume (all containers share one .env, so they all already
#     agree on it). The CALLER is responsible for passing empty here when the
#     configured value is a known placeholder for that specific secret.
#   - Otherwise reads $dir/<name> if it already exists (some container generated
#     it first), else atomically creates it with a freshly generated value.
# Atomicity/race: the value is written to a temp file on the shared volume FIRST,
# then the final name is claimed with `ln` (a hardlink, atomic and failing if the
# target already exists). Because the temp already holds the full value before
# the link, a concurrent reader in another container never observes a partial or
# empty file, and a container that loses the create race falls back to reading
# the winner's value instead of erroring. Returns non-zero (and prints nothing)
# only if the shared volume is unwritable, so the caller can fail closed rather
# than silently diverge.
resolve_shared_secret() {
    _rss_name="$1"
    _rss_cur="$2"
    _rss_gen="$3"

    if [ -n "$_rss_cur" ]; then
        printf '%s' "$_rss_cur"
        return 0
    fi

    _rss_dir="$(lancache_shared_secret_dir)"
    _rss_file="${_rss_dir}/${_rss_name}"

    if [ -s "$_rss_file" ]; then
        tr -d '\n' < "$_rss_file"
        return 0
    fi

    mkdir -p "$_rss_dir" 2>/dev/null || true

    _rss_val="$($_rss_gen)"
    if [ -z "$_rss_val" ]; then
        return 1
    fi

    _rss_tmp="$(mktemp "${_rss_dir}/.secret.XXXXXX" 2>/dev/null)" || return 1
    printf '%s' "$_rss_val" > "$_rss_tmp"
    chmod 0640 "$_rss_tmp" 2>/dev/null || true
    chgrp "$(lancache_shared_secret_gid)" "$_rss_tmp" 2>/dev/null || true

    if ln "$_rss_tmp" "$_rss_file" 2>/dev/null; then
        rm -f "$_rss_tmp"
        printf '%s' "$_rss_val"
        return 0
    fi

    rm -f "$_rss_tmp"
    if [ -s "$_rss_file" ]; then
        tr -d '\n' < "$_rss_file"
        return 0
    fi
    return 1
}
