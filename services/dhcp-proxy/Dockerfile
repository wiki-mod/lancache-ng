# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# dnsmasq-based DHCP proxy/relay image. Runs alongside an existing DHCP
# server in dnsmasq's "proxy" mode, overriding only DNS options for clients
# (mutually exclusive with the Kea DHCP mode in services/dhcp).
#
# Alpine base (issue #815, staged Alpine migration, dnsmasq-first): this
# service has no builder stage and no compiled binary, so the migration is a
# straightforward apt->apk package swap. Confirmed on Alpine 3.24: dnsmasq
# 2.92_p2-r0 (vs. Debian trixie's 2.91), no known musl-specific dnsmasq
# issues (dnsmasq implements its own UDP/TCP packet handling, it does not
# route DHCP/DNS serving through musl's client-side resolver). `bash` is
# installed explicitly because entrypoint.sh uses real Bash-only syntax
# (arrays, C-style `for ((...))` loops, `${var//pat/repl}`) that Alpine's
# default `/bin/sh` (busybox ash) does not support -- see AG-REL-006.
# `envsubst` ships in the separate `gettext-envsubst` sub-package on this
# Alpine version, not the base `gettext` package (verified: `apk info
# gettext-envsubst` on alpine:3.24).

FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.description="dnsmasq-based DHCP proxy and relay helper for lancache-ng deployments."

RUN apk add --no-cache \
    bash \
    dnsmasq \
    gettext-envsubst \
    nano \
    lsof \
    ripgrep

# nano/lsof/ripgrep: in-container troubleshooting tools -- see
# services/proxy/Dockerfile's identical comment for the full rationale.
ENV EDITOR=nano
ENV VISUAL=$EDITOR

COPY dnsmasq.conf.template /etc/dnsmasq.conf.template
COPY dnsmasq-relay.conf.template /etc/dnsmasq-relay.conf.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 67/udp

ENTRYPOINT ["/entrypoint.sh"]
