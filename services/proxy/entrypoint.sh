#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
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
LOG_READER_GID=10001

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
# Unlike the other CACHE_* variables below (CACHE_MEM_MB, CACHE_MAX_SIZE,
# CACHE_INACTIVE), which have always been mandatory (present since this
# project's first commit setting them), CACHE_MIN_FREE is new (bug-hunt #849
# item 11) -- an existing deployment that pulls an updated proxy image
# without also re-running `setup.sh update` (or hand-editing its .env) would
# otherwise have no value at all for it. Confirmed live: envsubst then
# renders nginx.conf's `min_free=${CACHE_MIN_FREE}` as `min_free=` (empty),
# which real nginx rejects outright ("invalid min_free value") -- a fallback
# here is what keeps that upgrade path from becoming a hard proxy startup
# failure. 1g matches the example value bug-hunt #849/#1068's own
# field-testing finding suggested when it first raised min_free.
CACHE_MIN_FREE="${CACHE_MIN_FREE:-1g}"
KEEP_KNOWN_GOOD_CONFIGS="${KEEP_KNOWN_GOOD_CONFIGS:-3}"
PROXY_CONFIG_SNAPSHOT_DIR="${PROXY_CONFIG_SNAPSHOT_DIR:-/var/lib/lancache-proxy/config-snapshots}"

# What: marks nginx's log directory setgid to gid 10001 and repairs existing files.
# Why: every reopen/rotation must keep proxy logs readable to the non-root syslog collector, not just the first boot.
# From: Issue #1427
prepare_proxy_log_dir_for_syslog() {
    mkdir -p /var/log/nginx
    chown nginx:"$LOG_READER_GID" /var/log/nginx
    chmod 2750 /var/log/nginx
    find /var/log/nginx -maxdepth 1 -type f -exec chown nginx:"$LOG_READER_GID" {} + -exec chmod g+r {} +
}

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
# Domain validation library (scripts/lib/domain-validation.sh)
#
# Mirrors the label-strict rules from Admin UI (domains.rs) to prevent
# invalid domains from being used in nginx maps, cert generation, and stream
# targets. This block is a byte-identical copy of
# scripts/lib/domain-validation.sh's function definitions (verified by
# tests/bats/domain_validation_sync.bats) rather than a sourced file, because
# this Dockerfile builds from services/proxy/ alone with no shared-file
# build context wired up for it -- see that file for the full rule
# documentation and rationale.
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

    # Must be <= 253 chars total (RFC 1035 domain name length limit)
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
# registrable root domain, and populates the globals shared by every
# generation loop below: _UNIQUE_DOMAINS (first-seen order of unique
# derived roots), _DOMAIN_IS_ROOT (root -> 1, always — every derived root
# needs both bare and wildcard cert/map coverage), _EXTRA_WILDCARD_BASES
# (leading-dot entries needing their own deeper wildcard cert), and
# _EXTRA_EXACT_HOSTS (bare entries needing their own deeper exact-match
# cert). Both "extra" sets exist for the same underlying reason: an X.509
# wildcard SAN only ever covers ONE label (RFC 6125) -- a "*.ea.com" cert
# (generated from the root alone) validates "cdn.ea.com" but never
# "x.cdn.ea.com" (two labels below the root). This affects a cdn-domains.txt
# entry regardless of whether it's written as a leading-dot wildcard or a
# bare exact host:
#   - ".cdn.ea.com" (wildcard-only) spoofs hosts of the form "*.cdn.ea.com"
#     -- always ONE label deeper than the entry's own text -- so it needs
#     its own "*.cdn.ea.com" cert whenever the entry text differs from the
#     root AT ALL, even by exactly one label (i.e. "cdn.ea.com" != root
#     "ea.com" already qualifies -- there is no "more than one label"
#     threshold for this case, unlike the bare-entry case below).
#   - "tlu.dl.delivery.mp.microsoft.com" (bare) spoofs exactly that one
#     literal host -- no extra "one label deeper" step -- so it needs its
#     own exact-match cert whenever the HOST ITSELF is more than one label
#     past the root (stripping exactly one leading label from it does not
#     land back on the root, meaning "*.<root>" cannot possibly cover it
#     either). A bare entry that's exactly one label past the root, like
#     "cdn.ea.com" itself, needs nothing extra: "*.ea.com" already covers
#     it.
# Without the matching dedicated cert, SSL-mode clients hitting these hosts
# get a certificate that does not validate for their SNI and the connection
# fails, even though DNS resolution and standard-mode (SNI-passthrough, no
# cert involved) both work fine.
#
# FORMER KNOWN LIMITATION (issue #1322), narrowed by #1276's stream-level
# SNI depth-dispatch fix (see "2a." below): this only ever adds ONE extra
# label of wildcard depth per leading-dot entry. A leading-dot entry's real
# DNS-side match scope is arbitrary depth (services/dns/entrypoint.sh's RPZ
# generation spoofs every subdomain of it, at any depth), but no static,
# pre-generated X.509 cert scheme can match that: a client two or more
# labels below the entry (e.g. "a.b.cdn.ea.com" under a ".cdn.ea.com" entry)
# still cannot get a cert that validates for it. What changed: such a
# client no longer gets served a mismatched cert and fails outright --
# "2a." below now routes it to a passthrough relay instead (same
# uncached, unencrypted-to-us blind-forward mechanism standard mode
# already uses), so the connection succeeds instead of failing TLS
# hostname verification. What did NOT change: that traffic still isn't
# cached or MITM'd at that depth -- only dynamic per-SNI certificate
# issuance at handshake time (a materially different architecture than
# this pre-generated-cert design, see AGENTS.md's AG-KD-005 -- corrected
# 2026-08-05, issue #1391 doc-sweep audit: this used to cite CLAUDE.md's
# "Pre-generated wildcard certs" decision, which moved to AGENTS.md on
# 2026-07-31) would close that residual gap, and that remains a
# separate, not-yet-scoped architecture question. The operator mitigation
# (add the specific deeper level as its own leading-dot entry, e.g.
# ".b.cdn.ea.com", to get real MITM/caching for that one additional level)
# still works exactly as before and still does not generalize to
# unbounded depth. STATUS: connectivity gap closed 2026-08-05 (#1276);
# caching-at-arbitrary-depth remains open, no longer tracked under #1322
# (closed as consolidated, see #1276's own comment thread).
#
# Multiple DNS entries commonly derive the
# same root (e.g. drivers.amd.com and pat.downloads.amd.com both derive
# amd.com), so this also deduplicates by root — without that, each
# map-generation loop below would emit the identical map key more than
# once, and nginx's map directive rejects duplicate keys at "nginx -t"
# time, leaving the SSL proxy unable to start.
declare -a _UNIQUE_DOMAINS=()
declare -A _DOMAIN_IS_ROOT=()
declare -a _EXTRA_WILDCARD_BASES=()
declare -A _SEEN_EXTRA_WILDCARD_BASE=()
declare -a _EXTRA_EXACT_HOSTS=()
declare -A _SEEN_EXTRA_EXACT_HOST=()
# root -> 1 whenever that root is ITSELF a leading-dot cdn-domains.txt entry
# (e.g. ".steamcontent.com", where domain == root already). Unlike a deeper
# leading-dot entry (_EXTRA_WILDCARD_BASES), this needs no extra cert -- the
# root's own "*.${root}" wildcard cert already covers one label below it --
# but it has the exact same residual issue #1322 gap one level further down
# (services/dns/entrypoint.sh's RPZ generation spoofs arbitrary depth below
# a leading-dot entry, not just one label), which only the SSL-mode stream
# dispatch map (see "2a." below) needs to know about. Kept separate from
# _EXTRA_WILDCARD_BASES rather than folded into it: that array specifically
# means "needs its own dedicated cert," which a root-level entry does not.
declare -A _ROOT_HAS_WILDCARD_ENTRY=()
# Set to 1 by _collect_domain_rows when any cdn-domains.txt row is skipped
# (invalid entry, or a root domain that could not be derived). A config
# generated from a domain list with skipped rows can still pass `nginx -t`
# (skipping a row is not a syntax error) -- but it is a *degraded* config
# missing coverage cdn-domains.txt actually lists, and #415's known-good
# snapshot mechanism must not treat it as a new known-good baseline (that
# would prune away a possibly-complete prior snapshot in favor of this
# incomplete one). See _proxy_validate_snapshot_or_rollback below.
_DOMAIN_ROWS_SKIPPED=0

# _proxy_is_one_label_past <domain> <root>
# True (0) if stripping exactly ONE leading label from <domain> lands
# exactly on <root> -- i.e. <domain> is precisely the depth "*.<root>"
# already covers. False (1) if <domain> IS <root> itself (bare root, a
# different case the callers handle separately) or if <domain> is two or
# more labels past <root> (needs its own dedicated cert).
_proxy_is_one_label_past() {
    local domain="$1" root="$2"
    [ "$domain" = "$root" ] && return 1
    local stripped="${domain#*.}"
    [ "$stripped" = "$root" ]
}

_collect_domain_rows() {
    _UNIQUE_DOMAINS=()
    _DOMAIN_IS_ROOT=()
    _EXTRA_WILDCARD_BASES=()
    _SEEN_EXTRA_WILDCARD_BASE=()
    _EXTRA_EXACT_HOSTS=()
    _SEEN_EXTRA_EXACT_HOST=()
    _ROOT_HAS_WILDCARD_ENTRY=()
    _DOMAIN_ROWS_SKIPPED=0
    local raw_domain domain root is_wildcard_only

    while IFS= read -r raw_domain || [ -n "$raw_domain" ]; do
        domain="${raw_domain#"${raw_domain%%[![:space:]]*}"}"
        domain="${domain%"${domain##*[![:space:]]}"}"
        [[ -z "$domain" || "$domain" == \#* ]] && continue

        # A leading "!" marks an entry the Admin UI's per-domain toggle has
        # deliberately disabled (#1073) -- skip it silently (no
        # _DOMAIN_ROWS_SKIPPED, no WARNING): this is an intentional operator
        # choice, not a malformed or degraded cdn-domains.txt row, so it must
        # not block known-good config snapshotting the way a genuinely bad
        # row does. Mirrors services/dns/entrypoint.sh's RPZ generation
        # handling of the same marker on the same file.
        [[ "$domain" == !* ]] && continue

        # Captured before _is_valid_domain/_normalize_domain, both of which
        # strip a leading dot -- same "leading dot = wildcard-only" flag
        # services/dns/entrypoint.sh's RPZ generation derives from the same
        # raw row on the same file.
        is_wildcard_only=0
        [[ "$domain" == .* ]] && is_wildcard_only=1

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

        if [ "$is_wildcard_only" -eq 1 ]; then
            # A wildcard-only entry's actual matched hosts are always one
            # label deeper than the entry text itself -- so it needs its
            # own cert whenever the entry text is already past the root at
            # all (not just past by more than one label).
            if [ "$domain" != "$root" ] \
                && [[ -z "${_SEEN_EXTRA_WILDCARD_BASE[$domain]+set}" ]]; then
                _EXTRA_WILDCARD_BASES+=("$domain")
                _SEEN_EXTRA_WILDCARD_BASE["$domain"]=1
            fi
            # A root-level leading-dot entry (domain == root, e.g.
            # ".steamcontent.com") needs no extra cert -- the root's own
            # cert already covers this -- but does need to be flagged for
            # the SSL-mode dispatch map below (see _ROOT_HAS_WILDCARD_ENTRY's
            # own declaration comment).
            #
            # Deliberately "if ...; then ...; fi", NOT the shorter
            # "[ cond ] && assignment" idiom used elsewhere in this function:
            # this is the LAST statement in this branch of the loop body, so
            # under `set -e`, a bare "&&" whose left side is false (domain
            # != root) would make this iteration's -- and therefore this
            # whole while loop's, and therefore _collect_domain_rows'
            # itself -- exit status non-zero, silently killing the entire
            # entrypoint at its own bare top-level "_collect_domain_rows"
            # call site with zero output. An explicit "if" with no "else"
            # always returns 0 when its condition is false, so it can't leak
            # a false exit status out of the loop this way.
            if [ "$domain" = "$root" ]; then
                _ROOT_HAS_WILDCARD_ENTRY["$root"]=1
            fi
        else
            # A bare entry's matched host IS the entry text itself -- needs
            # its own cert only once it's more than one label past the
            # root (exactly one label past is already covered by the
            # root's own "*.<root>" wildcard).
            if ! _proxy_is_one_label_past "$domain" "$root" \
                && [ "$domain" != "$root" ] \
                && [[ -z "${_SEEN_EXTRA_EXACT_HOST[$domain]+set}" ]]; then
                _EXTRA_EXACT_HOSTS+=("$domain")
                _SEEN_EXTRA_EXACT_HOST["$domain"]=1
            fi
        fi
    done < "$DOMAINS_FILE"
}

_collect_domain_rows

# set -f (noglob) around this loop: NGINX_UPSTREAM_RESOLVER is intentionally
# expanded unquoted below so its whitespace-separated tokens split into
# multiple resolver entries, but a bracketed IPv6 literal such as
# [2001:4860:4860::8888] is also a valid bash bracket-glob (matches any
# single character in the set). Without noglob, bash would silently replace
# that token with a matching filename from the cwd if one ever existed,
# instead of comparing the literal resolver value.
set -f
for resolver in ${NGINX_UPSTREAM_RESOLVER}; do
    resolver="$(_normalize_resolver_token "$resolver")"
    if [ "$resolver" = "$IP_STANDARD" ] || { [ -n "$IP_SSL" ] && [ "$resolver" = "$IP_SSL" ]; }; then
        echo "[lancache] ERROR: NGINX_UPSTREAM_RESOLVER must not point to a LanCache DNS/proxy IP ($resolver)." >&2
        echo "[lancache] Use a real upstream resolver such as 8.8.8.8, 8.8.4.4, 1.1.1.1, or your upstream/corporate DNS." >&2
        exit 1
    fi
done
set +f

case "$PROXY_SECURITY_MODE" in
    lazy|strict) ;;
    *)
        echo "[lancache] ERROR: PROXY_SECURITY_MODE must be lazy or strict (got: $PROXY_SECURITY_MODE)." >&2
        exit 1
        ;;
esac

export NGINX_UPSTREAM_RESOLVER PROXY_SECURITY_MODE PROXY_ALLOWED_CLIENT_CIDRS CACHE_MIN_FREE

# Deterministic, length-bounded cert/key filename for a domain that may
# be up to 253 bytes long (_is_valid_domain's own limit) -- well past
# Linux's 255-byte NAME_MAX once combined with any ".crt"/".key" suffix,
# if the raw hostname were used as the filename directly. $2 (a short
# namespace tag, e.g. "wildcard"/"exact") is mixed into the HASH INPUT
# (see the sha256sum call below), not appended as filename text -- the
# output is always a plain 32-character hex string plus the ordinary
# ".crt"/".key" suffix, with no extra namespace marker in the filename
# itself. Hashing the namespace-prefixed input is what keeps a bare and a
# leading-dot cdn-domains.txt entry for the same base resolving to two
# DIFFERENT names, matching this file's own existing requirement that
# those need two distinct certs. The real hostname is never lost -- it
# lives in each cert's SAN (see _sign_cert below) and in the nginx maps
# that select a cert by hostname, neither of which has an equivalent
# filesystem constraint.
#
# Defined here, unconditionally, rather than inside the SSL_ENABLED
# block below: the map-generation block further down (see "2. Generate
# request-time access policy maps") calls this for every
# _EXTRA_WILDCARD_BASES/_EXTRA_EXACT_HOSTS entry regardless of
# SSL_ENABLED, since those maps exist even when SSL mode is off. Defining
# it only inside the SSL_ENABLED=1 branch left it undefined ("command not
# found") whenever SSL_ENABLED=0 and cdn-domains.txt had any deep entry,
# breaking the generated map file and failing nginx -t on startup.
_bounded_cert_name() {
    printf '%s' "${2}:${1}" | sha256sum | cut -c1-32
}

# _regex_escape_domain <domain>
# Escapes literal dots for safe use inside an anchored nginx stream map regex
# key (see "2a." below). _is_valid_domain_label restricts every label to
# [a-z0-9-], so "." is the only regex-metacharacter a validated domain can
# contain. Uses an intermediate variable for the replacement text rather
# than "${d//./\\.}" directly -- confirmed live in bash that the inline form
# silently drops the backslash in this project's shell (produces an
# unescaped "." that would still parse as a valid regex, just matching any
# character instead of a literal dot -- a real, silent correctness bug, not
# a syntax error, so it would not have failed loudly).
_regex_escape_domain() {
    local d="$1"
    local esc_dot='\.'
    printf '%s' "${d//./$esc_dot}"
}

# ────────────────────────────────────────────────────────────────────────────
# 1. SSL mode: Generate CA and certs if needed
# ────────────────────────────────────────────────────────────────────────────
if [ "${SSL_ENABLED}" = "1" ]; then
    if [ -z "${IP_SSL}" ]; then
        echo "[lancache] ERROR: SSL_ENABLED=1 but IP_SSL is not set" >&2
        exit 1
    fi

    # _ensure_ca_cert: generates the CA on first boot only (idempotent --
    # does nothing once $CA_DIR/ca.crt and ca.key both already exist).
    # Factored into its own function (rather than inline top-level script
    # code) specifically so tests/bats/proxy_cert_dir_permissions.bats can
    # drive the real chmod hardening below through a real `openssl req`
    # call, without needing to run the rest of this entrypoint: ca.key's
    # and CERT_DIR's file modes are security-relevant
    # and need their own regression guard against a future accidental
    # deletion, independent of any other entrypoint behavior.
    _ensure_ca_cert() {
        if [ -f "$CA_DIR/ca.crt" ] && [ -f "$CA_DIR/ca.key" ]; then
            return 0
        fi
        echo "[lancache] Generating CA certificate (first-time setup)..."
        mkdir -p "$CA_DIR"
        if ! openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
            -subj "/CN=LanCache-NG CA/O=LanCache-NG/C=DE" \
            -keyout "$CA_DIR/ca.key" \
            -out    "$CA_DIR/ca.crt"; then
            echo "[lancache] ERROR: Failed to generate CA certificate" >&2
            exit 1
        fi
        # openssl -keyout follows the umask (0022 by default), leaving ca.key
        # world-readable (644). Harden it to match certs/generate-ca.sh's own
        # standalone CA generation, which already does this.
        chmod 600 "$CA_DIR/ca.key"
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
    }
    _ensure_ca_cert

    worker_user=$(awk '$1 == "user" {gsub(/;/, "", $2); print $2; exit}' /etc/nginx/nginx.conf.template)
    worker_user="${worker_user:-nginx}"

    # _harden_cert_dir <worker_user>: same factoring reason as _ensure_ca_cert
    # above -- lets the test drive the real chmod/chgrp calls directly.
    _harden_cert_dir() {
        local dir_worker_user="$1"
        mkdir -p "$CERT_DIR"
        chgrp "$dir_worker_user" "$CERT_DIR"
        chmod 2750 "$CERT_DIR"
    }
    _harden_cert_dir "$worker_user"

    # CERT_DIR is now a named, persistent volume, so a leaf cert signed by a
    # since-replaced CA is no longer flushed by the anonymous-volume reset
    # that a container-removing recreate used to cause incidentally. Without
    # this check, the per-domain loops below (which skip any cert/key pair
    # that already exists) would keep serving certs signed by a CA the
    # operator already told clients to stop trusting, per the CA-rotation
    # procedure docs/backup-restore.md documents. Track which CA signed the
    # certs currently in CERT_DIR and purge every leaf on a mismatch so
    # those loops regenerate them all against the current CA.
    _purge_stale_leaf_certs_on_ca_change() {
        local fingerprint_file="$CERT_DIR/.ca-fingerprint" current_fingerprint
        current_fingerprint="$(openssl x509 -noout -fingerprint -sha256 -in "$CA_DIR/ca.crt" 2>/dev/null)"
        if [ "$(cat "$fingerprint_file" 2>/dev/null)" != "$current_fingerprint" ]; then
            find "$CERT_DIR" -maxdepth 1 -type f \( -name '*.crt' -o -name '*.key' \) -delete
            printf '%s\n' "$current_fingerprint" > "$fingerprint_file"
        fi
    }
    _purge_stale_leaf_certs_on_ca_change

    # Persist the serial counter in the CA volume so it survives container restarts (#71).
    # Initialized with a nanosecond timestamp on first use to avoid colliding with any
    # serials that were issued under the old "echo 01" scheme.
    SERIAL_FILE="$CA_DIR/ca.srl"
    if [ ! -f "$SERIAL_FILE" ]; then
        printf '%016x\n' "$(date +%s%N)" > "$SERIAL_FILE"
    fi

    _sign_cert() {
        local cn="$1" key="$2" crt="$3" ext="${4:-}"
        # Subject CN is a fixed, short placeholder, not the real hostname:
        # OpenSSL's default policy caps commonName at 64 bytes
        # (ASN1_mbstring_ncopy rejects longer values with "string too long"),
        # but _is_valid_domain allows domains up to 253 bytes -- a deep
        # wildcard base or exact host past 64 bytes would otherwise fail
        # `openssl req -new` outright and abort startup. TLS clients validate
        # against subjectAltName, not CN (RFC 6125 / CA/Browser Forum
        # baseline), so the real hostname belongs only in $ext's SAN, which
        # has no such length limit here.
        if ! openssl req -new -newkey rsa:2048 -nodes -subj "/CN=lancache-ng" \
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
                # Clean up the key and any partial output, not just the CSR: a
                # failed sign otherwise leaves an orphaned private key (and a
                # possibly truncated $crt from an interrupted/full-disk write)
                # on disk (#655).
                rm -f /tmp/lancache-cert.csr "$key" "$crt"
                echo "[lancache] ERROR: Failed to sign certificate for ${cn}" >&2
                return 1
            fi
        else
            if ! openssl x509 -req -days 3650 \
                -in /tmp/lancache-cert.csr \
                -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAserial "$SERIAL_FILE" \
                -out "$crt"; then
                rm -f /tmp/lancache-cert.csr "$key" "$crt"
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
        # Matched via a here-string, not `echo ... | grep -q` (AG-VAL-032):
        # this script runs under `set -o pipefail`, and a multi-line $san
        # could let grep exit after an early match while echo is still
        # writing, which pipefail would report as failure even though grep
        # matched -- the general SIGPIPE-under-pipefail hazard that
        # scripts/untracked/check-pipefail-early-exit-grep.sh guards against repo-wide.
        grep -q "DNS:" <<< "$san" || return 0
        if [ -n "${IP_SSL}" ]; then
            # `grep -q "IP Address:${IP_SSL}"` would be an unanchored substring
            # match: if IP_SSL migrates from 192.168.1.11 to 192.168.1.1, the
            # search string is still found inside the old SAN, so a stale cert
            # for the old IP would be kept (#655). Anchor on the trailing edge
            # (dots escaped so they match literally, and the char right after
            # the address must not be another digit/dot) so only an exact IP
            # match counts; a comma, whitespace, or end of string may follow.
            local ip_pattern="${IP_SSL//./\\.}"
            [[ "$san" =~ IP\ Address:${ip_pattern}([^0-9.]|$) ]] || return 0
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
    # One additional cert per deeper wildcard base (see _EXTRA_WILDCARD_BASES'
    # declaration above) -- SAN is wildcard-only, no bare DNS: entry, since a
    # leading-dot cdn-domains.txt entry never covers its own bare form either.
    for domain in "${_EXTRA_WILDCARD_BASES[@]}"; do
        cert_name="$(_bounded_cert_name "$domain" wildcard)"
        [ -f "$CERT_DIR/${cert_name}.crt" ] && [ -f "$CERT_DIR/${cert_name}.key" ] && continue

        echo "[lancache] Generating deeper wildcard cert for *.$domain..."
        if ! _sign_cert "$domain" \
            "$CERT_DIR/${cert_name}.key" \
            "$CERT_DIR/${cert_name}.crt" \
            "subjectAltName=DNS:*.${domain}"; then
            echo "[lancache] ERROR: Failed to generate certificate for *.$domain" >&2
            exit 1
        fi
    done
    # One additional cert per deeper bare/exact host (see _EXTRA_EXACT_HOSTS'
    # declaration above) -- SAN is the exact hostname only, no wildcard,
    # since a bare cdn-domains.txt entry matches only that literal host.
    # File name comes from _bounded_cert_name's "exact" namespace, NOT the
    # bare domain string: cdn-domains.txt can legally list both
    # "x.cdn.ea.com" (bare) and ".x.cdn.ea.com" (wildcard) as separate
    # entries for the same base -- those need two DIFFERENT certs (one
    # exact-only SAN, one wildcard-only SAN), and the "exact"/"wildcard"
    # namespace tag keeps their hashed names from colliding.
    for domain in "${_EXTRA_EXACT_HOSTS[@]}"; do
        cert_name="$(_bounded_cert_name "$domain" exact)"
        [ -f "$CERT_DIR/${cert_name}.crt" ] && [ -f "$CERT_DIR/${cert_name}.key" ] && continue

        echo "[lancache] Generating deeper exact-match cert for $domain..."
        if ! _sign_cert "$domain" \
            "$CERT_DIR/${cert_name}.key" \
            "$CERT_DIR/${cert_name}.crt" \
            "subjectAltName=DNS:${domain}"; then
            echo "[lancache] ERROR: Failed to generate certificate for $domain" >&2
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
# Factored into its own function (rather than inline top-level script code)
# so tests/bats/proxy_ssl_map_generation.bats can drive the real
# $cdn_host_allowed (strict/lazy) and $lancache_client_allowed
# (PROXY_ALLOWED_CLIENT_CIDRS) map generation directly -- both the
# strict-mode 403 code path and the CIDR-allowlist 403 code path are
# security-relevant and need their own regression coverage independent of
# the rest of this entrypoint.
_render_ssl_map() {
    echo "# Auto-generated by entrypoint — do not edit"
    echo "map \$ssl_server_name \$ssl_cert_name {"
    echo "    hostnames;"
    for domain in "${_UNIQUE_DOMAINS[@]}"; do
        printf "    %-45s %s;\n" "*.${domain}"  "$domain"
        if [ "${_DOMAIN_IS_ROOT[$domain]}" -eq 1 ]; then
            printf "    %-45s %s;\n" "$domain" "$domain"
        fi
    done
    # More specific than the root entries above -- nginx's hostnames map
    # picks the longest matching "*."-prefixed wildcard, so an SNI value
    # under one of these deeper bases (e.g. x.cdn.ea.com) resolves here
    # instead of to its root's cert, which would not validate for it.
    for domain in "${_EXTRA_WILDCARD_BASES[@]}"; do
        printf "    %-45s %s;\n" "*.${domain}" "$(_bounded_cert_name "$domain" wildcard)"
    done
    # Exact-host entries (see _EXTRA_EXACT_HOSTS' declaration above) map the
    # literal hostname to its dedicated cert -- no "*."-prefix key, since a
    # bare cdn-domains.txt entry is never a wildcard match.
    for domain in "${_EXTRA_EXACT_HOSTS[@]}"; do
        printf "    %-45s %s;\n" "$domain" "$(_bounded_cert_name "$domain" exact)"
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
        for domain in "${_EXTRA_WILDCARD_BASES[@]}"; do
            printf "    %-45s 1;\n" "*.${domain}"
        done
        for domain in "${_EXTRA_EXACT_HOSTS[@]}"; do
            printf "    %-45s 1;\n" "$domain"
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
}
_render_ssl_map > "$SSL_MAP_FILE"

mkdir -p /etc/nginx/stream.d

# Shared fallback target for a missing/empty SNI in the $stream_backend map
# below. History: PR #198 originally fixed this for a static nginx.conf map
# with a literal "" -> 127.0.0.1:9 key (issue #88); commit e09a0f98 replaced
# that static map with this per-mode generated one and only carried the
# fallback into strict mode's own "default" line (a coincidence of strict
# mode's default already being the same safe target, not a deliberate
# re-application of the fix) -- lazy mode's default forwards to the literal
# SNI value itself ($ssl_preread_server_name:443), which becomes the invalid
# target ":443" for an empty SNI in the project's shipped default mode.
# Emitting this as an explicit "" key once, shared by both branches below,
# means a
# future edit to one branch cannot again drift out of sync with the other on
# this specific case (AG-CODE-011's own worked example is this exact file).
STREAM_EMPTY_SNI_BACKEND="127.0.0.1:9"

# Factored into its own function (rather than inline top-level script code)
# so tests/bats/proxy_stream_backend_map.bats can drive both
# PROXY_SECURITY_MODE branches directly.
_render_stream_backend_map() {
    echo "# Auto-generated by entrypoint — do not edit"
    echo "map \$ssl_preread_server_name \$stream_backend {"
    echo "    hostnames;"
    printf "    %-45s %s;\n" '""' "$STREAM_EMPTY_SNI_BACKEND"
    if [ "$PROXY_SECURITY_MODE" = "lazy" ]; then
        echo "    default \$ssl_preread_server_name:443;"
    else
        echo "    default $STREAM_EMPTY_SNI_BACKEND;"
        for domain in "${_UNIQUE_DOMAINS[@]}"; do
            # Forward to the requested SNI itself, NOT to "$domain:443" -- a
            # registrable root is only a cert-selection/DNS-match boundary,
            # not necessarily the real origin host for every subdomain
            # beneath it. A listed drivers.amd.com (root amd.com) must reach
            # drivers.amd.com:443, not amd.com:443, since the real CDN origin
            # may not serve that subdomain's content from the root's own
            # resolved IP -- confirmed live (issue #1297, folded into #1276):
            # this is the exact bug the _EXTRA_WILDCARD_BASES loop below was
            # already fixed for; this loop had the same bug for its own,
            # older case.
            printf "    %-45s \$ssl_preread_server_name:443;\n" "*.${domain}"
            # _DOMAIN_IS_ROOT[$domain] is structurally always 1 here: this
            # loop iterates _UNIQUE_DOMAINS, which by construction only ever
            # contains derived roots (see _collect_domain_rows), and every
            # derived root is marked as its own root unconditionally. The
            # guard is kept anyway so this stays parallel/defensive with the
            # other three map-generation loops below, none of which can
            # assume anything about _DOMAIN_IS_ROOT's contents for their own
            # arrays -- removing it here would save nothing at runtime but
            # would make this loop's shape inconsistent with its neighbors
            # for no benefit.
            if [ "${_DOMAIN_IS_ROOT[$domain]}" -eq 1 ]; then
                printf "    %-45s \$ssl_preread_server_name:443;\n" "$domain"
            fi
        done
        for domain in "${_EXTRA_WILDCARD_BASES[@]}"; do
            # Forward to the requested SNI itself, NOT to "$domain:443" --
            # same reasoning as the registrable-root loop above (issue
            # #1297, folded into #1276): a deeper wildcard base is a
            # cert-selection boundary, not necessarily a real,
            # independently resolvable host: passthrough must reach
            # whatever the client actually asked for (e.g. ftp.de.debian.org),
            # not the wildcard base's own name (de.debian.org), which may
            # have no DNS record or point at an unrelated endpoint.
            printf "    %-45s \$ssl_preread_server_name:443;\n" "*.${domain}"
        done
        for domain in "${_EXTRA_EXACT_HOSTS[@]}"; do
            # Reviewed for the same #1297 bug class as the two loops above
            # and found already correct by construction: the map key here
            # IS the literal exact host, so a match only ever happens when
            # $ssl_preread_server_name equals $domain exactly -- forwarding
            # to "$domain:443" is the same target "$ssl_preread_server_name:443"
            # would resolve to. No change needed for this loop.
            printf "    %-45s %s:443;\n" "$domain" "$domain"
        done
    fi
    echo "}"
}
_render_stream_backend_map > "$STREAM_TARGET_FILE"

# ────────────────────────────────────────────────────────────────────────────
# 2b. Client-IP allowlist for the stream-level (SNI-only) externally-facing
#     listeners
#
# $lancache_client_allowed (the geo map derived from PROXY_ALLOWED_CLIENT_CIDRS,
# see "3." below) is compiled only into $SSL_MAP_FILE, which nginx.conf's
# `http {}` block includes -- a geo variable is scoped to the context that
# defines it, so it is structurally unusable from the `stream {}` context
# regardless of how PROXY_ALLOWED_CLIENT_CIDRS is set. Every stream-level
# externally-facing listener (nginx.conf's static 8443 standard-mode
# passthrough server, and "2a." below's dynamically-generated 443 SSL-mode
# dispatcher when SSL_ENABLED=1) therefore accepted an unrestricted
# SNI-driven TLS relay to any host, regardless of PROXY_ALLOWED_CLIENT_CIDRS,
# in both lazy and strict mode -- confirmed via a targeted grep of every
# stream-context file in this service finding zero `allow`/`deny` directives
# anywhere. ngx_stream_access_module's plain allow/deny
# directives (a real nginx module, distinct from the geo-based approach
# above, since a geo variable cannot cross the http/stream context
# boundary) rather than trying to share the http-only geo variable.
#
# This file is `include`d ONLY by the two external listeners named above --
# never by "2a." below's internal 127.0.0.1-only relay hops (the MITM/
# passthrough relay servers), which must stay reachable from each other
# regardless of the ORIGINAL client's address: that address was already
# checked once, at whichever external listener first accepted the
# connection, and re-checking it against PROXY_ALLOWED_CLIENT_CIDRS a second
# time at the relay hop (whose own peer is always 127.0.0.1, the first
# listener itself) would silently break the relay chain for any operator
# whose CIDR list does not happen to include 127.0.0.1.
#
# Deliberately placed in its OWN subdirectory, not directly in stream.d/
# itself: nginx.conf's `include /etc/nginx/stream.d/*.conf;` (single-level
# glob, not recursive) already sweeps every top-level file in stream.d/ into
# the stream {} context unconditionally -- a bare allow/deny file dropped
# there would be picked up by that same blanket include and applied at the
# stream {} top level, inherited by every server within it (including the
# 127.0.0.1-only relay hops this comment just explained must NOT get it).
# A one-level-deeper subdirectory is invisible to a non-recursive `*.conf`
# glob against its parent, so this file is reachable only via the explicit,
# scoped `include` statements placed inside the two external listeners.
mkdir -p /etc/nginx/stream.d/access.d
STREAM_CLIENT_ACL_FILE="/etc/nginx/stream.d/access.d/00-stream-client-acl.conf"

# Factored into its own function (rather than inline top-level script code)
# so tests/bats/proxy_stream_client_acl.bats can drive the stream-level
# client ACL generation directly.
_render_stream_client_acl() {
    echo "# Auto-generated by entrypoint — do not edit"
    if [ -n "$PROXY_ALLOWED_CLIENT_CIDRS" ]; then
        for cidr in $PROXY_ALLOWED_CLIENT_CIDRS; do
            printf "allow %s;\n" "$cidr"
        done
        echo "deny all;"
    fi
    # PROXY_ALLOWED_CLIENT_CIDRS empty means "allow everyone" (this
    # project's documented lazy default, AG-OP-003/AG-OP-005): emitting no
    # allow/deny directives at all leaves ngx_stream_access_module's own
    # implicit "allow all" in effect, mirroring $lancache_client_allowed's
    # own "default 1;" branch below for the identical empty-CIDR case.
}
_render_stream_client_acl > "$STREAM_CLIENT_ACL_FILE"

# ────────────────────────────────────────────────────────────────────────────
# 2a. SSL mode: stream-level SNI depth-dispatch (issues #1276/#1322)
#
# A leading-dot cdn-domains.txt entry DNS-spoofs arbitrary depth below it
# (services/dns/entrypoint.sh's RPZ generation, #1072), but a pre-generated
# X.509 wildcard cert only ever covers exactly one label of depth (RFC
# 6125) -- a client two or more labels below such an entry got served a
# certificate that does not validate for its SNI, and the connection failed
# even though DNS resolution worked (#1322). Fix: an outer stream-level
# dispatcher reads the SNI via ssl_preread (before any TLS termination) and
# routes to one of two internal relays depending on whether that exact
# depth is covered by a real generated cert -- covered goes to the MITM
# relay (real cert, cache path), uncovered-but-still-DNS-spoofed goes to
# the passthrough relay (blind-forward, same mechanism standard mode
# already uses for any host it doesn't recognize).
#
# Two relays, not one, and both required even though only the MITM branch
# needed fixing: proxy_protocol (used to preserve the real client IP across
# the stream-level hop -- see below) applies per stream server block, not
# per destination within one block. A single new relay dedicated to only
# the MITM branch would still leave the outer dispatcher itself making an
# un-tagged connection to whichever backend $ssl_dispatch_backend picked --
# confirmed live: the relay saw 127.0.0.1, not the real client, regardless
# of what was configured on the relay end alone. Enabling proxy_protocol
# directly on the outer dispatcher applies to BOTH branches uniformly (it
# is per-block, not per-destination) -- correct for the MITM relay, but
# would corrupt the raw TLS bytes nginx forwards to a real, unmodified
# external CDN origin on the passthrough branch. Routing both branches
# through their own dedicated internal relay first resolves this: the
# passthrough relay accepts the PROXY-protocol-tagged connection from the
# dispatcher, re-reads the SNI itself, and forwards the raw TLS bytes
# onward unmodified -- passthrough itself stays structurally untouched.
#
# Uses regex-anchored map keys, NOT nginx's "hostnames" mode: hostnames
# mode's "*.base" wildcard form matches *any* depth below base, not one
# label -- confirmed live even against this file's own unmodified
# $ssl_cert_name map above. A naive port of that map into this dispatcher
# would silently reproduce the exact bug this section fixes. Regex keys
# instead express the real one-label RFC 6125 boundary precisely: "exactly
# one label below a covered base" routes to the MITM relay (matches that
# base's own generated cert, see "2." above); "two or more labels below"
# routes to the passthrough relay instead of a mismatched cert the client
# would reject anyway. Mirrors _UNIQUE_DOMAINS/_DOMAIN_IS_ROOT/
# _EXTRA_WILDCARD_BASES/_EXTRA_EXACT_HOSTS/_ROOT_HAS_WILDCARD_ENTRY --
# the exact same coverage "2."'s $ssl_cert_name generation already computed
# above -- rather than re-deriving it independently, so the two can never
# drift apart as cdn-domains.txt changes.
#
# Ordering note: nginx's stream map picks the FIRST matching regex in file
# order, not the most specific one (unlike "hostnames" mode's longest-match
# behavior). A shallower base's "two or more labels below" catch-all could
# otherwise shadow a deeper, more specific base's own "one label below"
# entry (e.g. an operator-added ".b.cdn.ea.com" nested under an existing
# ".cdn.ea.com" entry -- the documented per-level mitigation for this exact
# gap). Sorting every wildcard base by string length, longest (deepest,
# most specific) first, and emitting each base's own pair of entries
# together, guarantees a deeper base's entries are always checked before a
# shallower base's catch-all could shadow them -- verified with a
# three-level nested simulation before being written here.
#
# Internal-only relay/listener ports below are not operator-configurable:
# pure internal wiring between this container's own nginx processes, all
# bound to 127.0.0.1 only. Keep these literals in sync with
# conf.d/https.conf's two `listen` lines (8444 via the relay, 8445 plain for
# the Compose healthcheck) and deploy/prod/docker-compose.yml's healthcheck
# if ever changed.
# ────────────────────────────────────────────────────────────────────────────
SSL_DISPATCH_MAP_FILE="/etc/nginx/stream.d/01-ssl-dispatch.conf"
SSL_DISPATCH_MITM_RELAY_PORT=9445
SSL_DISPATCH_PASSTHROUGH_RELAY_PORT=9446
SSL_MITM_INTERNAL_PORT=8444

if [ "${SSL_ENABLED}" = "1" ]; then
    declare -a _wildcard_bases=("${_EXTRA_WILDCARD_BASES[@]}")
    for _root in "${_UNIQUE_DOMAINS[@]}"; do
        [[ -n "${_ROOT_HAS_WILDCARD_ENTRY[$_root]+set}" ]] && _wildcard_bases+=("$_root")
    done
    declare -a _sorted_wildcard_bases=()
    if [ "${#_wildcard_bases[@]}" -gt 0 ]; then
        mapfile -t _sorted_wildcard_bases < <(
            printf '%s\n' "${_wildcard_bases[@]}" | awk '{ print length, $0 }' | sort -rn -k1,1 | cut -d' ' -f2-
        )
    fi

    {
        echo "# Auto-generated by entrypoint — do not edit"
        echo "map \$ssl_preread_server_name \$ssl_dispatch_backend {"
        # Same empty-SNI safeguard as _render_stream_backend_map's own ""
        # key above (issue #88, AG-CODE-011's own worked example): without
        # an explicit "" key here, a client with no SNI at all falls to this
        # map's own "default" branch below, which in lazy mode points at
        # the passthrough relay's `proxy_pass $ssl_preread_server_name:443;`
        # -- an empty SNI there resolves to the literal invalid target
        # ":443", the exact same bug this shared constant already fixes for
        # the standard-mode stream_backend map.
        printf "    %-45s %s;\n" '""' "$STREAM_EMPTY_SNI_BACKEND"
        for domain in "${_UNIQUE_DOMAINS[@]}"; do
            # Bare root itself always goes to MITM (its own cert's bare
            # DNS: SAN entry). Its "one label below" regex is skipped here
            # when the root is ALSO wildcard-flagged -- that pair is
            # emitted together with its "two or more labels" counterpart in
            # the sorted-bases loop below instead, to avoid a duplicate map
            # key (nginx rejects those outright at "nginx -t" time).
            printf "    %-45s 127.0.0.1:%s;\n" "$domain" "$SSL_DISPATCH_MITM_RELAY_PORT"
            if [[ -z "${_ROOT_HAS_WILDCARD_ENTRY[$domain]+set}" ]]; then
                one_level_key="\"~^[^.]+\\.$(_regex_escape_domain "$domain")\$\""
                printf "    %-45s 127.0.0.1:%s;\n" "$one_level_key" "$SSL_DISPATCH_MITM_RELAY_PORT"
            fi
        done
        for domain in "${_EXTRA_EXACT_HOSTS[@]}"; do
            printf "    %-45s 127.0.0.1:%s;\n" "$domain" "$SSL_DISPATCH_MITM_RELAY_PORT"
        done
        for domain in "${_sorted_wildcard_bases[@]}"; do
            escaped="$(_regex_escape_domain "$domain")"
            one_level_key="\"~^[^.]+\\.${escaped}\$\""
            deeper_key="\"~^.+\\.${escaped}\$\""
            printf "    %-45s 127.0.0.1:%s;\n" "$one_level_key" "$SSL_DISPATCH_MITM_RELAY_PORT"
            printf "    %-45s 127.0.0.1:%s;\n" "$deeper_key" "$SSL_DISPATCH_PASSTHROUGH_RELAY_PORT"
        done
        if [ "$PROXY_SECURITY_MODE" = "strict" ]; then
            echo "    default 127.0.0.1:9;"
        else
            printf "    default 127.0.0.1:%s;\n" "$SSL_DISPATCH_PASSTHROUGH_RELAY_PORT"
        fi
        echo "}"
        echo ""
        echo "server {"
        echo "    listen 443;"
        echo "    listen [::]:443;"
        # Client-IP allowlist (see "2b." above) -- this is the
        # OUTER, externally-facing dispatcher, so it gets the check; the two
        # internal 127.0.0.1-only relay servers below deliberately do not
        # (their own peer is always this listener itself, not the original
        # client, and re-checking there would break the relay chain).
        printf "    include %s;\n" "$STREAM_CLIENT_ACL_FILE"
        echo "    ssl_preread on;"
        echo "    proxy_pass \$ssl_dispatch_backend;"
        echo "    proxy_protocol on;"
        echo "    proxy_connect_timeout 30s;"
        echo "    proxy_timeout        3600s;"
        echo "}"
        echo ""
        echo "server {"
        printf "    listen 127.0.0.1:%s proxy_protocol;\n" "$SSL_DISPATCH_MITM_RELAY_PORT"
        echo "    set_real_ip_from 127.0.0.1;"
        echo "    proxy_protocol on;"
        printf "    proxy_pass 127.0.0.1:%s;\n" "$SSL_MITM_INTERNAL_PORT"
        echo "    proxy_connect_timeout 30s;"
        echo "    proxy_timeout        3600s;"
        echo "}"
        echo ""
        echo "server {"
        printf "    listen 127.0.0.1:%s proxy_protocol;\n" "$SSL_DISPATCH_PASSTHROUGH_RELAY_PORT"
        echo "    set_real_ip_from 127.0.0.1;"
        echo "    ssl_preread on;"
        echo "    proxy_pass \$ssl_preread_server_name:443;"
        echo "    proxy_connect_timeout 30s;"
        echo "    proxy_timeout        3600s;"
        echo "}"
    } > "$SSL_DISPATCH_MAP_FILE"
else
    rm -f "$SSL_DISPATCH_MAP_FILE"
fi

# ────────────────────────────────────────────────────────────────────────────
# 3. Remove https.conf when SSL mode is disabled
#    (Docker routes IP_SSL:443→container:443 and IP_STANDARD:443→container:8443,
#    so https.conf can safely listen on 0.0.0.0:443 — only SSL clients reach it)
#    Since #1276/#1322: IP_SSL:443 now reaches the stream-level SNI dispatch
#    listener above instead, which itself only exists when SSL_ENABLED=1 --
#    see "2a." above.
# ────────────────────────────────────────────────────────────────────────────
if [ "${SSL_ENABLED}" = "0" ]; then
    rm -f /etc/nginx/conf.d/https.conf
fi

# ────────────────────────────────────────────────────────────────────────────
# 3a. Generate the static /healthz response body
#
# conf.d/http.conf and conf.d/https.conf's own "location = /healthz" blocks
# deliberately serve this via a real content-phase file handler (`alias`),
# NOT a bare `return 200 "ok\n";`: `return` is an ngx_http_rewrite_module
# directive that runs in nginx's rewrite phase, which executes BEFORE the
# access phase where `allow`/`deny` are evaluated. A location combining
# `deny all;` with a bare `return` in the SAME location therefore never
# enforces that deny at all -- reproduced on a stock, unmodified
# nginx:1.27-alpine image (not something specific to this project's own
# build): a bare `deny all;` alone correctly returns 403, the identical
# `deny all;` alongside `return 200 "...";` in one location returns 200
# regardless of source address. Serving the body via `alias` to a real
# file instead uses ngx_http_static_module's content-phase handler, which
# runs AFTER the access phase and therefore correctly enforces the ACL in
# both directions (403 for a denied source, 200 with the real body for an
# allowed one). See docs/release-validation-plan.md's Standing checks row
# for the full differential-container reproduction.
#
# Deliberately NOT added to PROXY_CANDIDATE_FILES/the known-good-snapshot
# mechanism below (section "5."): that mechanism exists to roll back a
# CONFIG file `nginx -t` can validate/invalidate. This is a static content
# file with fixed, entrypoint-controlled content ("ok\n") that `nginx -t`
# has no opinion on either way -- there is nothing for a snapshot to
# validate or a rollback to meaningfully restore here, unlike nginx.conf/
# proxy-params.conf/the generated maps.
# ────────────────────────────────────────────────────────────────────────────
printf 'ok\n' > /etc/nginx/lancache-healthz-body.txt

# ────────────────────────────────────────────────────────────────────────────
# 4. Render nginx.conf and proxy-params from templates
# ────────────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2016 # envsubst needs literal variable names, not shell-expanded ones.
envsubst '${CACHE_MEM_MB} ${CACHE_MAX_SIZE} ${CACHE_MIN_FREE} ${CACHE_INACTIVE} ${NGINX_UPSTREAM_RESOLVER}' \
    < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# shellcheck disable=SC2016 # envsubst needs literal variable names, not shell-expanded ones.
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

# _migrate_legacy_proxy_snapshots_for_stream_acl
# PROXY_CANDIDATE_FILES below includes $STREAM_CLIENT_ACL_FILE as one of its
# five candidate basenames. kgs_snapshot_apply (in the shared library above)
# deliberately rejects any snapshot missing one of the requested basenames
# as "incomplete" rather than silently mixing an old snapshot's files with
# the new one -- correct in general, but it means a snapshot taken under an
# older, shorter candidate list is permanently unusable for rollback once a
# new basename is added to that list, leaving zero valid rollback targets
# for the first bad boot after such an upgrade -- exactly the boot this
# rollback protection exists for. A one-time backfill is therefore scoped to
# proxy only (not added to the shared kgs_* library itself, which stays a
# generic, service-agnostic contract also embedded verbatim in dhcp-proxy/
# dns). The saved nginx.conf is the schema marker: only a configuration that
# predates the stream-ACL include may legitimately omit the ACL candidate.
# Such a snapshot gets an empty file, preserving the unrestricted stream
# behavior under which it was actually validated. A newer snapshot whose
# nginx.conf includes the ACL but whose ACL file is missing stays incomplete;
# recreating that file empty would turn filesystem damage into a silent
# allowlist bypass. Copying this boot's generated ACL is unsafe too, because
# a malformed current PROXY_ALLOWED_CLIENT_CIDRS could corrupt every usable
# rollback target before nginx validates the new configuration. The migration
# is idempotent and a no-op for snapshots that already contain the file.
_migrate_legacy_proxy_snapshots_for_stream_acl() {
    local snapshot_root="$1"
    local id snap_dir schema_status
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        snap_dir="${snapshot_root}/${id}"
        [ -f "${snap_dir}/nginx.conf" ] || continue
        [ -f "${snap_dir}/proxy-params.conf" ] || continue
        [ -f "${snap_dir}/00-stream-client-acl.conf" ] && continue
        if grep -Fq 'stream.d/access.d/00-stream-client-acl.conf' "${snap_dir}/nginx.conf"; then
            kgs_log WARN "proxy" "snapshot $id declares the stream ACL but is missing 00-stream-client-acl.conf; leaving it incomplete rather than weakening its saved allowlist"
            continue
        else
            schema_status=$?
        fi
        if [ "$schema_status" -ne 1 ]; then
            kgs_log WARN "proxy" "could not inspect nginx.conf in snapshot $id; leaving it incomplete because its schema cannot be identified safely"
            continue
        fi
        if : > "${snap_dir}/00-stream-client-acl.conf" 2>/dev/null; then
            kgs_log MIGRATE "proxy" "backfilled legacy unrestricted 00-stream-client-acl.conf into pre-existing known-good snapshot $id"
        else
            kgs_log FATAL "proxy" "failed to backfill 00-stream-client-acl.conf into known-good snapshot $id; it stays incomplete and unusable for rollback until this succeeds"
        fi
    done < <(kgs_list_snapshots "$snapshot_root")
}
_migrate_legacy_proxy_snapshots_for_stream_acl "$PROXY_CONFIG_SNAPSHOT_DIR"

PROXY_CANDIDATE_FILES=(/etc/nginx/nginx.conf /etc/nginx/proxy-params.conf "$SSL_MAP_FILE" "$STREAM_TARGET_FILE" "$STREAM_CLIENT_ACL_FILE")
_proxy_validate_snapshot_or_rollback "${PROXY_CANDIDATE_FILES[@]}" || exit 1

echo "[lancache] Starting nginx (IP_STANDARD=${IP_STANDARD}, SSL_ENABLED=${SSL_ENABLED})..."
prepare_proxy_log_dir_for_syslog
exec nginx -g "daemon off;"
