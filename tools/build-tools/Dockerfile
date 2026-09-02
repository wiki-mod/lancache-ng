
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# CI and developer validation toolchain with Rust, sccache, ccache, distcc, and build utilities.

# What: Rust/Go latest base with ARG placement
# Why: latest for CI; ARGs precede FROM; stages in sync
# From: PR #1706
ARG DOCKER_CLI_VERSION=29.7.2
ARG DOCKER_COMPOSE_VERSION=5.5.0
ARG DOCKER_BUILDX_VERSION=0.36.1
# What: sha256 pins for official docker tool binaries.
# Why: tool self-compiles dropped; prebuilts only now.
# From: Issue #1095
ARG DOCKER_CLI_SHA256_AMD64=803d433f226db4776e1768fd319fc6c6e4935a456acf84fcc0080818b854bc8f
ARG DOCKER_CLI_SHA256_ARM64=43d143448adf2c2787704e7d7704fd6d62d367a54c5edaef0a3f75509cb0938d
ARG DOCKER_COMPOSE_SHA256_AMD64=c57ab918abd5b05ca7e7d0f275875dd1330a695074f309dc9eab1b49efafcd4b
ARG DOCKER_COMPOSE_SHA256_ARM64=ff42489f5a9b879d5d117c5ffea6defc27390b3286da8ad52cbc9c6ab5df590e
ARG DOCKER_BUILDX_SHA256_AMD64=48af8a397ebd60178778bf63611dbcebe5f5e7a9be90eb9147b24b9587455778
ARG DOCKER_BUILDX_SHA256_ARM64=5d0cafd9d16afe1a0f0d9529885344ace2cc99efdd531b6c783c5455a6001569
# What: hoists sccache/audit/tarpaulin/actionlint pins
# Why: alpine-final and final stage had duplicate values
# From: Issue #1671 | PR #1750
ARG SCCACHE_VERSION=0.17.0
ARG CARGO_AUDIT_VERSION=0.22.2
ARG CARGO_TARPAULIN_VERSION=0.37.2
ARG ACTIONLINT_VERSION=1.7.12
ARG ACTIONLINT_SHA256_AMD64=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
ARG ACTIONLINT_SHA256_ARM64=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
ARG SHELLSPEC_VERSION=0.28.1
ARG SHELLSPEC_SHA256=350d3de04ba61505c54eda31a3c2ee912700f1758b1a80a284bc08fd8b6c5992

# What: fetches checksum-verified docker CLI tools.
# Why: official release binaries replace source builds.
# From: Issue #1095
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS docker-tools-fetch

# What: explicit proxy build-args, no default value set
# Why: routes self-hosted downloads via the LAN proxy
# From: Issue #1781 | PR #1783
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

ARG DOCKER_CLI_VERSION
ARG DOCKER_COMPOSE_VERSION
ARG DOCKER_BUILDX_VERSION
ARG DOCKER_CLI_SHA256_AMD64
ARG DOCKER_CLI_SHA256_ARM64
ARG DOCKER_COMPOSE_SHA256_AMD64
ARG DOCKER_COMPOSE_SHA256_ARM64
ARG DOCKER_BUILDX_SHA256_AMD64
ARG DOCKER_BUILDX_SHA256_ARM64

SHELL ["/bin/sh", "-o", "pipefail", "-c"]

# What: downloads three binaries, verifies sha256 pins.
# Why: per-arch pins fail closed on tampered artifacts.
# From: Issue #1095
RUN set -eu; \
    apk add --no-cache curl ca-certificates; \
    case "$(apk --print-arch)" in \
      x86_64) dl_arch="x86_64"; bx_arch="amd64"; \
        cli_sha="${DOCKER_CLI_SHA256_AMD64}"; \
        compose_sha="${DOCKER_COMPOSE_SHA256_AMD64}"; \
        buildx_sha="${DOCKER_BUILDX_SHA256_AMD64}" ;; \
      aarch64) dl_arch="aarch64"; bx_arch="arm64"; \
        cli_sha="${DOCKER_CLI_SHA256_ARM64}"; \
        compose_sha="${DOCKER_COMPOSE_SHA256_ARM64}"; \
        buildx_sha="${DOCKER_BUILDX_SHA256_ARM64}" ;; \
      *) echo "unsupported arch: $(apk --print-arch)" >&2; exit 1 ;; \
    esac; \
    mkdir -p /out; \
    cli_url="https://download.docker.com/linux/static/stable/${dl_arch}/docker-${DOCKER_CLI_VERSION}.tgz"; \
    curl -fsSL "$cli_url" -o /tmp/docker.tgz; \
    echo "${cli_sha}  /tmp/docker.tgz" | sha256sum -c -; \
    tar -xzf /tmp/docker.tgz -C /tmp docker/docker; \
    install -m 0755 /tmp/docker/docker /out/docker; \
    compose_url="https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${dl_arch}"; \
    curl -fsSL "$compose_url" -o /out/docker-compose; \
    echo "${compose_sha}  /out/docker-compose" | sha256sum -c -; \
    chmod 0755 /out/docker-compose; \
    buildx_url="https://github.com/docker/buildx/releases/download/v${DOCKER_BUILDX_VERSION}/buildx-v${DOCKER_BUILDX_VERSION}.linux-${bx_arch}"; \
    curl -fsSL "$buildx_url" -o /out/docker-buildx; \
    echo "${buildx_sha}  /out/docker-buildx" | sha256sum -c -; \
    chmod 0755 /out/docker-buildx; \
    rm -rf /tmp/docker /tmp/docker.tgz; \
    /out/docker --version; \
    /out/docker-compose version; \
    /out/docker-buildx version

# What: Alpine 3.24 candidate build-tools stage
# Why: Debian default; pin avoids clang22/lld22 breakage
# From: Issue #1095
FROM rust:alpine3.24 AS alpine-final

LABEL org.opencontainers.image.description="Prebuilt lancache-ng CI and developer validation toolchain image (Alpine candidate)."

# What: explicit proxy build-args, no default value set
# Why: routes self-hosted apk/cargo pulls via the LAN proxy
# From: Issue #1781 | PR #1783
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

# What: inherits shared version pins from top-level ARGs
# Why: avoids re-declaring the same literal per stage
# From: Issue #1671 | PR #1750
ARG SCCACHE_VERSION
# What: pins cargo-audit musl binary checksum
# Why: stale pin skips verification; recomputed per version
# From: Issue #1095 | PR #1743
ARG CARGO_AUDIT_VERSION
ARG CARGO_AUDIT_SHA256_MUSL_AMD64=7fb9497f8594b389e5fce5ef9b92db08432996895b2e0c5a0167a69ed445c428
# What: pins cargo-tarpaulin musl binary checksum
# Why: stale pin skips verification; recomputed per version
# From: Issue #1095 | PR #1743
ARG CARGO_TARPAULIN_VERSION
ARG CARGO_TARPAULIN_SHA256_MUSL_AMD64=837dc54d21da101e96e888c6f6680d25f3c06554b0614880ea385cdf68cd5173
# What: pins actionlint prebuilt binary and checksums
# Why: stale pin skips verification; recomputed per version
# From: Issue #1095 | PR #1743
ARG ACTIONLINT_VERSION
ARG ACTIONLINT_SHA256_AMD64
ARG ACTIONLINT_SHA256_ARM64
ARG SHELLSPEC_VERSION
ARG SHELLSPEC_SHA256

# What: uses plain /bin/sh for the apk-install step only.
# Why: rust:alpine has no bash until that step installs it.
# From: Issue #1095
SHELL ["/bin/sh", "-c"]

ENV PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    CARGO_INSTALL_ROOT="/usr/local" \
    RUST_BACKTRACE=1

# What: declare APK_CACHE_BUST before RUN
# Why: bust layer cache on rotation; matches APT pattern
# From: Issue #1095
ARG APK_CACHE_BUST=""

# What: installs bash, coreutils, github-cli, sqlite, etc
# Why: GNU coreutils differ from BusyBox (AG-VAL-034)
# From: Issue #1095
RUN set -euo pipefail; \
    : "apk-cache-bust=${APK_CACHE_BUST}"; \
    apk update; \
    apk upgrade --no-cache; \
    apk add --no-cache \
      bash \
      bats \
      bc \
      bind-tools \
      build-base \
      ca-certificates \
      ccache \
      clang22 \
      cmake \
      coreutils \
      curl \
      distcc \
      distcc-pump \
      expect \
      findutils \
      gawk \
      gettext \
      git \
      github-cli \
      gnupg \
      grep \
      iproute2 \
      jq \
      lld22 \
      make \
      musl-dev \
      openssl \
      openssl-dev \
      openssl-libs-static \
      perl \
      pkgconf \
      procps-ng \
      python3 \
      rsync \
      sed \
      shellcheck \
      sqlite \
      tcpdump \
      tzdata \
      util-linux \
      xz \
      zlib-dev \
      zlib-static; \
    ln -sf /usr/bin/pump /usr/bin/distcc-pump; \
    distcc_bin="$(command -v distcc)"; \
    mkdir -p /usr/local/lib/distcc; \
    for wrapper in cc gcc c++ g++; do ln -sf "$distcc_bin" "/usr/local/lib/distcc/$wrapper"; done

# What: verifies the apk-installed curl actually runs
# Why: catches a missing shared-lib chain at build time
# From: Issue #1781 | PR #1783
RUN curl --version >/dev/null

# What: switches SHELL to bash for every RUN step below.
# Why: BusyBox ash cannot parse this file's bash-array use.
# From: Issue #1095
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# What: COPY --from before heavy RUN serializes build
# Why: dependency blocks compile; prevents corruption
# From: Issue #1671 | PR #1750
RUN install -d /usr/local/lib/docker/cli-plugins
COPY --from=docker-tools-fetch /out/docker /usr/local/bin/docker
COPY --from=docker-tools-fetch /out/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
COPY --from=docker-tools-fetch /out/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx
RUN docker --version; \
    docker compose version; \
    docker buildx version

# What: builds sccache from source, like the Debian stage.
# Why: prebuilt release lacks Redis+dist-client feature
# From: Issue #1095
RUN set -euo pipefail; \
    rustup component add rustfmt clippy; \
    cargo install sccache --version "${SCCACHE_VERSION}" --no-default-features --features redis,dist-client --root /usr/local; \
    for tool in cargo cargo-clippy cargo-fmt clippy-driver rustc rustdoc rustfmt rustup; do \
      ln -sf "/usr/local/cargo/bin/${tool}" "/usr/local/bin/${tool}"; \
    done; \
    rm -rf /usr/local/cargo/registry /usr/local/cargo/git

# What: fetches cargo-audit/tarpaulin musl release bins.
# Why: native musl assets exist; matches AG-KD-003 policy.
# From: Issue #1095 | PR #1743
RUN set -euo pipefail; \
    case "$(apk --print-arch)" in \
      x86_64) ;; \
      *) echo "alpine-final is amd64-only: no aarch64-musl cargo-audit release exists" >&2; exit 1 ;; \
    esac; \
    prebuilt_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$prebuilt_tmp"' EXIT; \
    curl -fsSL "https://github.com/rustsec/rustsec/releases/download/cargo-audit/v${CARGO_AUDIT_VERSION}/cargo-audit-x86_64-unknown-linux-musl-v${CARGO_AUDIT_VERSION}.tgz" \
      -o "$prebuilt_tmp/cargo-audit.tgz"; \
    printf '%s  %s\n' "${CARGO_AUDIT_SHA256_MUSL_AMD64}" "$prebuilt_tmp/cargo-audit.tgz" | sha256sum -c -; \
    tar -xzf "$prebuilt_tmp/cargo-audit.tgz" -C "$prebuilt_tmp" "cargo-audit-x86_64-unknown-linux-musl-v${CARGO_AUDIT_VERSION}/cargo-audit"; \
    install -m 0755 "$prebuilt_tmp/cargo-audit-x86_64-unknown-linux-musl-v${CARGO_AUDIT_VERSION}/cargo-audit" /usr/local/cargo/bin/cargo-audit; \
    curl -fsSL "https://github.com/xd009642/tarpaulin/releases/download/${CARGO_TARPAULIN_VERSION}/cargo-tarpaulin-x86_64-unknown-linux-musl.tar.gz" \
      -o "$prebuilt_tmp/cargo-tarpaulin.tar.gz"; \
    printf '%s  %s\n' "${CARGO_TARPAULIN_SHA256_MUSL_AMD64}" "$prebuilt_tmp/cargo-tarpaulin.tar.gz" | sha256sum -c -; \
    tar -xzf "$prebuilt_tmp/cargo-tarpaulin.tar.gz" -C "$prebuilt_tmp" cargo-tarpaulin; \
    install -m 0755 "$prebuilt_tmp/cargo-tarpaulin" /usr/local/cargo/bin/cargo-tarpaulin; \
    ln -sf /usr/local/cargo/bin/cargo-audit /usr/local/bin/cargo-audit; \
    ln -sf /usr/local/cargo/bin/cargo-tarpaulin /usr/local/bin/cargo-tarpaulin

# What: fetches actionlint checksum-verified binary
# Why: static Go binary; no reachable stdlib CVE exposure
# From: Issue #1095 | PR #1743
RUN set -euo pipefail; \
    case "$(apk --print-arch)" in \
      x86_64) actionlint_arch="amd64"; actionlint_sha256="${ACTIONLINT_SHA256_AMD64}" ;; \
      aarch64) actionlint_arch="arm64"; actionlint_sha256="${ACTIONLINT_SHA256_ARM64}" ;; \
      *) echo "Unsupported architecture for actionlint prebuilt binary: $(apk --print-arch)" >&2; exit 1 ;; \
    esac; \
    actionlint_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$actionlint_tmp"' EXIT; \
    curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${actionlint_arch}.tar.gz" \
      -o "$actionlint_tmp/actionlint.tar.gz"; \
    printf '%s  %s\n' "$actionlint_sha256" "$actionlint_tmp/actionlint.tar.gz" | sha256sum -c -; \
    tar -xzf "$actionlint_tmp/actionlint.tar.gz" -C "$actionlint_tmp" actionlint; \
    install -m 0755 "$actionlint_tmp/actionlint" /usr/local/bin/actionlint; \
    actionlint --version

RUN set -euo pipefail; \
    shellspec_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$shellspec_tmp"' EXIT; \
    curl -fsSL "https://github.com/shellspec/shellspec/releases/download/${SHELLSPEC_VERSION}/shellspec-dist.tar.gz" \
      -o "$shellspec_tmp/shellspec-dist.tar.gz"; \
    printf '%s  %s\n' "${SHELLSPEC_SHA256}" "$shellspec_tmp/shellspec-dist.tar.gz" | sha256sum -c -; \
    tar -xzf "$shellspec_tmp/shellspec-dist.tar.gz" -C /opt; \
    ln -sf /opt/shellspec/shellspec /usr/local/bin/shellspec; \
    shellspec --version

# What: Alpine 3.24 lacks dhclient; uses busybox udhcpc
# Why: udhcpc ships in busybox base, nothing to install
# From: Issue #1095

# What: symlink musl-gcc to gcc; gcc targets musl already
# Why: required by dns/ui/watchdog; avoids duplicate binary
# From: Issue #1095 | PR #1691
RUN ln -sf /usr/bin/gcc /usr/local/bin/musl-gcc

# What: no separate musl cross-compile step, unlike Debian.
# Why: musl is already this image's default rustc triple.
# From: Issue #1095
RUN set -euo pipefail; \
    required_tools=( \
      bash \
      bats \
      cargo \
      rustc \
      rustup \
      rustfmt \
      clippy-driver \
      sccache \
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
      ccache \
      cp \
      curl \
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
    shellspec --version; \
    shellcheck --version; \
    docker --version; \
    docker compose version; \
    docker buildx version; \
    expect -v; \
    printf 'PATH=%s\n' "$PATH"; \
    case ":$PATH:" in \
      *:/usr/local/cargo/bin:*) ;; \
      *) echo "/usr/local/cargo/bin is missing from PATH" >&2; exit 1 ;; \
    esac; \
    rustc_host_line="$(rustc -vV)"; \
    grep -qE '^host: .*-musl$' <<<"${rustc_host_line}"; \
    musl-gcc --version

WORKDIR /workspace

CMD ["bash"]

FROM rust:latest

LABEL org.opencontainers.image.description="Prebuilt lancache-ng CI and developer validation toolchain image."

# What: explicit proxy build-args, no default value set
# Why: routes self-hosted apt/cargo pulls via the LAN proxy
# From: Issue #1781 | PR #1783
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

# What: inherits shared version pins from top-level ARGs
# Why: avoids re-declaring the same literal per stage
# From: Issue #1671 | PR #1750
ARG SCCACHE_VERSION
ARG CARGO_AUDIT_VERSION
ARG CARGO_AUDIT_SHA256_AMD64=ab28a1bdb54db4d5d8ad5981cf1f959410370b3d28250dbd35f6a44248620e39
ARG CARGO_AUDIT_SHA256_ARM64=c6603814ddaa45e51263dafd31c0ac98808f688d26f7395804f9670b0fd599dd
# What: pins cargo-tarpaulin binary and SHA256 checksums
# Why: stale checksum breaks build verification silently
# From: Issue #1570 | PR #1571
ARG CARGO_TARPAULIN_VERSION
ARG CARGO_TARPAULIN_SHA256_AMD64=8e47625d26c3c265886faf1ef8cfa3ccaf071abc87bf4854ef8e239f5ffeabd8
ARG CARGO_TARPAULIN_SHA256_ARM64=c8cc929a259871cfe4e3cda6e31975abe33b9b0a6078b76cbd466b6494c72792
# What: pins actionlint prebuilt binary and checksums
# Why: stale pin skips verification; recomputed per version
# From: Issue #1095 | PR #1743
ARG ACTIONLINT_VERSION
ARG ACTIONLINT_SHA256_AMD64
ARG ACTIONLINT_SHA256_ARM64
ARG DISTCC_PUMP_PACKAGE_VERSION=3.4+really3.4-12
ARG SHELLSPEC_VERSION
ARG SHELLSPEC_SHA256
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    CARGO_INSTALL_ROOT="/usr/local" \
    RUST_BACKTRACE=1

# What: add trixie-backports source and apt pin; upgrade
# Why: get all patches; pin uses a= suite not codename
# From: Issue #1570 | PR #1571
RUN echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/backports.list \
    && printf 'Package: *\nPin: release a=stable-backports\nPin-Priority: 500\n' > /etc/apt/preferences.d/backports \
    && apt-get update \
    && apt-get dist-upgrade -y \
    && apt-get full-upgrade -y \
    && rm -rf /var/lib/apt/lists/*

# What: install ccache, sqlite3, git, and other tools
# Why: ccache for C-deps; sqlite3 for audit; git for CI
# From: Issue #1585
RUN set -euo pipefail; \
      apt-get update; \
      apt-get install -y --no-install-recommends \
      bash \
      bats \
      bc \
      build-essential \
      ca-certificates \
      ccache \
      clang \
      cmake \
      curl \
      expect \
      gh \
      git \
      jq \
      lld \
      make \
      pkg-config \
      shellcheck \
      sqlite3 \
      xz-utils; \
      apt-get dist-upgrade -yy; \
      apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

# What: purges Cairo/GLib/ImageMagick/MariaDB dev bloat.
# Why: self-build's purge cascaded this away; now separate.
# From: Issue #1095 | PR #1743
RUN set -euo pipefail; \
    apt-get purge -y \
      default-libmysqlclient-dev \
      libcairo2-dev \
      libcurl4-openssl-dev \
      libfontconfig-dev \
      libfreetype-dev \
      libgdk-pixbuf-2.0-dev \
      libgio-2.0-dev \
      libglib2.0-dev \
      libharfbuzz-dev \
      libmagickcore-dev \
      libmagickwand-dev \
      libmariadb-dev \
      libmariadb-dev-compat \
      libopenexr-dev \
      libpango1.0-dev \
      libpng-dev \
      libpq-dev \
      librsvg2-dev \
      librtmp-dev \
      libssh2-1-dev \
      libtiff-dev \
      libwmf-dev \
      libxft-dev; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

# What: verifies the apt-installed curl actually runs
# Why: catches a missing shared-lib chain at build time
# From: Issue #1781 | PR #1783
RUN curl --version >/dev/null

# What: COPY --from before heavy RUN serializes build
# Why: dependency blocks compile; prevents corruption
# From: Issue #1671 | PR #1750
RUN install -d /usr/local/lib/docker/cli-plugins
COPY --from=docker-tools-fetch /out/docker /usr/local/bin/docker
COPY --from=docker-tools-fetch /out/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
COPY --from=docker-tools-fetch /out/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx
RUN docker --version; \
    docker compose version; \
    docker buildx version

# What: build sccache with redis/dist-client only
# Why: excludes unused backends; smaller binary
# From: Issue #1570 | PR #1571
RUN set -euo pipefail; \
    rustup component add rustfmt clippy; \
    cargo install sccache --version "${SCCACHE_VERSION}" --no-default-features --features redis,dist-client --root /usr/local; \
    for tool in cargo cargo-clippy cargo-fmt clippy-driver rustc rustdoc rustfmt rustup; do \
      ln -sf "/usr/local/cargo/bin/${tool}" "/usr/local/bin/${tool}"; \
    done; \
    rm -rf /usr/local/cargo/registry /usr/local/cargo/git

# What: keep dhclient for DHCP/Kea simulation scripts
# Why: Admin UI probe native Rust; dhclient for CI tests
# From: Issue #1570 | PR #1571

# What: tcpdump for DHCP-PXE-simulation pcap capture
# Why: live sniff misses replies from Docker bridge network
# From: Issue #1570 | PR #1571

# What: declare APT_CACHE_BUST right before this RUN
# Why: declaration affects cache-key; busts on rotation
# From: Issue #1570 | PR #1571
ARG APT_CACHE_BUST=""
RUN set -euo pipefail; \
    : "apt-cache-bust=${APT_CACHE_BUST}"; \
    distcc_pump_tmp=""; \
    cleanup_build_tools_apt() { \
        if [ -n "${distcc_pump_tmp}" ]; then rm -rf "${distcc_pump_tmp}"; fi; \
        rm -f /usr/sbin/invoke-rc.d; \
        if [ -x /usr/sbin/invoke-rc.d.real ]; then mv /usr/sbin/invoke-rc.d.real /usr/sbin/invoke-rc.d; fi; \
    }; \
    trap cleanup_build_tools_apt EXIT; \
    # What: replace invoke-rc.d with no-op; restore via trap
    # Why: distcc-pump needs init; container has none
    # From: Issue #1570 | PR #1571
    if [ -x /usr/sbin/invoke-rc.d ]; then mv /usr/sbin/invoke-rc.d /usr/sbin/invoke-rc.d.real; fi; \
    printf '%s\n' '#!/bin/sh' 'exit 0' > /usr/sbin/invoke-rc.d; \
    chmod +x /usr/sbin/invoke-rc.d; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      bind9-dnsutils \
      distcc \
      gettext-base \
      gnupg \
      iproute2 \
      isc-dhcp-client \
      openssl \
      procps \
      python3 \
      rsync \
      tcpdump; \
    # What: run dist-upgrade then full-upgrade before patch
    # Why: fetch fixes after rust:latest; both verbs needed
    # From: Issue #1570 | PR #1571
    apt-get dist-upgrade -y; \
    apt-get full-upgrade -y; \
    # What: force-upgrade jq/libjq1/libpq for known CVEs
    # Why: jq/libpq pulled transitively with CVE exposure
    # From: Issue #1570 | PR #1571
    apt-get install -y --no-install-recommends --only-upgrade linux-libc-dev jq libjq1 libpq-dev libpq5; \
    distcc_pump_tmp="$(mktemp -d)"; \
    chmod 0755 "${distcc_pump_tmp}"; \
    # What: chown temp dir to _apt:root for apt-get
    # Why: apt-get download runs as _apt; needs ownership
    # From: Issue #1570 | PR #1571
    chown _apt:root "${distcc_pump_tmp}"; \
    (cd "${distcc_pump_tmp}" && apt-get download "distcc-pump=${DISTCC_PUMP_PACKAGE_VERSION}"); \
    dpkg --unpack "${distcc_pump_tmp}"/distcc-pump_*.deb; \
    distcc_pump_parser="/usr/lib/python3/dist-packages/include_server/parse_command.py"; \
    grep -F "'-Wa,(%s\\.s)'" "${distcc_pump_parser}" >/dev/null; \
    grep -F "'-Wa,\\[(%s\\.s)\\]'" "${distcc_pump_parser}" >/dev/null; \
    # What: patch Python regex escapes before dpkg configure
    # Why: Debian distcc-pump ships invalid regex escapes
    # From: Issue #1570 | PR #1571
    sed -i \
      -e 's/%s\\.s/%s\\\\.s/g' \
      -e 's/-Wa,\\\[/-Wa,\\\\[/g' \
      -e 's/)\\\]/)\\\\]/g' \
      "${distcc_pump_parser}"; \
    grep -F "'-Wa,(%s\\\\.s)'" "${distcc_pump_parser}" >/dev/null; \
    grep -F "'-Wa,\\\\[(%s\\\\.s)\\\\]'" "${distcc_pump_parser}" >/dev/null; \
    python3 -Werror::SyntaxWarning -m py_compile "${distcc_pump_parser}"; \
    dpkg --configure distcc-pump; \
    python3 -Werror::SyntaxWarning -m compileall -q /usr/lib/python3/dist-packages/include_server; \
    distcc_bin="$(command -v distcc)"; \
    mkdir -p /usr/local/lib/distcc; \
    for wrapper in cc gcc c++ g++; do ln -sf "$distcc_bin" "/usr/local/lib/distcc/$wrapper"; done; \
    rm -rf /var/lib/apt/lists/*

# What: fetches cargo-audit/tarpaulin prebuilt binaries.
# Why: no behavioral diff building Rust tools from source.
# From: Issue #1095 | PR #1743
RUN set -euo pipefail; \
    case "$(dpkg --print-architecture)" in \
      amd64) \
        cargo_audit_arch="x86_64-unknown-linux-gnu"; cargo_audit_sha256="${CARGO_AUDIT_SHA256_AMD64}"; \
        tarpaulin_arch="x86_64-unknown-linux-gnu"; tarpaulin_sha256="${CARGO_TARPAULIN_SHA256_AMD64}" \
        ;; \
      arm64) \
        cargo_audit_arch="aarch64-unknown-linux-gnu"; cargo_audit_sha256="${CARGO_AUDIT_SHA256_ARM64}"; \
        tarpaulin_arch="aarch64-unknown-linux-gnu"; tarpaulin_sha256="${CARGO_TARPAULIN_SHA256_ARM64}" \
        ;; \
      *) echo "Unsupported architecture for prebuilt CI tool binaries: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    prebuilt_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$prebuilt_tmp"' EXIT; \
    curl -fsSL "https://github.com/rustsec/rustsec/releases/download/cargo-audit/v${CARGO_AUDIT_VERSION}/cargo-audit-${cargo_audit_arch}-v${CARGO_AUDIT_VERSION}.tgz" \
      -o "$prebuilt_tmp/cargo-audit.tgz"; \
    printf '%s  %s\n' "$cargo_audit_sha256" "$prebuilt_tmp/cargo-audit.tgz" | sha256sum -c -; \
    tar -xzf "$prebuilt_tmp/cargo-audit.tgz" -C "$prebuilt_tmp" "cargo-audit-${cargo_audit_arch}-v${CARGO_AUDIT_VERSION}/cargo-audit"; \
    install -m 0755 "$prebuilt_tmp/cargo-audit-${cargo_audit_arch}-v${CARGO_AUDIT_VERSION}/cargo-audit" /usr/local/cargo/bin/cargo-audit; \
    curl -fsSL "https://github.com/xd009642/tarpaulin/releases/download/${CARGO_TARPAULIN_VERSION}/cargo-tarpaulin-${tarpaulin_arch}.tar.gz" \
      -o "$prebuilt_tmp/cargo-tarpaulin.tar.gz"; \
    printf '%s  %s\n' "$tarpaulin_sha256" "$prebuilt_tmp/cargo-tarpaulin.tar.gz" | sha256sum -c -; \
    tar -xzf "$prebuilt_tmp/cargo-tarpaulin.tar.gz" -C "$prebuilt_tmp" cargo-tarpaulin; \
    install -m 0755 "$prebuilt_tmp/cargo-tarpaulin" /usr/local/cargo/bin/cargo-tarpaulin; \
    ln -sf /usr/local/cargo/bin/cargo-audit /usr/local/bin/cargo-audit; \
    ln -sf /usr/local/cargo/bin/cargo-tarpaulin /usr/local/bin/cargo-tarpaulin

# What: fetches actionlint checksum-verified binary
# Why: static Go binary; no reachable stdlib CVE exposure
# From: Issue #1095 | PR #1743
RUN set -euo pipefail; \
    case "$(dpkg --print-architecture)" in \
      amd64) actionlint_arch="amd64"; actionlint_sha256="${ACTIONLINT_SHA256_AMD64}" ;; \
      arm64) actionlint_arch="arm64"; actionlint_sha256="${ACTIONLINT_SHA256_ARM64}" ;; \
      *) echo "Unsupported architecture for actionlint prebuilt binary: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    actionlint_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$actionlint_tmp"' EXIT; \
    curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${actionlint_arch}.tar.gz" \
      -o "$actionlint_tmp/actionlint.tar.gz"; \
    printf '%s  %s\n' "$actionlint_sha256" "$actionlint_tmp/actionlint.tar.gz" | sha256sum -c -; \
    tar -xzf "$actionlint_tmp/actionlint.tar.gz" -C "$actionlint_tmp" actionlint; \
    install -m 0755 "$actionlint_tmp/actionlint" /usr/local/bin/actionlint; \
    actionlint --version

RUN set -euo pipefail; \
    shellspec_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$shellspec_tmp"' EXIT; \
    curl -fsSL "https://github.com/shellspec/shellspec/releases/download/${SHELLSPEC_VERSION}/shellspec-dist.tar.gz" \
      -o "$shellspec_tmp/shellspec-dist.tar.gz"; \
    printf '%s  %s\n' "${SHELLSPEC_SHA256}" "$shellspec_tmp/shellspec-dist.tar.gz" | sha256sum -c -; \
    tar -xzf "$shellspec_tmp/shellspec-dist.tar.gz" -C /opt; \
    ln -sf /opt/shellspec/shellspec /usr/local/bin/shellspec; \
    shellspec --version

# What: add musl-libc for cross-compilation static builds
# Why: services/ui/dns need static PIE; native-arch only
# From: Issue #1570 | PR #1571
RUN set -euo pipefail; \
    case "$(dpkg --print-architecture)" in \
      amd64) musl_target="x86_64-unknown-linux-musl" ;; \
      arm64) musl_target="aarch64-unknown-linux-musl" ;; \
      *) echo "Unsupported architecture for musl cross-compilation target: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      musl-dev \
      musl-tools; \
    rustup target add "${musl_target}"; \
    rm -rf /var/lib/apt/lists/*

# What: capture tool output to variables before grepping
# Why: prevents SIGPIPE when grep -q exits early
# From: Issue #1570 | PR #1571
RUN set -euo pipefail; \
    required_tools=( \
      bash \
      bats \
      cargo \
      rustc \
      rustup \
      rustfmt \
      clippy-driver \
      sccache \
      cargo-audit \
      cargo-tarpaulin \
      actionlint \
      shellspec \
      shellcheck \
      jq \
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
      ccache \
      cp \
      curl \
      dhclient \
      dig \
      dirname \
      distcc \
      gh \
      distcc-pump \
      docker \
      dpkg \
      envsubst \
      expect \
      find \
      flock \
      getent \
      grep \
      gzip \
      install \
      ip \
      ld.lld \
      make \
      mkdir \
      mktemp \
      musl-gcc \
      mv \
      openssl \
      printf \
      ps \
      ranlib \
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
    shellspec --version; \
    shellcheck --version; \
    docker --version; \
    docker compose version; \
    docker buildx version; \
    expect -v; \
    printf 'PATH=%s\n' "$PATH"; \
    case ":$PATH:" in \
      *:/usr/local/cargo/bin:*) ;; \
      *) echo "/usr/local/cargo/bin is missing from PATH" >&2; exit 1 ;; \
    esac; \
    bash -lc 'set -euo pipefail; cargo --version; rustc --version; rustfmt --version; cargo clippy --version'; \
    musl-gcc --version; \
    case "$(dpkg --print-architecture)" in \
      amd64) musl_target_check="x86_64-unknown-linux-musl" ;; \
      arm64) musl_target_check="aarch64-unknown-linux-musl" ;; \
      *) echo "Unsupported architecture for musl target verification: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    installed_targets="$(rustup target list --installed)"; \
    grep -qx "${musl_target_check}" <<<"${installed_targets}"; \
    rustc_host_line="$(rustc -vV)"; \
    grep -qE '^host: .*-gnu$' <<<"${rustc_host_line}"

# What: default WORKDIR for interactive/manual container use
# Why: CI always bind-mounts /work; not a real default here
# From: Issue #1671 | PR #1750
WORKDIR /workspace

CMD ["bash"]
