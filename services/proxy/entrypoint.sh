#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Nginx proxy entrypoint. Generates TLS interception certificates, renders
# request policy maps derived from cdn-domains.txt, validates the result and
# keeps a known-good configuration snapshot history (#415, see
# docs/known-good-config-snapshots.md), and starts the combined HTTP plus
# HTTPS proxy configuration.
set -euo pipefail

CA_DIR="/etc/nginx/ssl/ca"
CERT_DIR="/etc/nginx/ssl/certs"
DOMAINS_FILE="/etc/nginx/cdn-domains.txt"
PUBLIC_SUFFIX_LIST_FILE="/etc/nginx/public_suffix_list.dat"
SSL_MAP_FILE="/etc/nginx/conf.d/00-ssl-map.conf"
STREAM_TARGET_FILE="/etc/nginx/stream.d/00-stream-targets.conf"

# ────────────────────────────────────────────────────────────────────────────
# 0. Validate required environment variables
# ────────────────────────────────────────────────────────────────────────────
IP_STANDARD="${IP_STANDARD:?IP_STANDARD is required}"
IP_SSL="${IP_SSL:-}"
SSL_ENABLED="${SSL_ENABLED:-0}"
# Last-resort fallback if the container is run without an env_file at all
# (normal installs always set this via config/{dev,prod}/proxy.env or
# deploy/quickstart/.env). Matches those shipped defaults, including the
# bracketed IPv6 servers nginx's resolver directive requires.
NGINX_UPSTREAM_RESOLVER="${NGINX_UPSTREAM_RESOLVER:-8.8.8.8 8.8.4.4 [2001:4860:4860::8888] [2001:4860:4860::8844]}"
PROXY_SECURITY_MODE="${PROXY_SECURITY_MODE:-lazy}"
PROXY_ALLOWED_CLIENT_CIDRS="${PROXY_ALLOWED_CLIENT_CIDRS:-}"
KEEP_KNOWN_GOOD_CONFIGS="${KEEP_KNOWN_GOOD_CONFIGS:-3}"
PROXY_CONFIG_SNAPSHOT_DIR="${PROXY_CONFIG_SNAPSHOT_DIR:-/var/lib/lancache-proxy/config-snapshots}"

# ────────────────────────────────────────────────────────────────────────────
# 0a. Known-good configuration snapshot library (#415)
#
# See docs/known-good-config-snapshots.md for the full contract. This block
# is a byte-identical copy of scripts/lib/known-good-snapshots.sh's function
# definitions (verified by tests/bats/known_good_snapshots_sync.bats) rather
# than a sourced file, because this Dockerfile builds from services/proxy/
# alone with no shared-file build context wired up for it.
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

_normalize_resolver_token() {
    local token="$1"

    # Nginx accepts IPv6 resolvers in brackets and optional ports for IPv4 or
    # bracketed IPv6. Normalize those forms before comparing against local IPs.
    if [[ "$token" == \[* ]]; then
        token="${token#\[}"
        token="${token%%\]*}"
    elif [[ "$token" == *:* && "$token" != *:*:* ]]; then
        token="${token%%:*}"
    fi

    printf '%s' "$token"
}

# ────────────────────────────────────────────────────────────────────────────
# Domain validation: Mirrors the label-strict rules from Admin UI (domains.rs)
# to prevent invalid domains from being used in nginx maps, cert generation,
# and stream targets. Validation follows RFC 1035 and DNS best practices:
#
#   - Max 253 chars total length
#   - Min 2 labels (no single-label domains like "localhost")
#   - Each label: 1-63 chars, start/end with alphanumeric, contain only a-z/0-9/-
#   - Leading dot is stripped (optional in file notation)
#   - Input is trimmed and lowercased before validation
#   - Control characters and special chars are rejected
# ────────────────────────────────────────────────────────────────────────────

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

# ────────────────────────────────────────────────────────────────────────────
# Public-suffix-aware root domain derivation
#
# cdn-domains.txt is the single source of truth for CDN hostnames (see
# services/dns/entrypoint.sh, which drives DNS spoofing from the same file).
# Before v0.2.0, cdn-ssl-domains.txt was a SEPARATE, hand-maintained list of
# root domains for this file's wildcard cert generation, which an operator
# had to keep in sync by hand. In practice it never was: it carried three
# leftover entries from the project's initial commit with no corresponding
# DNS entry (dead certs, never reachable via any real SNI), and was missing
# root coverage for at least one real DNS-listed domain (drivers.amd.com had
# no matching cert because the hand-picked root was downloads.amd.com, a
# sibling subdomain, not the true registrable root amd.com). This section
# derives the same root domains automatically and correctly instead.
#
# "Correctly" here means using the real Mozilla Public Suffix List
# (vendored at $PUBLIC_SUFFIX_LIST_FILE, https://publicsuffix.org/list/,
# MPL-2.0) rather than a naive "last two labels" guess, which silently
# breaks for any domain under a compound-label TLD like co.uk or com.au
# (the root of foo.example.co.uk is example.co.uk, not co.uk).
#
# Deliberately ICANN-section only: the PSL also has a "PRIVATE DOMAINS"
# section listing CDN/hosting platforms (including akamaized.net and
# akamaihd.net, both used by real entries in cdn-domains.txt) where each
# customer's subdomain is treated as its own independently registrable
# name. That's the opposite of what this proxy needs — it wants ONE broad
# wildcard cert covering an entire shared CDN platform regardless of which
# customer a given hostname belongs to, not a separate cert per customer
# subdomain. Loading only the ICANN section makes akamaized.net itself the
# derived root (matching the pre-v0.2.0 hand-curated value), instead of
# deriving something like epicgames-download1.akamaized.net.
declare -A _PSL_RULES=()
declare -A _PSL_WILDCARDS=()
declare -A _PSL_EXCEPTIONS=()

_load_public_suffix_list() {
    local line rule
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" == "// ===BEGIN PRIVATE DOMAINS===" ]] && break
        [[ -z "$line" || "$line" == //* ]] && continue
        rule="$line"
        if [[ "$rule" == !* ]]; then
            _PSL_EXCEPTIONS["${rule#!}"]=1
        elif [[ "$rule" == \*.* ]]; then
            _PSL_WILDCARDS["${rule#\*.}"]=1
        else
            _PSL_RULES["$rule"]=1
        fi
    done < "$PUBLIC_SUFFIX_LIST_FILE"
}

# Prints the last $2 labels of the array named $1, dot-joined. Bash namerefs
# let this take the labels array by name instead of needing a global.
_suffix_from_end() {
    local -n _sfe_arr="$1"
    local count="$2"
    local n=${#_sfe_arr[@]}
    local start=$((n - count))
    ((start < 0)) && start=0
    local IFS=.
    printf '%s' "${_sfe_arr[*]:$start}"
}

# Computes the registrable ("root") domain for a normalized hostname using
# the standard public-suffix matching algorithm: try the longest possible
# suffix first (the whole domain), then progressively shorter suffixes,
# stopping at the first one that matches an exception, plain, or wildcard
# rule. An exception match always wins over a wildcard at the same
# position (see the "!city.kawasaki.jp" vs "*.kawasaki.jp" case in the real
# list — without the exception, "city.kawasaki.jp" would otherwise be
# swallowed as part of the public suffix instead of being a registrable
# name itself). Falls back to the implicit "*" rule (public suffix = the
# single trailing label) when nothing in the list matches at all, per spec.
# Returns non-zero if the domain has no label left over once the suffix is
# removed — i.e., the input is already at or above the suffix boundary,
# so there's no sensible root domain to generate a cert for.
_registrable_domain() {
    local domain="$1"
    local -a rd_labels
    IFS='.' read -r -a rd_labels <<< "$domain"
    local n=${#rd_labels[@]}
    local k suffix wildcard_base best_k=0

    for ((k = n; k >= 1; k--)); do
        suffix="$(_suffix_from_end rd_labels "$k")"
        if [[ -n "${_PSL_EXCEPTIONS[$suffix]+set}" ]]; then
            best_k=$((k - 1))
            break
        fi
        if [[ -n "${_PSL_RULES[$suffix]+set}" ]]; then
            best_k=$k
            break
        fi
        if ((k >= 2)); then
            wildcard_base="$(_suffix_from_end rd_labels "$((k - 1))")"
            if [[ -n "${_PSL_WILDCARDS[$wildcard_base]+set}" ]]; then
                best_k=$k
                break
            fi
        fi
    done
    ((best_k == 0)) && best_k=1

    local root_k=$((best_k + 1))
    ((root_k > n)) && return 1
    _suffix_from_end rd_labels "$root_k"
}

_load_public_suffix_list

# Reads $DOMAINS_FILE (cdn-domains.txt) once, derives each line's
# registrable root domain, and populates two globals shared by every
# generation loop below: _UNIQUE_DOMAINS (first-seen order of unique
# derived roots) and _DOMAIN_IS_ROOT (root -> 1, always — every derived
# root needs both bare and wildcard cert/map coverage, since the DNS side
# already treats every cdn-domains.txt entry as covering its whole
# subdomain tree). Multiple DNS entries commonly derive the same root (e.g.
# drivers.amd.com and pat.downloads.amd.com both derive amd.com), so this
# also deduplicates by root — without that, each map-generation loop below
# would emit the identical map key more than once, and nginx's map
# directive rejects duplicate keys at "nginx -t" time, leaving the SSL
# proxy unable to start.
declare -a _UNIQUE_DOMAINS=()
declare -A _DOMAIN_IS_ROOT=()
# Set to 1 by _collect_domain_rows when any cdn-domains.txt row is skipped
# (invalid entry, or a root domain that could not be derived). A config
# generated from a domain list with skipped rows can still pass `nginx -t`
# (skipping a row is not a syntax error) -- but it is a *degraded* config
# missing coverage cdn-domains.txt actually lists, and #415's known-good
# snapshot mechanism must not treat it as a new known-good baseline (that
# would prune away a possibly-complete prior snapshot in favor of this
# incomplete one). See _proxy_validate_snapshot_or_rollback below.
_DOMAIN_ROWS_SKIPPED=0
_collect_domain_rows() {
    _UNIQUE_DOMAINS=()
    _DOMAIN_IS_ROOT=()
    _DOMAIN_ROWS_SKIPPED=0
    local raw_domain domain root

    while IFS= read -r raw_domain || [ -n "$raw_domain" ]; do
        domain="${raw_domain#"${raw_domain%%[![:space:]]*}"}"
        domain="${domain%"${domain##*[![:space:]]}"}"
        [[ -z "$domain" || "$domain" == \#* ]] && continue

        # Validate and normalize domain before using it anywhere
        if ! _is_valid_domain "$domain"; then
            echo "[lancache] WARNING: skipping invalid domain entry: $domain" >&2
            _DOMAIN_ROWS_SKIPPED=1
            continue
        fi
        domain="$(_normalize_domain "$domain")"
        [[ -z "$domain" ]] && continue

        if ! root="$(_registrable_domain "$domain")" || [[ -z "$root" ]]; then
            echo "[lancache] WARNING: could not derive a root domain for: $domain" >&2
            _DOMAIN_ROWS_SKIPPED=1
            continue
        fi

        if [[ -z "${_DOMAIN_IS_ROOT[$root]+set}" ]]; then
            _UNIQUE_DOMAINS+=("$root")
        fi
        _DOMAIN_IS_ROOT["$root"]=1
    done < "$DOMAINS_FILE"
}

_collect_domain_rows

for resolver in ${NGINX_UPSTREAM_RESOLVER}; do
    resolver="$(_normalize_resolver_token "$resolver")"
    if [ "$resolver" = "$IP_STANDARD" ] || { [ -n "$IP_SSL" ] && [ "$resolver" = "$IP_SSL" ]; }; then
        echo "[lancache] ERROR: NGINX_UPSTREAM_RESOLVER must not point to a LanCache DNS/proxy IP ($resolver)." >&2
        echo "[lancache] Use a real upstream resolver such as 8.8.8.8, 8.8.4.4, 1.1.1.1, or your upstream/corporate DNS." >&2
        exit 1
    fi
done

case "$PROXY_SECURITY_MODE" in
    lazy|strict) ;;
    *)
        echo "[lancache] ERROR: PROXY_SECURITY_MODE must be lazy or strict (got: $PROXY_SECURITY_MODE)." >&2
        exit 1
        ;;
esac

export NGINX_UPSTREAM_RESOLVER PROXY_SECURITY_MODE PROXY_ALLOWED_CLIENT_CIDRS
# ────────────────────────────────────────────────────────────────────────────
# 1. SSL mode: Generate CA and certs if needed
# ────────────────────────────────────────────────────────────────────────────
if [ "${SSL_ENABLED}" = "1" ]; then
    if [ -z "${IP_SSL}" ]; then
        echo "[lancache] ERROR: SSL_ENABLED=1 but IP_SSL is not set" >&2
        exit 1
    fi

    if [ ! -f "$CA_DIR/ca.crt" ] || [ ! -f "$CA_DIR/ca.key" ]; then
        echo "[lancache] Generating CA certificate (first-time setup)..."
        mkdir -p "$CA_DIR"
        if ! openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
            -subj "/CN=LanCache-NG CA/O=LanCache-NG/C=DE" \
            -keyout "$CA_DIR/ca.key" \
            -out    "$CA_DIR/ca.crt"; then
            echo "[lancache] ERROR: Failed to generate CA certificate" >&2
            exit 1
        fi
        echo ""
        echo "╔══════════════════════════════════════════════════════════════════╗"
        echo "║              ACTION REQUIRED — READ BEFORE CONTINUING            ║"
        echo "╠══════════════════════════════════════════════════════════════════╣"
        echo "║                                                                  ║"
        echo "║  A CA certificate has been generated and saved to:               ║"
        echo "║    certs/ca.crt  (in your lancache-ng directory)                 ║"
        echo "║                                                                  ║"
        echo "║  Every client that uses the SSL mode MUST install this           ║"
        echo "║  certificate once. Without it, browsers will show a             ║"
        echo "║  security warning and downloads will fail.                       ║"
        echo "║                                                                  ║"
        echo "║  Instructions per OS: docs/install-ca-cert.md                   ║"
        echo "║                                                                  ║"
        echo "║  This message only appears once. The cert will be reused         ║"
        echo "║  on every subsequent start automatically.                        ║"
        echo "╚══════════════════════════════════════════════════════════════════╝"
        echo ""
    fi

    worker_user=$(awk '$1 == "user" {gsub(/;/, "", $2); print $2; exit}' /etc/nginx/nginx.conf.template)
    worker_user="${worker_user:-nginx}"

    mkdir -p "$CERT_DIR"
    chgrp "$worker_user" "$CERT_DIR"
    chmod 2750 "$CERT_DIR"

    # Persist the serial counter in the CA volume so it survives container restarts (#71).
    # Initialized with a nanosecond timestamp on first use to avoid colliding with any
    # serials that were issued under the old "echo 01" scheme.
    SERIAL_FILE="$CA_DIR/ca.srl"
    if [ ! -f "$SERIAL_FILE" ]; then
        printf '%016x\n' "$(date +%s%N)" > "$SERIAL_FILE"
    fi

    _sign_cert() {
        local cn="$1" key="$2" crt="$3" ext="${4:-}"
        if ! openssl req -new -newkey rsa:2048 -nodes -subj "/CN=${cn}" \
            -keyout "$key" -out /tmp/lancache-cert.csr; then
            rm -f /tmp/lancache-cert.csr
            echo "[lancache] ERROR: Failed to generate certificate request for ${cn}" >&2
            return 1
        fi
        if [ -n "$ext" ]; then
            if ! openssl x509 -req -days 3650 \
                -in /tmp/lancache-cert.csr \
                -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAserial "$SERIAL_FILE" \
                -extfile <(printf "%s" "$ext") \
                -out "$crt"; then
                rm -f /tmp/lancache-cert.csr
                echo "[lancache] ERROR: Failed to sign certificate for ${cn}" >&2
                return 1
            fi
        else
            if ! openssl x509 -req -days 3650 \
                -in /tmp/lancache-cert.csr \
                -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAserial "$SERIAL_FILE" \
                -out "$crt"; then
                rm -f /tmp/lancache-cert.csr
                echo "[lancache] ERROR: Failed to sign certificate for ${cn}" >&2
                return 1
            fi
        fi
        rm -f /tmp/lancache-cert.csr
    }

    # Returns 0 (true = needs regen) if the default cert:
    #   - is missing (#72)
    #   - has no matching key (partial generation state)
    #   - has no SAN at all (CN-only cert from old deployments, #72)
    #   - has an IP SAN that does not match the current IP_SSL (operator changed IP)
    _default_cert_needs_regen() {
        if [ ! -f "$CERT_DIR/default.crt" ] || [ ! -f "$CERT_DIR/default.key" ]; then
            return 0
        fi
        local san
        san=$(openssl x509 -noout -ext subjectAltName -in "$CERT_DIR/default.crt" 2>/dev/null)
        echo "$san" | grep -q "DNS:" || return 0
        if [ -n "${IP_SSL}" ]; then
            echo "$san" | grep -q "IP Address:${IP_SSL}" || return 0
        fi
        return 1
    }

    if _default_cert_needs_regen; then
        # Generate or regenerate the fallback cert with a proper SAN (#72).
        # Include IP_SSL in the SAN so clients connecting to that IP also pass validation.
        _default_san="DNS:lancache-default"
        [ -n "${IP_SSL}" ] && _default_san="${_default_san},IP:${IP_SSL}"
        if ! _sign_cert "lancache-default" "$CERT_DIR/default.key" "$CERT_DIR/default.crt" \
            "subjectAltName=${_default_san}"; then
            echo "[lancache] ERROR: Failed to generate default certificate" >&2
            exit 1
        fi
    fi
    for domain in "${_UNIQUE_DOMAINS[@]}"; do
        [ -f "$CERT_DIR/${domain}.crt" ] && [ -f "$CERT_DIR/${domain}.key" ] && continue

        echo "[lancache] Generating cert for $domain..."
        if ! _sign_cert "$domain" \
            "$CERT_DIR/${domain}.key" \
            "$CERT_DIR/${domain}.crt" \
            "subjectAltName=DNS:${domain},DNS:*.${domain}"; then
            echo "[lancache] ERROR: Failed to generate certificate for domain $domain" >&2
            exit 1
        fi
    done

    # Keep new keys in the nginx group and make existing/generated keys readable
    # by nginx workers during TLS handshakes.
    if ! chgrp "$worker_user" "$CERT_DIR" || ! find "$CERT_DIR" -type f -name '*.key' -exec chgrp "$worker_user" {} + -exec chmod 0640 {} +; then
        echo "[lancache] ERROR: Failed to set certificate key permissions" >&2
        exit 1
    fi
    find "$CERT_DIR" -type f -name '*.crt' -exec chmod 0644 {} +
fi

# ────────────────────────────────────────────────────────────────────────────
# 2. Generate request-time access policy maps
#    lazy  = keep historical behavior and allow any requested upstream host
#    strict = only proxy hosts derived from cdn-domains.txt (see above)
# ────────────────────────────────────────────────────────────────────────────
{
    echo "# Auto-generated by entrypoint — do not edit"
    echo "map \$ssl_server_name \$ssl_cert_name {"
    echo "    hostnames;"
    for domain in "${_UNIQUE_DOMAINS[@]}"; do
        printf "    %-45s %s;\n" "*.${domain}"  "$domain"
        if [ "${_DOMAIN_IS_ROOT[$domain]}" -eq 1 ]; then
            printf "    %-45s %s;\n" "$domain" "$domain"
        fi
    done
    echo "    default default;"
    echo "}"

    echo ""
    echo "map \$host \$cdn_host_allowed {"
    echo "    hostnames;"
    if [ "$PROXY_SECURITY_MODE" = "strict" ]; then
        echo "    default 0;"
        for domain in "${_UNIQUE_DOMAINS[@]}"; do
            printf "    %-45s 1;\n" "*.${domain}"
            if [ "${_DOMAIN_IS_ROOT[$domain]}" -eq 1 ]; then
                printf "    %-45s 1;\n" "$domain"
            fi
        done
    else
        echo "    default 1;"
    fi
    echo "}"

    echo ""
    echo "geo \$lancache_client_allowed {"
    if [ -n "$PROXY_ALLOWED_CLIENT_CIDRS" ]; then
        echo "    default 0;"
        for cidr in $PROXY_ALLOWED_CLIENT_CIDRS; do
            printf "    %-45s 1;\n" "$cidr"
        done
    else
        echo "    default 1;"
    fi
    echo "}"
} > "$SSL_MAP_FILE"

mkdir -p /etc/nginx/stream.d

{
    echo "# Auto-generated by entrypoint — do not edit"
    echo "map \$ssl_preread_server_name \$stream_backend {"
    echo "    hostnames;"
    if [ "$PROXY_SECURITY_MODE" = "lazy" ]; then
        echo "    default \$ssl_preread_server_name:443;"
    else
        echo "    default 127.0.0.1:9;"
        for domain in "${_UNIQUE_DOMAINS[@]}"; do
            printf "    %-45s %s:443;\n" "*.${domain}" "$domain"
            if [ "${_DOMAIN_IS_ROOT[$domain]}" -eq 1 ]; then
                printf "    %-45s %s:443;\n" "$domain" "$domain"
            fi
        done
    fi
    echo "}"
} > "$STREAM_TARGET_FILE"

# ────────────────────────────────────────────────────────────────────────────
# 3. Remove https.conf when SSL mode is disabled
#    (Docker routes IP_SSL:443→container:443 and IP_STANDARD:443→container:8443,
#    so https.conf can safely listen on 0.0.0.0:443 — only SSL clients reach it)
# ────────────────────────────────────────────────────────────────────────────
if [ "${SSL_ENABLED}" = "0" ]; then
    rm -f /etc/nginx/conf.d/https.conf
fi

# ────────────────────────────────────────────────────────────────────────────
# 4. Render nginx.conf and proxy-params from templates
# ────────────────────────────────────────────────────────────────────────────
envsubst '${CACHE_MEM_MB} ${CACHE_MAX_SIZE} ${CACHE_INACTIVE} ${NGINX_UPSTREAM_RESOLVER}' \
    < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

envsubst '${CACHE_SLICE_SIZE} ${CACHE_VALID_HIT} ${CACHE_VALID_ANY}' \
    < /etc/nginx/proxy-params.conf.template > /etc/nginx/proxy-params.conf

# ────────────────────────────────────────────────────────────────────────────
# 5. Validate config, snapshot known-good config, and start nginx (#415)
#
# Only the files this entrypoint regenerates from templates/env/cdn-domains
# on every boot are snapshotted; static conf.d assets baked into the image
# are not runtime-managed and are covered by the image build itself.
# ────────────────────────────────────────────────────────────────────────────

# _proxy_validate_snapshot_or_rollback <file...>
# Factored into its own function (rather than inline top-level script code)
# so tests/bats/proxy_known_good_snapshot.bats can drive the full nginx
# adapter flow against a stub `nginx` binary without needing to run the rest
# of this entrypoint (CA generation, cdn-domains.txt parsing, iptables, ...).
_proxy_validate_snapshot_or_rollback() {
    local -a candidate_files=("$@")

    echo "[lancache] Validating nginx config..."
    if nginx -t; then
        if [ "$_DOMAIN_ROWS_SKIPPED" -eq 1 ]; then
            # nginx -t passing only proves the generated config is
            # syntactically valid, not that it covers every domain
            # cdn-domains.txt actually lists. Snapshotting this degraded
            # config as "known-good" would prune away a possibly-complete
            # prior snapshot the moment a single malformed row appears --
            # skip the snapshot (the config still runs; only the rollback
            # baseline is left untouched) until cdn-domains.txt is fixed.
            echo "[lancache] WARNING: one or more cdn-domains.txt rows were skipped; NOT snapshotting this config as known-good (existing snapshot, if any, is preserved). Fix cdn-domains.txt to resume snapshotting." >&2
        elif ! kgs_snapshot_create "$PROXY_CONFIG_SNAPSHOT_DIR" "$KEEP_KNOWN_GOOD_CONFIGS" "proxy" "${candidate_files[@]}"; then
            # The config is valid and nginx still starts from it -- but
            # without a recorded snapshot, a future invalid config has
            # nothing to roll back to. Surface that loudly rather than
            # silently degrading rollback protection.
            echo "[lancache] WARNING: failed to record this valid config as a known-good snapshot (see FATAL line above); rollback protection is degraded until this succeeds." >&2
        fi
        return 0
    fi

    echo "[lancache] ERROR: generated nginx config failed validation (nginx -t)." >&2
    echo "[lancache] ERROR: attempting rollback to the newest known-good snapshot instead of starting with an invalid config." >&2
    local selected_id
    if selected_id="$(kgs_snapshot_apply "$PROXY_CONFIG_SNAPSHOT_DIR" "proxy" "nginx -t" "${candidate_files[@]}")"; then
        echo "[lancache] WARNING: nginx is starting from known-good snapshot ${selected_id}, NOT the newly generated config." >&2
        echo "[lancache] WARNING: fix the underlying config source (cdn-domains.txt, templates, env vars) and restart to pick up the intended change." >&2
        return 0
    fi

    echo "[lancache] FATAL: no known-good nginx config snapshot is available; refusing to start with an invalid config." >&2
    return 1
}

PROXY_CANDIDATE_FILES=(/etc/nginx/nginx.conf /etc/nginx/proxy-params.conf "$SSL_MAP_FILE" "$STREAM_TARGET_FILE")
_proxy_validate_snapshot_or_rollback "${PROXY_CANDIDATE_FILES[@]}" || exit 1

echo "[lancache] Starting nginx (IP_STANDARD=${IP_STANDARD}, SSL_ENABLED=${SSL_ENABLED})..."
exec nginx -g "daemon off;"
