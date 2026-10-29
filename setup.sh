#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: lifecycle CLI; subcommands dispatched at file end
# Why: one customer file for install and every later change
# From: Issue #1683 | PR #1858
set -euo pipefail
export LANG=C LC_ALL=C

# What: absolute directory of this setup.sh
# Why: SOT, compose and state paths resolve from it
# From: Issue #1683 | PR #1858
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)"
# What: helper container image; require_helper_image sets it
# Why: volume copy, restore and listing share one image
# From: Issue #1683 | PR #1858
LANCACHE_HELPER_IMAGE=""
# What: the units this script manages
# Why: one owner for every unit name
# From: Issue #1683 | PR #1858
STACK_UNIT="lancache.service"
CONVERGE_SERVICE_UNIT="lancache-converge.service"
CONVERGE_TIMER_UNIT="lancache-converge.timer"
AUTO_UPDATE_SERVICE_UNIT="lancache-auto-update.service"
AUTO_UPDATE_TIMER_UNIT="lancache-auto-update.timer"
DOCKER_UNIT="docker.service"
# What: the OpenRC services that stand for those units
# Why: Alpine has no systemd; one loop service per timer
# From: Issue #1683 | PR #1858
OPENRC_STACK_SERVICE="lancache"
OPENRC_CONVERGE_SERVICE="lancache-converge"
OPENRC_AUTO_UPDATE_SERVICE="lancache-auto-update"
OPENRC_DOCKER_SERVICE="docker"
# What: backup root and project repo
# Why: one owner each; rollback must find the backups
# From: Issue #1683 | PR #1858
BACKUP_ROOT="${LANCACHE_BACKUP_ROOT:-/var/backups/lancache-ng}"
# What: bootstrap copy of the SOT LANCACHE_REPO_URL
# Why: curl | bash clones before any SOT file exists
# From: Issue #1683 | PR #1912
LANCACHE_REPO_URL="https://github.com/wiki-mod/lancache-ng"
# What: tag of a source archive; git fills it at export
# Why: an archive has no .git; the tag is its version
# From: Issue #1683 | PR #1858
read -r LANCACHE_ARCHIVE_REF <<'EOF'
$Format:%(describe:tags=true)$
EOF
# What: Docker's repo root and Docker CE package names
# Why: apt, rpm, conflict guard and prompts share them
# From: Issue #1683 | PR #1858
DOCKER_REPO_URL="https://download.docker.com/linux"
DOCKER_COMPOSE_PLUGIN="docker-compose-plugin"
DOCKER_BUILDX_PLUGIN="docker-buildx-plugin"
DOCKER_CE_CLI="docker-ce-cli"
DOCKER_CE_PACKAGES=(docker-ce "$DOCKER_CE_CLI" containerd.io)
DOCKER_RPM_PACKAGES=("${DOCKER_CE_PACKAGES[@]}" "$DOCKER_BUILDX_PLUGIN" "$DOCKER_COMPOSE_PLUGIN")
# What: distro Docker package names per package manager
# Why: lookups, install sets, hints and prompts share them
# From: Issue #1683 | PR #1858
APT_DOCKER_ENGINE="docker.io"
APT_DOCKER_CLI="docker-cli"
APT_LEGACY_COMPOSE="docker-compose"
APT_COMPOSE_PACKAGES=("$DOCKER_COMPOSE_PLUGIN" docker-compose-v2 "$APT_LEGACY_COMPOSE")
APT_BUILDX_PACKAGES=("$DOCKER_BUILDX_PLUGIN" docker-buildx)
PACMAN_COMPOSE="docker-compose"
PACMAN_DOCKER_PACKAGES=(docker "$PACMAN_COMPOSE" docker-buildx)
# What: Alpine Docker packages and the GNU tools of setup.sh
# Why: BusyBox lacks options like realpath -m and grep -P
# From: Issue #1683 | PR #1858
APK_COMPOSE="docker-cli-compose"
APK_DOCKER_PACKAGES=(docker "$APK_COMPOSE" docker-cli-buildx)
APK_GNU_PACKAGES=(coreutils grep tar iproute2)

# What: ANSI colors only when stdout is a terminal
# Why: logs and pipes must not get escape codes
# From: Issue #1683 | PR #1858
if [[ -t 1 ]]; then
    BOLD="\033[1m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"
    RED="\033[0;31m"; CYAN="\033[0;36m"; RESET="\033[0m"
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; RESET=""
fi

# What: one output format for steps, results and errors
# Why: every message of setup.sh looks the same
# From: Issue #1683 | PR #1858
print_step() { printf "\n${BOLD}${CYAN}▶ %s${RESET}\n" "$*"; }
print_ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
print_warn() { printf "  ${YELLOW}⚠${RESET} %s\n" "$*"; }
print_error(){ printf "  ${RED}✗${RESET} %s\n" "$*" >&2; }
print_skip() { printf "  ${YELLOW}↷${RESET} SKIP: %s\n" "$*" >&2; }
die()        { print_error "$*"; exit 1; }

# What: true if a whole line of the list equals the needle
# Why: one membership owner; no grep exit code to misread
# From: Issue #1683 | PR #1858
list_has_line() {
    local needle="$1" line
    while IFS= read -r line; do
        if [[ "$line" == "$needle" ]]; then return 0; fi
    done <<< "$2"
    return 1
}

REPLY=""
# What: list-prompts makes ask()/confirm() record prompts
# Why: one shared recorder keeps the prompt walk in sync
# From: Issue #1683 | PR #1858
WIZARD_INTROSPECT_MODE=0
# What: fd 9 is the optional list-prompts answers file
# Why: unset means every prompt takes its default
# From: Issue #1683 | PR #1858
WIZARD_INTROSPECT_ANSWERS_FD=""
# What: the previous prompt of the list-prompts walk
# Why: finds a validation loop that cannot converge
# From: Issue #1683 | PR #1858
WIZARD_INTROSPECT_LAST_PROMPT=""

# What: prints PROMPT; REPLY from answer fd, else default
# Why: one code path, so the walk matches the real wizard
# From: Issue #1683 | PR #1858
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
# From: Issue #1683 | PR #1858
ask() {
    local prompt="$1" default="${2:-}"
    if [[ "$WIZARD_INTROSPECT_MODE" = "1" ]]; then
        wizard_introspect_record_prompt "$prompt" "$default"
        return
    fi
    local tty_fd
    # What: no terminal stops setup.sh with a clear error
    # Why: a failed tty read took the default silently
    # From: Issue #1683 | PR #1858
    { exec {tty_fd}< /dev/tty; } 2>&- \
        || die "setup.sh needs a terminal to ask '$prompt'; run it in an interactive shell (for SSH: ssh -t)."
    printf '  %s%s%s [%s]: ' "${BOLD}" "$prompt" "${RESET}" "$default"
    read -r REPLY <&"$tty_fd"
    exec {tty_fd}<&-
    REPLY="${REPLY:-$default}"
}

# What: asks until the answer passes a check function
# Why: one owner of the ask, check and retry loop
# From: Issue #1683 | PR #1912
ask_checked() {
    local -n _ask_checked_ref="$1"
    local prompt="$2" default="$3" check="$4" error="$5" optional="${6:-0}" retry_default="$3"
    [[ "$optional" != 1 ]] || retry_default=""
    ask "$prompt" "$default"
    while true; do
        _ask_checked_ref="$REPLY"
        [[ "$optional" = 1 && -z "$_ask_checked_ref" ]] && break
        "$check" "$_ask_checked_ref" && break
        print_error "${error}: ${_ask_checked_ref}"
        ask "$prompt" "$retry_default"
    done
}

# What: a SOT 0/1 or true/false default as Y or N
# Why: the SOT owns each default; a prompt only shows it
# From: Issue #1683 | PR #1912
yn_default() {
    local value
    value=$(prod_env_default "$1") || exit $?
    case "$value" in
        1|true) printf 'Y\n' ;;
        0|false) printf 'N\n' ;;
        *) die "The SOT default of $1 is '$value', not 0/1 or true/false." ;;
    esac
}

# What: the 1/0 value of a y/n answer
# Why: the wizard stores the answer, never a default
# From: Issue #1683 | PR #1912
yn_flag() {
    case "${1,,}" in y|yes) printf '1\n' ;; *) printf '0\n' ;; esac
}

# What: the [y/N] or [Y/n] hint of a prompt default
# Why: the capital letter marks the default answer
# From: Issue #1683 | PR #1912
yn_hint() {
    if [[ "$1" = "Y" ]]; then printf '[Y/n]\n'; else printf '[y/N]\n'; fi
}

# What: rejects a missing value or a flag as value
# Why: a flag would silently consume the next option
# From: Issue #1683 | PR #1858
require_value() {
    local option="$1" value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        die "${option} requires a value"
    fi
}

# What: true for a dotted IPv4, each octet 0 to 255
# Why: values are written to Docker and DNS config
# From: Issue #1683 | PR #1858
is_valid_ipv4() {
    local ip="$1"
    local octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    [[ "$ip" =~ ^${octet}\.${octet}\.${octet}\.${octet}$ ]]
}

# What: true for integers above zero, base-10 forced
# Why: leading zeros like 010 must not parse as octal
# From: Issue #1683 | PR #1858
is_positive_integer() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

# What: true if the value starts with /
# Why: cache and Kea data dirs must be absolute paths
# From: Issue #1683 | PR #1858
is_absolute_path() {
    [[ -n "${1:-}" && "$1" == /* ]]
}

# What: true if the value is a valid IPv4 ending in .0
# Why: dnsmasq proxy-DHCP needs a subnet base address
# From: Issue #1683 | PR #1858
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

# What: true for a DNS name; labels 1-63, total up to 253
# Why: dnsmasq writes the proxy domain into its config
# From: Issue #450
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

# What: true for one DHCP NTP entry: an IPv4 or a DNS name
# Why: watchdog and UI resolve names; digits stay IPv4
# From: Issue #1683 | PR #1912
is_valid_dhcp_ntp_server() {
    local entry="${1:-}"
    is_valid_ipv4 "$entry" && return 0
    [[ "$entry" =~ ^[0-9.]+$ ]] && return 1
    is_valid_dhcp_proxy_domain "$entry"
}

# What: true for an IPv6 literal of hex groups and colons
# Why: upstream DNS servers may be IPv6; Rust checks again
# From: Issue #1918 | PR #1858
is_valid_ipv6() {
    local ip="${1:-}"
    [[ "$ip" == *:*:* && "$ip" =~ ^[0-9A-Fa-f:]+$ && ! "$ip" =~ [0-9A-Fa-f]{5} \
        && "$ip" != *:::* && "${ip#*::}" != *::* ]]
}

# What: true if an IPv4 lies inside an IPv4 CIDR
# Why: LOOPBACK_NETS names loopback as nets, not as IPs
# From: Issue #1918 | PR #1858
ipv4_in_cidr() {
    local ip="$1" net="${2%/*}" bits="${2#*/}" a b c d n m
    if ! is_valid_ipv4 "$ip" || ! is_valid_ipv4 "$net" \
        || [[ ! "$bits" =~ ^[0-9]{1,2}$ ]] || (( 10#$bits > 32 )); then
        return 1
    fi
    bits=$(( 10#$bits ))
    IFS=. read -r a b c d <<< "$ip"
    n=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    IFS=. read -r a b c d <<< "$net"
    m=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    (( bits == 0 || (n >> (32 - bits)) == (m >> (32 - bits)) ))
}

# What: host and port of one upstream DNS entry
# Why: [v6]:port, v4:port and a bare IP name one server
# From: Issue #1918 | PR #1858
dns_upstream_split() {
    local entry="$1"
    local -n _split_host_ref="$2" _split_port_ref="$3"
    _split_host_ref="$entry" _split_port_ref=""
    if [[ "$entry" == \[*\]:* ]]; then
        _split_host_ref="${entry#\[}" _split_port_ref="${entry##*\]:}"
        _split_host_ref="${_split_host_ref%%\]*}"
    elif [[ "$entry" == *:* && "$entry" != *:*:* ]]; then
        _split_host_ref="${entry%:*}" _split_port_ref="${entry#*:}"
    fi
}

# What: why one upstream server is unusable, else nothing
# Why: the prompt names the reason while the user types
# From: Issue #1918 | PR #1858
dns_upstream_server_problem() {
    local entry="$1" own="$2" host port net nets
    local -a loopback_nets
    dns_upstream_split "$entry" host port
    nets=$(prod_env_default LOOPBACK_NETS) || exit $?
    read -r -a loopback_nets <<< "$nets"
    if [[ -n "$port" ]] && ! { is_positive_integer "$port" && (( 10#$port <= 65535 )); }; then
        printf "'%s' has no port from 1 to 65535\n" "$entry"
    elif ! is_valid_ipv4 "$host" && ! is_valid_ipv6 "$host"; then
        printf "'%s' is no IPv4 or IPv6 address\n" "$entry"
    elif [[ "$host" =~ ^[0:.]+$ ]]; then
        printf "'%s' is the unspecified address, not a DNS server\n" "$entry"
    elif [[ ",${own}," == *",${host},"* ]]; then
        printf "'%s' is a LanCache-NG address; forwarding to it would loop\n" "$entry"
    else
        for net in "${loopback_nets[@]}"; do
            if [[ "${host,,}" = "$net" ]] || ipv4_in_cidr "$host" "$net"; then
                printf "'%s' is this host itself, not an external DNS server\n" "$entry"
                break
            fi
        done
    fi
}

# What: why one upstream zone is unusable, else nothing
# Why: local zones stay; unsigned ones must be forwarded
# From: Issue #1918 | PR #1858
dns_upstream_zone_problem() {
    local raw="$1" lan="${2,,}" forwarded="${3:-}" zone inside=0 item
    local -a forwarded_zones
    zone="${raw,,}"
    zone="${zone%.}"
    read -r -a forwarded_zones <<< "${forwarded//,/ }"
    for item in "${forwarded_zones[@]}"; do
        [[ "$zone" = "$item" || "$zone" == *".$item" ]] && inside=1
    done
    if ! is_valid_dhcp_proxy_domain "$zone"; then
        printf "'%s' is no valid domain name\n" "$raw"
    elif [[ "$zone" = "$lan" || "$zone" == *".$lan" ]]; then
        printf "'%s' is answered by LanCache-NG itself\n" "$raw"
    elif [[ -n "$forwarded" && "$inside" = 0 ]]; then
        printf "'%s' is not inside a forwarded domain\n" "$raw"
    fi
}

# What: entries lower case, without final dot, comma-joined
# Why: .env keeps one spelling, so reruns compare equal
# From: Issue #1918 | PR #1858
dns_upstream_join() {
    local item out=""
    for item in "$@"; do
        item="${item,,}"
        out+="${out:+,}${item%.}"
    done
    printf '%s\n' "$out"
}

# What: the +short answer of one DNS query, else the error
# Why: the health check and the upstream probe ask alike
# From: Issue #1918 | PR #1858
dns_short_answer() {
    local server="$1" port="$2" type="$3" name="$4" answer rc=0
    local -a args=(+time=2 +tries=1 +short)
    [[ -z "$port" ]] || args+=(-p "$port")
    answer=$(dig "${args[@]}" @"$server" "$type" "$name" 2>&1) || rc=$?
    if [[ "$rc" -ne 0 || -z "$answer" || "$answer" == *";;"* ]]; then
        printf '%s\n' "${answer:-empty answer (exit $rc)}"
        return 1
    fi
    printf '%s\n' "$answer"
}

# What: one real DNS query to each upstream server
# Why: the user sees at once whether a server answers
# From: Issue #1918 | PR #1858
dns_upstream_answers() {
    local entry host port answer failed=0
    # What: list-prompts sends no query
    # Why: the walk must not touch the network
    # From: Issue #1918 | PR #1858
    if [[ "$WIZARD_INTROSPECT_MODE" = 1 ]]; then
        return 0
    fi
    install_missing_tools dig
    for entry in "$@"; do
        dns_upstream_split "$entry" host port
        if answer=$(dns_short_answer "$host" "$port" NS .); then
            print_ok "$entry answers DNS queries"
        else
            print_warn "$entry did not answer a DNS query: $answer"
            failed=1
        fi
    done
    [[ "$failed" = 0 ]]
}

# What: asks the optional upstream DNS questions
# Why: install and configure-upstream-dns ask the same
# From: Issue #1918 | PR #1858
prompt_dns_upstream() {
    local servers="$1" zones="$2" unsigned="$3" own="$4" lan="$5"
    local use_yn="N" scope="all" entry problem bad
    local -a entries
    [[ -z "$servers" ]] || use_yn="Y"
    [[ -z "$zones" ]] || scope="domains"
    printf "  Names LanCache-NG does not know (for example your NAS) are\n"
    printf "  resolved from the internet. A router or firewall that knows\n"
    printf "  them can answer instead. Game CDN names stay with LanCache-NG.\n\n"
    ask "Use an external DNS server? $(yn_hint "$use_yn")" "$use_yn"
    DNS_UPSTREAM_SERVERS="" DNS_UPSTREAM_ZONES="" DNS_UPSTREAM_UNSIGNED_ZONES=""
    if [[ "$(yn_flag "$REPLY")" != 1 ]]; then
        return 0
    fi
    while true; do
        ask "DNS server IPs (space or comma separated)" "$servers"
        read -r -a entries <<< "${REPLY//,/ }"
        bad=""
        (( ${#entries[@]} > 0 )) || bad="enter at least one IP address"
        for entry in "${entries[@]}"; do
            problem=$(dns_upstream_server_problem "$entry" "$own") || exit $?
            [[ -z "$problem" ]] || bad="$problem"
        done
        if [[ -z "$bad" ]]; then
            dns_upstream_answers "${entries[@]}" && break
            confirm "A server did not answer. Save anyway? [y/N]" "N" && break
            continue
        fi
        print_error "Invalid DNS server: $bad"
    done
    DNS_UPSTREAM_SERVERS=$(dns_upstream_join "${entries[@]}")
    while true; do
        ask "Forward all names, or only some domains? [all/domains]" "$scope"
        [[ "${REPLY,,}" = "all" || "${REPLY,,}" = "domains" ]] && break
        print_error "Please answer 'all' or 'domains'"
    done
    if [[ "${REPLY,,}" = "domains" ]]; then
        while true; do
            ask "Domains to forward (space or comma separated)" "$zones"
            read -r -a entries <<< "${REPLY//,/ }"
            bad=""
            (( ${#entries[@]} > 0 )) || bad="enter at least one domain"
            for entry in "${entries[@]}"; do
                problem=$(dns_upstream_zone_problem "$entry" "$lan")
                [[ -z "$problem" ]] || bad="$problem"
            done
            [[ -n "$bad" ]] || break
            print_error "Invalid domain: $bad"
        done
        DNS_UPSTREAM_ZONES=$(dns_upstream_join "${entries[@]}")
    fi
    printf "  DNSSEC checks stay on. Private domains of your network have\n"
    printf "  no signature; name them here, or their lookups fail.\n"
    while true; do
        ask "Private domains without DNSSEC (space or comma, 'none')" "${unsigned:-none}"
        entries=()
        [[ "${REPLY,,}" = "none" ]] || read -r -a entries <<< "${REPLY//,/ }"
        bad=""
        for entry in "${entries[@]}"; do
            problem=$(dns_upstream_zone_problem "$entry" "$lan" "$DNS_UPSTREAM_ZONES")
            [[ -z "$problem" ]] || bad="$problem"
        done
        [[ -n "$bad" ]] || break
        print_error "Invalid private domain: $bad"
    done
    DNS_UPSTREAM_UNSIGNED_ZONES=$(dns_upstream_join "${entries[@]}")
}

# What: asks for local private PTR zones; kea needs them on
# Why: off sends PTR lookups on like every other name
# From: Issue #1918 | PR #1858
prompt_dns_local_reverse_zones() {
    local current="$1" dhcp_mode="$2" yn="N"
    if [[ "$dhcp_mode" = "kea" ]]; then
        DNS_LOCAL_REVERSE_ZONES=1
        print_ok "Local reverse zones on: Kea writes PTR records for its leases"
        return 0
    fi
    [[ "$current" != 1 ]] || yn="Y"
    printf "  Reverse lookups (IP to name, PTR) of private networks go to\n"
    printf "  the external DNS server or the internet. LanCache-NG can\n"
    printf "  answer them itself instead, from its own reverse zones.\n\n"
    ask "Answer private reverse lookups locally? $(yn_hint "$yn")" "$yn"
    DNS_LOCAL_REVERSE_ZONES=$(yn_flag "$REPLY")
}

# What: true for a boot filename without blank or comma
# Why: dnsmasq dhcp-boot splits its fields at commas
# From: Issue #450
is_valid_dhcp_proxy_boot_filename() {
    local filename="${1:-}"
    [[ -n "$filename" && "${#filename}" -le 255 ]] || return 1
    [[ "$filename" != *[[:space:],]* ]] || return 1
    # What: rejects newline and shell or .env metachars
    # Why: a later .env write fails after earlier steps ran
    # From: Issue #1683 | PR #1858
    case "$filename" in
        *$'\n'* | *'$'* | *'`'* | *'"'* | *"'"* | *\\* | *'#'* )
            return 1
            ;;
    esac
    return 0
}

# What: true if a server and any filename are both set
# Why: dnsmasq emits no pxe-service with a half missing
# From: Issue #1683 | PR #1858
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

# What: reports a failed host_lan_addresses call, exit as $1
# Why: three callers share one error text
# From: Issue #1683 | PR #1858
print_host_addresses_failed() {
    print_error "Failed to list the IPv4 addresses of this host (exit $1)."
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
        || { print_host_addresses_failed "$?"; return 2; }
    ip=$(awk 'NR == 1 { print $1 }' <<< "$addrs")
    if [[ -n "$ip" ]] && is_valid_ipv4 "$ip"; then
        printf '%s\n' "$ip"
        return 0
    fi

    return 1
}

# What: lists port-53 holders on the chosen listen IP
# Why: a busy port would fail silently at container start
# From: Issue #1683 | PR #1858
secondary_listen_ip_conflicts() {
    local listen_ip="$1" sockets dns_port

    dns_port=$(prod_env_default DNS_PORT) || exit $?
    sockets=$(ss -H -ltnup "( sport = :${dns_port} )") \
        || die "Failed to list the port ${dns_port} listeners of this host (exit $?)."
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

# What: a free DNS-port IP: LAN first, then loopback IPs
# Why: 1 = none free, 2 = listing failed; never swallowed
# From: Issue #1683 | PR #1858
secondary_suggest_alternate_listen_ip() {
    local current="$1" candidate addrs conflicts loopback_ip n count

    addrs=$(host_lan_addresses) \
        || { print_host_addresses_failed "$?"; return 2; }
    while read -r candidate _; do
        [[ -n "$candidate" ]] || continue
        [[ "$candidate" = "$current" ]] && continue
        conflicts=$(secondary_listen_ip_conflicts "$candidate") || return 2
        [[ -z "$conflicts" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done <<< "$addrs"

    loopback_ip=$(prod_env_default LOOPBACK_BIND_IP) || exit $?
    count=$(prod_env_default SECONDARY_LOOPBACK_CANDIDATES) || exit $?
    for (( n = 1; n <= count; n++ )); do
        candidate="${loopback_ip%.*}.${n}"
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
# From: Issue #1683 | PR #1858
secondary_choose_listen_ip() {
    local listen_ip="$1" conflicts suggestion dns_port

    dns_port=$(prod_env_default DNS_PORT) || exit $?
    while true; do
        conflicts="$(secondary_listen_ip_conflicts "$listen_ip")" || exit $?
        if [[ -z "$conflicts" ]]; then
            printf '%s\n' "$listen_ip"
            return 0
        fi

        print_warn "Port ${dns_port} is already in use for bind IP ${listen_ip}."
        {
            printf '%s\n' "$conflicts" | sed 's/^/    /'
            # What: port-53 holder details, raw output
            # Why: diagnostics only; exit code is no result
            # From: Issue #1683 | PR #1858
            if command_available fuser; then
                fuser -v "${dns_port}/tcp" "${dns_port}/udp" 2>&1 | sed 's/^/    /' || printf '    (fuser exit %s)\n' "$?"
            fi
            if command_available lsof; then
                lsof -nP "-iTCP:${dns_port}" "-iUDP:${dns_port}" -sTCP:LISTEN 2>&1 | sed 's/^/    /' || printf '    (lsof exit %s)\n' "$?"
            fi
        } >&2

        if ! [[ -t 0 && -t 1 ]]; then
            return 1
        fi

        suggestion=$(secondary_suggest_alternate_listen_ip "$listen_ip") \
            || (( $? == 1 )) || exit 2
        ask_checked listen_ip "Use another Secondary bind IP" "${suggestion:-$listen_ip}" is_valid_ipv4 "Invalid IPv4 address"
    done
}

# What: validates IPv4 CIDR with prefix 1-32
# Why: rejects bad masks before DHCP config is written
# From: Issue #1683 | PR #1858
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
# From: Issue #1683 | PR #1858
is_valid_dhcp_mode() {
    case "$1" in
        disabled|kea|dnsmasq-proxy|dnsmasq-relay) return 0 ;;
        *) return 1 ;;
    esac
}

# What: checks UI session TTL is 1 to MAX seconds (1 year)
# Why: a bad value must not yield a never-expiring cookie
# From: Issue #1683 | PR #1858
validate_ui_session_ttl_seconds() {
    local value="$1" source="${2:-UI_SESSION_TTL_SECONDS}" numeric max

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        die "UI_SESSION_TTL_SECONDS in ${source} must be an unsigned integer number of seconds."
    fi
    # What: strips leading zeros before the comparisons
    # Why: bash reads a leading zero as octal
    # From: Issue #1683 | PR #1858
    numeric="${value#"${value%%[!0]*}"}"
    numeric="${numeric:-0}"
    if [[ "$numeric" = "0" ]]; then
        die "UI_SESSION_TTL_SECONDS in ${source} must be greater than zero."
    fi
    max=$(prod_env_default UI_SESSION_TTL_MAX_SECONDS) || exit $?
    if (( ${#numeric} > ${#max} )) || { (( ${#numeric} == ${#max} )) && (( 10#$numeric > 10#$max )); }; then
        die "UI_SESSION_TTL_SECONDS in ${source} must be at most ${max} seconds."
    fi
}

# What: COMPOSE_PROFILES without retired project profiles
# Why: five fixed services; operator profiles stay
# From: Issue #1683 | PR #1912
compose_profiles_for_runtime() {
    local existing="${1:-}" profile result="" trimmed
    local -a profiles

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

    printf '%s\n' "$result"
}

# What: yes/no prompt; accepts y or yes, any case
# Why: wraps ask() for boolean decisions
# From: Issue #1683 | PR #1858
confirm() {
    local prompt="$1" default="${2:-N}"
    ask "$prompt" "$default"
    [[ "$(yn_flag "$REPLY")" = 1 ]]
}

# What: runs a broadcast DHCP probe before Kea activation
# Why: stops or warns before a second DHCP server exists
# From: Issue #1683 | PR #1858
run_kea_dhcp_activation_preflight() {
    local env_file="$1" output status server_identifier=""

    if [[ "$DHCP_MODE" != "kea" ]]; then
        print_skip "DHCP activation preflight: DHCP_MODE is '$DHCP_MODE', not kea"
        return 0
    fi

    print_step "DHCP activation preflight"
    printf "  Probe-only check: the dhcp image runs its DHCP probe and exits without starting Kea.\n"

    # What: one supervisor probe run in the dhcp image
    # Why: the same probe as the Admin UI; no extra package
    # From: Issue #1683 | PR #1912
    if ! output=$(sot_compose "$env_file" -f "$PROD_COMPOSE" run --rm --no-deps dhcp \
        probe) || ! status=$(json_value .status "$output") || [[ "$status" = unavailable || -z "$status" ]]; then
        print_warn "DHCP discovery preflight could not be executed inside the dhcp image."
        print_warn "Kea activation will require an explicit confirmation because the safety check did not complete."
        confirm "Continue with Kea activation anyway? [y/N]" "N" \
            || die "Cancelled DHCP activation."
        return 0
    fi

    # What: the server address of the first DHCP offer
    # Why: names the existing server in the warning
    # From: Issue #1683 | PR #1912
    if [[ "$status" = conflict_found ]]; then
        server_identifier=$(json_value .conflict.output "$output") || die "Cannot read the probe answer (exit $?)."
        print_warn "An existing DHCP server answered before Kea activation: ${server_identifier:-unknown}"
        print_warn "Kea would become a second active DHCP server if you continue."
        confirm "Continue with Kea activation anyway? [y/N]" "N" \
            || die "Cancelled DHCP activation."
    else
        print_ok "No DHCP server answer was detected before Kea activation."
    fi
}

# What: true if the command resolves on PATH
# Why: command -v prints the path; callers need only the rc
# From: Issue #1683 | PR #1912
command_available() {
    local resolved
    resolved=$(command -v "$1") || return 1
    [[ -n "$resolved" ]]
}

# What: the host package manager; empty when none is known
# Why: one detection order for every install path
# From: Issue #1683 | PR #1858
host_package_manager() {
    local manager
    for manager in apt-get dnf yum pacman apk; do
        if command_available "$manager"; then
            printf '%s\n' "$manager"
            return 0
        fi
    done
}

# What: apt-get install without recommends, no prompt
# Why: one flag set for every apt install in this script
# From: Issue #1683 | PR #1858
apt_install() {
    apt-get install -y --no-install-recommends "$@"
}

# What: installs packages via apt, dnf, yum, pacman or apk
# Why: host changes need confirmation; unknown PM fails
# From: Issue #1683 | PR #1858
install_packages() {
    local reason="$1" manager
    shift
    local packages=("$@")

    print_warn "$reason"
    printf "  Required packages: %s\n" "${packages[*]}"
    if ! confirm "Install these packages now? [y/N]" "N"; then
        die "Aborted. Please install these packages manually, then rerun setup.sh: ${packages[*]}"
    fi

    manager=$(host_package_manager)
    case "$manager" in
        apt-get) apt-get update -y && apt_install "${packages[@]}" ;;
        dnf|yum) "$manager" install -y "${packages[@]}" ;;
        pacman) pacman -Syu --noconfirm "${packages[@]}" ;;
        apk) apk_install "${packages[@]}" ;;
        *) die "No supported package manager found. Please install these packages manually, then rerun setup.sh: ${packages[*]}" ;;
    esac
}

# What: apk index refresh and install in one call
# Why: Docker sits in Alpine's community repository
# From: Issue #1683 | PR #1858
apk_install() {
    local out rc=0
    apk update || die "apk update failed (exit $?); nothing was installed."
    out=$(apk add "$@" 2>&1) || rc=$?
    printf '%s\n' "$out"
    [[ "$rc" -eq 0 ]] && return 0
    print_error "apk add $* failed (exit $rc). Docker needs the community repository enabled in /etc/apk/repositories."
    return 1
}

# What: package installs ask first; unknown managers fail
# Why: setup.sh mutates the host, so it must not guess
# From: Issue #1683 | PR #1858
install_required_command() {
    local command_name="$1" reason="$2"
    shift 2

    install_packages "$reason" "$@" \
        || die "Failed to install required package(s): $*"

    command_available "$command_name" \
        || die "$command_name is still missing after installing package(s): $*"
}

# What: named wrappers for curl and git
# Why: call sites read as install_curl and install_git
# From: Issue #1683 | PR #1858
install_curl() {
    install_required_command curl "curl is missing." curl
}
install_git() {
    install_required_command git "git is missing." git
}

# What: true if apt has a candidate version for the package
# Why: installed state is not checked here
# From: Issue #1683 | PR #1858
apt_package_available() {
    local version
    version=$(apt_package_candidate_version "$1") \
        || die "Cannot read the apt candidate of $1 (exit $?)."
    [[ -n "$version" && "$version" != "(none)" ]]
}

# What: reads the version apt would install now
# Why: callers branch on version before installing
# From: Issue #1683 | PR #1858
apt_package_candidate_version() {
    local policy
    policy=$(apt-cache policy "$1") || die "apt-cache policy $1 failed (exit $?)."
    awk '/^[[:space:]]*Candidate:/ {print $2; exit}' <<< "$policy"
}

# What: true if the apt docker-compose candidate is v2
# Why: legacy name can ship Compose v2 (Trixie)
# From: Issue #1683 | PR #1858
apt_docker_compose_is_v2() {
    local version=""

    version=$(apt_package_candidate_version "$APT_LEGACY_COMPOSE") \
        || die "Cannot read the apt candidate of $APT_LEGACY_COMPOSE (exit $?)."
    [[ "$version" =~ ^2[.:-] ]]
}

# What: the Compose v2 apt package; empty when none exists
# Why: rc != 0 is a lookup error, never "not found"
# From: Issue #1683 | PR #1858
apt_compose_package() {
    local package
    for package in "${APT_COMPOSE_PACKAGES[@]}"; do
        apt_package_available "$package" || continue
        # What: the legacy name counts only as Compose v2
        # Why: Trixie ships Compose v2 under that name
        # From: Issue #1683 | PR #1858
        if [[ "$package" = "$APT_LEGACY_COMPOSE" ]] && ! apt_docker_compose_is_v2; then
            continue
        fi
        printf '%s\n' "$package"
        return 0
    done
}

# What: the Buildx apt package; empty when none exists
# Why: Buildx is optional here; a lookup error still dies
# From: Issue #1683 | PR #1858
apt_buildx_package() {
    local package
    for package in "${APT_BUILDX_PACKAGES[@]}"; do
        if apt_package_available "$package"; then
            printf '%s\n' "$package"
            return 0
        fi
    done
}

# What: Docker install is a first-install convenience only
# Why: production setup must stay separate from dev builds
# From: Issue #1683 | PR #1858
verify_docker_installation() {
    local out
    command_available docker \
        || die "Docker client binary is missing after installation."

    out=$(docker compose version 2>&1) \
        || die "Docker Compose v2 is missing after installation (exit $?): $out"
}

# What: installs docker-cli only if docker is still missing
# Why: Trixie's docker.io no longer ships /usr/bin/docker
# From: Issue #1683 | PR #1858
ensure_apt_docker_client() {
    if command_available docker; then
        return 0
    fi

    if apt_package_available "$APT_DOCKER_CLI"; then
        print_warn "$APT_DOCKER_ENGINE did not provide /usr/bin/docker; installing $APT_DOCKER_CLI for the Docker client."
        apt_install "$APT_DOCKER_CLI" || die "Failed to install $APT_DOCKER_CLI (exit $?)."
    fi

    command_available docker \
        || die "Docker client binary is missing after installation. Install ${APT_DOCKER_CLI} or ${DOCKER_CE_CLI} manually, then rerun setup.sh."
}

# What: one /etc/os-release field, empty if absent
# Why: one reader; read as data, never run as shell
# From: Issue #1683 | PR #1858
os_release_field() {
    [[ -r /etc/os-release ]] || return 0
    awk -F= -v k="$1" '$1 == k {
        v = substr($0, length(k) + 2); gsub(/^["\047]|["\047]$/, "", v); print v; exit
    }' /etc/os-release || die "Failed to read $1 from /etc/os-release (exit $?)."
}

# What: adds Docker's apt repo when no Compose v2 package
# Why: the distro index may lack a supported package
# From: Issue #1683 | PR #1858
install_docker_apt_repo() {
    local os_id="" codename="" repo_file="" dpkg_arch="" key_dir="" key_file=""

    os_id=$(os_release_field ID) || exit $?
    codename=$(os_release_field VERSION_CODENAME) || exit $?

    case "$os_id" in
        debian|ubuntu) ;;
        *)
            die "Docker's apt repository is only configured automatically on Debian and Ubuntu. Please install Docker and Docker Compose manually, then rerun setup.sh."
            ;;
    esac

    if [[ -z "$codename" ]] && command_available lsb_release; then
        codename=$(lsb_release -cs) || die "lsb_release -cs failed (exit $?)."
    fi
    [[ -n "$codename" ]] \
        || die "Could not determine the apt distribution codename. Please install Docker and Docker Compose manually, then rerun setup.sh."

    repo_file="/etc/apt/sources.list.d/docker.list"
    key_dir="/etc/apt/keyrings"
    key_file="$key_dir/docker.gpg"
    # What: each repo setup step dies with its own cause
    # Why: set -e is off under the caller's || die
    # From: Issue #1683 | PR #1858
    apt-get update -y || die "apt-get update failed (exit $?); Docker's repository was not added."
    apt_install ca-certificates curl gnupg \
        || die "Failed to install ca-certificates, curl and gnupg (exit $?)."
    install -m 0755 -d "$key_dir" || die "Failed to create $key_dir (exit $?)."
    curl -fsSL "$DOCKER_REPO_URL/$os_id/gpg" \
        | gpg --dearmor -o "$key_file" \
        || die "Failed to install Docker's apt signing key (exit $?)."
    chmod a+r "$key_file" || die "Failed to make Docker's apt signing key readable (exit $?)."
    dpkg_arch=$(dpkg --print-architecture) || die "dpkg --print-architecture failed (exit $?)."
    printf 'deb [arch=%s signed-by=%s] %s/%s %s stable\n' \
        "$dpkg_arch" "$key_file" "$DOCKER_REPO_URL" "$os_id" "$codename" > "$repo_file" \
        || die "Failed to write $repo_file (exit $?)."
    apt-get update -y || die "apt-get update failed after adding Docker's repository (exit $?)."
}

# What: sets the Compose v2 apt package; adds Docker's repo
# Why: engine and Compose-only installs share one lookup
# From: Issue #1683 | PR #1858
resolve_apt_compose_package() {
    local -n _compose_package_ref="$1"
    local manual="$2"

    _compose_package_ref=$(apt_compose_package) || die "Cannot look up the Compose v2 apt package (exit $?)."
    [[ -z "$_compose_package_ref" ]] || return 0
    print_warn "No Compose v2 package was found in the configured apt repositories. Adding Docker's official apt repository."
    install_docker_apt_repo
    _compose_package_ref=$(apt_compose_package) || die "Cannot look up the Compose v2 apt package (exit $?)."
    [[ -n "$_compose_package_ref" ]] \
        || die "No Docker Compose v2 package found. Please install $manual manually, then rerun setup.sh."
}

# What: installs Docker and Compose v2 on Debian/Ubuntu
# Why: distro packages are preferred over Docker's own repo
# From: Issue #1683 | PR #1858
install_docker_apt() {
    local compose_package="" buildx_package=""
    local -a docker_packages=()

    apt-get update -y || die "apt-get update failed (exit $?); Docker was not installed."
    resolve_apt_compose_package compose_package "Docker and the Docker Compose plugin"

    # What: installs buildx when the apt index has it
    # Why: docker buildx is needed before the first pull
    # From: Issue #1683 | PR #1858
    buildx_package=$(apt_buildx_package) || die "Cannot look up the Buildx apt package (exit $?)."

    if [[ "$compose_package" = "$DOCKER_COMPOSE_PLUGIN" ]]; then
        docker_packages=("${DOCKER_CE_PACKAGES[@]}")
    else
        docker_packages=("$APT_DOCKER_ENGINE")
    fi
    docker_packages+=("$compose_package")
    [[ -n "$buildx_package" ]] && docker_packages+=("$buildx_package")
    apt_install "${docker_packages[@]}" || die "Failed to install ${docker_packages[*]} (exit $?)."
    # What: falls back to docker-cli for the distro engine
    # Why: Trixie ships the client in docker-cli
    # From: Issue #1683 | PR #1858
    if [[ "${docker_packages[0]}" = "$APT_DOCKER_ENGINE" ]]; then
        ensure_apt_docker_client
    fi

    verify_docker_installation
}

# What: Compose-only install via apt, same fallbacks
# Why: Docker present; only the Compose plugin missing
# From: Issue #1683 | PR #1858
install_docker_compose_apt() {
    local compose_package=""

    apt-get update -y || die "apt-get update failed (exit $?); Docker Compose was not installed."
    resolve_apt_compose_package compose_package "the Docker Compose plugin"
    apt_install "$compose_package" || die "Failed to install $compose_package (exit $?)."
    verify_docker_installation
}

# What: keeps only the named packages that rpm lists
# Why: generic building block for conflict checks
# From: Issue #1683 | PR #1858
rpm_installed_package_list() {
    local installed package

    installed=$(rpm -qa --qf '%{NAME}\n') \
        || die "Failed to read the rpm package database (exit $?)."
    for package in "$@"; do
        if list_has_line "$package" "$installed"; then
            printf '%s\n' "$package"
        fi
    done
}

# What: lists legacy Docker packages that conflict
# Why: the operator sees removals, not an rpm error
# From: Issue #1683 | PR #1858
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

# What: lists installed packages that block Docker CE
# Why: the host's os-release ID picks the conflict rules
# From: Issue #1683 | PR #1858
rpm_conflicting_docker_packages() {
    local os_id
    os_id=$(os_release_field ID) || exit $?
    rpm_conflicting_docker_packages_for "$os_id"
}

# What: blocking packages for one os-release ID
# Why: podman and runc rules differ on Fedora and RHEL
# From: PR #429
rpm_conflicting_docker_packages_for() {
    local os_id="$1"
    if [[ "$os_id" = fedora ]]; then
        # What: Fedora: only Docker-family packages must go
        # Why: stock podman and runc stay allowed
        # From: Issue #1683 | PR #1858
        rpm_installed_package_list podman-docker
        rpm_legacy_docker_package_list
    else
        # What: RHEL-family also rejects podman and runc
        # Why: repo config must not change before the check
        # From: Issue #1683 | PR #1858
        rpm_legacy_docker_package_list
        rpm_installed_package_list \
            podman \
            runc
    fi
}

# What: fails closed with a dnf remove command
# Why: rpm conflicts mid-install would half-configure
# From: Issue #1683 | PR #1858
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

# What: Docker's rpm repo URL for one os-release ID
# Why: Fedora, RHEL own repos; other RHEL use CentOS
# From: PR #259
docker_rpm_repo_url() {
    local dir
    case "$1" in
        fedora|rhel) dir="$1" ;;
        *) dir=centos ;;
    esac
    printf '%s/%s/docker-ce.repo\n' "$DOCKER_REPO_URL" "$dir"
}

# What: installs Docker via Docker's own rpm repo
# Why: engine conflict guard runs only for engine packages
# From: Issue #1683 | PR #1858
install_docker_rpm() {
    local manager="$1"
    shift
    local repo_url os_id needs_engine=0 package docker_package
    local packages=("$@")

    if (( ${#packages[@]} == 0 )); then
        # What: default set adds buildx and compose plugins
        # Why: full install satisfies the buildx check
        # From: Issue #1683 | PR #1858
        packages=("${DOCKER_RPM_PACKAGES[@]}")
    fi

    for package in "${packages[@]}"; do
        for docker_package in "${DOCKER_RPM_PACKAGES[@]}"; do
            if [[ "$package" = "$docker_package" ]]; then
                needs_engine=1
            fi
        done
    done
    if (( needs_engine )); then
        guard_rpm_docker_conflicts
    fi

    os_id=$(os_release_field ID) || exit $?
    repo_url=$(docker_rpm_repo_url "$os_id")
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

# What: rpm install dialog; aborts without a yes
# Why: engine and Compose-only installs share one dialog
# From: Issue #1683 | PR #1858
confirm_docker_rpm_packages() {
    local warn="$1" question="$2" product="$3"
    shift 3

    print_warn "$warn"
    printf "  Required packages: %s\n" "$*"
    printf "  Docker's RPM repository will be configured before installation.\n"
    if ! confirm "$question" "N"; then
        die "Aborted. Please install $product from Docker's RPM repository manually, then rerun setup.sh: $*"
    fi
}

# What: installs only the Compose v2 plugin
# Why: each manager asks for confirmation before changes
# From: Issue #1683 | PR #1858
install_docker_compose() {
    local manager

    manager=$(host_package_manager)
    case "$manager" in
        apt-get)
            print_warn "Docker Compose plugin missing."
            printf "  Required package: an available Compose v2 package (%s, %s, or %s)\n" "${APT_COMPOSE_PACKAGES[@]}"
            if ! confirm "Install this package now? [y/N]" "N"; then
                die "Aborted. Please install a Docker Compose v2 package manually, then rerun setup.sh."
            fi
            install_docker_compose_apt || die "Failed to install Docker Compose."
            ;;
        dnf|yum)
            confirm_docker_rpm_packages "Docker Compose plugin missing." "Install this package now? [y/N]" \
                "Docker Compose" "$DOCKER_COMPOSE_PLUGIN"
            install_docker_rpm "$manager" "$DOCKER_COMPOSE_PLUGIN" || die "Failed to install Docker Compose."
            ;;
        pacman)
            install_packages "Docker Compose plugin missing." "$PACMAN_COMPOSE" \
                || die "Failed to install Docker Compose."
            ;;
        apk)
            install_packages "Docker Compose plugin missing." "$APK_COMPOSE" \
                || die "Failed to install Docker Compose."
            ;;
        *)
            die "No supported package manager found. Please install the Docker Compose plugin manually, then rerun setup.sh."
            ;;
    esac
}

# What: installs Docker engine and Compose v2 per manager
# Why: each manager has its own confirmation and package set
# From: Issue #1683 | PR #1858
install_docker() {
    local manager

    manager=$(host_package_manager)
    case "$manager" in
        apt-get)
            print_warn "Docker is missing."
            printf "  Required packages: %s, an available Compose v2 package (%s, %s, or %s), and Buildx (%s or %s) when this apt index has one\n" \
                "$APT_DOCKER_ENGINE" "${APT_COMPOSE_PACKAGES[@]}" "${APT_BUILDX_PACKAGES[@]}"
            if ! confirm "Install these packages now? [y/N]" "N"; then
                die "Aborted. Please install Docker and a Docker Compose v2 package manually, then rerun setup.sh."
            fi
            install_docker_apt || die "Failed to install Docker."
            ;;
        dnf|yum)
            confirm_docker_rpm_packages "Docker is missing." "Install these packages now? [y/N]" \
                "Docker" "${DOCKER_RPM_PACKAGES[@]}"
            install_docker_rpm "$manager" || die "Failed to install Docker."
            ;;
        pacman)
            install_packages "Docker is missing." "${PACMAN_DOCKER_PACKAGES[@]}" \
                || die "Failed to install Docker."
            ;;
        apk)
            install_packages "Docker is missing." "${APK_DOCKER_PACKAGES[@]}" \
                || die "Failed to install Docker."
            ;;
        *)
            die "No supported package manager found. Please install Docker and the Docker Compose plugin manually, then rerun setup.sh."
            ;;
    esac
}

# What: installs curl, Docker, Docker Compose v2 plugin
# Why: secondary needs the same set as primary
# From: Issue #1683 | PR #1858
ensure_stack_requirements_installed() {
    local info out
    [[ "$(id -u)" = "0" ]] \
        || die "This command must be run as root (sudo ./setup.sh install-requirements-primary or install-requirements-secondary)."
    # What: refuses an unsupported arch before any install
    # Why: no host change on a host the stack cannot run on
    # From: Issue #1683 | PR #1858
    assert_prebuilt_image_platform_supported

    if ! command_available curl; then
        install_curl
    fi

    # What: GNU coreutils, grep, tar and iproute2 on Alpine
    # Why: BusyBox lacks realpath -m, grep -P and ss
    # From: Issue #1683 | PR #1858
    local manager installed package
    local -a gnu_missing=()
    manager=$(host_package_manager)
    if [[ "$manager" = apk ]]; then
        installed=$(apk info) || die "apk info failed (exit $?)."
        for package in "${APK_GNU_PACKAGES[@]}"; do
            list_has_line "$package" "$installed" || gnu_missing+=("$package")
        done
        if (( ${#gnu_missing[@]} > 0 )); then
            install_packages "Alpine's BusyBox tools lack options setup.sh uses." "${gnu_missing[@]}" \
                || die "Failed to install ${gnu_missing[*]}."
        fi
    fi

    # What: jq reads every JSON answer this script gets
    # Why: primary, Kea and DNS replies need a real parser
    # From: Issue #1683 | PR #1858
    if ! command_available jq; then
        install_required_command jq "jq is missing." jq
    fi

    if ! command_available docker; then
        install_docker
        print_ok "Docker installed"
    fi

    if ! info=$(docker info 2>&1); then
        print_warn "Docker daemon not reachable (${info##*$'\n'}) — starting now..."
        host_unit_action "$DOCKER_UNIT" enable
        host_unit_action "$DOCKER_UNIT" start
        info=$(docker info 2>&1) \
            || die "Docker daemon is still not reachable after starting it (exit $?): $info"
    fi

    if ! out=$(docker compose version 2>&1); then
        print_warn "Docker Compose plugin not usable (${out##*$'\n'}) — installing..."
        install_docker_compose
    fi

    out=$(docker compose version 2>&1) \
        || die "Docker Compose plugin still missing after installing Docker requirements (exit $?): $out"
}

# What: installs curl, jq, Docker, Compose; prints next step
# Why: a host gets its requirements before any install
# From: Issue #1068
cmd_install_requirements_primary() {
    ensure_stack_requirements_installed
    print_ok "Primary node requirements installed (curl, jq, Docker, Docker Compose v2). Run ./setup.sh install next."
}
cmd_install_requirements_secondary() {
    ensure_stack_requirements_installed
    print_ok "Secondary node requirements installed (curl, jq, Docker, Docker Compose v2). Next: ./setup.sh secondary --help shows the registration command."
}

# What: strips quotes and unquoted inline comments
# Why: Compose-valid values must pass validate_env_value
# From: Issue #1683 | PR #1858
_compose_parse_env_value() {
    local value="$1" rest

    # What: trims leading whitespace before the quote check
    # Why: otherwise a leading space hides the quote
    # From: Issue #1683 | PR #1858
    value="${value#"${value%%[![:space:]]*}"}"

    if [[ "$value" == \"* ]]; then
        # What: takes text up to the first closing quote
        # Why: trailing comments after quotes are valid
        # From: Issue #1683 | PR #1858
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
# From: Issue #1683 | PR #1858

# What: true if KEY= is assigned; a missing file has none
# Why: a read error must stop setup, never read as absent
# From: Issue #1683 | PR #1858
env_key_exists() {
    local key="$1" env_file="$2" rc=0 hits
    [[ -e "$env_file" ]] || return 1
    hits=$(grep "^${key}=" "$env_file") || rc=$?
    [[ "$rc" -le 1 ]] || die "Failed to read $env_file while looking up $key (exit $rc)."
    [[ -n "$hits" ]]
}

# What: true if the key has a non-empty parsed value
# Why: empty values count as unset for setup decisions
# From: Issue #1683 | PR #1858
env_key_has_value() {
    local key="$1" env_file="$2" value
    value=$(get_env_var "$key" "$env_file") || exit $?
    [[ -n "$value" ]]
}

# What: true for empty, CHANGE_ME_*, <...> and alike
# Why: shared.rs rule; plain sh, the dns exec embeds it
# From: Issue #1683 | PR #1858
secret_value_is_placeholder() {
    local value="$1" normalized
    normalized=$(printf '%s' "$value" | tr '[:upper:]-' '[:lower:]_')
    case "$normalized" in
        ""|*change_me*|changeme*|your_*|*_here)
            return 0
            ;;
        lancache_*)
            case "$normalized" in
                *_secret) return 0 ;;
            esac
            ;;
    esac
    case "$value" in
        "<"*">") return 0 ;;
    esac
    return 1
}

# What: true if the key has a non-placeholder value
# Why: setup overwrites placeholders, never real secrets
# From: Issue #1683 | PR #1858
env_key_has_usable_secret() {
    local key="$1" env_file="$2" value
    value=$(get_env_var "$key" "$env_file") || exit $?
    ! secret_value_is_placeholder "$value"
}

# What: output of one SOT generator command, one line
# Why: runtime.secret_generators; ci.sh runs the same row
# From: Issue #1683 | PR #1858
secret_generator_output() {
    local name="$1" kind="$2" rows row value
    local -a cmd
    rows=$(lancache_sot_list secret_generators runtime) || exit $?
    row=$(awk -v k="$kind" '$1 == k { print; exit }' <<< "$rows") \
        || die "Failed to read the generator of $kind (exit $?)."
    [[ -n "$row" ]] || die "Unknown secret generator for $name: $kind"
    read -ra cmd <<< "${row#"$kind "}"
    value=$("${cmd[@]}") || die "Failed to generate $name with ${cmd[0]} (exit $?)."
    printf '%s\n' "${value//$'\n'/}"
}

# What: generate_secret_value fails on any generator error
# Why: an empty secret must never be written
# From: Issue #1683 | PR #1858
generate_secret_value() {
    local name="$1" kind="$2" value chunk managed
    # What: only a key on managed_secret_env_keys is made
    # Why: an unlisted key would ship unredacted in bundles
    # From: Issue #1683 | PR #1858
    managed=$(managed_secret_env_keys)
    list_has_line "$name" "$managed" \
        || die "Secret $name is not in managed_secret_env_keys; add it there so log bundles redact it."

    case "$kind" in
        alnum20)
            # What: alnum20: letters, digits of base64_32
            # Why: a UI password a person can type
            # From: Issue #1683 | PR #1858
            value=""
            while (( ${#value} < 20 )); do
                chunk=$(secret_generator_output "$name" base64_32) || exit $?
                chunk="${chunk//[^A-Za-z0-9]/}"
                value+="$chunk"
            done
            value="${value:0:20}"
            ;;
        *)
            value=$(secret_generator_output "$name" "$kind") || exit $?
            ;;
    esac

    [[ -n "$value" ]] || die "Generated empty secret for $name."
    printf '%s\n' "$value"
}

# What: keeps a usable secret, else generates one
# Why: empty values and placeholders are replaced
# From: Issue #1683 | PR #1858
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
# From: Issue #1683 | PR #1858
validate_env_value() {
    local key="$1" value="$2"

    # What: empty values are accepted
    # Why: optional settings are written as empty strings
    # From: Issue #1683 | PR #1858
    [[ -z "$value" ]] && return 0

    # What: rejects newline and shell or .env metachars
    # Why: Compose .env parsing would change the value
    # From: Issue #1683 | PR #1858
    case "$value" in
        *$'\n'* | *'$'* | *'`'* | *'"'* | *"'"* | *\\* | *'#'* )
            die "$key contains unsafe characters for .env. Cannot proceed. Value: $value"
            ;;
    esac

    return 0
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
# From: Issue #1683 | PR #1858
set_env_key() {
    local key="$1" value="$2" env_file="$3"
    validate_env_value "$key" "$value"
    if env_key_exists "$key" "$env_file"; then
        rewrite_env_key "$env_file" "$key" "$value" set
    else
        # What: explicit die on append failure
        # Why: errexit is ignored in tested subshells
        # From: Issue #1683 | PR #1858
        printf '%s=%s\n' "$key" "$value" >> "$env_file" \
            || die "Failed to append $key to $env_file."
    fi
}

# What: dies on a bad .env key or a newline in a raw value
# Why: one owner of the raw-assignment check
# From: Issue #1683 | PR #1858
validate_env_assignment() {
    local key="$1" assignment_value="$2"
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
}

# What: sets raw value without character validation
# Why: raw values may contain ${VAR} interpolation
# From: Issue #1683 | PR #1858
set_env_assignment() {
    local key="$1" assignment_value="$2" env_file="$3"
    validate_env_assignment "$key" "$assignment_value"

    if env_key_exists "$key" "$env_file"; then
        rewrite_env_key "$env_file" "$key" "$assignment_value" set
    else
        # What: same explicit die as set_env_key
        # Why: errexit is ignored in tested subshells
        # From: Issue #1683 | PR #1858
        printf '%s=%s\n' "$key" "$assignment_value" >> "$env_file" \
            || die "Failed to append $key to $env_file."
    fi
}

# What: adds KEY=VALUE only if the key is absent
# Why: an existing assignment, even empty, is kept
# From: Issue #1683 | PR #1858
append_env_key_if_missing() {
    local key="$1" value="$2" env_file="$3"
    validate_env_value "$key" "$value"
    # What: adds the key only when absent
    # Why: empty placeholders must survive updates
    # From: Issue #1683 | PR #1858
    env_key_exists "$key" "$env_file" \
        || printf '%s=%s\n' "$key" "$value" >> "$env_file" \
        || die "Failed to append $key to $env_file."
}

# What: fills a default only when missing or empty
# Why: a non-empty raw assignment is kept as-is
# From: Issue #1683 | PR #1858
set_env_key_if_empty_or_missing() {
    local key="$1" value="$2" env_file="$3" existing_assignment
    validate_env_value "$key" "$value"
    if env_key_exists "$key" "$env_file"; then
        # What: keeps an existing non-empty assignment
        # Why: Compose interpolation must survive updates
        # From: Issue #1683 | PR #1858
        existing_assignment=$(get_env_assignment_value_raw_nonempty "$key" "$env_file") || exit $?
        if [[ -n "$existing_assignment" ]]; then
            set_env_assignment "$key" "$existing_assignment" "$env_file"
        else
            set_env_key "$key" "$value" "$env_file"
        fi
    else
        # What: same explicit die as set_env_key
        # Why: errexit is ignored in tested subshells
        # From: Issue #1683 | PR #1858
        printf '%s=%s\n' "$key" "$value" >> "$env_file" \
            || die "Failed to append $key to $env_file."
    fi
}

# What: appends a raw assignment if the key is missing
# Why: raw values keep their interpolation
# From: Issue #1683 | PR #1858
append_env_assignment_if_missing() {
    local key="$1" assignment_value="$2" env_file="$3"
    validate_env_assignment "$key" "$assignment_value"
    # What: appends an assignment verbatim if key is missing
    # Why: keeps ${VAR:-...} interpolation intact
    # From: Issue #1683 | PR #1858
    env_key_exists "$key" "$env_file" \
        || printf '%s=%s\n' "$key" "$assignment_value" >> "$env_file" \
        || die "Failed to append $key to $env_file."
}

# What: migrates an old key to a new one, or seeds fallback
# Why: an empty target is a valid, intentional state
# From: Issue #1683 | PR #1858
append_env_migrated_assignment_if_missing() {
    local target_key="$1" source_key="$2" fallback_value="$3" env_file="$4"

    # What: keeps an existing empty optional target as is
    # Why: an empty value keeps Compose's fallback alive
    # From: Issue #1683 | PR #1858
    if env_key_exists "$target_key" "$env_file"; then
        return 0
    fi

    env_assign_from_source_or_fallback "$target_key" "$source_key" "$fallback_value" "$env_file"
}

# What: copies the source assignment, else the fallback
# Why: one owner of the tail of both migrations
# From: Issue #1683 | PR #1858
env_assign_from_source_or_fallback() {
    local target_key="$1" source_key="$2" fallback_value="$3" env_file="$4"
    local source_assignment

    source_assignment=$(get_env_assignment_value_raw_nonempty "$source_key" "$env_file") || exit $?
    if [[ -n "$source_assignment" ]]; then
        # What: rewrites an empty migrated target in place
        # Why: avoids duplicate KEY= lines on update
        # From: Issue #1683 | PR #1858
        set_env_assignment "$target_key" "$source_assignment" "$env_file"
    elif env_key_exists "$target_key" "$env_file" || [[ -n "$fallback_value" ]]; then
        set_env_key "$target_key" "$fallback_value" "$env_file"
    fi
}

# What: migrates a required key; repairs an empty target
# Why: Compose would turn KEY= into an invalid bind mount
# From: Issue #1683 | PR #1858
append_required_env_migrated_assignment_if_empty_or_missing() {
    local target_key="$1" source_key="$2" fallback_value="$3" env_file="$4"
    local target_assignment

    # What: keeps a non-empty duplicate target value
    # Why: updates must converge on the operator's real dir
    # From: Issue #1683 | PR #1858
    target_assignment=$(get_env_assignment_value_raw_nonempty "$target_key" "$env_file") || exit $?
    if [[ -n "$target_assignment" ]]; then
        set_env_assignment "$target_key" "$target_assignment" "$env_file"
        return 0
    fi

    env_assign_from_source_or_fallback "$target_key" "$source_key" "$fallback_value" "$env_file"
}

# What: sets strict proxy mode to default if no allowlist
# Why: no allowlist means no strict policy to preserve
# From: Issue #563 | PR #572
migrate_proxy_security_mode_for_update() {
    local env_file="$1" proxy_security_mode proxy_allowed_client_cidrs default_mode

    proxy_security_mode=$(get_env_var PROXY_SECURITY_MODE "$env_file") || exit $?
    default_mode=$(prod_env_default PROXY_SECURITY_MODE) || exit $?
    proxy_allowed_client_cidrs=$(get_env_var PROXY_ALLOWED_CLIENT_CIDRS "$env_file") || exit $?

    if [[ "$proxy_security_mode" = "strict" && -z "$proxy_allowed_client_cidrs" ]]; then
        set_env_key PROXY_SECURITY_MODE "$default_mode" "$env_file"
        print_ok "Migrated legacy PROXY_SECURITY_MODE=strict without PROXY_ALLOWED_CLIENT_CIDRS to $default_mode"
    fi
}

readonly LEGACY_STATE_ROOT="/srv/lancache"
readonly -a LEGACY_STATE_CHILDREN=(cache pdns pdns-ssl pdns-filter-state kea nats nats-conf)

# What: fixed pre-v0.1 state paths, used for migration
# Why: backup, update and restore must find legacy data
# From: Issue #1683 | PR #1858
legacy_state_path() {
    local child="${1:-}"

    # What: old installs keep PowerDNS data in pdns-standard
    # Why: existing installs keep their data in that dir.
    # From: Issue #1683 | PR #1912
    [[ "$child" != pdns ]] || child=pdns-standard
    if [[ -n "$child" ]]; then
        printf '%s/%s\n' "$LEGACY_STATE_ROOT" "$child"
    else
        printf '%s\n' "$LEGACY_STATE_ROOT"
    fi
}

# What: true if a known pre-v0.1 state subdirectory exists
# Why: an unrelated /srv/lancache dir is not legacy state
# From: Issue #1683 | PR #1858
legacy_state_root_has_known_children() {
    local child

    for child in "${LEGACY_STATE_CHILDREN[@]}"; do
        [[ -d "$(legacy_state_path "$child")" ]] && return 0
    done
    return 1
}

# What: legacy root if it has children, else the default
# Why: new-style default applies without legacy state
# From: Issue #1683 | PR #1858
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
# From: Issue #1683 | PR #1858
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
# From: Issue #1683 | PR #1858
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

    # What: leaves optional keys absent at the derived root
    # Why: a later LANCACHE_STATE_DIR change still applies
    # From: Issue #1683 | PR #1858
    [[ "$desired_path" = "$derived_path" ]] && return 0
    set_env_key "$key" "$desired_path" "$env_file"
}

# What: deletes every assignment of the key
# Why: a missing key is a no-op
# From: Issue #1683 | PR #1858
remove_env_key() {
    local key="$1" env_file="$2"

    env_key_exists "$key" "$env_file" || return 0
    rewrite_env_key "$env_file" "$key" "" remove
}

# What: default LANCACHE_STATE_DIR for an install dir
# Why: deploy/prod takes the SOT runtime default
# From: Issue #1683 | PR #1858
production_state_root_default() {
    local install_dir="$1" root

    # What: prod runs keep state outside the checkout
    # Why: state must not live in the Git checkout
    # From: Issue #1683 | PR #1858
    if is_deploy_prod_install_dir "$install_dir"; then
        # What: the root the SOT names for prod state
        # Why: the SOT owns it; compose and setup read it
        # From: Issue #1683 | PR #1912
        root=$(prod_env_default LANCACHE_STATE_DIR) || exit $?
        [[ "$root" =~ ^/[^[:space:]]*$ ]] \
            || die "The SOT runtime default LANCACHE_STATE_DIR is no absolute path: ${root}"
        printf '%s\n' "$root"
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

# What: the env file, the base .env and the state root
# Why: backup and the log bundle resolve the same three
# From: Issue #1683 | PR #1858
stack_env_context() {
    local install_dir="$1"
    local -n _env_ref="$2" _base_env_ref="$3" _state_ref="$4"
    _env_ref=$(runtime_env_file_for_install_dir "$install_dir")
    _base_env_ref="$install_dir/.env"
    _state_ref=$(install_state_root "$install_dir" "$_env_ref") \
        || die "Cannot resolve the state root of $install_dir (exit $?)."
}

# What: the resolved stack dir; dies without a compose file
# Why: backup and the log bundle share the stack lookup
# From: Issue #1683 | PR #1858
resolve_stack_dir_checked() {
    local dir
    dir=$(resolve_stack_dir "$(realpath -m "$1")") || exit $?
    [[ -f "$dir/docker-compose.yml" ]] || die_no_stack_found "$dir"
    printf '%s\n' "$dir"
}

# What: true for the manual checkout path deploy/prod
# Why: quickstart installs live elsewhere
# From: Issue #1683 | PR #1858
is_deploy_prod_install_dir() {
    local dir="${1%/}" rel="${PROD_COMPOSE#"$SCRIPT_DIR/"}"
    rel="${rel%/*}"
    [[ "$dir" = "$rel" || "$dir" = */"$rel" ]]
}

# What: picks .env.local for prod checkouts when it exists
# Why: git pull keeps operator production values
# From: Issue #1683 | PR #1858
runtime_env_file_for_install_dir() {
    local install_dir="$1"

    if is_deploy_prod_install_dir "$install_dir" && [[ -f "$install_dir/.env.local" ]]; then
        printf '%s\n' "$install_dir/.env.local"
    else
        printf '%s\n' "$install_dir/.env"
    fi
}

# What: builds -f args for base and operator override
# Why: any -f disables auto-discovery; base is listed
# From: Issue #1683 | PR #1858
compose_file_args_for_install_dir() {
    local install_dir="$1" override_file
    local -a args=(-f "$install_dir/docker-compose.yml")

    for override_file in "$install_dir/docker-compose.override.yml" "$install_dir/docker-compose.override.yaml"; do
        if [[ -f "$override_file" ]]; then
            args+=(-f "$override_file")
            break
        fi
    done

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
    list_has_line "$1" "$names"
}

# What: fills an array with the compose -f arguments
# Why: a failed list must stop, never shrink the stack
# From: Issue #1683 | PR #1858
compose_files_into() {
    local -n _compose_files_ref="$1"
    local files
    files=$(compose_file_args_for_install_dir "$2") \
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
    compose_files_into stack_files "$install_dir"
    sot_compose "$env_file" "${stack_files[@]}" "$@"
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
    if [[ "$rc" -eq 1 ]]; then
        print_skip "Copying Docker volume $volume: the volume does not exist"
        return 0
    fi
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

# What: default state subdir of a prod key, from the SOT
# Why: state_dir_keys names the SOT subdir entry; one owner
# From: Issue #1683 | PR #1912
prod_state_subdir() {
    local key="$1" rows row_key name sub
    rows=$(lancache_sot_list state_dir_keys runtime) || exit $?
    while read -r row_key name; do
        [[ "$row_key" == "$key" ]] || continue
        sub=$(prod_env_default "$name") || exit $?
        [[ "$sub" =~ ^[a-z0-9-]+$ ]] \
            || die "The SOT default of $name is no directory name: $sub"
        printf '%s\n' "$sub"
        return 0
    done <<< "$rows"
    die "The SOT runtime.state_dir_keys names no directory for $key."
}

# What: every state key the prod stack mounts, from the SOT
# Why: backup and update read the one list in the SOT
# From: Issue #1683 | PR #1912
prod_state_keys() {
    local rows row_key name
    rows=$(lancache_sot_list state_dir_keys runtime) || exit $?
    while read -r row_key name; do
        printf '%s\n' "$row_key"
    done <<< "$rows"
}

# What: "volume dir" per row of quickstart_volume_keys
# Why: copy and postcondition read the same mapping
# From: Issue #1683 | PR #1858
quickstart_volume_dirs() {
    local env_file="$1" rows volume key dir
    rows=$(lancache_sot_list quickstart_volume_keys runtime) || exit $?
    while read -r volume key; do
        dir=$(prod_state_dir_for_key "$key" "$env_file") || die "Cannot resolve the directory of $key (exit $?)."
        printf '%s %s\n' "$volume" "$dir"
    done <<< "$rows"
}

# What: a state key's dir: its value, else root/subdir
# Why: the one owner of the default; no env file = root only
# From: Issue #1683 | PR #1858
prod_state_dir_for_key() {
    local key="$1" env_file="$2" state="${3:-}" dir="" sub
    [[ -z "$env_file" ]] || dir=$(get_env_var "$key" "$env_file") \
        || die "Cannot read $key from $env_file (exit $?)."
    if [[ -z "$dir" ]]; then
        [[ -n "$state" || -z "$env_file" ]] || state=$(get_env_var LANCACHE_STATE_DIR "$env_file") \
            || die "Cannot read LANCACHE_STATE_DIR from $env_file (exit $?)."
        [[ -n "$state" ]] || die "No LANCACHE_STATE_DIR for $key (env file: ${env_file:-none})."
        sub=$(prod_state_subdir "$key") || die "Cannot read the default directory of $key (exit $?)."
        dir="$state/$sub"
    fi
    printf '%s\n' "$dir"
}

# What: copies a legacy ca.* set into the CA state dir
# Why: a new CA would break every client's TLS trust
# From: Issue #1683 | PR #1912
migrate_legacy_ca() {
    local src env_file="$2" remove="${3:-0}" dest f to ca_file
    src=$(realpath -m "$1")
    [[ -f "$src/ca.crt" ]] || return 0
    dest=$(prod_state_dir_for_key CA_DIR "$env_file") || exit $?
    ca_file=$(prod_env_default CA_CERT_FILE) || exit $?
    mkdir -p "$dest" || die "Failed to create the CA state dir $dest (exit $?)."
    for f in "$src/ca."*; do
        # What: a legacy CA file's name in the SOT layout
        # Why: legacy names are fixed; the SOT owns the new
        # From: Issue #1683 | PR #1858
        case "${f##*/}" in
            ca.crt) to=$ca_file ;;
            ca.key) to=$(prod_env_default CA_KEY_FILE) || exit $? ;;
            ca.srl) to=$(prod_env_default CA_SERIAL_FILE) || exit $? ;;
            *) to=${f##*/} ;;
        esac
        if [[ ! -f "$dest/$ca_file" ]] || [[ ! -e "$dest/$to" ]]; then
            cp -p -- "$f" "$dest/$to" \
                || die "Failed to copy $f to $dest/$to (exit $?)."
        fi
        cmp -- "$f" "$dest/$to" \
            || die "Postcondition failed: $dest/$to is not the CA file $f; nothing counts as migrated."
    done
    # What: the source goes only after a good update
    # Why: a rollback to the old checkout still mounts it
    # From: Issue #1683 | PR #1858
    [[ "$remove" = 1 ]] || return 0
    rm -f -- "$src/ca."* || die "Failed to remove the legacy CA in $src (exit $?)."
    rmdir --ignore-fail-on-non-empty -- "$src" \
        || die "Failed to remove the legacy CA in $src (exit $?)."
    print_ok "CA moved from $src to $dest"
}

# What: a checkout root resolves to deploy/prod
# Why: commands default to the checkout root
# From: Issue #1683 | PR #1858
resolve_stack_dir() {
    local dir="$1"
    local rel="${PROD_COMPOSE#"$SCRIPT_DIR/"}"
    # What: <root>/current wins over an old root checkout
    # Why: after a move, the old code must not run again
    # From: Issue #1683 | PR #1858
    if [[ ! -f "$dir/docker-compose.yml" && -f "$dir/current/$rel" ]]; then
        printf '%s\n' "$dir/current/${rel%/*}"
    elif [[ ! -f "$dir/docker-compose.yml" && -f "$dir/$rel" ]]; then
        printf '%s\n' "$dir/${rel%/*}"
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
    local https_ip fresh kept kept_list
    local -a service_list copy_lines path_key_list=()
    path_keys=$(lancache_sot_list quickstart_path_keys runtime) || exit $?
    path_keys="${path_keys//$'\n'/ }"
    read -ra path_key_list <<< "$path_keys"
    bundle=$(lancache_sot_list quickstart_bundle_copies runtime) || exit $?
    env_local="$stack_dir/.env.local"
    old_env="$old_dir/.env"
    record="$old_dir/.quickstart-migration"
    [[ -f "$old_env" ]] || die "Cannot migrate $old_dir: $old_env is missing."
    # What: a one-IP quickstart stops before any change
    # Why: prod always binds a second LAN IP (IP_HTTPS)
    # From: Issue #1683 | PR #1858
    https_ip=$(get_env_var IP_HTTPS "$old_env") || die "Cannot read IP_HTTPS from $old_env (exit $?)."
    [[ -n "$https_ip" ]] || https_ip=$(get_env_var IP_SSL "$old_env") \
        || die "Cannot read IP_SSL from $old_env (exit $?)."
    [[ -n "$https_ip" ]] \
        || die "The install at $old_dir has no second LAN IP (IP_HTTPS or IP_SSL in $old_env). LanCache-NG now needs one for HTTPS DNS and proxy: add a free LAN IP to this host, set IP_HTTPS=<that IP> in $old_env, then rerun setup.sh update. Nothing was changed."
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
    # What: a retry without live copies starts afresh
    # Why: a failed run's .env.local blocked every retry
    # From: Issue #1683 | PR #1858
    fresh=1
    if [[ -f "$env_local" ]]; then
        fresh=0
        if [[ -f "$record" ]]; then
            fresh=$(awk -F'|' '$1 == "envlocal" { m = 1 } $1 == "rolledback" { c = 0 }
                $1 == "copied" { c = 1 } END { print (m && !c) ? 1 : 0 }' "$record") \
                || die "Failed to read $record (exit $?)."
        fi
    fi
    if [[ "$fresh" = 1 ]]; then
        install -m 0600 "$old_env" "$env_local" || die "Failed to create $env_local from $old_env."
        printf 'envlocal|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$record" \
            || die "Failed to record the new $env_local in $record (exit $?)."
    fi
    if ! env_key_exists LANCACHE_STATE_DIR "$env_local"; then
        set_env_key LANCACHE_STATE_DIR "$old_dir" "$env_local"
    fi
    # What: relative paths become absolute to old dir
    # Why: prod resolves them against deploy/prod instead
    # From: Issue #1683 | PR #1858
    for key in "${path_key_list[@]}"; do
        value=$(get_env_var "$key" "$env_local") || die "Cannot read $key from $env_local (exit $?)."
        [[ -n "$value" && "$value" != /* ]] || continue
        set_env_key "$key" "$(realpath -m "$old_dir/$value")" "$env_local"
    done
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
    # What: .env.local gets its image pins and keys now
    # Why: the prod compose has no default; render pre-stop
    # From: Issue #1683 | PR #1912
    migrate_env_for_update "$stack_dir" \
        || die "Cannot prepare $env_local for the prod stack (exit $?); the quickstart stack in $old_dir was not stopped."
    # What: v0.3.2 plaintext UI password becomes a hash
    # Why: the ui needs user and hash; no plaintext stays
    # From: Issue #1683 | PR #1858
    ensure_ui_password_hash "$stack_dir" "$env_local"
    # What: every quickstart volume has a home in prod
    # Why: data without a target would be left behind
    # From: Issue #1683 | PR #1858
    old_volumes=$(stack_compose "$old_dir" "$old_env" config --volumes) \
        || die "Cannot list the volumes of $old_dir (exit $?); the quickstart stack was not touched."
    prod_volumes=$(stack_compose "$stack_dir" "$env_local" config --volumes) \
        || die "Cannot list the volumes of $PROD_COMPOSE (exit $?); the quickstart stack was not touched."
    rows=$(lancache_sot_list quickstart_volume_keys runtime) || exit $?
    kept_list=$(lancache_sot_list quickstart_volumes_kept runtime) || exit $?
    missing="" kept=""
    while IFS= read -r volume; do
        [[ -n "$volume" ]] || continue
        list_has_line "$volume" "$prod_volumes" && continue
        awk -v v="$volume" '$1 == v { f = 1 } END { exit !f }' <<< "$rows" && continue
        # What: SOT-listed log volumes stay, untouched
        # Why: nothing is deleted; the operator decides
        # From: Issue #1683 | PR #1858
        if list_has_line "$volume" "$kept_list"; then
            kept+=" ${project}_${volume}"
            continue
        fi
        missing+=" $volume"
    done <<< "$old_volumes"
    [[ -z "$missing" ]] || die "Quickstart volume(s)${missing} have no home in $PROD_COMPOSE; the quickstart stack was not touched."
    stack_compose "$old_dir" "$old_env" stop \
        || die "Failed to stop the quickstart stack in $old_dir (exit $?); the quickstart stack was not touched."
    copies=$(quickstart_volume_dirs "$env_local") \
        || die "Cannot resolve the state directories of $env_local (exit $?)."
    mapfile -t copy_lines <<< "$copies"
    for line in "${copy_lines[@]}"; do
        copy_volume_to_dir "${project}_${line%% *}" "${line#* }" "$record"
    done
    # What: prod uses the CA the quickstart clients trust
    # Why: another CA would break every client's TLS trust
    # From: Issue #1683 | PR #1858
    migrate_legacy_ca "$old_dir/certs" "$env_local"
    _UPDATE_ENV_FILE="$env_local" _UPDATE_STACK_DIR="$stack_dir"
    validate_compose_config "$stack_dir"
    local apply_rc=0
    apply_stack_update_ordered "$stack_dir" rollback_quickstart_migration "$old_dir" "$record" "$stack_dir" "$env_local" || apply_rc=$?
    if [[ "$apply_rc" -eq 2 ]]; then
        trap - EXIT
        UPDATE_CONVERGENCE_COMPLETED=1
        die_convergence_kept_paused "The migrated stack failed its health gate, and restarting the quickstart stack in $old_dir failed too."
    fi
    [[ "$apply_rc" -eq 0 ]] \
        || die "The migrated stack failed its health gate; the quickstart stack in $old_dir runs again and nothing counts as migrated. Fix the cause, then rerun setup.sh update."
    if ! write_lancache_host_services "$stack_dir"; then
        print_warn "Neither systemd nor OpenRC found — host services were not written"
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
    [[ -z "$kept" ]] \
        || print_warn "Old logs and snapshots without a place in the new stack stay in:${kept}. Remove them with docker volume rm when no longer needed."
    # What: names copies of earlier failed migration runs
    # Why: nothing is deleted; the operator decides
    # From: Issue #1683 | PR #1858
    local -a aside=("$old_dir"/*.rolledback-*)
    [[ ! -e "${aside[0]}" ]] \
        || print_warn "Copies of earlier failed migration runs stay in: ${aside[*]}. Remove them when no longer needed."
)

# What: stops prod, moves copies aside, restarts quickstart
# Why: a failed migration must leave the old install running
# From: Issue #1683 | PR #1858
rollback_quickstart_migration() {
    local old_dir="$1" record="$2" stack_dir="$3" env_file="$4" stamp copies dir
    print_warn "Rolling back the migration; restarting the quickstart stack in $old_dir"
    stack_compose "$stack_dir" "$env_file" stop \
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

# What: writes the units of systemd or OpenRC; 1 if neither
# Why: fresh install and migration share one definition
# From: Issue #1683 | PR #1858
write_lancache_host_services() {
    local stack_dir="$1" manager
    manager=$(host_service_manager)
    case "$manager" in
        systemd) write_lancache_systemd_units "$stack_dir" ;;
        openrc) write_lancache_openrc_services "$stack_dir" ;;
        *) return 1 ;;
    esac
}

# What: writes the three OpenRC services of the stack
# Why: Alpine runs OpenRC; loops stand in for the timers
# From: Issue #1683 | PR #1858
write_lancache_openrc_services() {
    local stack_dir="$1" setup_sh="$SCRIPT_DIR/setup.sh" defaults init_dir log_dir stop_seconds
    local name job
    defaults=$(runtime_defaults_list) || exit $?
    init_dir=$(runtime_default_in "$defaults" OPENRC_INIT_DIR) || exit $?
    log_dir=$(runtime_default_in "$defaults" OPENRC_LOG_DIR) || exit $?
    stop_seconds=$(runtime_default_in "$defaults" OPENRC_STOP_TIMEOUT_SECONDS) || exit $?
    local compose="${setup_sh} compose ${stack_dir}"
    cat > "$init_dir/$OPENRC_STACK_SERVICE" <<EOF || die "Failed to write $init_dir/$OPENRC_STACK_SERVICE."
#!/sbin/openrc-run
description="LanCache-NG"

depend() {
	need ${OPENRC_DOCKER_SERVICE}
}

start() {
	ebegin "Starting LanCache-NG"
	${compose} up -d
	eend \$?
}

stop() {
	ebegin "Stopping LanCache-NG"
	${compose} down
	eend \$?
}
EOF
    chmod 0755 "$init_dir/$OPENRC_STACK_SERVICE" || die "Failed to make $init_dir/$OPENRC_STACK_SERVICE executable (exit $?)."
    for job in converge auto-update; do
        name="$OPENRC_CONVERGE_SERVICE"
        [[ "$job" = converge ]] || name="$OPENRC_AUTO_UPDATE_SERVICE"
        cat > "$init_dir/$name" <<EOF || die "Failed to write $init_dir/$name."
#!/sbin/openrc-run
description="LanCache-NG ${job} loop"
supervisor=supervise-daemon
command="${setup_sh}"
command_args="openrc-loop ${job} ${stack_dir}"
output_log="${log_dir}/${name}.log"
error_log="${log_dir}/${name}.log"
retry="TERM/${stop_seconds}/KILL/5"

depend() {
	need ${OPENRC_DOCKER_SERVICE}
}
EOF
        chmod 0755 "$init_dir/$name" || die "Failed to make $init_dir/$name executable (exit $?)."
    done
}

# What: writes the four lancache systemd units
# Why: fresh install and migration share one unit definition
# From: Issue #1683 | PR #1858
write_lancache_systemd_units() {
    local stack_dir="$1" setup_sh="$SCRIPT_DIR/setup.sh" unit_dir
    local docker_unit="$DOCKER_UNIT" timer_target="timers.target" defaults
    local converge_minutes boot_minutes restart_seconds update_calendar update_spread
    defaults=$(runtime_defaults_list) || exit $?
    unit_dir=$(runtime_default_in "$defaults" SYSTEMD_UNIT_DIR) || exit $?
    converge_minutes=$(runtime_default_in "$defaults" CONVERGE_TIMER_INTERVAL_MINUTES) || exit $?
    boot_minutes=$(runtime_default_in "$defaults" CONVERGE_TIMER_BOOT_DELAY_MINUTES) || exit $?
    restart_seconds=$(runtime_default_in "$defaults" STACK_UNIT_RESTART_SECONDS) || exit $?
    update_calendar=$(runtime_default_in "$defaults" AUTO_UPDATE_TIMER_CALENDAR) || exit $?
    update_spread=$(runtime_default_in "$defaults" AUTO_UPDATE_TIMER_SPREAD) || exit $?
    # What: units run compose through setup.sh at run time
    # Why: overrides may change after the unit is written
    # From: Issue #1683 | PR #1858
    local compose="${setup_sh} compose ${stack_dir}"
    cat > "$unit_dir/$STACK_UNIT" <<EOF || die "Failed to write $STACK_UNIT."
[Unit]
Description=LanCache-NG
After=${docker_unit}
Requires=${docker_unit}

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${stack_dir}
ExecStart=${compose} up -d
ExecStop=${compose} down
Restart=on-failure
RestartSec=${restart_seconds}

[Install]
WantedBy=multi-user.target
EOF
    # What: reconcile (exit ignored), then converge
    # Why: a failed reconcile must not stop the drift repair
    # From: Issue #819
    cat > "$unit_dir/$CONVERGE_SERVICE_UNIT" <<EOF || die "Failed to write $CONVERGE_SERVICE_UNIT."
[Unit]
Description=LanCache-NG Convergence Check
After=${docker_unit}

[Service]
Type=oneshot
WorkingDirectory=${stack_dir}
ExecStart=-${setup_sh} converge-reconcile ${stack_dir}
ExecStart=${compose} up -d --remove-orphans
EOF
    cat > "$unit_dir/$CONVERGE_TIMER_UNIT" <<EOF || die "Failed to write $CONVERGE_TIMER_UNIT."
[Unit]
Description=LanCache-NG Convergence Timer

[Timer]
OnBootSec=${boot_minutes}min
OnUnitActiveSec=${converge_minutes}min
Unit=${CONVERGE_SERVICE_UNIT}

[Install]
WantedBy=${timer_target}
EOF
    # What: daily host-side update runs the on-disk setup.sh
    # Why: no container gets Docker socket write access
    # From: Issue #819
    cat > "$unit_dir/$AUTO_UPDATE_SERVICE_UNIT" <<EOF || die "Failed to write $AUTO_UPDATE_SERVICE_UNIT."
[Unit]
Description=LanCache-NG Scheduled Automatic Update
After=${docker_unit}
Requires=${docker_unit}

[Service]
Type=oneshot
WorkingDirectory=${stack_dir}
ExecStart=${setup_sh} auto-update ${stack_dir}
EOF
    # What: daily, spread over 1h, missed runs caught up
    # Why: installs must not all hit GHCR at the same minute
    # From: Issue #819
    cat > "$unit_dir/$AUTO_UPDATE_TIMER_UNIT" <<EOF || die "Failed to write $AUTO_UPDATE_TIMER_UNIT."
[Unit]
Description=LanCache-NG Scheduled Automatic Update Timer

[Timer]
OnCalendar=${update_calendar}
RandomizedDelaySec=${update_spread}
Persistent=true
Unit=${AUTO_UPDATE_SERVICE_UNIT}

[Install]
WantedBy=${timer_target}
EOF
    systemctl daemon-reload || die "systemctl daemon-reload failed (exit $?)."
}

# What: true if no tracked file has local changes
# Why: untracked ca/ must not block; checkout guards it
# From: Issue #1683 | PR #1858
git_repo_is_clean() {
    local repo_dir="$1" out

    out=$(git -C "$repo_dir" status --porcelain --untracked-files=no) \
        || die "Failed to read the git status of $repo_dir (exit $?)."
    [[ -z "$out" ]]
}

# What: hard-resets a checkout to one origin branch
# Why: refuses dirty trees, so local edits survive
# From: Issue #1683 | PR #1858
sync_repo_to_branch() {
    local repo_dir="$1" branch="$2"

    git_repo_is_clean "$repo_dir" \
        || die "Existing repository at $repo_dir has local changes. Clean it first or remove $repo_dir, then rerun setup.sh."

    git -C "$repo_dir" fetch --prune origin \
        || die "Failed to refresh repository metadata for $repo_dir."
    git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$branch" \
        || die "Remote branch origin/$branch is unavailable for $repo_dir."
    git -C "$repo_dir" checkout -B "$branch" "origin/$branch" \
        || die "Failed to reset $repo_dir to origin/$branch."
}

# What: detaches a clean checkout at a tag or commit
# Why: a pinned channel runs the code of its image tag
# From: Issue #1683 | PR #1858
sync_repo_to_commit() {
    local repo_dir="$1" ref="$2"

    git_repo_is_clean "$repo_dir" \
        || die "Existing repository at $repo_dir has local changes. Clean it first or remove $repo_dir, then rerun setup.sh."

    git -C "$repo_dir" fetch --prune --tags origin \
        || die "Failed to refresh repository metadata for $repo_dir."
    git -C "$repo_dir" checkout --detach "${ref}^{commit}" \
        || die "Tag or commit '$ref' is not on origin of $repo_dir; check LANCACHE_IMAGE_TAG."
}

# What: returns LANCACHE_SETUP_GIT_REF, empty if unset
# Why: unset keeps the default branch behavior
# From: Issue #1683 | PR #1858
resolve_setup_bootstrap_ref() {
    printf '%s\n' "${LANCACHE_SETUP_GIT_REF:-}"
}

# What: hard-resets a checkout to a pinned ref
# Why: fetches the named ref explicitly; dirty trees refused
# From: Issue #1683 | PR #1858
sync_repo_to_ref() {
    local repo_dir="$1" ref="$2"

    git_repo_is_clean "$repo_dir" \
        || die "Existing repository at $repo_dir has local changes. Clean it first or remove $repo_dir, then rerun setup.sh."

    git -C "$repo_dir" fetch --prune origin "$ref" \
        || die "Failed to fetch ref '$ref' for $repo_dir. Check that LANCACHE_SETUP_GIT_REF names a real branch, tag, or commit on origin."
    git -C "$repo_dir" checkout -B "$ref" FETCH_HEAD \
        || die "Failed to reset $repo_dir to ref '$ref'."
}

# What: repo root two levels above a deploy/prod dir
# Why: locates certs and cdn-domains.txt
# From: Issue #1683 | PR #1858
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


# What: stores the Argon2id hash of an Admin UI password
# Why: only the hash is kept; a hash cannot be read back
# From: Issue #1683 | PR #1912
set_ui_password_hash() {
    local install_dir="$1" env_file="$2" password="$3" hash
    hash=$(printf '%s' "$password" | stack_compose "$install_dir" "$env_file" run --rm --no-deps -T ui hash-password) \
        || die "Failed to hash the Admin UI password in the ui image (exit $?); ${env_file} holds no password hash."
    [[ "$hash" =~ ^[A-Za-z0-9_-]+$ ]] || die "The ui image returned no usable password hash."
    set_env_key UI_AUTH_PASSWORD_HASH "$hash" "$env_file"
}

# What: hash a plaintext UI password, or make one per user
# Why: no plaintext password is ever written (AG-SEC-003)
# From: Issue #1683 | PR #1912
ensure_ui_password_hash() {
    local install_dir="$1" env_file="$2" password user hash
    if env_key_has_usable_secret UI_AUTH_PASSWORD "$env_file"; then
        password=$(get_env_var UI_AUTH_PASSWORD "$env_file") || exit $?
        set_ui_password_hash "$install_dir" "$env_file" "$password"
        remove_env_key UI_AUTH_PASSWORD "$env_file"
        print_ok "Admin UI password stored as an Argon2id hash; the plaintext value was removed"
        return 0
    fi
    remove_env_key UI_AUTH_PASSWORD "$env_file"
    user=$(get_env_var UI_AUTH_USER "$env_file") || exit $?
    hash=$(get_env_var UI_AUTH_PASSWORD_HASH "$env_file") || exit $?
    [[ -n "$user" && -z "$hash" ]] || return 0
    password=$(generate_managed_secret UI_AUTH_PASSWORD ui) || exit $?
    set_ui_password_hash "$install_dir" "$env_file" "$password"
    print_ok "Generated missing Admin UI password because UI_AUTH_USER is set"
    print_ok "Admin UI user $user, password: ${BOLD}${password}${RESET}"
    print_warn "Note the password now; only its hash is stored."
}

# What: default of a key, read from the SOT runtime.defaults
# Why: build-manifest.yml is the one owner; no .env copy
# From: Issue #1683 | PR #1912
prod_env_default() {
    local list
    list=$(runtime_defaults_list) || exit $?
    runtime_default_in "$list" "$1"
}

# What: a key's .env value, else its SOT default
# Why: .env holds only user values; no guessed default
# From: Issue #1683 | PR #1912
env_or_sot_default() {
    local value
    value=$(get_env_var "$1" "$2") || exit $?
    [[ -n "$value" ]] || value=$(prod_env_default "$1") || exit $?
    printf '%s\n' "$value"
}

# What: sets DEFAULT_INSTALL_DIR from the SOT, once
# Why: LANCACHE_STATE_DIR owns the checkout dir.
# From: Issue #1683 | PR #1912
ensure_default_install_dir() {
    [[ -n "${DEFAULT_INSTALL_DIR:-}" ]] && return 0
    DEFAULT_INSTALL_DIR=$(prod_env_default LANCACHE_STATE_DIR) || exit $?
}

# What: the SOT runtime.defaults rows, @KEY@ resolved.
# Why: a value naming another entry has one owner.
# From: Issue #1683 | PR #1912
runtime_defaults_list() {
    local rows
    rows=$(lancache_sot_list defaults runtime) || exit $?
    runtime_defaults_expand <<< "$rows"
}

# What: KEY=value rows on stdin, @KEY@ resolved.
# Why: ci.sh bakes the same rows; one resolver, no copy.
# From: Issue #1683 | PR #1912
runtime_defaults_expand() {
    awk '
        function ex(k, d,   v, n, s, l) {
            if (k in done) return val[k]
            if (d > 16) { print "runtime.defaults: @" k "@ refers to itself" > "/dev/stderr"; bad = 1; return "" }
            v = raw[k]
            while (match(v, /@[A-Za-z0-9_]+@/)) {
                s = RSTART; l = RLENGTH; n = substr(v, s + 1, l - 2)
                if (!(n in raw)) { print "runtime.defaults: " k " names @" n "@, which is no entry" > "/dev/stderr"; bad = 1; return v }
                v = substr(v, 1, s - 1) ex(n, d + 1) substr(v, s + l)
            }
            done[k] = 1; val[k] = v
            return v
        }
        NF { i = index($0, "="); k = substr($0, 1, i - 1); raw[k] = substr($0, i + 1); ord[++c] = k }
        END {
            for (j = 1; j <= c; j++) print ord[j] "=" ex(ord[j], 0)
            exit bad
        }' || die "The SOT runtime.defaults holds an unresolved @KEY@ reference."
}

# What: one key's value in a runtime.defaults row list
# Why: sot_compose reads the list once, not once per key
# From: Issue #1683 | PR #1912
runtime_default_in() {
    awk -v p="$2=" 'index($0, p) == 1 && !f { print substr($0, length(p) + 1); f = 1 } END { exit !f }' <<< "$1" \
        || die "The SOT runtime.defaults holds no default for $2."
}

# What: compose env rows: SOT_<KEY> and each state dir
# Why: one owner; compose and ci.sh get resolved paths
# From: Issue #1683 | PR #1912
sot_compose_env() {
    local env_file="${1:-}" state="${2:-}" keys key value list dir
    local -a words=()
    keys=$(lancache_sot_value compose_keys runtime) || exit $?
    list=$(runtime_defaults_list) || exit $?
    # What: key lists split by read -a, no glob
    # Why: an unquoted loop word would expand * or ?
    # From: Issue #1683 | PR #1858
    read -ra words <<< "${keys//$'\n'/ }"
    for key in "${words[@]}"; do
        value=$(runtime_default_in "$list" "$key") || exit $?
        printf 'SOT_%s=%s\n' "$key" "$value"
    done
    keys=$(prod_state_keys) || exit $?
    read -ra words <<< "${keys//$'\n'/ }"
    for key in "${words[@]}"; do
        dir=$(prod_state_dir_for_key "$key" "$env_file" "$state") || exit $?
        printf '%s=%s\n' "$key" "$dir"
    done
}

# What: docker compose with the env file and SOT rows
# Why: compose names no path, port or default of its own
# From: Issue #1683 | PR #1912
sot_compose() {
    local env_file="$1" rows state=""
    local -a sot_env=()
    shift
    # What: a quickstart .env may lack LANCACHE_STATE_DIR
    # Why: its state lives in the quickstart dir (v0.3.2)
    # From: Issue #1683 | PR #1858
    if [[ "${env_file##*/}" = .env ]] && is_quickstart_install "${env_file%/*}"; then
        state=$(get_env_var LANCACHE_STATE_DIR "$env_file") \
            || die "Cannot read LANCACHE_STATE_DIR from $env_file (exit $?)."
        [[ -n "$state" ]] || state="${env_file%/*}"
    fi
    rows=$(sot_compose_env "$env_file" "$state") || exit $?
    mapfile -t sot_env <<< "$rows"
    env "${sot_env[@]}" docker compose --env-file "$env_file" "$@"
}

# What: "svc KEY [TARGET]" rows moved out of config/prod
# Why: config/prod is gone; .env is the one value owner
# From: Issue #1683 | PR #1858
config_prod_moved_keys() {
    printf '%s\n' 'dns-standard PROXY_IP IP_HTTP' 'dns-ssl PROXY_IP IP_HTTPS' 'watchdog SSL_ENABLED' \
        'proxy CACHE_MAX_SIZE' 'proxy CACHE_MEM_MB' 'proxy CACHE_SLICE_SIZE' 'proxy CACHE_VALID_HIT' \
        'proxy CACHE_VALID_ANY' 'proxy CACHE_INACTIVE' 'proxy NGINX_UPSTREAM_RESOLVER' \
        'proxy PROXY_SECURITY_MODE' 'proxy PROXY_ALLOWED_CLIENT_CIDRS' 'dhcp DHCP_SUBNET' \
        'dhcp DHCP_RANGE_START' 'dhcp DHCP_RANGE_END' 'dhcp DHCP_GATEWAY' 'dhcp-proxy DHCP_SUBNET_START' \
        'dhcp-proxy DHCP_DNS_PRIMARY' 'dhcp-proxy DHCP_DNS_SECONDARY' 'dhcp-proxy UPSTREAM_DHCP_IP' \
        'dhcp-proxy DHCP_RELAY_LOCAL_ADDR' 'dhcp-proxy DHCP_PROXY_INTERFACE' 'dhcp-proxy DHCP_PROXY_ROUTER' \
        'dhcp-proxy DHCP_NTP_SERVERS' 'dhcp-proxy DHCP_PROXY_DOMAIN' 'dhcp-proxy DHCP_PROXY_BOOT_FILENAME' \
        'dhcp-proxy DHCP_PROXY_BOOT_SERVER' 'dhcp-proxy DHCP_PROXY_CUSTOM_OPTIONS' \
        'dhcp-proxy DHCP_PROXY_PXE_BOOT_SERVER' 'dhcp-proxy DHCP_PROXY_PXE_BOOT_FILENAME_BIOS' \
        'dhcp-proxy DHCP_PROXY_PXE_BOOT_FILENAME_UEFI' \
        'watchdog CACHE_VALID_DAYS' 'ntp NTP_UPSTREAM_SERVERS' 'ntp NTP_ALLOWED_CLIENT_CIDRS' \
        'cachehamster CACHEHAMSTER_URLS' 'proxy CACHE_MIN_FREE' 'dns-standard LOG_QUERIES' \
        'dns-standard ROOT_ZONE_MIRROR' 'dhcp DHCP_DOMAIN' 'dhcp DHCP_NTP_SERVERS' 'dhcp DHCP_DDNS_ENABLED'
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
    [[ "$step" = drop ]] || return 0
    # What: an emptied legacy <svc>.local.env is deleted
    # Why: AG-SETUP-001: config/prod files must be deleted
    # From: Issue #1683 | PR #1858
    local dir="$repo_root/config/prod" file left rest
    [[ -d "$dir" ]] || return 0
    for file in "$dir"/*.local.env; do
        [[ -f "$file" ]] || continue
        left=$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ { print $1 }' "$file") \
            || die "Failed to list the keys of $file (exit $?)."
        if [[ -n "$left" ]]; then
            print_warn "Kept ${file##*/}: it still sets ${left//$'\n'/, }, which no container reads. Move them into ${env_file##*/} or delete the file."
            continue
        fi
        rm -f -- "$file" || die "Failed to delete $file (exit $?)."
        print_ok "Deleted the emptied legacy file ${file##*/}"
    done
    rest=$(find "$dir" -mindepth 1 -print -quit) || die "Failed to list $dir (exit $?)."
    [[ -n "$rest" ]] || rmdir -- "$dir" || die "Failed to delete the empty $dir (exit $?)."
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

# What: dies if a required key is missing or empty
# Why: update must not run with an unusable configuration
# From: Issue #1683 | PR #1858
require_env_value_for_update() {
    local key="$1" env_file="$2"
    env_key_has_value "$key" "$env_file" \
        || die "$key is missing or empty in $env_file. Set it before running setup.sh update."
}

# What: IP_HTTP and IP_HTTPS are two valid, distinct IPv4s
# Why: dns-http and dns-https bind apart (AG-SETUP-001)
# From: Issue #1683 | PR #1858
require_separate_lan_ips() {
    is_valid_ipv4 "$1" || die "IP_HTTP is not a valid IPv4 address: $1"
    is_valid_ipv4 "$2" || die "IP_HTTPS is not a valid IPv4 address: $2"
    [[ "$1" != "$2" ]] || die "IP_HTTP and IP_HTTPS must be different."
}

# What: sets a secret only if no usable value exists
# Why: an operator's real secret is never overwritten
# From: Issue #1683 | PR #1858
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
# Why: callers pick the fallback from the SOT defaults
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
    local arch platform
    arch=$(uname -m)
    platform=$(host_image_platform "$arch") \
        || die "This host's architecture '${arch}' has no container image platform; LanCache-NG cannot run here."
    print_ok "Host architecture ${arch} maps to image platform ${platform}"
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
# From: Issue #1683 | PR #1858
assert_resolved_image_tag_platform_supported() {
    local registry="$1" prefix="$2" tag="$3"
    local arch platform image single_platform inspect_text discovered_platforms buildx_out plat_line plat_found=0

    arch=$(uname -m)
    platform=$(host_image_platform "$arch") \
        || die "This host's architecture '${arch}' has no container image platform; LanCache-NG cannot run here."

    command_available docker \
        || die "docker is required to verify that image tag '${tag}' publishes a ${platform} image before continuing."
    buildx_out=$(docker buildx version 2>&1) \
        || die "docker buildx is required to verify that image tag '${tag}' publishes a ${platform} image before continuing (exit $?: ${buildx_out}). Install the ${DOCKER_BUILDX_PLUGIN} package, then rerun setup.sh."

    image="${registry}/${prefix}/dns:${tag}"

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

    # What: a line equal to the platform or below it counts
    # Why: a loop reads the whole list; no early-exit pipe
    # From: Issue #1377
    while IFS= read -r plat_line; do
        if [[ "$plat_line" == "$platform" || "$plat_line" == "$platform"/* ]]; then plat_found=1; fi
    done <<<"$discovered_platforms"
    [[ "$plat_found" -eq 1 ]] \
        || die "Image tag '${tag}' does not publish a ${platform} image for this ${arch} host (published: $(printf '%s' "$discovered_platforms" | tr '\n' ',' | sed 's/,$//')). Choose a tag or channel that publishes ${platform}, then rerun setup.sh."
}

# What: the running init: systemd, openrc or empty
# Why: a systemctl binary alone fails without an init
# From: Issue #1683 | PR #1858
host_service_manager() {
    if command_available systemctl && [[ -d /run/systemd/system ]]; then
        printf 'systemd\n'
    elif command_available rc-service && command_available rc-update && [[ -d /run/openrc ]]; then
        printf 'openrc\n'
    fi
}

# What: the OpenRC service of a unit; empty if none
# Why: one OpenRC loop service does timer plus job
# From: Issue #1683 | PR #1858
openrc_service_for_unit() {
    case "$1" in
        "$STACK_UNIT") printf '%s\n' "$OPENRC_STACK_SERVICE" ;;
        "$CONVERGE_TIMER_UNIT") printf '%s\n' "$OPENRC_CONVERGE_SERVICE" ;;
        "$AUTO_UPDATE_TIMER_UNIT") printf '%s\n' "$OPENRC_AUTO_UPDATE_SERVICE" ;;
        "$DOCKER_UNIT") printf '%s\n' "$OPENRC_DOCKER_SERVICE" ;;
    esac
}

# What: true if the init knows the unit or its service
# Why: timer handling is a no-op without the units
# From: Issue #1683 | PR #1858
host_unit_exists() {
    local unit="$1" manager name init_dir out rc=0
    manager=$(host_service_manager)
    case "$manager" in
        systemd)
            out=$(systemctl list-unit-files --no-legend "$unit" 2>&1) || rc=$?
            [[ -n "$out" ]] || return 1
            [[ "$rc" -eq 0 ]] || die "Failed to look up the systemd unit $unit (exit $rc): $out"
            ;;
        openrc)
            name=$(openrc_service_for_unit "$unit")
            [[ -n "$name" ]] || return 1
            init_dir=$(prod_env_default OPENRC_INIT_DIR) || exit $?
            [[ -x "$init_dir/$name" ]]
            ;;
        *) return 1 ;;
    esac
}

# What: true while the unit or its OpenRC service runs
# Why: pause and resume keep the state the operator set
# From: Issue #1683 | PR #1858
host_unit_active() {
    local unit="$1" manager name out rc=0
    manager=$(host_service_manager)
    case "$manager" in
        systemd) systemctl is-active --quiet "$unit" ;;
        openrc)
            name=$(openrc_service_for_unit "$unit")
            [[ -n "$name" ]] || return 1
            out=$(rc-service "$name" status 2>&1) || rc=$?
            [[ "$rc" -eq 0 || "$rc" -eq 3 ]] \
                || print_warn "rc-service $name status ended with exit $rc: $out"
            [[ "$rc" -eq 0 ]]
            ;;
        *) return 1 ;;
    esac
}

# What: true if the unit starts at boot
# Why: OpenRC keeps this as a default runlevel entry
# From: Issue #1683 | PR #1858
host_unit_enabled() {
    local unit="$1" manager name runlevel
    manager=$(host_service_manager)
    case "$manager" in
        systemd) systemctl is-enabled --quiet "$unit" ;;
        openrc)
            name=$(openrc_service_for_unit "$unit")
            [[ -n "$name" ]] || return 1
            runlevel=$(rc-update show default) || die "rc-update show default failed (exit $?)."
            awk -v s="$name" '$1 == s && $2 == "|" { found = 1 } END { exit !found }' <<< "$runlevel"
            ;;
        *) return 1 ;;
    esac
}

# What: start, stop, enable or disable a unit; dies on error
# Why: systemd and OpenRC share one call per unit action
# From: Issue #1683 | PR #1858
host_unit_action() {
    local unit="$1" action="$2" manager name out rc=0 limit
    manager=$(host_service_manager)
    # What: a start or stop ends after the SOT stop limit
    # Why: a hung stop held setup.sh update without a word
    # From: Issue #1683 | PR #1858
    limit=$(prod_env_default OPENRC_STOP_TIMEOUT_SECONDS) || exit $?
    limit=$(( limit + 60 ))
    case "$manager" in
        systemd) out=$(timeout "$limit" systemctl "$action" "$unit" 2>&1) || rc=$? ;;
        openrc)
            name=$(openrc_service_for_unit "$unit")
            [[ -n "$name" ]] || die "No OpenRC service stands for $unit."
            case "$action" in
                start|stop) out=$(timeout "$limit" rc-service "$name" "$action" 2>&1) || rc=$? ;;
                enable) out=$(rc-update add "$name" default 2>&1) || rc=$? ;;
                disable) out=$(rc-update del "$name" default 2>&1) || rc=$? ;;
                *) die "Unknown service action: $action" ;;
            esac
            ;;
        *) die "Neither systemd nor OpenRC runs here; cannot $action $unit." ;;
    esac
    [[ "$rc" -ne 124 ]] || die "Could not $action $unit within $limit s: $out"
    [[ "$rc" -eq 0 ]] || die "Failed to $action $unit (exit $rc): $out"
}

# What: the command an operator runs for a unit action
# Why: recovery hints name the command of this host's init
# From: Issue #1683 | PR #1858
host_unit_command() {
    local unit="$1" action="$2" manager name
    manager=$(host_service_manager)
    if [[ "$manager" = openrc ]]; then
        name=$(openrc_service_for_unit "$unit")
        case "$action" in
            enable) printf 'rc-update add %s default\n' "$name" ;;
            disable) printf 'rc-update del %s default\n' "$name" ;;
            *) printf 'rc-service %s %s\n' "$name" "$action" ;;
        esac
    else
        printf 'systemctl %s %s\n' "$action" "$unit"
    fi
}

CONVERGENCE_TIMER_WAS_ACTIVE=0
CONVERGENCE_TIMER_WAS_ENABLED=0
CONVERGENCE_SERVICE_WAS_ACTIVE=0
UPDATE_CONVERGENCE_PAUSED=0
UPDATE_CONVERGENCE_COMPLETED=0

# What: pauses the convergence timer and service for update
# Why: a running timer could start compose during migration
# From: Issue #1683 | PR #1858
pause_lancache_convergence_for_update() {
    CONVERGENCE_TIMER_WAS_ACTIVE=0
    CONVERGENCE_TIMER_WAS_ENABLED=0
    CONVERGENCE_SERVICE_WAS_ACTIVE=0

    local timer_exists=0 service_exists=0
    host_unit_exists "$CONVERGE_TIMER_UNIT" && timer_exists=1
    host_unit_exists "$CONVERGE_SERVICE_UNIT" && service_exists=1
    if [[ "$timer_exists" = "0" && "$service_exists" = "0" ]]; then
        return 0
    fi

    if [[ "$timer_exists" = "1" ]] && host_unit_active "$CONVERGE_TIMER_UNIT"; then
        CONVERGENCE_TIMER_WAS_ACTIVE=1
        print_step "Pausing convergence timer"
        host_unit_action "$CONVERGE_TIMER_UNIT" stop
    fi

    if [[ "$service_exists" = "1" ]] && host_unit_active "$CONVERGE_SERVICE_UNIT"; then
        CONVERGENCE_SERVICE_WAS_ACTIVE=1
        print_step "Stopping active convergence service"
        host_unit_action "$CONVERGE_SERVICE_UNIT" stop
        if host_unit_active "$CONVERGE_SERVICE_UNIT"; then
            die "$CONVERGE_SERVICE_UNIT is still active after stop; refusing to update concurrently."
        fi
    fi

    if [[ "$timer_exists" = "1" ]] && host_unit_enabled "$CONVERGE_TIMER_UNIT"; then
        CONVERGENCE_TIMER_WAS_ENABLED=1
        host_unit_action "$CONVERGE_TIMER_UNIT" disable
    fi
}

# What: restores units that were active or enabled
# Why: keeps manual operator choices intact
# From: Issue #1683 | PR #1858
resume_lancache_convergence_after_update() {
    local restart_service="${1:-false}"

    if [[ "$restart_service" = "true" ]] \
        && [[ "$CONVERGENCE_SERVICE_WAS_ACTIVE" = "1" ]] \
        && host_unit_exists "$CONVERGE_SERVICE_UNIT"; then
        host_unit_action "$CONVERGE_SERVICE_UNIT" start
    fi

    if ! host_unit_exists "$CONVERGE_TIMER_UNIT"; then
        return 0
    fi

    if [[ "$CONVERGENCE_TIMER_WAS_ENABLED" = "1" ]]; then
        host_unit_action "$CONVERGE_TIMER_UNIT" enable
    fi

    if [[ "$CONVERGENCE_TIMER_WAS_ACTIVE" = "1" ]]; then
        host_unit_action "$CONVERGE_TIMER_UNIT" start
    fi
}

# What: EXIT trap resumes convergence after a failed update
# Why: a failed run must not leave the timer stopped
# From: Issue #1683 | PR #1858
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

# What: EXIT trap while .env is prepared for moved code
# Why: units must not start new code with the old .env
# From: Issue #1683 | PR #1858
rollback_update_after_env_failure() {
    local exit_code=$?

    trap - EXIT
    UPDATE_CONVERGENCE_COMPLETED=1
    rollback_stack_update "$_UPDATE_ROLLBACK_DIR" \
        || die_convergence_kept_paused "Preparing .env for the new code failed, and the rollback to the pre-update backup failed too."
    resume_lancache_convergence_after_update
    print_error "Preparing .env for the new code failed (exit $exit_code); the update was rolled back."
    exit "$exit_code"
}

# What: dies; convergence stays paused, prints how to resume
# Why: a timer `compose up` must not race manual recovery
# From: Issue #1683 | PR #1858
die_convergence_kept_paused() {
    local resume="" cmd
    if [[ "$CONVERGENCE_TIMER_WAS_ENABLED" = "1" ]]; then
        resume=$(host_unit_command "$CONVERGE_TIMER_UNIT" enable)
    fi
    if [[ "$CONVERGENCE_TIMER_WAS_ACTIVE" = "1" ]]; then
        cmd=$(host_unit_command "$CONVERGE_TIMER_UNIT" start)
        resume="${resume:+$resume && }$cmd"
    fi
    die "$1 Manual recovery required.${resume:+ Convergence stays paused; after recovery run: $resume}"
}

# What: true for a vX.Y.Z or vX.Y.Z-rc.N release tag
# Why: SOT release.tag_final and tag_prerelease own it
# From: Issue #1683 | PR #1912
is_release_tag() {
    local tag="$1" final pre
    final=$(lancache_sot_value tag_final release) || exit $?
    pre=$(lancache_sot_value tag_prerelease release) || exit $?
    [[ "$tag" =~ $final || "$tag" =~ $pre ]]
}

# What: true for a sha-* commit image tag
# Why: SOT release.tag_commit owns the grammar
# From: Issue #1683 | PR #1912
is_commit_image_tag() {
    local tag="$1" commit
    commit=$(lancache_sot_value tag_commit release) || exit $?
    [[ "$tag" =~ $commit ]]
}

# What: validates the image tag before any compose pull
# Why: mutable channels must resolve to one immutable tag
# From: Issue #1683 | PR #1858
validate_lancache_image_tag() {
    local tag="$1"

    case "$tag" in
        sha-*)
            # What: short or malformed sha- pin stops
            # Why: AG-REL-015: full 40-hex SHA only
            # From: Issue #1683 | PR #1912
            is_commit_image_tag "$tag" \
                || die "LANCACHE_IMAGE_TAG '$tag' is not sha-<40-hex commit SHA>. Set the full commit SHA, a vX.Y.Z tag or a channel."
            return 0
            ;;
    esac

    is_release_tag "$tag" \
        || die "LANCACHE_IMAGE_TAG must be sha-<40-hex commit SHA> or a vX.Y.Z / vX.Y.Z-rc.N release tag."
}

# What: SOT release rows of one kind, fields after it
# Why: AG-REL-010; hosts lack yq; one awk reader
# From: Issue #1683 | PR #1858
lancache_release_rows() {
    local kind="$1" sot="$LANCACHE_SOT" text="$LANCACHE_SOT_TEXT" rows counts n_channel n_release n_pinned
    rows=$(awk '
        /^[^ #]/ { top = $0; sub(/:.*/, "", top); next }
        top != "release" || /^ *#/ || /^ *$/ { next }
        { depth = match($0, /[^ ]/) - 1; line = substr($0, depth + 1)
          key = line; sub(/:.*/, "", key); val = line; sub(/^[^:]*: */, "", val) }
        depth == 2 { sec = key; if (key == "pinned_channel") print "pinned", val; next }
        depth == 4 && sec == "channels" { ch = key; print "channel", ch; next }
        depth == 4 && sec == "retired_channels" { gsub(/^"|"$/, "", val); print "retired", key, val; next }
        depth == 6 && sec == "channels" && key == "release_tags" && val == "true" { print "release", ch; next }
        depth == 6 && sec == "channels" && key == "ref" { print "ref", ch, val; next }
        depth == 6 && sec == "channels" && key == "source_ref" { print "source", ch, val; next }
        depth == 6 && sec == "channels" && key == "aliases" {
            gsub(/^\[|\] *$/, "", val); n = split(val, list, / *, */)
            for (i = 1; i <= n; i++) if (list[i] != "") print "alias", list[i], ch
        }' <<< "$text") || die "Failed to read the release block of ${sot}."
    counts=$(awk '$1 == "channel" { c++ } $1 == "release" { r++ } $1 == "pinned" { p++ }
        END { print c + 0, r + 0, p + 0 }' <<< "$rows") || die "Failed to count the release rows of ${sot}."
    read -r n_channel n_release n_pinned <<< "$counts"
    [[ "$n_channel" -ge 1 && "$n_release" -eq 1 && "$n_pinned" -eq 1 ]] \
        || die "${sot} needs release channels, one release_tags channel and pinned_channel."
    awk -v k="$kind" '$1 == k { sub(/^[^ ]+ /, ""); print }' <<< "$rows"
}

# What: the SOT channel names and their aliases
# Why: a tag or channel word names a stack pointer
# From: Issue #1683 | PR #1858
lancache_channel_words() {
    local channels aliases
    channels=$(lancache_release_rows channel) || exit $?
    aliases=$(lancache_release_rows alias) || exit $?
    printf '%s\n' "$channels"
    awk '{ print $1 }' <<< "$aliases"
}

# What: accepts SOT channels, their aliases, pinned
# Why: retired names stop with their reason; no fallback
# From: Issue #1683 | PR #1858
validate_lancache_image_channel() {
    local channel="$1" accepted pinned retired reason valid
    accepted=$(lancache_channel_words) || exit $?
    pinned=$(lancache_release_rows pinned) || exit $?
    accepted=$(printf '%s\n%s\n' "$accepted" "$pinned")
    [[ -z "$channel" ]] || ! list_has_line "$channel" "$accepted" || return 0
    valid=$(paste -sd' ' <<< "$accepted")
    retired=$(lancache_release_rows retired) || exit $?
    reason=$(awk -v c="$channel" '$1 == c { sub(/^[^ ]+ /, ""); print; exit }' <<< "$retired")
    [[ -z "$reason" ]] \
        || die "LANCACHE_IMAGE_CHANNEL=$channel is no longer supported ($reason). Set LANCACHE_IMAGE_CHANNEL to one of: $valid; then re-run setup.sh."
    die "LANCACHE_IMAGE_CHANNEL must be one of: $valid."
}

# What: vX.Y.Z[-rc.N] from the git tag or the archive tag
# Why: rc 1 means no tag; rc 2 means found but malformed
# From: Issue #1683 | PR #1912
derive_release_archive_image_tag() {
    local version tag tags line git_stderr git_status
    local -a safe_dir_opt=()

    # What: a .git entry means a real git checkout
    # Why: git errors must not read as no checkout
    # From: Issue #1683 | PR #1858
    if [[ -e "$SCRIPT_DIR/.git" ]]; then
        if git_stderr=$(git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree 2>&1); then
            git_status=0
        else
            git_status=$?
        fi

        if [[ "$git_status" -ne 0 ]]; then
            if [[ "$git_stderr" == *"detected dubious ownership"* ]]; then
                # What: trusts the path git names on stderr
                # Why: bind mounts trigger dubious ownership
                # From: Issue #1683 | PR #1858
                local dubious_path="$SCRIPT_DIR"
                local dubious_first_line="${git_stderr%%$'\n'*}"
                if [[ "$dubious_first_line" =~ dubious\ ownership\ in\ repository\ at\ \'(.+)\' ]]; then
                    dubious_path="${BASH_REMATCH[1]}"
                fi
                safe_dir_opt=(-c "safe.directory=$dubious_path")
                printf 'Note: %s has different file ownership than the current user; trusting it for this run only (see: git help safe.directory).\n' "$dubious_path" >&2
            else
                printf 'Warning: %s contains a .git directory but git rejected it:\n%s\nSet LANCACHE_IMAGE_TAG or LANCACHE_IMAGE_CHANNEL to override.\n' "$SCRIPT_DIR" "$git_stderr" >&2
            fi
        fi

        if git_stderr=$(git "${safe_dir_opt[@]}" -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree 2>&1); then
            if ! tags=$(git "${safe_dir_opt[@]}" -C "$SCRIPT_DIR" tag --points-at HEAD); then
                printf 'Failed to list the tags at HEAD of %s.\n' "$SCRIPT_DIR" >&2
                return 2
            fi
            [[ -n "$tags" ]] || return 1
            tag=""
            while IFS= read -r line; do
                is_release_tag "$line" && tag+="${tag:+$'\n'}$line"
            done <<< "$tags"
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
        # What: falls through to the archive tag below
        # Why: git still refuses the .git after the retry
        # From: Issue #1683 | PR #1858
        printf 'Warning: git still rejects %s:\n%s\nUsing the archive tag, if any.\n' "$SCRIPT_DIR" "$git_stderr" >&2
    fi

    # What: the tag git wrote into this source archive
    # Why: the version is the tag; no SOT copy of it
    # From: Issue #1683 | PR #1858
    tag="$LANCACHE_ARCHIVE_REF"
    [[ "$tag" != *"Format:"* ]] || return 1
    is_release_tag "$tag" || return 1
    printf '%s\n' "$tag"
}

# What: rejects a value that is not a registry host[:port]
# Why: a bad host would break every image pull
# From: Issue #1683 | PR #1858
validate_lancache_image_registry() {
    local registry="$1"
    [[ "$registry" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?$ ]] \
        || die "LANCACHE_IMAGE_REGISTRY must be a registry hostname with an optional port."
}

# What: rejects a non-namespace prefix value
# Why: a bad prefix would break every image pull
# From: Issue #1683 | PR #1858
validate_lancache_image_prefix() {
    local prefix="$1"
    [[ "$prefix" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
        || die "LANCACHE_IMAGE_PREFIX must be a slash-separated image namespace."
}

# What: resolves the registry: shell env, .env, then the SOT
# Why: an override is validated and fails fast
# From: Issue #1683 | PR #1858
resolve_lancache_image_registry() {
    local env_file="${1:-}" registry="${LANCACHE_IMAGE_REGISTRY:-}"

    if [[ -z "$registry" && -n "$env_file" && -f "$env_file" ]]; then
        registry=$(get_env_var LANCACHE_IMAGE_REGISTRY "$env_file") || exit $?
    fi

    if [[ -z "$registry" ]]; then
        registry=$(lancache_sot_value registry release) || exit $?
    fi
    validate_lancache_image_registry "$registry"
    printf '%s\n' "$registry"
}

# What: resolves the prefix: shell env, .env, then the repo
# Why: same precedence as the registry resolver
# From: Issue #1683 | PR #1858
resolve_lancache_image_prefix() {
    local env_file="${1:-}" prefix="${LANCACHE_IMAGE_PREFIX:-}"

    if [[ -z "$prefix" && -n "$env_file" && -f "$env_file" ]]; then
        prefix=$(get_env_var LANCACHE_IMAGE_PREFIX "$env_file") || exit $?
    fi

    prefix="${prefix:-${LANCACHE_REPO_URL#https://github.com/}}"
    validate_lancache_image_prefix "$prefix"
    printf '%s\n' "$prefix"
}

# What: picks the channel from env, tag, or derived release
# Why: an untagged install gets the release-tag channel
# From: Issue #1683 | PR #1858
resolve_lancache_image_channel() {
    local env_file="${1:-}" channel="${LANCACHE_IMAGE_CHANNEL:-}" tag="${LANCACHE_IMAGE_TAG:-}" release_tag=""
    local words pinned release

    if [[ -z "$channel" && -n "$env_file" && -f "$env_file" ]]; then
        channel=$(get_env_var LANCACHE_IMAGE_CHANNEL "$env_file") || exit $?
    fi

    if [[ -z "$tag" && -n "$env_file" && -f "$env_file" ]]; then
        tag=$(get_env_var LANCACHE_IMAGE_TAG "$env_file") || exit $?
    fi

    words=$(lancache_channel_words) || exit $?
    pinned=$(lancache_release_rows pinned) || exit $?
    release=$(lancache_release_rows release) || exit $?
    if [[ -n "$tag" ]] && list_has_line "$tag" "$words"; then
        channel="${channel:-$tag}"
    elif [[ "$tag" == sha-* || "$tag" == v[0-9]* ]]; then
        channel="${channel:-$pinned}"
    fi

    if [[ -z "$channel" ]]; then
        if release_tag=$(derive_release_archive_image_tag); then
            channel="$pinned"
        elif [[ "$?" = "2" ]]; then
            die "Cannot derive a valid release image tag from this checkout/archive."
        fi
        [[ -n "$release_tag" ]] && channel="$pinned"
    fi

    channel="${channel:-$release}"
    validate_lancache_image_channel "$channel"
    printf '%s\n' "$channel"
}

# What: maps an alias to its channel; others pass through
# Why: an alias has no stack tag of its own
# From: Issue #1683 | PR #1858
lancache_stack_pointer_channel_for() {
    local channel="$1" aliases target
    aliases=$(lancache_release_rows alias) || exit $?
    target=$(awk -v a="$channel" '$1 == a { print $2; exit }' <<< "$aliases")
    printf '%s\n' "${target:-$channel}"
}

# What: the source branches of the SOT channels
# Why: only these branches does an update move
# From: Issue #1683 | PR #1858
lancache_channel_branches() {
    local sources
    sources=$(lancache_release_rows source) || exit $?
    awk '{ sub(/^refs\/heads\//, "", $2); print $2 }' <<< "$sources"
}

# What: git branch, tag or commit of a channel's code
# Why: AG-REL-009: compose and images from one ref
# From: Issue #1683 | PR #1858
lancache_channel_code_ref() {
    local channel="$1" tag="$2" pinned sources ref
    pinned=$(lancache_release_rows pinned) || exit $?
    if [[ "$channel" = "$pinned" ]]; then
        # What: sha-<commit> is a commit, vX.Y.Z a tag
        # Why: the image tag says which tree built it
        # From: Issue #1683 | PR #1858
        printf '%s\n' "${tag#sha-}"
        return 0
    fi
    channel=$(lancache_stack_pointer_channel_for "$channel") || exit $?
    sources=$(lancache_release_rows source) || exit $?
    ref=$(awk -v c="$channel" '$1 == c { print $2; exit }' <<< "$sources")
    [[ -n "$ref" ]] || die "${LANCACHE_SOT} defines no release.channels.${channel}.source_ref."
    printf '%s\n' "${ref#refs/heads/}"
}

# What: ref variable and slug of each first-party image
# Why: the prod compose names the ref; the slug is its name
# From: Issue #1683 | PR #1858
lancache_image_ref_vars() {
    local vars
    vars=$(sed -nE 's/^ *image: \$\{(LANCACHE_IMAGE_REF_([A-Z_]+)):\?.*$/\1 \2/p' "$PROD_COMPOSE" \
        | awk '{ print $1, tolower($2) }' | sort -u) \
        || die "Failed to read the first-party image refs from $PROD_COMPOSE."
    [[ -n "$vars" ]] || die "$PROD_COMPOSE declares no LANCACHE_IMAGE_REF_* image; cannot pin a channel."
    printf '%s\n' "$vars"
}

# What: one SOT key of a block: a scalar or its - items
# Why: one awk reader for both; yq is not on a host
# From: Issue #1683 | PR #1912
lancache_sot_read() {
    local kind="$1" key="$2" block="$3" sot="$LANCACHE_SOT" text="$LANCACHE_SOT_TEXT" value
    value=$(awk -v b="${block}:" -v k="  ${key}:" -v kind="$kind" '
        function unq(s) { sub(/^"/, "", s); sub(/"$/, "", s); return s }
        $0 == b { f = 1; next }
        f && /^[^ #]/ { exit }
        f && !l && kind == "value" && index($0, k) == 1 {
            v = substr($0, length(k) + 1); sub(/^ +/, "", v); print unq(v); exit
        }
        f && !l && kind == "list" && $0 == k { l = 1; next }
        l && /^    - / { print unq(substr($0, 7)); next }
        l && /^    #/ { next }
        l { exit }' <<< "$text") \
        || die "Failed to read ${block}.${key} from ${sot}."
    [[ -n "$value" ]] || die "${sot} defines no ${block}.${key} ${kind}."
    printf '%s\n' "$value"
}

# What: one value of KEY in a named SOT block
# Why: setup.sh reads product values, never copies them
# From: Issue #1683 | PR #1858
lancache_sot_value() {
    lancache_sot_read value "$1" "$2"
}

# What: the entries of one SOT block list, one per line
# Why: the installer reads lists too; yq is not on a host
# From: Issue #1683 | PR #1912
lancache_sot_list() {
    lancache_sot_read list "$1" "$2"
}

# What: sets the helper image to the SOT's alpine
# Why: one owner; latest, no third-party pin
# From: Issue #1683 | PR #1858
require_helper_image() {
    [[ -z "$LANCACHE_HELPER_IMAGE" ]] || return 0
    LANCACHE_HELPER_IMAGE=$(lancache_sot_value alpine base_images) || exit $?
}

# What: true while the channel's promote lock ref exists
# Why: promote moves every channel tag inside this lock
# From: Issue #1683 | PR #1858
lancache_promote_lock_held() {
    local lock_ref="$1" out pinned
    pinned=$(lancache_release_rows pinned) || exit $?
    out=$(git -C "$SCRIPT_DIR" ls-remote origin "$lock_ref") \
        || die "Failed to read the promote lock ${lock_ref} from origin (exit $?). A channel install needs the git checkout's origin; set LANCACHE_IMAGE_CHANNEL=${pinned} with a vX.Y.Z tag otherwise."
    [[ -n "$out" ]]
}

# What: VAR=<image>@<digest> per image, one registry pass
# Why: each image of the channel pinned to its digest
# From: Issue #1683 | PR #1858
lancache_channel_ref_pass() {
    local registry="$1" prefix="$2" pointer_channel="$3" vars="$4" var slug ref digest
    local release alias testing
    release=$(lancache_release_rows release) || exit $?
    alias=$(lancache_release_rows alias) || exit $?
    alias=$(awk -v c="$release" '$2 == c { print $1; exit }' <<< "$alias")
    testing=$(lancache_release_rows channel) || exit $?
    testing=$(awk -v r="$release" '$0 != r { print; exit }' <<< "$testing")
    while read -r var slug; do
        ref="${registry}/${prefix}/${slug}:${pointer_channel}"
        if ! digest=$(docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}' 2>&1); then
            if [[ "$pointer_channel" = "$release" ]]; then
                cat >&2 <<EOF

${RED}✗${RESET} Cannot resolve the '${alias:-$release}' release channel (published as the '${release}' pointer image).

To proceed, choose one of these options:

  1. Check the network access to the registry, then run setup.sh again.

  2. Pin to a specific release version or commit (immutable):
     LANCACHE_IMAGE_TAG=vX.Y.Z ./setup.sh install
     LANCACHE_IMAGE_TAG=sha-<40-hex commit SHA> ./setup.sh install

  3. Use the '${testing}' channel (experimental, may break, not for production):
     LANCACHE_IMAGE_CHANNEL=${testing} ./setup.sh install

For details on release channels and their stability, see:
  docs/release-versioning.md

EOF
                die "Cannot resolve the ${alias:-$release} channel image ${ref} (${digest})."
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
    local install_channel
    pointer_channel=$(lancache_stack_pointer_channel_for "$channel") || exit $?
    registry=$(resolve_lancache_image_registry "$env_file") \
        || die "Cannot resolve the image registry for channel ${channel} (exit $?)."
    prefix=$(resolve_lancache_image_prefix "$env_file") \
        || die "Cannot resolve the image prefix for channel ${channel} (exit $?)."
    vars=$(lancache_image_ref_vars) \
        || die "Cannot list the first-party images for channel ${channel} (exit $?)."
    max=$(lancache_sot_value install_lock_tries release) \
        || die "Cannot read release.install_lock_tries (exit $?)."
    backoff=$(lancache_sot_value install_lock_poll_seconds release) \
        || die "Cannot read release.install_lock_poll_seconds (exit $?)."
    lock_ref=$(lancache_sot_value promote_lock_ref release) \
        || die "Cannot read release.promote_lock_ref (exit $?)."
    lock_ref="${lock_ref}/${pointer_channel}"

    command_available docker \
        || die "Docker is required to resolve LANCACHE_IMAGE_CHANNEL=${channel}."
    buildx_out=$(docker buildx version 2>&1) \
        || die "docker buildx is required to resolve LANCACHE_IMAGE_CHANNEL=${channel} (exit $?: ${buildx_out}). Install the ${DOCKER_BUILDX_PLUGIN} package, then rerun setup.sh."

    printf '\n%s%s▶ Resolving image channel %s%s\n' "${BOLD}" "${CYAN}" "$channel" "${RESET}" >&2
    # What: every non-default pointer warns on each run
    # Why: maintainer 29.10.: nightly is experimental
    # From: Issue #1683 | PR #1858
    install_channel=$(lancache_sot_value install_channel release) \
        || die "Cannot read release.install_channel (exit $?)."
    install_channel=$(lancache_stack_pointer_channel_for "$install_channel") || exit $?
    if [[ "$pointer_channel" != "$install_channel" ]]; then
        print_warn "The $channel channel is experimental: untested daily builds that may break the stack; not for production use." >&2
    fi
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

# What: image pins for a tag; a channel resolves to digests
# Why: the prod compose has no image default; resolve first
# From: Issue #1683 | PR #1858
lancache_image_refs_for_tag() {
    local env_file="$1" tag="$2" channels registry prefix vars var slug
    channels=$(lancache_release_rows channel) || exit $?
    if list_has_line "$tag" "$channels"; then
        lancache_channel_image_refs "$env_file" "$tag"
        return
    fi
    registry=$(resolve_lancache_image_registry "$env_file") || exit $?
    prefix=$(resolve_lancache_image_prefix "$env_file") || exit $?
    vars=$(lancache_image_ref_vars) || exit $?
    while read -r var slug; do
        printf '%s=%s/%s/%s:%s\n' "$var" "$registry" "$prefix" "$slug" "$tag"
    done <<< "$vars"
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

# What: pointer for a channel word, else a checked fixed tag
# Why: the env tag and the .env tag follow one rule
# From: Issue #1683 | PR #1912
lancache_direct_image_tag() {
    local tag="$1" words="$2"
    if [[ -n "$tag" ]] && list_has_line "$tag" "$words"; then
        lancache_stack_pointer_channel_for "$tag"
        return 0
    fi
    case "$tag" in
        sha-*|v[0-9]*)
            validate_lancache_image_tag "$tag"
            printf '%s\n' "$tag"
            return 0
            ;;
    esac
    return 1
}

# What: release tag of this checkout, empty if it has none
# Why: a malformed tag stops; no tag lets the channel decide
# From: Issue #1683 | PR #1912
lancache_release_archive_tag_or_empty() {
    local tag
    if tag=$(derive_release_archive_image_tag); then
        printf '%s\n' "$tag"
    elif [[ "$?" = "2" ]]; then
        die "Cannot derive a valid release image tag from this checkout/archive."
    fi
    true
}

# What: a channel's pointer word or a fixed tag
# Why: channel pins live in LANCACHE_IMAGE_REF_*, tags stay
# From: Issue #1683 | PR #1858
resolve_lancache_image_tag() {
    local env_file="${1:-}" tag="${LANCACHE_IMAGE_TAG:-}" channel="" words pinned

    words=$(lancache_channel_words) || exit $?
    pinned=$(lancache_release_rows pinned) || exit $?
    lancache_direct_image_tag "$tag" "$words" && return 0

    channel="${LANCACHE_IMAGE_CHANNEL:-}"
    if [[ -z "$channel" && -n "$env_file" && -f "$env_file" ]]; then
        channel=$(get_env_var LANCACHE_IMAGE_CHANNEL "$env_file") || exit $?
    fi

    if [[ -n "$channel" ]] && list_has_line "$channel" "$words"; then
        lancache_stack_pointer_channel_for "$channel"
        return 0
    elif [[ -n "$channel" && "$channel" = "$pinned" ]]; then
        if [[ -z "$tag" && -n "$env_file" && -f "$env_file" ]]; then
            tag=$(get_env_var LANCACHE_IMAGE_TAG "$env_file") || exit $?
        fi
        [[ -n "$tag" ]] || tag=$(lancache_release_archive_tag_or_empty) || exit $?
        [[ -n "$tag" ]] \
            || die "LANCACHE_IMAGE_CHANNEL=$pinned requires LANCACHE_IMAGE_TAG to be set to an immutable sha-* or vX.Y.Z tag."
    elif [[ -n "$channel" ]]; then
        validate_lancache_image_channel "$channel"
    fi

    if [[ -z "$tag" && -n "$env_file" && -f "$env_file" ]]; then
        tag=$(get_env_var LANCACHE_IMAGE_TAG "$env_file") || exit $?
    fi
    lancache_direct_image_tag "$tag" "$words" && return 0

    [[ -n "$tag" ]] || tag=$(lancache_release_archive_tag_or_empty) || exit $?
    if [[ -z "$tag" ]]; then
        channel=$(resolve_lancache_image_channel "$env_file") || exit $?
        lancache_stack_pointer_channel_for "$channel"
        return 0
    fi

    validate_lancache_image_tag "$tag"
    printf '%s\n' "$tag"
}

# What: puts the .env snapshot back unless the run finished
# Why: EXIT trap of migrate_env_for_update
# From: Issue #1683 | PR #1912
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

# What: adds missing keys and normalizes legacy .env state
# Why: updates must be idempotent and keep operator secrets
# From: Issue #1683 | PR #1858
migrate_env_for_update() (
    # What: keeps a valid tag when preserve_image_tag is 1
    # Why: restore must not re-resolve a rolled-back tag
    # From: Issue #1683 | PR #1858
    local install_dir="$1" preserve_image_tag="${2:-0}" env_file dhcp_enabled dhcp_mode
    local dhcp_proxy_interface dhcp_proxy_router dhcp_ntp_servers dhcp_proxy_domain
    local dhcp_proxy_boot_filename dhcp_proxy_boot_server _dhcp_ntp_check _dhcp_ntp_ip dhcp_relay_local_addr
    # What: declares every temporary as function-local
    # Why: undeclared names leaked as globals
    # From: Issue #1683 | PR #1858
    local dhcp_proxy_pxe_boot_server dhcp_proxy_pxe_boot_filename_bios dhcp_proxy_pxe_boot_filename_uefi
    local cache_dir cache_max_gb cache_max_size cache_gb cache_mem_mb ip_https ui_password ui_password_hash ui_user
    local compose_profiles dhcp_dns_primary dhcp_dns_secondary dhcp_subnet_start ip_http upstream_dhcp_ip
    local state_keys state_key state_sub state_sub_dir legacy_path
    local state_dir ui_session_ttl
    local legacy_cache_http legacy_cache_https existing_image_tag
    local required_keys required_key required_value
    local -a required_key_list=()
    local lancache_image_registry lancache_image_prefix lancache_image_channel lancache_image_tag
    env_file=$(runtime_env_file_for_install_dir "$install_dir")

    [[ -f "$env_file" ]] \
        || die "Missing $env_file. Cannot update safely because local runtime configuration is not available."

    # What: a failed run puts the original .env back
    # Why: no failed check may leave .env half-written
    # From: Issue #1683 | PR #1858
    migrate_target="$env_file" migrate_done=0 migrate_snapshot_ok=0
    migrate_snapshot=$(mktemp "$(dirname "$env_file")/.$(basename "$env_file").before.XXXXXX") \
        || die "Cannot snapshot $env_file before the update (exit $?)."
    trap migrate_env_restore EXIT
    cp -p -- "$env_file" "$migrate_snapshot" || die "Cannot snapshot $env_file (exit $?)."
    migrate_snapshot_ok=1

    print_step "Checking runtime .env"

    # What: moves IP_STANDARD/IP_SSL to IP_HTTP/IP_HTTPS.
    # Why: older installs still carry the old key names.
    # From: Issue #1683 | PR #1912
    append_env_migrated_assignment_if_missing IP_HTTP IP_STANDARD "" "$env_file"
    append_env_migrated_assignment_if_missing IP_HTTPS IP_SSL "" "$env_file"
    remove_env_key IP_STANDARD "$env_file"
    remove_env_key IP_SSL "$env_file"
    # What: drops the unused NATS DNS replica login.
    # Why: no client uses it; it held DNS publish rights.
    # From: Issue #1683 | PR #1912
    remove_env_key NATS_DNS_REPLICA_USER "$env_file"
    remove_env_key NATS_DNS_REPLICA_PASSWORD "$env_file"
    require_env_value_for_update IP_HTTP "$env_file"
    # What: the second LAN IP must be set before any write
    # Why: prod always runs dns-https on it (AG-SETUP-001)
    # From: Issue #1683 | PR #1858
    require_env_value_for_update IP_HTTPS "$env_file"
    ip_http=$(get_env_var IP_HTTP "$env_file") || exit $?
    ip_https=$(get_env_var IP_HTTPS "$env_file") || exit $?
    require_separate_lan_ips "$ip_http" "$ip_https"

    # What: resolves and checks the image tag first
    # Why: a platform failure leaves other keys untouched
    # From: Issue #1683 | PR #1858
    lancache_image_registry=$(resolve_lancache_image_registry "$env_file") || exit $?
    validate_lancache_image_registry "$lancache_image_registry"
    lancache_image_prefix=$(resolve_lancache_image_prefix "$env_file") || exit $?
    validate_lancache_image_prefix "$lancache_image_prefix"
    lancache_image_channel=$(resolve_lancache_image_channel "$env_file") || exit $?
    existing_image_tag=$(get_env_var LANCACHE_IMAGE_TAG "$env_file") || exit $?
    local lancache_image_refs="" keep_image_refs=0 archived_refs
    archived_refs=$(awk '/^LANCACHE_IMAGE_REF_[A-Z_]+=/' "$env_file") \
        || die "Failed to read the image pins from $env_file (exit $?)."
    local stack_channels
    stack_channels=$(lancache_release_rows channel) || exit $?
    if [[ "$preserve_image_tag" = "1" ]] \
        && { is_commit_image_tag "$existing_image_tag" || is_release_tag "$existing_image_tag"; }; then
        # What: keeps the archived immutable tag as-is
        # Why: re-resolving would pull the bad channel image
        # From: Issue #1683 | PR #1858
        validate_lancache_image_tag "$existing_image_tag"
        lancache_image_tag="$existing_image_tag"
        lancache_image_refs=$(lancache_image_refs_for_tag "$env_file" "$lancache_image_tag") \
            || die "Cannot name the images of ${lancache_image_tag} for ${env_file}; it stays unchanged (exit $?)."
    elif [[ "$preserve_image_tag" = "1" && -n "$existing_image_tag" && -n "$archived_refs" ]] \
        && list_has_line "$existing_image_tag" "$stack_channels"; then
        # What: a restore keeps archived channel pins
        # Why: re-resolving pulls the current stack
        # From: Issue #1683 | PR #1858
        lancache_image_tag="$existing_image_tag"
        keep_image_refs=1
    else
        # What: re-derives the channel from the tag itself
        # Why: no channel write to .env is needed first
        # From: Issue #1683 | PR #1858
        lancache_image_tag=$(resolve_lancache_image_tag "$env_file") || exit $?
        lancache_image_refs=$(lancache_image_refs_for_tag "$env_file" "$lancache_image_tag") \
            || die "Cannot pin the images of ${lancache_image_tag} for ${env_file}; it stays unchanged (exit $?)."
    fi
    # What: a restore skips the registry platform check
    # Why: pins were checked once; a rollback needs no GHCR
    # From: Issue #1683 | PR #1858
    if [[ "$preserve_image_tag" != "1" ]]; then
        assert_resolved_image_tag_platform_supported \
            "$lancache_image_registry" "$lancache_image_prefix" "$lancache_image_tag"
    fi
    set_env_key_if_empty_or_missing LANCACHE_IMAGE_REGISTRY "$lancache_image_registry" "$env_file"
    set_env_key_if_empty_or_missing LANCACHE_IMAGE_PREFIX "$lancache_image_prefix" "$env_file"
    set_env_key_if_empty_or_missing LANCACHE_IMAGE_CHANNEL "$lancache_image_channel" "$env_file"
    set_env_key LANCACHE_IMAGE_TAG "$lancache_image_tag" "$env_file"
    [[ "$keep_image_refs" = "1" ]] || write_lancache_image_refs "$env_file" "$lancache_image_refs"
    adopt_moved_config_prod_keys "$install_dir" "$env_file" copy
    # What: moves SSL_ENABLED to HTTPS_ENABLED.
    # Why: old installs and config/prod keep the old key.
    # From: Issue #1683 | PR #1912
    append_env_migrated_assignment_if_missing HTTPS_ENABLED SSL_ENABLED "" "$env_file"
    remove_env_key SSL_ENABLED "$env_file"

    # What: validates an operator TTL; default is the SOT
    # Why: .env.local never repeats a runtime.defaults value
    # From: Issue #1683 | PR #1912
    ui_session_ttl=$(get_env_var UI_SESSION_TTL_SECONDS "$env_file") || exit $?
    [[ -z "$ui_session_ttl" ]] || validate_ui_session_ttl_seconds "$ui_session_ttl" "$env_file"

    # What: an install without the key gets auto-update off
    # Why: the user never agreed; a SOT change must not
    # From: Issue #1683 | PR #1912
    set_env_key_if_empty_or_missing AUTO_UPDATE_ENABLED "0" "$env_file"

    state_dir=$(install_state_root "$install_dir" "$env_file") \
        || die "Cannot resolve the state root of $install_dir (exit $?)."
    set_env_key_if_empty_or_missing LANCACHE_STATE_DIR "$state_dir" "$env_file"

    # What: CACHE_DIR is the canonical cache path
    # Why: legacy split cache keys must collapse into it
    # From: Issue #1683 | PR #1858
    cache_dir=$(get_env_var CACHE_DIR "$env_file") || exit $?
    legacy_cache_http=$(get_env_var CACHE_DIR_STANDARD "$env_file") || exit $?
    legacy_cache_https=$(get_env_var CACHE_DIR_SSL "$env_file") || exit $?
    if [[ -z "$cache_dir" ]]; then
        if [[ -n "$legacy_cache_http" && -n "$legacy_cache_https" && "$legacy_cache_http" != "$legacy_cache_https" ]]; then
            die "CACHE_DIR_STANDARD and CACHE_DIR_SSL point to different paths in $env_file. Set CACHE_DIR to one shared cache directory before rerunning setup.sh update. The update will not keep two cache directories."
        fi

        cache_dir="${legacy_cache_http:-$legacy_cache_https}"
    fi
    [[ -n "$cache_dir" ]] || cache_dir=$(legacy_dir_or_default "$(legacy_state_path cache)" "$state_dir/cache")
    set_env_key CACHE_DIR "$cache_dir" "$env_file"
    remove_env_key CACHE_DIR_STANDARD "$env_file"
    remove_env_key CACHE_DIR_SSL "$env_file"

    # What: moves PDNS_STANDARD_DIR to PDNS_DIR, data stays
    # Why: moving the key must not move the zone data.
    # From: Issue #1683 | PR #1912
    append_env_migrated_assignment_if_missing PDNS_DIR PDNS_STANDARD_DIR "" "$env_file"
    remove_env_key PDNS_STANDARD_DIR "$env_file"
    if [[ -z "$(get_env_var_nonempty PDNS_DIR "$env_file")" && -d "$state_dir/pdns-standard" && ! -d "$state_dir/pdns" ]]; then
        set_env_key PDNS_DIR "$state_dir/pdns-standard" "$env_file"
    fi

    # What: derives state dirs from the legacy root
    # Why: one state contract for update and upgrades
    # From: Issue #1683 | PR #1858
    state_keys=$(prod_state_keys) || die "Cannot list the state keys of the SOT (exit $?)."
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
    # What: the checkout CA becomes the CA state dir
    # Why: the old compose mounted ../../certs
    # From: Issue #1683 | PR #1912
    migrate_legacy_ca "$install_dir/../../certs" "$env_file"

    # What: a user cache size fills its missing partner key
    # Why: no size set means the SOT default; none is copied
    # From: Issue #1683 | PR #1912
    cache_max_size=$(get_env_var_nonempty CACHE_MAX_SIZE "$env_file") || exit $?
    cache_max_gb=$(get_env_var_nonempty CACHE_MAX_GB "$env_file") || exit $?
    if cache_gb=$(cache_size_gb_from_env "${cache_max_size:-$cache_max_gb}"); then
        set_env_key_if_empty_or_missing CACHE_MAX_SIZE "${cache_gb}g" "$env_file"
        set_env_key_if_empty_or_missing CACHE_MAX_GB "$cache_gb" "$env_file"
    fi
    # What: a broken CACHE_MEM_MB is removed, not replaced
    # Why: the image then takes the SOT default itself
    # From: Issue #1683 | PR #1912
    cache_mem_mb=$(get_env_var CACHE_MEM_MB "$env_file") || exit $?
    if [[ -n "$cache_mem_mb" ]] && ! is_positive_integer "$cache_mem_mb"; then
        remove_env_key CACHE_MEM_MB "$env_file"
        print_warn "CACHE_MEM_MB '$cache_mem_mb' is no positive integer; removed, the build-manifest.yml default applies"
    fi
    migrate_proxy_security_mode_for_update "$env_file"
    # What: image keys were resolved at the top
    # Why: the platform check runs before migration writes
    # From: Issue #1683 | PR #1858

    ip_http=$(get_env_var IP_HTTP "$env_file") || die "Cannot read IP_HTTP from $env_file (exit $?)."
    append_env_migrated_assignment_if_missing UI_BIND_IP IP_HTTP "$ip_http" "$env_file"

    # What: drops the retired global logging switch
    # Why: the Admin UI holds one switch per service
    # From: Issue #1683 | PR #1912
    remove_env_key LOGGING_ENABLED "$env_file"

    compose_profiles=$(get_env_var COMPOSE_PROFILES "$env_file") || exit $?
    dhcp_enabled=$(get_env_var DHCP_ENABLED "$env_file") || exit $?
    dhcp_mode=$(get_env_var DHCP_MODE "$env_file") || exit $?
    dhcp_mode=${dhcp_mode:-${DHCP_MODE:-}}
    # What: 1.x "1", profiles or DHCP_ENABLED give the mode
    # Why: an empty or unknown value must still converge
    # From: Issue #1683 | PR #1912
    if [[ "${dhcp_mode}" = "1" ]]; then
        dhcp_mode=kea
    elif ! is_valid_dhcp_mode "$dhcp_mode"; then
        if [[ ",$compose_profiles," = *,dhcp-proxy,* ]]; then
            dhcp_mode="dnsmasq-proxy"
        elif [[ ",$compose_profiles," = *,dhcp-kea,* || "$dhcp_enabled" = "1" ]]; then
            dhcp_mode="kea"
        else
            dhcp_mode="disabled"
        fi
    fi

    set_env_key DHCP_MODE "$dhcp_mode" "$env_file"
    # What: drops the 1.x Kea switch after it was read
    # Why: DHCP_MODE owns the choice; nothing reads the key
    # From: Issue #1683 | PR #1912
    remove_env_key DHCP_ENABLED "$env_file"
    dhcp_subnet_start=$(get_env_var DHCP_SUBNET_START "$env_file") || exit $?
    dhcp_dns_primary=$(get_env_var DHCP_DNS_PRIMARY "$env_file") || exit $?
    dhcp_dns_secondary=$(get_env_var DHCP_DNS_SECONDARY "$env_file") || exit $?
    upstream_dhcp_ip=$(get_env_var UPSTREAM_DHCP_IP "$env_file") || exit $?
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
            # What: an empty primary/secondary stays empty
            # Why: config.rs owns the rule for empty
            # From: Issue #1683 | PR #1912
            [[ -z "$dhcp_dns_primary" ]] || is_valid_ipv4 "$dhcp_dns_primary" \
                || die "DHCP_MODE=dnsmasq-proxy has invalid DHCP_DNS_PRIMARY in $env_file. Set a valid IPv4 address or leave it empty (the services then use IP_HTTP)."
            [[ -z "$dhcp_dns_secondary" ]] || is_valid_ipv4 "$dhcp_dns_secondary" \
                || die "DHCP_MODE=dnsmasq-proxy has invalid DHCP_DNS_SECONDARY in $env_file. Set a valid IPv4 address or leave it empty (the services then use IP_HTTPS)."
            is_valid_ipv4 "$upstream_dhcp_ip" \
                || die "DHCP_MODE=dnsmasq-proxy requires the real router DHCP IP in UPSTREAM_DHCP_IP in $env_file. Set it, then rerun setup.sh update."
            # What: optional fields are checked when set
            # Why: empty means the option is not used
            # From: Issue #1683 | PR #1858
            [[ -z "$dhcp_proxy_interface" ]] || is_valid_dhcp_proxy_interface "$dhcp_proxy_interface" \
                || die "DHCP_PROXY_INTERFACE in $env_file must be a valid interface name (letters, digits, '.', '-', '_') or empty."
            [[ -z "$dhcp_proxy_router" ]] || is_valid_ipv4 "$dhcp_proxy_router" \
                || die "DHCP_PROXY_ROUTER in $env_file must be a valid IPv4 address or empty."
            if [[ -n "$dhcp_ntp_servers" ]]; then
                IFS=',' read -r -a _dhcp_ntp_check <<< "$dhcp_ntp_servers"
                for _dhcp_ntp_ip in "${_dhcp_ntp_check[@]}"; do
                    _dhcp_ntp_ip="${_dhcp_ntp_ip//[[:space:]]/}"
                    [[ -z "$_dhcp_ntp_ip" ]] || is_valid_dhcp_ntp_server "$_dhcp_ntp_ip" \
                        || die "DHCP_NTP_SERVERS in $env_file must be a comma-separated list of IPv4 addresses or host names."
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
            # From: Issue #1683 | PR #1858
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
            # From: Issue #1683 | PR #1858
            is_valid_ipv4 "$dhcp_relay_local_addr" \
                || die "DHCP_MODE=dnsmasq-relay requires DHCP_RELAY_LOCAL_ADDR (this relay's own IPv4 on the client network) in $env_file. Set it, then rerun setup.sh update."
            is_valid_ipv4 "$upstream_dhcp_ip" \
                || die "DHCP_MODE=dnsmasq-relay requires the upstream DHCP server IPv4 in UPSTREAM_DHCP_IP in $env_file. Set it, then rerun setup.sh update."
            ;;
        *)
            is_valid_ipv4 "$dhcp_subnet_start" || dhcp_subnet_start=""
            is_valid_ipv4 "$dhcp_dns_primary" || dhcp_dns_primary=""
            is_valid_ipv4 "$dhcp_dns_secondary" || dhcp_dns_secondary=""
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

    # What: generates empty or placeholder SOT secrets
    # Why: real operator values are preserved
    # From: Issue #1683 | PR #1858
    secret_rows=$(managed_secret_rows stack) || exit $?
    while read -r secret_key secret_kind; do
        ensure_secret_env_key "$secret_key" "$env_file" "$secret_kind"
    done <<< "$secret_rows"

    # What: strips retired project profiles from the env
    # Why: an old install still lists dhcp-kea, ntp, logging
    # From: Issue #1683 | PR #1912
    if env_key_exists COMPOSE_PROFILES "$env_file"; then
        set_env_key COMPOSE_PROFILES "$(compose_profiles_for_runtime "$compose_profiles")" "$env_file"
    fi

    # What: UI auth is user-chosen; user needs a password
    # Why: unset user and password mean insecure UI
    # From: Issue #1683 | PR #1858
    append_env_key_if_missing UI_AUTH_USER "" "$env_file"
    append_env_key_if_missing UI_AUTH_PASSWORD_HASH "" "$env_file"
    ui_user=$(get_env_var UI_AUTH_USER "$env_file") || exit $?
    ui_password=$(get_env_var UI_AUTH_PASSWORD "$env_file") || exit $?
    ui_password_hash=$(get_env_var UI_AUTH_PASSWORD_HASH "$env_file") || exit $?

    # What: an install without UI login keeps running open
    # Why: it ran so before; others take the SOT value
    # From: Issue #1683 | PR #1912
    if [[ -z "$ui_user" && -z "$ui_password" && -z "$ui_password_hash" ]]; then
        append_env_key_if_missing ALLOW_INSECURE_UI true "$env_file"
    fi

    # What: every SOT-required key holds a value by now
    # Why: an empty required key breaks the stack at up
    # From: Issue #1683 | PR #1912
    required_keys=$(lancache_sot_value setup_required_repairs validation) || exit $?
    read -ra required_key_list <<< "${required_keys//$'\n'/ }"
    for required_key in "${required_key_list[@]}"; do
        required_value=$(get_env_var "$required_key" "$env_file") || exit $?
        [[ -n "$required_value" ]] \
            || die "Required key $required_key is still empty in $env_file after the update."
    done

    print_ok ".env is complete for the current deploy/prod template"
    migrate_done=1
    adopt_moved_config_prod_keys "$install_dir" "$env_file" drop
)

# What: maps a tool to its apt or apk package name
# Why: dig ships in bind9-dnsutils, dnsutils or bind-tools
# From: Issue #1683 | PR #1858
package_name_for_tool() {
    local manager
    manager=$(host_package_manager)
    case "$manager:$1" in
        apk:dig) printf 'bind-tools\n' ;;
        apk:ss|apk:ip) printf 'iproute2\n' ;;
        *:dig)
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

# What: installs only the missing tools for an operation
# Why: keeps minimal hosts able to back up and restore
# From: Issue #1683 | PR #1858
install_missing_tools() {
    local -a missing=() packages=() tools=("$@")
    local tool package manager
    for tool in "${tools[@]}"; do
        command_available "$tool" || missing+=("$tool")
    done
    (( ${#missing[@]} == 0 )) && return 0
    print_warn "Missing required tool(s): ${missing[*]} — installing now..."
    manager=$(host_package_manager)
    case "$manager" in
        apt-get|apk) ;;
        *) die "Cannot install missing tools automatically; install: ${missing[*]}" ;;
    esac
    for tool in "${missing[@]}"; do
        package=$(package_name_for_tool "$tool") || die "Cannot resolve the package of $tool (exit $?)."
        packages+=("$package")
    done
    if [[ "$manager" = apk ]]; then
        apk_install "${packages[@]}" || die "Failed to install required tool(s): ${missing[*]}"
    else
        apt-get update -y || die "apt-get update failed (exit $?); nothing was installed."
        apt_install "${packages[@]}" || die "Failed to install required tool(s): ${missing[*]}"
    fi
    for tool in "${missing[@]}"; do
        command_available "$tool" \
            || die "$tool is still missing after installing package(s): ${packages[*]}"
    done
}

# What: lists the paths a config or full backup includes
# Why: existing state dirs; cache only in full mode
# From: Issue #1683 | PR #1858
backup_manifest() {
    local install_dir="$1" mode="$2"
    local env_file="" cache_env_file="" state_dir=""
    local cache_dir keys key dir sub bundle copy
    stack_env_context "$install_dir" env_file cache_env_file state_dir
    cache_dir=$(get_env_var CACHE_DIR "$env_file") || exit $?
    cache_dir="${cache_dir:-$state_dir/cache}"

    printf '%s\n' "$cache_env_file"
    [[ "$env_file" != "$cache_env_file" ]] && printf '%s\n' "$env_file"
    printf '%s\n' "$install_dir/docker-compose.yml"
    # What: quickstart helper copies from the SOT list
    # Why: restore brings back what a quickstart had
    # From: Issue #1683 | PR #1912
    bundle=$(lancache_sot_list quickstart_bundle_copies runtime) || exit $?
    while IFS= read -r copy; do
        [[ -n "$copy" ]] && printf '%s\n' "$install_dir/$copy"
    done <<< "$bundle"
    deploy_prod_repo_input_paths "$install_dir"
    # What: every compose state dir but cache and logs
    # Why: cache: full mode only; logs are no rollback state
    # From: Issue #1683 | PR #1858
    keys=$(prod_state_keys) || die "Cannot list the state keys of the SOT (exit $?)."
    while IFS= read -r key; do
        case "$key" in CACHE_DIR|SYSLOG_NG_LOG_DIR) continue ;; esac
        dir=$(prod_state_dir_for_key "$key" "$env_file" "$state_dir") \
            || die "Cannot resolve the directory of $key (exit $?)."
        [[ -d "$dir" ]] && printf '%s\n' "$dir"
        sub=$(prod_state_subdir "$key") || die "Cannot read the default directory of $key (exit $?)."
        [[ -d "$(legacy_state_path "$sub")" ]] && printf '%s\n' "$(legacy_state_path "$sub")"
    done <<< "$keys"
    if [[ "$mode" = "full" ]]; then
        [[ -d "$cache_dir" ]] && printf '%s\n' "$cache_dir"
        [[ -d "$(legacy_state_path cache)" ]] && printf '%s\n' "$(legacy_state_path cache)"
    fi
    true
}

# What: true if child path is inside parent path
# Why: recursive backups can fill disks and corrupt restores
# From: Issue #1683 | PR #1858
path_is_inside() {
    local child="$1" parent="$2"
    child=$(realpath -m "$child")
    parent=$(realpath -m "$parent")
    [[ "$child" = "$parent" || "$child" = "$parent"/* ]]
}

# What: fails with a secondary-directory hint
# Why: a secondary stack lives outside the install dir
# From: Issue #1683 | PR #1858
die_no_stack_found() {
    local install_dir="$1"
    die "No stack found in ${install_dir}. If this is a fresh primary install, run ./setup.sh install. If this is a secondary DNS node, run this command from its own directory instead (the one named after --name when it was registered via ./setup.sh secondary), or pass that directory explicitly, e.g.: ./setup.sh <command> /path/to/that-directory"
}

# What: prints the stack's env file; dies when it is absent
# Why: the DNS reset and the Kea reset share one error text
# From: Issue #1683 | PR #1858
require_stack_env_file() {
    local install_dir="$1" env_file
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die_no_stack_found "$install_dir"
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    [[ -f "$env_file" ]] || die "No .env found for $install_dir (expected $env_file)."
    printf '%s\n' "$env_file"
}

# What: compose helpers return early without a stack
# Why: backup and restore must handle damaged installs
# From: Issue #1683 | PR #1858
compose_stack_available() {
    local install_dir="$1"
    [[ -f "$install_dir/docker-compose.yml" ]] && command_available docker
}

# What: compose_stack_available, else prints a SKIP line
# Why: a skipped step must say that it was skipped and why
# From: Issue #1683 | PR #1858
compose_stack_or_skip() {
    local install_dir="$1" action="$2"
    compose_stack_available "$install_dir" && return 0
    print_skip "$action: no docker-compose.yml or no docker for $install_dir"
    return 1
}

# What: true if any compose container is running
# Why: restore only restarts a stack that was running
# From: Issue #1683 | PR #1858
compose_stack_running() {
    local install_dir="$1" env_file out
    compose_stack_available "$install_dir" || return 1
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    out=$(stack_compose "$install_dir" "$env_file" ps -q) \
        || die "Failed to list the containers of $install_dir (exit $?)."
    [[ -n "$out" ]]
}

# What: stops the stack; a failed stop aborts the copy
# Why: files of a running stack can be torn mid-copy
# From: Issue #1683 | PR #1858
compose_stack_stop() {
    local install_dir="$1"
    local env_file
    compose_stack_or_skip "$install_dir" "Stopping the stack" || return 0
    print_step "Stopping stack for consistent backup/restore"
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    stack_compose "$install_dir" "$env_file" stop \
        || die "Failed to stop the stack in $install_dir (exit $?); nothing was copied."
}

# What: starts the stack for backup or restore cleanup
# Why: a start failure only warns, so cleanup finishes
# From: Issue #1683 | PR #1858
compose_stack_start() {
    local install_dir="$1"
    local env_file
    compose_stack_or_skip "$install_dir" "Starting the stack" || return 0
    print_step "Starting stack"
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    stack_compose "$install_dir" "$env_file" up -d \
        || print_warn "docker compose up failed (exit $?); start it with: $SCRIPT_DIR/setup.sh compose $install_dir up -d"
}

# What: notes whether the stack ran, then stops it
# Why: the caller's cleanup trap reads the flags set here
# From: Issue #1683 | PR #1858
stop_stack_noting_state() {
    local install_dir="$1"
    compose_stack_running "$install_dir" && stack_was_running=1
    stack_stopped=1
    compose_stack_stop "$install_dir"
}

# What: runs docker compose config as a dry-run check
# Why: catches invalid config before containers restart
# From: Issue #1683 | PR #1858
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
# From: Issue #1683 | PR #1858
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
        name="${compose_name_lines%%$'\n'*}"
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
# From: Issue #1683 | PR #1858
compose_volume_names() {
    local install_dir="$1" container env_file project containers mounts volumes names=""
    compose_stack_or_skip "$install_dir" "Listing the Docker volumes" || return 0
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
# From: Issue #456 | PR #1673
compose_project_has_named_volumes() {
    local project="$1"
    local volume_names
    # What: captures the volume listing before testing it
    # Why: a live pipe can SIGPIPE under pipefail
    # From: Issue #1683 | PR #1858
    volume_names="$(docker volume ls --filter "label=com.docker.compose.project=${project}" --format '{{.Name}}')" \
        || die "Failed to list the volumes of compose project $project (exit $?)."
    [[ -n "$volume_names" ]]
}

# What: runs a tar script on one volume in the helper image
# Why: backup and restore share the mounts and the call
# From: Issue #1683 | PR #1858
helper_volume_tar() {
    local volume="$1" root="$2" volume_mode="$3" backup_mode="$4" script="$5"
    docker run --rm \
        -v "${volume}:/volume${volume_mode}" \
        -v "${root}:/backup${backup_mode}" \
        "$LANCACHE_HELPER_IMAGE" sh -c "$script" sh "$volume"
}

# What: archives named volumes; cache volume only in full
# Why: cache payloads can be huge; config backups skip them
# From: Issue #1683 | PR #1858
backup_compose_volumes() {
    local install_dir="$1" volume_root="$2" mode="$3" volume env_file cache_volume volumes
    compose_stack_or_skip "$install_dir" "Archiving the Docker volumes" || return 0
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
        helper_volume_tar "$volume" "$volume_root" ":ro" "" "cd /volume && tar -cpf \"/backup/\$1.tar\" ." \
            || die "Failed to archive Docker volume $volume (exit $?)."
    done <<< "$volumes"
}

# What: wipes each volume and replaces it from its archive
# Why: skipping would restore an incomplete stack
# From: Issue #1683 | PR #1858
restore_compose_volumes() {
    local install_dir="$1" volume_root="$2" volume archive archives
    if [[ ! -d "$volume_root" ]]; then
        print_skip "Restoring Docker volumes: the backup holds no docker-volumes directory"
        return 0
    fi
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
        docker volume create "$volume" \
            || die "Failed to create Docker volume $volume (exit $?)."
        helper_volume_tar "$volume" "$volume_root" "" ":ro" "set -e; tar -tf \"/backup/\$1.tar\"; rm -rf /volume/* /volume/..?* /volume/.[!.]*; cd /volume; tar -xpf \"/backup/\$1.tar\"" \
            || die "Failed to restore Docker volume $volume from $archive (exit $?). Rerun the restore; the archive is unchanged."
    done <<< "$archives"
}

# What: true when both stack dirs are in the channel layout
# Why: <state root>, latest and nightly hold one install
# From: Issue #1683 | PR #1858
is_same_channel_install() {
    local a="$1" b="$2"
    [[ "$a" = */deploy/prod && "$b" = */deploy/prod ]] || return 1
    is_channel_layout_repo "${a%/deploy/prod}" && is_channel_layout_repo "${b%/deploy/prod}"
}

# What: blocks restore if other installs share the volumes
# Why: project name is fixed, so volumes are shared
# From: Issue #456 | PR #1673
guard_restore_shared_project_volumes() {
    local install_dir="$1" archived_install_dir="$2" project="$3" container working_dir containers
    if ! command_available docker; then
        print_skip "Shared-volume guard: docker is not available, so no containers can share the volumes"
        return 0
    fi
    containers=$(docker ps -a --filter "label=com.docker.compose.project=${project}" --format '{{.ID}}') \
        || die "Failed to list the containers of compose project $project (exit $?)."
    while IFS= read -r container; do
        [[ -n "$container" ]] || continue
        working_dir=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container") \
            || die "Failed to read the working directory label of container $container (exit $?)."
        [[ -n "$working_dir" ]] \
            || die "Refusing to restore: container $container of compose project '$project' has no working directory label, so its install cannot be attributed. Remove it with 'docker rm $container', then restore again."
        working_dir=$(realpath -m "$working_dir")
        # What: root, latest and nightly are one install
        # Why: their stack and data are one; a label may lag
        # From: Issue #1683 | PR #1858
        is_same_channel_install "$working_dir" "$install_dir" && continue
        if [[ "$working_dir" != "$install_dir" ]]; then
            die "Refusing to restore: compose project '$project' still has containers at $working_dir, which is not the restore target ($install_dir). Both installs share the same Docker-managed volumes because the compose project name is not per-install-dir. Remove the other install's containers first (cd \"$working_dir\" && docker compose down), or restore into $working_dir instead."
        fi
    done <<< "$containers"
    if [[ "$install_dir" != "$archived_install_dir" ]] && compose_project_has_named_volumes "$project"; then
        die "Refusing to restore: compose project '$project' still has named Docker volumes on this host, but the backup is being restored into a different install directory ($install_dir instead of $archived_install_dir). After docker compose down, Docker keeps the project label on the volumes but no longer retains a reliable install-dir owner marker, so same-host cross-directory restore would be ownership-ambiguous. Restore into $archived_install_dir instead, or remove the existing '$project' volumes first if they are no longer needed."
    fi
}

# What: records image digests as a rollback reference
# Why: informational only; failures warn, never restore
# From: Issue #1683 | PR #1858
record_image_revisions() {
    local install_dir="$1" output="$2" env_file revisions
    compose_stack_or_skip "$install_dir" "Recording the image revisions" || return 0
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
    local ext="$1" archive="$2" parent="$3" entry="$4" rows
    local -a row compressor=()
    rows=$(lancache_sot_list archive_compressors runtime) || exit $?
    while read -r -a row; do
        [[ "${row[0]}" != "$ext" ]] || compressor=("${row[@]:1}")
    done <<< "$rows"
    [[ ${#compressor[@]} -gt 0 ]] || die "No compressor for .$ext archives in runtime.archive_compressors."
    tar -C "$parent" -cf - "$entry" | "${compressor[@]}" > "$archive"
}

# What: config or full backup; the body is a subshell
# Why: its EXIT trap reads the state; nothing leaks out
# From: Issue #1683 | PR #1858
cmd_backup() (
    mode="config"
    backup_root="$BACKUP_ROOT"
    ensure_default_install_dir
    install_dir="$DEFAULT_INSTALL_DIR"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full) mode="full"; shift ;;
            --config) mode="config"; shift ;;
            --dest) require_value "$1" "${2:-}"; backup_root="$2"; shift 2 ;;
            *) install_dir="$1"; shift ;;
        esac
    done
    install_dir=$(resolve_stack_dir_checked "$install_dir") || exit $?
    backup_root=$(realpath -m "$backup_root")
    [[ -f "$(runtime_env_file_for_install_dir "$install_dir")" ]] \
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
    # From: Issue #1683 | PR #1858
    if [[ "${UPDATE_CONVERGENCE_PAUSED:-0}" != "1" ]]; then
        # What: sets the cleanup flag before the pause call
        # Why: a die inside pause still triggers the resume
        # From: Issue #1683 | PR #1858
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
    # What: records whether the stack was running
    # Why: cleanup restarts only a stack that was running
    # From: Issue #1683 | PR #1858
    stop_stack_noting_state "$install_dir"

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
# From: Issue #1683 | PR #1858
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
    ensure_default_install_dir
    install_dir="${2:-$DEFAULT_INSTALL_DIR}"
    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?
    [[ -n "$archive" ]] || die "Usage: $0 restore <backup.tar.gz> [install-dir]"
    [[ -f "$archive" ]] || die "Backup archive not found: $archive"
    # What: requires openssl for the convergence step
    # Why: fails before restore mutations on minimal hosts
    # From: Issue #1683 | PR #1858
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
                # From: Issue #1683 | PR #1858
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
    ensure_default_install_dir
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
    # From: Issue #1683 | PR #1858
    archived_project=$(compose_project_name "$root/$rel_install" "$(runtime_env_file_for_install_dir "$root/$rel_install")") \
        || exit $?
    guard_restore_shared_project_volumes "$install_dir" "$archived_install" "$archived_project"

    # What: records whether the stack was running
    # Why: restore restarts only a stack that was running
    # From: Issue #1683 | PR #1858
    stop_stack_noting_state "$install_dir"

    print_step "Restoring backup"
    if [[ -d "$root/$rel_install" ]]; then
        mkdir -p "$install_dir" || die "Failed to create $install_dir (exit $?)."
        rsync -aH --numeric-ids "$root/$rel_install/" "$install_dir/" \
            || die "Failed to restore $install_dir (exit $?)."
        # What: moves a stale .env.local aside first
        # Why: the rewrite must not treat it as archived
        # From: Issue #1683 | PR #1858
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
    # From: Issue #1683 | PR #1858
    if ! (
        # What: each step's failure ends the subshell
        # Why: no errexit inside "if !"; failures went on
        # From: Issue #1683 | PR #1858
        migrate_env_for_update "$install_dir" 1 || exit $?
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

# What: keeps the top-level usage text compact
# Why: per-command detail lives in its own help block
# From: Issue #1683 | PR #1858
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
                       Change the configured HTTP and HTTPS listener IPs.
                       Default dir: ${DEFAULT_INSTALL_DIR}
  configure-upstream-dns [install-dir]
                       Show, set, change or remove the external DNS server
                       for names LanCache-NG does not know.
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

# What: prints one subcommand's usage; returns 1 if none
# Why: the dispatcher then reports the unknown command
# From: Issue #1683 | PR #1912
print_command_help() {
    local command="$1"

    case "$command" in
        install)
            cat <<EOF
Usage: ./setup.sh install

Runs the guided LanCache-NG installer. setup.sh does nothing without a
command, so the curl | bash one-liner passes it: ... | sudo bash -s -- install

When no local repo is found (the standalone curl | bash path), this command
self-clones to ${DEFAULT_INSTALL_DIR} from the remote's default branch by
default. Set LANCACHE_SETUP_GIT_REF to a branch, tag, or commit-ish (e.g.
LANCACHE_SETUP_GIT_REF=vX.Y.Z) to bootstrap from that ref instead -- useful
for validating a pre-release branch the same documented one-liner way that
LANCACHE_IMAGE_CHANNEL already selects a specific image channel.
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

Introspection mode: walks the install wizard's real,
current branch logic (the exact same code ./setup.sh install runs) and
prints the ordered prompt sequence it would ask, one per line, as
"PROMPT<TAB>text<TAB>default". Never touches the filesystem, network, or
Docker -- no root required.

[answers-file] is optional: a plain text file with one reply per line, in
the order prompts are expected to be asked. A blank line (or running out of
lines) falls back to that prompt's own default, the same as an operator
pressing Enter. Omitting the file entirely walks the all-defaults path.

Intended consumer: docs/release-validation-plan.md reads the real prompt
sequence from this output instead of hand-encoding it, so a new prompt
cannot silently drift out of sync with the validated install.
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

Scheduled entry point, normally invoked by the lancache-auto-update
systemd timer or OpenRC service, not run directly by an operator. Does nothing unless
AUTO_UPDATE_ENABLED=1 in .env AND the resolved release channel has actually
moved to a new image set since the last update -- an unchanged channel is a
silent no-op, not a full pull-and-restart. When it does act, it runs the
exact same ordered, health-gated update as ./setup.sh update. If
[install-dir] is omitted, ${DEFAULT_INSTALL_DIR} is used.
EOF
            ;;
        update-ip)
            cat <<EOF
Usage: ./setup.sh update-ip [install-dir]

Interactively changes the HTTP and HTTPS listener IP addresses for an
existing installation. The stack then restarts through the same health-gated
steps as ./setup.sh update; if it does not become healthy, the previous IPs
are restored. If [install-dir] is omitted, ${DEFAULT_INSTALL_DIR} is used.

Compatibility: ./setup.sh --reconfigure still works and runs this command.
EOF
            ;;
        configure-upstream-dns)
            cat <<EOF
Usage: ./setup.sh configure-upstream-dns [install-dir]

Shows the external DNS setting of an existing primary installation and lets
you set, change or remove it. It also asks whether LanCache-NG answers
reverse lookups (PTR) of private networks itself; with Kea as DHCP server
this stays on. The answers are checked while you type. The
stack then restarts through the same health-gated steps as ./setup.sh update;
if it does not become healthy, the previous setting is restored. If
[install-dir] is omitted, ${DEFAULT_INSTALL_DIR} is used.
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
Usage: ./setup.sh secondary --primary <url> --token <token> --name <name> --ip-http <ip> [--listen-ip <ip>] [--ip-https <ip> --listen-ip-https <ip>] [--rotate]

Registers and starts a secondary DNS node on a remote host. The command
creates a local compose directory, writes the secondary .env file, and starts
the container after the primary server returns the required secrets.
Use --rotate in an existing secondary directory to refresh credentials after
the primary changes its NATS authentication model.

Required arguments:
  --primary <url>    Primary LanCache UI/API URL, for example http://<primary-ip>:<ui-port>
  --token <token>    Secondary registration token from the primary server
  --name <name>      Secondary node name, using letters, numbers, and dashes only
  --ip-http <ip>     Primary proxy IP address clients should use for cached traffic

Optional arguments:
  --listen-ip <ip>   Bind IP for the secondary DNS container (default: detected host LAN IP)
  --ip-https <ip>    Primary https proxy IP; adds a second DNS bind (needs --listen-ip-https)
  --listen-ip-https <ip>  Second bind IP for the https DNS (needs --ip-https; differs from --listen-ip)
  --rotate           Reuse an existing secondary directory and refresh credentials
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
control surface still is. Automates the exact by-hand recovery
sequence docs/known-good-config-snapshots.md's "Manual recovery" section
documents: list this install's known-good config snapshots for <service> and
apply one -- the given [snapshot-id], or the newest after an explicit
confirmation if omitted -- via that service's own real validate/apply/persist
API, the same sequence the Admin UI's own per-service rollback pages already
run when they ARE reachable.

Supported services:
  kea, dhcp          Rolls back Kea's DHCP config via its Control Agent API
                     (config-test -> config-set -> config-write), reading
                     snapshots from KEA_CONFIG_SNAPSHOT_DIR in the
                     KEA_DATA_DIR state dir.
  dns, pdns          Rolls back a PowerDNS zone's record data via
                     nats-subscriber's rollback listener (list snapshots ->
                     diff -> PATCH -> check-zone -> flush -> re-publish),
                     reached by execing curl inside the target container
                     (its port is Compose-internal only, never published to
                     the host). The dns container runs the one listener.
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
            return 1
            ;;
    esac
}

# What: plain globals hold the current update flow state
# Why: nested namerefs are fragile; no concurrent updates
# From: Issue #1683 | PR #1858
_UPDATE_ENV_FILE=""
_UPDATE_STACK_DIR=""
# What: per-service health baseline, filled before update
# Why: gate fails only on healthy-to-unhealthy regressions
# From: Issue #1683 | PR #1858
declare -gA _UPDATE_HEALTH_BASELINE=()

# What: container-id lookup for the update project
# Why: one shared lookup keeps the -a semantics
# From: Issue #1683 | PR #1858
service_container_id() {
    local service="$1"
    stack_compose "$_UPDATE_STACK_DIR" "$_UPDATE_ENV_FILE" ps -a -q "$service" || {
        print_error "Failed to look up the container of service $service (exit $?)."
        return 1
    }
}

# What: probes health; one-shot containers pass on exit 0
# Why: running state never holds for one-shot services
# From: Issue #1683 | PR #1858
service_container_is_healthy() {
    local service="$1"
    local container_id health status restart_policy exit_code

    # What: lookup includes stopped containers
    # Why: an exited one-shot service must still be found
    # From: Issue #1683 | PR #1858
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
# From: Issue #1683 | PR #1858
require_functional_check_tool() {
    local tool="$1" probe_description="$2"
    if ! command_available "$tool"; then
        print_error "Functional check failed: $probe_description requires '$tool', which is not installed"
        return 1
    fi
    return 0
}

# What: three-step check: TCP, port binding, loopback
# Why: one curl call conflates ports and ACL source IPs
# From: Issue #1683 | PR #1858

# What: bare TCP connect to ip:port, no HTTP request sent
# Why: reachability alone, apart from the /healthz answer
# From: Issue #1683 | PR #1858
_tcp_port_reachable() {
    local ip="$1" port="$2" err rc=0
    err=$(timeout 5 bash -c "exec 3<>\"/dev/tcp/\$1/\$2\"" _ "$ip" "$port" 2>&1) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf 'TCP connect to %s:%s failed (exit %s): %s\n' "$ip" "$port" "$rc" "$err" >&2
        return 1
    fi
}

# What: true if docker port lists the given host binding
# Why: the binding must belong to this proxy container
# From: Issue #1683 | PR #1858
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

# What: the health path of the SOT PROXY_HEALTH_URL
# Why: host probes use the one SOT path, not a literal
# From: Issue #1683 | PR #1858
proxy_health_path() {
    local url rest
    url=$(prod_env_default PROXY_HEALTH_URL) || exit $?
    rest="${url#*://}"
    printf '/%s\n' "${rest#*/}"
}

# What: checks port, proxy binding and /healthz of one IP
# Why: an open port may belong to another container
# From: Issue #849
_verify_healthz_endpoint() {
    local ip="$1" proxy_container_id port

    port=$(prod_env_default PROXY_HTTP_PORT) || exit $?
    if ! _tcp_port_reachable "$ip" "$port"; then
        print_error "Functional check failed: TCP connect to ${ip}:${port}"
        return 1
    fi

    proxy_container_id=$(service_container_id proxy) || exit $?
    if [[ -z "$proxy_container_id" ]]; then
        print_error "Functional check failed: no running 'proxy' container to probe /healthz through"
        return 1
    fi

    if ! _proxy_container_publishes_port "$proxy_container_id" "$ip" "$port"; then
        print_error "Functional check failed: the 'proxy' container's own Docker port binding does not include ${ip}:${port} -- the published port may be mapped to a different service"
        return 1
    fi

    require_functional_check_tool curl "the proxy-container-loopback /healthz probe" || return 1
    local health_url health_answer
    health_url=$(prod_env_default PROXY_HEALTH_URL) || exit $?
    if ! health_answer=$(docker exec "$proxy_container_id" curl -sSf "$health_url" 2>&1); then
        print_error "Functional check failed: $health_url inside the proxy container: $health_answer"
        return 1
    fi
    print_ok "$health_url inside the proxy container answered: $health_answer"
    return 0
}

# What: functional checks: proxy /healthz and DNS query
# Why: healthy alone does not prove a real answer
# From: Issue #1683 | PR #1858
verify_stack_functional_health() {
    local ip_http ip_https https_enabled test_fqdn resolved

    ip_http=$(get_env_var IP_HTTP "$_UPDATE_ENV_FILE") || exit $?
    ip_https=$(get_env_var IP_HTTPS "$_UPDATE_ENV_FILE") || exit $?
    https_enabled=$(env_or_sot_default HTTPS_ENABLED "$_UPDATE_ENV_FILE") || exit $?

    if [[ -n "$ip_http" ]]; then
        _verify_healthz_endpoint "$ip_http" || return 1
    fi
    if [[ "$https_enabled" = "1" && -n "$ip_https" ]]; then
        _verify_healthz_endpoint "$ip_https" || return 1
    fi

    # What: dig an exact, non-wildcard cdn-domains.txt host
    # Why: wildcard-only RPZ entries never match their apex
    # From: Issue #1149 | PR #1150
    test_fqdn=$(prod_env_default SETUP_DNS_PROBE_NAME) || exit $?
    if [[ -n "$ip_http" ]]; then
        require_functional_check_tool dig "the DNS resolution probe" || return 1
        if ! resolved=$(dns_short_answer "$ip_http" "" A "$test_fqdn"); then
            print_error "Functional check failed: DNS did not resolve ${test_fqdn} via ${ip_http}: ${resolved}"
            return 1
        fi
    fi

    return 0
}

# What: records pre-update health of each named service
# Why: gate fails only on regressions; several stable reads
# From: Issue #1683 | PR #1858
capture_stack_health_baseline() {
    local -a services=("$@")
    local svc container_id sample healthy_streak samples interval

    # What: sample count and interval from the SOT defaults
    # Why: one healthy read can hit a crash-loop window
    # From: Issue #1683 | PR #1858
    samples=$(prod_env_default SETUP_HEALTH_BASELINE_SAMPLES) || exit $?
    interval=$(prod_env_default SETUP_HEALTH_BASELINE_INTERVAL_SECONDS) || exit $?
    _UPDATE_HEALTH_BASELINE=()
    for svc in "${services[@]}"; do
        container_id=$(service_container_id "$svc") \
            || die "Cannot capture the health baseline of $svc (exit $?); nothing was changed."
        if [[ -z "$container_id" ]]; then
            # What: no old container; left out of baseline
            # Why: new services must become healthy
            # From: Issue #1683 | PR #1858
            continue
        fi

        healthy_streak=1
        for (( sample = 0; sample < samples; sample++ )); do
            if ! service_container_is_healthy "$svc"; then
                healthy_streak=0
                break
            fi
            (( sample < samples - 1 )) && sleep "$interval"
        done
        _UPDATE_HEALTH_BASELINE["$svc"]="$healthy_streak"
    done
}

# What: polls health and functional probe until timeout
# Why: pre-update unhealthy services do not block the update
# From: Issue #1683 | PR #1858
wait_for_stack_health() {
    local timeout_seconds="$1"
    shift
    local -a services=("$@")
    local interval_seconds elapsed=0 svc all_healthy baseline
    local -a regressed_services pre_existing_unhealthy_services

    interval_seconds=$(prod_env_default SETUP_HEALTH_POLL_SECONDS) || exit $?

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
        # Why: the operator needs the cause
        # From: Issue #1683 | PR #1858
        local log_lines
        log_lines=$(prod_env_default SETUP_REGRESSION_LOG_LINES) || exit $?
        for svc in "${regressed_services[@]}"; do
            local container_id
            # What: container id lookup is an if condition
            # Why: set -e would abort the update
            # From: Issue #1683 | PR #1858
            if container_id=$(service_container_id "$svc") && [[ -n "$container_id" ]]; then
                print_warn "Last $log_lines log lines for regressed service '$svc' (container $container_id):"
                docker logs --tail "$log_lines" "$container_id" 2>&1 | sed 's/^/    /' || print_warn "Could not retrieve logs for '$svc' (container may already be gone)."
            else
                print_warn "No container found for regressed service '$svc'; cannot dump its logs."
            fi
        done
    fi
    return 1
}

# What: restores the newest pre-update config backup
# Why: reuses cmd_restore instead of a second rollback path
# From: Issue #1683 | PR #1858
rollback_stack_update() {
    local install_dir="$1"
    local backup_root="$BACKUP_ROOT"
    local latest_backup="" backups sorted_backups

    if [[ -d "$backup_root" ]]; then
        if ! backups=$(find "$backup_root" -maxdepth 1 -name 'lancache-ng-config-*.tar.gz' -print); then
            print_error "Failed to list the backups under $backup_root; cannot roll back automatically. Manual recovery required."
            return 1
        fi
        sorted_backups=$(sort <<< "$backups") \
            || die "Failed to sort the backups under $backup_root (exit $?)."
        latest_backup="${sorted_backups##*$'\n'}"
    fi
    if [[ -z "$latest_backup" ]]; then
        print_error "No pre-update backup archive found under $backup_root; cannot roll back automatically. Manual recovery required."
        return 1
    fi

    # What: a channel switch goes back by the current link
    # Why: the old dir kept its code; its backup restores
    # From: Issue #1683 | PR #1858
    if [[ -n "${LANCACHE_UPDATE_SWITCHED_FROM:-}" ]]; then
        local link
        link=$(channel_active_link) || exit $?
        if is_channel_root_dir "$LANCACHE_UPDATE_SWITCHED_FROM"; then
            rm -f -- "$link" || { print_error "Failed to remove $link (exit $?). Manual recovery required."; return 1; }
        else
            ln -sfn "${LANCACHE_UPDATE_SWITCHED_FROM##*/}" "$link" \
                || { print_error "Failed to point $link back (exit $?). Manual recovery required."; return 1; }
        fi
        print_warn "Code of the stack is $LANCACHE_UPDATE_SWITCHED_FROM again"
        # What: the copied stack files leave the new dir
        # Why: one copy of credentials; a switch recopies
        # From: Issue #1683 | PR #1858
        local f
        for f in "${CHANNEL_STACK_FILES[@]}"; do
            rm -f -- "$LANCACHE_UPDATE_REPO/deploy/prod/$f" \
                || { print_error "Failed to remove $LANCACHE_UPDATE_REPO/deploy/prod/$f (exit $?)."; return 1; }
        done
        install_dir="$LANCACHE_UPDATE_FROM_INSTALL"
    # What: the checkout returns to its pre-update revision
    # Why: old config on new compose would be a mixed stack
    # From: Issue #1683 | PR #1858
    elif [[ -n "${LANCACHE_UPDATE_OLD_SHA:-}" ]]; then
        # What: no branch = a detached pinned checkout
        # Why: -B needs a name; --detach restores it
        # From: Issue #1683 | PR #1858
        local -a back=(-B "${LANCACHE_UPDATE_BRANCH:-}")
        [[ -n "${LANCACHE_UPDATE_BRANCH:-}" ]] || back=(--detach)
        git -C "$LANCACHE_UPDATE_REPO" checkout -q -f "${back[@]}" "$LANCACHE_UPDATE_OLD_SHA" \
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
    local svc services wait_services wait_ui

    wait_services=$(prod_env_default SETUP_HEALTH_WAIT_SERVICES_SECONDS) || exit $?
    wait_ui=$(prod_env_default SETUP_HEALTH_WAIT_UI_SECONDS) || exit $?
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
    # From: Issue #1683 | PR #1858
    (( ${#non_ui_services[@]} > 0 )) \
        || die "No non-UI services found in this compose configuration; refusing to apply an update that cannot guarantee UI-last ordering."

    # What: baseline is captured earlier by the caller
    # Why: earlier steps may already change containers
    # From: Issue #1683 | PR #1858
    if stack_update_step "Starting non-UI services" "Failed to start non-UI services." \
            stack_compose "$install_dir" "$_UPDATE_ENV_FILE" up -d --remove-orphans "${non_ui_services[@]}" \
        && stack_update_step "Verifying non-UI services are healthy" "Non-UI services did not become healthy in time." \
            wait_for_stack_health "$wait_services" "${non_ui_services[@]}" \
        && stack_update_step "Starting Admin UI (last)" "Failed to start the Admin UI." \
            stack_compose "$install_dir" "$_UPDATE_ENV_FILE" up -d --remove-orphans ui \
        && stack_update_step "Verifying the whole stack is healthy" "Admin UI did not become healthy in time." \
            wait_for_stack_health "$wait_ui" ui; then
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

# What: branch of a checkout; empty when detached
# Why: a detached checkout may move, a named one may not
# From: Issue #1683 | PR #1858
checkout_branch_name() {
    local repo_dir="$1" branch="" rc=0
    branch=$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD) || rc=$?
    [[ "$rc" -le 1 ]] || die "Failed to read the branch of $repo_dir (exit $rc)."
    printf '%s\n' "$branch"
}

# What: the code ref a checkout moves to; empty = stays
# Why: install and update follow the channel the same way
# From: Issue #1683 | PR #1858
channel_checkout_target() {
    local repo_dir="$1" channel="$2" tag="$3" branch branches target changes
    if [[ ! -e "$repo_dir/.git" ]]; then
        print_ok "$repo_dir is not a git checkout; its files stay as they are" >&2
        return 0
    fi
    branch=$(checkout_branch_name "$repo_dir") || exit $?
    branches=$(lancache_channel_branches) || exit $?
    # What: a branch outside the channel branches stays
    # Why: the operator chose that revision (AG-OP-009)
    # From: Issue #1683 | PR #1858
    if [[ -n "$branch" ]] && ! list_has_line "$branch" "$branches"; then
        print_warn "Checkout $repo_dir is on $branch, no channel branch; repository not updated." >&2
        return 0
    fi
    target=$(lancache_channel_code_ref "$channel" "$tag") || exit $?
    if [[ -z "$target" ]]; then
        print_warn "Channel $channel has no LANCACHE_IMAGE_TAG; repository not updated." >&2
        return 0
    fi
    changes=$(git -C "$repo_dir" status --porcelain --untracked-files=no) \
        || die "Failed to read the git status of $repo_dir (exit $?)."
    if [[ -n "$changes" ]]; then
        print_warn "Checkout $repo_dir has local changes; repository not updated:"$'\n'"$changes" >&2
        return 0
    fi
    printf '%s\n' "$target"
}

# What: a channel follows its branch, pinned its tag
# Why: nightly code is current_dev, stable code master
# From: Issue #1683 | PR #1858
sync_repo_to_channel_ref() {
    local repo_dir="$1" target="$2" branches
    branches=$(lancache_channel_branches) || exit $?
    if list_has_line "$target" "$branches"; then
        sync_repo_to_branch "$repo_dir" "$target"
    else
        sync_repo_to_commit "$repo_dir" "$target"
    fi
}

# What: <state root>/<pointer>: one code dir per channel
# Why: maintainer 29.10.: latest and nightly side by side
# From: Issue #1683 | PR #1858
channel_code_dir() {
    local pointer
    ensure_default_install_dir
    pointer=$(lancache_stack_pointer_channel_for "$1") || exit $?
    printf '%s/%s\n' "$DEFAULT_INSTALL_DIR" "$pointer"
}

# What: stack files a channel switch carries along
# Why: switch and rollback must name the same files
# From: Issue #1683 | PR #1858
CHANNEL_STACK_FILES=(.env.local .env docker-compose.override.yml docker-compose.override.yaml)

# What: <state root>/current links the running channel dir
# Why: units and default commands follow it on a switch
# From: Issue #1683 | PR #1858
channel_active_link() {
    ensure_default_install_dir
    printf '%s/current\n' "$DEFAULT_INSTALL_DIR"
}

# What: true when a dir is the state root itself
# Why: an old install cloned the code right into it
# From: Issue #1683 | PR #1858
is_channel_root_dir() {
    ensure_default_install_dir
    [[ "$(realpath -m "$1")" = "$(realpath -m "$DEFAULT_INSTALL_DIR")" ]]
}

# What: true for the state root or one of its channel dirs
# Why: only that layout moves between channel dirs
# From: Issue #1683 | PR #1858
is_channel_layout_repo() {
    local repo root pointers
    repo=$(realpath -m "$1")
    ensure_default_install_dir
    root=$(realpath -m "$DEFAULT_INSTALL_DIR")
    [[ "$repo" != "$root" ]] || return 0
    [[ "${repo%/*}" = "$root" ]] || return 1
    pointers=$(lancache_release_rows channel) || exit $?
    list_has_line "${repo##*/}" "$pointers"
}

# What: clones or moves a channel dir to its code ref
# Why: install and a channel switch share the git steps
# From: Issue #1683 | PR #1858
ensure_channel_checkout() {
    local dir="$1" target="$2" branches
    if [[ -e "$dir/.git" ]]; then
        sync_repo_to_channel_ref "$dir" "$target"
        return 0
    fi
    [[ ! -e "$dir" ]] || die "$dir exists but is no git checkout; move it away, then rerun setup.sh."
    mkdir -p "${dir%/*}" || die "Failed to create ${dir%/*} (exit $?)."
    branches=$(lancache_channel_branches) || exit $?
    if list_has_line "$target" "$branches"; then
        git clone --branch "$target" "${LANCACHE_REPO_URL}.git" "$dir" \
            || die "Failed to clone $target into $dir (exit $?)."
    else
        git clone "${LANCACHE_REPO_URL}.git" "$dir" || die "Failed to clone into $dir (exit $?)."
        sync_repo_to_commit "$dir" "$target"
    fi
}

# What: points <state root>/current at one channel dir
# Why: one place says which channel's code runs
# From: Issue #1683 | PR #1858
set_active_channel_dir() {
    local dir="$1" link
    link=$(channel_active_link) || exit $?
    ln -sfn "${dir##*/}" "$link" || die "Failed to point $link at $dir (exit $?)."
}

# What: install runs from the chosen channel's dir
# Why: compose files and images from one ref at once
# From: Issue #1683 | PR #1858
install_repo_follow_channel() {
    local channel="$1" target dir link branch branches old="" new exec_rc
    shift
    # What: a named non-channel branch installs in place
    # Why: the operator chose that revision (AG-OP-009)
    # From: Issue #1683 | PR #1858
    if [[ -e "$SCRIPT_DIR/.git" ]]; then
        branch=$(checkout_branch_name "$SCRIPT_DIR") || exit $?
        branches=$(lancache_channel_branches) || exit $?
        if [[ -n "$branch" ]] && ! list_has_line "$branch" "$branches"; then
            print_warn "Checkout $SCRIPT_DIR is on $branch, no channel branch; installing from it."
            return 0
        fi
    fi
    dir=$(channel_code_dir "$channel") || exit $?
    link=$(channel_active_link) || exit $?
    target="${LANCACHE_SETUP_GIT_REF:-}"
    [[ -n "$target" ]] || target=$(lancache_channel_code_ref "$channel" "${LANCACHE_IMAGE_TAG:-}") || exit $?
    [[ -n "$target" ]] || die "Channel $channel needs LANCACHE_IMAGE_TAG to name its code."
    [[ ! -e "$dir/.git" ]] || old=$(git -C "$dir" rev-parse HEAD) || die "Failed to read HEAD of $dir (exit $?)."
    print_step "Code of channel $channel in $dir ($target)"
    if [[ -n "${LANCACHE_SETUP_GIT_REF:-}" && -e "$dir/.git" ]]; then
        sync_repo_to_ref "$dir" "$target"
    elif [[ -n "${LANCACHE_SETUP_GIT_REF:-}" ]]; then
        git clone --branch "$target" "${LANCACHE_REPO_URL}.git" "$dir" \
            || die "Clone failed for LANCACHE_SETUP_GIT_REF='$target'. Check that it names a real branch or tag on origin."
    else
        ensure_channel_checkout "$dir" "$target"
    fi
    set_active_channel_dir "$dir"
    new=$(git -C "$dir" rev-parse HEAD) || die "Failed to read HEAD of $dir (exit $?)."
    # What: running from current at its HEAD goes on here
    # Why: units then name current, the link, not a dir
    # From: Issue #1683 | PR #1858
    if [[ "$SCRIPT_DIR" = "$link" && "$new" = "$old" ]]; then
        print_ok "Code of channel $channel is at $new"
        return 0
    fi
    print_ok "Continuing with $link/setup.sh ($new)"
    # What: the new setup.sh keeps the chosen channel
    # Why: its channel prompt is then skipped, not repeated
    # From: Issue #1683 | PR #1858
    export LANCACHE_IMAGE_CHANNEL="$channel"
    chmod +x "$dir/setup.sh" || die "Failed to make $dir/setup.sh executable (exit $?)."
    shopt -s execfail
    set +e
    exec "$link/setup.sh" "$@" || {
        exec_rc=$?
        set -e
        die "Failed to start $link/setup.sh (exit $exec_rc); nothing was installed yet."
    }
}

# What: drops the git files of an old root checkout
# Why: its code moved to a channel dir; data stays
# From: Issue #1683 | PR #1858
remove_root_checkout() {
    local root="$1" changes list f d
    local -a dirs=()
    changes=$(git -C "$root" status --porcelain --untracked-files=no) \
        || die "Failed to read the git status of $root (exit $?)."
    # What: changed tracked files keep the whole old code
    # Why: such a file may hold data; nothing is guessed
    # From: Issue #1683 | PR #1858
    if [[ -n "$changes" ]]; then
        print_warn "Old code in $root stays; these tracked files differ:"$'\n'"$changes"
        return 0
    fi
    list=$(mktemp) || die "Failed to create a temporary file (exit $?)."
    git -C "$root" ls-files -z > "$list" || die "Failed to list the files of $root (exit $?)."
    while IFS= read -r -d '' f; do
        rm -f -- "$root/$f" || die "Failed to remove $root/$f (exit $?)."
        [[ "$f" != */* ]] || dirs+=("${f%/*}")
    done < "$list"
    rm -f -- "$list" || die "Failed to remove $list (exit $?)."
    rm -f -- "$root/deploy/prod/.env.local" || die "Failed to remove $root/deploy/prod/.env.local (exit $?)."
    # What: drops emptied code dirs, deepest first
    # Why: a dir with data or other files must stay
    # From: Issue #1683 | PR #1858
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        while [[ -n "$d" ]]; do
            if [[ -d "$root/$d" ]]; then
                rmdir --ignore-fail-on-non-empty -- "$root/$d" || die "Failed to remove $root/$d (exit $?)."
            fi
            if [[ "$d" = */* ]]; then
                d="${d%/*}"
            else
                d=""
            fi
        done
    done < <(printf '%s\n' "${dirs[@]}" | sort -ru)
    rm -rf -- "$root/.git" || die "Failed to remove $root/.git (exit $?)."
    print_ok "Old code in $root removed; its data stays"
}

# What: update moves the stack to another channel's dir
# Why: a channel change runs the code of the new channel
# From: Issue #1683 | PR #1858
switch_channel_dir_and_resume() {
    local install_dir="$1" repo_dir="$2" channel="$3" target="$4" dir link old="" baseline="" svc exec_rc f
    local -a files=("${CHANNEL_STACK_FILES[@]}")
    dir=$(channel_code_dir "$channel") || exit $?
    link=$(channel_active_link) || exit $?
    [[ ! -e "$dir/.git" ]] || old=$(git -C "$dir" rev-parse HEAD) || die "Failed to read HEAD of $dir (exit $?)."
    print_step "Moving the stack to $dir (channel $channel)"
    # What: old copies of the stack files leave first
    # Why: the running stack owns them; a copy is redone
    # From: Issue #1683 | PR #1858
    for f in "${files[@]}"; do
        rm -f -- "$dir/deploy/prod/$f" || die "Failed to remove $dir/deploy/prod/$f (exit $?)."
    done
    ensure_channel_checkout "$dir" "$target"
    for f in "${files[@]}"; do
        [[ -f "$install_dir/$f" ]] || continue
        cp -p -- "$install_dir/$f" "$dir/deploy/prod/$f" \
            || die "Failed to copy $install_dir/$f to $dir/deploy/prod (exit $?)."
    done
    set_active_channel_dir "$dir"
    for svc in "${!_UPDATE_HEALTH_BASELINE[@]}"; do baseline+="${svc}=${_UPDATE_HEALTH_BASELINE[$svc]} "; done
    print_ok "Stack settings copied to $dir; continuing with its setup.sh"
    # What: the switch is undone by the link, not by git
    # Why: the old dir keeps its code; rollback starts it
    # From: Issue #1683 | PR #1858
    export LANCACHE_UPDATE_RESUMED=1 LANCACHE_UPDATE_REPO="$dir" LANCACHE_UPDATE_BRANCH="" \
        LANCACHE_UPDATE_OLD_SHA="" LANCACHE_UPDATE_BASELINE="$baseline" LANCACHE_BACKUP_ROOT="$BACKUP_ROOT" \
        LANCACHE_UPDATE_SWITCHED_FROM="$repo_dir" LANCACHE_UPDATE_FROM_INSTALL="$install_dir" \
        CONVERGENCE_TIMER_WAS_ACTIVE CONVERGENCE_TIMER_WAS_ENABLED CONVERGENCE_SERVICE_WAS_ACTIVE
    [[ -n "$old" ]] || print_ok "New channel dir $dir"
    chmod +x "$dir/setup.sh" || die "Failed to make $dir/setup.sh executable (exit $?)."
    shopt -s execfail
    set +e
    exec "$link/setup.sh" update "$link/deploy/prod" || {
        exec_rc=$?
        set -e
        die "Failed to start $link/setup.sh (exit $exec_rc); the stack was not changed."
    }
}

# What: pulls the checkout and reruns the update from it
# Why: compose, templates and setup.sh must move together
# From: Issue #1683 | PR #1858
update_repo_and_resume() {
    local install_dir="$1" repo_dir="$1" branch channel tag target old new baseline="" svc
    local exec_rc dir branches
    is_deploy_prod_install_dir "$install_dir" && repo_dir=$(deploy_prod_repo_root "$install_dir")
    channel=$(resolve_lancache_image_channel "$_UPDATE_ENV_FILE") || exit $?
    tag="${LANCACHE_IMAGE_TAG:-}"
    [[ -n "$tag" ]] || tag=$(get_env_var LANCACHE_IMAGE_TAG "$_UPDATE_ENV_FILE") || exit $?
    # What: another channel's dir or the old root moves
    # Why: each channel runs the code of its own dir
    # From: Issue #1683 | PR #1858
    if [[ -e "$repo_dir/.git" ]] && is_channel_layout_repo "$repo_dir"; then
        branch=$(checkout_branch_name "$repo_dir") || exit $?
        dir=$(channel_code_dir "$channel") || exit $?
        branches=$(lancache_channel_branches) || exit $?
        if [[ -z "$branch" ]] || list_has_line "$branch" "$branches"; then
            if [[ "$(realpath -m "$repo_dir")" != "$(realpath -m "$dir")" ]]; then
                target=$(lancache_channel_code_ref "$channel" "$tag") || exit $?
                [[ -n "$target" ]] || die "Channel $channel needs LANCACHE_IMAGE_TAG to name its code."
                switch_channel_dir_and_resume "$install_dir" "$repo_dir" "$channel" "$target"
            fi
        fi
    fi
    target=$(channel_checkout_target "$repo_dir" "$channel" "$tag") || exit $?
    [[ -n "$target" ]] || return 0
    branch=$(checkout_branch_name "$repo_dir") || exit $?
    old=$(git -C "$repo_dir" rev-parse HEAD) || die "Failed to read HEAD of $repo_dir (exit $?)."
    print_step "Updating repo to $target (channel $channel)"
    sync_repo_to_channel_ref "$repo_dir" "$target"
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
    # What: a failed exec returns to die, trap and all
    # Why: errexit ends bash at a failed exec, skipping EXIT
    # From: Issue #1683 | PR #1912
    shopt -s execfail
    set +e
    exec "$repo_dir/setup.sh" update "$install_dir" || {
        exec_rc=$?
        set -e
        die "Failed to start $repo_dir/setup.sh (exit $exec_rc); the stack was not changed."
    }
}

# What: takes the paused state and baseline over after exec
# Why: the timer stays paused and gates keep their baseline
# From: Issue #1683 | PR #1858
update_resume_handoff() {
    local pair
    local -a pairs=()
    [[ -n "${CONVERGENCE_TIMER_WAS_ACTIVE:-}" && -n "${CONVERGENCE_TIMER_WAS_ENABLED:-}" \
        && -n "${CONVERGENCE_SERVICE_WAS_ACTIVE:-}" && -n "${LANCACHE_UPDATE_REPO:-}" ]] \
        || die "LANCACHE_UPDATE_RESUMED is set without the state of the paused update; rerun setup.sh update without it."
    _UPDATE_HEALTH_BASELINE=()
    # What: read -a splits the pairs without glob expansion
    # Why: an unquoted loop word would expand * or ?
    # From: Issue #1683 | PR #1858
    read -ra pairs <<< "${LANCACHE_UPDATE_BASELINE:-}"
    for pair in "${pairs[@]}"; do
        _UPDATE_HEALTH_BASELINE["${pair%%=*}"]="${pair#*=}"
    done
    print_ok "Continuing the update with $LANCACHE_UPDATE_REPO/setup.sh"
}

# What: runs update steps in fixed order, with rollback
# Why: reordering can leave a half-migrated stack running
# From: Issue #1683 | PR #1858
perform_stack_update_flow() {
    local install_dir="$1"
    # What: refuses an unsupported arch before any change
    # Why: the quickstart migration below already mutates
    # From: Issue #1683 | PR #1858
    assert_prebuilt_image_platform_supported
    if is_quickstart_install "$install_dir"; then
        migrate_quickstart_install "$install_dir" || exit $?
        install_dir="${PROD_COMPOSE%/*}"
    fi
    install_dir=$(resolve_stack_dir "$install_dir") || exit $?
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die_no_stack_found "$install_dir"
    # What: installs curl, dig and jq before any mutation
    # Why: the functional health gate must not silently skip
    # From: Issue #1683 | PR #1858
    install_missing_tools curl dig jq
    cd "$install_dir"
    _UPDATE_ENV_FILE=$(runtime_env_file_for_install_dir "$install_dir")
    _UPDATE_STACK_DIR="$install_dir"
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

    # What: after a code move a failed .env step rolls back
    # Why: the moved code must not stay with the old stack
    # From: Issue #1683 | PR #1858
    if [[ -n "${LANCACHE_UPDATE_SWITCHED_FROM:-}${LANCACHE_UPDATE_OLD_SHA:-}" ]]; then
        _UPDATE_ROLLBACK_DIR="$install_dir"
        trap rollback_update_after_env_failure EXIT
    fi
    migrate_env_for_update "$install_dir"
    validate_compose_config "$install_dir"
    trap resume_lancache_convergence_after_failed_update EXIT

    print_step "Pulling selected images"
    if ! stack_compose "$install_dir" "$_UPDATE_ENV_FILE" pull; then
        # What: a failed pull restores code and .env
        # Why: new code with an old stack would mix
        # From: Issue #1683 | PR #1858
        trap - EXIT
        UPDATE_CONVERGENCE_COMPLETED=1
        rollback_stack_update "$install_dir" \
            || die_convergence_kept_paused "Pulling the images failed, and the rollback to the pre-update backup failed too."
        resume_lancache_convergence_after_update
        die "Failed to pull required container images; the update was rolled back. Check network access and GHCR authentication, then rerun setup.sh update."
    fi

    ensure_ui_password_hash "$install_dir" "$_UPDATE_ENV_FILE"
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

    migrate_legacy_ca "$install_dir/../../certs" "$_UPDATE_ENV_FILE" 1
    # What: a finished move from the old root cleans it up
    # Why: units then start the code behind the current link
    # From: Issue #1683 | PR #1858
    if [[ -n "${LANCACHE_UPDATE_SWITCHED_FROM:-}" ]] && is_channel_root_dir "$LANCACHE_UPDATE_SWITCHED_FROM"; then
        migrate_legacy_ca "$LANCACHE_UPDATE_SWITCHED_FROM/certs" "$_UPDATE_ENV_FILE" 1
        write_lancache_host_services "$(channel_active_link)/deploy/prod" \
            || print_warn "Neither systemd nor OpenRC found — host services were not written"
        remove_root_checkout "$LANCACHE_UPDATE_SWITCHED_FROM"
    fi
    trap - EXIT
    resume_lancache_convergence_after_update
    UPDATE_CONVERGENCE_COMPLETED=1
    print_ok "Stack updated"
}

# What: manual update with backup and health gate
# Why: a failed health check rolls back to the backup
# From: Issue #1683 | PR #1858
cmd_update() {
    ensure_default_install_dir
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
    install_dir=$(resolve_stack_dir_checked "$1") || exit $?
    shift
    stack_compose "$install_dir" "$(runtime_env_file_for_install_dir "$install_dir")" "$@"
}

# What: seconds of a systemd span like 90s, 5min or 1h
# Why: OpenRC loops read the SOT values of the timers
# From: Issue #1683 | PR #1858
timespan_seconds() {
    local span="$1"
    case "$span" in
        *min) [[ "${span%min}" =~ ^[0-9]+$ ]] && printf '%s\n' "$(( 10#${span%min} * 60 ))" && return 0 ;;
        *h) [[ "${span%h}" =~ ^[0-9]+$ ]] && printf '%s\n' "$(( 10#${span%h} * 3600 ))" && return 0 ;;
        *s) [[ "${span%s}" =~ ^[0-9]+$ ]] && printf '%s\n' "$(( 10#${span%s} ))" && return 0 ;;
    esac
    die "Unsupported time span '$span'; use <n>s, <n>min or <n>h."
}

# What: sleeps; a TERM ends the sleep and sets the stop flag
# Why: a stopped OpenRC loop must not wait out its sleep
# From: Issue #1683 | PR #1858
openrc_loop_sleep() {
    local seconds="$1" pid rc=0
    (( seconds > 0 )) || return 0
    sleep "$seconds" &
    pid=$!
    wait "$pid" || rc=$?
    if [[ "$rc" -gt 128 && -n "$(jobs -pr)" ]]; then
        kill "$pid" || print_warn "Failed to end sleep $pid (exit $?)."
    fi
}

# What: runs converge or auto-update forever, as a timer
# Why: OpenRC has no timers; supervise-daemon runs this
# From: Issue #1683 | PR #1858
cmd_openrc_loop() {
    local job="${1:-}" stack_dir="${2:-}" defaults first interval spread=0 calendar rc
    [[ -n "$job" && -n "$stack_dir" ]] \
        || die "Usage: setup.sh openrc-loop <converge|auto-update> <install-dir>"
    defaults=$(runtime_defaults_list) || exit $?
    case "$job" in
        converge)
            first=$(runtime_default_in "$defaults" CONVERGE_TIMER_BOOT_DELAY_MINUTES) || exit $?
            interval=$(runtime_default_in "$defaults" CONVERGE_TIMER_INTERVAL_MINUTES) || exit $?
            first=$(timespan_seconds "${first}min")
            interval=$(timespan_seconds "${interval}min")
            ;;
        auto-update)
            calendar=$(runtime_default_in "$defaults" AUTO_UPDATE_TIMER_CALENDAR) || exit $?
            [[ "$calendar" = daily ]] \
                || die "OpenRC runs AUTO_UPDATE_TIMER_CALENDAR=daily only, not '$calendar'."
            spread=$(runtime_default_in "$defaults" AUTO_UPDATE_TIMER_SPREAD) || exit $?
            spread=$(timespan_seconds "$spread")
            first=0
            interval=$(timespan_seconds 24h)
            ;;
        *) die "Unknown openrc-loop job '$job'; use converge or auto-update." ;;
    esac
    # What: TERM ends the loop after the running job
    # Why: a killed job could leave compose half applied
    # From: Issue #1683 | PR #1858
    OPENRC_LOOP_STOP=0
    trap 'OPENRC_LOOP_STOP=1' TERM
    openrc_loop_sleep "$first"
    while [[ "$OPENRC_LOOP_STOP" = 0 ]]; do
        (( spread == 0 )) || openrc_loop_sleep "$(( (RANDOM * 32768 + RANDOM) % spread ))"
        [[ "$OPENRC_LOOP_STOP" = 0 ]] || break
        rc=0
        if [[ "$job" = converge ]]; then
            "$SCRIPT_DIR/setup.sh" converge-reconcile "$stack_dir" || rc=$?
            [[ "$rc" -eq 0 ]] || print_error "converge-reconcile failed (exit $rc); compose up runs anyway."
            rc=0
            "$SCRIPT_DIR/setup.sh" compose "$stack_dir" up -d --remove-orphans || rc=$?
        else
            "$SCRIPT_DIR/setup.sh" auto-update "$stack_dir" || rc=$?
        fi
        [[ "$rc" -eq 0 ]] || print_error "openrc-loop $job failed (exit $rc); next run in ${interval} s."
        [[ "$OPENRC_LOOP_STOP" = 0 ]] || break
        openrc_loop_sleep "$interval"
    done
    print_ok "openrc-loop $job stopped"
}

# What: proceed/skip for one auto-update tick, no I/O
# Why: kept pure so the decision is testable without docker
# From: Issue #819
lancache_auto_update_should_proceed() {
    local auto_update_enabled="$1" channel="$2" current_tag="$3" deployed_tag="$4" pinned

    if [[ "$auto_update_enabled" != "1" ]]; then
        printf 'skip: AUTO_UPDATE_ENABLED is not 1\n'
        return 1
    fi
    pinned=$(lancache_release_rows pinned) || exit $?
    if [[ "$channel" = "$pinned" ]]; then
        printf 'skip: LANCACHE_IMAGE_CHANNEL=%s tracks one fixed tag, not a moving channel; nothing to detect\n' "$pinned"
        return 1
    fi
    if [[ "$current_tag" = "$deployed_tag" ]]; then
        printf 'skip: channel %s is already at %s\n' "$channel" "$current_tag"
        return 1
    fi
    printf 'proceed: channel %s moved %s -> %s\n' "$channel" "$deployed_tag" "$current_tag"
    return 0
}

# What: scheduled update tick; detects a channel move first
# Why: an unchanged channel must not restart the stack
# From: Issue #1683 | PR #1858
cmd_auto_update() {
    ensure_default_install_dir
    local install_dir="${1:-$DEFAULT_INSTALL_DIR}"
    local env_file auto_update_enabled current_channel current_tag deployed_tag decision
    local deployed_refs current_refs pinned

    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die_no_stack_found "$install_dir"
    env_file=$(runtime_env_file_for_install_dir "$install_dir")

    # What: re-checks AUTO_UPDATE_ENABLED before acting
    # Why: a timer may stay enabled after .env is edited
    # From: Issue #1683 | PR #1858
    auto_update_enabled=$(env_or_sot_default AUTO_UPDATE_ENABLED "$env_file") || exit $?
    current_channel=$(resolve_lancache_image_channel "$env_file") || exit $?
    pinned=$(lancache_release_rows pinned) || exit $?
    # What: stacks compared by image-pin fingerprint
    # Why: the channel word stays while digests move
    # From: Issue #1683 | PR #1858
    deployed_refs=$(awk '/^LANCACHE_IMAGE_REF_[A-Z_]+=/' "$env_file") \
        || die "Failed to read the image pins from $env_file (exit $?)."
    deployed_tag=$(lancache_image_refs_fingerprint "$deployed_refs") \
        || die "Cannot fingerprint the deployed image pins of $env_file (exit $?)."
    # What: resolves the channel after local checks
    # Why: disabled or pinned installs skip the registry
    # From: Issue #1683 | PR #1858
    if [[ "$auto_update_enabled" = "1" && "$current_channel" != "$pinned" ]]; then
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

# What: true if the UI channel is in the selectable list
# Why: a retired or unknown name is a no-op on a tick
# From: Issue #1683 | PR #1858
lancache_ui_channel_override_is_valid() {
    local selectable
    selectable=$(lancache_selectable_channels) || exit $?
    list_has_line "$1" "$selectable"
}

# What: channels the wizard offers, release name last
# Why: the testing channels, then the release alias
# From: Issue #1683 | PR #1858
lancache_selectable_channels() {
    local channels release aliases
    channels=$(lancache_release_rows channel) || exit $?
    release=$(lancache_release_rows release) || exit $?
    aliases=$(lancache_release_rows alias) || exit $?
    awk -v r="$release" '$0 != r' <<< "$channels"
    awk -v r="$release" '$2 == r { print $1; found = 1; exit } END { if (!found) print r }' <<< "$aliases"
}

# What: true for a positive whole number of GiB
# Why: a leading 0 must parse as decimal, not octal
# From: Issue #1683 | PR #1858
lancache_ui_cache_max_gb_override_is_valid() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    (( 10#$1 > 0 ))
}

# What: reads one KEY from the ui-data settings file
# Why: checks the volume exists; docker run would create it
# From: Issue #1683 | PR #1858
lancache_read_ui_settings_override() {
    local install_dir="$1" env_file="$2" key="$3" project volume raw rc=0 settings_file line found=""
    if ! command_available docker; then
        print_skip "Reading the UI setting $key: docker is not available"
        return 0
    fi
    require_helper_image
    project=$(compose_project_name "$install_dir" "$env_file") \
        || die "Cannot resolve the compose project of $install_dir (exit $?)."
    volume="${project}_ui-data"
    docker_volume_exists "$volume" || rc=$?
    if [[ "$rc" -eq 1 ]]; then
        print_skip "Reading the UI setting $key: Docker volume $volume does not exist yet"
        return 0
    fi
    [[ "$rc" -eq 0 ]] || die "Cannot check the Docker volume $volume; the UI settings were not read."
    settings_file=$(prod_env_default UI_SETTINGS_FILE) || exit $?
    settings_file="${settings_file##*/}"
    # What: the file name goes in as $1, not as code
    # Why: a value inside sh -c text would run as shell
    # From: Issue #1683 | PR #1858
    raw=$(docker run --rm -v "${volume}:/volume:ro" "$LANCACHE_HELPER_IMAGE" \
        sh -c 'if [ -e "/volume/$1" ]; then cat "/volume/$1"; fi' sh "$settings_file") \
        || die "Failed to read the UI settings from Docker volume $volume (exit $?)."
    # What: the last KEY= line of $raw wins
    # Why: a loop reads it all; no early-exit pipe
    # From: Issue #1377
    while IFS= read -r line; do
        if [[ "$line" == "${key}="* ]]; then found="${line#"${key}="}"; fi
    done <<<"$raw"
    if [[ -n "$found" ]]; then printf '%s\n' "$found"; fi
}

# What: syncs auto-update timer with AUTO_UPDATE_ENABLED
# Why: the .env value is the source of truth
# From: Issue #1683 | PR #1858
reconcile_auto_update_timer_state() {
    local env_file="$1" desired unit="$AUTO_UPDATE_TIMER_UNIT"
    if ! host_unit_exists "$unit"; then
        print_skip "Syncing the auto-update timer: $unit is not installed"
        return 0
    fi
    desired=$(env_or_sot_default AUTO_UPDATE_ENABLED "$env_file") \
        || die "Cannot read AUTO_UPDATE_ENABLED from $env_file (exit $?)."
    if [[ "$desired" = "1" ]]; then
        host_unit_enabled "$unit" || host_unit_action "$unit" enable
        host_unit_active "$unit" || host_unit_action "$unit" start
    else
        if host_unit_enabled "$unit"; then host_unit_action "$unit" disable; fi
        if host_unit_active "$unit"; then host_unit_action "$unit" stop; fi
    fi
}

# What: copies a valid UI setting into .env when it differs
# Why: channel and DHCP mode share read, check and write
# From: Issue #1683 | PR #1858
fold_ui_setting_into_env() {
    local install_dir="$1" env_file="$2" key="$3" check="$4" label="$5" ui_value current
    ui_value=$(lancache_read_ui_settings_override "$install_dir" "$env_file" "$key") \
        || die "Cannot read the UI setting $key (exit $?)."
    if [[ -n "$ui_value" ]] && "$check" "$ui_value"; then
        current=$(get_env_var "$key" "$env_file") || exit $?
        if [[ "$ui_value" != "$current" ]]; then
            set_env_key "$key" "$ui_value" "$env_file"
            print_ok "$label updated from Admin UI: ${current:-<unset>} -> $ui_value"
        fi
    fi
}

# What: copies valid Admin UI settings into .env per tick
# Why: the next compose up must use the UI choice
# From: Issue #819 | PR #831
cmd_converge_reconcile() {
    ensure_default_install_dir
    local install_dir="${1:-$DEFAULT_INSTALL_DIR}" env_file
    local ui_auto_update current_auto_update
    local ui_cache_max_gb current_cache_max_gb

    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?
    # What: a tick before the first install does nothing
    # Why: no compose file or .env exists to converge
    # From: Issue #1683 | PR #1858
    if [[ ! -f "$install_dir/docker-compose.yml" ]]; then
        print_skip "Converge tick: $install_dir/docker-compose.yml does not exist yet"
        return 0
    fi
    if ! command_available docker; then
        print_skip "Converge tick: docker is not available"
        return 0
    fi
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    if [[ ! -f "$env_file" ]]; then
        print_skip "Converge tick: $env_file does not exist yet"
        return 0
    fi

    fold_ui_setting_into_env "$install_dir" "$env_file" LANCACHE_IMAGE_CHANNEL lancache_ui_channel_override_is_valid "Release channel"

    ui_auto_update=$(lancache_read_ui_settings_override "$install_dir" "$env_file" "AUTO_UPDATE_ENABLED") \
        || die "Cannot read the UI setting AUTO_UPDATE_ENABLED (exit $?)."
    if [[ "$ui_auto_update" = "0" || "$ui_auto_update" = "1" ]]; then
        current_auto_update=$(env_or_sot_default AUTO_UPDATE_ENABLED "$env_file") || exit $?
        if [[ "$ui_auto_update" != "$current_auto_update" ]]; then
            set_env_key AUTO_UPDATE_ENABLED "$ui_auto_update" "$env_file"
            print_ok "Scheduled automatic updates setting updated from Admin UI: ${ui_auto_update} (was ${current_auto_update})"
        fi
    fi

    # What: folds the Admin UI DHCP mode into .env
    # Why: the dhcp container reads DHCP_MODE at its start
    # From: Issue #1683 | PR #1912
    fold_ui_setting_into_env "$install_dir" "$env_file" DHCP_MODE is_valid_dhcp_mode "DHCP mode"

    # What: reconciles the timer with .env's value
    # Why: a manual .env edit must also take effect
    # From: Issue #1683 | PR #1858
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

# What: read-only diagnostics that never repair
# Why: they run when the stack state is unknown
# From: Issue #1683 | PR #1858
cmd_debug() {
    ensure_default_install_dir
    local install_dir="${1:-$DEFAULT_INSTALL_DIR}"
    local env_file
    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die_no_stack_found "$install_dir"

    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    local ip_http ip_https cache_dir
    ip_http=$(get_env_var IP_HTTP "$env_file") || exit $?
    ip_https=$(get_env_var IP_HTTPS "$env_file") || exit $?
    cache_dir=$(get_env_var CACHE_DIR "$env_file") || exit $?

    print_step "Container status"
    stack_compose "$install_dir" "$env_file" ps || print_error "docker compose ps failed (exit $?)."

    local log_lines
    log_lines=$(prod_env_default SETUP_STATUS_LOG_LINES) || exit $?
    print_step "Logs (last $log_lines lines per service)"
    # What: logs of every service the compose files define
    # Why: a fixed list misses profile services
    # From: Issue #1683 | PR #1858
    local services svc
    if services=$(stack_compose "$install_dir" "$env_file" config --services); then
        while IFS= read -r svc; do
            [[ -n "$svc" ]] || continue
            printf '\n%s--- %s ---%s\n' "${BOLD}" "$svc" "${RESET}"
            stack_compose "$install_dir" "$env_file" logs --tail="$log_lines" "$svc" 2>&1 \
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
        print_host_addresses_failed "$?"
    fi

    print_step "Health checks"
    if ! command_available curl; then
        print_warn "curl not found — health checks skipped"
    else
        local ip probe health_path url
        health_path=$(proxy_health_path) || exit $?
        for ip in "$ip_http" "$ip_https"; do
            [[ -z "$ip" ]] && continue
            url="http://${ip}${health_path}"
            if probe=$(curl -sS -f "$url" 2>&1); then
                print_ok "$url — OK: $probe"
            else
                print_error "$url — ERROR (exit $?): $probe"
            fi
        done
    fi
}

# What: bundles redacted diagnostics for a bug report
# Why: secrets leak via compose config and logs too
# From: Issue #1683 | PR #1858

# What: every secret env key setup.sh makes and redacts
# Why: one list; generation refuses a key not on it
# From: Issue #762 | PR #1858
managed_secret_env_keys() {
    local rows
    rows=$(lancache_sot_list managed_secrets runtime) || exit $?
    awk '{ print $1 }' <<< "$rows"
}

# What: "KEY generator" rows of one owner, or a key's kind
# Why: SOT runtime.managed_secrets; no kind list in code
# From: Issue #1683 | PR #1912
managed_secret_rows() {
    local owner="$1" key="${2:-}" rows
    rows=$(lancache_sot_list managed_secrets runtime) || exit $?
    awk -v o="$owner" -v k="$key" '$3 == o && (k == "" || $1 == k) { print $1, $2 }' <<< "$rows"
}

# What: one managed secret, made by its SOT generator
# Why: no generator name beside runtime.managed_secrets
# From: Issue #1683 | PR #1912
generate_managed_secret() {
    local key="$1" owner="$2" row
    row=$(managed_secret_rows "$owner" "$key") || exit $?
    [[ "$row" == "$key "?* && "$row" != *$'\n'* ]] \
        || die "SOT runtime.managed_secrets needs one $owner row for $key."
    generate_secret_value "$key" "${row#"$key "}"
}

# What: name-pattern net for secret-shaped env keys
# Why: an operator's own secret key is redacted too
# From: Issue #762
logbundle_key_looks_like_secret() {
    local key="$1"
    # What: a key naming a property of a secret is plain
    # Why: redacting a value like "none" garbles the bundle
    # From: Issue #1683 | PR #1912
    [[ "$key" =~ _(PERSISTENCE|MODE|POLICY|ENABLED|TTL|SECONDS)$ ]] && return 1
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
    done | sort -u | awk '{ print length, $0 }' | sort -k1,1nr | awk '{ sub(/^[^ ]+ /, ""); print }'
}

# What: replaces every secret value with [REDACTED]
# Why: plain substitution; base64 punctuation is safe
# From: Issue #1683 | PR #1858
logbundle_redact_stream() {
    local secrets_file="$1"
    local content="" secret
    # What: reads all input; the dot keeps trailing newlines
    # Why: a failed read must stop the bundle, not cut it
    # From: Issue #1683 | PR #1912
    content=$(cat && printf .) || die "Cannot read the log bundle input for redaction (exit $?)."
    content="${content%.}"
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
# From: Issue #1683 | PR #1858
logbundle_redact_env_file() {
    local src="$1" dst="$2"
    local line key
    : > "$dst"
    if [[ ! -f "$src" ]]; then
        print_skip "Redacting $src: the file does not exist; $dst stays empty"
        return 0
    fi
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

# What: prints the ext of the first present compressor
# Why: runtime.archive_compressors lists them best first
# From: Issue #1683 | PR #1912
logbundle_select_compressor() {
    local rows
    local -a row
    rows=$(lancache_sot_list archive_compressors runtime) || exit $?
    while read -r -a row; do
        if command_available "${row[1]}"; then
            printf '%s\n' "${row[0]}"
            return 0
        fi
    done <<< "$rows"
    die "No compressor of runtime.archive_compressors is installed."
}

# What: lists known-good snapshot volumes with ls only
# Why: volumes are not host paths; ls runs in a container
# From: Issue #1683 | PR #1858
logbundle_named_volume_listing() {
    local install_dir="$1" env_file="$2" base_name="$3" subpath="$4" out="$5"
    if ! command_available docker; then
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
# From: Issue #1683 | PR #1858
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
    ensure_default_install_dir
    local install_dir="$DEFAULT_INSTALL_DIR"
    local dest_root="$BACKUP_ROOT"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dest) require_value "$1" "${2:-}"; dest_root="$2"; shift 2 ;;
            *) install_dir="$1"; shift ;;
        esac
    done
    install_dir=$(resolve_stack_dir_checked "$install_dir") || exit $?
    dest_root=$(realpath -m "$dest_root")
    install_missing_tools tar

    local env_file="" cache_env_file="" state_dir=""
    stack_env_context "$install_dir" env_file cache_env_file state_dir

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
    # From: Issue #1683 | PR #1858
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
    secrets_file=$(mktemp) || die "Could not create a temporary file for secret redaction (exit $?)."
    chmod 600 "$secrets_file" || die "Failed to restrict $secrets_file (exit $?)."

    print_step "Collecting diagnostic bundle for issue report"

    logbundle_collect_secret_values "${env_files[@]}" > "$secrets_file" \
        || die "Cannot collect the secret values to redact (exit $?); no log bundle was written."

    # What: writes Docker, Compose, disk and distro facts
    # Why: the fuller version strings help triage
    # From: Issue #1683 | PR #1858
    {
        printf 'Generated: %s UTC\n' "$stamp"
        printf 'Install directory: %s\n' "$install_dir"
        printf 'Docker: %s\n' "$(docker --version 2>&1 || printf ' (exit %s)' "$?")"
        printf 'Docker Compose: %s\n' "$(docker compose version 2>&1 || printf ' (exit %s)' "$?")"
        printf 'Kernel: %s\n' "$(uname -srm 2>&1 || printf ' (exit %s)' "$?")"
        printf 'OS: %s\n' "$(n=$(os_release_field PRETTY_NAME); [[ -n "$n" ]] \
            || n="$(os_release_field ID) $(os_release_field VERSION_ID)"; n="${n# }"; n="${n% }"; printf '%s' "${n:-unknown}")"
        printf '\nDisk usage:\n'
        df -h 2>&1 || printf '(df failed, exit %s)\n' "$?"
    } | logbundle_redact_stream "$secrets_file" > "$dest/host-facts.txt"

    print_step "Container status and configuration"
    logbundle_capture "$secrets_file" "$dest/compose-ps.txt" stack_compose "$install_dir" "$env_file" ps
    # What: config output is redacted like logs
    # Why: config re-interpolates ${VAR} secret values
    # From: Issue #1683 | PR #1858
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
    local svc log_lines
    log_lines=$(prod_env_default SETUP_LOGBUNDLE_LOG_LINES) || exit $?
    for svc in "${services[@]}"; do
        [[ -n "$svc" ]] || continue
        print_ok "Logs: $svc"
        logbundle_capture "$secrets_file" "$dest/logs/$svc.log" \
            stack_compose "$install_dir" "$env_file" logs --no-color --timestamps --tail="$log_lines" "$svc"
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
    logbundle_named_volume_listing "$install_dir" "$env_file" dhcp-config-snapshots config-snapshots \
        "$dest/known-good-snapshots/dhcp.txt"
    logbundle_named_volume_listing "$install_dir" "$env_file" dns-config-snapshots config-snapshots \
        "$dest/known-good-snapshots/dns.txt"
    # What: Kea snapshots: host path, then named volume
    # Why: pre-v0.3.0 dev stacks used a named volume
    # From: Issue #1683 | PR #1858
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
  logs/<service>.log           docker compose logs --tail=${log_lines} per service
  env/.env, env/.env.local      configuration, with secrets redacted
  known-good-snapshots/        directory listings only (no file content)

Every credential-shaped value (API keys, TSIG keys, passwords, tokens) has
been replaced with [REDACTED] everywhere it could appear in this bundle.
Review the contents before attaching this archive to a GitHub issue --
automatic upload is intentionally not part of this tool.
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
    printf '\n%sAttach this file to your GitHub issue:%s %s\n\n' "${BOLD}" "${RESET}" "$archive"
)

# What: rolls a Kea or DNS service back to a snapshot
# Why: works when the Admin UI is unreachable
# From: Issue #1683 | PR #1858
cmd_reset_to_last_known_good_config() {
    ensure_default_install_dir
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
    # From: Issue #1683 | PR #1858
    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?

    # What: positional[2] is zone (DNS) or snapshot (Kea)
    # Why: DNS snapshots are per zone; Kea has one file
    # From: Issue #1683 | PR #1858
    case "$service" in
        dns|pdns)
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
            # What: dns and pdns both target the dns service
            # Why: one container runs the rollback listener
            # From: Issue #1683 | PR #1912
            reset_dns_to_last_known_good_config "dns" "$install_dir" "$zone" "$snapshot_id" "$assume_yes"
            ;;
        "")
            die "Usage: ./setup.sh reset-to-last-known-good-config <service> [install-dir] [snapshot-id]. Supported services: kea, dns. Run './setup.sh reset-to-last-known-good-config --help' for details."
            ;;
        *)
            die "Unknown service '$service' for reset-to-last-known-good-config. Supported: kea, dns. Run './setup.sh reset-to-last-known-good-config --help' for details."
            ;;
    esac
}

# What: lists finalized Kea snapshot ids, oldest first
# Why: staging dirs are skipped; ids are fixed-width digits
# From: Issue #1683 | PR #1858
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
# Why: the one sender in setup.sh; the UI sends the same
# From: Issue #1683 | PR #1858
kea_ctrl_send() {
    local kea_ctrl_url="$1" kea_ctrl_user="$2" kea_ctrl_token="$3" body="$4"
    local out http_status response

    # What: passes the Basic-Auth token to curl via -K stdin
    # Why: -u would expose the token in process argv
    # From: Issue #1304 | PR #1550
    local kea_ctrl_token_escaped
    kea_ctrl_token_escaped=$(printf '%s' "$kea_ctrl_token" | sed 's/\\/\\\\/g; s/"/\\"/g')
    if ! out=$(printf 'user = "%s:%s"\n' "$kea_ctrl_user" "$kea_ctrl_token_escaped" | curl -sS -w '\n%{http_code}' -X POST \
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
    printf '%s\n' "$response"
}

# What: one Kea command that must carry result 0
# Why: Kea answers per service; result 0 means success
# From: Issue #1683 | PR #1912
kea_ctrl_post() {
    local response
    response=$(kea_ctrl_send "$@") || exit $?
    kea_reply_check "$response"
    printf '%s\n' "$response"
}

# What: stops unless a Kea reply carries result 0
# Why: setup.sh and ci.sh judge Kea replies in one place
# From: Issue #1683 | PR #1912
kea_reply_check() {
    local response="$1" result_code result_text
    result_code=$(json_value 'if type == "array" then .[0] else . end | .result' "$response") \
        || die "Unrecognized response from Kea's Control Agent: ${response}"
    result_text=$(json_value 'if type == "array" then .[0] else . end | .text' "$response") \
        || die "Unrecognized response from Kea's Control Agent: ${response}"
    [[ "$result_code" =~ ^-?[0-9]+$ ]] || die "Unrecognized response from Kea's Control Agent: ${response}"
    if [[ "$result_code" != "0" ]]; then
        die "Kea's Control Agent rejected the command (result=${result_code}): ${result_text:-<no message>}"
    fi
}

# What: one dhcp4 command; the config is its arguments
# Why: config-test, -set and -write share one body shape
# From: Issue #1683 | PR #1858
kea_dhcp4_command() {
    local body="{\"command\":\"$4\",\"service\":[\"dhcp4\"]"
    [[ $# -lt 5 ]] || body+=",\"arguments\":$5"
    kea_ctrl_post "$1" "$2" "$3" "${body}}"
}

# What: host dir of KEA_CONFIG_SNAPSHOT_DIR via the ui mount
# Why: the UI writes there; the dir is a SOT default
# From: Issue #1683 | PR #1858
kea_snapshot_host_dir() {
    local install_dir="$1" env_file="$2" kea_dir="$3" snapshot_dir target
    snapshot_dir=$(prod_env_default KEA_CONFIG_SNAPSHOT_DIR) || exit $?
    target=$(compose_config_value "$install_dir" "$env_file" \
        "[.services.ui.volumes[]? | select(.source == \$src) | .target] | first" --arg src "$kea_dir") || exit $?
    [[ -n "$target" ]] || die "The ui service of $install_dir does not mount $kea_dir."
    case "$snapshot_dir" in
        "$target"/*) printf '%s/%s\n' "$kea_dir" "${snapshot_dir#"$target"/}" ;;
        *) die "KEA_CONFIG_SNAPSHOT_DIR ($snapshot_dir) is not under the Kea data mount $target." ;;
    esac
}

# What: rolls Kea back to a snapshot through Control Agent
# Why: config-test, config-set and config-write run in order
# From: Issue #1683 | PR #1858
reset_kea_to_last_known_good_config() {
    local install_dir="$1" snapshot_id="$2" assume_yes="${3:-0}"
    local env_file state_dir kea_dir snapshot_root
    local kea_ctrl_host kea_ctrl_user kea_ctrl_token kea_ctrl_url kea_ctrl_port loopback_ip
    local -a snapshot_ids=()
    local sid config_json

    env_file=$(require_stack_env_file "$install_dir") || exit $?
    install_missing_tools curl jq

    kea_ctrl_token=$(get_env_var KEA_CTRL_TOKEN "$env_file") || exit $?
    [[ -n "$kea_ctrl_token" ]] \
        || die "KEA_CTRL_TOKEN is empty or missing in $env_file -- cannot authenticate to Kea's Control Agent."

    kea_ctrl_host=$(get_env_var KEA_CTRL_HOST "$env_file") || exit $?
    loopback_ip=$(prod_env_default LOOPBACK_BIND_IP) || exit $?
    kea_ctrl_host="${kea_ctrl_host:-$loopback_ip}"
    # What: maps a 0.0.0.0 Control Agent host to loopback
    # Why: dhcp uses host networking; 0.0.0.0 is no target
    # From: Issue #1683 | PR #1858
    [[ "$kea_ctrl_host" = "0.0.0.0" ]] && kea_ctrl_host="$loopback_ip"
    # What: Control Agent user and port from the SOT
    # Why: the SOT owns both; dhcp, ui and this read them
    # From: Issue #1683 | PR #1912
    kea_ctrl_user=$(prod_env_default KEA_CTRL_USER) || exit $?
    kea_ctrl_port=$(prod_env_default KEA_CTRL_PORT) || exit $?
    [[ "$kea_ctrl_port" =~ ^[0-9]+$ ]] || die "The SOT KEA_CTRL_PORT is not a port number."
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
        # From: Issue #1683 | PR #1858
        printf '  %s  (%s UTC)\n' "$sid" "$(date -u -d "@$(( 10#$sid / 1000000000 ))" '+%Y-%m-%d %H:%M:%S' 2>&1 || printf ' (exit %s)' "$?")"
    done

    if [[ -z "$snapshot_id" ]]; then
        snapshot_id="${snapshot_ids[${#snapshot_ids[@]}-1]}"
        warn_newest_snapshot "$snapshot_id"
    fi
    [[ -f "$snapshot_root/$snapshot_id/dhcp4.json" ]] \
        || die "Snapshot '$snapshot_id' not found under $snapshot_root."
    confirm_snapshot_rollback "Kea" "$snapshot_id" "$assume_yes"

    config_json=$(cat "$snapshot_root/$snapshot_id/dhcp4.json")

    print_step "Validating snapshot $snapshot_id (config-test)"
    kea_dhcp4_command "$kea_ctrl_url" "$kea_ctrl_user" "$kea_ctrl_token" config-test "$config_json"
    print_ok "Snapshot validated."

    print_step "Applying snapshot $snapshot_id (config-set)"
    kea_dhcp4_command "$kea_ctrl_url" "$kea_ctrl_user" "$kea_ctrl_token" config-set "$config_json"
    print_ok "Snapshot applied to the running Kea server."

    print_step "Persisting snapshot $snapshot_id (config-write)"
    kea_dhcp4_command "$kea_ctrl_url" "$kea_ctrl_user" "$kea_ctrl_token" config-write
    print_ok "Snapshot persisted to kea-dhcp4.conf."

    print_ok "Kea rolled back to known-good snapshot $snapshot_id (validated, applied, and persisted)."
    print_warn "This CLI fallback does not itself record a fresh known-good snapshot of the restored state (services/ui/src/main.rs's rollback_kea_snapshot does, when reached via the Admin UI) -- the next config change made through the Admin UI will."
}

# What: adds the trailing dot to a zone name if missing
# Why: the rollback listener uses dot-terminated names
# From: Issue #1683 | PR #1858
canonical_dns_zone() {
    local zone="$1"
    if [[ "$zone" == *. ]]; then
        printf '%s\n' "$zone"
    else
        printf '%s.\n' "$zone"
    fi
}

# What: warns that the newest snapshot id $1 is used
# Why: the Kea and the DNS rollback share the one text
# From: Issue #1683 | PR #1858
warn_newest_snapshot() {
    print_warn "No snapshot id given; defaulting to the newest: $1"
}

# What: asks before rolling $1 back to snapshot $2
# Why: the Kea and the DNS rollback share one question
# From: Issue #1683 | PR #1858
confirm_snapshot_rollback() {
    local target="$1" snapshot_id="$2" assume_yes="$3"
    [[ "$assume_yes" != "1" ]] || return 0
    confirm "Roll ${target} back to snapshot ${snapshot_id} now? This applies immediately. [y/N]" "N" \
        || die "Cancelled."
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
    json_value ".zones[\$zone][]? | \"\(.id) \(.created_unix)\"" "$1" --arg zone "$2"
}

# What: runs one listener request inside the DNS container
# Why: the listener is not published to the host
# From: Issue #1683 | PR #1858
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

    local exec_script placeholder_fn
    exec_script=$(cat <<'SCRIPT'
            key="$PDNS_API_KEY"
            ! secret_value_is_placeholder "$key" || key=""
            secrets=$(lancache-watchdog get LANCACHE_SHARED_SECRET_DIR) || exit 7
            if [ -z "$key" ] && [ -s "$secrets/pdns-api-key" ]; then
                key=$(tr -d "\n" < "$secrets/pdns-api-key")
            fi
            if [ -z "$key" ]; then
                echo "DNS_ROLLBACK_EXEC_NO_API_KEY"
                exit 9
            fi
            port=$(lancache-watchdog get DNS_ROLLBACK_PORT) || exit 7
            lo=$(lancache-watchdog get LOOPBACK_BIND_IP) || exit 7
            m="$1"; p="$2"; b="$3"
            if [ "$m" = "POST" ]; then
                curl -sS -w "\n%{http_code}" -X POST \
                    -H "X-API-Key: $key" -H "Content-Type: application/json" -d "$b" \
                    "http://$lo:$port$p" || { echo "DNS_ROLLBACK_EXEC_CURL_FAILED"; exit 8; }
            else
                curl -sS -w "\n%{http_code}" \
                    -H "X-API-Key: $key" "http://$lo:$port$p" || { echo "DNS_ROLLBACK_EXEC_CURL_FAILED"; exit 8; }
            fi
SCRIPT
    ) || die "Cannot build the listener request script (exit $?)."
    placeholder_fn=$(declare -f secret_value_is_placeholder) \
        || die "Cannot read secret_value_is_placeholder (exit $?)."
    exec_script="${placeholder_fn}"$'\n'"${exec_script}"
    stdout_val=$(stack_compose "$install_dir" "$env_file" -p "$project" exec -T "$container" sh -c "$exec_script" sh "$method" "$path" "$body" 2>"$err_file") || rc=$?
    exec_err=$(cat "$err_file") || die "Cannot read $err_file (exit $?)."

    if [[ $rc -ne 0 ]]; then
        case "$stdout_val" in
            *DNS_ROLLBACK_EXEC_NO_API_KEY*)
                die "PDNS_API_KEY could not be resolved inside the $container container (no usable value in its environment and nothing on the shared-secrets volume yet). Is the stack fully started?"
                ;;
            *DNS_ROLLBACK_EXEC_CURL_FAILED*)
                die "Failed to reach the rollback listener inside $container (curl could not connect to its rollback port). Is nats-subscriber running there?"
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
# From: Issue #1683 | PR #1858
reset_dns_to_last_known_good_config() {
    local container="$1" install_dir="$2" zone="$3" snapshot_id="$4" assume_yes="${5:-0}"
    local env_file snapshots_body zone_canon rollback_body resp zone_list entry_list
    local -a zone_names=()
    local -a entries=()
    local idx n entry eid ecreated found zn
    local applied zone_check_passed flush_ok republished changed_names flush_failed

    env_file=$(require_stack_env_file "$install_dir") || exit $?
    install_missing_tools jq

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
        warn_newest_snapshot "$snapshot_id"
    fi

    found=0
    for entry in "${entries[@]}"; do
        eid="${entry%% *}"
        [[ "$eid" = "$snapshot_id" ]] && { found=1; break; }
    done
    [[ "$found" -eq 1 ]] \
        || die "Snapshot '$snapshot_id' not found for zone $zone_canon on $container."

    confirm_snapshot_rollback "$container's zone $zone_canon" "$snapshot_id" "$assume_yes"

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

# What: writes the previous .env back and restarts the stack
# Why: IPs that fail the health gate must not stay active
# From: Issue #1683 | PR #1858
restore_update_ip_env() {
    local install_dir="$1" env_file="$2" saved="$3" rc=0
    write_file_atomically "$env_file" <<< "$saved" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        print_error "Failed to write the previous $env_file back (exit $rc)."
        return 1
    fi
    stack_compose "$install_dir" "$env_file" up -d || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        print_error "Failed to restart the stack with the previous IPs (exit $rc)."
        return 1
    fi
    print_warn "The previous IPs are active again"
}

# What: reconfigures IPs of an existing install
# Why: uses the install's directory, not the repo
# From: Issue #1683 | PR #1858
cmd_update_ip() {
    ensure_default_install_dir
    local install_dir="${1:-$DEFAULT_INSTALL_DIR}"
    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?

    printf "\n"
    printf '%s╔═══════════════════════════════════════╗%s\n' "${BOLD}" "${RESET}"
    printf '%s║  LanCache-NG — Reconfigure IPs        ║%s\n' "${BOLD}" "${RESET}"
    printf '%s╚═══════════════════════════════════════╝%s\n' "${BOLD}" "${RESET}"
    printf "\n"

    [[ "$(id -u)" = "0" ]] \
        || die "This script must be run as root (sudo ./setup.sh update-ip [install-dir])."
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die_no_stack_found "$install_dir"
    assert_prebuilt_image_platform_supported

    print_step "Reading current configuration"

    # What: only the runtime .env holds IPs; compose derives
    # Why: dns gets its IPs from IP_HTTP and IP_HTTPS
    # From: Issue #1683 | PR #1858
    local deploy_env
    deploy_env=$(runtime_env_file_for_install_dir "$install_dir")
    [[ -f "$deploy_env" ]] || die "Configuration not found: $deploy_env"

    local current_ip_http current_ip_https
    local new_ip_http new_ip_https
    current_ip_http=$(get_env_var IP_HTTP "$deploy_env") || exit $?
    current_ip_https=$(get_env_var IP_HTTPS "$deploy_env") || exit $?

    # What: defaults for UI_BIND_IP and DHCP DNS follow IP_*
    # Why: only install-time default values may be rewritten
    # From: Issue #1683 | PR #1858
    local current_ui_bind_ip current_dhcp_mode
    local current_dhcp_dns_primary current_dhcp_dns_secondary
    current_ui_bind_ip=$(get_env_var UI_BIND_IP "$deploy_env") || exit $?
    current_dhcp_mode=$(get_env_var DHCP_MODE "$deploy_env") || exit $?
    current_dhcp_dns_primary=$(get_env_var DHCP_DNS_PRIMARY "$deploy_env") || exit $?
    current_dhcp_dns_secondary=$(get_env_var DHCP_DNS_SECONDARY "$deploy_env") || exit $?

    printf '\n  %sCurrent configuration:%s\n' "${BOLD}" "${RESET}"
    printf "    HTTP IP:     %s\n" "$current_ip_http"
    printf "    HTTPS IP:    %s\n" "$current_ip_https"
    printf "\n"

    print_step "Prompt for new IPs"

    ask_checked new_ip_http "New HTTP mode IP" "$current_ip_http" is_valid_ipv4 "Invalid IPv4 address"

    printf "\n"
    ask_checked new_ip_https "New HTTPS mode IP" "$current_ip_https" is_valid_ipv4 "Invalid IPv4 address"

    require_separate_lan_ips "$new_ip_http" "$new_ip_https"

    printf "\n"
    printf '  %sNew configuration:%s\n' "${BOLD}" "${RESET}"
    printf "    HTTP IP:     %s\n" "$new_ip_http"
    printf "    HTTPS IP:    %s\n" "$new_ip_https"
    printf "\n"

    confirm "Apply changes? [y/N]" "N" || { printf "\n  Cancelled.\n\n"; exit 0; }

    # What: the same baseline and gate as ./setup.sh update
    # Why: new IPs that fail the gate must not stay active
    # From: Issue #1683 | PR #1858
    local services saved_env apply_rc=0
    local -a all_services
    install_missing_tools curl dig jq
    _UPDATE_ENV_FILE="$deploy_env"
    _UPDATE_STACK_DIR="$install_dir"
    print_step "Capturing health baseline"
    services=$(stack_compose "$install_dir" "$deploy_env" config --services) \
        || die "Cannot list the services of $install_dir (exit $?); nothing was changed."
    mapfile -t all_services <<< "$services"
    capture_stack_health_baseline "${all_services[@]}"
    saved_env=$(cat -- "$deploy_env") || die "Cannot read $deploy_env (exit $?); nothing was changed."

    print_step "Updating configuration files"

    set_env_key IP_HTTP "$new_ip_http" "$deploy_env"
    set_env_key IP_HTTPS "$new_ip_https" "$deploy_env"
    print_ok "Updated: $deploy_env (IP_HTTP, IP_HTTPS)"

    # What: rewrites UI_BIND_IP while it equals old IP
    # Why: an empty or explicit value stays untouched
    # From: Issue #666 | PR #745
    if [[ -n "$current_ui_bind_ip" && "$current_ui_bind_ip" = "$current_ip_http" ]]; then
        set_env_key UI_BIND_IP "$new_ip_http" "$deploy_env"
        print_ok "Updated: $deploy_env (UI_BIND_IP)"
    fi

    # What: rewrites DHCP DNS while it equals old IP
    # Why: dnsmasq-proxy reads these; Kea derives its own
    # From: Issue #1683 | PR #1858
    if [[ "$current_dhcp_mode" = "dnsmasq-proxy" ]]; then
        if [[ -n "$current_dhcp_dns_primary" && "$current_dhcp_dns_primary" = "$current_ip_http" ]]; then
            set_env_key DHCP_DNS_PRIMARY "$new_ip_http" "$deploy_env"
            print_ok "Updated: $deploy_env (DHCP_DNS_PRIMARY)"
        fi
        if [[ -n "$current_dhcp_dns_secondary" && "$current_dhcp_dns_secondary" = "$current_ip_https" ]]; then
            set_env_key DHCP_DNS_SECONDARY "$new_ip_https" "$deploy_env"
            print_ok "Updated: $deploy_env (DHCP_DNS_SECONDARY)"
        fi
    fi

    print_step "Restarting containers"

    apply_stack_update_ordered "$install_dir" restore_update_ip_env "$install_dir" "$deploy_env" "$saved_env" \
        || apply_rc=$?
    case "$apply_rc" in
        0) ;;
        1) die "The new IPs failed the health gate; the previous IPs are active again. Check that the new IPs are assigned to this host." ;;
        *) die "The new IPs failed the health gate, and restoring the previous ones failed too. Check: $SCRIPT_DIR/setup.sh compose $install_dir logs" ;;
    esac

    printf "\n"
    printf '%s%s════════════════════════════════════════%s\n' "${BOLD}" "${GREEN}" "${RESET}"
    printf '%s%s  Reconfiguration complete!%s\n' "${BOLD}" "${GREEN}" "${RESET}"
    printf '%s%s════════════════════════════════════════%s\n' "${BOLD}" "${GREEN}" "${RESET}"
    printf "\n"
    printf "  Done. Update your clients to use the new DNS IP.\n\n"
}

# What: puts the previous upstream values back, restarts dns
# Why: a setting that fails a check must not stay active
# From: Issue #1918 | PR #1858
restore_dns_upstream() {
    local install_dir="$1" env_file="$2" rc=0
    set_env_key DNS_UPSTREAM_SERVERS "$3" "$env_file"
    set_env_key DNS_UPSTREAM_ZONES "$4" "$env_file"
    set_env_key DNS_UPSTREAM_UNSIGNED_ZONES "$5" "$env_file"
    set_env_key DNS_LOCAL_REVERSE_ZONES "$6" "$env_file"
    stack_compose "$install_dir" "$env_file" up -d dns || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        print_error "Failed to restart dns with the previous external DNS setting (exit $rc)."
        return 1
    fi
    print_warn "The previous external DNS setting is active again"
}

# What: true if the live recursor config matches the setting
# Why: the watchdog starts without upstream on a bad value
# From: Issue #1918 | PR #1858
dns_upstream_is_live() {
    local install_dir="$1" env_file="$2" servers="$3" run_dir cid rc=0
    run_dir=$(prod_env_default SUPERVISE_RUN_DIR) || exit $?
    cid=$(stack_compose "$install_dir" "$env_file" ps -q dns) \
        || die "Failed to look up the dns container of $install_dir (exit $?)."
    if [[ -z "$cid" ]]; then
        print_error "No dns container is running in $install_dir."
        return 1
    fi
    docker exec "$cid" grep -r -q -e 'forward_zones_recurse:' "$run_dir" || rc=$?
    case "$rc" in
        0) [[ -n "$servers" ]] ;;
        1) [[ -z "$servers" ]] ;;
        *)
            print_error "Cannot read the recursor config in the dns container (exit $rc)."
            return 1
            ;;
    esac
}

# What: shows and changes the upstream DNS of an install
# Why: set, change or remove it without a reinstall
# From: Issue #1918 | PR #1858
cmd_configure_upstream_dns() {
    ensure_default_install_dir
    local install_dir="${1:-$DEFAULT_INSTALL_DIR}"
    install_dir=$(resolve_stack_dir "$(realpath -m "$install_dir")") || exit $?

    printf "\n"
    printf '%s╔═══════════════════════════════════════╗%s\n' "${BOLD}" "${RESET}"
    printf '%s║  LanCache-NG — External DNS server    ║%s\n' "${BOLD}" "${RESET}"
    printf '%s╚═══════════════════════════════════════╝%s\n' "${BOLD}" "${RESET}"
    printf "\n"

    [[ "$(id -u)" = "0" ]] \
        || die "This script must be run as root (sudo ./setup.sh configure-upstream-dns [install-dir])."
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die_no_stack_found "$install_dir"

    print_step "Reading current configuration"

    local env_file ip_http ip_https lan services apply_rc=0
    local old_servers old_zones old_unsigned old_reverse dhcp_mode
    local -a all_services
    env_file=$(runtime_env_file_for_install_dir "$install_dir")
    [[ -f "$env_file" ]] || die "Configuration not found: $env_file"
    old_servers=$(get_env_var DNS_UPSTREAM_SERVERS "$env_file") || exit $?
    old_zones=$(get_env_var DNS_UPSTREAM_ZONES "$env_file") || exit $?
    old_unsigned=$(get_env_var DNS_UPSTREAM_UNSIGNED_ZONES "$env_file") || exit $?
    old_reverse=$(env_or_sot_default DNS_LOCAL_REVERSE_ZONES "$env_file") || exit $?
    dhcp_mode=$(env_or_sot_default DHCP_MODE "$env_file") || exit $?
    ip_http=$(get_env_var IP_HTTP "$env_file") || exit $?
    ip_https=$(get_env_var IP_HTTPS "$env_file") || exit $?
    lan=$(env_or_sot_default DHCP_DOMAIN "$env_file") || exit $?

    printf '\n  %sCurrent configuration:%s\n' "${BOLD}" "${RESET}"
    printf "    DNS servers:        %s\n" "${old_servers:-none (LanCache-NG resolves names itself)}"
    printf "    Forwarded domains:  %s\n" "${old_zones:-all}"
    printf "    No DNSSEC:          %s\n" "${old_unsigned:-none}"
    printf "    Local PTR zones:    %s\n\n" "$([[ "$old_reverse" = 1 ]] && echo on || echo off)"

    print_step "Prompt for the new setting"

    prompt_dns_upstream "$old_servers" "$old_zones" "$old_unsigned" "${ip_http},${ip_https}" "$lan"
    prompt_dns_local_reverse_zones "$old_reverse" "$dhcp_mode"
    if [[ "$DNS_UPSTREAM_SERVERS" = "$old_servers" && "$DNS_UPSTREAM_ZONES" = "$old_zones" \
        && "$DNS_UPSTREAM_UNSIGNED_ZONES" = "$old_unsigned" \
        && "$DNS_LOCAL_REVERSE_ZONES" = "$old_reverse" ]]; then
        print_ok "No change. Nothing was written and no container was restarted."
        exit 0
    fi

    printf '\n  %sNew configuration:%s\n' "${BOLD}" "${RESET}"
    printf "    DNS servers:        %s\n" "${DNS_UPSTREAM_SERVERS:-none (LanCache-NG resolves names itself)}"
    printf "    Forwarded domains:  %s\n" "${DNS_UPSTREAM_ZONES:-all}"
    printf "    No DNSSEC:          %s\n" "${DNS_UPSTREAM_UNSIGNED_ZONES:-none}"
    printf "    Local PTR zones:    %s\n\n" "$([[ "$DNS_LOCAL_REVERSE_ZONES" = 1 ]] && echo on || echo off)"

    confirm "Apply changes? [y/N]" "N" || { printf "\n  Cancelled.\n\n"; exit 0; }

    # What: the same baseline and gate as ./setup.sh update
    # Why: one health-gated restart path, no second copy
    # From: Issue #1918 | PR #1858
    install_missing_tools curl dig jq
    _UPDATE_ENV_FILE="$env_file"
    _UPDATE_STACK_DIR="$install_dir"
    print_step "Capturing health baseline"
    services=$(stack_compose "$install_dir" "$env_file" config --services) \
        || die "Cannot list the services of $install_dir (exit $?); nothing was changed."
    mapfile -t all_services <<< "$services"
    capture_stack_health_baseline "${all_services[@]}"

    print_step "Saving configuration"
    set_env_key DNS_UPSTREAM_SERVERS "$DNS_UPSTREAM_SERVERS" "$env_file"
    set_env_key DNS_UPSTREAM_ZONES "$DNS_UPSTREAM_ZONES" "$env_file"
    set_env_key DNS_UPSTREAM_UNSIGNED_ZONES "$DNS_UPSTREAM_UNSIGNED_ZONES" "$env_file"
    set_env_key DNS_LOCAL_REVERSE_ZONES "$DNS_LOCAL_REVERSE_ZONES" "$env_file"
    print_ok "Saved in $env_file"

    apply_stack_update_ordered "$install_dir" restore_dns_upstream "$install_dir" "$env_file" \
        "$old_servers" "$old_zones" "$old_unsigned" "$old_reverse" || apply_rc=$?
    case "$apply_rc" in
        0) ;;
        1) die "The new external DNS setting failed the health gate; the previous setting is active again." ;;
        *) die "The new setting failed the health gate, and restoring the previous one failed too. Check: $SCRIPT_DIR/setup.sh compose $install_dir logs dns" ;;
    esac
    if ! dns_upstream_is_live "$install_dir" "$env_file" "$DNS_UPSTREAM_SERVERS"; then
        restore_dns_upstream "$install_dir" "$env_file" "$old_servers" "$old_zones" "$old_unsigned" "$old_reverse" \
            || die "The dns container rejected the new setting, and restoring the previous one failed. Check: $SCRIPT_DIR/setup.sh compose $install_dir logs dns"
        die "The dns container rejected the new setting (see: $SCRIPT_DIR/setup.sh compose $install_dir logs dns); the previous setting is active again."
    fi
    print_ok "External DNS setting applied and active in the dns container"
}

# What: a repo file's text: checkout or the same ref
# Why: one owner; a curl|bash secondary has no checkout
# From: Issue #1683 | PR #1858
lancache_repo_file_text() {
    local path="$1" local_file="$SCRIPT_DIR/$1" ref raw
    if [[ -f "$local_file" ]]; then
        cat -- "$local_file" || die "Failed to read $local_file (exit $?)."
        return 0
    fi
    ref=$(resolve_setup_bootstrap_ref) || exit $?
    raw="https://raw.githubusercontent.com/${LANCACHE_REPO_URL#https://github.com/}/${ref:-HEAD}/${path}"
    curl -fsSL "$raw" || die "Failed to download ${path} from $raw (exit $?)."
}

# What: dies naming each NAME=VALUE pair with empty value
# Why: arguments and response fields share the check
# From: Issue #1683 | PR #1858
die_if_any_empty() {
    local message="$1" pair
    local -a missing=()
    shift
    for pair in "$@"; do
        [[ -n "${pair#*=}" ]] || missing+=("${pair%%=*}")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "${message}: ${missing[*]}"
}

# What: secondary setup consumes primary credentials
# Why: it must not modify the primary host
# From: Issue #1683 | PR #1858
cmd_secondary() {
    local primary="" token="" name="" ip_http="" listen_ip="" ip_https="" listen_ip_https="" rotate=0
    local out http_status response secondary_dir cmd ddns_tsig_key dns_xfr_primary tag_input
    local nats_url nats_user nats_password consumer_name pdns_api_key
    local response_image_registry response_image_prefix response_image_channel response_image_tag
    local existing_env_file lancache_image_registry lancache_image_prefix lancache_image_channel lancache_image_tag
    local explicit_lancache_image_tag keep_known_good_configs
    local preflight_dir preflight_env_file preflight_registry preflight_prefix preflight_channel preflight_env_tag
    local preflight_tag preflight_verified_registry="" preflight_verified_prefix="" preflight_verified_tag=""
    local secondary_env_file compose_out bad_response secondary_compose
    local channel_words pinned release dns_port

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
            --ip-http)
                require_value "$1" "${2:-}"
                ip_http="$2"
                shift 2
                ;;
            --listen-ip)
                require_value "$1" "${2:-}"
                listen_ip="$2"
                shift 2
                ;;
            --ip-https)
                require_value "$1" "${2:-}"
                ip_https="$2"
                shift 2
                ;;
            --listen-ip-https)
                require_value "$1" "${2:-}"
                listen_ip_https="$2"
                shift 2
                ;;
            --rotate)
                rotate=1
                shift
                ;;
            -h|--help)
                print_command_help secondary
                exit 0
                ;;
            *)
                print_command_help secondary >&2
                die "Unknown argument: $1"
                ;;
        esac
    done

    die_if_any_empty "Required argument(s) missing" \
        "--primary=$primary" "--token=$token" "--name=$name" "--ip-http=$ip_http"

    for cmd in curl docker jq; do
        command_available "$cmd" \
            || die "$cmd is not installed or is not in PATH; run: sudo $0 install-requirements-secondary"
    done

    compose_out=$(docker compose version 2>&1) \
        || die "'docker compose' is not available; install Docker Compose v2 before continuing (exit $?): $compose_out"

    [[ "$name" =~ ^[a-zA-Z0-9-]+$ ]] \
        || die "--name must contain only alphanumeric characters and dashes"
    is_valid_ipv4 "$ip_http" \
        || die "--ip-http must be a valid IPv4 address"
    if [[ -n "$listen_ip" ]]; then
        is_valid_ipv4 "$listen_ip" \
            || die "--listen-ip must be a valid IPv4 address"
    else
        listen_ip=$(detect_lan_ip) \
            || die "Could not auto-detect a secondary bind IP. Re-run with --listen-ip <ip>."
    fi
    dns_port=$(prod_env_default DNS_PORT) || exit $?
    listen_ip=$(secondary_choose_listen_ip "$listen_ip") \
        || die "No usable secondary bind IP on port ${dns_port} (exit $?; see above). Re-run with --listen-ip <ip> after freeing the port."
    print_ok "Secondary DNS bind IP: ${listen_ip}"
    if [[ -n "$ip_https" || -n "$listen_ip_https" ]]; then
        [[ -n "$ip_https" && -n "$listen_ip_https" ]] \
            || die "--ip-https and --listen-ip-https must be given together"
        is_valid_ipv4 "$ip_https" \
            || die "--ip-https must be a valid IPv4 address"
        is_valid_ipv4 "$listen_ip_https" \
            || die "--listen-ip-https must be a valid IPv4 address"
        listen_ip_https=$(secondary_choose_listen_ip "$listen_ip_https") \
            || die "No usable secondary https bind IP on port ${dns_port} (exit $?; see above). Re-run with --listen-ip-https <ip> after freeing the port."
        [[ "$listen_ip_https" != "$listen_ip" ]] \
            || die "the https bind IP must differ from the http bind IP ${listen_ip}"
        print_ok "Secondary https DNS bind IP: ${listen_ip_https}"
    fi
    assert_prebuilt_image_platform_supported
    # What: the compose file is fetched before registration
    # Why: a fetch failure must not follow a registration
    # From: Issue #1683 | PR #1858
    secondary_compose=$(lancache_repo_file_text deploy/secondary/docker-compose.yml) || exit $?
    # What: the CDN list of the same ref as the compose
    # Why: the secondary dns mounts it; missing = broken
    # From: Issue #1683 | PR #1858
    local cdn_file cdn_domains
    cdn_file=$(prod_env_default SETUP_CDN_DOMAINS_REPO_FILE) || exit $?
    cdn_domains=$(lancache_repo_file_text "$cdn_file") || exit $?

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
    # From: Issue #1683 | PR #1858
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
                pinned=$(lancache_release_rows pinned) || exit $?

                # What: pinned channel needs a tag to check
                # Why: only the primary can supply the tag
                # From: Issue #1683 | PR #1858
                if [[ "$preflight_channel" != "$pinned" || -n "$preflight_env_tag" ]]; then
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
    # What: the register route, read from the SOT defaults
    # Why: the ui path has one owner, build-manifest.yml
    # From: Issue #1683 | PR #1912
    local register_route
    register_route=$(prod_env_default UI_ROUTE_SECONDARY_REGISTER) || exit $?
    if ! out=$(printf '%s' "$request" \
        | curl -sS -w '\n%{http_code}' -X POST \
        -H "Content-Type: application/json" \
        -d @- \
        "${primary}${register_route}"); then
        die "Failed to connect to primary server at ${primary}. Check the URL, network connectivity, and that the primary service is running."
    fi
    split_http_response response http_status "$out" \
        || die "Unrecognized response from primary server at ${primary}."

    if [[ "$http_status" = "503" ]]; then
        # What: 503 means primary lacks a reachable NATS URL
        # Why: dns publishes NATS only with NATS_BIND_IP set
        # From: Issue #1683 | PR #1858
        die "Primary server at ${primary} is not configured to register remote secondaries (HTTP 503): it needs NATS_BIND_IP (or the more specific NATS_ADVERTISE_URL) set in its .env/.env.local to a NATS address this secondary can reach, AND its 'dns' service recreated -- e.g. docker compose up -d dns if the variable is in .env, or docker compose --env-file .env.local up -d dns if it is in .env.local (Compose does not auto-load .env.local) -- so NATS actually publishes that address; restarting only the ui container is not enough. See docs/architecture-ng.md's \"Remote secondary NATS access\" section."
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
    # What: the secondary takes the primary's PTR switch
    # Why: both must serve the same private reverse zones
    # From: Issue #1918 | PR #1858
    local local_reverse
    local_reverse=$(json_value .dns_local_reverse_zones "$response") || die "$bad_response"
    validate_env_value DNS_LOCAL_REVERSE_ZONES "$local_reverse"

    die_if_any_empty "Invalid response from primary server; missing field(s)" \
        "nats_url=$nats_url" "nats_user=$nats_user" "nats_password=$nats_password" \
        "consumer_name=$consumer_name" "pdns_api_key=$pdns_api_key" \
        "ddns_tsig_key=$ddns_tsig_key" "dns_xfr_primary=$dns_xfr_primary"

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

    channel_words=$(lancache_channel_words) || exit $?
    pinned=$(lancache_release_rows pinned) || exit $?
    release=$(lancache_release_rows release) || exit $?
    lancache_image_channel="${LANCACHE_IMAGE_CHANNEL:-}"
    if [[ -z "$lancache_image_channel" && -n "$existing_env_file" ]]; then
        lancache_image_channel=$(get_env_var LANCACHE_IMAGE_CHANNEL "$existing_env_file") || exit $?
    fi
    if [[ -z "$lancache_image_channel" && -n "$response_image_channel" ]]; then
        lancache_image_channel="$response_image_channel"
    fi
    if [[ -z "$lancache_image_channel" && -n "${response_image_tag:-}" ]] \
        && list_has_line "$response_image_tag" "$channel_words"; then
        lancache_image_channel="$response_image_tag"
    fi
    if [[ -z "$lancache_image_channel" && "${response_image_tag:-}" =~ ^(sha-|v[0-9]) ]]; then
        lancache_image_channel="$pinned"
    fi
    lancache_image_channel="${lancache_image_channel:-$release}"
    validate_lancache_image_channel "$lancache_image_channel"

    explicit_lancache_image_tag="${LANCACHE_IMAGE_TAG:-}"
    tag_input="$explicit_lancache_image_tag"
    if [[ -z "$explicit_lancache_image_tag" && "$lancache_image_channel" = "$pinned" && -n "$existing_env_file" ]]; then
        tag_input=$(get_env_var LANCACHE_IMAGE_TAG "$existing_env_file") || exit $?
    fi
    if [[ -z "$explicit_lancache_image_tag" && "$lancache_image_channel" = "$pinned" && -z "$tag_input" && -n "$response_image_tag" ]] \
        && ! list_has_line "$response_image_tag" "$channel_words"; then
        tag_input="$response_image_tag"
    fi
    if [[ "$lancache_image_channel" != "$pinned" && -z "$explicit_lancache_image_tag" ]]; then
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
    # What: the secondary pins dns to a digest or the tag
    # Why: the secondary compose has no image default
    # From: Issue #1683 | PR #1858
    local secondary_refs="" secondary_dns_ref=""
    if [[ -n "$lancache_image_tag" ]]; then
        secondary_refs=$(LANCACHE_IMAGE_REGISTRY="$lancache_image_registry" \
            LANCACHE_IMAGE_PREFIX="$lancache_image_prefix" \
            lancache_image_refs_for_tag "" "$lancache_image_tag") \
            || die "Cannot pin the dns image of ${lancache_image_tag} for the secondary (exit $?)."
        secondary_dns_ref=$(awk -F= '$1 == "LANCACHE_IMAGE_REF_DNS" { print substr($0, length($1) + 2) }' <<< "$secondary_refs") \
            || die "Failed to read LANCACHE_IMAGE_REF_DNS from the image pins (exit $?)."
        [[ -n "$secondary_dns_ref" ]] \
            || die "${lancache_image_tag} resolved no LANCACHE_IMAGE_REF_DNS pin for the secondary."
    fi

    # What: verifies tag platform before secondary writes
    # Why: skips a repeat of the rotate preflight check
    # From: Issue #1683 | PR #1858
    if [[ -z "$preflight_verified_tag" \
        || "$lancache_image_registry" != "$preflight_verified_registry" \
        || "$lancache_image_prefix" != "$preflight_verified_prefix" \
        || "$lancache_image_tag" != "$preflight_verified_tag" ]]; then
        assert_resolved_image_tag_platform_supported "$lancache_image_registry" "$lancache_image_prefix" "$lancache_image_tag"
    fi

    # What: KEEP_KNOWN_GOOD_CONFIGS: env, .env, else empty
    # Why: per node; empty means the SOT runtime default
    # From: Issue #615 | PR #625
    keep_known_good_configs="${KEEP_KNOWN_GOOD_CONFIGS:-}"
    if [[ -z "$keep_known_good_configs" && -n "$existing_env_file" ]]; then
        keep_known_good_configs=$(get_env_var KEEP_KNOWN_GOOD_CONFIGS "$existing_env_file") || exit $?
    fi
    # What: the upstream DNS keys survive --rotate
    # Why: rotate rewrites .env; the operator value stays
    # From: Issue #1918 | PR #1858
    local upstream_key upstream_value upstream_rows=""
    if [[ -n "$existing_env_file" ]]; then
        for upstream_key in DNS_UPSTREAM_SERVERS DNS_UPSTREAM_ZONES DNS_UPSTREAM_UNSIGNED_ZONES; do
            upstream_value=$(get_env_var "$upstream_key" "$existing_env_file") || exit $?
            validate_env_value "$upstream_key" "$upstream_value"
            upstream_rows+="${upstream_key}=${upstream_value}"$'\n'
        done
    fi

    write_file_atomically "${secondary_dir}/docker-compose.yml" <<< "$secondary_compose" \
        || die "Failed to write ${secondary_dir}/docker-compose.yml (exit $?)."
    write_file_atomically "${secondary_dir}/${cdn_file##*/}" <<< "$cdn_domains" \
        || die "Failed to write ${secondary_dir}/${cdn_file##*/} (exit $?)."

    secondary_env_file="$(realpath -m "${secondary_dir}/.env")"

    # What: https bind: given IP on DNS port, else loopback
    # Why: compose derives nothing; the SOT owns both values
    # From: Issue #1683 | PR #1912
    dns_https_host_port=""
    if [[ -n "$listen_ip_https" ]]; then
        dns_https_host_port=$(prod_env_default DNS_PORT) || exit $?
    else
        listen_ip_https=$(prod_env_default LOOPBACK_BIND_IP) || exit $?
    fi

    write_file_atomically "${secondary_dir}/.env" <<EOF
IP_HTTP=${ip_http}
LISTEN_IP=${listen_ip}
IP_HTTPS=${ip_https}
LISTEN_IP_HTTPS=${listen_ip_https}
DNS_HTTPS_HOST_PORT=${dns_https_host_port}
PDNS_API_KEY=${pdns_api_key}
DDNS_TSIG_KEY=${ddns_tsig_key}
DNS_XFR_PRIMARY=${dns_xfr_primary}
NATS_URL=${nats_url}
NATS_USER=${nats_user}
NATS_PASSWORD=${nats_password}
NATS_CONSUMER=${consumer_name}
KEEP_KNOWN_GOOD_CONFIGS=${keep_known_good_configs}
DNS_LOCAL_REVERSE_ZONES=${local_reverse}
${upstream_rows}LANCACHE_IMAGE_REGISTRY=${lancache_image_registry}
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

# What: the SOT text, read once per setup.sh process
# Why: each SOT read was its own cat or curl of it
# From: Issue #1683 | PR #1912
LANCACHE_SOT=.github/yaml/build-manifest.yml
LANCACHE_SOT_TEXT=$(lancache_repo_file_text "$LANCACHE_SOT") || exit $?

# What: the prod compose file, SOT runtime.compose_file
# Why: one owner; setup.sh and CI name the same file
# From: Issue #1683 | PR #1858
PROD_COMPOSE="$SCRIPT_DIR/$(lancache_sot_value compose_file runtime)" || exit $?

# What: runs the subcommand named in the first argument
# Why: the install flow below runs only for install
# From: Issue #1683 | PR #1858
ensure_default_install_dir

# What: no command prints the help and changes nothing
# Why: only the explicit install command installs
# From: Issue #1683 | PR #1858
if [[ -z "${1:-}" ]]; then
    print_usage
    exit 0
fi
# What: maps old command spellings to their names
# Why: docs/how-to-change-ip.md still uses --reconfigure
# From: Issue #1683 | PR #1912
setup_command="$1"
case "$setup_command" in
    --secondary) setup_command=secondary ;;
    --reconfigure|reconfigure) setup_command=update-ip ;;
esac
# What: "<command> --help" asks print_command_help
# Why: one check; that function owns the help list
# From: Issue #1683 | PR #1912
if [[ "${2:-}" = "--help" || "${2:-}" = "help" ]] \
    && [[ ! "$setup_command" =~ ^(compose|converge-reconcile|openrc-loop|help|--help|-h)$ ]]; then
    print_command_help "$setup_command" && exit 0
fi
case "$setup_command" in
    install) ;;
    list-prompts)
        # What: list-prompts records, then falls through
        # Why: the walk uses the real wizard branch logic
        # From: Issue #1683 | PR #1858
        WIZARD_INTROSPECT_MODE=1
        if [[ -n "${2:-}" ]]; then
            [[ -f "$2" ]] || die "Answers file not found: $2"
            # What: fd 9 is opened once for the answers file
            # Why: no nested re-exec can reuse fd 9
            # From: Issue #1683 | PR #1858
            exec 9<"$2"
            WIZARD_INTROSPECT_ANSWERS_FD=9
        fi
        ;;
    install-requirements-primary)
        cmd_install_requirements_primary; exit 0 ;;
    install-requirements-secondary)
        cmd_install_requirements_secondary; exit 0 ;;
    update)
        cmd_update "${2:-$DEFAULT_INSTALL_DIR}"; exit 0 ;;
    auto-update)
        cmd_auto_update "${2:-$DEFAULT_INSTALL_DIR}"; exit 0 ;;
    converge-reconcile)
        # What: internal-only; not in the usage text
        # Why: the converge service calls it
        # From: Issue #1683 | PR #1858
        cmd_converge_reconcile "${2:-$DEFAULT_INSTALL_DIR}"; exit 0 ;;
    openrc-loop)
        # What: internal-only; not in the usage text
        # Why: the OpenRC loop services call it
        # From: Issue #1683 | PR #1858
        shift; cmd_openrc_loop "$@"; exit 0 ;;
    compose)
        # What: internal; units and recovery hints call it
        # Why: compose always needs the stack's file list
        # From: Issue #1683 | PR #1858
        shift; cmd_compose "$@"; exit 0 ;;
    debug)
        cmd_debug  "${2:-$DEFAULT_INSTALL_DIR}"; exit 0 ;;
    create-logs-for-issue)
        shift; cmd_create_logs_for_issue "$@"; exit 0 ;;
    backup)
        shift; cmd_backup "$@"; exit 0 ;;
    restore)
        shift; cmd_restore "$@"; exit 0 ;;
    secondary)
        shift; cmd_secondary "$@"; exit 0 ;;
    update-ip)
        cmd_update_ip "${2:-$DEFAULT_INSTALL_DIR}"; exit 0 ;;
    configure-upstream-dns)
        cmd_configure_upstream_dns "${2:-$DEFAULT_INSTALL_DIR}"; exit 0 ;;
    reset-to-last-known-good-config)
        shift; cmd_reset_to_last_known_good_config "$@"; exit 0 ;;
    help|--help|-h) print_usage; exit 0 ;;
    *)           die "Unknown command: $1. Run './setup.sh --help' for available commands." ;;
esac

# What: first-user production flow, linear and readable
# Why: prompt, write config once, then start containers
# From: Issue #1683 | PR #1858

printf "\n"
printf '%s╔══════════════════════════════════════════╗%s\n' "${BOLD}" "${RESET}"
printf '%s║      LanCache-NG — Initial Setup        ║%s\n' "${BOLD}" "${RESET}"
printf '%s╚══════════════════════════════════════════╝%s\n' "${BOLD}" "${RESET}"
printf "\n"
printf "  This script sets up LanCache-NG and starts all containers.\n"
printf "  After: ./setup.sh update  |  ./setup.sh debug  |  ./setup.sh update-ip\n"
printf "  Help:  ./setup.sh --help (use './setup.sh <command> --help' for details)\n"

# What: step 1: list-prompts skips root, Docker, git checks
# Why: lets list-prompts run cheaply in CI
# From: Issue #1683 | PR #1858
if [[ "$WIZARD_INTROSPECT_MODE" != "1" ]]; then
    print_step "Checking prerequisites"

    [[ "$(id -u)" = "0" ]] \
        || die "This script must be run as root (sudo ./setup.sh install)."

    ensure_stack_requirements_installed

    # What: no checkout here: step 1b clones the code
    # Why: it goes straight into the chosen channel's dir
    # From: Issue #1683 | PR #1858
    if [[ ! -f "$PROD_COMPOSE" ]]; then
        print_warn "No local repo found — the code of the chosen channel goes to ${DEFAULT_INSTALL_DIR}/<channel>."
        command_available git || install_git
    fi

    # What: version lines; an unknown version only warns
    # Why: a cosmetic print must not abort the install
    # From: Issue #1377
    docker_version_raw="$(docker --version)" || die "docker --version failed (exit $?)."
    if docker_version_numbers="$(grep -oP '[\d.]+' <<<"$docker_version_raw")"; then
        print_ok "Docker ${docker_version_numbers%%$'\n'*}"
    else
        print_warn "Docker version not recognised: $docker_version_raw"
    fi
    if compose_version="$(docker compose version --short)"; then
        print_ok "Docker Compose $compose_version"
    else
        print_warn "Docker Compose version unavailable (exit $?)"
    fi
fi

# What: step 1a: the image channel to install
# Why: first, so the checkout can follow it before asking
# From: Issue #1683 | PR #1858
print_step "Release channel"

# What: a pre-set LANCACHE_IMAGE_CHANNEL skips the prompt
# Why: the operator chose the channel before the start
# From: Issue #1683 | PR #1858
if [[ -n "${LANCACHE_IMAGE_CHANNEL:-}" ]]; then
    validate_lancache_image_channel "$LANCACHE_IMAGE_CHANNEL"
    print_ok "Using the channel already set via LANCACHE_IMAGE_CHANNEL=${LANCACHE_IMAGE_CHANNEL}."
else
    selectable=$(lancache_selectable_channels) || exit $?
    retired=$(lancache_release_rows retired) || exit $?
    # What: the default is SOT release.install_channel
    # Why: maintainer 24.10.: stable, never nightly unwarned
    # From: Issue #1683 | PR #1858
    install_channel=$(lancache_sot_value install_channel release) || exit $?
    list_has_line "$install_channel" "$selectable" \
        || die "SOT release.install_channel '$install_channel' is not a channel setup.sh offers."
    while IFS= read -r offered; do
        if [[ "$offered" = "$install_channel" ]]; then
            printf "  %s — tested releases; the recommended default.\n" "$offered"
        else
            printf "  %s — experimental daily builds; they may break; not for production.\n" "$offered"
        fi
    done <<< "$selectable"
    printf "\n"

    channel_hint=$(paste -sd/ <<< "$selectable")
    while true; do
        ask "Release channel [$channel_hint]" "$install_channel"
        if list_has_line "${REPLY,,}" "$selectable"; then
            LANCACHE_IMAGE_CHANNEL="${REPLY,,}"
            # What: any other channel needs a second yes
            # Why: untested builds never install unwarned
            # From: Issue #1683 | PR #1858
            if [[ "$LANCACHE_IMAGE_CHANNEL" != "$install_channel" ]]; then
                print_warn "The $LANCACHE_IMAGE_CHANNEL channel is experimental: untested daily builds that may break the stack; not for production use."
                confirm "Install from $LANCACHE_IMAGE_CHANNEL anyway? [y/N]" "N" || continue
            fi
            print_ok "Using the $LANCACHE_IMAGE_CHANNEL channel."
            break
        fi
        # What: a retired name shows why it went
        # Why: release-versioning asks for a clear answer
        # From: Issue #1683 | PR #1858
        reason=$(awk -v c="${REPLY,,}" '$1 == c { sub(/^[^ ]+ /, ""); print; exit }' <<< "$retired")
        if [[ -n "$reason" ]]; then
            print_error "The '${REPLY,,}' channel is no longer supported ($reason). Please answer one of: $channel_hint."
        else
            print_error "Please answer one of: $channel_hint."
        fi
    done
fi

# What: step 1b: setup runs from the channel's dir
# Why: compose files and images from one ref at once
# From: Issue #1683 | PR #1858
if [[ "$WIZARD_INTROSPECT_MODE" != "1" ]]; then
    install_repo_follow_channel "$LANCACHE_IMAGE_CHANNEL" "$@"
fi

# What: step 2: LAN IPs and HTTPS mode
# Why: the DNS and proxy containers listen on these IPs
# From: Issue #1683 | PR #1858
print_step "Network configuration"

# What: listing or detection failure leaves no default
# Why: AG-SEC-007; a host without ip must not abort
# From: Issue #1683 | PR #1858
detected_ip=""
if lan_addresses=$(host_lan_addresses); then
    printf "\n  Found LAN addresses:\n"
    awk '{ print "    " $1 "/" $2 " dev " $3 }' <<< "$lan_addresses"
    detect_rc=0
    detected_ip=$(detect_lan_ip) || detect_rc=$?
    [[ "$detect_rc" -eq 0 ]] \
        || print_warn "No LAN IP detected (exit $detect_rc; see above); enter it below."
else
    print_warn "Cannot list this host's IPv4 addresses (exit $?); enter them below."
fi
printf "\n"

# What: both LAN IPs start empty before they are asked
# Why: ask_checked fills them by name; the init shows it
# From: Issue #1683 | PR #1912
IP_HTTP=""
IP_HTTPS=""
ask_checked IP_HTTP "Server IP (HTTP mode)" "$detected_ip" is_valid_ipv4 "Invalid IPv4 address"

printf "\n"
printf '  %sSecond LAN IP%s: the HTTPS DNS/proxy address, always required.\n\n' "${BOLD}" "${RESET}"
# What: the second LAN address is always asked and checked
# Why: AG-SETUP-001; prod runs dns-https on IP_HTTPS always
# From: Issue #1683 | PR #1912
suggested_https="${IP_HTTP%.*}.$((10#${IP_HTTP##*.} + 1))"
ask_checked IP_HTTPS "Second LAN IP (HTTPS mode)" "$suggested_https" is_valid_ipv4 "Invalid IPv4 address"
require_separate_lan_ips "$IP_HTTP" "$IP_HTTPS"
# What: IP_HTTPS goes on IP_HTTP's device and prefix
# Why: same link and subnet; no guessed device or mask
# From: Issue #1683 | PR #1858
https_assigned=0 http_link=""
if host_addresses=$(host_ipv4_addresses); then
    awk -v ip="$IP_HTTPS" '$1 == ip { found = 1 } END { exit !found }' <<< "$host_addresses" \
        && https_assigned=1
    http_link=$(awk -v ip="$IP_HTTP" '$1 == ip { print $2, $3; exit }' <<< "$host_addresses")
else
    print_warn "Cannot list this host's IPv4 addresses (exit $?)."
fi
if [[ "$https_assigned" = 1 ]]; then
    print_ok "$IP_HTTPS already assigned"
else
    print_warn "$IP_HTTPS not yet assigned to an interface"
    if [[ -n "$http_link" ]]; then
        read -r http_prefix http_dev <<< "$http_link"
        if confirm "Add now? (ip addr add $IP_HTTPS/$http_prefix dev $http_dev) [y/N]" "N"; then
            if [[ "$WIZARD_INTROSPECT_MODE" = "1" ]]; then
                # What: introspection skips ip addr add
                # Why: list-prompts only walks the prompts
                # From: Issue #1176
                print_ok "$IP_HTTPS would be added (skipped: introspection mode)"
            elif ip addr add "$IP_HTTPS/$http_prefix" dev "$http_dev"; then
                print_ok "$IP_HTTPS added (not persistent)"
            else
                print_warn "Adding failed (exit $?) — please add manually"
            fi
        fi
    else
        print_warn "Add $IP_HTTPS to the interface that carries $IP_HTTP."
    fi
    printf "\n"
    print_warn "For persistent configuration after reboot:"
    printf "    netplan:    sudo nano /etc/netplan/01-netcfg.yaml\n"
    printf "    interfaces: sudo nano /etc/network/interfaces\n"
fi

printf "\n"
printf '  %sHTTPS mode%s: also caches HTTPS downloads (Epic, EA, Blizzard…)\n' "${BOLD}" "${RESET}"
printf "  Requires a CA certificate on clients.\n\n"
https_yn=$(yn_default HTTPS_ENABLED) || exit $?
ask "Enable HTTPS mode? $(yn_hint "$https_yn")" "$https_yn"
HTTPS_ENABLED=$(yn_flag "$REPLY")
print_ok "HTTPS mode $([[ "$HTTPS_ENABLED" = 1 ]] && echo enabled || echo disabled) (second IP $IP_HTTPS)"

# What: step 3: the directory for all persistent state
# Why: cache, DNS, DHCP and NTP data live below it
# From: Issue #1683 | PR #1858
print_step "Data directory"

# What: the stack runs from this checkout's deploy/prod
# Why: AG-KD-008: deploy/prod is the only deployment profile
# From: Issue #1683 | PR #1858
INSTALL_DIR="${PROD_COMPOSE%/*}"
ENV_LOCAL="$INSTALL_DIR/.env.local"
STATE_ROOT_DEFAULT=$(production_state_root_default "$INSTALL_DIR") \
    || die "Cannot read the default state root from $INSTALL_DIR (exit $?)."
ask "Data directory (cache, DNS, DHCP, NTP state)" "$STATE_ROOT_DEFAULT"
LANCACHE_STATE_DIR="$(realpath -m "$REPLY")"

if [[ -f "$ENV_LOCAL" ]]; then
    print_warn "Existing configuration found: $ENV_LOCAL"
    confirm "Overwrite? [y/N]" "N" || die "Cancelled."
fi

if [[ "$WIZARD_INTROSPECT_MODE" != "1" ]]; then
    mkdir -p "$LANCACHE_STATE_DIR"
fi

# What: step 4: cache directory, size and RAM buffer
# Why: nginx needs size and keys_zone before it starts
# From: Issue #1683 | PR #1858
print_step "Cache configuration"

while true; do
    ask "Cache directory (absolute path)" "$LANCACHE_STATE_DIR/cache"
    CACHE_DIR="$REPLY"
    is_absolute_path "$CACHE_DIR" && break
    print_error "Please enter an absolute path (e.g. $LANCACHE_STATE_DIR/cache)."
done

default_cache_gb=$(cache_size_gb_from_env "$(prod_env_default CACHE_MAX_SIZE)") \
    || die "The CACHE_MAX_SIZE default is not a GB size."
while true; do
    ask "Cache size in GiB" "$default_cache_gb"
    cache_gb="$REPLY"
    [[ "$cache_gb" =~ ^[0-9]+$ ]] && (( cache_gb > 0 )) && break
    print_error "Please enter a positive integer (e.g. ${default_cache_gb})."
done

default_cache_mem_mb=$(prod_env_default CACHE_MEM_MB) || exit $?
while true; do
    ask "Cache RAM buffer in MB (keys_zone)" "$default_cache_mem_mb"
    CACHE_MEM_MB="$REPLY"
    is_positive_integer "$CACHE_MEM_MB" && break
    print_error "Please enter a positive integer (e.g. 512)."
done

# What: step 6: scheduled updates by a host service
# Why: Watchtower cannot verify health or roll back
# From: Issue #1683 | PR #1858
print_step "Scheduled automatic updates"

printf "  A host service can periodically run this project's own update logic:\n"
printf "  it only proceeds if the release channel actually moved to a new\n"
printf "  immutable image set, brings every service except the Admin UI up first\n"
printf "  and verifies it is healthy, updates the Admin UI last, and rolls back to\n"
printf "  the pre-update backup automatically if a health check fails.\n"
auto_update_yn=$(yn_default AUTO_UPDATE_ENABLED) || exit $?
printf "  Default: %s. Update manually any time with: ./setup.sh update\n\n" \
    "$([[ "$auto_update_yn" = "Y" ]] && echo enabled || echo disabled)"

ask "Enable scheduled automatic updates? $(yn_hint "$auto_update_yn")" "$auto_update_yn"
AUTO_UPDATE_ENABLED=$(yn_flag "$REPLY")
if [[ "$AUTO_UPDATE_ENABLED" = 1 ]]; then
    print_ok "Scheduled automatic updates enabled (ordered, health-gated, daily)"
else
    print_warn "Scheduled automatic updates disabled — manual updates with: ./setup.sh update"
fi

# What: optional external DNS server for unknown names
# Why: a router may answer the names of LAN devices
# From: Issue #1918 | PR #1858
print_step "External DNS server (optional)"
install_lan_zone=$(prod_env_default DHCP_DOMAIN) || exit $?
prompt_dns_upstream "" "" "" "${IP_HTTP},${IP_HTTPS}" "$install_lan_zone"
if [[ -n "$DNS_UPSTREAM_SERVERS" ]]; then
    print_ok "External DNS: ${DNS_UPSTREAM_SERVERS}"
else
    print_ok "No external DNS server; LanCache-NG resolves names itself"
fi

# What: step 7: DHCP mode and its addresses
# Why: each mode needs its own set of keys
# From: Issue #1683 | PR #1858
print_step "DHCP mode"

printf "  Kea (full mode): route and DNS options via Admin-UI\n"
printf "  dnsmasq-proxy: experimental proxy-DHCP helper; it does not reliably replace DNS options from a normal router DHCP server\n"
printf "  dnsmasq-relay: forward DHCP to an upstream server on another segment (relay only; injects nothing of its own)\n"
printf "  disabled: keep router DHCP and do nothing in LanCache\n\n"

default_dhcp_mode=$(prod_env_default DHCP_MODE) || exit $?
while true; do
    ask "DHCP mode (disabled, kea, dnsmasq-proxy, dnsmasq-relay)" "$default_dhcp_mode"
    DHCP_MODE="${REPLY,,}"
    if is_valid_dhcp_mode "$DHCP_MODE"; then
        break
    fi
    print_error "Invalid DHCP mode: $DHCP_MODE"
done

# What: DHCP defaults come from the SOT runtime.defaults
# Why: AG-SEC-007; the SOT owns these values
# From: Issue #1683 | PR #1912
DHCP_SUBNET_DEFAULT=$(prod_env_default DHCP_SUBNET) || exit $?
DHCP_GATEWAY_DEFAULT=$(prod_env_default DHCP_GATEWAY) || exit $?
DHCP_RANGE_START_DEFAULT=$(prod_env_default DHCP_RANGE_START) || exit $?
DHCP_RANGE_END_DEFAULT=$(prod_env_default DHCP_RANGE_END) || exit $?
KEA_DATA_DIR=""
DHCP_SUBNET=""
DHCP_GATEWAY="$DHCP_GATEWAY_DEFAULT"
DHCP_RANGE_START=""
DHCP_RANGE_END=""
DHCP_SUBNET_START=""
# What: both DHCP DNS values are empty unless set.
# Why: config.rs owns the rule for empty; one owner.
# From: Issue #1683 | PR #1912
DHCP_DNS_PRIMARY=""
DHCP_DNS_SECONDARY=""
UPSTREAM_DHCP_IP="$DHCP_GATEWAY"
# What: relay-mode local address, empty by default
# Why: only dnsmasq-relay uses it
# From: Issue #1683 | PR #1858
DHCP_RELAY_LOCAL_ADDR=""
# What: optional dnsmasq fields, empty unless opted in
# Why: the operator opts in below; NTP starts at the default
# From: Issue #450 | PR #1912
DHCP_PROXY_INTERFACE=""
DHCP_PROXY_ROUTER=""
DHCP_NTP_SERVERS=""
DHCP_PROXY_DOMAIN=""
DHCP_PROXY_BOOT_FILENAME=""
DHCP_PROXY_BOOT_SERVER=""
DHCP_PROXY_CUSTOM_OPTIONS=""
# What: PXE boot-pointer fields set by the wizard or default
# Why: .env is the one place an operator sets them
# From: Issue #1683 | PR #1858
DHCP_PROXY_PXE_BOOT_SERVER=""
DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=""
DHCP_PROXY_PXE_BOOT_FILENAME_UEFI=""

if [[ "$DHCP_MODE" = "kea" ]]; then
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

    ask_checked DHCP_GATEWAY "Gateway" "$DHCP_GATEWAY_DEFAULT" is_valid_ipv4 "Invalid IPv4 address"

    ask_checked DHCP_RANGE_START "IP pool start" "$DHCP_RANGE_START_DEFAULT" is_valid_ipv4 "Invalid IPv4 address"

    ask_checked DHCP_RANGE_END "IP pool end" "$DHCP_RANGE_END_DEFAULT" is_valid_ipv4 "Invalid IPv4 address"

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

    ask_checked DHCP_DNS_PRIMARY "Primary DNS option for proxy-DHCP/PXE clients (blank = HTTP IP)" "$DHCP_DNS_PRIMARY" is_valid_ipv4 "Invalid IPv4 address" 1

    ask_checked DHCP_DNS_SECONDARY "Secondary DNS option for proxy-DHCP/PXE clients (blank = HTTPS IP)" "$DHCP_DNS_SECONDARY" is_valid_ipv4 "Invalid IPv4 address" 1

    ask_checked UPSTREAM_DHCP_IP "Upstream DHCP server IP" "$DHCP_GATEWAY" is_valid_ipv4 "Invalid IPv4 address"

    # What: optional relay/proxy options; all skippable
    # Why: a plain Enter still gives a working proxy
    # From: Issue #450
    boot_filename_error="Invalid boot filename (no whitespace, commas, or other .env-unsafe characters like \$, \`, \", ', \\, #)"
    print_warn "Optional: additional dnsmasq relay/proxy options (router, NTP, domain, PXE/TFTP boot, listen interface, custom options)."
    print_warn "These are delivered only to PXE/network-boot-aware clients via the supplemental ProxyDHCP exchange, never to ordinary DHCP clients -- see docs/dhcp-modes.md."
    if confirm "Configure additional dnsmasq relay/proxy options now? [y/N]" "N"; then
        ask_checked DHCP_PROXY_INTERFACE "Listen interface (blank = listen on all interfaces)" "$DHCP_PROXY_INTERFACE" is_valid_dhcp_proxy_interface "Invalid interface name" 1

        ask_checked DHCP_PROXY_ROUTER "Router/gateway option, PXE-scoped (blank = skip)" "$DHCP_PROXY_ROUTER" is_valid_ipv4 "Invalid IPv4 address" 1

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
                is_valid_dhcp_ntp_server "$_dhcp_ntp_ip" || _dhcp_ntp_ok=0
            done
            [[ "$_dhcp_ntp_ok" = "1" ]] && break
            print_error "Invalid NTP servers list (must be comma-separated IPv4 addresses or host names): $DHCP_NTP_SERVERS"
            ask "NTP servers, PXE-scoped, comma-separated (blank = skip)" ""
        done

        ask_checked DHCP_PROXY_DOMAIN "Domain option, PXE-scoped (blank = skip)" "$DHCP_PROXY_DOMAIN" is_valid_dhcp_proxy_domain "Invalid domain name" 1

        ask_checked DHCP_PROXY_BOOT_FILENAME "PXE boot filename (blank = skip PXE boot info)" "$DHCP_PROXY_BOOT_FILENAME" is_valid_dhcp_proxy_boot_filename "$boot_filename_error" 1

        if [[ -n "$DHCP_PROXY_BOOT_FILENAME" ]]; then
            ask_checked DHCP_PROXY_BOOT_SERVER "PXE boot server address (blank = this host's own address)" "$DHCP_PROXY_BOOT_SERVER" is_valid_ipv4 "Invalid IPv4 address" 1
        else
            DHCP_PROXY_BOOT_SERVER=""
        fi

        print_ok "Additional dnsmasq relay/proxy options configured. Custom safe options (DHCP_PROXY_CUSTOM_OPTIONS) can be added later from the Admin UI DHCP page."
    fi

    # What: PXE boot-pointer is its own opt-in gate
    # Why: without pxe-service dnsmasq never replies
    # From: Issue #1683 | PR #1858
    print_warn "Optional: PXE boot-pointer support. This makes dnsmasq start REPLYING to every PXE-tagged client on this segment, pointing them at an EXISTING external PXE/TFTP boot server -- lancache-ng does not host boot files itself. See docs/dhcp-modes.md."
    if confirm "Configure PXE boot-pointer support now? [y/N]" "N"; then
        ask_checked DHCP_PROXY_PXE_BOOT_SERVER "External PXE/TFTP boot server address (blank = skip PXE boot-pointer support)" "$DHCP_PROXY_PXE_BOOT_SERVER" is_valid_ipv4 "Invalid IPv4 address" 1

        if [[ -n "$DHCP_PROXY_PXE_BOOT_SERVER" ]]; then
            ask_checked DHCP_PROXY_PXE_BOOT_FILENAME_BIOS "BIOS (legacy x86PC) boot filename (blank = skip BIOS clients)" "$DHCP_PROXY_PXE_BOOT_FILENAME_BIOS" is_valid_dhcp_proxy_boot_filename "$boot_filename_error" 1

            ask_checked DHCP_PROXY_PXE_BOOT_FILENAME_UEFI "UEFI (x86-64/ARM64) boot filename (blank = skip UEFI clients)" "$DHCP_PROXY_PXE_BOOT_FILENAME_UEFI" is_valid_dhcp_proxy_boot_filename "$boot_filename_error" 1

            if pxe_boot_pointer_answers_are_complete "$DHCP_PROXY_PXE_BOOT_SERVER" "$DHCP_PROXY_PXE_BOOT_FILENAME_BIOS" "$DHCP_PROXY_PXE_BOOT_FILENAME_UEFI"; then
                print_ok "PXE boot-pointer support configured (external boot server: $DHCP_PROXY_PXE_BOOT_SERVER)."
            else
                # What: a server alone renders nothing
                # Why: it only logs a startup warning
                # From: Issue #1683 | PR #1858
                print_warn "No BIOS or UEFI boot filename set; PXE boot-pointer support will remain inactive."
                DHCP_PROXY_PXE_BOOT_SERVER=""
            fi
        fi
    fi

    print_ok "DHCP proxy mode enabled — subnet start: $DHCP_SUBNET_START"
elif [[ "$DHCP_MODE" = "dnsmasq-relay" ]]; then
    # What: relay mode needs only local and upstream IPs
    # Why: a relay injects no subnet, DNS or PXE options
    # From: Issue #1683 | PR #1858
    print_warn "dnsmasq-relay forwards every client's DHCP request to an upstream DHCP server on another segment."
    print_warn "The upstream server owns the whole lease and every option; LanCache injects nothing of its own here."

    ask_checked DHCP_RELAY_LOCAL_ADDR "This relay's own IP on the client-facing network (giaddr)" "" is_valid_ipv4 "Invalid IPv4 address"

    ask_checked UPSTREAM_DHCP_IP "Upstream DHCP server IP" "$DHCP_GATEWAY" is_valid_ipv4 "Invalid IPv4 address"

    print_ok "DHCP relay mode enabled — relaying ${DHCP_RELAY_LOCAL_ADDR} -> upstream ${UPSTREAM_DHCP_IP}"
else
    print_ok "DHCP skipped — existing router DHCP remains active"
fi

# What: step 7a: local private PTR zones, SOT default off
# Why: kea DDNS writes PTR records into these zones
# From: Issue #1918 | PR #1858
print_step "Reverse lookups (PTR)"
install_reverse_zones=$(prod_env_default DNS_LOCAL_REVERSE_ZONES) || exit $?
prompt_dns_local_reverse_zones "$install_reverse_zones" "$DHCP_MODE"

# What: step 7b: asks for the NTP start value
# Why: the watchdog runs chronyd in the services container
# From: Issue #1683 | PR #1912
print_step "LanCache-NG-NTP"

printf "  A small, self-contained NTP server, disciplined against public NTP\n"
ntp_yn=$(yn_default NTP_ENABLED) || exit $?
ntp_port=$(prod_env_default NTP_PORT) || exit $?
printf "  servers, that serves time to LAN clients on UDP/%s. Enable/disable and\n" "$ntp_port"
printf "  upstream server list are then configured from the Admin UI.\n"
printf "  Default: %s.\n\n" "$([[ "$ntp_yn" = "Y" ]] && echo enabled || echo disabled)"

ask "Enable LanCache-NG-NTP? $(yn_hint "$ntp_yn")" "$ntp_yn"
NTP_ENABLED=$(yn_flag "$REPLY")
ntp_subdir=$(prod_env_default STATE_SUBDIR_NTP) || exit $?
NTP_DATA_DIR="$LANCACHE_STATE_DIR/$ntp_subdir"
if [[ "$NTP_ENABLED" = "1" ]]; then
    print_ok "LanCache-NG-NTP enabled — configure upstream servers and the DHCP auto-populate toggle from the Admin UI's NTP page"
else
    print_ok "LanCache-NG-NTP skipped — can be enabled later from the Admin UI"
fi

# What: step 8: Admin UI login and bind address
# Why: the Admin UI controls the whole stack
# From: Issue #1683 | PR #1858
print_step "Admin-UI access control"

printf "  Admin-UI runs on %s — reachable from your LAN by default.\n" "$IP_HTTP"
printf "  Password protection is optional, but recommended on shared or untrusted networks.\n"
UI_LOOPBACK_HINT=$(prod_env_default LOOPBACK_BIND_IP) || exit $?
printf "  To restrict the UI to this host later, set UI_BIND_IP=%s in .env.\n\n" "$UI_LOOPBACK_HINT"

UI_AUTH_USER=""
UI_AUTH_PASSWORD=""
UI_AUTH_PASSWORD_HASH=""
ALLOW_INSECURE_UI=""
if confirm "Protect Admin-UI with password? [Y/n]" "Y"; then
    ui_user_default=$(prod_env_default SETUP_UI_USER_DEFAULT) || exit $?
    ask "Username" "$ui_user_default"
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
        && env_key_has_usable_secret UI_AUTH_PASSWORD_HASH "$ENV_LOCAL"; then
        UI_AUTH_PASSWORD_HASH=$(get_env_var UI_AUTH_PASSWORD_HASH "$ENV_LOCAL") || exit $?
        print_ok "Existing Admin-UI password preserved"
    elif [[ -f "$ENV_LOCAL" ]] \
        && [[ "$existing_ui_user" = "$UI_AUTH_USER" ]] \
        && env_key_has_usable_secret UI_AUTH_PASSWORD "$ENV_LOCAL"; then
        UI_AUTH_PASSWORD=$(get_env_var UI_AUTH_PASSWORD "$ENV_LOCAL") || exit $?
        print_ok "Existing Admin-UI password preserved; it is stored as a hash after the image pull"
    elif [[ "$WIZARD_INTROSPECT_MODE" = "1" ]]; then
        # What: introspection mode prints no real secret
        # Why: repeat runs must stay deterministic
        # From: Issue #1683 | PR #1858
        UI_AUTH_PASSWORD=""
        print_ok "Admin-UI password would be generated (skipped: introspection mode)"
    else
        UI_AUTH_PASSWORD=$(generate_managed_secret UI_AUTH_PASSWORD ui) || exit $?
        printf "\n"
        print_ok "Credentials:"
        printf '    User:     %s%s%s\n' "${BOLD}" "$UI_AUTH_USER" "${RESET}"
        printf '    Password: %s%s%s\n' "${BOLD}" "$UI_AUTH_PASSWORD" "${RESET}"
        print_warn "Note the password now; only its hash is stored in $ENV_LOCAL"
        printf "\n"
    fi
else
    insecure_yn=$(yn_default ALLOW_INSECURE_UI) || exit $?
    if confirm "Allow Admin-UI without authentication? $(yn_hint "$insecure_yn")" "$insecure_yn"; then
        ALLOW_INSECURE_UI=true
        print_warn "No password protection — Admin-UI will be reachable on $IP_HTTP"
        print_warn "This is explicitly allowed by ALLOW_INSECURE_UI=true"
    else
        die "Admin-UI authentication is required. Re-run setup and enable password protection, or explicitly allow insecure access."
    fi
fi

# What: step 9: writes .env.local in one atomic step
# Why: a half-written .env.local must never exist
# From: Issue #1683 | PR #1858
print_step "Writing .env"

env_file="$ENV_LOCAL"

# What: from here on, the real install mutations run
# Why: introspection mode must leave the host untouched
# From: Issue #1683 | PR #1858
if [[ "$WIZARD_INTROSPECT_MODE" != "1" ]]; then

# What: generates or keeps secrets; placeholders regenerate
# Why: empty or placeholder values are never used
# From: Issue #1683 | PR #1858
LANCACHE_IMAGE_REGISTRY=$(resolve_lancache_image_registry "$env_file")
LANCACHE_IMAGE_PREFIX=$(resolve_lancache_image_prefix "$env_file")
LANCACHE_IMAGE_CHANNEL=$(resolve_lancache_image_channel "$env_file")
LANCACHE_IMAGE_TAG=$(resolve_lancache_image_tag "$env_file")
LANCACHE_IMAGE_REFS=$(lancache_image_refs_for_tag "$env_file" "$LANCACHE_IMAGE_TAG") \
    || die "Cannot pin the images of ${LANCACHE_IMAGE_TAG}; ${env_file} was not written (exit $?)."

# What: verifies the tag publishes this platform
# Why: a platform failure must stop before state writes
# From: Issue #1683 | PR #1858
assert_resolved_image_tag_platform_supported "$LANCACHE_IMAGE_REGISTRY" "$LANCACHE_IMAGE_PREFIX" "$LANCACHE_IMAGE_TAG"

# What: every SOT secret: the kept value or a generated one
# Why: the SOT lists the keys; setup.sh names none itself
# From: Issue #1683 | PR #1912
secret_rows=$(managed_secret_rows stack) || exit $?
while read -r secret_key secret_kind; do
    secret_value=$(get_or_generate_secret "$secret_key" "$env_file" "$secret_kind") || exit $?
    printf -v "$secret_key" '%s' "$secret_value"
done <<< "$secret_rows"
# What: an empty TTL means the SOT default
# Why: .env.local never repeats a runtime.defaults value
# From: Issue #1683 | PR #1912
UI_SESSION_TTL_SECONDS=$(get_env_var UI_SESSION_TTL_SECONDS "$env_file")
[[ -z "$UI_SESSION_TTL_SECONDS" ]] || validate_ui_session_ttl_seconds "$UI_SESSION_TTL_SECONDS" "$env_file"

# What: the first .env.local text; values are unquoted
# Why: the one key list; the check below reads this body
# From: Issue #1683 | PR #1912
render_initial_env_local() {
    cat <<EOF
# What: LAN IP for HTTP; HTTP cached, HTTPS passed on
# Why: HTTP mode needs no CA certificate
# From: Issue #1683 | PR #1858
IP_HTTP=${IP_HTTP}

# What: second LAN IP for the HTTPS DNS and proxy
# Why: always required (AG-SETUP-001)
# From: Issue #1683 | PR #1858
IP_HTTPS=${IP_HTTPS}

# What: root of all persistent state
# Why: cache, DNS, DHCP and NTP data live below it
# From: Issue #1683 | PR #1858
LANCACHE_STATE_DIR=${LANCACHE_STATE_DIR}

HTTPS_ENABLED=${HTTPS_ENABLED}

CACHE_DIR=${CACHE_DIR}
CACHE_MAX_SIZE=${cache_gb}g
CACHE_MEM_MB=${CACHE_MEM_MB}

# What: cache size in GB as a plain number
# Why: the Admin UI draws its progress bar from it
# From: Issue #1683 | PR #1858
CACHE_MAX_GB=${cache_gb}

# What: image source; the channel resolves to a sha-* tag
# Why: setup.sh pulls only immutable tags
# From: Issue #1683 | PR #1858
LANCACHE_IMAGE_REGISTRY=${LANCACHE_IMAGE_REGISTRY}
LANCACHE_IMAGE_PREFIX=${LANCACHE_IMAGE_PREFIX}
LANCACHE_IMAGE_CHANNEL=${LANCACHE_IMAGE_CHANNEL}
LANCACHE_IMAGE_TAG=${LANCACHE_IMAGE_TAG}

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
# What: relay local address (giaddr); see docs/dhcp-modes.md
# Why: only DHCP_MODE=dnsmasq-relay uses it
# From: Issue #1683 | PR #1858
DHCP_RELAY_LOCAL_ADDR=${DHCP_RELAY_LOCAL_ADDR}

# What: optional dnsmasq proxy options; empty by default
# Why: only PXE clients get them via ProxyDHCP
# From: Issue #1683 | PR #1858
DHCP_PROXY_INTERFACE=${DHCP_PROXY_INTERFACE}
DHCP_PROXY_ROUTER=${DHCP_PROXY_ROUTER}
DHCP_NTP_SERVERS=${DHCP_NTP_SERVERS}
DHCP_PROXY_DOMAIN=${DHCP_PROXY_DOMAIN}
DHCP_PROXY_BOOT_FILENAME=${DHCP_PROXY_BOOT_FILENAME}
DHCP_PROXY_BOOT_SERVER=${DHCP_PROXY_BOOT_SERVER}
DHCP_PROXY_CUSTOM_OPTIONS=${DHCP_PROXY_CUSTOM_OPTIONS}
# What: PXE boot-pointer fields; empty means no PXE
# Why: dnsmasq-proxy points PXE clients only when set
# From: Issue #705
DHCP_PROXY_PXE_BOOT_SERVER=${DHCP_PROXY_PXE_BOOT_SERVER}
DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=${DHCP_PROXY_PXE_BOOT_FILENAME_BIOS}
DHCP_PROXY_PXE_BOOT_FILENAME_UEFI=${DHCP_PROXY_PXE_BOOT_FILENAME_UEFI}

# What: start value; the Admin UI NTP page changes it later
# Why: the watchdog runs chronyd in services only when 1
# From: Issue #1683 | PR #1912
NTP_ENABLED=${NTP_ENABLED}
NTP_DATA_DIR=${NTP_DATA_DIR}

# What: generated secrets; keep them unchanged
# Why: DHCP, DNS, NATS and the Admin UI share these values
# From: Issue #1683 | PR #1858
KEA_CTRL_TOKEN=${KEA_CTRL_TOKEN?}
DDNS_TSIG_KEY=${DDNS_TSIG_KEY?}
PDNS_API_KEY=${PDNS_API_KEY?}
NETDATA_ALARM_TOKEN=${NETDATA_ALARM_TOKEN}
NATS_UI_PASSWORD=${NATS_UI_PASSWORD}
NATS_DNS_WRITER_PASSWORD=${NATS_DNS_WRITER_PASSWORD}
NATS_CALLOUT_PASSWORD=${NATS_CALLOUT_PASSWORD}
NATS_SYS_PASSWORD=${NATS_SYS_PASSWORD}

# What: token for ./setup.sh secondary registration
# Why: whoever knows it can register a secondary
# From: Issue #1683 | PR #1858
SECONDARY_REGISTRATION_TOKEN=${SECONDARY_REGISTRATION_TOKEN}

# What: 1 = a host service runs ./setup.sh auto-update
# Why: 0 = manual updates only, with ./setup.sh update
# From: Issue #1683 | PR #1858
AUTO_UPDATE_ENABLED=${AUTO_UPDATE_ENABLED}

# What: external DNS; empty zones send all names there
# Why: empty servers: LanCache-NG resolves on its own
# From: Issue #1918 | PR #1858
DNS_UPSTREAM_SERVERS=${DNS_UPSTREAM_SERVERS}
DNS_UPSTREAM_ZONES=${DNS_UPSTREAM_ZONES}
DNS_UPSTREAM_UNSIGNED_ZONES=${DNS_UPSTREAM_UNSIGNED_ZONES}

# What: 1 = LanCache-NG answers private PTR lookups itself
# Why: 0 sends them on like every other name; kea needs 1
# From: Issue #1918 | PR #1858
DNS_LOCAL_REVERSE_ZONES=${DNS_LOCAL_REVERSE_ZONES}

# What: Admin UI login; empty only with ALLOW_INSECURE_UI
# Why: an open Admin UI controls the whole stack
# From: Issue #1683 | PR #1858
UI_AUTH_USER=${UI_AUTH_USER}
UI_AUTH_PASSWORD_HASH=${UI_AUTH_PASSWORD_HASH}
ALLOW_INSECURE_UI=${ALLOW_INSECURE_UI}

# What: session lifetime in seconds
# Why: empty uses the built-in default
# From: Issue #1683 | PR #1858
UI_SESSION_TTL_SECONDS=${UI_SESSION_TTL_SECONDS}

# What: Admin UI bind address; default is the LAN IP
# Why: ${UI_LOOPBACK_HINT} limits access to this host
# From: Issue #1683 | PR #1858
UI_BIND_IP=${IP_HTTP}
EOF
}

# What: checks every ${VAR} the text uses, before writing
# Why: a value with a newline or quote would break .env
# From: Issue #1683 | PR #1912
validate_initial_env_local() {
    local body line key ref
    body=$(declare -f render_initial_env_local) \
        || die "Cannot read render_initial_env_local (exit $?)."
    while IFS= read -r line; do
        key="${line%%=*}"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || key=""
        while [[ "$line" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
            ref="${BASH_REMATCH[1]}"
            validate_env_value "${key:-$ref}" "${!ref-}"
            line="${line/"${BASH_REMATCH[0]}"/}"
        done
    done <<< "$body"
}

validate_initial_env_local
render_initial_env_local | write_file_atomically "$ENV_LOCAL" \
    || die "Failed to write $ENV_LOCAL (exit $?)."
print_ok ".env.local written: $ENV_LOCAL"
write_lancache_image_refs "$ENV_LOCAL" "$LANCACHE_IMAGE_REFS"

# What: step 10: creates the state directories
# Why: compose bind mounts need existing directories
# From: Issue #1683 | PR #1858
print_step "Creating directories"
mkdir -p "$CACHE_DIR"
print_ok "Cache:          $CACHE_DIR"
if [[ -n "$KEA_DATA_DIR" ]]; then
    mkdir -p "$KEA_DATA_DIR"
    print_ok "Kea data:       $KEA_DATA_DIR"
fi
if [[ "$NTP_ENABLED" = "1" && -n "$NTP_DATA_DIR" ]]; then
    mkdir -p "$NTP_DATA_DIR"
    print_ok "NTP data:       $NTP_DATA_DIR"
fi
# What: pre-creates syslog log root as the runtime uid
# Why: Docker would create it root-owned, unwritable
# From: Issue #1683 | PR #1912
syslog_ng_subdir=$(prod_env_default STATE_SUBDIR_SYSLOG_NG) || exit $?
syslog_ng_log_dir="${SYSLOG_NG_LOG_DIR:-$LANCACHE_STATE_DIR/$syslog_ng_subdir}"
mkdir -p "$syslog_ng_log_dir" || die "Failed to create $syslog_ng_log_dir (exit $?)."
runtime_id=$(lancache_sot_value gid runtime) || exit $?
if chown_err=$(chown "$runtime_id:$runtime_id" "$syslog_ng_log_dir" 2>&1); then
    print_ok "Syslog-ng log root: $syslog_ng_log_dir (owned by uid $runtime_id)"
else
    # What: a failed chown is only a warning
    # Why: the container detector catches write loss
    # From: Issue #1683 | PR #1858
    print_warn "Could not chown $syslog_ng_log_dir to uid $runtime_id ($chown_err) -- the services container may not be able to write logs there. See docs/architecture-ng.md's syslog-ng section, or chown it manually before starting the stack."
fi

# What: step 11: boot start, convergence, daily update
# Why: units are enabled only after the first pull succeeds
# From: Issue #1683 | PR #1858
print_step "Installing host services"

HOST_SERVICES_AVAILABLE=0
if write_lancache_host_services "$INSTALL_DIR"; then
    HOST_SERVICES_AVAILABLE=1
    print_ok "Host services installed; they will be enabled after image pull succeeds"
else
    print_warn "Neither systemd nor OpenRC found — host services will not be installed"
    print_warn "Start stack manually after reboot: $SCRIPT_DIR/setup.sh compose $INSTALL_DIR up -d"
fi

fi # WIZARD_INTROSPECT_MODE guard opened before "Writing .env" above

# What: step 12: shows the answers, asks to start
# Why: nothing starts without the operator yes
# From: Issue #1683 | PR #1858
printf "\n"
printf '%s┌──────────────────────────────────────────────┐%s\n' "${BOLD}" "${RESET}"
printf '%s│              Configuration                   │%s\n' "${BOLD}" "${RESET}"
printf '%s├──────────────────────────────────────────────┤%s\n' "${BOLD}" "${RESET}"
printf "  %-26s %s\n"    "HTTP IP:"                  "$IP_HTTP"
if [[ "$HTTPS_ENABLED" = "1" ]]; then
    printf "  %-26s %s\n" "HTTPS IP:"                "$IP_HTTPS"
else
    printf "  %-26s %s\n" "HTTPS mode:"                "disabled"
fi
printf "  %-26s %s\n"    "Stack directory:"         "$INSTALL_DIR"
printf "  %-26s %s\n"    "Data directory:"          "$LANCACHE_STATE_DIR"
printf "  %-26s %s\n"    "Cache:"                   "$CACHE_DIR"
printf "  %-26s %s GiB\n" "Cache size:"              "$cache_gb"
printf "  %-26s %s MB\n"  "Cache RAM:"               "$CACHE_MEM_MB"
printf "  %-26s %s\n"    "DHCP mode:"               "$DHCP_MODE"
if [[ "$DHCP_MODE" = "kea" ]]; then
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
    # What: summary shows operator-set values when set
    # Why: an unshown value looks unconfigured
    # From: Issue #1683 | PR #1858
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
printf "  %-26s %s\n" "Central logging:" "on for every service; switch each in the Admin UI (Logs)"
if [[ "$AUTO_UPDATE_ENABLED" = "1" ]]; then
    printf "  %-26s %s\n" "Scheduled updates:"        "enabled (ordered, health-gated, daily)"
else
    printf "  %-26s %s\n" "Scheduled updates:"        "disabled — manual: ./setup.sh update"
fi
if [[ -n "$DNS_UPSTREAM_SERVERS" ]]; then
    printf "  %-26s %s\n" "External DNS:" \
        "${DNS_UPSTREAM_SERVERS} (domains: ${DNS_UPSTREAM_ZONES:-all}; no DNSSEC: ${DNS_UPSTREAM_UNSIGNED_ZONES:-none})"
else
    printf "  %-26s %s\n" "External DNS:" "none — LanCache-NG resolves names itself"
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
printf '%s└──────────────────────────────────────────────┘%s\n\n' "${BOLD}" "${RESET}"

ask "Start now? [Y/n]" "Y"
# What: skips the real start when introspection mode is on
# Why: the walk never reaches pull or a host service
# From: Issue #1683 | PR #1858
[[ "$WIZARD_INTROSPECT_MODE" != "1" && "${REPLY,,}" != "n" ]] \
    || { printf "\n  Start later with: %s compose %s up -d\n\n" "$SCRIPT_DIR/setup.sh" "$INSTALL_DIR"; exit 0; }

# What: step 13: pulls images before enabling any unit
# Why: failed first installs stay reversible
# From: Issue #1683 | PR #1858
print_step "Pulling images"
cd "$INSTALL_DIR"
stack_compose "$INSTALL_DIR" "$ENV_LOCAL" pull \
    || die "Failed to pull required container images. Check network access and GHCR authentication, then rerun setup.sh."

# What: hashes the chosen Admin UI password via the ui image
# Why: the plaintext never reaches .env.local
# From: Issue #1683 | PR #1912
if [[ -n "$UI_AUTH_PASSWORD" ]]; then
    set_ui_password_hash "$INSTALL_DIR" "$ENV_LOCAL" "$UI_AUTH_PASSWORD"
fi

run_kea_dhcp_activation_preflight "$ENV_LOCAL"

print_step "Starting stack"
if [[ "$HOST_SERVICES_AVAILABLE" = "1" ]]; then
    host_unit_action "$STACK_UNIT" enable
    host_unit_action "$CONVERGE_TIMER_UNIT" enable
    print_ok "$STACK_UNIT enabled for boot"
    print_ok "$CONVERGE_TIMER_UNIT enabled for boot"
    host_unit_action "$STACK_UNIT" start
    host_unit_action "$CONVERGE_TIMER_UNIT" start
    if [[ "$AUTO_UPDATE_ENABLED" = "1" ]]; then
        host_unit_action "$AUTO_UPDATE_TIMER_UNIT" enable
        host_unit_action "$AUTO_UPDATE_TIMER_UNIT" start
        print_ok "$AUTO_UPDATE_TIMER_UNIT enabled (scheduled automatic updates)"
    fi
else
    stack_compose "$INSTALL_DIR" "$ENV_LOCAL" up -d || die "Failed to start the stack in $INSTALL_DIR (exit $?)."
fi
print_ok "Stack started"

# What: step 14: Admin UI URL from the ui port mapping
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
printf '%s%s══════════════════════════════════════════════════%s\n' "${BOLD}" "${GREEN}" "${RESET}"
printf '%s%s  LanCache-NG is running!%s\n' "${BOLD}" "${GREEN}" "${RESET}"
printf '%s%s══════════════════════════════════════════════════%s\n' "${BOLD}" "${GREEN}" "${RESET}"
printf "\n"
if [[ -n "$UI_AUTH_USER" ]]; then
    printf '  %sAdmin-UI:%s    %s  (User: %s)\n' "${BOLD}" "${RESET}" "$ui_url" "$UI_AUTH_USER"
else
    printf '  %sAdmin-UI:%s    %s\n' "${BOLD}" "${RESET}" "$ui_url"
fi
printf "\n"
if [[ "$HTTPS_ENABLED" = "1" ]]; then
    printf '  %sCA certificate%s (available after first start):\n' "${BOLD}" "${RESET}"
    printf "    %s/%s\n" "$(prod_state_dir_for_key CA_DIR "$ENV_LOCAL")" "$(prod_env_default CA_CERT_FILE)"
    printf "    → install on clients for HTTPS mode\n"
    printf '    → guide: %s/wiki\n' "$LANCACHE_REPO_URL"
    printf "\n"
fi
printf '  %sConfigure DNS on clients:%s\n' "${BOLD}" "${RESET}"
printf "    HTTP mode (no certificate): %s\n" "$IP_HTTP"
if [[ "$HTTPS_ENABLED" = "1" ]]; then
    printf "    HTTPS mode (with certificate):   %s\n" "$IP_HTTPS"
fi
printf "\n"
printf '  %sCommands:%s\n' "${BOLD}" "${RESET}"
printf "    Status:  %s/setup.sh debug\n"  "$SCRIPT_DIR"
printf "    Update:  %s/setup.sh update\n" "$SCRIPT_DIR"
printf "\n"
