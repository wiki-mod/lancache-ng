#!/bin/sh
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Admin UI container entrypoint: fixes up ownership on shared/bind-mounted
# data paths when started as root, then drops privileges to the unprivileged
# `lancache` user before exec-ing the real command.
set -eu

# ── Shared-secret bootstrap (issue #858) ─────────────────────────────────────
# Embedded byte-identical copy of scripts/lib/shared-secret-bootstrap.sh's
# function definitions (guarded by tests/bats/shared_secret_bootstrap_sync.bats):
# this image builds from services/ui/ alone with no shared-file build context.
# BEGIN shared-secret-bootstrap library (scripts/lib/shared-secret-bootstrap.sh)
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
# (Option B: cross-validate, don't unify). Divergences from the other two,
# confirmed via tests/fixtures/placeholder-detection-cases.txt and
# tests/bats/placeholder_detection_parity.bats:
#   - This function does NOT recognize the legacy "lancache-*-secret"
#     template-default shape. This omission IS deliberate: the now-retired
#     deploy/dev/docker-compose.yml and deploy/dev/.env (v0.3.0, #766)
#     shipped real, working dev secrets in exactly that shape (e.g.
#     lancache-nats-ui-dev-secret) that this read path had to accept as
#     configured, not regenerate. Kept as a regression pin (see the test
#     fixtures below) so that shape is never misclassified if an operator's
#     own secret happens to match it.
#   - This function does NOT recognize a bare "change-me"/"change_me" infix
#     without a CHANGE_ME/changeme prefix, unlike setup.sh/Rust. Pre-existing,
#     not reconciled here (#967 Option B keeps the three pattern sets
#     separate rather than unifying them); no known rationale beyond that.
#   - This function DOES recognize a bare YOUR_* prefix without a trailing
#     _HERE suffix, and a generic *_HERE suffix on any value (not just
#     YOUR_*_HERE) -- both wider than setup.sh/Rust. Also pre-existing and not
#     reconciled here; no shipped placeholder in this repo actually needs
#     either bare form, so the gap has not mattered in practice, but it is a
#     real, confirmed divergence, not an intentional design choice.
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
# END shared-secret-bootstrap library

# Resolve the Admin UI's share of the handshake secrets (issue #858) while still
# root, so the same first-writer-wins value the dns/dhcp/nats containers use is
# exported into the environment the Rust process (config.rs) reads after the
# privilege drop below. Doing it here means no split-brain: the UI's PowerDNS
# REST client (PDNS_API_KEY) and Kea API client (DHCP_API_TOKEN) resolve the same
# shared file the server side does, instead of the UI reading an empty/placeholder
# env while the server self-generated a real value. Only runs in the root branch
# (an operator-overridden non-root user cannot write the shared volume anyway).
# _ui_resolve_or_die <var_name> <shared_secret_name> <current_value> <gen_func>
# Fail closed (Codex review, PR #886): resolve_shared_secret only returns
# non-zero when the shared-secrets volume itself is unwritable. Previously each
# call site below silently left the original empty/placeholder value in place
# on that failure and kept booting -- the Rust process (config.rs) has no
# startup validation for PDNS_API_KEY/DHCP_API_TOKEN, so the UI would start
# with a different secret than the dns/dhcp/nats containers generated and every
# handshake using it (PowerDNS REST calls, Kea API calls) would fail with 401
# at request time instead of a clear boot-time error. Matches the exit-1
# pattern services/dns/entrypoint.sh already uses for PDNS_API_KEY.
_ui_resolve_or_die() {
    _uird_var="$1" _uird_name="$2" _uird_cur="$3" _uird_gen="$4"
    if ! _uird_val="$(resolve_shared_secret "$_uird_name" "$_uird_cur" "$_uird_gen")"; then
        echo "[lancache-ui] FATAL: ${_uird_var} is unset/placeholder and the shared-secrets volume is not writable, so no shared value could be generated." >&2
        echo "[lancache-ui] Mount the shared-secrets volume, or set ${_uird_var} to the real value the corresponding backend container uses." >&2
        exit 1
    fi
    eval "$_uird_var=\$_uird_val"
    eval "export $_uird_var"
}

if [ "$(id -u)" = "0" ]; then
    _ui_pdns_cfg="${PDNS_API_KEY:-}"
    if secret_is_placeholder "$_ui_pdns_cfg"; then _ui_pdns_cfg=""; fi
    _ui_resolve_or_die PDNS_API_KEY pdns-api-key "$_ui_pdns_cfg" lancache_gen_hex32

    # DHCP_API_TOKEN mirrors the shared KEA_CTRL_TOKEN (the compose default already
    # falls DHCP_API_TOKEN back to KEA_CTRL_TOKEN); resolve it against the same
    # kea-ctrl-token shared file the dhcp container uses. An explicit non-placeholder
    # operator override is preserved. secret_is_placeholder covers the universal
    # CHANGE_ME*/changeme*/YOUR_*/*_HERE conventions; the case below adds this
    # service's own legacy shipped defaults, which aren't generically named.
    _ui_dhcp_tok="${DHCP_API_TOKEN:-}"
    if secret_is_placeholder "$_ui_dhcp_tok"; then
        _ui_dhcp_tok=""
    else
        case "$_ui_dhcp_tok" in
            lancache-dhcp-secret|lancache-dhcp-dev-secret|lancache-dhcp-prod-secret) _ui_dhcp_tok="" ;;
        esac
    fi
    _ui_resolve_or_die DHCP_API_TOKEN kea-ctrl-token "$_ui_dhcp_tok" lancache_gen_hex32

    # NATS credentials the UI connects with: NATS_UI_PASSWORD (record/flush
    # publisher) and NATS_CALLOUT_PASSWORD (the auth-callout responder's own
    # static bypass identity). Both are also written into nats-server's static
    # user list by the nats bootstrap; resolving them from the same shared files
    # keeps the UI and the server in lockstep.
    _ui_nats_ui_cfg="${NATS_UI_PASSWORD:-}"
    if secret_is_placeholder "$_ui_nats_ui_cfg"; then _ui_nats_ui_cfg=""; fi
    _ui_resolve_or_die NATS_UI_PASSWORD nats-ui-password "$_ui_nats_ui_cfg" lancache_gen_hex32
    _ui_nats_callout_cfg="${NATS_CALLOUT_PASSWORD:-}"
    if secret_is_placeholder "$_ui_nats_callout_cfg"; then _ui_nats_callout_cfg=""; fi
    _ui_resolve_or_die NATS_CALLOUT_PASSWORD nats-callout-password "$_ui_nats_callout_cfg" lancache_gen_hex32

    # Issue #681: NATS_SYS_PASSWORD is the third credential the UI actually
    # connects to NATS with (nats_kick.rs, alongside NATS_UI_PASSWORD and
    # NATS_CALLOUT_PASSWORD above) -- the system-account identity used only to
    # look up (CONNZ) and force-disconnect (KICK) a removed/rotated secondary's
    # live connection. Same lockstep-with-the-nats-service rationale as above.
    _ui_nats_sys_cfg="${NATS_SYS_PASSWORD:-}"
    if secret_is_placeholder "$_ui_nats_sys_cfg"; then _ui_nats_sys_cfg=""; fi
    _ui_resolve_or_die NATS_SYS_PASSWORD nats-sys-password "$_ui_nats_sys_cfg" lancache_gen_hex32

    # The UI never connects to NATS as the dns-writer/dns-replica roles (only
    # dns-standard/dns-ssl do), but config.rs holds both passwords anyway and
    # main.rs's preflight_startup_config() -> validate_runtime_nats_credentials()
    # rejects a missing value for either one before the HTTP listener binds
    # (defense-in-depth: catch a broken NATS credential set as a whole, not just
    # the two roles this process happens to use). Resolving them here against
    # the exact same shared files dns-standard/dns-ssl read
    # (NATS_PASSWORD_SHARED_SECRET=nats-dns-writer-password / ...-replica-...)
    # keeps this preflight check in lockstep with the real generated values
    # instead of hard-failing the whole container on an empty/placeholder .env.
    _ui_nats_writer_cfg="${NATS_DNS_WRITER_PASSWORD:-}"
    if secret_is_placeholder "$_ui_nats_writer_cfg"; then _ui_nats_writer_cfg=""; fi
    _ui_resolve_or_die NATS_DNS_WRITER_PASSWORD nats-dns-writer-password "$_ui_nats_writer_cfg" lancache_gen_hex32
    _ui_nats_replica_cfg="${NATS_DNS_REPLICA_PASSWORD:-}"
    if secret_is_placeholder "$_ui_nats_replica_cfg"; then _ui_nats_replica_cfg=""; fi
    _ui_resolve_or_die NATS_DNS_REPLICA_PASSWORD nats-dns-replica-password "$_ui_nats_replica_cfg" lancache_gen_hex32
fi

# Bind mounts and shared volumes are often created as root-owned paths at
# container start, after image-time chown has run. When the entrypoint starts as
# root, normalize the writable paths before dropping privileges so Admin UI
# writes -- including init_tracing()'s ui.log file under /var/log/lancache-ui
# (#633 central logging pipeline) -- keep working. If an operator overrides
# the container user, do not try to chown or call setpriv from an
# unprivileged account.
if [ "$(id -u)" = "0" ]; then
    for path in /data /etc/nats /var/lib/powerdns-state /var/log/lancache-ui; do
        if [ -e "$path" ]; then
            chown -R lancache:lancache "$path"
        fi
    done

    exec setpriv --reuid=lancache --regid=lancache --init-groups "$@"
fi

exec "$@"
