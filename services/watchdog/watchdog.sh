#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Health monitor and auto-restart-on-failure daemon.
#
# File-retention responsibilities (cache-age purge, syslog-ng storage-budget
# pruning, fluent-bit self-log rotation) live in the standalone
# services/watchdog/retention.sh process. This file retains CACHE_DIR only for
# disk_info()'s independent status.json disk-usage reporting. LOGGING_ENABLED
# remains here because it is a runtime-presence gate, not a retention setting:
# it decides whether the combined syslog+fluent-bit container exists and should
# be monitored alert-only. SYSLOG_ENABLED is intentionally narrower and belongs
# to the retention/pruning engine. DHCP_MODE is carried through Compose for the
# Rust implementation's alert-only target resolution, while the live Bash path
# uses LOGGING_ENABLED for syslog presence.

set -euo pipefail

DOCKER_PROXY_URL="${DOCKER_PROXY_URL:-http://docker-socket-proxy:2375}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
RESTART_AFTER="${RESTART_AFTER:-3}"
DISK_WARN_PCT="${DISK_WARN_PCT:-85}"
DISK_ALARM_PCT="${DISK_ALARM_PCT:-95}"
STATUS_FILE="${STATUS_FILE:-/var/run/watchdog/status.json}"

F_PROXY=0; F_DNS_STD=0; F_DNS_SSL=0; F_NATS=0; F_DOCKER_PROXY=0; F_SYSLOG=0; F_NTP=0
H_PROXY="unknown"; H_DNS_STD="unknown"; H_DNS_SSL="unknown"; H_NATS="unknown"; H_DOCKER_PROXY="unknown"; H_SYSLOG="unknown"; H_NTP="unknown"

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
# load-bearing facts are: (1) scripts/tracked/docker-socket-proxy.sh's allowlist
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

# ntp (issue #1296): the first of issue #842's originally-proposed five
# alert-only services (ui, dhcp, dhcp-proxy, netdata, syslog) to actually
# ship in THIS live bash entrypoint -- the other five exist only in
# services/watchdog/src/ (the Rust rewrite scaffold), which is not yet
# this container's real ENTRYPOINT (see services/watchdog/Dockerfile and
# src/lib.rs's own module doc comment), so adding ntp only to that crate
# would have had zero real effect on the Admin UI dashboard an operator
# actually sees. Gated by NTP_ENABLED (same env var and default ("0"/off)
# `setup.sh` already uses to gate the `ntp` Compose profile itself,
# `append_env_key_if_missing NTP_ENABLED "0"`) -- an install that never
# enabled `ntp` has no `lancache-ntp` container at all, and monitoring it
# anyway would produce a permanent false "unreachable" alert for a
# container that was never supposed to exist. Alert-only like
# docker-socket-proxy below, not restart-capable like the four services
# above: a genuinely crashed `ntp` is worth a dashboard alert, but this
# script's restart-capable set is reserved for services whose restart is
# an already-reviewed, safe recovery action -- see check_alert_only()'s own
# comment for the shared alert-only pattern this reuses.
# Resolves one alert-only monitoring target's container name into <out_var>,
# honoring the truthy gate in <enabled_var> and the coordinated
# LANCACHE_CONTAINER_SUFFIX, or sets <out_var> to empty when the gate is
# false. <override_var>, if given and non-empty, overrides <base_name> --
# only C_NTP's caller passes one (CONTAINER_NTP); C_SYSLOG's caller
# intentionally omits it, matching services/watchdog/src/config.rs's fixed
# CONTAINER_SYSLOG constant (no separate env var for
# scripts/untracked/check-naming-consistency.sh to validate -- see C_SYSLOG's own call
# site below for that contract's full rationale). Shared so the
# gate-check-then-suffix-append mechanics themselves cannot silently diverge
# between callers or a future third one, even though the override policy
# each caller chooses stays caller-controlled (Rule-Ref: AG-CODE-011).
_watchdog_resolve_alert_target() {
    local enabled_var="$1" out_var="$2" base_name="$3" override_var="${4:-}"
    local name="$base_name"
    if [ -n "$override_var" ]; then
        local override_value="${!override_var:-}"
        [ -n "$override_value" ] && name="$override_value"
    fi
    if is_truthy "${!enabled_var:-0}"; then
        printf -v "$out_var" '%s%s' "$name" "${LANCACHE_CONTAINER_SUFFIX:-}"
    else
        printf -v "$out_var" ''
    fi
}

_watchdog_resolve_alert_target NTP_ENABLED C_NTP lancache-ntp CONTAINER_NTP

# docker-socket-proxy (issue #1170 Part 1): a fixed literal, not a
# ${CONTAINER_*:-...}-style override like the four names above. Those four
# are validated against scripts/tracked/docker-socket-proxy.sh's allowlist below
# because get_health()/restart_container() build a real
# /containers/<name>/... Docker-API URL out of them. This constant is never
# used that way -- probe_docker_socket_proxy() (below) hits
# DOCKER_PROXY_URL's own /_ping endpoint directly, with no container-name
# path segment at all -- so it is deliberately NOT wired through a
# CONTAINER_* env var, and scripts/untracked/check-naming-consistency.sh's watchdog_names
# extraction (which greps for exactly that ${CONTAINER_*:-lancache-*} shape)
# correctly never sees it. Per docs/naming-conventions.md's "Operator-visible
# consistency" section, docker-socket-proxy has a real container_name but is
# intentionally NOT an allowlist target; adding this constant to that
# allowlist would be wrong, not merely unnecessary. It exists purely as the
# stable status.json/dashboard key and log label for this probe.
C_DOCKER_PROXY="lancache-docker-socket-proxy"

# syslog uses the same fixed-name contract as the Rust implementation:
# services/watchdog/src/config.rs exposes CONTAINER_SYSLOG as a plain constant,
# not an environment override, so there is no separate CONTAINER_SYSLOG value
# for scripts/untracked/check-naming-consistency.sh to validate. The coordinated suffix
# still applies because the real Compose container name and Docker-proxy
# allowlist both use it. LOGGING_ENABLED, not SYSLOG_ENABLED, gates presence:
# an install without the logging profile has no syslog container to monitor,
# while SYSLOG_ENABLED controls only the separate storage-budget retention
# engine and can legitimately remain false while central logging is active.
_watchdog_resolve_alert_target LOGGING_ENABLED C_SYSLOG lancache-syslog

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
    log_err "FATAL: CONTAINER_PROXY=${C_PROXY} is not supported (expected '${EXPECTED_PROXY}'). Running more than one lancache-ng stack per host is a deliberate non-goal (#849 finding #5), not an unfinished feature -- scripts/tracked/docker-socket-proxy.sh's allowlist, the Admin UI, and this script all hardcode the fixed container name 'lancache-proxy' (plus this run's own LANCACHE_CONTAINER_SUFFIX, if any) for exactly that reason. Revert CONTAINER_PROXY to the default; if you have a genuine need for multiple stacks on one host, open a feature request describing it in detail rather than renaming this container."
    exit 1
fi
if [ "$C_DNS_STD" != "$EXPECTED_DNS_STD" ]; then
    log_err "FATAL: CONTAINER_DNS_STANDARD=${C_DNS_STD} is not supported (expected '${EXPECTED_DNS_STD}'). Running more than one lancache-ng stack per host is a deliberate non-goal (#849 finding #5), not an unfinished feature -- scripts/tracked/docker-socket-proxy.sh's allowlist, the Admin UI, and this script all hardcode the fixed container name 'lancache-dns-standard' (plus this run's own LANCACHE_CONTAINER_SUFFIX, if any) for exactly that reason. Revert CONTAINER_DNS_STANDARD to the default; if you have a genuine need for multiple stacks on one host, open a feature request describing it in detail rather than renaming this container."
    exit 1
fi
if [ "$SSL_ENABLED" = "1" ] && [ "$C_DNS_SSL" != "$EXPECTED_DNS_SSL" ]; then
    log_err "FATAL: CONTAINER_DNS_SSL=${C_DNS_SSL} is not supported (expected '${EXPECTED_DNS_SSL}'). Running more than one lancache-ng stack per host is a deliberate non-goal (#849 finding #5), not an unfinished feature -- scripts/tracked/docker-socket-proxy.sh's allowlist, the Admin UI, and this script all hardcode the fixed container name 'lancache-dns-ssl' (plus this run's own LANCACHE_CONTAINER_SUFFIX, if any) for exactly that reason. Revert CONTAINER_DNS_SSL to the default; if you have a genuine need for multiple stacks on one host, open a feature request describing it in detail rather than renaming this container."
    exit 1
fi
if [ "$C_NATS" != "$EXPECTED_NATS" ]; then
    log_err "FATAL: CONTAINER_NATS=${C_NATS} is not supported (expected '${EXPECTED_NATS}'). Running more than one lancache-ng stack per host is a deliberate non-goal (#849 finding #5), not an unfinished feature -- scripts/tracked/docker-socket-proxy.sh's allowlist, the Admin UI, and this script all hardcode the fixed container name 'lancache-nats' (plus this run's own LANCACHE_CONTAINER_SUFFIX, if any) for exactly that reason. Revert CONTAINER_NATS to the default; if you have a genuine need for multiple stacks on one host, open a feature request describing it in detail rather than renaming this container."
    exit 1
fi

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
    local status
    status=$(jq -r '.State.Health.Status // "none"' 2>/dev/null <<< "$body") \
        || { echo "unreachable"; return; }
    # Issue #1296: a container that Docker itself reports "healthy" can
    # still tell watchdog, through its own healthcheck's captured output,
    # that it is intentionally operating with reduced guarantees -- a
    # `DEGRADED: <reason>` line anywhere in the MOST RECENT
    # `.State.Health.Log` entry (already part of this exact response body;
    # no second request). First real user: `ntp`'s CAP_SYS_TIME graceful
    # degradation (a nested/LXC host denying real clock-stepping capability
    # makes chronyd start in `-x` mode instead of crash-looping -- see
    # services/ntp/entrypoint.sh and deploy/*/docker-compose.yml's `ntp`
    # healthcheck). Reports the synthetic string "degraded" here, the same
    # way probe_docker_socket_proxy() below already writes synthetic
    # "healthy"/"unhealthy" strings not lifted directly from a real
    # `.State.Health.Status` value. Only checked when Status is genuinely
    # "healthy": a stale marker in an old log entry must never override a
    # real unhealthy/starting reading.
    #
    # Deliberately `split("\n") | ... | startswith(...)`, NOT a `test("^...";
    # "m")` regex: confirmed live that jq's regex engine (Oniguruma) does
    # NOT make `^` match after an embedded newline under the "m" flag the
    # way PCRE-style multi-line mode would (Oniguruma's "m" flag instead
    # means "dot matches newline", a different axis entirely) -- a
    # `test("^DEGRADED: "; "m")` against a real multi-line Output string
    # reproducibly returned `false` even with a literal "DEGRADED: " line
    # present. Splitting into lines and checking each one's prefix directly
    # has no such ambiguity.
    if [ "$status" = "healthy" ] && jq -e '
            ((.State.Health.Log // [])[-1].Output // "")
            | split("\n")
            | any(startswith("DEGRADED: "))
        ' >/dev/null 2>&1 <<< "$body"; then
        echo "degraded"
        return
    fi
    echo "$status"
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
# GET /_ping is already permitted by scripts/tracked/docker-socket-proxy.sh's
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
    # Dashboard cards consume these stable color names directly. "degraded"
    # (issue #1296) deliberately gets its OWN color ("amber"), not "yellow":
    # yellow means "unknown/transitional" (the default `*` case below,
    # matching services/watchdog/src/health.rs's identical Rust-side
    # reasoning for HealthReading::color() -- keep both in sync), whereas
    # degraded is a known, deliberate, stable state that must not look like
    # "wait and see."
    case "$1" in
        healthy)   echo "green" ;;
        degraded)  echo "amber" ;;
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

# Alert-only counterpart to check_and_maybe_restart() above (issue #1296):
# updates the failure counter and last-known health string for dashboard
# visibility, but never calls restart_container(). First real user: `ntp`
# (see C_NTP's own comment for why restart-capable monitoring is not the
# right fit for it). "healthy"/"starting"/"none"/"degraded" are all
# "not currently a problem" -- matching
# services/watchdog/src/health.rs's HealthReading::is_alert_ok() exactly
# (keep both in sync) -- everything else (unhealthy, unreachable, or any
# unrecognized string) increments the counter and logs an alert. Unlike
# check_and_maybe_restart(), there is no RESTART_AFTER threshold to reach:
# this counter climbs for as long as the condition persists, which is
# itself useful operator-visible information (matching
# probe_docker_socket_proxy()'s own AlertCounter-style semantics), not a
# bug to cap.
check_alert_only() {
    local name="$1"
    local -n _fcount="$2"
    local -n _hstring="$3"

    local health
    health=$(get_health "$name")
    _hstring="$health"

    case "$health" in
        healthy|starting|none|degraded)
            [ "$_fcount" -gt 0 ] && log "RECOVERED $name"
            _fcount=0
            ;;
        *)
            _fcount=$((_fcount + 1))
            log "UNHEALTHY $name (${_fcount} consecutive failures) -- alert only, never auto-restarted"
            ;;
    esac
}

# Builds one comma-prefixed status.json service entry
# (`,\n    "<name>":   {"status": ..., "health": ..., "failures": ...}`) for
# write_status()'s optional services below (SSL DNS, syslog, ntp). The
# always-present services in write_status()'s own heredoc are not built
# through this helper: the first entry in a JSON object has no leading
# comma, a genuinely different shape from every optional entry after it, not
# merely a cosmetic difference this helper could also absorb. Pulled out so
# a fix to this JSON fragment's shape (key names, quoting, spacing) reaches
# every optional service at once instead of needing to be manually kept in
# sync across copies (Rule-Ref: AG-CODE-011).
_watchdog_status_json_fragment() {
    local container="$1" health="$2" failures="$3"
    printf ',\n    "%s":   {"status": "%s",   "health": "%s",   "failures": %s}' \
        "$container" "$(health_color "$health")" "$health" "$failures"
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
        ssl_services=$(_watchdog_status_json_fragment "$C_DNS_SSL" "$H_DNS_SSL" "$F_DNS_SSL")
    fi

    # Omitting the key entirely when C_SYSLOG/C_NTP is empty prevents a
    # deployment without central logging/ntp from showing a permanently
    # unhealthy service that never existed.
    local syslog_service=""
    if [ -n "$C_SYSLOG" ]; then
        syslog_service=$(_watchdog_status_json_fragment "$C_SYSLOG" "$H_SYSLOG" "$F_SYSLOG")
    fi

    local ntp_service=""
    if [ -n "$C_NTP" ]; then
        ntp_service=$(_watchdog_status_json_fragment "$C_NTP" "$H_NTP" "$F_NTP")
    fi

    cat > "${STATUS_FILE}.tmp" <<EOF
{
  "updated": "$ts",
  "services": {
    "$C_PROXY": {"status": "$(health_color "$H_PROXY")", "health": "$H_PROXY", "failures": $F_PROXY},
  "$C_DNS_STD":   {"status": "$(health_color "$H_DNS_STD")",   "health": "$H_DNS_STD",   "failures": $F_DNS_STD},
  "$C_NATS":   {"status": "$(health_color "$H_NATS")",   "health": "$H_NATS",   "failures": $F_NATS},
  "$C_DOCKER_PROXY": {"status": "$(health_color "$H_DOCKER_PROXY")", "health": "$H_DOCKER_PROXY", "failures": $F_DOCKER_PROXY}${ssl_services}${syslog_service}${ntp_service}
  },
  "disk": {
    "cache": ${disk_cache}
  }
}
EOF
    mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

log "Watchdog started. Monitoring: $C_PROXY $C_DNS_STD $C_DNS_SSL $C_NATS (SSL_ENABLED=$SSL_ENABLED); alert-only probe: $C_DOCKER_PROXY; alert-only monitored: ${C_SYSLOG:-none}${C_NTP:+ $C_NTP}"
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
    # Syslog is alert-only because making it restart-capable would require a
    # separate Docker-proxy allowlist widening. Skip the check entirely when
    # LOGGING_ENABLED says the container is not part of this deployment.
    if [ -n "$C_SYSLOG" ]; then
        check_alert_only "$C_SYSLOG" F_SYSLOG H_SYSLOG
    fi
    if [ -n "$C_NTP" ]; then
        check_alert_only "$C_NTP" F_NTP H_NTP
    fi
    write_status
    sleep "$CHECK_INTERVAL"
done
