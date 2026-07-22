#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# PowerDNS container entrypoint. Generates RPZ zones from cdn-domains.txt
# (with monotonic serial handling), renders the recursor/authoritative config
# templates, validates them and keeps a known-good configuration snapshot
# history (#615, see docs/known-good-config-snapshots.md), configures DDNS
# TSIG auth (configure_ddns_tsig), and starts the authoritative server,
# recursor, and NATS subscriber in one container so DNS records stay aligned
# with Admin UI changes.
set -euo pipefail

# ── Shared-secret bootstrap (issue #858) ─────────────────────────────────────
# Embedded byte-identical copy of scripts/lib/shared-secret-bootstrap.sh's
# function definitions (guarded by tests/bats/shared_secret_bootstrap_sync.bats),
# for the same reason as the known-good-snapshot library below: this image
# builds from services/dns/ alone with no shared-file build context.
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
#     template-default shape. This omission IS deliberate:
#     deploy/dev/docker-compose.yml and deploy/dev/.env ship real, working dev
#     secrets in exactly that shape (e.g. lancache-nats-ui-dev-secret) that
#     this read path must accept as configured, not regenerate.
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

# ── Setup Variables ──────────────────────────────────────────────────────────
PROXY_IP="${PROXY_IP:?PROXY_IP is required - set it to the host LAN IP}"
PROXY_IPV6="${PROXY_IPV6:-}"
# Resolve the shared PDNS_API_KEY (issue #858): PowerDNS here (authoritative +
# recursor REST API) and the Admin UI's PowerDNS REST client must use the exact
# same key or the UI's domain writes get 401. A real configured value wins; an
# empty or checked-in placeholder is replaced by a first-writer-wins value shared
# with the UI via the shared-secrets volume, instead of crash-looping this
# container. The placeholder/length assertions further below still run on the
# resolved value as defense in depth.
_pdns_api_key_cfg="${PDNS_API_KEY:-}"
if secret_is_placeholder "$_pdns_api_key_cfg"; then _pdns_api_key_cfg=""; fi
if ! PDNS_API_KEY="$(resolve_shared_secret pdns-api-key "$_pdns_api_key_cfg" lancache_gen_hex32)"; then
    echo "[lancache-dns] FATAL: PDNS_API_KEY is unset/placeholder and the shared-secrets volume is not writable, so no shared key could be generated."
    echo "[lancache-dns] Mount the shared-secrets volume, or set PDNS_API_KEY to a real value (openssl rand -hex 32)."
    exit 1
fi
DDNS_ALLOW_FROM="${DDNS_ALLOW_FROM:-127.0.0.1}"
# Resolve the shared DDNS_TSIG_KEY (issue #858): the TSIG key PowerDNS imports
# here must be byte-identical to the one Kea's DHCP-DDNS daemon signs updates
# with. Historically an empty value meant "TSIG off, DDNS loopback-only"; now an
# empty/placeholder value is replaced by a first-writer-wins shared key so DDNS
# is TSIG-authenticated end-to-end (documented in docs/threat-model.md). If the
# shared volume is unwritable, fall back to the old empty = TSIG-off fail-safe
# rather than crash-looping.
_ddns_tsig_key_cfg="${DDNS_TSIG_KEY:-}"
if secret_is_placeholder "$_ddns_tsig_key_cfg"; then _ddns_tsig_key_cfg=""; fi
DDNS_TSIG_KEY="$(resolve_shared_secret ddns-tsig-key "$_ddns_tsig_key_cfg" lancache_gen_base64_32)" || DDNS_TSIG_KEY=""
DDNS_TSIG_NAME="${DDNS_TSIG_NAME:-lancache-ddns-key}"
DDNS_TSIG_ALGORITHM="${DDNS_TSIG_ALGORITHM:-hmac-sha256}"

# Fail closed when no real TSIG key is configured (PR #769 review follow-up).
# deploy/prod/docker-compose.yml's DDNS_ALLOW_FROM override sets this to the
# host's real LAN IP(s) (IP_STANDARD/IP_SSL) unconditionally, for the case
# DDNS_TSIG_KEY *is* set. But PowerDNS's own documented default is
# dnsupdate-require-tsig=no (confirmed against the upstream docs), which
# means "zones without TSIG keys can be updated by unauthenticated agents
# operating from an allowed address range" -- i.e. allow-dnsupdate-from
# alone, with no TSIG key configured at all, would accept an *unsigned* DNS
# UPDATE from anything that can send (or spoof, trivially on a shared LAN
# segment/UDP) a packet with that source IP. Forcing
# `dnsupdate-require-tsig=yes` globally in pdns.conf.template would close
# this cleanly, but this image's pdns-server (Debian Trixie, 4.9.x) predates
# that setting (added upstream only in PowerDNS 5.0.0) -- `--config=check`
# would reject it as an unknown setting and the container would refuse to
# start or roll back to a known-good snapshot. So the fix here is on the
# other side of the same equation: when DDNS_TSIG_KEY is empty (the shipped
# default until an operator generates one) or still a placeholder, there is
# no real auth control for DDNS at all, so allow-dnsupdate-from must not be
# widened past loopback regardless of what the environment/compose
# requested -- matching configure_ddns_tsig's own case pattern below and
# making docs/threat-model.md's existing "DDNS_TSIG_KEY is fail-closed"
# claim actually true. The CHANGE_ME*/changeme* placeholder case doesn't
# strictly need this (configure_ddns_tsig already exits 1 before pdns_server
# ever starts, further down this script), but is included anyway so this
# check doesn't silently rely on staying in sync with that later exit.
if secret_is_placeholder "$DDNS_TSIG_KEY"; then
    if [ "$DDNS_ALLOW_FROM" != "127.0.0.1" ]; then
        echo "[lancache-dns] No usable DDNS_TSIG_KEY is configured; forcing DDNS_ALLOW_FROM back to 127.0.0.1 (was: ${DDNS_ALLOW_FROM}) so unsigned DNS UPDATE packets from LAN hosts are not accepted."
        DDNS_ALLOW_FROM="127.0.0.1"
    fi
fi
LOG_QUERIES="${LOG_QUERIES:-${DNSMASQ_LOG_QUERIES:-0}}"
ROOT_ZONE_MIRROR="${ROOT_ZONE_MIRROR:-1}"
NATS_URL="${NATS_URL:-nats://nats:4222}"
NATS_USER="${NATS_USER:-}"
# Resolve the shared NATS password (issue #858). The nats server and this dns
# client must agree on the password for this container's role (dns-standard is
# the writer, dns-ssl the replica). NATS_PASSWORD_SHARED_SECRET names the
# shared-secrets file for that role; when set, an empty/placeholder NATS_PASSWORD
# is replaced by the first-writer-wins shared value. When unset (e.g. a remote
# secondary whose credentials come from setup.sh registration, with no shared
# volume) NATS_PASSWORD is left exactly as configured.
NATS_PASSWORD="${NATS_PASSWORD:-}"
if [ -n "${NATS_PASSWORD_SHARED_SECRET:-}" ]; then
    _nats_pw_cfg="$NATS_PASSWORD"
    if secret_is_placeholder "$_nats_pw_cfg"; then _nats_pw_cfg=""; fi
    # Fail closed (Codex review, PR #886): unlike DDNS_TSIG_KEY, an empty
    # NATS_PASSWORD has no safe fallback -- nats-subscriber just fails auth
    # silently and keeps retrying while this container's own DNS healthcheck
    # stays green, so record/flush propagation breaks with no boot-time signal.
    if ! NATS_PASSWORD="$(resolve_shared_secret "$NATS_PASSWORD_SHARED_SECRET" "$_nats_pw_cfg" lancache_gen_hex32)"; then
        echo "[lancache-dns] FATAL: NATS_PASSWORD is unset/placeholder and the shared-secrets volume is not writable, so no shared password could be generated."
        echo "[lancache-dns] Mount the shared-secrets volume, or set NATS_PASSWORD to the real value the nats service uses."
        exit 1
    fi
fi
NATS_TOKEN="${NATS_TOKEN:-}"
NATS_CONSUMER="${NATS_CONSUMER:-}"
NATS_RECONCILER="${NATS_RECONCILER:-0}"
KEEP_KNOWN_GOOD_CONFIGS="${KEEP_KNOWN_GOOD_CONFIGS:-3}"
DNS_CONFIG_SNAPSHOT_DIR="${DNS_CONFIG_SNAPSHOT_DIR:-/var/lib/lancache-dns/config-snapshots}"
# Zone/record rollback listener (#628, nats-subscriber's own process -- see
# services/dns/nats-subscriber/src/rollback_listener.rs). Bound to 0.0.0.0,
# not 127.0.0.1: the Admin UI reaching this port lives in a different
# container/network-namespace, the same reasoning that already applies to
# PowerDNS's own 8081/8082 (see rollback_listener.rs's module doc comment).
DNS_ROLLBACK_LISTEN_ADDR="${DNS_ROLLBACK_LISTEN_ADDR:-0.0.0.0:8083}"
RECURSOR_CONF_FILE="/etc/pdns/recursor.conf"
PDNS_AUTH_CONF_FILE="/etc/pdns/auth/pdns.conf"
# Central logging pipeline (#633): PowerDNS has no native "log to file"
# config directive on Linux -- confirmed against the upstream docs/mailing
# list, both pdns_server and pdns_recursor only ever write to stdout/stderr
# or syslog, never a plain file (the plan this followed assumed a
# `logfile=`-style directive existed, which is only ever true on the Windows
# build). So instead of a config change, run_auth/run_recursor below `tee`
# each daemon's own stdout/stderr into this file in addition to the
# container's normal stdout -- same dual-output shape as every other service
# in this issue, just implemented at the process level instead of in config.
PDNS_LOG_DIR="/var/log/lancache-dns"
mkdir -p "$PDNS_LOG_DIR"

# Fail if PDNS_API_KEY is a known placeholder value. secret_is_placeholder's
# universal CHANGE_ME*/changeme*/YOUR_*/*_HERE conventions (this project also
# uses YOUR_*_HERE elsewhere, e.g. SECONDARY_REGISTRATION_TOKEN) fully cover
# the PDNS-specific literals this check used to list separately.
if secret_is_placeholder "$PDNS_API_KEY"; then
    echo "[lancache-dns] FATAL: PDNS_API_KEY is still set to a default placeholder ('$PDNS_API_KEY')"
    echo "[lancache-dns] This is a security issue — the API key must be changed before deployment."
    echo "[lancache-dns] Generate a strong key with: openssl rand -hex 32"
    exit 1
fi

# Fail if PDNS_API_KEY is too short (weak) — checked for all values, not just placeholders
if [ ${#PDNS_API_KEY} -lt 16 ]; then
    echo "[lancache-dns] FATAL: PDNS_API_KEY is too short (${#PDNS_API_KEY} characters, minimum 16 required)"
    echo "[lancache-dns] Generate a strong key with: openssl rand -hex 32"
    exit 1
fi

# detect_pdns_local_address
# Determines this container's own real, non-loopback IPv4 address at
# runtime, so pdns_server (dnsupdate=yes) can bind a second, real listener
# alongside 127.0.0.1 -- DDNS updates from the separate `dhcp`
# container/host (network_mode: host in prod, a completely different
# container in dev) can only reach a loopback-only bind if they originate
# inside this same container, which they never do (issue #706). No fixed IP
# is knowable ahead of time and none is hardcoded: dev's dns-standard
# happens to get a static compose-assigned IP, but prod's container gets a
# dynamically-assigned Docker bridge-network IP on every start -- the same
# runtime self-detection below runs in both, with no per-environment
# special-casing. First tier mirrors setup.sh's detect_secondary_listen_ip
# (same "src" parsing of `ip route get`, the address the kernel would
# actually use to reach the internet, i.e. this container's real bridge
# address). Deliberately does NOT reuse that function's second-tier
# fallback verbatim: that fallback excludes 172.x addresses because it is
# hunting a *host's* real LAN IP, but this container's own address usually
# *is* a 172.x Docker bridge address -- the same exclusion here would
# reject exactly the address needed.
detect_pdns_local_address() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' \
        || true)
    if [ -n "$ip" ]; then
        printf '%s\n' "$ip"
        return 0
    fi

    # Fallback: first non-loopback IPv4 address on any interface, for the
    # rare case this container has no default route yet but is already
    # reachable on its own bridge address.
    ip=$(ip -4 addr show \
        | awk '/inet / && $2 !~ /^127\./ { sub(/\/.*/, "", $2); print $2; exit }' \
        || true)
    if [ -n "$ip" ]; then
        printf '%s\n' "$ip"
        return 0
    fi

    return 1
}

# Fails loud on failure, deliberately not silently falling back to
# 127.0.0.1: `pdns_server --config=check` (used below) validates syntax
# only, not reachability, so a silent fallback here would reintroduce the
# exact loopback-only-bind bug this is fixing without any startup error to
# catch it.
if ! PDNS_LOCAL_ADDRESS="$(detect_pdns_local_address)"; then
    echo "[lancache-dns] FATAL: could not detect this container's own non-loopback IPv4 address."
    echo "[lancache-dns] pdns_server must bind a real address (alongside 127.0.0.1) or DDNS updates from the dhcp container/host can never reach it."
    exit 1
fi
echo "[lancache-dns] pdns_server will bind local-address=127.0.0.1,${PDNS_LOCAL_ADDRESS}"

export PDNS_API_KEY DDNS_ALLOW_FROM PDNS_LOCAL_ADDRESS ROOT_ZONE_MIRROR NATS_URL NATS_USER NATS_PASSWORD NATS_TOKEN NATS_CONSUMER NATS_RECONCILER
# #628: nats-subscriber (the child process started below by
# run_nats_subscriber) reads these three directly -- KEEP_KNOWN_GOOD_CONFIGS
# and DNS_CONFIG_SNAPSHOT_DIR are shared with the recursor.conf/pdns.conf
# static-file adapter above (#615), DNS_ROLLBACK_LISTEN_ADDR is new for the
# zone/record rollback listener.
export KEEP_KNOWN_GOOD_CONFIGS DNS_CONFIG_SNAPSHOT_DIR DNS_ROLLBACK_LISTEN_ADDR

# ────────────────────────────────────────────────────────────────────────────
# Known-good configuration snapshot library (#415, #615)
#
# See docs/known-good-config-snapshots.md for the full contract. This block
# is a byte-identical copy of scripts/lib/known-good-snapshots.sh's function
# definitions (verified by tests/bats/known_good_snapshots_sync.bats) rather
# than a sourced file, because this Dockerfile builds from services/dns/
# alone with no shared-file build context wired up for it (same reasoning as
# the proxy/dhcp-proxy adapters).
# ────────────────────────────────────────────────────────────────────────────
# BEGIN known-good-snapshot library (scripts/lib/known-good-snapshots.sh)
# kgs_log <level> <label> <message...>
# Emits one explicit, greppable log line for every snapshot lifecycle event
# (create, prune, rollback-select, reject) per the issue's acceptance
# criteria. level is a short tag: CREATE/PRUNE/SELECT/REJECT/FATAL.
kgs_log() {
    local level="$1" label="$2"
    shift 2
    echo "[known-good-snapshot][${label}][${level}] $*" >&2
}

# kgs_new_snapshot_id
# Prints a new, sortable, practically collision-free snapshot id.
kgs_new_snapshot_id() {
    date -u +%Y%m%dT%H%M%S.%N
}

# kgs_list_snapshots <snapshot_root>
# Prints existing snapshot ids, oldest first, one per line. Empty output
# (no error) when <snapshot_root> does not exist yet or holds no snapshots.
# Excludes .staging.* entries: kgs_snapshot_create assembles a new snapshot
# in such a directory before the final atomic `mv` into its real <id> name,
# so a container killed mid-copy can leave one behind. Without this
# exclusion, a leftover .staging.* directory would be listed and treated as
# a real (but only partially-written) snapshot by callers of this function.
kgs_list_snapshots() {
    local snapshot_root="$1"
    [ -d "$snapshot_root" ] || return 0
    find "$snapshot_root" -mindepth 1 -maxdepth 1 -type d -not -name '.staging.*' -printf '%f\n' 2>/dev/null | sort
}

# kgs_snapshot_create <snapshot_root> <keep_n> <label> <file...>
# Copies <file...> into a new snapshot directory, then prunes anything
# beyond the newest <keep_n>. Creation is atomic-enough: files are
# assembled in a temporary sibling directory on the same filesystem and only
# `mv`-ed into their final <id> name once complete, so a crash mid-copy
# never leaves a partially-written snapshot directory visible to
# kgs_list_snapshots/kgs_snapshot_apply.
kgs_snapshot_create() {
    local snapshot_root="$1" keep_n="$2" label="$3"
    shift 3
    local -a files=("$@")
    local id staging f base

    mkdir -p "$snapshot_root" || {
        kgs_log FATAL "$label" "cannot create snapshot root $snapshot_root"
        return 1
    }

    id="$(kgs_new_snapshot_id)"
    staging="$(mktemp -d "${snapshot_root}/.staging.XXXXXX")" || {
        kgs_log FATAL "$label" "cannot create staging directory under $snapshot_root"
        return 1
    }

    for f in "${files[@]}"; do
        if [ ! -f "$f" ]; then
            kgs_log FATAL "$label" "candidate file missing, refusing snapshot: $f"
            rm -rf "$staging"
            return 1
        fi
        base="$(basename "$f")"
        if ! cp -p "$f" "$staging/$base"; then
            kgs_log FATAL "$label" "failed to copy $f into snapshot staging"
            rm -rf "$staging"
            return 1
        fi
    done

    if ! mv "$staging" "${snapshot_root}/${id}"; then
        kgs_log FATAL "$label" "failed to finalize snapshot $id"
        rm -rf "$staging"
        return 1
    fi

    kgs_log CREATE "$label" "created known-good snapshot $id (${files[*]})"
    kgs_snapshot_prune "$snapshot_root" "$keep_n" "$label"
}

# kgs_snapshot_prune <snapshot_root> <keep_n> <label>
# Deletes the oldest snapshots beyond <keep_n>. A missing/non-numeric/
# non-positive keep_n is clamped to the documented default of 3 rather than
# trusted as-is, so a misconfigured KEEP_KNOWN_GOOD_CONFIGS (e.g. "0" or
# empty) can never silently disable retention or prune away every snapshot,
# including the one just created by kgs_snapshot_create.
kgs_snapshot_prune() {
    local snapshot_root="$1" keep_n="$2" label="$3"
    case "$keep_n" in
        '' | *[!0-9]*) keep_n=3 ;;
    esac
    [ "$keep_n" -ge 1 ] || keep_n=3

    local -a ids=()
    while IFS= read -r id; do
        [ -n "$id" ] && ids+=("$id")
    done < <(kgs_list_snapshots "$snapshot_root")

    local total=${#ids[@]}
    local excess=$((total - keep_n))
    [ "$excess" -gt 0 ] || return 0

    local i id
    for ((i = 0; i < excess; i++)); do
        id="${ids[$i]}"
        if rm -rf "${snapshot_root:?}/${id}"; then
            kgs_log PRUNE "$label" "pruned known-good snapshot $id (retention=${keep_n})"
        else
            kgs_log FATAL "$label" "failed to prune snapshot $id"
        fi
    done
}

# kgs_snapshot_apply <snapshot_root> <label> <validator_cmd> <dest...>
# Attempts to roll the live config at <dest...> back to the newest snapshot
# that passes <validator_cmd> (a command string evaluated with no arguments
# after the snapshot's files have been copied onto <dest...>; it must exit 0
# for a valid config, e.g. "nginx -t" or "dnsmasq --test -C /etc/dnsmasq.conf").
# Tries snapshots newest-to-oldest, logging a REJECT line for each one that
# fails validation, and never applies one that doesn't pass. Prints the
# selected snapshot id and returns 0 on success. If no snapshot validates (or
# none exist), <dest...> is restored to exactly what was live before this
# function was called, so a failed rollback attempt never leaves <dest...>
# in a half-applied state, and returns 1.
kgs_snapshot_apply() {
    local snapshot_root="$1" label="$2" validator_cmd="$3"
    shift 3
    local -a dest=("$@")
    local -a ids=()
    while IFS= read -r id; do
        [ -n "$id" ] && ids+=("$id")
    done < <(kgs_list_snapshots "$snapshot_root")

    if [ "${#ids[@]}" -eq 0 ]; then
        kgs_log FATAL "$label" "no known-good snapshots available to roll back to"
        return 1
    fi

    local backup_dir
    backup_dir="$(mktemp -d)" || {
        kgs_log FATAL "$label" "cannot create rollback backup directory"
        return 1
    }
    local d base
    for d in "${dest[@]}"; do
        base="$(basename "$d")"
        [ -f "$d" ] && cp -p "$d" "$backup_dir/$base"
    done

    local i id snap_dir
    for ((i = ${#ids[@]} - 1; i >= 0; i--)); do
        id="${ids[$i]}"
        snap_dir="${snapshot_root}/${id}"

        # Require every requested basename to be present in this snapshot
        # before touching any live file. A finalized-but-incomplete
        # snapshot (e.g. taken before a new generated file was added to the
        # candidate list) would otherwise leave that one dest untouched --
        # silently validating a mix of this snapshot's files and whatever
        # happened to already be live, a combination that was never itself
        # actually validated together.
        local snapshot_complete=1
        for d in "${dest[@]}"; do
            base="$(basename "$d")"
            if [ ! -f "${snap_dir}/${base}" ]; then
                snapshot_complete=0
                break
            fi
        done
        if [ "$snapshot_complete" -ne 1 ]; then
            kgs_log REJECT "$label" "rejected known-good snapshot $id: incomplete (missing at least one candidate file)"
            continue
        fi

        for d in "${dest[@]}"; do
            base="$(basename "$d")"
            cp -p "${snap_dir}/${base}" "$d"
        done

        # Redirect the validator's own stdout to stderr: this function's
        # stdout is the caller's return channel (the selected snapshot id
        # via command substitution), and a validator like "nginx -t" or
        # "dnsmasq --test" may print its own diagnostic text to stdout,
        # which would otherwise silently corrupt that return value.
        if eval "$validator_cmd" 1>&2; then
            kgs_log SELECT "$label" "selected known-good snapshot $id for rollback"
            rm -rf "$backup_dir"
            printf '%s\n' "$id"
            return 0
        fi
        kgs_log REJECT "$label" "rejected known-good snapshot $id: failed validation"
    done

    # Nothing validated: restore exactly what was live before this call so a
    # failed rollback attempt never leaves dest in a half-applied state.
    for d in "${dest[@]}"; do
        base="$(basename "$d")"
        if [ -f "$backup_dir/$base" ]; then
            cp -p "$backup_dir/$base" "$d"
        else
            rm -f "$d"
        fi
    done
    rm -rf "$backup_dir"
    kgs_log FATAL "$label" "no known-good snapshot passed validation; refusing rollback"
    return 1
}
# END known-good-snapshot library

# ────────────────────────────────────────────────────────────────────────────
# Domain validation library (scripts/lib/domain-validation.sh)
#
# Mirrors the label-strict rules from Admin UI (domains.rs) and
# services/proxy/entrypoint.sh's own embedded copy, so a malformed or
# overly-broad cdn-domains.txt entry (e.g. a bare TLD, a single label like
# "localhost", or "*") is rejected here too, not just in the UI that writes
# the file. Before this, section 7's RPZ zone generation below had zero
# validation: a bad entry would generate an RPZ wildcard rule that could
# redirect far more DNS traffic than intended. This block is a
# byte-identical copy of scripts/lib/domain-validation.sh's function
# definitions (verified by tests/bats/domain_validation_sync.bats) rather
# than a sourced file, for the same reason as the libraries above: this
# image builds from services/dns/ alone with no shared-file build context
# wired up for it.
# ────────────────────────────────────────────────────────────────────────────
# BEGIN domain-validation library (scripts/lib/domain-validation.sh)
_is_valid_domain_label() {
    local label="$1"

    # Label must not be empty
    [ -n "$label" ] || return 1

    # Label must be <= 63 chars
    [ ${#label} -le 63 ] || return 1

    # Label must not start or end with hyphen
    [[ "$label" != -* ]] && [[ "$label" != *- ]] || return 1

    # Label must only contain lowercase ASCII a-z, digits 0-9, or hyphen
    [[ "$label" =~ ^[a-z0-9-]+$ ]] || return 1

    return 0
}

# Prints the normalized form (trimmed, lowercased, leading dot stripped) of a
# domain to stdout. Callers must capture this and use it instead of the raw
# input for anything written to disk/config — _is_valid_domain() only reports
# whether a value validates, it does not mutate the caller's variable.
_normalize_domain() {
    local domain="$1"
    # Trim whitespace via pure parameter expansion, not xargs — xargs applies
    # shell-style unquoting/escaping first, which would let malformed manual
    # entries like a quoted "Example.COM" slip through as a clean example.com.
    domain="${domain#"${domain%%[![:space:]]*}"}"
    domain="${domain%"${domain##*[![:space:]]}"}"
    domain="${domain,,}"
    domain="${domain#.}"
    printf '%s' "$domain"
}

_is_valid_domain() {
    local domain
    domain="$(_normalize_domain "$1")"

    # Must not be empty after normalization
    [ -n "$domain" ] || return 1

    # Must be <= 253 chars total
    [ ${#domain} -le 253 ] || return 1

    # Check for trailing dot (RFC 1035 allows it, but we reject it like the Rust validator does)
    [[ "$domain" != *. ]] || return 1

    # Validate each label using a loop to properly handle empty labels
    # (bash word splitting would silently drop trailing empty labels,
    # but we want to reject domains like "example.com." explicitly)
    local label
    local remaining="$domain"

    while [ -n "$remaining" ]; do
        # Extract label up to next dot
        if [[ "$remaining" == *.* ]]; then
            label="${remaining%%.*}"
            remaining="${remaining#*.}"
        else
            label="$remaining"
            remaining=""
        fi

        _is_valid_domain_label "$label" || return 1
    done

    # Must have at least 2 labels (so the loop must execute at least twice)
    # We can check this by ensuring the domain contains at least one dot
    [[ "$domain" == *.* ]] || return 1

    return 0
}
# END domain-validation library

LAN_ZONES=(
    lan.
    local.lan.
)

PRIVATE_REVERSE_ZONES=(
    10.in-addr.arpa.
    168.192.in-addr.arpa.
    16.172.in-addr.arpa.
    17.172.in-addr.arpa.
    18.172.in-addr.arpa.
    19.172.in-addr.arpa.
    20.172.in-addr.arpa.
    21.172.in-addr.arpa.
    22.172.in-addr.arpa.
    23.172.in-addr.arpa.
    24.172.in-addr.arpa.
    25.172.in-addr.arpa.
    26.172.in-addr.arpa.
    27.172.in-addr.arpa.
    28.172.in-addr.arpa.
    29.172.in-addr.arpa.
    30.172.in-addr.arpa.
    31.172.in-addr.arpa.
    c.f.ip6.arpa.
    d.f.ip6.arpa.
)

DDNS_UPDATE_ZONES=("${LAN_ZONES[@]}" "${PRIVATE_REVERSE_ZONES[@]}")

configure_ddns_tsig() {
    if [ -z "$DDNS_TSIG_KEY" ]; then
        echo "[lancache-dns] DDNS_TSIG_KEY is not set; TSIG-authenticated DNS updates are not configured."
        return
    fi
    if secret_is_placeholder "$DDNS_TSIG_KEY"; then
        echo "[lancache-dns] FATAL: DDNS_TSIG_KEY is still set to a default placeholder."
        printf '%s\n' "[lancache-dns] Generate a shared key with: openssl rand -base64 32 | tr -d '\\n'"
        exit 1
    fi

    pdnsutil --config-dir=/etc/pdns/auth import-tsig-key \
        "$DDNS_TSIG_NAME" "$DDNS_TSIG_ALGORITHM" "$DDNS_TSIG_KEY" >/dev/null

    for zone in "${DDNS_UPDATE_ZONES[@]}"; do
        pdnsutil --config-dir=/etc/pdns/auth set-meta "$zone" TSIG-ALLOW-DNSUPDATE "$DDNS_TSIG_NAME" >/dev/null
    done

    echo "[lancache-dns] Configured TSIG-authenticated DDNS updates for LAN zones."
}

render_template_atomic() {
    local variables="$1" template="$2" target="$3"
    local enable_query_logging="${4:-0}"
    local target_dir target_name tmp

    target_dir=$(dirname "$target")
    target_name=$(basename "$target")
    tmp=$(mktemp "${target_dir}/.${target_name}.tmp.XXXXXX") \
        || {
            echo "[lancache-dns] FATAL: failed to create a temporary file for $target_name"
            exit 1
        }

    if ! envsubst "$variables" < "$template" > "$tmp"; then
        rm -f "$tmp"
        echo "[lancache-dns] FATAL: failed to render $target_name"
        exit 1
    fi
    if [ "$enable_query_logging" = "1" ]; then
        sed -i 's/^  loglevel: 3$/  loglevel: 6/' "$tmp"
    fi

    if ! mv "$tmp" "$target"; then
        rm -f "$tmp"
        echo "[lancache-dns] FATAL: failed to replace $target_name"
        exit 1
    fi
}

# _dns_recursor_validate_snapshot_or_rollback <recursor_conf_file>
# recursor.conf's validator: `pdns_recursor --config=check` is a genuine
# side-effect-free check-only invocation, confirmed present in the Debian
# Trixie pdns-recursor package (5.2.x) -- it parses and validates the YAML
# config and exits non-zero on error without binding any sockets or starting
# the recursor, exactly like `nginx -t`/`dnsmasq --test`. Factored into its
# own function so tests/bats/dns_known_good_snapshot.bats can drive it
# against a stub `pdns_recursor` binary.
_dns_recursor_validate_snapshot_or_rollback() {
    local recursor_conf="$1"
    local config_dir
    config_dir="$(dirname "$recursor_conf")"

    echo "[lancache-dns] Validating recursor.conf (pdns_recursor --config=check)..."
    if pdns_recursor --config=check --config-dir="$config_dir" >/dev/null; then
        # Checked explicitly (not left to `set -e`): this function is called
        # at its call site as `... || exit 1`, and bash suppresses errexit
        # for every command run inside a function invoked on the left side
        # of `||` -- so a non-zero kgs_snapshot_create here would otherwise
        # fall through to `return 0` silently, leaving no rollback baseline
        # for a future bad config. Matches the proxy adapter's handling.
        if ! kgs_snapshot_create "${DNS_CONFIG_SNAPSHOT_DIR}/recursor" "$KEEP_KNOWN_GOOD_CONFIGS" "dns-recursor" "$recursor_conf"; then
            echo "[lancache-dns] WARNING: failed to record this valid recursor.conf as a known-good snapshot (see FATAL line above); rollback protection is degraded until this succeeds." >&2
        fi
        return 0
    fi

    echo "[lancache-dns] ERROR: generated recursor.conf failed validation (pdns_recursor --config=check)." >&2
    echo "[lancache-dns] ERROR: attempting rollback to the newest known-good snapshot instead of starting with an invalid config." >&2
    local selected_id
    if selected_id="$(kgs_snapshot_apply "${DNS_CONFIG_SNAPSHOT_DIR}/recursor" "dns-recursor" "pdns_recursor --config=check --config-dir='${config_dir}'" "$recursor_conf")"; then
        echo "[lancache-dns] WARNING: recursor is starting from known-good snapshot ${selected_id}, NOT the newly generated config." >&2
        echo "[lancache-dns] WARNING: check PDNS_API_KEY/LOG_QUERIES and restart to pick up the intended change." >&2
        # This function only ever rolls back recursor.conf, never pdns.conf
        # (deliberately -- see the comment at this pair's call site). That
        # split means a *partial* rollback -- recursor.conf falls back here
        # while pdns.conf, validated separately below, still passes -- can
        # leave the two daemons with different PDNS_API_KEY values: recursor
        # keeps whatever key was baked into the restored snapshot, while
        # pdns.conf and every out-of-process caller (Admin UI, nats-
        # subscriber) use the current environment's key. This isn't specific
        # to a YAML-breaking key value -- it happens any time recursor.conf
        # fails validation for some other reason on a restart where
        # PDNS_API_KEY also changed. Detected here, not assumed: compare
        # what's actually on disk after the restore against the live env,
        # so this only fires when the two are genuinely out of sync.
        local restored_api_key
        restored_api_key=$(sed -n 's/^[[:space:]]*api_key:[[:space:]]*//p' "$recursor_conf" | head -n1)
        if [ -n "$restored_api_key" ] && [ "$restored_api_key" != "$PDNS_API_KEY" ]; then
            echo "[lancache-dns] WARNING: the restored recursor.conf's api_key does not match the current PDNS_API_KEY. The recursor's REST API (port 8082) is now authenticating with a stale key while pdns.conf, the Admin UI, and nats-subscriber use the current one -- packet-cache flush calls will fail with 401 until PDNS_API_KEY is fixed and the container is restarted." >&2
        fi
        return 0
    fi

    echo "[lancache-dns] FATAL: no known-good recursor.conf snapshot is available; refusing to start with an invalid config." >&2
    return 1
}

# _dns_auth_validate_snapshot_or_rollback <pdns_conf_file>
# pdns.conf's validator: `pdns_server --config=check --config-dir=<dir>` is
# a genuine side-effect-free check-only invocation, exactly like
# `pdns_recursor --config=check` above and `nginx -t`/`dnsmasq --test`.
# `--help` on the packaged pdns-server (4.9.x) doesn't spell out "check" as
# a value the way pdns_recursor's --help does, which earlier led this
# adapter to a more complex start-then-verify probe (start the daemon, poll
# `pdns_control rping`, tear down) instead. Live-verified against the real
# binary on a self-hosted runner (not assumed) that the flag genuinely
# exists and works: `--config=check` exits 0 on a valid config; exits 1 and
# prints a "Fatal error: Trying to set unknown setting '<name>'" on an
# unknown/malformed setting (the realistic failure mode here -- a broken
# `PDNS_API_KEY`/`DDNS_ALLOW_FROM` substitution corrupting the file); exits
# 1 on a `launch=` backend that fails to load; and in every case exits
# within well under a second, binds no port, and leaves no process running
# -- equivalent detection coverage to the start-then-verify probe for this
# adapter's actual failure surface, without ever having to start a real
# `pdns_server` instance. (Neither this check nor a full daemon start
# validates semantic values such as CIDR syntax in `allow-dnsupdate-from`
# -- confirmed empirically that PowerDNS does not parse that eagerly at
# startup either way, so this is a pre-existing PowerDNS limitation, not a
# gap introduced by preferring the simpler check-only flag.) Factored into
# its own function so tests/bats/dns_known_good_snapshot.bats can drive it
# against a stub `pdns_server` binary.
_dns_auth_validate_snapshot_or_rollback() {
    local pdns_conf="$1"
    local config_dir
    config_dir="$(dirname "$pdns_conf")"

    echo "[lancache-dns] Validating pdns.conf (pdns_server --config=check)..."
    if pdns_server --config=check --config-dir="$config_dir" >/dev/null; then
        # Checked explicitly -- same `set -e`-suppressed-by-`||`-at-the-call-site
        # reasoning as the recursor function above.
        if ! kgs_snapshot_create "${DNS_CONFIG_SNAPSHOT_DIR}/auth" "$KEEP_KNOWN_GOOD_CONFIGS" "dns-auth" "$pdns_conf"; then
            echo "[lancache-dns] WARNING: failed to record this valid pdns.conf as a known-good snapshot (see FATAL line above); rollback protection is degraded until this succeeds." >&2
        fi
        return 0
    fi

    echo "[lancache-dns] ERROR: generated pdns.conf failed validation (pdns_server --config=check)." >&2
    echo "[lancache-dns] ERROR: attempting rollback to the newest known-good snapshot instead of starting with an invalid config." >&2
    local selected_id
    if selected_id="$(kgs_snapshot_apply "${DNS_CONFIG_SNAPSHOT_DIR}/auth" "dns-auth" "pdns_server --config=check --config-dir='${config_dir}'" "$pdns_conf")"; then
        echo "[lancache-dns] WARNING: pdns_server is starting from known-good snapshot ${selected_id}, NOT the newly generated config." >&2
        echo "[lancache-dns] WARNING: check PDNS_API_KEY/DDNS_ALLOW_FROM and restart to pick up the intended change." >&2
        # Mirrors the recursor rollback's stale-API-key detection above (see
        # the comment there for why a partial rollback -- only one side
        # restoring an older snapshot while the other still validates -- can
        # leave PDNS_API_KEY out of sync between daemons). Here it's the
        # authoritative server's own REST API (port 8081, consumed by the
        # Admin UI and nats-subscriber) that ends up on the stale key while
        # recursor.conf keeps the current one. Detected here, not assumed:
        # compare what's actually on disk after the restore against the live
        # env, so this only fires when the two are genuinely out of sync.
        # pdns.conf is flat `key=value` (no leading whitespace, no YAML
        # colon), unlike recursor.conf's indented `api_key: value`.
        local restored_api_key
        restored_api_key=$(sed -n 's/^api-key=//p' "$pdns_conf" | head -n1)
        if [ -n "$restored_api_key" ] && [ "$restored_api_key" != "$PDNS_API_KEY" ]; then
            echo "[lancache-dns] WARNING: the restored pdns.conf's api-key does not match the current PDNS_API_KEY. The authoritative server's REST API (port 8081) is now authenticating with a stale key while recursor.conf, the Admin UI, and nats-subscriber use the current one -- domain writes/reconciliation calls will fail with 401 until PDNS_API_KEY is fixed and the container is restarted." >&2
        fi

        # #706 follow-up (PR #769 review): the restored snapshot's
        # local-address line still holds whichever Docker bridge IP this
        # container had when *that* snapshot was created (pdns.conf.template
        # bakes in the dynamic $PDNS_LOCAL_ADDRESS). If this container was
        # recreated since then, that address may no longer exist on any
        # interface here -- and `pdns_server --config=check` never catches
        # this, because it doesn't validate whether an address is actually
        # bindable (same "doesn't parse eagerly" limitation noted above for
        # allow-dnsupdate-from). Left alone, pdns_server would restart-loop
        # trying to bind a dead address after a rollback that itself
        # reported success. Re-stamp the restored file with this session's
        # freshly-detected address (byte-identical to what
        # render_template_atomic would have emitted) before returning --
        # deliberately not re-validated, since this substitution only
        # touches the one value the check-only validator already ignores.
        if [ -n "${PDNS_LOCAL_ADDRESS:-}" ]; then
            sed -i "s/^local-address=.*/local-address=127.0.0.1,${PDNS_LOCAL_ADDRESS}/" "$pdns_conf"
        fi
        return 0
    fi

    echo "[lancache-dns] FATAL: no known-good pdns.conf snapshot is available; refusing to start with an invalid config." >&2
    return 1
}

echo "[lancache-dns] Proxy IPv4: $PROXY_IP"
[ -n "$PROXY_IPV6" ] && echo "[lancache-dns] Proxy IPv6: $PROXY_IPV6"

# ── 1. Generate Recursor Config ──────────────────────────────────────────────
echo "[lancache-dns] Generating recursor.conf..."
# shellcheck disable=SC2016 # envsubst needs the literal variable name.
if [ "$LOG_QUERIES" = "1" ]; then
    echo "[lancache-dns] Enabling query logging..."
fi
render_template_atomic '${PDNS_API_KEY}' /etc/pdns/recursor.conf.template "$RECURSOR_CONF_FILE" "$LOG_QUERIES"
_dns_recursor_validate_snapshot_or_rollback "$RECURSOR_CONF_FILE" || exit 1

# ── 2. Generate Authoritative Config ─────────────────────────────────────────
echo "[lancache-dns] Generating pdns.conf..."
# shellcheck disable=SC2016 # envsubst needs the literal variable names.
render_template_atomic '${PDNS_API_KEY}:${DDNS_ALLOW_FROM}:${PDNS_LOCAL_ADDRESS}' /etc/pdns/auth/pdns.conf.template "$PDNS_AUTH_CONF_FILE"

# ── 3. Initialize SQLite Database ────────────────────────────────────────────
if [ ! -f /var/lib/powerdns/pdns.sqlite3 ]; then
    echo "[lancache-dns] Initializing SQLite database..."
    SCHEMA=$(find /usr/share -name 'schema.sqlite3.sql' -print -quit 2>/dev/null)
    if [ -z "$SCHEMA" ]; then
        echo "[lancache-dns] FATAL: sqlite schema not found in /usr/share"
        exit 1
    fi
    echo "[lancache-dns] Using schema: $SCHEMA"
    sqlite3 /var/lib/powerdns/pdns.sqlite3 < "$SCHEMA"
    chown pdns:pdns /var/lib/powerdns/pdns.sqlite3
fi

# ── 4. Validate Authoritative Config (pdns_server --config=check, #615) ─────
# `--config=check` doesn't require the SQLite database to exist (verified
# empirically -- it still exits 0 with a nonexistent gsqlite3-database=
# path), so this could in principle run before step 3. It's kept here,
# after the database exists and before any pdnsutil call below, purely so
# the validated config is confirmed in place before anything else in this
# script (zone creation, TSIG import) depends on pdns.conf being parseable
# -- if this rolls back to a known-good snapshot, every subsequent
# pdnsutil/zone-creation call must see that rolled-back config, not the
# rejected candidate.
_dns_auth_validate_snapshot_or_rollback "$PDNS_AUTH_CONF_FILE" || exit 1

# ── 5. Migrate Legacy AAAA Filter Marker ─────────────────────────────────────
# The AAAA filter marker moved from this container's own data volume
# (toggled via `docker exec` before the Docker socket proxy was narrowed) to
# the shared /var/lib/powerdns-state volume the Admin UI now toggles instead.
# This container is the only one that can ever see the old marker (it lived
# in this container's own /var/lib/powerdns), so it owns migrating it forward
# one time; the Admin UI has no access to /var/lib/powerdns to do this itself.
LEGACY_AAAA_FILTER_MARKER="/var/lib/powerdns/aaaa-filter-enabled"
AAAA_FILTER_STATE_DIR="/var/lib/powerdns-state"
AAAA_FILTER_MARKER="${AAAA_FILTER_STATE_DIR}/aaaa-filter-enabled"
if [ -f "$LEGACY_AAAA_FILTER_MARKER" ]; then
    mkdir -p "$AAAA_FILTER_STATE_DIR"
    if [ ! -f "$AAAA_FILTER_MARKER" ]; then
        echo "[lancache-dns] Migrating legacy AAAA filter marker to shared state volume..."
        touch "$AAAA_FILTER_MARKER"
    else
        echo "[lancache-dns] Removing already-migrated legacy AAAA filter marker..."
    fi
    rm -f "$LEGACY_AAAA_FILTER_MARKER"
fi

# ── 6. Create LAN Zones ──────────────────────────────────────────────────────
echo "[lancache-dns] Creating LAN zones in authoritative database..."

# Create LAN zones (will not error if already exist)
for zone in "${LAN_ZONES[@]}"; do
    pdnsutil --config-dir=/etc/pdns/auth create-zone "$zone" || true
done

# Create empty reverse zones for privacy (prevent external PTR leakage)
for zone in "${PRIVATE_REVERSE_ZONES[@]}"; do
    pdnsutil --config-dir=/etc/pdns/auth create-zone "$zone" || true
done

configure_ddns_tsig

# ── 7. Generate RPZ Zone from cdn-domains.txt ────────────────────────────────
echo "[lancache-dns] Generating RPZ zone from cdn-domains.txt..."
SERIAL=$(date +%s | tail -c 11)
RPZ_FILE="/var/lib/powerdns/rpz.zone"

# Preserve monotonic RPZ SOA serials: ensure SERIAL doesn't go backwards
if [ -f "$RPZ_FILE" ]; then
    OLD_SERIAL=$(grep -oP '^\s*@\s+SOA\s+[^\s]+\s+[^\s]+\s+\K\d+' "$RPZ_FILE" 2>/dev/null || echo 0)
    if [ "$SERIAL" -le "$OLD_SERIAL" ]; then
        SERIAL=$(( OLD_SERIAL + 1 ))
        echo "[lancache-dns] Monotonic serial: new=$SERIAL (was $OLD_SERIAL)"
    fi
fi

{
    echo "\$ORIGIN rpz."
    echo "\$TTL 60"
    echo "@ SOA localhost. admin.rpz. $SERIAL 3600 900 604800 60"
    echo "@ NS localhost."
    echo ""
    while IFS= read -r domain || [ -n "$domain" ]; do
        domain="${domain#"${domain%%[![:space:]]*}"}"
        domain="${domain%"${domain##*[![:space:]]}"}"
        [[ -z "$domain" || "$domain" == \#* ]] && continue
        is_wildcard_only=0
        if [[ "$domain" == .* ]]; then
            is_wildcard_only=1
            domain="${domain#.}"
        fi
        [[ -z "$domain" ]] && continue
        # Reject a malformed or overly-broad entry (bare TLD, single label
        # like "localhost", "*", control/special characters) before it ever
        # becomes an RPZ rule: an unvalidated entry here could redirect far
        # more DNS traffic than intended (e.g. a bare "com" would generate
        # "*.com", matching almost every .com domain). Mirrors
        # services/proxy/entrypoint.sh's _collect_domain_rows validation of
        # the same cdn-domains.txt file.
        if ! _is_valid_domain "$domain"; then
            echo "[lancache-dns] WARNING: skipping invalid domain entry in RPZ zone: $domain" >&2
            continue
        fi
        domain="$(_normalize_domain "$domain")"
        [[ -z "$domain" ]] && continue
        # Three non-overlapping match modes selected by how the entry is
        # written (issue #1072): a bare entry ("domain.com" or
        # "sub.domain.com") matches only that exact host and must never also
        # emit a wildcard record for what's underneath it; only a
        # leading-dot entry (".domain.com") opts into wildcard coverage, and
        # in that case the bare root itself is deliberately not emitted.
        if [ "$is_wildcard_only" -eq 0 ]; then
            printf "%s 60 IN A %s\n" "${domain}" "${PROXY_IP}"
        else
            printf "*.%s 60 IN A %s\n" "${domain}" "${PROXY_IP}"
        fi
        if [ -n "$PROXY_IPV6" ]; then
            if [ "$is_wildcard_only" -eq 0 ]; then
                printf "%s 60 IN AAAA %s\n" "${domain}" "${PROXY_IPV6}"
            else
                printf "*.%s 60 IN AAAA %s\n" "${domain}" "${PROXY_IPV6}"
            fi
        fi
    done < /etc/pdns/cdn-domains.txt
} > "$RPZ_FILE"

count=$(grep -c "^[a-zA-Z*]" "$RPZ_FILE" 2>/dev/null || true)
echo "[lancache-dns] RPZ zone: ${count:-0} records written."
chown pdns:pdns "$RPZ_FILE"

# ── 8. Start Both Processes (with restart loops) ─────────────────────────────
echo "[lancache-dns] Starting PowerDNS Authoritative and Recursor..."

run_auth() {
    while true; do
        pdns_server --config-dir=/etc/pdns/auth --guardian=no --daemon=no 2>&1 \
            | tee -a "$PDNS_LOG_DIR/pdns-auth.log" || true
        echo "[lancache-dns] pdns_server exited, restarting in 3s..."
        sleep 3
    done
}

run_recursor() {
    mkdir -p /var/run/pdns-recursor
    while true; do
        pdns_recursor --config-dir=/etc/pdns 2>&1 \
            | tee -a "$PDNS_LOG_DIR/pdns-recursor.log" || true
        echo "[lancache-dns] pdns_recursor exited, restarting in 3s..."
        sleep 3
    done
}

# Start auth server first
run_auth &
AUTH_PID=$!

# Wait for pdns_server to be ready before starting recursor (polling with timeout)
READY=0
for i in {1..10}; do
    if pdns_control rping >/dev/null 2>&1; then
        echo "[lancache-dns] pdns_server is ready (attempt $i)"
        READY=1
        break
    fi
    sleep 0.5
done
if [ $READY -eq 0 ]; then
    echo "[lancache-dns] WARNING: pdns_server did not respond to ping; recursor will start anyway"
fi

# Start recursor
run_recursor &
REC_PID=$!

# ── 9. Start NATS Subscriber ────────────────────────────────────────────────
run_nats_subscriber() {
    while true; do
        # Central logging pipeline (#633): tee alongside pdns_server/pdns_recursor
        # above so nats-subscriber's connect/auth/processing errors also reach
        # fluent-bit's tail of $PDNS_LOG_DIR/*.log instead of only Docker stdout.
        nats-subscriber 2>&1 \
            | tee -a "$PDNS_LOG_DIR/nats-subscriber.log" || true
        echo "[lancache-dns] nats-subscriber exited, restarting in 3s..."
        sleep 3
    done
}

run_nats_subscriber &
NATS_PID=$!

# Handle termination
trap 'kill $AUTH_PID $REC_PID $NATS_PID 2>/dev/null || true' EXIT TERM INT

# Wait indefinitely
wait
