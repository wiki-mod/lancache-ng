#!/bin/bash
# LanCache-NG — Guided setup script
# Usage: ./setup.sh [update|debug] [install-dir]
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    read -r REPLY
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
    local svc
    for svc in proxy-standard dns-standard proxy-ssl dns-ssl ui netdata; do
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
command -v docker >/dev/null 2>&1 \
    || die "Docker nicht gefunden.\n  Installation: https://docs.docker.com/engine/install/"
docker info >/dev/null 2>&1 \
    || die "Docker-Daemon läuft nicht.\n  Starten mit: systemctl start docker"
docker compose version >/dev/null 2>&1 \
    || die "Docker Compose Plugin fehlt.\n  Installation: https://docs.docker.com/compose/install/"
[[ -f "$QUICKSTART_COMPOSE" ]] \
    || die "docker-compose.yml nicht gefunden: $QUICKSTART_COMPOSE"

print_ok "Docker $(docker --version | grep -oP '[\d.]+'  | head -1)"
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
    ask "Standard-Modus IP (kein CA-Zertifikat)" "${detected_ip:-192.168.1.10}"
    IP_STANDARD="$REPLY"
    is_valid_ipv4 "$IP_STANDARD" && break
    print_error "Ungültige IPv4-Adresse: $IP_STANDARD"
done

suggested_ssl="${IP_STANDARD%.*}.$((${IP_STANDARD##*.} + 1))"

while true; do
    ask "SSL-Modus IP (CA-Zertifikat erforderlich)" "$suggested_ssl"
    IP_SSL="$REPLY"
    is_valid_ipv4 "$IP_SSL" && break
    print_error "Ungültige IPv4-Adresse: $IP_SSL"
done

[[ "$IP_STANDARD" != "$IP_SSL" ]] \
    || die "Standard-IP und SSL-IP dürfen nicht identisch sein."

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

ask "Cache-Verzeichnis Standard-Modus" "$INSTALL_DIR/cache/standard"
CACHE_DIR_STANDARD="$REPLY"

ask "Cache-Verzeichnis SSL-Modus" "$INSTALL_DIR/cache/ssl"
CACHE_DIR_SSL="$REPLY"

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

printf "  Watchtower prüft täglich ob neue Images auf GHCR verfügbar sind\n"
printf "  und aktualisiert die Container automatisch. Standard: aktiv.\n\n"

ask "Automatische Updates deaktivieren? [j/N]" "N"
if [[ "${REPLY,,}" = "j" ]]; then
    COMPOSE_PROFILES=""
    print_warn "Watchtower deaktiviert — manuelle Updates mit: ./setup.sh update"
else
    COMPOSE_PROFILES="watchtower"
    print_ok "Watchtower aktiv (prüft täglich auf neue Images)"
fi

# ── 6. .env schreiben ─────────────────────────────────────────────────────────
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
IP_SSL=${IP_SSL}

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

# ── Profile ───────────────────────────────────────────────────────────────────
# watchtower = automatische tägliche Updates aktiv; leer = deaktiviert
COMPOSE_PROFILES=${COMPOSE_PROFILES}
EOF
print_ok ".env geschrieben: $INSTALL_DIR/.env"

# ── 7. Cache-Verzeichnisse anlegen ────────────────────────────────────────────
print_step "Cache-Verzeichnisse anlegen"
mkdir -p "$CACHE_DIR_STANDARD" "$CACHE_DIR_SSL"
print_ok "Standard: $CACHE_DIR_STANDARD"
print_ok "SSL:      $CACHE_DIR_SSL"

# ── 8. Systemd-Watchdog ───────────────────────────────────────────────────────
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

# ── 9. Zusammenfassung + Bestätigung ─────────────────────────────────────────
printf "\n"
printf "${BOLD}┌──────────────────────────────────────────────┐${RESET}\n"
printf "${BOLD}│              Konfiguration                   │${RESET}\n"
printf "${BOLD}├──────────────────────────────────────────────┤${RESET}\n"
printf "  %-26s %s\n"    "Standard-IP:"              "$IP_STANDARD"
printf "  %-26s %s\n"    "SSL-IP:"                   "$IP_SSL"
printf "  %-26s %s\n"    "Installations-Dir:"        "$INSTALL_DIR"
printf "  %-26s %s\n"    "Cache Standard:"           "$CACHE_DIR_STANDARD"
printf "  %-26s %s\n"    "Cache SSL:"                "$CACHE_DIR_SSL"
printf "  %-26s %s GiB\n" "Cache-Größe:"             "$cache_gb"
printf "  %-26s %s MB\n"  "Cache-RAM:"               "$CACHE_MEM_MB"
if [[ -n "$COMPOSE_PROFILES" ]]; then
    printf "  %-26s %s\n" "Watchtower:"               "aktiv (täglich)"
else
    printf "  %-26s %s\n" "Watchtower:"               "deaktiviert"
fi
printf "${BOLD}└──────────────────────────────────────────────┘${RESET}\n\n"

ask "Jetzt starten? [J/n]" "J"
[[ "${REPLY,,}" != "n" ]] \
    || { printf "\n  Später starten mit: cd %s && docker compose up -d\n\n" "$INSTALL_DIR"; exit 0; }

# ── 10. Stack starten ─────────────────────────────────────────────────────────
print_step "Images laden"
cd "$INSTALL_DIR"
docker compose pull || print_warn "Pull teilweise fehlgeschlagen — weiter mit gecachten Images"

print_step "Stack starten"
docker compose up -d
print_ok "Stack gestartet"

# ── 11. Post-Start-Info ───────────────────────────────────────────────────────
printf "\n"
printf "${BOLD}${GREEN}══════════════════════════════════════════════════${RESET}\n"
printf "${BOLD}${GREEN}  LanCache-NG läuft!${RESET}\n"
printf "${BOLD}${GREEN}══════════════════════════════════════════════════${RESET}\n"
printf "\n"
printf "  ${BOLD}Admin-UI:${RESET}    http://%s:8080\n" "$IP_STANDARD"
printf "\n"
printf "  ${BOLD}CA-Zertifikat${RESET} (nach erstem Start verfügbar):\n"
printf "    %s/certs/ca.crt\n" "$INSTALL_DIR"
printf "    → auf Clients installieren für SSL-Modus\n"
printf "    → Anleitung: %s/docs/install-ca-cert.md\n" "$SCRIPT_DIR"
printf "\n"
printf "  ${BOLD}DNS auf Clients einstellen:${RESET}\n"
printf "    Standard-Modus (kein Zertifikat nötig): %s\n" "$IP_STANDARD"
printf "    SSL-Modus (mit Zertifikat):              %s\n" "$IP_SSL"
printf "\n"
printf "  ${BOLD}Befehle:${RESET}\n"
printf "    Status:  %s/setup.sh debug\n"  "$SCRIPT_DIR"
printf "    Update:  %s/setup.sh update\n" "$SCRIPT_DIR"
printf "\n"
