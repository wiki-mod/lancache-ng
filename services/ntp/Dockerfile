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

# trixie-backports is the standard package source for this image (maintainer
# decision, 2026-07-30) -- project-wide, not scoped to any one package here:
# `Package: *` at Pin-Priority 500 (tied with the regular trixie archive)
# means ordinary version-comparison rules pick whichever archive has the
# newer version for ANY package this image installs, not a hand-picked
# subset. `apt-get dist-upgrade` then `apt-get full-upgrade` are both run
# deliberately (kept as two explicit calls even though modern apt treats
# `full-upgrade` as the same operation `dist-upgrade` performs) so any
# package backports has already patched gets picked up on every rebuild, not
# only the packages named in the install list below.
#
# The pin selector below MUST use `a=stable-backports`, not
# `a=trixie-backports`: APT's `a=`/release-Archive selector matches the
# Release file's `Suite:` field, and trixie-backports' own Release file
# declares `Suite: stable-backports` / `Codename: trixie-backports` -- the
# two are not interchangeable (see services/proxy/Dockerfile's matching
# comment: a first version of this pin used `a=trixie-backports` and
# silently never matched anything, so every "backports-sourced" package
# stayed on the vulnerable plain-trixie version despite the pin file being
# present -- caught only by building the image for real and checking the
# installed package versions, not by trusting the Dockerfile comment).
RUN echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/backports.list \
    && printf 'Package: *\nPin: release a=stable-backports\nPin-Priority: 500\n' > /etc/apt/preferences.d/backports \
    && apt-get update \
    && apt-get dist-upgrade -y \
    && apt-get full-upgrade -y \
    && apt-get install -y --no-install-recommends \
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
