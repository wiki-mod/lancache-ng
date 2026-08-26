
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# nginx-based caching proxy image: unified standard (SNI passthrough) and
# SSL/MITM (TLS-interception) mode, selected at runtime by entrypoint.sh.
# Installs nginx from nginx.org's own mainline apk repo (not Alpine's own
# `nginx` distro package, which lags a minor version behind). nginx.org's
# own package compiles the stream module (used by standard mode's SNI
# passthrough, see nginx.conf's `stream {}` block) in statically -- no
# separate module package and no `load_module` directive are needed, on
# Alpine exactly as on the prior Debian base; see AGENTS.md's "Key Design
# Decisions" (AG-KD-007) for the full explanation.
#
# Alpine base (issue #815 Part B, staged Alpine migration for
# proxy/ntp/watchdog/ui -- proxy picked up after ntp/dhcp/dhcp-proxy/dns/
# watchdog had already landed). Confirmed live (2026-08-06) against a real
# alpine:3.24 container: nginx.org publishes a full apk repository at
# https://nginx.org/packages/{mainline,stable}/alpine/v<ver>/main with
# identical version currency to its Debian apt repo (both mainline 1.31.3
# at the time of this migration) -- `apk add nginx` after adding that repo
# and its signing key resolves to `nginx/1.31.3-r1`, and `nginx -V` shows
# `--with-stream --with-stream_ssl_preread_module` compiled in statically,
# matching the Debian package exactly.
#
# What: source stage for tools copied from the shared utilities image below.
# Why: pinned by digest (not a mutable tag) so this build is reproducible;
#   the digest is the `nightly` channel's manifest-list at the time of this
#   change, resolved manually since consuming this image has no CI-side
#   digest-resolution wiring (unlike BUILD_TOOLS_IMAGE).
# From: Issue #1556
FROM ghcr.io/wiki-mod/lancache-ng/utilities@sha256:718af4cf8f1352cee341e851cecb9821033de9a5c7804c64e1c6217b62c79186 AS utilities-tools

FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.description="nginx-based lancache-ng caching proxy for standard and TLS-interception cache traffic."

# `apk upgrade --no-cache` (before the package installs, same layer)
# upgrades packages already baked into the alpine:3.24 base layer itself --
# see services/dhcp-proxy/Dockerfile's matching comment for the fuller
# rationale and live verification of this behavior.
#
# nginx.org's own Alpine apk repo is added the same way its own official
# Docker images do it: fetch the RSA public key it signs its packages with
# (https://nginx.org/keys/nginx_signing.rsa.pub -- a different key format
# than the apt/gpg key the prior Debian stage used, but the same nginx.org
# signing identity), then append a `@nginx`-tagged repository line pointing
# at this Alpine version's mainline channel. The `@nginx` tag namespaces the
# repo so `apk add nginx@nginx` explicitly resolves from it rather than
# whatever plain `nginx` a future Alpine base version's own main/community
# repos might also carry, keeping this pin unambiguous even if Alpine's own
# distro nginx package version ever happens to converge with nginx.org's.
#
# Package translations from the Debian stage (confirmed live against a real
# alpine:3.24 container, 2026-08-06):
#   - gettext-base -> gettext-envsubst: Alpine splits envsubst out of the
#     base gettext package, matching every other already-migrated service.
#   - locales/locale-gen/LANG=en_US.UTF-8 dropped entirely, not replaced:
#     grepped entrypoint.sh, nginx.conf, proxy-params.conf, and conf.d/* for
#     any LANG/LC_ALL/locale dependency -- none found. musl has no
#     glibc-style locale-data system, and nothing this service actually does
#     (nginx access/error log output, entrypoint.sh's own `sort`/string
#     handling) depends on real glibc locale collation, so this block is
#     purely cosmetic and safely droppable, per #815's own explicit
#     instruction to check before assuming a substitute is needed.
#   - findutils added: entrypoint.sh's kgs_list_snapshots() calls
#     `find ... -printf '%f\n'`, a GNU-find-only flag BusyBox's own `find`
#     applet does not support at all (confirmed live: `find: unrecognized:
#     -printf`) -- the same BusyBox gap already hit and fixed for
#     services/watchdog (#1346), services/dhcp/dhcp-proxy (#1347), and
#     services/dns (#1425). Installing findutils (GNU find) fixes it with
#     zero script changes.
#   - coreutils added: BusyBox's own `date` applet silently produces an
#     EMPTY nanosecond field for `date +%N` instead of erroring (confirmed
#     live: real output was `20260806T120718.` -- a trailing dot with
#     nothing after it), used both by kgs_new_snapshot_id() (snapshot-id
#     uniqueness) and the CA serial-file first-init seed. Installing
#     coreutils (GNU date) fixes both with zero script changes; also makes
#     basename/dirname/sort consistently GNU-flavored (BusyBox's own
#     versions of those already behaved correctly in this file's actual
#     usage, verified live, so this is precautionary consistency rather
#     than a second confirmed bug -- see this service's PR body for the
#     full per-construct verification evidence).
#   - bash added: entrypoint.sh's own `#!/bin/bash` shebang plus its use of
#     `local`, indexed/associative arrays, `[[ ... ]]`, nameref parameters
#     (`local -n`), and `${var,,}` lowercasing all require real bash --
#     Alpine's base image has no bash by default, unlike Debian's.
#
# What: curl/findutils/envsubst/lsof/ripgrep come from the shared utilities image.
# Why: avoids rebuilding the same tools per-image; safe since this stage
#   pins the identical alpine:3.24 digest the utilities image itself uses.
# From: Issue #1556

# What: removes the BusyBox symlinks at these paths before real binaries land.
# Why: COPY writes through an existing symlink to /bin/busybox (also
#   /bin/sh's target), corrupting busybox and breaking /bin/sh in later RUNs.
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
    sh /usr/local/bin/verify-version-banner.sh "lsof version information" lsof -v

# What: declares APT_CACHE_BUST right before the RUN it busts.
# Why: without this, BuildKit's cache has no wall-clock expiry and can
#   replay a stale `apk upgrade` forever; see tools/build-tools/Dockerfile's
#   identical ARG for the full rationale.
# From: Issue #1095
ARG APT_CACHE_BUST=""
RUN : "apt-cache-bust=${APT_CACHE_BUST}" && \
    apk upgrade --no-cache && \
    apk add --no-cache ca-certificates openssl && \
    curl -fsSL -o /etc/apk/keys/nginx_signing.rsa.pub https://nginx.org/keys/nginx_signing.rsa.pub && \
    printf '%s\n' "@nginx https://nginx.org/packages/mainline/alpine/v$(cut -d. -f1,2 /etc/alpine-release)/main" >> /etc/apk/repositories && \
    apk update && \
    apk add --no-cache \
    nginx@nginx \
    coreutils \
    bash \
    nano
# curl/ca-certificates/openssl are kept at runtime (not purged): curl is
# genuinely shelled out to by deploy/{prod,quickstart,full-setup}'s proxy
# container healthcheck (`deploy/prod/docker-compose.yml`'s `curl -sf
# http://127.0.0.1/healthz ...` probe); ca-certificates and openssl are
# needed for TLS (nginx's SSL-mode wildcard certs, entrypoint.sh's CA/cert
# generation via openssl, and the system trust store for whatever nginx
# itself needs) -- same rationale as the prior Debian stage, no gnupg-style
# purge-after-use step is needed here since Alpine's apk signing-key
# mechanism (a plain RSA public key file) never pulls in a temporary
# package the way apt's gpg-based key import did. ca-certificates itself
# stays apk-installed (not copied from utilities): it is a certificate-data
# package, not a binary, and this build needs its trust store before the
# COPY'd curl's first HTTPS call above even runs.
# nano: in-container troubleshooting tool -- see services/dns/Dockerfile's
# identical comment for the full rationale; lsof/ripgrep are COPY'd above
# but serve the same troubleshooting purpose.
ENV EDITOR=nano
ENV VISUAL=$EDITOR

RUN mkdir -p \
    /etc/nginx/ssl/ca \
    /etc/nginx/ssl/certs \
    /var/cache/nginx/lancache \
    /var/cache/nginx/tmp

COPY nginx.conf /etc/nginx/nginx.conf.template
COPY conf.d/ /etc/nginx/conf.d/
COPY proxy-params.conf /etc/nginx/proxy-params.conf.template
# Static third-party data (not user-editable, unlike cdn-domains.txt below),
# so it's baked into the image rather than volume-mounted. See entrypoint.sh
# for how it's used to derive wildcard cert root domains.
COPY public_suffix_list.dat /etc/nginx/public_suffix_list.dat
# Build-time snapshot fallback for deployments with no live bind-mount (see
# deploy/quickstart, which has no local repo checkout to mount from). The
# "dns-domains" name is a named additional build context — services/dns/ is
# outside this Dockerfile's own build context (services/proxy/), and Docker
# build contexts can't reach outside their own tree without one (see
# .github/workflows/build-push.yml's `build-contexts: dns-domains=services/dns`
# / `--build-context` for a plain `docker build`; no remaining compose file
# builds this image locally via a compose-level `additional_contexts:` key --
# the former `deploy/dev/docker-compose.yml` did, before being retired in
# v0.3.0, #766). prod always shadows this baked default with a live
# bind-mount of the real file at container start.
COPY --from=dns-domains cdn-domains.txt /etc/nginx/cdn-domains.txt
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/etc/nginx/ssl", "/var/cache/nginx/lancache"]

EXPOSE 80 443

ENTRYPOINT ["/entrypoint.sh"]
