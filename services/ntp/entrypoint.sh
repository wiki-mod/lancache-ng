#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
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
if [ -f /data/lancache-ui-settings.env ]; then
    # shellcheck disable=SC1091
    . /data/lancache-ui-settings.env
fi

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

# Least-privilege hardening, seccomp leg (issue #1358): `-F 1` only makes
# sense if this build was actually compiled with seccomp support at all --
# checked live rather than assumed (AG-VAL-023) via `chronyd -v`'s own
# reported feature list, which shows `+SCFILTER` for this image's Alpine
# `chrony-nts` package (its `chrony-common`/`chrony-nts` APKBUILD links
# against `libseccomp`, pulled in automatically as a real package
# dependency, not something this Dockerfile opts into itself). Level 1 (not
# 2) per chrony-project.org's own chronyd(8) docs: level 1 is the strict
# allow-list ("only selected system calls... normally expected to be made
# by chronyd"; anything else is blocked), whereas level 2 only blocks a
# small named set (e.g. fork/exec) -- level 1 is the actual least-privilege
# choice this issue asks for, not the lighter one. Confirmed live (see PR
# #1358's validation notes) that chronyd starts, disciplines its clock, and
# keeps answering `chronyc tracking`/LAN NTP queries normally with this
# flag set -- an over-strict seccomp level would instead kill the process
# outright on its first disallowed syscall, which is not what was observed.
echo "Starting LanCache-NG-NTP (chronyd) with upstream servers: $NTP_UPSTREAM_SERVERS"
exec chronyd -n -f "$NTP_RUNTIME_CONF" -F 1
