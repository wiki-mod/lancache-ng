# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Alpine nginx caching proxy; apk install image-local.
# Why: nginx.org stream module; http repos let Squid cache.
# From: Issue #815 | Issue #1683

# What: base image, supplied by ci.sh from the SOT pin.
# Why: non-authoritative fallback keeps FROM valid (AG-CI-008).
# From: Issue #1683
ARG ALPINE_IMAGE=alpine:3.24
FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="nginx-based lancache-ng caching proxy for standard and TLS-interception cache traffic."

# What: explicit proxy build-args, no default value set.
# Why: routes self-hosted apk fetches via the LAN proxy.
# From: Issue #1781 | PR #1783
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

# What: APT_CACHE_BUST invalidates BuildKit's apk layer cache.
# Why: without it BuildKit replays a stale layer forever.
# From: Issue #1095
ARG APT_CACHE_BUST=""
# What: image-local nginx.org nginx + tools; CA-trust build-only.
# Why: stream module needs nginx.org; CA reaches it via the proxy.
# From: Issue #815 | Issue #1095 | Issue #1781
RUN --mount=type=secret,id=project_selfhosted_proxy_ca \
    sed -i 's|^https://|http://|' /etc/apk/repositories \
    && if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
         cp /etc/ssl/certs/ca-certificates.crt /var/tmp/ca-bundle.orig \
         && cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
       fi \
    && : "apt-cache-bust=${APT_CACHE_BUST}" \
    && apk upgrade --no-cache \
    && apk add --no-cache ca-certificates openssl curl \
    && if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
         cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
       fi \
    && curl -fsSL -o /etc/apk/keys/nginx_signing.rsa.pub https://nginx.org/keys/nginx_signing.rsa.pub \
    && printf '%s\n' "@nginx http://nginx.org/packages/mainline/alpine/v$(cut -d. -f1,2 /etc/alpine-release)/main" >> /etc/apk/repositories \
    && apk update \
    && apk add --no-cache \
        nginx@nginx \
        coreutils \
        bash \
        nano \
        findutils \
        gettext-envsubst \
        lsof \
        ripgrep \
    && if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then mv /var/tmp/ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

ENV EDITOR=nano
ENV VISUAL=$EDITOR

# What: nginx cache, ssl and tmp dirs pre-created.
# Why: entrypoint drops privileges; dirs must pre-exist.
# From: Issue #1428 | PR #1431
RUN mkdir -p \
    /etc/nginx/ssl/ca \
    /etc/nginx/ssl/certs \
    /var/cache/nginx/lancache \
    /var/cache/nginx/tmp

COPY nginx.conf /etc/nginx/nginx.conf.template
COPY conf.d/ /etc/nginx/conf.d/
COPY proxy-params.conf /etc/nginx/proxy-params.conf.template

# What: static public suffix list for cert-domain derivation.
# Why: entrypoint derives wildcard cert domains from it.
# From: Issue #1095
COPY public_suffix_list.dat /etc/nginx/public_suffix_list.dat

# What: shared domain-validation lib + cdn-domains snapshot.
# Why: dns owns both; proxy consumes them via the named context.
# From: Issue #766 | Issue #1683
COPY --from=dns-domains domain-validation.sh /usr/local/lib/domain-validation.sh
COPY --from=dns-domains cdn-domains.txt /etc/nginx/cdn-domains.txt

COPY entrypoint.sh /entrypoint.sh

VOLUME ["/etc/nginx/ssl", "/var/cache/nginx/lancache"]

EXPOSE 80 443

ENTRYPOINT ["/entrypoint.sh"]
