#!/bin/bash
set -euo pipefail

DOCKER_PROXY_URL="${DOCKER_PROXY_URL:-http://docker-socket-proxy:2375}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
RESTART_AFTER="${RESTART_AFTER:-3}"
DISK_WARN_PCT="${DISK_WARN_PCT:-85}"
DISK_ALARM_PCT="${DISK_ALARM_PCT:-95}"
CACHE_DIR_STANDARD="${CACHE_DIR_STANDARD:-/cache/standard}"
CACHE_DIR_SSL="${CACHE_DIR_SSL:-/cache/ssl}"
CACHE_VALID_DAYS="${CACHE_VALID_DAYS:-365}"
STATUS_FILE="${STATUS_FILE:-/var/run/watchdog/status.json}"
PURGE_STAMP="/var/run/watchdog/purge.stamp"

SSL_ENABLED="${SSL_ENABLED:-1}"

C_PROXY="${CONTAINER_PROXY:-lancache-proxy}"
C_DNS_STD="${CONTAINER_DNS_STANDARD:-lancache-dns-standard}"
if [ "$SSL_ENABLED" = "1" ]; then
    C_DNS_SSL="${CONTAINER_DNS_SSL:-lancache-dns-ssl}"
else
    C_DNS_SSL=""
fi

F_PROXY=0; F_DNS_STD=0; F_DNS_SSL=0
H_PROXY="unknown"; H_DNS_STD="unknown"; H_DNS_SSL="unknown"

log() { echo "[watchdog] $(date -u +%H:%M:%S) $*"; }

get_health() {
    local name="$1"
    curl -sf "${DOCKER_PROXY_URL}/containers/${name}/json" 2>/dev/null \
        | jq -r '.State.Health.Status // "none"' 2>/dev/null \
        || echo "unreachable"
}

restart_container() {
    local name="$1"
    log "RESTARTING $name"
    curl -sf -X POST "${DOCKER_PROXY_URL}/containers/${name}/restart" >/dev/null 2>&1 \
        || log "WARNING: restart call failed for $name"
}

health_color() {
    case "$1" in
        healthy)   echo "green" ;;
        starting)  echo "yellow" ;;
        unhealthy) echo "red" ;;
        *)         echo "yellow" ;;
    esac
}

disk_info() {
    local dir="$1"
    [ -d "$dir" ] || { printf '{"pct": 0, "status": "unknown"}'; return; }
    local pct
    pct=$(df "$dir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}') || pct=0
    local status="green"
    if   [ "${pct:-0}" -ge "$DISK_ALARM_PCT" ]; then status="red"
    elif [ "${pct:-0}" -ge "$DISK_WARN_PCT"  ]; then status="yellow"
    fi
    printf '{"pct": %s, "status": "%s"}' "$pct" "$status"
}

check_and_maybe_restart() {
    local name="$1"
    local -n _fcount="$2"
    local -n _hstring="$3"

    local health
    health=$(get_health "$name")
    _hstring="$health"

    if [ "$health" = "unhealthy" ]; then
        _fcount=$((_fcount + 1))
        log "UNHEALTHY $name (${_fcount}/${RESTART_AFTER})"
        if [ "$_fcount" -ge "$RESTART_AFTER" ]; then
            restart_container "$name"
            _fcount=0
        fi
    elif [ "$health" = "healthy" ]; then
        [ "$_fcount" -gt 0 ] && log "RECOVERED $name"
        _fcount=0
    fi
}

write_status() {
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local disk_std; disk_std=$(disk_info "$CACHE_DIR_STANDARD")

    mkdir -p "$(dirname "$STATUS_FILE")"

    local ssl_services=""
    if [ "$SSL_ENABLED" = "1" ]; then
        ssl_services=",
    \"$C_DNS_SSL\":   {\"status\": \"$(health_color "$H_DNS_SSL")\",   \"health\": \"$H_DNS_SSL\",   \"failures\": $F_DNS_SSL}"
    fi

    cat > "${STATUS_FILE}.tmp" <<EOF
{
  "updated": "$ts",
  "services": {
    "$C_PROXY": {"status": "$(health_color "$H_PROXY")", "health": "$H_PROXY", "failures": $F_PROXY},
    "$C_DNS_STD":   {"status": "$(health_color "$H_DNS_STD")",   "health": "$H_DNS_STD",   "failures": $F_DNS_STD}${ssl_services}
  },
  "disk": {
    "standard": ${disk_std}
  }
}
EOF
    mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

maybe_purge() {
    local now; now=$(date +%s)
    local last=0
    [ -f "$PURGE_STAMP" ] && last=$(cat "$PURGE_STAMP")
    [ $((now - last)) -lt 86400 ] && return

    log "Daily purge: removing cache files older than ${CACHE_VALID_DAYS} days"
    for dir in "$CACHE_DIR_STANDARD" "$CACHE_DIR_SSL"; do
        [ -d "$dir" ] || continue
        local count=0
        while IFS= read -r file; do
            rm -f "$file"
            count=$(( count + 1 ))
        done < <(find "$dir" -type f -mtime "+${CACHE_VALID_DAYS}" 2>/dev/null)
        log "Purged $count files from $dir"
    done
    mkdir -p "$(dirname "$PURGE_STAMP")"
    echo "$now" > "$PURGE_STAMP"
}

log "Starting. Monitoring: $C_PROXY $C_DNS_STD $C_DNS_SSL (SSL_ENABLED=$SSL_ENABLED)"
log "Interval: ${CHECK_INTERVAL}s | Restart after: ${RESTART_AFTER} | Disk warn: ${DISK_WARN_PCT}% alarm: ${DISK_ALARM_PCT}%"

while true; do
    check_and_maybe_restart "$C_PROXY" F_PROXY H_PROXY
    check_and_maybe_restart "$C_DNS_STD"   F_DNS_STD   H_DNS_STD
    if [ "$SSL_ENABLED" = "1" ]; then
        check_and_maybe_restart "$C_DNS_SSL"   F_DNS_SSL   H_DNS_SSL
    fi
    write_status
    maybe_purge
    sleep "$CHECK_INTERVAL"
done
