#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Health monitor and auto-restart-on-failure daemon.
#
# File-retention responsibilities (cache-age purge, syslog-ng storage-budget
# pruning, fluent-bit self-log rotation) moved out of this file into the
# standalone services/watchdog/retention.sh (#842, 2026-08-01), run as a
# genuinely separate OS process by the compose `command:` override -- see
# that file's header for the full blast-radius-separation rationale. This
# file no longer reads CACHE_VALID_DAYS/SYSLOG_*/FLUENT_BIT_SELFLOG_* at all;
# CACHE_DIR is one exception, still read here for disk_info()'s unrelated
# disk-usage-percentage reporting into status.json, resolved independently of
# retention.sh's own copy (see that file's resolve_cache_dir() comment for
# why this is deliberate duplication, not shared state). SYSLOG_ENABLED is
# the other exception (#849 bug-hunt finding observability.md#8, 2026-08-06):
# this file DOES now read it, gating alert-only health monitoring of the
# combined syslog+fluent-bit container -- see check_alert_only()'s own
# comment below for why that container is alert-only rather than
# restart-capable, and why SYSLOG_ENABLED/DHCP_MODE were already present in
# every deploy/*/docker-compose.yml's `watchdog:` environment block (added
# ahead of this change for the not-yet-wired-up Rust rewrite -- see
# services/watchdog/src/lib.rs's module doc comment).

set -euo pipefail

DOCKER_PROXY_URL="${DOCKER_PROXY_URL:-http://docker-socket-proxy:2375}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
RESTART_AFTER="${RESTART_AFTER:-3}"
DISK_WARN_PCT="${DISK_WARN_PCT:-85}"
DISK_ALARM_PCT="${DISK_ALARM_PCT:-95}"
STATUS_FILE="${STATUS_FILE:-/var/run/watchdog/status.json}"

F_PROXY=0; F_DNS_STD=0; F_DNS_SSL=0; F_NATS=0; F_DOCKER_PROXY=0; F_SYSLOG=0
H_PROXY="unknown"; H_DNS_STD="unknown"; H_DNS_SSL="unknown"; H_NATS="unknown"; H_DOCKER_PROXY="unknown"; H_SYSLOG="unknown"

log() { echo "[watchdog] $(date -u +%H:%M:%S) $*"; }
# Some diagnostics (resolve_cache_dir()'s fail-closed error, the CONTAINER_*
# mismatch checks below) fire from inside `$(...)` command substitution or
# before the main loop even starts; log()'s plain stdout `echo` would be
# silently captured and discarded in the first case, and either way an
# operator needs these visible regardless of how `docker logs` is piped.
log_err() { echo "[watchdog] $(date -u +%H:%M:%S) $*" >&2; }

# CHECK_INTERVAL gets the same digit-only guard the other numeric knobs
# (CACHE_VALID_DAYS, SYSLOG_RETENTION_DAYS, SYSLOG_MAX_GB) already have --
# unvalidated, a bad value reaches `sleep "$CHECK_INTERVAL"` under `set -e`
# and crashes the whole daemon (crash-loop risk). A literal 0 is additionally
# floored to 1: it would make `sleep` a no-op, turning the main loop into a
# busy-loop hammering docker-socket-proxy every iteration -- never a sane
# operator intent, so it gets the same treatment as an invalid value.
case "$CHECK_INTERVAL" in
    ''|*[!0-9]*)
        log "Invalid CHECK_INTERVAL=${CHECK_INTERVAL}; using default 30"
        CHECK_INTERVAL=30
        ;;
esac
if [ "$CHECK_INTERVAL" -lt 1 ]; then
    log "CHECK_INTERVAL=${CHECK_INTERVAL} is below the supported minimum (1s); using 1"
    CHECK_INTERVAL=1
fi

# Canonical truthy-parsing contract shared with the Admin UI's env_bool()
# (services/ui/src/config.rs). Recognizes 1/true/yes/on as truthy,
# case-insensitively and after trimming surrounding whitespace, exactly like
# env_bool()'s `value.trim().to_ascii_lowercase()` match. Anything else
# (including 0/false/no/off, empty, or unrecognized garbage) is not-truthy;
# callers combine this with their own `${VAR:-default}` fallback for the
# "unset" case, same as env_bool()'s `unwrap_or(default)`.
is_truthy() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    v="${v,,}"
    case "$v" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# SSL_ENABLED used to require the exact literal "1", but the Admin UI's
# env_bool("SSL_ENABLED", true) already accepts true/yes/on
# (case-insensitive) -- SSL_ENABLED=true showed SSL mode as enabled in the
# Admin UI while watchdog silently left dns-ssl unmonitored. Normalizing
# once here to a canonical "1"/"0" keeps every later comparison in this file
# (`[ "$SSL_ENABLED" = "1" ]`) unchanged.
if is_truthy "${SSL_ENABLED:-1}"; then
    SSL_ENABLED=1
else
    SSL_ENABLED=0
fi

# docker-socket-proxy.sh's HAProxy allowlist hardcodes these exact container
# names, and every compose file's `container_name:` does too (the Admin
# UI's docker_client.rs hardcodes them a third time) -- nothing in the stack
# actually reads CONTAINER_PROXY/CONTAINER_DNS_STANDARD/CONTAINER_DNS_SSL to
# rename anything. Honoring a mismatched value here would only make health
# checks silently return "unreachable" and restarts silently 403 through the
# proxy, not actually support renaming end-to-end. Fail loudly at startup
# instead of pretending the knob works.
#
# This is a deliberate design boundary, not an unfinished feature (maintainer
# decision, #849 bug-hunt finding #5): running more than one lancache-ng
# stack on the same host is not a supported or intended deployment shape.
# These four fixed container names (matching the fixed `container_name:`
# values in every `deploy/*/docker-compose.yml`) are exactly what makes a
# single-stack-per-host install unambiguous and predictable for
# docker-socket-proxy's allowlist, the Admin UI, and this script alike --
# renaming any of them to run a second, co-located stack would need all
# three of those layers to support a configurable name simultaneously, a
# real project-wide multi-stack architecture change, not a small env-var
# fix here. An operator who genuinely needs multiple lancache-ng stacks on
# one host (e.g. a real multi-tenant or staging-alongside-production case,
# not merely wanting different container names for cosmetic reasons) should
# open a feature request describing that concrete need in detail --
# reverting `CONTAINER_*` to the documented defaults is the correct
# workaround today, not renaming them.
C_PROXY="${CONTAINER_PROXY:-lancache-proxy}"
C_DNS_STD="${CONTAINER_DNS_STANDARD:-lancache-dns-standard}"
if [ "$SSL_ENABLED" = "1" ]; then
    C_DNS_SSL="${CONTAINER_DNS_SSL:-lancache-dns-ssl}"
else
    C_DNS_SSL=""
fi
# nats (#842): unlike C_DNS_SSL above, nats is never profile/flag-gated --
# the compose service has no `profiles:` entry and runs in every deployment
# mode, so it is always monitored, the same way C_PROXY/C_DNS_STD are.
#
# Why nats specifically, and not the other five services #842 raised
# (ui, dhcp, dhcp-proxy, netdata, syslog/syslog-ng), is documented in that
# issue's closing PR body rather than repeated in full here, but the two
# load-bearing facts are: (1) scripts/docker-socket-proxy.sh's allowlist
# already permits both inspecting AND restarting lancache-nats (added for
# the Admin UI's own config-apply restart, e.g.
# services/ui/src/routes/secondaries.rs::update_nats_conf) -- adding it here
# needs no allowlist change, unlike ui/dhcp, which the allowlist does not
# (yet) permit a restart for; (2) the Admin UI's auth-callout responder
# (services/ui/src/nats_auth_callout.rs::run_auth_callout) already runs
# inside an unconditional reconnect loop with capped exponential backoff
# (1s up to 30s) that treats "connection dropped, retry" as its normal
# steady state -- a watchdog-triggered nats restart is just another
# disconnect/reconnect cycle to that loop, not a novel failure mode it was
# never built to handle.
C_NATS="${CONTAINER_NATS:-lancache-nats}"

# docker-socket-proxy (issue #1170 Part 1): a fixed literal, not a
# ${CONTAINER_*:-...}-style override like the four names above. Those four
# are validated against scripts/docker-socket-proxy.sh's allowlist below
# because get_health()/restart_container() build a real
# /containers/<name>/... Docker-API URL out of them. This constant is never
# used that way -- probe_docker_socket_proxy() (below) hits
# DOCKER_PROXY_URL's own /_ping endpoint directly, with no container-name
# path segment at all -- so it is deliberately NOT wired through a
# CONTAINER_* env var, and scripts/check-naming-consistency.sh's watchdog_names
# extraction (which greps for exactly that ${CONTAINER_*:-lancache-*} shape)
# correctly never sees it. Per docs/naming-conventions.md's "Operator-visible
# consistency" section, docker-socket-proxy has a real container_name but is
# intentionally NOT an allowlist target; adding this constant to that
# allowlist would be wrong, not merely unnecessary. It exists purely as the
# stable status.json/dashboard key and log label for this probe.
C_DOCKER_PROXY="lancache-docker-socket-proxy"

# syslog (#849 bug-hunt finding observability.md#8, 2026-08-06): no
# ${CONTAINER_*:-...}-style override exists for it in the Rust rewrite this
# mirrors (services/watchdog/src/config.rs's CONTAINER_SYSLOG is a plain
# `const`, never read from an env var), so there is nothing for
# scripts/check-naming-consistency.sh's watchdog_names extraction to
# validate here either -- unlike C_PROXY/C_DNS_STD/etc. above, there is no
# separate FATAL-guarded CONTAINER_SYSLOG env var to compare against. It
# DOES still need LANCACHE_CONTAINER_SUFFIX appended, though: this
# container's own real name (see deploy/*/docker-compose.yml's
# `container_name: lancache-syslog${LANCACHE_CONTAINER_SUFFIX:-}`) and
# scripts/docker-socket-proxy.sh's own generated HAProxy allowlist (which
# rewrites its `lancache-syslog` ACL entry with this exact suffix at
# startup) both carry it -- referenced directly from the raw environment
# variable here since LANCACHE_CONTAINER_SUFFIX itself is not normalized
# until further below, and this assignment runs first. Gated on
# SYSLOG_ENABLED, matching resolve_alert_only_targets()'s own `if
# syslog_enabled { targets.push(...) }` gate exactly -- an install that
# never opted into `docker compose --profile logging` never starts this
# container at all, so monitoring it unconditionally would report a
# permanent false "unhealthy" for a container that was never supposed to
# exist.
if is_truthy "${SYSLOG_ENABLED:-false}"; then
    C_SYSLOG="lancache-syslog${LANCACHE_CONTAINER_SUFFIX:-}"
else
    C_SYSLOG=""
fi

# LANCACHE_CONTAINER_SUFFIX (issue #1415): the FATAL guards below no longer
# compare against the bare literal default -- they compare against this
# same suffix appended to it, so a CI run that gave every one of this
# project's containers a shared, coordinated suffix (see
# deploy/quickstart/docker-compose.yml's own CONTAINER_PROXY/etc.
# environment entries, which append the identical suffix) is recognized as
# the still-consistent, single-stack-per-host shape #849 finding #5
# requires -- NOT a relaxation of that finding's actual protection. Any
# value that is not exactly "the default plus this run's own suffix" still
# FATALs exactly as before: an operator setting CONTAINER_PROXY to an
# unrelated name gets the identical rejection, since LANCACHE_CONTAINER_SUFFIX
# is empty by default and this comparison is therefore byte-identical to the
# original bare-literal check for every real single-host install.
LANCACHE_CONTAINER_SUFFIX="${LANCACHE_CONTAINER_SUFFIX:-}"
EXPECTED_PROXY="lancache-proxy${LANCACHE_CONTAINER_SUFFIX}"
EXPECTED_DNS_STD="lancache-dns-standard${LANCACHE_CONTAINER_SUFFIX}"
EXPECTED_DNS_SSL="lancache-dns-ssl${LANCACHE_CONTAINER_SUFFIX}"
EXPECTED_NATS="lancache-nats${LANCACHE_CONTAINER_SUFFIX}"

if [ "$C_PROXY" != "$EXPECTED_PROXY" ]; then
    log_err "FATAL: CONTAINER_PROXY=${C_PROXY} is not supported (expected '${EXPECTED_PROXY}'). Running more than one lancache-ng stack per host is a deliberate non-goal (#849 finding #5), not an unfinished feature -- scripts/docker-socket-proxy.sh's allowlist, the Admin UI, and this script all hardcode the fixed container name 'lancache-proxy' (plus this run's own LANCACHE_CONTAINER_SUFFIX, if any) for exactly that reason. Revert CONTAINER_PROXY to the default; if you have a genuine need for multiple stacks on one host, open a feature request describing it in detail rather than renaming this container."
    exit 1
fi
if [ "$C_DNS_STD" != "$EXPECTED_DNS_STD" ]; then
    log_err "FATAL: CONTAINER_DNS_STANDARD=${C_DNS_STD} is not supported (expected '${EXPECTED_DNS_STD}'). Running more than one lancache-ng stack per host is a deliberate non-goal (#849 finding #5), not an unfinished feature -- scripts/docker-socket-proxy.sh's allowlist, the Admin UI, and this script all hardcode the fixed container name 'lancache-dns-standard' (plus this run's own LANCACHE_CONTAINER_SUFFIX, if any) for exactly that reason. Revert CONTAINER_DNS_STANDARD to the default; if you have a genuine need for multiple stacks on one host, open a feature request describing it in detail rather than renaming this container."
    exit 1
fi
if [ "$SSL_ENABLED" = "1" ] && [ "$C_DNS_SSL" != "$EXPECTED_DNS_SSL" ]; then
    log_err "FATAL: CONTAINER_DNS_SSL=${C_DNS_SSL} is not supported (expected '${EXPECTED_DNS_SSL}'). Running more than one lancache-ng stack per host is a deliberate non-goal (#849 finding #5), not an unfinished feature -- scripts/docker-socket-proxy.sh's allowlist, the Admin UI, and this script all hardcode the fixed container name 'lancache-dns-ssl' (plus this run's own LANCACHE_CONTAINER_SUFFIX, if any) for exactly that reason. Revert CONTAINER_DNS_SSL to the default; if you have a genuine need for multiple stacks on one host, open a feature request describing it in detail rather than renaming this container."
    exit 1
fi
if [ "$C_NATS" != "$EXPECTED_NATS" ]; then
    log_err "FATAL: CONTAINER_NATS=${C_NATS} is not supported (expected '${EXPECTED_NATS}'). Running more than one lancache-ng stack per host is a deliberate non-goal (#849 finding #5), not an unfinished feature -- scripts/docker-socket-proxy.sh's allowlist, the Admin UI, and this script all hardcode the fixed container name 'lancache-nats' (plus this run's own LANCACHE_CONTAINER_SUFFIX, if any) for exactly that reason. Revert CONTAINER_NATS to the default; if you have a genuine need for multiple stacks on one host, open a feature request describing it in detail rather than renaming this container."
    exit 1
fi

# Canonical truthy-parsing contract shared with the Admin UI's env_bool()
# (services/ui/src/config.rs). Recognizes 1/true/yes/on as truthy,
# case-insensitively and after trimming surrounding whitespace,
# exactly like env_bool()'s `value.trim().to_ascii_lowercase()` match.
# Anything else (including 0/false/no/off, empty, or unrecognized garbage)
# is treated as not-truthy; callers combine this with their own
# `${VAR:-default}` fallback for the "unset" case, same as env_bool()'s
# `unwrap_or(default)`. Only used for boolean-style env vars (currently
# SYSLOG_ENABLED); introduced as a single shared function specifically so a
# second flag can reuse it instead of re-implementing its own truthy check
# that could drift from this one the way SYSLOG_ENABLED's did.
is_truthy() {
    local v="$1"
    # Trim leading/trailing whitespace (mirrors Rust's `.trim()`).
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    v="${v,,}" # lowercase (mirrors Rust's `.to_ascii_lowercase()`)
    case "$v" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

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
        # log() writes to stdout, which the `CACHE_DIR="$(resolve_cache_dir)"`
        # command substitution below captures and discards -- this fail-closed
        # diagnostic must reach the operator, so it goes to stderr instead.
        log_err "ERROR: CACHE_DIR_STANDARD and CACHE_DIR_SSL point to different paths without CACHE_DIR. Set CACHE_DIR to one shared cache directory."
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

CURL_MAX_TIME="${CURL_MAX_TIME:-5}"
# restart_container()'s own timeout budget must exceed Docker's stop grace period
# (default 10s) plus the container's worst-case startup time (several seconds for
# cert generation in the proxy service). See #1166 for the race condition this
# fixes: without a generous budget, curl times out on a successful-but-slow restart.
# get_health() keeps CURL_MAX_TIME (5s) to catch a stalled docker-socket-proxy
# quickly without blocking the health-check loop.
CURL_MAX_TIME_RESTART="${CURL_MAX_TIME_RESTART:-30}"

get_health() {
    local name="$1" body
    # Docker socket access is routed through the narrowed proxy, so health reads
    # must stay on the allowed container-inspect endpoint rather than exec.
    # --max-time bounds a hung/unresponsive docker-socket-proxy: without it, a
    # stalled proxy stalls this single-threaded main loop indefinitely (no
    # further health checks, no restarts, no status.json refresh).
    #
    # curl's exit status is captured directly here rather than piping straight
    # into jq: a curl failure (connection refused, or exactly what --max-time
    # itself now produces on a real timeout) leaves curl's stdout completely
    # empty, and `jq -r '... // "none"'` exits 0 with no output on a fully
    # empty input -- not a parse error -- so a `curl | jq || echo unreachable`
    # pipeline would never reach the fallback and get_health() would silently
    # return an empty string instead of "unreachable". check_and_maybe_restart()
    # only recognizes the literal strings "healthy"/"unhealthy", so an empty
    # result would be silently ignored every cycle: no failure counter
    # increment, no restart, ever, for a container the proxy can't reach at
    # all -- exactly the scenario this fix's --max-time is meant to surface.
    body=$(curl -sf --max-time "$CURL_MAX_TIME" "${DOCKER_PROXY_URL}/containers/${name}/json" 2>/dev/null) \
        || { echo "unreachable"; return; }
    jq -r '.State.Health.Status // "none"' 2>/dev/null <<< "$body" \
        || echo "unreachable"
}

restart_container() {
    local name="$1"
    log "RESTARTING $name"
    # Restart is intentionally the only mutating Docker operation watchdog uses.
    # Container creation/exec remain unavailable through the proxy allowlist.
    # --max-time uses CURL_MAX_TIME_RESTART (30s default), not CURL_MAX_TIME (5s),
    # because restart includes both a stop phase (Docker's grace period, up to 10s
    # by default, controlled by t= below) plus a start phase (which can take several
    # seconds for cert generation). See #1166 for the race that prompted this.
    # t=2 tells Docker to wait 2 seconds for SIGTERM before sending SIGKILL, ensuring
    # the total operation completes well within the curl budget even for wedged
    # containers. The two timeouts are now coordinated instead of racing.
    curl -sf --max-time "$CURL_MAX_TIME_RESTART" -X POST "${DOCKER_PROXY_URL}/containers/${name}/restart?t=2" >/dev/null 2>&1 \
        || log "WARNING: restart call failed for $name"
}

# Issue #1170 Part 1: docker-socket-proxy is watchdog's own gateway to the
# Docker API (DOCKER_PROXY_URL, above) -- every get_health()/restart_container()
# call in this file goes through it. If it crashes outright, Docker's own
# `restart: always` already recovers it (docs/architecture-ng.md's
# docker-socket-proxy bullet). But if it only *hangs* (process alive, HAProxy
# not answering), nothing in the stack could previously detect that: this
# daemon's only restart channel goes THROUGH docker-socket-proxy, so "restart
# docker-socket-proxy via docker-socket-proxy" is circular by construction --
# it has no Docker healthcheck either, so even `docker inspect` can't see a
# hang. This function is deliberately alert-only: it is never passed to
# check_and_maybe_restart() and restart_container() is never called for it.
# Actually self-healing docker-socket-proxy (a supervisor inside its own
# container that kills its own PID 1 so `restart: always` recovers it) is a
# separate, harder change with open verification questions (reliable
# in-container hang detection, clean PID 1 shutdown) and is tracked
# separately as issue #1170 Part 2 -- not implemented here.
#
# GET /_ping is already permitted by scripts/docker-socket-proxy.sh's
# safe_ping ACL (the same allowlist entry get_health() and every other
# caller in this file already rely on), so this needs zero new privilege.
# Unlike get_health() (which parses a Docker /containers/.../json health
# JSON body), /_ping returns a bare "OK" string on success with no JSON body
# to fall back on -- curl -sf's exit status alone (a non-2xx HTTP response,
# or the connection/timeout failure --max-time itself produces) is
# sufficient. The "healthy"/"unhealthy" strings this writes into
# H_DOCKER_PROXY are a synthetic reachability result, not a real Docker
# `.State.Health.Status` value like every other H_* variable in this file --
# health_color() still maps them the same way (unhealthy -> red) because
# that is the correct dashboard color for "the management plane cannot
# currently reach its own Docker API gateway", but a future reader should
# not assume this came from a real container healthcheck.
probe_docker_socket_proxy() {
    local -n _fcount="$1"
    local -n _hstring="$2"

    if curl -sf --max-time "$CURL_MAX_TIME" "${DOCKER_PROXY_URL}/_ping" >/dev/null 2>&1; then
        _hstring="healthy"
        [ "$_fcount" -gt 0 ] && log "RECOVERED $C_DOCKER_PROXY"
        _fcount=0
    else
        _fcount=$((_fcount + 1))
        _hstring="unhealthy"
        # Unlike check_and_maybe_restart()'s services, this counter never resets
        # via a restart (there is none) -- it keeps climbing for as long as
        # docker-socket-proxy stays unreachable, which is itself useful
        # operator-visible information (how many consecutive ~CHECK_INTERVAL-second
        # cycles this has been down), not a bug to cap at RESTART_AFTER.
        log "UNHEALTHY $C_DOCKER_PROXY (${_fcount} consecutive failures) -- alert only, watchdog cannot restart its own Docker API channel (see issue #1170)"
    fi
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
    # capacity limit for the single shared cache path. -P forces POSIX output
    # format (one line per filesystem): without it, a long device name (common
    # for overlay/mapper devices) wraps onto its own line, and `awk 'NR==2'`
    # then reads the wrapped device-name line instead of the real data row,
    # leaving $5/pct empty.
    pct=$(df -P "$dir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}') || pct=0
    local status="green"
    if   [ "${pct:-0}" -ge "$DISK_ALARM_PCT" ]; then status="red"
    elif [ "${pct:-0}" -ge "$DISK_WARN_PCT"  ]; then status="yellow"
    fi
    # ${pct:-0}, not $pct: an empty pct (df failure, unexpected output shape)
    # must still produce valid JSON. Interpolating a raw empty "$pct" here
    # emitted `{"pct": , "status": ...}` -- syntactically invalid JSON that
    # corrupted the whole status.json for every reader (Admin UI dashboard).
    printf '{"pct": %s, "status": "%s"}' "${pct:-0}" "$status"
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

# Alert-only monitoring (#849 bug-hunt finding observability.md#8): unlike
# check_and_maybe_restart() above, this never calls restart_container().
# scripts/docker-socket-proxy.sh's safe_service_restart ACL (line 63) only
# permits a restart POST for lancache-proxy/lancache-dns-standard/
# lancache-dns-ssl/lancache-nats -- a restart attempt for any other
# container, including the syslog+fluent-bit container this monitors, would
# get an HTTP 403 from HAProxy, so restart-capable monitoring is not even
# implementable here without a separate, deliberate allowlist-widening
# decision (a real security-boundary change, out of scope for a bug-hunt
# fix). This also mirrors the already-decided design in the not-yet-wired-up
# Rust rewrite (services/watchdog/src/main.rs's resolve_alert_only_targets(),
# services/watchdog/src/health.rs's HealthReading::is_alert_ok, issue #842):
# alert-only visibility, not auto-restart, is the deliberate safe default for
# a newly-monitored service until a per-service restart decision is
# consciously made ("a mid-startup restart of a dependency can make a
# dependent service's own reconnect logic worse, not better"). `_fcount`
# climbs for as long as the container stays unhealthy/unreachable (same
# never-resets-via-restart shape as probe_docker_socket_proxy()'s own
# counter above) rather than resetting at RESTART_AFTER -- there is no
# restart here for that threshold to gate.
check_alert_only() {
    local name="$1"
    local -n _fcount="$2"
    local -n _hstring="$3"

    local health
    health=$(get_health "$name")
    _hstring="$health"

    # "unreachable" (get_health()'s own fallback for a curl failure or an
    # unparseable/empty response, see that function's header) is treated as
    # a failure here, not just "unhealthy": the container being gone,
    # unresponsive, or unreachable through docker-socket-proxy is exactly
    # the "enabled but not actually running/reachable" outage this
    # alert-only monitoring exists to surface -- silently ignoring it would
    # leave a stopped/crashed container with zero alerting for as long as
    # it stayed down. "starting" (Docker's own healthcheck grace period) and
    # "none" (no healthcheck configured/reported yet) stay non-failures, the
    # same as before, since both are normal transient states, not outages.
    if [ "$health" = "unhealthy" ] || [ "$health" = "unreachable" ]; then
        _fcount=$((_fcount + 1))
        log "UNHEALTHY $name (${_fcount} consecutive failures, health=${health}) -- alert only, watchdog does not restart this service (issue #842)"
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

    # #849 bug-hunt finding observability.md#8: same conditional-inclusion
    # shape as ssl_services above -- omitted entirely (not just "unknown")
    # when SYSLOG_ENABLED is falsy, so an install that never opted into
    # central logging doesn't show a permanently "unhealthy"/never-existed
    # container in the dashboard's service list.
    local syslog_service=""
    if [ -n "$C_SYSLOG" ]; then
        syslog_service=",
    \"$C_SYSLOG\":   {\"status\": \"$(health_color "$H_SYSLOG")\",   \"health\": \"$H_SYSLOG\",   \"failures\": $F_SYSLOG}"
    fi

    cat > "${STATUS_FILE}.tmp" <<EOF
{
  "updated": "$ts",
  "services": {
    "$C_PROXY": {"status": "$(health_color "$H_PROXY")", "health": "$H_PROXY", "failures": $F_PROXY},
  "$C_DNS_STD":   {"status": "$(health_color "$H_DNS_STD")",   "health": "$H_DNS_STD",   "failures": $F_DNS_STD},
  "$C_NATS":   {"status": "$(health_color "$H_NATS")",   "health": "$H_NATS",   "failures": $F_NATS},
  "$C_DOCKER_PROXY": {"status": "$(health_color "$H_DOCKER_PROXY")", "health": "$H_DOCKER_PROXY", "failures": $F_DOCKER_PROXY}${ssl_services}${syslog_service}
  },
  "disk": {
    "cache": ${disk_cache}
  }
}
EOF
    mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

log "Watchdog started. Monitoring: $C_PROXY $C_DNS_STD $C_DNS_SSL $C_NATS (SSL_ENABLED=$SSL_ENABLED); alert-only probe: $C_DOCKER_PROXY; alert-only monitored: ${C_SYSLOG:-none}"
log "Cache directory: $CACHE_DIR"
log "Interval: ${CHECK_INTERVAL}s | Restart after: ${RESTART_AFTER} | Disk warn: ${DISK_WARN_PCT}% alarm: ${DISK_ALARM_PCT}%"

while true; do
    check_and_maybe_restart "$C_PROXY" F_PROXY H_PROXY
    check_and_maybe_restart "$C_DNS_STD"   F_DNS_STD   H_DNS_STD
    if [ "$SSL_ENABLED" = "1" ]; then
        check_and_maybe_restart "$C_DNS_SSL"   F_DNS_SSL   H_DNS_SSL
    fi
    check_and_maybe_restart "$C_NATS" F_NATS H_NATS
    # Alert-only (issue #1170 Part 1): deliberately NOT check_and_maybe_restart --
    # see probe_docker_socket_proxy()'s own comment for why this daemon must
    # never attempt to restart its own Docker API gateway.
    probe_docker_socket_proxy F_DOCKER_PROXY H_DOCKER_PROXY
    # Alert-only (#849 bug-hunt finding observability.md#8): deliberately
    # check_alert_only, not check_and_maybe_restart -- see that function's
    # own comment for why restart-capable monitoring is not implementable
    # for this container without a separate allowlist-widening decision.
    # Skipped entirely (not called with an empty name) when SYSLOG_ENABLED
    # is falsy, matching every other SSL_ENABLED-style conditional monitor
    # above.
    if [ -n "$C_SYSLOG" ]; then
        check_alert_only "$C_SYSLOG" F_SYSLOG H_SYSLOG
    fi
    write_status
    sleep "$CHECK_INTERVAL"
done
