
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# CI and developer validation toolchain with Rust, sccache, ccache, distcc, and build utilities.

# What: Rust/Go latest base with ARG placement
# Why: latest for CI; ARGs precede FROM; stages in sync
# From: PR #1706
ARG DOCKER_CLI_VERSION=29.8.0
ARG DOCKER_COMPOSE_VERSION=5.5.1
ARG DOCKER_BUILDX_VERSION=0.37.0
# What: pins the official docker CLI static-bundle sha256.
# Why: verifies the prebuilt binary; no source build.
# From: Issue #1671
ARG DOCKER_CLI_SHA256_AMD64=cc21815cf1e2efed867dc9c8b96b46ffed8ea176ffab32b0aacb54726ded8f25
ARG DOCKER_CLI_SHA256_ARM64=1462a696be6029bd478d7d60d7f3c31cdd15affd1178a4a278aaf4a1d1b7f8b5
# What: pins the official docker-compose release sha256.
# Why: verifies the prebuilt plugin; no source build.
# From: Issue #1671
ARG DOCKER_COMPOSE_SHA256_AMD64=db1889184726840f75c4f9c001048430d4f25b3be3cb084d3ddd762bc0aed576
ARG DOCKER_COMPOSE_SHA256_ARM64=732e3a84c1a0f67256ce80bc2598a24546b10ca05f9faa97efceb1171ece2ef7
# What: pins the official docker-buildx release sha256.
# Why: verifies the prebuilt plugin; no source build.
# From: Issue #1671
ARG DOCKER_BUILDX_SHA256_AMD64=ae43fa08c796b44efc86d7a63c55f73f7c35f3101188dea7bf93bcd6f99577ba
ARG DOCKER_BUILDX_SHA256_ARM64=d263ce31bd2c9e9210aaa2c7537c67802bccabcd342e4c9fe4907085ddb41aa5
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

# What: holds the shared CA-install script for later stages.
# Why: several stages trust the LAN proxy CA identically.
# From: Issue #1095
FROM scratch AS go-tools-script

# What: trusts the LAN proxy's re-signing CA when set.
# Why: shared by every stage fetching https via Squid.
# From: Issue #1095
COPY <<'INSTALL_CA_CERT_EOF' /install-ca-cert.sh
#!/bin/sh
set -eu
if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then
  cp /run/secrets/project_selfhosted_proxy_ca /usr/local/share/ca-certificates/lancache-ci-proxy-ca.crt
  update-ca-certificates
fi
INSTALL_CA_CERT_EOF

# What: downloads prebuilt docker CLI/compose/buildx.
# Why: official static release binaries, not a source build.
# From: Issue #1671
FROM alpine:latest AS binary-downloader

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

# What: Go cache-mount + GOPROXY targets from self-hosted vars.
# Why: single source of truth; ready when a Go build returns.
# From: Issue #1671
ARG PROJECT_SELFHOSTED_GOMODCACHE=/go/pkg/mod
ARG PROJECT_SELFHOSTED_GOCACHE=/root/.cache/go-build
ARG PROJECT_SELFHOSTED_GOPROXY=

COPY --from=go-tools-script /install-ca-cert.sh /install-ca-cert.sh

# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: downloads+verifies the three prebuilt docker tools.
# Why: official static binaries replace the from-source build.
# From: Issue #1671
RUN --mount=type=cache,target=${PROJECT_SELFHOSTED_GOMODCACHE},sharing=locked \
    --mount=type=cache,target=${PROJECT_SELFHOSTED_GOCACHE},sharing=locked \
    --mount=type=secret,id=project_selfhosted_proxy_ca set -eu; \
    apk update; \
    apk add --no-cache ca-certificates curl tar; \
    sh /install-ca-cert.sh; \
    case "$(apk --print-arch)" in \
      x86_64) \
        docker_arch=x86_64; buildx_arch=amd64; \
        docker_sha256="${DOCKER_CLI_SHA256_AMD64}"; \
        compose_sha256="${DOCKER_COMPOSE_SHA256_AMD64}"; \
        buildx_sha256="${DOCKER_BUILDX_SHA256_AMD64}" \
        ;; \
      aarch64) \
        docker_arch=aarch64; buildx_arch=arm64; \
        docker_sha256="${DOCKER_CLI_SHA256_ARM64}"; \
        compose_sha256="${DOCKER_COMPOSE_SHA256_ARM64}"; \
        buildx_sha256="${DOCKER_BUILDX_SHA256_ARM64}" \
        ;; \
      *) echo "Unsupported architecture: $(apk --print-arch)" >&2; exit 1 ;; \
    esac; \
    install -d /out; \
    tmp="$(mktemp -d)"; \
    trap 'rm -rf "$tmp"' EXIT; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_CLI_VERSION}.tgz" -o "$tmp/docker.tgz"; \
    printf '%s  %s\n' "$docker_sha256" "$tmp/docker.tgz" | sha256sum -c -; \
    tar -xzf "$tmp/docker.tgz" -C "$tmp" docker/docker; \
    install -m 0755 "$tmp/docker/docker" /out/docker; \
    curl -fsSL "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${docker_arch}" -o "$tmp/docker-compose"; \
    printf '%s  %s\n' "$compose_sha256" "$tmp/docker-compose" | sha256sum -c -; \
    install -m 0755 "$tmp/docker-compose" /out/docker-compose; \
    curl -fsSL "https://github.com/docker/buildx/releases/download/v${DOCKER_BUILDX_VERSION}/buildx-v${DOCKER_BUILDX_VERSION}.linux-${buildx_arch}" -o "$tmp/docker-buildx"; \
    printf '%s  %s\n' "$buildx_sha256" "$tmp/docker-buildx" | sha256sum -c -; \
    install -m 0755 "$tmp/docker-buildx" /out/docker-buildx; \
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
# What: pins cargo-tarpaulin musl binary checksums
# Why: stale pin skips verification; recomputed per version
# From: Issue #1683
ARG CARGO_TARPAULIN_VERSION
ARG CARGO_TARPAULIN_SHA256_MUSL_AMD64=837dc54d21da101e96e888c6f6680d25f3c06554b0614880ea385cdf68cd5173
ARG CARGO_TARPAULIN_SHA256_MUSL_ARM64=f94bfd24784134d03b61872d0f52f192325a9a2b0511d09fab37acb84e65a603
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

# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: installs bash, coreutils, github-cli, sqlite, etc
# Why: GNU coreutils differ from BusyBox (AG-VAL-034)
# From: Issue #1095
# What: trusts the proxy CA for this RUN, re-applied below.
# Why: ca-certificates install resets the bundle mid-RUN.
# From: Issue #1781 | PR #1783
RUN --mount=type=secret,id=project_selfhosted_proxy_ca set -euo pipefail; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /tmp/ca-bundle.orig; \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi; \
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
      cargo-audit \
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
      run-parts \
      sccache \
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
    for wrapper in cc gcc c++ g++; do ln -sf "$distcc_bin" "/usr/local/lib/distcc/$wrapper"; done; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then mv /tmp/ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

# What: verifies the apk-installed curl actually runs
# Why: catches a missing shared-lib chain at build time
# From: Issue #1781 | PR #1783
RUN curl --version >/dev/null

# What: switches SHELL to bash for every RUN step below.
# Why: BusyBox ash cannot parse this file's bash-array use.
# From: Issue #1095
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# What: copies the prebuilt docker/compose/buildx binaries.
# Why: from binary-downloader; each verified by checksum.
# From: Issue #1671
RUN install -d /usr/local/lib/docker/cli-plugins
COPY --from=binary-downloader /out/docker /usr/local/bin/docker
COPY --from=binary-downloader /out/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
COPY --from=binary-downloader /out/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx
RUN docker --version; \
    docker compose version; \
    docker buildx version

COPY --from=go-tools-script /install-ca-cert.sh /install-ca-cert.sh

# What: adds rustfmt and clippy rustup components.
# Why: rust:alpine ships neither; smoke and CI need them.
# From: Issue #1683
RUN --mount=type=secret,id=project_selfhosted_proxy_ca set -euo pipefail; \
    # What: drop CI proxy CA before layer commit
    # Why: CA must never persist in published image
    # From: PR #1752 regression | Issue #1095
    trap 'rm -f /usr/local/share/ca-certificates/lancache-ci-proxy-ca.crt; update-ca-certificates >/dev/null 2>&1 || true' EXIT; \
    sh /install-ca-cert.sh; \
    rustup component add rustfmt clippy; \
    for tool in cargo cargo-clippy cargo-fmt clippy-driver rustc rustdoc rustfmt rustup; do \
      ln -sf "/usr/local/cargo/bin/${tool}" "/usr/local/bin/${tool}"; \
    done; \
    rm -rf /usr/local/cargo/registry /usr/local/cargo/git

# What: fetches cargo-audit/tarpaulin musl release bins.
# Why: native musl assets exist; matches AG-KD-003 policy.
# From: Issue #1095 | PR #1743
# What: trusts the proxy's CA for this RUN, never in a layer.
# Why: a secret mount never persists; bundle restored below.
# From: Issue #1781 | PR #1783
RUN --mount=type=secret,id=project_selfhosted_proxy_ca set -euo pipefail; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /tmp/ca-bundle.orig; \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi; \
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
    ln -sf /usr/local/cargo/bin/cargo-tarpaulin /usr/local/bin/cargo-tarpaulin; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then mv /tmp/ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

# What: fetches actionlint checksum-verified binary
# Why: static Go binary; no reachable stdlib CVE exposure
# From: Issue #1095 | PR #1743
# What: trusts the proxy's CA for this RUN, never in a layer.
# Why: a secret mount never persists; bundle restored below.
# From: Issue #1781 | PR #1783
RUN --mount=type=secret,id=project_selfhosted_proxy_ca set -euo pipefail; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /tmp/ca-bundle.orig; \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi; \
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
    actionlint --version; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then mv /tmp/ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

# What: trusts the proxy's CA for this RUN, never in a layer.
# Why: a secret mount never persists; bundle restored below.
# From: Issue #1781 | PR #1783
RUN --mount=type=secret,id=project_selfhosted_proxy_ca set -euo pipefail; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /tmp/ca-bundle.orig; \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi; \
    shellspec_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$shellspec_tmp"' EXIT; \
    curl -fsSL "https://github.com/shellspec/shellspec/releases/download/${SHELLSPEC_VERSION}/shellspec-dist.tar.gz" \
      -o "$shellspec_tmp/shellspec-dist.tar.gz"; \
    printf '%s  %s\n' "${SHELLSPEC_SHA256}" "$shellspec_tmp/shellspec-dist.tar.gz" | sha256sum -c -; \
    tar -xzf "$shellspec_tmp/shellspec-dist.tar.gz" -C /opt; \
    ln -sf /opt/shellspec/shellspec /usr/local/bin/shellspec; \
    shellspec --version; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then mv /tmp/ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

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

# What: fail build if CI proxy CA leaked into image
# Why: CA must never persist in published build-tools
# From: PR #1752 regression | Issue #1095
RUN if [ -e /usr/local/share/ca-certificates/lancache-ci-proxy-ca.crt ]; then \
      echo "SECURITY: CI proxy CA persisted in final image" >&2; exit 1; \
    fi

WORKDIR /workspace

CMD ["bash"]
