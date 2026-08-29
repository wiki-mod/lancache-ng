
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# First-party build of the `netdata` service, replacing the previously
# pulled third-party `netdata/netdata` Docker image (Debian trixie based).
# netdata does not publish (and per its own
# packaging/PLATFORM_SUPPORT.md, has never published) an Alpine-based
# Docker image -- this Dockerfile instead installs netdata's own
# officially-supported static musl release asset (a self-extracting
# `.gz.run` package netdata itself builds "in an Alpine Linux environment
# using musl", per that same upstream doc) directly on top of a plain
# Alpine base. This sidesteps the Debian-base-image findings tracked in
# issue #815 Part C for this service entirely, and -- unlike the previous
# image -- lets Trivy see this service via the same per-service Dockerfile
# build/scan path every other first-party service already goes through.
#
# Known, checked, and confirmed-inapplicable static-build limitations (see
# upstream packaging/PLATFORM_SUPPORT.md): no systemd integration (Alpine
# has no systemd anyway; irrelevant here), no IPMI hardware-sensor
# monitoring and no eBPF-related capabilities (this deployment configures
# neither -- confirmed by grep across deploy/prod/docker-compose.yml and
# docs/architecture-ng.md, no `ipmi`/`ebpf` references anywhere), and
# "generally do not support non-local username mappings or exotic name
# resolution configurations" (this deployment's collectors are all
# local-only: /proc, /sys, the Docker socket, and a bind-mounted log file
# -- no LDAP/NIS/sssd or unusual DNS setup anywhere in this stack).
#
FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.description="First-party Alpine + netdata's official static musl build, replacing the pulled third-party netdata/netdata (Debian) image."

# What: curl 8.20.0 bundled in netdata static build
# Why: Trivy cannot detect curl; check-netdata-curl-pin enforces
# From: Issue #1304 | PR #1662
ARG NETDATA_VERSION=v2.11.0
ARG NETDATA_X86_64_SHA256=b42d9937807f28812502a967906d370cff9ab443453813656b99ff6a9b3c5649

# `bash` is required at build time because netdata's own installer script
# (packaging/makeself/install-or-update.sh, run by the extracted .gz.run
# package) has a `#!/usr/bin/env bash` shebang, and is kept at runtime
# because several of netdata's own bundled plugins.d helper scripts are
# bash, not POSIX sh -- most relevantly cgroup-name.sh, which this
# deployment's Docker-socket mount (see deploy/prod/docker-compose.yml)
# uses to resolve human-readable container names for per-container cgroup
# metrics; alarm-notify.sh (bash) would also need it if health
# notifications are ever configured. `ca-certificates` is required because
# Alpine's base image ships none by default (confirmed empirically:
# /etc/ssl/certs is empty on a stock alpine:3.24 image), and this
# deployment leaves NETDATA_CERT_MODE at the installer's "check" default,
# which validates against the real system trust store rather than
# skipping validation.
RUN set -eu; \
    apk add --no-cache bash ca-certificates; \
    wget -q -O /tmp/netdata.gz.run \
      "https://github.com/netdata/netdata/releases/download/${NETDATA_VERSION}/netdata-x86_64-${NETDATA_VERSION}.gz.run"; \
    echo "${NETDATA_X86_64_SHA256}  /tmp/netdata.gz.run" | sha256sum -c -; \
    chmod +x /tmp/netdata.gz.run; \
    # --dont-start-it: this is a Docker build, not a running system --
    # netdata is started by this image's own entrypoint.sh at container
    # start, not by the installer. --disable-telemetry: no anonymous
    # usage statistics. --stable-channel: pin to netdata's stable release
    # channel rather than its nightly channel, matching this project's
    # own "pull only pinned/stable references" posture (Rule-Ref:
    # AG-CI-009/AG-VAL-026).
    /tmp/netdata.gz.run --accept -- --dont-start-it --disable-telemetry --stable-channel; \
    rm -f /tmp/netdata.gz.run; \
    rm -rf /tmp/netdata-updater* /tmp/netdata-installer*

EXPOSE 19999

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
