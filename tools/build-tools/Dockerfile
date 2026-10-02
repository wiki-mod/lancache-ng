
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: Alpine CI and developer validation toolchain.
# Why: One musl toolchain image builds the whole stack.
# From: Issue #1683

# What: Base image pin, consumed from the version SOT.
# Why: build-manifest.yml is the sole owner of the pin.
# From: Issue #1683
ARG ALPINE_IMAGE

# What: Reused ISC dhclient pin, from the version SOT.
# Why: Version, branch and per-arch digests owned centrally.
# From: Issue #1683
ARG DHCLIENT_VERSION
ARG DHCLIENT_ALPINE_BRANCH
ARG DHCLIENT_ARCH
ARG DHCLIENT_SHA256

# What: Alpine toolchain stage; scratch if no image arg.
# Why: no baked image; a missing arg fails the build.
# From: Issue #1683 | PR #1858
FROM ${ALPINE_IMAGE:-scratch}

LABEL org.opencontainers.image.description="Prebuilt lancache-ng CI and developer validation toolchain image (Alpine)."

# What: re-declare SOT build-args for use in this stage.
# Why: pre-FROM ARGs are not visible after FROM in Docker.
# From: Issue #1683
ARG DHCLIENT_VERSION
ARG DHCLIENT_ALPINE_BRANCH
ARG DHCLIENT_ARCH
ARG DHCLIENT_SHA256

# What: uses plain /bin/sh for the apk-install step only.
# Why: the alpine base has no bash until apk installs it.
# From: Issue #1095
SHELL ["/bin/sh", "-c"]

ENV PATH="/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    RUST_BACKTRACE=1

# What: fail closed if any dhclient build-arg is empty.
# Why: the reused dhclient apk is a pinned SOT input.
# From: Issue #1683
RUN set -eu; \
    missing=""; \
    for kv in \
      "DHCLIENT_VERSION=${DHCLIENT_VERSION}" \
      "DHCLIENT_ALPINE_BRANCH=${DHCLIENT_ALPINE_BRANCH}" \
      "DHCLIENT_ARCH=${DHCLIENT_ARCH}" \
      "DHCLIENT_SHA256=${DHCLIENT_SHA256}"; do \
      case "$kv" in *=) missing="${missing} ${kv%=}" ;; esac; \
    done; \
    if [ -n "$missing" ]; then \
      echo "[CI-ERROR-BUILDTOOLS-0001] empty build-arg(s):${missing}" >&2; \
      exit 1; \
    fi

# What: build identity keys the cache of later layers.
# Why: a new package set must not reuse a stale apk layer.
# From: Issue #1683 | PR #1858
ARG BUILD_IDENTITY

# What: the apk package list, supplied from the SOT.
# Why: the SOT owns the list; this stage only consumes it.
# From: Issue #1683
ARG APK_PACKAGES

# What: tagged apk repos (tag=url), supplied from the SOT.
# Why: the SOT owns the URL; this stage only adds it.
# From: Issue #1683 | PR #1858
ARG APK_TAGGED_REPOS

# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: add each SOT tagged repo as "@tag url".
# Why: only tagged packages (trivy) resolve, not global.
# From: Issue #1683 | PR #1858
RUN for kv in ${APK_TAGGED_REPOS}; do echo "@${kv%%=*} ${kv#*=}" >> /etc/apk/repositories; done

# What: install base utils + SOT tools; trust proxy CA.
# Why: GNU coreutils differ; CA restored before commit.
# From: Issue #1683
RUN --mount=type=secret,id=project_selfhosted_proxy_ca set -euo pipefail; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /var/tmp/ca-bundle.orig; \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi; \
    apk update; \
    apk add --no-cache ${APK_PACKAGES}; \
    ln -sf /usr/bin/pump /usr/bin/distcc-pump; \
    distcc_bin="$(command -v distcc)"; \
    mkdir -p /usr/local/lib/distcc; \
    for wrapper in cc gcc c++ g++; do ln -sf "$distcc_bin" "/usr/local/lib/distcc/$wrapper"; done; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then mv /var/tmp/ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

# What: verifies the apk-installed curl actually runs
# Why: catches a missing shared-lib chain at build time
# From: Issue #1781 | PR #1783
RUN curl --version >/dev/null

# What: switches SHELL to bash for every RUN step below.
# Why: pipefail guards the dhclient checksum pipe.
# From: Issue #1095
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# What: reuse the SOT-pinned Alpine ISC dhclient apk.
# Why: newer Alpine dropped it; musl build, real dhclient.
# From: Issue #1683
RUN set -euo pipefail; \
    dh_tmp="$(mktemp -d -p /var/tmp)"; \
    trap 'rm -rf "$dh_tmp"' EXIT; \
    curl -fsSL \
      "http://dl-cdn.alpinelinux.org/alpine/${DHCLIENT_ALPINE_BRANCH}/main/${DHCLIENT_ARCH}/dhclient-${DHCLIENT_VERSION}.apk" \
      -o "$dh_tmp/dhclient.apk"; \
    printf '%s  %s\n' "${DHCLIENT_SHA256}" "$dh_tmp/dhclient.apk" | sha256sum -c -; \
    tar -xzf "$dh_tmp/dhclient.apk" -C /; \
    rm -f /.PKGINFO /.SIGN.* /.pre-install /.post-install /.trigger; \
    dhclient --version

# What: symlink musl-gcc to gcc; gcc targets musl already
# Why: required by dns/ui/watchdog; avoids duplicate binary
# From: Issue #1095 | PR #1691
RUN ln -sf /usr/bin/gcc /usr/local/bin/musl-gcc

WORKDIR /workspace

CMD ["bash"]
