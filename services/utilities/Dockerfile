
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: shared image with curl + 9 CLI tools, COPY --from=.
# Why: avoids each service installing its own copy.
# From: Issue #1556

FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS curl-builder

# What: explicit proxy build-args, no default value set.
# Why: build fleet sits behind a proxy; allow a NO_PROXY.
# From: Issue #1637
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

# What: pinned curl release, checksum-verified before extract.
# Why: matches this project's checksum-verified fetch pattern.
# From: Issue #1556
ARG CURL_VERSION=8.21.0
ARG CURL_SHA256=aa1b66a70eace83dc624508745646c08ae561de512ab403adffb93ac87fc72e6

RUN set -euo pipefail; \
    apk add --no-cache --virtual .fetch-deps curl ca-certificates; \
    curl -fsSL "https://curl.se/download/curl-${CURL_VERSION}.tar.xz" -o /tmp/curl.tar.xz; \
    printf '%s  %s\n' "${CURL_SHA256}" /tmp/curl.tar.xz | sha256sum -c -; \
    tar -xJf /tmp/curl.tar.xz -C /tmp; \
    apk del .fetch-deps

# What: build deps for a static curl build; libpsl excluded.
# Why: Alpine's libpsl-static won't link into a static build.
# From: Issue #1556
RUN apk add --no-cache \
      build-base \
      ccache \
      file \
      perl \
      openssl-dev \
      openssl-libs-static \
      zlib-dev \
      zlib-static \
      ca-certificates

# What: removes unversioned .so symlinks before static build.
# Why: libtool's -static handling doesn't forward to the libs.
# From: Issue #1556
RUN rm -f /usr/lib/libssl.so /usr/lib/libcrypto.so /usr/lib/libz.so

WORKDIR /tmp/curl-${CURL_VERSION}

# What: builds curl, wraps compiler in ccache when mounted.
# Why: reuses dns's AG-CI-022 ccache-over-distcc layer.
# From: Issue #1556
RUN --mount=type=secret,id=ccache_redis_url \
    set -euo pipefail; \
    cc_wrapper=gcc; \
    if [ -s /run/secrets/ccache_redis_url ]; then \
      ccache_redis_endpoint="$(cat /run/secrets/ccache_redis_url)"; \
      case "$ccache_redis_endpoint" in \
        redis://* | redis+tls://*) ;; \
        *) ccache_redis_endpoint="redis://$ccache_redis_endpoint" ;; \
      esac; \
      export CCACHE_REMOTE_STORAGE="$ccache_redis_endpoint"; \
      export CCACHE_DIR=/tmp/ccache-utilities; \
      export CCACHE_COMPILERCHECK=content; \
      cc_wrapper="ccache gcc"; \
      echo "[INFO] curl-builder: ccache enabled with Redis remote storage." >&2; \
    else \
      echo "[INFO] curl-builder: no ccache_redis_url secret mounted; compiling without a compiler cache." >&2; \
    fi; \
    ./configure \
      --disable-shared --enable-static \
      --disable-ftp --disable-file --disable-ldap --disable-ldaps \
      --disable-rtsp --disable-dict --disable-telnet --disable-tftp \
      --disable-pop3 --disable-imap --disable-smtp --disable-smb \
      --disable-gopher --disable-mqtt \
      --disable-scp --disable-sftp --without-libssh2 --without-libssh \
      --disable-ntlm --disable-kerberos-auth --disable-negotiate-auth \
      --disable-aws \
      --disable-manual --disable-libcurl-option \
      --disable-ipfs --disable-websockets \
      --without-librtmp --without-libidn2 --without-brotli --without-zstd \
      --without-nghttp2 --without-nghttp3 --without-ngtcp2 --without-libpsl \
      --with-openssl \
      --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
      --enable-http --enable-cookies --enable-ipv6 \
      CC="$cc_wrapper" CFLAGS="-fno-PIE" LDFLAGS="-no-pie" PKG_CONFIG="pkg-config --static"; \
    make -j"$(nproc)" LDFLAGS="-all-static -no-pie"; \
    if [ -n "${CCACHE_REMOTE_STORAGE:-}" ]; then \
      ccache -s || true; \
    fi; \
    mkdir -p /out/usr/local/bin /out/etc/ssl/certs; \
    install -m 0755 src/curl /out/usr/local/bin/curl; \
    /out/usr/local/bin/curl --version; \
    curl_file_type="$(file /out/usr/local/bin/curl)"; \
    case "$curl_file_type" in \
      *"statically linked"*) ;; \
      *) echo "ERROR: curl build is not fully static: $curl_file_type" >&2; exit 1 ;; \
    esac

# What: this stage is the utilities image itself.
# Why: only this base matters; curl is already static.
# From: Issue #1556
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

# What: upgrades base packages, installs 9 non-curl tools.
# Why: apk installs register in the image's package db.
# From: Issue #1556
# What: declares APT_CACHE_BUST right before the RUN it busts.
# Why: without this, BuildKit cache has no wall-clock expiry.
# From: Issue #1095
ARG APT_CACHE_BUST=""
RUN : "apt-cache-bust=${APT_CACHE_BUST}" && \
    apk upgrade --no-cache && \
    apk add --no-cache \
      nano \
      lsof \
      ripgrep \
      findutils \
      coreutils \
      gettext-envsubst \
      jq \
      zstd \
      ca-certificates

# What: verifies coreutils/findutils commands still resolve.
# Why: coreutils overwrites some BusyBox symlinks.
# From: Issue #1556
RUN set -euo pipefail; \
    for expected in basename cp date dirname install mktemp mv rm sort realpath base64 od find xargs; do \
      command -v "$expected" >/dev/null 2>&1 || { echo "ERROR: expected coreutils/findutils binary missing: $expected" >&2; exit 1; }; \
    done

# What: ships the shared version-banner smoke check.
# Why: dedupes the lsof-banner check six Dockerfiles carried.
# From: Issue #1613
COPY verify-version-banner.sh /usr/local/bin/verify-version-banner.sh

COPY --from=curl-builder /out/usr/local/bin/curl /usr/local/bin/curl
