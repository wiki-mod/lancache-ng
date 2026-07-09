#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Guided lifecycle CLI for a lancache-ng installation. Subcommands: install
# (interactive first-time setup — installs Docker/Compose if missing on
# Debian/Ubuntu/RHEL-family hosts, writes .env with generated secrets,
# configures DHCP mode/cache sizing/DNS IPs, enables the systemd
# service+converge timer, and starts the stack), update, update-ip, debug,
# secondary (register/rotate a secondary DNS node against a primary),
# backup, and restore. Also hosts the shared .env helpers (read/write/
# generate secret values, validate CIDR/DHCP-mode input) reused by the
# secondary registration flow.
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
ask() {
    local prompt="$1" default="${2:-}"
    printf "  ${BOLD}%s${RESET} [%s]: " "$prompt" "$default"
    read -r REPLY < /dev/tty
    REPLY="${REPLY:-$default}"
}

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

is_positive_integer() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

is_absolute_path() {
    [[ -n "${1:-}" && "$1" == /* ]]
}

is_dnsmasq_subnet_start() {
    local ip="$1"

    is_valid_ipv4 "$ip" && [[ "$ip" == *".0" ]]
}

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

is_valid_dhcp_mode() {
    case "$1" in
        disabled|kea|dnsmasq-proxy) return 0 ;;
        *) return 1 ;;
    esac
}

validate_ui_session_ttl_seconds() {
    local value="$1" source="${2:-UI_SESSION_TTL_SECONDS}" numeric max

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        die "UI_SESSION_TTL_SECONDS in ${source} must be an unsigned integer number of seconds."
    fi
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

confirm() {
    local prompt="$1" default="${2:-N}"
    ask "$prompt" "$default"
    [[ "${REPLY,,}" = "y" || "${REPLY,,}" = "yes" ]]
}

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

install_curl() {
    install_required_command curl "curl is missing." curl
}

install_git() {
    install_required_command git "git is missing." git
}

apt_package_available() {
    apt-cache show "$1" >/dev/null 2>&1
}

apt_package_candidate_version() {
    apt-cache policy "$1" 2>/dev/null \
        | awk '/^[[:space:]]*Candidate:/ {print $2; exit}'
}

apt_docker_compose_is_v2() {
    local version=""

    version=$(apt_package_candidate_version docker-compose)
    [[ "$version" =~ ^2[.:-] ]]
}

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

# Docker bootstrap is a first-install convenience, not a build environment
# contract. Changes here affect production setup directly and must stay separate
# from future dev-mode/compiler-farm decisions.
verify_docker_installation() {
    command -v docker >/dev/null 2>&1 \
        || die "Docker client binary is missing after installation."

    docker compose version >/dev/null 2>&1 \
        || die "Docker Compose v2 is missing after installation."
}

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

install_docker_apt() {
    local compose_package=""

    apt-get update -y
    if ! compose_package=$(apt_compose_package); then
        print_warn "No Compose v2 package was found in the configured apt repositories. Adding Docker's official apt repository."
        install_docker_apt_repo
        compose_package=$(apt_compose_package) \
            || die "No Docker Compose v2 package found. Please install Docker and the Docker Compose plugin manually, then rerun setup.sh."
    fi

    if [[ "$compose_package" = docker-compose-plugin ]]; then
        apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io "$compose_package"
    else
        apt-get install -y --no-install-recommends docker.io "$compose_package"
        # Debian Trixie splits the Docker client into docker-cli, so install it
        # only when docker.io did not already provide /usr/bin/docker.
        ensure_apt_docker_client
    fi

    verify_docker_installation
}

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

rpm_installed_package_list() {
    local package

    for package in "$@"; do
        rpm -q "$package" >/dev/null 2>&1 && printf '%s\n' "$package"
    done
}

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

guard_rpm_docker_conflicts() {
    local package
    local -a conflicts=()

    while IFS= read -r package; do
        [[ -n "$package" ]] && conflicts+=("$package")
    done < <(rpm_conflicting_docker_packages)

    (( ${#conflicts[@]} == 0 )) && return 0

    die "Docker's RPM packages conflict with these installed packages: ${conflicts[*]}. Remove them first (for example: dnf remove ${conflicts[*]}), then rerun setup.sh."
}

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

install_docker_rpm() {
    local manager="$1"
    shift
    local repo_url needs_engine=0 package
    local packages=("$@")

    if (( ${#packages[@]} == 0 )); then
        packages=(docker-ce docker-ce-cli containerd.io docker-compose-plugin)
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

install_docker() {
    local packages=()

    if command -v apt-get >/dev/null 2>&1; then
        print_warn "Docker is missing."
        printf "  Required packages: docker.io and an available Compose v2 package (docker-compose-plugin, docker-compose-v2, or docker-compose)\n"
        if ! confirm "Install these packages now? [y/N]" "N"; then
            die "Aborted. Please install Docker and a Docker Compose v2 package manually, then rerun setup.sh."
        fi
        install_docker_apt || die "Failed to install Docker."
    elif command -v dnf >/dev/null 2>&1; then
        packages=(docker-ce docker-ce-cli containerd.io docker-compose-plugin)
        print_warn "Docker is missing."
        printf "  Required packages: %s\n" "${packages[*]}"
        printf "  Docker's RPM repository will be configured before installation.\n"
        if ! confirm "Install these packages now? [y/N]" "N"; then
            die "Aborted. Please install Docker from Docker's RPM repository manually, then rerun setup.sh: ${packages[*]}"
        fi
        install_docker_rpm dnf || die "Failed to install Docker."
    elif command -v yum >/dev/null 2>&1; then
        packages=(docker-ce docker-ce-cli containerd.io docker-compose-plugin)
        print_warn "Docker is missing."
        printf "  Required packages: %s\n" "${packages[*]}"
        printf "  Docker's RPM repository will be configured before installation.\n"
        if ! confirm "Install these packages now? [y/N]" "N"; then
            die "Aborted. Please install Docker from Docker's RPM repository manually, then rerun setup.sh: ${packages[*]}"
        fi
        install_docker_rpm yum || die "Failed to install Docker."
    elif command -v pacman >/dev/null 2>&1; then
        packages=(docker docker-compose)
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

get_env_var() {
    local raw
    raw=$(awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$2" 2>/dev/null) || true
    _compose_parse_env_value "$raw"
}

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

get_env_assignment_value_raw() {
    awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$2" 2>/dev/null || true
}

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

env_key_has_value() {
    local key="$1" env_file="$2" value
    value=$(get_env_var "$key" "$env_file")
    [[ -n "$value" ]]
}

secret_value_is_placeholder() {
    local value="$1"
    case "$value" in
        ""|CHANGE_ME_*|YOUR_*_HERE|changeme*|*change-me*|lancache-*-secret)
            return 0
            ;;
    esac
    return 1
}

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
        printf '%s=%s\n' "$key" "$value" >> "$env_file"
    fi
}

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
        printf '%s=%s\n' "$key" "$assignment_value" >> "$env_file"
    fi
}

append_env_key_if_missing() {
    local key="$1" value="$2" env_file="$3"
    validate_env_value "$key" "$value"
    # Preserve intentional empty placeholders; only add the key when it is absent.
    env_key_exists "$key" "$env_file" || printf '%s=%s\n' "$key" "$value" >> "$env_file"
}

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
        printf '%s=%s\n' "$key" "$value" >> "$env_file"
    fi
}

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
    env_key_exists "$key" "$env_file" || printf '%s=%s\n' "$key" "$assignment_value" >> "$env_file"
}

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

legacy_state_root_has_known_children() {
    local child

    for child in "${LEGACY_STATE_CHILDREN[@]}"; do
        [[ -d "$(legacy_state_path "$child")" ]] && return 0
    done
    return 1
}

legacy_state_root_or_default() {
    local default_dir="$1"

    if legacy_state_root_has_known_children; then
        legacy_state_path
    else
        printf '%s\n' "$default_dir"
    fi
}

legacy_dir_or_default() {
    local legacy_dir="$1" default_dir="$2"

    if [[ -d "$legacy_dir" ]]; then
        printf '%s\n' "$legacy_dir"
    else
        printf '%s\n' "$default_dir"
    fi
}

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

remove_env_key() {
    local key="$1" env_file="$2"

    env_key_exists "$key" "$env_file" || return 0
    awk -F= -v key="$key" '$1 != key' "$env_file" | write_env_file "$env_file"
}

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

is_deploy_prod_install_dir() {
    local install_dir="$1"
    [[ "$(basename "$install_dir")" = "prod" && "$(basename "$(dirname "$install_dir")")" = "deploy" ]]
}

runtime_env_file_for_install_dir() {
    local install_dir="$1"

    if is_deploy_prod_install_dir "$install_dir" && [[ -f "$install_dir/.env.local" ]]; then
        printf '%s\n' "$install_dir/.env.local"
    else
        printf '%s\n' "$install_dir/.env"
    fi
}

install_quickstart_compose_assets() {
    local install_dir="$1" socket_proxy_target dhcp_probe_target

    socket_proxy_target="$install_dir/scripts/docker-socket-proxy.sh"
    dhcp_probe_target="$install_dir/scripts/dhcp-probe.sh"
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
}

git_default_branch_name() {
    local repo_dir="$1" default_branch=""

    default_branch=$(git -C "$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    default_branch="${default_branch#origin/}"
    if [[ -z "$default_branch" ]]; then
        default_branch=$(git -C "$repo_dir" remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF; exit}' || true)
    fi

    printf '%s\n' "${default_branch:-master}"
}

git_repo_is_clean() {
    local repo_dir="$1"

    [[ -z "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]]
}

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

deploy_prod_repo_root() {
    local install_dir="$1"
    realpath -m "$install_dir/../.."
}

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

require_env_value_for_update() {
    local key="$1" env_file="$2"
    env_key_has_value "$key" "$env_file" \
        || die "$key is missing or empty in $env_file. Set it before running setup.sh update."
}

ensure_secret_env_key() {
    local key="$1" env_file="$2" kind="$3" value
    if env_key_has_usable_secret "$key" "$env_file"; then
        return 0
    fi

    value=$(generate_secret_value "$key" "$kind")
    set_env_key "$key" "$value" "$env_file"
    print_ok "Generated missing or placeholder secret: $key"
}

cache_size_gb_from_env() {
    local cache_max_size="$1"
    cache_max_size="${cache_max_size,,}"
    cache_max_size="${cache_max_size%g}"
    [[ "$cache_max_size" =~ ^[0-9]+$ ]] || cache_max_size="50"
    printf '%s\n' "$cache_max_size"
}

# Production installs consume prebuilt service images. Until multi-arch images
# are explicitly published and tested, reject unsupported host architectures
# before writing or mutating runtime state.
assert_prebuilt_image_platform_supported() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            ;;
        *)
            die "Prebuilt production images are currently published for linux/amd64 only. This host reports '${arch}'. Multi-architecture images are tracked separately."
            ;;
    esac
}

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
# as latest/edge/dev must resolve to one immutable stack tag before the compose
# pull, so one installation cannot accidentally mix image versions.
validate_lancache_image_tag() {
    local tag="$1"

    case "$tag" in
        sha-*)
            [[ "$tag" =~ ^sha-[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] \
                || die "LANCACHE_IMAGE_TAG must be a valid sha-* image tag."
            return 0
            ;;
    esac

    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] \
        || die "LANCACHE_IMAGE_TAG must be an immutable sha-* tag or a vX.Y.Z / vX.Y.Z-rc.N release tag."
}

validate_lancache_image_channel() {
    local channel="$1"
    case "$channel" in
        latest|dev|edge|pinned)
            return 0
            ;;
    esac
    die "LANCACHE_IMAGE_CHANNEL must be latest, dev, edge, or pinned."
}

derive_release_archive_image_tag() {
    local version tag

    if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        tag=$(git -C "$SCRIPT_DIR" describe --tags --exact-match 2>/dev/null || true)
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

validate_lancache_image_registry() {
    local registry="$1"
    [[ "$registry" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?$ ]] \
        || die "LANCACHE_IMAGE_REGISTRY must be a registry hostname with an optional port."
}

validate_lancache_image_prefix() {
    local prefix="$1"
    [[ "$prefix" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
        || die "LANCACHE_IMAGE_PREFIX must be a slash-separated image namespace."
}

resolve_lancache_image_registry() {
    local env_file="${1:-}" registry="${LANCACHE_IMAGE_REGISTRY:-}"

    if [[ -z "$registry" && -n "$env_file" && -f "$env_file" ]]; then
        registry=$(get_env_var LANCACHE_IMAGE_REGISTRY "$env_file")
    fi

    registry="${registry:-ghcr.io}"
    validate_lancache_image_registry "$registry"
    printf '%s\n' "$registry"
}

resolve_lancache_image_prefix() {
    local env_file="${1:-}" prefix="${LANCACHE_IMAGE_PREFIX:-}"

    if [[ -z "$prefix" && -n "$env_file" && -f "$env_file" ]]; then
        prefix=$(get_env_var LANCACHE_IMAGE_PREFIX "$env_file")
    fi

    prefix="${prefix:-wiki-mod/lancache-ng}"
    validate_lancache_image_prefix "$prefix"
    printf '%s\n' "$prefix"
}

resolve_lancache_image_channel() {
    local env_file="${1:-}" channel="${LANCACHE_IMAGE_CHANNEL:-}" tag="${LANCACHE_IMAGE_TAG:-}" release_tag=""

    if [[ -z "$channel" && -n "$env_file" && -f "$env_file" ]]; then
        channel=$(get_env_var LANCACHE_IMAGE_CHANNEL "$env_file")
    fi

    if [[ -z "$tag" && -n "$env_file" && -f "$env_file" ]]; then
        tag=$(get_env_var LANCACHE_IMAGE_TAG "$env_file")
    fi

    case "$tag" in
        latest|dev|edge)
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
    # pre-stable testing must opt into edge explicitly so production users do
    # not drift onto a moving integration channel by accident.
    channel="${channel:-latest}"
    validate_lancache_image_channel "$channel"
    printf '%s\n' "$channel"
}

resolve_lancache_stack_channel_tag() {
    local env_file="$1" channel="$2"
    local registry prefix stack_image container_id="" resolved_tag=""

    registry=$(resolve_lancache_image_registry "$env_file")
    prefix=$(resolve_lancache_image_prefix "$env_file")
    stack_image="${registry}/${prefix}/stack:${channel}"

    command -v docker >/dev/null 2>&1 \
        || die "Docker is required to resolve LANCACHE_IMAGE_CHANNEL=${channel} through ${stack_image}."
    command -v tar >/dev/null 2>&1 \
        || die "tar is required to read the stack channel pointer image ${stack_image}."

    printf "\n${BOLD}${CYAN}▶ Resolving image channel %s${RESET}\n" "$channel" >&2
    docker pull "$stack_image" >/dev/null \
        || {
            if [[ "$channel" = "latest" ]]; then
                cat >&2 <<EOF

${RED}✗${RESET} Cannot resolve the 'latest' stable release channel.

This project is currently in active development (pre-1.0). While images are published
to the 'edge' testing channel daily from master, a formal stable release with a
published 'latest' channel tag has not yet been created.

To proceed, choose one of these options:

  1. Use the 'edge' testing channel (pre-release, may change frequently):
     LANCACHE_IMAGE_CHANNEL=edge ./setup.sh install

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

resolve_lancache_image_tag() {
    local env_file="${1:-}" tag="${LANCACHE_IMAGE_TAG:-}" release_tag="" channel=""

    if [[ -n "$tag" ]]; then
        case "$tag" in
            latest|dev|edge)
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
        latest|dev|edge)
            resolve_lancache_stack_channel_tag "$env_file" "$channel"
            return 0
            ;;
        pinned)
            if [[ -z "$tag" && -n "$env_file" && -f "$env_file" ]]; then
                tag=$(get_env_var LANCACHE_IMAGE_TAG "$env_file")
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
        latest|dev|edge)
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
    local install_dir="$1" env_file dhcp_enabled dhcp_mode
    local allow_insecure_ui cache_dir cache_max_gb cache_max_size cache_gb cache_mem_mb ip_ssl ssl_enabled ui_password ui_user
    local compose_profiles dhcp_dns_primary dhcp_dns_secondary dhcp_subnet_start ip_standard upstream_dhcp_ip
    local kea_data_default kea_data_dir nats_conf_default nats_conf_dir nats_data_default nats_data_dir
    local pdns_filter_state_default pdns_filter_state_dir pdns_ssl_default pdns_ssl_dir pdns_standard_default pdns_standard_dir
    local state_dir state_root_default ui_session_ttl
    env_file=$(runtime_env_file_for_install_dir "$install_dir")

    [[ -f "$env_file" ]] \
        || die "Missing $env_file. Cannot update safely because local runtime configuration is not available."

    print_step "Checking runtime .env"

    require_env_value_for_update IP_STANDARD "$env_file"
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

    state_root_default=$(production_state_root_default "$install_dir")
    state_dir=$(get_env_var LANCACHE_STATE_DIR "$env_file")
    state_dir="${state_dir:-$(legacy_state_root_or_default "$state_root_default")}"
    set_env_key_if_empty_or_missing LANCACHE_STATE_DIR "$state_dir" "$env_file"

    # Cache settings. Older installs may only have CACHE_DIR, so keep that path
    # and map both proxy modes to the same cache directory by default.
    cache_dir=$(get_env_var CACHE_DIR_STANDARD "$env_file")
    if [[ -z "$cache_dir" ]]; then
        cache_dir=$(get_env_var CACHE_DIR "$env_file")
    fi
    cache_dir="${cache_dir:-$(legacy_dir_or_default "$(legacy_state_path cache)" "$state_dir/cache")}"
    set_optional_env_path_override_if_needed CACHE_DIR_STANDARD "$cache_dir" "$state_dir/cache" "$env_file"
    set_optional_env_path_override_if_needed CACHE_DIR_SSL "$cache_dir" "$state_dir/cache" "$env_file"

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

    set_env_key_if_empty_or_missing NGINX_UPSTREAM_RESOLVER "8.8.8.8 8.8.4.4" "$env_file"
    set_env_key_if_empty_or_missing PROXY_SECURITY_MODE "lazy" "$env_file"
    append_env_key_if_missing PROXY_ALLOWED_CLIENT_CIDRS "" "$env_file"
    set_env_key_if_empty_or_missing LANCACHE_IMAGE_REGISTRY "$(resolve_lancache_image_registry "$env_file")" "$env_file"
    set_env_key_if_empty_or_missing LANCACHE_IMAGE_PREFIX "$(resolve_lancache_image_prefix "$env_file")" "$env_file"
    set_env_key_if_empty_or_missing LANCACHE_IMAGE_CHANNEL "$(resolve_lancache_image_channel "$env_file")" "$env_file"
    set_env_key LANCACHE_IMAGE_TAG "$(resolve_lancache_image_tag "$env_file")" "$env_file"
    validate_lancache_image_registry "$(get_env_var LANCACHE_IMAGE_REGISTRY "$env_file")"
    validate_lancache_image_prefix "$(get_env_var LANCACHE_IMAGE_PREFIX "$env_file")"
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

    # Mandatory service tokens. Preserve real values; regenerate empty values
    # and known placeholders like CHANGE_ME_* or lancache-*-secret.
    ensure_secret_env_key KEA_CTRL_TOKEN "$env_file" hex32
    ensure_secret_env_key DDNS_TSIG_KEY "$env_file" base64_32
    ensure_secret_env_key PDNS_API_KEY "$env_file" hex32
    set_env_key_if_empty_or_missing NATS_UI_USER "lancache-ui" "$env_file"
    ensure_secret_env_key NATS_UI_PASSWORD "$env_file" hex32
    set_env_key_if_empty_or_missing NATS_DNS_WRITER_USER "lancache-dns-writer" "$env_file"
    ensure_secret_env_key NATS_DNS_WRITER_PASSWORD "$env_file" hex32
    set_env_key_if_empty_or_missing NATS_DNS_READER_USER "lancache-dns-reader" "$env_file"
    ensure_secret_env_key NATS_DNS_READER_PASSWORD "$env_file" hex32
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
        set_env_key UI_AUTH_PASSWORD "$(generate_secret_value UI_AUTH_PASSWORD alnum20)" "$env_file"
        print_ok "Generated missing Admin UI password because UI_AUTH_USER is set"
    fi

    allow_insecure_ui=false
    [[ -z "$ui_user" && -z "$ui_password" ]] && allow_insecure_ui=true
    append_env_key_if_missing ALLOW_INSECURE_UI "$allow_insecure_ui" "$env_file"

    print_ok ".env is complete for the current quickstart template"
}

# Backup/restore may run on minimal hosts. Install only the missing tools needed
# for the requested operation instead of expanding the base installer footprint.
install_missing_tools() {
    local -a missing=() tools=("$@")
    local tool
    for tool in "${tools[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    (( ${#missing[@]} == 0 )) && return 0
    print_warn "Missing required tool(s): ${missing[*]} — installing now..."
    command -v apt-get >/dev/null 2>&1 || die "Cannot install missing tools automatically; install: ${missing[*]}"
    apt-get update -y
    apt-get install -y --no-install-recommends "${missing[@]}" \
        || die "Failed to install required tool(s): ${missing[*]}"
}

backup_manifest() {
    local install_dir="$1" mode="$2"
    local env_file cache_env_file
    local cache_std cache_ssl kea_dir nats_conf_dir nats_data_dir pdns_filter_state_dir pdns_ssl_dir pdns_standard_dir state_dir
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    cache_env_file="$install_dir/.env"
    state_dir=$(get_env_var LANCACHE_STATE_DIR "$env_file")
    state_dir="${state_dir:-$(legacy_state_root_or_default "$(production_state_root_default "$install_dir")")}"
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

compose_stack_stop() {
    local install_dir="$1"
    local env_file
    compose_stack_available "$install_dir" || return 0
    print_step "Stopping stack for consistent backup/restore"
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    (cd "$install_dir" && docker compose --env-file "$env_file" stop) || print_warn "docker compose stop failed — continuing"
}

compose_stack_start() {
    local install_dir="$1"
    local env_file
    compose_stack_available "$install_dir" || return 0
    print_step "Starting stack"
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    (cd "$install_dir" && docker compose --env-file "$env_file" up -d) || print_warn "docker compose up failed — start the stack manually"
}

validate_compose_config() {
    local install_dir="$1"
    local env_file
    print_step "Validating Docker Compose configuration"
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    (cd "$install_dir" && docker compose --env-file "$env_file" -f "$install_dir/docker-compose.yml" config --quiet) \
        || die "Docker Compose configuration is not valid. The stack was not pulled or restarted."
    print_ok "Docker Compose configuration is valid"
}

compose_volume_names() {
    local install_dir="$1" container env_file
    compose_stack_available "$install_dir" || return 0
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    while IFS= read -r container; do
        [[ -n "$container" ]] || continue
        docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' "$container"
    done < <(cd "$install_dir" && docker compose --env-file "$env_file" ps --all -q 2>/dev/null) | sort -u
}

backup_compose_volumes() {
    local install_dir="$1" volume_root="$2" volume
    compose_stack_available "$install_dir" || return 0
    mkdir -p "$volume_root"
    while IFS= read -r volume; do
        [[ -n "$volume" ]] || continue
        print_ok "Including Docker volume: $volume"
        docker run --rm \
            -v "${volume}:/volume:ro" \
            -v "${volume_root}:/backup" \
            alpine sh -c 'cd /volume && tar -cpf "/backup/$1.tar" .' sh "$volume"
    done < <(compose_volume_names "$install_dir")
}

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

    local stamp dest archive rel path old_umask stack_stopped=0
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    dest="$backup_root/$stamp"
    archive="$backup_root/lancache-ng-${mode}-${stamp}.tar.gz"
    mkdir -p "$backup_root"
    old_umask=$(umask)
    umask 077
    mkdir -p "$dest/rootfs"
    backup_cleanup() {
        local status=$?
        [[ "$stack_stopped" = "1" ]] && compose_stack_start "$install_dir"
        rm -rf "$dest"
        umask "$old_umask"
        trap - EXIT
        return "$status"
    }
    trap backup_cleanup EXIT

    print_step "Creating $mode backup"
    backup_manifest "$install_dir" "$mode" | sort -u > "$dest/manifest.txt"
    while IFS= read -r path; do
        [[ -e "$path" ]] || continue
        if path_is_inside "$backup_root" "$path"; then
            die "Backup destination must not be inside included path: $path"
        fi
    done < "$dest/manifest.txt"

    record_image_revisions "$install_dir" "$dest/image-revisions.txt"
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
    backup_compose_volumes "$install_dir" "$dest/docker-volumes"

    cat > "$dest/README.txt" <<EOF
LanCache-NG backup created at $stamp UTC
Mode: $mode
Install directory: $install_dir

Config backups include text/configuration, Docker named volumes, and runtime databases needed for update rollback.
Full backups additionally include cache directories, which can be very large.
Restore with: ./setup.sh restore $archive $install_dir
EOF
    tar -C "$backup_root" -czf "$archive" "$stamp"
    chmod 600 "$archive"
    print_ok "Backup written: $archive"
    backup_cleanup
}

cmd_restore() {
    local archive="${1:-}" install_dir="${2:-/opt/lancache-ng}"
    install_dir=$(realpath -m "$install_dir")
    [[ -n "$archive" ]] || die "Usage: $0 restore <backup.tar.gz> [install-dir]"
    [[ -f "$archive" ]] || die "Backup archive not found: $archive"
    install_missing_tools tar rsync

    local tmp root backup_dir archived_install archived_repo_root new_repo_root rel_install stack_stopped=0 path rel target
    tmp=$(mktemp -d)
    restore_cleanup() {
        local status=$?
        [[ "$stack_stopped" = "1" ]] && compose_stack_start "$install_dir"
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

    compose_stack_stop "$install_dir"
    stack_stopped=1

    print_step "Restoring backup"
    if [[ -d "$root/$rel_install" ]]; then
        mkdir -p "$install_dir"
        rsync -aH --numeric-ids "$root/$rel_install/" "$install_dir/"
        if [[ "$archived_install" != "$install_dir" ]]; then
            for path in "$install_dir/.env" "$install_dir/.env.local"; do
                [[ -f "$path" ]] || continue
                sed -i "s#${archived_install}#${install_dir}#g" "$path"
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
  update-ip           Change the configured standard and SSL listener IPs.
  debug [install-dir]  Print diagnostic information for an existing stack.
  secondary [options]  Register and launch a secondary DNS node.
  backup [options]     Create a config-only or full rollback backup.
  restore <archive>    Restore a setup-script backup.
  help, --help         Show this compact command list.

Compatibility aliases:
  --reconfigure        Same as update-ip, kept for existing documentation and
                       scripts that already use ./setup.sh --reconfigure.

Tip:
  Run './setup.sh <command> --help' for command-specific help. The main help
  intentionally stays short so it does not flood curl | bash users.
EOF
}

print_command_help() {
    local command="$1"

    case "$command" in
        install)
            cat <<EOF
Usage: ./setup.sh install

Runs the guided LanCache-NG installer. This is the default command when no
argument is provided, which preserves the existing curl | bash setup flow.
EOF
            ;;
        update)
            cat <<EOF
Usage: ./setup.sh update [install-dir]

Updates an existing LanCache-NG installation, pulls fresh container images, and
restarts the stack. If [install-dir] is omitted, /opt/lancache-ng is used.
EOF
            ;;
        update-ip|--reconfigure|reconfigure)
            cat <<EOF
Usage: ./setup.sh update-ip

Interactively changes the standard and SSL listener IP addresses in the
production configuration, then restarts the production stack.

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
certificates, secrets, runtime databases, Docker named volumes, and image
revision metadata. Full backups also include cache directories and can be very
large.
EOF
            ;;
        restore)
            cat <<EOF
Usage: ./setup.sh restore <backup.tar.gz> [install-dir]

Restores a setup-script backup. Files from the archived install directory are
remapped to [install-dir] when it differs from the original path.
EOF
            ;;
        *)
            die "Unknown command for help: $command"
            ;;
    esac
}

# ── update subcommand ─────────────────────────────────────────────────────────
# Update order is deliberate: pause convergence, create a rollback backup,
# migrate/validate config, pull images, validate again, restart, then resume
# convergence. Reordering can leave a half-migrated stack running.
cmd_update() {
    local install_dir="${1:-/opt/lancache-ng}"
    local env_file
    install_dir=$(realpath -m "$install_dir")
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die "No stack found in $install_dir. Run ./setup.sh first."
    assert_prebuilt_image_platform_supported
    cd "$install_dir"
    env_file=$(runtime_env_file_for_install_dir "$install_dir")

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
    docker compose --env-file "$env_file" pull \
        || die "Failed to pull required container images. Check network access and GHCR authentication, then rerun setup.sh update."

    validate_compose_config "$install_dir"

    print_step "Restarting containers"
    docker compose --env-file "$env_file" up -d --remove-orphans
    trap - EXIT
    resume_lancache_convergence_after_update
    UPDATE_CONVERGENCE_COMPLETED=1
    print_ok "Stack updated"
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
    local ip_standard ip_ssl cache_std cache_ssl
    ip_standard=$(get_env_var IP_STANDARD "$env_file")
    ip_ssl=$(get_env_var IP_SSL "$env_file")
    cache_std=$(get_env_var CACHE_DIR_STANDARD "$env_file")
    cache_ssl=$(get_env_var CACHE_DIR_SSL "$env_file")

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
    local dir
    for dir in "$cache_std" "$cache_ssl"; do
        [[ -z "$dir" ]] && continue
        if [[ -d "$dir" ]]; then
            du -sh "$dir"
        else
            print_warn "Directory not found: $dir"
        fi
    done

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

# ── update-ip subcommand ───────────────────────────────────────────────────────
# update-ip is the compatibility reconfiguration path for existing installs. It
# changes only listener/DNS IP references and restarts the current production
# compose stack.
cmd_update_ip() {
    printf "\n"
    printf "${BOLD}╔═══════════════════════════════════════╗${RESET}\n"
    printf "${BOLD}║  LanCache-NG — Reconfigure IPs        ║${RESET}\n"
    printf "${BOLD}╚═══════════════════════════════════════╝${RESET}\n"
    printf "\n"

    [[ "$(id -u)" = "0" ]] \
        || die "This script must be run as root (sudo ./setup.sh update-ip)."
    assert_prebuilt_image_platform_supported

    print_step "Reading current configuration"

    local prod_dir="$SCRIPT_DIR/deploy/prod"
    local deploy_env
    local dns_standard_env="$SCRIPT_DIR/config/prod/dns-standard.env"
    local dns_ssl_env="$SCRIPT_DIR/config/prod/dns-ssl.env"

    deploy_env=$(runtime_env_file_for_install_dir "$prod_dir")
    [[ -f "$deploy_env" ]] || die "Configuration not found: $deploy_env"
    [[ -f "$dns_standard_env" ]] || die "Configuration not found: $dns_standard_env"
    [[ -f "$dns_ssl_env" ]] || die "Configuration not found: $dns_ssl_env"

    local current_ip_standard current_ip_ssl
    local new_ip_standard new_ip_ssl
    current_ip_standard=$(get_env_var IP_STANDARD "$deploy_env")
    current_ip_ssl=$(get_env_var IP_SSL "$deploy_env")

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

    sed -i "s|^PROXY_IP=.*|PROXY_IP=$new_ip_standard|" "$dns_standard_env"
    print_ok "Updated: $dns_standard_env"

    sed -i "s|^PROXY_IP=.*|PROXY_IP=$new_ip_ssl|" "$dns_ssl_env"
    print_ok "Updated: $dns_ssl_env"

    print_step "Restarting containers"

    (cd "$prod_dir" && docker compose --env-file "$deploy_env" -f "$prod_dir/docker-compose.yml" up -d) \
        && print_ok "Stack restarted"

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
    local explicit_lancache_image_tag

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

    [[ -n "$primary" ]] || die "--primary is required"
    [[ -n "$token" ]] || die "--token is required"
    [[ -n "$name" ]] || die "--name is required"
    [[ -n "$proxy_ip" ]] || die "--proxy-ip is required"

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

    print_step "Registering secondary"
    response_file=$(mktemp)
    SECONDARY_RESPONSE_FILE="$response_file"
    trap 'rm -f -- "${SECONDARY_RESPONSE_FILE:-}"' EXIT

    if ! http_status=$(curl -sS -o "$response_file" -w "%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"token\":\"${token}\",\"name\":\"${name}\"}" \
        "${primary}/api/secondary/register"); then
        die "Failed to connect to primary server at ${primary}. Check the URL, network connectivity, and that the primary service is running."
    fi

    response=$(cat "$response_file")
    rm -f -- "$response_file"
    SECONDARY_RESPONSE_FILE=""
    trap - EXIT

    if [[ ! "$http_status" =~ ^2 ]]; then
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
    if [[ -z "$lancache_image_channel" && "${response_image_tag:-}" =~ ^(latest|dev|edge)$ ]]; then
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
    if [[ -z "$explicit_lancache_image_tag" && "$lancache_image_channel" = "pinned" && -z "${LANCACHE_IMAGE_TAG:-}" && -n "$response_image_tag" && ! "$response_image_tag" =~ ^(latest|dev|edge)$ ]]; then
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
    volumes:
      - pdns-data:/var/lib/powerdns
      - pdns-filter-state:/var/lib/powerdns-state
    ports:
      - "\${LISTEN_IP:?Set LISTEN_IP to the secondary host LAN IP}:53:53/udp"
      - "\${LISTEN_IP:?Set LISTEN_IP to the secondary host LAN IP}:53:53/tcp"
    restart: always
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "2"

volumes:
  pdns-data:
  pdns-filter-state:
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
    debug)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help debug
            exit 0
        fi
        cmd_debug  "${2:-/opt/lancache-ng}"; exit 0 ;;
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
        cmd_update_ip; exit 0 ;;
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
    if [[ -d "/opt/lancache-ng/.git" ]]; then
        print_warn "Existing checkout found at /opt/lancache-ng — syncing to the remote default branch..."
        sync_repo_to_default_branch /opt/lancache-ng
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
    ask "Cache directory (absolute path)" "$INSTALL_DIR/cache/standard"
    CACHE_DIR_STANDARD="$REPLY"
    is_absolute_path "$CACHE_DIR_STANDARD" && break
    print_error "Please enter an absolute path (e.g. $INSTALL_DIR/cache/standard)."
done

if [[ "$SSL_ENABLED" = "1" ]]; then
    while true; do
        ask "Cache directory SSL mode (absolute path)" "$INSTALL_DIR/cache/ssl"
        CACHE_DIR_SSL="$REPLY"
        is_absolute_path "$CACHE_DIR_SSL" && break
        print_error "Please enter an absolute path (e.g. $INSTALL_DIR/cache/ssl)."
    done
else
    CACHE_DIR_SSL="$CACHE_DIR_STANDARD"
fi

while true; do
    ask "Cache size in GiB" "50"
    cache_gb="$REPLY"
    [[ "$cache_gb" =~ ^[0-9]+$ ]] && (( cache_gb > 0 )) && break
    print_error "Please enter a positive integer (e.g. 50)."
done

while true; do
    ask "Cache RAM buffer in MB (keys_zone)" "512"
    CACHE_MEM_MB="$REPLY"
    is_positive_integer "$CACHE_MEM_MB" && break
    print_error "Please enter a positive integer (e.g. 512)."
done

# ── 5. Watchtower ─────────────────────────────────────────────────────────────
print_step "Automatic helper updates (Watchtower)"

printf "  LanCache-NG first-party images are pinned to one resolved stack tag.\n"
printf "  Use ./setup.sh update for first-party updates so .env migrations run first.\n"
printf "  Watchtower is optional and should only be used for helper image refreshes.\n"
printf "  Default: disabled.\n\n"

ask "Enable optional Watchtower helper updates? [y/N]" "N"
COMPOSE_PROFILES=""
[[ "$SSL_ENABLED" = "1" ]] && COMPOSE_PROFILES="ssl"
if [[ "${REPLY,,}" = "y" ]]; then
    [[ -n "$COMPOSE_PROFILES" ]] && COMPOSE_PROFILES="${COMPOSE_PROFILES},watchtower" || COMPOSE_PROFILES="watchtower"
    print_ok "Watchtower enabled for optional helper updates (daily at 04:00)"
else
    print_warn "Watchtower disabled — manual updates with: ./setup.sh update"
fi

# ── 6. DHCP mode ─────────────────────────────────────────────────────────────
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

    print_ok "DHCP proxy mode enabled — subnet start: $DHCP_SUBNET_START"
else
    print_ok "DHCP skipped — existing router DHCP remains active"
fi

COMPOSE_PROFILES="$(compose_profiles_for_runtime "$COMPOSE_PROFILES" "$SSL_ENABLED" "$DHCP_MODE")"

# ── 7. Admin-UI access control ────────────────────────────────────────────────
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

# ── 8. Writing .env ───────────────────────────────────────────────────────────
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
KEA_CTRL_TOKEN=$(get_or_generate_secret KEA_CTRL_TOKEN "$env_file" hex32)
DDNS_TSIG_KEY=$(get_or_generate_secret DDNS_TSIG_KEY "$env_file" base64_32)
PDNS_API_KEY=$(get_or_generate_secret PDNS_API_KEY "$env_file" hex32)
NATS_UI_USER=$(get_env_var NATS_UI_USER "$env_file")
NATS_UI_USER="${NATS_UI_USER:-lancache-ui}"
NATS_UI_PASSWORD=$(get_or_generate_secret NATS_UI_PASSWORD "$env_file" hex32)
NATS_DNS_WRITER_USER=$(get_env_var NATS_DNS_WRITER_USER "$env_file")
NATS_DNS_WRITER_USER="${NATS_DNS_WRITER_USER:-lancache-dns-writer}"
NATS_DNS_WRITER_PASSWORD=$(get_or_generate_secret NATS_DNS_WRITER_PASSWORD "$env_file" hex32)
NATS_DNS_READER_USER=$(get_env_var NATS_DNS_READER_USER "$env_file")
NATS_DNS_READER_USER="${NATS_DNS_READER_USER:-lancache-dns-reader}"
NATS_DNS_READER_PASSWORD=$(get_or_generate_secret NATS_DNS_READER_PASSWORD "$env_file" hex32)
SECONDARY_REGISTRATION_TOKEN=$(get_or_generate_secret SECONDARY_REGISTRATION_TOKEN "$env_file" hex32)
UI_SESSION_TTL_SECONDS=$(get_env_var UI_SESSION_TTL_SECONDS "$env_file")
UI_SESSION_TTL_SECONDS="${UI_SESSION_TTL_SECONDS:-$DEFAULT_UI_SESSION_TTL_SECONDS}"
validate_ui_session_ttl_seconds "$UI_SESSION_TTL_SECONDS" "$env_file"

validate_env_values_for_initial_write \
    "IP_STANDARD=${IP_STANDARD}" \
    "IP_SSL=${IP_SSL}" \
    "SSL_ENABLED=${SSL_ENABLED}" \
    "CACHE_DIR_STANDARD=${CACHE_DIR_STANDARD}" \
    "CACHE_DIR_SSL=${CACHE_DIR_SSL}" \
    "CACHE_MAX_SIZE=${cache_gb}g" \
    "CACHE_MEM_MB=${CACHE_MEM_MB}" \
    "CACHE_SLICE_SIZE=8m" \
    "CACHE_VALID_HIT=365d" \
    "CACHE_VALID_ANY=1m" \
    "CACHE_INACTIVE=365d" \
    "NGINX_UPSTREAM_RESOLVER=8.8.8.8 8.8.4.4" \
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
    "KEA_CTRL_TOKEN=${KEA_CTRL_TOKEN}" \
    "DDNS_TSIG_KEY=${DDNS_TSIG_KEY}" \
    "PDNS_API_KEY=${PDNS_API_KEY}" \
    "NATS_UI_USER=${NATS_UI_USER}" \
    "NATS_UI_PASSWORD=${NATS_UI_PASSWORD}" \
    "NATS_DNS_WRITER_USER=${NATS_DNS_WRITER_USER}" \
    "NATS_DNS_WRITER_PASSWORD=${NATS_DNS_WRITER_PASSWORD}" \
    "NATS_DNS_READER_USER=${NATS_DNS_READER_USER}" \
    "NATS_DNS_READER_PASSWORD=${NATS_DNS_READER_PASSWORD}" \
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
CACHE_DIR_STANDARD=${CACHE_DIR_STANDARD}
CACHE_DIR_SSL=${CACHE_DIR_SSL}

CACHE_MAX_SIZE=${cache_gb}g
CACHE_MEM_MB=${CACHE_MEM_MB}
CACHE_SLICE_SIZE=8m
CACHE_VALID_HIT=365d
CACHE_VALID_ANY=1m
CACHE_INACTIVE=365d

# Real upstream DNS for nginx origin lookups. Do not set this to a LanCache DNS/proxy IP.
NGINX_UPSTREAM_RESOLVER=8.8.8.8 8.8.4.4
# Keep lazy as the default: it preserves the historical cache-first behavior
# and avoids breaking downloads when a launcher introduces a new CDN hostname.
PROXY_SECURITY_MODE=lazy
PROXY_ALLOWED_CLIENT_CIDRS=

# For Admin UI (GB as number for progress bar)
CACHE_MAX_GB=${cache_gb}

# First-party service image selector. "latest" is the stable default.
# Use "edge" only when you explicitly want the tested pre-stable channel.
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
# DNS reader role for secondary DNS containers (generated, do not change)
NATS_DNS_READER_USER=${NATS_DNS_READER_USER}
NATS_DNS_READER_PASSWORD=${NATS_DNS_READER_PASSWORD}
# Token for setup.sh secondary — anyone who knows this can register a secondary
SECONDARY_REGISTRATION_TOKEN=${SECONDARY_REGISTRATION_TOKEN}

# ── Profiles ───────────────────────────────────────────────────────────────────
# ssl = SSL mode active; watchtower = optional helper updates; empty = both disabled
COMPOSE_PROFILES=${COMPOSE_PROFILES}

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

# ── 9. Creating directories ───────────────────────────────────────────────────
print_step "Creating directories"
mkdir -p "$CACHE_DIR_STANDARD"
print_ok "Standard cache: $CACHE_DIR_STANDARD"
if [[ "$SSL_ENABLED" = "1" && "$CACHE_DIR_SSL" != "$CACHE_DIR_STANDARD" ]]; then
    mkdir -p "$CACHE_DIR_SSL"
    print_ok "SSL cache:      $CACHE_DIR_SSL"
fi
if [[ "$DHCP_ENABLED" = "1" && -n "$KEA_DATA_DIR" ]]; then
    mkdir -p "$KEA_DATA_DIR"
    print_ok "Kea data:       $KEA_DATA_DIR"
fi

# ── 10. Installing systemd watchdog ───────────────────────────────────────────
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

    systemctl daemon-reload
    SYSTEMD_AVAILABLE=1
    print_ok "systemd units installed; they will be enabled after image pull succeeds"
fi

# ── 11. Summary and confirmation ──────────────────────────────────────────────
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
printf "  %-26s %s\n"    "Cache:"                   "$CACHE_DIR_STANDARD"
[[ "$SSL_ENABLED" = "1" && "$CACHE_DIR_SSL" != "$CACHE_DIR_STANDARD" ]] \
    && printf "  %-26s %s\n" "Cache SSL:"            "$CACHE_DIR_SSL"
printf "  %-26s %s GiB\n" "Cache size:"              "$cache_gb"
printf "  %-26s %s MB\n"  "Cache RAM:"               "$CACHE_MEM_MB"
printf "  %-26s %s\n"    "DHCP mode:"               "$DHCP_MODE"
if [[ "$DHCP_ENABLED" = "1" ]]; then
    printf "  %-26s %s\n" "DHCP server:"             "$DHCP_SUBNET (Pool: $DHCP_RANGE_START–$DHCP_RANGE_END)"
else
    printf "  %-26s %s\n" "DHCP server:"             "disabled"
fi
if [[ "$DHCP_MODE" = "dnsmasq-proxy" ]]; then
    printf "  %-26s %s\n" "DHCP proxy subnet start:" "$DHCP_SUBNET_START"
fi
if [[ "$COMPOSE_PROFILES" = *watchtower* ]]; then
    printf "  %-26s %s\n" "Watchtower:"              "enabled for helper updates (daily at 04:00)"
else
    printf "  %-26s %s\n" "Watchtower:"              "disabled"
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

# ── 12. Starting stack ───────────────────────────────────────────────────────
# Pull before starting so GHCR/auth/platform failures happen while systemd units
# are installed but not yet enabled, keeping failed first installs reversible.
print_step "Pulling images"
cd "$INSTALL_DIR"
assert_prebuilt_image_platform_supported
docker compose --env-file "$INSTALL_DIR/.env" pull \
    || die "Failed to pull required container images. Check network access and GHCR authentication, then rerun setup.sh."

print_step "Starting stack"
if [[ "$SYSTEMD_AVAILABLE" = "1" ]]; then
    systemctl enable lancache.service
    systemctl enable lancache-converge.timer
    print_ok "lancache.service enabled for boot"
    print_ok "lancache-converge.timer enabled for boot"
    systemctl start lancache.service
    systemctl start lancache-converge.timer
else
    docker compose --env-file "$INSTALL_DIR/.env" up -d
fi
print_ok "Stack started"

# ── 13. Post-start info ──────────────────────────────────────────────────────
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
