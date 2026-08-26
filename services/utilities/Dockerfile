
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: shared image with curl plus 9 non-compiler CLI tools for `COPY --from=`.
# Why: avoids each service independently installing/building its own copy.
# From: Issue #1556

FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS curl-builder

# What: explicit proxy build-args, no default value set.
# Why: this project's build fleet sits behind an HTTP(S) proxy; lets a
#   caller pass a local-network NO_PROXY exception.
# From: Issue #1637
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

# What: pinned curl release, checksum-verified before extraction.
# Why: matches this project's established checksum-verified download
# pattern for third-party sources.
# From: Issue #1556
ARG CURL_VERSION=8.21.0
ARG CURL_SHA256=aa1b66a70eace83dc624508745646c08ae561de512ab403adffb93ac87fc72e6

RUN set -euo pipefail; \
    apk add --no-cache --virtual .fetch-deps curl ca-certificates; \
    curl -fsSL "https://curl.se/download/curl-${CURL_VERSION}.tar.xz" -o /tmp/curl.tar.xz; \
    printf '%s  %s\n' "${CURL_SHA256}" /tmp/curl.tar.xz | sha256sum -c -; \
    tar -xJf /tmp/curl.tar.xz -C /tmp; \
    apk del .fetch-deps

# What: build-time deps for a static curl build; libpsl deliberately excluded.
# Why: Alpine's libpsl-static does not link cleanly into a static build, and
# this project's curl usage only targets a small, fixed, trusted host set.
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

# What: removes unversioned .so linker symlinks before the static build.
# Why: libtool's own -static handling does not forward to the non-libtool
# openssl/zlib libraries, so the linker keeps resolving shared .so files
# unless those symlinks are gone; confined to this throwaway stage.
# From: Issue #1556
RUN rm -f /usr/lib/libssl.so /usr/lib/libcrypto.so /usr/lib/libz.so

WORKDIR /tmp/curl-${CURL_VERSION}

# What: builds curl, wrapping the C compiler in ccache when a secret is mounted.
# Why: reuses the same repository secret dns's AG-CI-022 ccache-over-distcc
#   layer uses, under a distinct mount id; fails closed to plain gcc
#   per AG-CI-009 otherwise.
# From: Issue #1095 (G15 | #1556)
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

# What: this stage is the ghcr.io/wiki-mod/lancache-ng/utilities image itself.
# Why: only this stage's own runtime base matters here -- curl is already
# static (built above); the other 9 tools are ordinary Alpine dynamic
# binaries, tied to this base's musl libc.
# From: Issue #1556
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

# What: upgrades base packages, installs the 9 non-curl tools via apk.
# Why: apk-installed packages register in this image's own package
# database, keeping them Trivy-visible.
# From: Issue #1556
# What: declares APT_CACHE_BUST right before the RUN it busts.
# Why: without this, BuildKit's cache has no wall-clock expiry and can
#   replay a stale `apk upgrade` forever; see tools/build-tools/Dockerfile's
#   identical ARG for the full rationale.
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

# What: verifies expected coreutils/findutils commands still resolve.
# Why: installing coreutils overwrites some of Alpine's own BusyBox
# symlinks; this catches a regression if any expected command breaks.
# From: Issue #1556
RUN set -euo pipefail; \
    for expected in basename cp date dirname install mktemp mv rm sort realpath base64 od find xargs; do \
      command -v "$expected" >/dev/null 2>&1 || { echo "ERROR: expected coreutils/findutils binary missing: $expected" >&2; exit 1; }; \
    done

# What: ships the shared copied-tool version-banner smoke check.
# Why: dedupes the byte-identical lsof-banner check six consumer Dockerfiles
# each carried inline.
# From: Issue #1613
COPY verify-version-banner.sh /usr/local/bin/verify-version-banner.sh

COPY --from=curl-builder /out/usr/local/bin/curl /usr/local/bin/curl
