#!/bin/sh
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
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
    acl lancache_container path,url_dec -m reg -i ^(/v[0-9.]+)?/containers/(lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-dhcp|lancache-dhcp-proxy|lancache-dhcp-probe|lancache-nats|lancache-ntp)(/|$)
    acl safe_container_inspect path,url_dec -m reg -i ^(/v[0-9.]+)?/containers/(lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-dhcp|lancache-dhcp-proxy|lancache-dhcp-probe|lancache-nats|lancache-ntp)/json$
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
    http-request allow if safe_get safe_ping
    http-request allow if safe_head safe_ping
    http-request allow if safe_get safe_version
    http-request allow if safe_get safe_container_inspect
    http-request allow if safe_get safe_container_logs
    http-request allow if safe_post safe_service_restart
    http-request allow if safe_post safe_dhcp_action
    http-request allow if safe_post safe_ntp_action
    http-request allow if safe_post safe_probe_action
    http-request deny if docker_container_path !lancache_container
    http-request deny
    default_backend dockerbackend
EOF

exec haproxy -f /tmp/lancache-haproxy.cfg
