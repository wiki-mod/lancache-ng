#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Health monitor, auto-restart on failure, and periodic cache-age purge daemon.

set -euo pipefail

DOCKER_PROXY_URL="${DOCKER_PROXY_URL:-http://docker-socket-proxy:2375}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
RESTART_AFTER="${RESTART_AFTER:-3}"
DISK_WARN_PCT="${DISK_WARN_PCT:-85}"
DISK_ALARM_PCT="${DISK_ALARM_PCT:-95}"
CACHE_VALID_DAYS="${CACHE_VALID_DAYS:-365}"
STATUS_FILE="${STATUS_FILE:-/var/run/watchdog/status.json}"
PURGE_STAMP="/var/run/watchdog/purge.stamp"

# Central syslog-ng retention engine (#633). Fail-closed: unset/anything but
# "true" leaves maybe_prune_syslog() a no-op, matching the project's
# opt-in-only `logging` profile (installs that never enable it must never
# have watchdog touch a path that doesn't exist for them).
SYSLOG_ENABLED="${SYSLOG_ENABLED:-false}"
SYSLOG_PRUNE_STAMP="/var/run/watchdog/syslog-prune.stamp"

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

# Keep the watchdog on one cache path only. If an old install still carries
# split cache vars, they must agree or the helper refuses to guess.
resolve_cache_dir() {
    local cache_dir cache_std cache_ssl

    cache_dir="${CACHE_DIR:-}"
    cache_std="${CACHE_DIR_STANDARD:-}"
    cache_ssl="${CACHE_DIR_SSL:-}"

    if [ -n "$cache_dir" ]; then
        printf '%s\n' "$cache_dir"
        return 0
    fi

    if [ -n "$cache_std" ] && [ -n "$cache_ssl" ] && [ "$cache_std" != "$cache_ssl" ]; then
        log "ERROR: CACHE_DIR_STANDARD and CACHE_DIR_SSL point to different paths without CACHE_DIR. Set CACHE_DIR to one shared cache directory."
        exit 1
    fi

    if [ -n "$cache_std" ]; then
        printf '%s\n' "$cache_std"
        return 0
    fi

    if [ -n "$cache_ssl" ]; then
        printf '%s\n' "$cache_ssl"
        return 0
    fi

    printf '%s\n' "/var/cache/lancache"
}

CACHE_DIR="$(resolve_cache_dir)"

get_health() {
    local name="$1"
    # Docker socket access is routed through the narrowed proxy, so health reads
    # must stay on the allowed container-inspect endpoint rather than exec.
    curl -sf "${DOCKER_PROXY_URL}/containers/${name}/json" 2>/dev/null \
        | jq -r '.State.Health.Status // "none"' 2>/dev/null \
        || echo "unreachable"
}

restart_container() {
    local name="$1"
    log "RESTARTING $name"
    # Restart is intentionally the only mutating Docker operation watchdog uses.
    # Container creation/exec remain unavailable through the proxy allowlist.
    curl -sf -X POST "${DOCKER_PROXY_URL}/containers/${name}/restart" >/dev/null 2>&1 \
        || log "WARNING: restart call failed for $name"
}

health_color() {
    # Dashboard cards consume these stable color names directly.
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
    # df reports the filesystem behind CACHE_DIR, which is the operator-visible
    # capacity limit for the single shared cache path.
    pct=$(df "$dir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}') || pct=0
    local status="green"
    if   [ "${pct:-0}" -ge "$DISK_ALARM_PCT" ]; then status="red"
    elif [ "${pct:-0}" -ge "$DISK_WARN_PCT"  ]; then status="yellow"
    fi
    printf '{"pct": %s, "status": "%s"}' "$pct" "$status"
}

# Called once per monitored container each loop iteration. `_fcount` and
# `_hstring` are bash namerefs (`local -n`) bound to the caller's own
# F_PROXY/F_DNS_STD/F_DNS_SSL and H_PROXY/H_DNS_STD/H_DNS_SSL variables, so
# this function can update each container's failure counter and last-known
# health string in place without returning multiple values or relying on
# globals named after a specific container.
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

# Writes the status JSON consumed by the Admin UI dashboard. Built with
# plain string interpolation rather than a JSON library or `jq` (this image
# doesn't ship jq for writing, only `curl`/`jq` for reading Docker's health
# API above) — every value going into the template is either a fixed enum
# (health_color's output), an integer counter, or a container name we
# ourselves defaulted, so there's no untrusted/arbitrary string that could
# break the JSON structure. Written to a .tmp file and renamed into place so
# a concurrent reader never sees a half-written file.
write_status() {
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local disk_cache; disk_cache=$(disk_info "$CACHE_DIR")

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
    "cache": ${disk_cache}
  }
}
EOF
    mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

maybe_purge() {
    local now; now=$(date +%s)
    local last=0

    # Purging is rate-limited by a stamp file so a restarted watchdog does not
    # repeatedly scan a large cache tree on every boot loop.
    # Validate and read purge stamp
    if [ -f "$PURGE_STAMP" ]; then
        last=$(cat "$PURGE_STAMP")
        case "$last" in
            ''|*[!0-9]*)
                log "Invalid PURGE_STAMP=${last}; forcing purge timestamp reset"
                last=0
                ;;
        esac
    fi

    # Force decimal parsing so digit-only corrupt stamps like "08" are not
    # interpreted as invalid octal values by Bash arithmetic under set -e.
    local last_epoch=$((10#$last))
    if [ "$last_epoch" -gt "$now" ]; then
        log "PURGE_STAMP=${last} is in the future; forcing purge timestamp reset"
        last_epoch=0
    fi
    [ $(( now - last_epoch )) -lt 86400 ] && return

    # Validate cache valid days setting
    case "$CACHE_VALID_DAYS" in
        ''|*[!0-9]*)
            log "Invalid CACHE_VALID_DAYS=${CACHE_VALID_DAYS}; skipping purge"
            return
            ;;
    esac

    log "Daily purge: removing cache files older than ${CACHE_VALID_DAYS} days"
    if [ -d "$CACHE_DIR" ]; then
        local count=0
        while IFS= read -r -d '' file; do
            if [ -f "$file" ] && rm -- "$file"; then
                count=$(( count + 1 ))
            fi
        done < <(find "$CACHE_DIR" -type f -mtime "+${CACHE_VALID_DAYS}" -print0 2>/dev/null)
        log "Purged $count files from $CACHE_DIR"
    fi
    mkdir -p "$(dirname "$PURGE_STAMP")"
    echo "$now" > "$PURGE_STAMP"
}

# Storage-budget retention engine for syslog-ng's rotated/compressed output
# (#633). Modeled directly on maybe_purge() above: rate-limited via its own
# stamp file, untrusted numeric input clamped to a safe default via the same
# `case ''|*[!0-9]*)` idiom, every deletion explicitly logged.
#
# Ordering is deliberate and matches the issue's explicit requirement --
# SIZE BUDGET TAKES PRIORITY OVER RETENTION DAYS:
#   Pass 1 (age):  delete anything older than SYSLOG_RETENTION_DAYS first.
#                  This is a floor, not the primary control.
#   Pass 2 (size): re-measure what's left; if still over SYSLOG_MAX_GB,
#                  delete oldest-first (regardless of age) until under
#                  budget. This can and will delete files younger than the
#                  retention floor if the size budget demands it.
#
# syslog-ng writes to $SYSLOG_LOG_ROOT/$HOST/$YEAR$MONTH$DAY.log, rotates
# oversized active files to "$file.$timestamp", and compresses those to
# ".zst" (falling back to ".gz" if zstd is unavailable at rotation time) --
# see the `syslog-ng` service's rotation loop in deploy/*/docker-compose.yml.
# This function treats every regular file under $SYSLOG_LOG_ROOT the same
# regardless of extension (.log/.zst/.gz all count), since compression state
# has no bearing on age or disk usage eligibility.
maybe_prune_syslog() {
    if [ "$SYSLOG_ENABLED" != "true" ]; then
        return
    fi

    local now; now=$(date +%s)
    local last=0

    # Rate-limited the same way as maybe_purge(): a potentially large,
    # deep syslog-ng tree must not be rescanned every 30s watchdog cycle.
    if [ -f "$SYSLOG_PRUNE_STAMP" ]; then
        last=$(cat "$SYSLOG_PRUNE_STAMP")
        case "$last" in
            ''|*[!0-9]*)
                log "Invalid SYSLOG_PRUNE_STAMP=${last}; forcing syslog prune timestamp reset"
                last=0
                ;;
        esac
    fi

    local last_epoch=$((10#$last))
    if [ "$last_epoch" -gt "$now" ]; then
        log "SYSLOG_PRUNE_STAMP=${last} is in the future; forcing syslog prune timestamp reset"
        last_epoch=0
    fi
    [ $(( now - last_epoch )) -lt 86400 ] && return

    # Clamp untrusted numeric env input (same idiom as CACHE_VALID_DAYS in
    # maybe_purge above): unset/empty/non-digit values fall back to a safe
    # default instead of reaching `find -mtime`/shell arithmetic, which
    # would abort the whole watchdog loop under `set -e` on a malformed
    # value like "abc" or a negative number.
    local retention_days="${SYSLOG_RETENTION_DAYS:-30}"
    case "$retention_days" in
        ''|*[!0-9]*)
            log "Invalid SYSLOG_RETENTION_DAYS=${SYSLOG_RETENTION_DAYS:-}; using default 30"
            retention_days=30
            ;;
    esac

    local max_gb="${SYSLOG_MAX_GB:-10}"
    case "$max_gb" in
        ''|*[!0-9]*)
            log "Invalid SYSLOG_MAX_GB=${SYSLOG_MAX_GB:-}; using default 10"
            max_gb=10
            ;;
    esac

    local log_root="${SYSLOG_LOG_ROOT:-/var/log/lancache-syslog-ng}"

    if [ ! -d "$log_root" ]; then
        log "SYSLOG_LOG_ROOT=${log_root} does not exist yet; skipping syslog prune"
        return
    fi

    log "Syslog prune: retention=${retention_days}d budget=${max_gb}GB root=${log_root}"

    # --- Pass 1: age-based deletion (retention-days floor) -----------------
    local age_scan; age_scan="$(mktemp)"
    local age_err; age_err="$(mktemp)"
    if ! find "$log_root" -type f -mtime "+${retention_days}" -print0 > "$age_scan" 2>"$age_err"; then
        # A non-fatal `return` here (not `return 1`) is deliberate: the whole
        # script runs under `set -euo pipefail`, and this function is called
        # as a bare statement from the main loop, so a nonzero return would
        # kill the watchdog daemon entirely on a transient find failure (e.g.
        # a file vanishing mid-scan because syslog-ng's own rotation loop
        # renamed/compressed it concurrently -- a real, expected race, not an
        # exotic one). "Fail loud" means log the error and skip this cycle's
        # prune, not take the health monitor down with it. The stamp file is
        # intentionally NOT updated on this path, so the next cycle retries
        # rather than silently going dark for a full day.
        log "ERROR: find failed while scanning $log_root for age-based syslog pruning: $(cat "$age_err")"
        rm -f "$age_scan" "$age_err"
        return
    fi
    rm -f "$age_err"

    local age_count=0
    while IFS= read -r -d '' file; do
        if [ -f "$file" ] && rm -- "$file"; then
            age_count=$(( age_count + 1 ))
            log "Pruned syslog file (age > ${retention_days}d): $file"
        fi
    done < "$age_scan"
    rm -f "$age_scan"
    log "Age-based syslog prune: removed $age_count file(s) older than ${retention_days}d from $log_root"

    # --- Pass 2: size-budget deletion, oldest-first -------------------------
    # Re-measure after Pass 1 deleted whatever it deleted; du/find failures
    # here must never be swallowed -- a silent size-measurement failure would
    # mean the budget is never enforced again until the next daily run.
    local du_output
    if ! du_output=$(du -sb "$log_root" 2>&1); then
        # See the age-pass ERROR branch above for why this is a bare `return`
        # (not `return 1`) under `set -e` -- same reasoning applies here.
        log "ERROR: du failed while measuring $log_root size for syslog retention: $du_output"
        return
    fi
    local size_bytes; size_bytes=$(awk '{print $1}' <<< "$du_output")
    local budget_bytes=$(( max_gb * 1024 * 1024 * 1024 ))

    if [ "$size_bytes" -le "$budget_bytes" ]; then
        log "Syslog size within budget: ${size_bytes} bytes <= ${budget_bytes} bytes (${max_gb}GB); no size-based pruning needed"
        mkdir -p "$(dirname "$SYSLOG_PRUNE_STAMP")"
        echo "$now" > "$SYSLOG_PRUNE_STAMP"
        return
    fi

    log "Syslog size budget exceeded: ${size_bytes} bytes > ${budget_bytes} bytes (${max_gb}GB); pruning oldest files first regardless of age"

    # Tab-separated mtime/path pairs: %T@ is a float epoch, so `sort -n`
    # orders oldest-first on the leading numeric field. This assumes
    # filenames under $log_root (syslog-ng's own $HOST/$DATE[.ts][.zst|.gz]
    # naming) never contain a literal tab -- true for every name syslog-ng's
    # rotation loop generates.
    local size_scan; size_scan="$(mktemp)"
    local size_err; size_err="$(mktemp)"
    if ! find "$log_root" -type f -printf '%T@\t%p\n' > "$size_scan" 2>"$size_err"; then
        # Same non-fatal-`return`-under-`set -e` reasoning as the two ERROR
        # branches above.
        log "ERROR: find failed while listing $log_root for size-based syslog pruning: $(cat "$size_err")"
        rm -f "$size_scan" "$size_err"
        return
    fi
    rm -f "$size_err"

    local size_sorted; size_sorted="$(mktemp)"
    sort -n "$size_scan" > "$size_sorted"
    rm -f "$size_scan"

    local size_count=0
    while IFS=$'\t' read -r _mtime file; do
        [ "$size_bytes" -le "$budget_bytes" ] && break
        [ -f "$file" ] || continue
        local fsize
        fsize=$(stat -c '%s' "$file" 2>/dev/null || echo 0)
        if rm -- "$file"; then
            size_bytes=$(( size_bytes - fsize ))
            size_count=$(( size_count + 1 ))
            log "Pruned syslog file (size budget, oldest-first): $file"
        fi
    done < "$size_sorted"
    rm -f "$size_sorted"
    log "Size-based syslog prune: removed $size_count file(s), size now ${size_bytes} bytes (budget ${budget_bytes} bytes)"

    mkdir -p "$(dirname "$SYSLOG_PRUNE_STAMP")"
    echo "$now" > "$SYSLOG_PRUNE_STAMP"
}
log "Watchdog started. Monitoring: $C_PROXY $C_DNS_STD $C_DNS_SSL (SSL_ENABLED=$SSL_ENABLED)"
log "Cache directory: $CACHE_DIR"
log "Interval: ${CHECK_INTERVAL}s | Restart after: ${RESTART_AFTER} | Disk warn: ${DISK_WARN_PCT}% alarm: ${DISK_ALARM_PCT}%"

while true; do
    check_and_maybe_restart "$C_PROXY" F_PROXY H_PROXY
    check_and_maybe_restart "$C_DNS_STD"   F_DNS_STD   H_DNS_STD
    if [ "$SSL_ENABLED" = "1" ]; then
        check_and_maybe_restart "$C_DNS_SSL"   F_DNS_SSL   H_DNS_SSL
    fi
    write_status
    maybe_purge
    maybe_prune_syslog
    sleep "$CHECK_INTERVAL"
done
