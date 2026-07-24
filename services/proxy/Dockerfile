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

RUN apt-get update && apt-get install -y --no-install-recommends \
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
