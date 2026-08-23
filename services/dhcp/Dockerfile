
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
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
#
# Alpine analogue of the project-wide Debian trixie-backports + dist-upgrade
# policy (2026-07-30, maintainer decision): plain `apk add --no-cache` does
# implicitly fetch a fresh package index each time (no persistent index
# cache is left in the image layer, unlike a bare `apt-get install` without
# a preceding `apt-get update`), so newly-added packages here already land
# on a reasonably current version. But it does NOT touch packages already
# baked into the alpine:3.24 base image layer itself (musl, busybox,
# apk-tools, ...) -- those stay frozen at whatever version the pinned base
# digest shipped with unless an explicit `apk upgrade` runs. Alpine has no
# backports equivalent to Debian's (security fixes land in-place within the
# current release branch's own repo, closer to Ubuntu's model), so the fix
# is narrower than the Debian side: `apk update && apk upgrade` before the
# package install, in the same layer so it costs no extra image size.
# Verified for real on a pinned alpine:3.24 pull (2026-07-30): `apk-tools`/
# `libapk` were baked in at 3.0.6-r0 but 3.0.7-r0 was already available in
# the branch's own repo -- `apk upgrade --no-cache` picked it up
# immediately, while a plain `apk add --no-cache <pkg>` with no preceding
# upgrade step would have left the stale 3.0.6-r0 in place indefinitely.
# `--no-cache` on `update`/`upgrade` mirrors the same flag already used on
# `add` below: it keeps the fetched index out of `/var/cache/apk` instead
# of leaving a persistent cache in the image layer.
#
# `findutils` (issue #840, found while validating a later, unrelated Alpine
# migration for services/watchdog -- PR #1346): this Dockerfile's original
# Alpine migration (this PR) omitted it, and entrypoint.sh's own
# `list_kea_snapshot_ids()` (used by the Kea config-validation-rollback path,
# #763/docs/known-good-config-snapshots.md) uses `find ... -printf '%f\n'`
# to sort known-good snapshot ids by name. Confirmed live on a real
# `alpine:3.24` container: BusyBox's bundled `find` does not support the
# GNU-findutils-only `-printf` action at all ("find: unrecognized:
# -printf"), fails with exit 1, and writes that error to stderr -- which the
# function's own `2>/dev/null` silently swallows, leaving `sort` with empty
# input and the function silently returning an empty snapshot list
# (indistinguishable from "no snapshots exist yet"). `apk add findutils`
# installs GNU `find`/`xargs` at `/usr/bin/find`, ahead of BusyBox's own
# `find` applet earlier in `$PATH` -- the same fix already verified and
# shipped for `services/watchdog` (PR #1346): `findutils`, not `coreutils`,
# since `find` is a GNU findutils binary, not a GNU coreutils one. This
# Dockerfile's other `find` call (`KEA_LEASE_CMDS_HOOK_PATH`'s
# `find /usr/lib -maxdepth 5 -name libdhcp_lease_cmds.so` fail-closed check,
# documented above) was never broken by BusyBox -- it only uses portable
# `-maxdepth`/`-name` actions, no `-printf` -- and is unaffected by this
# change: confirmed on the real built image that it still resolves the
# real hook path with GNU `find` now ahead of BusyBox's own in `$PATH`.

# What: source stage for tools copied into the final image below.
# Why: pinned by digest (not a mutable tag) for a reproducible build -- see
#   services/proxy/Dockerfile's identical stage comment for the full
#   digest-resolution rationale.
# From: Issue #1556
FROM ghcr.io/wiki-mod/lancache-ng/utilities@sha256:718af4cf8f1352cee341e851cecb9821033de9a5c7804c64e1c6217b62c79186 AS utilities-tools

FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.description="Kea DHCP, control-agent, and DHCP-DDNS service for lancache-ng managed networks."

# What: curl/findutils/envsubst/lsof/ripgrep come from the shared utilities image.
# Why: same alpine:3.24 digest as utilities, safe binary-compatible swap; jq
#   stays apk-installed (own private libjq.so.1/libonig.so.5, one caller only).
# From: Issue #1556

# What: removes the BusyBox symlinks at these paths before real binaries land.
# Why: see services/proxy/Dockerfile's identical comment for the reason.
# From: Issue #1556
RUN rm -f /usr/bin/find /usr/bin/xargs /usr/bin/lsof

COPY --from=utilities-tools /usr/local/bin/curl /usr/local/bin/curl
COPY --from=utilities-tools /usr/bin/find /usr/bin/find
COPY --from=utilities-tools /usr/bin/xargs /usr/bin/xargs
COPY --from=utilities-tools /usr/bin/envsubst /usr/bin/envsubst
COPY --from=utilities-tools /usr/lib/libintl.so.8 /usr/lib/libintl.so.8
COPY --from=utilities-tools /usr/bin/lsof /usr/bin/lsof
COPY --from=utilities-tools /usr/bin/rg /usr/bin/rg
COPY --from=utilities-tools /usr/lib/libgcc_s.so.1 /usr/lib/libgcc_s.so.1
COPY --from=utilities-tools /usr/lib/libpcre2-8.so.0* /usr/lib/
COPY --from=utilities-tools /usr/local/bin/verify-version-banner.sh /usr/local/bin/verify-version-banner.sh

# What: verifies the copied binaries actually run, not just that they exist.
# Why: a missing shared-library dependency fails at exec time, not at COPY
#   time; the lsof check is delegated to a shared script (see that file).
# From: Issue #1613
RUN set -euo pipefail; \
    find . -maxdepth 0 -printf '%f\n' >/dev/null; \
    printf '%s' '$FOO' | FOO=bar envsubst >/dev/null; \
    rg --version >/dev/null; \
    curl --version >/dev/null; \
    sh /usr/local/bin/verify-version-banner.sh "lsof version information" lsof -v

RUN apk update --no-cache && apk upgrade --no-cache && apk add --no-cache \
    kea-dhcp4 \
    kea-ctrl-agent \
    kea-dhcp-ddns \
    kea-admin \
    kea-hook-lease-cmds \
    bash \
    nmap \
    openssl \
    jq \
    iptables \
    nano

# nano: in-container troubleshooting tool -- see services/proxy/Dockerfile's
# identical comment for the full rationale; lsof/ripgrep are COPY'd above
# but serve the same troubleshooting purpose.
ENV EDITOR=nano
ENV VISUAL=$EDITOR

# Config templates — expanded once into /var/lib/kea/ on first boot
COPY kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.template
COPY kea-ctrl-agent.conf /etc/kea/kea-ctrl-agent.conf.template
COPY kea-dhcp-ddns.conf /etc/kea/kea-dhcp-ddns.conf.template
COPY entrypoint.sh /entrypoint.sh

# /run/kea holds Kea's unix-domain control-channel sockets (kea4.sock,
# kea-ddns.sock, per the *.conf "socket-name" entries above) -- mode 750
# (owner rwx, group rx, no world access) keeps that directory readable only
# to root and its own group, since these sockets are container-internal
# control channels, not something any other local user needs to reach.
RUN chmod +x /entrypoint.sh && mkdir -p /var/lib/kea && install -d -m 750 /run/kea

EXPOSE 67/udp 8000

ENTRYPOINT ["/entrypoint.sh"]
