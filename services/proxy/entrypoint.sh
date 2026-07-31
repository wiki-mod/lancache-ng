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
# KNOWN LIMITATION (issue #1322): this only ever adds ONE extra label of
# wildcard depth per leading-dot entry. A leading-dot entry's real DNS-side
# match scope is arbitrary depth (services/dns/entrypoint.sh's RPZ generation
# spoofs every subdomain of it, at any depth), but no static, pre-generated
# X.509 cert scheme can match that: a client two or more labels below the
# entry (e.g. "a.b.cdn.ea.com" under a ".cdn.ea.com" entry) still fails TLS
# hostname verification. Mitigation that works today: add the specific
# deeper level as its own leading-dot entry (e.g. ".b.cdn.ea.com") -- nginx's
# hostnames map picks the more specific of two matching wildcard keys, so
# the new, more specific cert wins for that level. This does not generalize
# to arbitrary depth; the same gap recurs one level further for a CDN that
# genuinely serves from unpredictable subdomain depths. Fully closing this
# needs dynamic per-SNI certificate issuance at handshake time, a materially
# different architecture than this pre-generated-cert design (see CLAUDE.md's
# "Pre-generated wildcard certs" decision) -- a maintainer decision, not a
# fix reachable here. STATUS: as of 2026-07-30, unresolved; see issue #1322.
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

export NGINX_UPSTREAM_RESOLVER PROXY_SECURITY_MODE PROXY_ALLOWED_CLIENT_CIDRS

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
        # openssl -keyout follows the umask (0022 by default), leaving ca.key
        # world-readable (644). Harden it to match certs/generate-ca.sh's own
        # standalone CA generation, which already does this (#1031).
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
        echo "$san" | grep -q "DNS:" || return 0
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
        for domain in "${_EXTRA_WILDCARD_BASES[@]}"; do
            # Forward to the requested SNI itself, NOT to "$domain:443" --
            # unlike a registrable root (_UNIQUE_DOMAINS above), a deeper
            # wildcard base is a cert-selection boundary, not necessarily a
            # real, independently resolvable host: passthrough must reach
            # whatever the client actually asked for (e.g. ftp.de.debian.org),
            # not the wildcard base's own name (de.debian.org), which may
            # have no DNS record or point at an unrelated endpoint. The
            # registrable-root loop above has this same class of bug for its
            # own case (a listed drivers.amd.com forwards to amd.com:443, not
            # drivers.amd.com:443) -- confirmed separately, tracked as issue
            # #1297, not fixed here (out of this change's scope).
            printf "    %-45s \$ssl_preread_server_name:443;\n" "*.${domain}"
        done
        for domain in "${_EXTRA_EXACT_HOSTS[@]}"; do
            printf "    %-45s %s:443;\n" "$domain" "$domain"
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
