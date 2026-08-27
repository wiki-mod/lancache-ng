#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# LanCache-NG-NTP entrypoint. Renders /etc/chrony/chrony.conf from the base
# template plus the operator-configured upstream server list and LAN-scoped
# client allowlist, validates the result structurally, then starts chronyd
# in the foreground.

set -e

mkdir -p /var/log/chrony /var/lib/chrony

# Real bug found while validating issue #1358's least-privilege hardening,
# unrelated to and pre-existing before that hardening itself (present
# identically on the unmodified image; not something cap_drop/user/-F
# introduced): nothing in this project ever created /run/chrony, and
# chronyd does not create its own pidfile's parent directory -- it only
# opens the pidfile assuming the directory already exists. This project's
# own self-hosted CI runner fleet never surfaced it because every one of
# those hosts is itself LXC-nested and chronyd there always dies earlier,
# at the unrelated adjtimex/CAP_SYS_TIME step (issue #1296), before ever
# reaching the pidfile-open step this bug lives in -- confirmed live by
# deliberately bypassing that earlier failure with chronyd's own `-x` flag
# (never step/slew) as a diagnostic-only probe, which let startup proceed
# far enough to hit "Fatal error : Could not open /run/chrony/chronyd.pid :
# No such file or directory" instead. A real deployment where CAP_SYS_TIME
# actually works (i.e. anywhere outside this project's own nested-LXC CI
# fleet) would reach this same failure today, unconditionally, matching
# AG-WF-027 ("fix identified problems in the same pass," even ones outside
# the change's original narrow scope, when reachable without a separate
# approval gate). /run is typically a fresh tmpfs each container start, so
# this must be created every start, not just once at image build time (a
# build-time `mkdir -p /run/chrony` in the Dockerfile would not survive
# into the running container).
mkdir -p /run/chrony

# The Admin UI persists its own settings (including this service's) to the
# shared ui-data volume rather than mutating this container's environment
# directly -- same mechanism services/dhcp-proxy/entrypoint.sh already uses,
# since (unlike Kea) this daemon has no live control API the UI can call
# instead. An operator-supplied real env var still wins if set directly
# (e.g. via config/*/ntp.env), matching that same precedent.
#
# _ntp_source_ui_settings <settings_file>
#
# Reads the Admin-UI-persisted settings file if it exists, WITHOUT executing
# it as shell code; a missing file is not an error -- a fresh install has
# none yet, and every var this function might set has its own
# `: "${VAR:=}"` fallback further down.
#
# Deliberately does NOT `. <file>` (dot-source) the settings file, even
# though an earlier version of this entrypoint did (issue #849 finding,
# same root cause as services/dhcp-proxy/entrypoint.sh's identical pattern,
# fixed there first). This file is SHARED across multiple services'
# Admin-UI-persisted settings -- NTP_UPSTREAM_SERVERS itself is strictly
# validated (validate_ntp_upstream_servers, services/ui/src/routes/ntp.rs:
# every entry must parse as a bare IPv4/IPv6 literal or an RFC 1123 hostname
# label, no shell metacharacters possible), but this entrypoint dot-sourced
# the WHOLE file, not just its own keys -- so a weakly-validated value
# written by a DIFFERENT route into this SAME file (confirmed real:
# DHCP_PROXY_CUSTOM_OPTIONS, validated only for length/embedded-newlines by
# validate_custom_dhcp_option_data, not shell metacharacters) would be
# executed here too, during this container's own startup, even though ntp
# never reads that variable itself. Parsing the file as plain KEY=value text
# instead (a case-statement allowlist of the exact key names this service
# actually reads, `printf -v` for the assignment, never `eval` or a
# dot-source) closes that off entirely, regardless of what any other
# service's route ever writes into this shared file.
_ntp_source_ui_settings() {
    local settings_file="$1"
    [ -f "$settings_file" ] || return 0

    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '' | '#'*) continue ;;
        esac
        case "$line" in
            *=*)
                key="${line%%=*}"
                value="${line#*=}"
                ;;
            *)
                continue
                ;;
        esac
        # Strip one layer of matching quotes for an operator's own
        # hand-edited file -- the Admin UI's own writer never quotes
        # values. Never interpreted as shell syntax either way: this is a
        # plain string trim, not a re-parse.
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac
        # Allowlist: only assign the variables this script actually reads
        # further down. $key can only ever equal one of these exact literal
        # strings after matching this case pattern (bash case matching here
        # is a literal string comparison, not a regex/glob substitution
        # into the pattern), so this cannot become a variable-name
        # injection either -- an unrecognized key in the file (settings
        # belonging to a different service, a future Admin-UI-only setting,
        # a typo, or anything else) is silently ignored rather than
        # exported as an arbitrary shell variable.
        case "$key" in
            NTP_UPSTREAM_SERVERS | NTP_ALLOWED_CLIENT_CIDRS)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$settings_file"
}

_ntp_source_ui_settings /data/lancache-ui-settings.env

# Curated default: the four official Debian NTP pool zones plus Cloudflare's
# well-known anycast NTP service, for a sensible default an operator never
# has to think about. These pool zone hostnames work identically regardless
# of this image's own base OS -- pool.ntp.org vendor zones are just a
# courtesy DNS naming convention for spreading load across the public pool,
# not something tied to the querying host's own distro (any pool zone
# resolves to real, usable NTP servers for any client). Kept as-is after
# this image's Alpine migration (issue #815 Part B) rather than switched to
# an Alpine-specific zone: Alpine has no comparably established dedicated
# vendor pool zone, and changing this default would be a user-visible
# behavior change out of scope for a base-image swap.
: "${NTP_UPSTREAM_SERVERS:=0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org 3.debian.pool.ntp.org time.cloudflare.com}"
: "${NTP_ALLOWED_CLIENT_CIDRS:=}"

# Requirement 1 (see the issue this container was built for): this service
# must discipline its own clock against real upstream servers, never stand
# alone. An empty upstream list would silently start chronyd with nothing to
# sync against, so this is a hard, fail-closed error -- not just a warning.
if [ -z "${NTP_UPSTREAM_SERVERS// /}" ]; then
    echo "ERROR: NTP_UPSTREAM_SERVERS is empty. LanCache-NG-NTP must be configured with at least one upstream NTP server/pool; it never operates as a standalone time source." >&2
    exit 1
fi

# Not a hard failure (a deliberate single-upstream override is still a valid,
# if less resilient, configuration) -- just makes the "multiple servers"
# expectation from requirement 1 visible in the logs when an operator has
# narrowed the list down to one entry.
_ntp_upstream_count=0
for _ntp_entry in $NTP_UPSTREAM_SERVERS; do
    _ntp_upstream_count=$((_ntp_upstream_count + 1))
done
if [ "$_ntp_upstream_count" -lt 2 ]; then
    echo "WARNING: NTP_UPSTREAM_SERVERS configures only ${_ntp_upstream_count} upstream server(s); syncing against multiple independent servers is recommended for reliable discipline." >&2
fi

# is_ip_literal <entry>
# True for an IPv4 or IPv6 literal (a plain regex classification, not a real
# parse -- good enough to choose chrony's `server` vs `pool` directive; an
# invalid literal that slips through is still just handed to chronyd, which
# will reject it with its own clear error on start).
is_ip_literal() {
    case "$1" in
        *:*) return 0 ;;                              # any colon => IPv6 literal
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) return 0 ;;       # dotted-quad shape => IPv4 literal
        *) return 1 ;;
    esac
}

render_ntp_config() {
    # template defaults to the real base config, but is overridable so
    # tests/bats/ntp_entrypoint_rendering.bats can point this at a throwaway
    # fixture instead of requiring /etc/chrony/chrony.conf.template to exist
    # on the test host.
    local target="$1" template="${2:-/etc/chrony/chrony.conf.template}"

    cp "$template" "$target"

    {
        echo ""
        echo "# Upstream servers (NTP_UPSTREAM_SERVERS) -- rendered at container start."
        for entry in $NTP_UPSTREAM_SERVERS; do
            if is_ip_literal "$entry"; then
                printf 'server %s iburst\n' "$entry"
            else
                printf 'pool %s iburst\n' "$entry"
            fi
        done

        echo ""
        echo "# LAN client access (NTP_ALLOWED_CLIENT_CIDRS) -- rendered at container start."
        if [ -n "$NTP_ALLOWED_CLIENT_CIDRS" ]; then
            for cidr in $NTP_ALLOWED_CLIENT_CIDRS; do
                printf 'allow %s\n' "$cidr"
            done
        else
            # Matches services/proxy's PROXY_ALLOWED_CLIENT_CIDRS convention:
            # empty means allow any client that can reach the bound LAN/Docker
            # port, not "deny everyone" -- chrony denies all NTP clients by
            # default without at least one explicit `allow`, which would
            # silently defeat requirement 3 (LAN exposure on UDP/123) for any
            # operator who never touches this setting.
            echo "allow 0.0.0.0/0"
            echo "allow ::/0"
        fi
    } >> "$target"
}

# Structural pre-flight check, not a real "config test": chronyd has no
# offline config-validation mode equivalent to `nginx -t`/`dnsmasq --test`
# (confirmed against chronyd's own documented options), so this only catches
# the specific way rendering above could break rather than every possible
# chrony.conf error -- chronyd itself is still the authoritative validator
# when it starts.
validate_ntp_config() {
    local target="$1"

    if ! grep -Eq '^(pool|server) ' "$target"; then
        echo "ERROR: rendered $target has no pool/server directive; refusing to start." >&2
        return 1
    fi
    if ! grep -Eq '^allow ' "$target"; then
        echo "ERROR: rendered $target has no allow directive; refusing to start." >&2
        return 1
    fi
    return 0
}

# _fix_chrony_dir_ownership_core <owner> <log_dir> <lib_dir>
# Real logic, shared by production and tests, all three arguments required
# (not optional): chronyd drops privileges to the packaged `chrony` user on
# its own (compiled-in PRIVDROP default -- confirmed live: it runs as
# `chrony`/uid 100 after startup even though this entrypoint execs it as
# root below), but this entrypoint itself still runs as root here, so
# log_dir/lib_dir can end up root-owned instead: the image's own
# /var/log/chrony is created by the Dockerfile's `mkdir -p` at build time
# (root, since no package pre-creates it the way chrony-nts's chrony-common
# dependency pre-creates /var/lib/chrony as chrony:chrony), a fresh
# Docker-managed named volume mounted over it copies that same root
# ownership on first use, and a host bind mount (e.g. NTP_DATA_DIR) is
# whatever the host directory already was before this container ever wrote
# to it. Without this, the privilege-dropped chronyd cannot open its own
# log files or driftfile there and fails silently -- confirmed live,
# reproducibly, with real "Could not open /var/log/chrony/*.log :
# Permission denied" errors, present identically on the pre-Alpine-migration
# Debian image too (a real, pre-existing bug this validation pass found, not
# something the base-image swap introduced). Called every start (not just
# first) so an already wrong-owned pre-existing production volume self-heals
# on its very next restart, not only on a fresh install.
#
# Deliberately always returns 0 (never propagates a chown failure to the
# caller, so a bare call at the top level cannot trip `set -e` above): this
# is optional, best-effort hardening, not a required step -- see
# AG-VAL-004's carve-out for an explicitly documented optional fallback.
# Logging/driftfile persistence are secondary to this service's actual job
# (disciplining the clock and serving LAN clients on UDP/123), which
# chronyd continues to do correctly even when these particular writes fail.
#
# Deliberately takes required (not optional/defaulted) parameters, unlike
# render_ntp_config's `template` or cleanup_stale_ntp_pidfile's `pidfile`:
# an earlier version of this file gave THIS function optional defaults too
# and suppressed the resulting shellcheck SC2120 finding ("references
# arguments, but none are ever passed" -- true within this file alone,
# since the one production call site passed none) with a disable comment.
# That shipped without maintainer sign-off and was reverted on maintainer
# instruction: a lint suppression is not an acceptable default response to
# an inconvenient warning, even a plausible one, without asking first. This
# split (a real, parameterized, directly-testable core plus a fixed-value
# production entry point below) removes the warning by construction instead
# -- `fix_chrony_dir_ownership` below has no parameters to flag, and this
# function genuinely IS called with real arguments in production code (by
# that entry point), so shellcheck's premise for SC2120 no longer holds
# either. tests/bats/ntp_entrypoint_rendering.bats calls this function
# directly with fixture owners/paths to exercise the exact same logic
# production uses, without needing a second, divergent test-only
# reimplementation.
_fix_chrony_dir_ownership_core() {
    local owner="$1" log_dir="$2" lib_dir="$3"

    if ! chown "$owner" "$log_dir" "$lib_dir" 2>&1; then
        echo "WARNING: could not chown $log_dir and/or $lib_dir to $owner; chronyd's own log/driftfile writes may fail (the service will still discipline time and serve NTP clients normally)." >&2
    fi
    return 0
}

# fix_chrony_dir_ownership
# Production entry point: no parameters at all, so there is nothing for a
# future shellcheck pass to flag as unused. Hardcodes the real values this
# service always uses -- see _fix_chrony_dir_ownership_core's comment above
# for why this exists as a separate function instead of giving that
# function optional/defaulted parameters directly.
fix_chrony_dir_ownership() {
    _fix_chrony_dir_ownership_core chrony:chrony /var/log/chrony /var/lib/chrony
}

# _cleanup_stale_ntp_pidfile_core <pidfile>
# Removes chronyd's own pidfile if a stale one survives from a previously
# crashed instance in THIS SAME container (issue #1318). Docker's
# `restart: always` re-execs this entrypoint against the same writable
# container filesystem -- /run is not reset between restarts within one
# container's lifetime -- so if chronyd previously started, wrote its
# pidfile, then crashed before exiting cleanly (e.g. the fatal
# CAP_SYS_TIME/adjtimex error confirmed on this project's self-hosted LXC
# runner fleet, #1296), that pidfile survives and makes every subsequent
# restart attempt fail with a second, unrelated, misleading error
# ("Another chronyd may already be running") instead of the real original
# cause -- a restart loop that never actually retries cleanly, matching
# this project's convergence/idempotence expectations (issue #456: a
# transient failure must not permanently wedge a service that could
# otherwise recover on its own).
#
# Safe to remove unconditionally, every start, with no race: this
# entrypoint always execs chronyd directly as this container's own PID 1
# (see the final `exec` below), so there is never a legitimate SECOND
# chronyd process running concurrently in this container that this pidfile
# could be protecting against -- a fresh start always replaces whatever was
# PID 1 before, stale or not.
#
# Deliberately takes a required (not optional/defaulted) parameter, the
# same restructuring _fix_chrony_dir_ownership_core/fix_chrony_dir_ownership
# above went through and for the same reason (maintainer decision, AG-WF-027
# "mitbereinigen" -- fix this failure class everywhere it's found in the
# same pass, not just where it was first noticed): an earlier version gave
# this function an optional `${1:-real-path}` default and suppressed the
# resulting shellcheck SC2120 finding with a disable comment instead of
# restructuring around it. That pattern is what this file no longer uses
# anywhere -- see cleanup_stale_ntp_pidfile below for the zero-parameter
# production entry point that supplies the real path.
_cleanup_stale_ntp_pidfile_core() {
    local pidfile="$1"
    rm -f "$pidfile"
}

# cleanup_stale_ntp_pidfile
# Production entry point: no parameters, so there is nothing for a lint
# pass to flag as unused. Path confirmed directly against this image's own
# real chronyd build (AG-VAL-023: checked the tool's actual behavior, not
# assumed it) -- chrony.conf.template sets no explicit `pidfile` directive,
# so chronyd uses its packaged compiled-in default, and a real crash's own
# fatal-error message named this exact path: "Another chronyd may already
# be running (pid=1), check /run/chrony/chronyd.pid". This path is
# confirmed identical on both the pre-Alpine-migration Debian image and the
# current Alpine image.
cleanup_stale_ntp_pidfile() {
    _cleanup_stale_ntp_pidfile_core /run/chrony/chronyd.pid
}

NTP_RUNTIME_CONF=/etc/chrony/chrony.conf
render_ntp_config "$NTP_RUNTIME_CONF"
validate_ntp_config "$NTP_RUNTIME_CONF" || exit 1
cleanup_stale_ntp_pidfile
fix_chrony_dir_ownership

# Least-privilege hardening, seccomp leg (issue #1358) -- REVISED (issue
# #1296, real non-LXC verification): the original choice here was `-F 1`
# (chrony's strict syscall allow-list). That was ONLY ever verified end to
# end on two environments -- this project's self-hosted LXC runner fleet
# (via chronyd's own `-x` flag, since every one of those hosts dies earlier
# at the unrelated CAP_SYS_TIME/adjtimex restriction below, so `-F 1` was
# never actually observed reaching a real synchronised state there) and a
# GitHub-hosted `ubuntu-24.04` runner (`scripts/tracked/simulations/ntp-cap-sys-time-
# simulation.sh`). Real end-to-end validation on a genuine, non-LXC KVM
# VM (Debian 13, kernel 6.12.100) for issue #1296 found that `-F 1`
# deterministically crashes chronyd there -- 4/4 real, unmodified `docker
# run` reproductions, always the same "Fatal error : Could not open
# /run/chrony/chronyd.pid : Permission denied" this project had previously
# only ever seen from the unrelated CAP_SYS_TIME issue below, even though
# the pidfile open happens well before any clock-stepping code runs and has
# nothing to do with CAP_SYS_TIME. Attaching `strace` to observe the exact
# blocked syscall made the crash disappear instead (2/2 clean runs under
# trace, including one using `strace --seccomp-bpf` specifically to try to
# avoid perturbing timing) -- confirmed real and repeatable, but the exact
# kernel-level mechanism behind it was NOT isolated (a real EPERM is not
# the errno a bare `SECCOMP_RET_TRACE`-with-no-tracer fallback would be
# expected to produce on most documented kernel behavior, so that specific
# theory does not fully fit either, and this comment deliberately does not
# claim a mechanism it cannot back up -- AG-VAL-023). What IS established,
# by direct repeated measurement: `-F 1` deterministically breaks this
# daemon on this real, representative kernel, tracing it away is real and
# reproducible, and this project's OWN earlier verification of `-F 1` never
# actually exercised this codepath under real conditions (see above) -- so
# treating `-F 1` as validated least-privilege hardening was wrong
# regardless of the exact underlying mechanism. A strict allow-list whose
# correctness cannot be trusted against a real, representative kernel is
# not usable hardening -- it trades a security improvement for
# non-deterministic total service unavailability, which is a worse outcome
# for this daemon's actual job. Downgraded to `-F 2` (chrony's own
# documented looser level: blocks only a small explicitly named set, e.g.
# fork/exec, rather than allow-listing every syscall chronyd might use) and
# re-verified for real on the same VM: 5/5 clean `docker run -d` starts, 0
# restarts, real `Stratum`/`Leap status: Normal` sync against public
# upstream servers (see this fix's PR body for the full command/output
# transcript). Still real seccomp hardening (blocks the same dangerous
# fork/exec-family syscalls a compromised chronyd should never need), just
# not the strict allow-list variant that turned out to be unsafe on real
# kernels this project had never actually exercised it against before.
NTP_CHRONYD_FLAGS=(-F 2)

# clock_control_available
# Real, EXECUTED probe for whether this container can actually discipline
# the host's system clock right now -- deliberately not a static capability
# check (e.g. parsing /proc/self/status's CapEff bitmask), because that
# would report a false "yes" for exactly the environment this exists to
# catch: this project's own self-hosted CI runner fleet is itself LXC-
# nested, and Docker's `cap_add: SYS_TIME` genuinely lands in this
# container's effective capability set there (confirmed live) -- the outer
# LXC layer's own host-clock-isolation boundary is what then rejects the
# actual clock-setting syscall with EPERM, a restriction no in-container
# capability inspection can see.
#
# Deliberately probes `adjtimex`, NOT `date -s`: an earlier version of this
# function used `date -s <current time>` (settimeofday()/clock_settime()),
# reasoning that it exercised "the same" restricted codepath chronyd needs.
# That was wrong, confirmed live on this project's own self-hosted LXC
# fleet: `date -s` to the current time SUCCEEDS there, while chronyd itself
# still immediately crashes with `adjtimex(0x8001) failed : Operation not
# permitted` -- the LXC host's restriction specifically targets the
# `adjtimex`/`clock_adjtime` syscall chronyd actually uses for gradual NTP
# discipline, not the blunter `settimeofday` one-shot set `date -s` uses,
# even though both nominally require CAP_SYS_TIME. A probe using the wrong
# syscall would silently report "available" right into the same crash-loop
# this function exists to prevent. `adjtimex` with no arguments is a pure
# read (mode 0, no capability needed on any kernel -- confirmed live it
# succeeds even where the restriction applies) used here only to fetch the
# host's own current tick-length value, which is then written straight
# back via `adjtimex -t <that same value>` -- a genuine no-op adjustment
# (identical value in, identical value out) that still has to pass through
# the real ADJ_TICK capability check, and fails with the exact same
# "Operation not permitted" real chronyd hits when the restriction applies
# (confirmed live on all four self-hosted LXC hosts, issue #1296).
# Fails closed (returns 1, same as a genuine LXC-style denial) on either
# unexpected problem below, but deliberately logs a distinct, louder ERROR
# for each -- not the same call site's ordinary degraded-mode WARNING --
# because these are NOT the expected, already-documented nested/LXC
# restriction this function normally exists to detect; they mean the probe
# itself could not run as designed, which is a packaging/environment
# problem worth its own loud signal so it does not get misread as "just
# another LXC host." Failing closed here (rather than assuming "available"
# when the probe cannot even complete) is the safer wrong answer: a
# real deployment that never disciplines its clock but incorrectly reports
# healthy is a silent correctness problem an operator has no reason to ever
# notice, whereas a real deployment that degrades when it did not strictly
# need to is loudly visible in this container's own startup log and still
# fully functional as an NTP relay.
clock_control_available() {
    local current_tick

    # busybox's built-in `adjtimex` applet (see services/ntp/Dockerfile's
    # own comment -- not a separate apk package, just part of Alpine's base
    # busybox binary) missing would mean this image's base changed in a way
    # that silently broke this probe.
    if ! command -v adjtimex >/dev/null 2>&1; then
        echo "ERROR: the 'adjtimex' probe tool this entrypoint depends on for CAP_SYS_TIME detection is missing from this image. This is an unexpected packaging/base-image problem, NOT the expected nested/LXC restriction (issue #1296) -- please report this. Failing closed (treating clock control as unavailable) rather than risk a false 'available' that would let a real deployment silently never discipline its clock." >&2
        return 1
    fi

    current_tick="$(adjtimex 2>/dev/null | awk '/tick:/ { print $3 }')"
    if [ -z "$current_tick" ]; then
        echo "ERROR: 'adjtimex' ran but its read-mode output did not contain a parseable tick value. This is an unexpected probe-tool/output-format problem, NOT the expected nested/LXC restriction (issue #1296) -- please report this. Failing closed (treating clock control as unavailable) rather than risk a false 'available' that would let a real deployment silently never discipline its clock." >&2
        return 1
    fi

    adjtimex -q -t "$current_tick" >/dev/null 2>&1
}

# Requirement 1 says this service must discipline its own clock -- but a
# nested-container host that silently withholds CAP_SYS_TIME (issue #1296)
# makes that impossible no matter what this container requests, and
# chronyd's own reaction to that (a fatal `adjtimex(...) failed : Operation
# not permitted` crash) previously meant this service crash-looped forever
# in that environment with `restart: always`, never reporting healthy and
# never explaining why. Detecting the real restriction up front and
# stepping down to chronyd's own documented `-x` flag ("do not step or
# slew the system clock") turns an indefinite crash-loop into a genuinely
# healthy, self-explaining degraded mode: chronyd still starts, still
# tracks upstream servers' reported offsets (so `chronyc tracking` and this
# service's own Docker healthcheck keep working), still answers LAN NTP
# queries, it just never touches the host's own clock. This is a
# real, permanent property of the *environment* this container is running
# in (confirmed unconditionally reproducible, not a transient network
# blip), so this check runs once at startup rather than being retried --
# an operator who moves this container to a host that does grant
# CAP_SYS_TIME gets full clock discipline back on the container's next
# restart, same as any other environment-dependent startup decision this
# entrypoint already makes.
# Fixed path/content the compose healthcheck (see deploy/prod and
# deploy/quickstart's docker-compose.yml `ntp` service) reads on EVERY run,
# not just once: a maintainer explicitly rejected reporting plain Docker-
# "healthy" for this condition (issue #1296) -- a container that is
# genuinely running and answering NTP queries must never be confused with
# a broken/needs-restart one (there is no fourth Docker health state to
# express that distinction directly), but the reduced-guarantee condition
# itself must stay visible for as long as it applies, not scroll away as a
# one-time startup log line. Writing the reason text into this file (once,
# here) and having the healthcheck `cat` it back verbatim keeps the exact
# wording defined in exactly one place -- entrypoint.sh and the compose
# YAML's healthcheck test string would otherwise duplicate this sentence
# and could silently drift apart. `services/watchdog/src/docker_client.rs`
# reads this same text back out of Docker's own `.State.Health.Log` (part
# of the container-inspect response it already fetches) to produce a
# genuinely distinct `HealthReading::Degraded` -- see that module's
# `degraded_reason_from_health_log()` for the `DEGRADED: ` prefix
# convention this file's content feeds into. /run is a fresh tmpfs per
# container start (same reasoning as /run/chrony above), so this must be
# (re)written every start, not just once at image build time, and a
# restart onto a host that now grants CAP_SYS_TIME correctly stops writing
# it and reverts to plain healthy.
# `|| true` on both the removal and the write below is deliberate: this
# marker is a visibility nice-to-have consumed by the healthcheck/watchdog,
# not something chronyd itself needs to function. Under `set -e` (see top of
# this file), an unguarded failure here -- e.g. a future compose change that
# makes /run read-only, or any other environment this file's own author did
# not anticipate -- would kill the entrypoint before it ever reaches `exec
# chronyd` below, turning a real, deliberate degraded-but-running mode into
# an outright crash-loop: exactly the failure this whole mechanism exists to
# avoid. Losing only the marker (falling back to the pre-#1296-rework
# behavior of a silent, undisciplined-but-"healthy" clock) is a strictly
# better failure mode than losing the container.
NTP_DEGRADED_MARKER=/run/ntp-cap-sys-time-degraded
rm -f "$NTP_DEGRADED_MARKER" || true

if clock_control_available; then
    echo "Starting LanCache-NG-NTP (chronyd) with upstream servers: $NTP_UPSTREAM_SERVERS"
else
    _ntp_degraded_reason="CAP_SYS_TIME denied -- clock not disciplined (issue #1296)"
    echo "WARNING: this environment denies CAP_SYS_TIME for real clock stepping even though it was requested (commonly a nested/LXC container host -- see issue #1296). Starting LanCache-NG-NTP (chronyd) in degraded mode: it will track upstream servers ($NTP_UPSTREAM_SERVERS) and answer LAN NTP queries, but will NOT discipline this host's own system clock. Move this container to a host that grants real CAP_SYS_TIME to restore full clock discipline." >&2
    printf '%s\n' "$_ntp_degraded_reason" > "$NTP_DEGRADED_MARKER" || echo "WARNING: could not write $NTP_DEGRADED_MARKER -- the degraded healthcheck marker will be unavailable, but continuing in degraded mode regardless (see comment above)." >&2
    NTP_CHRONYD_FLAGS+=(-x)
fi
exec chronyd -n -f "$NTP_RUNTIME_CONF" "${NTP_CHRONYD_FLAGS[@]}"
