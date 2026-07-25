# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Kea DHCP image: DHCPv4 server, control agent (API on :8000), and DHCP-DDNS
# service for lancache-ng managed networks.
#
# Alpine base (issue #815, staged Alpine migration, Kea second): no builder
# stage or compiled binary here either, so this is also an apt->apk package
# swap, pinned to Alpine's kea 3.0.3 LTS line (matching Debian trixie's own
# 2.6.3 -> next-LTS direction; Alpine tracks the upstream 3.0.x LTS branch
# through June 2028). One real, non-obvious packaging difference from
# Debian found and verified here: Debian's kea-dhcp4-server package bundles
# every hook library (including libdhcp_lease_cmds.so) directly, but
# Alpine's aports split each Kea hook into its own separate package
# (`kea-hook-<name>`) -- `kea-dhcp4` alone does NOT ship
# /usr/lib/kea/hooks/libdhcp_lease_cmds.so; the dedicated `kea-hook-lease-cmds`
# package is required too, or entrypoint.sh's fail-closed
# `find /usr/lib -maxdepth 5 -name libdhcp_lease_cmds.so` check (needed for
# lease4-del, used by the Admin UI's release-lease route) exits 1 at
# startup. `bash` is installed explicitly for the same reason as
# services/dhcp-proxy/Dockerfile: entrypoint.sh uses real Bash-only syntax
# Alpine's default ash shell does not support. `envsubst` ships in the
# separate `gettext-envsubst` package here too, same as dhcp-proxy.

FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.description="Kea DHCP, control-agent, and DHCP-DDNS service for lancache-ng managed networks."

RUN apk add --no-cache \
    kea-dhcp4 \
    kea-ctrl-agent \
    kea-dhcp-ddns \
    kea-admin \
    kea-hook-lease-cmds \
    bash \
    nmap \
    gettext-envsubst \
    openssl \
    curl \
    jq \
    iptables \
    nano \
    lsof \
    ripgrep

# nano/lsof/ripgrep: in-container troubleshooting tools -- see
# services/proxy/Dockerfile's identical comment for the full rationale.
ENV EDITOR=nano
ENV VISUAL=$EDITOR

# Config templates — expanded once into /var/lib/kea/ on first boot
COPY kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.template
COPY kea-ctrl-agent.conf /etc/kea/kea-ctrl-agent.conf.template
COPY kea-dhcp-ddns.conf /etc/kea/kea-dhcp-ddns.conf.template
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && mkdir -p /var/lib/kea && install -d -m 750 /run/kea

EXPOSE 67/udp 8000

ENTRYPOINT ["/entrypoint.sh"]
