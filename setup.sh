#!/bin/bash
# LanCache-NG — Guided setup script
# Usage: ./setup.sh [update|debug] [install-dir]
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)"
QUICKSTART_COMPOSE="$SCRIPT_DIR/deploy/quickstart/docker-compose.yml"

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

is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.' p parts
    read -ra parts <<< "$ip"
    for p in "${parts[@]}"; do
        (( 10#$p >= 0 && 10#$p <= 255 )) || return 1
    done
}

get_env_var() {
    grep "^${1}=" "${2}" 2>/dev/null | head -1 | cut -d= -f2-
}

# ── update subcommand ─────────────────────────────────────────────────────────
cmd_update() {
    local install_dir="${1:-/opt/lancache-ng}"
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die "No stack found in $install_dir. Run ./setup.sh first."
    cd "$install_dir"

    if [[ -d "$install_dir/.git" ]]; then
        print_step "Updating repo"
        git -C "$install_dir" pull --ff-only \
            || print_warn "git pull failed — continuing with local version"
        cp "$install_dir/deploy/quickstart/docker-compose.yml" \
           "$install_dir/docker-compose.yml"
        print_ok "docker-compose.yml updated"
    fi

    print_step "Pulling latest images"
    docker compose pull || print_warn "Pull partially failed — continuing with cached images"

    print_step "Restarting containers"
    docker compose up -d --remove-orphans
    print_ok "Stack updated"
}

# ── debug subcommand ──────────────────────────────────────────────────────────
cmd_debug() {
    local install_dir="${1:-/opt/lancache-ng}"
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die "No stack found in $install_dir. Run ./setup.sh first."
    cd "$install_dir"

    local env_file="$install_dir/.env"
    local ip_standard ip_ssl cache_std cache_ssl
    ip_standard=$(get_env_var IP_STANDARD "$env_file")
    ip_ssl=$(get_env_var IP_SSL "$env_file")
    cache_std=$(get_env_var CACHE_DIR_STANDARD "$env_file")
    cache_ssl=$(get_env_var CACHE_DIR_SSL "$env_file")

    print_step "Container status"
    docker compose ps

    print_step "Logs (last 30 lines per service)"
    local ssl_enabled; ssl_enabled=$(get_env_var SSL_ENABLED "$env_file")
    local -a svc_list
    svc_list=(proxy-standard dns-standard ui netdata watchdog)
    [[ "${ssl_enabled:-1}" = "1" ]] && svc_list=(proxy-standard dns-standard proxy-ssl dns-ssl ui netdata watchdog)
    local svc
    for svc in "${svc_list[@]}"; do
        printf "\n${BOLD}--- %s ---${RESET}\n" "$svc"
        docker compose logs --tail=30 "$svc" 2>/dev/null || true
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

# ── reconfigure subcommand ─────────────────────────────────────────────────────
cmd_reconfigure() {
    printf "\n"
    printf "${BOLD}╔═══════════════════════════════════════╗${RESET}\n"
    printf "${BOLD}║  LanCache-NG — Reconfigure IPs        ║${RESET}\n"
    printf "${BOLD}╚═══════════════════════════════════════╝${RESET}\n"
    printf "\n"

    [[ "$(id -u)" = "0" ]] \
        || die "This script must be run as root (sudo ./setup.sh --reconfigure)."

    print_step "Reading current configuration"

    local deploy_env="$SCRIPT_DIR/deploy/prod/.env"
    local dns_standard_env="$SCRIPT_DIR/config/prod/dns-standard.env"
    local dns_ssl_env="$SCRIPT_DIR/config/prod/dns-ssl.env"

    [[ -f "$deploy_env" ]] || die "Configuration not found: $deploy_env"
    [[ -f "$dns_standard_env" ]] || die "Configuration not found: $dns_standard_env"
    [[ -f "$dns_ssl_env" ]] || die "Configuration not found: $dns_ssl_env"

    local current_ip_standard current_ip_ssl
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
    sed -i "s|^IP_SSL=.*|IP_SSL=$new_ip_ssl|" "$deploy_env"
    print_ok "Updated: $deploy_env"

    sed -i "s|^PROXY_IP=.*|PROXY_IP=$new_ip_standard|" "$dns_standard_env"
    print_ok "Updated: $dns_standard_env"

    sed -i "s|^PROXY_IP=.*|PROXY_IP=$new_ip_ssl|" "$dns_ssl_env"
    print_ok "Updated: $dns_ssl_env"

    print_step "Restarting containers"

    cd "$SCRIPT_DIR"
    docker compose -f "$SCRIPT_DIR/deploy/prod/docker-compose.yml" up -d \
        && print_ok "Stack restarted"

    printf "\n"
    printf "${BOLD}${GREEN}════════════════════════════════════════${RESET}\n"
    printf "${BOLD}${GREEN}  Reconfiguration complete!${RESET}\n"
    printf "${BOLD}${GREEN}════════════════════════════════════════${RESET}\n"
    printf "\n"
    printf "  Done. Update your clients to use the new DNS IP.\n\n"

    exit 0
}

# ── Dispatch subcommands ──────────────────────────────────────────────────────
case "${1:-}" in
    update)      cmd_update "${2:-/opt/lancache-ng}"; exit 0 ;;
    debug)       cmd_debug  "${2:-/opt/lancache-ng}"; exit 0 ;;
    --reconfigure) cmd_reconfigure; exit 0 ;;
    "")          ;;
    *)           die "Unknown command: $1\nUsage: $0 [update|debug|--reconfigure] [install-dir]" ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# Main setup
# ══════════════════════════════════════════════════════════════════════════════

printf "\n"
printf "${BOLD}╔══════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}║      LanCache-NG — Initial Setup        ║${RESET}\n"
printf "${BOLD}╚══════════════════════════════════════════╝${RESET}\n"
printf "\n"
printf "  This script sets up LanCache-NG and starts all containers.\n"
printf "  After: ./setup.sh update  |  ./setup.sh debug\n"

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
print_step "Checking prerequisites"

[[ "$(id -u)" = "0" ]] \
    || die "This script must be run as root (sudo ./setup.sh)."

if ! command -v curl >/dev/null 2>&1; then
    print_warn "curl missing — installing now..."
    apt-get update -y
    apt-get install -y --no-install-recommends curl \
        || die "Failed to install curl."
fi

if ! command -v docker >/dev/null 2>&1; then
    print_warn "Docker not found — installing now (get.docker.com)..."
    curl -fsSL https://get.docker.com | sh \
        || die "Docker installation failed."
    print_ok "Docker installed"
fi

if ! docker info >/dev/null 2>&1; then
    print_warn "Docker daemon not running — starting now..."
    systemctl enable --now docker \
        || die "Failed to start Docker daemon."
fi

docker compose version >/dev/null 2>&1 \
    || die "Docker Compose plugin missing — please reinstall Docker."

if [[ ! -f "$QUICKSTART_COMPOSE" ]]; then
    print_warn "No local repo found — cloning to /opt/lancache-ng..."
    if ! command -v git >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y --no-install-recommends git \
            || die "Failed to install git."
    fi
    if [[ -d "/opt/lancache-ng/.git" ]]; then
        git -C /opt/lancache-ng pull --ff-only
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
INSTALL_DIR="$REPLY"

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_warn "Existing directory found: $INSTALL_DIR"
    ask "Overwrite? [y/N]" "N"
    [[ "${REPLY,,}" = "y" ]] || die "Cancelled."
fi

mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/certs"
cp "$QUICKSTART_COMPOSE" "$INSTALL_DIR/docker-compose.yml"
print_ok "docker-compose.yml copied to $INSTALL_DIR/docker-compose.yml"

# ── 4. Cache configuration ───────────────────────────────────────────────────
print_step "Cache configuration"

ask "Cache directory" "$INSTALL_DIR/cache/standard"
CACHE_DIR_STANDARD="$REPLY"

if [[ "$SSL_ENABLED" = "1" ]]; then
    ask "Cache directory SSL mode" "$INSTALL_DIR/cache/ssl"
    CACHE_DIR_SSL="$REPLY"
else
    CACHE_DIR_SSL="$CACHE_DIR_STANDARD"
fi

while true; do
    ask "Cache size per mode in GiB" "500"
    cache_gb="$REPLY"
    [[ "$cache_gb" =~ ^[0-9]+$ ]] && (( cache_gb > 0 )) && break
    print_error "Please enter a positive integer (e.g. 500)."
done

ask "Cache RAM buffer in MB (keys_zone)" "512"
CACHE_MEM_MB="$REPLY"

# ── 5. Watchtower ─────────────────────────────────────────────────────────────
print_step "Automatic updates (Watchtower)"

printf "  Watchtower checks daily for new images\n"
printf "  and updates containers automatically. Default: enabled.\n\n"

ask "Enable automatic updates? [Y/n]" "Y"
COMPOSE_PROFILES=""
[[ "$SSL_ENABLED" = "1" ]] && COMPOSE_PROFILES="ssl"
if [[ "${REPLY,,}" != "n" ]]; then
    [[ -n "$COMPOSE_PROFILES" ]] && COMPOSE_PROFILES="${COMPOSE_PROFILES},watchtower" || COMPOSE_PROFILES="watchtower"
    print_ok "Watchtower enabled (checks daily at 04:00 for new images)"
else
    print_warn "Watchtower disabled — manual updates with: ./setup.sh update"
fi

# ── 6. DHCP server ───────────────────────────────────────────────────────────
print_step "DHCP server (optional)"

printf "  LanCache-NG can run as a DHCP server and assign cache DNS IPs to clients.\n"
printf "  The existing DHCP server (router) can then be shut down.\n\n"

ask "Enable DHCP server? [y/N]" "N"
DHCP_ENABLED=0
KEA_DATA_DIR=""
DHCP_SUBNET=""
DHCP_GATEWAY=""
DHCP_RANGE_START=""
DHCP_RANGE_END=""
if [[ "${REPLY,,}" = "y" ]]; then
    DHCP_ENABLED=1

    ask "Kea data directory (config + leases)" "$INSTALL_DIR/kea"
    KEA_DATA_DIR="$REPLY"

    ask "DHCP subnet (CIDR)" "10.0.0.0/24"
    DHCP_SUBNET="$REPLY"

    ask "Gateway" "10.0.0.1"
    DHCP_GATEWAY="$REPLY"

    ask "IP pool start" "10.0.0.128"
    DHCP_RANGE_START="$REPLY"

    ask "IP pool end" "10.0.0.254"
    DHCP_RANGE_END="$REPLY"

    print_ok "DHCP enabled — Subnet: $DHCP_SUBNET, Pool: $DHCP_RANGE_START–$DHCP_RANGE_END"
    print_warn "Kea Control Agent port 8000 should be restricted by firewall"
    printf "  iptables (legacy):  iptables -I INPUT -p tcp --dport 8000 ! -s 172.28.0.0/16 -j DROP\n"
    printf "  nftables:           nft add rule inet filter input tcp dport 8000 ip saddr != 172.28.0.0/16 drop\n"
    printf "  ufw:                ufw deny from any to any port 8000\n\n"
else
    print_ok "DHCP skipped — existing router DHCP remains active"
fi

# ── 7. Admin-UI access control ────────────────────────────────────────────────
print_step "Admin-UI access control"

printf "  Admin-UI runs on http://%s:8080 — only accessible within the local network.\n" "$IP_STANDARD"
printf "  Without a password, anyone on the LAN can restart containers and change domains.\n\n"

ask "Protect Admin-UI with password? [y/N]" "N"
UI_AUTH_USER=""
UI_AUTH_PASSWORD=""
if [[ "${REPLY,,}" = "y" ]]; then
    ask "Username" "admin"
    UI_AUTH_USER="$REPLY"
    UI_AUTH_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
    printf "\n"
    print_ok "Credentials:"
    printf "    User:     ${BOLD}%s${RESET}\n" "$UI_AUTH_USER"
    printf "    Password: ${BOLD}%s${RESET}\n" "$UI_AUTH_PASSWORD"
    print_warn "Note the password now — it will also appear in $INSTALL_DIR/.env"
    printf "\n"
else
    print_ok "No password protection — Admin-UI public on LAN"
fi

# ── 8. Writing .env ───────────────────────────────────────────────────────────
print_step "Writing .env"

env_file="$INSTALL_DIR/.env"

if [[ -f "$env_file" ]]; then
    ask "Overwrite .env? [y/N]" "N"
    [[ "${REPLY,,}" = "y" ]] || die "Cancelled."
fi

# Generate or preserve secrets (only preserve non-empty values)
if ! grep -q "^DDNS_TSIG_KEY=[^[:space:]]" "$env_file" 2>/dev/null; then
    DDNS_TSIG_KEY=$(openssl rand -base64 32 | tr -d '\n')
else
    DDNS_TSIG_KEY=$(get_env_var DDNS_TSIG_KEY "$env_file")
fi

if ! grep -q "^NATS_LOCAL_TOKEN=[^[:space:]]" "$env_file" 2>/dev/null; then
    NATS_LOCAL_TOKEN=$(openssl rand -hex 32)
else
    NATS_LOCAL_TOKEN=$(get_env_var NATS_LOCAL_TOKEN "$env_file")
fi

if ! grep -q "^SECONDARY_REGISTRATION_TOKEN=[^[:space:]]" "$env_file" 2>/dev/null; then
    SECONDARY_REGISTRATION_TOKEN=$(openssl rand -hex 32)
else
    SECONDARY_REGISTRATION_TOKEN=$(get_env_var SECONDARY_REGISTRATION_TOKEN "$env_file")
fi

if ! grep -q "^PDNS_API_KEY=[^[:space:]]" "$env_file" 2>/dev/null; then
    PDNS_API_KEY=$(openssl rand -hex 32)
else
    PDNS_API_KEY=$(get_env_var PDNS_API_KEY "$env_file")
fi

cat > "$INSTALL_DIR/.env" <<EOF
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

# For Admin-UI (GB as number for progress bar)
STANDARD_CACHE_MAX_GB=${cache_gb}
SSL_CACHE_MAX_GB=${cache_gb}

# ── DHCP ───────────────────────────────────────────────────────────────────────
DHCP_ENABLED=${DHCP_ENABLED}
KEA_DATA_DIR=${KEA_DATA_DIR}
DHCP_SUBNET=${DHCP_SUBNET}
DHCP_GATEWAY=${DHCP_GATEWAY}
DHCP_RANGE_START=${DHCP_RANGE_START}
DHCP_RANGE_END=${DHCP_RANGE_END}

# Shared TSIG key for Kea DDNS → PowerDNS updates. Keep secret.
DDNS_TSIG_KEY=${DDNS_TSIG_KEY}

# ── NATS (DNS-record sync bus) ─────────────────────────────────────────────────
# Token for local DNS containers (generated, do not change)
NATS_LOCAL_TOKEN=${NATS_LOCAL_TOKEN}
# Token for setup-secondary.sh — anyone who knows this can register a secondary
SECONDARY_REGISTRATION_TOKEN=${SECONDARY_REGISTRATION_TOKEN}

# Shared PowerDNS API key for DNS containers and Admin UI. Keep secret.
PDNS_API_KEY=${PDNS_API_KEY}

# ── Profiles ───────────────────────────────────────────────────────────────────
# ssl = SSL mode active; watchtower = automatic updates; empty = both disabled
COMPOSE_PROFILES=${COMPOSE_PROFILES}

# ── Admin-UI ───────────────────────────────────────────────────────────────────
# Empty = no password protection
UI_AUTH_USER=${UI_AUTH_USER}
UI_AUTH_PASSWORD=${UI_AUTH_PASSWORD}
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
print_step "Installing systemd watchdog"

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
    systemctl enable --now lancache.service
    systemctl enable --now lancache-converge.timer
    print_ok "lancache.service enabled (starts on boot)"
    print_ok "lancache-converge.timer enabled (convergence check every 5 minutes)"
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
if [[ "$DHCP_ENABLED" = "1" ]]; then
    printf "  %-26s %s\n" "DHCP server:"             "$DHCP_SUBNET (Pool: $DHCP_RANGE_START–$DHCP_RANGE_END)"
else
    printf "  %-26s %s\n" "DHCP server:"             "disabled"
fi
if [[ "$COMPOSE_PROFILES" = *watchtower* ]]; then
    printf "  %-26s %s\n" "Watchtower:"              "enabled (daily at 04:00)"
else
    printf "  %-26s %s\n" "Watchtower:"              "disabled"
fi
if [[ -n "$UI_AUTH_USER" ]]; then
    printf "  %-26s %s\n" "Admin-UI auth:"           "enabled (user: $UI_AUTH_USER)"
else
    printf "  %-26s %s\n" "Admin-UI auth:"           "disabled"
fi
printf "${BOLD}└──────────────────────────────────────────────┘${RESET}\n\n"

ask "Start now? [Y/n]" "Y"
[[ "${REPLY,,}" != "n" ]] \
    || { printf "\n  Start later with: cd %s && docker compose up -d\n\n" "$INSTALL_DIR"; exit 0; }

# ── 12. Starting stack ───────────────────────────────────────────────────────
print_step "Pulling images"
cd "$INSTALL_DIR"
docker compose pull || print_warn "Pull partially failed — continuing with cached images"

print_step "Starting stack"
docker compose up -d
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
