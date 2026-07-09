# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# CI and developer validation toolchain with Rust, sccache, distcc, and build utilities.
#
# Intentional build-tools default: use rust:latest so developer and CI
# validation sees current Rust tooling early. Production service Dockerfiles
# stay separately pinned for reproducible runtime image builds.
FROM golang:latest AS actionlint-builder

ARG ACTIONLINT_VERSION=1.7.12

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# actionlint is a Go binary, and Go statically embeds its entire standard
# library into every compiled binary -- unlike a dynamically-linked C tool,
# there is no way to get security fixes into an already-built Go binary
# short of recompiling it. actionlint's own upstream release binaries are
# only cut when actionlint itself has a new feature/fix to ship, not on
# every Go stdlib security release, so the latest available release
# (v1.7.12, published 2026-03-30) is built against a Go toolchain old enough
# to carry 11 known stdlib CVEs (crypto/x509, crypto/tls, net/mail, HTTP/2 --
# confirmed via Trivy scanning that exact release binary). Building from
# source with whatever Go toolchain `golang:latest` resolves to at build
# time is the only way to get a current, patched stdlib into this specific
# tool. cargo-audit and cargo-tarpaulin below don't have this problem: they
# are Rust binaries, not Go, so they carry no equivalent statically-embedded
# runtime to go stale.
RUN set -euo pipefail; \
    GOBIN=/out go install "github.com/rhysd/actionlint/cmd/actionlint@v${ACTIONLINT_VERSION}"; \
    /out/actionlint --version

FROM rust:latest

LABEL org.opencontainers.image.description="Prebuilt lancache-ng CI and developer validation toolchain image."

ARG SCCACHE_VERSION=0.16.0
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

# cargo-audit and cargo-tarpaulin publish prebuilt release binaries and,
# unlike sccache, neither needs a non-default feature set -- so building
# them from source would only add build time for no behavioral difference.
# Fetch and checksum-verify the official release asset for each instead,
# matching the existing docker/docker-compose/shellspec pattern below.
# actionlint is not included here -- see the actionlint-builder stage above
# for why it's built from source instead.
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

COPY --from=actionlint-builder /out/actionlint /usr/local/bin/actionlint

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
