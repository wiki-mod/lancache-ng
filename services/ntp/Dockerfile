# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# LanCache-NG-NTP image: chrony (chronyd) disciplining its own clock against
# a curated set of public NTP servers and serving that time to LAN clients
# on UDP/123. No Rust builder stage is needed here (unlike services/dns/ or
# services/ui/) -- this image is a plain package install plus a shell
# entrypoint, the same shape as services/dhcp/Dockerfile.

FROM mirror.gcr.io/library/debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2

LABEL org.opencontainers.image.description="LanCache-NG-NTP: chrony-based NTP server, disciplined against public NTP servers, serving LAN clients on UDP/123."

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    chrony \
    gettext-base \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY chrony.conf /etc/chrony/chrony.conf.template
COPY entrypoint.sh /entrypoint.sh

# chronyd runs as root in this container (no `-u`/privilege drop): it needs
# CAP_SYS_TIME to actually step/slew the container HOST's real system clock
# (containers share one kernel clock -- there is no per-container clock
# namespace), and Docker's default capability bounding set excludes
# CAP_SYS_TIME regardless of any file capability the Debian package may set
# on the binary. Running as root sidesteps relying on those file
# capabilities surviving into the container's bounding set; the compose
# files grant `cap_add: [SYS_TIME]` on top of that (see their comments for
# the host-wide-clock operational tradeoff this implies).
RUN chmod +x /entrypoint.sh \
    && mkdir -p /var/lib/chrony /var/log/chrony

EXPOSE 123/udp

ENTRYPOINT ["/entrypoint.sh"]
