#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Guided lifecycle CLI for a lancache-ng installation. Subcommands: install
# (interactive first-time setup — installs Docker/Compose if missing on
# Debian/Ubuntu/RHEL-family hosts, writes .env with generated secrets,
# configures DHCP mode/cache sizing/DNS IPs, enables the systemd
# service+converge timer, and starts the stack), update, update-ip, debug,
# create-logs-for-issue (bundles redacted logs/config for a GitHub bug
# report), secondary (register/rotate a secondary DNS node against a
# primary), backup, and restore. Also hosts the shared .env helpers
# (read/write/generate secret values, validate CIDR/DHCP-mode input) reused
# by the secondary registration flow.
# Usage: ./setup.sh [command] [install-dir]
set -euo pipefail
export LANG=C LC_ALL=C

# Keep the normal installer as the production path: collect runtime settings,
# generate or preserve secrets, write the quickstart .env/compose files, pull
# prebuilt images, and start the stack. Development-only behavior belongs behind
# an explicit future opt-in path, not inside the default first-user flow.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)"
QUICKSTART_COMPOSE="$SCRIPT_DIR/deploy/quickstart/docker-compose.yml"
DOCKER_SOCKET_PROXY_SCRIPT="$SCRIPT_DIR/scripts/docker-socket-proxy.sh"
DHCP_PROBE_SCRIPT="$SCRIPT_DIR/services/ui/dhcp-probe.sh"
# Shared-secret bootstrap helper (#858): the quickstart nats service sources this
# to resolve the NATS_*_PASSWORD handshake secrets from the shared-secrets volume.
# Copied flat into $install_dir/scripts/ like the two scripts above, so the
# quickstart compose can bind-mount ./scripts/shared-secret-bootstrap.sh.
SHARED_SECRET_BOOTSTRAP_SCRIPT="$SCRIPT_DIR/scripts/lib/shared-secret-bootstrap.sh"
DEFAULT_UI_SESSION_TTL_SECONDS=86400
MAX_UI_SESSION_TTL_SECONDS=31536000

# ── Colors (only when connected to a terminal) ────────────────────────────────
if [[ -t 1 ]]; then
    BOLD="\033[1m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"
    RED="\033[0;31m"; CYAN="\033[0;36m"; RESET="\033[0m"
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; RESET=""
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
print_step() { printf "\n${BOLD}${CYAN}▶ %s${RESET}\n" "$*"; }
print_ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
print_warn() { printf "  ${YELLOW}⚠${RESET} %s\n" "$*"; }
print_error(){ printf "  ${RED}✗${RESET} %s\n" "$*" >&2; }
die()        { print_error "$*"; exit 1; }

REPLY=""
# Reads from /dev/tty explicitly, not stdin: this script is commonly run via
# `curl ... | bash`, which occupies stdin with the script body itself. Without
# this, every prompt would silently read leftover script text instead of
# waiting for the user.
ask() {
    local prompt="$1" default="${2:-}"
    printf "  ${BOLD}%s${RESET} [%s]: " "$prompt" "$default"
    read -r REPLY < /dev/tty
    REPLY="${REPLY:-$default}"
}

# CLI argument-parsing guard: dies if a flag's value is missing or looks like
# another flag (e.g. `--token --name`), which would otherwise silently consume
# the next option as this one's value.
require_value() {
    local option="$1" value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        die "${option} requires a value"
    fi
}

is_valid_ipv4() {
    local ip="$1"

    # Keep IPv4 validation as one readable regular expression so every octet
    # is range-checked before the value is written into Docker or DNS config.
    # Accepted: 0.0.0.0 through 255.255.255.255. Rejected: partial IPs,
    # hostnames, negative numbers, and out-of-range octets such as 256.
    local octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    [[ "$ip" =~ ^${octet}\.${octet}\.${octet}\.${octet}$ ]]
}

# True for unsigned decimal integers greater than zero. The 10# base prefix
# forces base-10 arithmetic so a leading-zero value like "010" is read as ten,
# not misinterpreted as octal by bash arithmetic.
is_positive_integer() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

# True if the value is non-empty and starts with /, i.e. a filesystem absolute path.
is_absolute_path() {
    [[ -n "${1:-}" && "$1" == /* ]]
}

# True for an nginx-style time value (e.g. "365d", "1h30m", "600") as accepted
# by directives like proxy_cache_path's inactive= parameter. nginx's own time
# grammar is a run of <number><unit> pairs (ms, s, m, h, d, w, M, y); a bare
# number with no suffix means seconds. This mirrors that grammar closely
# enough to catch a typo before it reaches envsubst/nginx config generation,
# without needing nginx itself available at setup time to validate it.
is_valid_nginx_time_value() {
    [[ "${1:-}" =~ ^([0-9]+(ms|[smhdwMy])?)+$ ]]
}

# Walks up from $1 to the nearest existing ancestor directory. Used for disk
# free-space checks against CACHE_DIR: at the point the cache-size prompt
# runs, CACHE_DIR itself does not exist yet (it is only created later via
# `mkdir -p "$CACHE_DIR"`, near the end of the install flow), so `df` would
# otherwise fail with "No such file or directory" on the path as typed.
nearest_existing_ancestor_dir() {
    local path="$1"
    while [[ ! -d "$path" ]]; do
        path="$(dirname "$path")"
    done
    printf '%s\n' "$path"
}

# Free space, in whole MiB, on the filesystem that would back directory $1
# once created (see nearest_existing_ancestor_dir above). Uses `df -Pk`
# (POSIX output format, 1024-byte blocks) rather than plain `df`, since
# plain df's column layout wraps onto a second line for long device/mount
# source strings (e.g. some overlay mounts), which would otherwise shift
# the field this awk expression reads.
available_space_mib_at() {
    local dir avail_kib
    dir="$(nearest_existing_ancestor_dir "$1")"
    # `|| true` keeps a failing `df` (permission issue, exotic filesystem)
    # from tripping `set -e`/`pipefail` before the explicit die() below can
    # produce a clear message -- the same guard-then-validate pattern used
    # elsewhere in this script (e.g. detect_secondary_listen_ip's route lookup).
    avail_kib=$(df -Pk "$dir" 2>/dev/null | awk 'NR==2 {print $4}' || true)
    [[ "$avail_kib" =~ ^[0-9]+$ ]] \
        || die "Could not determine free disk space at $dir (df failed or returned unexpected output)."
    echo $(( avail_kib / 1024 ))
}

# Maintainer-directed safety buffer (issue #1069): reserve more headroom for a
# larger requested cache. nginx's cache manager sweeps periodically rather
# than enforcing max_size instantaneously (manager_sleep/manager_threshold on
# proxy_cache_path), so actual disk usage can transiently overshoot max_size
# by roughly one sweep's worth of writes before cleanup catches up -- and a
# larger declared cache means more concurrent downloads can land in that
# window before the manager gets to them.
cache_size_buffer_mib() {
    local cache_gb="$1"
    if (( cache_gb > 6 )); then
        echo 2048
    elif (( cache_gb > 4 )); then
        echo 1024
    else
        echo 512
    fi
}

# True if requesting cache_gb GiB still leaves cache_size_buffer_mib's
# required buffer free on a filesystem with avail_mib MiB currently free.
cache_size_fits_available_mib() {
    local cache_gb="$1" avail_mib="$2" buffer_mib
    buffer_mib=$(cache_size_buffer_mib "$cache_gb")
    (( avail_mib - buffer_mib >= cache_gb * 1024 ))
}

# Largest whole-GiB cache size that currently passes
# cache_size_fits_available_mib, for the rejection message. Scans downward
# from the free-space ceiling rather than solving the step-function buffer
# bands in closed form: the buffer only grows as the requested size grows, so
# the scan is short (bounded by the disk's own size in GiB) and this stays
# obviously correct instead of clever. Prints 0 and returns failure if even a
# 1 GiB cache would not leave a buffer.
largest_valid_cache_gb() {
    local avail_mib="$1" candidate
    candidate=$(( avail_mib / 1024 ))
    while (( candidate >= 1 )); do
        if cache_size_fits_available_mib "$candidate" "$avail_mib"; then
            echo "$candidate"
            return 0
        fi
        candidate=$(( candidate - 1 ))
    done
    echo 0
    return 1
}

# Proxy-DHCP (dnsmasq) needs a subnet *base* address, not an arbitrary host IP,
# so it must be a valid IPv4 address ending in ".0".
is_dnsmasq_subnet_start() {
    local ip="$1"

    is_valid_ipv4 "$ip" && [[ "$ip" == *".0" ]]
}

# Issue #450: light shape validation for the optional dnsmasq relay/proxy
# fields, mirroring services/ui/src/routes/dhcp.rs's Rust-side validators of
# the same name/intent (is_valid_interface_name, is_valid_domain_name,
# is_valid_boot_filename) so a hand-edited .env fails just as closed as an
# Admin UI submission would. All three are optional -- callers only invoke
# them when the value is non-empty.
is_valid_dhcp_proxy_interface() {
    [[ "${1:-}" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

is_valid_dhcp_proxy_domain() {
    local domain="${1:-}"
    [[ -n "$domain" && "${#domain}" -le 253 ]] || return 1
    local label
    local -a labels
    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
}

is_valid_dhcp_proxy_boot_filename() {
    local filename="${1:-}"
    [[ -n "$filename" && "${#filename}" -le 255 ]] || return 1
    [[ "$filename" != *[[:space:],]* ]]
}

# Two-tier detection for a secondary node's own LAN IP: prefer the source
# address the kernel would actually use to reach the internet (most accurate
# on multi-homed hosts), then fall back to the first non-loopback,
# non-Docker-bridge (172.x) address if the route lookup fails or returns
# nothing usable.
detect_secondary_listen_ip() {
    local ip

    ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' \
        || true)
    if [[ -n "$ip" ]] && is_valid_ipv4 "$ip"; then
        printf '%s\n' "$ip"
        return 0
    fi

    ip=$(ip -4 addr show \
        | awk '/inet / && $2 !~ /^127\./ && $2 !~ /^172\./ { sub(/\/.*/, "", $2); print $2; exit }' \
        || true)
    if [[ -n "$ip" ]] && is_valid_ipv4 "$ip"; then
        printf '%s\n' "$ip"
        return 0
    fi

    return 1
}

# Cluster: detects and works around another process (e.g. systemd-resolved)
# already bound to port 53 on the chosen Secondary listen IP, since that would
# otherwise fail silently at container start rather than during setup.
secondary_listen_ip_conflicts() {
    local listen_ip="$1"

    ss -H -ltnup '( sport = :53 )' 2>/dev/null | awk -v ip="$listen_ip" '
        {
            local = $5
            sub(/:[0-9]+$/, "", local)
            if (ip == "0.0.0.0") {
                print
            } else if (local == ip || local == "0.0.0.0" || local == "*") {
                print
            }
        }
    '
}

# Finds a free bind IP for the secondary node when the requested one already
# has something listening on port 53. Tries the host's other real (non-loopback,
# non-Docker-bridge) addresses first, then falls back to the 127.0.0.2-.10
# loopback-alias range, since those can be bound independently on Linux.
secondary_suggest_alternate_listen_ip() {
    local current="$1" candidate

    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        [[ "$candidate" = "$current" ]] && continue
        [[ -z "$(secondary_listen_ip_conflicts "$candidate")" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done < <(
        ip -4 addr show \
            | awk '/inet / && $2 !~ /^127\./ && $2 !~ /^172\./ { sub(/\/.*/, "", $2); print $2 }'
    )

    for candidate in 127.0.0.1 127.0.0.2 127.0.0.3 127.0.0.4 127.0.0.5 127.0.0.6 127.0.0.7 127.0.0.8 127.0.0.9 127.0.0.10; do
        [[ "$candidate" = "$current" ]] && continue
        [[ -z "$(secondary_listen_ip_conflicts "$candidate")" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done

    return 1
}

# Interactive gate before starting the secondary node: reports what else is
# bound to port 53 on the chosen IP (via ss/fuser/lsof) and offers a suggested
# alternate. Requires an actual terminal to prompt, so it fails closed instead
# of looping forever when run non-interactively (e.g. from another script).
secondary_choose_listen_ip() {
    local listen_ip="$1" conflicts suggestion

    while true; do
        conflicts="$(secondary_listen_ip_conflicts "$listen_ip")"
        if [[ -z "$conflicts" ]]; then
            printf '%s\n' "$listen_ip"
            return 0
        fi

        print_warn "Port 53 is already in use for bind IP ${listen_ip}."
        {
            printf '%s\n' "$conflicts" | sed 's/^/    /'
            if command -v fuser >/dev/null 2>&1; then
                fuser -v 53/tcp 53/udp 2>&1 | sed 's/^/    /' || true
            fi
            if command -v lsof >/dev/null 2>&1; then
                lsof -nP -iTCP:53 -iUDP:53 -sTCP:LISTEN 2>/dev/null | sed 's/^/    /' || true
            fi
        } >&2

        if ! [[ -t 0 && -t 1 ]]; then
            return 1
        fi

        suggestion="$(secondary_suggest_alternate_listen_ip "$listen_ip" || true)"
        ask "Use another Secondary bind IP" "${suggestion:-$listen_ip}"
        listen_ip="$REPLY"
        is_valid_ipv4 "$listen_ip" \
            || { print_error "Invalid IPv4 address: $listen_ip"; continue; }
    done
}

# Validates a full IPv4 CIDR (address + /prefix), octet-by-octet and with the
# prefix length bounded to 1-32, before it is written into DHCP subnet config.
is_valid_cidr() {
    local cidr="$1" ip mask octets

    if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        return 1
    fi

    ip=${cidr%/*}
    mask=${cidr#*/}

    [[ "$mask" =~ ^[0-9]+$ ]] || return 1
    (( mask >= 1 && mask <= 32 )) || return 1

    IFS='.' read -r -a octets <<< "$ip"
    for part in "${octets[@]}"; do
        [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1
        (( part >= 0 && part <= 255 )) || return 1
    done

    return 0
}

# Enumerates the only three DHCP_MODE values setup.sh understands: DHCP off,
# our own Kea server, or dnsmasq acting as a proxy-DHCP helper for PXE.
is_valid_dhcp_mode() {
    case "$1" in
        disabled|kea|dnsmasq-proxy) return 0 ;;
        *) return 1 ;;
    esac
}

# Validates UI_SESSION_TTL_SECONDS is a positive integer no greater than
# MAX_UI_SESSION_TTL_SECONDS (1 year), so a malformed or absurd .env value
# cannot produce a session cookie that never expires.
validate_ui_session_ttl_seconds() {
    local value="$1" source="${2:-UI_SESSION_TTL_SECONDS}" numeric max

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        die "UI_SESSION_TTL_SECONDS in ${source} must be an unsigned integer number of seconds."
    fi
    # Strip leading zeros before the numeric comparisons below: bash arithmetic
    # treats a leading-zero literal (e.g. "010") as octal, which would silently
    # misparse or reject an otherwise valid decimal value.
    numeric="${value#"${value%%[!0]*}"}"
    numeric="${numeric:-0}"
    if [[ "$numeric" = "0" ]]; then
        die "UI_SESSION_TTL_SECONDS in ${source} must be greater than zero."
    fi
    max="$MAX_UI_SESSION_TTL_SECONDS"
    if (( ${#numeric} > ${#max} )) || { (( ${#numeric} == ${#max} )) && (( 10#$numeric > 10#$max )); }; then
        die "UI_SESSION_TTL_SECONDS in ${source} must be at most ${MAX_UI_SESSION_TTL_SECONDS} seconds (1 year)."
    fi
}

# Centralize runtime profile calculation so install and update cannot drift:
# SSL, Kea DHCP, and dnsmasq proxy mode are represented once in COMPOSE_PROFILES
# while unrelated profiles are preserved.
compose_profiles_for_runtime() {
    local existing="${1:-}" ssl_enabled="${2:-0}" dhcp_mode="${3:-disabled}"
    local profile result="" trimmed

    IFS=',' read -r -a profiles <<< "$existing"
    for profile in "${profiles[@]}"; do
        trimmed="${profile#"${profile%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        case "$trimmed" in
            ""|ssl|dhcp-kea|dhcp-proxy) continue ;;
        esac
        case ",$result," in
            *",$trimmed,"*) ;;
            *) [[ -n "$result" ]] && result+=","; result+="$trimmed" ;;
        esac
    done

    if [[ "$ssl_enabled" = "1" ]]; then
        case ",$result," in
            *,ssl,*) ;;
            *) [[ -n "$result" ]] && result+=","; result+="ssl" ;;
        esac
    fi

    case "$dhcp_mode" in
        kea)
            [[ -n "$result" ]] && result+=","
            result+="dhcp-kea"
            ;;
        dnsmasq-proxy)
            [[ -n "$result" ]] && result+=","
            result+="dhcp-proxy"
            ;;
    esac

    printf '%s\n' "$result"
}

# Wraps ask() into a yes/no boolean prompt (accepts "y" or "yes", case-insensitive).
confirm() {
    local prompt="$1" default="${2:-N}"
    ask "$prompt" "$default"
    [[ "${REPLY,,}" = "y" || "${REPLY,,}" = "yes" ]]
}

# The Kea path must stay discovery-first: run a non-invasive broadcast probe
# before the stack is activated so we can stop or warn before becoming a
# second active DHCP server on the LAN.
run_kea_dhcp_activation_preflight() {
    local env_file="$1" output server_identifier=""

    [[ "$DHCP_MODE" = "kea" ]] || return 0

    print_step "DHCP activation preflight"
    printf "  Discovery-only check: the Kea image will run nmap and exit without starting Kea.\n"

    # No -e/--interface flag: nmap has no "any" pseudo-interface (confirmed
    # directly -- "I cannot figure out what source address to use for
    # device any, does it even exist?"), so passing one made this probe
    # fail its own execution on every single run, unconditionally forcing
    # the "could not be executed" confirmation path below regardless of
    # whether a real conflict existed. Letting nmap auto-select the
    # interface (no -e at all) matches the already-proven working
    # invocation in services/ui/dhcp-probe.sh.
    if ! output=$(docker compose --env-file "$env_file" -f "$QUICKSTART_COMPOSE" --profile dhcp-kea run --rm --no-deps dhcp \
        nmap --script broadcast-dhcp-discover --script-args broadcast-dhcp-discover.timeout=5 2>&1); then
        print_warn "DHCP discovery preflight could not be executed inside the Kea image."
        print_warn "Kea activation will require an explicit confirmation because the safety check did not complete."
        confirm "Continue with Kea activation anyway? [y/N]" "N" \
            || die "Cancelled DHCP activation."
        return 0
    fi

    # Matches services/ui/dhcp-probe.sh's already-proven parsing: anchor at
    # the start of the line (after stripping nmap's leading |/_ prefixes and
    # whitespace) instead of a bare substring match, and take the first
    # match rather than assuming there is exactly one.
    server_identifier="$(printf '%s\n' "$output" | sed -n 's/^[|_[:space:]]*Server Identifier:[[:space:]]*//p' | sed -n '1p')"

    if [[ -n "$server_identifier" ]]; then
        print_warn "An existing DHCP server answered before Kea activation: $server_identifier"
        print_warn "Kea would become a second active DHCP server if you continue."
        confirm "Continue with Kea activation anyway? [y/N]" "N" \
            || die "Cancelled DHCP activation."
    else
        print_ok "No DHCP server answer was detected before Kea activation."
    fi
}

# Installs the given packages via whichever supported package manager is
# present (apt/dnf/yum/pacman), after an explicit operator confirmation since
# this mutates the host outside setup.sh's own config. Fails closed if no
# supported package manager is found rather than guessing a command.
install_packages() {
    local reason="$1"
    shift
    local packages=("$@")

    print_warn "$reason"
    printf "  Required packages: %s\n" "${packages[*]}"
    if ! confirm "Install these packages now? [y/N]" "N"; then
        die "Aborted. Please install these packages manually, then rerun setup.sh: ${packages[*]}"
    fi

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y \
            && apt-get install -y --no-install-recommends "${packages[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${packages[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${packages[@]}"
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Syu --noconfirm "${packages[@]}"
    else
        die "No supported package manager found. Please install these packages manually, then rerun setup.sh: ${packages[*]}"
    fi
}

# Package installation is intentionally interactive because setup.sh mutates the
# host. Missing prerequisites are offered to DAU users, but unsupported package
# managers fail closed instead of guessing.
install_required_command() {
    local command_name="$1" reason="$2"
    shift 2

    install_packages "$reason" "$@" \
        || die "Failed to install required package(s): $*"

    command -v "$command_name" >/dev/null 2>&1 \
        || die "$command_name is still missing after installing package(s): $*"
}

# Thin named wrappers around install_required_command so call sites read as
# "install_curl" / "install_git" rather than a repeated three-argument call.
install_curl() {
    install_required_command curl "curl is missing." curl
}

install_git() {
    install_required_command git "git is missing." git
}

# True if apt's package index has any candidate version for the named package
# (does not check whether it is already installed).
apt_package_available() {
    apt-cache show "$1" >/dev/null 2>&1
}

# Reads the version apt would install for a package right now, without
# installing anything, so callers can branch on version before committing.
apt_package_candidate_version() {
    apt-cache policy "$1" 2>/dev/null \
        | awk '/^[[:space:]]*Candidate:/ {print $2; exit}'
}

# Some distro apt indexes reuse the legacy "docker-compose" package name for
# Compose v2 (see apt_compose_package below); this checks the candidate
# version's leading digit to tell v2 apart from the old Python-based v1.
apt_docker_compose_is_v2() {
    local version=""

    version=$(apt_package_candidate_version docker-compose)
    [[ "$version" =~ ^2[.:-] ]]
}

# Picks the best available Compose v2 package name for this apt index, in
# preference order, since its name varies across Debian/Ubuntu releases.
apt_compose_package() {
    if apt_package_available docker-compose-plugin; then
        printf '%s\n' docker-compose-plugin
    elif apt_package_available docker-compose-v2; then
        printf '%s\n' docker-compose-v2
    elif apt_package_available docker-compose && apt_docker_compose_is_v2; then
        # Debian Trixie packages Compose v2 under the historical docker-compose
        # package name while still providing the `docker compose` CLI plugin.
        printf '%s\n' docker-compose
    else
        return 1
    fi
}

# Picks the best available Buildx plugin package name for this apt index, same
# preference-order pattern as apt_compose_package: Docker's own apt repo names
# it docker-buildx-plugin, while Debian's/Ubuntu's native repos package the
# same CLI plugin as docker-buildx. Returns non-zero (not a die()) when
# neither is available so callers can treat provisioning it as best-effort --
# assert_resolved_image_tag_platform_supported (#665) still fails closed later
# with its own actionable "install docker-buildx-plugin" message if Buildx
# ends up missing regardless.
apt_buildx_package() {
    if apt_package_available docker-buildx-plugin; then
        printf '%s\n' docker-buildx-plugin
    elif apt_package_available docker-buildx; then
        printf '%s\n' docker-buildx
    else
        return 1
    fi
}

# Docker bootstrap is a first-install convenience, not a build environment
# contract. Changes here affect production setup directly and must stay separate
# from future dev-mode/compiler-farm decisions.
verify_docker_installation() {
    command -v docker >/dev/null 2>&1 \
        || die "Docker client binary is missing after installation."

    docker compose version >/dev/null 2>&1 \
        || die "Docker Compose v2 is missing after installation."
}

# Debian Trixie's docker.io package no longer ships /usr/bin/docker itself;
# the client lives in the separate docker-cli package. Install it only when
# docker is still missing after docker.io, to stay a no-op on older distros
# where docker.io already provides the client.
ensure_apt_docker_client() {
    if command -v docker >/dev/null 2>&1; then
        return 0
    fi

    if apt_package_available docker-cli; then
        print_warn "docker.io did not provide /usr/bin/docker; installing docker-cli for the Docker client."
        apt-get install -y --no-install-recommends docker-cli
    fi

    command -v docker >/dev/null 2>&1 \
        || die "Docker client binary is missing after installation. Install docker-cli or docker-ce-cli manually, then rerun setup.sh."
}

# Fallback for when the distro's own apt index has no Compose v2 package at
# all: adds Docker's official apt repository (GPG key + sources list) so a
# supported package becomes available, then refreshes the index.
install_docker_apt_repo() {
    local os_id="" codename="" repo_file=""

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-}"
        codename="${VERSION_CODENAME:-}"
    fi

    case "$os_id" in
        debian|ubuntu) ;;
        *)
            die "Docker's apt repository is only configured automatically on Debian and Ubuntu. Please install Docker and Docker Compose manually, then rerun setup.sh."
            ;;
    esac

    if [[ -z "$codename" ]]; then
        codename=$(lsb_release -cs 2>/dev/null || true)
    fi
    [[ -n "$codename" ]] \
        || die "Could not determine the apt distribution codename. Please install Docker and Docker Compose manually, then rerun setup.sh."

    repo_file="/etc/apt/sources.list.d/docker.list"
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
        "$(dpkg --print-architecture)" "$os_id" "$codename" > "$repo_file"
    apt-get update -y
}

# Installs Docker + Compose v2 on Debian/Ubuntu. Prefers the distro's own
# packages; only adds Docker's apt repo (install_docker_apt_repo) if the distro
# index has no Compose v2 package. Uses the lighter docker.io + ensure_apt_docker_client
# path when possible instead of always pulling in Docker's own docker-ce group.
install_docker_apt() {
    local compose_package="" buildx_package=""
    local -a docker_packages=()

    apt-get update -y
    if ! compose_package=$(apt_compose_package); then
        print_warn "No Compose v2 package was found in the configured apt repositories. Adding Docker's official apt repository."
        install_docker_apt_repo
        compose_package=$(apt_compose_package) \
            || die "No Docker Compose v2 package found. Please install Docker and the Docker Compose plugin manually, then rerun setup.sh."
    fi

    # assert_resolved_image_tag_platform_supported (#665) hard-requires
    # `docker buildx` before the first pull. Install it alongside Docker/Compose
    # here so that check does not immediately abort a fresh install right after
    # setup.sh finished installing its own prerequisites -- best-effort only:
    # if this apt index has neither buildx package name, skip it and let the
    # later platform check fail closed with its own actionable message instead
    # of failing this whole Docker install over an unrelated package gap.
    buildx_package=$(apt_buildx_package) || buildx_package=""

    if [[ "$compose_package" = docker-compose-plugin ]]; then
        docker_packages=(docker-ce docker-ce-cli containerd.io "$compose_package")
        [[ -n "$buildx_package" ]] && docker_packages+=("$buildx_package")
        apt-get install -y --no-install-recommends "${docker_packages[@]}"
    else
        docker_packages=(docker.io "$compose_package")
        [[ -n "$buildx_package" ]] && docker_packages+=("$buildx_package")
        apt-get install -y --no-install-recommends "${docker_packages[@]}"
        # Debian Trixie splits the Docker client into docker-cli, so install it
        # only when docker.io did not already provide /usr/bin/docker.
        ensure_apt_docker_client
    fi

    verify_docker_installation
}

# Same fallback logic as install_docker_apt, but for the case where Docker
# itself is already installed and only the Compose v2 plugin is missing.
install_docker_compose_apt() {
    local compose_package=""

    apt-get update -y
    if ! compose_package=$(apt_compose_package); then
        print_warn "No Compose v2 package was found in the configured apt repositories. Adding Docker's official apt repository."
        install_docker_apt_repo
        compose_package=$(apt_compose_package) \
            || die "No Docker Compose v2 package found. Please install the Docker Compose plugin manually, then rerun setup.sh."
    fi

    apt-get install -y --no-install-recommends "$compose_package"
    verify_docker_installation
}

# Filters an arbitrary package name list down to just the ones actually
# installed, via rpm -q, for use as a generic conflict-detection building block.
rpm_installed_package_list() {
    local package

    for package in "$@"; do
        rpm -q "$package" >/dev/null 2>&1 && printf '%s\n' "$package"
    done
}

# Lists the historical Docker Inc./distro-provided package names that conflict
# with Docker CE's own RPM packages, so they can be surfaced before installing
# and the operator is told what to remove instead of hitting an opaque rpm error.
rpm_legacy_docker_package_list() {
    rpm_installed_package_list \
        docker \
        docker-client \
        docker-client-latest \
        docker-common \
        docker-latest \
        docker-latest-logrotate \
        docker-logrotate \
        docker-selinux \
        docker-engine-selinux \
        docker-engine
}

# Returns every installed package that would block a clean Docker CE RPM
# install, using OS-specific rules (see the branch comments below) since
# Fedora and RHEL-family hosts have different podman/runc conflict policies.
rpm_conflicting_docker_packages() {
    local os_id=""

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-}"
    fi

    if [[ "$os_id" = fedora ]]; then
        # Fedora's supported Docker install path only requires removing
        # Docker-family packages. Stock podman/runc must remain allowed.
        rpm_installed_package_list podman-docker
        rpm_legacy_docker_package_list
    else
        # RHEL-family Docker packages additionally conflict with stock
        # podman/runc, so fail before mutating repository configuration.
        rpm_legacy_docker_package_list
        rpm_installed_package_list \
            podman \
            runc
    fi
}

# Fails closed with a concrete remediation command (dnf remove ...) instead of
# letting rpm/dnf hit the conflict mid-install and leave the host half-configured.
guard_rpm_docker_conflicts() {
    local package
    local -a conflicts=()

    while IFS= read -r package; do
        [[ -n "$package" ]] && conflicts+=("$package")
    done < <(rpm_conflicting_docker_packages)

    (( ${#conflicts[@]} == 0 )) && return 0

    die "Docker's RPM packages conflict with these installed packages: ${conflicts[*]}. Remove them first (for example: dnf remove ${conflicts[*]}), then rerun setup.sh."
}

# Docker publishes separate yum/dnf repo files per RHEL-family distro; picks
# the matching one by /etc/os-release ID, defaulting to the CentOS repo for
# other RHEL derivatives that aren't Fedora or RHEL itself.
docker_rpm_repo_url() {
    local os_id=""

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-}"
    fi

    if [[ "$os_id" = fedora ]]; then
        printf '%s\n' "https://download.docker.com/linux/fedora/docker-ce.repo"
    elif [[ "$os_id" = rhel ]]; then
        printf '%s\n' "https://download.docker.com/linux/rhel/docker-ce.repo"
    else
        printf '%s\n' "https://download.docker.com/linux/centos/docker-ce.repo"
    fi
}

# Installs Docker (or just its Compose plugin) on dnf/yum systems by adding
# Docker's own repo and installing the given packages (defaulting to the full
# docker-ce set). Only runs the podman/runc conflict guard when an actual
# Docker engine package is being installed, so a compose-plugin-only install
# is not blocked by an unrelated podman conflict rule.
install_docker_rpm() {
    local manager="$1"
    shift
    local repo_url needs_engine=0 package
    local packages=("$@")

    if (( ${#packages[@]} == 0 )); then
        # docker-buildx-plugin is included here (not just docker-compose-plugin)
        # so a fresh full Docker install already satisfies
        # assert_resolved_image_tag_platform_supported's (#665) `docker buildx`
        # requirement -- this repo_url is always Docker's own official repo
        # (see docker_rpm_repo_url above), which publishes docker-buildx-plugin
        # directly, unlike the apt path where it must be probed for (see
        # apt_buildx_package).
        packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
    fi

    for package in "${packages[@]}"; do
        case "$package" in
            docker-ce|docker-ce-cli|containerd.io|docker-buildx-plugin|docker-compose-plugin)
                needs_engine=1
                break
                ;;
        esac
    done
    if (( needs_engine )); then
        guard_rpm_docker_conflicts
    fi

    repo_url=$(docker_rpm_repo_url)
    if [[ "$manager" = dnf ]]; then
        dnf install -y dnf-plugins-core
        dnf config-manager --add-repo "$repo_url" \
            || dnf config-manager addrepo --from-repofile="$repo_url"
        dnf install -y "${packages[@]}"
    else
        yum install -y yum-utils
        yum-config-manager --add-repo "$repo_url"
        yum install -y "${packages[@]}"
    fi

    verify_docker_installation
}

# Interactive installer for the Compose v2 plugin only (Docker engine already
# present). Dispatches to the right package manager, each with its own
# operator confirmation before mutating the host.
install_docker_compose() {
    local packages=()

    if command -v apt-get >/dev/null 2>&1; then
        print_warn "Docker Compose plugin missing."
        printf "  Required package: an available Compose v2 package (docker-compose-plugin, docker-compose-v2, or docker-compose)\n"
        if ! confirm "Install this package now? [y/N]" "N"; then
            die "Aborted. Please install a Docker Compose v2 package manually, then rerun setup.sh."
        fi
        install_docker_compose_apt || die "Failed to install Docker Compose."
    elif command -v dnf >/dev/null 2>&1; then
        packages=(docker-compose-plugin)
        print_warn "Docker Compose plugin missing."
        printf "  Required packages: %s\n" "${packages[*]}"
        printf "  Docker's RPM repository will be configured before installation.\n"
        if ! confirm "Install this package now? [y/N]" "N"; then
            die "Aborted. Please install Docker Compose from Docker's RPM repository manually, then rerun setup.sh: ${packages[*]}"
        fi
        install_docker_rpm dnf "${packages[@]}" || die "Failed to install Docker Compose."
    elif command -v yum >/dev/null 2>&1; then
        packages=(docker-compose-plugin)
        print_warn "Docker Compose plugin missing."
        printf "  Required packages: %s\n" "${packages[*]}"
        printf "  Docker's RPM repository will be configured before installation.\n"
        if ! confirm "Install this package now? [y/N]" "N"; then
            die "Aborted. Please install Docker Compose from Docker's RPM repository manually, then rerun setup.sh: ${packages[*]}"
        fi
        install_docker_rpm yum "${packages[@]}" || die "Failed to install Docker Compose."
    elif command -v pacman >/dev/null 2>&1; then
        packages=(docker-compose)
        install_packages "Docker Compose plugin missing." "${packages[@]}" \
            || die "Failed to install Docker Compose."
    else
        die "No supported package manager found. Please install the Docker Compose plugin manually, then rerun setup.sh."
    fi
}

# Interactive installer for Docker engine + Compose v2 together, dispatching to
# the right package manager with its own confirmation prompt and package set.
install_docker() {
    local packages=()

    if command -v apt-get >/dev/null 2>&1; then
        print_warn "Docker is missing."
        printf "  Required packages: docker.io, an available Compose v2 package (docker-compose-plugin, docker-compose-v2, or docker-compose), and Buildx (docker-buildx-plugin or docker-buildx) when this apt index has one\n"
        if ! confirm "Install these packages now? [y/N]" "N"; then
            die "Aborted. Please install Docker and a Docker Compose v2 package manually, then rerun setup.sh."
        fi
        install_docker_apt || die "Failed to install Docker."
    elif command -v dnf >/dev/null 2>&1; then
        packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
        print_warn "Docker is missing."
        printf "  Required packages: %s\n" "${packages[*]}"
        printf "  Docker's RPM repository will be configured before installation.\n"
        if ! confirm "Install these packages now? [y/N]" "N"; then
            die "Aborted. Please install Docker from Docker's RPM repository manually, then rerun setup.sh: ${packages[*]}"
        fi
        install_docker_rpm dnf || die "Failed to install Docker."
    elif command -v yum >/dev/null 2>&1; then
        packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
        print_warn "Docker is missing."
        printf "  Required packages: %s\n" "${packages[*]}"
        printf "  Docker's RPM repository will be configured before installation.\n"
        if ! confirm "Install these packages now? [y/N]" "N"; then
            die "Aborted. Please install Docker from Docker's RPM repository manually, then rerun setup.sh: ${packages[*]}"
        fi
        install_docker_rpm yum || die "Failed to install Docker."
    elif command -v pacman >/dev/null 2>&1; then
        packages=(docker docker-compose docker-buildx)
        install_packages "Docker is missing." "${packages[@]}" \
            || die "Failed to install Docker."
    else
        die "No supported package manager found. Please install Docker and the Docker Compose plugin manually, then rerun setup.sh."
    fi
}

# Approximates Docker Compose's own .env value semantics for a value read back
# out of an existing file: strips a fully single- or double-quoted value's
# surrounding quotes, and drops an unquoted inline comment (a '#' preceded by
# whitespace). Without this, migrating an older but valid Compose value (e.g.
# `CACHE_DIR=/srv/lancache # nvme` or `CACHE_DIR="/srv/lancache cache"`) into
# validate_env_value() would reject it for characters Compose itself parses
# away.
_compose_parse_env_value() {
    local value="$1" rest

    # Trim leading whitespace before checking for a quote so a value like
    # ` "foo"` is still recognized as quoted.
    value="${value#"${value%%[![:space:]]*}"}"

    if [[ "$value" == \"* ]]; then
        # Take everything up to the FIRST closing quote, not the end of the
        # string — a trailing inline comment like `"foo" # bar` is valid
        # Compose syntax and must not be treated as part of the value.
        rest="${value#\"}"
        value="${rest%%\"*}"
    elif [[ "$value" == \'* ]]; then
        rest="${value#\'}"
        value="${rest%%\'*}"
    else
        value="${value%%[[:space:]]\#*}"
        value="${value%"${value##*[![:space:]]}"}"
    fi

    printf '%s' "$value"
}

# Reads the FIRST assignment of a key from a .env file and returns its parsed
# (unquoted, comment-stripped) value, regardless of whether it is empty.
get_env_var() {
    local raw
    raw=$(awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$2" 2>/dev/null) || true
    _compose_parse_env_value "$raw"
}

# Unlike get_env_var, scans ALL assignments of a key top-to-bottom and returns
# the parsed value of the first NON-EMPTY one. This matters for migrated .env
# files that can end up with an earlier empty placeholder line followed by a
# later real value for the same key.
get_env_var_nonempty() {
    local key="$1" env_file="$2" raw value
    while IFS= read -r raw; do
        value=$(_compose_parse_env_value "$raw")
        if [[ -n "$value" ]]; then
            printf '%s' "$value"
            return 0
        fi
    done < <(awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print}' "$env_file" 2>/dev/null)
}

# Like get_env_var, but returns the RAW (unparsed) assignment text of the first
# match instead of the parsed value, so callers that need to preserve quoting
# or ${VAR} interpolation verbatim can copy it unchanged.
get_env_assignment_value_raw() {
    awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$2" 2>/dev/null || true
}

# Combines the two behaviors above: scans for the first assignment whose
# parsed value is non-empty, but returns that match's RAW text so migration
# helpers can carry over interpolation/quoting intact.
get_env_assignment_value_raw_nonempty() {
    local key="$1" env_file="$2" raw value
    while IFS= read -r raw; do
        value=$(_compose_parse_env_value "$raw")
        if [[ -n "$value" ]]; then
            printf '%s' "$raw"
            return 0
        fi
    done < <(awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print}' "$env_file" 2>/dev/null)
}

# .env helpers stay in setup.sh because this script owns install, update, and
# migration behavior for curl | bash users.
env_key_exists() {
    local key="$1" env_file="$2"
    grep -q "^${key}=" "$env_file" 2>/dev/null
}

# True if the key exists in the .env file with a non-empty parsed value.
env_key_has_value() {
    local key="$1" env_file="$2" value
    value=$(get_env_var "$key" "$env_file")
    [[ -n "$value" ]]
}

# Recognizes placeholder-style secret values (empty, CHANGE_ME_*, YOUR_*_HERE,
# changeme*, or the old lancache-*-secret template default) so setup.sh can
# tell "operator has not configured a real secret yet" apart from "operator
# configured this on purpose" and knows when it must generate a real value
# instead of trusting the placeholder as configured.
#
# Matching is case-insensitive and treats "-"/"_" as equivalent (issue #967:
# e.g. "change-me", "CHANGE_ME", and "Change-Me" are all recognized) --
# normalize first, then match against lowercase/underscore patterns. This is a
# deliberate fail-safe widening: it can only make MORE values match as a
# placeholder, never fewer, so a real randomly-generated hex/base64 secret is
# not realistically affected.
#
# This is one of three independently-maintained placeholder detectors in this
# repo (the others: scripts/lib/shared-secret-bootstrap.sh's
# secret_is_placeholder, embedded into the dns/dhcp/ui entrypoints, and
# services/ui/src/main.rs's secondary_registration_token_is_placeholder), kept
# deliberately separate per the maintainer decision recorded in issue #967
# (Option B: cross-validate, don't unify) rather than sourcing the shared
# library directly. Divergences from the shared library, confirmed via
# tests/fixtures/placeholder-detection-cases.txt and
# tests/bats/placeholder_detection_parity.bats:
#   - This write path additionally recognizes the legacy "lancache-*-secret"
#     template-default shape and a bare "change-me"/"change_me" infix. This
#     IS deliberate: setup.sh must never mistake a stale template default for
#     a real secret it should preserve, unlike the shared library's read path
#     (see that function's own comment for why it omits both).
#   - This write path requires a full YOUR_*_HERE suffix match, and does not
#     have the shared library's generic *_HERE-on-any-value rule, both
#     narrower than the shared library. Pre-existing, not reconciled here
#     (#967 Option B keeps the pattern sets separate); no shipped placeholder
#     in this repo actually needs either bare form, so the gap has not
#     mattered in practice, but it is a real, confirmed divergence, not an
#     intentional design choice.
secret_value_is_placeholder() {
    local value="$1"
    local normalized="${value,,}"
    normalized="${normalized//-/_}"
    case "$normalized" in
        ""|change_me_*|your_*_here|changeme*|*change_me*|lancache_*_secret)
            return 0
            ;;
    esac
    return 1
}

# True only if the key holds a real, usable secret — i.e. it has a value and
# that value is not one of the known placeholder patterns above. Used to gate
# secret generation so setup.sh never overwrites an operator's real secret but
# always replaces a placeholder.
env_key_has_usable_secret() {
    local key="$1" env_file="$2" value
    value=$(get_env_var "$key" "$env_file")
    ! secret_value_is_placeholder "$value"
}

# Secret generation must fail closed. setup.sh must never write empty secrets
# after a missing openssl binary, broken RNG, or interrupted generator command.
generate_secret_value() {
    local name="$1" kind="$2" value chunk

    case "$kind" in
        hex32)
            value=$(openssl rand -hex 32) \
                || die "Failed to generate $name with openssl."
            ;;
        base64_32)
            value=$(openssl rand -base64 32) \
                || die "Failed to generate $name with openssl."
            value="${value//$'\n'/}"
            ;;
        alnum20)
            value=""
            while (( ${#value} < 20 )); do
                chunk=$(openssl rand -base64 32) \
                    || die "Failed to generate $name with openssl."
                chunk="${chunk//[^A-Za-z0-9]/}"
                value+="$chunk"
            done
            value="${value:0:20}"
            ;;
        *)
            die "Unknown secret generator for $name: $kind"
            ;;
    esac

    [[ -n "$value" ]] || die "Generated empty secret for $name."
    printf '%s\n' "$value"
}

# Keep real existing secrets, but replace empty values and known placeholders.
get_or_generate_secret() {
    local key="$1" env_file="$2" kind="$3"

    if env_key_has_usable_secret "$key" "$env_file"; then
        get_env_var "$key" "$env_file"
    else
        generate_secret_value "$key" "$kind"
    fi
}

# validate_env_value — Guard against .env value characters that could break parsing.
#
# Docker Compose's .env reader is strict: unquoted values with spaces, special
# characters, or problematic punctuation can silently change their semantics or
# be interpreted as directive markers (# for comments, $ for substitution, etc.).
# This function rejects values that contain unescapable characters rather than
# trying to quote/escape them, to minimize diff and maintain confidence that
# output values will parse identically to the original unquoted form.
#
# Safe characters: empty string, alphanumeric, spaces, common separators and URLs:
#   . : - _ / + = ,
# Unsafe characters (REJECTED): newline, $, backtick, double-quote, single-quote,
#   backslash, hash (comment marker), and other shell metacharacters.
#
# Exit 0 if safe; die with message if unsafe.
validate_env_value() {
    local key="$1" value="$2"

    # Empty values are allowed (e.g., IP_SSL="", DHCP_SUBNET="").
    [[ -z "$value" ]] && return 0

    # Use case pattern matching to detect forbidden characters.
    # Reject if the value contains any of: newline, $, `, ", ', \, #
    case "$value" in
        *$'\n'* | *'$'* | *'`'* | *'"'* | *"'"* | *'\'* | *'#'* )
            die "$key contains unsafe characters for .env. Cannot proceed. Value: $value"
            ;;
    esac

    return 0
}

# Runs validate_env_value over every KEY=VALUE pair before the first-install
# .env heredoc is written (see comment inside for why that heredoc specifically
# needs this pre-check).
validate_env_values_for_initial_write() {
    local key value pair

    # The first-install .env writer below is a heredoc with unquoted
    # substitutions. Validate every interpolated value before opening the file
    # so unsafe characters cannot change Compose .env parsing semantics.
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        validate_env_value "$key" "$value"
    done
}

# Sets KEY=VALUE in the .env file, validating the value's characters first.
# If the key already has one or more assignments, the awk pass rewrites only
# the first occurrence and drops any later duplicate lines for the same key,
# so the file always converges on a single canonical assignment per key.
set_env_key() {
    local key="$1" value="$2" env_file="$3"
    validate_env_value "$key" "$value"
    if env_key_exists "$key" "$env_file"; then
        awk -F= -v key="$key" -v value="$value" '
            $1 == key {
                if (!seen) {
                    print key "=" value
                    seen=1
                }
                next
            }
            { print }
        ' "$env_file" | write_env_file "$env_file"
    else
        # Explicit die() instead of relying on `set -e`: a caller running this
        # inside a subshell whose own exit status is being tested (e.g.
        # `if ! ( fn1 && fn2 )`) sits in a bash context where errexit is
        # silently ignored for everything inside that subshell, so a bare
        # failed append here would otherwise go unnoticed instead of aborting.
        printf '%s=%s\n' "$key" "$value" >> "$env_file" \
            || die "Failed to append $key to $env_file."
    fi
}

# Like set_env_key, but writes a raw assignment value verbatim (only rejecting
# embedded newlines) instead of running it through validate_env_value's strict
# character check. Used to carry over an existing raw .env assignment — which
# may legitimately contain ${VAR} interpolation — without re-validating
# characters that Compose itself already parses safely.
set_env_assignment() {
    local key="$1" assignment_value="$2" env_file="$3"
    case "$key" in
        ""|*[!A-Za-z0-9_]*|[0-9]*)
            die "Invalid .env key: $key"
            ;;
    esac
    case "$assignment_value" in
        *$'\n'*)
            die "$key contains a newline and cannot be copied into .env."
            ;;
    esac

    if env_key_exists "$key" "$env_file"; then
        awk -F= -v key="$key" -v value="$assignment_value" '
            $1 == key {
                if (!seen) {
                    print key "=" value
                    seen=1
                }
                next
            }
            { print }
        ' "$env_file" | write_env_file "$env_file"
    else
        # See set_env_key's matching comment: explicit die() so a failure
        # here is never silently swallowed by a tested-subshell errexit gap.
        printf '%s=%s\n' "$key" "$assignment_value" >> "$env_file" \
            || die "Failed to append $key to $env_file."
    fi
}

# Adds KEY=VALUE only if the key is completely absent; never touches an
# existing assignment, even if it is empty (see comment inside).
append_env_key_if_missing() {
    local key="$1" value="$2" env_file="$3"
    validate_env_value "$key" "$value"
    # Preserve intentional empty placeholders; only add the key when it is
    # absent. Explicit die() (see set_env_key's matching comment) instead of
    # relying on `set -e` alone.
    env_key_exists "$key" "$env_file" \
        || printf '%s=%s\n' "$key" "$value" >> "$env_file" \
        || die "Failed to append $key to $env_file."
}

# Fills in a default only when the key is missing or its current value is
# empty; a non-empty existing assignment (even raw/interpolated) is kept as-is.
set_env_key_if_empty_or_missing() {
    local key="$1" value="$2" env_file="$3" existing_assignment
    validate_env_value "$key" "$value"
    if env_key_exists "$key" "$env_file"; then
        # Keep an operator's existing non-empty assignment verbatim so Compose
        # interpolation and other already-valid raw values survive update.
        existing_assignment=$(get_env_assignment_value_raw_nonempty "$key" "$env_file")
        if [[ -n "$existing_assignment" ]]; then
            set_env_assignment "$key" "$existing_assignment" "$env_file"
        else
            set_env_key "$key" "$value" "$env_file"
        fi
    else
        # See set_env_key's matching comment: explicit die() so a failure
        # here is never silently swallowed by a tested-subshell errexit gap.
        printf '%s=%s\n' "$key" "$value" >> "$env_file" \
            || die "Failed to append $key to $env_file."
    fi
}

# Like append_env_key_if_missing, but for a raw assignment (see set_env_assignment).
append_env_assignment_if_missing() {
    local key="$1" assignment_value="$2" env_file="$3"
    case "$key" in
        ""|*[!A-Za-z0-9_]*|[0-9]*)
            die "Invalid .env key: $key"
            ;;
    esac
    case "$assignment_value" in
        *$'\n'*)
            die "$key contains a newline and cannot be copied into .env."
            ;;
    esac
    # Migration-only helper: duplicate an existing Compose .env assignment
    # without destroying supported interpolation such as ${LAN_CACHE_ROOT:-...}.
    # Explicit die() (see set_env_key's matching comment) instead of relying
    # on `set -e` alone.
    env_key_exists "$key" "$env_file" \
        || printf '%s=%s\n' "$key" "$assignment_value" >> "$env_file" \
        || die "Failed to append $key to $env_file."
}

# Migrates an optional key from an old name (source_key) to a new one
# (target_key), or seeds fallback_value if there is nothing to migrate. Used
# for renamed .env keys where an empty target value is a valid, intentional
# state (see comment inside).
append_env_migrated_assignment_if_missing() {
    local target_key="$1" source_key="$2" fallback_value="$3" env_file="$4"
    local source_assignment

    # Preserve intentionally empty optional targets. UI_BIND_IP=, for example,
    # deliberately keeps Compose's ${UI_BIND_IP:-${IP_STANDARD}} fallback alive.
    if env_key_exists "$target_key" "$env_file"; then
        return 0
    fi

    source_assignment=$(get_env_assignment_value_raw_nonempty "$source_key" "$env_file")
    if [[ -n "$source_assignment" ]]; then
        # Rewrite empty migrated targets in place so updates do not append
        # duplicate KEY= lines.
        set_env_assignment "$target_key" "$source_assignment" "$env_file"
    elif env_key_exists "$target_key" "$env_file" || [[ -n "$fallback_value" ]]; then
        set_env_key "$target_key" "$fallback_value" "$env_file"
    fi
}

# Same migration idea as append_env_migrated_assignment_if_missing, but for
# keys that must never end up empty (e.g. bind-mount paths); repairs an empty
# target instead of leaving it alone (see comment inside for why).
append_required_env_migrated_assignment_if_empty_or_missing() {
    local target_key="$1" source_key="$2" fallback_value="$3" env_file="$4"
    local target_assignment source_assignment

    # Required migrated paths cannot stay empty: Compose would turn KEY= into an
    # invalid bind mount. This helper repairs only those required keys and keeps
    # the optional migration helper above from changing deliberate empty values.
    # Preserve a later non-empty duplicate before falling back to source or
    # default state so updates converge on the operator's actual cache dir.
    target_assignment=$(get_env_assignment_value_raw_nonempty "$target_key" "$env_file")
    if [[ -n "$target_assignment" ]]; then
        set_env_assignment "$target_key" "$target_assignment" "$env_file"
        return 0
    fi

    source_assignment=$(get_env_assignment_value_raw_nonempty "$source_key" "$env_file")
    if [[ -n "$source_assignment" ]]; then
        set_env_assignment "$target_key" "$source_assignment" "$env_file"
    elif env_key_exists "$target_key" "$env_file" || [[ -n "$fallback_value" ]]; then
        set_env_key "$target_key" "$fallback_value" "$env_file"
    fi
}

migrate_proxy_security_mode_for_update() {
    local env_file="$1" proxy_security_mode proxy_allowed_client_cidrs

    proxy_security_mode=$(get_env_var PROXY_SECURITY_MODE "$env_file")
    proxy_allowed_client_cidrs=$(get_env_var PROXY_ALLOWED_CLIENT_CIDRS "$env_file")

    # Early setup versions generated strict mode before lazy was restored as
    # the default. Without an allowlist there is no usable strict policy to
    # preserve, so update those legacy defaults back to lazy while leaving
    # explicit strict+allowlist operator configurations intact.
    if [[ "$proxy_security_mode" = "strict" && -z "$proxy_allowed_client_cidrs" ]]; then
        set_env_key PROXY_SECURITY_MODE "lazy" "$env_file"
        print_ok "Migrated legacy PROXY_SECURITY_MODE=strict without PROXY_ALLOWED_CLIENT_CIDRS to lazy"
    fi
}

readonly LEGACY_STATE_ROOT="/srv/lancache"
readonly -a LEGACY_STATE_CHILDREN=(cache pdns-standard pdns-ssl pdns-filter-state kea nats nats-conf)

# These paths are fixed compatibility anchors for pre-v0.1 production installs.
# They are not active defaults anymore; setup.sh only touches them when it must
# preserve real legacy state during backup, update, or restore.
legacy_state_path() {
    local child="${1:-}"

    if [[ -n "$child" ]]; then
        printf '%s/%s\n' "$LEGACY_STATE_ROOT" "$child"
    else
        printf '%s\n' "$LEGACY_STATE_ROOT"
    fi
}

# True if any of the known pre-v0.1 state subdirectories actually exist under
# LEGACY_STATE_ROOT, i.e. this host has real legacy state to migrate rather
# than just an unrelated /srv/lancache directory.
legacy_state_root_has_known_children() {
    local child

    for child in "${LEGACY_STATE_CHILDREN[@]}"; do
        [[ -d "$(legacy_state_path "$child")" ]] && return 0
    done
    return 1
}

# Picks the legacy state root only when it actually has legacy children on
# disk; otherwise falls back to the given (new-style) default directory.
legacy_state_root_or_default() {
    local default_dir="$1"

    if legacy_state_root_has_known_children; then
        legacy_state_path
    else
        printf '%s\n' "$default_dir"
    fi
}

# Generic version of legacy_state_root_or_default for a single directory:
# use it if it exists on disk, otherwise use the new-style default.
legacy_dir_or_default() {
    local legacy_dir="$1" default_dir="$2"

    if [[ -d "$legacy_dir" ]]; then
        printf '%s\n' "$legacy_dir"
    else
        printf '%s\n' "$default_dir"
    fi
}

# Reconciles a per-service directory override (e.g. CACHE_DIR_STANDARD) against
# the one-root state-dir contract: drops the key entirely when it already
# matches the derived default (see comment inside for why), keeps templated or
# absolute-path overrides verbatim, and repairs anything else that is clearly
# broken (a stray number, a single letter, etc.).
set_optional_env_path_override_if_needed() {
    local key="$1" desired_path="$2" derived_path="$3" env_file="$4"
    local existing_assignment

    existing_assignment=$(get_env_assignment_value_raw_nonempty "$key" "$env_file")
    if [[ -n "$existing_assignment" ]]; then
        if [[ "$existing_assignment" = "$derived_path" ]]; then
            remove_env_key "$key" "$env_file"
        elif [[ "$existing_assignment" == *'$'* ]]; then
            # Preserve intentionally templated values like ${LAN_CACHE_ROOT}/cache.
            set_env_assignment "$key" "$existing_assignment" "$env_file"
        elif is_absolute_path "$existing_assignment"; then
            set_env_assignment "$key" "$existing_assignment" "$env_file"
        else
            # Repair obviously broken literal values such as "50" or "n".
            set_env_key "$key" "$desired_path" "$env_file"
        fi
        return 0
    fi

    # Keep the one-root contract effective: if the derived state-root path is
    # already correct, leave optional per-service keys absent so a later
    # LANCACHE_STATE_DIR change still retargets the service.
    [[ "$desired_path" = "$derived_path" ]] && return 0
    set_env_key "$key" "$desired_path" "$env_file"
}

# Deletes every line assigning the given key, if any exist; a no-op if the key
# is already absent.
remove_env_key() {
    local key="$1" env_file="$2"

    env_key_exists "$key" "$env_file" || return 0
    awk -F= -v key="$key" '$1 != key' "$env_file" | write_env_file "$env_file"
}

# Default LANCACHE_STATE_DIR for a given install_dir (see comment inside for
# the deploy/prod special case).
production_state_root_default() {
    local install_dir="$1"

    # A manual production checkout runs setup.sh update against deploy/prod,
    # but runtime state must still live in the approved production root instead
    # of inside the Git checkout.
    if [[ "$(basename "$install_dir")" = "prod" && "$(basename "$(dirname "$install_dir")")" = "deploy" ]]; then
        printf '%s\n' "/opt/lancache-ng"
    else
        printf '%s\n' "$install_dir"
    fi
}

# True if install_dir is the manual production checkout path (.../deploy/prod),
# as opposed to a quickstart-installed directory like /opt/lancache-ng.
is_deploy_prod_install_dir() {
    local install_dir="$1"
    [[ "$(basename "$install_dir")" = "prod" && "$(basename "$(dirname "$install_dir")")" = "deploy" ]]
}

# Picks which .env file actually drives Compose for this install: manual
# deploy/prod checkouts use .env.local (an untracked override) when present,
# so a git pull during update never clobbers the operator's real production
# values that live in the tracked .env template.
runtime_env_file_for_install_dir() {
    local install_dir="$1"

    if is_deploy_prod_install_dir "$install_dir" && [[ -f "$install_dir/.env.local" ]]; then
        printf '%s\n' "$install_dir/.env.local"
    else
        printf '%s\n' "$install_dir/.env"
    fi
}

# True if this install currently relies on the remote-secondary NATS
# host-binding override (docker-compose.nats-secondary.yml) being active, so
# update/validate must keep passing it on every subsequent compose invocation
# instead of silently reverting to the base compose file's NATS wiring (which
# only `expose`s 4222 internally, dropping the host port publish remote
# secondary DNS nodes depend on). NATS_BIND_IP has exactly one purpose in
# this codebase: it is the value the override's `ports:` mapping requires via
# `${NATS_BIND_IP:?...}` (see docker-compose.nats-secondary.yml), so a
# non-empty NATS_BIND_IP is used as the activation signal instead of
# inventing a separate marker file. The override file's own header comment
# documents its PRIMARY activation example as a shell-exported
# `NATS_BIND_IP=<ip> docker compose ... up -d`, not a persisted .env.local
# assignment, so the process environment is checked first -- mirroring
# Compose's own variable-interpolation precedence, where a shell variable
# always wins over an --env-file value. Only if the shell has nothing set do
# we fall back to the runtime env file, covering operators who persisted
# NATS_BIND_IP into .env.local so the override keeps working across shell
# sessions (the file's documented secondary activation path). Either path
# means the operator has, by construction, committed to running with the
# override active.
nats_secondary_override_active_for_install_dir() {
    local install_dir="$1" env_file="$2" bind_ip

    [[ -f "$install_dir/docker-compose.nats-secondary.yml" ]] || return 1
    if [[ -n "${NATS_BIND_IP:-}" ]]; then
        return 0
    fi
    bind_ip=$(get_env_var_nonempty NATS_BIND_IP "$env_file" 2>/dev/null || true)
    [[ -n "$bind_ip" ]]
}

# Builds the -f argument list a compose invocation for install_dir needs:
# the base file, an operator-provided docker-compose.override.yml/.yaml when
# present, and the NATS-secondary override when
# nats_secondary_override_active_for_install_dir() says it is active. The
# base file must always be passed explicitly the moment any -f is added at
# all: Compose disables its cwd auto-discovery of docker-compose.yml (and,
# with it, the auto-discovery/merge of a sibling docker-compose.override.yml)
# as soon as one -f is given, so a call site that appended only the
# NATS-secondary override would both (a) run the stack from that
# partial-services fragment alone and (b) silently drop any operator
# override customizations that Compose would otherwise have auto-merged.
# Detecting and re-adding the override file here keeps that auto-merge
# behavior intact even though this function must pass -f explicitly.
compose_file_args_for_install_dir() {
    local install_dir="$1" env_file="$2" override_file
    local -a args=(-f "$install_dir/docker-compose.yml")

    for override_file in "$install_dir/docker-compose.override.yml" "$install_dir/docker-compose.override.yaml"; do
        if [[ -f "$override_file" ]]; then
            args+=(-f "$override_file")
            break
        fi
    done

    if nats_secondary_override_active_for_install_dir "$install_dir" "$env_file"; then
        args+=(-f "$install_dir/docker-compose.nats-secondary.yml")
    fi
    printf '%s\n' "${args[@]}"
}

# Copies the quickstart compose file and helper scripts into install_dir (used
# on both first install and every update, so copied installs always run the
# current container wiring). See the inline comment for the #538 workaround
# that force-removes a stale auto-vivified directory before reinstalling
# dhcp-probe.sh/docker-socket-proxy.sh.
install_quickstart_compose_assets() {
    local install_dir="$1" socket_proxy_target dhcp_probe_target helper_target

    socket_proxy_target="$install_dir/scripts/docker-socket-proxy.sh"
    dhcp_probe_target="$install_dir/scripts/dhcp-probe.sh"
    helper_target="$install_dir/scripts/shared-secret-bootstrap.sh"
    mkdir -p "$install_dir/scripts"
    install -m 0644 "$QUICKSTART_COMPOSE" "$install_dir/docker-compose.yml"
    # A prior install that hit the missing-copy bug (#538) left Docker's own
    # auto-vivified bind-mount source behind as an empty directory. GNU
    # install(1) treats an existing directory target as "copy into", not
    # "replace" — leaving it in place would install to dhcp-probe.sh/dhcp-probe.sh
    # and still leave the actual mount source as a directory.
    if [[ -d "$dhcp_probe_target" ]]; then
        rm -rf "$dhcp_probe_target"
    fi
    if [[ "$(realpath -m "$DHCP_PROBE_SCRIPT")" != "$(realpath -m "$dhcp_probe_target")" ]]; then
        install -m 0755 "$DHCP_PROBE_SCRIPT" "$dhcp_probe_target"
    else
        chmod 0755 "$dhcp_probe_target"
    fi
    if [[ -d "$socket_proxy_target" ]]; then
        rm -rf "$socket_proxy_target"
    fi
    if [[ "$(realpath -m "$DOCKER_SOCKET_PROXY_SCRIPT")" != "$(realpath -m "$socket_proxy_target")" ]]; then
        install -m 0755 "$DOCKER_SOCKET_PROXY_SCRIPT" "$socket_proxy_target"
    else
        chmod 0755 "$socket_proxy_target"
    fi
    # Shared-secret bootstrap helper (#858), same auto-vivified-directory guard
    # as the two scripts above (#538): the nats service bind-mounts this to
    # source resolve_shared_secret for the NATS_*_PASSWORD handshake secrets.
    if [[ -d "$helper_target" ]]; then
        rm -rf "$helper_target"
    fi
    if [[ "$(realpath -m "$SHARED_SECRET_BOOTSTRAP_SCRIPT")" != "$(realpath -m "$helper_target")" ]]; then
        install -m 0644 "$SHARED_SECRET_BOOTSTRAP_SCRIPT" "$helper_target"
    else
        chmod 0644 "$helper_target"
    fi
}

# Determines origin's default branch (e.g. master) via the cheap local
# refs/remotes/origin/HEAD symref first, falling back to a network call
# (`git remote show origin`) only if that symref hasn't been set locally.
# Falls back to the literal name "master" if both lookups fail.
git_default_branch_name() {
    local repo_dir="$1" default_branch=""

    default_branch=$(git -C "$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    default_branch="${default_branch#origin/}"
    if [[ -z "$default_branch" ]]; then
        default_branch=$(git -C "$repo_dir" remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF; exit}' || true)
    fi

    printf '%s\n' "${default_branch:-master}"
}

# True if the working tree has no uncommitted changes (`git status --porcelain` is empty).
git_repo_is_clean() {
    local repo_dir="$1"

    [[ -z "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]]
}

# Hard-resets a repo checkout to origin's current default branch. Refuses to
# run on a dirty tree so an update can never silently discard local edits;
# the operator must clean or remove the checkout first.
sync_repo_to_default_branch() {
    local repo_dir="$1" default_branch

    default_branch=$(git_default_branch_name "$repo_dir")
    git_repo_is_clean "$repo_dir" \
        || die "Existing repository at $repo_dir has local changes. Clean it first or remove $repo_dir, then rerun setup.sh."

    git -C "$repo_dir" fetch --prune origin \
        || die "Failed to refresh repository metadata for $repo_dir."
    git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$default_branch" \
        || die "Remote branch origin/$default_branch is unavailable for $repo_dir."
    git -C "$repo_dir" checkout -B "$default_branch" "origin/$default_branch" \
        || die "Failed to reset $repo_dir to origin/$default_branch."
}

# Resolves which git ref the standalone bootstrap (the self-clone path used by
# the documented `curl | bash` one-liner) should check out. An operator-supplied
# LANCACHE_SETUP_GIT_REF (mirroring the existing LANCACHE_IMAGE_CHANNEL env-var
# override pattern) takes priority; unset/empty means "keep today's behavior"
# (resolve and track origin's default branch) so existing installs, docs, and
# automation are unaffected by this being introduced (#814).
resolve_setup_bootstrap_ref() {
    printf '%s\n' "${LANCACHE_SETUP_GIT_REF:-}"
}

# Hard-resets a repo checkout to a specific, operator-pinned ref (branch, tag,
# or commit-ish). Fetches the ref explicitly by name rather than relying on a
# bare `git fetch --prune origin` (which only guarantees branches land under
# refs/remotes/origin/* -- tag-following is a local clone/config detail this
# function should not have to assume) so this works uniformly whether "ref" is
# a branch or a release tag such as v0.2.0. Refuses to run on a dirty tree,
# matching sync_repo_to_default_branch's safety behavior above.
sync_repo_to_ref() {
    local repo_dir="$1" ref="$2"

    git_repo_is_clean "$repo_dir" \
        || die "Existing repository at $repo_dir has local changes. Clean it first or remove $repo_dir, then rerun setup.sh."

    git -C "$repo_dir" fetch --prune origin "$ref" \
        || die "Failed to fetch ref '$ref' for $repo_dir. Check that LANCACHE_SETUP_GIT_REF names a real branch, tag, or commit on origin."
    git -C "$repo_dir" checkout -B "$ref" FETCH_HEAD \
        || die "Failed to reset $repo_dir to ref '$ref'."
}

# Resolves the git repo root two levels above a deploy/prod install_dir
# (deploy/prod -> repo root), used to locate the manual production repo's
# other runtime inputs (certs/, config/prod/, cdn-domains.txt).
deploy_prod_repo_root() {
    local install_dir="$1"
    realpath -m "$install_dir/../.."
}

# Lists the repo-root paths that a deploy/prod stack pulls in via ../../
# relative references, so backup/restore can capture the full manual
# production configuration and not just install_dir itself. A no-op for
# non-deploy/prod installs, which have no such external repo-root inputs.
deploy_prod_repo_input_paths() {
    local install_dir="$1" repo_root
    is_deploy_prod_install_dir "$install_dir" || return 0

    repo_root=$(deploy_prod_repo_root "$install_dir")

    # Snapshot every repo-root runtime input currently reached via ../../ from
    # deploy/prod/docker-compose.yml so rollback can restore the full manual
    # production configuration that existed before git pull changed tracked files.
    [[ -d "$repo_root/certs" ]] && printf '%s\n' "$repo_root/certs"
    [[ -d "$repo_root/config/prod" ]] && printf '%s\n' "$repo_root/config/prod"
    [[ -f "$repo_root/services/dns/cdn-domains.txt" ]] && printf '%s\n' "$repo_root/services/dns/cdn-domains.txt"
    # docker-socket-proxy is also mounted via ../../scripts/docker-socket-proxy.sh
    # (see docs/naming-conventions.md's "Docker socket proxy allowlist"
    # section) -- without this, a manual deploy/prod config backup would
    # silently omit the one file that defines which container names the
    # socket proxy allows the Admin UI/watchdog to act on.
    [[ -f "$repo_root/scripts/docker-socket-proxy.sh" ]] && printf '%s\n' "$repo_root/scripts/docker-socket-proxy.sh"
    # Shared-secret bootstrap helper (issue #858) is likewise mounted read-only
    # via ../../scripts/lib/shared-secret-bootstrap.sh into the nats service in
    # deploy/prod/docker-compose.yml. Without it in the manifest, a config
    # backup/restore taken before a bad git pull changes or removes this file
    # would restore a compose tree whose nats service sources a missing/stale
    # helper and exits before generating nats.conf.
    [[ -f "$repo_root/scripts/lib/shared-secret-bootstrap.sh" ]] && printf '%s\n' "$repo_root/scripts/lib/shared-secret-bootstrap.sh"
}

# Resolves the config files cmd_update_ip must edit for a given install_dir.
# Prints exactly three lines: deploy_env, dns_standard_env, dns_ssl_env. The
# latter two are empty for quickstart installs (the default /opt/lancache-ng
# tree and any other directory install_quickstart_compose_assets populated):
# deploy/quickstart/docker-compose.yml wires PROXY_IP straight from
# ${IP_STANDARD}/${IP_SSL} in deploy_env, so there is no separate
# dns-standard.env/dns-ssl.env to edit. Only a manual deploy/prod checkout
# (identified the same way runtime_env_file_for_install_dir already does, via
# is_deploy_prod_install_dir) has those files, two levels up from install_dir
# at repo_root/config/prod -- see deploy/prod/docker-compose.yml's env_file
# references and deploy_prod_repo_root().
resolve_update_ip_config_paths() {
    local install_dir="$1"
    local deploy_env dns_standard_env="" dns_ssl_env=""

    deploy_env=$(runtime_env_file_for_install_dir "$install_dir")
    if is_deploy_prod_install_dir "$install_dir"; then
        local repo_root
        repo_root=$(deploy_prod_repo_root "$install_dir")
        dns_standard_env="$repo_root/config/prod/dns-standard.env"
        dns_ssl_env="$repo_root/config/prod/dns-ssl.env"
    fi

    printf '%s\n%s\n%s\n' "$deploy_env" "$dns_standard_env" "$dns_ssl_env"
}

# Full .env rewrites keep the original owner/mode because the file contains
# runtime tokens and may already be locked down to 0600.
write_env_file() {
    local env_file="$1" env_dir tmp
    env_dir=$(dirname "$env_file")
    tmp=$(mktemp "${env_dir}/.env.tmp.XXXXXX") \
        || die "Failed to create a temporary .env file in $env_dir."

    if [[ -f "$env_file" ]]; then
        chown --reference="$env_file" "$tmp" \
            || { rm -f "$tmp"; die "Failed to preserve owner for $env_file."; }
        chmod --reference="$env_file" "$tmp" \
            || { rm -f "$tmp"; die "Failed to preserve permissions for $env_file."; }
    else
        chmod 0600 "$tmp" \
            || { rm -f "$tmp"; die "Failed to secure permissions for $tmp."; }
    fi

    if ! cat > "$tmp"; then
        rm -f "$tmp"
        die "Failed to write temporary .env file."
    fi

    mv "$tmp" "$env_file" \
        || { rm -f "$tmp"; die "Failed to replace $env_file."; }
}

# Generic version of write_env_file for non-.env generated files (no
# owner/permission preservation, since these are newly generated content, not
# an existing operator-owned file): writes via a same-directory temp file and
# atomically renames into place so a failed write never leaves a half-written target.
write_generated_runtime_file() {
    local target="$1" target_dir target_name tmp
    target_dir=$(dirname "$target")
    target_name=$(basename "$target")
    tmp=$(mktemp "${target_dir}/.${target_name}.tmp.XXXXXX") \
        || die "Failed to create a temporary file for $target."

    if ! cat > "$tmp"; then
        rm -f "$tmp"
        die "Failed to write temporary file for $target."
    fi

    mv "$tmp" "$target" \
        || { rm -f "$tmp"; die "Failed to replace $target."; }
}

# Update-time guard: dies with a clear remediation message if a required key
# is missing or empty, instead of letting `setup.sh update` silently proceed
# with an unusable runtime configuration.
require_env_value_for_update() {
    local key="$1" env_file="$2"
    env_key_has_value "$key" "$env_file" \
        || die "$key is missing or empty in $env_file. Set it before running setup.sh update."
}

# Generates and stores a secret for key only if it doesn't already hold a
# usable (non-placeholder) value — a thin wrapper combining
# env_key_has_usable_secret + generate_secret_value for the common
# "fill in this secret if needed" call sites in migrate_env_for_update.
ensure_secret_env_key() {
    local key="$1" env_file="$2" kind="$3" value
    if env_key_has_usable_secret "$key" "$env_file"; then
        return 0
    fi

    value=$(generate_secret_value "$key" "$kind")
    set_env_key "$key" "$value" "$env_file"
    print_ok "Generated missing or placeholder secret: $key"
}

# Normalizes a CACHE_MAX_SIZE value like "50g" or "50G" down to a bare GB
# integer for internal comparisons; falls back to "50" if it can't be parsed
# as a plain gigabyte count.
cache_size_gb_from_env() {
    local cache_max_size="$1"
    cache_max_size="${cache_max_size,,}"
    cache_max_size="${cache_max_size%g}"
    [[ "$cache_max_size" =~ ^[0-9]+$ ]] || cache_max_size="50"
    printf '%s\n' "$cache_max_size"
}

# Production installs consume prebuilt service images. Prebuilt images are
# published for linux/amd64 and linux/arm64 (see #395); reject any other host
# architecture before writing or mutating runtime state.
assert_prebuilt_image_platform_supported() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64|aarch64|arm64)
            ;;
        *)
            die "Prebuilt production images are currently published for linux/amd64 and linux/arm64 only. This host reports '${arch}'."
            ;;
    esac
}

# Maps `uname -m` to the "linux/<arch>" platform string used throughout
# release/stack-images.yml and by `docker buildx`. Shared by
# assert_prebuilt_image_platform_supported's host-only check and by
# assert_resolved_image_tag_platform_supported below so both checks agree on
# exactly which architectures are recognized.
host_image_platform() {
    local arch="$1"
    case "$arch" in
        x86_64|amd64)
            printf 'linux/amd64\n'
            ;;
        aarch64|arm64)
            printf 'linux/arm64\n'
            ;;
        *)
            return 1
            ;;
    esac
}

# assert_prebuilt_image_platform_supported only checks that this host's
# architecture is one setup.sh understands at all; it says nothing about
# whether the specific tag/channel this install actually resolved to
# (LANCACHE_IMAGE_TAG) has a manifest published for that architecture. A host
# pinned to a pre-arm64 tag, or to a channel whose current pointer is missing
# an arm64 leg, would otherwise sail past that earlier guard and only fail
# deep inside `docker compose pull`, after setup.sh has already written
# .env/compose state for this install (#665). Call this once the tag is fully
# resolved and before the first state-mutating write for that install/update.
#
# Mirrors scripts/require-image-platforms.sh's `docker buildx imagetools
# inspect` approach, but inlined rather than shelled out to that script:
# setup.sh is documented (see README.md) to run standalone via `curl | bash`,
# so it cannot assume a full repository checkout with scripts/ present on
# disk. Checks the "dns" image only -- release/stack-images.yml declares an
# identical platform list for every runtime service and the stack pointer, so
# one lookup is representative and avoids one registry round-trip per service.
assert_resolved_image_tag_platform_supported() {
    local registry="$1" prefix="$2" tag="$3"
    local arch platform image single_platform inspect_text discovered_platforms

    # Every guard below adds an explicit `return 1` after `die`. In
    # production this is unreachable (die() calls exit and terminates the
    # whole process), but it makes the function correctly fail-fast under
    # test doubles that stub die() as a non-exiting `return` (see
    # tests/bats/helpers/setup-platform-helpers.sh) instead of silently
    # falling through to later checks with empty, unset state.
    arch=$(uname -m)
    platform=$(host_image_platform "$arch") \
        || { die "Prebuilt production images are currently published for linux/amd64 and linux/arm64 only. This host reports '${arch}'."; return 1; }

    command -v docker >/dev/null 2>&1 \
        || { die "docker is required to verify that image tag '${tag}' publishes a ${platform} image before continuing."; return 1; }
    docker buildx version >/dev/null 2>&1 \
        || { die "docker buildx is required to verify that image tag '${tag}' publishes a ${platform} image before continuing. Install the docker-buildx-plugin package, then rerun setup.sh."; return 1; }

    image="${registry}/${prefix}/dns:${tag}"

    # shellcheck disable=SC2016 # Go template is evaluated by Docker, not the shell.
    single_platform=$(docker buildx imagetools inspect "$image" --format '{{if .Image}}{{.Image.OS}}/{{.Image.Architecture}}{{end}}' 2>&1) \
        || { die "Failed to inspect ${image} to verify it publishes a ${platform} image (${single_platform}). Check network access and registry reachability, then rerun setup.sh."; return 1; }

    if [[ -n "$single_platform" && "$single_platform" != "<no value>/<no value>" && "$single_platform" != "unknown/unknown" ]]; then
        discovered_platforms="$single_platform"
    else
        inspect_text=$(docker buildx imagetools inspect "$image" 2>&1) \
            || { die "Failed to inspect ${image} manifest to verify it publishes a ${platform} image (${inspect_text}). Check network access and registry reachability, then rerun setup.sh."; return 1; }
        discovered_platforms=$(printf '%s\n' "$inspect_text" | awk '$1 == "Platform:" && $2 != "unknown/unknown" { print $2 }' | sort -u)
    fi

    [[ -n "$discovered_platforms" ]] \
        || { die "${image} did not expose any usable platform metadata; cannot verify ${platform} support for tag '${tag}'."; return 1; }

    printf '%s\n' "$discovered_platforms" | grep -Eq "^${platform}(/.*)?$" \
        || die "Image tag '${tag}' does not publish a ${platform} image for this ${arch} host (published: $(printf '%s' "$discovered_platforms" | tr '\n' ',' | sed 's/,$//')). Choose a tag/channel that publishes ${platform}, for example LANCACHE_IMAGE_CHANNEL=latest, then rerun setup.sh."
}

# True if systemctl is present AND the given unit file is known to it. Used to
# make all convergence-timer handling a no-op on hosts without systemd or
# without the lancache-converge units installed, instead of erroring out.
systemd_unit_exists() {
    local unit="$1"
    command -v systemctl >/dev/null 2>&1 \
        && systemctl list-unit-files "$unit" >/dev/null 2>&1
}

CONVERGENCE_TIMER_WAS_ACTIVE=0
CONVERGENCE_TIMER_WAS_ENABLED=0
CONVERGENCE_SERVICE_WAS_ACTIVE=0
UPDATE_CONVERGENCE_PAUSED=0
UPDATE_CONVERGENCE_COMPLETED=0

# The convergence timer may start `docker compose up` while update is migrating
# files. Pause and remember exact state so update can restore the previous timer
# behavior after success or pre-mutation failure.
pause_lancache_convergence_for_update() {
    CONVERGENCE_TIMER_WAS_ACTIVE=0
    CONVERGENCE_TIMER_WAS_ENABLED=0
    CONVERGENCE_SERVICE_WAS_ACTIVE=0

    local timer_exists=0 service_exists=0
    systemd_unit_exists lancache-converge.timer && timer_exists=1
    systemd_unit_exists lancache-converge.service && service_exists=1
    if [[ "$timer_exists" = "0" && "$service_exists" = "0" ]]; then
        return 0
    fi

    if [[ "$timer_exists" = "1" ]] && systemctl is-active --quiet lancache-converge.timer; then
        CONVERGENCE_TIMER_WAS_ACTIVE=1
        print_step "Pausing convergence timer"
        systemctl stop lancache-converge.timer \
            || die "Failed to stop lancache-converge.timer before update."
    fi

    if [[ "$service_exists" = "1" ]] && systemctl is-active --quiet lancache-converge.service; then
        CONVERGENCE_SERVICE_WAS_ACTIVE=1
        print_step "Stopping active convergence service"
        systemctl stop lancache-converge.service \
            || die "Failed to stop lancache-converge.service before update."
        if systemctl is-active --quiet lancache-converge.service; then
            die "lancache-converge.service is still active after stop; refusing to update concurrently."
        fi
    fi

    if [[ "$timer_exists" = "1" ]] && systemctl is-enabled --quiet lancache-converge.timer; then
        CONVERGENCE_TIMER_WAS_ENABLED=1
        systemctl disable lancache-converge.timer >/dev/null \
            || die "Failed to disable lancache-converge.timer before update."
    fi
}

# Resume only what was active/enabled before the update. This keeps manual
# operator choices intact and avoids enabling convergence on systems that did
# not use it before.
resume_lancache_convergence_after_update() {
    local restart_service="${1:-false}"

    if [[ "$restart_service" = "true" ]] \
        && [[ "$CONVERGENCE_SERVICE_WAS_ACTIVE" = "1" ]] \
        && systemd_unit_exists lancache-converge.service; then
        systemctl start lancache-converge.service \
            || die "Failed to restart lancache-converge.service after failed pre-mutation update."
    fi

    if ! systemd_unit_exists lancache-converge.timer; then
        return 0
    fi

    if [[ "$CONVERGENCE_TIMER_WAS_ENABLED" = "1" ]]; then
        systemctl enable lancache-converge.timer >/dev/null \
            || die "Failed to re-enable lancache-converge.timer after update."
    fi

    if [[ "$CONVERGENCE_TIMER_WAS_ACTIVE" = "1" ]]; then
        systemctl start lancache-converge.timer \
            || die "Failed to restart lancache-converge.timer after update."
    fi
}

# EXIT trap installed by cmd_update for the whole update run. This is the
# failure-path counterpart to resume_lancache_convergence_after_update: it
# fires on ANY exit (success or error) via the trap, but only actually acts
# if convergence was paused and the update never reached its completed
# marker — so a successful update (which clears the trap itself) never
# double-resumes, while a die() partway through still restores the timer
# instead of leaving it stopped forever. Preserves and re-exits with the
# original exit code so the process's final status is unchanged.
resume_lancache_convergence_after_failed_update() {
    local exit_code=$?

    trap - EXIT
    if [[ "${UPDATE_CONVERGENCE_PAUSED:-0}" = "1" ]] \
        && [[ "${UPDATE_CONVERGENCE_COMPLETED:-0}" != "1" ]]; then
        print_warn "Update failed after pausing convergence; restoring convergence state."
        resume_lancache_convergence_after_update true
    fi

    exit "$exit_code"
}

# Image selection is part of the release safety contract: mutable channels such
# as latest/nightly must resolve to one immutable stack tag before the compose
# pull, so one installation cannot accidentally mix image versions.
validate_lancache_image_tag() {
    local tag="$1"

    case "$tag" in
        sha-*)
            [[ "$tag" =~ ^sha-[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] \
                || die "LANCACHE_IMAGE_TAG must be a valid sha-* image tag."
            return 0
            ;;
        pr-*)
            # CI-only immutable staging-tag format pr-<N>-sha-<short>, pushed by
            # build-push.yml (and back-filled by scripts/ensure-pr-staging-images.sh)
            # for a same-repo PR's merge commit. It is keyed on that commit's sha
            # and never re-pointed, so it is a legitimate PINNED target that lets
            # the full-setup deep-validate suite's setup.sh CLI simulation install
            # the PR's OWN images instead of a mutable, possibly-stale channel.
            # Deliberately NOT surfaced in the operator-facing pinned/derive error
            # messages below (which still name only sha-*/vX.Y.Z): these tags are
            # ephemeral CI build artifacts, not a release channel operators should
            # pin production installs to.
            [[ "$tag" =~ ^pr-[0-9]+-sha-[0-9a-fA-F]{7,}$ ]] \
                || die "LANCACHE_IMAGE_TAG pr-* staging tags must match pr-<number>-sha-<commit>."
            return 0
            ;;
    esac

    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] \
        || die "LANCACHE_IMAGE_TAG must be an immutable sha-* tag or a vX.Y.Z / vX.Y.Z-rc.N release tag."
}

# Enumerates the supported LANCACHE_IMAGE_CHANNEL values.
#
# "stable" is the operator-facing name setup.sh's interactive channel picker
# writes (#819); "latest" is the original, still-accepted name for the exact
# same underlying stack:latest pointer -- kept valid (not deprecated/rejected)
# so existing installs' .env files and any external tooling/docs that already
# say LANCACHE_IMAGE_CHANNEL=latest keep working unchanged. The two are
# resolved identically; see resolve_lancache_stack_channel_tag below.
#
# "edge" was the OLD name of the "nightly" channel (renamed in v0.3.0, #1056).
# It is a HARD CUT, not an alias: an install still carrying
# LANCACHE_IMAGE_CHANNEL=edge is rejected with a clear, actionable error telling
# the operator to switch to "nightly", rather than being silently accepted as a
# synonym. This is an intentional v0.3.0 breaking change.
#
# "dev" was RETIRED (not renamed) in v0.3.0 (#825/#1141): it used to publish
# automatically from whichever vX.Y.Z branch was the active pre-release
# integration branch of the time. Since current_dev became the permanent
# active-development branch, that role was never re-pointed to it -- the
# maintainer's decision (#825, 2026-07-23: "master = stable, current_dev =
# nightly, vY.X.Z = archived release") formally retired dev instead, because
# archived vY.X.Z branches are frozen release history now, not an active
# integration branch, so there is nothing left for a dev channel to mean.
# This is the same HARD CUT treatment as edge, for the same reason: silently
# keeping dev valid would mean install/update against an increasingly stale,
# unmaintained image with no warning. dev was never offered by setup.sh's
# interactive picker or the Admin UI's channel control (see
# lancache_ui_channel_override_is_valid), so this only affects operators who
# set LANCACHE_IMAGE_CHANNEL=dev explicitly via .env/shell env or the
# secondary-node registration flow.
validate_lancache_image_channel() {
    local channel="$1"
    case "$channel" in
        stable|latest|nightly|pinned)
            return 0
            ;;
        edge)
            die "LANCACHE_IMAGE_CHANNEL=edge is no longer supported: the 'edge' channel was renamed to 'nightly' in v0.3.0 (#1056). Update your .env (or shell env) to LANCACHE_IMAGE_CHANNEL=nightly and re-run setup.sh."
            ;;
        dev)
            die "LANCACHE_IMAGE_CHANNEL=dev is no longer supported: the 'dev' channel was retired in v0.3.0 (#825/#1141) -- archived vY.X.Z release branches no longer publish a live channel. Update your .env (or shell env) to LANCACHE_IMAGE_CHANNEL=nightly (tracks current_dev's ongoing development) or LANCACHE_IMAGE_CHANNEL=stable/latest (tracks the stable release), then re-run setup.sh."
            ;;
    esac
    die "LANCACHE_IMAGE_CHANNEL must be stable, latest, nightly, or pinned."
}

# Derives a release tag (vX.Y.Z[-rc.N]) for a checkout/archive that has no
# explicit LANCACHE_IMAGE_TAG/CHANNEL configured: prefers an exact git tag on
# HEAD when run from a git checkout, otherwise falls back to the VERSION file
# shipped in release archives/tarballs. Returns 1 (no tag available, caller
# should fall back further) vs. 2 (a tag/version WAS found but is malformed,
# caller should die) so callers can tell "nothing to derive from" apart from
# "found something invalid."
derive_release_archive_image_tag() {
    local version tag git_stderr git_status
    local -a safe_dir_opt=()

    # A .git entry (dir, or a file for worktrees) means this is a genuine git
    # checkout, not a release archive -- even if git itself goes on to refuse
    # to touch it below. Checking this directly (rather than relying solely on
    # `git rev-parse --is-inside-work-tree`'s exit code as a proxy for "is
    # this a git checkout") is what lets the branches below tell "no .git at
    # all" apart from "git rejected a .git that does exist".
    if [[ -e "$SCRIPT_DIR/.git" ]]; then
        if git_stderr=$(git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree 2>&1 1>/dev/null); then
            git_status=0
        else
            git_status=$?
        fi

        if [[ "$git_status" -ne 0 ]]; then
            if [[ "$git_stderr" == *"detected dubious ownership"* ]]; then
                # Since Git 2.35.2 (the CVE-2022-24765 fix), git refuses to
                # operate on a repository whose directory is owned by a
                # different user/UID than the process invoking git. That is a
                # normal, non-malicious situation for this project's own
                # supported use cases -- a bind-mounted checkout run inside a
                # container under a different UID, or `sudo ./setup.sh` after
                # a plain-user `git clone` -- so it must not be silently
                # conflated with "there is no .git directory" (the genuine
                # release-archive case the VERSION-file fallback below exists
                # for) and must not silently resolve a possibly-stale
                # VERSION tag instead.
                #
                # Trust the path this run's dubious-ownership check actually
                # rejected -- not necessarily $SCRIPT_DIR verbatim. Git checks
                # safe.directory against the repository's real (symlink-
                # resolved) path, so if $SCRIPT_DIR is itself a symlink,
                # scoping trust to the symlink path would not match and this
                # retry would still fail, falling through to the possibly-
                # stale VERSION file -- exactly the bug this is meant to
                # avoid. Git's own error message already names the exact path
                # it checked ("... in repository at '<path>' ..."), so parse
                # that out instead of assuming $SCRIPT_DIR is already the
                # physical path; fall back to $SCRIPT_DIR only if the message
                # format is ever unrecognized.
                #
                # Either way, this is scoped for this ONE git invocation only,
                # via `-c` on the command line. This is deliberately narrower
                # than `git config --global --add safe.directory`: it is
                # never written to any git config file, never persists beyond
                # this single process, never affects any other git invocation
                # on the system, and never uses a wildcard ("*") that would
                # trust every repository regardless of path -- so it does not
                # weaken the dubious-ownership protection for anything other
                # than this script resolving its own, already-trusted path.
                # Match against only git's first stderr line: the full
                # message also repeats the path later (in its own
                # single-quoted "git config --global --add safe.directory
                # '<path>'" suggestion), and a greedy (.+) spanning the
                # whole multi-line string would capture through to that
                # later quote instead of stopping at the first line's own
                # closing quote -- confirmed live (a path containing a
                # space reproduced this: the over-captured value never
                # matched what git actually checked, so the retry below
                # still failed and fell through to the stale VERSION file).
                local dubious_path="$SCRIPT_DIR"
                local dubious_first_line="${git_stderr%%$'\n'*}"
                if [[ "$dubious_first_line" =~ dubious\ ownership\ in\ repository\ at\ \'(.+)\' ]]; then
                    dubious_path="${BASH_REMATCH[1]}"
                fi
                safe_dir_opt=(-c "safe.directory=$dubious_path")
                printf 'Note: %s has different file ownership than the current user; trusting it for this run only (see: git help safe.directory).\n' "$dubious_path" >&2
            else
                printf 'Warning: %s contains a .git directory but git rejected it:\n%s\nFalling back to the VERSION file, which may be stale or unpublished. Set LANCACHE_IMAGE_TAG or LANCACHE_IMAGE_CHANNEL to override.\n' "$SCRIPT_DIR" "$git_stderr" >&2
            fi
        fi

        if git "${safe_dir_opt[@]}" -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            tag=$(git "${safe_dir_opt[@]}" -C "$SCRIPT_DIR" describe --tags --exact-match 2>/dev/null || true)
            if [[ -n "$tag" ]]; then
                if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]; then
                    printf 'Invalid release tag from git checkout: %s\n' "$tag" >&2
                    return 2
                fi
                printf '%s\n' "$tag"
                return 0
            fi
            return 1
        fi
        # .git exists but git still refuses it even with dubious-ownership
        # trust scoped to this one call (some other problem, already warned
        # about above) -- fall through to the VERSION-file branch as a last
        # resort.
    fi

    [[ -f "$SCRIPT_DIR/VERSION" ]] || return 1
    version=$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")
    if [[ -z "$version" ]]; then
        printf 'VERSION is empty; cannot derive a release image tag.\n' >&2
        return 2
    fi
    if [[ "$version" = v* ]]; then
        tag="$version"
    else
        tag="v$version"
    fi
    if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]; then
        printf 'Invalid release image tag derived from VERSION: %s\n' "$tag" >&2
        return 2
    fi
    printf '%s\n' "$tag"
}

# Rejects anything that isn't a plausible registry hostname[:port].
validate_lancache_image_registry() {
    local registry="$1"
    [[ "$registry" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?$ ]] \
        || die "LANCACHE_IMAGE_REGISTRY must be a registry hostname with an optional port."
}

# Rejects anything that isn't a plausible slash-separated image namespace.
validate_lancache_image_prefix() {
    local prefix="$1"
    [[ "$prefix" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
        || die "LANCACHE_IMAGE_PREFIX must be a slash-separated image namespace."
}

# Resolves the registry host to use for pulling images: explicit shell env var
# wins, then the value already in .env, then the ghcr.io default. Always
# validated so a typo'd override fails fast instead of producing a broken pull.
resolve_lancache_image_registry() {
    local env_file="${1:-}" registry="${LANCACHE_IMAGE_REGISTRY:-}"

    if [[ -z "$registry" && -n "$env_file" && -f "$env_file" ]]; then
        registry=$(get_env_var LANCACHE_IMAGE_REGISTRY "$env_file")
    fi

    registry="${registry:-ghcr.io}"
    validate_lancache_image_registry "$registry"
    printf '%s\n' "$registry"
}

# Same precedence as resolve_lancache_image_registry (shell env > .env >
# default), but for the image namespace/prefix.
resolve_lancache_image_prefix() {
    local env_file="${1:-}" prefix="${LANCACHE_IMAGE_PREFIX:-}"

    if [[ -z "$prefix" && -n "$env_file" && -f "$env_file" ]]; then
        prefix=$(get_env_var LANCACHE_IMAGE_PREFIX "$env_file")
    fi

    prefix="${prefix:-wiki-mod/lancache-ng}"
    validate_lancache_image_prefix "$prefix"
    printf '%s\n' "$prefix"
}

# Resolves which release channel (latest/nightly/pinned) this install should
# track, in this precedence order:
#   1. An explicit LANCACHE_IMAGE_CHANNEL (shell env, then .env).
#   2. If no channel was set but LANCACHE_IMAGE_TAG names a moving channel
#      word (latest/nightly), infer that as the channel; if it names an
#      immutable tag (sha-*/vX.Y.Z), infer channel=pinned.
#   3. If still unresolved and this is a git checkout/release archive with a
#      derivable release tag, infer channel=pinned so that exact release is used.
#   4. Otherwise default to "latest" — deliberately the stable channel, never
#      silently "nightly" or "master", so a plain install never opts a production
#      host into a moving pre-release channel without saying so explicitly.
# The result is always validated before being returned.
resolve_lancache_image_channel() {
    local env_file="${1:-}" channel="${LANCACHE_IMAGE_CHANNEL:-}" tag="${LANCACHE_IMAGE_TAG:-}" release_tag=""

    if [[ -z "$channel" && -n "$env_file" && -f "$env_file" ]]; then
        channel=$(get_env_var LANCACHE_IMAGE_CHANNEL "$env_file")
    fi

    if [[ -z "$tag" && -n "$env_file" && -f "$env_file" ]]; then
        tag=$(get_env_var LANCACHE_IMAGE_TAG "$env_file")
    fi

    case "$tag" in
        stable|latest|nightly)
            channel="${channel:-$tag}"
            ;;
        sha-*|v[0-9]*)
            channel="${channel:-pinned}"
            ;;
    esac

    if [[ -z "$channel" ]]; then
        if release_tag=$(derive_release_archive_image_tag); then
            channel="pinned"
        elif [[ "$?" = "2" ]]; then
            die "Cannot derive a valid release image tag from this checkout/archive."
        fi
        [[ -n "$release_tag" ]] && channel="pinned"
    fi

    # Normal installs default to the stable channel. Untagged development or
    # pre-stable testing must opt into nightly explicitly so production users do
    # not drift onto a moving integration channel by accident. "latest", not
    # "stable", stays the hardcoded fallback here so an install with genuinely
    # nothing configured lands on the name that has existed the whole time
    # (both resolve identically either way -- see resolve_lancache_stack_channel_tag).
    channel="${channel:-latest}"
    validate_lancache_image_channel "$channel"
    printf '%s\n' "$channel"
}

# Pure name mapping, no I/O: which physical GHCR "stack:<tag>" pointer image
# backs a given operator-facing LANCACHE_IMAGE_CHANNEL value. "stable" (#819)
# is the operator-facing name for the exact same underlying stack:latest
# pointer image -- there is no separate stack:stable GHCR tag, and none is
# planned; both names are published identically by the release job. Every
# other channel name passes through unchanged. Kept as its own tiny function
# (rather than inlined where it's used) specifically so this one mapping can
# be unit-tested with zero docker/tar involved.
#
# Note there is deliberately no "edge -> nightly" mapping here: the old "edge"
# channel was hard-cut, not aliased, in v0.3.0 (#1056) -- an edge value is
# rejected by validate_lancache_image_channel long before this function, so it
# never reaches this pointer resolution. The same is true of the retired
# "dev" channel (#825/#1141): validate_lancache_image_channel rejects it
# before this function ever sees it, so there is no "dev" case here either.
lancache_stack_pointer_channel_for() {
    local channel="$1"
    if [[ "$channel" = "stable" ]]; then
        printf 'latest\n'
    else
        printf '%s\n' "$channel"
    fi
}

# Turns a mutable channel name (latest/nightly) into one immutable sha-* tag.
# Channels are published as a tiny "stack:<channel>" pointer image whose only
# content is a stack.env file naming the current immutable LANCACHE_IMAGE_TAG
# for that channel; this pulls that pointer image, reads stack.env out of it
# via `docker cp` + tar (no local container run needed), and validates the
# extracted tag really is a sha-* value before trusting it. This indirection
# is what lets `LANCACHE_IMAGE_CHANNEL=nightly` resolve to one fixed, reproducible
# stack version instead of "whatever :nightly happens to mean when you docker pull".
# A pull failure on the "latest" channel gets a dedicated explanation (this
# project is pre-1.0 and has not cut a stable release yet) instead of a raw
# Docker error.
resolve_lancache_stack_channel_tag() {
    local env_file="$1" channel="$2"
    local registry prefix stack_image container_id="" resolved_tag=""
    local pointer_channel
    pointer_channel=$(lancache_stack_pointer_channel_for "$channel")

    registry=$(resolve_lancache_image_registry "$env_file")
    prefix=$(resolve_lancache_image_prefix "$env_file")
    stack_image="${registry}/${prefix}/stack:${pointer_channel}"

    command -v docker >/dev/null 2>&1 \
        || die "Docker is required to resolve LANCACHE_IMAGE_CHANNEL=${channel} through ${stack_image}."
    command -v tar >/dev/null 2>&1 \
        || die "tar is required to read the stack channel pointer image ${stack_image}."

    printf "\n${BOLD}${CYAN}▶ Resolving image channel %s${RESET}\n" "$channel" >&2
    docker pull "$stack_image" >/dev/null \
        || {
            if [[ "$pointer_channel" = "latest" ]]; then
                cat >&2 <<EOF

${RED}✗${RESET} Cannot resolve the 'stable' release channel (published as the 'latest' pointer image).

This project is currently in active development (pre-1.0). While images are published
to the 'nightly' testing channel continuously from current_dev, a formal stable release
with a published 'latest'/'stable' channel tag has not yet been created.

To proceed, choose one of these options:

  1. Use the 'nightly' testing channel (pre-release, may change frequently):
     LANCACHE_IMAGE_CHANNEL=nightly ./setup.sh install

  2. Pin to a specific release version or commit (immutable):
     LANCACHE_IMAGE_TAG=vX.Y.Z ./setup.sh install        # once a stable release is tagged
     LANCACHE_IMAGE_TAG=sha-abc1234 ./setup.sh install   # specific commit build

For details on release channels and their stability, see:
  docs/release-versioning.md

EOF
                die "Cannot resolve stack channel pointer ${stack_image}."
            else
                die "Failed to pull stack channel pointer ${stack_image}. Check GHCR access or set LANCACHE_IMAGE_TAG to an immutable sha-* / vX.Y.Z tag."
            fi
        }

    container_id=$(docker create "$stack_image") \
        || die "Failed to create temporary container from ${stack_image}."
    resolved_tag=$(docker cp "${container_id}:/stack.env" - \
        | tar -xO 2>/dev/null \
        | awk -F= '$1 == "LANCACHE_IMAGE_TAG" {print $2; exit}') \
        || { docker rm "$container_id" >/dev/null 2>&1 || true; die "Failed to read stack.env from ${stack_image}."; }
    docker rm "$container_id" >/dev/null \
        || die "Failed to remove temporary stack pointer container ${container_id}."

    [[ "$resolved_tag" =~ ^sha-[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] \
        || die "Stack channel pointer ${stack_image} returned invalid LANCACHE_IMAGE_TAG: ${resolved_tag:-<empty>}."

    printf '%s\n' "$resolved_tag"
}

# Resolves the actual immutable image tag docker compose should pull, in this
# precedence order (mirrors, and is deliberately more specific than, the
# channel precedence in resolve_lancache_image_channel):
#   1. An explicit LANCACHE_IMAGE_TAG (shell env) that already names a channel
#      word or an immutable tag is used/resolved directly.
#   2. Otherwise an explicit LANCACHE_IMAGE_CHANNEL (shell env or .env) is
#      resolved to its immutable tag via resolve_lancache_stack_channel_tag.
#      LANCACHE_IMAGE_CHANNEL=pinned specifically requires LANCACHE_IMAGE_TAG
#      to already be set — "pinned" has no channel pointer image of its own.
#   3. Otherwise LANCACHE_IMAGE_TAG from .env, same channel-word-vs-immutable-tag check.
#   4. Otherwise, for a git checkout/release archive, derive the release tag
#      straight from the tag/VERSION file.
#   5. Otherwise fall back to resolving the default channel (see
#      resolve_lancache_image_channel — "latest", never silently "nightly").
# Every path validates the final value before returning it.
resolve_lancache_image_tag() {
    local env_file="${1:-}" tag="${LANCACHE_IMAGE_TAG:-}" release_tag="" channel=""

    if [[ -n "$tag" ]]; then
        case "$tag" in
            stable|latest|nightly)
                resolve_lancache_stack_channel_tag "$env_file" "$tag"
                return 0
                ;;
            sha-*|v[0-9]*)
                validate_lancache_image_tag "$tag"
                printf '%s\n' "$tag"
                return 0
                ;;
        esac
    fi

    channel="${LANCACHE_IMAGE_CHANNEL:-}"
    if [[ -z "$channel" && -n "$env_file" && -f "$env_file" ]]; then
        channel=$(get_env_var LANCACHE_IMAGE_CHANNEL "$env_file")
    fi

    case "$channel" in
        stable|latest|nightly)
            resolve_lancache_stack_channel_tag "$env_file" "$channel"
            return 0
            ;;
        pinned)
            if [[ -z "$tag" && -n "$env_file" && -f "$env_file" ]]; then
                tag=$(get_env_var LANCACHE_IMAGE_TAG "$env_file")
            fi
            if [[ -z "$tag" ]]; then
                if release_tag=$(derive_release_archive_image_tag); then
                    tag="$release_tag"
                elif [[ "$?" = "2" ]]; then
                    die "Cannot derive a valid release image tag from this checkout/archive."
                fi
            fi
            [[ -n "$tag" ]] \
                || die "LANCACHE_IMAGE_CHANNEL=pinned requires LANCACHE_IMAGE_TAG to be set to an immutable sha-* or vX.Y.Z tag."
            ;;
        "")
            ;;
        *)
            validate_lancache_image_channel "$channel"
            ;;
    esac

    if [[ -z "$tag" && -n "$env_file" && -f "$env_file" ]]; then
        tag=$(get_env_var LANCACHE_IMAGE_TAG "$env_file")
    fi

    case "$tag" in
        stable|latest|nightly)
            resolve_lancache_stack_channel_tag "$env_file" "$tag"
            return 0
            ;;
        sha-*|v[0-9]*)
            validate_lancache_image_tag "$tag"
            printf '%s\n' "$tag"
            return 0
            ;;
    esac

    if [[ -z "$tag" ]]; then
        if release_tag=$(derive_release_archive_image_tag); then
            tag="$release_tag"
        elif [[ "$?" = "2" ]]; then
            die "Cannot derive a valid release image tag from this checkout/archive."
        fi
        [[ -n "$release_tag" ]] && tag="$release_tag"
    fi

    if [[ -z "$tag" ]]; then
        channel=$(resolve_lancache_image_channel "$env_file")
        resolve_lancache_stack_channel_tag "$env_file" "$channel"
        return 0
    fi

    validate_lancache_image_tag "$tag"
    printf '%s\n' "$tag"
}

# Update migrations must be idempotent. They add keys introduced after an older
# install, preserve real operator secrets, replace placeholders, and normalize
# legacy profile/DHCP/cache state without rewriting the whole file blindly.
migrate_env_for_update() {
    # preserve_image_tag: "1" keeps an already-valid LANCACHE_IMAGE_TAG as-is
    # instead of re-resolving it against the current channel pointer. update
    # always wants the default (0) re-resolve behavior, since that is how a
    # channel-tracking install picks up a new image on every update. restore
    # passes 1: restoring an old backup to roll back a bad channel image must
    # keep the archived immutable tag, not silently re-resolve back to
    # whatever the channel (e.g. nightly/latest) currently points to -- which,
    # right after a bad release, is likely still the same bad tag.
    local install_dir="$1" preserve_image_tag="${2:-0}" env_file dhcp_enabled dhcp_mode
    local dhcp_proxy_interface dhcp_proxy_router dhcp_ntp_servers dhcp_proxy_domain
    local dhcp_proxy_boot_filename dhcp_proxy_boot_server _dhcp_ntp_check _dhcp_ntp_ip
    local allow_insecure_ui cache_dir cache_max_gb cache_max_size cache_gb cache_mem_mb ip_ssl ssl_enabled ui_generated_password ui_password ui_user
    local compose_profiles dhcp_dns_primary dhcp_dns_secondary dhcp_subnet_start ip_standard upstream_dhcp_ip
    local kea_data_default kea_data_dir nats_conf_default nats_conf_dir nats_data_default nats_data_dir
    local pdns_filter_state_default pdns_filter_state_dir pdns_ssl_default pdns_ssl_dir pdns_standard_default pdns_standard_dir
    local state_dir state_root_default ui_session_ttl
    local legacy_cache_std legacy_cache_ssl existing_image_tag
    local lancache_image_registry lancache_image_prefix lancache_image_channel lancache_image_tag
    env_file=$(runtime_env_file_for_install_dir "$install_dir")

    [[ -f "$env_file" ]] \
        || die "Missing $env_file. Cannot update safely because local runtime configuration is not available."

    print_step "Checking runtime .env"

    require_env_value_for_update IP_STANDARD "$env_file"

    # Resolve, verify, and persist the image registry/prefix/channel/tag
    # before any other .env mutation below (#665). This used to run after
    # several unrelated normalizations (session TTL, cache/state directory
    # migration, PROXY_SECURITY_MODE, ...), so a host whose resolved tag
    # lacks this platform would still have all of those already rewritten
    # into .env by the time assert_resolved_image_tag_platform_supported
    # aborted the update -- more partial state than necessary, even though
    # cmd_update's pre-update backup (taken before this function runs) still
    # makes it recoverable. Resolving into local variables first and calling
    # assert_resolved_image_tag_platform_supported before writing anything
    # means a platform failure here leaves every key in the rest of this
    # function's migration untouched, not just these four.
    lancache_image_registry=$(resolve_lancache_image_registry "$env_file")
    validate_lancache_image_registry "$lancache_image_registry"
    lancache_image_prefix=$(resolve_lancache_image_prefix "$env_file")
    validate_lancache_image_prefix "$lancache_image_prefix"
    lancache_image_channel=$(resolve_lancache_image_channel "$env_file")
    existing_image_tag=$(get_env_var LANCACHE_IMAGE_TAG "$env_file")
    if [[ "$preserve_image_tag" = "1" ]] \
        && [[ "$existing_image_tag" =~ ^(sha-[A-Za-z0-9][A-Za-z0-9_.-]{0,127}|v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?)$ ]]; then
        # Restoring a backup to roll back a bad channel-tracked image: keep
        # the archived immutable tag as-is instead of re-resolving it below,
        # which would silently pull whatever the channel (nightly/latest)
        # currently points to -- right after a bad release that is likely
        # still the same bad tag, defeating the whole point of the restore.
        validate_lancache_image_tag "$existing_image_tag"
        lancache_image_tag="$existing_image_tag"
    else
        # resolve_lancache_image_tag independently re-derives the same
        # tag-implies-channel inference resolve_lancache_image_channel just
        # computed (see its own docstring: "mirrors, and is deliberately more
        # specific than" that precedence) by reading env_file directly, so it
        # does not need lancache_image_channel written into .env first to
        # reach the same result -- verified by tracing every branch of both
        # functions.
        lancache_image_tag=$(resolve_lancache_image_tag "$env_file")
    fi
    assert_resolved_image_tag_platform_supported \
        "$lancache_image_registry" "$lancache_image_prefix" "$lancache_image_tag"
    set_env_key_if_empty_or_missing LANCACHE_IMAGE_REGISTRY "$lancache_image_registry" "$env_file"
    set_env_key_if_empty_or_missing LANCACHE_IMAGE_PREFIX "$lancache_image_prefix" "$env_file"
    set_env_key_if_empty_or_missing LANCACHE_IMAGE_CHANNEL "$lancache_image_channel" "$env_file"
    set_env_key LANCACHE_IMAGE_TAG "$lancache_image_tag" "$env_file"

    ui_session_ttl=$(get_env_var UI_SESSION_TTL_SECONDS "$env_file")
    ui_session_ttl="${ui_session_ttl:-$DEFAULT_UI_SESSION_TTL_SECONDS}"
    validate_ui_session_ttl_seconds "$ui_session_ttl" "$env_file"
    set_env_key_if_empty_or_missing UI_SESSION_TTL_SECONDS "$ui_session_ttl" "$env_file"

    # Listener addresses. IP_SSL may stay empty; that means SSL mode is off.
    append_env_key_if_missing IP_SSL "" "$env_file"
    ip_ssl=$(get_env_var IP_SSL "$env_file")
    ssl_enabled=0
    [[ -n "$ip_ssl" ]] && ssl_enabled=1
    set_env_key_if_empty_or_missing SSL_ENABLED "$ssl_enabled" "$env_file"

    # An install from before #819 has no AUTO_UPDATE_ENABLED key at all; "0"
    # (disabled) is the safe default, matching the interactive picker's own
    # opt-in default -- migration must never silently turn scheduled automatic
    # updates on for an existing install that never asked for them.
    set_env_key_if_empty_or_missing AUTO_UPDATE_ENABLED "0" "$env_file"

    state_root_default=$(production_state_root_default "$install_dir")
    state_dir=$(get_env_var LANCACHE_STATE_DIR "$env_file")
    state_dir="${state_dir:-$(legacy_state_root_or_default "$state_root_default")}"
    set_env_key_if_empty_or_missing LANCACHE_STATE_DIR "$state_dir" "$env_file"

    # CACHE_DIR is the canonical install-time cache path.
    # Legacy split cache keys can still be present on disk, but they must
    # collapse to one shared directory before update continues. Fall back to the
    # legacy /srv path or the shared state root when nothing is configured yet.
    cache_dir=$(get_env_var CACHE_DIR "$env_file")
    legacy_cache_std=$(get_env_var CACHE_DIR_STANDARD "$env_file")
    legacy_cache_ssl=$(get_env_var CACHE_DIR_SSL "$env_file")
    if [[ -z "$cache_dir" ]]; then
        if [[ -n "$legacy_cache_std" && -n "$legacy_cache_ssl" && "$legacy_cache_std" != "$legacy_cache_ssl" ]]; then
            die "CACHE_DIR_STANDARD and CACHE_DIR_SSL point to different paths in $env_file. Set CACHE_DIR to one shared cache directory before rerunning setup.sh update. The update will not keep two cache directories."
        fi

        cache_dir="${legacy_cache_std:-$legacy_cache_ssl}"
    fi
    cache_dir="${cache_dir:-$(legacy_dir_or_default "$(legacy_state_path cache)" "$state_dir/cache")}"
    set_env_key CACHE_DIR "$cache_dir" "$env_file"
    remove_env_key CACHE_DIR_STANDARD "$env_file"
    remove_env_key CACHE_DIR_SSL "$env_file"

    # Older repository-based prod installs stored state below one legacy root.
    # Preserve that root first, then derive per-service defaults from it so both
    # automatic setup updates and documented manual prod upgrades use one state
    # contract instead of several unrelated path edits.
    pdns_standard_default="$state_dir/pdns-standard"
    pdns_ssl_default="$state_dir/pdns-ssl"
    pdns_filter_state_default="$state_dir/pdns-filter-state"
    nats_data_default="$state_dir/nats"
    nats_conf_default="$state_dir/nats-conf"
    pdns_standard_dir=$(legacy_dir_or_default "$(legacy_state_path pdns-standard)" "$pdns_standard_default")
    pdns_ssl_dir=$(legacy_dir_or_default "$(legacy_state_path pdns-ssl)" "$pdns_ssl_default")
    pdns_filter_state_dir=$(legacy_dir_or_default "$(legacy_state_path pdns-filter-state)" "$pdns_filter_state_default")
    nats_data_dir=$(legacy_dir_or_default "$(legacy_state_path nats)" "$nats_data_default")
    nats_conf_dir=$(legacy_dir_or_default "$(legacy_state_path nats-conf)" "$nats_conf_default")
    set_optional_env_path_override_if_needed PDNS_STANDARD_DIR "$pdns_standard_dir" "$pdns_standard_default" "$env_file"
    set_optional_env_path_override_if_needed PDNS_SSL_DIR "$pdns_ssl_dir" "$pdns_ssl_default" "$env_file"
    set_optional_env_path_override_if_needed PDNS_FILTER_STATE_DIR "$pdns_filter_state_dir" "$pdns_filter_state_default" "$env_file"
    set_optional_env_path_override_if_needed NATS_DATA_DIR "$nats_data_dir" "$nats_data_default" "$env_file"
    set_optional_env_path_override_if_needed NATS_CONF_DIR "$nats_conf_dir" "$nats_conf_default" "$env_file"

    cache_max_size=$(get_env_var_nonempty CACHE_MAX_SIZE "$env_file")
    cache_max_gb=$(get_env_var_nonempty CACHE_MAX_GB "$env_file")
    if [[ -n "$cache_max_size" ]]; then
        cache_gb=$(cache_size_gb_from_env "$cache_max_size")
    else
        cache_gb=$(cache_size_gb_from_env "${cache_max_gb:-50}")
    fi

    set_env_key_if_empty_or_missing CACHE_MAX_SIZE "${cache_gb}g" "$env_file"
    cache_mem_mb=$(get_env_var CACHE_MEM_MB "$env_file")
    if ! is_positive_integer "$cache_mem_mb"; then
        cache_mem_mb="512"
    fi
    set_env_key CACHE_MEM_MB "$cache_mem_mb" "$env_file"
    set_env_key_if_empty_or_missing CACHE_SLICE_SIZE "8m" "$env_file"
    set_env_key_if_empty_or_missing CACHE_VALID_HIT "365d" "$env_file"
    set_env_key_if_empty_or_missing CACHE_VALID_ANY "1m" "$env_file"
    set_env_key_if_empty_or_missing CACHE_INACTIVE "365d" "$env_file"

    append_env_key_if_missing PROXY_ALLOWED_CLIENT_CIDRS "" "$env_file"
    set_env_key_if_empty_or_missing NGINX_UPSTREAM_RESOLVER "8.8.8.8 8.8.4.4 [2001:4860:4860::8888] [2001:4860:4860::8844]" "$env_file"
    migrate_proxy_security_mode_for_update "$env_file"
    set_env_key_if_empty_or_missing PROXY_SECURITY_MODE "lazy" "$env_file"
    # LANCACHE_IMAGE_REGISTRY/PREFIX/CHANNEL/TAG (including the #731
    # preserve_image_tag restore-rollback exception) were already resolved,
    # verified, and written near the top of this function, before any of the
    # migration above -- see the #665 comment there.

    set_env_key_if_empty_or_missing CACHE_MAX_GB "$cache_gb" "$env_file"
    append_env_migrated_assignment_if_missing UI_BIND_IP IP_STANDARD "$(get_env_var IP_STANDARD "$env_file")" "$env_file"

    # DHCP/Kea can stay disabled, but the keys must exist so Compose and the UI
    # read one complete runtime configuration.
    append_env_key_if_missing DHCP_ENABLED "0" "$env_file"
    kea_data_default="$state_dir/kea"
    kea_data_dir=$(legacy_dir_or_default "$(legacy_state_path kea)" "$kea_data_default")
    set_optional_env_path_override_if_needed KEA_DATA_DIR "$kea_data_dir" "$kea_data_default" "$env_file"
    append_env_key_if_missing DHCP_SUBNET "" "$env_file"
    append_env_key_if_missing DHCP_GATEWAY "" "$env_file"
    append_env_key_if_missing DHCP_RANGE_START "" "$env_file"
    append_env_key_if_missing DHCP_RANGE_END "" "$env_file"

    compose_profiles=$(get_env_var COMPOSE_PROFILES "$env_file")
    dhcp_enabled=$(get_env_var DHCP_ENABLED "$env_file")
    dhcp_mode=$(get_env_var DHCP_MODE "$env_file")
    dhcp_mode=${dhcp_mode:-${DHCP_MODE:-}}
    if [[ "${dhcp_mode}" = "1" ]]; then
        dhcp_mode=kea
    elif [[ -z "${dhcp_mode}" ]]; then
        if [[ ",$compose_profiles," = *,dhcp-proxy,* ]]; then
            dhcp_mode="dnsmasq-proxy"
        elif [[ ",$compose_profiles," = *,dhcp-kea,* || "$dhcp_enabled" = "1" ]]; then
            dhcp_mode="kea"
        else
            dhcp_mode="disabled"
        fi
    fi

    if ! is_valid_dhcp_mode "$dhcp_mode"; then
        if [[ ",$compose_profiles," = *,dhcp-proxy,* ]]; then
            dhcp_mode="dnsmasq-proxy"
        elif [[ ",$compose_profiles," = *,dhcp-kea,* || "$dhcp_enabled" = "1" ]]; then
            dhcp_mode="kea"
        else
            dhcp_mode="disabled"
        fi
    fi

    append_env_key_if_missing DHCP_MODE "disabled" "$env_file"
    set_env_key DHCP_MODE "$dhcp_mode" "$env_file"
    ip_standard=$(get_env_var IP_STANDARD "$env_file")
    ip_ssl=$(get_env_var IP_SSL "$env_file")
    dhcp_subnet_start=$(get_env_var DHCP_SUBNET_START "$env_file")
    dhcp_dns_primary=$(get_env_var DHCP_DNS_PRIMARY "$env_file")
    dhcp_dns_secondary=$(get_env_var DHCP_DNS_SECONDARY "$env_file")
    upstream_dhcp_ip=$(get_env_var UPSTREAM_DHCP_IP "$env_file")
    # Issue #450: additional optional dnsmasq relay/proxy fields. Unlike the
    # four values above, none of these are required in dnsmasq-proxy mode --
    # an empty value just means entrypoint.sh renders no directive for it.
    append_env_key_if_missing DHCP_PROXY_INTERFACE "" "$env_file"
    append_env_key_if_missing DHCP_PROXY_ROUTER "" "$env_file"
    append_env_key_if_missing DHCP_NTP_SERVERS "" "$env_file"
    append_env_key_if_missing DHCP_PROXY_DOMAIN "" "$env_file"
    append_env_key_if_missing DHCP_PROXY_BOOT_FILENAME "" "$env_file"
    append_env_key_if_missing DHCP_PROXY_BOOT_SERVER "" "$env_file"
    append_env_key_if_missing DHCP_PROXY_CUSTOM_OPTIONS "" "$env_file"
    dhcp_proxy_interface=$(get_env_var DHCP_PROXY_INTERFACE "$env_file")
    dhcp_proxy_router=$(get_env_var DHCP_PROXY_ROUTER "$env_file")
    dhcp_ntp_servers=$(get_env_var DHCP_NTP_SERVERS "$env_file")
    dhcp_proxy_domain=$(get_env_var DHCP_PROXY_DOMAIN "$env_file")
    dhcp_proxy_boot_filename=$(get_env_var DHCP_PROXY_BOOT_FILENAME "$env_file")
    dhcp_proxy_boot_server=$(get_env_var DHCP_PROXY_BOOT_SERVER "$env_file")

    case "$dhcp_mode" in
        dnsmasq-proxy)
            is_dnsmasq_subnet_start "$dhcp_subnet_start" \
                || die "DHCP_MODE=dnsmasq-proxy requires a proxy-DHCP subnet start ending in .0 in $env_file. Set the subnet base for your LAN, then rerun setup.sh update."
            is_valid_ipv4 "$dhcp_dns_primary" \
                || die "DHCP_MODE=dnsmasq-proxy requires a real DHCP_DNS_PRIMARY in $env_file. Set the DNS option that proxy-DHCP/PXE clients should receive, then rerun setup.sh update."
            if [[ -z "$dhcp_dns_secondary" ]]; then
                dhcp_dns_secondary="$dhcp_dns_primary"
            else
                is_valid_ipv4 "$dhcp_dns_secondary" \
                    || die "DHCP_MODE=dnsmasq-proxy has invalid DHCP_DNS_SECONDARY in $env_file. Set a valid IPv4 address or leave it empty to reuse DHCP_DNS_PRIMARY."
            fi
            is_valid_ipv4 "$upstream_dhcp_ip" \
                || die "DHCP_MODE=dnsmasq-proxy requires the real router DHCP IP in UPSTREAM_DHCP_IP in $env_file. Set it, then rerun setup.sh update."
            # Optional fields: only validated when non-empty, since leaving
            # them empty is the supported "not using this option" state.
            [[ -z "$dhcp_proxy_interface" ]] || is_valid_dhcp_proxy_interface "$dhcp_proxy_interface" \
                || die "DHCP_PROXY_INTERFACE in $env_file must be a valid interface name (letters, digits, '.', '-', '_') or empty."
            [[ -z "$dhcp_proxy_router" ]] || is_valid_ipv4 "$dhcp_proxy_router" \
                || die "DHCP_PROXY_ROUTER in $env_file must be a valid IPv4 address or empty."
            if [[ -n "$dhcp_ntp_servers" ]]; then
                IFS=',' read -r -a _dhcp_ntp_check <<< "$dhcp_ntp_servers"
                for _dhcp_ntp_ip in "${_dhcp_ntp_check[@]}"; do
                    _dhcp_ntp_ip="${_dhcp_ntp_ip//[[:space:]]/}"
                    [[ -z "$_dhcp_ntp_ip" ]] || is_valid_ipv4 "$_dhcp_ntp_ip" \
                        || die "DHCP_NTP_SERVERS in $env_file must be a comma-separated list of valid IPv4 addresses."
                done
            fi
            [[ -z "$dhcp_proxy_domain" ]] || is_valid_dhcp_proxy_domain "$dhcp_proxy_domain" \
                || die "DHCP_PROXY_DOMAIN in $env_file must be a valid DNS domain name or empty."
            [[ -z "$dhcp_proxy_boot_filename" ]] || is_valid_dhcp_proxy_boot_filename "$dhcp_proxy_boot_filename" \
                || die "DHCP_PROXY_BOOT_FILENAME in $env_file must not contain whitespace or commas."
            [[ -z "$dhcp_proxy_boot_server" ]] || is_valid_ipv4 "$dhcp_proxy_boot_server" \
                || die "DHCP_PROXY_BOOT_SERVER in $env_file must be a valid IPv4 address or empty."
            ;;
        *)
            is_valid_ipv4 "$dhcp_subnet_start" || dhcp_subnet_start=""
            is_valid_ipv4 "$dhcp_dns_primary" || dhcp_dns_primary="$ip_standard"
            is_valid_ipv4 "$dhcp_dns_secondary" || dhcp_dns_secondary="${ip_ssl:-$ip_standard}"
            is_valid_ipv4 "$upstream_dhcp_ip" || upstream_dhcp_ip=""
            ;;
    esac

    set_env_key DHCP_SUBNET_START "$dhcp_subnet_start" "$env_file"
    set_env_key DHCP_DNS_PRIMARY "$dhcp_dns_primary" "$env_file"
    set_env_key DHCP_DNS_SECONDARY "$dhcp_dns_secondary" "$env_file"
    set_env_key UPSTREAM_DHCP_IP "$upstream_dhcp_ip" "$env_file"
    set_env_key DHCP_PROXY_INTERFACE "$dhcp_proxy_interface" "$env_file"
    set_env_key DHCP_PROXY_ROUTER "$dhcp_proxy_router" "$env_file"
    set_env_key DHCP_NTP_SERVERS "$dhcp_ntp_servers" "$env_file"
    set_env_key DHCP_PROXY_DOMAIN "$dhcp_proxy_domain" "$env_file"
    set_env_key DHCP_PROXY_BOOT_FILENAME "$dhcp_proxy_boot_filename" "$env_file"
    set_env_key DHCP_PROXY_BOOT_SERVER "$dhcp_proxy_boot_server" "$env_file"

    # Mandatory service tokens. Preserve real values; regenerate empty values
    # and known placeholders like CHANGE_ME_* or lancache-*-secret.
    ensure_secret_env_key KEA_CTRL_TOKEN "$env_file" hex32
    ensure_secret_env_key DDNS_TSIG_KEY "$env_file" base64_32
    ensure_secret_env_key PDNS_API_KEY "$env_file" hex32
    set_env_key_if_empty_or_missing NATS_UI_USER "lancache-ui" "$env_file"
    ensure_secret_env_key NATS_UI_PASSWORD "$env_file" hex32
    set_env_key_if_empty_or_missing NATS_DNS_WRITER_USER "lancache-dns-writer" "$env_file"
    ensure_secret_env_key NATS_DNS_WRITER_PASSWORD "$env_file" hex32
    set_env_key_if_empty_or_missing NATS_DNS_REPLICA_USER "lancache-dns-replica" "$env_file"
    ensure_secret_env_key NATS_DNS_REPLICA_PASSWORD "$env_file" hex32
    set_env_key_if_empty_or_missing NATS_CALLOUT_USER "lancache-nats-callout" "$env_file"
    ensure_secret_env_key NATS_CALLOUT_PASSWORD "$env_file" hex32
    ensure_secret_env_key SECONDARY_REGISTRATION_TOKEN "$env_file" hex32

    append_env_key_if_missing COMPOSE_PROFILES "" "$env_file"
    set_env_key COMPOSE_PROFILES \
        "$(compose_profiles_for_runtime "$compose_profiles" "$(get_env_var SSL_ENABLED "$env_file")" "$dhcp_mode")" \
        "$env_file"

    # UI auth stays a user choice. A configured username must have a real
    # password; otherwise the UI is explicitly marked insecure.
    append_env_key_if_missing UI_AUTH_USER "" "$env_file"
    append_env_key_if_missing UI_AUTH_PASSWORD "" "$env_file"
    append_env_key_if_missing UI_SESSION_TTL_SECONDS "86400" "$env_file"
    ui_user=$(get_env_var UI_AUTH_USER "$env_file")
    ui_password=$(get_env_var UI_AUTH_PASSWORD "$env_file")
    if [[ -n "$ui_user" ]] && ! env_key_has_usable_secret UI_AUTH_PASSWORD "$env_file"; then
        ui_generated_password=$(generate_secret_value UI_AUTH_PASSWORD alnum20)
        set_env_key UI_AUTH_PASSWORD "$ui_generated_password" "$env_file"
        print_ok "Generated missing Admin UI password because UI_AUTH_USER is set"
    fi

    allow_insecure_ui=false
    [[ -z "$ui_user" && -z "$ui_password" ]] && allow_insecure_ui=true
    append_env_key_if_missing ALLOW_INSECURE_UI "$allow_insecure_ui" "$env_file"

    print_ok ".env is complete for the current quickstart template"
}

# The apt package that provides a binary sometimes has a different name than
# the binary itself -- `dig` moved from the `dnsutils` metapackage to
# `bind9-dnsutils` on modern Debian/Ubuntu, so `apt-get install dig` fails
# outright. Falls back to the binary name for the common case (tar, rsync,
# openssl, ...) where package and binary names match.
package_name_for_tool() {
    case "$1" in
        dig)
            if apt_package_available bind9-dnsutils; then
                printf '%s\n' bind9-dnsutils
            else
                printf '%s\n' dnsutils
            fi
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

# Backup/restore may run on minimal hosts. Install only the missing tools needed
# for the requested operation instead of expanding the base installer footprint.
install_missing_tools() {
    local -a missing=() packages=() tools=("$@")
    local tool
    for tool in "${tools[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    (( ${#missing[@]} == 0 )) && return 0
    print_warn "Missing required tool(s): ${missing[*]} — installing now..."
    command -v apt-get >/dev/null 2>&1 || die "Cannot install missing tools automatically; install: ${missing[*]}"
    for tool in "${missing[@]}"; do
        packages+=("$(package_name_for_tool "$tool")")
    done
    apt-get update -y
    apt-get install -y --no-install-recommends "${packages[@]}" \
        || die "Failed to install required tool(s): ${missing[*]}"
    for tool in "${missing[@]}"; do
        command -v "$tool" >/dev/null 2>&1 \
            || die "$tool is still missing after installing package(s): ${packages[*]}"
    done
}

# Prints the newline-separated list of absolute host paths that a backup
# (config or full) should include: .env(s), compose file, certs/scripts,
# deploy/prod's external repo-root inputs, and every per-service state
# directory that actually exists on disk — falling back through
# get_env_var -> state_dir default the same way migrate_env_for_update does,
# so a backup captures the real paths in use even on an install that has
# never been through migrate_env_for_update. "full" mode additionally
# includes the (potentially huge) cache directories.
backup_manifest() {
    local install_dir="$1" mode="$2"
    local env_file cache_env_file
    local cache_dir cache_std cache_ssl kea_dir nats_conf_dir nats_data_dir pdns_filter_state_dir pdns_ssl_dir pdns_standard_dir state_dir
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    cache_env_file="$install_dir/.env"
    state_dir=$(get_env_var LANCACHE_STATE_DIR "$env_file")
    state_dir="${state_dir:-$(legacy_state_root_or_default "$(production_state_root_default "$install_dir")")}"
    cache_dir=$(get_env_var CACHE_DIR "$env_file")
    cache_std=$(get_env_var CACHE_DIR_STANDARD "$env_file")
    cache_ssl=$(get_env_var CACHE_DIR_SSL "$env_file")
    kea_dir=$(get_env_var KEA_DATA_DIR "$env_file")
    nats_conf_dir=$(get_env_var NATS_CONF_DIR "$env_file")
    nats_data_dir=$(get_env_var NATS_DATA_DIR "$env_file")
    pdns_filter_state_dir=$(get_env_var PDNS_FILTER_STATE_DIR "$env_file")
    pdns_ssl_dir=$(get_env_var PDNS_SSL_DIR "$env_file")
    pdns_standard_dir=$(get_env_var PDNS_STANDARD_DIR "$env_file")
    cache_std="${cache_std:-$state_dir/cache}"
    cache_ssl="${cache_ssl:-$cache_std}"
    kea_dir="${kea_dir:-$state_dir/kea}"
    nats_conf_dir="${nats_conf_dir:-$state_dir/nats-conf}"
    nats_data_dir="${nats_data_dir:-$state_dir/nats}"
    pdns_filter_state_dir="${pdns_filter_state_dir:-$state_dir/pdns-filter-state}"
    pdns_ssl_dir="${pdns_ssl_dir:-$state_dir/pdns-ssl}"
    pdns_standard_dir="${pdns_standard_dir:-$state_dir/pdns-standard}"

    printf '%s\n' "$cache_env_file"
    [[ "$env_file" != "$cache_env_file" ]] && printf '%s\n' "$env_file"
    printf '%s\n' "$install_dir/docker-compose.yml" "$install_dir/certs" "$install_dir/scripts"
    deploy_prod_repo_input_paths "$install_dir"
    [[ -n "${pdns_standard_dir:-}" && -d "$pdns_standard_dir" ]] && printf '%s\n' "$pdns_standard_dir"
    [[ -n "${pdns_ssl_dir:-}" && -d "$pdns_ssl_dir" ]] && printf '%s\n' "$pdns_ssl_dir"
    [[ -n "${pdns_filter_state_dir:-}" && -d "$pdns_filter_state_dir" ]] && printf '%s\n' "$pdns_filter_state_dir"
    [[ -n "${nats_data_dir:-}" && -d "$nats_data_dir" ]] && printf '%s\n' "$nats_data_dir"
    [[ -n "${nats_conf_dir:-}" && -d "$nats_conf_dir" ]] && printf '%s\n' "$nats_conf_dir"
    [[ -d "$(legacy_state_path pdns-standard)" ]] && printf '%s\n' "$(legacy_state_path pdns-standard)"
    [[ -d "$(legacy_state_path pdns-ssl)" ]] && printf '%s\n' "$(legacy_state_path pdns-ssl)"
    [[ -d "$(legacy_state_path pdns-filter-state)" ]] && printf '%s\n' "$(legacy_state_path pdns-filter-state)"
    [[ -d "$(legacy_state_path kea)" ]] && printf '%s\n' "$(legacy_state_path kea)"
    [[ -d "$(legacy_state_path nats)" ]] && printf '%s\n' "$(legacy_state_path nats)"
    [[ -d "$(legacy_state_path nats-conf)" ]] && printf '%s\n' "$(legacy_state_path nats-conf)"
    [[ -n "${kea_dir:-}" && -d "$kea_dir" ]] && printf '%s\n' "$kea_dir"
    if [[ "$mode" = "full" ]]; then
        [[ -n "${cache_dir:-}" && -d "$cache_dir" ]] && printf '%s\n' "$cache_dir"
        [[ -n "${cache_std:-}" && -d "$cache_std" ]] && printf '%s\n' "$cache_std"
        [[ -n "${cache_ssl:-}" && "$cache_ssl" != "$cache_std" && -d "$cache_ssl" ]] && printf '%s\n' "$cache_ssl"
        [[ -d "$(legacy_state_path cache)" ]] && printf '%s\n' "$(legacy_state_path cache)"
    fi
    true
}

# Prevent recursive backups such as /var/backups being archived into itself.
# That case can fill disks and produce archives that cannot be restored safely.
path_is_inside() {
    local child="$1" parent="$2"
    child=$(realpath -m "$child")
    parent=$(realpath -m "$parent")
    [[ "$child" = "$parent" || "$child" = "$parent"/* ]]
}

# Compose helpers are deliberately no-ops when the stack is unavailable so
# config-only backup/restore can still handle partial or damaged installs.
compose_stack_available() {
    local install_dir="$1"
    [[ -f "$install_dir/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1
}

# Reports whether any container in this compose project is currently in a
# running state (plain `ps -q`, not `--all`). Backup/restore call this BEFORE
# compose_stack_stop so their cleanup traps can restart the stack only if it
# was actually running beforehand, instead of unconditionally undoing a
# deliberate prior stop (e.g. `systemctl stop lancache.service`, or manual
# maintenance) -- see #669.
compose_stack_running() {
    local install_dir="$1" env_file
    compose_stack_available "$install_dir" || return 1
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    [[ -n "$(cd "$install_dir" && docker compose --env-file "$env_file" ps -q 2>/dev/null)" ]]
}

# Stops the stack before a backup/restore so files on disk are consistent
# (no service writing to cache/state mid-copy). A stop failure only warns,
# not dies, since backup/restore should still be attempted even if the stack
# was already in a bad state.
compose_stack_stop() {
    local install_dir="$1"
    local env_file
    compose_stack_available "$install_dir" || return 0
    print_step "Stopping stack for consistent backup/restore"
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    (cd "$install_dir" && docker compose --env-file "$env_file" stop) || print_warn "docker compose stop failed — continuing"
}

# Counterpart to compose_stack_stop, used by backup/restore cleanup traps to
# bring the stack back up. Also only warns on failure so the trap always
# finishes cleanup instead of getting stuck mid-exit.
compose_stack_start() {
    local install_dir="$1"
    local env_file
    compose_stack_available "$install_dir" || return 0
    print_step "Starting stack"
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    (cd "$install_dir" && docker compose --env-file "$env_file" up -d) || print_warn "docker compose up failed — start the stack manually"
}

# Runs `docker compose config` as a dry-run check. Called both before and
# after pulling images during update, so a migration or pull that produced an
# invalid compose config is caught before containers are actually restarted.
validate_compose_config() {
    local install_dir="$1"
    local env_file
    local -a compose_files
    print_step "Validating Docker Compose configuration"
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    mapfile -t compose_files < <(compose_file_args_for_install_dir "$install_dir" "$env_file")
    (cd "$install_dir" && docker compose --env-file "$env_file" "${compose_files[@]}" config --quiet) \
        || die "Docker Compose configuration is not valid. The stack was not pulled or restarted."
    print_ok "Docker Compose configuration is valid"
}

# Resolves the effective Docker Compose project name for a compose directory.
# Compose itself resolves this, in priority order, from: the
# COMPOSE_PROJECT_NAME environment variable, a COMPOSE_PROJECT_NAME entry in
# the env file, the top-level `name:` key in docker-compose.yml, and finally
# the containing directory's basename. All three of this repo's compose files
# (deploy/quickstart, deploy/dev, deploy/prod) pin `name: lancache-ng`, so the
# yaml fallback is what actually resolves today for every install — but
# honoring an operator override first keeps this correct if that ever
# changes. Reads the yaml directly (rather than shelling out to `docker
# compose config`) so it also works against an archived, not-yet-restored
# compose directory that has no running containers, and requires no Docker
# JSON parsing dependency (jq is not otherwise used in this script).
compose_project_name() {
    local compose_dir="$1" env_file="$2" name
    name="${COMPOSE_PROJECT_NAME:-}"
    [[ -n "$name" ]] || name=$(get_env_var COMPOSE_PROJECT_NAME "$env_file")
    if [[ -z "$name" && -f "$compose_dir/docker-compose.yml" ]]; then
        name=$(sed -n 's/^name:[[:space:]]*//p' "$compose_dir/docker-compose.yml" | head -1)
    fi
    name="${name:-$(basename "$compose_dir")}"
    printf '%s\n' "$name"
}

# The proxy-cache Docker volume's project-prefixed name (e.g.
# "lancache-ng_proxy-cache"), derived rather than looked up via `docker volume
# ls`, so it can be classified even before the volume exists (a fresh
# install's first backup, run before any container has started). Both prod's
# bind-backed named volume and dev's plain named volume share this same
# `<project>_proxy-cache` name, so a single name match excludes both (see
# #669 #1: quickstart's cache is a plain bind-mount, type "bind", already
# filtered out of compose_volume_names below without any special-casing).
compose_cache_volume_name() {
    local install_dir="$1" env_file="$2" project
    project=$(compose_project_name "$install_dir" "$env_file")
    printf '%s_proxy-cache\n' "$project"
}

# Lists the distinct Docker named-volume names belonging to this compose
# project, as the union of two discovery methods:
#   1. Mounts of any container in the project (including stopped ones, via
#      `ps --all`) — picks up volumes attached to containers that predate the
#      current compose file.
#   2. `docker volume ls` filtered by the compose project label — needed
#      because `lancache.service`'s `ExecStop=docker compose down` REMOVES
#      containers (not just stops them), so after `systemctl stop
#      lancache.service` method 1 alone finds nothing even though the named
#      volumes (NATS/PowerDNS state, etc.) still exist on disk (#669 #5).
compose_volume_names() {
    local install_dir="$1" container env_file project
    compose_stack_available "$install_dir" || return 0
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    project=$(compose_project_name "$install_dir" "$env_file")
    {
        while IFS= read -r container; do
            [[ -n "$container" ]] || continue
            docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' "$container"
        done < <(cd "$install_dir" && docker compose --env-file "$env_file" ps --all -q 2>/dev/null)
        docker volume ls --filter "label=com.docker.compose.project=${project}" --format '{{.Name}}' 2>/dev/null
    } | sort -u
}

# Archives every Docker named volume used by this stack into its own tar file
# under volume_root, using a throwaway alpine container to read the volume
# read-only — avoids needing tar/permissions to reach the volume's real
# on-disk location directly, which varies by Docker storage driver.
#
# The cache volume is skipped outside of `--full` mode: it can be hundreds of
# GB on a prod install, and config-mode backups (including the automatic
# pre-update rollback backup every `setup.sh update` runs) are documented as
# excluding cache payloads — backup_manifest() already gates the bind-mounted
# cache directories the same way. Docker still reports the bind-backed
# `proxy-cache` volume's mount `.Type` as "volume" (its driver_opts make it a
# bind mount under the hood, but Compose still models it as a named volume),
# so without this it slipped through the mode gate entirely (#669 #1).
backup_compose_volumes() {
    local install_dir="$1" volume_root="$2" mode="$3" volume env_file cache_volume
    compose_stack_available "$install_dir" || return 0
    mkdir -p "$volume_root"
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    cache_volume=$(compose_cache_volume_name "$install_dir" "$env_file")
    while IFS= read -r volume; do
        [[ -n "$volume" ]] || continue
        if [[ "$mode" != "full" && "$volume" = "$cache_volume" ]]; then
            print_warn "Skipping cache volume in $mode-mode backup: $volume"
            continue
        fi
        print_ok "Including Docker volume: $volume"
        docker run --rm \
            -v "${volume}:/volume:ro" \
            -v "${volume_root}:/backup" \
            alpine sh -c 'cd /volume && tar -cpf "/backup/$1.tar" .' sh "$volume"
    done < <(compose_volume_names "$install_dir")
}

# Counterpart to backup_compose_volumes: recreates each volume (if missing)
# and replaces its full contents from the matching archive, wiping existing
# volume content first (including dotfiles) so a restore is a clean
# replacement rather than a merge with whatever was already in the volume.
# Dies (rather than skipping) if the backup has volume payloads but Docker
# is unavailable, since silently skipping would restore an incomplete stack.
restore_compose_volumes() {
    local install_dir="$1" volume_root="$2" volume archive
    [[ -d "$volume_root" ]] || return 0
    compose_stack_available "$install_dir" \
        || die "Backup contains Docker volume payloads, but Docker/compose is not available for $install_dir. Install Docker and restore again."
    while IFS= read -r archive; do
        volume="$(basename "$archive" .tar)"
        [[ -n "$volume" ]] || continue
        print_ok "Restoring Docker volume: $volume"
        docker volume create "$volume" >/dev/null
        docker run --rm \
            -v "${volume}:/volume" \
            -v "${volume_root}:/backup:ro" \
            alpine sh -c 'rm -rf /volume/* /volume/..?* /volume/.[!.]* 2>/dev/null || true; cd /volume && tar -xpf "/backup/$1.tar"' sh "$volume"
    done < <(find "$volume_root" -maxdepth 1 -type f -name '*.tar' | sort)
}

# The compose project name ("lancache-ng") is fixed across every compose file
# in this repo (deploy/quickstart, deploy/dev, deploy/prod), not derived from
# install_dir. Two installs on the same Docker host therefore resolve to the
# SAME named Docker volumes regardless of install directory. `cmd_restore`'s
# own --help documents remapping a restore to a different [install-dir] as
# supported, but restore only stops the stack at the *target* install_dir
# before restore_compose_volumes wipes and reloads those shared volumes — if
# a DIFFERENT install on the same host is still actively running under the
# same project name, its volumes get clobbered without ever being stopped.
#
# This is a real, documented constraint of same-host multi-install setups:
# giving each install a unique COMPOSE_PROJECT_NAME would fix it, but would
# also orphan every EXISTING install's already-created volumes on its next
# `docker compose up` (the volumes are named `<old-project>_<name>`, and
# nothing would reattach them to a renamed project) — a real regression
# swapped for a narrower one. So this guards against the unsafe case instead
# of silently working around it: refuse the restore outright rather than
# risk destroying another install's live state.
guard_restore_shared_project_volumes() {
    local install_dir="$1" project="$2" container working_dir
    command -v docker >/dev/null 2>&1 || return 0
    while IFS= read -r container; do
        [[ -n "$container" ]] || continue
        working_dir=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container" 2>/dev/null)
        [[ -n "$working_dir" ]] || continue
        working_dir=$(realpath -m "$working_dir")
        if [[ "$working_dir" != "$install_dir" ]]; then
            die "Refusing to restore: a running stack for compose project '$project' is already active at $working_dir, which is not the restore target ($install_dir). Both installs share the same Docker-managed volumes because the compose project name is not per-install-dir (see #669). Stop the other install first (cd \"$working_dir\" && docker compose down), or restore into $working_dir instead."
        fi
    done < <(docker ps --filter "label=com.docker.compose.project=${project}" --format '{{.ID}}' 2>/dev/null)
}

# Snapshots the exact image references/digests in use at backup time (JSON
# preferred, falling back to plain `docker compose images` text on older
# Compose versions that lack --format json), purely as rollback/debugging
# reference — never restored automatically, only warns on failure.
record_image_revisions() {
    local install_dir="$1" output="$2" env_file
    compose_stack_available "$install_dir" || return 0
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    (cd "$install_dir" && docker compose --env-file "$env_file" images --format json > "$output") 2>/dev/null \
        || (cd "$install_dir" && docker compose --env-file "$env_file" images > "$output") 2>/dev/null \
        || print_warn "Could not record current image revisions"
}

# Config backups are the update rollback path. Full backups additionally include
# cache payloads and may be huge, so they stay an explicit operator choice.
cmd_backup() {
    local mode="config" install_dir="/opt/lancache-ng" backup_root="/var/backups/lancache-ng"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full) mode="full"; shift ;;
            --config) mode="config"; shift ;;
            --dest) backup_root="${2:?Missing value for --dest}"; shift 2 ;;
            *) install_dir="$1"; shift ;;
        esac
    done
    install_dir=$(realpath -m "$install_dir")
    backup_root=$(realpath -m "$backup_root")
    [[ -f "$install_dir/docker-compose.yml" && -f "$(runtime_env_file_for_install_dir "$install_dir")" ]] \
        || die "No stack found in $install_dir. Run ./setup.sh first."
    install_missing_tools tar rsync

    local stamp dest archive rel path old_umask stack_stopped=0 stack_was_running=0 backup_paused_convergence=0
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    dest="$backup_root/$stamp"
    archive="$backup_root/lancache-ng-${mode}-${stamp}.tar.gz"
    mkdir -p "$backup_root"
    old_umask=$(umask)
    umask 077
    mkdir -p "$dest/rootfs"
    backup_cleanup() {
        local status=$?
        [[ "$stack_stopped" = "1" && "$stack_was_running" = "1" ]] && compose_stack_start "$install_dir"
        [[ "$backup_paused_convergence" = "1" ]] && resume_lancache_convergence_after_update
        rm -rf "$dest"
        umask "$old_umask"
        trap - EXIT
        return "$status"
    }
    trap backup_cleanup EXIT

    # Only pause the convergence timer ourselves if it isn't already paused by
    # an enclosing cmd_update run: cmd_update pauses before calling
    # `cmd_backup --config` for its pre-update rollback backup, and pausing a
    # second time here would overwrite CONVERGENCE_TIMER_WAS_* with "already
    # stopped", so cmd_update's own resume at the end would never re-enable
    # the timer. A STANDALONE `setup.sh backup` (dispatched directly, no
    # cmd_update wrapper) has nothing pausing it otherwise, so
    # lancache-converge.timer could fire `docker compose up -d
    # --remove-orphans` mid-backup and restart the stack we just stopped for
    # a consistent copy (#669 #2).
    if [[ "${UPDATE_CONVERGENCE_PAUSED:-0}" != "1" ]]; then
        # Set the cleanup flag BEFORE calling the mutating pause helper, not
        # after: pause_lancache_convergence_for_update can `die` partway
        # through (e.g. it stops lancache-converge.timer successfully but
        # then fails to `systemctl disable` it), and `die` exits, which
        # fires backup_cleanup via the EXIT trap above immediately. If the
        # flag were only set on a successful return from the helper, that
        # trap would see backup_paused_convergence=0 and skip resume
        # entirely, leaving convergence disabled after a failed backup
        # attempt. cmd_update's own UPDATE_CONVERGENCE_PAUSED=1 (set before
        # its call to the same helper) already establishes this
        # set-before-call ordering as the pattern for this script (PR #748
        # review).
        backup_paused_convergence=1
        pause_lancache_convergence_for_update
    fi

    print_step "Creating $mode backup"
    backup_manifest "$install_dir" "$mode" | sort -u > "$dest/manifest.txt"
    while IFS= read -r path; do
        [[ -e "$path" ]] || continue
        if path_is_inside "$backup_root" "$path"; then
            die "Backup destination must not be inside included path: $path"
        fi
    done < "$dest/manifest.txt"

    record_image_revisions "$install_dir" "$dest/image-revisions.txt"
    # Captured before compose_stack_stop so backup_cleanup only restarts the
    # stack if it was actually running beforehand, instead of unconditionally
    # undoing a deliberate prior stop (#669 #3).
    compose_stack_running "$install_dir" && stack_was_running=1
    compose_stack_stop "$install_dir"
    stack_stopped=1

    while IFS= read -r path; do
        [[ -e "$path" ]] || continue
        rel="${path#/}"
        if [[ -d "$path" ]]; then
            mkdir -p "$dest/rootfs/$rel"
            rsync -aH --numeric-ids "$path/" "$dest/rootfs/$rel/"
        else
            mkdir -p "$dest/rootfs/$(dirname "$rel")"
            rsync -aH --numeric-ids "$path" "$dest/rootfs/$(dirname "$rel")/"
        fi
        print_ok "Included: $path"
    done < "$dest/manifest.txt"
    backup_compose_volumes "$install_dir" "$dest/docker-volumes" "$mode"

    cat > "$dest/README.txt" <<EOF
LanCache-NG backup created at $stamp UTC
Mode: $mode
Install directory: $install_dir

Config backups include text/configuration, Docker named volumes, and runtime databases needed for update rollback.
The cache volume is always excluded from config backups, since it can be very large.
Full backups additionally include cache directories and the cache volume, which can be very large.
Restore with: ./setup.sh restore $archive $install_dir
EOF
    tar -C "$backup_root" -czf "$archive" "$stamp"
    chmod 600 "$archive"
    print_ok "Backup written: $archive"
    backup_cleanup
}

# Restores a setup.sh backup archive into install_dir, remapping paths when
# install_dir differs from the directory the archive was originally taken
# from (both the install tree itself and, for deploy/prod archives, the
# separate repo-root inputs from deploy_prod_repo_input_paths). Manifest paths
# under the archived install directory are skipped in the generic copy loop
# and handled separately first, since they need the path-remap/sed rewrite
# rather than a literal restore to their original absolute path.
#
# A restored archive can carry a legacy or otherwise unconverged .env (older
# split cache keys, a stale strict security mode, keys a later release added)
# because it was captured verbatim at backup time -- unlike cmd_update, which
# always runs migrate_env_for_update + validate_compose_config before it lets
# the stack come back up. Issue #639: after files/volumes are restored, this
# function runs that same convergence path so a restore never leaves an
# install silently un-migrated, requiring an undocumented manual
# `setup.sh update` afterward. Following AG-OP-010 (validate before restart
# when a failed validation would leave the install worse off), a migration or
# validation failure here is fail-closed: stack_stopped is cleared before
# die() runs so the already-stopped stack is left stopped instead of being
# started against a config that failed to converge or validate. The restored
# files/volumes and whatever migrate_env_for_update managed to write to .env
# before failing are left on disk either way; rerun `setup.sh update` once the
# reported problem is fixed.
#
# If the archived install tree has no .env.local (a backup that predates the
# .env.local split, or a deploy/prod backup taken before an operator ever
# created one), moves any .env.local currently sitting at install_dir out of
# the way instead of leaving it in place. Without this, rsync (deliberately
# run without --delete, see cmd_restore's own comment below) leaves a
# pre-restore .env.local completely untouched, and
# runtime_env_file_for_install_dir() prefers .env.local over .env whenever it
# exists -- so every subsequent compose/update/debug call would keep reading
# the stale pre-restore override instead of the archive's just-restored
# .env, silently defeating the point of a rollback restore. The stale file is
# renamed rather than deleted outright, so it stays available for manual
# recovery instead of being silently lost. Idempotent: a second restore of
# the same archive against the same target finds no .env.local left to move
# and is a no-op.
# Rejects a path that cannot be safely used as a literal in the restore-time
# `sed` path rewrite below. `#` is that s-command's delimiter, and `&`/`\` are
# sed replacement-side metacharacters -- any of them in the archived-install or
# install-dir path would corrupt the command or the value it writes into the
# restored .env. Kept as its own function so it is unit-testable. Regex
# metacharacters such as `.` are deliberately NOT rejected: they cannot corrupt
# the command (only, in theory, widen a match), and realpath-normalized install
# paths legitimately contain them.
restore_path_is_sed_safe() {
    case "$1" in
        *'#'* | *'&'* | *'\'* | *$'\n'*) return 1 ;;
    esac
    return 0
}

restore_clear_stale_env_local_if_unarchived() {
    local archived_install_root="$1" install_dir="$2" stale_target

    [[ -f "$archived_install_root/.env.local" ]] && return 0
    [[ -f "$install_dir/.env.local" ]] || return 0

    stale_target="$install_dir/.env.local.pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$install_dir/.env.local" "$stale_target"
    print_warn "Archived backup has no .env.local; moved the stale pre-restore override to $(basename "$stale_target") so the restored .env takes effect."
}

cmd_restore() {
    local archive="${1:-}" install_dir="${2:-/opt/lancache-ng}"
    install_dir=$(realpath -m "$install_dir")
    [[ -n "$archive" ]] || die "Usage: $0 restore <backup.tar.gz> [install-dir]"
    [[ -f "$archive" ]] || die "Backup archive not found: $archive"
    # openssl is required here (not just tar/rsync) because the .env
    # convergence step below can call ensure_secret_env_key() for a legacy or
    # incomplete backup with missing/placeholder service tokens, and that
    # generator shells out to `openssl rand`. Installing it upfront means a
    # minimal disaster-recovery host fails before any restore mutation
    # instead of after files/volumes are already restored.
    install_missing_tools tar rsync openssl

    local tmp root backup_dir archived_install archived_repo_root new_repo_root rel_install stack_stopped=0 stack_was_running=0 archived_project path rel target
    tmp=$(mktemp -d)
    restore_cleanup() {
        local status=$?
        if [[ "$stack_stopped" = "1" ]]; then
            if [[ "$status" -eq 0 ]]; then
                # Success: restart only if the stack was actually running
                # before this restore, instead of unconditionally bringing it
                # up (#669 #4's "was already stopped" half).
                [[ "$stack_was_running" = "1" ]] && compose_stack_start "$install_dir"
            else
                # Failure/partial restore: leave the stack stopped rather
                # than starting it on a mixed old/new or partially-restored
                # state. Whatever files did get copied stay in place for
                # inspection; the operator decides when it's safe to bring
                # the stack back up (#669 #4).
                #
                # The printed recovery command must pass the same
                # --env-file that compose_stack_start uses elsewhere in this
                # script: a manual deploy/prod checkout that runs on
                # .env.local (see runtime_env_file_for_install_dir) would
                # otherwise have `docker compose up -d` silently fall back to
                # the tracked .env template, restarting with the wrong
                # IPs/secrets on top of an already-partial restore (PR #748
                # review).
                local recovery_env_file
                recovery_env_file=$(runtime_env_file_for_install_dir "$install_dir")
                print_warn "Restore failed; leaving the stack stopped at $install_dir for manual recovery."
                print_warn "Investigate the error above, then run: cd \"$install_dir\" && docker compose --env-file \"$recovery_env_file\" up -d"
            fi
        fi
        rm -rf "$tmp"
        trap - EXIT
        return "$status"
    }
    trap restore_cleanup EXIT
    tar -C "$tmp" -xzf "$archive"
    root=$(find "$tmp" -mindepth 2 -maxdepth 2 -type d -name rootfs | head -1)
    [[ -n "$root" && -d "$root" ]] || die "Backup archive has no rootfs payload."
    backup_dir=$(dirname "$root")
    archived_install=$(awk -F': ' '/^Install directory: / {print $2; exit}' "$backup_dir/README.txt" 2>/dev/null || true)
    archived_install="${archived_install:-/opt/lancache-ng}"
    archived_install=$(realpath -m "$archived_install")
    rel_install="${archived_install#/}"
    archived_repo_root=""
    new_repo_root=""
    if is_deploy_prod_install_dir "$archived_install" && is_deploy_prod_install_dir "$install_dir"; then
        archived_repo_root=$(deploy_prod_repo_root "$archived_install")
        new_repo_root=$(deploy_prod_repo_root "$install_dir")
    fi

    # Read the project name from the ARCHIVED compose file (the one that
    # actually owns the volumes about to be wiped/reloaded), not the restore
    # target — the target's own docker-compose.yml may not exist yet on a
    # fresh install-dir, and either way it is only relevant here as a name
    # lookup, not as the thing being restored. See
    # guard_restore_shared_project_volumes's own comment for why this matters
    # (#669 #6). Resolved via runtime_env_file_for_install_dir rather than a
    # hardcoded ".env": a manual deploy/prod archive whose active runtime
    # config was .env.local (backup_manifest archives that file separately
    # from the tracked .env template, so it lands at this same extracted
    # path) can carry its own COMPOSE_PROJECT_NAME override. Reading only
    # .env would silently fall back to the tracked template's name and make
    # the guard check the wrong project's running containers (PR #748 review).
    archived_project=$(compose_project_name "$root/$rel_install" "$(runtime_env_file_for_install_dir "$root/$rel_install")")
    guard_restore_shared_project_volumes "$install_dir" "$archived_project"

    # Captured before compose_stack_stop so restore_cleanup only restarts the
    # stack on a successful restore if it was actually running beforehand
    # (#669 #3/#4 pattern).
    compose_stack_running "$install_dir" && stack_was_running=1
    compose_stack_stop "$install_dir"
    stack_stopped=1

    print_step "Restoring backup"
    if [[ -d "$root/$rel_install" ]]; then
        mkdir -p "$install_dir"
        rsync -aH --numeric-ids "$root/$rel_install/" "$install_dir/"
        # Must run before the path-rewrite sed loop below: a stale .env.local
        # that the archive doesn't account for should be moved aside, not
        # rewritten in place as if it were part of the restored config.
        restore_clear_stale_env_local_if_unarchived "$root/$rel_install" "$install_dir"
        if [[ "$archived_install" != "$install_dir" ]]; then
            # Validate both operator-controlled paths before feeding them to
            # sed, and fail closed on the substitution itself: a silently
            # failed rewrite would leave .env/.env.local pointing at the old
            # archived path and let the restore continue with a broken install
            # location (the structurally identical rewrite in cmd_update_ip
            # stays safe by only ever operating on is_valid_ipv4-validated
            # values).
            restore_path_is_sed_safe "$archived_install" \
                || die "Cannot rewrite restored config: archived install path '$archived_install' contains a character unsafe for path substitution (#, &, or \\)."
            restore_path_is_sed_safe "$install_dir" \
                || die "Cannot rewrite restored config: install path '$install_dir' contains a character unsafe for path substitution (#, &, or \\)."
            for path in "$install_dir/.env" "$install_dir/.env.local"; do
                [[ -f "$path" ]] || continue
                sed -i "s#${archived_install}#${install_dir}#g" "$path" \
                    || die "Failed to rewrite the install path in $path during restore."
            done
        fi
    fi
    while IFS= read -r path; do
        rel="${path#/}"
        if [[ "$path" = "$archived_install" || "$path" = "$archived_install"/* ]]; then
            continue
        fi
        [[ -e "$root/$rel" ]] || continue
        target="/$rel"
        if [[ -n "$archived_repo_root" && -n "$new_repo_root" && "$path" = "$archived_repo_root"/* ]]; then
            target="${new_repo_root}${path#"$archived_repo_root"}"
        fi
        if [[ -d "$root/$rel" ]]; then
            mkdir -p "$target"
            rsync -aH --numeric-ids "$root/$rel/" "$target/"
        else
            mkdir -p "$(dirname "$target")"
            rsync -aH --numeric-ids "$root/$rel" "$(dirname "$target")/"
        fi
    done < "$backup_dir/manifest.txt"
    restore_compose_volumes "$install_dir" "$backup_dir/docker-volumes"
    print_ok "Files restored from $archive"

    # A quickstart install keeps its own copied docker-compose.yml/scripts
    # bundle under install_dir rather than a Git checkout, so an archive
    # taken before a compose/script change (e.g. the pre-single-CACHE_DIR
    # layout) restores that stale bundle verbatim. Refresh it from this
    # running setup.sh's own checkout before convergence -- exactly what
    # cmd_update() already does -- so the migration below never validates or
    # starts the stack against compose wiring the .env it just produced no
    # longer matches. Skipped for a deploy/prod (Git-tracked) restore target:
    # that compose file is managed by the checkout itself, not this bundle,
    # and restore deliberately does not run a git sync (unlike update).
    if ! is_deploy_prod_install_dir "$install_dir"; then
        install_quickstart_compose_assets "$install_dir"
        print_ok "quickstart compose assets refreshed"
    fi

    # Run in a subshell so a die() inside either helper is caught here instead
    # of unwinding straight past the stack_stopped=0 line below -- both
    # helpers already wrote whatever they could to the on-disk .env before
    # die()ing, and that partial progress is intentionally left in place for
    # the operator to inspect/finish via setup.sh update. migrate_env_for_update
    # is called with preserve_image_tag=1 so a rollback restore keeps the
    # archived immutable image tag instead of re-resolving a channel back to
    # its current (possibly still-bad) pointer -- see the function's own
    # preserve_image_tag comment. validate_compose_config only runs when
    # Docker/compose is actually available: backup/restore intentionally
    # support config-only archives on hosts without Docker (see
    # compose_stack_available and restore_compose_volumes above), and
    # `docker compose config` would otherwise fail that offline restore path
    # even though nothing here actually needs Docker to converge .env.
    if ! (
        migrate_env_for_update "$install_dir" 1
        if compose_stack_available "$install_dir"; then
            validate_compose_config "$install_dir"
        else
            print_warn "Docker/compose not available for $install_dir -- .env was converged, but compose validation and the stack start were skipped. Install Docker, then run: setup.sh update $install_dir"
        fi
    ); then
        stack_stopped=0
        die "Restore could not converge or validate the restored .env. The stack was left stopped instead of starting on an unconverged/invalid configuration. Fix the reported problem, then run: setup.sh update $install_dir"
    fi

    restore_cleanup
}

# Keep user-facing help compact. Detailed behavior should live in command help
# blocks and comments near the implementation, not in the top-level output.
print_usage() {
    cat <<EOF
LanCache-NG setup

Usage:
  ./setup.sh [command] [install-dir]

Commands:
  install              Run the guided first-time setup. This is also the
                       default when no command is given, so this remains safe
                       for curl | bash installation.
  update [install-dir] Update an existing stack. Default dir: /opt/lancache-ng
  update-ip [install-dir]
                       Change the configured standard and SSL listener IPs.
                       Default dir: /opt/lancache-ng
  debug [install-dir]  Print diagnostic information for an existing stack.
  create-logs-for-issue [install-dir]
                       Bundle redacted logs/config into an archive to attach
                       to a GitHub bug report.
  secondary [options]  Register and launch a secondary DNS node.
  backup [options]     Create a config-only or full rollback backup.
  restore <archive>    Restore a setup-script backup.
  reset-to-last-known-good-config <service> [install-dir] [snapshot-id]
                       CLI fallback for rolling a service back to a known-good
                       config when the Admin UI itself is unreachable.
  help, --help         Show this compact command list.

Compatibility aliases:
  --reconfigure        Same as update-ip, kept for existing documentation and
                       scripts that already use ./setup.sh --reconfigure.

Tip:
  Run './setup.sh <command> --help' for command-specific help. The main help
  intentionally stays short so it does not flood curl | bash users.
EOF
}

# Prints the detailed usage block for one subcommand (invoked via
# `./setup.sh <command> --help`), keeping the verbose per-command docs out of
# the compact top-level print_usage output above.
print_command_help() {
    local command="$1"

    case "$command" in
        install)
            cat <<EOF
Usage: ./setup.sh install

Runs the guided LanCache-NG installer. This is the default command when no
argument is provided, which preserves the existing curl | bash setup flow.

When no local repo is found (the standalone curl | bash path), this command
self-clones to /opt/lancache-ng from the remote's default branch (master) by
default. Set LANCACHE_SETUP_GIT_REF to a branch, tag, or commit-ish (e.g.
LANCACHE_SETUP_GIT_REF=v0.2.0) to bootstrap from that ref instead -- useful
for validating a pre-release branch the same documented one-liner way that
LANCACHE_IMAGE_CHANNEL already selects a specific image channel (#814).
EOF
            ;;
        update)
            cat <<EOF
Usage: ./setup.sh update [install-dir]

Updates an existing LanCache-NG installation, pulls fresh container images, and
restarts the stack. If [install-dir] is omitted, /opt/lancache-ng is used.

Applies the same ordered, health-gated sequence as auto-update below: every
service except the Admin UI is brought up and verified healthy first, the
Admin UI is recreated last, and a failed health check rolls back to the
pre-update backup this command takes automatically.
EOF
            ;;
        auto-update)
            cat <<EOF
Usage: ./setup.sh auto-update [install-dir]

Scheduled entry point (#819), normally invoked by the lancache-auto-update
systemd timer, not run directly by an operator. Does nothing unless
AUTO_UPDATE_ENABLED=1 in .env AND the resolved release channel has actually
moved to a new image set since the last update -- an unchanged channel is a
silent no-op, not a full pull-and-restart. When it does act, it runs the
exact same ordered, health-gated update as ./setup.sh update. If
[install-dir] is omitted, /opt/lancache-ng is used.
EOF
            ;;
        update-ip|--reconfigure|reconfigure)
            cat <<EOF
Usage: ./setup.sh update-ip [install-dir]

Interactively changes the standard and SSL listener IP addresses for an
existing installation, then restarts its stack. If [install-dir] is omitted,
/opt/lancache-ng is used.

Compatibility: ./setup.sh --reconfigure still works and runs this command.
EOF
            ;;
        debug)
            cat <<EOF
Usage: ./setup.sh debug [install-dir]

Prints container status, recent logs, cache usage, LAN addresses, and health
checks for an existing installation. If [install-dir] is omitted,
/opt/lancache-ng is used.
EOF
            ;;
        create-logs-for-issue)
            cat <<EOF
Usage: ./setup.sh create-logs-for-issue [install-dir] [--dest /output/path]

Bundles docker compose logs/ps/config, a secret-redacted copy of .env, host
facts (Docker/Compose versions, disk space), and known-good-snapshot
directory listings into one compressed, timestamped archive, then prints its
path. Attach that one file to a GitHub bug report instead of manually
running and pasting a series of commands. If [install-dir] is omitted,
/opt/lancache-ng is used; the archive is written to /var/backups/lancache-ng
unless --dest overrides it.

Every credential-shaped value (API keys, TSIG keys, passwords, tokens) is
redacted before compression. This command never uploads or attaches
anything automatically -- review the archive yourself before attaching it.
EOF
            ;;
        secondary)
            cat <<EOF
Usage: ./setup.sh secondary --primary <url> --token <token> --name <name> --proxy-ip <ip> [--listen-ip <ip>] [--rotate]

Registers and starts a secondary DNS node on a remote host. The command
creates a local compose directory, writes the secondary .env file, and starts
the container after the primary server returns the required secrets.
Use --rotate in an existing secondary directory to refresh credentials after
the primary changes its NATS authentication model.
EOF
            ;;
        backup)
            cat <<EOF
Usage: ./setup.sh backup [--config|--full] [install-dir] [--dest /backup/path]

Creates a timestamped backup archive. Config backups include configuration,
certificates, secrets, runtime databases, and Docker named volumes (excluding
the cache volume), plus image revision metadata. Full backups also include
cache directories and the cache volume, and can be very large.
EOF
            ;;
        restore)
            cat <<EOF
Usage: ./setup.sh restore <backup.tar.gz> [install-dir]

Restores a setup-script backup. Files from the archived install directory are
remapped to [install-dir] when it differs from the original path. After
restoring, runs the same .env convergence and Compose validation as
setup.sh update, then starts the stack. If convergence or validation fails,
the stack is left stopped instead of starting on an unconverged config; fix
the reported problem and run setup.sh update.

Same-host limitation: the Docker Compose project name is fixed
("lancache-ng") for every install, so two installs on the same host share the
same named Docker volumes regardless of install-dir. Restoring into a
different [install-dir] refuses to proceed if a running stack elsewhere on
this host is still using that project name, to avoid overwriting its live
volumes.
EOF
            ;;
        reset-to-last-known-good-config)
            cat <<EOF
Usage: ./setup.sh reset-to-last-known-good-config <service> [install-dir] [snapshot-id] [--yes]

CLI fallback for when the Admin UI itself is unreachable but a service's own
control surface still is (issue #763). Automates the exact by-hand recovery
sequence docs/known-good-config-snapshots.md's "Manual recovery" section
documents: list this install's known-good config snapshots for <service> and
apply one -- the given [snapshot-id], or the newest after an explicit
confirmation if omitted -- via that service's own real validate/apply/persist
API, the same sequence the Admin UI's own per-service rollback pages already
run when they ARE reachable.

Supported services:
  kea, dhcp   Rolls back Kea's DHCP config via its Control Agent API
              (config-test -> config-set -> config-write), reading snapshots
              from the shared kea-data volume.

Not yet supported: dns/pdns zone-record rollback (depends on issue #628's
PowerDNS rollback listener).

--yes, -y     Skip the interactive confirmation prompt (e.g. for scripted use).
              Applying a snapshot always takes effect immediately either way.

If [install-dir] is omitted, /opt/lancache-ng is used.
EOF
            ;;
        *)
            die "Unknown command for help: $command"
            ;;
    esac
}

# ── update / auto-update shared internals ─────────────────────────────────────
# Internal shared state for the current stack-update flow (set once near the
# top of perform_stack_update_flow, read by every helper below it). This is
# deliberately plain globals rather than threading the env-file/compose-files
# values through several layers of function parameters: bash nameref
# parameters (`local -n`) become fragile once nested more than one call deep
# (name collisions between an outer and inner nameref are a real footgun), and
# this flow never runs two updates concurrently in the same process, so there
# is no real downside to shared state scoped to "the update currently in
# progress." Not meant to be read outside of the functions in this section.
_UPDATE_ENV_FILE=""
_UPDATE_COMPOSE_FILES=()

# `docker compose` pre-loaded with the current update flow's env-file and
# compose files, so every helper below calls the exact same stack the rest of
# the flow is already operating on.
dc_update() {
    docker compose --env-file "$_UPDATE_ENV_FILE" "${_UPDATE_COMPOSE_FILES[@]}" "$@"
}

# Real per-container status probe, not just "the process started". If the
# container declares a Docker HEALTHCHECK, this requires it to report
# "healthy" -- Docker leaves `.State.Health` empty for a container with no
# healthcheck defined, which is how this tells "no healthcheck declared" apart
# from "starting"/"unhealthy" rather than guessing. For a container with no
# healthcheck at all, the best available signal is that it is actually in the
# "running" state (weaker, but honestly the most this project can assert for
# those services today).
service_container_is_healthy() {
    local service="$1"
    local container_id health status

    container_id=$(dc_update ps -q "$service" 2>/dev/null)
    [[ -n "$container_id" ]] || return 1

    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container_id" 2>/dev/null)
    if [[ -n "$health" ]]; then
        [[ "$health" = "healthy" ]]
        return $?
    fi

    status=$(docker inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null)
    [[ "$status" = "running" ]]
}

# A missing tool must never look identical to "the thing it would have
# probed is actually healthy" -- a functional check that silently skips when
# its tool is absent is indistinguishable from a check that never ran at
# all, so callers cannot tell "verified healthy" apart from "never verified".
# Every tool-gated functional probe below routes through this instead of its
# own ad hoc `command -v` skip so that shape can't recur one probe at a time.
require_functional_check_tool() {
    local tool="$1" probe_description="$2"
    if ! command -v "$tool" >/dev/null 2>&1; then
        print_error "Functional check failed: $probe_description requires '$tool', which is not installed"
        return 1
    fi
    return 0
}

# Functional confirmation on top of per-container health: a container
# reporting "healthy" only proves ITS OWN internal check passed, not that it
# actually serves what a real client needs. Reuses this project's own
# established real-probe idioms rather than inventing new ones: the proxy
# /healthz check already used by cmd_debug's "Health checks" step, and a real
# dig-based DNS query in the same style scripts/dns-zone-rollback-simulation.sh
# already uses. `ping`/`ss` are deliberately not used here -- neither proves
# the service actually answers a real request.
#
# Every probe below fails closed (require_functional_check_tool) when curl or
# dig is missing rather than silently skipping that half of the check: a
# skipped check and a passed check must never produce the same "healthy"
# verdict, or a broken update can sail through purely because a probe
# dependency was never installed. perform_stack_update_flow installs both
# tools up front specifically so this fail-closed path is the rare exception,
# not the normal case, on a real update run.
verify_stack_functional_health() {
    local ip_standard ip_ssl ssl_enabled test_fqdn resolved

    ip_standard=$(get_env_var IP_STANDARD "$_UPDATE_ENV_FILE")
    ip_ssl=$(get_env_var IP_SSL "$_UPDATE_ENV_FILE")
    ssl_enabled=$(get_env_var SSL_ENABLED "$_UPDATE_ENV_FILE")

    if [[ -n "$ip_standard" ]]; then
        require_functional_check_tool curl "the http://$ip_standard/healthz probe" || return 1
        if ! curl -sf "http://$ip_standard/healthz" >/dev/null; then
            print_error "Functional check failed: http://$ip_standard/healthz"
            return 1
        fi
    fi
    if [[ "${ssl_enabled:-0}" = "1" && -n "$ip_ssl" ]]; then
        require_functional_check_tool curl "the http://$ip_ssl/healthz probe" || return 1
        if ! curl -sf "http://$ip_ssl/healthz" >/dev/null; then
            print_error "Functional check failed: http://$ip_ssl/healthz"
            return 1
        fi
    fi

    # A fixed, always-in-cdn-domains.txt hostname: this only proves the DNS
    # container answers a real query at all (AGENTS.md requires a real
    # query/response probe here, not ping/ss), not that every domain resolves.
    # Must be a bare-apex cdn-domains.txt entry, not a wildcard-only one
    # (leading-dot, e.g. ".steamcontent.com" since #1073): RPZ wildcard-only
    # entries never match the bare apex itself, so probing steamcontent.com
    # directly always came back empty after #1073 and permanently failed this
    # gate even on a perfectly healthy stack (issue #1149).
    test_fqdn="content1.steampowered.com"
    if [[ -n "$ip_standard" ]]; then
        require_functional_check_tool dig "the DNS resolution probe" || return 1
        resolved=$(dig +time=2 +tries=1 +short @"$ip_standard" A "$test_fqdn" 2>/dev/null)
        if [[ -z "$resolved" ]]; then
            print_error "Functional check failed: DNS did not resolve ${test_fqdn} via ${ip_standard}"
            return 1
        fi
    fi

    return 0
}

# Polls every named service until each is container-healthy (see
# service_container_is_healthy) AND the whole set passes the functional probe,
# or the timeout elapses. This is the real decision point the removed
# Watchtower helper never had: a real wait with a real pass/fail outcome, not
# "log a warning and continue anyway" (its actual documented behavior even in
# its one health-aware mode, confirmed on #819 -- see the mechanics research
# there for the primary-source citations).
wait_for_stack_health() {
    local timeout_seconds="$1"
    shift
    local -a services=("$@")
    local interval_seconds=3 elapsed=0 svc all_healthy

    while (( elapsed < timeout_seconds )); do
        all_healthy=1
        for svc in "${services[@]}"; do
            if ! service_container_is_healthy "$svc"; then
                all_healthy=0
                break
            fi
        done
        if [[ "$all_healthy" = "1" ]] && verify_stack_functional_health; then
            return 0
        fi
        sleep "$interval_seconds"
        elapsed=$((elapsed + interval_seconds))
    done
    return 1
}

# Rolls the whole stack back to the pre-update backup perform_stack_update_flow
# just took, found by its deterministic filename (the newest
# lancache-ng-config-*.tar.gz under the default backup root is always that
# exact archive: perform_stack_update_flow only reaches the point where this
# can be called after successfully creating one moments earlier, and archive
# timestamps are UTC and lexically sortable). Reuses the existing cmd_restore
# path rather than reimplementing rollback -- restore already stops the stack,
# replaces state, and re-converges .env correctly.
rollback_stack_update() {
    local install_dir="$1"
    local backup_root="/var/backups/lancache-ng"
    local latest_backup

    latest_backup=$(find "$backup_root" -maxdepth 1 -name 'lancache-ng-config-*.tar.gz' -print 2>/dev/null | sort | tail -1)
    if [[ -z "$latest_backup" ]]; then
        print_error "No pre-update backup archive found under $backup_root; cannot roll back automatically. Manual recovery required."
        return 1
    fi

    print_warn "Rolling back to pre-update backup: $latest_backup"
    if cmd_restore "$latest_backup" "$install_dir"; then
        print_ok "Rollback completed; stack restored to its pre-update state."
        return 0
    fi
    print_error "Rollback itself failed. Manual recovery required: inspect $latest_backup and $install_dir directly."
    return 1
}

# Applies an already-pulled image set in the order #819 requires: every
# service except the Admin UI first, verified actually healthy (not merely
# started), only then the Admin UI recreated last -- so an operator's one
# visibility tool into the stack stays up throughout and only blips at the
# very end, once nothing else could still fail. A failed health gate at
# either stage rolls back to the pre-update backup rather than leaving a
# half-updated, unverified stack running. This is the reversed
# start-then-verify-then-retire-old order identified in the #819 Watchtower
# mechanics research as the concrete fix for Watchtower's own no-rollback gap
# -- built as real engineering here, not ported from it.
apply_stack_update_ordered() {
    local install_dir="$1"
    local -a all_services non_ui_services
    local svc

    mapfile -t all_services < <(dc_update config --services)
    non_ui_services=()
    for svc in "${all_services[@]}"; do
        [[ "$svc" = "ui" ]] && continue
        non_ui_services+=("$svc")
    done
    # This project's compose files always define several non-ui services
    # (proxy, dns, nats, ...), so non_ui_services is never actually empty --
    # important because an empty array here would expand to zero arguments,
    # and `docker compose up -d` with no explicit service names means "bring
    # up everything", silently starting the Admin UI too and defeating the
    # UI-last ordering this function exists to guarantee. Fail closed instead
    # of silently falling into that behavior if this assumption is ever wrong.
    (( ${#non_ui_services[@]} > 0 )) \
        || die "No non-UI services found in this compose configuration; refusing to apply an update that cannot guarantee UI-last ordering."

    print_step "Starting non-UI services"
    if ! dc_update up -d --remove-orphans "${non_ui_services[@]}"; then
        print_error "Failed to start non-UI services."
        rollback_stack_update "$install_dir"
        return 1
    fi

    print_step "Verifying non-UI services are healthy"
    if ! wait_for_stack_health 180 "${non_ui_services[@]}"; then
        print_error "Non-UI services did not become healthy in time."
        rollback_stack_update "$install_dir"
        return 1
    fi

    print_step "Starting Admin UI (last)"
    if ! dc_update up -d --remove-orphans ui; then
        print_error "Failed to start the Admin UI."
        rollback_stack_update "$install_dir"
        return 1
    fi

    print_step "Verifying the whole stack is healthy"
    if ! wait_for_stack_health 120 ui; then
        print_error "Admin UI did not become healthy in time."
        rollback_stack_update "$install_dir"
        return 1
    fi

    print_ok "Whole stack verified healthy"
    return 0
}

# The shared flow both `setup.sh update` (manual) and `setup.sh auto-update`
# (scheduled, #819) run once they've decided an update should happen. Order is
# deliberate: pause convergence, create a rollback backup, migrate/validate
# config, pull images, validate again, apply ordered+health-gated (rolling
# back to the backup just taken on a failed health check), then resume
# convergence. Reordering can leave a half-migrated stack running.
perform_stack_update_flow() {
    local install_dir="$1"
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die "No stack found in $install_dir. Run ./setup.sh first."
    assert_prebuilt_image_platform_supported
    # Installed up front, before anything is mutated, so the post-update
    # verify_stack_functional_health gate below actually runs its DNS/HTTP
    # probes on a default install instead of silently no-oping because curl
    # or dig was never present (verify_stack_functional_health still fails
    # closed on its own if a tool ever goes missing again after this point).
    install_missing_tools curl dig
    cd "$install_dir"
    _UPDATE_ENV_FILE=$(runtime_env_file_for_install_dir "$install_dir")
    mapfile -t _UPDATE_COMPOSE_FILES < <(compose_file_args_for_install_dir "$install_dir" "$_UPDATE_ENV_FILE")
    # Query the activation state directly rather than inferring it from
    # ${#_UPDATE_COMPOSE_FILES[@]}: that count now also grows when a
    # docker-compose.override.yml/.yaml is auto-detected (see
    # compose_file_args_for_install_dir), so array length alone can no longer
    # distinguish "NATS override active" from "operator override present".
    if nats_secondary_override_active_for_install_dir "$install_dir" "$_UPDATE_ENV_FILE"; then
        print_ok "NATS_BIND_IP is set; keeping the remote-secondary NATS override active for this update"
    fi

    UPDATE_CONVERGENCE_PAUSED=0
    UPDATE_CONVERGENCE_COMPLETED=0
    trap resume_lancache_convergence_after_failed_update EXIT
    UPDATE_CONVERGENCE_PAUSED=1
    pause_lancache_convergence_for_update

    if [[ -d "$install_dir/.git" ]]; then
        print_step "Updating repo"
        sync_repo_to_default_branch "$install_dir"
    fi

    # Quickstart installs keep a copied compose bundle under the install tree.
    # Refresh those assets before any backup-driven restart so even copied
    # installs use the current container wiring during the whole update.
    install_quickstart_compose_assets "$install_dir"
    print_ok "quickstart compose assets updated"

    print_step "Creating pre-update rollback backup"
    if ! ( cmd_backup --config "$install_dir" ); then
        trap - EXIT
        resume_lancache_convergence_after_update true
        UPDATE_CONVERGENCE_COMPLETED=1
        die "Pre-update rollback backup failed. The convergence timer was restored because no update mutations were applied."
    fi

    migrate_env_for_update "$install_dir"
    validate_compose_config "$install_dir"

    print_step "Pulling selected images"
    dc_update pull \
        || die "Failed to pull required container images. Check network access and GHCR authentication, then rerun setup.sh update."

    validate_compose_config "$install_dir"

    if ! apply_stack_update_ordered "$install_dir"; then
        trap - EXIT
        resume_lancache_convergence_after_update
        UPDATE_CONVERGENCE_COMPLETED=1
        die "Update failed its post-update health gate and was rolled back to the pre-update backup. Investigate before retrying."
    fi

    trap - EXIT
    resume_lancache_convergence_after_update
    UPDATE_CONVERGENCE_COMPLETED=1
    print_ok "Stack updated"
}

# ── update subcommand ─────────────────────────────────────────────────────────
cmd_update() {
    local install_dir="${1:-/opt/lancache-ng}"
    install_dir=$(realpath -m "$install_dir")
    perform_stack_update_flow "$install_dir"
}

# Pure decision, no docker/registry I/O: given the current state, should a
# scheduled auto-update tick actually proceed? Isolated from
# resolve_lancache_image_channel/resolve_lancache_stack_channel_tag (which do
# the real, docker-dependent resolution) specifically so this decision can be
# unit-tested directly -- see tests/bats/setup_auto_update_gate.bats. Prints
# one human-readable reason line either way and returns 0 (proceed) or 1
# (skip).
lancache_auto_update_should_proceed() {
    local auto_update_enabled="$1" channel="$2" current_tag="$3" deployed_tag="$4"

    if [[ "$auto_update_enabled" != "1" ]]; then
        printf 'skip: AUTO_UPDATE_ENABLED is not 1\n'
        return 1
    fi
    if [[ "$channel" = "pinned" ]]; then
        printf 'skip: LANCACHE_IMAGE_CHANNEL=pinned tracks one fixed tag, not a moving channel; nothing to detect\n'
        return 1
    fi
    if [[ "$current_tag" = "$deployed_tag" ]]; then
        printf 'skip: channel %s is already at %s\n' "$channel" "$current_tag"
        return 1
    fi
    printf 'proceed: channel %s moved %s -> %s\n' "$channel" "$deployed_tag" "$current_tag"
    return 0
}

# ── auto-update subcommand ────────────────────────────────────────────────────
# Scheduled entry point (#819): invoked by lancache-auto-update.timer on the
# host, not normally run directly. Detect-then-act, not unconditional
# pull-and-restart -- a scheduled tick where the channel hasn't moved must be a
# true no-op, or every tick would restart the whole stack for nothing.
cmd_auto_update() {
    local install_dir="${1:-/opt/lancache-ng}"
    local env_file auto_update_enabled current_channel current_tag deployed_tag decision

    install_dir=$(realpath -m "$install_dir")
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die "No stack found in $install_dir. Run ./setup.sh first."
    env_file=$(runtime_env_file_for_install_dir "$install_dir")

    # Re-checked here, not just trusted from whatever gated the systemd timer
    # itself: an operator can flip AUTO_UPDATE_ENABLED=0 in .env directly
    # without re-running setup.sh, which would not by itself disable an
    # already-enabled timer unit. This is the cheap, fail-closed belt-and-
    # braces check that keeps a stale enabled timer from ever actually acting
    # once the operator's intent in .env says otherwise.
    auto_update_enabled=$(get_env_var AUTO_UPDATE_ENABLED "$env_file")
    current_channel=$(resolve_lancache_image_channel "$env_file")
    deployed_tag=$(get_env_var LANCACHE_IMAGE_TAG "$env_file")
    # Only actually resolve the channel through the registry once the cheap,
    # local checks above haven't already ruled the tick out -- avoids a
    # pointless registry round-trip on a disabled or pinned install.
    if [[ "$auto_update_enabled" = "1" && "$current_channel" != "pinned" ]]; then
        current_tag=$(resolve_lancache_stack_channel_tag "$env_file" "$current_channel")
    else
        current_tag=""
    fi

    if decision=$(lancache_auto_update_should_proceed "$auto_update_enabled" "$current_channel" "$current_tag" "$deployed_tag"); then
        print_step "Scheduled automatic update: ${decision#proceed: }"
        perform_stack_update_flow "$install_dir"
    else
        print_ok "${decision#skip: }"
        return 0
    fi
}

# ── converge-reconcile subcommand (#819) ──────────────────────────────────────
# Internal entry point, not meant for interactive use: invoked as the first
# ExecStart of lancache-converge.service, immediately before its existing
# container-drift convergence step further below (see the "Installing
# systemd watchdog" step -- that ExecStart line brings the whole compose
# stack back up, unchanged by this commit). Bridges the Admin UI's release-
# channel/scheduled-update control (services/ui/src/routes/setup.rs's
# update_stack_settings) onto the host.
#
# That control can only write into the ui-data Docker-managed *named volume*
# (routes/dhcp.rs's persist_ui_settings/write_ui_settings_file target) -- a
# plain host script cannot read that as a filesystem path. Rather than
# migrate ui-data to a LANCACHE_STATE_DIR bind-mount (a real, irreversible-
# if-wrong change to every existing install's already-saved DHCP settings),
# this reads the volume's content through a throwaway read-only container,
# the same idiom backup_compose_volumes already uses for exactly this reason.
#
# Only two keys are ever pulled: LANCACHE_IMAGE_CHANNEL and
# AUTO_UPDATE_ENABLED, validated independently of the wider
# validate_lancache_image_channel (which `die`s on an unrecognized value --
# unsuitable here, since an unexpected value from the UI must be a silent
# no-op tick, not an aborted systemd service run). Only "stable"/"nightly" are
# accepted, matching exactly what routes/setup.rs's is_valid_ui_channel now
# offers the operator; this intentionally does not widen to "pinned" even
# once another codepath's validator learns it, since this control was never
# meant to set it. "edge" (the old name of "nightly", renamed in v0.3.0
# #1056) and "dev" (retired, not renamed, in v0.3.0 #825/#1141) are both
# deliberately NOT accepted -- consistent with the hard cut elsewhere, and
# neither was ever offered by the Admin UI to begin with. A settings volume
# still holding "edge" from a pre-rename Admin UI is treated as an
# unrecognized value and no-op'd here (this must not `die` -- see above --
# because it runs inside the auto-update service tick); the operator re-picks a
# valid channel in the current UI.
lancache_ui_channel_override_is_valid() {
    case "$1" in
        stable|nightly) return 0 ;;
        *) return 1 ;;
    esac
}

# Reads a single KEY=value line out of the ui-data volume's
# lancache-ui-settings.env, or prints nothing if the volume doesn't exist yet
# (a fresh install before the UI container has ever started), Docker itself
# isn't available, or the settings file hasn't been written yet. Deliberately
# checks `docker volume inspect` before `docker run -v`: mounting a
# not-yet-existing named volume silently CREATES an empty one as a side
# effect, which would turn this read-only helper into an accidental write.
lancache_read_ui_settings_override() {
    local install_dir="$1" env_file="$2" key="$3" project volume raw
    command -v docker >/dev/null 2>&1 || return 0
    project=$(compose_project_name "$install_dir" "$env_file")
    volume="${project}_ui-data"
    docker volume inspect "$volume" >/dev/null 2>&1 || return 0
    raw=$(docker run --rm -v "${volume}:/volume:ro" alpine \
        sh -c 'cat /volume/lancache-ui-settings.env 2>/dev/null') 2>/dev/null || return 0
    printf '%s\n' "$raw" | sed -n "s/^${key}=//p" | tail -1
}

# Makes lancache-auto-update.timer's actual systemctl enabled/active state
# match .env's current AUTO_UPDATE_ENABLED, regardless of how that value got
# there (an Admin UI override just folded in below, or a direct manual .env
# edit) -- this is the one place that keeps the timer's real state honest,
# called on every convergence tick. A no-op if the unit was never installed
# (systemd unavailable, or "Installing systemd watchdog" never ran).
reconcile_auto_update_timer_state() {
    local env_file="$1" desired
    systemd_unit_exists lancache-auto-update.timer || return 0
    desired=$(get_env_var AUTO_UPDATE_ENABLED "$env_file")
    if [[ "$desired" = "1" ]]; then
        systemctl is-enabled --quiet lancache-auto-update.timer 2>/dev/null \
            || systemctl enable --now lancache-auto-update.timer >/dev/null 2>&1 \
            || true
    else
        if systemctl is-enabled --quiet lancache-auto-update.timer 2>/dev/null; then
            systemctl disable --now lancache-auto-update.timer >/dev/null 2>&1 || true
        fi
    fi
}

cmd_converge_reconcile() {
    local install_dir="${1:-/opt/lancache-ng}" env_file
    local ui_channel ui_auto_update current_channel current_auto_update

    install_dir=$(realpath -m "$install_dir")
    # A converge tick can fire before the very first install completes (the
    # timer/service are both installed, then enabled, in that order -- see
    # "Installing systemd watchdog"/"Starting stack"); silently skip rather
    # than die, exactly like the pre-existing container-drift convergence
    # ExecStart line this runs alongside would also have nothing to converge
    # yet.
    [[ -f "$install_dir/docker-compose.yml" ]] || return 0
    command -v docker >/dev/null 2>&1 || return 0
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    [[ -f "$env_file" ]] || return 0

    ui_channel=$(lancache_read_ui_settings_override "$install_dir" "$env_file" "LANCACHE_IMAGE_CHANNEL")
    if [[ -n "$ui_channel" ]] && lancache_ui_channel_override_is_valid "$ui_channel"; then
        current_channel=$(get_env_var LANCACHE_IMAGE_CHANNEL "$env_file")
        if [[ "$ui_channel" != "$current_channel" ]]; then
            set_env_key LANCACHE_IMAGE_CHANNEL "$ui_channel" "$env_file"
            print_ok "Release channel updated from Admin UI: ${current_channel:-<unset>} -> $ui_channel"
        fi
    fi

    ui_auto_update=$(lancache_read_ui_settings_override "$install_dir" "$env_file" "AUTO_UPDATE_ENABLED")
    if [[ "$ui_auto_update" = "0" || "$ui_auto_update" = "1" ]]; then
        current_auto_update=$(get_env_var AUTO_UPDATE_ENABLED "$env_file")
        if [[ "$ui_auto_update" != "$current_auto_update" ]]; then
            set_env_key AUTO_UPDATE_ENABLED "$ui_auto_update" "$env_file"
            print_ok "Scheduled automatic updates setting updated from Admin UI: ${ui_auto_update} (was ${current_auto_update:-0})"
        fi
    fi

    # Reconciles the timer against .env's CURRENT value regardless of whether
    # the block above just changed it or it was already correct -- covers a
    # direct manual .env edit too, not only the Admin UI path.
    reconcile_auto_update_timer_state "$env_file"
}

# ── debug subcommand ──────────────────────────────────────────────────────────
# Debug is read-only diagnostics. It must not repair, update, or rewrite config;
# operators use it when the stack is already in an unknown state.
cmd_debug() {
    local install_dir="${1:-/opt/lancache-ng}"
    local env_file
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die "No stack found in $install_dir. Run ./setup.sh first."
    cd "$install_dir"

    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    local ip_standard ip_ssl cache_dir cache_std cache_ssl
    ip_standard=$(get_env_var IP_STANDARD "$env_file")
    ip_ssl=$(get_env_var IP_SSL "$env_file")
    cache_dir=$(get_env_var CACHE_DIR "$env_file")
    cache_std=$(get_env_var CACHE_DIR_STANDARD "$env_file")
    cache_ssl=$(get_env_var CACHE_DIR_SSL "$env_file")
    if [[ -z "$cache_dir" ]]; then
        if [[ -n "$cache_std" && -n "$cache_ssl" && "$cache_std" != "$cache_ssl" ]]; then
            print_error "Legacy cache paths differ; set CACHE_DIR before relying on cache debug output."
        else
            cache_dir="${cache_std:-$cache_ssl}"
        fi
    fi

    print_step "Container status"
    docker compose --env-file "$env_file" ps

    print_step "Logs (last 30 lines per service)"
    local ssl_enabled; ssl_enabled=$(get_env_var SSL_ENABLED "$env_file")
    local -a svc_list
    svc_list=(proxy dns-standard ui netdata watchdog)
    [[ "${ssl_enabled:-1}" = "1" ]] && svc_list=(proxy dns-standard dns-ssl ui netdata watchdog)
    local svc
    for svc in "${svc_list[@]}"; do
        printf "\n${BOLD}--- %s ---${RESET}\n" "$svc"
        docker compose --env-file "$env_file" logs --tail=30 "$svc" 2>/dev/null || true
    done

    print_step "Cache usage"
    if [[ -n "$cache_dir" ]]; then
        if [[ -d "$cache_dir" ]]; then
            du -sh "$cache_dir"
        else
            print_warn "Directory not found: $cache_dir"
        fi
    fi

    print_step "Network (LAN IPs)"
    ip -4 addr show | grep "inet " | grep -v " 127\." | grep -v " 172\." || true

    print_step "Health checks"
    if ! command -v curl >/dev/null 2>&1; then
        print_warn "curl not found — health checks skipped"
    else
        local ip
        for ip in "$ip_standard" "$ip_ssl"; do
            [[ -z "$ip" ]] && continue
            if curl -sf "http://$ip/healthz" >/dev/null 2>&1; then
                print_ok "http://$ip/healthz — OK"
            else
                print_error "http://$ip/healthz — ERROR"
            fi
        done
    fi
}

# ── create-logs-for-issue subcommand ──────────────────────────────────────────
# #762: bundles the diagnostic state a maintainer needs to triage a bug
# report into one compressed, secret-redacted archive, so a non-technical
# operator (this project's actual audience per CLAUDE.md) can attach one
# file to a GitHub issue instead of manually running and pasting a series of
# commands. Read-only like cmd_debug above: this never repairs, restarts, or
# rewrites anything, it only collects and redacts.
#
# Redaction is intentionally two-layered (see #762 review) because a
# name-based scrub of just the .env file is not enough on its own:
# `docker compose config` re-emits the same secret VALUES interpolated into
# the resolved YAML wherever a service references them via ${VAR}/env_file:,
# and a service's own startup logs can echo a secret value verbatim (e.g. a
# connection URL embedding a password). Redacting only .env would still ship
# every one of those values in a different file inside the same archive.
# So every collected artifact — not just .env — is run through
# logbundle_redact_stream, which substitutes the literal current VALUE of
# every credential-shaped variable, on top of (not instead of) the
# name-based, line-level redaction applied to the .env copy itself.

# The explicit floor for "credential-shaped variable name": every key this
# script itself generates/manages via ensure_secret_env_key/
# get_or_generate_secret/generate_secret_value (grepped fresh against this
# file for #762, not assumed from memory — see the PR body for the exact
# `grep` used). logbundle_key_looks_like_secret below extends this with a
# name-pattern safety net, so a future credential-shaped variable added
# without also updating this explicit list is still redacted.
logbundle_secret_env_keys() {
    printf '%s\n' \
        KEA_CTRL_TOKEN \
        DDNS_TSIG_KEY \
        PDNS_API_KEY \
        NATS_UI_PASSWORD \
        NATS_DNS_WRITER_PASSWORD \
        NATS_DNS_REPLICA_PASSWORD \
        NATS_CALLOUT_PASSWORD \
        SECONDARY_REGISTRATION_TOKEN \
        UI_AUTH_PASSWORD
}

# Pattern-based safety net on top of logbundle_secret_env_keys above: matches
# any env var KEY containing PASSWORD/SECRET/TOKEN/TSIG/CREDENTIAL, or ending
# in _KEY. Deliberately broad (per #762's "when in doubt, over-redact"
# instruction) so a future secret-shaped variable this list forgets to
# enumerate — or a variable an operator adds to their own .env by hand — is
# still caught instead of silently shipped in the archive.
logbundle_key_looks_like_secret() {
    local key="$1"
    [[ "$key" =~ (PASSWORD|SECRET|TOKEN|TSIG|CREDENTIAL|_KEY) ]]
}

# Prints one non-empty, non-placeholder secret VALUE per line, longest first,
# gathered from every given env file for every key that is either in
# logbundle_secret_env_keys or matches logbundle_key_looks_like_secret.
# secret_value_is_placeholder (line ~890) is reused here so a still-default
# CHANGE_ME_*/lancache-*-secret placeholder is never treated as a real
# secret needing redaction (that would just clutter every log line
# containing e.g. "CHANGE_ME" with a confusing [REDACTED]).
# Longest-first ordering matters for logbundle_redact_stream's sequential
# literal substitution: if one secret value happened to be a substring of
# another, replacing the shorter one first would corrupt the longer one's
# remaining, un-redacted tail instead of fully masking it.
logbundle_collect_secret_values() {
    local -a env_files=("$@")
    local -A key_set=()
    local key env_file value

    while IFS= read -r key; do
        [[ -n "$key" ]] && key_set["$key"]=1
    done < <(logbundle_secret_env_keys)

    for env_file in "${env_files[@]}"; do
        [[ -f "$env_file" ]] || continue
        while IFS= read -r key; do
            [[ -n "$key" ]] || continue
            logbundle_key_looks_like_secret "$key" && key_set["$key"]=1
        done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "$env_file" 2>/dev/null)
    done

    for key in "${!key_set[@]}"; do
        for env_file in "${env_files[@]}"; do
            [[ -f "$env_file" ]] || continue
            value=$(get_env_var_nonempty "$key" "$env_file")
            [[ -n "$value" ]] || continue
            secret_value_is_placeholder "$value" && continue
            printf '%s\n' "$value"
        done
    done | sort -u | awk '{ print length, $0 }' | sort -k1,1nr | cut -d' ' -f2-
}

# Reads all of stdin, replaces every literal secret VALUE listed in
# secrets_file with "[REDACTED]" (plain string substitution, not regex, so
# no escaping concerns for values containing base64 punctuation like +/=),
# and writes the result to stdout. Used on every collected artifact —
# compose config/ps output, per-service logs, and the redacted .env copy —
# so a credential is scrubbed everywhere it could appear, not just in the
# one file it is "supposed" to live in. `read -d ''` slurps stdin verbatim
# (including embedded blank lines) since these artifacts are always text
# with no NUL bytes.
logbundle_redact_stream() {
    local secrets_file="$1"
    local content="" secret
    IFS= read -r -d '' content || true
    if [[ -f "$secrets_file" ]]; then
        while IFS= read -r secret; do
            [[ -n "$secret" ]] || continue
            content="${content//"$secret"/[REDACTED]}"
        done < "$secrets_file"
    fi
    printf '%s' "$content"
}

# Writes a redacted copy of an env file: every line whose KEY looks
# credential-shaped (logbundle_key_looks_like_secret) has its VALUE replaced
# with [REDACTED] unconditionally — including an already-empty or
# still-placeholder value — so the archived file consistently reads as
# "this field is a secret" rather than incidentally revealing which
# credentials were still on their generated/placeholder default. Lines that
# don't look credential-shaped (IPs, DHCP mode, SSL_ENABLED, ...) are copied
# through unmodified since they're exactly the operational context a
# maintainer needs to triage the report.
logbundle_redact_env_file() {
    local src="$1" dst="$2"
    local line key
    : > "$dst"
    [[ -f "$src" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            key="${BASH_REMATCH[1]}"
            if logbundle_key_looks_like_secret "$key"; then
                printf '%s=[REDACTED]\n' "$key" >> "$dst"
                continue
            fi
        fi
        printf '%s\n' "$line" >> "$dst"
    done < "$src"
}

# Picks the best compressor actually available on the host, preferring
# zstd > bzip2 > gzip per #762's explicit scope. This extends, rather than
# invents, the "prefer the best available compressor, fall back gracefully"
# idiom this project already uses for syslog-ng log rotation
# (deploy/*/docker-compose.yml's zstd-preferred/gzip-fallback rotation
# block) — that existing idiom is only two-tiered (zstd or gzip, no bzip2
# anywhere in this codebase today), so this adds the missing middle tier
# rather than copying a pre-existing three-way chain that does not exist
# yet. gzip is always available on every Debian host this project targets,
# so this chain always terminates. Prints one of zst/bz2/gz.
logbundle_select_compressor() {
    if command -v zstd >/dev/null 2>&1; then
        printf 'zst\n'
    elif command -v bzip2 >/dev/null 2>&1; then
        printf 'bz2\n'
    else
        printf 'gz\n'
    fi
}

# Directory listings (never file content) of the known-good-snapshot volumes
# documented in docs/known-good-config-snapshots.md. proxy/dhcp-proxy/pdns
# snapshot volumes are, per that document and their own docker-compose.yml
# declaration comment ("Deliberately plain Docker-managed volumes ... out of
# scope for setup.sh backup/restore"), plain Docker-managed named volumes
# outside the LANCACHE_STATE_DIR bind-mount contract backup_manifest()
# already walks — so they are not reachable as host paths and need the same
# `docker run --rm -v <volume>:/data busybox ls -la /data` approach that
# doc's own "Manual recovery" section documents for hand triage. Only `ls`
# ever runs inside the throwaway container; it cannot read file content.
logbundle_named_volume_listing() {
    local install_dir="$1" env_file="$2" base_name="$3" subpath="$4" out="$5"
    if ! command -v docker >/dev/null 2>&1; then
        printf 'docker not available; skipped\n' > "$out"
        return 0
    fi
    local project volume
    project=$(compose_project_name "$install_dir" "$env_file")
    volume="${project}_${base_name}"
    if ! docker volume inspect "$volume" >/dev/null 2>&1; then
        printf 'volume %s not found (not created yet)\n' "$volume" > "$out"
        return 0
    fi
    docker run --rm -v "${volume}:/data:ro" alpine \
        sh -c "ls -laR '/data/${subpath}' 2>/dev/null || echo '(no snapshots yet)'" \
        > "$out" 2>/dev/null
}

# Counterpart to logbundle_named_volume_listing for a known-good-snapshot
# path that is (or may be) a real host directory instead of a Docker-managed
# volume — this is Kea's case in prod/quickstart, where KEA_DATA_DIR is a
# plain bind mount (unlike proxy/dhcp-proxy/pdns's snapshot volumes above),
# so the host path is directly listable with no container needed.
logbundle_host_path_listing() {
    local dir="$1" out="$2"
    if [[ -d "$dir" ]]; then
        ls -laR "$dir" > "$out" 2>/dev/null
    else
        printf 'directory %s not found\n' "$dir" > "$out"
    fi
}

cmd_create_logs_for_issue() {
    local install_dir="/opt/lancache-ng"
    local dest_root="/var/backups/lancache-ng"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dest) dest_root="${2:?Missing value for --dest}"; shift 2 ;;
            *) install_dir="$1"; shift ;;
        esac
    done
    install_dir=$(realpath -m "$install_dir")
    dest_root=$(realpath -m "$dest_root")
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die "No stack found in $install_dir. Run ./setup.sh first."
    install_missing_tools tar

    local env_file cache_env_file state_dir
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    cache_env_file="$install_dir/.env"
    state_dir=$(get_env_var LANCACHE_STATE_DIR "$env_file")
    state_dir="${state_dir:-$(legacy_state_root_or_default "$(production_state_root_default "$install_dir")")}"

    local -a env_files=("$env_file")
    [[ "$cache_env_file" != "$env_file" && -f "$cache_env_file" ]] && env_files+=("$cache_env_file")

    local stamp dest ext archive old_umask secrets_file
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    dest="$dest_root/.create-logs-for-issue-$stamp"
    old_umask=$(umask)
    umask 077
    mkdir -p "$dest_root" "$dest/logs" "$dest/env" "$dest/known-good-snapshots"
    secrets_file=$(mktemp) || die "Could not create a temporary file for secret redaction."
    chmod 600 "$secrets_file"

    # Cleanup always removes the working directory and the secrets scratch
    # file, whether this succeeds, fails partway, or is interrupted — the
    # working directory's contents only ever matter once folded into the
    # final archive below, and the secrets file must never survive on disk
    # longer than this run needs it.
    logbundle_cleanup() {
        local status=$?
        rm -rf "$dest"
        rm -f "$secrets_file"
        umask "$old_umask"
        trap - EXIT
        return "$status"
    }
    trap logbundle_cleanup EXIT

    print_step "Collecting diagnostic bundle for issue report"

    logbundle_collect_secret_values "${env_files[@]}" > "$secrets_file"

    # Host facts (#762 scope: Docker version, Compose version, disk space).
    # Follows the same docker/compose version commands already used for the
    # one-off terminal print_ok lines in the main install flow above, but
    # keeps their full, unstripped output here (that flow trims to a bare
    # version number for a short interactive message; a diagnostic bundle
    # benefits from the fuller string instead). Disk space has no prior
    # helper to reuse — nothing in this script gathers it today — so `df -h`
    # is added fresh.
    {
        printf 'Generated: %s UTC\n' "$stamp"
        printf 'Install directory: %s\n' "$install_dir"
        printf 'Docker: %s\n' "$(docker --version 2>/dev/null || printf 'not found')"
        printf 'Docker Compose: %s\n' "$(docker compose version 2>/dev/null || printf 'not found')"
        printf 'Kernel: %s\n' "$(uname -srm 2>/dev/null || printf 'unknown')"
        printf '\nDisk usage:\n'
        df -h 2>/dev/null || true
    } | logbundle_redact_stream "$secrets_file" > "$dest/host-facts.txt"

    print_step "Container status and configuration"
    docker compose --env-file "$env_file" ps 2>&1 \
        | logbundle_redact_stream "$secrets_file" > "$dest/compose-ps.txt"
    # config re-interpolates every ${VAR}/env_file: reference into plain
    # text, which is exactly why this is redacted the same way as logs
    # instead of being assumed safe just because it's "just config" (#762
    # review — see the function comment above logbundle_redact_stream).
    docker compose --env-file "$env_file" config 2>&1 \
        | logbundle_redact_stream "$secrets_file" > "$dest/compose-config.txt"

    print_step "Collecting service logs"
    local -a services=()
    mapfile -t services < <(docker compose --env-file "$env_file" config --services 2>/dev/null)
    local svc
    for svc in "${services[@]}"; do
        [[ -n "$svc" ]] || continue
        print_ok "Logs: $svc"
        docker compose --env-file "$env_file" logs --no-color --timestamps --tail=2000 "$svc" 2>&1 \
            | logbundle_redact_stream "$secrets_file" > "$dest/logs/$svc.log"
    done

    print_step "Redacting configuration"
    logbundle_redact_env_file "$cache_env_file" "$dest/env/.env"
    logbundle_redact_stream "$secrets_file" < "$dest/env/.env" > "$dest/env/.env.tmp"
    mv "$dest/env/.env.tmp" "$dest/env/.env"
    if [[ "$env_file" != "$cache_env_file" ]]; then
        logbundle_redact_env_file "$env_file" "$dest/env/.env.local"
        logbundle_redact_stream "$secrets_file" < "$dest/env/.env.local" > "$dest/env/.env.local.tmp"
        mv "$dest/env/.env.local.tmp" "$dest/env/.env.local"
    fi

    print_step "Known-good-snapshot directory listings"
    logbundle_named_volume_listing "$install_dir" "$env_file" proxy-config-snapshots config-snapshots \
        "$dest/known-good-snapshots/proxy.txt"
    logbundle_named_volume_listing "$install_dir" "$env_file" dhcp-proxy-config-snapshots config-snapshots \
        "$dest/known-good-snapshots/dhcp-proxy.txt"
    logbundle_named_volume_listing "$install_dir" "$env_file" pdns-config-snapshots-standard config-snapshots \
        "$dest/known-good-snapshots/dns-standard.txt"
    if [[ "$(get_env_var SSL_ENABLED "$env_file")" = "1" ]]; then
        logbundle_named_volume_listing "$install_dir" "$env_file" pdns-config-snapshots-ssl config-snapshots \
            "$dest/known-good-snapshots/dns-ssl.txt"
    fi
    # Kea's config-snapshots directory is a plain host bind mount in
    # prod/quickstart (KEA_DATA_DIR) but a real named Docker volume in dev
    # (see deploy/dev/docker-compose.yml's top-level kea-data: entry vs.
    # prod/quickstart's ${KEA_DATA_DIR:-...}/kea bind path) — try the host
    # path first and only fall back to the named-volume approach if it does
    # not exist, so this works correctly for both.
    local kea_dir; kea_dir=$(get_env_var KEA_DATA_DIR "$env_file"); kea_dir="${kea_dir:-$state_dir/kea}"
    if [[ -d "$kea_dir" ]]; then
        logbundle_host_path_listing "$kea_dir/config-snapshots" "$dest/known-good-snapshots/kea.txt"
    else
        logbundle_named_volume_listing "$install_dir" "$env_file" kea-data config-snapshots \
            "$dest/known-good-snapshots/kea.txt"
    fi

    cat > "$dest/README.txt" <<EOF
LanCache-NG diagnostic bundle created at $stamp UTC
Install directory: $install_dir

Contents:
  host-facts.txt              Docker/Compose versions, kernel, disk space
  compose-ps.txt               docker compose ps
  compose-config.txt           docker compose config (resolved)
  logs/<service>.log           docker compose logs --tail=2000 per service
  env/.env, env/.env.local      configuration, with secrets redacted
  known-good-snapshots/        directory listings only (no file content)

Every credential-shaped value (API keys, TSIG keys, passwords, tokens) has
been replaced with [REDACTED] everywhere it could appear in this bundle.
Review the contents before attaching this archive to a GitHub issue --
automatic upload is intentionally not part of this tool (#762).
EOF

    ext=$(logbundle_select_compressor)
    archive="$dest_root/lancache-ng-issue-logs-${stamp}.tar.${ext}"
    case "$ext" in
        zst) tar -C "$dest_root" --zstd -cf "$archive" "$(basename "$dest")" ;;
        bz2) tar -C "$dest_root" -cjf "$archive" "$(basename "$dest")" ;;
        *)   tar -C "$dest_root" -czf "$archive" "$(basename "$dest")" ;;
    esac
    chmod 600 "$archive"

    logbundle_cleanup
    print_ok "Diagnostic bundle written: $archive"
    printf "\n${BOLD}Attach this file to your GitHub issue:${RESET} %s\n\n" "$archive"
}

# ── reset-to-last-known-good-config subcommand ────────────────────────────────
# CLI fallback for #763: when the Admin UI itself is unreachable, an operator
# still needs a way to roll a service back to its last known-good persisted
# config -- the Admin UI's own per-service rollback pages (/dhcp for Kea) are
# not an option if the UI can't be reached. docs/known-good-config-snapshots.md's
# "Manual recovery" section already documents doing this by hand for Kea:
# inspect the snapshot JSON files under kea-data/config-snapshots, then apply
# one via config-test -> config-set -> config-write against the real Kea
# Control Agent (the same three-call sequence services/ui/src/routes/dhcp.rs's
# rollback_kea_snapshot already runs when the UI IS reachable). This command
# automates exactly that sequence into one invocation, rather than inventing a
# new mechanism.
cmd_reset_to_last_known_good_config() {
    local service="" install_dir="/opt/lancache-ng" snapshot_id="" assume_yes=0
    local -a positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) assume_yes=1; shift ;;
            *) positional+=("$1"); shift ;;
        esac
    done
    service="${positional[0]:-}"
    [[ -n "${positional[1]:-}" ]] && install_dir="${positional[1]}"
    snapshot_id="${positional[2]:-}"

    case "$service" in
        kea|dhcp)
            reset_kea_to_last_known_good_config "$install_dir" "$snapshot_id" "$assume_yes"
            ;;
        dns|pdns|dns-standard|dns-ssl)
            # #628/PR #788 (PowerDNS zone/record snapshot + rollback listener)
            # was still in review, not yet merged, when this command was
            # added -- automating its manual-recovery sequence here would mean
            # guessing at an API surface still subject to change. Fails
            # closed with a clear pointer instead of silently no-op-ing or
            # shipping against a moving target.
            die "reset-to-last-known-good-config for '$service' is not implemented yet: it depends on the PowerDNS zone/record rollback listener tracked in issue #628. Once that lands, this command will call it the same way the 'kea' target already calls Kea's Control Agent API. Until then, see docs/known-good-config-snapshots.md's \"Manual recovery\" section."
            ;;
        "")
            die "Usage: ./setup.sh reset-to-last-known-good-config <service> [install-dir] [snapshot-id]\nSupported services: kea. Run './setup.sh reset-to-last-known-good-config --help' for details."
            ;;
        *)
            die "Unknown service '$service' for reset-to-last-known-good-config. Supported: kea. Run './setup.sh reset-to-last-known-good-config --help' for details."
            ;;
    esac
}

# Lists this install's known-good Kea config snapshot ids, oldest first.
# Mirrors services/ui/src/kea_snapshots.rs::list_snapshot_ids exactly: a
# snapshot only counts if its directory holds a finalized dhcp4.json payload,
# not a leftover ".staging-<id>" directory from an interrupted write (that
# staging naming, and the fact that a real id is a plain run of digits, is
# also why the loop below skips any directory name that isn't all-digits
# rather than special-casing the "staging-" prefix alone). Directory names
# sort correctly as plain strings here because every real id is the same
# fixed 20-digit zero-padded width (kea_snapshots.rs's `format!("{nanos:020}")`).
list_kea_snapshot_ids() {
    local snapshot_root="$1" entry id
    local -a ids=()
    for entry in "$snapshot_root"/*/; do
        [[ -e "$entry" ]] || continue
        id=$(basename "$entry")
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        [[ -f "${entry}dhcp4.json" ]] || continue
        ids+=("$id")
    done
    [[ ${#ids[@]} -eq 0 ]] && return 0
    printf '%s\n' "${ids[@]}" | sort
}

# Issues one Kea Control Agent command (config-test/config-set/config-write)
# over HTTP Basic auth, exactly matching services/ui/src/routes/dhcp.rs's
# kea_post: same endpoint ("/"), same Content-Type, same "admin" username.
# Kea always answers with a JSON array whose first element carries the
# per-service result ("result": 0 means success); jq is deliberately not a
# setup.sh dependency (see compose_project_name's comment), so both fields are
# pulled out with the same grep -oP idiom cmd_secondary already uses to parse
# the primary server's JSON response, rather than introducing a new parsing
# style just for this command.
kea_ctrl_post() {
    local kea_ctrl_url="$1" kea_ctrl_token="$2" body="$3"
    local response_file http_status response result_code result_text

    response_file=$(mktemp)
    # The Basic-Auth credential is passed to curl via -K (config read from
    # stdin), not -u/--user on the command line: a -u value is a plain argv
    # secret, visible to any other process on the host for curl's whole
    # lifetime (e.g. `ps aux`, /proc/<pid>/cmdline). KEA_CTRL_TOKEN is
    # generated as a hex string by default (see ensure_secret_env_key's
    # hex32 kind), so it never contains the '"' that would break the quoted
    # config value below; this is unchanged from the previous -u form, which
    # had no such validation either.
    if ! http_status=$(printf 'user = "admin:%s"\n' "$kea_ctrl_token" | curl -sS -o "$response_file" -w "%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -K - \
        -d "$body" \
        "$kea_ctrl_url"); then
        rm -f -- "$response_file"
        die "Failed to connect to Kea's Control Agent at ${kea_ctrl_url}. Is the dhcp container running?"
    fi
    response=$(cat "$response_file")
    rm -f -- "$response_file"

    if [[ ! "$http_status" =~ ^2 ]]; then
        die "Kea's Control Agent rejected the request with HTTP ${http_status}. Response: ${response}"
    fi
    result_code=$(printf '%s' "$response" | grep -oP '"result"\s*:\s*\K-?[0-9]+' | head -1)
    result_text=$(printf '%s' "$response" | grep -oP '"text"\s*:\s*"\K[^"]*' | head -1)
    [[ -n "$result_code" ]] || die "Unrecognized response from Kea's Control Agent: ${response}"
    if [[ "$result_code" != "0" ]]; then
        die "Kea's Control Agent rejected the command (result=${result_code}): ${result_text:-<no message>}"
    fi
    printf '%s\n' "$response"
}

# Automates docs/known-good-config-snapshots.md's Kea manual-recovery
# sequence (see that doc's "Manual recovery" section for the by-hand version
# this replaces): list known-good dhcp4.json snapshots from the shared
# kea-data volume (newest last), apply the requested one -- or, if none was
# given, the newest after an explicit confirmation -- via the real
# config-test -> config-set -> config-write chain against Kea's own Control
# Agent, the exact sequence services/ui/src/routes/dhcp.rs's
# rollback_kea_snapshot already runs for an operator who CAN reach the Admin
# UI. This is the fallback for when they can't.
reset_kea_to_last_known_good_config() {
    local install_dir="$1" snapshot_id="$2" assume_yes="${3:-0}"
    local env_file state_dir kea_dir snapshot_root snapshot_dir_override
    local kea_ctrl_host kea_ctrl_token kea_ctrl_url
    local -a snapshot_ids=()
    local sid config_json

    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die "No stack found in $install_dir. Run ./setup.sh first."

    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    [[ -f "$env_file" ]] || die "No .env found for $install_dir (expected $env_file)."

    kea_ctrl_token=$(get_env_var KEA_CTRL_TOKEN "$env_file")
    [[ -n "$kea_ctrl_token" ]] \
        || die "KEA_CTRL_TOKEN is empty or missing in $env_file -- cannot authenticate to Kea's Control Agent."

    kea_ctrl_host=$(get_env_var KEA_CTRL_HOST "$env_file")
    kea_ctrl_host="${kea_ctrl_host:-127.0.0.1}"
    # The dhcp service runs with network_mode: host (deploy/prod/docker-compose.yml),
    # so its Control Agent is reachable directly from THIS host's own loopback
    # -- 0.0.0.0 (the container's own bind-all default) is not a valid address
    # to connect *to*, so it is remapped to 127.0.0.1 exactly like the dhcp
    # service's own healthcheck already does in docker-compose.yml.
    [[ "$kea_ctrl_host" = "0.0.0.0" ]] && kea_ctrl_host="127.0.0.1"
    kea_ctrl_url="http://${kea_ctrl_host}:8000/"

    state_dir=$(get_env_var LANCACHE_STATE_DIR "$env_file")
    state_dir="${state_dir:-$(legacy_state_root_or_default "$(production_state_root_default "$install_dir")")}"
    kea_dir=$(get_env_var KEA_DATA_DIR "$env_file")
    kea_dir="${kea_dir:-$state_dir/kea}"

    # KEA_CONFIG_SNAPSHOT_DIR (services/ui/src/config.rs) is read by the Admin
    # UI process, not this script -- if an operator overrode it away from the
    # documented default, this command has no way to know what host path that
    # maps to and must fail closed rather than guess.
    snapshot_dir_override=$(get_env_var KEA_CONFIG_SNAPSHOT_DIR "$env_file")
    if [[ -n "$snapshot_dir_override" && "$snapshot_dir_override" != "/var/lib/kea/config-snapshots" ]]; then
        die "KEA_CONFIG_SNAPSHOT_DIR is overridden to a non-default value ($snapshot_dir_override) that this command does not know how to map to a host path. Apply the snapshot manually -- see docs/known-good-config-snapshots.md's \"Manual recovery\" section."
    fi
    snapshot_root="$kea_dir/config-snapshots"
    [[ -d "$snapshot_root" ]] \
        || die "No known-good Kea config snapshots found at $snapshot_root."

    mapfile -t snapshot_ids < <(list_kea_snapshot_ids "$snapshot_root")
    [[ ${#snapshot_ids[@]} -gt 0 ]] \
        || die "No valid known-good Kea config snapshots found under $snapshot_root."

    print_step "Known-good Kea config snapshots (oldest first)"
    for sid in "${snapshot_ids[@]}"; do
        # 10#$sid forces base-10: sid is a fixed-width, zero-padded digit
        # string, which bash arithmetic would otherwise misparse as octal
        # (a leading "0" with an 8 or 9 in it is a hard bash error, and any
        # other leading-zero value is silently mis-evaluated).
        printf '  %s  (%s UTC)\n' "$sid" "$(date -u -d "@$(( 10#$sid / 1000000000 ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
    done

    if [[ -z "$snapshot_id" ]]; then
        snapshot_id="${snapshot_ids[${#snapshot_ids[@]}-1]}"
        print_warn "No snapshot id given; defaulting to the newest: $snapshot_id"
    fi
    [[ -f "$snapshot_root/$snapshot_id/dhcp4.json" ]] \
        || die "Snapshot '$snapshot_id' not found under $snapshot_root."
    if [[ "$assume_yes" != "1" ]]; then
        confirm "Roll Kea back to snapshot $snapshot_id now? This applies immediately. [y/N]" "N" \
            || die "Cancelled."
    fi

    config_json=$(cat "$snapshot_root/$snapshot_id/dhcp4.json")

    print_step "Validating snapshot $snapshot_id (config-test)"
    kea_ctrl_post "$kea_ctrl_url" "$kea_ctrl_token" \
        "{\"command\":\"config-test\",\"service\":[\"dhcp4\"],\"arguments\":${config_json}}" >/dev/null
    print_ok "Snapshot validated."

    print_step "Applying snapshot $snapshot_id (config-set)"
    kea_ctrl_post "$kea_ctrl_url" "$kea_ctrl_token" \
        "{\"command\":\"config-set\",\"service\":[\"dhcp4\"],\"arguments\":${config_json}}" >/dev/null
    print_ok "Snapshot applied to the running Kea server."

    print_step "Persisting snapshot $snapshot_id (config-write)"
    kea_ctrl_post "$kea_ctrl_url" "$kea_ctrl_token" \
        '{"command":"config-write","service":["dhcp4"]}' >/dev/null
    print_ok "Snapshot persisted to kea-dhcp4.conf."

    print_ok "Kea rolled back to known-good snapshot $snapshot_id (validated, applied, and persisted)."
    print_warn "This CLI fallback does not itself record a fresh known-good snapshot of the restored state (services/ui/src/routes/dhcp.rs's rollback_kea_snapshot does, when reached via the Admin UI) -- the next config change made through the Admin UI will."
}

# ── update-ip subcommand ───────────────────────────────────────────────────────
# update-ip is the reconfiguration path for an existing install. It changes
# only listener/DNS IP references and restarts that install's compose stack.
# Mirrors cmd_update's install_dir resolution (${1:-/opt/lancache-ng}) so the
# guided-install hint banner's suggested invocation actually operates on the
# real running install instead of always reading/writing the repo checkout's
# own deploy/prod tree (#666).
cmd_update_ip() {
    local install_dir="${1:-/opt/lancache-ng}"
    install_dir=$(realpath -m "$install_dir")

    printf "\n"
    printf "${BOLD}╔═══════════════════════════════════════╗${RESET}\n"
    printf "${BOLD}║  LanCache-NG — Reconfigure IPs        ║${RESET}\n"
    printf "${BOLD}╚═══════════════════════════════════════╝${RESET}\n"
    printf "\n"

    [[ "$(id -u)" = "0" ]] \
        || die "This script must be run as root (sudo ./setup.sh update-ip [install-dir])."
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die "No stack found in $install_dir. Run ./setup.sh first."
    assert_prebuilt_image_platform_supported

    print_step "Reading current configuration"

    local deploy_env dns_standard_env dns_ssl_env
    { read -r deploy_env; read -r dns_standard_env; read -r dns_ssl_env; } \
        < <(resolve_update_ip_config_paths "$install_dir")

    [[ -f "$deploy_env" ]] || die "Configuration not found: $deploy_env"
    if [[ -n "$dns_standard_env" ]]; then
        [[ -f "$dns_standard_env" ]] || die "Configuration not found: $dns_standard_env"
        [[ -f "$dns_ssl_env" ]] || die "Configuration not found: $dns_ssl_env"
    fi

    local current_ip_standard current_ip_ssl
    local new_ip_standard new_ip_ssl
    current_ip_standard=$(get_env_var IP_STANDARD "$deploy_env")
    current_ip_ssl=$(get_env_var IP_SSL "$deploy_env")

    # UI_BIND_IP and DHCP_DNS_PRIMARY/SECONDARY default to IP_STANDARD/IP_SSL
    # at install time (see cmd_setup below) and, for a default quickstart
    # install, are written into deploy_env as concrete values rather than
    # staying empty -- Compose's ${UI_BIND_IP:-${IP_STANDARD}} fallback never
    # kicks in. Read them here so the update below can tell "still the
    # install-time default" apart from "operator set this explicitly" and
    # only rewrite the former (e.g. 127.0.0.1 or a custom DNS IP survives).
    local current_ui_bind_ip current_dhcp_mode
    local current_dhcp_dns_primary current_dhcp_dns_secondary
    current_ui_bind_ip=$(get_env_var UI_BIND_IP "$deploy_env")
    current_dhcp_mode=$(get_env_var DHCP_MODE "$deploy_env")
    current_dhcp_dns_primary=$(get_env_var DHCP_DNS_PRIMARY "$deploy_env")
    current_dhcp_dns_secondary=$(get_env_var DHCP_DNS_SECONDARY "$deploy_env")

    printf "\n  ${BOLD}Current configuration:${RESET}\n"
    printf "    Standard IP: %s\n" "$current_ip_standard"
    printf "    SSL IP:      %s\n" "$current_ip_ssl"
    printf "\n"

    print_step "Prompt for new IPs"

    while true; do
        ask "New standard mode IP" "$current_ip_standard"
        new_ip_standard="$REPLY"
        is_valid_ipv4 "$new_ip_standard" && break
        print_error "Invalid IPv4 address: $new_ip_standard"
    done

    printf "\n"
    while true; do
        ask "New SSL mode IP" "$current_ip_ssl"
        new_ip_ssl="$REPLY"
        is_valid_ipv4 "$new_ip_ssl" && break
        print_error "Invalid IPv4 address: $new_ip_ssl"
    done

    [[ "$new_ip_standard" != "$new_ip_ssl" ]] \
        || die "Standard IP and SSL IP must be different."

    printf "\n"
    printf "  ${BOLD}New configuration:${RESET}\n"
    printf "    Standard IP: %s\n" "$new_ip_standard"
    printf "    SSL IP:      %s\n" "$new_ip_ssl"
    printf "\n"

    ask "Apply changes? [y/N]" "N"
    [[ "${REPLY,,}" = "y" ]] || { printf "\n  Cancelled.\n\n"; exit 0; }

    print_step "Updating configuration files"

    sed -i "s|^IP_STANDARD=.*|IP_STANDARD=$new_ip_standard|" "$deploy_env"
    print_ok "Updated: $deploy_env"

    sed -i "s|^IP_SSL=.*|IP_SSL=$new_ip_ssl|" "$deploy_env"
    print_ok "Updated: $deploy_env"

    # Keep UI_BIND_IP in sync only while it still equals the pre-update
    # Standard IP -- that is the install-time default (see cmd_setup), so an
    # unmodified default install would otherwise stay bound to the address
    # docker-compose.yml just removed. An explicit override such as
    # 127.0.0.1 will not match current_ip_standard and is left alone. The
    # `-n` guard also leaves a deliberately empty UI_BIND_IP= untouched: that
    # empty state already tracks IP_STANDARD automatically via Compose's
    # ${UI_BIND_IP:-${IP_STANDARD}} fallback (see line ~1114), so rewriting
    # it here is unnecessary and would just turn it into a fixed value.
    if [[ -n "$current_ui_bind_ip" && "$current_ui_bind_ip" = "$current_ip_standard" ]]; then
        sed -i "s|^UI_BIND_IP=.*|UI_BIND_IP=$new_ip_standard|" "$deploy_env"
        print_ok "Updated: $deploy_env (UI_BIND_IP)"
    fi

    # Same idea for the proxy-DHCP/PXE DNS options: DHCP_DNS_PRIMARY/SECONDARY
    # default to IP_STANDARD/IP_SSL at install time and are only actually
    # consumed by deploy/quickstart/docker-compose.yml's dhcp-proxy service
    # when DHCP_MODE=dnsmasq-proxy (the Kea dhcp service re-derives its DNS
    # options from IP_STANDARD/IP_SSL directly and never goes stale). Only
    # rewrite values that still match the pre-update defaults so an operator
    # who pointed proxy-DHCP clients at real DNS servers keeps that choice.
    if [[ "$current_dhcp_mode" = "dnsmasq-proxy" ]]; then
        if [[ -n "$current_dhcp_dns_primary" && "$current_dhcp_dns_primary" = "$current_ip_standard" ]]; then
            sed -i "s|^DHCP_DNS_PRIMARY=.*|DHCP_DNS_PRIMARY=$new_ip_standard|" "$deploy_env"
            print_ok "Updated: $deploy_env (DHCP_DNS_PRIMARY)"
        fi
        if [[ -n "$current_dhcp_dns_secondary" && "$current_dhcp_dns_secondary" = "$current_ip_ssl" ]]; then
            sed -i "s|^DHCP_DNS_SECONDARY=.*|DHCP_DNS_SECONDARY=$new_ip_ssl|" "$deploy_env"
            print_ok "Updated: $deploy_env (DHCP_DNS_SECONDARY)"
        fi
    fi

    # Quickstart installs have no separate dns-standard.env/dns-ssl.env --
    # deploy/quickstart/docker-compose.yml reads PROXY_IP straight from
    # IP_STANDARD/IP_SSL in deploy_env above, so there's nothing more to edit.
    if [[ -n "$dns_standard_env" ]]; then
        sed -i "s|^PROXY_IP=.*|PROXY_IP=$new_ip_standard|" "$dns_standard_env"
        print_ok "Updated: $dns_standard_env"

        sed -i "s|^PROXY_IP=.*|PROXY_IP=$new_ip_ssl|" "$dns_ssl_env"
        print_ok "Updated: $dns_ssl_env"
    fi

    print_step "Restarting containers"

    # `cmd1 && cmd2` as a bare statement is exempt from set -e when cmd1 is
    # not the list's last command (verified: `set -e; false && echo hi` does
    # NOT exit) -- so a failing `docker compose up -d` here would silently
    # fall through to the "Reconfiguration complete!" banner below even
    # though the running containers are still bound to the old IPs. Branch
    # explicitly and die() so a restart failure is fatal and visible.
    if (cd "$install_dir" && docker compose --env-file "$deploy_env" -f "$install_dir/docker-compose.yml" up -d); then
        print_ok "Stack restarted"
    else
        die "Failed to restart the stack: 'docker compose up -d' exited non-zero. The .env files were already updated with the new IPs, but the running containers may still be bound to the old ones -- fix the issue (e.g. confirm the new IP is assigned to this host) and rerun: docker compose --env-file $deploy_env -f $install_dir/docker-compose.yml up -d"
    fi

    printf "\n"
    printf "${BOLD}${GREEN}════════════════════════════════════════${RESET}\n"
    printf "${BOLD}${GREEN}  Reconfiguration complete!${RESET}\n"
    printf "${BOLD}${GREEN}════════════════════════════════════════${RESET}\n"
    printf "\n"
    printf "  Done. Update your clients to use the new DNS IP.\n\n"

    exit 0
}

# ── secondary subcommand ──────────────────────────────────────────────────────
# Secondary setup is intentionally separate from primary install: it consumes
# credentials returned by the primary UI/API, writes a small DNS-only compose
# directory, and must not modify the primary host configuration.
cmd_secondary() {
    local primary="" token="" name="" proxy_ip="" listen_ip="" rotate=0
    local response_file http_status response secondary_dir
    local nats_url nats_user nats_password consumer_name pdns_api_key
    local response_image_registry response_image_prefix response_image_channel response_image_tag
    local existing_env_file lancache_image_registry lancache_image_prefix lancache_image_channel lancache_image_tag
    local explicit_lancache_image_tag keep_known_good_configs
    local preflight_dir preflight_env_file preflight_registry preflight_prefix preflight_channel
    local preflight_tag preflight_verified_registry="" preflight_verified_prefix="" preflight_verified_tag=""
    local missing_fields secondary_env_file

    usage_secondary() {
        cat <<EOF
Usage: $0 secondary --primary <url> --token <token> --name <name> --proxy-ip <ip> [--listen-ip <ip>] [--rotate]

Required arguments:
  --primary <url>    Primary LanCache UI/API URL, for example http://192.168.1.10:8080
  --token <token>    Secondary registration token from the primary server
  --name <name>      Secondary node name, using letters, numbers, and dashes only
  --proxy-ip <ip>    Primary proxy IP address clients should use for cached traffic

Optional arguments:
  --listen-ip <ip>   Bind IP for the secondary DNS container (default: detected host LAN IP)
  --rotate           Reuse an existing secondary directory and refresh credentials
EOF
    }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --primary)
                require_value "$1" "${2:-}"
                primary="$2"
                shift 2
                ;;
            --token)
                require_value "$1" "${2:-}"
                token="$2"
                shift 2
                ;;
            --name)
                require_value "$1" "${2:-}"
                name="$2"
                shift 2
                ;;
            --proxy-ip)
                require_value "$1" "${2:-}"
                proxy_ip="$2"
                shift 2
                ;;
            --listen-ip)
                require_value "$1" "${2:-}"
                listen_ip="$2"
                shift 2
                ;;
            --rotate)
                rotate=1
                shift
                ;;
            -h|--help)
                usage_secondary
                exit 0
                ;;
            *)
                usage_secondary >&2
                die "Unknown argument: $1"
                ;;
        esac
    done

    missing_args=()
    [[ -n "$primary" ]] || missing_args+=("--primary")
    [[ -n "$token" ]] || missing_args+=("--token")
    [[ -n "$name" ]] || missing_args+=("--name")
    [[ -n "$proxy_ip" ]] || missing_args+=("--proxy-ip")
    if [[ ${#missing_args[@]} -gt 0 ]]; then
        die "Required argument(s) missing: ${missing_args[*]}"
    fi

    for cmd in curl docker; do
        command -v "$cmd" >/dev/null 2>&1 \
            || die "$cmd is not installed or is not in PATH"
    done

    docker compose version >/dev/null 2>&1 \
        || die "'docker compose' is not available; install Docker Compose v2 before continuing"

    [[ "$name" =~ ^[a-zA-Z0-9-]+$ ]] \
        || die "--name must contain only alphanumeric characters and dashes"
    is_valid_ipv4 "$proxy_ip" \
        || die "--proxy-ip must be a valid IPv4 address"
    if [[ -n "$listen_ip" ]]; then
        is_valid_ipv4 "$listen_ip" \
            || die "--listen-ip must be a valid IPv4 address"
    else
        listen_ip=$(detect_secondary_listen_ip) \
            || die "Could not auto-detect a secondary bind IP. Re-run with --listen-ip <ip>."
    fi
    listen_ip=$(secondary_choose_listen_ip "$listen_ip") \
        || die "No free secondary bind IP available on port 53. Re-run with --listen-ip <ip> after freeing the port."
    print_ok "Secondary DNS bind IP: ${listen_ip}"
    assert_prebuilt_image_platform_supported

    # --rotate against an existing secondary directory can resolve
    # registry/prefix/channel/tag entirely from local config (an explicit
    # LANCACHE_IMAGE_* env var or the existing .env) with no need for the
    # primary's response below. Check the platform for that case here, before
    # the registration POST rotates this secondary's NATS password on the
    # primary (#665) -- otherwise a Buildx/platform failure surfacing only
    # after the POST would leave the primary already expecting the new
    # password while this host's .env still has the old one, with no way to
    # recover except registering again. A fresh (non-rotate) registration has
    # no local .env to resolve from yet, so it necessarily keeps relying on
    # the existing post-registration check further down; the same is true for
    # a --rotate run whose local channel/tag genuinely can't be resolved
    # without the primary's response (e.g. a still-mutable, non-pinned
    # channel with no LANCACHE_IMAGE_TAG override).
    if [[ "$rotate" -eq 1 ]]; then
        preflight_dir="${name}"
        if [[ "$(basename "$PWD")" = "$name" && -f .env && -f docker-compose.yml ]]; then
            preflight_dir="."
        fi
        preflight_env_file=""
        [[ -f "${preflight_dir}/.env" ]] && preflight_env_file="${preflight_dir}/.env"

        if [[ -n "$preflight_env_file" ]]; then
            preflight_registry="${LANCACHE_IMAGE_REGISTRY:-$(get_env_var LANCACHE_IMAGE_REGISTRY "$preflight_env_file")}"
            preflight_prefix="${LANCACHE_IMAGE_PREFIX:-$(get_env_var LANCACHE_IMAGE_PREFIX "$preflight_env_file")}"
            preflight_channel="${LANCACHE_IMAGE_CHANNEL:-$(get_env_var LANCACHE_IMAGE_CHANNEL "$preflight_env_file")}"

            if [[ -n "$preflight_registry" && -n "$preflight_prefix" && -n "$preflight_channel" ]]; then
                validate_lancache_image_registry "$preflight_registry"
                validate_lancache_image_prefix "$preflight_prefix"
                validate_lancache_image_channel "$preflight_channel"

                # A non-pinned (mutable) channel with no explicit
                # LANCACHE_IMAGE_TAG override still resolves entirely from
                # local/registry state (it pulls the channel's own pointer
                # image), so it counts as locally resolvable too. A pinned
                # channel, by contrast, has no channel pointer of its own --
                # it requires an actual tag from either the shell env or the
                # existing .env; if neither has one, only the primary's
                # response can supply it, so this preflight must be skipped.
                if [[ "$preflight_channel" != "pinned" \
                    || -n "${LANCACHE_IMAGE_TAG:-}" \
                    || -n "$(get_env_var LANCACHE_IMAGE_TAG "$preflight_env_file")" ]]; then
                    preflight_tag=$(LANCACHE_IMAGE_REGISTRY="$preflight_registry" \
                        LANCACHE_IMAGE_PREFIX="$preflight_prefix" \
                        LANCACHE_IMAGE_CHANNEL="$preflight_channel" \
                        resolve_lancache_image_tag "$preflight_env_file")
                    assert_resolved_image_tag_platform_supported "$preflight_registry" "$preflight_prefix" "$preflight_tag"
                    preflight_verified_registry="$preflight_registry"
                    preflight_verified_prefix="$preflight_prefix"
                    preflight_verified_tag="$preflight_tag"
                fi
            fi
        fi
    fi

    print_step "Registering secondary"
    response_file=$(mktemp)
    SECONDARY_RESPONSE_FILE="$response_file"
    trap 'rm -f -- "${SECONDARY_RESPONSE_FILE:-}"' EXIT

    # The registration token is passed to curl as a JSON body read from
    # stdin (`-d @-`), not as a literal `-d "..."` argument: the latter puts
    # the token in this process's argv for the whole request's lifetime
    # (visible to anything reading `ps`/`/proc/<pid>/cmdline` on this host),
    # the same exposure class already fixed for kea_ctrl_post's Basic-Auth
    # credential (#955/#956).
    # #1084: also report this secondary's chosen DNS bind IP so the primary can
    # store it and later run an active health probe against it. Harmless if the
    # primary is older and ignores the field; the primary validates it as a
    # private IPv4 before storing, so a blank/odd value is simply dropped.
    if ! http_status=$(printf '{"token":"%s","name":"%s","address":"%s"}' "$token" "$name" "$listen_ip" \
        | curl -sS -o "$response_file" -w "%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d @- \
        "${primary}/api/secondary/register"); then
        die "Failed to connect to primary server at ${primary}. Check the URL, network connectivity, and that the primary service is running."
    fi

    response=$(cat "$response_file")
    rm -f -- "$response_file"
    SECONDARY_RESPONSE_FILE=""
    trap - EXIT

    if [[ "$http_status" = "503" ]]; then
        # Issue #866: the primary's register_secondary refuses with 503,
        # specifically (not a generic 4xx), when it has no genuinely
        # reachable NATS URL to hand out -- neither NATS_BIND_IP nor
        # NATS_ADVERTISE_URL is configured on the primary. This is not a
        # problem with this command's own arguments, so give the operator
        # the actual fix instead of the generic "verify token/name" message
        # below, which would send them looking in the wrong place.
        #
        # Setting NATS_BIND_IP/NATS_ADVERTISE_URL and restarting only the
        # `ui` container is NOT sufficient on its own: `ui` only reads the
        # value to compute what to advertise, but the `nats` service itself
        # still needs `docker-compose.nats-secondary.yml` included (and the
        # stack recreated with it) to actually publish port 4222 on that
        # address -- see that file's own `NATS_BIND_IP:?...` host-port
        # binding. Telling the operator to restart only `ui` here would let
        # registration "succeed" while `nats` still has no host-port
        # publish, reproducing the exact silent-sync-failure this change
        # exists to prevent.
        #
        # The recreate example must include `--env-file .env.local` when
        # that is where the operator set the variable: Docker Compose only
        # auto-loads the project directory's default `.env`, never
        # `.env.local`, so a recreate command copied verbatim without
        # `--env-file .env.local` would leave `NATS_BIND_IP`'s
        # `${NATS_BIND_IP:?...}` guard in docker-compose.nats-secondary.yml
        # unset and the override would not actually apply.
        die "Primary server at ${primary} is not configured to register remote secondaries (HTTP 503): it needs NATS_BIND_IP (or the more specific NATS_ADVERTISE_URL) set in its .env/.env.local to a NATS address this secondary can reach, AND its 'nats' service recreated with the docker-compose.nats-secondary.yml override included -- e.g. docker compose -f docker-compose.yml -f docker-compose.nats-secondary.yml up -d if the variable is in .env, or docker compose --env-file .env.local -f docker-compose.yml -f docker-compose.nats-secondary.yml up -d if it is in .env.local (Compose does not auto-load .env.local) -- so NATS actually publishes that address; restarting only the ui container is not enough. See docs/architecture-ng.md's \"Remote secondary NATS access\" section."
    elif [[ ! "$http_status" =~ ^2 ]]; then
        die "Primary server rejected the registration request with HTTP ${http_status}. Verify the registration token, secondary name, and primary server logs."
    fi
    [[ -n "$response" ]] || die "Empty response from primary server after successful registration request"

    nats_url=$(echo "$response" | grep -oP '"nats_url"\s*:\s*"\K[^"]*' || true)
    nats_user=$(echo "$response" | grep -oP '"nats_user"\s*:\s*"\K[^"]*' || true)
    nats_password=$(echo "$response" | grep -oP '"nats_password"\s*:\s*"\K[^"]*' || true)
    consumer_name=$(echo "$response" | grep -oP '"consumer_name"\s*:\s*"\K[^"]*' || true)
    pdns_api_key=$(echo "$response" | grep -oP '"pdns_api_key"\s*:\s*"\K[^"]*' || true)
    response_image_registry=$(echo "$response" | grep -oP '"image_registry"\s*:\s*"\K[^"]*' || true)
    response_image_prefix=$(echo "$response" | grep -oP '"image_prefix"\s*:\s*"\K[^"]*' || true)
    response_image_channel=$(echo "$response" | grep -oP '"image_channel"\s*:\s*"\K[^"]*' || true)
    response_image_tag=$(echo "$response" | grep -oP '"image_tag"\s*:\s*"\K[^"]*' || true)

    missing_fields=()
    [[ -n "$nats_url" ]] || missing_fields+=("nats_url")
    [[ -n "$nats_user" ]] || missing_fields+=("nats_user")
    [[ -n "$nats_password" ]] || missing_fields+=("nats_password")
    [[ -n "$consumer_name" ]] || missing_fields+=("consumer_name")
    [[ -n "$pdns_api_key" ]] || missing_fields+=("pdns_api_key")
    if [[ ${#missing_fields[@]} -gt 0 ]]; then
        die "Invalid response from primary server; missing field(s): ${missing_fields[*]}"
    fi

    secondary_dir="${name}"
    if [[ "$rotate" -eq 1 ]]; then
        if [[ "$(basename "$PWD")" = "$name" && -f .env && -f docker-compose.yml ]]; then
            secondary_dir="."
        elif [[ ! -d "$secondary_dir" ]]; then
            die "No existing secondary directory '${secondary_dir}' found. Run --rotate from its parent directory or from inside the existing '${name}' directory."
        fi
    elif [[ -d "$secondary_dir" ]]; then
        die "Directory '${secondary_dir}' already exists; rerun with --rotate to update the secondary files"
    fi
    mkdir -p "$secondary_dir"

    existing_env_file=""
    if [[ -f "${secondary_dir}/.env" ]]; then
        existing_env_file="${secondary_dir}/.env"
    fi

    lancache_image_registry="${LANCACHE_IMAGE_REGISTRY:-}"
    if [[ -z "$lancache_image_registry" && -n "$existing_env_file" ]]; then
        lancache_image_registry=$(get_env_var LANCACHE_IMAGE_REGISTRY "$existing_env_file")
    fi
    lancache_image_registry="${lancache_image_registry:-${response_image_registry:-ghcr.io}}"
    validate_lancache_image_registry "$lancache_image_registry"

    lancache_image_prefix="${LANCACHE_IMAGE_PREFIX:-}"
    if [[ -z "$lancache_image_prefix" && -n "$existing_env_file" ]]; then
        lancache_image_prefix=$(get_env_var LANCACHE_IMAGE_PREFIX "$existing_env_file")
    fi
    lancache_image_prefix="${lancache_image_prefix:-${response_image_prefix:-wiki-mod/lancache-ng}}"
    validate_lancache_image_prefix "$lancache_image_prefix"

    lancache_image_channel="${LANCACHE_IMAGE_CHANNEL:-}"
    if [[ -z "$lancache_image_channel" && -n "$existing_env_file" ]]; then
        lancache_image_channel=$(get_env_var LANCACHE_IMAGE_CHANNEL "$existing_env_file")
    fi
    if [[ -z "$lancache_image_channel" && -n "$response_image_channel" ]]; then
        lancache_image_channel="$response_image_channel"
    fi
    if [[ -z "$lancache_image_channel" && "${response_image_tag:-}" =~ ^(stable|latest|nightly)$ ]]; then
        lancache_image_channel="$response_image_tag"
    fi
    if [[ -z "$lancache_image_channel" && "${response_image_tag:-}" =~ ^(sha-|v[0-9]) ]]; then
        lancache_image_channel="pinned"
    fi
    lancache_image_channel="${lancache_image_channel:-latest}"
    validate_lancache_image_channel "$lancache_image_channel"

    explicit_lancache_image_tag="${LANCACHE_IMAGE_TAG:-}"
    if [[ -z "$explicit_lancache_image_tag" && "$lancache_image_channel" = "pinned" && -n "$existing_env_file" ]]; then
        LANCACHE_IMAGE_TAG=$(get_env_var LANCACHE_IMAGE_TAG "$existing_env_file")
    fi
    if [[ -z "$explicit_lancache_image_tag" && "$lancache_image_channel" = "pinned" && -z "${LANCACHE_IMAGE_TAG:-}" && -n "$response_image_tag" && ! "$response_image_tag" =~ ^(stable|latest|nightly)$ ]]; then
        LANCACHE_IMAGE_TAG="$response_image_tag"
    fi
    if [[ "$lancache_image_channel" != "pinned" && -z "$explicit_lancache_image_tag" ]]; then
        if [[ -n "$response_image_tag" && "$response_image_tag" =~ ^sha- ]]; then
            LANCACHE_IMAGE_TAG="$response_image_tag"
        else
            LANCACHE_IMAGE_TAG=""
        fi
    fi
    if [[ -z "${LANCACHE_IMAGE_TAG:-}" ]]; then
        LANCACHE_IMAGE_CHANNEL="$lancache_image_channel"
    fi
    lancache_image_tag=$(LANCACHE_IMAGE_REGISTRY="$lancache_image_registry" \
        LANCACHE_IMAGE_PREFIX="$lancache_image_prefix" \
        LANCACHE_IMAGE_CHANNEL="$lancache_image_channel" \
        resolve_lancache_image_tag)

    # Verify the resolved tag actually publishes an image for this secondary
    # host's architecture before any secondary state below is written (#665).
    # The earlier assert_prebuilt_image_platform_supported call only checked
    # the host architecture in general, not this specific tag/channel. Skip
    # this if the --rotate preflight above (before the registration POST)
    # already verified these exact registry/prefix/tag values -- re-running it
    # here would only repeat the same registry inspect for no new information.
    # Any drift from the preflight (e.g. the response provided different
    # values than local config) still falls through to a fresh, real check.
    if [[ -z "$preflight_verified_tag" \
        || "$lancache_image_registry" != "$preflight_verified_registry" \
        || "$lancache_image_prefix" != "$preflight_verified_prefix" \
        || "$lancache_image_tag" != "$preflight_verified_tag" ]]; then
        assert_resolved_image_tag_platform_supported "$lancache_image_registry" "$lancache_image_prefix" "$lancache_image_tag"
    fi

    # Known-good pdns.conf/recursor.conf snapshot retention (#615): same
    # variable and default (3) as config/{dev,prod}/dns-standard.env. The
    # primary's registration response has no opinion on this -- it is a
    # purely local, per-secondary-node setting -- so resolve it the same way
    # as the image registry/prefix/channel above: an explicit env var wins,
    # then whatever the existing generated .env already had (so --rotate
    # doesn't silently reset an operator's prior choice), then the default.
    keep_known_good_configs="${KEEP_KNOWN_GOOD_CONFIGS:-}"
    if [[ -z "$keep_known_good_configs" && -n "$existing_env_file" ]]; then
        keep_known_good_configs=$(get_env_var KEEP_KNOWN_GOOD_CONFIGS "$existing_env_file")
    fi
    keep_known_good_configs="${keep_known_good_configs:-3}"

    write_generated_runtime_file "${secondary_dir}/docker-compose.yml" <<EOF
# Secondary DNS node — run on a remote host.
# Generated by setup.sh secondary — do not edit manually.
# To update credentials, rerun: ./setup.sh secondary --rotate ...

services:
  dns-secondary:
    image: \${LANCACHE_IMAGE_REGISTRY:-ghcr.io}/\${LANCACHE_IMAGE_PREFIX:-wiki-mod/lancache-ng}/dns:\${LANCACHE_IMAGE_TAG:-latest}
    environment:
      - PROXY_IP=\${PROXY_IP}
      - PDNS_API_KEY=\${PDNS_API_KEY}
      - NATS_URL=\${NATS_URL}
      - NATS_USER=\${NATS_USER}
      - NATS_PASSWORD=\${NATS_PASSWORD}
      - NATS_CONSUMER=\${NATS_CONSUMER}
      - DDNS_ALLOW_FROM=127.0.0.1
      # Known-good pdns.conf/recursor.conf snapshot retention (#615), same
      # variable/default as the primary's config/{dev,prod}/dns-standard.env.
      - KEEP_KNOWN_GOOD_CONFIGS=\${KEEP_KNOWN_GOOD_CONFIGS:-3}
    volumes:
      - pdns-data:/var/lib/powerdns
      - pdns-filter-state:/var/lib/powerdns-state
      # Known-good pdns.conf/recursor.conf snapshots (#615): without this,
      # a secondary node keeps its rollback baseline only in the container
      # layer, and loses it on every image update/recreate.
      - pdns-config-snapshots:/var/lib/lancache-dns
    ports:
      - "\${LISTEN_IP:?Set LISTEN_IP to the secondary host LAN IP}:53:53/udp"
      - "\${LISTEN_IP:?Set LISTEN_IP to the secondary host LAN IP}:53:53/tcp"
    healthcheck:
      # Real query/response probe (AG-VAL-018), not bare \`rec_control ping\`
      # (liveness only -- proves the control socket answers, not that DNS
      # itself resolves, AG-VAL-019). Matches
      # deploy/quickstart/docker-compose.yml's compliant check (#869):
      # dnsutils/dig is already installed in this image
      # (services/dns/Dockerfile). cdn-domains.txt is baked into the image
      # itself (\`COPY cdn-domains.txt /etc/pdns/cdn-domains.txt\` in
      # services/dns/Dockerfile, no bind mount needed here), and the RPZ
      # zone is generated from that file during entrypoint.sh's startup
      # sequence, before the NATS subscriber even starts -- verified live
      # against ghcr.io/wiki-mod/lancache-ng/dns:latest. NATS here only
      # syncs the dynamic \`lan.\` zone from the primary, not the CDN list,
      # so this check does not depend on NATS reconciliation and has the
      # same timing profile as every other profile's DNS containers.
      test: ["CMD-SHELL", "dig @127.0.0.1 content1.steampowered.com A +short +time=2 +tries=1 | grep -q ."]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    restart: always
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "2"

volumes:
  pdns-data:
  pdns-filter-state:
  pdns-config-snapshots:
EOF

    secondary_env_file="$(realpath -m "${secondary_dir}/.env")"

    write_env_file "${secondary_dir}/.env" <<EOF
PROXY_IP=${proxy_ip}
LISTEN_IP=${listen_ip}
PDNS_API_KEY=${pdns_api_key}
NATS_URL=${nats_url}
NATS_USER=${nats_user}
NATS_PASSWORD=${nats_password}
NATS_CONSUMER=${consumer_name}
KEEP_KNOWN_GOOD_CONFIGS=${keep_known_good_configs}
LANCACHE_IMAGE_REGISTRY=${lancache_image_registry}
LANCACHE_IMAGE_PREFIX=${lancache_image_prefix}
LANCACHE_IMAGE_CHANNEL=${lancache_image_channel}
LANCACHE_IMAGE_TAG=${lancache_image_tag}
EOF

    print_step "Starting secondary DNS container"
    (cd "$secondary_dir" && docker compose --env-file "$secondary_env_file" up -d) \
        || die "Failed to start docker compose in ${secondary_dir}. Review Docker logs and the generated compose file."

    print_ok "Secondary DNS '${name}' is running. Configure this host's IP as DNS on your clients."
}

# ── Dispatch subcommands ──────────────────────────────────────────────────────
# Keep this command router in setup.sh rather than splitting files. Operators can
# read one script, while command names still follow a simple verb / verb-suffix
# pattern: install, update, update-ip, debug, backup, restore.
case "${1:-install}" in
    install|"")
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help install
            exit 0
        fi
        ;;
    update)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help update
            exit 0
        fi
        cmd_update "${2:-/opt/lancache-ng}"; exit 0 ;;
    auto-update)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help auto-update
            exit 0
        fi
        cmd_auto_update "${2:-/opt/lancache-ng}"; exit 0 ;;
    converge-reconcile)
        # Internal-only (#819): invoked by lancache-converge.service, not
        # documented in print_command_help/print_usage and not meant for
        # interactive use -- see cmd_converge_reconcile's own comment for what
        # it does and why.
        cmd_converge_reconcile "${2:-/opt/lancache-ng}"; exit 0 ;;
    debug)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help debug
            exit 0
        fi
        cmd_debug  "${2:-/opt/lancache-ng}"; exit 0 ;;
    create-logs-for-issue)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help create-logs-for-issue
            exit 0
        fi
        shift; cmd_create_logs_for_issue "$@"; exit 0 ;;
    backup)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help backup
            exit 0
        fi
        shift; cmd_backup "$@"; exit 0 ;;
    restore)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help restore
            exit 0
        fi
        shift; cmd_restore "$@"; exit 0 ;;
    secondary)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help secondary
            exit 0
        fi
        shift; cmd_secondary "$@"; exit 0 ;;
    --secondary)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help secondary
            exit 0
        fi
        shift; cmd_secondary "$@"; exit 0 ;;
    update-ip|--reconfigure|reconfigure)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help update-ip
            exit 0
        fi
        cmd_update_ip "${2:-/opt/lancache-ng}"; exit 0 ;;
    reset-to-last-known-good-config)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help reset-to-last-known-good-config
            exit 0
        fi
        shift; cmd_reset_to_last_known_good_config "$@"; exit 0 ;;
    help|--help|-h) print_usage; exit 0 ;;
    *)           die "Unknown command: $1\nRun './setup.sh --help' for available commands." ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# Main setup
# ══════════════════════════════════════════════════════════════════════════════
# This is the first-user production flow. Keep it linear and readable: prompt
# for runtime choices, write the config once, install watchdog units, show the
# final summary, then pull/start prebuilt containers.

printf "\n"
printf "${BOLD}╔══════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}║      LanCache-NG — Initial Setup        ║${RESET}\n"
printf "${BOLD}╚══════════════════════════════════════════╝${RESET}\n"
printf "\n"
printf "  This script sets up LanCache-NG and starts all containers.\n"
printf "  After: ./setup.sh update  |  ./setup.sh debug  |  ./setup.sh update-ip\n"
printf "  Help:  ./setup.sh --help (use './setup.sh <command> --help' for details)\n"

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
print_step "Checking prerequisites"

[[ "$(id -u)" = "0" ]] \
    || die "This script must be run as root (sudo ./setup.sh)."

assert_prebuilt_image_platform_supported

if ! command -v curl >/dev/null 2>&1; then
    install_curl
fi

if ! command -v docker >/dev/null 2>&1; then
    install_docker
    print_ok "Docker installed"
fi

if ! docker info >/dev/null 2>&1; then
    print_warn "Docker daemon not running — starting now..."
    systemctl enable --now docker \
        || die "Failed to start Docker daemon."
fi

if ! docker compose version >/dev/null 2>&1; then
    install_docker_compose
fi

docker compose version >/dev/null 2>&1 \
    || die "Docker Compose plugin still missing after installing Docker requirements."

if [[ ! -f "$QUICKSTART_COMPOSE" ]]; then
    print_warn "No local repo found — cloning to /opt/lancache-ng..."
    if ! command -v git >/dev/null 2>&1; then
        install_git
    fi
    setup_bootstrap_ref=$(resolve_setup_bootstrap_ref)
    if [[ -d "/opt/lancache-ng/.git" ]]; then
        if [[ -n "$setup_bootstrap_ref" ]]; then
            print_warn "Existing checkout found at /opt/lancache-ng — syncing to LANCACHE_SETUP_GIT_REF=${setup_bootstrap_ref}..."
            sync_repo_to_ref /opt/lancache-ng "$setup_bootstrap_ref"
        else
            print_warn "Existing checkout found at /opt/lancache-ng — syncing to the remote default branch..."
            sync_repo_to_default_branch /opt/lancache-ng
        fi
    elif [[ -n "$setup_bootstrap_ref" ]]; then
        git clone --branch "$setup_bootstrap_ref" https://github.com/wiki-mod/lancache-ng.git /opt/lancache-ng \
            || die "Clone failed for LANCACHE_SETUP_GIT_REF='${setup_bootstrap_ref}'. Check that it names a real branch or tag on origin."
    else
        git clone https://github.com/wiki-mod/lancache-ng.git /opt/lancache-ng \
            || die "Clone failed."
    fi
    chmod +x /opt/lancache-ng/setup.sh
    exec /opt/lancache-ng/setup.sh "$@"
fi

print_ok "Docker $(docker --version | grep -oP '[\d.]+' | head -1)"
print_ok "Docker Compose $(docker compose version --short 2>/dev/null || true)"

# ── 2. Network IPs ────────────────────────────────────────────────────────────
print_step "Network configuration"

detected_ip=$(ip -4 addr show | grep -oP '(?<=inet )[\d.]+' \
    | grep -v '^127\.' | grep -v '^172\.' | head -1 || true)
detected_iface=$(ip -4 route show default | awk '{print $5}' | head -1 || true)

printf "\n  Found LAN addresses:\n"
ip -4 addr show | grep "inet " | grep -v " 127\." | grep -v " 172\." \
    | awk '{print "    " $2}' || true
printf "\n"

while true; do
    ask "Server IP (Standard mode)" "${detected_ip:-192.168.1.10}"
    IP_STANDARD="$REPLY"
    is_valid_ipv4 "$IP_STANDARD" && break
    print_error "Invalid IPv4 address: $IP_STANDARD"
done

printf "\n"
printf "  ${BOLD}SSL mode${RESET}: also caches HTTPS downloads (Epic, EA, Blizzard…)\n"
printf "  Requires a second IP and a CA certificate on clients.\n\n"
ask "Enable SSL mode? [y/N]" "N"
SSL_ENABLED=0
IP_SSL=""
if [[ "${REPLY,,}" = "y" ]]; then
    SSL_ENABLED=1
    suggested_ssl="${IP_STANDARD%.*}.$((10#${IP_STANDARD##*.} + 1))"
    while true; do
        ask "SSL mode IP (second LAN IP)" "$suggested_ssl"
        IP_SSL="$REPLY"
        is_valid_ipv4 "$IP_SSL" && break
        print_error "Invalid IPv4 address: $IP_SSL"
    done
    [[ "$IP_STANDARD" != "$IP_SSL" ]] \
        || die "Standard IP and SSL IP must be different."
    if ip -4 addr show | grep -q "inet ${IP_SSL}/"; then
        print_ok "$IP_SSL already assigned"
    else
        print_warn "$IP_SSL not yet assigned to an interface"
        ask "Add now? (ip addr add $IP_SSL/24 dev ${detected_iface:-eth0}) [y/N]" "N"
        if [[ "${REPLY,,}" = "y" ]]; then
            ip addr add "$IP_SSL/24" dev "${detected_iface:-eth0}" \
                && print_ok "$IP_SSL added (not persistent)" \
                || print_warn "Adding failed — please add manually"
        fi
        printf "\n"
        print_warn "For persistent configuration after reboot:"
        printf "    netplan:    sudo nano /etc/netplan/01-netcfg.yaml\n"
        printf "    interfaces: sudo nano /etc/network/interfaces\n"
    fi
    print_ok "SSL mode enabled ($IP_SSL)"
else
    print_ok "SSL mode skipped — standard mode only"
fi

# ── 3. Installation directory ─────────────────────────────────────────────────
print_step "Installation directory"

ask "Directory" "/opt/lancache-ng"
INSTALL_DIR="$(realpath -m "$REPLY")"

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_warn "Existing directory found: $INSTALL_DIR"
    ask "Overwrite? [y/N]" "N"
    [[ "${REPLY,,}" = "y" ]] || die "Cancelled."
fi

mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/certs"
install_quickstart_compose_assets "$INSTALL_DIR"
print_ok "quickstart compose assets copied to $INSTALL_DIR"

# ── 4. Cache configuration ───────────────────────────────────────────────────
print_step "Cache configuration"

while true; do
    ask "Cache directory (absolute path)" "$INSTALL_DIR/cache"
    CACHE_DIR="$REPLY"
    is_absolute_path "$CACHE_DIR" && break
    print_error "Please enter an absolute path (e.g. $INSTALL_DIR/cache)."
done

# Checked against the nearest existing ancestor of CACHE_DIR (see
# nearest_existing_ancestor_dir) since CACHE_DIR itself is only created later
# via `mkdir -p`. Computed once, before the loop: the operator's answer to
# this prompt cannot change which filesystem CACHE_DIR lives on.
cache_dir_avail_mib=$(available_space_mib_at "$CACHE_DIR")

while true; do
    ask "Cache size in GiB" "50"
    cache_gb="$REPLY"
    if ! is_positive_integer "$cache_gb"; then
        print_error "Please enter a positive integer (e.g. 50)."
        continue
    fi
    # Canonicalize away any leading zero (e.g. "008") before this value is
    # used in bash arithmetic below: without the 10# base prefix, an
    # unnormalized leading-zero string is parsed as octal by `((...))`, and
    # digits 8/9 in that string would abort the script with a bash
    # arithmetic error rather than a clean validation message.
    cache_gb=$(( 10#$cache_gb ))
    cache_size_fits_available_mib "$cache_gb" "$cache_dir_avail_mib" && break
    # Issue #1069: reject a cache size that would not leave a safety buffer on
    # the real disk backing CACHE_DIR, instead of silently writing a
    # CACHE_MAX_SIZE the disk cannot possibly satisfy. Buffer scales with the
    # requested size -- see cache_size_buffer_mib.
    largest_valid_gb=$(largest_valid_cache_gb "$cache_dir_avail_mib" || true)
    if (( largest_valid_gb >= 1 )); then
        print_error "$cache_gb GiB would not leave a safety buffer at $CACHE_DIR (only $(( cache_dir_avail_mib / 1024 )) GiB free there). The largest value that currently passes is ${largest_valid_gb} GiB."
    else
        print_error "Not enough free space at $CACHE_DIR for any cache size with a safety buffer (only $(( cache_dir_avail_mib / 1024 )) GiB free there). Free up disk space or choose a different cache directory."
    fi
done

while true; do
    ask "Cache RAM buffer in MB (keys_zone)" "512"
    CACHE_MEM_MB="$REPLY"
    is_positive_integer "$CACHE_MEM_MB" && break
    print_error "Please enter a positive integer (e.g. 512)."
done

while true; do
    ask "Cache entry max age (inactive; e.g. 365d, 30d, 12h)" "365d"
    cache_inactive="$REPLY"
    is_valid_nginx_time_value "$cache_inactive" && break
    print_error "Please enter an nginx-style time value (e.g. 365d, 30d, 12h)."
done

# ── 5. Release channel ────────────────────────────────────────────────────────
print_step "Release channel"

# Unlike the other prompts in this flow (INSTALL_DIR, detected_ip, ...), an
# already-set LANCACHE_IMAGE_CHANNEL is NOT just a default to confirm -- it is
# respected outright and the prompt is skipped entirely. Two real callers rely
# on this: (1) the documented `LANCACHE_IMAGE_CHANNEL=nightly ./setup.sh install`
# non-interactive invocation (see resolve_lancache_stack_channel_tag's own
# die() message), and (2) scripts/setup-cli-simulation.sh, which exports
# LANCACHE_IMAGE_CHANNEL=pinned (plus an explicit LANCACHE_IMAGE_TAG) so CI
# installs THIS commit's own just-built images rather than any published
# channel. "pinned" is not a stable/nightly choice at all -- it is a request for
# one specific immutable tag -- so re-prompting and overwriting it with
# whatever the operator/simulation answers here would silently discard that
# request (a real regression caught in CI, not a hypothetical). Respecting any
# pre-set value, of any kind, keeps this idempotent with the rest of this
# script's "existing non-empty local values must be preserved by default"
# convention (AGENTS.md) instead of treating this one field as an exception.
if [[ -n "${LANCACHE_IMAGE_CHANNEL:-}" ]]; then
    validate_lancache_image_channel "$LANCACHE_IMAGE_CHANNEL"
    print_ok "Using the channel already set via LANCACHE_IMAGE_CHANNEL=${LANCACHE_IMAGE_CHANNEL}."
else
    printf "  stable — the channel promoted after the full release validation gate.\n"
    printf "           Recommended for most installs. This is what './setup.sh update'\n"
    printf "           tracks by default, and what most operators should stay on.\n"
    printf "  nightly — the most recently built channel from active development.\n"
    printf "            Refreshes continuously from current_dev, may be less tested\n"
    printf "            than stable. Opt in only if you specifically want the newest\n"
    printf "            changes and accept the extra risk.\n\n"

    # Writes the plain LANCACHE_IMAGE_CHANNEL shell variable that
    # resolve_lancache_image_channel already checks first (see its precedence
    # comment above); nothing downstream needs to change to pick this up.
    # "stable" and "latest" resolve to the identical published stack pointer
    # (see resolve_lancache_stack_channel_tag) -- "stable" is only the
    # friendlier, self-explanatory name this prompt writes for new installs.
    while true; do
        ask "Release channel [stable/nightly]" "stable"
        case "${REPLY,,}" in
            stable)
                LANCACHE_IMAGE_CHANNEL="stable"
                print_ok "Using the stable channel (recommended)."
                break
                ;;
            nightly)
                LANCACHE_IMAGE_CHANNEL="nightly"
                print_warn "Using the nightly channel — more recent, less tested than stable."
                break
                ;;
            # "edge" was the old name of the nightly channel (renamed in v0.3.0,
            # #1056) and is intentionally NOT accepted as a synonym here -- point
            # the operator at the new name rather than silently substituting it.
            edge)
                print_error "The 'edge' channel was renamed to 'nightly' in v0.3.0. Please answer 'nightly'."
                ;;
            *)
                print_error "Please answer 'stable' or 'nightly'."
                ;;
        esac
    done
fi

# ── 6. Scheduled automatic updates ────────────────────────────────────────────
# Replaces the former Watchtower opt-in (#819): Watchtower was removed because
# it structurally cannot deliver what this project needs from an updater --
# it never verifies a container/stack is actually healthy after recreating it
# (its one health-aware mode is documented as incompatible with any container
# that has dependency links, which this stack's own depends_on topology
# rules out outright), and it has no rollback path at all. This project's own
# orchestrator (cmd_auto_update, invoked by a host systemd timer -- see the
# "Installing systemd watchdog" step below) replaces it: it only acts when
# the channel pointer actually moved, brings the whole stack up ordered and
# health-gated with the Admin UI last, and rolls back to the pre-update
# backup on a failed health check, instead of Watchtower's uncoordinated
# per-container recreate-and-hope.
print_step "Scheduled automatic updates"

printf "  A systemd timer can periodically run this project's own update logic:\n"
printf "  it only proceeds if the release channel actually moved to a new\n"
printf "  immutable image set, brings every service except the Admin UI up first\n"
printf "  and verifies it is healthy, updates the Admin UI last, and rolls back to\n"
printf "  the pre-update backup automatically if a health check fails.\n"
printf "  Default: disabled — update manually any time with: ./setup.sh update\n\n"

ask "Enable scheduled automatic updates? [y/N]" "N"
AUTO_UPDATE_ENABLED=0
if [[ "${REPLY,,}" = "y" ]]; then
    AUTO_UPDATE_ENABLED=1
    print_ok "Scheduled automatic updates enabled (ordered, health-gated, daily)"
else
    print_warn "Scheduled automatic updates disabled — manual updates with: ./setup.sh update"
fi

COMPOSE_PROFILES=""
[[ "$SSL_ENABLED" = "1" ]] && COMPOSE_PROFILES="ssl"

# ── 7. DHCP mode ─────────────────────────────────────────────────────────────
print_step "DHCP mode"

printf "  Kea (full mode): route and DNS options via Admin-UI\n"
printf "  dnsmasq-proxy: experimental proxy-DHCP helper; it does not reliably replace DNS options from a normal router DHCP server\n"
printf "  disabled: keep router DHCP and do nothing in LanCache\n\n"

while true; do
    ask "DHCP mode (disabled, kea, dnsmasq-proxy)" "disabled"
    DHCP_MODE="${REPLY,,}"
    if is_valid_dhcp_mode "$DHCP_MODE"; then
        break
    fi
    print_error "Invalid DHCP mode: $DHCP_MODE"
done

DHCP_ENABLED=0
KEA_DATA_DIR=""
DHCP_SUBNET=""
DHCP_GATEWAY="10.0.0.1"
DHCP_RANGE_START=""
DHCP_RANGE_END=""
DHCP_SUBNET_START=""
DHCP_DNS_PRIMARY="$IP_STANDARD"
DHCP_DNS_SECONDARY="${IP_SSL:-$IP_STANDARD}"
UPSTREAM_DHCP_IP="$DHCP_GATEWAY"
# Issue #450: additional optional dnsmasq relay/proxy fields, all left empty
# unless the operator opts in below.
DHCP_PROXY_INTERFACE=""
DHCP_PROXY_ROUTER=""
DHCP_NTP_SERVERS=""
DHCP_PROXY_DOMAIN=""
DHCP_PROXY_BOOT_FILENAME=""
DHCP_PROXY_BOOT_SERVER=""
DHCP_PROXY_CUSTOM_OPTIONS=""

if [[ "$DHCP_MODE" = "kea" ]]; then
    DHCP_ENABLED=1

    while true; do
        ask "Kea data directory (config + leases, absolute path)" "$INSTALL_DIR/kea"
        KEA_DATA_DIR="$REPLY"
        is_absolute_path "$KEA_DATA_DIR" && break
        print_error "Please enter an absolute path (e.g. $INSTALL_DIR/kea)."
    done

    while true; do
        ask "DHCP subnet (CIDR)" "10.0.0.0/24"
        DHCP_SUBNET="$REPLY"
        is_valid_cidr "$DHCP_SUBNET" && break
        print_error "Invalid CIDR: $DHCP_SUBNET"
    done

    while true; do
        ask "Gateway" "10.0.0.1"
        DHCP_GATEWAY="$REPLY"
        is_valid_ipv4 "$DHCP_GATEWAY" && break
        print_error "Invalid IPv4 address: $DHCP_GATEWAY"
    done

    while true; do
        ask "IP pool start" "10.0.0.128"
        DHCP_RANGE_START="$REPLY"
        is_valid_ipv4 "$DHCP_RANGE_START" && break
        print_error "Invalid IPv4 address: $DHCP_RANGE_START"
    done

    while true; do
        ask "IP pool end" "10.0.0.254"
        DHCP_RANGE_END="$REPLY"
        is_valid_ipv4 "$DHCP_RANGE_END" && break
        print_error "Invalid IPv4 address: $DHCP_RANGE_END"
    done

    print_ok "DHCP enabled in Kea mode — Subnet: $DHCP_SUBNET, Pool: $DHCP_RANGE_START–$DHCP_RANGE_END"
    print_warn "Before Kea is activated, setup will run a non-invasive DHCP discovery preflight."
    print_warn "Kea Control Agent port 8000 should be restricted by firewall"
    printf "  iptables (legacy):  iptables -I INPUT -p tcp --dport 8000 ! -s 172.28.0.0/16 -j DROP\n"
    printf "  nftables:           nft add rule inet filter input tcp dport 8000 ip saddr != 172.28.0.0/16 drop\n"
    printf "  ufw:                ufw deny from any to any port 8000\n\n"
elif [[ "$DHCP_MODE" = "dnsmasq-proxy" ]]; then
    print_warn "dnsmasq-proxy uses dnsmasq proxy-DHCP."
    print_warn "It does not reliably replace DNS options from a normal router DHCP server."
    print_warn "Use Kea mode if LanCache must control normal client DNS settings."
    confirm "Continue with experimental dnsmasq-proxy mode? [y/N]" "N" \
        || die "Cancelled dnsmasq-proxy mode. Re-run setup and choose kea or disabled."

    ask "DHCP subnet start for dnsmasq-proxy" "10.0.0.0"
    while true; do
        DHCP_SUBNET_START="$REPLY"
        is_dnsmasq_subnet_start "$DHCP_SUBNET_START" && break
        print_error "DHCP subnet start must be a network address ending in .0, e.g. 10.0.0.0"
        ask "DHCP subnet start for dnsmasq-proxy" "10.0.0.0"
    done

    while true; do
        ask "Primary DNS option for proxy-DHCP/PXE clients" "$DHCP_DNS_PRIMARY"
        DHCP_DNS_PRIMARY="$REPLY"
        is_valid_ipv4 "$DHCP_DNS_PRIMARY" && break
        print_error "Invalid IPv4 address: $DHCP_DNS_PRIMARY"
    done

    while true; do
        ask "Secondary DNS option for proxy-DHCP/PXE clients" "$DHCP_DNS_SECONDARY"
        DHCP_DNS_SECONDARY="$REPLY"
        is_valid_ipv4 "$DHCP_DNS_SECONDARY" && break
        print_error "Invalid IPv4 address: $DHCP_DNS_SECONDARY"
    done

    while true; do
        ask "Upstream DHCP server IP" "$DHCP_GATEWAY"
        UPSTREAM_DHCP_IP="$REPLY"
        is_valid_ipv4 "$UPSTREAM_DHCP_IP" && break
        print_error "Invalid IPv4 address: $UPSTREAM_DHCP_IP"
    done

    # Issue #450: additional optional dnsmasq relay/proxy options. All are
    # skippable (empty = not configured); this whole block is only offered
    # if the operator explicitly wants it, so a plain Enter through the
    # required prompts above still gets a working minimal proxy setup with
    # no behavior change from before this issue.
    print_warn "Optional: additional dnsmasq relay/proxy options (router, NTP, domain, PXE/TFTP boot, listen interface, custom options)."
    print_warn "These are delivered only to PXE/network-boot-aware clients via the supplemental ProxyDHCP exchange, never to ordinary DHCP clients -- see docs/dhcp-modes.md."
    if confirm "Configure additional dnsmasq relay/proxy options now? [y/N]" "N"; then
        ask "Listen interface (blank = listen on all interfaces)" "$DHCP_PROXY_INTERFACE"
        while true; do
            DHCP_PROXY_INTERFACE="$REPLY"
            [[ -z "$DHCP_PROXY_INTERFACE" ]] && break
            is_valid_dhcp_proxy_interface "$DHCP_PROXY_INTERFACE" && break
            print_error "Invalid interface name: $DHCP_PROXY_INTERFACE"
            ask "Listen interface (blank = listen on all interfaces)" ""
        done

        ask "Router/gateway option, PXE-scoped (blank = skip)" "$DHCP_PROXY_ROUTER"
        while true; do
            DHCP_PROXY_ROUTER="$REPLY"
            [[ -z "$DHCP_PROXY_ROUTER" ]] && break
            is_valid_ipv4 "$DHCP_PROXY_ROUTER" && break
            print_error "Invalid IPv4 address: $DHCP_PROXY_ROUTER"
            ask "Router/gateway option, PXE-scoped (blank = skip)" ""
        done

        ask "NTP servers, PXE-scoped, comma-separated (blank = skip)" "$DHCP_NTP_SERVERS"
        while true; do
            DHCP_NTP_SERVERS="$REPLY"
            if [[ -z "$DHCP_NTP_SERVERS" ]]; then
                break
            fi
            _dhcp_ntp_ok=1
            IFS=',' read -r -a _dhcp_ntp_check <<< "$DHCP_NTP_SERVERS"
            for _dhcp_ntp_ip in "${_dhcp_ntp_check[@]}"; do
                _dhcp_ntp_ip="${_dhcp_ntp_ip//[[:space:]]/}"
                [[ -z "$_dhcp_ntp_ip" ]] && continue
                is_valid_ipv4 "$_dhcp_ntp_ip" || _dhcp_ntp_ok=0
            done
            [[ "$_dhcp_ntp_ok" = "1" ]] && break
            print_error "Invalid NTP servers list (must be comma-separated IPv4 addresses): $DHCP_NTP_SERVERS"
            ask "NTP servers, PXE-scoped, comma-separated (blank = skip)" ""
        done

        ask "Domain option, PXE-scoped (blank = skip)" "$DHCP_PROXY_DOMAIN"
        while true; do
            DHCP_PROXY_DOMAIN="$REPLY"
            [[ -z "$DHCP_PROXY_DOMAIN" ]] && break
            is_valid_dhcp_proxy_domain "$DHCP_PROXY_DOMAIN" && break
            print_error "Invalid domain name: $DHCP_PROXY_DOMAIN"
            ask "Domain option, PXE-scoped (blank = skip)" ""
        done

        ask "PXE boot filename (blank = skip PXE boot info)" "$DHCP_PROXY_BOOT_FILENAME"
        while true; do
            DHCP_PROXY_BOOT_FILENAME="$REPLY"
            [[ -z "$DHCP_PROXY_BOOT_FILENAME" ]] && break
            is_valid_dhcp_proxy_boot_filename "$DHCP_PROXY_BOOT_FILENAME" && break
            print_error "Invalid boot filename (no whitespace or commas): $DHCP_PROXY_BOOT_FILENAME"
            ask "PXE boot filename (blank = skip PXE boot info)" ""
        done

        if [[ -n "$DHCP_PROXY_BOOT_FILENAME" ]]; then
            ask "PXE boot server address (blank = this host's own address)" "$DHCP_PROXY_BOOT_SERVER"
            while true; do
                DHCP_PROXY_BOOT_SERVER="$REPLY"
                [[ -z "$DHCP_PROXY_BOOT_SERVER" ]] && break
                is_valid_ipv4 "$DHCP_PROXY_BOOT_SERVER" && break
                print_error "Invalid IPv4 address: $DHCP_PROXY_BOOT_SERVER"
                ask "PXE boot server address (blank = this host's own address)" ""
            done
        else
            DHCP_PROXY_BOOT_SERVER=""
        fi

        print_ok "Additional dnsmasq relay/proxy options configured. Custom safe options (DHCP_PROXY_CUSTOM_OPTIONS) can be added later from the Admin UI DHCP page."
    fi

    print_ok "DHCP proxy mode enabled — subnet start: $DHCP_SUBNET_START"
else
    print_ok "DHCP skipped — existing router DHCP remains active"
fi

COMPOSE_PROFILES="$(compose_profiles_for_runtime "$COMPOSE_PROFILES" "$SSL_ENABLED" "$DHCP_MODE")"

# ── 8. Admin-UI access control ────────────────────────────────────────────────
print_step "Admin-UI access control"

printf "  Admin-UI runs on http://%s:8080 — reachable from your LAN by default.\n" "$IP_STANDARD"
printf "  Password protection is optional, but recommended on shared or untrusted networks.\n"
printf "  To restrict the UI to this host later, set UI_BIND_IP=127.0.0.1 in .env.\n\n"

ask "Protect Admin-UI with password? [Y/n]" "Y"
UI_AUTH_USER=""
UI_AUTH_PASSWORD=""
ALLOW_INSECURE_UI=false
if [[ "${REPLY,,}" = "y" ]]; then
    ask "Username" "admin"
    UI_AUTH_USER="$REPLY"

    if [[ -f "$INSTALL_DIR/.env" ]] \
        && [[ "$(get_env_var UI_AUTH_USER "$INSTALL_DIR/.env")" = "$UI_AUTH_USER" ]] \
        && env_key_has_usable_secret UI_AUTH_PASSWORD "$INSTALL_DIR/.env"; then
        UI_AUTH_PASSWORD=$(get_env_var UI_AUTH_PASSWORD "$INSTALL_DIR/.env")
        print_ok "Existing Admin-UI password preserved"
    else
        UI_AUTH_PASSWORD=$(generate_secret_value UI_AUTH_PASSWORD alnum20)
        printf "\n"
        print_ok "Credentials:"
        printf "    User:     ${BOLD}%s${RESET}\n" "$UI_AUTH_USER"
        printf "    Password: ${BOLD}%s${RESET}\n" "$UI_AUTH_PASSWORD"
        print_warn "Note the password now — it will also appear in $INSTALL_DIR/.env"
        printf "\n"
    fi
else
    ask "Allow Admin-UI without authentication? [y/N]" "N"
    if [[ "${REPLY,,}" = "y" ]]; then
        ALLOW_INSECURE_UI=true
        print_warn "No password protection — Admin-UI will be reachable on http://$IP_STANDARD:8080"
        print_warn "This is explicitly allowed by ALLOW_INSECURE_UI=true"
    else
        die "Admin-UI authentication is required. Re-run setup and enable password protection, or explicitly allow insecure access."
    fi
fi

# ── 9. Writing .env ───────────────────────────────────────────────────────────
print_step "Writing .env"

env_file="$INSTALL_DIR/.env"

if [[ -f "$env_file" ]]; then
    ask "Overwrite .env? [y/N]" "N"
    [[ "${REPLY,,}" = "y" ]] || die "Cancelled."
fi

# Generate or preserve secrets. Empty values and known placeholders are regenerated.
LANCACHE_IMAGE_REGISTRY=$(resolve_lancache_image_registry "$env_file")
LANCACHE_IMAGE_PREFIX=$(resolve_lancache_image_prefix "$env_file")
LANCACHE_IMAGE_CHANNEL=$(resolve_lancache_image_channel "$env_file")
LANCACHE_IMAGE_TAG=$(resolve_lancache_image_tag "$env_file")

# Verify the resolved tag actually publishes an image for this host's
# architecture before any state below is written (#665). The earlier
# assert_prebuilt_image_platform_supported call only checked the host
# architecture in general, not this specific tag/channel.
assert_resolved_image_tag_platform_supported "$LANCACHE_IMAGE_REGISTRY" "$LANCACHE_IMAGE_PREFIX" "$LANCACHE_IMAGE_TAG"

KEA_CTRL_TOKEN=$(get_or_generate_secret KEA_CTRL_TOKEN "$env_file" hex32)
DDNS_TSIG_KEY=$(get_or_generate_secret DDNS_TSIG_KEY "$env_file" base64_32)
PDNS_API_KEY=$(get_or_generate_secret PDNS_API_KEY "$env_file" hex32)
NATS_UI_USER=$(get_env_var NATS_UI_USER "$env_file")
NATS_UI_USER="${NATS_UI_USER:-lancache-ui}"
NATS_UI_PASSWORD=$(get_or_generate_secret NATS_UI_PASSWORD "$env_file" hex32)
NATS_DNS_WRITER_USER=$(get_env_var NATS_DNS_WRITER_USER "$env_file")
NATS_DNS_WRITER_USER="${NATS_DNS_WRITER_USER:-lancache-dns-writer}"
NATS_DNS_WRITER_PASSWORD=$(get_or_generate_secret NATS_DNS_WRITER_PASSWORD "$env_file" hex32)
NATS_DNS_REPLICA_USER=$(get_env_var NATS_DNS_REPLICA_USER "$env_file")
NATS_DNS_REPLICA_USER="${NATS_DNS_REPLICA_USER:-lancache-dns-replica}"
NATS_DNS_REPLICA_PASSWORD=$(get_or_generate_secret NATS_DNS_REPLICA_PASSWORD "$env_file" hex32)
NATS_CALLOUT_USER=$(get_env_var NATS_CALLOUT_USER "$env_file")
NATS_CALLOUT_USER="${NATS_CALLOUT_USER:-lancache-nats-callout}"
NATS_CALLOUT_PASSWORD=$(get_or_generate_secret NATS_CALLOUT_PASSWORD "$env_file" hex32)
SECONDARY_REGISTRATION_TOKEN=$(get_or_generate_secret SECONDARY_REGISTRATION_TOKEN "$env_file" hex32)
UI_SESSION_TTL_SECONDS=$(get_env_var UI_SESSION_TTL_SECONDS "$env_file")
UI_SESSION_TTL_SECONDS="${UI_SESSION_TTL_SECONDS:-$DEFAULT_UI_SESSION_TTL_SECONDS}"
validate_ui_session_ttl_seconds "$UI_SESSION_TTL_SECONDS" "$env_file"

validate_env_values_for_initial_write \
    "IP_STANDARD=${IP_STANDARD}" \
    "IP_SSL=${IP_SSL}" \
    "SSL_ENABLED=${SSL_ENABLED}" \
    "CACHE_DIR=${CACHE_DIR}" \
    "CACHE_MAX_SIZE=${cache_gb}g" \
    "CACHE_MEM_MB=${CACHE_MEM_MB}" \
    "CACHE_SLICE_SIZE=8m" \
    "CACHE_VALID_HIT=365d" \
    "CACHE_VALID_ANY=1m" \
    "CACHE_INACTIVE=${cache_inactive}" \
    "NGINX_UPSTREAM_RESOLVER=8.8.8.8 8.8.4.4 [2001:4860:4860::8888] [2001:4860:4860::8844]" \
    "PROXY_SECURITY_MODE=lazy" \
    "PROXY_ALLOWED_CLIENT_CIDRS=" \
    "CACHE_MAX_GB=${cache_gb}" \
    "LANCACHE_IMAGE_REGISTRY=${LANCACHE_IMAGE_REGISTRY}" \
    "LANCACHE_IMAGE_PREFIX=${LANCACHE_IMAGE_PREFIX}" \
    "LANCACHE_IMAGE_CHANNEL=${LANCACHE_IMAGE_CHANNEL}" \
    "LANCACHE_IMAGE_TAG=${LANCACHE_IMAGE_TAG}" \
    "DHCP_ENABLED=${DHCP_ENABLED}" \
    "KEA_DATA_DIR=${KEA_DATA_DIR}" \
    "DHCP_MODE=${DHCP_MODE}" \
    "DHCP_SUBNET=${DHCP_SUBNET}" \
    "DHCP_GATEWAY=${DHCP_GATEWAY}" \
    "DHCP_RANGE_START=${DHCP_RANGE_START}" \
    "DHCP_RANGE_END=${DHCP_RANGE_END}" \
    "DHCP_SUBNET_START=${DHCP_SUBNET_START}" \
    "DHCP_DNS_PRIMARY=${DHCP_DNS_PRIMARY}" \
    "DHCP_DNS_SECONDARY=${DHCP_DNS_SECONDARY}" \
    "UPSTREAM_DHCP_IP=${UPSTREAM_DHCP_IP}" \
    "DHCP_PROXY_INTERFACE=${DHCP_PROXY_INTERFACE}" \
    "DHCP_PROXY_ROUTER=${DHCP_PROXY_ROUTER}" \
    "DHCP_NTP_SERVERS=${DHCP_NTP_SERVERS}" \
    "DHCP_PROXY_DOMAIN=${DHCP_PROXY_DOMAIN}" \
    "DHCP_PROXY_BOOT_FILENAME=${DHCP_PROXY_BOOT_FILENAME}" \
    "DHCP_PROXY_BOOT_SERVER=${DHCP_PROXY_BOOT_SERVER}" \
    "DHCP_PROXY_CUSTOM_OPTIONS=${DHCP_PROXY_CUSTOM_OPTIONS}" \
    "KEA_CTRL_TOKEN=${KEA_CTRL_TOKEN}" \
    "DDNS_TSIG_KEY=${DDNS_TSIG_KEY}" \
    "PDNS_API_KEY=${PDNS_API_KEY}" \
    "NATS_UI_USER=${NATS_UI_USER}" \
    "NATS_UI_PASSWORD=${NATS_UI_PASSWORD}" \
    "NATS_DNS_WRITER_USER=${NATS_DNS_WRITER_USER}" \
    "NATS_DNS_WRITER_PASSWORD=${NATS_DNS_WRITER_PASSWORD}" \
    "NATS_DNS_REPLICA_USER=${NATS_DNS_REPLICA_USER}" \
    "NATS_DNS_REPLICA_PASSWORD=${NATS_DNS_REPLICA_PASSWORD}" \
    "NATS_CALLOUT_USER=${NATS_CALLOUT_USER}" \
    "NATS_CALLOUT_PASSWORD=${NATS_CALLOUT_PASSWORD}" \
    "SECONDARY_REGISTRATION_TOKEN=${SECONDARY_REGISTRATION_TOKEN}" \
    "UI_SESSION_TTL_SECONDS=${UI_SESSION_TTL_SECONDS}" \
    "COMPOSE_PROFILES=${COMPOSE_PROFILES}" \
    "UI_AUTH_USER=${UI_AUTH_USER}" \
    "UI_AUTH_PASSWORD=${UI_AUTH_PASSWORD}" \
    "ALLOW_INSECURE_UI=${ALLOW_INSECURE_UI}" \
    "UI_BIND_IP=${IP_STANDARD}"

write_env_file "$INSTALL_DIR/.env" <<EOF
# ── LAN IPs ────────────────────────────────────────────────────────────────────
# Standard mode (no CA certificate needed): HTTP cached, HTTPS passthrough
IP_STANDARD=${IP_STANDARD}

# SSL mode (install CA certificate on clients): HTTP + HTTPS cached
# Empty = SSL mode disabled
IP_SSL=${IP_SSL}

# ── SSL ────────────────────────────────────────────────────────────────────────
SSL_ENABLED=${SSL_ENABLED}

# ── Cache ──────────────────────────────────────────────────────────────────────
CACHE_DIR=${CACHE_DIR}

CACHE_MAX_SIZE=${cache_gb}g
CACHE_MEM_MB=${CACHE_MEM_MB}
CACHE_SLICE_SIZE=8m
CACHE_VALID_HIT=365d
CACHE_VALID_ANY=1m
CACHE_INACTIVE=${cache_inactive}

# Real upstream DNS for nginx origin lookups. Do not set this to a LanCache DNS/proxy IP.
# Includes both IPv4 and IPv6 Google Public DNS (see CLAUDE.md for the
# dual-stack rationale); IPv6 literals are bracketed because nginx's
# \`resolver\` directive requires brackets around IPv6 nameservers. (Backticks
# escaped: this whole heredoc is deliberately unquoted so ${IP_STANDARD} etc.
# below interpolate -- an unescaped backtick here is real command
# substitution, not an inert comment. Confirmed live, 2026-07-14: this exact
# line ran resolver as a command on every install, printing "resolver:
# command not found" to stderr and silently deleting the word from the
# written .env comment.)
NGINX_UPSTREAM_RESOLVER=8.8.8.8 8.8.4.4 [2001:4860:4860::8888] [2001:4860:4860::8844]
# Keep lazy as the default: it preserves the historical cache-first behavior
# and avoids breaking downloads when a launcher introduces a new CDN hostname.
PROXY_SECURITY_MODE=lazy
PROXY_ALLOWED_CLIENT_CIDRS=

# For Admin UI (GB as number for progress bar)
CACHE_MAX_GB=${cache_gb}

# First-party service image selector. "latest" is the stable default.
# Use "nightly" only when you explicitly want the tested pre-stable channel,
# built continuously from master (this was formerly called "edge").
# setup.sh resolves mutable channels to an immutable sha-* service tag before
# pulling images so one install cannot consume a mixed stack during promotion.
# Release archives should use their matching vX.Y.Z or vX.Y.Z-rc.N tag.
LANCACHE_IMAGE_REGISTRY=${LANCACHE_IMAGE_REGISTRY}
LANCACHE_IMAGE_PREFIX=${LANCACHE_IMAGE_PREFIX}
LANCACHE_IMAGE_CHANNEL=${LANCACHE_IMAGE_CHANNEL}
LANCACHE_IMAGE_TAG=${LANCACHE_IMAGE_TAG}

# ── DHCP ───────────────────────────────────────────────────────────────────────
DHCP_ENABLED=${DHCP_ENABLED}
KEA_DATA_DIR=${KEA_DATA_DIR}
DHCP_MODE=${DHCP_MODE}
DHCP_SUBNET=${DHCP_SUBNET}
DHCP_GATEWAY=${DHCP_GATEWAY}
DHCP_RANGE_START=${DHCP_RANGE_START}
DHCP_RANGE_END=${DHCP_RANGE_END}
DHCP_SUBNET_START=${DHCP_SUBNET_START}
DHCP_DNS_PRIMARY=${DHCP_DNS_PRIMARY}
DHCP_DNS_SECONDARY=${DHCP_DNS_SECONDARY}
UPSTREAM_DHCP_IP=${UPSTREAM_DHCP_IP}

# Issue #450: additional optional dnsmasq relay/proxy options, all empty by
# default. Delivered only via the supplemental ProxyDHCP/PXE exchange to
# PXE/network-boot-aware clients -- see docs/dhcp-modes.md.
DHCP_PROXY_INTERFACE=${DHCP_PROXY_INTERFACE}
DHCP_PROXY_ROUTER=${DHCP_PROXY_ROUTER}
DHCP_NTP_SERVERS=${DHCP_NTP_SERVERS}
DHCP_PROXY_DOMAIN=${DHCP_PROXY_DOMAIN}
DHCP_PROXY_BOOT_FILENAME=${DHCP_PROXY_BOOT_FILENAME}
DHCP_PROXY_BOOT_SERVER=${DHCP_PROXY_BOOT_SERVER}
DHCP_PROXY_CUSTOM_OPTIONS=${DHCP_PROXY_CUSTOM_OPTIONS}

# Kea Control Agent/API token shared by DHCP and Admin UI. Keep secret.
KEA_CTRL_TOKEN=${KEA_CTRL_TOKEN}

# Shared TSIG key for Kea DDNS → PowerDNS updates. Keep secret.
DDNS_TSIG_KEY=${DDNS_TSIG_KEY}

# ── PowerDNS API ───────────────────────────────────────────────────────────────
# API key for PowerDNS Authoritative + Recursor (generated, do not change)
PDNS_API_KEY=${PDNS_API_KEY}

# ── NATS (DNS-record sync bus) ─────────────────────────────────────────────────
# UI NATS role (generated, do not change)
NATS_UI_USER=${NATS_UI_USER}
NATS_UI_PASSWORD=${NATS_UI_PASSWORD}
# DNS writer role for primary DNS containers (generated, do not change)
NATS_DNS_WRITER_USER=${NATS_DNS_WRITER_USER}
NATS_DNS_WRITER_PASSWORD=${NATS_DNS_WRITER_PASSWORD}
# DNS replica role for the primary's own co-located dns-ssl container only
# (generated, do not change). NOT used by registered secondaries -- each of
# those gets its own per-instance NATS credential via auth callout at
# registration time instead (issue #583).
NATS_DNS_REPLICA_USER=${NATS_DNS_REPLICA_USER}
NATS_DNS_REPLICA_PASSWORD=${NATS_DNS_REPLICA_PASSWORD}
# Admin UI's own NATS identity for answering auth-callout requests for
# registered secondaries (generated, do not change)
NATS_CALLOUT_USER=${NATS_CALLOUT_USER}
NATS_CALLOUT_PASSWORD=${NATS_CALLOUT_PASSWORD}
# Token for setup.sh secondary — anyone who knows this can register a secondary
SECONDARY_REGISTRATION_TOKEN=${SECONDARY_REGISTRATION_TOKEN}

# ── Profiles ───────────────────────────────────────────────────────────────────
# ssl = SSL mode active; empty = disabled
COMPOSE_PROFILES=${COMPOSE_PROFILES}

# ── Scheduled automatic updates ─────────────────────────────────────────────────
# 1 = the host systemd timer (lancache-auto-update.timer) is enabled and will
# periodically run ./setup.sh auto-update; 0 = manual updates only
# (./setup.sh update). See "Scheduled automatic updates" in setup.sh's
# interactive install flow.
AUTO_UPDATE_ENABLED=${AUTO_UPDATE_ENABLED}

# ── Admin-UI ───────────────────────────────────────────────────────────────────
# Empty auth values are only allowed when ALLOW_INSECURE_UI=true is set explicitly.
UI_AUTH_USER=${UI_AUTH_USER}
UI_AUTH_PASSWORD=${UI_AUTH_PASSWORD}
UI_SESSION_TTL_SECONDS=${UI_SESSION_TTL_SECONDS}
ALLOW_INSECURE_UI=${ALLOW_INSECURE_UI}

# Bind address for Admin-UI. Default keeps quickstart reachable on the LAN.
# Set to 127.0.0.1 to restrict access to this host.
UI_BIND_IP=${IP_STANDARD}
EOF
print_ok ".env written: $INSTALL_DIR/.env"

# ── 10. Creating directories ───────────────────────────────────────────────────
print_step "Creating directories"
mkdir -p "$CACHE_DIR"
print_ok "Cache:          $CACHE_DIR"
if [[ "$DHCP_ENABLED" = "1" && -n "$KEA_DATA_DIR" ]]; then
    mkdir -p "$KEA_DATA_DIR"
    print_ok "Kea data:       $KEA_DATA_DIR"
fi

# ── 11. Installing systemd watchdog ───────────────────────────────────────────
# The systemd service owns boot startup; the timer is a convergence guard that
# re-applies compose state if containers drift. It is not an update mechanism.
print_step "Installing systemd watchdog"

SYSTEMD_AVAILABLE=0
if ! command -v systemctl >/dev/null 2>&1; then
    print_warn "systemd not found — watchdog will not be installed"
    print_warn "Start stack manually after reboot: cd $INSTALL_DIR && docker compose up -d"
else
    cat > /etc/systemd/system/lancache.service <<EOF
[Unit]
Description=LanCache-NG
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=docker compose up -d
ExecStop=docker compose down
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/lancache-converge.service <<EOF
[Unit]
Description=LanCache-NG Convergence Check
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
# Ordered ExecStart lines run in sequence (#819): the reconcile step folds
# any Admin UI release-channel/scheduled-update override into .env and syncs
# lancache-auto-update.timer's state to match, BEFORE the pre-existing
# container-drift convergence below runs. systemd does not invoke ExecStart
# through a shell, so a leading "-" (not shell "||") is systemd's own syntax
# for "run this, but never let its exit code fail the unit" -- a non-zero
# exit from the reconcile step must never take down the convergence tick it
# normally still needs to run, even though cmd_converge_reconcile is already
# internally defensive and should not normally fail at all.
ExecStart=-${INSTALL_DIR}/setup.sh converge-reconcile ${INSTALL_DIR}
ExecStart=docker compose up -d --remove-orphans
EOF

    cat > /etc/systemd/system/lancache-converge.timer <<EOF
[Unit]
Description=LanCache-NG Convergence Timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=lancache-converge.service

[Install]
WantedBy=timers.target
EOF

    # Scheduled automatic updates (#819), replacing the removed Watchtower
    # opt-in. Always written (harmless while disabled), only enabled/started
    # later if AUTO_UPDATE_ENABLED=1 -- same "install now, activate after a
    # successful first pull" pattern as lancache.service/lancache-converge.*
    # above. Runs on the HOST via systemd, not as a container: no container
    # gains expanded Docker-socket or filesystem access to perform an update,
    # unlike the removed Watchtower helper (which needed read-write socket
    # access in its own container -- see docs/threat-model.md).
    #
    # ExecStart runs whatever setup.sh is already on this install's disk at
    # tick time -- it does NOT `git pull`/re-fetch itself first. Deliberate
    # choice (#819, mirroring mailcow-dockerized's own update.sh, which
    # self-updates but refuses to re-exec in the same process): rewriting a
    # script file out from under the interpreter currently executing it risks
    # corrupted/partial execution of the remaining lines. The accepted cost is
    # that a bugfix to setup.sh's own update logic only takes effect on the
    # NEXT scheduled tick, not immediately -- far safer than the alternative.
    cat > /etc/systemd/system/lancache-auto-update.service <<EOF
[Unit]
Description=LanCache-NG Scheduled Automatic Update
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/setup.sh auto-update ${INSTALL_DIR}
EOF

    # RandomizedDelaySec spreads many installs' ticks across an hour instead
    # of every one of them hitting GHCR at exactly 04:00; Persistent=true
    # catches up a missed run (e.g. host was off) on next boot instead of
    # silently skipping to the next scheduled day.
    cat > /etc/systemd/system/lancache-auto-update.timer <<EOF
[Unit]
Description=LanCache-NG Scheduled Automatic Update Timer

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
Unit=lancache-auto-update.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    SYSTEMD_AVAILABLE=1
    print_ok "systemd units installed; they will be enabled after image pull succeeds"
fi

# ── 12. Summary and confirmation ──────────────────────────────────────────────
printf "\n"
printf "${BOLD}┌──────────────────────────────────────────────┐${RESET}\n"
printf "${BOLD}│              Configuration                   │${RESET}\n"
printf "${BOLD}├──────────────────────────────────────────────┤${RESET}\n"
printf "  %-26s %s\n"    "Standard IP:"              "$IP_STANDARD"
if [[ "$SSL_ENABLED" = "1" ]]; then
    printf "  %-26s %s\n" "SSL IP:"                  "$IP_SSL"
else
    printf "  %-26s %s\n" "SSL mode:"                "disabled"
fi
printf "  %-26s %s\n"    "Install directory:"       "$INSTALL_DIR"
printf "  %-26s %s\n"    "Cache:"                   "$CACHE_DIR"
printf "  %-26s %s GiB\n" "Cache size:"              "$cache_gb"
printf "  %-26s %s MB\n"  "Cache RAM:"               "$CACHE_MEM_MB"
printf "  %-26s %s\n"    "Cache entry max age:"     "$cache_inactive"
printf "  %-26s %s\n"    "DHCP mode:"               "$DHCP_MODE"
if [[ "$DHCP_ENABLED" = "1" ]]; then
    printf "  %-26s %s\n" "DHCP server:"             "$DHCP_SUBNET (Pool: $DHCP_RANGE_START–$DHCP_RANGE_END)"
else
    printf "  %-26s %s\n" "DHCP server:"             "disabled"
fi
if [[ "$DHCP_MODE" = "dnsmasq-proxy" ]]; then
    printf "  %-26s %s\n" "DHCP proxy subnet start:" "$DHCP_SUBNET_START"
    [[ -n "$DHCP_PROXY_INTERFACE" ]] && printf "  %-26s %s\n" "  Listen interface:" "$DHCP_PROXY_INTERFACE"
    [[ -n "$DHCP_PROXY_ROUTER" ]] && printf "  %-26s %s\n" "  Router option (PXE-scoped):" "$DHCP_PROXY_ROUTER"
    [[ -n "$DHCP_NTP_SERVERS" ]] && printf "  %-26s %s\n" "  NTP option (PXE-scoped):" "$DHCP_NTP_SERVERS"
    [[ -n "$DHCP_PROXY_DOMAIN" ]] && printf "  %-26s %s\n" "  Domain option (PXE-scoped):" "$DHCP_PROXY_DOMAIN"
    [[ -n "$DHCP_PROXY_BOOT_FILENAME" ]] && printf "  %-26s %s\n" "  PXE boot filename:" "$DHCP_PROXY_BOOT_FILENAME"
fi
if [[ "$AUTO_UPDATE_ENABLED" = "1" ]]; then
    printf "  %-26s %s\n" "Scheduled updates:"        "enabled (ordered, health-gated, daily)"
else
    printf "  %-26s %s\n" "Scheduled updates:"        "disabled — manual: ./setup.sh update"
fi
if [[ -n "$UI_AUTH_USER" ]]; then
    printf "  %-26s %s\n" "Admin-UI auth:"           "enabled (user: $UI_AUTH_USER)"
else
    if [[ "$ALLOW_INSECURE_UI" = "true" ]]; then
        printf "  %-26s %s\n" "Admin-UI auth:"           "disabled (explicitly allowed)"
    else
        printf "  %-26s %s\n" "Admin-UI auth:"           "disabled"
    fi
fi
printf "${BOLD}└──────────────────────────────────────────────┘${RESET}\n\n"

ask "Start now? [Y/n]" "Y"
[[ "${REPLY,,}" != "n" ]] \
    || { printf "\n  Start later with: cd %s && docker compose up -d\n\n" "$INSTALL_DIR"; exit 0; }

# ── 13. Starting stack ───────────────────────────────────────────────────────
# Pull before starting so GHCR/auth/platform failures happen while systemd units
# are installed but not yet enabled, keeping failed first installs reversible.
print_step "Pulling images"
cd "$INSTALL_DIR"
assert_prebuilt_image_platform_supported
docker compose --env-file "$INSTALL_DIR/.env" pull \
    || die "Failed to pull required container images. Check network access and GHCR authentication, then rerun setup.sh."

run_kea_dhcp_activation_preflight "$INSTALL_DIR/.env"

print_step "Starting stack"
if [[ "$SYSTEMD_AVAILABLE" = "1" ]]; then
    systemctl enable lancache.service
    systemctl enable lancache-converge.timer
    print_ok "lancache.service enabled for boot"
    print_ok "lancache-converge.timer enabled for boot"
    systemctl start lancache.service
    systemctl start lancache-converge.timer
    if [[ "$AUTO_UPDATE_ENABLED" = "1" ]]; then
        systemctl enable lancache-auto-update.timer
        systemctl start lancache-auto-update.timer
        print_ok "lancache-auto-update.timer enabled (scheduled automatic updates)"
    fi
else
    docker compose --env-file "$INSTALL_DIR/.env" up -d
fi
print_ok "Stack started"

# ── 14. Post-start info ──────────────────────────────────────────────────────
printf "\n"
printf "${BOLD}${GREEN}══════════════════════════════════════════════════${RESET}\n"
printf "${BOLD}${GREEN}  LanCache-NG is running!${RESET}\n"
printf "${BOLD}${GREEN}══════════════════════════════════════════════════${RESET}\n"
printf "\n"
if [[ -n "$UI_AUTH_USER" ]]; then
    printf "  ${BOLD}Admin-UI:${RESET}    http://%s:8080  (User: %s)\n" "$IP_STANDARD" "$UI_AUTH_USER"
else
    printf "  ${BOLD}Admin-UI:${RESET}    http://%s:8080\n" "$IP_STANDARD"
fi
printf "\n"
if [[ "$SSL_ENABLED" = "1" ]]; then
    printf "  ${BOLD}CA certificate${RESET} (available after first start):\n"
    printf "    %s/certs/ca.crt\n" "$INSTALL_DIR"
    printf "    → install on clients for SSL mode\n"
    printf "    → guide: https://github.com/wiki-mod/lancache-ng/wiki\n"
    printf "\n"
fi
printf "  ${BOLD}Configure DNS on clients:${RESET}\n"
printf "    Standard mode (no certificate): %s\n" "$IP_STANDARD"
if [[ "$SSL_ENABLED" = "1" ]]; then
    printf "    SSL mode (with certificate):    %s\n" "$IP_SSL"
fi
printf "\n"
printf "  ${BOLD}Commands:${RESET}\n"
printf "    Status:  %s/setup.sh debug\n"  "$SCRIPT_DIR"
printf "    Update:  %s/setup.sh update\n" "$SCRIPT_DIR"
printf "\n"
