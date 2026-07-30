# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Runtime health-check and recovery service for lancache-ng containers.

FROM mirror.gcr.io/library/debian:13-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2

LABEL org.opencontainers.image.description="lancache-ng watchdog helper for runtime health checks and recovery hooks."

# trixie-backports is the standard package source for this image (maintainer
# decision, 2026-07-30) -- not scoped to curl or any other single package:
# `Package: *` at Pin-Priority 500 (tied with the regular trixie archive)
# applies project-wide to every Debian-based image, so ordinary
# version-comparison rules pick whichever archive has the newer version for
# ANY package this image installs, not just one of them. `apt-get
# dist-upgrade` then `apt-get full-upgrade` are both run deliberately (a
# maintainer decision to keep both explicit, even though modern apt treats
# `full-upgrade` as the same operation `dist-upgrade` performs) so any
# package backports has already patched gets picked up on every rebuild.
# See services/proxy/Dockerfile's identical pin block for the full
# rationale and incident history this was copied from.
#
# The pin selector below MUST use `a=stable-backports`, not
# `a=trixie-backports`: APT's `a=`/release-Archive selector matches the
# Release file's `Suite:` field, and trixie-backports' own Release file
# declares `Suite: stable-backports` / `Codename: trixie-backports` -- the
# two are not interchangeable. Using the wrong one means the pin silently
# never matches anything and every "backports-sourced" package stays on
# the plain-trixie version despite the pin file being present -- this was
# caught in services/proxy/Dockerfile only by building the image for real
# and checking installed package versions, not by reading the Dockerfile
# (see issue #1304 / #1298).
#
# Verified via a real rebuild on lancache-240 (2026-07-30): `apt-cache
# madison` for every package this Dockerfile installs (curl, jq,
# ca-certificates, nano, lsof, ripgrep, zstd) shows curl is the ONLY one
# of the seven with a trixie-backports candidate at all
# (8.21.0-2~bpo13+1 vs plain trixie's 8.14.1-2+deb13u4); the other six
# have no backports build in this snapshot and correctly stayed on their
# plain-trixie version. `dpkg -l` in the built image confirms curl is the
# only package actually carrying a `~bpo13+1` suffix -- the pin is
# working as intended (whichever archive has the newer version wins for
# a given package, not "backports always wins" for every package).
#
# A real before/after Trivy HIGH/CRITICAL scan of this image (same
# command as this project's CI: `docker run --rm -v
# /var/run/docker.sock:/var/run/docker.sock -v
# trivy-cache:/root/.cache/ aquasec/trivy:latest image ...`) found the
# EXACT SAME 37 findings (33 HIGH, 4 CRITICAL) before and after this
# change -- a byte-for-byte identical (package, CVE-ID, severity) set,
# zero fixed, zero newly introduced. The 7 curl/libcurl4t64 CVEs
# (CVE-2026-12064, -8286, -8927, -8932, -9079, -9080, -9545) are the same
# unfixed-upstream findings services/proxy/Dockerfile's issue #1304
# already tracks for curl specifically; the remaining 30 findings
# (util-linux family CVE-2026-53615, gzip, libacl1, the ncurses/perl-base
# baseline findings) are pre-existing `debian:13-slim` base-image issues
# with no fix in either archive, matching the pattern issue #1298 already
# tracks. Do not assume a version bump always reduces a Trivy finding
# count without re-checking -- it did not here, for any of this image's
# seven installed packages.
RUN echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/backports.list \
    && printf 'Package: *\nPin: release a=stable-backports\nPin-Priority: 500\n' > /etc/apt/preferences.d/backports \
    && apt-get update \
    && apt-get dist-upgrade -y \
    && apt-get full-upgrade -y \
    && apt-get install -y --no-install-recommends \
    curl jq ca-certificates nano lsof ripgrep zstd \
    && rm -rf /var/lib/apt/lists/*
# nano/lsof/ripgrep: in-container troubleshooting tools -- see
# services/proxy/Dockerfile's identical comment for the full rationale.
# zstd (#1236): maybe_rotate_fluent_bit_selflog() compresses rotated
# fluent-bit self-log backups with it, matching the compression tool the
# syslog-ng service already uses for its own rotation loop (see
# deploy/*/docker-compose.yml). Installed at build time here rather than
# syslog-ng's runtime `apt-get install` pattern: that pattern exists there
# because syslog-ng's official image can't be given a custom Dockerfile,
# while this project owns this Dockerfile directly, so a guaranteed
# build-time install is simpler and doesn't depend on network egress at
# container start.
ENV EDITOR=nano
ENV VISUAL=$EDITOR
COPY watchdog.sh /watchdog.sh
COPY healthcheck.sh /healthcheck.sh
RUN chmod +x /watchdog.sh /healthcheck.sh
VOLUME ["/var/run/watchdog"]
ENTRYPOINT ["/watchdog.sh"]
