#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: lifecycle CLI; subcommands dispatched at file end
# Why: .env helpers are shared with secondary registration
set -euo pipefail
export LANG=C LC_ALL=C

# What: normal install path is the production profile
# Why: development-only behaviour needs an explicit opt-in
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)"
PROD_COMPOSE="$SCRIPT_DIR/deploy/prod/docker-compose.yml"
# What: helper container image; require_helper_image sets it
# Why: volume copy, restore and listing share one image
# From: Issue #1683 | PR #1858
LANCACHE_HELPER_IMAGE=""
# What: systemd unit dir and the units this script manages
# Why: one owner for every unit file and systemctl call
# From: Issue #1683 | PR #1858
SYSTEMD_UNIT_DIR="/etc/systemd/system"
STACK_UNIT="lancache.service"
CONVERGE_SERVICE_UNIT="lancache-converge.service"
CONVERGE_TIMER_UNIT="lancache-converge.timer"
AUTO_UPDATE_SERVICE_UNIT="lancache-auto-update.service"
AUTO_UPDATE_TIMER_UNIT="lancache-auto-update.timer"
# What: default checkout, backup root and project repo
# Why: one owner each; rollback must find the backups
# From: Issue #1683 | PR #1858
DEFAULT_INSTALL_DIR="/opt/lancache-ng"
BACKUP_ROOT="${LANCACHE_BACKUP_ROOT:-/var/backups/lancache-ng}"
LANCACHE_REPO_URL="https://github.com/wiki-mod/lancache-ng"
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
# What: list-prompts makes ask()/confirm() record prompts
# Why: one shared recorder keeps the prompt walk in sync
WIZARD_INTROSPECT_MODE=0
# What: fd 9 is the optional list-prompts answers file
# Why: unset means every prompt takes its default
WIZARD_INTROSPECT_ANSWERS_FD=""
# What: the previous prompt of the list-prompts walk
# Why: finds a validation loop that cannot converge
# From: Issue #1683 | PR #1858
WIZARD_INTROSPECT_LAST_PROMPT=""

# What: prints PROMPT; REPLY from answer fd, else default
# Why: one code path, so the walk matches the real wizard
wizard_introspect_record_prompt() {
    local prompt="$1" default="$2" line="" answered=0
    printf 'PROMPT\t%s\t%s\n' "$prompt" "$default"
    # What: an unterminated last line still counts
    # Why: read fails at EOF even when it read text
    # From: Issue #1683 | PR #1858
    if [[ -n "$WIZARD_INTROSPECT_ANSWERS_FD" ]] \
        && { IFS= read -r line <&"$WIZARD_INTROSPECT_ANSWERS_FD" || [[ -n "$line" ]]; }; then
        answered=1
    fi
    # What: a re-asked prompt without a new answer fails
    # Why: a rejected default never changes; no endless walk
    # From: Issue #1683 | PR #1858
    [[ "$answered" = 1 || "$prompt" != "$WIZARD_INTROSPECT_LAST_PROMPT" ]] \
        || die "list-prompts: '$prompt' rejected its answer; add a valid one to the answers file."
    WIZARD_INTROSPECT_LAST_PROMPT="$prompt"
    REPLY="${line:-$default}"
}

# What: ask() reads from /dev/tty, not stdin
# Why: curl ... | bash occupies stdin with the script body
ask() {
    local prompt="$1" default="${2:-}"
    if [[ "$WIZARD_INTROSPECT_MODE" = "1" ]]; then
        wizard_introspect_record_prompt "$prompt" "$default"
        return
    fi
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

    # What: one regex range-checks each IPv4 octet
    # Why: values are written to Docker and DNS config
    local octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    [[ "$ip" =~ ^${octet}\.${octet}\.${octet}\.${octet}$ ]]
}

# What: true for integers above zero, base-10 forced
# Why: leading zeros like 010 must not parse as octal
is_positive_integer() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

# What: true if the value starts with /
# Why: cache and Kea data dirs must be absolute paths
is_absolute_path() {
    [[ -n "${1:-}" && "$1" == /* ]]
}

# What: true if the value is a valid IPv4 ending in .0
# Why: dnsmasq proxy-DHCP needs a subnet base address
is_dnsmasq_subnet_start() {
    local ip="$1"

    is_valid_ipv4 "$ip" && [[ "$ip" == *".0" ]]
}

# What: shape checks for optional dnsmasq relay/proxy values
# Why: hand-edited .env fails as closed as Admin UI input
# From: Issue #450
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
    [[ "$filename" != *[[:space:],]* ]] || return 1
    # What: rejects newline and shell or .env metachars
    # Why: a later .env write fails after earlier steps ran
    case "$filename" in
        *$'\n'* | *'$'* | *'`'* | *'"'* | *"'"* | *'\'* | *'#'* )
            return 1
            ;;
    esac
    return 0
}

# What: true if a server and any filename are both set
# Why: dnsmasq emits no pxe-service with a half missing
pxe_boot_pointer_answers_are_complete() {
    local server="$1" filename_bios="$2" filename_uefi="$3"
    [[ -n "$server" ]] || return 1
    [[ -n "$filename_bios" || -n "$filename_uefi" ]]
}

# What: every IPv4 address of this host as "ip prefix dev"
# Why: one parser for wizard, secondary and debug
# From: Issue #1683 | PR #1858
host_ipv4_addresses() {
    local addrs
    addrs=$(ip -4 addr show) || return $?
    awk '
        /^[0-9]+: / { dev = $2; sub(/:$/, "", dev); sub(/@.*/, "", dev) }
        $1 == "inet" { split($2, a, "/"); print a[1], a[2], dev }
    ' <<< "$addrs"
}

# What: host addresses without loopback and Docker 172.x
# Why: only these can serve DNS to LAN clients
# From: Issue #1683 | PR #1858
host_lan_addresses() {
    local addrs
    addrs=$(host_ipv4_addresses) || return $?
    awk '$1 !~ /^127\./ && $1 !~ /^172\./' <<< "$addrs"
}

# What: internet-route source IP, else the first LAN IP
# Why: the route source is right on multi-homed hosts
# From: Issue #1683 | PR #1858
detect_lan_ip() {
    local ip routes addrs

    if routes=$(ip -4 route get 1.1.1.1); then
        ip=$(awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' <<< "$routes")
        if [[ -n "$ip" ]] && is_valid_ipv4 "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    fi

    addrs=$(host_lan_addresses) \
        || { print_error "Failed to list the IPv4 addresses of this host (exit $?)."; return 2; }
    ip=$(awk 'NR == 1 { print $1 }' <<< "$addrs")
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
    local listen_ip="$1" sockets

    sockets=$(ss -H -ltnup '( sport = :53 )') \
        || die "Failed to list the port 53 listeners of this host (exit $?)."
    awk -v ip="$listen_ip" '
        {
            local = $5
            sub(/:[0-9]+$/, "", local)
            if (ip == "0.0.0.0") {
                print
            } else if (local == ip || local == "0.0.0.0" || local == "*") {
                print
            }
        }
    ' <<< "$sockets"
}

# What: a free port-53 IP: LAN first, then 127.0.0.1-10
# Why: 1 = none free, 2 = listing failed; never swallowed
# From: Issue #1683 | PR #1858
secondary_suggest_alternate_listen_ip() {
    local current="$1" candidate addrs conflicts

    addrs=$(host_lan_addresses) \
        || { print_error "Failed to list the IPv4 addresses of this host (exit $?)."; return 2; }
    while read -r candidate _; do
        [[ -n "$candidate" ]] || continue
        [[ "$candidate" = "$current" ]] && continue
        conflicts=$(secondary_listen_ip_conflicts "$candidate") || return 2
        [[ -z "$conflicts" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done <<< "$addrs"

    for candidate in 127.0.0.1 127.0.0.2 127.0.0.3 127.0.0.4 127.0.0.5 127.0.0.6 127.0.0.7 127.0.0.8 127.0.0.9 127.0.0.10; do
        [[ "$candidate" = "$current" ]] && continue
        conflicts=$(secondary_listen_ip_conflicts "$candidate") || return 2
        [[ -z "$conflicts" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done

    return 1
}

# What: port-53 holders shown; prompt for alternate IP
# Why: fails closed without a terminal, no endless loop
secondary_choose_listen_ip() {
    local listen_ip="$1" conflicts suggestion

    while true; do
        conflicts="$(secondary_listen_ip_conflicts "$listen_ip")" || exit $?
        if [[ -z "$conflicts" ]]; then
            printf '%s\n' "$listen_ip"
            return 0
        fi

        print_warn "Port 53 is already in use for bind IP ${listen_ip}."
        {
            printf '%s\n' "$conflicts" | sed 's/^/    /'
            # What: port-53 holder details, raw output
            # Why: diagnostics only; exit code is no result
            # From: Issue #1683 | PR #1858
            if command -v fuser >/dev/null 2>&1; then
                fuser -v 53/tcp 53/udp 2>&1 | sed 's/^/    /' || printf '    (fuser exit %s)\n' "$?"
            fi
            if command -v lsof >/dev/null 2>&1; then
                lsof -nP -iTCP:53 -iUDP:53 -sTCP:LISTEN 2>&1 | sed 's/^/    /' || printf '    (lsof exit %s)\n' "$?"
            fi
        } >&2

        if ! [[ -t 0 && -t 1 ]]; then
            return 1
        fi

        suggestion=$(secondary_suggest_alternate_listen_ip "$listen_ip") \
            || (( $? == 1 )) || exit 2
        ask "Use another Secondary bind IP" "${suggestion:-$listen_ip}"
        listen_ip="$REPLY"
        is_valid_ipv4 "$listen_ip" \
            || { print_error "Invalid IPv4 address: $listen_ip"; continue; }
    done
}

# What: validates IPv4 CIDR with prefix 1-32
# Why: rejects bad masks before DHCP config is written
is_valid_cidr() {
    local cidr="$1" ip mask octets part

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

# What: lists the valid DHCP_MODE values
# Why: unknown modes must be rejected, not defaulted
is_valid_dhcp_mode() {
    case "$1" in
        disabled|kea|dnsmasq-proxy|dnsmasq-relay) return 0 ;;
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

# What: rebuilds COMPOSE_PROFILES; keeps unrelated profiles
# Why: keeps install and update from drifting apart
compose_profiles_for_runtime() {
    local existing="${1:-}" dhcp_mode="${2:-disabled}" ntp_enabled="${3:-0}" logging_enabled="${4:-1}"
    local profile result="" trimmed
    local -a profiles

    # What: managed profiles rebuilt; a stale ssl dropped
    # Why: prod compose has no ssl profile; it was dead
    # From: Issue #1683 | PR #1858
    IFS=',' read -r -a profiles <<< "$existing"
    for profile in "${profiles[@]}"; do
        trimmed="${profile#"${profile%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        case "$trimmed" in
            ""|ssl|dhcp-kea|dhcp-proxy|ntp|logging) continue ;;
        esac
        case ",$result," in
            *",$trimmed,"*) ;;
            *) [[ -n "$result" ]] && result+=","; result+="$trimmed" ;;
        esac
    done

    case "$dhcp_mode" in
        kea)
            [[ -n "$result" ]] && result+=","
            result+="dhcp-kea"
            ;;
        dnsmasq-proxy|dnsmasq-relay)
            # What: dnsmasq modes share dhcp-proxy profile
            # Why: container reads DHCP_MODE for its config
            [[ -n "$result" ]] && result+=","
            result+="dhcp-proxy"
            ;;
    esac

    if [[ "$ntp_enabled" = "1" ]]; then
        [[ -n "$result" ]] && result+=","
        result+="ntp"
    fi

    if [[ "$logging_enabled" = "1" ]]; then
        [[ -n "$result" ]] && result+=","
        result+="logging"
    fi

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

    # What: runs nmap DHCP discovery in the dhcp (Kea) image
    # Why: nmap has no 'any' interface, so no -e is passed
    if ! output=$(docker compose --env-file "$env_file" -f "$PROD_COMPOSE" --profile dhcp-kea run --rm --no-deps dhcp \
        nmap --script broadcast-dhcp-discover --script-args broadcast-dhcp-discover.timeout=5 2>&1); then
        print_warn "DHCP discovery preflight could not be executed inside the Kea image."
        print_warn "Kea activation will require an explicit confirmation because the safety check did not complete."
        confirm "Continue with Kea activation anyway? [y/N]" "N" \
            || die "Cancelled DHCP activation."
        return 0
    fi

    # What: first Server Identifier line of the nmap output
    # Why: here-strings avoid a live pipe under pipefail
    # From: Issue #1377
    server_identifier="$(sed -n '1p' <<<"$(sed -n 's/^[|_[:space:]]*Server Identifier:[[:space:]]*//p' <<<"$output")")"

    if [[ -n "$server_identifier" ]]; then
        print_warn "An existing DHCP server answered before Kea activation: $server_identifier"
        print_warn "Kea would become a second active DHCP server if you continue."
        confirm "Continue with Kea activation anyway? [y/N]" "N" \
            || die "Cancelled DHCP activation."
    else
        print_ok "No DHCP server answer was detected before Kea activation."
    fi
}

# What: installs packages via apt, dnf, yum or pacman
# Why: host changes need confirmation; unknown PM fails
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

# What: package installs ask first; unknown managers fail
# Why: setup.sh mutates the host, so it must not guess
install_required_command() {
    local command_name="$1" reason="$2"
    shift 2

    install_packages "$reason" "$@" \
        || die "Failed to install required package(s): $*"

    command -v "$command_name" >/dev/null 2>&1 \
        || die "$command_name is still missing after installing package(s): $*"
}

# What: named wrappers for curl and git
# Why: call sites read as install_curl and install_git
install_curl() {
    install_required_command curl "curl is missing." curl
}

install_git() {
    install_required_command git "git is missing." git
}

# What: true if apt has a candidate version for the package
# Why: installed state is not checked here
apt_package_available() {
    local version
    version=$(apt_package_candidate_version "$1") \
        || die "Cannot read the apt candidate of $1 (exit $?)."
    [[ -n "$version" && "$version" != "(none)" ]]
}

# What: reads the version apt would install now
# Why: callers branch on version before installing
apt_package_candidate_version() {
    local policy
    policy=$(apt-cache policy "$1") || die "apt-cache policy $1 failed (exit $?)."
    awk '/^[[:space:]]*Candidate:/ {print $2; exit}' <<< "$policy"
}

# What: true if the apt docker-compose candidate is v2
# Why: legacy name can ship Compose v2 (Trixie)
apt_docker_compose_is_v2() {
    local version=""

    version=$(apt_package_candidate_version docker-compose) \
        || die "Cannot read the apt candidate of docker-compose (exit $?)."
    [[ "$version" =~ ^2[.:-] ]]
}

# What: the Compose v2 apt package; empty when none exists
# Why: rc != 0 is a lookup error, never "not found"
# From: Issue #1683 | PR #1858
apt_compose_package() {
    if apt_package_available docker-compose-plugin; then
        printf '%s\n' docker-compose-plugin
    elif apt_package_available docker-compose-v2; then
        printf '%s\n' docker-compose-v2
    elif apt_package_available docker-compose && apt_docker_compose_is_v2; then
        # What: Trixie docker-compose package is Compose v2
        # Why: gives the docker compose CLI plugin
        printf '%s\n' docker-compose
    fi
}

# What: the Buildx apt package; empty when none exists
# Why: Buildx is optional here; a lookup error still dies
# From: Issue #1683 | PR #1858
apt_buildx_package() {
    if apt_package_available docker-buildx-plugin; then
        printf '%s\n' docker-buildx-plugin
    elif apt_package_available docker-buildx; then
        printf '%s\n' docker-buildx
    fi
}

# What: Docker install is a first-install convenience only
# Why: production setup must stay separate from dev builds
verify_docker_installation() {
    local out
    command -v docker >/dev/null 2>&1 \
        || die "Docker client binary is missing after installation."

    out=$(docker compose version 2>&1) \
        || die "Docker Compose v2 is missing after installation (exit $?): $out"
}

# What: installs docker-cli only if docker is still missing
# Why: Trixie's docker.io no longer ships /usr/bin/docker
ensure_apt_docker_client() {
    if command -v docker >/dev/null 2>&1; then
        return 0
    fi

    if apt_package_available docker-cli; then
        print_warn "docker.io did not provide /usr/bin/docker; installing docker-cli for the Docker client."
        apt-get install -y --no-install-recommends docker-cli \
            || die "Failed to install docker-cli (exit $?)."
    fi

    command -v docker >/dev/null 2>&1 \
        || die "Docker client binary is missing after installation. Install docker-cli or docker-ce-cli manually, then rerun setup.sh."
}

# What: adds Docker's apt repo when no Compose v2 package
# Why: the distro index may lack a supported package
install_docker_apt_repo() {
    local os_id="" codename="" repo_file="" dpkg_arch=""

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

    if [[ -z "$codename" ]] && command -v lsb_release >/dev/null 2>&1; then
        codename=$(lsb_release -cs) || die "lsb_release -cs failed (exit $?)."
    fi
    [[ -n "$codename" ]] \
        || die "Could not determine the apt distribution codename. Please install Docker and Docker Compose manually, then rerun setup.sh."

    repo_file="/etc/apt/sources.list.d/docker.list"
    # What: each repo setup step dies with its own cause
    # Why: set -e is off under the caller's || die
    # From: Issue #1683 | PR #1858
    apt-get update -y || die "apt-get update failed (exit $?); Docker's repository was not added."
    apt-get install -y --no-install-recommends ca-certificates curl gnupg \
        || die "Failed to install ca-certificates, curl and gnupg (exit $?)."
    install -m 0755 -d /etc/apt/keyrings || die "Failed to create /etc/apt/keyrings (exit $?)."
    curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
        || die "Failed to install Docker's apt signing key (exit $?)."
    chmod a+r /etc/apt/keyrings/docker.gpg || die "Failed to make Docker's apt signing key readable (exit $?)."
    dpkg_arch=$(dpkg --print-architecture) || die "dpkg --print-architecture failed (exit $?)."
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
        "$dpkg_arch" "$os_id" "$codename" > "$repo_file" || die "Failed to write $repo_file (exit $?)."
    apt-get update -y || die "apt-get update failed after adding Docker's repository (exit $?)."
}

# What: installs Docker and Compose v2 on Debian/Ubuntu
# Why: distro packages are preferred over Docker's own repo
install_docker_apt() {
    local compose_package="" buildx_package=""
    local -a docker_packages=()

    apt-get update -y || die "apt-get update failed (exit $?); Docker was not installed."
    compose_package=$(apt_compose_package) || die "Cannot look up the Compose v2 apt package (exit $?)."
    if [[ -z "$compose_package" ]]; then
        print_warn "No Compose v2 package was found in the configured apt repositories. Adding Docker's official apt repository."
        install_docker_apt_repo
        compose_package=$(apt_compose_package) || die "Cannot look up the Compose v2 apt package (exit $?)."
        [[ -n "$compose_package" ]] \
            || die "No Docker Compose v2 package found. Please install Docker and the Docker Compose plugin manually, then rerun setup.sh."
    fi

    # What: installs buildx when the apt index has it
    # Why: docker buildx is needed before the first pull
    buildx_package=$(apt_buildx_package) || die "Cannot look up the Buildx apt package (exit $?)."

    if [[ "$compose_package" = docker-compose-plugin ]]; then
        docker_packages=(docker-ce docker-ce-cli containerd.io "$compose_package")
        [[ -n "$buildx_package" ]] && docker_packages+=("$buildx_package")
        apt-get install -y --no-install-recommends "${docker_packages[@]}" \
            || die "Failed to install ${docker_packages[*]} (exit $?)."
    else
        docker_packages=(docker.io "$compose_package")
        [[ -n "$buildx_package" ]] && docker_packages+=("$buildx_package")
        apt-get install -y --no-install-recommends "${docker_packages[@]}" \
            || die "Failed to install ${docker_packages[*]} (exit $?)."
        # What: falls back to docker-cli if needed
        # Why: Trixie ships the client in docker-cli
        ensure_apt_docker_client
    fi

    verify_docker_installation
}

# Same fallback logic as install_docker_apt, but for the case where Docker
# itself is already installed and only the Compose v2 plugin is missing.
install_docker_compose_apt() {
    local compose_package=""

    apt-get update -y || die "apt-get update failed (exit $?); Docker Compose was not installed."
    compose_package=$(apt_compose_package) || die "Cannot look up the Compose v2 apt package (exit $?)."
    if [[ -z "$compose_package" ]]; then
        print_warn "No Compose v2 package was found in the configured apt repositories. Adding Docker's official apt repository."
        install_docker_apt_repo
        compose_package=$(apt_compose_package) || die "Cannot look up the Compose v2 apt package (exit $?)."
        [[ -n "$compose_package" ]] \
            || die "No Docker Compose v2 package found. Please install the Docker Compose plugin manually, then rerun setup.sh."
    fi

    apt-get install -y --no-install-recommends "$compose_package" \
        || die "Failed to install $compose_package (exit $?)."
    verify_docker_installation
}

# Filters an arbitrary package name list down to just the ones actually
# installed, via rpm -q, for use as a generic conflict-detection building block.
rpm_installed_package_list() {
    local installed package

    installed=$(rpm -qa --qf '%{NAME}\n') \
        || die "Failed to read the rpm package database (exit $?)."
    for package in "$@"; do
        if grep -qxF -- "$package" <<< "$installed"; then
            printf '%s\n' "$package"
        fi
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
    local package list
    local -a conflicts=()

    list=$(rpm_conflicting_docker_packages) \
        || die "Cannot list the installed rpm packages that conflict with Docker (exit $?)."
    while IFS= read -r package; do
        [[ -n "$package" ]] && conflicts+=("$package")
    done <<< "$list"

    (( ${#conflicts[@]} == 0 )) && return 0

    die "Docker's RPM packages conflict with these installed packages: ${conflicts[*]}. Remove them first (for example: dnf remove ${conflicts[*]}), then rerun setup.sh."
}

# What: picks Docker's rpm repo URL by os-release ID
# Why: Fedora, RHEL own repos; other RHEL use CentOS
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

# What: installs Docker via Docker's own rpm repo
# Why: engine conflict guard runs only for engine packages
install_docker_rpm() {
    local manager="$1"
    shift
    local repo_url needs_engine=0 package
    local packages=("$@")

    if (( ${#packages[@]} == 0 )); then
        # What: default set adds buildx and compose plugins
        # Why: full install satisfies the buildx check
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

    repo_url=$(docker_rpm_repo_url) || die "Cannot resolve Docker's rpm repository (exit $?)."
    # What: each package step dies with its own cause
    # Why: set -e is off under the caller's || die
    # From: Issue #1683 | PR #1858
    if [[ "$manager" = dnf ]]; then
        dnf install -y dnf-plugins-core || die "Failed to install dnf-plugins-core (exit $?)."
        dnf config-manager --add-repo "$repo_url" \
            || dnf config-manager addrepo --from-repofile="$repo_url" \
            || die "Failed to add Docker's dnf repository $repo_url (exit $?)."
        dnf install -y "${packages[@]}" || die "Failed to install ${packages[*]} (exit $?)."
    else
        yum install -y yum-utils || die "Failed to install yum-utils (exit $?)."
        yum-config-manager --add-repo "$repo_url" || die "Failed to add Docker's yum repository $repo_url (exit $?)."
        yum install -y "${packages[@]}" || die "Failed to install ${packages[*]} (exit $?)."
    fi

    verify_docker_installation
}

# What: installs only the Compose v2 plugin
# Why: each manager asks for confirmation before changes
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

# What: installs Docker engine and Compose v2 per manager
# Why: each manager has its own confirmation and package set
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

# What: installs curl, Docker, Docker Compose v2 plugin
# Why: secondary needs the same set as primary
ensure_stack_requirements_installed() {
    local info out
    [[ "$(id -u)" = "0" ]] \
        || die "This command must be run as root (sudo ./setup.sh install-requirements-primary or install-requirements-secondary)."

    if ! command -v curl >/dev/null 2>&1; then
        install_curl
    fi

    # What: jq reads every JSON answer this script gets
    # Why: primary, Kea and DNS replies need a real parser
    # From: Issue #1683 | PR #1858
    if ! command -v jq >/dev/null 2>&1; then
        install_required_command jq "jq is missing." jq
    fi

    if ! command -v docker >/dev/null 2>&1; then
        install_docker
        print_ok "Docker installed"
    fi

    if ! info=$(docker info 2>&1); then
        print_warn "Docker daemon not reachable (${info##*$'\n'}) — starting now..."
        systemctl enable --now docker \
            || die "Failed to start Docker daemon."
        info=$(docker info 2>&1) \
            || die "Docker daemon is still not reachable after starting it (exit $?): $info"
    fi

    if ! docker compose version >/dev/null 2>&1; then
        install_docker_compose
    fi

    out=$(docker compose version 2>&1) \
        || die "Docker Compose plugin still missing after installing Docker requirements (exit $?): $out"
}

cmd_install_requirements_primary() {
    ensure_stack_requirements_installed
    print_ok "Primary node requirements installed (curl, jq, Docker, Docker Compose v2). Run ./setup.sh install next."
}

cmd_install_requirements_secondary() {
    ensure_stack_requirements_installed
    print_ok "Secondary node requirements installed (curl, jq, Docker, Docker Compose v2). Run ./setup.sh secondary --primary <url> --token <token> --name <name> --proxy-ip <ip> next."
}

# What: strips quotes and unquoted inline comments
# Why: Compose-valid values must pass validate_env_value
_compose_parse_env_value() {
    local value="$1" rest

    # What: trims leading whitespace before the quote check
    # Why: otherwise a leading space hides the quote
    value="${value#"${value%%[![:space:]]*}"}"

    if [[ "$value" == \"* ]]; then
        # What: takes text up to the first closing quote
        # Why: trailing comments after quotes are valid
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

# What: raw values of KEY= lines; the last one, or all
# Why: compose uses the last; a read error must stop
# From: Issue #1683 | PR #1858
env_raw_assignments() {
    local key="$1" env_file="$2" mode="$3" out
    [[ -e "$env_file" ]] || return 0
    out=$(awk -F= -v key="$key" -v mode="$mode" '
        $1 == key { sub(/^[^=]*=/, ""); last = $0; seen = 1; if (mode == "all") print }
        END { if (mode == "last" && seen) print last }' "$env_file") \
        || die "Failed to read $key from $env_file (exit $?)."
    [[ -z "$out" ]] || printf '%s\n' "$out"
}

# What: the parsed value compose uses for a key, or ""
# Why: setup must decide on the value the stack runs with
# From: Issue #1683 | PR #1858
get_env_var() {
    local raw
    raw=$(env_raw_assignments "$1" "$2" last) \
        || die "Cannot read $1 from $2 (exit $?)."
    _compose_parse_env_value "$raw"
}

# What: the last non-empty parsed value of a key, or ""
# Why: repairs an empty later line; else compose's winner
# From: Issue #1683 | PR #1858
get_env_var_nonempty() {
    local raw
    raw=$(get_env_assignment_value_raw_nonempty "$1" "$2") \
        || die "Cannot read $1 from $2 (exit $?)."
    _compose_parse_env_value "$raw"
}

# What: the raw text of the assignment compose uses
# Why: migrations copy quoting and ${VAR} verbatim
# From: Issue #1683 | PR #1858
get_env_assignment_value_raw() {
    env_raw_assignments "$1" "$2" last
}

# What: the raw text of the last non-empty assignment
# Why: migrations keep a real value over an empty one
# From: Issue #1683 | PR #1858
get_env_assignment_value_raw_nonempty() {
    local key="$1" env_file="$2" raw lines found=""
    lines=$(env_raw_assignments "$key" "$env_file" all) \
        || die "Cannot read $key from $env_file (exit $?)."
    while IFS= read -r raw; do
        [[ -z "$(_compose_parse_env_value "$raw")" ]] || found="$raw"
    done <<< "$lines"
    printf '%s' "$found"
}

# What: .env helpers for install, update and migration
# Why: setup.sh owns these for curl | bash users

# What: true if KEY= is assigned; a missing file has none
# Why: a read error must stop setup, never read as absent
# From: Issue #1683 | PR #1858
env_key_exists() {
    local key="$1" env_file="$2" rc=0
    [[ -e "$env_file" ]] || return 1
    grep -q "^${key}=" "$env_file" || rc=$?
    [[ "$rc" -le 1 ]] || die "Failed to read $env_file while looking up $key (exit $rc)."
    return "$rc"
}

# What: true if the key has a non-empty parsed value
# Why: empty values count as unset for setup decisions
env_key_has_value() {
    local key="$1" env_file="$2" value
    value=$(get_env_var "$key" "$env_file") || exit $?
    [[ -n "$value" ]]
}

# What: true for empty, CHANGE_ME_* and similar placeholders
# Why: setup replaces placeholders, not keeps them
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

# What: true if the key has a non-placeholder value
# Why: setup overwrites placeholders, never real secrets
env_key_has_usable_secret() {
    local key="$1" env_file="$2" value
    value=$(get_env_var "$key" "$env_file") || exit $?
    ! secret_value_is_placeholder "$value"
}

# What: generate_secret_value fails on any generator error
# Why: an empty secret must never be written
generate_secret_value() {
    local name="$1" kind="$2" value chunk managed
    # What: only a key on managed_secret_env_keys is made
    # Why: an unlisted key would ship unredacted in bundles
    # From: Issue #1683 | PR #1858
    managed=$(managed_secret_env_keys)
    grep -qxF -- "$name" <<< "$managed" \
        || die "Secret $name is not in managed_secret_env_keys; add it there so log bundles redact it."

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

# What: dies on values with shell or .env metachars
# Why: Compose .env parsing would change the value
validate_env_value() {
    local key="$1" value="$2"

    # What: empty values are accepted
    # Why: optional settings are written as empty strings
    [[ -z "$value" ]] && return 0

    # What: rejects newline and shell or .env metachars
    # Why: Compose .env parsing would change the value
    case "$value" in
        *$'\n'* | *'$'* | *'`'* | *'"'* | *"'"* | *'\'* | *'#'* )
            die "$key contains unsafe characters for .env. Cannot proceed. Value: $value"
            ;;
    esac

    return 0
}

# What: validates each KEY=VALUE before the first .env write
# Why: heredoc interpolates values unquoted
validate_env_values_for_initial_write() {
    local key value pair

    # What: validates every value before the .env file opens
    # Why: unquoted heredoc values could change parsing
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        validate_env_value "$key" "$value"
    done
}

# What: rewrites KEY= lines of an env file (set or remove)
# Why: a failed awk must never truncate or mangle the file
# From: Issue #1683 | PR #1858
rewrite_env_key() {
    local env_file="$1" key="$2" value="$3" mode="$4" out
    out=$(ENV_KEY="$key" ENV_VALUE="$value" ENV_MODE="$mode" awk -F= '
        $1 == ENVIRON["ENV_KEY"] {
            if (ENVIRON["ENV_MODE"] == "set" && !seen) print ENVIRON["ENV_KEY"] "=" ENVIRON["ENV_VALUE"]
            seen = 1
            next
        }
        { print }' "$env_file" && printf x) \
        || die "Failed to rewrite $key in $env_file (exit $?); it was not changed."
    # What: a failed write ends the run in any context
    # Why: if/|| turn set -e off; a bare rc gets lost
    # From: Issue #1683 | PR #1858
    printf '%s' "${out%x}" | write_file_atomically "$env_file" \
        || die "Failed to write $key into $env_file (exit $?)."
}

# What: sets KEY=VALUE after validating its characters
# Why: duplicate lines are dropped, one assignment remains
set_env_key() {
    local key="$1" value="$2" env_file="$3"
    validate_env_value "$key" "$value"
    if env_key_exists "$key" "$env_file"; then
        rewrite_env_key "$env_file" "$key" "$value" set
    else
        # What: explicit die on append failure
        # Why: errexit is ignored in tested subshells
        printf '%s=%s\n' "$key" "$value" >> "$env_file" \
            || die "Failed to append $key to $env_file."
    fi
}

# What: sets raw value without character validation
# Why: raw values may contain ${VAR} interpolation
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
        rewrite_env_key "$env_file" "$key" "$assignment_value" set
    else
        # What: same explicit die as set_env_key
        # Why: errexit is ignored in tested subshells
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
        existing_assignment=$(get_env_assignment_value_raw_nonempty "$key" "$env_file") || exit $?
        if [[ -n "$existing_assignment" ]]; then
            set_env_assignment "$key" "$existing_assignment" "$env_file"
        else
            set_env_key "$key" "$value" "$env_file"
        fi
    else
        # What: same explicit die as set_env_key
        # Why: errexit is ignored in tested subshells
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
    # What: appends an assignment verbatim if key is missing
    # Why: keeps ${VAR:-...} interpolation intact
    env_key_exists "$key" "$env_file" \
        || printf '%s=%s\n' "$key" "$assignment_value" >> "$env_file" \
        || die "Failed to append $key to $env_file."
}

# What: migrates an old key to a new one, or seeds fallback
# Why: an empty target is a valid, intentional state
append_env_migrated_assignment_if_missing() {
    local target_key="$1" source_key="$2" fallback_value="$3" env_file="$4"
    local source_assignment

    # What: keeps an existing empty optional target as is
    # Why: an empty value keeps Compose's fallback alive
    if env_key_exists "$target_key" "$env_file"; then
        return 0
    fi

    source_assignment=$(get_env_assignment_value_raw_nonempty "$source_key" "$env_file") || exit $?
    if [[ -n "$source_assignment" ]]; then
        # What: rewrites an empty migrated target in place
        # Why: avoids duplicate KEY= lines on update
        set_env_assignment "$target_key" "$source_assignment" "$env_file"
    elif env_key_exists "$target_key" "$env_file" || [[ -n "$fallback_value" ]]; then
        set_env_key "$target_key" "$fallback_value" "$env_file"
    fi
}

# What: migrates a required key; repairs an empty target
# Why: Compose would turn KEY= into an invalid bind mount
append_required_env_migrated_assignment_if_empty_or_missing() {
    local target_key="$1" source_key="$2" fallback_value="$3" env_file="$4"
    local target_assignment source_assignment

    # What: keeps a non-empty duplicate target value
    # Why: updates must converge on the operator's real dir
    target_assignment=$(get_env_assignment_value_raw_nonempty "$target_key" "$env_file") || exit $?
    if [[ -n "$target_assignment" ]]; then
        set_env_assignment "$target_key" "$target_assignment" "$env_file"
        return 0
    fi

    source_assignment=$(get_env_assignment_value_raw_nonempty "$source_key" "$env_file") || exit $?
    if [[ -n "$source_assignment" ]]; then
        set_env_assignment "$target_key" "$source_assignment" "$env_file"
    elif env_key_exists "$target_key" "$env_file" || [[ -n "$fallback_value" ]]; then
        set_env_key "$target_key" "$fallback_value" "$env_file"
    fi
}

migrate_proxy_security_mode_for_update() {
    local env_file="$1" proxy_security_mode proxy_allowed_client_cidrs

    proxy_security_mode=$(get_env_var PROXY_SECURITY_MODE "$env_file") || exit $?
    proxy_allowed_client_cidrs=$(get_env_var PROXY_ALLOWED_CLIENT_CIDRS "$env_file") || exit $?

    # What: resets strict to lazy when no allowlist is set
    # Why: no allowlist means no strict policy to preserve
    if [[ "$proxy_security_mode" = "strict" && -z "$proxy_allowed_client_cidrs" ]]; then
        set_env_key PROXY_SECURITY_MODE "lazy" "$env_file"
        print_ok "Migrated legacy PROXY_SECURITY_MODE=strict without PROXY_ALLOWED_CLIENT_CIDRS to lazy"
    fi
}

readonly LEGACY_STATE_ROOT="/srv/lancache"
readonly -a LEGACY_STATE_CHILDREN=(cache pdns-standard pdns-ssl pdns-filter-state kea nats nats-conf)

# What: fixed pre-v0.1 state paths, used for migration
# Why: backup, update and restore must find legacy data
legacy_state_path() {
    local child="${1:-}"

    if [[ -n "$child" ]]; then
        printf '%s/%s\n' "$LEGACY_STATE_ROOT" "$child"
    else
        printf '%s\n' "$LEGACY_STATE_ROOT"
    fi
}

# What: true if a known pre-v0.1 state subdirectory exists
# Why: an unrelated /srv/lancache dir is not legacy state
legacy_state_root_has_known_children() {
    local child

    for child in "${LEGACY_STATE_CHILDREN[@]}"; do
        [[ -d "$(legacy_state_path "$child")" ]] && return 0
    done
    return 1
}

# What: legacy root if it has children, else the default
# Why: new-style default applies without legacy state
legacy_state_root_or_default() {
    local default_dir="$1"

    if legacy_state_root_has_known_children; then
        legacy_state_path
    else
        printf '%s\n' "$default_dir"
    fi
}

# What: legacy dir if it exists, else the default
# Why: a single directory needs no child-directory check
legacy_dir_or_default() {
    local legacy_dir="$1" default_dir="$2"

    if [[ -d "$legacy_dir" ]]; then
        printf '%s\n' "$legacy_dir"
    else
        printf '%s\n' "$default_dir"
    fi
}

# What: reconciles a per-service directory override
# Why: overrides matching the derived default are dropped
set_optional_env_path_override_if_needed() {
    local key="$1" desired_path="$2" derived_path="$3" env_file="$4"
    local existing_assignment

    existing_assignment=$(get_env_assignment_value_raw_nonempty "$key" "$env_file") || exit $?
    if [[ -n "$existing_assignment" ]]; then
        if [[ "$existing_assignment" = "$derived_path" ]]; then
            remove_env_key "$key" "$env_file"
            return 0
        elif [[ "$existing_assignment" == *'$'* ]] || is_absolute_path "$existing_assignment"; then
            set_env_assignment "$key" "$existing_assignment" "$env_file"
            return 0
        fi
        # What: a broken value (e.g. 50) is dropped as unset
        # Why: one run converges; a rerun changes nothing
        # From: Issue #1683 | PR #1858
        remove_env_key "$key" "$env_file"
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
    rewrite_env_key "$env_file" "$key" "" remove
}

# Default LANCACHE_STATE_DIR for a given install_dir (see comment inside for
# the deploy/prod special case).
production_state_root_default() {
    local install_dir="$1" compose roots

    # A manual production checkout runs setup.sh update against deploy/prod,
    # but runtime state must still live in the approved production root instead
    # of inside the Git checkout.
    if is_deploy_prod_install_dir "$install_dir"; then
        # What: the root the prod compose falls back to
        # Why: the compose file owns the state default
        # From: Issue #1683 | PR #1858
        compose="$install_dir/docker-compose.yml"
        roots=$(grep -o 'LANCACHE_STATE_DIR:-[^}]*}' "$compose") \
            || die "$compose has no LANCACHE_STATE_DIR default (exit $?)."
        roots=$(sort -u <<< "$roots")
        [[ "$roots" =~ ^LANCACHE_STATE_DIR:-/[^[:space:]]*\}$ ]] \
            || die "$compose gives no single LANCACHE_STATE_DIR default: ${roots//$'\n'/ }"
        roots="${roots#LANCACHE_STATE_DIR:-}"
        printf '%s\n' "${roots%\}}"
    else
        printf '%s\n' "$install_dir"
    fi
}

# What: an install's state root: env, legacy root, default
# Why: one resolution for update, backup, logs and DHCP
# From: Issue #1683 | PR #1858
install_state_root() {
    local install_dir="$1" env_file="$2" state
    state=$(get_env_var LANCACHE_STATE_DIR "$env_file") \
        || die "Cannot read LANCACHE_STATE_DIR from $env_file (exit $?)."
    if [[ -z "$state" ]]; then
        state=$(production_state_root_default "$install_dir") \
            || die "Cannot resolve the default state root of $install_dir (exit $?)."
        state=$(legacy_state_root_or_default "$state") || exit $?
    fi
    printf '%s\n' "$state"
}

# True if install_dir is the manual production checkout path (.../deploy/prod),
# as opposed to a quickstart-installed directory like /opt/lancache-ng.
is_deploy_prod_install_dir() {
    local install_dir="$1"
    [[ "$(basename "$install_dir")" = "prod" && "$(basename "$(dirname "$install_dir")")" = "deploy" ]]
}

# What: picks .env.local for prod checkouts when it exists
# Why: git pull keeps operator production values
runtime_env_file_for_install_dir() {
    local install_dir="$1"

    if is_deploy_prod_install_dir "$install_dir" && [[ -f "$install_dir/.env.local" ]]; then
        printf '%s\n' "$install_dir/.env.local"
    else
        printf '%s\n' "$install_dir/.env"
    fi
}

# What: true if the NATS-secondary override is active
# Why: shell or env file NATS_BIND_IP activates it
nats_secondary_override_active_for_install_dir() {
    local install_dir="$1" env_file="$2" bind_ip

    [[ -f "$install_dir/docker-compose.nats-secondary.yml" ]] || return 1
    if [[ -n "${NATS_BIND_IP:-}" ]]; then
        return 0
    fi
    bind_ip=$(get_env_var_nonempty NATS_BIND_IP "$env_file") \
        || die "Cannot read NATS_BIND_IP from $env_file (exit $?)."
    [[ -n "$bind_ip" ]]
}

# What: builds -f args for base, override, NATS
# Why: any -f disables auto-discovery; base is listed
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

# What: volume exists (0), absent (1), lookup error (2)
# Why: a lookup error must never read as "no data"
# From: Issue #1683 | PR #1858
docker_volume_exists() {
    local names
    names=$(docker volume ls -q) || {
        print_error "Failed to list Docker volumes (exit $?)."
        return 2
    }
    grep -qxF -- "$1" <<< "$names"
}

# What: fills an array with the compose -f arguments
# Why: a failed list must stop, never shrink the stack
# From: Issue #1683 | PR #1858
compose_files_into() {
    local -n _compose_files_ref="$1"
    local files
    files=$(compose_file_args_for_install_dir "$2" "$3") \
        || die "Cannot build the compose file list for $2 (exit $?)."
    mapfile -t _compose_files_ref <<< "$files"
}

# What: docker compose with one install's env and files
# Why: every call must see the stack with all its overrides
# From: Issue #1683 | PR #1858
stack_compose() {
    local install_dir="$1" env_file="$2"
    local -a stack_files
    shift 2
    compose_files_into stack_files "$install_dir" "$env_file"
    # What: a container start first writes the allowlist
    # Why: the socket proxy cannot start without that file
    # From: Issue #1683 | PR #1858
    if [[ " $* " =~ \ (up|run|start|restart|create)\  ]] && is_deploy_prod_install_dir "$install_dir"; then
        render_socket_proxy_config "$install_dir" "$env_file" || return $?
    fi
    docker compose --env-file "$env_file" "${stack_files[@]}" "$@"
}

# What: ci.sh renders the socket-proxy allowlist for a stack
# Why: one renderer; the SOT policy reaches every start
# From: Issue #1683 | PR #1858
render_socket_proxy_config() {
    local install_dir="$1" env_file="$2" out rc=0
    out=$(bash "$(deploy_prod_repo_root "$install_dir")/.github/scripts/ci.sh" \
        socket-proxy-config "$install_dir/docker-compose.yml" "$env_file" 2>&1) || rc=$?
    if (( rc != 0 )); then
        print_error "The docker-socket-proxy allowlist was not written (ci.sh exit $rc):"
        printf '%s\n' "$out" >&2
        return "$rc"
    fi
}

# What: sorted entries of a volume/dir: mode, owner, hash
# Why: a copy counts only when both lists are equal
# From: Issue #1683 | PR #1858
path_manifest() {
    require_helper_image
    docker run --rm -v "${1}:/m:ro" "$LANCACHE_HELPER_IMAGE" sh -c '
        set -eu
        cd /m
        nl=$(find . -name "*
*")
        if [ -n "$nl" ]; then
            echo "a file name contains a newline and cannot be verified" >&2
            exit 3
        fi
        find . > /tmp/entries
        LC_ALL=C sort /tmp/entries > /tmp/sorted
        while IFS= read -r p; do
            if [ -L "$p" ]; then
                t=$(readlink "$p")
                printf "L %s -> %s\n" "$p" "$t"
            elif [ -d "$p" ]; then
                m=$(stat -c "%a %u %g" "$p")
                printf "D %s %s\n" "$p" "$m"
            elif [ -f "$p" ]; then
                m=$(stat -c "%a %u %g %s" "$p")
                s=$(sha256sum "$p")
                printf "F %s %s %s\n" "$p" "$m" "${s%% *}"
            else
                m=$(stat -c "%F %a %u %g" "$p")
                printf "O %s %s\n" "$p" "$m"
            fi
        done < /tmp/sorted'
}

# What: dies naming the first entry where two lists differ
# Why: a mismatch must show the exact entry as evidence
# From: Issue #1683 | PR #1858
manifest_mismatch_die() {
    local what="$1" want="$2" have="$3" i
    local -a w h
    mapfile -t w <<< "$want"
    mapfile -t h <<< "$have"
    for (( i = 0; i < ${#w[@]} || i < ${#h[@]}; i++ )); do
        if [[ "${w[i]-}" != "${h[i]-}" ]]; then
            die "$what: entry $(( i + 1 )) differs: source '${w[i]-<none>}', copy '${h[i]-<none>}'."
        fi
    done
    die "$what: the entry lists differ."
}

# What: true if a copy is recorded after the last rollback
# Why: a rolled-back copy is stale and must be redone
# From: Issue #1683 | PR #1858
volume_copy_recorded() {
    local record="$1" volume="$2" dir="$3" state
    [[ -e "$record" ]] || return 1
    state=$(awk -F'|' -v v="$volume" -v d="$dir" '
        $1 == "rolledback" { ok = 0 }
        $1 == "copied" && $2 == v && $3 == d { ok = 1 }
        END { print ok + 0 }' "$record") \
        || die "Failed to read $record (exit $?)."
    [[ "$state" = "1" ]]
}

# What: copies a volume into a dir, proven equal, recorded
# Why: a partial or unproven copy must never count as done
# From: Issue #1683 | PR #1858
copy_volume_to_dir() {
    local volume="$1" dir="$2" record="$3" rc=0 want have stage parent entries digest
    local -a lines
    require_helper_image
    docker_volume_exists "$volume" || rc=$?
    [[ "$rc" -ne 1 ]] || return 0
    [[ "$rc" -eq 0 ]] || die "Cannot check the Docker volume $volume; nothing was copied."
    if volume_copy_recorded "$record" "$volume" "$dir"; then
        print_ok "Kept $dir: its copy of $volume is already verified"
        return 0
    fi
    want=$(path_manifest "$volume") \
        || die "Cannot list the Docker volume $volume (exit $?); nothing was copied."
    entries=""
    if [[ -e "$dir" ]]; then
        entries=$(ls -A -- "$dir") || die "Cannot read $dir (exit $?); nothing was copied."
    fi
    if [[ -n "$entries" ]]; then
        have=$(path_manifest "$dir") || die "Cannot list $dir (exit $?); nothing was copied."
        [[ "$have" == "$want" ]] \
            || manifest_mismatch_die "$dir already holds other data than $volume and was not changed" "$want" "$have"
    else
        parent=$(dirname -- "$dir")
        stage="$parent/.${dir##*/}.quickstart-copy"
        mkdir -p -- "$parent" || die "Failed to create $parent (exit $?)."
        rm -rf -- "$stage" || die "Failed to remove the unfinished copy $stage (exit $?)."
        docker run --rm -v "${volume}:/from:ro" -v "${parent}:/to" "$LANCACHE_HELPER_IMAGE" \
            cp -a /from "/to/${stage##*/}" \
            || die "Failed to copy the Docker volume $volume to $stage (exit $?); $dir was not changed."
        have=$(path_manifest "$stage") || die "Cannot list $stage (exit $?); $dir was not changed."
        [[ "$have" == "$want" ]] \
            || manifest_mismatch_die "The copy of $volume in $stage is incomplete; $dir was not changed" "$want" "$have"
        if [[ -e "$dir" ]]; then
            rmdir -- "$dir" || die "Failed to replace the empty $dir (exit $?)."
        fi
        mv -- "$stage" "$dir" || die "Failed to move $stage to $dir (exit $?)."
    fi
    digest=$(sha256sum <<< "$want") || die "Failed to hash the entry list of $volume (exit $?)."
    mapfile -t lines <<< "$want"
    printf 'copied|%s|%s|%s|%s\n' "$volume" "$dir" "${digest%% *}" "${#lines[@]}" >> "$record" \
        || die "Failed to record the copy of $volume in $record (exit $?)."
    print_ok "Copied $volume into $dir (${#lines[@]} entries, verified)"
}

# What: default state subdir of a prod key, from compose
# Why: deploy/prod owns these defaults; no second copy
# From: Issue #1683 | PR #1858
prod_state_subdir() {
    local key="$1" subs
    subs=$(awk -v k="$key" '{
        p = "${" k ":-${LANCACHE_STATE_DIR:-"
        i = index($0, p)
        if (!i) next
        rest = substr($0, i + length(p))
        j = index(rest, "}/")
        if (!j) next
        rest = substr(rest, j + 2)
        print substr(rest, 1, index(rest, "}") - 1)
    }' "$PROD_COMPOSE") || die "Failed to read $PROD_COMPOSE (exit $?)."
    subs=$(sort -u <<< "$subs")
    [[ "$subs" =~ ^[a-z0-9-]+$ ]] \
        || die "$PROD_COMPOSE gives no single default directory for $key: ${subs//$'\n'/ }"
    printf '%s\n' "$subs"
}

# What: every state key the prod compose mounts
# Why: backup must not keep a second, drifting list
# From: Issue #1683 | PR #1858
prod_state_keys() {
    local keys
    keys=$(grep -oE '\$\{[A-Z0-9_]+:-\$\{LANCACHE_STATE_DIR:-' "$PROD_COMPOSE") \
        || die "$PROD_COMPOSE mounts no state directory (exit $?)."
    sed -E 's/^\$\{([A-Z0-9_]+):-.*/\1/' <<< "$keys" | sort -u
}

# What: quickstart .env keys that may hold relative paths
# Why: migration and its test read the same key list
# From: Issue #1683 | PR #1858
quickstart_path_keys() {
    printf '%s\n' CACHE_DIR KEA_DATA_DIR NTP_DATA_DIR CACHEHAMSTER_DATA_DIR
}

# What: files a quickstart dir carries below its root
# Why: migration removes them last; the test plants them
# From: Issue #1683 | PR #1858
quickstart_bundle_copies() {
    printf '%s\n' scripts/shared-secret-bootstrap.sh scripts/untracked/docker-socket-proxy.sh
}

# What: quickstart volume and the prod state-dir key per row
# Why: prod binds these as dirs, not as named volumes
# From: Issue #1683 | PR #1858
quickstart_volume_keys() {
    printf '%s\n' 'pdns-data-standard PDNS_STANDARD_DIR' 'pdns-data-ssl PDNS_SSL_DIR' \
        'pdns-filter-state PDNS_FILTER_STATE_DIR' 'nats-data NATS_DATA_DIR' \
        'nats-conf NATS_CONF_DIR' 'logs-syslog-ng SYSLOG_NG_LOG_DIR'
}

# What: "volume dir" per row of quickstart_volume_keys
# Why: copy and postcondition read the same mapping
# From: Issue #1683 | PR #1858
quickstart_volume_dirs() {
    local env_file="$1" rows volume key dir
    rows=$(quickstart_volume_keys) || exit $?
    while read -r volume key; do
        dir=$(prod_state_dir_for_key "$key" "$env_file") || die "Cannot resolve the directory of $key (exit $?)."
        printf '%s %s\n' "$volume" "$dir"
    done <<< "$rows"
}

# What: a state key's dir: its value, else root/subdir
# Why: compose falls back to LANCACHE_STATE_DIR/<subdir>
# From: Issue #1683 | PR #1858
prod_state_dir_for_key() {
    local key="$1" env_file="$2" state="${3:-}" dir sub
    dir=$(get_env_var "$key" "$env_file") || die "Cannot read $key from $env_file (exit $?)."
    if [[ -z "$dir" ]]; then
        [[ -n "$state" ]] || state=$(get_env_var LANCACHE_STATE_DIR "$env_file") \
            || die "Cannot read LANCACHE_STATE_DIR from $env_file (exit $?)."
        [[ -n "$state" ]] || die "$env_file sets no LANCACHE_STATE_DIR."
        sub=$(prod_state_subdir "$key") || die "Cannot read the default directory of $key (exit $?)."
        dir="$state/$sub"
    fi
    printf '%s\n' "$dir"
}

# What: a checkout root resolves to deploy/prod
# Why: commands default to the checkout root
# From: Issue #1683 | PR #1858
resolve_stack_dir() {
    local dir="$1"
    if [[ ! -f "$dir/docker-compose.yml" && -f "$dir/deploy/prod/docker-compose.yml" ]]; then
        printf '%s\n' "$dir/deploy/prod"
    else
        printf '%s\n' "$dir"
    fi
}

# What: true for a quickstart copy outside deploy/prod
# Why: these installs must converge to deploy/prod on update
# From: Issue #1683 | PR #1858
is_quickstart_install() {
    local dir="$1"
    ! is_deploy_prod_install_dir "$dir" && [[ -f "$dir/docker-compose.yml" && -f "$PROD_COMPOSE" ]]
}

# What: converts a quickstart install into deploy/prod
# Why: AG-KD-008 one profile; AG-OP-007 convergence
# From: Issue #1683 | PR #1858
migrate_quickstart_install() (
    local old_dir="$1" stack_dir="${PROD_COMPOSE%/*}" env_local old_env record project key value volume dir copy f
    local services old_volumes prod_volumes rows missing copies keys old_raw new_raw old_value line path_keys bundle
    local -a service_list copy_lines
    path_keys=$(quickstart_path_keys) || exit $?
    path_keys="${path_keys//$'\n'/ }"
    bundle=$(quickstart_bundle_copies) || exit $?
    env_local="$stack_dir/.env.local"
    old_env="$old_dir/.env"
    record="$old_dir/.quickstart-migration"
    [[ -f "$old_env" ]] || die "Cannot migrate $old_dir: $old_env is missing."
    print_step "Migrating the quickstart install at $old_dir to $stack_dir"
    # What: convergence paused for the whole migration
    # Why: the timer must not run compose mid-migration
    # From: Issue #1683 | PR #1858
    UPDATE_CONVERGENCE_PAUSED=0
    UPDATE_CONVERGENCE_COMPLETED=0
    trap resume_lancache_convergence_after_failed_update EXIT
    UPDATE_CONVERGENCE_PAUSED=1
    pause_lancache_convergence_for_update
    _UPDATE_ENV_FILE="$old_env" _UPDATE_STACK_DIR="$old_dir"
    services=$(stack_compose "$old_dir" "$old_env" config --services) \
        || die "Cannot list the services of $old_dir (exit $?); nothing was changed."
    mapfile -t service_list <<< "$services"
    capture_stack_health_baseline "${service_list[@]}"
    ( cmd_backup --config "$old_dir" ) \
        || die "Pre-migration backup of $old_dir failed; nothing was changed."
    project=$(compose_project_name "$old_dir" "$old_env") \
        || die "Cannot resolve the compose project of $old_dir (exit $?); nothing was changed."
    # What: every quickstart volume has a home in prod
    # Why: data without a target would be left behind
    # From: Issue #1683 | PR #1858
    old_volumes=$(stack_compose "$old_dir" "$old_env" config --volumes) \
        || die "Cannot list the volumes of $old_dir (exit $?); nothing was changed."
    prod_volumes=$(stack_compose "$stack_dir" "$old_env" config --volumes) \
        || die "Cannot list the volumes of $PROD_COMPOSE (exit $?); nothing was changed."
    rows=$(quickstart_volume_keys) || exit $?
    missing=""
    while IFS= read -r volume; do
        [[ -n "$volume" ]] || continue
        grep -qxF -- "$volume" <<< "$prod_volumes" && continue
        awk -v v="$volume" '$1 == v { f = 1 } END { exit !f }' <<< "$rows" && continue
        missing+=" $volume"
    done <<< "$old_volumes"
    [[ -z "$missing" ]] || die "Quickstart volume(s)${missing} have no home in $PROD_COMPOSE; nothing was changed."
    stack_compose "$old_dir" "$old_env" stop \
        || die "Failed to stop the quickstart stack in $old_dir (exit $?); nothing was changed."
    if [[ ! -f "$env_local" ]]; then
        install -m 0600 "$old_env" "$env_local" || die "Failed to create $env_local from $old_env."
    fi
    if ! env_key_exists LANCACHE_STATE_DIR "$env_local"; then
        set_env_key LANCACHE_STATE_DIR "$old_dir" "$env_local"
    fi
    # What: relative paths become absolute to old dir
    # Why: prod resolves them against deploy/prod instead
    # From: Issue #1683 | PR #1858
    for key in $path_keys; do
        value=$(get_env_var "$key" "$env_local") || die "Cannot read $key from $env_local (exit $?)."
        [[ -n "$value" && "$value" != /* ]] || continue
        set_env_key "$key" "$(realpath -m "$old_dir/$value")" "$env_local"
    done
    copies=$(quickstart_volume_dirs "$env_local") \
        || die "Cannot resolve the state directories of $env_local (exit $?)."
    mapfile -t copy_lines <<< "$copies"
    for line in "${copy_lines[@]}"; do
        copy_volume_to_dir "${project}_${line%% *}" "${line#* }" "$record"
    done
    # What: prod uses the CA the quickstart clients trust
    # Why: another CA would break every client's TLS trust
    # From: Issue #1683 | PR #1858
    if [[ -f "$old_dir/certs/ca.crt" ]]; then
        if [[ ! -f "$SCRIPT_DIR/certs/ca.crt" ]]; then
            mkdir -p "$SCRIPT_DIR/certs" && cp -p "$old_dir/certs/ca."* "$SCRIPT_DIR/certs/" \
                || die "Failed to copy the CA from $old_dir/certs to $SCRIPT_DIR/certs."
        fi
        for f in "$old_dir/certs/ca."*; do
            cmp -- "$f" "$SCRIPT_DIR/certs/${f##*/}" \
                || die "Postcondition failed: $SCRIPT_DIR/certs/${f##*/} is not the CA file of $old_dir; nothing counts as migrated."
        done
    fi
    # What: every quickstart setting reaches .env.local
    # Why: changed secrets or IPs break running clients
    # From: Issue #1683 | PR #1858
    keys=$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ {print $1}' "$old_env") \
        || die "Failed to list the keys of $old_env (exit $?)."
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        if [[ " $path_keys " == *" $key "* ]]; then
            old_value=$(get_env_var "$key" "$old_env") || die "Cannot read $key from $old_env (exit $?)."
            new_raw=$(get_env_var "$key" "$env_local") || die "Cannot read $key from $env_local (exit $?)."
            [[ -z "$old_value" || "$old_value" == /* ]] || old_value=$(realpath -m "$old_dir/$old_value")
            [[ "$new_raw" == "$old_value" ]] && continue
        else
            old_raw=$(get_env_assignment_value_raw "$key" "$old_env") || die "Cannot read $key from $old_env (exit $?)."
            new_raw=$(get_env_assignment_value_raw "$key" "$env_local") || die "Cannot read $key from $env_local (exit $?)."
            [[ "$new_raw" == "$old_raw" ]] && continue
        fi
        die "Postcondition failed: $key in $env_local differs from $old_env; nothing counts as migrated."
    done <<< "$keys"
    _UPDATE_ENV_FILE="$env_local" _UPDATE_STACK_DIR="$stack_dir"
    validate_compose_config "$stack_dir"
    local apply_rc=0
    apply_stack_update_ordered "$stack_dir" rollback_quickstart_migration "$old_dir" "$record" || apply_rc=$?
    if [[ "$apply_rc" -eq 2 ]]; then
        trap - EXIT
        UPDATE_CONVERGENCE_COMPLETED=1
        die_convergence_kept_paused "The migrated stack failed its health gate, and restarting the quickstart stack in $old_dir failed too."
    fi
    [[ "$apply_rc" -eq 0 ]] \
        || die "The migrated stack failed its health gate; the quickstart stack in $old_dir runs again and nothing counts as migrated. Fix the cause, then rerun setup.sh update."
    if systemd_available; then
        write_lancache_systemd_units "$stack_dir"
    fi
    printf 'completed|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$record" \
        || die "Failed to record the completed migration in $record (exit $?)."
    # What: bundle removed last; its absence marks done
    # Why: an interrupted run resumes on the next update
    # From: Issue #1683 | PR #1858
    while IFS= read -r copy; do
        rm -f "$old_dir/$copy" || die "Failed to remove the quickstart copy $old_dir/$copy."
    done <<< "$bundle"
    rm -f "$old_dir/docker-compose.yml" "$old_env" || die "Failed to remove the quickstart files in $old_dir."
    trap - EXIT
    resume_lancache_convergence_after_update
    UPDATE_CONVERGENCE_COMPLETED=1
    print_ok "Quickstart install migrated to $stack_dir; its old Docker volumes were kept"
)

# What: stops prod, moves copies aside, restarts quickstart
# Why: a failed migration must leave the old install running
# From: Issue #1683 | PR #1858
rollback_quickstart_migration() {
    local old_dir="$1" record="$2" stamp copies dir
    print_warn "Rolling back the migration; restarting the quickstart stack in $old_dir"
    stack_compose "$_UPDATE_STACK_DIR" "$_UPDATE_ENV_FILE" stop \
        || { print_error "Failed to stop the migrated stack (exit $?). Manual recovery required."; return 1; }
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    copies=$(awk -F'|' '$1 == "rolledback" { delete c } $1 == "copied" { c[$3] = 1 } END { for (d in c) print d }' "$record") \
        || { print_error "Failed to read $record (exit $?). Manual recovery required."; return 1; }
    while IFS= read -r dir; do
        [[ -n "$dir" && -e "$dir" ]] || continue
        mv -- "$dir" "$dir.rolledback-$stamp" \
            || { print_error "Failed to move $dir aside (exit $?). Manual recovery required."; return 1; }
        print_warn "Moved the migrated copy $dir aside to $dir.rolledback-$stamp"
    done <<< "$copies"
    printf 'rolledback|%s\n' "$stamp" >> "$record" \
        || { print_error "Failed to record the rollback in $record (exit $?). Manual recovery required."; return 1; }
    stack_compose "$old_dir" "$old_dir/.env" up -d \
        || { print_error "Failed to restart the quickstart stack in $old_dir (exit $?). Manual recovery required."; return 1; }
    print_ok "The quickstart stack in $old_dir runs again"
}

# What: writes the four lancache systemd units
# Why: fresh install and migration share one unit definition
# From: Issue #1683 | PR #1858
write_lancache_systemd_units() {
    local stack_dir="$1" setup_sh="$SCRIPT_DIR/setup.sh"
    # What: units run compose through setup.sh at run time
    # Why: overrides may change after the unit is written
    # From: Issue #1683 | PR #1858
    local compose="${setup_sh} compose ${stack_dir}"
    cat > "$SYSTEMD_UNIT_DIR/$STACK_UNIT" <<EOF || die "Failed to write $STACK_UNIT."
[Unit]
Description=LanCache-NG
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${stack_dir}
ExecStart=${compose} up -d
ExecStop=${compose} down
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    # What: reconcile (exit ignored), then converge
    # Why: a failed reconcile must not stop the drift repair
    # From: Issue #819
    cat > "$SYSTEMD_UNIT_DIR/$CONVERGE_SERVICE_UNIT" <<EOF || die "Failed to write $CONVERGE_SERVICE_UNIT."
[Unit]
Description=LanCache-NG Convergence Check
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=${stack_dir}
ExecStart=-${setup_sh} converge-reconcile ${stack_dir}
ExecStart=${compose} up -d --remove-orphans
EOF
    cat > "$SYSTEMD_UNIT_DIR/$CONVERGE_TIMER_UNIT" <<EOF || die "Failed to write $CONVERGE_TIMER_UNIT."
[Unit]
Description=LanCache-NG Convergence Timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=${CONVERGE_SERVICE_UNIT}

[Install]
WantedBy=timers.target
EOF
    # What: daily host-side update runs the on-disk setup.sh
    # Why: no container gets Docker socket write access
    # From: Issue #819
    cat > "$SYSTEMD_UNIT_DIR/$AUTO_UPDATE_SERVICE_UNIT" <<EOF || die "Failed to write $AUTO_UPDATE_SERVICE_UNIT."
[Unit]
Description=LanCache-NG Scheduled Automatic Update
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${stack_dir}
ExecStart=${setup_sh} auto-update ${stack_dir}
EOF
    # What: daily, spread over 1h, missed runs caught up
    # Why: installs must not all hit GHCR at the same minute
    # From: Issue #819
    cat > "$SYSTEMD_UNIT_DIR/$AUTO_UPDATE_TIMER_UNIT" <<EOF || die "Failed to write $AUTO_UPDATE_TIMER_UNIT."
[Unit]
Description=LanCache-NG Scheduled Automatic Update Timer

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
Unit=${AUTO_UPDATE_SERVICE_UNIT}

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload || die "systemctl daemon-reload failed."
}

# What: origin's default branch; else the SOT release branch
# Why: the local symref avoids a network call when it is set
# From: Issue #1683 | PR #1858
git_default_branch_name() {
    local repo_dir="$1" default_branch="" rc=0 remote ref

    default_branch=$(git -C "$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD) || rc=$?
    [[ "$rc" -le 1 ]] || die "Failed to read origin/HEAD of $repo_dir (exit $rc)."
    default_branch="${default_branch#origin/}"
    if [[ -z "$default_branch" ]]; then
        remote=$(git -C "$repo_dir" remote show origin) \
            || die "Failed to read the remote origin of $repo_dir (exit $?)."
        default_branch=$(awk '/HEAD branch/ && $NF != "(unknown)" {print $NF; exit}' <<< "$remote")
    fi
    if [[ -z "$default_branch" ]]; then
        ref=$(env -u CI_MANIFEST -u CI_REPO_ROOT bash "$repo_dir/.github/scripts/ci.sh" release-ref) \
            || die "Failed to read the release branch from the SOT of $repo_dir (exit $?); set LANCACHE_SETUP_GIT_REF."
        [[ "$ref" == refs/heads/?* ]] || die "The SOT of $repo_dir names no release branch ref: '$ref'."
        default_branch="${ref#refs/heads/}"
    fi

    printf '%s\n' "$default_branch"
}

# True if the working tree has no uncommitted changes (`git status --porcelain` is empty).
git_repo_is_clean() {
    local repo_dir="$1" out

    out=$(git -C "$repo_dir" status --porcelain) \
        || die "Failed to read the git status of $repo_dir (exit $?)."
    [[ -z "$out" ]]
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

# What: returns LANCACHE_SETUP_GIT_REF, empty if unset
# Why: unset keeps the default branch behavior
resolve_setup_bootstrap_ref() {
    printf '%s\n' "${LANCACHE_SETUP_GIT_REF:-}"
}

# What: hard-resets a checkout to a pinned ref
# Why: fetches the named ref explicitly; dirty trees refused
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

# What: existing repo paths compose reaches via ../../
# Why: rollback restores them; a hand list missed one mount
# From: Issue #1683 | PR #1858
deploy_prod_repo_input_paths() {
    local install_dir="$1" repo_root rels rel
    local -a composes
    is_deploy_prod_install_dir "$install_dir" || return 0
    repo_root=$(deploy_prod_repo_root "$install_dir") || exit $?
    composes=("$install_dir"/docker-compose*.y*ml)
    [[ -e "${composes[0]}" ]] || return 0
    rels=$(awk '!/^[[:space:]]*#/ {
            while (match($0, /\.\.\/\.\.\/[^:" ]+/)) { print substr($0, RSTART, RLENGTH); $0 = substr($0, RSTART + RLENGTH) }
        }' "${composes[@]}") || die "Failed to read the compose files of $install_dir (exit $?)."
    rels=$(sort -u <<< "$rels")
    while IFS= read -r rel; do
        [[ -n "$rel" && -e "$repo_root/${rel#../../}" ]] && printf '%s\n' "$repo_root/${rel#../../}"
    done <<< "$rels"
    true
}


# What: default of a key, read from deploy/prod/.env
# Why: one owner for the defaults compose maps
# From: Issue #1683 | PR #1858
prod_env_default() {
    local template="${PROD_COMPOSE%/*}/.env"
    env_key_exists "$1" "$template" || die "$template defines no default for $1."
    get_env_var "$1" "$template"
}

# What: adds each missing KEY with the deploy/prod default
# Why: an existing value stays, even an intentional empty
# From: Issue #1683 | PR #1858
append_env_defaults_if_missing() {
    local env_file="$1" key default
    shift
    for key in "$@"; do
        default=$(prod_env_default "$key") || die "Cannot read the default of $key (exit $?)."
        append_env_key_if_missing "$key" "$default" "$env_file"
    done
}

# What: fills each empty or missing KEY from deploy/prod
# Why: compose requires these keys to be non-empty
# From: Issue #1683 | PR #1858
set_env_defaults_if_empty_or_missing() {
    local env_file="$1" key default
    shift
    for key in "$@"; do
        default=$(prod_env_default "$key") || die "Cannot read the default of $key (exit $?)."
        set_env_key_if_empty_or_missing "$key" "$default" "$env_file"
    done
}

# What: fills keys whose only value owner is deploy/prod
# Why: install and update share one list; no value copies
# From: Issue #1683 | PR #1858
set_template_owned_env_defaults() {
    set_env_defaults_if_empty_or_missing "$1" CACHE_SLICE_SIZE CACHE_VALID_HIT CACHE_VALID_ANY \
        CACHE_INACTIVE NGINX_UPSTREAM_RESOLVER PROXY_SECURITY_MODE KEA_CONFIG_SNAPSHOT_DIR
    append_env_defaults_if_missing "$1" PROXY_ALLOWED_CLIENT_CIDRS
}

# What: "svc KEY [TARGET]" rows moved out of config/prod
# Why: compose maps these per service from the .env now
# From: Issue #1683 | PR #1858
config_prod_moved_keys() {
    printf '%s\n' 'dns-standard PROXY_IP IP_STANDARD' 'dns-ssl PROXY_IP IP_SSL' 'watchdog SSL_ENABLED' \
        'proxy CACHE_MAX_SIZE' 'proxy CACHE_MEM_MB' 'proxy CACHE_SLICE_SIZE' 'proxy CACHE_VALID_HIT' \
        'proxy CACHE_VALID_ANY' 'proxy CACHE_INACTIVE' 'proxy NGINX_UPSTREAM_RESOLVER' \
        'proxy PROXY_SECURITY_MODE' 'proxy PROXY_ALLOWED_CLIENT_CIDRS' 'dhcp DHCP_SUBNET' \
        'dhcp DHCP_RANGE_START' 'dhcp DHCP_RANGE_END' 'dhcp DHCP_GATEWAY' 'dhcp-proxy DHCP_SUBNET_START' \
        'dhcp-proxy DHCP_DNS_PRIMARY' 'dhcp-proxy DHCP_DNS_SECONDARY' 'dhcp-proxy UPSTREAM_DHCP_IP' \
        'dhcp-proxy DHCP_RELAY_LOCAL_ADDR' 'dhcp-proxy DHCP_PROXY_INTERFACE' 'dhcp-proxy DHCP_PROXY_ROUTER' \
        'dhcp-proxy DHCP_NTP_SERVERS' 'dhcp-proxy DHCP_PROXY_DOMAIN' 'dhcp-proxy DHCP_PROXY_BOOT_FILENAME' \
        'dhcp-proxy DHCP_PROXY_BOOT_SERVER' 'dhcp-proxy DHCP_PROXY_CUSTOM_OPTIONS' \
        'dhcp-proxy DHCP_PROXY_PXE_BOOT_SERVER' 'dhcp-proxy DHCP_PROXY_PXE_BOOT_FILENAME_BIOS' \
        'dhcp-proxy DHCP_PROXY_PXE_BOOT_FILENAME_UEFI'
}

# What: moves those keys from <svc>.local.env to the .env
# Why: compose environment would shadow them silently
# From: Issue #1683 | PR #1858
adopt_moved_config_prod_keys() {
    local install_dir="$1" env_file="$2" step="$3" repo_root rows svc key target local_env raw current
    is_deploy_prod_install_dir "$install_dir" || return 0
    repo_root=$(deploy_prod_repo_root "$install_dir") \
        || die "Cannot resolve the repository root of $install_dir (exit $?)."
    rows=$(config_prod_moved_keys)
    # What: copy runs in the update, drop after it succeeds
    # Why: a failed update must never lose an operator value
    # From: Issue #1683 | PR #1858
    while read -r svc key target; do
        local_env="$repo_root/config/prod/$svc.local.env"
        env_key_exists "$key" "$local_env" || continue
        if [[ "$step" = drop ]]; then
            remove_env_key "$key" "$local_env"
            print_ok "Moved $key from ${local_env##*/} into ${env_file##*/}${target:+ as $target}"
            continue
        fi
        raw=$(get_env_assignment_value_raw "$key" "$local_env") \
            || die "Cannot read $key from $local_env (exit $?)."
        if [[ -z "$target" ]]; then
            set_env_assignment "$key" "$raw" "$env_file"
            continue
        fi
        current=$(get_env_assignment_value_raw "$target" "$env_file") \
            || die "Cannot read $target from $env_file (exit $?)."
        [[ "$raw" == "$current" ]] \
            || die "$key=$raw in $local_env differs from $target=$current in $env_file; both must be the same address. Set $target, remove $key from $local_env, then rerun setup.sh update."
    done <<< "$rows"
}

# What: template edits move into <x>.local.env, newest wins
# Why: edits survive (AG-OP-009); checkout stays syncable
# From: Issue #1683 | PR #1858
adopt_config_prod_edits() {
    local repo_root="$1" rel template local_env key raw head_raw head list in_head keys
    local -a changed
    [[ -e "$repo_root/.git" ]] || return 0
    list=$(git -C "$repo_root" diff --name-only HEAD -- 'config/prod/*.env') \
        || die "Failed to list edited config/prod files in $repo_root (exit $?)."
    mapfile -t changed <<< "$list"
    for rel in "${changed[@]}"; do
        [[ -n "$rel" && "$rel" != *.local.env ]] || continue
        template="$repo_root/$rel"
        local_env="${template%.env}.local.env"
        in_head=$(git -C "$repo_root" ls-tree --name-only HEAD -- "$rel") \
            || die "Failed to look up $rel in HEAD of $repo_root (exit $?)."
        if [[ -z "$in_head" ]]; then
            print_warn "Leaving $rel unchanged: it is not part of the checkout"
            continue
        fi
        head=$(git -C "$repo_root" show "HEAD:$rel") \
            || die "Failed to read HEAD:$rel in $repo_root (exit $?)."
        if [[ ! -e "$template" ]]; then
            print_warn "Restoring $rel, which was deleted locally"
        else
            keys=$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ {print $1}' "$template") \
                || die "Failed to list the keys of $template (exit $?)."
            while IFS= read -r key; do
                [[ -n "$key" ]] || continue
                raw=$(get_env_assignment_value_raw "$key" "$template") \
                    || die "Cannot read $key from $template (exit $?)."
                head_raw=$(get_env_assignment_value_raw "$key" /dev/stdin <<< "$head") \
                    || die "Cannot read $key from HEAD:$rel (exit $?)."
                if [[ "$raw" != "$head_raw" ]] || ! env_key_exists "$key" /dev/stdin <<< "$head"; then
                    set_env_assignment "$key" "$raw" "$local_env"
                fi
            done <<< "$keys"
        fi
        git -C "$repo_root" checkout HEAD -- "$rel" \
            || die "Failed to restore $rel after moving its edits to ${local_env##*/}."
        print_ok "Moved local edits of $rel into ${local_env##*/}"
    done
}

# What: writes stdin via a same-dir temp file and a rename
# Why: a torn write or a stray temp file must never remain
# From: Issue #1683 | PR #1858
write_file_atomically() (
    target="$1"
    dir=$(dirname "$target")
    tmp=$(mktemp "$dir/.$(basename "$target").tmp.XXXXXX") \
        || die "Failed to create a temporary file in $dir (exit $?)."
    trap 'rm -f -- "$tmp"' EXIT
    # What: an existing file keeps its owner and mode
    # Why: env files hold tokens and may be locked to 0600
    # From: Issue #1683 | PR #1858
    if [[ -f "$target" ]]; then
        chown --reference="$target" "$tmp" || die "Failed to preserve the owner of $target (exit $?)."
        chmod --reference="$target" "$tmp" || die "Failed to preserve the mode of $target (exit $?)."
    else
        chmod 0600 "$tmp" || die "Failed to restrict $tmp (exit $?)."
    fi
    cat > "$tmp" || die "Failed to write the temporary file for $target (exit $?)."
    mv -- "$tmp" "$target" || die "Failed to replace $target (exit $?)."
)

# What: replaces every literal copy of a string in a file
# Why: sed reads a path as regex; #, & or \ break it
# From: Issue #1683 | PR #1858
replace_literal_in_file() {
    local file="$1"
    [[ -n "$2" ]] || die "Refusing to replace an empty string in $file."
    OLD_TEXT="$2" NEW_TEXT="$3" awk '{
        old = ENVIRON["OLD_TEXT"]; new = ENVIRON["NEW_TEXT"]; out = ""
        while ((i = index($0, old)) > 0) { out = out substr($0, 1, i - 1) new; $0 = substr($0, i + length(old)) }
        print out $0
    }' "$file" | write_file_atomically "$file" \
        || die "Failed to rewrite $file (exit $?)."
}

# Update-time guard: dies with a clear remediation message if a required key
# is missing or empty, instead of letting `setup.sh update` silently proceed
# with an unusable runtime configuration.
require_env_value_for_update() {
    local key="$1" env_file="$2"
    env_key_has_value "$key" "$env_file" \
        || die "$key is missing or empty in $env_file. Set it before running setup.sh update."
}

# What: IP_STANDARD and IP_SSL are two valid, distinct IPv4s
# Why: dns-standard and dns-ssl bind apart (AG-SETUP-001)
# From: Issue #1683 | PR #1858
require_separate_lan_ips() {
    is_valid_ipv4 "$1" || die "IP_STANDARD is not a valid IPv4 address: $1"
    is_valid_ipv4 "$2" || die "IP_SSL is not a valid IPv4 address: $2"
    [[ "$1" != "$2" ]] || die "Standard IP and SSL IP must be different."
}

# What: sets a secret only if no usable value exists
# Why: an operator's real secret is never overwritten
ensure_secret_env_key() {
    local key="$1" env_file="$2" kind="$3" value
    if env_key_has_usable_secret "$key" "$env_file"; then
        return 0
    fi

    value=$(generate_secret_value "$key" "$kind") || exit $?
    set_env_key "$key" "$value" "$env_file"
    print_ok "Generated missing or placeholder secret: $key"
}

# What: "50g"/"50G"/"50" as bare GB; rc 1 if not a number
# Why: callers pick the fallback from deploy/prod/.env
# From: Issue #1683 | PR #1858
cache_size_gb_from_env() {
    local cache_max_size="$1"
    cache_max_size="${cache_max_size,,}"
    cache_max_size="${cache_max_size%g}"
    [[ "$cache_max_size" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$cache_max_size"
}

# What: dies unless this host's arch has an OCI platform
# Why: published platforms are the registry's; checked later
# From: Issue #1683 | PR #1858
assert_prebuilt_image_platform_supported() {
    local arch
    arch=$(uname -m)
    host_image_platform "$arch" > /dev/null \
        || die "This host's architecture '${arch}' has no container image platform; LanCache-NG cannot run here."
}

# What: `uname -m` to its OCI platform name (Docker naming)
# Why: the manifest check compares by OCI platform name
# From: Issue #1683 | PR #1858
host_image_platform() {
    case "$1" in
        x86_64|amd64) printf 'linux/amd64\n' ;;
        aarch64|arm64) printf 'linux/arm64\n' ;;
        armv7l|armv7) printf 'linux/arm/v7\n' ;;
        armv6l|armv6) printf 'linux/arm/v6\n' ;;
        i386|i686) printf 'linux/386\n' ;;
        ppc64le|s390x|riscv64) printf 'linux/%s\n' "$1" ;;
        *) return 1 ;;
    esac
}

# What: checks the resolved tag publishes this platform
# Why: a failure would surface only after .env was written
assert_resolved_image_tag_platform_supported() {
    local registry="$1" prefix="$2" tag="$3"
    local arch platform image single_platform inspect_text discovered_platforms buildx_out

    arch=$(uname -m)
    platform=$(host_image_platform "$arch") \
        || die "This host's architecture '${arch}' has no container image platform; LanCache-NG cannot run here."

    command -v docker >/dev/null 2>&1 \
        || die "docker is required to verify that image tag '${tag}' publishes a ${platform} image before continuing."
    buildx_out=$(docker buildx version 2>&1) \
        || die "docker buildx is required to verify that image tag '${tag}' publishes a ${platform} image before continuing (exit $?: ${buildx_out}). Install the docker-buildx-plugin package, then rerun setup.sh."

    image="${registry}/${prefix}/dns:${tag}"

    # shellcheck disable=SC2016 # Go template is evaluated by Docker, not the shell.
    single_platform=$(docker buildx imagetools inspect "$image" --format '{{if .Image}}{{.Image.OS}}/{{.Image.Architecture}}{{end}}' 2>&1) \
        || die "Failed to inspect ${image} to verify it publishes a ${platform} image (${single_platform}). Check network access and registry reachability, then rerun setup.sh."

    if [[ -n "$single_platform" && "$single_platform" != "<no value>/<no value>" && "$single_platform" != "unknown/unknown" ]]; then
        discovered_platforms="$single_platform"
    else
        inspect_text=$(docker buildx imagetools inspect "$image" 2>&1) \
            || die "Failed to inspect ${image} manifest to verify it publishes a ${platform} image (${inspect_text}). Check network access and registry reachability, then rerun setup.sh."
        discovered_platforms=$(printf '%s\n' "$inspect_text" | awk '$1 == "Platform:" && $2 != "unknown/unknown" { print $2 }' | sort -u)
    fi

    [[ -n "$discovered_platforms" ]] \
        || die "${image} did not expose any usable platform metadata; cannot verify ${platform} support for tag '${tag}'."

    # What: grep -q reads a here-string, not a live pipe.
    # Why: avoids SIGPIPE on multi-line platform lists
    # From: Issue #1377
    grep -Eq "^${platform}(/.*)?$" <<<"$discovered_platforms" \
        || die "Image tag '${tag}' does not publish a ${platform} image for this ${arch} host (published: $(printf '%s' "$discovered_platforms" | tr '\n' ',' | sed 's/,$//')). Choose a tag or channel that publishes ${platform}, then rerun setup.sh."
}

# What: true if systemctl exists and systemd runs as init
# Why: a systemctl binary alone fails without an init
systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

# What: true if systemctl knows the unit file
# Why: timer handling is a no-op without the units
systemd_unit_exists() {
    local unit="$1" out rc=0
    systemd_available || return 1
    out=$(systemctl list-unit-files --no-legend "$unit" 2>&1) || rc=$?
    [[ -n "$out" ]] || return 1
    [[ "$rc" -eq 0 ]] || die "Failed to look up the systemd unit $unit (exit $rc): $out"
}

CONVERGENCE_TIMER_WAS_ACTIVE=0
CONVERGENCE_TIMER_WAS_ENABLED=0
CONVERGENCE_SERVICE_WAS_ACTIVE=0
UPDATE_CONVERGENCE_PAUSED=0
UPDATE_CONVERGENCE_COMPLETED=0

# What: pauses the convergence timer and service for update
# Why: a running timer could start compose during migration
pause_lancache_convergence_for_update() {
    CONVERGENCE_TIMER_WAS_ACTIVE=0
    CONVERGENCE_TIMER_WAS_ENABLED=0
    CONVERGENCE_SERVICE_WAS_ACTIVE=0

    local timer_exists=0 service_exists=0
    systemd_unit_exists "$CONVERGE_TIMER_UNIT" && timer_exists=1
    systemd_unit_exists "$CONVERGE_SERVICE_UNIT" && service_exists=1
    if [[ "$timer_exists" = "0" && "$service_exists" = "0" ]]; then
        return 0
    fi

    if [[ "$timer_exists" = "1" ]] && systemctl is-active --quiet "$CONVERGE_TIMER_UNIT"; then
        CONVERGENCE_TIMER_WAS_ACTIVE=1
        print_step "Pausing convergence timer"
        systemctl stop "$CONVERGE_TIMER_UNIT" \
            || die "Failed to stop $CONVERGE_TIMER_UNIT before update."
    fi

    if [[ "$service_exists" = "1" ]] && systemctl is-active --quiet "$CONVERGE_SERVICE_UNIT"; then
        CONVERGENCE_SERVICE_WAS_ACTIVE=1
        print_step "Stopping active convergence service"
        systemctl stop "$CONVERGE_SERVICE_UNIT" \
            || die "Failed to stop $CONVERGE_SERVICE_UNIT before update."
        if systemctl is-active --quiet "$CONVERGE_SERVICE_UNIT"; then
            die "$CONVERGE_SERVICE_UNIT is still active after stop; refusing to update concurrently."
        fi
    fi

    if [[ "$timer_exists" = "1" ]] && systemctl is-enabled --quiet "$CONVERGE_TIMER_UNIT"; then
        CONVERGENCE_TIMER_WAS_ENABLED=1
        systemctl disable "$CONVERGE_TIMER_UNIT" >/dev/null \
            || die "Failed to disable $CONVERGE_TIMER_UNIT before update."
    fi
}

# What: restores units that were active or enabled
# Why: keeps manual operator choices intact
resume_lancache_convergence_after_update() {
    local restart_service="${1:-false}"

    if [[ "$restart_service" = "true" ]] \
        && [[ "$CONVERGENCE_SERVICE_WAS_ACTIVE" = "1" ]] \
        && systemd_unit_exists "$CONVERGE_SERVICE_UNIT"; then
        systemctl start "$CONVERGE_SERVICE_UNIT" \
            || die "Failed to restart $CONVERGE_SERVICE_UNIT after failed pre-mutation update."
    fi

    if ! systemd_unit_exists "$CONVERGE_TIMER_UNIT"; then
        return 0
    fi

    if [[ "$CONVERGENCE_TIMER_WAS_ENABLED" = "1" ]]; then
        systemctl enable "$CONVERGE_TIMER_UNIT" >/dev/null \
            || die "Failed to re-enable $CONVERGE_TIMER_UNIT after update."
    fi

    if [[ "$CONVERGENCE_TIMER_WAS_ACTIVE" = "1" ]]; then
        systemctl start "$CONVERGE_TIMER_UNIT" \
            || die "Failed to restart $CONVERGE_TIMER_UNIT after update."
    fi
}

# What: EXIT trap resumes convergence after a failed update
# Why: a failed run must not leave the timer stopped
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

# What: dies; convergence stays paused, prints how to resume
# Why: a timer `compose up` must not race manual recovery
# From: Issue #1683 | PR #1858
die_convergence_kept_paused() {
    local resume=""
    [[ "$CONVERGENCE_TIMER_WAS_ENABLED" = "1" ]] && resume="systemctl enable $CONVERGE_TIMER_UNIT"
    [[ "$CONVERGENCE_TIMER_WAS_ACTIVE" = "1" ]] && resume="${resume:+$resume && }systemctl start $CONVERGE_TIMER_UNIT"
    die "$1 Manual recovery required.${resume:+ Convergence stays paused; after recovery run: $resume}"
}

# What: validates the image tag before any compose pull
# Why: mutable channels must resolve to one immutable tag
validate_lancache_image_tag() {
    local tag="$1"

    case "$tag" in
        sha-*)
            [[ "$tag" =~ ^sha-[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] \
                || die "LANCACHE_IMAGE_TAG must be a valid sha-* image tag."
            return 0
            ;;
        pr-*)
            # What: pr-<N>-sha-<full> CI tags are accepted
            # Why: CI simulation installs a pinned PR build
            [[ "$tag" =~ ^pr-[0-9]+-sha-[0-9a-fA-F]{7,}$ ]] \
                || die "LANCACHE_IMAGE_TAG pr-* staging tags must match pr-<number>-sha-<commit>."
            return 0
            ;;
    esac

    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] \
        || die "LANCACHE_IMAGE_TAG must be an immutable sha-* tag or a vX.Y.Z / vX.Y.Z-rc.N release tag."
}

# What: accepts stable, latest, nightly and pinned channels
# Why: edge and dev are hard cuts, not aliases
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

# What: derives vX.Y.Z[-rc.N] from git tag or VERSION file
# Why: rc 1 means no tag; rc 2 means found but malformed
derive_release_archive_image_tag() {
    local version tag tags git_stderr git_status
    local -a safe_dir_opt=()

    # What: a .git entry means a real git checkout
    # Why: git errors must not read as no checkout
    if [[ -e "$SCRIPT_DIR/.git" ]]; then
        if git_stderr=$(git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree 2>&1 1>/dev/null); then
            git_status=0
        else
            git_status=$?
        fi

        if [[ "$git_status" -ne 0 ]]; then
            if [[ "$git_stderr" == *"detected dubious ownership"* ]]; then
                # What: trusts the path git names on stderr
                # Why: bind mounts trigger dubious ownership
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
            if ! tags=$(git "${safe_dir_opt[@]}" -C "$SCRIPT_DIR" tag --points-at HEAD); then
                printf 'Failed to list the tags at HEAD of %s.\n' "$SCRIPT_DIR" >&2
                return 2
            fi
            [[ -n "$tags" ]] || return 1
            tag=$(awk '/^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$/' <<< "$tags")
            if [[ -z "$tag" ]]; then
                printf 'Invalid release tag from git checkout: %s\n' "${tags//$'\n'/ }" >&2
                return 2
            fi
            if [[ "$tag" == *$'\n'* ]]; then
                printf 'Several release tags point at HEAD: %s\n' "${tag//$'\n'/ }" >&2
                return 2
            fi
            printf '%s\n' "$tag"
            return 0
        fi
        # What: falls through to the VERSION file
        # Why: git still refuses the .git after the retry
    fi

    [[ -f "$SCRIPT_DIR/VERSION" ]] || return 1
    version=$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION") || die "Failed to read $SCRIPT_DIR/VERSION (exit $?)."
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
        registry=$(get_env_var LANCACHE_IMAGE_REGISTRY "$env_file") || exit $?
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
        prefix=$(get_env_var LANCACHE_IMAGE_PREFIX "$env_file") || exit $?
    fi

    prefix="${prefix:-wiki-mod/lancache-ng}"
    validate_lancache_image_prefix "$prefix"
    printf '%s\n' "$prefix"
}

# What: picks the channel from env, tag, or derived release
# Why: untagged installs default to latest, never nightly
resolve_lancache_image_channel() {
    local env_file="${1:-}" channel="${LANCACHE_IMAGE_CHANNEL:-}" tag="${LANCACHE_IMAGE_TAG:-}" release_tag=""

    if [[ -z "$channel" && -n "$env_file" && -f "$env_file" ]]; then
        channel=$(get_env_var LANCACHE_IMAGE_CHANNEL "$env_file") || exit $?
    fi

    if [[ -z "$tag" && -n "$env_file" && -f "$env_file" ]]; then
        tag=$(get_env_var LANCACHE_IMAGE_TAG "$env_file") || exit $?
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

    # What: falls back to latest when nothing is configured
    # Why: latest is the name that has always existed
    channel="${channel:-latest}"
    validate_lancache_image_channel "$channel"
    printf '%s\n' "$channel"
}

# What: maps stable to latest, other channels pass through
# Why: no stack:stable tag exists; both names publish alike
lancache_stack_pointer_channel_for() {
    local channel="$1"
    if [[ "$channel" = "stable" ]]; then
        printf 'latest\n'
    else
        printf '%s\n' "$channel"
    fi
}

# What: ref variable and slug of each first-party image
# Why: the prod compose owns the service-to-image mapping
# From: Issue #1683 | PR #1858
lancache_image_ref_vars() {
    local vars
    vars=$(sed -nE 's/^ *image: \$\{(LANCACHE_IMAGE_REF_[A-Z_]+):-.*\/([a-z0-9-]+):\$\{LANCACHE_IMAGE_TAG.*$/\1 \2/p' "$PROD_COMPOSE" | sort -u) \
        || die "Failed to read the first-party image refs from $PROD_COMPOSE."
    [[ -n "$vars" ]] || die "$PROD_COMPOSE declares no LANCACHE_IMAGE_REF_* image; cannot pin a channel."
    printf '%s\n' "$vars"
}

# What: one value of a CI SOT block (default ci_variables)
# Why: installer reads CI-owned values, never copies
# From: Issue #1683 | PR #1858
lancache_sot_value() {
    local key="$1" block="${2:-ci_variables}" sot="$SCRIPT_DIR/.github/yaml/build-manifest.yml" value
    value=$(awk -v b="${block}:" -v k="  ${key}:" '
        $0 == b { f = 1; next }
        f && /^[^ #]/ { exit }
        f && index($0, k) == 1 {
            v = substr($0, length(k) + 1); sub(/^ +/, "", v); sub(/^"/, "", v); sub(/"$/, "", v)
            print v; exit
        }' "$sot") \
        || die "Failed to read ${block}.${key} from ${sot}."
    [[ -n "$value" ]] || die "${sot} defines no ${block}.${key}."
    printf '%s\n' "$value"
}

# What: sets the helper image to the SOT's pinned alpine
# Why: AG-CI-008: one owner, never a mutable alpine tag
# From: Issue #1683 | PR #1858
require_helper_image() {
    [[ -z "$LANCACHE_HELPER_IMAGE" ]] || return 0
    LANCACHE_HELPER_IMAGE=$(lancache_sot_value alpine base_images) || exit $?
    [[ "$LANCACHE_HELPER_IMAGE" == *@sha256:* ]] \
        || die "base_images.alpine in the SOT is not digest-pinned: $LANCACHE_HELPER_IMAGE"
}

# What: true while the channel's promote lock ref exists
# Why: promote moves every channel tag inside this lock
# From: Issue #1683 | PR #1858
lancache_promote_lock_held() {
    local lock_ref="$1" out
    out=$(git -C "$SCRIPT_DIR" ls-remote origin "$lock_ref") \
        || die "Failed to read the promote lock ${lock_ref} from origin (exit $?). A channel install needs the git checkout's origin; set LANCACHE_IMAGE_CHANNEL=pinned with a vX.Y.Z tag otherwise."
    [[ -n "$out" ]]
}

# What: VAR=<image>@<digest> per image, one registry pass
# Why: each image of the channel pinned to its digest
# From: Issue #1683 | PR #1858
lancache_channel_ref_pass() {
    local registry="$1" prefix="$2" pointer_channel="$3" vars="$4" var slug ref digest
    while read -r var slug; do
        ref="${registry}/${prefix}/${slug}:${pointer_channel}"
        if ! digest=$(docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}' 2>&1); then
            if [[ "$pointer_channel" = "latest" ]]; then
                cat >&2 <<EOF

${RED}✗${RESET} Cannot resolve the 'stable' release channel (published as the 'latest' pointer image).

This project is currently in active development (pre-1.0). While images are published
to the 'nightly' testing channel from current_dev (built once daily plus on-demand,
gated on a full green build+scan), a formal stable release with a published
'latest'/'stable' channel tag has not yet been created.

To proceed, choose one of these options:

  1. Use the 'nightly' testing channel (pre-release, may change frequently):
     LANCACHE_IMAGE_CHANNEL=nightly ./setup.sh install

  2. Pin to a specific release version or commit (immutable):
     LANCACHE_IMAGE_TAG=vX.Y.Z ./setup.sh install        # once a stable release is tagged
     LANCACHE_IMAGE_TAG=sha-abc1234 ./setup.sh install   # specific commit build

For details on release channels and their stability, see:
  docs/release-versioning.md

EOF
                die "Cannot resolve the stable channel image ${ref} (${digest})."
            fi
            die "Failed to resolve ${ref} to a digest (${digest}). Check registry access or set LANCACHE_IMAGE_TAG to an immutable sha-* / vX.Y.Z tag."
        fi
        [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
            || die "${ref} returned an invalid digest: ${digest:-<empty>}."
        printf '%s=%s/%s/%s@%s\n' "$var" "$registry" "$prefix" "$slug" "$digest"
    done <<< "$vars"
}

# What: lock-free, twice-identical channel refs, else retry
# Why: a promote between reads must not mix a stack
# From: Issue #1683 | PR #1858
lancache_channel_image_refs() {
    local env_file="$1" channel="$2"
    local registry prefix pointer_channel vars max backoff lock_ref buildx_out n=1 first second reason line changed
    pointer_channel=$(lancache_stack_pointer_channel_for "$channel") || exit $?
    registry=$(resolve_lancache_image_registry "$env_file") \
        || die "Cannot resolve the image registry for channel ${channel} (exit $?)."
    prefix=$(resolve_lancache_image_prefix "$env_file") \
        || die "Cannot resolve the image prefix for channel ${channel} (exit $?)."
    vars=$(lancache_image_ref_vars) \
        || die "Cannot list the first-party images for channel ${channel} (exit $?)."
    max=$(lancache_sot_value CI_PROMOTE_LOCK_MAX) \
        || die "Cannot read CI_PROMOTE_LOCK_MAX (exit $?)."
    backoff=$(lancache_sot_value CI_PROMOTE_LOCK_BACKOFF) \
        || die "Cannot read CI_PROMOTE_LOCK_BACKOFF (exit $?)."
    lock_ref=$(lancache_sot_value CI_PROMOTE_LOCK_REF) \
        || die "Cannot read CI_PROMOTE_LOCK_REF (exit $?)."
    lock_ref="${lock_ref}/${pointer_channel}"

    command -v docker >/dev/null \
        || die "Docker is required to resolve LANCACHE_IMAGE_CHANNEL=${channel}."
    buildx_out=$(docker buildx version 2>&1) \
        || die "docker buildx is required to resolve LANCACHE_IMAGE_CHANNEL=${channel} (exit $?: ${buildx_out}). Install the docker-buildx-plugin package, then rerun setup.sh."

    printf "\n${BOLD}${CYAN}▶ Resolving image channel %s${RESET}\n" "$channel" >&2
    while [[ "$n" -le "$max" ]]; do
        reason="promote lock ${lock_ref} is held"
        if ! lancache_promote_lock_held "$lock_ref"; then
            first=$(lancache_channel_ref_pass "$registry" "$prefix" "$pointer_channel" "$vars") \
                || die "First read of channel ${channel} failed (exit $?)."
            if ! lancache_promote_lock_held "$lock_ref"; then
                second=$(lancache_channel_ref_pass "$registry" "$prefix" "$pointer_channel" "$vars") \
                    || die "Second read of channel ${channel} failed (exit $?)."
                if ! lancache_promote_lock_held "$lock_ref"; then
                    if [[ "$first" == "$second" ]]; then
                        printf '%s\n' "$first"
                        return 0
                    fi
                    changed=""
                    while IFS= read -r line; do
                        [[ $'\n'"$first"$'\n' == *$'\n'"$line"$'\n'* ]] || changed+=" ${line}"
                    done <<< "$second"
                    reason="digests changed between two reads:${changed}"
                fi
            fi
        fi
        print_warn "Channel ${channel}: ${reason}; retry in ${backoff}s (${n}/${max})." >&2
        sleep "$backoff"
        n=$((n + 1))
    done
    die "Channel ${channel}: ${reason}; no consistent stack after ${max} attempts."
}

# What: short fingerprint of a set of image pins, or empty
# Why: auto-update compares stack states, not channel words
# From: Issue #1683 | PR #1858
lancache_image_refs_fingerprint() {
    local refs="$1" sum
    [[ -n "$refs" ]] || return 0
    sum=$(LC_ALL=C sort <<< "$refs" | sha256sum) || die "Failed to fingerprint the image pins (exit $?)."
    printf 'refs-%s\n' "${sum:0:12}"
}

# What: image pins for a resolved tag; none for a fixed tag
# Why: resolve before writing; a failure changes nothing
# From: Issue #1683 | PR #1858
lancache_image_refs_for_tag() {
    local env_file="$1" tag="$2"
    case "$tag" in
        latest|nightly) lancache_channel_image_refs "$env_file" "$tag" ;;
        *) : ;;
    esac
}

# What: replaces all image pins in an env file
# Why: a stale channel pin must never shadow a chosen tag
# From: Issue #1683 | PR #1858
write_lancache_image_refs() {
    local env_file="$1" refs="$2" vars var line want current
    vars=$(lancache_image_ref_vars) \
        || die "Cannot list the first-party images to rewrite pins in ${env_file} (exit $?)."
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ $'\n'"$vars"$'\n' == *$'\n'"${line%%=*} "* ]] \
            || die "${line%%=*} is no first-party image pin of $PROD_COMPOSE; ${env_file} was not changed."
        validate_env_value "${line%%=*}" "${line#*=}"
    done <<< "$refs"
    while read -r var _; do
        current=$(<"$env_file") || die "Failed to read ${env_file} (exit $?)."
        want=""
        while IFS= read -r line; do
            [[ "${line%%=*}" != "$var" ]] || want="${line#*=}"
        done <<< "$refs"
        if [[ -z "$want" ]]; then
            remove_env_key "$var" "$env_file" \
                || die "Failed to remove ${var} from ${env_file} (exit $?)."
        elif [[ $'\n'"$current"$'\n' != *$'\n'"${var}=${want}"$'\n'* ]]; then
            set_env_key "$var" "$want" "$env_file" \
                || die "Failed to write ${var} to ${env_file} (exit $?)."
        fi
    done <<< "$vars"
}

# What: channel word (latest|nightly) or a fixed tag
# Why: channel pins live in LANCACHE_IMAGE_REF_*, tags stay
# From: Issue #1683 | PR #1858
resolve_lancache_image_tag() {
    local env_file="${1:-}" tag="${LANCACHE_IMAGE_TAG:-}" release_tag="" channel=""

    if [[ -n "$tag" ]]; then
        case "$tag" in
            stable|latest|nightly)
                lancache_stack_pointer_channel_for "$tag"
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
        channel=$(get_env_var LANCACHE_IMAGE_CHANNEL "$env_file") || exit $?
    fi

    case "$channel" in
        stable|latest|nightly)
            lancache_stack_pointer_channel_for "$channel"
            return 0
            ;;
        pinned)
            if [[ -z "$tag" && -n "$env_file" && -f "$env_file" ]]; then
                tag=$(get_env_var LANCACHE_IMAGE_TAG "$env_file") || exit $?
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
        tag=$(get_env_var LANCACHE_IMAGE_TAG "$env_file") || exit $?
    fi

    case "$tag" in
        stable|latest|nightly)
            lancache_stack_pointer_channel_for "$tag"
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
        channel=$(resolve_lancache_image_channel "$env_file") || exit $?
        lancache_stack_pointer_channel_for "$channel"
        return 0
    fi

    validate_lancache_image_tag "$tag"
    printf '%s\n' "$tag"
}

# What: adds missing keys and normalizes legacy .env state
# Why: updates must be idempotent and keep operator secrets
migrate_env_for_update() (
    # What: keeps a valid tag when preserve_image_tag is 1
    # Why: restore must not re-resolve a rolled-back tag
    local install_dir="$1" preserve_image_tag="${2:-0}" env_file dhcp_enabled dhcp_mode
    local dhcp_proxy_interface dhcp_proxy_router dhcp_ntp_servers dhcp_proxy_domain
    local dhcp_proxy_boot_filename dhcp_proxy_boot_server _dhcp_ntp_check _dhcp_ntp_ip dhcp_relay_local_addr
    # What: declares every temporary as function-local
    # Why: undeclared names leaked as globals
    local dhcp_proxy_pxe_boot_server dhcp_proxy_pxe_boot_filename_bios dhcp_proxy_pxe_boot_filename_uefi
    local default_cache_size default_cache_gb
    local allow_insecure_ui cache_dir cache_max_gb cache_max_size cache_gb cache_mem_mb ip_ssl ui_generated_password ui_password ui_user
    local compose_profiles dhcp_dns_primary dhcp_dns_secondary dhcp_subnet_start ip_standard upstream_dhcp_ip
    local state_keys state_key state_sub state_sub_dir legacy_path ntp_enabled logging_enabled
    local state_dir ui_session_ttl
    local legacy_cache_std legacy_cache_ssl existing_image_tag
    local lancache_image_registry lancache_image_prefix lancache_image_channel lancache_image_tag
    env_file=$(runtime_env_file_for_install_dir "$install_dir")

    [[ -f "$env_file" ]] \
        || die "Missing $env_file. Cannot update safely because local runtime configuration is not available."

    # What: a failed run puts the original .env back
    # Why: no failed check may leave .env half-written
    # From: Issue #1683 | PR #1858
    migrate_target="$env_file" migrate_done=0 migrate_snapshot_ok=0
    migrate_env_restore() {
        if [[ "$migrate_done" != 1 && "$migrate_snapshot_ok" = 1 ]]; then
            write_file_atomically "$migrate_target" < "$migrate_snapshot" || {
                print_error "Could not restore $migrate_target; its snapshot stays at $migrate_snapshot."
                return
            }
            print_warn "Restored $migrate_target to its state before the update"
        fi
        rm -f -- "$migrate_snapshot" || print_error "Failed to remove the snapshot $migrate_snapshot (exit $?)."
    }
    migrate_snapshot=$(mktemp "$(dirname "$env_file")/.$(basename "$env_file").before.XXXXXX") \
        || die "Cannot snapshot $env_file before the update (exit $?)."
    trap migrate_env_restore EXIT
    cp -p -- "$env_file" "$migrate_snapshot" || die "Cannot snapshot $env_file (exit $?)."
    migrate_snapshot_ok=1

    print_step "Checking runtime .env"

    require_env_value_for_update IP_STANDARD "$env_file"
    # What: the second LAN IP must be set before any write
    # Why: prod always runs dns-ssl on it (AG-SETUP-001)
    # From: Issue #1683 | PR #1858
    require_env_value_for_update IP_SSL "$env_file"
    ip_standard=$(get_env_var IP_STANDARD "$env_file") || exit $?
    ip_ssl=$(get_env_var IP_SSL "$env_file") || exit $?
    require_separate_lan_ips "$ip_standard" "$ip_ssl"

    # What: resolves and checks the image tag first
    # Why: a platform failure leaves other keys untouched
    lancache_image_registry=$(resolve_lancache_image_registry "$env_file") || exit $?
    validate_lancache_image_registry "$lancache_image_registry"
    lancache_image_prefix=$(resolve_lancache_image_prefix "$env_file") || exit $?
    validate_lancache_image_prefix "$lancache_image_prefix"
    lancache_image_channel=$(resolve_lancache_image_channel "$env_file") || exit $?
    existing_image_tag=$(get_env_var LANCACHE_IMAGE_TAG "$env_file") || exit $?
    local lancache_image_refs="" keep_image_refs=0 archived_refs
    archived_refs=$(awk '/^LANCACHE_IMAGE_REF_[A-Z_]+=/' "$env_file") \
        || die "Failed to read the image pins from $env_file (exit $?)."
    if [[ "$preserve_image_tag" = "1" ]] \
        && [[ "$existing_image_tag" =~ ^(sha-[A-Za-z0-9][A-Za-z0-9_.-]{0,127}|v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?)$ ]]; then
        # What: keeps the archived immutable tag as-is
        # Why: re-resolving would pull the bad channel image
        validate_lancache_image_tag "$existing_image_tag"
        lancache_image_tag="$existing_image_tag"
    elif [[ "$preserve_image_tag" = "1" && "$existing_image_tag" =~ ^(latest|nightly)$ && -n "$archived_refs" ]]; then
        # What: a restore keeps archived channel pins
        # Why: re-resolving pulls the current stack
        # From: Issue #1683 | PR #1858
        lancache_image_tag="$existing_image_tag"
        keep_image_refs=1
    else
        # What: re-derives the channel from the tag itself
        # Why: no channel write to .env is needed first
        lancache_image_tag=$(resolve_lancache_image_tag "$env_file") || exit $?
        lancache_image_refs=$(lancache_image_refs_for_tag "$env_file" "$lancache_image_tag") \
            || die "Cannot pin the images of ${lancache_image_tag} for ${env_file}; it stays unchanged (exit $?)."
    fi
    assert_resolved_image_tag_platform_supported \
        "$lancache_image_registry" "$lancache_image_prefix" "$lancache_image_tag"
    set_env_key_if_empty_or_missing LANCACHE_IMAGE_REGISTRY "$lancache_image_registry" "$env_file"
    set_env_key_if_empty_or_missing LANCACHE_IMAGE_PREFIX "$lancache_image_prefix" "$env_file"
    set_env_key_if_empty_or_missing LANCACHE_IMAGE_CHANNEL "$lancache_image_channel" "$env_file"
    set_env_key LANCACHE_IMAGE_TAG "$lancache_image_tag" "$env_file"
    [[ "$keep_image_refs" = "1" ]] || write_lancache_image_refs "$env_file" "$lancache_image_refs"
    adopt_moved_config_prod_keys "$install_dir" "$env_file" copy

    ui_session_ttl=$(get_env_var UI_SESSION_TTL_SECONDS "$env_file") || exit $?
    ui_session_ttl="${ui_session_ttl:-$DEFAULT_UI_SESSION_TTL_SECONDS}"
    validate_ui_session_ttl_seconds "$ui_session_ttl" "$env_file"
    set_env_key_if_empty_or_missing UI_SESSION_TTL_SECONDS "$ui_session_ttl" "$env_file"

    # What: an empty SSL_ENABLED becomes 1
    # Why: prod always runs dns-ssl on the required IP_SSL
    # From: Issue #1683 | PR #1858
    set_env_key_if_empty_or_missing SSL_ENABLED 1 "$env_file"

    # What: missing AUTO_UPDATE_ENABLED defaults to 0
    # Why: migration never turns auto-update on
    set_env_key_if_empty_or_missing AUTO_UPDATE_ENABLED "0" "$env_file"

    state_dir=$(install_state_root "$install_dir" "$env_file") \
        || die "Cannot resolve the state root of $install_dir (exit $?)."
    set_env_key_if_empty_or_missing LANCACHE_STATE_DIR "$state_dir" "$env_file"

    # What: CACHE_DIR is the canonical cache path
    # Why: legacy split cache keys must collapse into it
    cache_dir=$(get_env_var CACHE_DIR "$env_file") || exit $?
    legacy_cache_std=$(get_env_var CACHE_DIR_STANDARD "$env_file") || exit $?
    legacy_cache_ssl=$(get_env_var CACHE_DIR_SSL "$env_file") || exit $?
    if [[ -z "$cache_dir" ]]; then
        if [[ -n "$legacy_cache_std" && -n "$legacy_cache_ssl" && "$legacy_cache_std" != "$legacy_cache_ssl" ]]; then
            die "CACHE_DIR_STANDARD and CACHE_DIR_SSL point to different paths in $env_file. Set CACHE_DIR to one shared cache directory before rerunning setup.sh update. The update will not keep two cache directories."
        fi

        cache_dir="${legacy_cache_std:-$legacy_cache_ssl}"
    fi
    [[ -n "$cache_dir" ]] || cache_dir=$(legacy_dir_or_default "$(legacy_state_path cache)" "$state_dir/cache")
    set_env_key CACHE_DIR "$cache_dir" "$env_file"
    remove_env_key CACHE_DIR_STANDARD "$env_file"
    remove_env_key CACHE_DIR_SSL "$env_file"

    # What: derives state dirs from the legacy root
    # Why: one state contract for update and upgrades
    state_keys=$(prod_state_keys) || die "Cannot list the state keys of $PROD_COMPOSE (exit $?)."
    while IFS= read -r state_key; do
        state_sub=$(prod_state_subdir "$state_key") \
            || die "Cannot read the default directory of $state_key (exit $?)."
        [[ "$state_key" != CACHE_DIR ]] || continue
        state_sub_dir="$state_dir/$state_sub"
        if [[ " ${LEGACY_STATE_CHILDREN[*]} " == *" $state_sub "* ]]; then
            legacy_path=$(legacy_state_path "$state_sub") || exit $?
            state_sub_dir=$(legacy_dir_or_default "$legacy_path" "$state_sub_dir") || exit $?
        fi
        set_optional_env_path_override_if_needed "$state_key" "$state_sub_dir" "$state_dir/$state_sub" "$env_file"
    done <<< "$state_keys"

    cache_max_size=$(get_env_var_nonempty CACHE_MAX_SIZE "$env_file") || exit $?
    cache_max_gb=$(get_env_var_nonempty CACHE_MAX_GB "$env_file") || exit $?
    default_cache_size=$(prod_env_default CACHE_MAX_SIZE) \
        || die "Cannot read the default of CACHE_MAX_SIZE (exit $?)."
    default_cache_gb=$(cache_size_gb_from_env "$default_cache_size") \
        || die "The CACHE_MAX_SIZE default '$default_cache_size' is not a GB size."
    cache_gb=$(cache_size_gb_from_env "${cache_max_size:-$cache_max_gb}") || cache_gb="$default_cache_gb"

    set_env_key_if_empty_or_missing CACHE_MAX_SIZE "${cache_gb}g" "$env_file"
    cache_mem_mb=$(get_env_var CACHE_MEM_MB "$env_file") || exit $?
    if ! is_positive_integer "$cache_mem_mb"; then
        cache_mem_mb=$(prod_env_default CACHE_MEM_MB) \
            || die "Cannot read the default of CACHE_MEM_MB (exit $?)."
    fi
    set_env_key CACHE_MEM_MB "$cache_mem_mb" "$env_file"
    migrate_proxy_security_mode_for_update "$env_file"
    set_template_owned_env_defaults "$env_file"
    # What: image keys were resolved at the top
    # Why: the platform check runs before migration writes

    set_env_key_if_empty_or_missing CACHE_MAX_GB "$cache_gb" "$env_file"
    ip_standard=$(get_env_var IP_STANDARD "$env_file") || die "Cannot read IP_STANDARD from $env_file (exit $?)."
    append_env_migrated_assignment_if_missing UI_BIND_IP IP_STANDARD "$ip_standard" "$env_file"

    # DHCP/Kea can stay disabled, but the keys must exist so Compose and the UI
    # read one complete runtime configuration.
    append_env_key_if_missing DHCP_ENABLED "0" "$env_file"
    append_env_defaults_if_missing "$env_file" DHCP_SUBNET DHCP_GATEWAY DHCP_RANGE_START DHCP_RANGE_END

    # What: NTP can stay disabled; its key must still exist
    # Why: Compose and the UI read one complete config
    # From: Issue #1683 | PR #1858
    append_env_key_if_missing NTP_ENABLED "0" "$env_file"

    # What: logging defaults to 1 when the key is absent
    # Why: existing LOGGING_ENABLED values are kept
    append_env_key_if_missing LOGGING_ENABLED "1" "$env_file"

    compose_profiles=$(get_env_var COMPOSE_PROFILES "$env_file") || exit $?
    dhcp_enabled=$(get_env_var DHCP_ENABLED "$env_file") || exit $?
    dhcp_mode=$(get_env_var DHCP_MODE "$env_file") || exit $?
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
    ip_standard=$(get_env_var IP_STANDARD "$env_file") || exit $?
    ip_ssl=$(get_env_var IP_SSL "$env_file") || exit $?
    dhcp_subnet_start=$(get_env_var DHCP_SUBNET_START "$env_file") || exit $?
    dhcp_dns_primary=$(get_env_var DHCP_DNS_PRIMARY "$env_file") || exit $?
    dhcp_dns_secondary=$(get_env_var DHCP_DNS_SECONDARY "$env_file") || exit $?
    upstream_dhcp_ip=$(get_env_var UPSTREAM_DHCP_IP "$env_file") || exit $?
    # What: dnsmasq keys exist even while DHCP is off
    # Why: the .env lists every option an operator can set
    # From: Issue #1683 | PR #1858
    append_env_defaults_if_missing "$env_file" DHCP_RELAY_LOCAL_ADDR DHCP_PROXY_INTERFACE \
        DHCP_PROXY_ROUTER DHCP_NTP_SERVERS DHCP_PROXY_DOMAIN DHCP_PROXY_BOOT_FILENAME \
        DHCP_PROXY_BOOT_SERVER DHCP_PROXY_CUSTOM_OPTIONS DHCP_PROXY_PXE_BOOT_SERVER \
        DHCP_PROXY_PXE_BOOT_FILENAME_BIOS DHCP_PROXY_PXE_BOOT_FILENAME_UEFI
    dhcp_relay_local_addr=$(get_env_var DHCP_RELAY_LOCAL_ADDR "$env_file") || exit $?
    dhcp_proxy_interface=$(get_env_var DHCP_PROXY_INTERFACE "$env_file") || exit $?
    dhcp_proxy_router=$(get_env_var DHCP_PROXY_ROUTER "$env_file") || exit $?
    dhcp_ntp_servers=$(get_env_var DHCP_NTP_SERVERS "$env_file") || exit $?
    dhcp_proxy_domain=$(get_env_var DHCP_PROXY_DOMAIN "$env_file") || exit $?
    dhcp_proxy_boot_filename=$(get_env_var DHCP_PROXY_BOOT_FILENAME "$env_file") || exit $?
    dhcp_proxy_boot_server=$(get_env_var DHCP_PROXY_BOOT_SERVER "$env_file") || exit $?
    dhcp_proxy_pxe_boot_server=$(get_env_var DHCP_PROXY_PXE_BOOT_SERVER "$env_file") || exit $?
    dhcp_proxy_pxe_boot_filename_bios=$(get_env_var DHCP_PROXY_PXE_BOOT_FILENAME_BIOS "$env_file") || exit $?
    dhcp_proxy_pxe_boot_filename_uefi=$(get_env_var DHCP_PROXY_PXE_BOOT_FILENAME_UEFI "$env_file") || exit $?

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
                || die "DHCP_PROXY_BOOT_FILENAME in $env_file must not contain whitespace, commas, or other characters unsafe in a .env value (newline, \$, \`, \", ', \\, or #)."
            [[ -z "$dhcp_proxy_boot_server" ]] || is_valid_ipv4 "$dhcp_proxy_boot_server" \
                || die "DHCP_PROXY_BOOT_SERVER in $env_file must be a valid IPv4 address or empty."
            [[ -z "$dhcp_proxy_pxe_boot_server" ]] || is_valid_ipv4 "$dhcp_proxy_pxe_boot_server" \
                || die "DHCP_PROXY_PXE_BOOT_SERVER in $env_file must be a valid IPv4 address or empty."
            [[ -z "$dhcp_proxy_pxe_boot_filename_bios" ]] || is_valid_dhcp_proxy_boot_filename "$dhcp_proxy_pxe_boot_filename_bios" \
                || die "DHCP_PROXY_PXE_BOOT_FILENAME_BIOS in $env_file must not contain whitespace, commas, or other characters unsafe in a .env value (newline, \$, \`, \", ', \\, or #)."
            [[ -z "$dhcp_proxy_pxe_boot_filename_uefi" ]] || is_valid_dhcp_proxy_boot_filename "$dhcp_proxy_pxe_boot_filename_uefi" \
                || die "DHCP_PROXY_PXE_BOOT_FILENAME_UEFI in $env_file must not contain whitespace, commas, or other characters unsafe in a .env value (newline, \$, \`, \", ', \\, or #)."
            # What: PXE needs both server and filename
            # Why: update is unattended; never clears input
            if [[ -n "$dhcp_proxy_pxe_boot_server" ]] \
                && ! pxe_boot_pointer_answers_are_complete "$dhcp_proxy_pxe_boot_server" "$dhcp_proxy_pxe_boot_filename_bios" "$dhcp_proxy_pxe_boot_filename_uefi"; then
                die "DHCP_PROXY_PXE_BOOT_SERVER is set in $env_file but neither DHCP_PROXY_PXE_BOOT_FILENAME_BIOS nor DHCP_PROXY_PXE_BOOT_FILENAME_UEFI is; PXE boot-pointer support needs at least one boot filename to activate. Set one of them, or clear DHCP_PROXY_PXE_BOOT_SERVER, then re-run update."
            elif [[ -z "$dhcp_proxy_pxe_boot_server" && ( -n "$dhcp_proxy_pxe_boot_filename_bios" || -n "$dhcp_proxy_pxe_boot_filename_uefi" ) ]]; then
                die "A DHCP_PROXY_PXE_BOOT_FILENAME_* value is set in $env_file but DHCP_PROXY_PXE_BOOT_SERVER is empty; PXE boot-pointer support needs a boot server to activate. Set DHCP_PROXY_PXE_BOOT_SERVER, or clear both boot filename values, then re-run update."
            fi
            ;;
        dnsmasq-relay)
            # What: relay needs local and upstream IPs
            # Why: ProxyDHCP fields are unused in relay
            is_valid_ipv4 "$dhcp_relay_local_addr" \
                || die "DHCP_MODE=dnsmasq-relay requires DHCP_RELAY_LOCAL_ADDR (this relay's own IPv4 on the client network) in $env_file. Set it, then rerun setup.sh update."
            is_valid_ipv4 "$upstream_dhcp_ip" \
                || die "DHCP_MODE=dnsmasq-relay requires the upstream DHCP server IPv4 in UPSTREAM_DHCP_IP in $env_file. Set it, then rerun setup.sh update."
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
    set_env_key DHCP_RELAY_LOCAL_ADDR "$dhcp_relay_local_addr" "$env_file"
    set_env_key DHCP_PROXY_INTERFACE "$dhcp_proxy_interface" "$env_file"
    set_env_key DHCP_PROXY_ROUTER "$dhcp_proxy_router" "$env_file"
    set_env_key DHCP_NTP_SERVERS "$dhcp_ntp_servers" "$env_file"
    set_env_key DHCP_PROXY_DOMAIN "$dhcp_proxy_domain" "$env_file"
    set_env_key DHCP_PROXY_BOOT_FILENAME "$dhcp_proxy_boot_filename" "$env_file"
    set_env_key DHCP_PROXY_BOOT_SERVER "$dhcp_proxy_boot_server" "$env_file"
    set_env_key DHCP_PROXY_PXE_BOOT_SERVER "$dhcp_proxy_pxe_boot_server" "$env_file"
    set_env_key DHCP_PROXY_PXE_BOOT_FILENAME_BIOS "$dhcp_proxy_pxe_boot_filename_bios" "$env_file"
    set_env_key DHCP_PROXY_PXE_BOOT_FILENAME_UEFI "$dhcp_proxy_pxe_boot_filename_uefi" "$env_file"

    # What: generates empty or placeholder service tokens
    # Why: real operator values are preserved
    ensure_secret_env_key KEA_CTRL_TOKEN "$env_file" hex32
    ensure_secret_env_key DDNS_TSIG_KEY "$env_file" base64_32
    ensure_secret_env_key PDNS_API_KEY "$env_file" hex32
    # What: NETDATA_ALARM_TOKEN is generated proactively
    # Why: shared bootstrap only heals placeholders
    ensure_secret_env_key NETDATA_ALARM_TOKEN "$env_file" hex32
    set_env_key_if_empty_or_missing NATS_UI_USER "lancache-ui" "$env_file"
    ensure_secret_env_key NATS_UI_PASSWORD "$env_file" hex32
    set_env_key_if_empty_or_missing NATS_DNS_WRITER_USER "lancache-dns-writer" "$env_file"
    ensure_secret_env_key NATS_DNS_WRITER_PASSWORD "$env_file" hex32
    set_env_key_if_empty_or_missing NATS_DNS_REPLICA_USER "lancache-dns-replica" "$env_file"
    ensure_secret_env_key NATS_DNS_REPLICA_PASSWORD "$env_file" hex32
    set_env_key_if_empty_or_missing NATS_CALLOUT_USER "lancache-nats-callout" "$env_file"
    ensure_secret_env_key NATS_CALLOUT_PASSWORD "$env_file" hex32
    # What: NATS_SYS_USER is set if missing
    # Why: installed primary converges to new capability
    set_env_key_if_empty_or_missing NATS_SYS_USER "lancache-nats-sys" "$env_file"
    ensure_secret_env_key NATS_SYS_PASSWORD "$env_file" hex32
    ensure_secret_env_key SECONDARY_REGISTRATION_TOKEN "$env_file" hex32

    ntp_enabled=$(get_env_var NTP_ENABLED "$env_file") || exit $?
    logging_enabled=$(get_env_var LOGGING_ENABLED "$env_file") || exit $?
    append_env_key_if_missing COMPOSE_PROFILES "" "$env_file"
    set_env_key COMPOSE_PROFILES \
        "$(compose_profiles_for_runtime "$compose_profiles" "$dhcp_mode" "$ntp_enabled" "$logging_enabled")" \
        "$env_file"

    # What: UI auth is user-chosen; user needs a password
    # Why: unset user and password mean insecure UI
    append_env_key_if_missing UI_AUTH_USER "" "$env_file"
    append_env_key_if_missing UI_AUTH_PASSWORD "" "$env_file"
    ui_user=$(get_env_var UI_AUTH_USER "$env_file") || exit $?
    ui_password=$(get_env_var UI_AUTH_PASSWORD "$env_file") || exit $?
    if [[ -n "$ui_user" ]] && ! env_key_has_usable_secret UI_AUTH_PASSWORD "$env_file"; then
        ui_generated_password=$(generate_secret_value UI_AUTH_PASSWORD alnum20) || exit $?
        set_env_key UI_AUTH_PASSWORD "$ui_generated_password" "$env_file"
        print_ok "Generated missing Admin UI password because UI_AUTH_USER is set"
    fi

    allow_insecure_ui=false
    [[ -z "$ui_user" && -z "$ui_password" ]] && allow_insecure_ui=true
    append_env_key_if_missing ALLOW_INSECURE_UI "$allow_insecure_ui" "$env_file"

    print_ok ".env is complete for the current deploy/prod template"
    migrate_done=1
    adopt_moved_config_prod_keys "$install_dir" "$env_file" drop
)

# What: maps a tool to its apt package name
# Why: dig ships in bind9-dnsutils or dnsutils, not dig
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
    local tool package
    for tool in "${tools[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    (( ${#missing[@]} == 0 )) && return 0
    print_warn "Missing required tool(s): ${missing[*]} — installing now..."
    command -v apt-get >/dev/null 2>&1 || die "Cannot install missing tools automatically; install: ${missing[*]}"
    for tool in "${missing[@]}"; do
        package=$(package_name_for_tool "$tool") || die "Cannot resolve the package of $tool (exit $?)."
        packages+=("$package")
    done
    apt-get update -y || die "apt-get update failed (exit $?); nothing was installed."
    apt-get install -y --no-install-recommends "${packages[@]}" \
        || die "Failed to install required tool(s): ${missing[*]}"
    for tool in "${missing[@]}"; do
        command -v "$tool" >/dev/null 2>&1 \
            || die "$tool is still missing after installing package(s): ${packages[*]}"
    done
}

# What: lists the paths a config or full backup includes
# Why: existing state dirs; cache only in full mode
backup_manifest() {
    local install_dir="$1" mode="$2"
    local env_file cache_env_file
    local cache_dir cache_std cache_ssl state_dir keys key dir sub
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    cache_env_file="$install_dir/.env"
    state_dir=$(install_state_root "$install_dir" "$env_file") \
        || die "Cannot resolve the state root of $install_dir (exit $?)."
    cache_dir=$(get_env_var CACHE_DIR "$env_file") || exit $?
    cache_std=$(get_env_var CACHE_DIR_STANDARD "$env_file") || exit $?
    cache_ssl=$(get_env_var CACHE_DIR_SSL "$env_file") || exit $?
    cache_std="${cache_std:-$state_dir/cache}"
    cache_ssl="${cache_ssl:-$cache_std}"

    printf '%s\n' "$cache_env_file"
    [[ "$env_file" != "$cache_env_file" ]] && printf '%s\n' "$env_file"
    printf '%s\n' "$install_dir/docker-compose.yml" "$install_dir/certs" "$install_dir/scripts"
    deploy_prod_repo_input_paths "$install_dir"
    # What: every compose state dir but cache and logs
    # Why: cache: full mode only; logs are no rollback state
    # From: Issue #1683 | PR #1858
    keys=$(prod_state_keys) || die "Cannot list the state keys of $PROD_COMPOSE (exit $?)."
    while IFS= read -r key; do
        case "$key" in CACHE_DIR|SYSLOG_NG_LOG_DIR) continue ;; esac
        dir=$(prod_state_dir_for_key "$key" "$env_file" "$state_dir") \
            || die "Cannot resolve the directory of $key (exit $?)."
        [[ -d "$dir" ]] && printf '%s\n' "$dir"
        sub=$(prod_state_subdir "$key") || die "Cannot read the default directory of $key (exit $?)."
        [[ -d "$(legacy_state_path "$sub")" ]] && printf '%s\n' "$(legacy_state_path "$sub")"
    done <<< "$keys"
    if [[ "$mode" = "full" ]]; then
        [[ -n "${cache_dir:-}" && -d "$cache_dir" ]] && printf '%s\n' "$cache_dir"
        [[ -n "${cache_std:-}" && -d "$cache_std" ]] && printf '%s\n' "$cache_std"
        [[ -n "${cache_ssl:-}" && "$cache_ssl" != "$cache_std" && -d "$cache_ssl" ]] && printf '%s\n' "$cache_ssl"
        [[ -d "$(legacy_state_path cache)" ]] && printf '%s\n' "$(legacy_state_path cache)"
    fi
    true
}

# What: true if child path is inside parent path
# Why: recursive backups can fill disks and corrupt restores
path_is_inside() {
    local child="$1" parent="$2"
    child=$(realpath -m "$child")
    parent=$(realpath -m "$parent")
    [[ "$child" = "$parent" || "$child" = "$parent"/* ]]
}

# What: fails with a secondary-directory hint
# Why: a secondary stack lives outside /opt/lancache-ng
die_no_stack_found() {
    local install_dir="$1"
    die "No stack found in ${install_dir}. If this is a fresh primary install, run ./setup.sh install. If this is a secondary DNS node, run this command from its own directory instead (the one named after --name when it was registered via ./setup.sh secondary), or pass that directory explicitly, e.g.: ./setup.sh <command> /path/to/that-directory"
}

# What: compose helpers return early without a stack
# Why: backup and restore must handle damaged installs
compose_stack_available() {
    local install_dir="$1"
    [[ -f "$install_dir/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1
}

# What: true if any compose container is running
# Why: restore only restarts a stack that was running
compose_stack_running() {
    local install_dir="$1" env_file out
    compose_stack_available "$install_dir" || return 1
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    out=$(stack_compose "$install_dir" "$env_file" ps -q) \
        || die "Failed to list the containers of $install_dir (exit $?)."
    [[ -n "$out" ]]
}

# What: stops the stack before backup or restore
# Why: a stop failure warns, so backup can proceed
compose_stack_stop() {
    local install_dir="$1"
    local env_file
    compose_stack_available "$install_dir" || return 0
    print_step "Stopping stack for consistent backup/restore"
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    # What: a failed stop aborts before any data is copied
    # Why: files of a running stack can be torn mid-copy
    # From: Issue #1683 | PR #1858
    stack_compose "$install_dir" "$env_file" stop \
        || die "Failed to stop the stack in $install_dir (exit $?); nothing was copied."
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
    stack_compose "$install_dir" "$env_file" up -d \
        || print_warn "docker compose up failed (exit $?); start it with: $SCRIPT_DIR/setup.sh compose $install_dir up -d"
}

# Runs `docker compose config` as a dry-run check. Called both before and
# after pulling images during update, so a migration or pull that produced an
# invalid compose config is caught before containers are actually restarted.
validate_compose_config() {
    local install_dir="$1"
    local env_file
    print_step "Validating Docker Compose configuration"
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    stack_compose "$install_dir" "$env_file" config --quiet \
        || die "Docker Compose configuration is not valid. The stack was not pulled or restarted."
    print_ok "Docker Compose configuration is valid"
}

# What: resolves the Compose project name from yaml or env
# Why: archived compose dirs have no running containers
compose_project_name() {
    local compose_dir="$1" env_file="$2" name
    name="${COMPOSE_PROJECT_NAME:-}"
    [[ -n "$name" ]] || name=$(get_env_var COMPOSE_PROJECT_NAME "$env_file")
    if [[ -z "$name" && -f "$compose_dir/docker-compose.yml" ]]; then
        # What: sed output is captured, then head reads it
        # Why: avoids SIGPIPE when several name: keys match
        # From: Issue #1377
        local compose_name_lines
        compose_name_lines=$(sed -n 's/^name:[[:space:]]*//p' "$compose_dir/docker-compose.yml") \
            || die "Failed to read $compose_dir/docker-compose.yml (exit $?)."
        name=$(head -1 <<<"$compose_name_lines")
    fi
    name="${name:-$(basename "$compose_dir")}"
    printf '%s\n' "$name"
}

# What: <project>_<volume> of the CACHE_DIR-backed volume
# Why: the prod compose owns the name; works pre-create
# From: Issue #1683 | PR #1858
compose_cache_volume_name() {
    local install_dir="$1" env_file="$2" project volume
    project=$(compose_project_name "$install_dir" "$env_file") || exit $?
    volume=$(awk '
        /^volumes:/ { v = 1; next }
        v && /^[^ #]/ { v = 0 }
        v && /^  [A-Za-z0-9_.-]+:/ { name = $1; sub(/:$/, "", name) }
        v && /device: *\$\{CACHE_DIR[:}]/ { print name; exit }' "$PROD_COMPOSE") \
        || die "Failed to read $PROD_COMPOSE (exit $?)."
    [[ -n "$volume" ]] || die "$PROD_COMPOSE defines no CACHE_DIR-backed volume."
    printf '%s_%s\n' "$project" "$volume"
}

# What: lists volumes of containers and the project label
# Why: compose down removes containers but keeps volumes
compose_volume_names() {
    local install_dir="$1" container env_file project containers mounts volumes names=""
    compose_stack_available "$install_dir" || return 0
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    project=$(compose_project_name "$install_dir" "$env_file") \
        || die "Cannot resolve the compose project of $install_dir (exit $?)."
    containers=$(stack_compose "$install_dir" "$env_file" ps --all -q) \
        || die "Failed to list the containers of $install_dir (exit $?)."
    while IFS= read -r container; do
        [[ -n "$container" ]] || continue
        mounts=$(docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' "$container") \
            || die "Failed to read the volumes of container $container (exit $?)."
        names+="${mounts}"$'\n'
    done <<< "$containers"
    volumes=$(docker volume ls --filter "label=com.docker.compose.project=${project}" --format '{{.Name}}') \
        || die "Failed to list the volumes of compose project $project (exit $?)."
    names+="$volumes"
    awk 'NF' <<< "$names" | sort -u
}

# What: true if any named volume carries this project label
# Why: label survives docker compose down on the volume
compose_project_has_named_volumes() {
    local project="$1"
    local volume_names
    # What: captures the volume listing before testing it
    # Why: a live pipe can SIGPIPE under pipefail
    volume_names="$(docker volume ls --filter "label=com.docker.compose.project=${project}" --format '{{.Name}}')" \
        || die "Failed to list the volumes of compose project $project (exit $?)."
    grep -q . <<<"$volume_names"
}

# What: archives named volumes; cache volume only in full
# Why: cache payloads can be huge; config backups skip them
backup_compose_volumes() {
    local install_dir="$1" volume_root="$2" mode="$3" volume env_file cache_volume volumes
    compose_stack_available "$install_dir" || return 0
    require_helper_image
    mkdir -p "$volume_root" || die "Failed to create $volume_root (exit $?)."
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    cache_volume=$(compose_cache_volume_name "$install_dir" "$env_file") \
        || die "Cannot resolve the cache volume of $install_dir (exit $?)."
    volumes=$(compose_volume_names "$install_dir") \
        || die "Cannot list the Docker volumes of $install_dir (exit $?)."
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
            "$LANCACHE_HELPER_IMAGE" sh -c 'cd /volume && tar -cpf "/backup/$1.tar" .' sh "$volume" \
            || die "Failed to archive Docker volume $volume (exit $?)."
    done <<< "$volumes"
}

# What: wipes each volume and replaces it from its archive
# Why: skipping would restore an incomplete stack
restore_compose_volumes() {
    local install_dir="$1" volume_root="$2" volume archive archives
    [[ -d "$volume_root" ]] || return 0
    compose_stack_available "$install_dir" \
        || die "Backup contains Docker volume payloads, but Docker/compose is not available for $install_dir. Install Docker and restore again."
    require_helper_image
    archives=$(find "$volume_root" -maxdepth 1 -type f -name '*.tar') \
        || die "Failed to list the volume archives in $volume_root (exit $?)."
    archives=$(sort <<< "$archives")
    while IFS= read -r archive; do
        [[ -n "$archive" ]] || continue
        volume="$(basename "$archive" .tar)"
        [[ -n "$volume" ]] || continue
        print_ok "Restoring Docker volume: $volume"
        docker volume create "$volume" >/dev/null \
            || die "Failed to create Docker volume $volume (exit $?)."
        docker run --rm \
            -v "${volume}:/volume" \
            -v "${volume_root}:/backup:ro" \
            "$LANCACHE_HELPER_IMAGE" sh -c 'set -e; tar -tf "/backup/$1.tar" >/dev/null; rm -rf /volume/* /volume/..?* /volume/.[!.]*; cd /volume; tar -xpf "/backup/$1.tar"' sh "$volume" \
            || die "Failed to restore Docker volume $volume from $archive (exit $?). Rerun the restore; the archive is unchanged."
    done <<< "$archives"
}

# What: blocks restore if other installs share the volumes
# Why: project name is fixed, so volumes are shared
guard_restore_shared_project_volumes() {
    local install_dir="$1" archived_install_dir="$2" project="$3" container working_dir containers
    command -v docker >/dev/null 2>&1 || return 0
    containers=$(docker ps -a --filter "label=com.docker.compose.project=${project}" --format '{{.ID}}') \
        || die "Failed to list the containers of compose project $project (exit $?)."
    while IFS= read -r container; do
        [[ -n "$container" ]] || continue
        working_dir=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container") \
            || die "Failed to read the working directory label of container $container (exit $?)."
        [[ -n "$working_dir" ]] \
            || die "Refusing to restore: container $container of compose project '$project' has no working directory label, so its install cannot be attributed. Remove it with 'docker rm $container', then restore again."
        working_dir=$(realpath -m "$working_dir")
        if [[ "$working_dir" != "$install_dir" ]]; then
            die "Refusing to restore: compose project '$project' still has containers at $working_dir, which is not the restore target ($install_dir). Both installs share the same Docker-managed volumes because the compose project name is not per-install-dir (see #669). Remove the other install's containers first (cd \"$working_dir\" && docker compose down), or restore into $working_dir instead."
            return 1
        fi
    done <<< "$containers"
    if [[ "$install_dir" != "$archived_install_dir" ]] && compose_project_has_named_volumes "$project"; then
        die "Refusing to restore: compose project '$project' still has named Docker volumes on this host, but the backup is being restored into a different install directory ($install_dir instead of $archived_install_dir). After docker compose down, Docker keeps the project label on the volumes but no longer retains a reliable install-dir owner marker, so same-host cross-directory restore would be ownership-ambiguous. Restore into $archived_install_dir instead, or remove the existing '$project' volumes first if they are no longer needed."
        return 1
    fi
}

# What: records image digests as a rollback reference
# Why: informational only; failures warn, never restore
record_image_revisions() {
    local install_dir="$1" output="$2" env_file revisions
    compose_stack_available "$install_dir" || return 0
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    if revisions=$(stack_compose "$install_dir" "$env_file" images --format json); then
        :
    elif revisions=$(stack_compose "$install_dir" "$env_file" images); then
        :
    else
        print_warn "Could not record current image revisions (exit $?)"
        return 0
    fi
    printf '%s\n' "$revisions" > "$output" || die "Failed to write $output (exit $?)."
}

# What: tars one entry through the compressor of <ext>
# Why: bash waits for both ends; no half-written archive
# From: Issue #1683 | PR #1858
write_compressed_tar() {
    local ext="$1" archive="$2" parent="$3" entry="$4"
    local -a compressor
    case "$ext" in
        zst) compressor=(zstd -q -c) ;;
        bz2) compressor=(bzip2 -c) ;;
        gz) compressor=(gzip -c) ;;
        *) die "No compressor for .$ext archives." ;;
    esac
    tar -C "$parent" -cf - "$entry" | "${compressor[@]}" > "$archive"
}

# What: config or full backup; the body is a subshell
# Why: its EXIT trap reads the state; nothing leaks out
# From: Issue #1683 | PR #1858
cmd_backup() (
    mode="config"
    backup_root="$BACKUP_ROOT"
    install_dir="$DEFAULT_INSTALL_DIR"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full) mode="full"; shift ;;
            --config) mode="config"; shift ;;
            --dest) backup_root="${2:?Missing value for --dest}"; shift 2 ;;
            *) install_dir="$1"; shift ;;
        esac
    done
    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?
    backup_root=$(realpath -m "$backup_root")
    [[ -f "$install_dir/docker-compose.yml" && -f "$(runtime_env_file_for_install_dir "$install_dir")" ]] \
        || die_no_stack_found "$install_dir"
    install_missing_tools tar rsync

    stack_stopped=0
    stack_was_running=0
    backup_paused_convergence=0
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    dest="$backup_root/$stamp"
    archive="$backup_root/lancache-ng-${mode}-${stamp}.tar.gz"
    mkdir -p "$backup_root" || die "Failed to create $backup_root (exit $?)."
    old_umask=$(umask)
    umask 077
    backup_cleanup() {
        local status=$?
        [[ "$stack_stopped" = "1" && "$stack_was_running" = "1" ]] && compose_stack_start "$install_dir"
        [[ "$backup_paused_convergence" = "1" ]] && resume_lancache_convergence_after_update
        rm -rf "$dest" || print_error "Failed to remove the unfinished backup $dest (exit $?)."
        rm -f "$archive.partial" || print_error "Failed to remove $archive.partial (exit $?)."
        umask "$old_umask"
        trap - EXIT
        return "$status"
    }
    trap backup_cleanup EXIT
    mkdir -p "$dest/rootfs" || die "Failed to create $dest/rootfs (exit $?)."

    # What: pauses convergence unless cmd_update did
    # Why: a second pause would overwrite saved timer state
    if [[ "${UPDATE_CONVERGENCE_PAUSED:-0}" != "1" ]]; then
        # What: sets the cleanup flag before the pause call
        # Why: a die inside pause still triggers the resume
        backup_paused_convergence=1
        pause_lancache_convergence_for_update
    fi

    print_step "Creating $mode backup"
    manifest=$(backup_manifest "$install_dir" "$mode") \
        || die "Cannot list the paths to back up from $install_dir (exit $?)."
    sort -u <<< "$manifest" > "$dest/manifest.txt" \
        || die "Failed to write $dest/manifest.txt (exit $?)."
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
    stack_stopped=1
    compose_stack_stop "$install_dir"

    while IFS= read -r path; do
        [[ -e "$path" ]] || continue
        rel="${path#/}"
        if [[ -d "$path" ]]; then
            mkdir -p "$dest/rootfs/$rel" || die "Failed to create $dest/rootfs/$rel (exit $?)."
            rsync -aH --numeric-ids "$path/" "$dest/rootfs/$rel/" \
                || die "Failed to back up $path (exit $?)."
        else
            mkdir -p "$dest/rootfs/$(dirname "$rel")" || die "Failed to create the backup dir of $path (exit $?)."
            rsync -aH --numeric-ids "$path" "$dest/rootfs/$(dirname "$rel")/" \
                || die "Failed to back up $path (exit $?)."
        fi
        print_ok "Included: $path"
    done < "$dest/manifest.txt"
    backup_compose_volumes "$install_dir" "$dest/docker-volumes" "$mode"

    cat > "$dest/README.txt" <<EOF || die "Failed to write $dest/README.txt."
LanCache-NG backup created at $stamp UTC
Mode: $mode
Install directory: $install_dir

Config backups include text/configuration, Docker named volumes, and runtime databases needed for update rollback.
The cache volume is always excluded from config backups, since it can be very large.
Full backups additionally include cache directories and the cache volume, which can be very large.
Restore with: ./setup.sh restore $archive $install_dir
EOF
    # What: archive is written as .partial, then renamed
    # Why: rollback takes the newest complete archive
    # From: Issue #1683 | PR #1858
    write_compressed_tar gz "$archive.partial" "$backup_root" "$stamp" \
        || die "Failed to write $archive (exit $?)."
    chmod 600 "$archive.partial" || die "Failed to restrict $archive.partial (exit $?)."
    mv "$archive.partial" "$archive" || die "Failed to finish $archive (exit $?)."
    print_ok "Backup written: $archive"
    backup_cleanup
)

# What: moves stale .env.local aside when archive lacks one
# Why: prefers .env.local over .env, so it must go

restore_clear_stale_env_local_if_unarchived() {
    local archived_install_root="$1" install_dir="$2" stale_target

    [[ -f "$archived_install_root/.env.local" ]] && return 0
    [[ -f "$install_dir/.env.local" ]] || return 0

    stale_target="$install_dir/.env.local.pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$install_dir/.env.local" "$stale_target" \
        || die "Failed to move the stale $install_dir/.env.local aside (exit $?)."
    print_warn "Archived backup has no .env.local; moved the stale pre-restore override to $(basename "$stale_target") so the restored .env takes effect."
}

# What: restores a backup archive; the body is a subshell
# Why: its EXIT trap reads the state; nothing leaks out
# From: Issue #1683 | PR #1858
cmd_restore() (
    archive="${1:-}"
    install_dir="${2:-$DEFAULT_INSTALL_DIR}"
    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?
    [[ -n "$archive" ]] || die "Usage: $0 restore <backup.tar.gz> [install-dir]"
    [[ -f "$archive" ]] || die "Backup archive not found: $archive"
    # What: requires openssl for the convergence step
    # Why: fails before restore mutations on minimal hosts
    install_missing_tools tar rsync openssl

    stack_stopped=0
    stack_was_running=0
    tmp=$(mktemp -d) || die "Failed to create a temporary directory for the restore (exit $?)."
    restore_cleanup() {
        local status=$?
        if [[ "$stack_stopped" = "1" ]]; then
            if [[ "$status" -eq 0 ]]; then
                # What: restarts only if it was running
                # Why: a stopped stack must stay stopped
                [[ "$stack_was_running" = "1" ]] && compose_stack_start "$install_dir"
            else
                # What: failure keeps the stack stopped
                # Why: no start on a partial restore
                # From: Issue #1683 | PR #1858
                print_warn "Restore failed; leaving the stack stopped at $install_dir for manual recovery."
                print_warn "Investigate the error above, then run: $SCRIPT_DIR/setup.sh compose \"$install_dir\" up -d"
            fi
        fi
        rm -rf "$tmp" || print_error "Failed to remove the restore workspace $tmp (exit $?)."
        trap - EXIT
        return "$status"
    }
    trap restore_cleanup EXIT
    tar -C "$tmp" -xzf "$archive" || die "Failed to unpack $archive (exit $?)."
    # What: find stops at the first rootfs match via -quit
    # Why: avoids SIGPIPE from an early pipe close
    # From: Issue #1377
    root=$(find "$tmp" -mindepth 2 -maxdepth 2 -type d -name rootfs -print -quit) \
        || die "Failed to search $tmp for the archived rootfs (exit $?)."
    [[ -n "$root" && -d "$root" ]] || die "Backup archive has no rootfs payload."
    backup_dir=$(dirname "$root")
    archived_install=""
    if [[ -e "$backup_dir/README.txt" ]]; then
        archived_install=$(awk -F': ' '/^Install directory: / {print $2; exit}' "$backup_dir/README.txt") \
            || die "Failed to read $backup_dir/README.txt (exit $?)."
    fi
    archived_install="${archived_install:-$DEFAULT_INSTALL_DIR}"
    archived_install=$(realpath -m "$archived_install")
    rel_install="${archived_install#/}"
    archived_repo_root=""
    new_repo_root=""
    if is_deploy_prod_install_dir "$archived_install" && is_deploy_prod_install_dir "$install_dir"; then
        archived_repo_root=$(deploy_prod_repo_root "$archived_install") || exit $?
        new_repo_root=$(deploy_prod_repo_root "$install_dir") || exit $?
    fi

    # What: resolves project name from archived compose
    # Why: the guard must check the archive's own project
    archived_project=$(compose_project_name "$root/$rel_install" "$(runtime_env_file_for_install_dir "$root/$rel_install")") \
        || exit $?
    guard_restore_shared_project_volumes "$install_dir" "$archived_install" "$archived_project"

    # What: records whether the stack was running
    # Why: restore restarts only a stack that was running
    compose_stack_running "$install_dir" && stack_was_running=1
    stack_stopped=1
    compose_stack_stop "$install_dir"

    print_step "Restoring backup"
    if [[ -d "$root/$rel_install" ]]; then
        mkdir -p "$install_dir" || die "Failed to create $install_dir (exit $?)."
        rsync -aH --numeric-ids "$root/$rel_install/" "$install_dir/" \
            || die "Failed to restore $install_dir (exit $?)."
        # What: moves a stale .env.local aside first
        # Why: the rewrite must not treat it as archived
        restore_clear_stale_env_local_if_unarchived "$root/$rel_install" "$install_dir"
        if [[ "$archived_install" != "$install_dir" ]]; then
            # What: old path becomes new path, literally
            # Why: regex or sed chars must not skip a line
            # From: Issue #1683 | PR #1858
            [[ "$archived_install$install_dir" != *$'\n'* ]] \
                || die "Cannot rewrite restored config: an install path contains a line break."
            for path in "$install_dir/.env" "$install_dir/.env.local"; do
                [[ -f "$path" ]] || continue
                replace_literal_in_file "$path" "$archived_install" "$install_dir"
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
            mkdir -p "$target" || die "Failed to create $target (exit $?)."
            rsync -aH --numeric-ids "$root/$rel/" "$target/" || die "Failed to restore $target (exit $?)."
        else
            mkdir -p "$(dirname "$target")" || die "Failed to create the directory of $target (exit $?)."
            rsync -aH --numeric-ids "$root/$rel" "$(dirname "$target")/" \
                || die "Failed to restore $target (exit $?)."
        fi
    done < "$backup_dir/manifest.txt"
    restore_compose_volumes "$install_dir" "$backup_dir/docker-volumes"
    print_ok "Files restored from $archive"

    # What: restored quickstart archives move to deploy/prod
    # Why: the old bundle no longer matches this checkout
    # From: Issue #1683 | PR #1858
    if is_quickstart_install "$install_dir"; then
        if ! compose_stack_available "$install_dir"; then
            stack_stopped=0
            die "Restored a quickstart install, but Docker is not available to migrate it. Install Docker, then run: setup.sh update $install_dir"
        fi
        migrate_quickstart_install "$install_dir" || exit $?
        install_dir="${PROD_COMPOSE%/*}"
    fi

    # What: runs migration and config check in a subshell
    # Why: a die must not skip the stack_stopped reset
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
)

# Keep user-facing help compact. Detailed behavior should live in command help
# blocks and comments near the implementation, not in the top-level output.
print_usage() {
    cat <<EOF
LanCache-NG setup

Usage:
  ./setup.sh [command] [install-dir]

Commands:
  install              Run the guided first-time setup. Without a command,
                       setup.sh only prints this help; curl | bash passes
                       the command as: bash -s -- install
  install-requirements-primary
                       Install only the Docker prerequisites (curl, Docker
                       engine, Docker Compose v2) for a primary node, without
                       running the rest of the interactive installer.
  install-requirements-secondary
                       Install only the Docker prerequisites for a secondary
                       DNS node, without running ./setup.sh secondary.
  list-prompts [answers-file]
                       Introspection mode: reports the exact ordered prompt
                       sequence the install wizard would ask for a given set
                       of answers, without touching the filesystem, network,
                       or Docker. See './setup.sh list-prompts --help'.
  update [install-dir] Update an existing stack. Default dir: ${DEFAULT_INSTALL_DIR}
  update-ip [install-dir]
                       Change the configured standard and SSL listener IPs.
                       Default dir: ${DEFAULT_INSTALL_DIR}
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
                       Supported: kea, dns/pdns (dns/pdns also takes a <zone>
                       argument -- run with --help for the full shape).
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

Runs the guided LanCache-NG installer. setup.sh does nothing without a
command, so the curl | bash one-liner passes it: ... | sudo bash -s -- install

When no local repo is found (the standalone curl | bash path), this command
self-clones to ${DEFAULT_INSTALL_DIR} from the remote's default branch (master) by
default. Set LANCACHE_SETUP_GIT_REF to a branch, tag, or commit-ish (e.g.
LANCACHE_SETUP_GIT_REF=v0.2.0) to bootstrap from that ref instead -- useful
for validating a pre-release branch the same documented one-liner way that
LANCACHE_IMAGE_CHANNEL already selects a specific image channel (#814).
EOF
            ;;
        install-requirements-primary)
            cat <<EOF
Usage: ./setup.sh install-requirements-primary

Installs only the Docker prerequisites (curl, Docker engine, a running Docker
daemon, and the Docker Compose v2 plugin) for a primary node, then stops --
does not run the rest of the interactive installer. Useful for provisioning a
host's requirements ahead of time, or standalone, separately from the guided
setup. Must be run as root. Follow with ./setup.sh install.
EOF
            ;;
        install-requirements-secondary)
            cat <<EOF
Usage: ./setup.sh install-requirements-secondary

Installs only the Docker prerequisites (curl, Docker engine, a running Docker
daemon, and the Docker Compose v2 plugin) for a secondary DNS node, then
stops. ./setup.sh secondary itself only checks for these tools and fails with
"docker is not installed" if they are missing -- this command lets an
operator install exactly what a secondary needs, standalone, before running
./setup.sh secondary. Must be run as root.
EOF
            ;;
        list-prompts)
            cat <<EOF
Usage: ./setup.sh list-prompts [answers-file]

Introspection mode for issue #1176: walks the install wizard's real,
current branch logic (the exact same code ./setup.sh install runs) and
prints the ordered prompt sequence it would ask, one per line, as
"PROMPT<TAB>text<TAB>default". Never touches the filesystem, network, or
Docker -- no root required.

[answers-file] is optional: a plain text file with one reply per line, in
the order prompts are expected to be asked. A blank line (or running out of
lines) falls back to that prompt's own default, the same as an operator
pressing Enter. Omitting the file entirely walks the all-defaults path.

Intended consumer: .github/scripts/ci.bats derives the answers of its real
install run from this output instead of hand-encoding them, so a new prompt
cannot silently drift out of sync with the tested install.
EOF
            ;;
        update)
            cat <<EOF
Usage: ./setup.sh update [install-dir]

Updates an existing LanCache-NG installation, pulls fresh container images, and
restarts the stack. If [install-dir] is omitted, ${DEFAULT_INSTALL_DIR} is used.

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
[install-dir] is omitted, ${DEFAULT_INSTALL_DIR} is used.
EOF
            ;;
        update-ip|--reconfigure|reconfigure)
            cat <<EOF
Usage: ./setup.sh update-ip [install-dir]

Interactively changes the standard and SSL listener IP addresses for an
existing installation, then restarts its stack. If [install-dir] is omitted,
${DEFAULT_INSTALL_DIR} is used.

Compatibility: ./setup.sh --reconfigure still works and runs this command.
EOF
            ;;
        debug)
            cat <<EOF
Usage: ./setup.sh debug [install-dir]

Prints container status, recent logs, cache usage, LAN addresses, and health
checks for an existing installation. If [install-dir] is omitted,
${DEFAULT_INSTALL_DIR} is used.
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
${DEFAULT_INSTALL_DIR} is used; the archive is written to ${BACKUP_ROOT}
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
       ./setup.sh reset-to-last-known-good-config dns|pdns [install-dir] <zone> [snapshot-id] [--yes]

CLI fallback for when the Admin UI itself is unreachable but a service's own
control surface still is (issue #763). Automates the exact by-hand recovery
sequence docs/known-good-config-snapshots.md's "Manual recovery" section
documents: list this install's known-good config snapshots for <service> and
apply one -- the given [snapshot-id], or the newest after an explicit
confirmation if omitted -- via that service's own real validate/apply/persist
API, the same sequence the Admin UI's own per-service rollback pages already
run when they ARE reachable.

Supported services:
  kea, dhcp          Rolls back Kea's DHCP config via its Control Agent API
                     (config-test -> config-set -> config-write), reading
                     snapshots from the shared kea-data volume.
  dns, pdns          Rolls back a PowerDNS zone's record data via
                     nats-subscriber's rollback listener (list snapshots ->
                     diff -> PATCH -> check-zone -> flush -> re-publish),
                     reached by execing curl inside the target container
                     (its port is Compose-internal only, never published to
                     the host). Defaults to the dns-standard container,
                     matching the Admin UI's own current single-primary
                     scope; dns-standard/dns-ssl select one explicitly.
                     Unlike Kea, PowerDNS tracks snapshots per zone (lan.,
                     local.lan., and the private reverse zones), so a <zone>
                     argument is required -- omit it to list which zones
                     currently have snapshots instead of guessing one.

--yes, -y     Skip the interactive confirmation prompt (e.g. for scripted use).
              Applying a snapshot always takes effect immediately either way.

If [install-dir] is omitted, ${DEFAULT_INSTALL_DIR} is used.
EOF
            ;;
        *)
            die "Unknown command for help: $command"
            ;;
    esac
}

# ── update / auto-update shared internals ─────────────────────────────────────
# What: plain globals hold the current update flow state
# Why: nested namerefs are fragile; no concurrent updates
_UPDATE_ENV_FILE=""
_UPDATE_STACK_DIR=""
# What: per-service health baseline, filled before update
# Why: gate fails only on healthy-to-unhealthy regressions
declare -gA _UPDATE_HEALTH_BASELINE=()

# What: container-id lookup for the update project
# Why: one shared lookup keeps the -a semantics
service_container_id() {
    local service="$1"
    stack_compose "$_UPDATE_STACK_DIR" "$_UPDATE_ENV_FILE" ps -a -q "$service" || {
        print_error "Failed to look up the container of service $service (exit $?)."
        return 1
    }
}

# What: probes health; one-shot containers pass on exit 0
# Why: running state never holds for one-shot services
service_container_is_healthy() {
    local service="$1"
    local container_id health status restart_policy exit_code

    # What: lookup includes stopped containers
    # Why: an exited one-shot service must still be found
    container_id=$(service_container_id "$service") || return 1
    [[ -n "$container_id" ]] || return 1

    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container_id") \
        || { print_error "Failed to read the health of $service ($container_id, exit $?)."; return 1; }
    if [[ -n "$health" ]]; then
        [[ "$health" = "healthy" ]]
        return $?
    fi

    status=$(docker inspect --format '{{.State.Status}}' "$container_id") \
        || { print_error "Failed to read the state of $service ($container_id, exit $?)."; return 1; }
    [[ "$status" = "running" ]] && return 0

    restart_policy=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container_id") \
        || { print_error "Failed to read the restart policy of $service ($container_id, exit $?)."; return 1; }
    if [[ "$status" = "exited" && "$restart_policy" = "no" ]]; then
        exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container_id") \
            || { print_error "Failed to read the exit code of $service ($container_id, exit $?)."; return 1; }
        [[ "$exit_code" = "0" ]]
        return $?
    fi

    return 1
}

# What: fails when a required probe tool is missing
# Why: a skipped check must not look like a pass
require_functional_check_tool() {
    local tool="$1" probe_description="$2"
    if ! command -v "$tool" >/dev/null 2>&1; then
        print_error "Functional check failed: $probe_description requires '$tool', which is not installed"
        return 1
    fi
    return 0
}

# What: three-step check: TCP, port binding, loopback
# Why: one curl call conflates ports and ACL source IPs

# What: bare TCP connect to ip:port, no HTTP request sent
# Why: reachability alone, apart from the /healthz answer
# From: Issue #1683 | PR #1858
_tcp_port_reachable() {
    local ip="$1" port="$2" err rc=0
    err=$(timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$ip" "$port" 2>&1) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf 'TCP connect to %s:%s failed (exit %s): %s\n' "$ip" "$port" "$rc" "$err" >&2
        return 1
    fi
}

# What: true if docker port lists the given host binding
# Why: the binding must belong to this proxy container
_proxy_container_publishes_port() {
    local container_id="$1" ip="$2" port="$3" binding bindings
    bindings=$(docker port "$container_id" "${port}/tcp") || return 1
    while IFS= read -r binding; do
        case "$binding" in
            "0.0.0.0:${port}"|"${ip}:${port}"|"[::]:${port}") return 0 ;;
        esac
    done <<< "$bindings"
    return 1
}

_verify_healthz_endpoint() {
    local ip="$1" proxy_container_id

    if ! _tcp_port_reachable "$ip" 80; then
        print_error "Functional check failed: TCP connect to ${ip}:80"
        return 1
    fi

    proxy_container_id=$(service_container_id proxy) || exit $?
    if [[ -z "$proxy_container_id" ]]; then
        print_error "Functional check failed: no running 'proxy' container to probe /healthz through"
        return 1
    fi

    if ! _proxy_container_publishes_port "$proxy_container_id" "$ip" 80; then
        print_error "Functional check failed: the 'proxy' container's own Docker port binding does not include ${ip}:80 -- the published port may be mapped to a different service"
        return 1
    fi

    require_functional_check_tool curl "the proxy-container-loopback /healthz probe" || return 1
    if ! docker exec "$proxy_container_id" curl -sf "http://127.0.0.1/healthz" >/dev/null; then
        print_error "Functional check failed: http://127.0.0.1/healthz inside the proxy container"
        return 1
    fi
    return 0
}

# What: functional checks: proxy /healthz and DNS query
# Why: healthy alone does not prove a real answer
verify_stack_functional_health() {
    local ip_standard ip_ssl ssl_enabled test_fqdn resolved

    ip_standard=$(get_env_var IP_STANDARD "$_UPDATE_ENV_FILE") || exit $?
    ip_ssl=$(get_env_var IP_SSL "$_UPDATE_ENV_FILE") || exit $?
    ssl_enabled=$(get_env_var SSL_ENABLED "$_UPDATE_ENV_FILE") || exit $?

    if [[ -n "$ip_standard" ]]; then
        _verify_healthz_endpoint "$ip_standard" || return 1
    fi
    if [[ "${ssl_enabled:-0}" = "1" && -n "$ip_ssl" ]]; then
        _verify_healthz_endpoint "$ip_ssl" || return 1
    fi

    # What: dig queries a fixed host on the DNS container
    # Why: real answer needed; ping and ss prove nothing
    test_fqdn="content1.steampowered.com"
    if [[ -n "$ip_standard" ]]; then
        require_functional_check_tool dig "the DNS resolution probe" || return 1
        if ! resolved=$(dig +time=2 +tries=1 +short @"$ip_standard" A "$test_fqdn" 2>&1) \
            || [[ -z "$resolved" || "$resolved" == *";;"* ]]; then
            print_error "Functional check failed: DNS did not resolve ${test_fqdn} via ${ip_standard}: ${resolved:-empty answer}"
            return 1
        fi
    fi

    return 0
}

# What: sample count and interval for the health baseline
# Why: one healthy read can hit a crash-loop window
_UPDATE_HEALTH_BASELINE_SAMPLES=3
_UPDATE_HEALTH_BASELINE_SAMPLE_INTERVAL=2

# What: records pre-update health of each named service
# Why: gate fails only on regressions; 3 stable reads
capture_stack_health_baseline() {
    local -a services=("$@")
    local svc container_id sample healthy_streak

    _UPDATE_HEALTH_BASELINE=()
    for svc in "${services[@]}"; do
        container_id=$(service_container_id "$svc") \
            || die "Cannot capture the health baseline of $svc (exit $?); nothing was changed."
        if [[ -z "$container_id" ]]; then
            # What: no old container; left out of baseline
            # Why: new services must become healthy
            continue
        fi

        healthy_streak=1
        for (( sample = 0; sample < _UPDATE_HEALTH_BASELINE_SAMPLES; sample++ )); do
            if ! service_container_is_healthy "$svc"; then
                healthy_streak=0
                break
            fi
            (( sample < _UPDATE_HEALTH_BASELINE_SAMPLES - 1 )) \
                && sleep "$_UPDATE_HEALTH_BASELINE_SAMPLE_INTERVAL"
        done
        _UPDATE_HEALTH_BASELINE["$svc"]="$healthy_streak"
    done
}

# What: maps file-logged services to syslog hosts
# Why: docker logs is blind for these services
declare -gA _REGRESSED_SERVICE_SYSLOG_HOST=(
    [dhcp-proxy]="lancache-dhcp-proxy"
    [nats]="lancache-nats"
    [syslog]="lancache-syslog"
)

# What: tails the forwarded syslog-ng log of one service
# Why: supplements docker logs; needs logging active
dump_service_syslog_ng_tail() {
    local svc="$1" syslog_host="$2"
    local syslog_ng_log_dir today_file

    # What: a failed lookup skips only this diagnostic
    # Why: it runs in the rollback path, which must go on
    # From: Issue #1683 | PR #1858
    if ! syslog_ng_log_dir=$(prod_state_dir_for_key SYSLOG_NG_LOG_DIR "$_UPDATE_ENV_FILE"); then
        print_warn "Cannot resolve SYSLOG_NG_LOG_DIR; skipping the forwarded logs of '$svc'."
        return 0
    fi
    today_file="$syslog_ng_log_dir/$syslog_host/$(date -u +%Y%m%d).log"

    if [[ -r "$today_file" ]]; then
        print_warn "Last 50 forwarded log lines for '$svc' (docker logs is empty for this service while central logging is active -- see $today_file):"
        tail -n 50 "$today_file" 2>&1 | sed 's/^/    /' || print_warn "Could not read $today_file (may have rotated mid-read)."
    else
        print_warn "No forwarded syslog-ng log file found for '$svc' yet at $today_file."
    fi
}

# What: polls health and functional probe until timeout
# Why: pre-update unhealthy services do not block the update
wait_for_stack_health() {
    local timeout_seconds="$1"
    shift
    local -a services=("$@")
    local interval_seconds=3 elapsed=0 svc all_healthy baseline
    local -a regressed_services pre_existing_unhealthy_services

    while (( elapsed < timeout_seconds )); do
        all_healthy=1
        regressed_services=()
        pre_existing_unhealthy_services=()
        for svc in "${services[@]}"; do
            if ! service_container_is_healthy "$svc"; then
                baseline="${_UPDATE_HEALTH_BASELINE[$svc]-1}"
                if [[ "$baseline" = "1" ]]; then
                    all_healthy=0
                    regressed_services+=("$svc")
                else
                    pre_existing_unhealthy_services+=("$svc")
                fi
            fi
        done
        if [[ "$all_healthy" = "1" ]] && verify_stack_functional_health; then
            if (( ${#pre_existing_unhealthy_services[@]} > 0 )); then
                print_warn "Proceeding despite service(s) unhealthy before this update started too (not a regression this update caused, so not blocking it): ${pre_existing_unhealthy_services[*]}"
            fi
            return 0
        fi
        sleep "$interval_seconds"
        elapsed=$((elapsed + interval_seconds))
    done

    if (( ${#regressed_services[@]} > 0 )); then
        print_error "Service(s) regressed from healthy to unhealthy during this update: ${regressed_services[*]}"
        # What: dumps each regressed service's recent logs
        # Why: CI and operators need the cause
        for svc in "${regressed_services[@]}"; do
            local container_id
            # What: container id lookup is an if condition
            # Why: set -e would abort the update
            if container_id=$(service_container_id "$svc") && [[ -n "$container_id" ]]; then
                print_warn "Last 50 log lines for regressed service '$svc' (container $container_id):"
                docker logs --tail 50 "$container_id" 2>&1 | sed 's/^/    /' || print_warn "Could not retrieve logs for '$svc' (container may already be gone)."
            else
                print_warn "No container found for regressed service '$svc'; cannot dump its logs."
            fi
            if [[ -n "${_REGRESSED_SERVICE_SYSLOG_HOST[$svc]-}" ]]; then
                local logging_enabled
                logging_enabled=$(get_env_var LOGGING_ENABLED "$_UPDATE_ENV_FILE") || {
                    print_warn "Cannot read LOGGING_ENABLED (exit $?); skipping the syslog-ng tail of $svc."
                    logging_enabled=0
                }
                if [[ "${logging_enabled:-1}" = "1" ]]; then
                    dump_service_syslog_ng_tail "$svc" "${_REGRESSED_SERVICE_SYSLOG_HOST[$svc]}"
                fi
            fi
        done
    fi
    return 1
}

# What: restores the newest pre-update config backup
# Why: reuses cmd_restore instead of a second rollback path
rollback_stack_update() {
    local install_dir="$1"
    local backup_root="$BACKUP_ROOT"
    local latest_backup="" backups

    if [[ -d "$backup_root" ]]; then
        if ! backups=$(find "$backup_root" -maxdepth 1 -name 'lancache-ng-config-*.tar.gz' -print); then
            print_error "Failed to list the backups under $backup_root; cannot roll back automatically. Manual recovery required."
            return 1
        fi
        latest_backup=$(sort <<< "$backups" | tail -1)
    fi
    if [[ -z "$latest_backup" ]]; then
        print_error "No pre-update backup archive found under $backup_root; cannot roll back automatically. Manual recovery required."
        return 1
    fi

    # What: the checkout returns to its pre-update revision
    # Why: old config on new compose would be a mixed stack
    # From: Issue #1683 | PR #1858
    if [[ -n "${LANCACHE_UPDATE_OLD_SHA:-}" ]]; then
        git -C "$LANCACHE_UPDATE_REPO" checkout -q -f -B "$LANCACHE_UPDATE_BRANCH" "$LANCACHE_UPDATE_OLD_SHA" \
            || { print_error "Failed to return $LANCACHE_UPDATE_REPO to $LANCACHE_UPDATE_OLD_SHA (exit $?). Manual recovery required."; return 1; }
        print_warn "Returned $LANCACHE_UPDATE_REPO to $LANCACHE_UPDATE_OLD_SHA"
    fi
    print_warn "Rolling back to pre-update backup: $latest_backup"
    if cmd_restore "$latest_backup" "$install_dir"; then
        print_ok "Rollback completed; stack restored to its pre-update state."
        return 0
    fi
    print_error "Rollback itself failed. Manual recovery required: inspect $latest_backup and $install_dir directly."
    return 1
}

# What: non-UI first, then UI; each gated; rollback on fail
# Why: the caller's rollback fits the state it changed
# From: Issue #1683 | PR #1858
apply_stack_update_ordered() {
    local install_dir="$1"
    local -a all_services non_ui_services rollback=("${@:2}")
    [[ "${#rollback[@]}" -gt 0 ]] || rollback=(rollback_stack_update "$install_dir")
    local svc services

    services=$(stack_compose "$install_dir" "$_UPDATE_ENV_FILE" config --services) \
        || die "Cannot list the services of $install_dir (exit $?); nothing was started."
    mapfile -t all_services <<< "$services"
    non_ui_services=()
    for svc in "${all_services[@]}"; do
        [[ "$svc" = "ui" ]] && continue
        non_ui_services+=("$svc")
    done
    # What: fails closed if no non-UI service exists
    # Why: empty args would make compose start the UI too
    (( ${#non_ui_services[@]} > 0 )) \
        || die "No non-UI services found in this compose configuration; refusing to apply an update that cannot guarantee UI-last ordering."

    # What: baseline is captured earlier by the caller
    # Why: earlier steps may already change containers
    if stack_update_step "Starting non-UI services" "Failed to start non-UI services." \
            stack_compose "$install_dir" "$_UPDATE_ENV_FILE" up -d --remove-orphans "${non_ui_services[@]}" \
        && stack_update_step "Verifying non-UI services are healthy" "Non-UI services did not become healthy in time." \
            wait_for_stack_health 180 "${non_ui_services[@]}" \
        && stack_update_step "Starting Admin UI (last)" "Failed to start the Admin UI." \
            stack_compose "$install_dir" "$_UPDATE_ENV_FILE" up -d --remove-orphans ui \
        && stack_update_step "Verifying the whole stack is healthy" "Admin UI did not become healthy in time." \
            wait_for_stack_health 120 ui; then
        print_ok "Whole stack verified healthy"
        return 0
    fi
    # What: 1 = rolled back, 2 = the rollback failed too
    # Why: callers must not claim a rollback that failed
    # From: Issue #1683 | PR #1858
    "${rollback[@]}" || return 2
    return 1
}

# What: one update step: banner, run, message on failure
# Why: the ordered steps share one failure path
# From: Issue #1683 | PR #1858
stack_update_step() {
    local banner="$1" failure="$2" rc=0
    shift 2
    print_step "$banner"
    # What: the step runs in a subshell
    # Why: a die inside a step must reach the rollback path
    # From: Issue #1683 | PR #1858
    ( "$@" ) || rc=$?
    [[ "$rc" -ne 0 ]] || return 0
    print_error "$failure (exit $rc)"
    return 1
}

# What: pulls the checkout and reruns the update from it
# Why: compose, templates and setup.sh must move together
# From: Issue #1683 | PR #1858
update_repo_and_resume() {
    local install_dir="$1" repo_dir="$1" branch="" default changes old new baseline="" svc rc=0
    is_deploy_prod_install_dir "$install_dir" && repo_dir=$(deploy_prod_repo_root "$install_dir")
    if [[ ! -e "$repo_dir/.git" ]]; then
        print_ok "$repo_dir is not a git checkout; its files stay as they are"
        return 0
    fi
    branch=$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD) || rc=$?
    [[ "$rc" -le 1 ]] || die "Failed to read the branch of $repo_dir (exit $rc)."
    default=$(git_default_branch_name "$repo_dir")
    # What: a pinned or foreign ref is never moved
    # Why: the operator chose that revision (AG-OP-009)
    # From: Issue #1683 | PR #1858
    if [[ "$rc" -eq 1 || "$branch" != "$default" ]]; then
        print_warn "Checkout $repo_dir is on ${branch:-a pinned commit}, not $default; repository not updated."
        return 0
    fi
    changes=$(git -C "$repo_dir" status --porcelain) || die "Failed to read the git status of $repo_dir (exit $?)."
    if [[ -n "$changes" ]]; then
        print_warn "Checkout $repo_dir has local changes; repository not updated:"$'\n'"$changes"
        return 0
    fi
    old=$(git -C "$repo_dir" rev-parse HEAD) || die "Failed to read HEAD of $repo_dir (exit $?)."
    print_step "Updating repo"
    sync_repo_to_default_branch "$repo_dir"
    new=$(git -C "$repo_dir" rev-parse HEAD) || die "Failed to read HEAD of $repo_dir (exit $?)."
    if [[ "$new" = "$old" ]]; then
        print_ok "Repository already at $new"
        return 0
    fi
    for svc in "${!_UPDATE_HEALTH_BASELINE[@]}"; do baseline+="${svc}=${_UPDATE_HEALTH_BASELINE[$svc]} "; done
    print_ok "Repository moved $old -> $new; continuing with its setup.sh"
    export LANCACHE_UPDATE_RESUMED=1 LANCACHE_UPDATE_REPO="$repo_dir" LANCACHE_UPDATE_BRANCH="$branch" \
        LANCACHE_UPDATE_OLD_SHA="$old" LANCACHE_UPDATE_BASELINE="$baseline" LANCACHE_BACKUP_ROOT="$BACKUP_ROOT" \
        CONVERGENCE_TIMER_WAS_ACTIVE CONVERGENCE_TIMER_WAS_ENABLED CONVERGENCE_SERVICE_WAS_ACTIVE
    # What: a failed exec returns here instead of exiting
    # Why: bash skips the EXIT trap when exec itself fails
    # From: Issue #1683 | PR #1858
    shopt -s execfail
    exec "$repo_dir/setup.sh" update "$install_dir"
    die "Failed to start $repo_dir/setup.sh (exit $?); the stack was not changed."
}

# What: takes the paused state and baseline over after exec
# Why: the timer stays paused and gates keep their baseline
# From: Issue #1683 | PR #1858
update_resume_handoff() {
    local pair
    [[ -n "${CONVERGENCE_TIMER_WAS_ACTIVE:-}" && -n "${CONVERGENCE_TIMER_WAS_ENABLED:-}" \
        && -n "${CONVERGENCE_SERVICE_WAS_ACTIVE:-}" && -n "${LANCACHE_UPDATE_REPO:-}" ]] \
        || die "LANCACHE_UPDATE_RESUMED is set without the state of the paused update; rerun setup.sh update without it."
    _UPDATE_HEALTH_BASELINE=()
    for pair in ${LANCACHE_UPDATE_BASELINE:-}; do
        _UPDATE_HEALTH_BASELINE["${pair%%=*}"]="${pair#*=}"
    done
    print_ok "Continuing the update with $LANCACHE_UPDATE_REPO/setup.sh"
}

# What: runs update steps in fixed order, with rollback
# Why: reordering can leave a half-migrated stack running
perform_stack_update_flow() {
    local install_dir="$1"
    if is_quickstart_install "$install_dir"; then
        migrate_quickstart_install "$install_dir" || exit $?
        install_dir="${PROD_COMPOSE%/*}"
    fi
    install_dir=$(resolve_stack_dir "$install_dir") || exit $?
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die_no_stack_found "$install_dir"
    assert_prebuilt_image_platform_supported
    # What: installs curl, dig and jq before any mutation
    # Why: the functional health gate must not silently skip
    install_missing_tools curl dig jq
    cd "$install_dir"
    _UPDATE_ENV_FILE=$(runtime_env_file_for_install_dir "$install_dir")
    _UPDATE_STACK_DIR="$install_dir"
    # What: tells the operator the NATS override is in use
    # Why: it changes which compose files the update runs
    # From: Issue #1683 | PR #1858
    if nats_secondary_override_active_for_install_dir "$install_dir" "$_UPDATE_ENV_FILE"; then
        print_ok "NATS_BIND_IP is set; keeping the remote-secondary NATS override active for this update"
    fi

    UPDATE_CONVERGENCE_COMPLETED=0
    if [[ "${LANCACHE_UPDATE_RESUMED:-0}" = 1 ]]; then
        update_resume_handoff
        UPDATE_CONVERGENCE_PAUSED=1
        trap resume_lancache_convergence_after_failed_update EXIT
    else
        # What: health baseline before sync, backup, restart
        # Why: a later restart bakes regressions into it
        # From: Issue #1391
        print_step "Capturing pre-update health baseline"
        local -a _update_baseline_services
        local baseline_services
        baseline_services=$(stack_compose "$install_dir" "$_UPDATE_ENV_FILE" config --services) \
            || die "Cannot list the services of $install_dir (exit $?); nothing was changed."
        mapfile -t _update_baseline_services <<< "$baseline_services"
        capture_stack_health_baseline "${_update_baseline_services[@]}"

        UPDATE_CONVERGENCE_PAUSED=0
        trap resume_lancache_convergence_after_failed_update EXIT
        UPDATE_CONVERGENCE_PAUSED=1
        pause_lancache_convergence_for_update
    fi

    # What: deploy/prod template edits move into .local.env
    # Why: a clean checkout keeps git pulls possible
    # From: Issue #1683 | PR #1858
    if is_deploy_prod_install_dir "$install_dir"; then
        adopt_config_prod_edits "$(deploy_prod_repo_root "$install_dir")"
    fi

    if [[ "${LANCACHE_UPDATE_RESUMED:-0}" != 1 ]]; then
        print_step "Creating pre-update rollback backup"
        if ! ( cmd_backup --config "$install_dir" ); then
            trap - EXIT
            resume_lancache_convergence_after_update true
            UPDATE_CONVERGENCE_COMPLETED=1
            die "Pre-update rollback backup failed. The convergence timer was restored because no update mutations were applied."
        fi
        update_repo_and_resume "$install_dir"
    fi

    migrate_env_for_update "$install_dir"
    validate_compose_config "$install_dir"

    print_step "Pulling selected images"
    stack_compose "$install_dir" "$_UPDATE_ENV_FILE" pull \
        || die "Failed to pull required container images. Check network access and GHCR authentication, then rerun setup.sh update."

    validate_compose_config "$install_dir"

    local apply_rc=0
    apply_stack_update_ordered "$install_dir" || apply_rc=$?
    if [[ "$apply_rc" -ne 0 ]]; then
        trap - EXIT
        UPDATE_CONVERGENCE_COMPLETED=1
        [[ "$apply_rc" -eq 1 ]] \
            || die_convergence_kept_paused "The update failed its health gate, and the rollback to the pre-update backup failed too."
        resume_lancache_convergence_after_update
        die "Update failed its post-update health gate and was rolled back to the pre-update backup. Investigate before retrying."
    fi

    trap - EXIT
    resume_lancache_convergence_after_update
    UPDATE_CONVERGENCE_COMPLETED=1
    print_ok "Stack updated"
}

# ── update subcommand ─────────────────────────────────────────────────────────
cmd_update() {
    local install_dir="${1:-$DEFAULT_INSTALL_DIR}"
    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?
    perform_stack_update_flow "$install_dir"
}

# What: docker compose args for an install, with its files
# Why: units and operators start the stack exactly as setup
# From: Issue #1683 | PR #1858
cmd_compose() {
    local install_dir
    [[ $# -ge 1 ]] || die "Usage: setup.sh compose <install-dir> <compose args>"
    install_dir=$(resolve_stack_dir "$(realpath -m "$1")")
    shift
    [[ -f "$install_dir/docker-compose.yml" ]] || die_no_stack_found "$install_dir"
    stack_compose "$install_dir" "$(runtime_env_file_for_install_dir "$install_dir")" "$@"
}

# What: proceed/skip for one auto-update tick, no I/O
# Why: kept pure so the decision is testable without docker
# From: Issue #819
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
# What: scheduled update tick; detects a channel move first
# Why: an unchanged channel must not restart the stack
cmd_auto_update() {
    local install_dir="${1:-$DEFAULT_INSTALL_DIR}"
    local env_file auto_update_enabled current_channel current_tag deployed_tag decision
    local deployed_refs current_refs

    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die_no_stack_found "$install_dir"
    env_file=$(runtime_env_file_for_install_dir "$install_dir")

    # What: re-checks AUTO_UPDATE_ENABLED before acting
    # Why: a timer may stay enabled after .env is edited
    auto_update_enabled=$(get_env_var AUTO_UPDATE_ENABLED "$env_file") || exit $?
    current_channel=$(resolve_lancache_image_channel "$env_file") || exit $?
    # What: stacks compared by image-pin fingerprint
    # Why: the channel word stays while digests move
    # From: Issue #1683 | PR #1858
    deployed_refs=$(awk '/^LANCACHE_IMAGE_REF_[A-Z_]+=/' "$env_file") \
        || die "Failed to read the image pins from $env_file (exit $?)."
    deployed_tag=$(lancache_image_refs_fingerprint "$deployed_refs") \
        || die "Cannot fingerprint the deployed image pins of $env_file (exit $?)."
    # What: resolves the channel after local checks
    # Why: disabled or pinned installs skip the registry
    if [[ "$auto_update_enabled" = "1" && "$current_channel" != "pinned" ]]; then
        current_refs=$(lancache_channel_image_refs "$env_file" "$current_channel") \
            || die "Cannot resolve channel ${current_channel}; auto-update skipped this tick (exit $?)."
        current_tag=$(lancache_image_refs_fingerprint "$current_refs") \
            || die "Cannot fingerprint the current image pins of channel ${current_channel} (exit $?)."
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
# What: true if the UI channel is in the selectable list
# Why: edge and dev are hard cuts; no-op, not die, on a tick
lancache_ui_channel_override_is_valid() {
    local channel
    for channel in "${LANCACHE_SELECTABLE_CHANNELS[@]}"; do
        [[ "$1" = "$channel" ]] && return 0
    done
    return 1
}

# What: channels wizard and Admin UI offer; first = default
# Why: one list; a secondary runs without the SOT checkout
# From: Issue #1683 | PR #1858
LANCACHE_SELECTABLE_CHANNELS=(nightly stable)

# What: true for a positive whole number of GiB
# Why: a leading 0 must parse as decimal, not octal
lancache_ui_cache_max_gb_override_is_valid() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    (( 10#$1 > 0 ))
}

# What: reads one KEY from the ui-data settings file
# Why: checks the volume exists; docker run would create it
lancache_read_ui_settings_override() {
    local install_dir="$1" env_file="$2" key="$3" project volume raw rc=0
    command -v docker >/dev/null 2>&1 || return 0
    require_helper_image
    project=$(compose_project_name "$install_dir" "$env_file") \
        || die "Cannot resolve the compose project of $install_dir (exit $?)."
    volume="${project}_ui-data"
    docker_volume_exists "$volume" || rc=$?
    [[ "$rc" -ne 1 ]] || return 0
    [[ "$rc" -eq 0 ]] || die "Cannot check the Docker volume $volume; the UI settings were not read."
    raw=$(docker run --rm -v "${volume}:/volume:ro" "$LANCACHE_HELPER_IMAGE" \
        sh -c 'if [ -e /volume/lancache-ui-settings.env ]; then cat /volume/lancache-ui-settings.env; fi') \
        || die "Failed to read the UI settings from Docker volume $volume (exit $?)."
    # What: sed reads $raw via a here-string
    # Why: avoids SIGPIPE under pipefail
    # From: Issue #1377
    sed -n "s/^${key}=//p" <<<"$raw" | tail -1
}

# What: syncs auto-update timer with AUTO_UPDATE_ENABLED
# Why: the .env value is the source of truth
reconcile_auto_update_timer_state() {
    local env_file="$1" desired out
    systemd_unit_exists "$AUTO_UPDATE_TIMER_UNIT" || return 0
    desired=$(get_env_var AUTO_UPDATE_ENABLED "$env_file") \
        || die "Cannot read AUTO_UPDATE_ENABLED from $env_file (exit $?)."
    if [[ "$desired" = "1" ]]; then
        out=$(systemctl enable --now "$AUTO_UPDATE_TIMER_UNIT" 2>&1) \
            || die "Failed to enable $AUTO_UPDATE_TIMER_UNIT (exit $?): $out"
    else
        out=$(systemctl disable --now "$AUTO_UPDATE_TIMER_UNIT" 2>&1) \
            || die "Failed to disable $AUTO_UPDATE_TIMER_UNIT (exit $?): $out"
    fi
}

cmd_converge_reconcile() {
    local install_dir="${1:-$DEFAULT_INSTALL_DIR}" env_file
    local ui_channel ui_auto_update current_channel current_auto_update
    local ui_cache_max_gb current_cache_max_gb
    local ui_dhcp_mode current_dhcp_mode current_compose_profiles new_compose_profiles
    local current_ntp_enabled ui_logging_enabled current_logging_enabled

    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?
    # What: a tick before the first install does nothing
    # Why: no compose file or .env exists to converge
    [[ -f "$install_dir/docker-compose.yml" ]] || return 0
    command -v docker >/dev/null 2>&1 || return 0
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    [[ -f "$env_file" ]] || return 0

    ui_channel=$(lancache_read_ui_settings_override "$install_dir" "$env_file" "LANCACHE_IMAGE_CHANNEL") \
        || die "Cannot read the UI setting LANCACHE_IMAGE_CHANNEL (exit $?)."
    if [[ -n "$ui_channel" ]] && lancache_ui_channel_override_is_valid "$ui_channel"; then
        current_channel=$(get_env_var LANCACHE_IMAGE_CHANNEL "$env_file") || exit $?
        if [[ "$ui_channel" != "$current_channel" ]]; then
            set_env_key LANCACHE_IMAGE_CHANNEL "$ui_channel" "$env_file"
            print_ok "Release channel updated from Admin UI: ${current_channel:-<unset>} -> $ui_channel"
        fi
    fi

    ui_auto_update=$(lancache_read_ui_settings_override "$install_dir" "$env_file" "AUTO_UPDATE_ENABLED") \
        || die "Cannot read the UI setting AUTO_UPDATE_ENABLED (exit $?)."
    if [[ "$ui_auto_update" = "0" || "$ui_auto_update" = "1" ]]; then
        current_auto_update=$(get_env_var AUTO_UPDATE_ENABLED "$env_file") || exit $?
        if [[ "$ui_auto_update" != "$current_auto_update" ]]; then
            set_env_key AUTO_UPDATE_ENABLED "$ui_auto_update" "$env_file"
            print_ok "Scheduled automatic updates setting updated from Admin UI: ${ui_auto_update} (was ${current_auto_update:-0})"
        fi
    fi

    # What: folds the UI DHCP mode into .env profiles
    # Why: UI cannot create containers, only start them
    ui_dhcp_mode=$(lancache_read_ui_settings_override "$install_dir" "$env_file" "DHCP_MODE") \
        || die "Cannot read the UI setting DHCP_MODE (exit $?)."
    if [[ -n "$ui_dhcp_mode" ]] && is_valid_dhcp_mode "$ui_dhcp_mode"; then
        current_dhcp_mode=$(get_env_var DHCP_MODE "$env_file") || exit $?
        if [[ "$ui_dhcp_mode" != "$current_dhcp_mode" ]]; then
            current_compose_profiles=$(get_env_var COMPOSE_PROFILES "$env_file") || exit $?
            # What: keeps NTP and logging profiles
            # Why: omitted flags would drop those profiles
            current_ntp_enabled=$(get_env_var NTP_ENABLED "$env_file") || exit $?
            current_logging_enabled=$(get_env_var LOGGING_ENABLED "$env_file") || exit $?
            new_compose_profiles=$(compose_profiles_for_runtime \
                "$current_compose_profiles" "$ui_dhcp_mode" "$current_ntp_enabled" "$current_logging_enabled")
            set_env_key DHCP_MODE "$ui_dhcp_mode" "$env_file"
            set_env_key COMPOSE_PROFILES "$new_compose_profiles" "$env_file"
            print_ok "DHCP mode updated from Admin UI: ${current_dhcp_mode:-<unset>} -> $ui_dhcp_mode (COMPOSE_PROFILES: ${current_compose_profiles:-<none>} -> ${new_compose_profiles:-<none>})"
        fi
    fi

    # What: folds the Admin UI logging toggle into profiles
    # Why: the syslog services are profile-gated
    ui_logging_enabled=$(lancache_read_ui_settings_override "$install_dir" "$env_file" "LOGGING_ENABLED") \
        || die "Cannot read the UI setting LOGGING_ENABLED (exit $?)."
    if [[ "$ui_logging_enabled" = "0" || "$ui_logging_enabled" = "1" ]]; then
        current_logging_enabled=$(get_env_var LOGGING_ENABLED "$env_file") || exit $?
        if [[ "$ui_logging_enabled" != "$current_logging_enabled" ]]; then
            current_compose_profiles=$(get_env_var COMPOSE_PROFILES "$env_file") || exit $?
            current_dhcp_mode=$(get_env_var DHCP_MODE "$env_file") || exit $?
            current_ntp_enabled=$(get_env_var NTP_ENABLED "$env_file") || exit $?
            new_compose_profiles=$(compose_profiles_for_runtime \
                "$current_compose_profiles" "$current_dhcp_mode" "$current_ntp_enabled" "$ui_logging_enabled")
            set_env_key LOGGING_ENABLED "$ui_logging_enabled" "$env_file"
            set_env_key COMPOSE_PROFILES "$new_compose_profiles" "$env_file"
            print_ok "Central logging updated from Admin UI: ${current_logging_enabled:-<unset>} -> $ui_logging_enabled (COMPOSE_PROFILES: ${current_compose_profiles:-<none>} -> ${new_compose_profiles:-<none>})"
        fi
    fi

    # Reconciles the timer against .env's CURRENT value regardless of whether
    # the block above just changed it or it was already correct -- covers a
    # direct manual .env edit too, not only the Admin UI path.
    reconcile_auto_update_timer_state "$env_file"

    # What: UI cache size -> CACHE_MAX_SIZE and CACHE_MAX_GB
    # Why: nginx and the dashboard read one value pair
    # From: Issue #1069 | PR #1858
    ui_cache_max_gb=$(lancache_read_ui_settings_override "$install_dir" "$env_file" "CACHE_MAX_GB") \
        || die "Cannot read the UI setting CACHE_MAX_GB (exit $?)."
    if [[ -n "$ui_cache_max_gb" ]] && lancache_ui_cache_max_gb_override_is_valid "$ui_cache_max_gb"; then
        ui_cache_max_gb=$(( 10#$ui_cache_max_gb ))
        current_cache_max_gb=$(get_env_var CACHE_MAX_GB "$env_file") || exit $?
        if [[ "$ui_cache_max_gb" != "$current_cache_max_gb" ]]; then
            set_env_key CACHE_MAX_SIZE "${ui_cache_max_gb}g" "$env_file"
            set_env_key CACHE_MAX_GB "$ui_cache_max_gb" "$env_file"
            print_ok "Cache size updated from Admin UI: ${current_cache_max_gb:-<unset>} GB -> ${ui_cache_max_gb} GB"
        fi
    fi
}

# ── debug subcommand ──────────────────────────────────────────────────────────
# Debug is read-only diagnostics. It must not repair, update, or rewrite config;
# operators use it when the stack is already in an unknown state.
cmd_debug() {
    local install_dir="${1:-$DEFAULT_INSTALL_DIR}"
    local env_file
    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die_no_stack_found "$install_dir"

    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    local ip_standard ip_ssl cache_dir cache_std cache_ssl
    ip_standard=$(get_env_var IP_STANDARD "$env_file") || exit $?
    ip_ssl=$(get_env_var IP_SSL "$env_file") || exit $?
    cache_dir=$(get_env_var CACHE_DIR "$env_file") || exit $?
    cache_std=$(get_env_var CACHE_DIR_STANDARD "$env_file") || exit $?
    cache_ssl=$(get_env_var CACHE_DIR_SSL "$env_file") || exit $?
    if [[ -z "$cache_dir" ]]; then
        if [[ -n "$cache_std" && -n "$cache_ssl" && "$cache_std" != "$cache_ssl" ]]; then
            print_error "Legacy cache paths differ; set CACHE_DIR before relying on cache debug output."
        else
            cache_dir="${cache_std:-$cache_ssl}"
        fi
    fi

    print_step "Container status"
    stack_compose "$install_dir" "$env_file" ps || print_error "docker compose ps failed (exit $?)."

    print_step "Logs (last 30 lines per service)"
    # What: logs of every service the compose files define
    # Why: a fixed list misses profile services
    # From: Issue #1683 | PR #1858
    local services svc
    if services=$(stack_compose "$install_dir" "$env_file" config --services); then
        while IFS= read -r svc; do
            [[ -n "$svc" ]] || continue
            printf "\n${BOLD}--- %s ---${RESET}\n" "$svc"
            stack_compose "$install_dir" "$env_file" logs --tail=30 "$svc" 2>&1 \
                || print_error "Logs of $svc failed (exit $?)."
        done <<< "$services"
    else
        print_error "Cannot list the compose services of $install_dir (exit $?)."
    fi

    print_step "Cache usage"
    if [[ -n "$cache_dir" ]]; then
        if [[ -d "$cache_dir" ]]; then
            du -sh "$cache_dir" || print_error "Failed to measure $cache_dir (exit $?)."
        else
            print_warn "Directory not found: $cache_dir"
        fi
    fi

    print_step "Network (LAN IPs)"
    local addrs
    if addrs=$(host_lan_addresses); then
        awk '{ print "    " $1 "/" $2 " dev " $3 }' <<< "$addrs"
    else
        print_error "Failed to list the IPv4 addresses of this host (exit $?)."
    fi

    print_step "Health checks"
    if ! command -v curl >/dev/null 2>&1; then
        print_warn "curl not found — health checks skipped"
    else
        local ip probe
        for ip in "$ip_standard" "$ip_ssl"; do
            [[ -z "$ip" ]] && continue
            if probe=$(curl -sS -f -o /dev/null "http://$ip/healthz" 2>&1); then
                print_ok "http://$ip/healthz — OK"
            else
                print_error "http://$ip/healthz — ERROR (exit $?): $probe"
            fi
        done
    fi
}

# ── create-logs-for-issue subcommand ──────────────────────────────────────────
# What: bundles redacted diagnostics for a bug report
# Why: secrets leak via compose config and logs too

# What: every secret env key setup.sh makes and redacts
# Why: one list; generation refuses a key not on it
# From: Issue #762 | PR #1858
managed_secret_env_keys() {
    printf '%s\n' \
        KEA_CTRL_TOKEN \
        DDNS_TSIG_KEY \
        PDNS_API_KEY \
        NETDATA_ALARM_TOKEN \
        NATS_UI_PASSWORD \
        NATS_DNS_WRITER_PASSWORD \
        NATS_DNS_REPLICA_PASSWORD \
        NATS_CALLOUT_PASSWORD \
        NATS_SYS_PASSWORD \
        SECONDARY_REGISTRATION_TOKEN \
        UI_AUTH_PASSWORD
}

# What: name-pattern net for secret-shaped env keys
# Why: an operator's own secret key is redacted too
# From: Issue #762
logbundle_key_looks_like_secret() {
    local key="$1"
    [[ "$key" =~ (PASSWORD|SECRET|TOKEN|TSIG|CREDENTIAL|_KEY) ]]
}

# What: each set secret value, one per line, longest first
# Why: values also leak in compose config and logs
# From: Issue #782
logbundle_collect_secret_values() {
    local -a env_files=("$@")
    local -A key_set=()
    local key env_file value

    local keys rc
    keys=$(managed_secret_env_keys) || die "Cannot list the secret env keys (exit $?)."
    while IFS= read -r key; do
        [[ -n "$key" ]] && key_set["$key"]=1
    done <<< "$keys"

    for env_file in "${env_files[@]}"; do
        [[ -f "$env_file" ]] || continue
        rc=0
        keys=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "$env_file") || rc=$?
        [[ "$rc" -le 1 ]] || die "Failed to read the keys of $env_file (exit $rc); no log bundle was written."
        while IFS= read -r key; do
            [[ -n "$key" ]] || continue
            logbundle_key_looks_like_secret "$key" && key_set["$key"]=1
        done <<< "$keys"
    done

    for key in "${!key_set[@]}"; do
        for env_file in "${env_files[@]}"; do
            [[ -f "$env_file" ]] || continue
            value=$(get_env_var_nonempty "$key" "$env_file") \
                || die "Cannot read $key from $env_file (exit $?); no log bundle was written."
            [[ -n "$value" ]] || continue
            # What: skips default placeholder secrets
            # Why: redacting placeholders clutters logs
            # From: Issue #782
            secret_value_is_placeholder "$value" && continue
            printf '%s\n' "$value"
        done
    # What: sorts secrets longest first
    # Why: a shorter value would corrupt a longer one
    # From: Issue #782
    done | sort -u | awk '{ print length, $0 }' | sort -k1,1nr | cut -d' ' -f2-
}

# What: replaces every secret value with [REDACTED]
# Why: plain substitution; base64 punctuation is safe
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

# What: writes a command's redacted output and exit status
# Why: a failed check is evidence, not a silent abort
# From: Issue #1683 | PR #1858
logbundle_capture() {
    local secrets_file="$1" out="$2" text rc=0
    shift 2
    text=$("$@" 2>&1) || rc=$?
    [[ "$rc" -eq 0 ]] || text+=$'\n'"(exit $rc)"
    logbundle_redact_stream "$secrets_file" <<< "$text" > "$out" \
        || die "Failed to write $out (exit $?)."
}

# What: copies env file; redacts secret-shaped values
# Why: placeholders are redacted too, defaults stay hidden
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

# What: prints the best available compressor: zst, bz2 or gz
# Why: gzip is always present, so the chain terminates
logbundle_select_compressor() {
    if command -v zstd >/dev/null 2>&1; then
        printf 'zst\n'
    elif command -v bzip2 >/dev/null 2>&1; then
        printf 'bz2\n'
    else
        printf 'gz\n'
    fi
}

# What: lists known-good snapshot volumes with ls only
# Why: volumes are not host paths; ls runs in a container
logbundle_named_volume_listing() {
    local install_dir="$1" env_file="$2" base_name="$3" subpath="$4" out="$5"
    if ! command -v docker >/dev/null 2>&1; then
        printf 'docker not available; skipped\n' > "$out"
        return 0
    fi
    local project volume err rc=0 prc=0
    project=$(compose_project_name "$install_dir" "$env_file") || prc=$?
    if [[ "$prc" -ne 0 ]]; then
        printf 'compose project lookup failed (exit %s); see the setup.sh output\n' "$prc" > "$out"
        return 0
    fi
    volume="${project}_${base_name}"
    err=$(docker_volume_exists "$volume" 2>&1) || rc=$?
    if [[ "$rc" -eq 1 ]]; then
        printf 'volume %s not found (not created yet)\n' "$volume" > "$out"
        return 0
    elif [[ "$rc" -ne 0 ]]; then
        printf 'volume lookup failed: %s\n' "$err" > "$out"
        return 0
    fi
    require_helper_image
    docker run --rm -v "${volume}:/data:ro" "$LANCACHE_HELPER_IMAGE" \
        sh -c 'p="/data/$1"; if [ -e "$p" ]; then ls -laR "$p"; else echo "(no snapshots yet)"; fi' sh "$subpath" \
        > "$out" 2>&1 || printf '(listing failed, exit %s)\n' "$?" >> "$out"
}

# What: lists a known-good snapshot host path directly
# Why: Kea's snapshot path is a plain bind mount
logbundle_host_path_listing() {
    local dir="$1" out="$2"
    if [[ -d "$dir" ]]; then
        ls -laR "$dir" > "$out" 2>&1 || printf '(listing failed, exit %s)\n' "$?" >> "$out"
    else
        printf 'directory %s not found\n' "$dir" > "$out"
    fi
}

# What: redacted issue log bundle; the body is a subshell
# Why: its EXIT trap reads the state; nothing leaks out
# From: Issue #1683 | PR #1858
cmd_create_logs_for_issue() (
    local install_dir="$DEFAULT_INSTALL_DIR"
    local dest_root="$BACKUP_ROOT"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dest) dest_root="${2:?Missing value for --dest}"; shift 2 ;;
            *) install_dir="$1"; shift ;;
        esac
    done
    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?
    dest_root=$(realpath -m "$dest_root")
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die_no_stack_found "$install_dir"
    install_missing_tools tar

    local env_file cache_env_file state_dir
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    cache_env_file="$install_dir/.env"
    state_dir=$(install_state_root "$install_dir" "$env_file") \
        || die "Cannot resolve the state root of $install_dir (exit $?)."

    local -a env_files=("$env_file")
    [[ "$cache_env_file" != "$env_file" && -f "$cache_env_file" ]] && env_files+=("$cache_env_file")

    local stamp ext archive
    secrets_file=""
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    dest="$dest_root/.create-logs-for-issue-$stamp"
    old_umask=$(umask)
    umask 077

    # What: cleanup removes the workspace and secrets file
    # Why: the secrets file must not outlive this run
    logbundle_cleanup() {
        local status=$?
        rm -rf "$dest" || print_error "Failed to remove the bundle workspace $dest (exit $?)."
        [[ -z "$secrets_file" ]] || rm -f "$secrets_file" \
            || print_error "Failed to remove the secret scratch file $secrets_file (exit $?); delete it by hand."
        umask "$old_umask"
        trap - EXIT
        return "$status"
    }
    trap logbundle_cleanup EXIT
    mkdir -p "$dest_root" "$dest/logs" "$dest/env" "$dest/known-good-snapshots" \
        || die "Failed to create the bundle directories under $dest_root (exit $?)."
    secrets_file=$(mktemp) || die "Could not create a temporary file for secret redaction."
    chmod 600 "$secrets_file" || die "Failed to restrict $secrets_file (exit $?)."

    print_step "Collecting diagnostic bundle for issue report"

    logbundle_collect_secret_values "${env_files[@]}" > "$secrets_file" \
        || die "Cannot collect the secret values to redact (exit $?); no log bundle was written."

    # What: writes Docker, Compose, disk and distro facts
    # Why: the fuller version strings help triage
    {
        printf 'Generated: %s UTC\n' "$stamp"
        printf 'Install directory: %s\n' "$install_dir"
        printf 'Docker: %s\n' "$(docker --version 2>&1 || printf ' (exit %s)' "$?")"
        printf 'Docker Compose: %s\n' "$(docker compose version 2>&1 || printf ' (exit %s)' "$?")"
        printf 'Kernel: %s\n' "$(uname -srm 2>&1 || printf ' (exit %s)' "$?")"
        printf 'OS: %s\n' "$(if [[ -r /etc/os-release ]]; then (. /etc/os-release; printf '%s' "${PRETTY_NAME:-$ID $VERSION_ID}"); else printf 'unknown'; fi)"
        printf '\nDisk usage:\n'
        df -h 2>&1 || printf '(df failed, exit %s)\n' "$?"
    } | logbundle_redact_stream "$secrets_file" > "$dest/host-facts.txt"

    print_step "Container status and configuration"
    logbundle_capture "$secrets_file" "$dest/compose-ps.txt" stack_compose "$install_dir" "$env_file" ps
    # What: config output is redacted like logs
    # Why: config re-interpolates ${VAR} secret values
    logbundle_capture "$secrets_file" "$dest/compose-config.txt" stack_compose "$install_dir" "$env_file" config

    print_step "Collecting service logs"
    local -a services=()
    local services_list slrc=0
    services_list=$(stack_compose "$install_dir" "$env_file" config --services 2>&1) || slrc=$?
    if [[ "$slrc" -ne 0 ]]; then
        printf 'service list failed (exit %s): %s\n' "$slrc" "$services_list" \
            | logbundle_redact_stream "$secrets_file" > "$dest/logs/_service-list-error.log"
        print_warn "Could not list the compose services; see logs/_service-list-error.log in the bundle."
        services_list=""
    fi
    mapfile -t services <<< "$services_list"
    local svc
    for svc in "${services[@]}"; do
        [[ -n "$svc" ]] || continue
        print_ok "Logs: $svc"
        logbundle_capture "$secrets_file" "$dest/logs/$svc.log" \
            stack_compose "$install_dir" "$env_file" logs --no-color --timestamps --tail=2000 "$svc"
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
    ssl_enabled=$(get_env_var SSL_ENABLED "$env_file") || die "Cannot read SSL_ENABLED from $env_file (exit $?)."
    if [[ "$ssl_enabled" = "1" ]]; then
        logbundle_named_volume_listing "$install_dir" "$env_file" pdns-config-snapshots-ssl config-snapshots \
            "$dest/known-good-snapshots/dns-ssl.txt"
    fi
    # What: Kea snapshots: host path, then named volume
    # Why: pre-v0.3.0 dev stacks used a named volume
    local kea_dir
    kea_dir=$(prod_state_dir_for_key KEA_DATA_DIR "$env_file" "$state_dir") \
        || die "Cannot resolve KEA_DATA_DIR of $install_dir (exit $?)."
    if [[ -d "$kea_dir" ]]; then
        logbundle_host_path_listing "$kea_dir/config-snapshots" "$dest/known-good-snapshots/kea.txt"
    else
        logbundle_named_volume_listing "$install_dir" "$env_file" kea-data config-snapshots \
            "$dest/known-good-snapshots/kea.txt"
    fi

    cat > "$dest/README.txt" <<EOF || die "Failed to write $dest/README.txt."
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
    local tar_rc=0
    write_compressed_tar "$ext" "$archive" "$dest_root" "$(basename "$dest")" || tar_rc=$?
    if [[ "$tar_rc" -ne 0 ]]; then
        rm -f "$archive" || print_error "Failed to remove the partial archive $archive (exit $?)."
        die "Failed to write $archive (exit $tar_rc)."
    fi
    chmod 600 "$archive" || die "Failed to restrict $archive (exit $?)."

    logbundle_cleanup
    print_ok "Diagnostic bundle written: $archive"
    printf "\n${BOLD}Attach this file to your GitHub issue:${RESET} %s\n\n" "$archive"
)

# ── reset-to-last-known-good-config subcommand ────────────────────────────────
# What: rolls a Kea or DNS service back to a snapshot
# Why: works when the Admin UI is unreachable
cmd_reset_to_last_known_good_config() {
    local service="" install_dir="$DEFAULT_INSTALL_DIR" snapshot_id="" zone="" assume_yes=0
    local -a positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) assume_yes=1; shift ;;
            *) positional+=("$1"); shift ;;
        esac
    done
    service="${positional[0]:-}"
    [[ -n "${positional[1]:-}" ]] && install_dir="${positional[1]}"
    # What: normalizes install-dir to an absolute path
    # Why: a relative path would double env_file's path
    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?

    # What: positional[2] is zone (DNS) or snapshot (Kea)
    # Why: DNS snapshots are per zone; Kea has one file
    case "$service" in
        dns|pdns|dns-standard|dns-ssl)
            zone="${positional[2]:-}"
            snapshot_id="${positional[3]:-}"
            ;;
        *)
            snapshot_id="${positional[2]:-}"
            ;;
    esac

    case "$service" in
        kea|dhcp)
            reset_kea_to_last_known_good_config "$install_dir" "$snapshot_id" "$assume_yes"
            ;;
        dns|pdns)
            # What: dns and pdns both target dns-standard
            # Why: matches the UI's single-primary scope
            reset_dns_to_last_known_good_config "dns-standard" "$install_dir" "$zone" "$snapshot_id" "$assume_yes"
            ;;
        dns-standard|dns-ssl)
            # What: explicit DNS target is passed through
            # Why: rollback listener runs in both containers
            reset_dns_to_last_known_good_config "$service" "$install_dir" "$zone" "$snapshot_id" "$assume_yes"
            ;;
        "")
            die "Usage: ./setup.sh reset-to-last-known-good-config <service> [install-dir] [snapshot-id]\nSupported services: kea, dns. Run './setup.sh reset-to-last-known-good-config --help' for details."
            ;;
        *)
            die "Unknown service '$service' for reset-to-last-known-good-config. Supported: kea, dns. Run './setup.sh reset-to-last-known-good-config --help' for details."
            ;;
    esac
}

# What: lists finalized Kea snapshot ids, oldest first
# Why: staging dirs are skipped; ids are fixed-width digits
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

# What: splits "<body>\n<code>" into body and HTTP code
# Why: callers keep no temp file to clean up on any exit
# From: Issue #1683 | PR #1858
split_http_response() {
    local -n _http_body_ref="$1" _http_code_ref="$2"
    _http_code_ref="${3##*$'\n'}"
    _http_body_ref="${3%$'\n'*}"
    [[ "$_http_code_ref" =~ ^[0-9]{3}$ ]]
}

# What: values of a jq filter on JSON; null prints ""
# Why: grep cannot read escapes, nesting or absent fields
# From: Issue #1683 | PR #1858
json_value() {
    local filter="$1" json="$2"
    shift 2
    jq -r "$@" "($filter) | if . == null then \"\" elif type == \"string\" then . else tojson end" <<< "$json"
}

# What: one jq value of the rendered compose config
# Why: compose owns ports and mounts; setup keeps no copy
# From: Issue #1683 | PR #1858
compose_config_value() {
    local install_dir="$1" env_file="$2" filter="$3" cfg
    shift 3
    cfg=$(stack_compose "$install_dir" "$env_file" config --format json) \
        || die "Cannot render the compose config of $install_dir (exit $?)."
    json_value "$filter" "$cfg" "$@" \
        || die "Cannot read $filter from the compose config of $install_dir (exit $?)."
}

# What: one Kea Control Agent command, as the UI sends it
# Why: Kea answers per service; result 0 means success
# From: Issue #1683 | PR #1858
kea_ctrl_post() {
    local kea_ctrl_url="$1" kea_ctrl_token="$2" body="$3"
    local out http_status response result_code result_text

    # What: passes the Basic-Auth token to curl via -K stdin
    # Why: -u would expose the token in process argv
    # From: PR #1550
    local kea_ctrl_token_escaped
    kea_ctrl_token_escaped=$(printf '%s' "$kea_ctrl_token" | sed 's/\\/\\\\/g; s/"/\\"/g')
    if ! out=$(printf 'user = "admin:%s"\n' "$kea_ctrl_token_escaped" | curl -sS -w '\n%{http_code}' -X POST \
        -H "Content-Type: application/json" \
        -K - \
        -d "$body" \
        "$kea_ctrl_url"); then
        die "Failed to connect to Kea's Control Agent at ${kea_ctrl_url}. Is the dhcp container running?"
    fi
    split_http_response response http_status "$out" \
        || die "Unrecognized response from Kea's Control Agent: ${out}"

    if [[ ! "$http_status" =~ ^2 ]]; then
        die "Kea's Control Agent rejected the request with HTTP ${http_status}. Response: ${response}"
    fi
    result_code=$(json_value 'if type == "array" then .[0] else . end | .result' "$response") \
        || die "Unrecognized response from Kea's Control Agent: ${response}"
    result_text=$(json_value 'if type == "array" then .[0] else . end | .text' "$response") \
        || die "Unrecognized response from Kea's Control Agent: ${response}"
    [[ "$result_code" =~ ^-?[0-9]+$ ]] || die "Unrecognized response from Kea's Control Agent: ${response}"
    if [[ "$result_code" != "0" ]]; then
        die "Kea's Control Agent rejected the command (result=${result_code}): ${result_text:-<no message>}"
    fi
    printf '%s\n' "$response"
}

# What: host dir of KEA_CONFIG_SNAPSHOT_DIR via the ui mount
# Why: the UI writes snapshots there; setup reads the host
# From: Issue #1683 | PR #1858
kea_snapshot_host_dir() {
    local install_dir="$1" env_file="$2" kea_dir="$3" snapshot_dir target
    snapshot_dir=$(get_env_var KEA_CONFIG_SNAPSHOT_DIR "$env_file") || exit $?
    [[ -n "$snapshot_dir" ]] \
        || die "KEA_CONFIG_SNAPSHOT_DIR is empty or missing in $env_file; run setup.sh update."
    target=$(compose_config_value "$install_dir" "$env_file" \
        '[.services.ui.volumes[]? | select(.source == $src) | .target] | first' --arg src "$kea_dir") || exit $?
    [[ -n "$target" ]] || die "The ui service of $install_dir does not mount $kea_dir."
    case "$snapshot_dir" in
        "$target"/*) printf '%s/%s\n' "$kea_dir" "${snapshot_dir#"$target"/}" ;;
        *) die "KEA_CONFIG_SNAPSHOT_DIR ($snapshot_dir) is not under the Kea data mount $target." ;;
    esac
}

# What: rolls Kea back to a snapshot through Control Agent
# Why: config-test, config-set and config-write run in order
reset_kea_to_last_known_good_config() {
    local install_dir="$1" snapshot_id="$2" assume_yes="${3:-0}"
    local env_file state_dir kea_dir snapshot_root repo_root
    local kea_ctrl_host kea_ctrl_token kea_ctrl_url kea_ctrl_port
    local -a snapshot_ids=()
    local sid config_json

    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die_no_stack_found "$install_dir"
    install_missing_tools curl jq

    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    [[ -f "$env_file" ]] || die "No .env found for $install_dir (expected $env_file)."

    kea_ctrl_token=$(get_env_var KEA_CTRL_TOKEN "$env_file") || exit $?
    [[ -n "$kea_ctrl_token" ]] \
        || die "KEA_CTRL_TOKEN is empty or missing in $env_file -- cannot authenticate to Kea's Control Agent."

    kea_ctrl_host=$(get_env_var KEA_CTRL_HOST "$env_file") || exit $?
    kea_ctrl_host="${kea_ctrl_host:-127.0.0.1}"
    # What: maps a 0.0.0.0 Control Agent host to 127.0.0.1
    # Why: dhcp uses host networking; 0.0.0.0 is no target
    [[ "$kea_ctrl_host" = "0.0.0.0" ]] && kea_ctrl_host="127.0.0.1"
    # What: Control Agent port from the dhcp conf
    # Why: kea-ctrl-agent.conf owns it; no second copy
    # From: Issue #1683 | PR #1858
    repo_root=$(deploy_prod_repo_root "$install_dir") \
        || die "Cannot resolve the repository root of $install_dir (exit $?)."
    kea_ctrl_port=$(jq -er '.["Control-agent"]["http-port"]' "$repo_root/services/dhcp/kea-ctrl-agent.conf") \
        || die "Cannot read the Kea Control Agent port from $repo_root/services/dhcp/kea-ctrl-agent.conf (exit $?)."
    kea_ctrl_url="http://${kea_ctrl_host}:${kea_ctrl_port}/"

    state_dir=$(install_state_root "$install_dir" "$env_file") \
        || die "Cannot resolve the state root of $install_dir (exit $?)."
    kea_dir=$(prod_state_dir_for_key KEA_DATA_DIR "$env_file" "$state_dir") \
        || die "Cannot resolve KEA_DATA_DIR of $install_dir (exit $?)."
    snapshot_root=$(kea_snapshot_host_dir "$install_dir" "$env_file" "$kea_dir") || exit $?
    [[ -d "$snapshot_root" ]] \
        || die "No known-good Kea config snapshots found at $snapshot_root."

    sid=$(list_kea_snapshot_ids "$snapshot_root") || die "Cannot list the snapshots under $snapshot_root (exit $?)."
    [[ -z "$sid" ]] || mapfile -t snapshot_ids <<< "$sid"
    [[ ${#snapshot_ids[@]} -gt 0 ]] \
        || die "No valid known-good Kea config snapshots found under $snapshot_root."

    print_step "Known-good Kea config snapshots (oldest first)"
    for sid in "${snapshot_ids[@]}"; do
        # What: forces base-10 for the snapshot id
        # Why: zero-padded ids would parse as octal
        printf '  %s  (%s UTC)\n' "$sid" "$(date -u -d "@$(( 10#$sid / 1000000000 ))" '+%Y-%m-%d %H:%M:%S' 2>&1 || printf ' (exit %s)' "$?")"
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

# What: adds the trailing dot to a zone name if missing
# Why: the rollback listener uses dot-terminated names
canonical_dns_zone() {
    local zone="$1"
    if [[ "$zone" == *. ]]; then
        printf '%s\n' "$zone"
    else
        printf '%s.\n' "$zone"
    fi
}

# What: zones of a GET /snapshots body with a snapshot
# Why: every managed zone is listed, most of them empty
# From: Issue #1683 | PR #1858
list_dns_zones_with_snapshots() {
    json_value '.zones | to_entries[] | select(.value | length > 0) | .key' "$1"
}

# What: "<id> <created_unix>" per snapshot, newest first
# Why: the listener's order; one line per mapfile entry
# From: Issue #1683 | PR #1858
dns_zone_snapshot_entries() {
    json_value '.zones[$zone][]? | "\(.id) \(.created_unix)"' "$1" --arg zone "$2"
}

# What: runs one listener request inside the DNS container
# Why: the listener is not published to the host
dns_rollback_exec() (
    local install_dir="$1" env_file="$2" container="$3" method="$4" path="$5" body="${6:-}"
    local project stdout_val rc=0 exec_err http_status response_body

    project=$(compose_project_name "$install_dir" "$env_file") \
        || die "Cannot determine the compose project of $install_dir (exit $?)."
    err_file=$(mktemp) || die "Cannot create a temporary file for the exec errors (exit $?)."
    # What: the subshell body's trap removes the error file
    # Why: no exit path may leave the file behind
    # From: Issue #1683 | PR #1858
    trap 'rm -f -- "$err_file"' EXIT

    stdout_val=$(stack_compose "$install_dir" "$env_file" -p "$project" exec -T "$container" sh -c '
            key="$PDNS_API_KEY"
            case "$key" in
                ""|CHANGE_ME*|changeme*|change_me*|YOUR_*|*_HERE) key="" ;;
            esac
            if [ -z "$key" ] && [ -s /var/lib/lancache-secrets/pdns-api-key ]; then
                key=$(tr -d "\n" < /var/lib/lancache-secrets/pdns-api-key)
            fi
            if [ -z "$key" ]; then
                echo "DNS_ROLLBACK_EXEC_NO_API_KEY"
                exit 9
            fi
            m="$1"; p="$2"; b="$3"
            if [ "$m" = "POST" ]; then
                curl -sS -w "\n%{http_code}" -X POST \
                    -H "X-API-Key: $key" -H "Content-Type: application/json" -d "$b" \
                    "http://127.0.0.1:8083$p" || { echo "DNS_ROLLBACK_EXEC_CURL_FAILED"; exit 8; }
            else
                curl -sS -w "\n%{http_code}" \
                    -H "X-API-Key: $key" "http://127.0.0.1:8083$p" || { echo "DNS_ROLLBACK_EXEC_CURL_FAILED"; exit 8; }
            fi
        ' sh "$method" "$path" "$body" 2>"$err_file") || rc=$?
    exec_err=$(cat "$err_file") || die "Cannot read $err_file (exit $?)."

    if [[ $rc -ne 0 ]]; then
        case "$stdout_val" in
            *DNS_ROLLBACK_EXEC_NO_API_KEY*)
                die "PDNS_API_KEY could not be resolved inside the $container container (no usable value in its environment and nothing on the shared-secrets volume yet). Is the stack fully started?"
                ;;
            *DNS_ROLLBACK_EXEC_CURL_FAILED*)
                die "Failed to reach the rollback listener inside $container (curl could not connect to 127.0.0.1:8083). Is nats-subscriber running there?"
                ;;
            *)
                die "docker compose exec into $container failed (exit $rc): ${exec_err:-$stdout_val}"
                ;;
        esac
    fi

    split_http_response response_body http_status "$stdout_val" \
        || die "Unexpected response from $container's rollback listener: $stdout_val"
    if [[ ! "$http_status" =~ ^2 ]]; then
        die "$container's rollback listener rejected the request with HTTP ${http_status}. Response: ${response_body}"
    fi
    printf '%s\n' "$response_body"
)

# What: rolls a DNS zone back to a chosen snapshot
# Why: a zone is required; PDNS snapshots are per zone
reset_dns_to_last_known_good_config() {
    local container="$1" install_dir="$2" zone="$3" snapshot_id="$4" assume_yes="${5:-0}"
    local env_file snapshots_body zone_canon rollback_body resp zone_list entry_list
    local -a zone_names=()
    local -a entries=()
    local idx n entry eid ecreated found zn
    local applied zone_check_passed flush_ok republished changed_names flush_failed

    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die "No stack found in $install_dir. Run ./setup.sh install first."
    install_missing_tools jq

    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    [[ -f "$env_file" ]] || die "No .env found for $install_dir (expected $env_file)."

    snapshots_body=$(dns_rollback_exec "$install_dir" "$env_file" "$container" GET /snapshots)

    if [[ -z "$zone" ]]; then
        zone_list=$(list_dns_zones_with_snapshots "$snapshots_body") \
            || die "Unrecognized snapshot list from $container: $snapshots_body"
        zone_names=()
        [[ -z "$zone_list" ]] || mapfile -t zone_names <<< "$zone_list"
        print_step "Zones with known-good snapshots on $container"
        if [[ ${#zone_names[@]} -eq 0 ]]; then
            print_warn "No zone currently has any known-good snapshot on $container."
        else
            for zn in "${zone_names[@]}"; do
                printf '  %s\n' "$zn"
            done
        fi
        die "A zone is required for the dns/pdns target (PowerDNS tracks snapshots per zone, unlike Kea's single config file). Usage: ./setup.sh reset-to-last-known-good-config dns [install-dir] <zone> [snapshot-id] [--yes]"
    fi

    zone_canon=$(canonical_dns_zone "$zone")

    entry_list=$(dns_zone_snapshot_entries "$snapshots_body" "$zone_canon") \
        || die "Unrecognized snapshot list from $container: $snapshots_body"
    entries=()
    [[ -z "$entry_list" ]] || mapfile -t entries <<< "$entry_list"
    [[ ${#entries[@]} -gt 0 ]] \
        || die "No known-good snapshots found for zone $zone_canon on $container."

    print_step "Known-good $zone_canon zone snapshots on $container (oldest first)"
    n=${#entries[@]}
    for (( idx = n - 1; idx >= 0; idx-- )); do
        eid="${entries[$idx]%% *}"
        ecreated="${entries[$idx]#* }"
        printf '  %s  (%s UTC)\n' "$eid" "$(date -u -d "@${ecreated}" '+%Y-%m-%d %H:%M:%S' 2>&1 || printf ' (exit %s)' "$?")"
    done

    if [[ -z "$snapshot_id" ]]; then
        snapshot_id="${entries[0]%% *}"
        print_warn "No snapshot id given; defaulting to the newest: $snapshot_id"
    fi

    found=0
    for entry in "${entries[@]}"; do
        eid="${entry%% *}"
        [[ "$eid" = "$snapshot_id" ]] && { found=1; break; }
    done
    [[ "$found" -eq 1 ]] \
        || die "Snapshot '$snapshot_id' not found for zone $zone_canon on $container."

    if [[ "$assume_yes" != "1" ]]; then
        confirm "Roll $container's zone $zone_canon back to snapshot $snapshot_id now? This applies immediately. [y/N]" "N" \
            || die "Cancelled."
    fi

    # What: the request body is built by jq, not by printf
    # Why: a quote in a user-given snapshot id breaks JSON
    # From: Issue #1683 | PR #1858
    rollback_body=$(jq -nc --arg zone "$zone_canon" --arg id "$snapshot_id" '{zone: $zone, snapshot_id: $id}') \
        || die "Failed to build the rollback request (exit $?)."
    print_step "Applying snapshot $snapshot_id for zone $zone_canon (rollback listener PATCH)"
    resp=$(dns_rollback_exec "$install_dir" "$env_file" "$container" POST /rollback "$rollback_body")

    applied=$(json_value .applied "$resp") || die "Unrecognized rollback response from $container: $resp"
    zone_check_passed=$(json_value .zone_check_passed "$resp") || die "Unrecognized rollback response from $container: $resp"
    flush_ok=$(json_value .flush_ok "$resp") || die "Unrecognized rollback response from $container: $resp"
    republished=$(json_value .republished_to_nats "$resp") || die "Unrecognized rollback response from $container: $resp"
    changed_names=$(json_value '.changed_names // [] | join(", ")' "$resp") \
        || die "Unrecognized rollback response from $container: $resp"
    flush_failed=$(json_value '.flush_failed_names // [] | join(", ")' "$resp") \
        || die "Unrecognized rollback response from $container: $resp"

    [[ "$applied" = "true" ]] \
        || die "Rollback listener did not report applied=true: $resp"

    print_ok "Zone $zone_canon on $container rolled back to known-good snapshot $snapshot_id."
    [[ -n "$changed_names" ]] && print_ok "Changed rrsets: ${changed_names}"
    if [[ "$zone_check_passed" != "true" ]]; then
        print_warn "Post-rollback pdnsutil check-zone reported a problem for $zone_canon -- the rollback was already applied and is NOT automatically reverted. Inspect the zone manually."
    fi
    if [[ "$flush_ok" != "true" ]]; then
        print_warn "One or more recursor cache-flush publishes failed after rollback (${flush_failed:-see response}) -- affected clients may see stale answers until TTL expiry."
    fi
    if [[ "$zone_canon" = "lan." && "$republished" = "true" ]]; then
        print_ok "Restored lan. records were re-published to NATS so secondary DNS nodes converge."
    fi
    print_ok "A fresh known-good snapshot of the restored state was recorded automatically (same as an Admin-UI-driven rollback)."
}

# ── update-ip subcommand ───────────────────────────────────────────────────────
# What: reconfigures IPs of an existing install
# Why: uses the install's directory, not the repo
cmd_update_ip() {
    local install_dir="${1:-$DEFAULT_INSTALL_DIR}"
    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?

    printf "\n"
    printf "${BOLD}╔═══════════════════════════════════════╗${RESET}\n"
    printf "${BOLD}║  LanCache-NG — Reconfigure IPs        ║${RESET}\n"
    printf "${BOLD}╚═══════════════════════════════════════╝${RESET}\n"
    printf "\n"

    [[ "$(id -u)" = "0" ]] \
        || die "This script must be run as root (sudo ./setup.sh update-ip [install-dir])."
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die_no_stack_found "$install_dir"
    assert_prebuilt_image_platform_supported

    print_step "Reading current configuration"

    # What: only the runtime .env holds IPs; compose derives
    # Why: PROXY_IP and binds come from IP_STANDARD/IP_SSL
    # From: Issue #1683 | PR #1858
    local deploy_env
    deploy_env=$(runtime_env_file_for_install_dir "$install_dir")
    [[ -f "$deploy_env" ]] || die "Configuration not found: $deploy_env"

    local current_ip_standard current_ip_ssl
    local new_ip_standard new_ip_ssl
    current_ip_standard=$(get_env_var IP_STANDARD "$deploy_env") || exit $?
    current_ip_ssl=$(get_env_var IP_SSL "$deploy_env") || exit $?

    # What: defaults for UI_BIND_IP and DHCP DNS follow IP_*
    # Why: only install-time default values may be rewritten
    local current_ui_bind_ip current_dhcp_mode
    local current_dhcp_dns_primary current_dhcp_dns_secondary
    current_ui_bind_ip=$(get_env_var UI_BIND_IP "$deploy_env") || exit $?
    current_dhcp_mode=$(get_env_var DHCP_MODE "$deploy_env") || exit $?
    current_dhcp_dns_primary=$(get_env_var DHCP_DNS_PRIMARY "$deploy_env") || exit $?
    current_dhcp_dns_secondary=$(get_env_var DHCP_DNS_SECONDARY "$deploy_env") || exit $?

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

    require_separate_lan_ips "$new_ip_standard" "$new_ip_ssl"

    printf "\n"
    printf "  ${BOLD}New configuration:${RESET}\n"
    printf "    Standard IP: %s\n" "$new_ip_standard"
    printf "    SSL IP:      %s\n" "$new_ip_ssl"
    printf "\n"

    ask "Apply changes? [y/N]" "N"
    [[ "${REPLY,,}" = "y" ]] || { printf "\n  Cancelled.\n\n"; exit 0; }

    print_step "Updating configuration files"

    set_env_key IP_STANDARD "$new_ip_standard" "$deploy_env"
    set_env_key IP_SSL "$new_ip_ssl" "$deploy_env"
    print_ok "Updated: $deploy_env (IP_STANDARD, IP_SSL)"

    # What: rewrites UI_BIND_IP while it equals old IP
    # Why: an empty or explicit value stays untouched
    if [[ -n "$current_ui_bind_ip" && "$current_ui_bind_ip" = "$current_ip_standard" ]]; then
        set_env_key UI_BIND_IP "$new_ip_standard" "$deploy_env"
        print_ok "Updated: $deploy_env (UI_BIND_IP)"
    fi

    # What: rewrites DHCP DNS while it equals old IP
    # Why: dnsmasq-proxy reads these; Kea derives its own
    if [[ "$current_dhcp_mode" = "dnsmasq-proxy" ]]; then
        if [[ -n "$current_dhcp_dns_primary" && "$current_dhcp_dns_primary" = "$current_ip_standard" ]]; then
            set_env_key DHCP_DNS_PRIMARY "$new_ip_standard" "$deploy_env"
            print_ok "Updated: $deploy_env (DHCP_DNS_PRIMARY)"
        fi
        if [[ -n "$current_dhcp_dns_secondary" && "$current_dhcp_dns_secondary" = "$current_ip_ssl" ]]; then
            set_env_key DHCP_DNS_SECONDARY "$new_ip_ssl" "$deploy_env"
            print_ok "Updated: $deploy_env (DHCP_DNS_SECONDARY)"
        fi
    fi

    print_step "Restarting containers"

    # What: restart failure is checked explicitly
    # Why: a bare && is exempt from set -e here
    if stack_compose "$install_dir" "$deploy_env" up -d; then
        print_ok "Stack restarted"
    else
        die "Failed to restart the stack: 'docker compose up -d' exited non-zero. The .env files were already updated with the new IPs, but the running containers may still be bound to the old ones -- fix the issue (e.g. confirm the new IP is assigned to this host) and rerun: $SCRIPT_DIR/setup.sh compose $install_dir up -d"
    fi

    printf "\n"
    printf "${BOLD}${GREEN}════════════════════════════════════════${RESET}\n"
    printf "${BOLD}${GREEN}  Reconfiguration complete!${RESET}\n"
    printf "${BOLD}${GREEN}════════════════════════════════════════${RESET}\n"
    printf "\n"
    printf "  Done. Update your clients to use the new DNS IP.\n\n"

    exit 0
}

# What: deploy/secondary compose text: checkout or same ref
# Why: one owner; a curl|bash secondary has no checkout
# From: Issue #1683 | PR #1858
secondary_compose_text() {
    local local_file="$SCRIPT_DIR/deploy/secondary/docker-compose.yml" ref raw
    if [[ -f "$local_file" ]]; then
        cat -- "$local_file" || die "Failed to read $local_file (exit $?)."
        return 0
    fi
    ref=$(resolve_setup_bootstrap_ref) || exit $?
    raw="https://raw.githubusercontent.com/${LANCACHE_REPO_URL#https://github.com/}/${ref:-HEAD}/deploy/secondary/docker-compose.yml"
    curl -fsSL "$raw" || die "Failed to download the secondary compose file from $raw (exit $?)."
}

# ── secondary subcommand ──────────────────────────────────────────────────────
# Secondary setup is intentionally separate from primary install: it consumes
# credentials returned by the primary UI/API, writes a small DNS-only compose
# directory, and must not modify the primary host configuration.
cmd_secondary() {
    local primary="" token="" name="" proxy_ip="" listen_ip="" rotate=0
    local out http_status response secondary_dir cmd ddns_tsig_key dns_xfr_primary tag_input
    local -a missing_args
    local nats_url nats_user nats_password consumer_name pdns_api_key
    local response_image_registry response_image_prefix response_image_channel response_image_tag
    local existing_env_file lancache_image_registry lancache_image_prefix lancache_image_channel lancache_image_tag
    local explicit_lancache_image_tag keep_known_good_configs
    local preflight_dir preflight_env_file preflight_registry preflight_prefix preflight_channel preflight_env_tag
    local preflight_tag preflight_verified_registry="" preflight_verified_prefix="" preflight_verified_tag=""
    local missing_fields secondary_env_file compose_out bad_response secondary_compose

    usage_secondary() {
        cat <<EOF
Usage: $0 secondary --primary <url> --token <token> --name <name> --proxy-ip <ip> [--listen-ip <ip>] [--rotate]

Required arguments:
  --primary <url>    Primary LanCache UI/API URL, for example http://<primary-ip>:<ui-port>
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

    for cmd in curl docker jq; do
        command -v "$cmd" >/dev/null 2>&1 \
            || die "$cmd is not installed or is not in PATH; run: sudo $0 install-requirements-secondary"
    done

    compose_out=$(docker compose version 2>&1) \
        || die "'docker compose' is not available; install Docker Compose v2 before continuing (exit $?): $compose_out"

    [[ "$name" =~ ^[a-zA-Z0-9-]+$ ]] \
        || die "--name must contain only alphanumeric characters and dashes"
    is_valid_ipv4 "$proxy_ip" \
        || die "--proxy-ip must be a valid IPv4 address"
    if [[ -n "$listen_ip" ]]; then
        is_valid_ipv4 "$listen_ip" \
            || die "--listen-ip must be a valid IPv4 address"
    else
        listen_ip=$(detect_lan_ip) \
            || die "Could not auto-detect a secondary bind IP. Re-run with --listen-ip <ip>."
    fi
    listen_ip=$(secondary_choose_listen_ip "$listen_ip") \
        || die "No usable secondary bind IP on port 53 (exit $?; see above). Re-run with --listen-ip <ip> after freeing the port."
    print_ok "Secondary DNS bind IP: ${listen_ip}"
    assert_prebuilt_image_platform_supported
    # What: the compose file is fetched before registration
    # Why: a fetch failure must not follow a registration
    # From: Issue #1683 | PR #1858
    secondary_compose=$(secondary_compose_text) || exit $?

    secondary_dir="${name}"
    if [[ "$rotate" -eq 1 ]]; then
        if [[ "$(basename "$PWD")" = "$name" && -f .env && -f docker-compose.yml ]]; then
            secondary_dir="."
        elif [[ ! -d "$secondary_dir" ]]; then
            die "No existing secondary directory '${secondary_dir}' found. Run --rotate from its parent directory or from inside the existing '${name}' directory."
        fi
    else
        if [[ "$(basename "$PWD")" = "$name" ]]; then
            die "Current directory already matches secondary '${name}'; rerun with --rotate to update the secondary files"
        elif [[ -d "$secondary_dir" ]]; then
            die "Directory '${secondary_dir}' already exists; rerun with --rotate to update the secondary files"
        fi
    fi

    # What: --rotate may check the platform before the POST
    # Why: a late failure would leave a rotated password
    if [[ "$rotate" -eq 1 ]]; then
        preflight_dir="$secondary_dir"
        preflight_env_file=""
        [[ -f "${preflight_dir}/.env" ]] && preflight_env_file="${preflight_dir}/.env"

        if [[ -n "$preflight_env_file" ]]; then
            # What: shell env wins, else secondary's .env
            # Why: a failed read must stop, not look unset
            # From: Issue #1683 | PR #1858
            preflight_registry="${LANCACHE_IMAGE_REGISTRY:-}" preflight_prefix="${LANCACHE_IMAGE_PREFIX:-}"
            preflight_channel="${LANCACHE_IMAGE_CHANNEL:-}" preflight_env_tag="${LANCACHE_IMAGE_TAG:-}"
            [[ -n "$preflight_registry" ]] || preflight_registry=$(get_env_var LANCACHE_IMAGE_REGISTRY "$preflight_env_file") \
                || die "Cannot read LANCACHE_IMAGE_REGISTRY from $preflight_env_file (exit $?)."
            [[ -n "$preflight_prefix" ]] || preflight_prefix=$(get_env_var LANCACHE_IMAGE_PREFIX "$preflight_env_file") \
                || die "Cannot read LANCACHE_IMAGE_PREFIX from $preflight_env_file (exit $?)."
            [[ -n "$preflight_channel" ]] || preflight_channel=$(get_env_var LANCACHE_IMAGE_CHANNEL "$preflight_env_file") \
                || die "Cannot read LANCACHE_IMAGE_CHANNEL from $preflight_env_file (exit $?)."
            [[ -n "$preflight_env_tag" ]] || preflight_env_tag=$(get_env_var LANCACHE_IMAGE_TAG "$preflight_env_file") \
                || die "Cannot read LANCACHE_IMAGE_TAG from $preflight_env_file (exit $?)."

            if [[ -n "$preflight_registry" && -n "$preflight_prefix" && -n "$preflight_channel" ]]; then
                validate_lancache_image_registry "$preflight_registry"
                validate_lancache_image_prefix "$preflight_prefix"
                validate_lancache_image_channel "$preflight_channel"

                # What: pinned channel needs a tag to check
                # Why: only the primary can supply the tag
                if [[ "$preflight_channel" != "pinned" || -n "$preflight_env_tag" ]]; then
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

    # What: jq builds the body; the token comes on stdin
    # Why: escapes stay valid JSON; no secret in any argv
    # From: Issue #1683 | PR #1858
    local request
    request=$(printf '%s' "$token" | jq -Rsc --arg name "$name" --arg address "$listen_ip" \
        '{token: ., name: $name, address: $address}') \
        || die "Failed to build the registration request (exit $?)."
    if ! out=$(printf '%s' "$request" \
        | curl -sS -w '\n%{http_code}' -X POST \
        -H "Content-Type: application/json" \
        -d @- \
        "${primary}/api/secondary/register"); then
        die "Failed to connect to primary server at ${primary}. Check the URL, network connectivity, and that the primary service is running."
    fi
    split_http_response response http_status "$out" \
        || die "Unrecognized response from primary server at ${primary}."

    if [[ "$http_status" = "503" ]]; then
        # What: 503 means primary lacks a reachable NATS URL
        # Why: nats needs the secondary override too
        die "Primary server at ${primary} is not configured to register remote secondaries (HTTP 503): it needs NATS_BIND_IP (or the more specific NATS_ADVERTISE_URL) set in its .env/.env.local to a NATS address this secondary can reach, AND its 'nats' service recreated with the docker-compose.nats-secondary.yml override included -- e.g. docker compose -f docker-compose.yml -f docker-compose.nats-secondary.yml up -d if the variable is in .env, or docker compose --env-file .env.local -f docker-compose.yml -f docker-compose.nats-secondary.yml up -d if it is in .env.local (Compose does not auto-load .env.local) -- so NATS actually publishes that address; restarting only the ui container is not enough. See docs/architecture-ng.md's \"Remote secondary NATS access\" section."
    elif [[ ! "$http_status" =~ ^2 ]]; then
        die "Primary server rejected the registration request with HTTP ${http_status}. Verify the registration token, secondary name, and primary server logs."
    fi
    [[ -n "$response" ]] || die "Empty response from primary server after successful registration request"

    bad_response="Unrecognized response from primary server at ${primary}."
    nats_url=$(json_value .nats_url "$response") || die "$bad_response"
    nats_user=$(json_value .nats_user "$response") || die "$bad_response"
    nats_password=$(json_value .nats_password "$response") || die "$bad_response"
    consumer_name=$(json_value .consumer_name "$response") || die "$bad_response"
    pdns_api_key=$(json_value .pdns_api_key "$response") || die "$bad_response"
    ddns_tsig_key=$(json_value .ddns_tsig_key "$response") || die "$bad_response"
    dns_xfr_primary=$(json_value .dns_xfr_primary "$response") || die "$bad_response"
    response_image_registry=$(json_value .image_registry "$response") || die "$bad_response"
    response_image_prefix=$(json_value .image_prefix "$response") || die "$bad_response"
    response_image_channel=$(json_value .image_channel "$response") || die "$bad_response"
    response_image_tag=$(json_value .image_tag "$response") || die "$bad_response"

    missing_fields=()
    [[ -n "$nats_url" ]] || missing_fields+=("nats_url")
    [[ -n "$nats_user" ]] || missing_fields+=("nats_user")
    [[ -n "$nats_password" ]] || missing_fields+=("nats_password")
    [[ -n "$consumer_name" ]] || missing_fields+=("consumer_name")
    [[ -n "$pdns_api_key" ]] || missing_fields+=("pdns_api_key")
    [[ -n "$ddns_tsig_key" ]] || missing_fields+=("ddns_tsig_key")
    [[ -n "$dns_xfr_primary" ]] || missing_fields+=("dns_xfr_primary")
    if [[ ${#missing_fields[@]} -gt 0 ]]; then
        die "Invalid response from primary server; missing field(s): ${missing_fields[*]}"
    fi

    mkdir -p "$secondary_dir"

    existing_env_file=""
    if [[ -f "${secondary_dir}/.env" ]]; then
        existing_env_file="${secondary_dir}/.env"
    fi

    lancache_image_registry="${LANCACHE_IMAGE_REGISTRY:-}"
    if [[ -z "$lancache_image_registry" && -n "$existing_env_file" ]]; then
        lancache_image_registry=$(get_env_var LANCACHE_IMAGE_REGISTRY "$existing_env_file") || exit $?
    fi
    lancache_image_registry=$(LANCACHE_IMAGE_REGISTRY="${lancache_image_registry:-$response_image_registry}" \
        resolve_lancache_image_registry) || die "Cannot resolve the image registry (exit $?)."

    lancache_image_prefix="${LANCACHE_IMAGE_PREFIX:-}"
    if [[ -z "$lancache_image_prefix" && -n "$existing_env_file" ]]; then
        lancache_image_prefix=$(get_env_var LANCACHE_IMAGE_PREFIX "$existing_env_file") || exit $?
    fi
    lancache_image_prefix=$(LANCACHE_IMAGE_PREFIX="${lancache_image_prefix:-$response_image_prefix}" \
        resolve_lancache_image_prefix) || die "Cannot resolve the image prefix (exit $?)."

    lancache_image_channel="${LANCACHE_IMAGE_CHANNEL:-}"
    if [[ -z "$lancache_image_channel" && -n "$existing_env_file" ]]; then
        lancache_image_channel=$(get_env_var LANCACHE_IMAGE_CHANNEL "$existing_env_file") || exit $?
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
    tag_input="$explicit_lancache_image_tag"
    if [[ -z "$explicit_lancache_image_tag" && "$lancache_image_channel" = "pinned" && -n "$existing_env_file" ]]; then
        tag_input=$(get_env_var LANCACHE_IMAGE_TAG "$existing_env_file") || exit $?
    fi
    if [[ -z "$explicit_lancache_image_tag" && "$lancache_image_channel" = "pinned" && -z "$tag_input" && -n "$response_image_tag" && ! "$response_image_tag" =~ ^(stable|latest|nightly)$ ]]; then
        tag_input="$response_image_tag"
    fi
    if [[ "$lancache_image_channel" != "pinned" && -z "$explicit_lancache_image_tag" ]]; then
        if [[ -n "$response_image_tag" && "$response_image_tag" =~ ^sha- ]]; then
            tag_input="$response_image_tag"
        else
            tag_input=""
        fi
    fi
    lancache_image_tag=$(LANCACHE_IMAGE_REGISTRY="$lancache_image_registry" \
        LANCACHE_IMAGE_PREFIX="$lancache_image_prefix" \
        LANCACHE_IMAGE_CHANNEL="$lancache_image_channel" \
        LANCACHE_IMAGE_TAG="$tag_input" \
        resolve_lancache_image_tag)
    # What: a channel secondary pins dns to its digest
    # Why: same consistent stack read as the primary install
    # From: Issue #1683 | PR #1858
    local secondary_refs="" secondary_dns_ref=""
    if [[ "$lancache_image_tag" =~ ^(latest|nightly)$ ]]; then
        secondary_refs=$(LANCACHE_IMAGE_REGISTRY="$lancache_image_registry" \
            LANCACHE_IMAGE_PREFIX="$lancache_image_prefix" \
            lancache_image_refs_for_tag "" "$lancache_image_tag") \
            || die "Cannot pin the dns image of channel ${lancache_image_tag} for the secondary (exit $?)."
        secondary_dns_ref=$(awk -F= '$1 == "LANCACHE_IMAGE_REF_DNS" { print substr($0, length($1) + 2) }' <<< "$secondary_refs") \
            || die "Failed to read LANCACHE_IMAGE_REF_DNS from the channel pins (exit $?)."
        [[ -n "$secondary_dns_ref" ]] \
            || die "Channel ${lancache_image_tag} resolved no LANCACHE_IMAGE_REF_DNS pin for the secondary."
    fi

    # What: verifies tag platform before secondary writes
    # Why: skips a repeat of the rotate preflight check
    if [[ -z "$preflight_verified_tag" \
        || "$lancache_image_registry" != "$preflight_verified_registry" \
        || "$lancache_image_prefix" != "$preflight_verified_prefix" \
        || "$lancache_image_tag" != "$preflight_verified_tag" ]]; then
        assert_resolved_image_tag_platform_supported "$lancache_image_registry" "$lancache_image_prefix" "$lancache_image_tag"
    fi

    # What: KEEP_KNOWN_GOOD_CONFIGS: env, .env, else 3
    # Why: a local per-node setting; the primary has no say
    keep_known_good_configs="${KEEP_KNOWN_GOOD_CONFIGS:-}"
    if [[ -z "$keep_known_good_configs" && -n "$existing_env_file" ]]; then
        keep_known_good_configs=$(get_env_var KEEP_KNOWN_GOOD_CONFIGS "$existing_env_file") || exit $?
    fi

    write_file_atomically "${secondary_dir}/docker-compose.yml" <<< "$secondary_compose" \
        || die "Failed to write ${secondary_dir}/docker-compose.yml (exit $?)."

    secondary_env_file="$(realpath -m "${secondary_dir}/.env")"

    write_file_atomically "${secondary_dir}/.env" <<EOF
PROXY_IP=${proxy_ip}
LISTEN_IP=${listen_ip}
PDNS_API_KEY=${pdns_api_key}
DDNS_TSIG_KEY=${ddns_tsig_key}
DNS_XFR_PRIMARY=${dns_xfr_primary}
NATS_URL=${nats_url}
NATS_USER=${nats_user}
NATS_PASSWORD=${nats_password}
NATS_CONSUMER=${consumer_name}
KEEP_KNOWN_GOOD_CONFIGS=${keep_known_good_configs}
LANCACHE_IMAGE_REGISTRY=${lancache_image_registry}
LANCACHE_IMAGE_PREFIX=${lancache_image_prefix}
LANCACHE_IMAGE_CHANNEL=${lancache_image_channel}
LANCACHE_IMAGE_TAG=${lancache_image_tag}
LANCACHE_IMAGE_REF_DNS=${secondary_dns_ref}
EOF

    print_step "Starting secondary DNS container"
    stack_compose "$(realpath -m "$secondary_dir")" "$secondary_env_file" up -d \
        || die "Failed to start docker compose in ${secondary_dir}. Review Docker logs and the generated compose file."

    print_ok "Secondary DNS '${name}' is running. Configure this host's IP as DNS on your clients."
}

# What: a sourced setup.sh stops here: functions, no run
# Why: tests load every function from the real file
# From: Issue #1683 | PR #1858
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

# ── Dispatch subcommands ──────────────────────────────────────────────────────
# What: no command prints the help and changes nothing
# Why: only the explicit install command installs
# From: Issue #1683 | PR #1858
if [[ -z "${1:-}" ]]; then
    print_usage
    exit 0
fi
case "${1:-install}" in
    install)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help install
            exit 0
        fi
        ;;
    list-prompts)
        # What: list-prompts records, then falls through
        # Why: the walk uses the real wizard branch logic
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help list-prompts
            exit 0
        fi
        WIZARD_INTROSPECT_MODE=1
        if [[ -n "${2:-}" ]]; then
            [[ -f "$2" ]] || die "Answers file not found: $2"
            # What: fd 9 is opened once for the answers file
            # Why: no nested re-exec can reuse fd 9
            exec 9<"$2"
            WIZARD_INTROSPECT_ANSWERS_FD=9
        fi
        ;;
    install-requirements-primary)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help install-requirements-primary
            exit 0
        fi
        cmd_install_requirements_primary; exit 0 ;;
    install-requirements-secondary)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help install-requirements-secondary
            exit 0
        fi
        cmd_install_requirements_secondary; exit 0 ;;
    update)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help update
            exit 0
        fi
        cmd_update "${2:-$DEFAULT_INSTALL_DIR}"; exit 0 ;;
    auto-update)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help auto-update
            exit 0
        fi
        cmd_auto_update "${2:-$DEFAULT_INSTALL_DIR}"; exit 0 ;;
    converge-reconcile)
        # What: internal-only; not in the usage text
        # Why: the converge service calls it
        cmd_converge_reconcile "${2:-$DEFAULT_INSTALL_DIR}"; exit 0 ;;
    compose)
        # What: internal; units and recovery hints call it
        # Why: compose always needs the stack's file list
        # From: Issue #1683 | PR #1858
        shift; cmd_compose "$@"; exit 0 ;;
    debug)
        if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]]; then
            print_command_help debug
            exit 0
        fi
        cmd_debug  "${2:-$DEFAULT_INSTALL_DIR}"; exit 0 ;;
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
        cmd_update_ip "${2:-$DEFAULT_INSTALL_DIR}"; exit 0 ;;
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
# What: first-user production flow, linear and readable
# Why: prompt, write config once, then start containers

printf "\n"
printf "${BOLD}╔══════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}║      LanCache-NG — Initial Setup        ║${RESET}\n"
printf "${BOLD}╚══════════════════════════════════════════╝${RESET}\n"
printf "\n"
printf "  This script sets up LanCache-NG and starts all containers.\n"
printf "  After: ./setup.sh update  |  ./setup.sh debug  |  ./setup.sh update-ip\n"
printf "  Help:  ./setup.sh --help (use './setup.sh <command> --help' for details)\n"

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
# What: list-prompts skips root, Docker and git checks
# Why: lets list-prompts run cheaply in CI
if [[ "$WIZARD_INTROSPECT_MODE" != "1" ]]; then
    print_step "Checking prerequisites"

    [[ "$(id -u)" = "0" ]] \
        || die "This script must be run as root (sudo ./setup.sh install)."

    assert_prebuilt_image_platform_supported

    ensure_stack_requirements_installed

    if [[ ! -f "$PROD_COMPOSE" ]]; then
        print_warn "No local repo found — cloning to ${DEFAULT_INSTALL_DIR}..."
        if ! command -v git >/dev/null 2>&1; then
            install_git
        fi
        setup_bootstrap_ref=$(resolve_setup_bootstrap_ref) || exit $?
        if [[ -d "$DEFAULT_INSTALL_DIR/.git" ]]; then
            if [[ -n "$setup_bootstrap_ref" ]]; then
                print_warn "Existing checkout found at ${DEFAULT_INSTALL_DIR} — syncing to LANCACHE_SETUP_GIT_REF=${setup_bootstrap_ref}..."
                sync_repo_to_ref "$DEFAULT_INSTALL_DIR" "$setup_bootstrap_ref"
            else
                print_warn "Existing checkout found at ${DEFAULT_INSTALL_DIR} — syncing to the remote default branch..."
                sync_repo_to_default_branch "$DEFAULT_INSTALL_DIR"
            fi
        elif [[ -n "$setup_bootstrap_ref" ]]; then
            git clone --branch "$setup_bootstrap_ref" "${LANCACHE_REPO_URL}.git" "$DEFAULT_INSTALL_DIR" \
                || die "Clone failed for LANCACHE_SETUP_GIT_REF='${setup_bootstrap_ref}'. Check that it names a real branch or tag on origin."
        else
            git clone "${LANCACHE_REPO_URL}.git" "$DEFAULT_INSTALL_DIR" \
                || die "Clone failed."
        fi
        chmod +x "$DEFAULT_INSTALL_DIR/setup.sh"
        exec "$DEFAULT_INSTALL_DIR/setup.sh" "$@"
    fi

    # What: version lines; an unknown version only warns
    # Why: a cosmetic print must not abort the install
    # From: Issue #1377
    docker_version_raw="$(docker --version)" || die "docker --version failed (exit $?)."
    if docker_version_numbers="$(grep -oP '[\d.]+' <<<"$docker_version_raw")"; then
        print_ok "Docker $(head -1 <<<"$docker_version_numbers")"
    else
        print_warn "Docker version not recognised: $docker_version_raw"
    fi
    if compose_version="$(docker compose version --short)"; then
        print_ok "Docker Compose $compose_version"
    else
        print_warn "Docker Compose version unavailable (exit $?)"
    fi
fi

# ── 2. Network IPs ────────────────────────────────────────────────────────────
print_step "Network configuration"

# What: listing or detection failure leaves no default
# Why: AG-SEC-007; a host without ip must not abort
# From: Issue #1683 | PR #1858
detected_ip=""
if lan_addresses=$(host_lan_addresses); then
    printf "\n  Found LAN addresses:\n"
    awk '{ print "    " $1 "/" $2 " dev " $3 }' <<< "$lan_addresses"
    detected_ip=$(detect_lan_ip) || detected_ip=""
else
    print_warn "Cannot list this host's IPv4 addresses (exit $?); enter them below."
fi
printf "\n"

while true; do
    ask "Server IP (Standard mode)" "$detected_ip"
    IP_STANDARD="$REPLY"
    is_valid_ipv4 "$IP_STANDARD" && break
    print_error "Invalid IPv4 address: $IP_STANDARD"
done

printf "\n"
printf "  ${BOLD}Second LAN IP${RESET}: the SSL DNS/proxy address, always required.\n\n"
# What: the second LAN address is always asked and checked
# Why: AG-SETUP-001; prod runs dns-ssl on IP_SSL always
# From: Issue #1683 | PR #1858
suggested_ssl="${IP_STANDARD%.*}.$((10#${IP_STANDARD##*.} + 1))"
while true; do
    ask "Second LAN IP (SSL mode)" "$suggested_ssl"
    IP_SSL="$REPLY"
    is_valid_ipv4 "$IP_SSL" && break
    print_error "Invalid IPv4 address: $IP_SSL"
done
require_separate_lan_ips "$IP_STANDARD" "$IP_SSL"
# What: IP_SSL goes on IP_STANDARD's device and prefix
# Why: same link and subnet; no guessed device or mask
# From: Issue #1683 | PR #1858
ssl_assigned=0 standard_link=""
if host_addresses=$(host_ipv4_addresses); then
    awk -v ip="$IP_SSL" '$1 == ip { found = 1 } END { exit !found }' <<< "$host_addresses" \
        && ssl_assigned=1
    standard_link=$(awk -v ip="$IP_STANDARD" '$1 == ip { print $2, $3; exit }' <<< "$host_addresses")
else
    print_warn "Cannot list this host's IPv4 addresses (exit $?)."
fi
if [[ "$ssl_assigned" = 1 ]]; then
    print_ok "$IP_SSL already assigned"
else
    print_warn "$IP_SSL not yet assigned to an interface"
    if [[ -n "$standard_link" ]]; then
        read -r standard_prefix standard_dev <<< "$standard_link"
        ask "Add now? (ip addr add $IP_SSL/$standard_prefix dev $standard_dev) [y/N]" "N"
        if [[ "${REPLY,,}" = "y" ]]; then
            if [[ "$WIZARD_INTROSPECT_MODE" = "1" ]]; then
                # What: introspection skips ip addr add
                # Why: list-prompts only walks the prompts
                # From: Issue #1176
                print_ok "$IP_SSL would be added (skipped: introspection mode)"
            elif ip addr add "$IP_SSL/$standard_prefix" dev "$standard_dev"; then
                print_ok "$IP_SSL added (not persistent)"
            else
                print_warn "Adding failed (exit $?) — please add manually"
            fi
        fi
    else
        print_warn "Add $IP_SSL to the interface that carries $IP_STANDARD."
    fi
    printf "\n"
    print_warn "For persistent configuration after reboot:"
    printf "    netplan:    sudo nano /etc/netplan/01-netcfg.yaml\n"
    printf "    interfaces: sudo nano /etc/network/interfaces\n"
fi

printf "\n"
printf "  ${BOLD}SSL mode${RESET}: also caches HTTPS downloads (Epic, EA, Blizzard…)\n"
printf "  Requires a CA certificate on clients.\n\n"
ask "Enable SSL mode? [y/N]" "N"
SSL_ENABLED=0
[[ "${REPLY,,}" = "y" ]] && SSL_ENABLED=1
print_ok "SSL mode $([[ "$SSL_ENABLED" = 1 ]] && echo enabled || echo disabled) (second IP $IP_SSL)"

# ── 3. Data directory ─────────────────────────────────────────────────────────
print_step "Data directory"

# What: the stack runs from this checkout's deploy/prod
# Why: AG-KD-008: deploy/prod is the only deployment profile
# From: Issue #1683 | PR #1858
INSTALL_DIR="$SCRIPT_DIR/deploy/prod"
ENV_LOCAL="$INSTALL_DIR/.env.local"
STATE_ROOT_DEFAULT=$(production_state_root_default "$INSTALL_DIR") \
    || die "Cannot read the default state root from $INSTALL_DIR (exit $?)."
ask "Data directory (cache, DNS, DHCP, NTP state)" "$STATE_ROOT_DEFAULT"
LANCACHE_STATE_DIR="$(realpath -m "$REPLY")"

if [[ -f "$ENV_LOCAL" ]]; then
    print_warn "Existing configuration found: $ENV_LOCAL"
    ask "Overwrite? [y/N]" "N"
    [[ "${REPLY,,}" = "y" ]] || die "Cancelled."
fi

if [[ "$WIZARD_INTROSPECT_MODE" != "1" ]]; then
    mkdir -p "$LANCACHE_STATE_DIR" "$SCRIPT_DIR/certs"
fi

# ── 4. Cache configuration ───────────────────────────────────────────────────
print_step "Cache configuration"

while true; do
    ask "Cache directory (absolute path)" "$LANCACHE_STATE_DIR/cache"
    CACHE_DIR="$REPLY"
    is_absolute_path "$CACHE_DIR" && break
    print_error "Please enter an absolute path (e.g. $LANCACHE_STATE_DIR/cache)."
done

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

# ── 5. Release channel ────────────────────────────────────────────────────────
print_step "Release channel"

# Unlike the other prompts in this flow (INSTALL_DIR, detected_ip, ...), an
# already-set LANCACHE_IMAGE_CHANNEL is NOT just a default to confirm -- it is
# respected outright and the prompt is skipped entirely. Two real callers rely
# on this: (1) the documented `LANCACHE_IMAGE_CHANNEL=nightly ./setup.sh install`
# non-interactive invocation (see lancache_channel_ref_pass's own
# die() message), and (2) scripts/untracked/simulations/setup-cli-simulation.sh, which exports
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
    printf "  nightly — the most recently built channel from active development.\n"
    printf "            Refreshes continuously from current_dev. Currently the\n"
    printf "            practical default: this project is pre-1.0 and has not cut\n"
    printf "            a stable release yet (see below), so this is what most new\n"
    printf "            installs should pick.\n"
    printf "  stable — the channel promoted after the full release validation gate,\n"
    printf "           once a stable release exists. NOT YET AVAILABLE: no stable\n"
    printf "           release has been cut for this project yet, so choosing it now\n"
    printf "           will fail during image pull with an explanation of how to\n"
    printf "           proceed instead. Once a stable release ships, this becomes the\n"
    printf "           recommended default again.\n\n"

    # Writes the plain LANCACHE_IMAGE_CHANNEL shell variable that
    # resolve_lancache_image_channel already checks first (see its precedence
    # comment above); nothing downstream needs to change to pick this up.
    # "stable" and "latest" resolve to the identical promoted channel tags
    # (see lancache_channel_image_refs) -- "stable" is only the
    # friendlier, self-explanatory name this prompt writes for new installs.
    #
    # Default answer and recommendation deliberately flipped from "stable" to
    # "nightly" (#1068 field-testing finding): pre-1.0, accepting the prior
    # default silently walked a new operator straight into a "manifest
    # unknown" dead end (lancache_channel_ref_pass's own die()
    # message already explains this gracefully if reached, so "stable" stays
    # a valid, non-rejected answer here for the operator who explicitly wants
    # it or is running this after a real stable release exists -- only the
    # picker's own default/recommendation changes, not what inputs it
    # accepts).
    channel_hint=$(IFS=/; printf '%s' "${LANCACHE_SELECTABLE_CHANNELS[*]}")
    while true; do
        ask "Release channel [$channel_hint]" "${LANCACHE_SELECTABLE_CHANNELS[0]}"
        if lancache_ui_channel_override_is_valid "${REPLY,,}"; then
            LANCACHE_IMAGE_CHANNEL="${REPLY,,}"
            if [[ "$LANCACHE_IMAGE_CHANNEL" = "${LANCACHE_SELECTABLE_CHANNELS[0]}" ]]; then
                print_ok "Using the $LANCACHE_IMAGE_CHANNEL channel (recommended pre-1.0)."
            else
                print_warn "Using the $LANCACHE_IMAGE_CHANNEL channel -- this will fail during image pull unless a stable release already exists."
            fi
            break
        fi
        case "${REPLY,,}" in
            # "edge" was the old name of the nightly channel (renamed in v0.3.0,
            # #1056) and is intentionally NOT accepted as a synonym here -- point
            # the operator at the new name rather than silently substituting it.
            edge)
                print_error "The 'edge' channel was renamed to 'nightly' in v0.3.0. Please answer 'nightly'."
                ;;
            *)
                print_error "Please answer one of: $channel_hint."
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
printf "  dnsmasq-relay: forward DHCP to an upstream server on another segment (relay only; injects nothing of its own)\n"
printf "  disabled: keep router DHCP and do nothing in LanCache\n\n"

while true; do
    ask "DHCP mode (disabled, kea, dnsmasq-proxy, dnsmasq-relay)" "disabled"
    DHCP_MODE="${REPLY,,}"
    if is_valid_dhcp_mode "$DHCP_MODE"; then
        break
    fi
    print_error "Invalid DHCP mode: $DHCP_MODE"
done

# What: DHCP defaults come from the deploy/prod template
# Why: AG-SEC-007; the template owns these values
# From: Issue #1683 | PR #1858
DHCP_SUBNET_DEFAULT=$(get_env_var DHCP_SUBNET "$INSTALL_DIR/.env") || exit $?
DHCP_GATEWAY_DEFAULT=$(get_env_var DHCP_GATEWAY "$INSTALL_DIR/.env") || exit $?
DHCP_RANGE_START_DEFAULT=$(get_env_var DHCP_RANGE_START "$INSTALL_DIR/.env") || exit $?
DHCP_RANGE_END_DEFAULT=$(get_env_var DHCP_RANGE_END "$INSTALL_DIR/.env") || exit $?
DHCP_ENABLED=0
KEA_DATA_DIR=""
DHCP_SUBNET=""
DHCP_GATEWAY="$DHCP_GATEWAY_DEFAULT"
DHCP_RANGE_START=""
DHCP_RANGE_END=""
DHCP_SUBNET_START=""
DHCP_DNS_PRIMARY="$IP_STANDARD"
DHCP_DNS_SECONDARY="${IP_SSL:-$IP_STANDARD}"
UPSTREAM_DHCP_IP="$DHCP_GATEWAY"
# Issue #844: relay-mode local address, empty unless dnsmasq-relay is chosen.
DHCP_RELAY_LOCAL_ADDR=""
# Issue #450: additional optional dnsmasq relay/proxy fields, all left empty
# unless the operator opts in below.
DHCP_PROXY_INTERFACE=""
DHCP_PROXY_ROUTER=""
DHCP_NTP_SERVERS=""
DHCP_PROXY_DOMAIN=""
DHCP_PROXY_BOOT_FILENAME=""
DHCP_PROXY_BOOT_SERVER=""
DHCP_PROXY_CUSTOM_OPTIONS=""
# Issue #705: PXE boot-pointer (`pxe-service`) fields, separate from the
# #450 fields above -- the only other way to set these is hand-editing
# config/prod/dhcp-proxy.env directly, so a fresh install writes real,
# wizard-driven values (or the empty default) here instead.
DHCP_PROXY_PXE_BOOT_SERVER=""
DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=""
DHCP_PROXY_PXE_BOOT_FILENAME_UEFI=""

if [[ "$DHCP_MODE" = "kea" ]]; then
    DHCP_ENABLED=1

    while true; do
        ask "Kea data directory (config + leases, absolute path)" "$LANCACHE_STATE_DIR/kea"
        KEA_DATA_DIR="$REPLY"
        is_absolute_path "$KEA_DATA_DIR" && break
        print_error "Please enter an absolute path (e.g. $LANCACHE_STATE_DIR/kea)."
    done

    while true; do
        ask "DHCP subnet (CIDR)" "$DHCP_SUBNET_DEFAULT"
        DHCP_SUBNET="$REPLY"
        is_valid_cidr "$DHCP_SUBNET" && break
        print_error "Invalid CIDR: $DHCP_SUBNET"
    done

    while true; do
        ask "Gateway" "$DHCP_GATEWAY_DEFAULT"
        DHCP_GATEWAY="$REPLY"
        is_valid_ipv4 "$DHCP_GATEWAY" && break
        print_error "Invalid IPv4 address: $DHCP_GATEWAY"
    done

    while true; do
        ask "IP pool start" "$DHCP_RANGE_START_DEFAULT"
        DHCP_RANGE_START="$REPLY"
        is_valid_ipv4 "$DHCP_RANGE_START" && break
        print_error "Invalid IPv4 address: $DHCP_RANGE_START"
    done

    while true; do
        ask "IP pool end" "$DHCP_RANGE_END_DEFAULT"
        DHCP_RANGE_END="$REPLY"
        is_valid_ipv4 "$DHCP_RANGE_END" && break
        print_error "Invalid IPv4 address: $DHCP_RANGE_END"
    done

    print_ok "DHCP enabled in Kea mode — Subnet: $DHCP_SUBNET, Pool: $DHCP_RANGE_START–$DHCP_RANGE_END"
    print_warn "Before Kea is activated, setup will run a non-invasive DHCP discovery preflight."
    # What: names the fence the dhcp container sets itself
    # Why: its entrypoint owns the rule; a copy here drifted
    # From: Issue #1683 | PR #1858
    print_ok "The dhcp container limits the Kea control API to loopback and Docker networks."
    printf "\n"
elif [[ "$DHCP_MODE" = "dnsmasq-proxy" ]]; then
    print_warn "dnsmasq-proxy uses dnsmasq proxy-DHCP."
    print_warn "It does not reliably replace DNS options from a normal router DHCP server."
    print_warn "Use Kea mode if LanCache must control normal client DNS settings."
    confirm "Continue with experimental dnsmasq-proxy mode? [y/N]" "N" \
        || die "Cancelled dnsmasq-proxy mode. Re-run setup and choose kea or disabled."

    ask "DHCP subnet start for dnsmasq-proxy" "${DHCP_SUBNET_DEFAULT%/*}"
    while true; do
        DHCP_SUBNET_START="$REPLY"
        is_dnsmasq_subnet_start "$DHCP_SUBNET_START" && break
        print_error "DHCP subnet start must be a network address ending in .0, e.g. ${DHCP_SUBNET_DEFAULT%/*}"
        ask "DHCP subnet start for dnsmasq-proxy" "${DHCP_SUBNET_DEFAULT%/*}"
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
            print_error "Invalid boot filename (no whitespace, commas, or other .env-unsafe characters like \$, \`, \", ', \\, #): $DHCP_PROXY_BOOT_FILENAME"
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

    # Issue #705: PXE boot-pointer support (`pxe-service`), kept as its own
    # separate opt-in gate rather than folded into the #450 options block
    # above -- entrypoint.sh's own investigation (see
    # _dhcp_proxy_render_pxe_service_directives's header comment) found this
    # is a real behavior change, not just another optional field: dnsmasq's
    # ProxyDHCP mode does not reply to ANY DHCPDISCOVER at all until at
    # least one `pxe-service` directive exists, so turning this on makes an
    # installation that previously never replied start replying to every
    # PXE-tagged client on the segment. That deserves its own explicit,
    # separately-worded confirmation, not a field buried in a generic
    # "additional options" prompt. lancache-ng only points at an operator's
    # EXISTING external PXE/TFTP boot server -- it never hosts boot files
    # itself (docs/dhcp-modes.md).
    print_warn "Optional: PXE boot-pointer support. This makes dnsmasq start REPLYING to every PXE-tagged client on this segment, pointing them at an EXISTING external PXE/TFTP boot server -- lancache-ng does not host boot files itself. See docs/dhcp-modes.md."
    if confirm "Configure PXE boot-pointer support now? [y/N]" "N"; then
        ask "External PXE/TFTP boot server address (blank = skip PXE boot-pointer support)" "$DHCP_PROXY_PXE_BOOT_SERVER"
        while true; do
            DHCP_PROXY_PXE_BOOT_SERVER="$REPLY"
            [[ -z "$DHCP_PROXY_PXE_BOOT_SERVER" ]] && break
            is_valid_ipv4 "$DHCP_PROXY_PXE_BOOT_SERVER" && break
            print_error "Invalid IPv4 address: $DHCP_PROXY_PXE_BOOT_SERVER"
            ask "External PXE/TFTP boot server address (blank = skip PXE boot-pointer support)" ""
        done

        if [[ -n "$DHCP_PROXY_PXE_BOOT_SERVER" ]]; then
            ask "BIOS (legacy x86PC) boot filename (blank = skip BIOS clients)" "$DHCP_PROXY_PXE_BOOT_FILENAME_BIOS"
            while true; do
                DHCP_PROXY_PXE_BOOT_FILENAME_BIOS="$REPLY"
                [[ -z "$DHCP_PROXY_PXE_BOOT_FILENAME_BIOS" ]] && break
                is_valid_dhcp_proxy_boot_filename "$DHCP_PROXY_PXE_BOOT_FILENAME_BIOS" && break
                print_error "Invalid boot filename (no whitespace, commas, or other .env-unsafe characters like \$, \`, \", ', \\, #): $DHCP_PROXY_PXE_BOOT_FILENAME_BIOS"
                ask "BIOS (legacy x86PC) boot filename (blank = skip BIOS clients)" ""
            done

            ask "UEFI (x86-64/ARM64) boot filename (blank = skip UEFI clients)" "$DHCP_PROXY_PXE_BOOT_FILENAME_UEFI"
            while true; do
                DHCP_PROXY_PXE_BOOT_FILENAME_UEFI="$REPLY"
                [[ -z "$DHCP_PROXY_PXE_BOOT_FILENAME_UEFI" ]] && break
                is_valid_dhcp_proxy_boot_filename "$DHCP_PROXY_PXE_BOOT_FILENAME_UEFI" && break
                print_error "Invalid boot filename (no whitespace, commas, or other .env-unsafe characters like \$, \`, \", ', \\, #): $DHCP_PROXY_PXE_BOOT_FILENAME_UEFI"
                ask "UEFI (x86-64/ARM64) boot filename (blank = skip UEFI clients)" ""
            done

            if pxe_boot_pointer_answers_are_complete "$DHCP_PROXY_PXE_BOOT_SERVER" "$DHCP_PROXY_PXE_BOOT_FILENAME_BIOS" "$DHCP_PROXY_PXE_BOOT_FILENAME_UEFI"; then
                print_ok "PXE boot-pointer support configured (external boot server: $DHCP_PROXY_PXE_BOOT_SERVER)."
            else
                # Matches entrypoint.sh's own fail-safe: a boot server alone
                # renders no pxe-service directive at all (just a WARNING on
                # every start), so reset it here rather than persist a
                # permanently-incomplete, warning-generating config.
                print_warn "No BIOS or UEFI boot filename set; PXE boot-pointer support will remain inactive."
                DHCP_PROXY_PXE_BOOT_SERVER=""
            fi
        fi
    fi

    print_ok "DHCP proxy mode enabled — subnet start: $DHCP_SUBNET_START"
elif [[ "$DHCP_MODE" = "dnsmasq-relay" ]]; then
    # Issue #844: real DHCP relay. Only two values matter -- this relay's own
    # client-facing address (forwarded as giaddr) and the upstream server it
    # relays to. No subnet/DNS/PXE prompts: a relay injects nothing of its own.
    print_warn "dnsmasq-relay forwards every client's DHCP request to an upstream DHCP server on another segment."
    print_warn "The upstream server owns the whole lease and every option; LanCache injects nothing of its own here."

    while true; do
        ask "This relay's own IP on the client-facing network (giaddr)" ""
        DHCP_RELAY_LOCAL_ADDR="$REPLY"
        is_valid_ipv4 "$DHCP_RELAY_LOCAL_ADDR" && break
        print_error "Invalid IPv4 address: $DHCP_RELAY_LOCAL_ADDR"
    done

    while true; do
        ask "Upstream DHCP server IP" "$DHCP_GATEWAY"
        UPSTREAM_DHCP_IP="$REPLY"
        is_valid_ipv4 "$UPSTREAM_DHCP_IP" && break
        print_error "Invalid IPv4 address: $UPSTREAM_DHCP_IP"
    done

    print_ok "DHCP relay mode enabled — relaying ${DHCP_RELAY_LOCAL_ADDR} -> upstream ${UPSTREAM_DHCP_IP}"
else
    print_ok "DHCP skipped — existing router DHCP remains active"
fi

# ── 7b. LanCache-NG-NTP ───────────────────────────────────────────────────────
# Kept minimal and non-interactive by design: the container's own upstream
# server list and the DHCP auto-populate toggle are Admin-UI-configured
# settings (requirement 2 of the issue this service was built for), not
# install-wizard prompts -- this section only decides whether the container
# is created at all (NTP_ENABLED / the `ntp` Compose profile), matching how
# little SSL_ENABLED asks up front for its own similarly toggle-shaped
# feature above.
print_step "LanCache-NG-NTP"

printf "  A small, self-contained NTP server, disciplined against public NTP\n"
printf "  servers, that serves time to LAN clients on UDP/123. Enable/disable and\n"
printf "  upstream server list are then configured from the Admin UI.\n"
printf "  Default: disabled.\n\n"

ask "Enable LanCache-NG-NTP? [y/N]" "N"
NTP_ENABLED=0
NTP_DATA_DIR="$LANCACHE_STATE_DIR/ntp"
if [[ "${REPLY,,}" = "y" ]]; then
    NTP_ENABLED=1
    print_ok "LanCache-NG-NTP enabled — configure upstream servers and the DHCP auto-populate toggle from the Admin UI's NTP page"
else
    print_ok "LanCache-NG-NTP skipped — can be enabled later from the Admin UI"
fi

# ── 7c. Central logging ───────────────────────────────────────────────────────
# Issue #1343: central logging (syslog-ng + Fluent Bit, #453) was always meant
# to be a core, on-by-default feature -- the maintainer confirmed directly
# that it should be "always on" in intent -- but this wizard never asked
# about it at all, and the underlying Compose services carry `profiles:
# [logging]`, so a standard install never actually started them. Corrected
# design (maintainer decision after the initial "fully non-optional" framing
# was reconsidered): keep a real, working opt-out for genuinely
# storage-constrained installs, but default it to enabled -- the opposite
# default from SSL/DHCP/NTP above, which all default to OFF because they are
# genuinely opt-in features. A separate, Admin-UI-configurable log-verbosity
# control was considered while implementing this (per-service severity
# filtering, e.g. "only forward nginx WARN+") but deliberately NOT built here:
# fluent-bit's pipeline currently forwards every tailed line verbatim with no
# severity filter anywhere, nginx's access.log has no severity field to filter
# on at all, and a fluent-bit `-l`/Log_Level flag only controls fluent-bit's
# OWN diagnostic verbosity, not what it forwards -- wiring that flag to a UI
# control would have shipped a setting that does not do what its label says.
# See the #1343 issue thread for the decision list this was flagged back to
# the maintainer as, rather than silently building or silently dropping it.
print_step "Central logging"

printf "  Central logging (syslog-ng + Fluent Bit) collects and forwards logs from\n"
printf "  every service into one place for easier troubleshooting -- a core,\n"
printf "  on-by-default feature. Disable only for genuinely storage-constrained\n"
printf "  installs.\n"
printf "  Default: enabled.\n\n"

if confirm "Enable central logging? [Y/n]" "Y"; then
    LOGGING_ENABLED=1
    print_ok "Central logging enabled — adjust verbosity from the Admin UI's logging settings"
else
    LOGGING_ENABLED=0
    print_warn "Central logging disabled — re-enable later via LOGGING_ENABLED=1 in .env (or the Admin UI) and rerun setup.sh update"
fi

COMPOSE_PROFILES="$(compose_profiles_for_runtime "$COMPOSE_PROFILES" "$DHCP_MODE" "$NTP_ENABLED" "$LOGGING_ENABLED")"

# ── 8. Admin-UI access control ────────────────────────────────────────────────
print_step "Admin-UI access control"

printf "  Admin-UI runs on %s — reachable from your LAN by default.\n" "$IP_STANDARD"
printf "  Password protection is optional, but recommended on shared or untrusted networks.\n"
printf "  To restrict the UI to this host later, set UI_BIND_IP=127.0.0.1 in .env.\n\n"

ask "Protect Admin-UI with password? [Y/n]" "Y"
UI_AUTH_USER=""
UI_AUTH_PASSWORD=""
ALLOW_INSECURE_UI=false
if [[ "${REPLY,,}" = "y" ]]; then
    ask "Username" "admin"
    UI_AUTH_USER="$REPLY"

    # What: the stored user is read before it is compared
    # Why: a read error must not rotate the stored password
    # From: Issue #1683 | PR #1858
    existing_ui_user=""
    if [[ -f "$ENV_LOCAL" ]]; then
        existing_ui_user=$(get_env_var UI_AUTH_USER "$ENV_LOCAL") || exit $?
    fi
    if [[ -f "$ENV_LOCAL" ]] \
        && [[ "$existing_ui_user" = "$UI_AUTH_USER" ]] \
        && env_key_has_usable_secret UI_AUTH_PASSWORD "$ENV_LOCAL"; then
        UI_AUTH_PASSWORD=$(get_env_var UI_AUTH_PASSWORD "$ENV_LOCAL") || exit $?
        print_ok "Existing Admin-UI password preserved"
    elif [[ "$WIZARD_INTROSPECT_MODE" = "1" ]]; then
        # Issue #1176: introspection mode must not fabricate and print a real
        # random secret on every run -- it never gets written anywhere, and
        # doing so would also make list-prompts' own output non-deterministic
        # across repeat runs with identical answers (AG-OP-006/007), even
        # though the actual PROMPT sequence itself is unaffected either way.
        UI_AUTH_PASSWORD=""
        print_ok "Admin-UI password would be generated (skipped: introspection mode)"
    else
        UI_AUTH_PASSWORD=$(generate_secret_value UI_AUTH_PASSWORD alnum20) || exit $?
        printf "\n"
        print_ok "Credentials:"
        printf "    User:     ${BOLD}%s${RESET}\n" "$UI_AUTH_USER"
        printf "    Password: ${BOLD}%s${RESET}\n" "$UI_AUTH_PASSWORD"
        print_warn "Note the password now — it will also appear in $ENV_LOCAL"
        printf "\n"
    fi
else
    ask "Allow Admin-UI without authentication? [y/N]" "N"
    if [[ "${REPLY,,}" = "y" ]]; then
        ALLOW_INSECURE_UI=true
        print_warn "No password protection — Admin-UI will be reachable on $IP_STANDARD"
        print_warn "This is explicitly allowed by ALLOW_INSECURE_UI=true"
    else
        die "Admin-UI authentication is required. Re-run setup and enable password protection, or explicitly allow insecure access."
    fi
fi

# ── 9. Writing .env ───────────────────────────────────────────────────────────
print_step "Writing .env"

env_file="$ENV_LOCAL"

if [[ -f "$env_file" ]]; then
    ask "Overwrite .env.local? [y/N]" "N"
    [[ "${REPLY,,}" = "y" ]] || die "Cancelled."
fi

# Issue #1176: from here through the end of "Installing systemd watchdog"
# below is every remaining real mutation the install performs (secret
# generation, the actual .env write, cache/Kea/NTP directory creation,
# systemd unit files, `systemctl daemon-reload`) -- none of it can run in
# introspection mode, which must leave the host completely untouched. No
# prompt is asked anywhere in this span (confirmed by
# scripts/tracked/check-setup-prompt-drift.sh's own wizard-region scan, which would
# fail closed on a stray ask()/confirm() call site inside a newly
# unbalanced block here), so skipping it wholesale changes no prompt
# ordering -- control falls straight through to the unconditional
# "Start now?" prompt after "Installing systemd watchdog" either way.
if [[ "$WIZARD_INTROSPECT_MODE" != "1" ]]; then

# Generate or preserve secrets. Empty values and known placeholders are regenerated.
LANCACHE_IMAGE_REGISTRY=$(resolve_lancache_image_registry "$env_file")
LANCACHE_IMAGE_PREFIX=$(resolve_lancache_image_prefix "$env_file")
LANCACHE_IMAGE_CHANNEL=$(resolve_lancache_image_channel "$env_file")
LANCACHE_IMAGE_TAG=$(resolve_lancache_image_tag "$env_file")
LANCACHE_IMAGE_REFS=$(lancache_image_refs_for_tag "$env_file" "$LANCACHE_IMAGE_TAG") \
    || die "Cannot pin the images of ${LANCACHE_IMAGE_TAG}; ${env_file} was not written (exit $?)."

# Verify the resolved tag actually publishes an image for this host's
# architecture before any state below is written (#665). The earlier
# assert_prebuilt_image_platform_supported call only checked the host
# architecture in general, not this specific tag/channel.
assert_resolved_image_tag_platform_supported "$LANCACHE_IMAGE_REGISTRY" "$LANCACHE_IMAGE_PREFIX" "$LANCACHE_IMAGE_TAG"

KEA_CTRL_TOKEN=$(get_or_generate_secret KEA_CTRL_TOKEN "$env_file" hex32)
DDNS_TSIG_KEY=$(get_or_generate_secret DDNS_TSIG_KEY "$env_file" base64_32)
PDNS_API_KEY=$(get_or_generate_secret PDNS_API_KEY "$env_file" hex32)
# Bug hunt #849, observability.md finding #3: shared token gating
# POST /api/netdata-alarms (services/ui/src/routes/netdata_alarms.rs).
NETDATA_ALARM_TOKEN=$(get_or_generate_secret NETDATA_ALARM_TOKEN "$env_file" hex32)
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
# Issue #681: system-account identity, used only by the Admin UI's kicker
# connection (nats_kick.rs) to look up and force-disconnect a removed/rotated
# secondary's live connection.
NATS_SYS_USER=$(get_env_var NATS_SYS_USER "$env_file")
NATS_SYS_USER="${NATS_SYS_USER:-lancache-nats-sys}"
NATS_SYS_PASSWORD=$(get_or_generate_secret NATS_SYS_PASSWORD "$env_file" hex32)
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
    "CACHE_INACTIVE=365d" \
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
    "DHCP_RELAY_LOCAL_ADDR=${DHCP_RELAY_LOCAL_ADDR}" \
    "DHCP_PROXY_INTERFACE=${DHCP_PROXY_INTERFACE}" \
    "DHCP_PROXY_ROUTER=${DHCP_PROXY_ROUTER}" \
    "DHCP_NTP_SERVERS=${DHCP_NTP_SERVERS}" \
    "DHCP_PROXY_DOMAIN=${DHCP_PROXY_DOMAIN}" \
    "DHCP_PROXY_BOOT_FILENAME=${DHCP_PROXY_BOOT_FILENAME}" \
    "DHCP_PROXY_BOOT_SERVER=${DHCP_PROXY_BOOT_SERVER}" \
    "DHCP_PROXY_CUSTOM_OPTIONS=${DHCP_PROXY_CUSTOM_OPTIONS}" \
    "DHCP_PROXY_PXE_BOOT_SERVER=${DHCP_PROXY_PXE_BOOT_SERVER}" \
    "DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=${DHCP_PROXY_PXE_BOOT_FILENAME_BIOS}" \
    "DHCP_PROXY_PXE_BOOT_FILENAME_UEFI=${DHCP_PROXY_PXE_BOOT_FILENAME_UEFI}" \
    "NTP_ENABLED=${NTP_ENABLED}" \
    "NTP_DATA_DIR=${NTP_DATA_DIR}" \
    "LOGGING_ENABLED=${LOGGING_ENABLED}" \
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
    "NATS_SYS_USER=${NATS_SYS_USER}" \
    "NATS_SYS_PASSWORD=${NATS_SYS_PASSWORD}" \
    "SECONDARY_REGISTRATION_TOKEN=${SECONDARY_REGISTRATION_TOKEN}" \
    "UI_SESSION_TTL_SECONDS=${UI_SESSION_TTL_SECONDS}" \
    "COMPOSE_PROFILES=${COMPOSE_PROFILES}" \
    "UI_AUTH_USER=${UI_AUTH_USER}" \
    "UI_AUTH_PASSWORD=${UI_AUTH_PASSWORD}" \
    "ALLOW_INSECURE_UI=${ALLOW_INSECURE_UI}" \
    "UI_BIND_IP=${IP_STANDARD}"

write_file_atomically "$ENV_LOCAL" <<EOF
# ── LAN IPs ────────────────────────────────────────────────────────────────────
# Standard mode (no CA certificate needed): HTTP cached, HTTPS passthrough
IP_STANDARD=${IP_STANDARD}

# Second LAN IP for the SSL DNS/proxy, always required (AG-SETUP-001)
IP_SSL=${IP_SSL}

# Root of all persistent state (cache, DNS, DHCP, NTP)
LANCACHE_STATE_DIR=${LANCACHE_STATE_DIR}

# ── SSL ────────────────────────────────────────────────────────────────────────
SSL_ENABLED=${SSL_ENABLED}

# ── Cache ──────────────────────────────────────────────────────────────────────
CACHE_DIR=${CACHE_DIR}

CACHE_MAX_SIZE=${cache_gb}g
CACHE_MEM_MB=${CACHE_MEM_MB}

# For Admin UI (GB as number for progress bar)
CACHE_MAX_GB=${cache_gb}

# Image channel: stable (alias of latest, built from master) or
# nightly (built from current_dev). setup.sh resolves the channel
# to an immutable sha-* service tag before it pulls any image.
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
# Issue #844: DHCP-relay-mode local address (giaddr source). Empty unless
# DHCP_MODE=dnsmasq-relay; see docs/dhcp-modes.md.
DHCP_RELAY_LOCAL_ADDR=${DHCP_RELAY_LOCAL_ADDR}

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
# Issue #705: PXE boot-pointer (\`pxe-service\`) fields, empty by default.
# See docs/dhcp-modes.md and services/dhcp-proxy/entrypoint.sh's own
# _dhcp_proxy_render_pxe_service_directives for the full opt-in rationale.
DHCP_PROXY_PXE_BOOT_SERVER=${DHCP_PROXY_PXE_BOOT_SERVER}
DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=${DHCP_PROXY_PXE_BOOT_FILENAME_BIOS}
DHCP_PROXY_PXE_BOOT_FILENAME_UEFI=${DHCP_PROXY_PXE_BOOT_FILENAME_UEFI}

# ── LanCache-NG-NTP ────────────────────────────────────────────────────────────
# Enable/disable, upstream server list, and the DHCP auto-populate toggle are
# configured from the Admin UI's NTP page; this only controls whether the
# container is created at all (see the \`ntp\` Compose profile).
NTP_ENABLED=${NTP_ENABLED}
NTP_DATA_DIR=${NTP_DATA_DIR}

# ── Central logging ────────────────────────────────────────────────────────────
# Issue #1343: on by default (unlike SSL/DHCP/NTP above) -- central logging
# was always meant to be a core, always-available feature. Set to 0 here for
# a genuinely storage-constrained install; this controls whether the
# syslog-ng/fluent-bit containers are created at all (see the \`logging\`
# Compose profile).
LOGGING_ENABLED=${LOGGING_ENABLED}

# Kea Control Agent/API token shared by DHCP and Admin UI. Keep secret.
KEA_CTRL_TOKEN=${KEA_CTRL_TOKEN}

# Shared TSIG key for Kea DDNS → PowerDNS updates. Keep secret.
DDNS_TSIG_KEY=${DDNS_TSIG_KEY}

# ── PowerDNS API ───────────────────────────────────────────────────────────────
# API key for PowerDNS Authoritative + Recursor (generated, do not change)
PDNS_API_KEY=${PDNS_API_KEY}

# ── Netdata alarm forwarding ────────────────────────────────────────────────────
# Shared token for Netdata's alarm-notify.sh to authenticate to the Admin
# UI's POST /api/netdata-alarms webhook (bug hunt #849, observability.md
# finding #3; generated, do not change)
NETDATA_ALARM_TOKEN=${NETDATA_ALARM_TOKEN}

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
# System-account identity (generated, do not change). Used only by the Admin
# UI's kicker connection (nats_kick.rs) to look up and force-disconnect a
# removed/rotated secondary's live NATS connection (issue #681).
NATS_SYS_USER=${NATS_SYS_USER}
NATS_SYS_PASSWORD=${NATS_SYS_PASSWORD}
# Token for setup.sh secondary — anyone who knows this can register a secondary
SECONDARY_REGISTRATION_TOKEN=${SECONDARY_REGISTRATION_TOKEN}

# ── Profiles ───────────────────────────────────────────────────────────────────
# Comma-separated Compose profiles, kept in sync by compose_profiles_for_runtime()
# on every install/update/Admin-UI-driven change -- do not hand-edit without
# also updating the matching *_ENABLED/DHCP_MODE key above, since the next
# convergence tick recomputes this value from those keys, not the other way
# around. Recognized values: ssl (SSL mode), dhcp-kea (Kea DHCP), dhcp-proxy
# (dnsmasq ProxyDHCP/relay), ntp (LanCache-NG-NTP), logging (syslog-ng/
# fluent-bit central logging, on by default per issue #1343). Empty = only the
# always-on core services.
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

# Bind address for Admin-UI. Default keeps it reachable on the LAN.
# Set to 127.0.0.1 to restrict access to this host.
UI_BIND_IP=${IP_STANDARD}
EOF
set_template_owned_env_defaults "$ENV_LOCAL"
print_ok ".env.local written: $ENV_LOCAL"
write_lancache_image_refs "$ENV_LOCAL" "$LANCACHE_IMAGE_REFS"

# ── 10. Creating directories ───────────────────────────────────────────────────
print_step "Creating directories"
mkdir -p "$CACHE_DIR"
print_ok "Cache:          $CACHE_DIR"
if [[ "$DHCP_ENABLED" = "1" && -n "$KEA_DATA_DIR" ]]; then
    mkdir -p "$KEA_DATA_DIR"
    print_ok "Kea data:       $KEA_DATA_DIR"
fi
if [[ "$NTP_ENABLED" = "1" && -n "$NTP_DATA_DIR" ]]; then
    mkdir -p "$NTP_DATA_DIR"
    print_ok "NTP data:       $NTP_DATA_DIR"
fi
if [[ "$LOGGING_ENABLED" = "1" ]]; then
    # Real, reproduced bug this pre-creation step fixes (see the combined
    # `syslog` container's own data-loss-detector.sh header for the full
    # finding): a bind-mounted host directory that does not already exist
    # before first container start is auto-created by Docker as root:root
    # 0755, which the non-root (uid 10001) syslog-ng process in the combined
    # container cannot write its own per-host subdirectories into --
    # silently, with `syslog-ng-ctl stats` still reporting messages as
    # "processed" even though zero bytes reach disk. Pre-creating and
    # chowning this path here, mirroring $CACHE_DIR's existing pattern
    # above, is the fix at the deployment-tooling layer; the combined
    # container's own periodic detector is the defense-in-depth backstop for
    # an install that predates this fix or has its permissions changed
    # later (e.g. by a manual `chown` mistake, or a restore from a backup
    # taken with different ownership).
    #
    # Idempotence (AG-OP-006/013): `mkdir -p` and `chown` are both naturally
    # idempotent -- re-running this block against an already-correct
    # directory changes nothing and does not error. `${SYSLOG_NG_LOG_DIR:-}`
    # honors an operator override the same way deploy/*/docker-compose.yml's
    # own `${SYSLOG_NG_LOG_DIR:-...}` fallback does, so a customized path is
    # preserved rather than silently redirected to the computed default
    # (AG-OP-009).
    syslog_ng_log_dir="${SYSLOG_NG_LOG_DIR:-$LANCACHE_STATE_DIR/syslog-ng}"
    mkdir -p "$syslog_ng_log_dir" || die "Failed to create $syslog_ng_log_dir (exit $?)."
    if chown_err=$(chown 10001:10001 "$syslog_ng_log_dir" 2>&1); then
        print_ok "Syslog-ng log root: $syslog_ng_log_dir (owned by uid 10001)"
    else
        # Non-fatal: this host may not grant setup.sh's own invoking user
        # permission to chown (e.g. running unprivileged against an existing
        # directory owned by someone else already). The combined container's
        # data-loss detector still catches the resulting silent-write
        # failure at runtime rather than this install failing closed here.
        print_warn "Could not chown $syslog_ng_log_dir to uid 10001 ($chown_err) -- the combined syslog container may not be able to write logs there. See docs/architecture-ng.md's syslog-ng section, or chown it manually before starting the stack."
    fi
fi

# ── 11. Installing systemd watchdog ───────────────────────────────────────────
# What: boot start, drift convergence, optional daily update
# Why: units are enabled only after the first pull succeeds
print_step "Installing systemd watchdog"

SYSTEMD_AVAILABLE=0
if ! systemd_available; then
    print_warn "systemd not found — watchdog will not be installed"
    print_warn "Start stack manually after reboot: $SCRIPT_DIR/setup.sh compose $INSTALL_DIR up -d"
else
    write_lancache_systemd_units "$INSTALL_DIR"
    SYSTEMD_AVAILABLE=1
    print_ok "systemd units installed; they will be enabled after image pull succeeds"
fi

fi # WIZARD_INTROSPECT_MODE guard opened before "Writing .env" above

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
printf "  %-26s %s\n"    "Stack directory:"         "$INSTALL_DIR"
printf "  %-26s %s\n"    "Data directory:"          "$LANCACHE_STATE_DIR"
printf "  %-26s %s\n"    "Cache:"                   "$CACHE_DIR"
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
    [[ -n "$DHCP_PROXY_INTERFACE" ]] && printf "  %-26s %s\n" "  Listen interface:" "$DHCP_PROXY_INTERFACE"
    [[ -n "$DHCP_PROXY_ROUTER" ]] && printf "  %-26s %s\n" "  Router option (PXE-scoped):" "$DHCP_PROXY_ROUTER"
    [[ -n "$DHCP_NTP_SERVERS" ]] && printf "  %-26s %s\n" "  NTP option (PXE-scoped):" "$DHCP_NTP_SERVERS"
    [[ -n "$DHCP_PROXY_DOMAIN" ]] && printf "  %-26s %s\n" "  Domain option (PXE-scoped):" "$DHCP_PROXY_DOMAIN"
    [[ -n "$DHCP_PROXY_BOOT_FILENAME" ]] && printf "  %-26s %s\n" "  PXE boot filename:" "$DHCP_PROXY_BOOT_FILENAME"
    # An operator-set value that never appears in this install summary looks
    # unconfigured even when it isn't -- print it whenever it is non-empty,
    # matching the other conditional lines in this block.
    [[ -n "$DHCP_PROXY_BOOT_SERVER" ]] && printf "  %-26s %s\n" "  PXE boot server:" "$DHCP_PROXY_BOOT_SERVER"
    [[ -n "$DHCP_PROXY_PXE_BOOT_SERVER" ]] && printf "  %-26s %s\n" "  PXE boot-pointer server:" "$DHCP_PROXY_PXE_BOOT_SERVER"
    [[ -n "$DHCP_PROXY_PXE_BOOT_FILENAME_BIOS" ]] && printf "  %-26s %s\n" "  PXE boot-pointer (BIOS):" "$DHCP_PROXY_PXE_BOOT_FILENAME_BIOS"
    [[ -n "$DHCP_PROXY_PXE_BOOT_FILENAME_UEFI" ]] && printf "  %-26s %s\n" "  PXE boot-pointer (UEFI):" "$DHCP_PROXY_PXE_BOOT_FILENAME_UEFI"
fi
if [[ "$NTP_ENABLED" = "1" ]]; then
    printf "  %-26s %s\n" "LanCache-NG-NTP:" "enabled (configure upstream servers from the Admin UI)"
else
    printf "  %-26s %s\n" "LanCache-NG-NTP:" "disabled"
fi
if [[ "$LOGGING_ENABLED" = "1" ]]; then
    printf "  %-26s %s\n" "Central logging:" "enabled"
else
    printf "  %-26s %s\n" "Central logging:" "disabled"
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
# Issue #1176: this is the last prompt list-prompts needs -- reusing the
# existing "start later" exit path here (rather than adding a second exit
# point) also guarantees introspection never reaches the real pull/systemctl/
# docker-compose-up mutations below, regardless of what an answers file said.
[[ "$WIZARD_INTROSPECT_MODE" != "1" && "${REPLY,,}" != "n" ]] \
    || { printf "\n  Start later with: %s compose %s up -d\n\n" "$SCRIPT_DIR/setup.sh" "$INSTALL_DIR"; exit 0; }

# ── 13. Starting stack ───────────────────────────────────────────────────────
# Pull before starting so GHCR/auth/platform failures happen while systemd units
# are installed but not yet enabled, keeping failed first installs reversible.
print_step "Pulling images"
cd "$INSTALL_DIR"
assert_prebuilt_image_platform_supported
stack_compose "$INSTALL_DIR" "$ENV_LOCAL" pull \
    || die "Failed to pull required container images. Check network access and GHCR authentication, then rerun setup.sh."

run_kea_dhcp_activation_preflight "$ENV_LOCAL"

print_step "Starting stack"
if [[ "$SYSTEMD_AVAILABLE" = "1" ]]; then
    systemctl enable "$STACK_UNIT" || die "Failed to enable $STACK_UNIT (exit $?)."
    systemctl enable "$CONVERGE_TIMER_UNIT" || die "Failed to enable $CONVERGE_TIMER_UNIT (exit $?)."
    print_ok "$STACK_UNIT enabled for boot"
    print_ok "$CONVERGE_TIMER_UNIT enabled for boot"
    systemctl start "$STACK_UNIT" || die "Failed to start $STACK_UNIT (exit $?)."
    systemctl start "$CONVERGE_TIMER_UNIT" || die "Failed to start $CONVERGE_TIMER_UNIT (exit $?)."
    if [[ "$AUTO_UPDATE_ENABLED" = "1" ]]; then
        systemctl enable "$AUTO_UPDATE_TIMER_UNIT" || die "Failed to enable $AUTO_UPDATE_TIMER_UNIT (exit $?)."
        systemctl start "$AUTO_UPDATE_TIMER_UNIT" || die "Failed to start $AUTO_UPDATE_TIMER_UNIT (exit $?)."
        print_ok "$AUTO_UPDATE_TIMER_UNIT enabled (scheduled automatic updates)"
    fi
else
    stack_compose "$INSTALL_DIR" "$ENV_LOCAL" up -d || die "Failed to start the stack in $INSTALL_DIR (exit $?)."
fi
print_ok "Stack started"

# ── 14. Post-start info ──────────────────────────────────────────────────────
# What: Admin UI URL from the ui port mapping; else a warn
# Why: compose owns IP and port; a print never aborts setup
# From: Issue #1683 | PR #1858
ui_url_rc=0
ui_url=$(compose_config_value "$INSTALL_DIR" "$ENV_LOCAL" \
    '.services.ui.ports[0] // empty | "http://\(.host_ip):\(.published)"') || ui_url_rc=$?
if [[ "$ui_url_rc" -ne 0 || -z "$ui_url" ]]; then
    print_warn "Cannot derive the Admin-UI URL (exit $ui_url_rc); the stack runs, see the ui ports in $INSTALL_DIR/docker-compose.yml."
    ui_url="(see the ui ports in $INSTALL_DIR/docker-compose.yml)"
fi
printf "\n"
printf "${BOLD}${GREEN}══════════════════════════════════════════════════${RESET}\n"
printf "${BOLD}${GREEN}  LanCache-NG is running!${RESET}\n"
printf "${BOLD}${GREEN}══════════════════════════════════════════════════${RESET}\n"
printf "\n"
if [[ -n "$UI_AUTH_USER" ]]; then
    printf "  ${BOLD}Admin-UI:${RESET}    %s  (User: %s)\n" "$ui_url" "$UI_AUTH_USER"
else
    printf "  ${BOLD}Admin-UI:${RESET}    %s\n" "$ui_url"
fi
printf "\n"
if [[ "$SSL_ENABLED" = "1" ]]; then
    printf "  ${BOLD}CA certificate${RESET} (available after first start):\n"
    printf "    %s/certs/ca.crt\n" "$SCRIPT_DIR"
    printf "    → install on clients for SSL mode\n"
    printf '    → guide: %s/wiki\n' "$LANCACHE_REPO_URL"
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
