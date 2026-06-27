#!/bin/bash
# LanCache-NG — Guided setup script
# Usage: ./setup.sh [install|update|update-ip|debug|backup|restore|help] [options]
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

    # Keep IPv4 validation as one readable regular expression so every octet
    # is range-checked before the value is written into Docker or DNS config.
    # Accepted: 0.0.0.0 through 255.255.255.255. Rejected: partial IPs,
    # hostnames, negative numbers, and out-of-range octets such as 256.
    local octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    [[ "$ip" =~ ^${octet}\.${octet}\.${octet}\.${octet}$ ]]
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
        pacman -Sy --noconfirm "${packages[@]}"
    else
        die "No supported package manager found. Please install these packages manually, then rerun setup.sh: ${packages[*]}"
    fi
}

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

install_docker() {
    local packages=()

    if command -v apt-get >/dev/null 2>&1; then
        packages=(docker.io docker-compose-plugin)
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        packages=(docker docker-compose-plugin)
    elif command -v pacman >/dev/null 2>&1; then
        packages=(docker docker-compose)
    else
        die "No supported package manager found. Please install Docker and the Docker Compose plugin manually, then rerun setup.sh."
    fi

    install_packages "Docker is missing." "${packages[@]}" \
        || die "Failed to install Docker."
}

get_env_var() {
    awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$2" 2>/dev/null || true
}


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
    local env_file="$install_dir/.env"
    local cache_std cache_ssl kea_dir
    cache_std=$(get_env_var CACHE_DIR_STANDARD "$env_file")
    cache_ssl=$(get_env_var CACHE_DIR_SSL "$env_file")
    kea_dir=$(get_env_var KEA_DATA_DIR "$env_file")

    printf '%s\n' "$install_dir/.env" "$install_dir/docker-compose.yml" "$install_dir/certs"
    [[ -d /srv/lancache/pdns-standard ]] && printf '%s\n' /srv/lancache/pdns-standard
    [[ -d /srv/lancache/pdns-ssl ]] && printf '%s\n' /srv/lancache/pdns-ssl
    [[ -d /srv/lancache/kea ]] && printf '%s\n' /srv/lancache/kea
    [[ -d /srv/lancache/nats ]] && printf '%s\n' /srv/lancache/nats
    [[ -d /srv/lancache/nats-conf ]] && printf '%s\n' /srv/lancache/nats-conf
    [[ -n "${kea_dir:-}" && -d "$kea_dir" ]] && printf '%s\n' "$kea_dir"
    if [[ "$mode" = "full" ]]; then
        [[ -n "${cache_std:-}" && -d "$cache_std" ]] && printf '%s\n' "$cache_std"
        [[ -n "${cache_ssl:-}" && "$cache_ssl" != "$cache_std" && -d "$cache_ssl" ]] && printf '%s\n' "$cache_ssl"
        [[ -d /srv/lancache/cache ]] && printf '%s\n' /srv/lancache/cache
    fi
    true
}

path_is_inside() {
    local child="$1" parent="$2"
    child=$(realpath -m "$child")
    parent=$(realpath -m "$parent")
    [[ "$child" = "$parent" || "$child" = "$parent"/* ]]
}

compose_stack_available() {
    local install_dir="$1"
    [[ -f "$install_dir/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1
}

compose_stack_stop() {
    local install_dir="$1"
    compose_stack_available "$install_dir" || return 0
    print_step "Stopping stack for consistent backup/restore"
    (cd "$install_dir" && docker compose stop) || print_warn "docker compose stop failed — continuing"
}

compose_stack_start() {
    local install_dir="$1"
    compose_stack_available "$install_dir" || return 0
    print_step "Starting stack"
    (cd "$install_dir" && docker compose up -d) || print_warn "docker compose up failed — start the stack manually"
}

compose_volume_names() {
    local install_dir="$1" container
    compose_stack_available "$install_dir" || return 0
    while IFS= read -r container; do
        [[ -n "$container" ]] || continue
        docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' "$container"
    done < <(cd "$install_dir" && docker compose ps --all -q 2>/dev/null) | sort -u
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
    local install_dir="$1" output="$2"
    compose_stack_available "$install_dir" || return 0
    (cd "$install_dir" && docker compose images --format json > "$output") 2>/dev/null \
        || (cd "$install_dir" && docker compose images > "$output") 2>/dev/null \
        || print_warn "Could not record current image revisions"
}

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
    [[ -f "$install_dir/docker-compose.yml" && -f "$install_dir/.env" ]] \
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

    local tmp root backup_dir archived_install rel_install stack_stopped=0 path rel target
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

    compose_stack_stop "$install_dir"
    stack_stopped=1

    print_step "Restoring backup"
    if [[ -d "$root/$rel_install" ]]; then
        mkdir -p "$install_dir"
        rsync -aH --numeric-ids "$root/$rel_install/" "$install_dir/"
        if [[ "$archived_install" != "$install_dir" && -f "$install_dir/.env" ]]; then
            sed -i "s#${archived_install}#${install_dir}#g" "$install_dir/.env"
        fi
    fi
    while IFS= read -r path; do
        rel="${path#/}"
        if [[ "$path" = "$archived_install" || "$path" = "$archived_install"/* ]]; then
            continue
        fi
        [[ -e "$root/$rel" ]] || continue
        target="/$rel"
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
cmd_update() {
    local install_dir="${1:-/opt/lancache-ng}"
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die "No stack found in $install_dir. Run ./setup.sh first."
    cd "$install_dir"

    print_step "Creating pre-update rollback backup"
    cmd_backup --config "$install_dir"

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

# ── update-ip subcommand ───────────────────────────────────────────────────────
cmd_update_ip() {
    printf "\n"
    printf "${BOLD}╔═══════════════════════════════════════╗${RESET}\n"
    printf "${BOLD}║  LanCache-NG — Reconfigure IPs        ║${RESET}\n"
    printf "${BOLD}╚═══════════════════════════════════════╝${RESET}\n"
    printf "\n"

    [[ "$(id -u)" = "0" ]] \
        || die "This script must be run as root (sudo ./setup.sh update-ip)."

    print_step "Reading current configuration"

    local deploy_env="$SCRIPT_DIR/deploy/prod/.env"
    local dns_standard_env="$SCRIPT_DIR/config/prod/dns-standard.env"
    local dns_ssl_env="$SCRIPT_DIR/config/prod/dns-ssl.env"

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
    print_warn "Docker Compose plugin missing — installing Docker requirements now..."
    install_docker
fi

docker compose version >/dev/null 2>&1 \
    || die "Docker Compose plugin still missing after installing Docker requirements."

if [[ ! -f "$QUICKSTART_COMPOSE" ]]; then
    print_warn "No local repo found — cloning to /opt/lancache-ng..."
    if ! command -v git >/dev/null 2>&1; then
        install_git
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

printf "  Admin-UI runs on http://%s:8080 — reachable from your LAN by default.\n" "$IP_STANDARD"
printf "  Password protection is optional, but recommended on shared or untrusted networks.\n"
printf "  To restrict the UI to this host later, set UI_BIND_IP=127.0.0.1 in .env.\n\n"

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
    print_warn "No password protection — Admin-UI will be reachable on http://$IP_STANDARD:8080"
fi

# ── 8. Writing .env ───────────────────────────────────────────────────────────
print_step "Writing .env"

env_file="$INSTALL_DIR/.env"

if [[ -f "$env_file" ]]; then
    ask "Overwrite .env? [y/N]" "N"
    [[ "${REPLY,,}" = "y" ]] || die "Cancelled."
fi

# Generate or preserve secrets (only preserve non-empty values)
if ! grep -q "^KEA_CTRL_TOKEN=[^[:space:]]" "$env_file" 2>/dev/null; then
    KEA_CTRL_TOKEN=$(openssl rand -hex 32)
else
    KEA_CTRL_TOKEN=$(get_env_var KEA_CTRL_TOKEN "$env_file")
fi

if ! grep -q "^DDNS_TSIG_KEY=[^[:space:]]" "$env_file" 2>/dev/null; then
    DDNS_TSIG_KEY=$(openssl rand -base64 32 | tr -d '\n')
else
    DDNS_TSIG_KEY=$(get_env_var DDNS_TSIG_KEY "$env_file")
fi

if ! grep -q "^PDNS_API_KEY=[^[:space:]]" "$env_file" 2>/dev/null; then
    PDNS_API_KEY=$(openssl rand -hex 32)
else
    PDNS_API_KEY=$(get_env_var PDNS_API_KEY "$env_file")
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

# Real upstream DNS for nginx origin lookups. Do not set this to a LanCache DNS/proxy IP.
NGINX_UPSTREAM_RESOLVER=8.8.8.8 8.8.4.4
PROXY_SECURITY_MODE=lazy
PROXY_ALLOWED_CLIENT_CIDRS=

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

# Kea Control Agent/API token shared by DHCP and Admin UI. Keep secret.
KEA_CTRL_TOKEN=${KEA_CTRL_TOKEN}

# Shared TSIG key for Kea DDNS → PowerDNS updates. Keep secret.
DDNS_TSIG_KEY=${DDNS_TSIG_KEY}

# ── PowerDNS API ───────────────────────────────────────────────────────────────
# API key for PowerDNS Authoritative + Recursor (generated, do not change)
PDNS_API_KEY=${PDNS_API_KEY}

# ── NATS (DNS-record sync bus) ─────────────────────────────────────────────────
# Token for local DNS containers (generated, do not change)
NATS_LOCAL_TOKEN=${NATS_LOCAL_TOKEN}
# Token for setup-secondary.sh — anyone who knows this can register a secondary
SECONDARY_REGISTRATION_TOKEN=${SECONDARY_REGISTRATION_TOKEN}

# ── Profiles ───────────────────────────────────────────────────────────────────
# ssl = SSL mode active; watchtower = automatic updates; empty = both disabled
COMPOSE_PROFILES=${COMPOSE_PROFILES}

# ── Admin-UI ───────────────────────────────────────────────────────────────────
# Empty = no password protection
UI_AUTH_USER=${UI_AUTH_USER}
UI_AUTH_PASSWORD=${UI_AUTH_PASSWORD}

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
