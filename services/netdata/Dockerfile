# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# First-party build of the `netdata` service, replacing the previously
# pulled third-party `netdata/netdata` Docker image (Debian trixie based,
# see issue #1304). netdata does not publish (and per its own
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
# IMPORTANT, found during this migration's own evaluation (2026-07-31), not
# hidden: netdata's static build statically links its own vendored curl
# build (confirmed via `ldd` -- the netdata binary itself is "not a dynamic
# program", and CFLAGS in the installed .environment file show
# `-I/curl-local/include/curl`, i.e. curl is compiled from source and
# baked directly into the netdata binary, not linked against a distro
# package). The vendored curl identifies itself as `8.17.0-DEV`, which
# falls inside the affected range curl's own upstream advisories give for
# all 7 CVE IDs issue #1304 tracks (each states "Affected versions: ...
# and including 8.20.0", "Not affected versions: ... >= 8.21.0" --
# verified directly against curl.se's own per-CVE pages, not inferred).
# Migrating to this image makes those 7 CVE IDs disappear from a Trivy
# scan, but NOT because the underlying vendored curl code is patched --
# it disappears because Trivy's os-pkg scanner has no visibility into
# code statically compiled into a binary outside any package manager's
# record. This is a real, load-bearing distinction for whoever reviews
# this PR's Trivy evidence: "0 findings" here means "invisible to this
# scanner", not "confirmed fixed", and that nuance is the maintainer's to
# weigh against this migration's other real benefits (eliminates 2
# netdata-specific already-upstream-fixed-elsewhere curl CVEs the old
# pinned Debian package still carried, eliminates issue #815 Part C's 5
# baseline Debian package-group findings for this service, smaller image).

FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.description="First-party Alpine + netdata's official static musl build, replacing the pulled third-party netdata/netdata (Debian) image."

# Intentional ARG default, matching this project's existing pattern for
# release/tool references (e.g. services/ui/Dockerfile's BUILD_TOOLS_IMAGE
# ARG): overridable at build time via --build-arg, not itself the pin.
# The real pin is NETDATA_X86_64_SHA256 below -- a content hash, not a
# mutable tag -- verified against a real download of this exact asset on
# self-hosted runner lancache-241 on 2026-07-31 before being written here.
ARG NETDATA_VERSION=v2.10.4
ARG NETDATA_X86_64_SHA256=9c5c06a9ff4949e0aad9fc894ba4649146ed213b558200cd050e4a52f5dedf40

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
