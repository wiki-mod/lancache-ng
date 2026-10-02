
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Alpine nginx caching proxy
# Why: nginx.org has stream; http repos let Squid cache.
# From: Issue #1683

# What: base image pin, supplied by ci.sh from the SOT.
# Why: SOT base_images.alpine is the sole owner (AG-CI-006).
# From: Issue #1683
ARG ALPINE_IMAGE
# What: scratch only when ci.sh passed no image arg.
# Why: no baked image; a missing arg fails the build.
# From: Issue #1683 | PR #1858
FROM ${ALPINE_IMAGE:-scratch}

LABEL org.opencontainers.image.description="nginx-based lancache-ng caching proxy for standard and TLS-interception cache traffic."

# What: build identity keys the cache of later layers.
# Why: a new package set must not reuse a stale apk layer.
# From: Issue #1683 | PR #1858
ARG BUILD_IDENTITY
# What: Install nginx.org nginx with CA trust setup
# Why: nginx.org has stream; the CA passes the TLS proxy.
# From: Issue #1095
RUN --mount=type=secret,id=project_selfhosted_proxy_ca \
    sed -i 's|^https://|http://|' /etc/apk/repositories \
    && if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
         cp /etc/ssl/certs/ca-certificates.crt /var/tmp/ca-bundle.orig \
         && cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
       fi \
    && apk update --no-cache \
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

# What: Static public suffix list for domain derivation
# Why: Entrypoint uses it for wildcard cert domains
# From: Issue #1095
COPY public_suffix_list.dat /etc/nginx/public_suffix_list.dat

# What: Copy domain validation lib and CDN domains
# Why: dns stage owns both; proxy consumes via context
# From: Issue #1683
COPY --from=dns-domains domain-validation.sh /usr/local/lib/domain-validation.sh
COPY --from=dns-domains cdn-domains.txt /etc/nginx/cdn-domains.txt

# What: Copy known-good snapshots library
# Why: Entrypoint sources it via build context
# From: Issue #1683
COPY --from=known-good known-good-snapshots.sh /usr/local/lib/known-good-snapshots.sh
COPY entrypoint.sh /entrypoint.sh

VOLUME ["/etc/nginx/ssl", "/var/cache/nginx/lancache"]

EXPOSE 80 443

ENTRYPOINT ["/entrypoint.sh"]
