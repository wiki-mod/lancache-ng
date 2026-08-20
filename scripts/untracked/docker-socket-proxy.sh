#!/bin/sh
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Docker socket proxy entrypoint: generates the HAProxy allowlist used by the
# Admin UI/watchdog so Docker access stays limited to fixed project containers
# and explicitly allowed lifecycle actions.
set -eu

cat > /tmp/lancache-haproxy.cfg <<'EOF'
# Docker exec and generic container creation are intentionally banned here:
# the Admin UI and watchdog only need narrowly scoped lifecycle operations for
# known lancache-ng containers. A compromised UI should not gain a general
# Docker API that can create privileged containers or attach to unrelated
# workloads on the host.
global
    log stdout format raw daemon info
    pidfile /run/haproxy.pid
    maxconn 4000

defaults
    mode http
    log global
    option httplog
    option dontlognull
    option http-server-close
    timeout http-request 10s
    timeout connect 10s
    timeout client 10m
    timeout server 10m

backend dockerbackend
    server dockersocket /var/run/docker.sock

frontend dockerfrontend
    bind [::]:2375 v4v6
    # Permit only Docker daemon health/version checks plus a small set of
    # container operations for fixed lancache-ng container names.
    acl safe_get method GET
    acl safe_head method HEAD
    acl safe_post method POST
    acl safe_ping path,url_dec -m reg -i ^(/v[0-9.]+)?/_ping$
    acl safe_version path,url_dec -m reg -i ^(/v[0-9.]+)?/version$
    acl docker_container_path path,url_dec -m reg -i ^(/v[0-9.]+)?/containers/
    # ui/netdata/syslog (issue #842/#849): added to the master
    # allowlist and to safe_container_inspect. watchdog's Rust rewrite
    # monitors all three for dashboard visibility (alert-only, see
    # services/watchdog/src/main.rs's resolve_alert_only_targets()) and never
    # restarts any of them itself.
    # UPDATED (issue #1486): ui now ALSO gets its own narrow restart-only
    # grant (safe_ui_restart below) for the Admin UI's own self-restart
    # control -- restart-only (never start/stop, see safe_ui_restart's own
    # comment) so this path can never be used to leave the UI stopped.
    # netdata and syslog still get no restart grant at all, and watchdog
    # itself is not even in this allowlist (mirrors how
    # lancache-dhcp/lancache-dhcp-proxy have inspect access without a
    # restart grant -- see safe_dhcp_action below for why those two use
    # start/stop instead). This distinction -- ui restartable,
    # watchdog/syslog never restartable/stoppable/startable via the Admin UI
    # under any circumstance -- is this issue's own explicit, load-bearing
    # requirement: watchdog is the mechanism that notices and recovers other
    # services, so no UI control may ever be able to disable it.
    # UPDATED (syslog+fluent-bit consolidation PR, 2026-08, merged
    # concurrently with #842/#849 which originally added BOTH
    # lancache-syslog and lancache-syslog-ng here as two separate entries):
    # syslog (fluent-bit) and syslog-ng are now one combined container under
    # the single name lancache-syslog -- lancache-syslog-ng removed from both
    # regexes below rather than left as permanently-unmatchable dead weight,
    # since no compose file will ever start a container by that name again.
    acl lancache_container path,url_dec -m reg -i ^(/v[0-9.]+)?/containers/(lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-dhcp|lancache-dhcp-proxy|lancache-dhcp-probe|lancache-nats|lancache-ntp|lancache-ui|lancache-netdata|lancache-syslog)(/|$)
    acl safe_container_inspect path,url_dec -m reg -i ^(/v[0-9.]+)?/containers/(lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-dhcp|lancache-dhcp-proxy|lancache-dhcp-probe|lancache-nats|lancache-ntp|lancache-ui|lancache-netdata|lancache-syslog)/json$
    acl safe_container_logs path,url_dec -m reg -i ^(/v[0-9.]+)?/containers/lancache-dhcp-probe/logs$
    acl safe_service_restart path,url_dec -m reg -i ^(/v[0-9.]+)?/containers/(lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-nats)/restart$
    acl safe_dhcp_action path,url_dec -m reg -i ^(/v[0-9.]+)?/containers/(lancache-dhcp|lancache-dhcp-proxy)/(start|stop)$
    # LanCache-NG-NTP enable/disable toggle (Admin UI's ntp.rs): same
    # start/stop-only shape as safe_dhcp_action, kept as its own rule rather
    # than folded into that one so build-push.yml's exact-literal check on
    # safe_dhcp_action's regex (see its "socket_proxy_script" step) never has
    # to change when this service's allowlist entry changes independently.
    acl safe_ntp_action path,url_dec -m reg -i ^(/v[0-9.]+)?/containers/lancache-ntp/(start|stop)$
    acl safe_probe_action path,url_dec -m reg -i ^(/v[0-9.]+)?/containers/lancache-dhcp-probe/(start|stop|wait)$
    # Admin UI self-restart (issue #1486): restart-only, scoped to exactly
    # this one container name -- deliberately its own acl (same rationale as
    # safe_ntp_action above) rather than folded into safe_service_restart, so
    # build-push.yml's exact-literal check on that acl's regex never has to
    # change when this grant changes independently. restart-only (never
    # start/stop) means this path can never be used to leave the UI stopped,
    # unlike safe_dhcp_action/safe_ntp_action's start/stop shape, which is
    # the correct shape for a service the operator may deliberately disable.
    acl safe_ui_restart path,url_dec -m reg -i ^(/v[0-9.]+)?/containers/lancache-ui/restart$
    http-request allow if safe_get safe_ping
    http-request allow if safe_head safe_ping
    http-request allow if safe_get safe_version
    http-request allow if safe_get safe_container_inspect
    http-request allow if safe_get safe_container_logs
    http-request allow if safe_post safe_service_restart
    http-request allow if safe_post safe_dhcp_action
    http-request allow if safe_post safe_ntp_action
    http-request allow if safe_post safe_probe_action
    http-request allow if safe_post safe_ui_restart
    http-request deny if docker_container_path !lancache_container
    http-request deny
    default_backend dockerbackend
EOF

# Issue #1415: LANCACHE_CONTAINER_SUFFIX (default empty; only ever set by CI
# -- see deploy/quickstart/docker-compose.yml's own top-of-file comment for
# why) widens the allowlist generated above, at container startup, to also
# accept THIS run's actual suffixed container names. This only ever touches
# the GENERATED /tmp file below, never this script's own checked-in source
# text above: build-push.yml's "socket_proxy_script" step and
# scripts/tracked/check-naming-consistency.sh both grep this script's static source
# for the exact literal fixed names, so leaving that text untouched keeps
# both checks passing unchanged regardless of whether a suffix is active.
LANCACHE_CONTAINER_SUFFIX="${LANCACHE_CONTAINER_SUFFIX:-}"
if [ -n "$LANCACHE_CONTAINER_SUFFIX" ]; then
    # Fail closed (AG-OP-008/AG-VAL-002): reject anything but a plain
    # alphanumeric/hyphen token before it ever reaches a sed replacement
    # string -- an unexpected value here must not be able to inject sed or
    # HAProxy regex metacharacters into the generated allowlist.
    case "$LANCACHE_CONTAINER_SUFFIX" in
        *[!A-Za-z0-9-]*)
            echo "FATAL: LANCACHE_CONTAINER_SUFFIX='$LANCACHE_CONTAINER_SUFFIX' contains characters other than [A-Za-z0-9-]; refusing to generate a socket-proxy allowlist that could be corrupted by it." >&2
            exit 1
            ;;
    esac
    # Each pattern below is anchored with a trailing \([^-]\) capture, so a
    # shorter name (e.g. lancache-dhcp) can never match inside a longer one
    # that starts with it (e.g. lancache-dhcp-proxy): the character right
    # after "dhcp" there is a literal "-", which [^-] rejects. This makes
    # every substitution mutually exclusive by construction, so the order
    # below (kept longest-first for readability only) does not affect
    # correctness. Covers every one of the 11 names the allowlist's own acl
    # lines above reference; watchdog/docker-socket-proxy/retention are
    # deliberately absent, matching the allowlist's own documented scope.
    sed -i \
        -e "s/lancache-dhcp-proxy\([^-]\)/lancache-dhcp-proxy${LANCACHE_CONTAINER_SUFFIX}\1/g" \
        -e "s/lancache-dhcp-probe\([^-]\)/lancache-dhcp-probe${LANCACHE_CONTAINER_SUFFIX}\1/g" \
        -e "s/lancache-dhcp\([^-]\)/lancache-dhcp${LANCACHE_CONTAINER_SUFFIX}\1/g" \
        -e "s/lancache-dns-standard\([^-]\)/lancache-dns-standard${LANCACHE_CONTAINER_SUFFIX}\1/g" \
        -e "s/lancache-dns-ssl\([^-]\)/lancache-dns-ssl${LANCACHE_CONTAINER_SUFFIX}\1/g" \
        -e "s/lancache-proxy\([^-]\)/lancache-proxy${LANCACHE_CONTAINER_SUFFIX}\1/g" \
        -e "s/lancache-nats\([^-]\)/lancache-nats${LANCACHE_CONTAINER_SUFFIX}\1/g" \
        -e "s/lancache-ntp\([^-]\)/lancache-ntp${LANCACHE_CONTAINER_SUFFIX}\1/g" \
        -e "s/lancache-ui\([^-]\)/lancache-ui${LANCACHE_CONTAINER_SUFFIX}\1/g" \
        -e "s/lancache-netdata\([^-]\)/lancache-netdata${LANCACHE_CONTAINER_SUFFIX}\1/g" \
        -e "s/lancache-syslog\([^-]\)/lancache-syslog${LANCACHE_CONTAINER_SUFFIX}\1/g" \
        /tmp/lancache-haproxy.cfg
fi

exec haproxy -f /tmp/lancache-haproxy.cfg
