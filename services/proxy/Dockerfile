# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# nginx-based caching proxy image: unified standard (SNI passthrough) and
# SSL/MITM (TLS-interception) mode, selected at runtime by entrypoint.sh.
# Installs nginx from the nginx.org mainline repo (not Debian's own nginx
# package) and includes libnginx-mod-stream for standard mode's SNI
# passthrough; see CLAUDE.md's "Key Design Decisions" for the stream-module
# load order requirement.

FROM mirror.gcr.io/library/debian:13-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2

LABEL org.opencontainers.image.description="nginx-based lancache-ng caching proxy for standard and TLS-interception cache traffic."

# trixie-backports is used to get a newer curl (8.21.0 instead of plain
# trixie's 8.14.1-2+deb13u4) -- pin is scoped to exactly curl and the
# specific shared libraries its backports build pulls in, never
# `Package: *`. IMPORTANT, corrected 2026-07-30 after a real before/after
# Trivy scan: this does NOT reduce curl's Trivy HIGH finding count. Both
# curl versions carry the exact same 7 HIGH CVE IDs (CVE-2026-12064,
# -8286, -8927, -8932, -9079, -9080, -9545; each `Status: affected`,
# `FixedVersion: None` in Trivy's DB) -- these were disclosed 2026-07-03,
# after 8.21.0 shipped, and have no fix anywhere yet (not trixie, not
# backports, not sid). An earlier version of this comment claimed
# backports "fixes all 7 of curl's CVEs," which was true only for a
# different, earlier set of 7 CVE IDs that 8.21.0 itself did fix relative
# to older curl releases -- it was never re-verified against a fresh scan
# before being written down here, and a fresh scan against the actual
# built image shows the image's current curl finding set is unchanged
# before vs. after this backports move. The residual risk and the
# maintainer decision this leaves open (accept as-is, purge curl and
# migrate the healthcheck off it, or something else) are tracked in issue
# #1304 -- do not re-assert "fixes curl's CVEs" here without first
# re-running the same before/after scan this comment is based on, since
# curl's actual CVE set is a moving target.
# What backports still buys, independent of the HIGH-finding count: a
# newer curl in general (HTTP/3/QUIC support), and this scoped pin itself
# only widens the package's own maintenance path, not this image's
# general package provenance (see the pin-scoping rationale below).
# The pin selector below MUST use `a=stable-backports`, not
# `a=trixie-backports`: APT's `a=`/release-Archive selector matches the
# Release file's `Suite:` field, and trixie-backports' own Release file
# declares `Suite: stable-backports` / `Codename: trixie-backports` -- the
# two are not interchangeable. A first version of this pin used
# `a=trixie-backports` and silently never matched anything (apt-cache
# policy still showed backports at its Debian-default priority 100),
# so every "backports-sourced" package silently stayed on the vulnerable
# plain-trixie version despite the pin file being present -- caught only by
# building the image for real and checking the installed curl version
# rather than trusting the Dockerfile comment.
#
# The `Package:` line names exactly five packages, not `*`: a first version
# of this fix pinned ALL of `stable-backports` to priority 500 (tied with
# the regular trixie archive) and additionally ran `apt-get dist-upgrade`/
# `full-upgrade` under that blanket pin. That happened to only pull in
# curl's own dependency closure in THIS build (confirmed by a real build:
# `dpkg -l | grep bpo` showed exactly `curl`, `libcurl4t64`,
# `libnghttp3-9`, `libngtcp2-16`, and `libngtcp2-crypto-ossl0` -- the last
# three are curl 8.21's HTTP/3/QUIC support libraries, not present at a
# new-enough version in plain trixie), but that was incidental to today's
# package-version state, not something the blanket pin structurally
# guaranteed: the moment trixie-backports ships a newer build of ANY other
# installed package (e.g. one of the base-image packages tracked in #1298),
# a future rebuild would silently move it onto backports too, widening this
# image's package provenance far beyond "just get a fixed curl." Naming the
# five packages explicitly, and dropping the blanket `dist-upgrade`/
# `full-upgrade` calls entirely (they were only ever needed to let the
# blanket pin's version-comparison reach curl's dependency chain; a scoped
# pin plus a normal `apt-get install curl` reaches the same five packages
# without them, verified by a real rebuild after this change), keeps every
# other installed package on plain trixie exactly as before this PR.
RUN echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/backports.list \
    && printf 'Package: curl libcurl4t64 libnghttp3-9 libngtcp2-16 libngtcp2-crypto-ossl0\nPin: release a=stable-backports\nPin-Priority: 500\n' > /etc/apt/preferences.d/backports \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    gnupg \
    curl \
    ca-certificates \
    && curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/nginx.gpg \
    && echo "deb http://nginx.org/packages/mainline/debian/ trixie nginx" > /etc/apt/sources.list.d/nginx.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    openssl \
    gettext-base \
    locales \
    nano \
    lsof \
    ripgrep \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && locale-gen \
    # gnupg (which pulls in dirmngr/gpg/gpg-agent/gpgconf/gpgsm/gnupg-l10n)
    # is needed ONLY to fetch and dearmor nginx.org's signing key above,
    # before the apt source it authenticates even exists -- purged here, in
    # the same layer it was installed in, so it never persists in any image
    # layer. curl is KEPT: deploy/{prod,quickstart,full-setup}'s container
    # healthcheck probes genuinely shell out to it at runtime (confirmed by
    # docs/bug-hunt/proxy.md's own prior audit and
    # docs/capability-inventory/SoT-proxy.md's Compose-wiring section) --
    # purging it, as this PR's first two passes did, breaks every proxy
    # healthcheck. curl is pulled from trixie-backports for a newer
    # version (see this block's own pin-priority setup above) -- but per
    # that comment's 2026-07-30 correction, this does NOT eliminate
    # curl's Trivy HIGH findings, which persist unfixed regardless of
    # curl version; see issue #1304 for the still-open maintainer
    # decision on how to handle that residual risk.
    # ca-certificates and openssl are also kept: both are genuinely needed
    # at runtime for TLS (nginx's SSL-mode wildcard certs, entrypoint.sh's
    # CA/cert generation via openssl, and the system trust store for
    # whatever nginx itself needs).
    && apt-get purge -y --auto-remove gnupg \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
# nano/lsof/ripgrep: in-container troubleshooting tools -- these images
# otherwise ship no editor, no way to see which process holds an open
# file/socket, and no fast recursive search, all real gaps when debugging a
# live container via `docker exec`. EDITOR/VISUAL default to nano now that
# it's actually present, matching common shell/tool expectations (git,
# crontab -e, etc.) that read one of these instead of falling back to vi.
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
