# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# CI and developer validation toolchain with Rust, sccache, distcc, and build utilities.
#
# Intentional build-tools default: use rust:latest so developer and CI
# validation sees current Rust tooling early. Production service Dockerfiles
# stay separately pinned for reproducible runtime image builds.
FROM rust:latest

LABEL org.opencontainers.image.description="Prebuilt lancache-ng CI and developer validation toolchain image."

ARG SCCACHE_VERSION=0.16.0
ARG ACTIONLINT_VERSION=1.7.12
ARG ACTIONLINT_SHA256_AMD64=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
ARG ACTIONLINT_SHA256_ARM64=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
ARG CARGO_AUDIT_VERSION=0.22.2
ARG CARGO_AUDIT_SHA256_AMD64=ab28a1bdb54db4d5d8ad5981cf1f959410370b3d28250dbd35f6a44248620e39
ARG CARGO_AUDIT_SHA256_ARM64=c6603814ddaa45e51263dafd31c0ac98808f688d26f7395804f9670b0fd599dd
# Verified against the live crates.io index during development of the coverage
# CI job (a plain `cargo install cargo-tarpaulin` resolved to this exact
# version); re-verify before bumping if this drifts from the latest release.
ARG CARGO_TARPAULIN_VERSION=0.37.0
ARG CARGO_TARPAULIN_SHA256_AMD64=398ca437e9f2b2baee46ef9d3d03966112f03f2cce8b1655a8ba0b61cef08bff
ARG CARGO_TARPAULIN_SHA256_ARM64=d6ae06b7126fb44414dd65165f9aec9e330146513f709af69e6a7927093f277a
ARG DISTCC_PUMP_PACKAGE_VERSION=3.4+really3.4-12
ARG DOCKER_CLI_VERSION=29.6.1
ARG DOCKER_COMPOSE_VERSION=5.2.0
ARG SHELLSPEC_VERSION=0.28.1
ARG SHELLSPEC_SHA256=350d3de04ba61505c54eda31a3c2ee912700f1758b1a80a284bc08fd8b6c5992
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    CARGO_INSTALL_ROOT="/usr/local" \
    RUST_BACKTRACE=1

RUN set -euo pipefail; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      bash \
      bats \
      bc \
      build-essential \
      ca-certificates \
      clang \
      cmake \
      curl \
      git \
      jq \
      libssl-dev \
      lld \
      make \
      pkg-config \
      shellcheck \
      xz-utils; \
    rm -rf /var/lib/apt/lists/*

# Keep sccache source-built and version-pinned: the official release binary's
# default feature set also bundles s3/memcached/gcs/azure/gha/webdav/oss/cos
# backends this project never uses, so building --no-default-features with
# only the two backends actually needed (Redis and sccache-dist client
# support) keeps the binary smaller and its dependency surface narrower.
RUN set -euo pipefail; \
    rustup component add rustfmt clippy; \
    cargo install sccache --version "${SCCACHE_VERSION}" --no-default-features --features redis,dist-client --root /usr/local; \
    for tool in cargo cargo-clippy cargo-fmt clippy-driver rustc rustdoc rustfmt rustup; do \
      ln -sf "/usr/local/cargo/bin/${tool}" "/usr/local/bin/${tool}"; \
    done; \
    rm -rf /usr/local/cargo/registry /usr/local/cargo/git

# actionlint, cargo-audit, and cargo-tarpaulin all publish prebuilt release
# binaries -- unlike sccache, none of them need a non-default feature set, so
# building them from source would only add a compiler dependency (a Go
# toolchain, in actionlint's case) for no behavioral difference. Fetch and
# checksum-verify the official release asset for each instead, matching the
# existing docker/docker-compose/shellspec pattern below.
RUN set -euo pipefail; \
    case "$(dpkg --print-architecture)" in \
      amd64) \
        actionlint_arch="linux_amd64"; actionlint_sha256="${ACTIONLINT_SHA256_AMD64}"; \
        cargo_audit_arch="x86_64-unknown-linux-gnu"; cargo_audit_sha256="${CARGO_AUDIT_SHA256_AMD64}"; \
        tarpaulin_arch="x86_64-unknown-linux-gnu"; tarpaulin_sha256="${CARGO_TARPAULIN_SHA256_AMD64}" \
        ;; \
      arm64) \
        actionlint_arch="linux_arm64"; actionlint_sha256="${ACTIONLINT_SHA256_ARM64}"; \
        cargo_audit_arch="aarch64-unknown-linux-gnu"; cargo_audit_sha256="${CARGO_AUDIT_SHA256_ARM64}"; \
        tarpaulin_arch="aarch64-unknown-linux-gnu"; tarpaulin_sha256="${CARGO_TARPAULIN_SHA256_ARM64}" \
        ;; \
      *) echo "Unsupported architecture for prebuilt CI tool binaries: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    prebuilt_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$prebuilt_tmp"' EXIT; \
    curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_${actionlint_arch}.tar.gz" \
      -o "$prebuilt_tmp/actionlint.tar.gz"; \
    printf '%s  %s\n' "$actionlint_sha256" "$prebuilt_tmp/actionlint.tar.gz" | sha256sum -c -; \
    tar -xzf "$prebuilt_tmp/actionlint.tar.gz" -C "$prebuilt_tmp" actionlint; \
    install -m 0755 "$prebuilt_tmp/actionlint" /usr/local/bin/actionlint; \
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

RUN set -euo pipefail; \
    shellspec_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$shellspec_tmp"' EXIT; \
    curl -fsSL "https://github.com/shellspec/shellspec/releases/download/${SHELLSPEC_VERSION}/shellspec-dist.tar.gz" \
      -o "$shellspec_tmp/shellspec-dist.tar.gz"; \
    printf '%s  %s\n' "${SHELLSPEC_SHA256}" "$shellspec_tmp/shellspec-dist.tar.gz" | sha256sum -c -; \
    tar -xzf "$shellspec_tmp/shellspec-dist.tar.gz" -C /opt; \
    ln -sf /opt/shellspec/shellspec /usr/local/bin/shellspec; \
    shellspec --version

RUN set -euo pipefail; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) docker_arch="x86_64"; compose_arch="x86_64" ;; \
      arm64) docker_arch="aarch64"; compose_arch="aarch64" ;; \
      *) echo "Unsupported Docker CLI architecture: $arch" >&2; exit 1 ;; \
    esac; \
    docker_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$docker_tmp"' EXIT; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_CLI_VERSION}.tgz" \
      -o "$docker_tmp/docker.tgz"; \
    tar -xzf "$docker_tmp/docker.tgz" -C "$docker_tmp"; \
    install -m 0755 "$docker_tmp/docker/docker" /usr/local/bin/docker; \
    install -d /usr/local/lib/docker/cli-plugins; \
    curl -fsSL "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${compose_arch}" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose; \
    chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose; \
    docker --version; \
    docker compose version

RUN set -euo pipefail; \
    distcc_pump_tmp=""; \
    cleanup_build_tools_apt() { \
        if [ -n "${distcc_pump_tmp}" ]; then rm -rf "${distcc_pump_tmp}"; fi; \
        rm -f /usr/sbin/invoke-rc.d; \
        if [ -x /usr/sbin/invoke-rc.d.real ]; then mv /usr/sbin/invoke-rc.d.real /usr/sbin/invoke-rc.d; fi; \
    }; \
    trap cleanup_build_tools_apt EXIT; \
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
      openssl \
      procps \
      python3 \
      rsync; \
    # Base and tool packages can receive security fixes after the upstream
    # rust:latest image was published. Apply Debian upgrades before patching
    # distcc-pump so package updates cannot overwrite the warning fix below.
    apt-get upgrade -y; \
    # linux-libc-dev is pulled in by the toolchain layer and can lag behind the
    # base image even after a generic upgrade; force the current security-fixed
    # package so Trivy does not fail the build-tools image on stale headers.
    apt-get install -y --no-install-recommends --only-upgrade linux-libc-dev; \
    distcc_pump_tmp="$(mktemp -d)"; \
    chmod 0755 "${distcc_pump_tmp}"; \
    chown _apt:root "${distcc_pump_tmp}"; \
    (cd "${distcc_pump_tmp}" && apt-get download "distcc-pump=${DISTCC_PUMP_PACKAGE_VERSION}"); \
    dpkg --unpack "${distcc_pump_tmp}"/distcc-pump_*.deb; \
    distcc_pump_parser="/usr/lib/python3/dist-packages/include_server/parse_command.py"; \
    grep -F "'-Wa,(%s\\.s)'" "${distcc_pump_parser}" >/dev/null; \
    grep -F "'-Wa,\\[(%s\\.s)\\]'" "${distcc_pump_parser}" >/dev/null; \
    # Debian distcc-pump 3.4+really3.4-12 ships invalid Python regex escapes.
    # Patch them before package configuration and compile with warnings as errors.
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
    rm -rf /var/lib/apt/lists/*

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
      cp \
      curl \
      dig \
      dirname \
      distcc \
      distcc-pump \
      docker \
      dpkg \
      envsubst \
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
    cargo audit --version; \
    cargo tarpaulin --version; \
    actionlint --version; \
    bats --version; \
    shellspec --version; \
    shellcheck --version; \
    docker --version; \
    docker compose version; \
    printf 'PATH=%s\n' "$PATH"; \
    case ":$PATH:" in \
      *:/usr/local/cargo/bin:*) ;; \
      *) echo "/usr/local/cargo/bin is missing from PATH" >&2; exit 1 ;; \
    esac; \
    bash -lc 'set -euo pipefail; cargo --version; rustc --version; rustfmt --version; cargo clippy --version'

WORKDIR /workspace

CMD ["bash"]
