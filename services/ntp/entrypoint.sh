#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# LanCache-NG-NTP entrypoint. Renders /etc/chrony/chrony.conf from the base
# template plus the operator-configured upstream server list and LAN-scoped
# client allowlist, validates the result structurally, then starts chronyd
# in the foreground.

set -e

mkdir -p /var/log/chrony /var/lib/chrony

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

# Curated default: the four official Debian NTP pool zones (this image's own
# vendor pool, matching the base OS) plus Cloudflare's well-known anycast NTP
# service, for a sensible default an operator never has to think about.
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

NTP_RUNTIME_CONF=/etc/chrony/chrony.conf
render_ntp_config "$NTP_RUNTIME_CONF"
validate_ntp_config "$NTP_RUNTIME_CONF" || exit 1

echo "Starting LanCache-NG-NTP (chronyd) with upstream servers: $NTP_UPSTREAM_SERVERS"
exec chronyd -n -f "$NTP_RUNTIME_CONF"
