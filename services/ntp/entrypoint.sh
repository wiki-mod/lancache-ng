#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# LanCache-NG-NTP entrypoint. Renders /etc/chrony/chrony.conf from the base
# template plus the operator-configured upstream server list and LAN-scoped
# client allowlist, validates the result structurally, then starts chronyd
# in the foreground.

set -e

mkdir -p /var/log/chrony /var/lib/chrony

# chronyd drops privileges to the packaged `chrony` user on its own
# (compiled-in PRIVDROP default -- confirmed live: it runs as `chrony`/uid
# 100 after startup even though this entrypoint execs it as root below), but
# this entrypoint itself still runs as root here, so /var/log/chrony and
# /var/lib/chrony can end up root-owned instead: the image's own
# /var/log/chrony is created by the Dockerfile's `mkdir -p` at build time
# (root, since no package pre-creates it the way chrony-nts's chrony-common
# dependency pre-creates /var/lib/chrony as chrony:chrony), a fresh
# Docker-managed named volume mounted over it copies that same root
# ownership on first use, and a host bind mount (e.g. NTP_DATA_DIR) is
# whatever the host directory already was before this container ever wrote
# to it. Without this chown, the privilege-dropped chronyd cannot open its
# own log files or driftfile there and fails silently -- confirmed live,
# reproducibly, with real "Could not open /var/log/chrony/*.log :
# Permission denied" errors, present identically on the pre-Alpine-migration
# Debian image too (a real, pre-existing bug this validation pass found, not
# something the base-image swap introduced). Deliberately best-effort, not a
# hard failure under `set -e` above: logging/driftfile persistence are
# secondary to this service's actual job (disciplining the clock and
# serving LAN clients on UDP/123), which chronyd continues to do correctly
# even when these particular writes fail.
if ! chown chrony:chrony /var/log/chrony /var/lib/chrony; then
    echo "WARNING: could not chown /var/log/chrony and/or /var/lib/chrony to the chrony user; chronyd's own log/driftfile writes may fail (the service will still discipline time and serve NTP clients normally)." >&2
fi

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
# Path confirmed directly against this image's own real chronyd build
# (AG-VAL-023: checked the tool's actual behavior, not assumed it) --
# chrony.conf.template sets no explicit `pidfile` directive, so chronyd
# uses its Debian package's compiled-in default, and a real crash's own
# fatal-error message named this exact path: "Another chronyd may already
# be running (pid=1), check /run/chrony/chronyd.pid".
# shellcheck disable=SC2120 # the real call site below intentionally passes
# no argument (always wants chrony's real default path); the optional
# override exists purely so tests/bats/ntp_entrypoint_rendering.bats can
# point this at a throwaway fixture path instead of the real
# /run/chrony/chronyd.pid, the same optional-parameter pattern
# render_ntp_config's own template argument already uses above.
cleanup_stale_ntp_pidfile() {
    local pidfile="${1:-/run/chrony/chronyd.pid}"
    rm -f "$pidfile"
}

NTP_RUNTIME_CONF=/etc/chrony/chrony.conf
render_ntp_config "$NTP_RUNTIME_CONF"
validate_ntp_config "$NTP_RUNTIME_CONF" || exit 1
cleanup_stale_ntp_pidfile

echo "Starting LanCache-NG-NTP (chronyd) with upstream servers: $NTP_UPSTREAM_SERVERS"
exec chronyd -n -f "$NTP_RUNTIME_CONF"
