
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Alpine nginx image using http apk repos
# Why: Static stream module; http enables LAN proxy cache
# From: Issue #815 | Issue #1683


# What: Base image pin, consumed from the version SOT.
# Why: build-manifest.yml is the sole owner of the pin.
# From: Issue #1683
ARG ALPINE_IMAGE
FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="nginx-based lancache-ng caching proxy for standard and TLS-interception cache traffic."

# What: explicit proxy build-args, no default value set
# Why: routes self-hosted downloads via the LAN proxy
# From: Issue #1781 | PR #1783
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

# What: Install nginx and GNU utilities from nginx.org repo
# Why: Stream module needed; GNU tools for shell scripts
# From: Issue #1781 | PR #1783 | Issue #1425

# What: Shared version-banner script, reused by all services
# Why: Named build context avoids per-service duplication
# From: Issue #1781 | PR #1783
COPY --from=shared-scripts verify-version-banner.sh /usr/local/bin/verify-version-banner.sh

# What: copies the domain-validation library in.
# Why: entrypoint.sh no longer embeds a byte-identical copy.
# From: Issue #1683
COPY --from=shared-scripts domain-validation.sh /usr/local/lib/domain-validation.sh

# What: Declare APT_CACHE_BUST to expire BuildKit cache.
# Why: Expires BuildKit cache for apk upgrade phases.
# From: Issue #1095

# What: Switch apk repositories to plain http.
# Why: Squid proxy caches http; signing keeps integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

ARG APT_CACHE_BUST=""
# What: trusts the proxy CA for this RUN, re-applied below.
# Why: ca-certificates install resets the bundle mid-RUN.
# From: Issue #1781 | PR #1783
RUN --mount=type=secret,id=project_selfhosted_proxy_ca \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /tmp/ca-bundle.orig && \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi && \
    : "apt-cache-bust=${APT_CACHE_BUST}" && \
    apk upgrade --no-cache && \
    apk add --no-cache ca-certificates openssl curl && \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi && \
    curl -fsSL -o /etc/apk/keys/nginx_signing.rsa.pub https://nginx.org/keys/nginx_signing.rsa.pub && \
    printf '%s\n' "@nginx http://nginx.org/packages/mainline/alpine/v$(cut -d. -f1,2 /etc/alpine-release)/main" >> /etc/apk/repositories && \
    apk update && \
    apk add --no-cache \
    nginx@nginx \
    coreutils \
    bash \
    nano \
    findutils \
    gettext-envsubst \
    lsof \
    ripgrep && \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then mv /tmp/ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

# What: Keep runtime packages and add debug tools
# Why: Curl/certs for healthcheck and TLS; tools for debug
# From: Issue #1095 | Issue #1346 | Issue #1613

# What: Verify apk-installed binaries execute properly.
# Why: Missing library dependencies fail at runtime.
# From: Issue #1613 | Issue #1781 | PR #1783
RUN set -euo pipefail; \
    find . -maxdepth 0 -printf '%f\n' >/dev/null; \
    printf '%s' '$FOO' | FOO=bar envsubst >/dev/null; \
    rg --version >/dev/null; \
    curl --version >/dev/null; \
    sh /usr/local/bin/verify-version-banner.sh "lsof version information" lsof -v

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

# What: Static public suffix list for certificate generation
# Why: Used by entrypoint.sh to derive wildcard cert domains
# From: Issue #1095
COPY public_suffix_list.dat /etc/nginx/public_suffix_list.dat

# What: Build-time snapshot fallback for domain config.
# Why: Used when live bind-mount unavailable (quickstart).
# From: Issue #766
COPY --from=dns-domains cdn-domains.txt /etc/nginx/cdn-domains.txt
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/etc/nginx/ssl", "/var/cache/nginx/lancache"]

# What: Final apk upgrade pass, no new packages added.
# Why: Patches CVEs fixed after package installs.
# From: Issue #1781 | PR #1783
RUN apk upgrade --no-cache

EXPOSE 80 443

ENTRYPOINT ["/entrypoint.sh"]
