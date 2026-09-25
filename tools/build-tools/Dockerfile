
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
ARG DHCLIENT_APK_ARCH
ARG DHCLIENT_SHA256

# What: The single Alpine toolchain stage, base from SOT.
# Why: apk installs Rust; musl-native, no rustup.
# From: Issue #1683
FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="Prebuilt lancache-ng CI and developer validation toolchain image (Alpine)."

# What: explicit proxy build-args, no default value set
# Why: routes self-hosted apk/cargo pulls via the LAN proxy
# From: Issue #1781 | PR #1783
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

# What: re-declare SOT build-args for use in this stage.
# Why: pre-FROM ARGs are not visible after FROM in Docker.
# From: Issue #1683
ARG DHCLIENT_VERSION
ARG DHCLIENT_ALPINE_BRANCH
ARG DHCLIENT_APK_ARCH
ARG DHCLIENT_SHA256

# What: uses plain /bin/sh for the apk-install step only.
# Why: rust:alpine has no bash until that step installs it.
# From: Issue #1095
SHELL ["/bin/sh", "-c"]

ENV PATH="/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    RUST_BACKTRACE=1

# What: fail closed if any dhclient build-arg is empty.
# Why: the reused v3.20 apk is a pinned input, not loose.
# From: Issue #1683
RUN set -eu; \
    missing=""; \
    for kv in \
      "DHCLIENT_VERSION=${DHCLIENT_VERSION}" \
      "DHCLIENT_ALPINE_BRANCH=${DHCLIENT_ALPINE_BRANCH}" \
      "DHCLIENT_APK_ARCH=${DHCLIENT_APK_ARCH}" \
      "DHCLIENT_SHA256=${DHCLIENT_SHA256}"; do \
      case "$kv" in *=) missing="${missing} ${kv%=}" ;; esac; \
    done; \
    if [ -n "$missing" ]; then \
      echo "[CI-ERROR-BUILDTOOLS-0001] empty build-arg(s):${missing}" >&2; \
      exit 1; \
    fi

# What: declare APK_CACHE_BUST before RUN
# Why: bust layer cache on rotation; matches APT pattern
# From: Issue #1095
ARG APK_CACHE_BUST=""

# What: the apk package list, supplied from the SOT.
# Why: the SOT owns the list; this stage only consumes it.
# From: Issue #1683
ARG APK_PACKAGES

# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: add edge/testing as a tagged http repo.
# Why: only @testing tags (trivy) resolve, not global.
# From: Issue #1683
RUN echo "@testing http://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories

# What: install base utils + SOT tools; trust proxy CA.
# Why: GNU coreutils differ; CA restored before commit.
# From: Issue #1683
RUN --mount=type=secret,id=project_selfhosted_proxy_ca set -euo pipefail; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /var/tmp/ca-bundle.orig; \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi; \
    : "apk-cache-bust=${APK_CACHE_BUST}"; \
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
# Why: BusyBox ash cannot parse this file's bash-array use.
# From: Issue #1095
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# What: reuse the last Alpine v3.20 ISC dhclient apk.
# Why: 3.21+ dropped it; musl build, real dhclient.
# From: Issue #1683
RUN set -euo pipefail; \
    dh_tmp="$(mktemp -d -p /var/tmp)"; \
    trap 'rm -rf "$dh_tmp"' EXIT; \
    curl -fsSL \
      "http://dl-cdn.alpinelinux.org/alpine/${DHCLIENT_ALPINE_BRANCH}/main/${DHCLIENT_APK_ARCH}/dhclient-${DHCLIENT_VERSION}.apk" \
      -o "$dh_tmp/dhclient.apk"; \
    printf '%s  %s\n' "${DHCLIENT_SHA256}" "$dh_tmp/dhclient.apk" | sha256sum -c -; \
    tar -xzf "$dh_tmp/dhclient.apk" -C /; \
    rm -f /.PKGINFO /.SIGN.* /.pre-install /.post-install /.trigger; \
    dhclient --version

# What: symlink musl-gcc to gcc; gcc targets musl already
# Why: required by dns/ui/watchdog; avoids duplicate binary
# From: Issue #1095 | PR #1691
RUN ln -sf /usr/bin/gcc /usr/local/bin/musl-gcc

# What: verify every required tool is present and runs.
# Why: a missing tool must fail the build, not CI later.
# From: Issue #1095
RUN set -euo pipefail; \
    required_tools=( \
      bash \
      bats \
      cargo \
      rustc \
      rustfmt \
      clippy-driver \
      sccache \
      ccache \
      cargo-audit \
      cargo-tarpaulin \
      actionlint \
      shellspec \
      shellcheck \
      jq \
      gh \
      git \
      gpg \
      pkg-config \
      cmake \
      ar \
      awk \
      basename \
      cat \
      chgrp \
      chmod \
      chown \
      clang \
      c++ \
      cp \
      curl \
      dhclient \
      dig \
      dirname \
      distcc \
      distcc-pump \
      docker \
      envsubst \
      expect \
      find \
      flock \
      musl-gcc \
      getent \
      grep \
      gzip \
      install \
      ip \
      ld.lld \
      make \
      mkdir \
      mktemp \
      mv \
      openssl \
      printf \
      ps \
      rm \
      rsync \
      sed \
      sha256sum \
      sort \
      tar \
      tcpdump \
      tee \
      test \
      timeout \
      xargs \
      xz \
      cc \
      g++ \
    ); \
    for tool in "${required_tools[@]}"; do \
      command -v "$tool" >/dev/null; \
    done; \
    cargo --version; \
    rustc --version; \
    cargo fmt --version; \
    cargo clippy --version; \
    sccache --version; \
    ccache --version; \
    cargo audit --version; \
    cargo tarpaulin --version; \
    actionlint --version; \
    bats --version; \
    parallel --version; \
    shellspec --version; \
    shellcheck --version; \
    docker --version; \
    docker compose version; \
    docker buildx version; \
    dhclient --version; \
    expect -v; \
    printf 'PATH=%s\n' "$PATH"; \
    rustc_host_line="$(rustc -vV)"; \
    grep -qE '^host: .*-musl$' <<<"${rustc_host_line}"; \
    musl-gcc --version

# What: fail build if CI proxy CA leaked into image
# Why: CA must never persist in published build-tools
# From: PR #1752 regression | Issue #1095
RUN if [ -e /usr/local/share/ca-certificates/lancache-ci-proxy-ca.crt ]; then \
      echo "SECURITY: CI proxy CA persisted in final image" >&2; exit 1; \
    fi

WORKDIR /workspace

CMD ["bash"]
