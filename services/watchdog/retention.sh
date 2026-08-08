#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Standalone file-retention daemon: cache-age purge, syslog-ng storage-budget
# retention, and fluent-bit self-log rotation (see #1236 for the last one).
#
# Deliberately extracted out of watchdog.sh into its own script AND its own
# OS process (maintainer decision, issue #842, 2026-08-01): blast-radius
# separation between destructive file-retention logic and the health-check/
# restart state machine. The two concerns share no data and have very
# different risk profiles -- this script's job is exclusively "decide which
# files under a handful of mounted paths are old/oversized and delete them,"
# watchdog.sh's job is exclusively "poll container health and restart/report
# it." A bug or future compromise in this script's find/rm paths must never
# be able to take down container health monitoring or the Admin UI's
# dashboard status feed, and vice versa. Running as a genuinely separate
# process (not just separate functions inside one shared bash process, which
# is how this code lived before this split) is what makes that true rather
# than aspirational: an uncaught fatal error here (a `set -e` exit from an
# edge case this file doesn't yet handle) kills only this process.
#
# Since #842 Teil 2 (2026-08-01), that process is also a genuinely separate
# CONTAINER (a dedicated `retention` compose service, see
# deploy/*/docker-compose.yml), not merely a separate process backgrounded
# inside watchdog's own container the way an earlier version of this split
# had it -- restart/respawn on crash comes from Compose's own `restart:
# always` on that service now, the same mechanism every other service in this
# project already relies on, rather than this image re-implementing process
# supervision itself. See retention-entrypoint.sh for that container's own
# entrypoint and its non-root/capability-scoped privilege drop.
#
# Deliberately does NOT source any code from watchdog.sh, not even the
# trivial log()/is_truthy() helpers duplicated below almost verbatim --
# sharing a library file would reintroduce exactly the coupling the process
# split above is meant to remove (a bug in a shared helper could affect both
# processes again, defeating the point). Keep both copies in sync by hand if
# their shared contracts (is_truthy()'s truthy-value set, CACHE_DIR
# resolution) ever change; watchdog.sh's own copies carry the same note.
set -euo pipefail

log() { echo "[retention] $(date -u +%H:%M:%S) $*"; }
# See watchdog.sh's log_err() for why this goes to stderr rather than
# log()'s plain stdout echo: fail-closed validation errors below run before
# any loop starts and must reach `docker logs`/the supervisor wrapper
# regardless of any stdout redirection.
log_err() { echo "[retention] $(date -u +%H:%M:%S) $*" >&2; }

# Canonical truthy-parsing contract shared with the Admin UI's env_bool()
# (services/ui/src/config.rs) and watchdog.sh's own identical copy -- see
# that file's is_truthy() for the full rationale (1/true/yes/on,
# case-insensitive, trimmed). Duplicated here rather than shared; see this
# file's header for why.
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

# Same split-cache-var resolution as watchdog.sh's resolve_cache_dir() --
# duplicated (not sourced, see file header) because this script needs the
# resolved cache path for its own purpose (the destructive age-based purge
# below), independent of watchdog.sh's own unrelated use of the same value
# (disk-usage percentage reporting into status.json). Both scripts reading
# the same env vars independently is not shared *state*, just an identical
# interpretation of the same input -- if this ever drifts from watchdog.sh's
# copy, the two processes would disagree on which directory is "the cache,"
# so keep them in lockstep by hand.
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

# --- Fail-closed path validation (#842 Teil 1 hardening) -------------------
#
# Real vulnerability this closes: before this function existed, none of
# CACHE_DIR/SYSLOG_LOG_ROOT/FLUENT_BIT_SELFLOG_DIR were validated at all
# before reaching a destructive `find ... -mtime ... | rm --`/size-budget
# pass. A misconfiguration or future Admin-UI-exposed setting of, say,
# CACHE_DIR=/ would make the daily purge walk and delete from the entire
# container root filesystem instead of just the cache volume -- demonstrated
# concretely (not just asserted) in this PR's body via a real before/after
# repro on a scratch container. Every one of this script's three entry
# points (maybe_purge, maybe_prune_syslog, maybe_rotate_fluent_bit_selflog)
# now validates its own target directory through this function at the top
# of every call, deliberately NOT cached into a once-at-startup variable:
# this mirrors how CACHE_DIR/SYSLOG_LOG_ROOT/FLUENT_BIT_SELFLOG_DIR were
# already read fresh on every call before this hardening pass (real
# production behavior this preserves on purpose: a volume that finishes
# mounting asynchronously after this process starts is picked up on the
# next cycle, exactly like the existing "does not exist yet" skip already
# relies on) -- caching the resolved path once would have silently broken
# that. The extra `realpath`/case-match cost is negligible next to this
# function's own `find`/`du` work, run at most once per RETENTION_INTERVAL.
#
# `realpath -m` canonicalizes the path: resolves symlinks in any existing
# ancestor component and collapses `.`/`..` segments, without requiring the
# full path to already exist (a not-yet-created FLUENT_BIT_SELFLOG_DIR mount
# is a normal state before the `logging` profile is ever used). Every
# comparison below operates on this canonical form, never on the raw,
# operator/env-controllable string -- a `../../etc`-style traversal attempt
# cannot survive past this point, because `realpath -m` has already resolved
# it into whatever real absolute path it actually names.
validate_retention_dir() {
    local var_name="$1" raw_value="$2" expected_prefix="$3"
    local resolved

    if [ -z "$raw_value" ]; then
        log_err "FATAL: ${var_name} is empty. Refusing to guess a retention target -- fail closed rather than operate on an unintended directory."
        return 1
    fi

    case "$raw_value" in
        /*) ;;
        *)
            log_err "FATAL: ${var_name}=${raw_value} is not an absolute path. A relative path's meaning depends on this process's current working directory, which is not a safe basis for a destructive retention pass -- refusing."
            return 1
            ;;
    esac

    resolved=$(realpath -m -- "$raw_value" 2>/dev/null) || {
        log_err "FATAL: ${var_name}=${raw_value} could not be canonicalized (realpath failed)."
        return 1
    }

    case "$resolved" in
        "$expected_prefix"/*)
            # A genuine subdirectory of the expected mount root -- accepted.
            ;;
        "$expected_prefix")
            log_err "FATAL: ${var_name} resolves to '${resolved}', which IS ${expected_prefix} itself, not a subdirectory under it. Refusing to run retention directly against a shared parent directory that other paths under the same prefix might also rely on."
            return 1
            ;;
        *)
            log_err "FATAL: ${var_name}=${raw_value} resolves to '${resolved}', which is outside the expected ${expected_prefix} mount tree. This looks like a path-traversal attempt or a serious misconfiguration -- refusing to run any find/rm against it."
            return 1
            ;;
    esac

    printf '%s\n' "$resolved"
}

# Expected mount-root prefixes for validate_retention_dir() below. Defaults
# match this project's real compose mounts (proxy-cache under /var/cache,
# the syslog-ng log tree under /var/log, the fluent-bit self-log volume
# under /var/lib -- see deploy/*/docker-compose.yml's `watchdog:` service).
# Deliberately overridable, not hardcoded literals: bats coverage points
# CACHE_DIR/SYSLOG_LOG_ROOT/FLUENT_BIT_SELFLOG_DIR at an isolated
# BATS_TEST_TMPDIR fixture per test (never a real /var path), and a
# legitimate non-default deployment (a test/dev simulation script, an
# unusual host layout) may need a different real root too. Overriding one of
# these three env vars is a deliberate, explicit, informed choice an
# operator/test makes -- categorically different from an unvalidated
# CACHE_DIR/SYSLOG_LOG_ROOT/FLUENT_BIT_SELFLOG_DIR value silently reaching
# `find`/`rm` with no check at all, which is the vulnerability this whole
# validation function exists to close.
CACHE_DIR_ALLOWED_PREFIX="${CACHE_DIR_ALLOWED_PREFIX:-/var/cache}"
SYSLOG_LOG_ROOT_ALLOWED_PREFIX="${SYSLOG_LOG_ROOT_ALLOWED_PREFIX:-/var/log}"
FLUENT_BIT_SELFLOG_DIR_ALLOWED_PREFIX="${FLUENT_BIT_SELFLOG_DIR_ALLOWED_PREFIX:-/var/lib}"

CACHE_VALID_DAYS="${CACHE_VALID_DAYS:-365}"
# /var/lib/lancache-retention-state (#842 Teil 2, 2026-08-01): moved off
# watchdog.sh's own /var/run/watchdog (shared with STATUS_FILE/status.json,
# read by the Admin UI) onto a dedicated volume once retention.sh became its
# own compose service/container -- these two stamp files are retention's own
# rate-limiting state, unrelated to health-check status, and sharing that
# volume stopped making sense once the two processes stopped sharing a
# container. See services/watchdog/Dockerfile and retention-entrypoint.sh for
# how this new path gets created/chowned for the non-root `lancache` user
# this script now runs as in production.
PURGE_STAMP="${PURGE_STAMP:-/var/lib/lancache-retention-state/purge.stamp}"

# See watchdog.sh's identical comment block on SYSLOG_ENABLED for the full
# fail-closed/truthy-parsing rationale; duplicated here since this is the
# process that actually acts on it.
SYSLOG_ENABLED="${SYSLOG_ENABLED:-false}"
SYSLOG_PRUNE_STAMP="${SYSLOG_PRUNE_STAMP:-/var/lib/lancache-retention-state/syslog-prune.stamp}"

CACHE_DIR="$(resolve_cache_dir)"

maybe_purge() {
    local now; now=$(date +%s)
    local last=0

    # Purging is rate-limited by a stamp file so a restarted retention
    # process does not repeatedly scan a large cache tree on every boot loop.
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

    case "$CACHE_VALID_DAYS" in
        ''|*[!0-9]*)
            log "Invalid CACHE_VALID_DAYS=${CACHE_VALID_DAYS}; skipping purge"
            return
            ;;
    esac

    # Fail-closed path validation, every call (see this file's validate_
    # retention_dir() comment for why per-call, not once at startup). A
    # rejection here is loud and non-fatal: this cycle's purge is skipped
    # (stamp left untouched so it retries next cycle), the same "return
    # before writing the stamp" shape as the missing-directory case below,
    # but the retention daemon itself keeps running.
    local cache_dir_resolved
    # `|| return 0`, not bare `|| return`: a bare `return` propagates the
    # exit status of validate_retention_dir() itself (1, since it failed) --
    # under this script's `set -euo pipefail`, the main loop calls
    # maybe_purge() as a plain statement, so ANY nonzero return here would
    # kill the whole retention daemon on every single rejected value,
    # instead of the intended "log loudly, skip this cycle, keep running
    # forever" behavior every other fail-closed branch in this file already
    # has (each of those ends with a successful `log(...)` call right
    # before its own bare `return`, which is why they return 0 without
    # needing to say so explicitly -- this one does not, since
    # validate_retention_dir() already did its own logging). Caught by
    # retention_path_validation.bats's "maybe_purge refuses to run..." test
    # failing during development -- exactly the kind of bug an isolated
    # unit test of validate_retention_dir() alone would not have caught.
    cache_dir_resolved="$(validate_retention_dir "CACHE_DIR" "$CACHE_DIR" "$CACHE_DIR_ALLOWED_PREFIX")" || return 0

    # Fail-closed on a missing CACHE_DIR: return BEFORE writing the stamp, so
    # the next cycle retries instead of the rate-limit stamp claiming a
    # purge ran when it was actually skipped entirely.
    if [ ! -d "$cache_dir_resolved" ]; then
        log "CACHE_DIR=${cache_dir_resolved} does not exist; skipping purge (stamp left untouched so this retries next cycle)"
        return
    fi

    log "Daily purge: removing cache files older than ${CACHE_VALID_DAYS} days"

    # mktemp scan+err files, not `find ... 2>/dev/null` piped straight into
    # the read loop: the old pattern silently swallowed real find errors
    # (permission denied, I/O error).
    #
    # -xdev (#842 Teil 1 hardening): never descend into a different mounted
    # filesystem than the one cache_dir_resolved itself lives on. Cheap
    # defense-in-depth against this container ever ending up with an
    # unexpected nested mount (or a symlink-created bind-mount-like
    # structure) somewhere under the cache tree causing this scan to wander
    # outside the intended volume.
    local count=0
    local purge_scan purge_err
    purge_scan="$(mktemp)"
    purge_err="$(mktemp)"
    if ! find "$cache_dir_resolved" -xdev -type f -mtime "+${CACHE_VALID_DAYS}" -print0 > "$purge_scan" 2>"$purge_err"; then
        # Non-fatal `return` (not `return 1`) under `set -e`: this function
        # is called as a bare statement from the main loop, so a nonzero
        # return would kill the whole retention daemon on a transient find
        # failure. The stamp is intentionally NOT updated on this path
        # either, for the same reason as the missing-CACHE_DIR case above.
        log "ERROR: find failed while scanning $cache_dir_resolved for cache purge: $(cat "$purge_err")"
        rm -f "$purge_scan" "$purge_err"
        return
    fi
    rm -f "$purge_err"

    # TOCTOU note (#842 Teil 1 review, not fully closed -- see this file's
    # header comment for the honest framing): there is an unavoidable window
    # between find's stat (deciding a file is old) and rm (deleting it) that
    # pure shell cannot close without inode-relative unlinkat, which no
    # POSIX shell builtin exposes. The `[ -f "$file" ]` re-check immediately
    # before rm narrows this window (a file removed between the scan and now
    # is skipped rather than erroring) but does not eliminate a race against
    # a concurrent writer recreating the exact same path in that window.
    # `find -type f` itself is not fooled by a symlink swap (GNU find's
    # `-type` without `-L` never matches a symlink, so a symlink planted at
    # this path would simply not appear in $purge_scan at all) -- the
    # residual risk is narrower than "arbitrary symlink redirection," it is
    # "a same-path file replaced by another same-path file in a small
    # window." Closing this fully is exactly what the container-level
    # containment (Docker Compose hardening / jail, tracked as this issue's
    # Part 2) is for: even a successful race here can only ever reach paths
    # inside the mounted cache tree, never outside it.
    while IFS= read -r -d '' file; do
        if [ -f "$file" ] && rm -- "$file"; then
            count=$(( count + 1 ))
        fi
    done < "$purge_scan"
    rm -f "$purge_scan"
    log "Purged $count files from $cache_dir_resolved"

    mkdir -p "$(dirname "$PURGE_STAMP")"
    echo "$now" > "$PURGE_STAMP"
}

# Storage-budget retention engine for syslog-ng's rotated/compressed output
# (#633). Rate-limited via its own stamp file, untrusted numeric input
# clamped to a safe default via the same `case ''|*[!0-9]*)` idiom, every
# deletion explicitly logged.
#
# Ordering is deliberate and matches the issue's explicit requirement --
# SIZE BUDGET TAKES PRIORITY OVER RETENTION DAYS:
#   Pass 1 (age):  delete anything older than SYSLOG_RETENTION_DAYS first.
#                  This is a floor, not the primary control.
#   Pass 2 (size): re-measure what's left; if still over SYSLOG_MAX_GB,
#                  delete oldest-first (regardless of age) until under
#                  budget. This can and will delete files younger than the
#                  retention floor if the size budget demands it.
maybe_prune_syslog() {
    if ! is_truthy "$SYSLOG_ENABLED"; then
        return
    fi

    local now; now=$(date +%s)
    local last=0

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
    if [ "$max_gb" -lt 1 ]; then
        log "SYSLOG_MAX_GB=${max_gb} is below the supported minimum (1 GiB); using default 10"
        max_gb=10
    fi
    if [ "$max_gb" -gt 1048576 ]; then
        log "SYSLOG_MAX_GB=${max_gb} exceeds supported maximum (1048576 GiB); clamping to 1048576"
        max_gb=1048576
    fi

    # Fail-closed path validation, every call -- see validate_retention_dir()'s
    # comment and maybe_purge()'s identical pattern above.
    local syslog_log_root_resolved
    SYSLOG_LOG_ROOT="${SYSLOG_LOG_ROOT:-/var/log/lancache-syslog-ng}"
    # `|| return 0` -- see maybe_purge()'s identical comment above for why a
    # bare `return` here would incorrectly kill the whole retention daemon.
    syslog_log_root_resolved="$(validate_retention_dir "SYSLOG_LOG_ROOT" "$SYSLOG_LOG_ROOT" "$SYSLOG_LOG_ROOT_ALLOWED_PREFIX")" || return 0

    if [ ! -d "$syslog_log_root_resolved" ]; then
        log "SYSLOG_LOG_ROOT=${syslog_log_root_resolved} does not exist yet; skipping syslog prune"
        return
    fi

    log "Syslog prune: retention=${retention_days}d budget=${max_gb}GB root=${syslog_log_root_resolved}"

    # --- Pass 1: age-based deletion (retention-days floor) -----------------
    # -xdev: see maybe_purge()'s identical comment above.
    local age_scan; age_scan="$(mktemp)"
    local age_err; age_err="$(mktemp)"
    if ! find "$syslog_log_root_resolved" -xdev -type f -mtime "+${retention_days}" -print0 > "$age_scan" 2>"$age_err"; then
        log "ERROR: find failed while scanning $syslog_log_root_resolved for age-based syslog pruning: $(cat "$age_err")"
        rm -f "$age_scan" "$age_err"
        return
    fi
    rm -f "$age_err"

    local age_count=0
    # TOCTOU note: see maybe_purge()'s identical residual-risk comment above
    # -- the same analysis applies to every deletion loop in this file.
    while IFS= read -r -d '' file; do
        if [ -f "$file" ] && rm -- "$file"; then
            age_count=$(( age_count + 1 ))
            log "Pruned syslog file (age > ${retention_days}d): $file"
        fi
    done < "$age_scan"
    rm -f "$age_scan"
    log "Age-based syslog prune: removed $age_count file(s) older than ${retention_days}d from $syslog_log_root_resolved"

    # --- Pass 2: size-budget deletion, oldest-first -------------------------
    local du_output
    if ! du_output=$(du -sb "$syslog_log_root_resolved" 2>&1); then
        log "ERROR: du failed while measuring $syslog_log_root_resolved size for syslog retention: $du_output"
        return
    fi
    local size_bytes; size_bytes=$(awk '{print $1}' <<< "$du_output")
    # `10#` forces base-10 evaluation -- see watchdog.sh's identical fix and
    # comment for the underlying incident class this guards against.
    local budget_bytes=$(( 10#$max_gb * 1024 * 1024 * 1024 ))

    if [ "$size_bytes" -le "$budget_bytes" ]; then
        log "Syslog size within budget: ${size_bytes} bytes <= ${budget_bytes} bytes (${max_gb}GB); no size-based pruning needed"
        mkdir -p "$(dirname "$SYSLOG_PRUNE_STAMP")"
        echo "$now" > "$SYSLOG_PRUNE_STAMP"
        return
    fi

    log "Syslog size budget exceeded: ${size_bytes} bytes > ${budget_bytes} bytes (${max_gb}GB); pruning oldest files first regardless of age"

    local size_scan; size_scan="$(mktemp)"
    local size_err; size_err="$(mktemp)"
    if ! find "$syslog_log_root_resolved" -xdev -type f -printf '%T@\t%p\n' > "$size_scan" 2>"$size_err"; then
        log "ERROR: find failed while listing $syslog_log_root_resolved for size-based syslog pruning: $(cat "$size_err")"
        rm -f "$size_scan" "$size_err"
        return
    fi
    rm -f "$size_err"

    local size_sorted; size_sorted="$(mktemp)"
    sort -n "$size_scan" > "$size_sorted"
    rm -f "$size_scan"

    local size_count=0
    # syslog-ng writes directly to $syslog_log_root_resolved/$HOST/$YEAR$MONTH$DAY.log;
    # only its own rotation loop may retire today's per-host file -- see the
    # original watchdog.sh version of this comment (preserved in git history)
    # for the full reasoning. `date -u` here must match the date syslog-ng's
    # own destination macro renders; neither container sets TZ, so both
    # default to UTC and stay in agreement.
    local today_name; today_name="$(date -u +%Y%m%d).log"
    while IFS=$'\t' read -r _mtime file; do
        [ "$size_bytes" -le "$budget_bytes" ] && break
        [ -f "$file" ] || continue
        if [ "$(basename -- "$file")" = "$today_name" ]; then
            continue
        fi
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
    if [ "$size_bytes" -gt "$budget_bytes" ]; then
        # #849 bug-hunt finding observability.md#21: this branch used to
        # stamp $now unconditionally, exactly like the success path below --
        # since the gate at the top of this function only re-enters once
        # 86400s have elapsed since the stamp, that made the very retry the
        # WARNING below promises wait up to a full 24h even when syslog-ng
        # rotates today's active file (making it prunable) minutes later.
        # Back-dating the stamp by (86400 - SYSLOG_PRUNE_RETRY_COOLDOWN)
        # seconds reuses that same top-of-function comparison completely
        # unchanged, but makes it become eligible again after
        # SYSLOG_PRUNE_RETRY_COOLDOWN seconds (default 1h) instead of the
        # full day -- a real, bounded retry cadence rather than a comment
        # that merely claims one exists.
        local retry_cooldown="${SYSLOG_PRUNE_RETRY_COOLDOWN:-3600}"
        case "$retry_cooldown" in
            ''|*[!0-9]*)
                log "Invalid SYSLOG_PRUNE_RETRY_COOLDOWN=${SYSLOG_PRUNE_RETRY_COOLDOWN:-}; using default 3600"
                retry_cooldown=3600
                ;;
        esac
        # `10#` forces base-10 evaluation -- see this file's other numeric
        # knobs for the identical leading-zero-as-octal incident this guards
        # against. Clamped to the normal 86400s cadence as an upper bound: a
        # cooldown longer than that would make the still-exceeded branch
        # retry LESS often than the already-converged success path above,
        # which is backwards for a "budget still exceeded" state.
        if [ "$((10#$retry_cooldown))" -gt 86400 ]; then
            log "SYSLOG_PRUNE_RETRY_COOLDOWN=${retry_cooldown} exceeds the normal 86400s cadence; clamping to 86400"
            retry_cooldown=86400
        fi
        log "WARNING: syslog size budget still exceeded after pruning -- today's active per-host log files are never deleted to avoid unlinking a file syslog-ng still has open; will retry in ${retry_cooldown}s once they age out or syslog-ng rotates them"
        echo "$(( now - 86400 + 10#$retry_cooldown ))" > "$SYSLOG_PRUNE_STAMP"
    else
        echo "$now" > "$SYSLOG_PRUNE_STAMP"
    fi
}

# Bounds fluent-bit's own operational self-log file (issue #1236). See
# watchdog.sh's original version of this comment (preserved in git history)
# for the full empirical background on why copy-then-truncate is used
# instead of rename-based rotation, and why this has no SYSLOG_ENABLED gate
# and no daily rate limit, unlike maybe_prune_syslog() above.
maybe_rotate_fluent_bit_selflog() {
    # Fail-closed path validation, every call -- see validate_retention_dir()'s
    # comment and maybe_purge()'s identical pattern above. Unlike the age/size
    # daily-stamped functions, this one runs every cycle, so this validation
    # runs every cycle too -- still negligible next to a single `stat` call.
    local fluent_bit_selflog_dir_resolved
    FLUENT_BIT_SELFLOG_DIR="${FLUENT_BIT_SELFLOG_DIR:-/var/lib/lancache-syslog-data}"
    # `|| return 0` -- see maybe_purge()'s identical comment above for why a
    # bare `return` here would incorrectly kill the whole retention daemon.
    fluent_bit_selflog_dir_resolved="$(validate_retention_dir "FLUENT_BIT_SELFLOG_DIR" "$FLUENT_BIT_SELFLOG_DIR" "$FLUENT_BIT_SELFLOG_DIR_ALLOWED_PREFIX")" || return 0

    local selflog_file="$fluent_bit_selflog_dir_resolved/fluent-bit.log"

    if [ ! -f "$selflog_file" ]; then
        return
    fi

    local max_mb="${FLUENT_BIT_SELFLOG_MAX_MB:-20}"
    case "$max_mb" in
        ''|*[!0-9]*)
            log "Invalid FLUENT_BIT_SELFLOG_MAX_MB=${FLUENT_BIT_SELFLOG_MAX_MB:-}; using default 20"
            max_mb=20
            ;;
    esac
    if [ "$max_mb" -lt 1 ]; then
        log "FLUENT_BIT_SELFLOG_MAX_MB=${max_mb} is below the supported minimum (1 MiB); using default 20"
        max_mb=20
    fi
    if [ "$max_mb" -gt 1048576 ]; then
        log "FLUENT_BIT_SELFLOG_MAX_MB=${max_mb} exceeds supported maximum (1048576 MiB); clamping to 1048576"
        max_mb=1048576
    fi

    local max_rotations="${FLUENT_BIT_SELFLOG_MAX_ROTATIONS:-5}"
    case "$max_rotations" in
        ''|*[!0-9]*)
            log "Invalid FLUENT_BIT_SELFLOG_MAX_ROTATIONS=${FLUENT_BIT_SELFLOG_MAX_ROTATIONS:-}; using default 5"
            max_rotations=5
            ;;
    esac
    if [ "$max_rotations" -lt 1 ]; then
        log "FLUENT_BIT_SELFLOG_MAX_ROTATIONS=${max_rotations} is below the supported minimum (1); using default 5"
        max_rotations=5
    fi

    local max_bytes=$(( 10#$max_mb * 1024 * 1024 ))
    local size_bytes
    size_bytes=$(stat -c '%s' "$selflog_file" 2>/dev/null || echo 0)

    if [ "$size_bytes" -le "$max_bytes" ]; then
        return
    fi

    log "Fluent-bit self-log budget exceeded: ${size_bytes} bytes > ${max_bytes} bytes (${max_mb}MB); rotating"

    local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
    local rotated="${selflog_file}.${ts}"

    # Copy-then-truncate, not rename+reopen -- see file header pointer above
    # for the full empirical justification (preserved in the original
    # watchdog.sh commit history). `cp` before `: > file` is deliberate: a
    # failed copy must leave the live file untouched rather than truncated
    # with its content already lost.
    if cp -- "$selflog_file" "$rotated"; then
        : > "$selflog_file"
        log "Rotated fluent-bit self-log to $rotated (live file truncated in place)"
        if command -v zstd >/dev/null 2>&1; then
            zstd -q -T0 -19 --rm "$rotated" 2>/dev/null || true
        fi
    else
        log "ERROR: failed to copy $selflog_file to $rotated; skipping this cycle's rotation to avoid losing unarchived content"
        return
    fi

    # Cap total rotated-backup count regardless of outage length, oldest-first.
    local rotation_scan; rotation_scan="$(mktemp)"
    if ! find "$fluent_bit_selflog_dir_resolved" -maxdepth 1 -type f \
            -name "fluent-bit.log.*" -printf '%T@\t%p\n' > "$rotation_scan" 2>/dev/null; then
        log "ERROR: find failed while listing rotated fluent-bit self-log backups; skipping rotation-count cleanup this cycle"
        rm -f "$rotation_scan"
        return
    fi

    local rotation_count
    rotation_count=$(wc -l < "$rotation_scan")
    if [ "$rotation_count" -gt "$max_rotations" ]; then
        local excess=$(( rotation_count - 10#$max_rotations ))
        local rotation_sorted; rotation_sorted="$(mktemp)"
        sort -n "$rotation_scan" > "$rotation_sorted"
        local pruned=0
        while IFS=$'\t' read -r _mtime file && [ "$pruned" -lt "$excess" ]; do
            if rm -- "$file"; then
                pruned=$(( pruned + 1 ))
                log "Pruned old fluent-bit self-log rotation (rotation-count budget, oldest-first): $file"
            fi
        done < "$rotation_sorted"
        rm -f "$rotation_sorted"
    fi
    rm -f "$rotation_scan"
}

# --- Startup: log the effective configuration, not authoritative -----------
# Purely informational, matching watchdog.sh's own startup log lines --
# real, authoritative path validation happens fresh inside each function on
# every call instead (see validate_retention_dir()'s own comment for why
# per-call beats once-at-startup here). A bad value is NOT rejected here
# with `exit 1`; it surfaces as a loud, repeating rejection log from
# whichever function's call to validate_retention_dir() first hits it,
# every single cycle -- fail closed forever rather than fail open once and
# stop checking.
SYSLOG_LOG_ROOT="${SYSLOG_LOG_ROOT:-/var/log/lancache-syslog-ng}"
FLUENT_BIT_SELFLOG_DIR="${FLUENT_BIT_SELFLOG_DIR:-/var/lib/lancache-syslog-data}"

# Own loop interval, independent of watchdog.sh's CHECK_INTERVAL (a separate
# process needs its own knob) but defaulting to the same value so existing
# installs see identical retention timing behavior after this split as
# before it. Same digit-only + floor-at-1 guard as watchdog.sh's
# CHECK_INTERVAL for the same reason: an unvalidated value reaches `sleep`
# under `set -e` and crashes this daemon, and a literal 0 would busy-loop.
RETENTION_INTERVAL="${RETENTION_INTERVAL:-${CHECK_INTERVAL:-30}}"
case "$RETENTION_INTERVAL" in
    ''|*[!0-9]*)
        log "Invalid RETENTION_INTERVAL=${RETENTION_INTERVAL}; using default 30"
        RETENTION_INTERVAL=30
        ;;
esac
if [ "$RETENTION_INTERVAL" -lt 1 ]; then
    log "RETENTION_INTERVAL=${RETENTION_INTERVAL} is below the supported minimum (1s); using 1"
    RETENTION_INTERVAL=1
fi

log "Retention daemon started. Cache: $CACHE_DIR (valid ${CACHE_VALID_DAYS}d, allowed prefix ${CACHE_DIR_ALLOWED_PREFIX}) | Syslog: $SYSLOG_LOG_ROOT (enabled=$SYSLOG_ENABLED, allowed prefix ${SYSLOG_LOG_ROOT_ALLOWED_PREFIX}) | Fluent-bit self-log: $FLUENT_BIT_SELFLOG_DIR (allowed prefix ${FLUENT_BIT_SELFLOG_DIR_ALLOWED_PREFIX})"

while true; do
    maybe_purge
    maybe_prune_syslog
    # Unlike the two above, maybe_rotate_fluent_bit_selflog() (#1236) runs
    # every cycle rather than once every ~24h -- see its own comment for why
    # a daily rate limit doesn't fit a single-file `stat` check; this
    # per-cycle cadence must survive at whatever RETENTION_INTERVAL is set
    # to, unlike the two daily-stamped functions above it.
    maybe_rotate_fluent_bit_selflog
    sleep "$RETENTION_INTERVAL"
done
