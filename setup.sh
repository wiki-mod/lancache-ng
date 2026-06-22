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
    read -r REPLY </dev/tty
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
        || die "Kein Stack in $install_dir gefunden. Zuerst ./setup.sh ausführen."
    cd "$install_dir"

    if [[ -d "$install_dir/.git" ]]; then
        print_step "Repo aktualisieren"
        git -C "$install_dir" pull --ff-only \
            || print_warn "git pull fehlgeschlagen — weiter mit lokaler Version"
        cp "$install_dir/deploy/quickstart/docker-compose.yml" \
           "$install_dir/docker-compose.yml"
        print_ok "docker-compose.yml aktualisiert"
    fi

    print_step "Neueste Images laden"
    docker compose pull || print_warn "Pull teilweise fehlgeschlagen — weiter mit gecachten Images"

    print_step "Container neu starten"
    docker compose up -d --remove-orphans
    print_ok "Stack aktualisiert"
}

# ── debug subcommand ──────────────────────────────────────────────────────────
cmd_debug() {
    local install_dir="${1:-/opt/lancache-ng}"
    [[ -f "$install_dir/docker-compose.yml" ]] \
        || die "Kein Stack in $install_dir gefunden. Zuerst ./setup.sh ausführen."
    cd "$install_dir"

    local env_file="$install_dir/.env"
    local ip_standard ip_ssl cache_std cache_ssl
    ip_standard=$(get_env_var IP_STANDARD "$env_file")
    ip_ssl=$(get_env_var IP_SSL "$env_file")
    cache_std=$(get_env_var CACHE_DIR_STANDARD "$env_file")
    cache_ssl=$(get_env_var CACHE_DIR_SSL "$env_file")

    print_step "Container-Status"
    docker compose ps

    print_step "Logs (letzte 30 Zeilen je Service)"
    local ssl_enabled; ssl_enabled=$(get_env_var SSL_ENABLED "$env_file")
    local svc_list="proxy-standard dns-standard ui netdata watchdog"
    [[ "${ssl_enabled:-1}" = "1" ]] && svc_list="proxy-standard dns-standard proxy-ssl dns-ssl ui netdata watchdog"
    local svc
    for svc in $svc_list; do
        printf "\n${BOLD}--- %s ---${RESET}\n" "$svc"
        docker compose logs --tail=30 "$svc" 2>/dev/null || true
    done

    print_step "Cache-Belegung"
    local dir
    for dir in "$cache_std" "$cache_ssl"; do
        [[ -z "$dir" ]] && continue
        if [[ -d "$dir" ]]; then
            du -sh "$dir"
        else
            print_warn "Verzeichnis nicht gefunden: $dir"
        fi
    done

    print_step "Netzwerk (LAN-IPs)"
    ip -4 addr show | grep "inet " | grep -v " 127\." | grep -v " 172\." || true

    print_step "Healthchecks"
    if ! command -v curl >/dev/null 2>&1; then
        print_warn "curl nicht gefunden — Healthchecks übersprungen"
    else
        local ip
        for ip in "$ip_standard" "$ip_ssl"; do
            [[ -z "$ip" ]] && continue
            if curl -sf "http://$ip/healthz" >/dev/null 2>&1; then
                print_ok "http://$ip/healthz — OK"
            else
                print_error "http://$ip/healthz — FEHLER"
            fi
        done
    fi
}

# ── Dispatch subcommands ──────────────────────────────────────────────────────
case "${1:-}" in
    update) cmd_update "${2:-/opt/lancache-ng}"; exit 0 ;;
    debug)  cmd_debug  "${2:-/opt/lancache-ng}"; exit 0 ;;
    "")     ;;
    *)      die "Unbekannter Befehl: $1\nVerwendung: $0 [update|debug] [install-dir]" ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# Hauptsetup
# ══════════════════════════════════════════════════════════════════════════════

printf "\n"
printf "${BOLD}╔══════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}║      LanCache-NG — Ersteinrichtung       ║${RESET}\n"
printf "${BOLD}╚══════════════════════════════════════════╝${RESET}\n"
printf "\n"
printf "  Dieses Skript richtet LanCache-NG ein und startet alle Container.\n"
printf "  Danach: ./setup.sh update  |  ./setup.sh debug\n"

# ── 1. Voraussetzungen ────────────────────────────────────────────────────────
print_step "Voraussetzungen prüfen"

[[ "$(id -u)" = "0" ]] \
    || die "Dieses Skript muss als root ausgeführt werden (sudo ./setup.sh)."

if ! command -v curl >/dev/null 2>&1; then
    print_warn "curl fehlt — wird nachinstalliert..."
    apt-get install -y --no-install-recommends curl \
        || die "curl konnte nicht installiert werden."
fi

if ! command -v docker >/dev/null 2>&1; then
    print_warn "Docker nicht gefunden — wird jetzt installiert (get.docker.com)..."
    curl -fsSL https://get.docker.com | sh \
        || die "Docker-Installation fehlgeschlagen."
    print_ok "Docker installiert"
fi

if ! docker info >/dev/null 2>&1; then
    print_warn "Docker-Daemon läuft nicht — wird gestartet..."
    systemctl enable --now docker \
        || die "Docker-Daemon konnte nicht gestartet werden."
fi

docker compose version >/dev/null 2>&1 \
    || die "Docker Compose Plugin fehlt — bitte Docker neu installieren."

if [[ ! -f "$QUICKSTART_COMPOSE" ]]; then
    print_warn "Kein lokales Repo gefunden — klone nach /opt/lancache-ng..."
    command -v git >/dev/null 2>&1 \
        || apt-get install -y --no-install-recommends git \
        || die "git konnte nicht installiert werden."
    if [[ -d "/opt/lancache-ng/.git" ]]; then
        git -C /opt/lancache-ng pull --ff-only
    else
        git clone https://github.com/wiki-mod/lancache-ng.git /opt/lancache-ng \
            || die "Klonen fehlgeschlagen."
    fi
    chmod +x /opt/lancache-ng/setup.sh
    exec /opt/lancache-ng/setup.sh "$@"
fi

print_ok "Docker $(docker --version | grep -oP '[\d.]+' | head -1)"
print_ok "Docker Compose $(docker compose version --short 2>/dev/null || true)"

# ── 2. Netzwerk-IPs ───────────────────────────────────────────────────────────
print_step "Netzwerk-Konfiguration"

detected_ip=$(ip -4 addr show | grep -oP '(?<=inet )[\d.]+' \
    | grep -v '^127\.' | grep -v '^172\.' | head -1 || true)
detected_iface=$(ip -4 route show default | awk '{print $5}' | head -1 || true)

printf "\n  Gefundene LAN-Adressen:\n"
ip -4 addr show | grep "inet " | grep -v " 127\." | grep -v " 172\." \
    | awk '{print "    " $2}' || true
printf "\n"

while true; do
    ask "Server-IP (Standard-Modus)" "${detected_ip:-192.168.1.10}"
    IP_STANDARD="$REPLY"
    is_valid_ipv4 "$IP_STANDARD" && break
    print_error "Ungültige IPv4-Adresse: $IP_STANDARD"
done

printf "\n"
printf "  ${BOLD}SSL-Modus${RESET}: cachet auch HTTPS-Downloads (Epic, EA, Blizzard…)\n"
printf "  Braucht eine zweite IP und einmalig ein CA-Zertifikat auf den Clients.\n\n"
ask "SSL-Modus aktivieren? [j/N]" "N"
SSL_ENABLED=0
IP_SSL=""
if [[ "${REPLY,,}" = "j" ]]; then
    SSL_ENABLED=1
    suggested_ssl="${IP_STANDARD%.*}.$((${IP_STANDARD##*.} + 1))"
    while true; do
        ask "SSL-Modus IP (zweite LAN-IP)" "$suggested_ssl"
        IP_SSL="$REPLY"
        is_valid_ipv4 "$IP_SSL" && break
        print_error "Ungültige IPv4-Adresse: $IP_SSL"
    done
    [[ "$IP_STANDARD" != "$IP_SSL" ]] \
        || die "Standard-IP und SSL-IP müssen verschieden sein."
    if ip -4 addr show | grep -q "inet ${IP_SSL}/"; then
        print_ok "$IP_SSL ist bereits zugewiesen"
    else
        print_warn "$IP_SSL ist noch nicht auf einem Interface zugewiesen"
        ask "Jetzt hinzufügen? (ip addr add $IP_SSL/24 dev ${detected_iface:-eth0}) [j/N]" "N"
        if [[ "${REPLY,,}" = "j" ]]; then
            ip addr add "$IP_SSL/24" dev "${detected_iface:-eth0}" \
                && print_ok "$IP_SSL hinzugefügt (nicht persistent)" \
                || print_warn "Hinzufügen fehlgeschlagen — bitte manuell ausführen"
        fi
        printf "\n"
        print_warn "Für persistente Konfiguration nach Neustart:"
        printf "    netplan:    sudo nano /etc/netplan/01-netcfg.yaml\n"
        printf "    interfaces: sudo nano /etc/network/interfaces\n"
    fi
    print_ok "SSL-Modus aktiviert ($IP_SSL)"
else
    print_ok "SSL-Modus übersprungen — nur Standard-Modus aktiv"
fi

# ── 3. Installations-Verzeichnis ──────────────────────────────────────────────
print_step "Installations-Verzeichnis"

ask "Verzeichnis" "/opt/lancache-ng"
INSTALL_DIR="$REPLY"

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_warn "Bestehendes Verzeichnis gefunden: $INSTALL_DIR"
    ask "Überschreiben? [j/N]" "N"
    [[ "${REPLY,,}" = "j" ]] || die "Abgebrochen."
fi

mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/certs"
cp "$QUICKSTART_COMPOSE" "$INSTALL_DIR/docker-compose.yml"
print_ok "docker-compose.yml → $INSTALL_DIR/docker-compose.yml"

# ── 4. Cache-Konfiguration ────────────────────────────────────────────────────
print_step "Cache-Konfiguration"

ask "Cache-Verzeichnis" "$INSTALL_DIR/cache/standard"
CACHE_DIR_STANDARD="$REPLY"

if [[ "$SSL_ENABLED" = "1" ]]; then
    ask "Cache-Verzeichnis SSL-Modus" "$INSTALL_DIR/cache/ssl"
    CACHE_DIR_SSL="$REPLY"
else
    CACHE_DIR_SSL="$CACHE_DIR_STANDARD"
fi

while true; do
    ask "Cache-Größe pro Modus in GiB" "500"
    cache_gb="$REPLY"
    [[ "$cache_gb" =~ ^[0-9]+$ ]] && (( cache_gb > 0 )) && break
    print_error "Bitte eine positive Ganzzahl eingeben (z.B. 500)."
done

ask "Cache-RAM-Puffer in MB (keys_zone)" "512"
CACHE_MEM_MB="$REPLY"

# ── 5. Watchtower ─────────────────────────────────────────────────────────────
print_step "Automatische Updates (Watchtower)"

printf "  Watchtower prüft täglich ob neue Images verfügbar sind\n"
printf "  und aktualisiert die Container automatisch. Standard: aktiv.\n\n"

ask "Automatische Updates aktivieren? [J/n]" "J"
COMPOSE_PROFILES=""
[[ "$SSL_ENABLED" = "1" ]] && COMPOSE_PROFILES="ssl"
if [[ "${REPLY,,}" != "n" ]]; then
    [[ -n "$COMPOSE_PROFILES" ]] && COMPOSE_PROFILES="${COMPOSE_PROFILES},watchtower" || COMPOSE_PROFILES="watchtower"
    print_ok "Watchtower aktiv (prüft täglich um 04:00 Uhr auf neue Images)"
else
    print_warn "Watchtower deaktiviert — manuelle Updates mit: ./setup.sh update"
fi

# ── 6. DHCP-Server ───────────────────────────────────────────────────────────
print_step "DHCP-Server (optional)"

printf "  LanCache-NG kann als DHCP-Server laufen und Clients automatisch\n"
printf "  die Cache-DNS-IPs zuweisen. Bestehender DHCP-Server (Router) kann\n"
printf "  danach abgeschaltet werden.\n\n"

ask "DHCP-Server aktivieren? [j/N]" "N"
DHCP_ENABLED=0
KEA_DATA_DIR=""
DHCP_SUBNET=""
DHCP_GATEWAY=""
DHCP_RANGE_START=""
DHCP_RANGE_END=""
if [[ "${REPLY,,}" = "j" ]]; then
    DHCP_ENABLED=1

    ask "Kea-Daten-Verzeichnis (Config + Leases)" "$INSTALL_DIR/kea"
    KEA_DATA_DIR="$REPLY"

    ask "DHCP-Subnet (CIDR)" "10.0.0.0/24"
    DHCP_SUBNET="$REPLY"

    ask "Gateway" "10.0.0.1"
    DHCP_GATEWAY="$REPLY"

    ask "IP-Pool Start" "10.0.0.128"
    DHCP_RANGE_START="$REPLY"

    ask "IP-Pool Ende" "10.0.0.254"
    DHCP_RANGE_END="$REPLY"

    print_ok "DHCP aktiviert — Subnet: $DHCP_SUBNET, Pool: $DHCP_RANGE_START–$DHCP_RANGE_END"
    print_warn "Kea Control Agent Port 8000 wird per Firewall empfohlen"
    printf "    iptables -I INPUT -p tcp --dport 8000 ! -s 172.28.0.0/16 -j DROP\n\n"
else
    print_ok "DHCP übersprungen — bestehender Router-DHCP bleibt aktiv"
fi

# ── 7. Admin-UI Zugangschutz ──────────────────────────────────────────────────
print_step "Admin-UI Zugangschutz"

printf "  Die Admin-UI läuft auf http://%s:8080 — nur im lokalen Netz erreichbar.\n" "$IP_STANDARD"
printf "  Ohne Passwort kann jeder im LAN Container neu starten und Domains ändern.\n\n"

ask "Admin-UI mit Passwort schützen? [j/N]" "N"
UI_AUTH_USER=""
UI_AUTH_PASSWORD=""
if [[ "${REPLY,,}" = "j" ]]; then
    ask "Benutzername" "admin"
    UI_AUTH_USER="$REPLY"
    UI_AUTH_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
    printf "\n"
    print_ok "Zugangsdaten:"
    printf "    Benutzer:  ${BOLD}%s${RESET}\n" "$UI_AUTH_USER"
    printf "    Passwort:  ${BOLD}%s${RESET}\n" "$UI_AUTH_PASSWORD"
    print_warn "Passwort jetzt notieren — steht auch später in $INSTALL_DIR/.env"
    printf "\n"
else
    print_ok "Kein Passwortschutz — Admin-UI öffentlich im LAN"
fi

# ── 8. .env schreiben ─────────────────────────────────────────────────────────
# Generate TSIG key for Kea DDNS ↔ BIND9 (shared across DHCP + DNS containers)
DDNS_TSIG_KEY=$(openssl rand -base64 32 | tr -d '\n')

print_step ".env schreiben"

if [[ -f "$INSTALL_DIR/.env" ]]; then
    ask ".env überschreiben? [j/N]" "N"
    [[ "${REPLY,,}" = "j" ]] || die "Abgebrochen."
fi

cat > "$INSTALL_DIR/.env" <<EOF
# ── LAN-IPs ───────────────────────────────────────────────────────────────────
# Standard-Modus (kein CA-Zertifikat nötig): HTTP gecacht, HTTPS durchgeleitet
IP_STANDARD=${IP_STANDARD}

# SSL-Modus (CA-Zertifikat auf Clients installieren): HTTP + HTTPS gecacht
# Leer = SSL-Modus deaktiviert
IP_SSL=${IP_SSL}

# ── SSL ───────────────────────────────────────────────────────────────────────
SSL_ENABLED=${SSL_ENABLED}

# ── Cache ─────────────────────────────────────────────────────────────────────
CACHE_DIR_STANDARD=${CACHE_DIR_STANDARD}
CACHE_DIR_SSL=${CACHE_DIR_SSL}

CACHE_MAX_SIZE=${cache_gb}g
CACHE_MEM_MB=${CACHE_MEM_MB}
CACHE_SLICE_SIZE=8m
CACHE_VALID_HIT=365d
CACHE_VALID_ANY=1m
CACHE_INACTIVE=365d

# Für die Admin-UI (GB als Zahl für den Füllstandsbalken)
STANDARD_CACHE_MAX_GB=${cache_gb}
SSL_CACHE_MAX_GB=${cache_gb}

# ── DHCP ──────────────────────────────────────────────────────────────────────
DHCP_ENABLED=${DHCP_ENABLED}
KEA_DATA_DIR=${KEA_DATA_DIR}
DHCP_SUBNET=${DHCP_SUBNET}
DHCP_GATEWAY=${DHCP_GATEWAY}
DHCP_RANGE_START=${DHCP_RANGE_START}
DHCP_RANGE_END=${DHCP_RANGE_END}

# Shared TSIG key for Kea DDNS → BIND9 updates. Keep secret.
DDNS_TSIG_KEY=${DDNS_TSIG_KEY}

# ── Profile ───────────────────────────────────────────────────────────────────
# ssl = SSL-Modus aktiv; watchtower = automatische Updates; leer = beides aus
COMPOSE_PROFILES=${COMPOSE_PROFILES}

# ── Admin-UI ──────────────────────────────────────────────────────────────────
# Leer = kein Passwortschutz
UI_AUTH_USER=${UI_AUTH_USER}
UI_AUTH_PASSWORD=${UI_AUTH_PASSWORD}
EOF
print_ok ".env geschrieben: $INSTALL_DIR/.env"

# ── 9. Verzeichnisse anlegen ──────────────────────────────────────────────────
print_step "Verzeichnisse anlegen"
mkdir -p "$CACHE_DIR_STANDARD"
print_ok "Standard-Cache: $CACHE_DIR_STANDARD"
if [[ "$SSL_ENABLED" = "1" && "$CACHE_DIR_SSL" != "$CACHE_DIR_STANDARD" ]]; then
    mkdir -p "$CACHE_DIR_SSL"
    print_ok "SSL-Cache:      $CACHE_DIR_SSL"
fi
if [[ "$DHCP_ENABLED" = "1" && -n "$KEA_DATA_DIR" ]]; then
    mkdir -p "$KEA_DATA_DIR"
    print_ok "Kea-Daten:      $KEA_DATA_DIR"
fi

# ── 10. Systemd-Watchdog ──────────────────────────────────────────────────────
print_step "Systemd-Watchdog installieren"

if ! command -v systemctl >/dev/null 2>&1; then
    print_warn "systemd nicht gefunden — Watchdog wird nicht installiert"
    print_warn "Stack manuell nach Neustart starten: cd $INSTALL_DIR && docker compose up -d"
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
    print_ok "lancache.service aktiviert (Start beim Booten)"
    print_ok "lancache-converge.timer aktiviert (Konvergenz alle 5 Minuten)"
fi

# ── 11. Zusammenfassung + Bestätigung ────────────────────────────────────────
printf "\n"
printf "${BOLD}┌──────────────────────────────────────────────┐${RESET}\n"
printf "${BOLD}│              Konfiguration                   │${RESET}\n"
printf "${BOLD}├──────────────────────────────────────────────┤${RESET}\n"
printf "  %-26s %s\n"    "Standard-IP:"              "$IP_STANDARD"
if [[ "$SSL_ENABLED" = "1" ]]; then
    printf "  %-26s %s\n" "SSL-IP:"                  "$IP_SSL"
else
    printf "  %-26s %s\n" "SSL-Modus:"               "deaktiviert"
fi
printf "  %-26s %s\n"    "Installations-Dir:"        "$INSTALL_DIR"
printf "  %-26s %s\n"    "Cache:"                    "$CACHE_DIR_STANDARD"
[[ "$SSL_ENABLED" = "1" && "$CACHE_DIR_SSL" != "$CACHE_DIR_STANDARD" ]] \
    && printf "  %-26s %s\n" "Cache SSL:"            "$CACHE_DIR_SSL"
printf "  %-26s %s GiB\n" "Cache-Größe:"             "$cache_gb"
printf "  %-26s %s MB\n"  "Cache-RAM:"               "$CACHE_MEM_MB"
if [[ "$DHCP_ENABLED" = "1" ]]; then
    printf "  %-26s %s\n" "DHCP-Server:"              "$DHCP_SUBNET (Pool: $DHCP_RANGE_START–$DHCP_RANGE_END)"
else
    printf "  %-26s %s\n" "DHCP-Server:"              "deaktiviert"
fi
if [[ "$COMPOSE_PROFILES" = *watchtower* ]]; then
    printf "  %-26s %s\n" "Watchtower:"               "aktiv (täglich 04:00)"
else
    printf "  %-26s %s\n" "Watchtower:"               "deaktiviert"
fi
if [[ -n "$UI_AUTH_USER" ]]; then
    printf "  %-26s %s\n" "Admin-UI Auth:"            "aktiv (Benutzer: $UI_AUTH_USER)"
else
    printf "  %-26s %s\n" "Admin-UI Auth:"            "deaktiviert"
fi
printf "${BOLD}└──────────────────────────────────────────────┘${RESET}\n\n"

ask "Jetzt starten? [J/n]" "J"
[[ "${REPLY,,}" != "n" ]] \
    || { printf "\n  Später starten mit: cd %s && docker compose up -d\n\n" "$INSTALL_DIR"; exit 0; }

# ── 12. Stack starten ────────────────────────────────────────────────────────
print_step "Images laden"
cd "$INSTALL_DIR"
docker compose pull || print_warn "Pull teilweise fehlgeschlagen — weiter mit gecachten Images"

print_step "Stack starten"
docker compose up -d
print_ok "Stack gestartet"

# ── 13. Post-Start-Info ──────────────────────────────────────────────────────
printf "\n"
printf "${BOLD}${GREEN}══════════════════════════════════════════════════${RESET}\n"
printf "${BOLD}${GREEN}  LanCache-NG läuft!${RESET}\n"
printf "${BOLD}${GREEN}══════════════════════════════════════════════════${RESET}\n"
printf "\n"
if [[ -n "$UI_AUTH_USER" ]]; then
    printf "  ${BOLD}Admin-UI:${RESET}    http://%s:8080  (Benutzer: %s)\n" "$IP_STANDARD" "$UI_AUTH_USER"
else
    printf "  ${BOLD}Admin-UI:${RESET}    http://%s:8080\n" "$IP_STANDARD"
fi
printf "\n"
if [[ "$SSL_ENABLED" = "1" ]]; then
    printf "  ${BOLD}CA-Zertifikat${RESET} (nach erstem Start verfügbar):\n"
    printf "    %s/certs/ca.crt\n" "$INSTALL_DIR"
    printf "    → auf Clients installieren für SSL-Modus\n"
    printf "    → Anleitung: https://github.com/wiki-mod/lancache-ng/wiki\n"
    printf "\n"
fi
printf "  ${BOLD}DNS auf Clients einstellen:${RESET}\n"
printf "    Standard-Modus (kein Zertifikat): %s\n" "$IP_STANDARD"
if [[ "$SSL_ENABLED" = "1" ]]; then
    printf "    SSL-Modus (mit Zertifikat):       %s\n" "$IP_SSL"
fi
printf "\n"
printf "  ${BOLD}Befehle:${RESET}\n"
printf "    Status:  %s/setup.sh debug\n"  "$SCRIPT_DIR"
printf "    Update:  %s/setup.sh update\n" "$SCRIPT_DIR"
printf "\n"
