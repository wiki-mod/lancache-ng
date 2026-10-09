
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: CI and developer validation toolchain image.
# Why: CI and developers validate in one pinned environment.
# From: PR #1544

# What: declares shared tool version and checksum inputs.
# Why: every stage derives the same immutable tool identity.
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
# What: hoists shared build-tools version pins.
# Why: the Alpine final stage is the only consumer.
# From: Issue #1671 | PR #1750
ARG SCCACHE_VERSION=0.17.0
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

# What: downloads prebuilt Docker tools below /var/tmp.
# Why: runner /tmp is RAM-backed and can exhaust memory.
# From: Issue #1860 | PR #1872
FROM alpine:3.24 AS binary-downloader

# What: imports the Docker tool versions and checksums.
# Why: the download step verifies each binary against them.
# From: Issue #1671 | PR #1823
ARG DOCKER_CLI_VERSION
ARG DOCKER_COMPOSE_VERSION
ARG DOCKER_BUILDX_VERSION
ARG DOCKER_CLI_SHA256_AMD64
ARG DOCKER_CLI_SHA256_ARM64
ARG DOCKER_COMPOSE_SHA256_AMD64
ARG DOCKER_COMPOSE_SHA256_ARM64
ARG DOCKER_BUILDX_SHA256_AMD64
ARG DOCKER_BUILDX_SHA256_ARM64

# What: Go cache and GOPROXY targets from self-hosted vars.
# Why: one owner for the self-hosted Go cache wiring.
# From: Issue #1671 | PR #1823
ARG PROJECT_SELFHOSTED_GOMODCACHE=/go/pkg/mod
ARG PROJECT_SELFHOSTED_GOCACHE=/root/.cache/go-build
ARG PROJECT_SELFHOSTED_GOPROXY=

# What: copies the CA-install script into this stage.
# Why: downloads trust the LAN proxy CA when it is provided.
# From: Issue #1095 | PR #1752
COPY --from=go-tools-script /install-ca-cert.sh /install-ca-cert.sh

# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: downloads+verifies the three prebuilt docker tools.
# Why: official static binaries, verified by pinned sha256.
# From: Issue #1671 | PR #1823
RUN --mount=type=cache,target=${PROJECT_SELFHOSTED_GOMODCACHE},sharing=locked \
    --mount=type=cache,target=${PROJECT_SELFHOSTED_GOCACHE},sharing=locked \
    --mount=type=secret,id=project_selfhosted_proxy_ca set -eu; \
    apk update; \
    apk add --no-cache ca-certificates curl parallel tar; \
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
    tmp="$(mktemp -d -p /var/tmp lancache-build-tools.XXXXXX)"; \
    trap 'rm -rf "$tmp"' EXIT; \
    curl --trace-time --verbose --connect-timeout 20 --max-time 120 --retry 4 --retry-all-errors --retry-delay 2 -fsSL "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_CLI_VERSION}.tgz" -o "$tmp/docker.tgz"; \
    printf '%s  %s\n' "$docker_sha256" "$tmp/docker.tgz" | sha256sum -c -; \
    tar -xzf "$tmp/docker.tgz" -C "$tmp" docker/docker; \
    install -m 0755 "$tmp/docker/docker" /out/docker; \
    curl --trace-time --verbose --connect-timeout 20 --max-time 120 --retry 4 --retry-all-errors --retry-delay 2 -fsSL "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${docker_arch}" -o "$tmp/docker-compose"; \
    printf '%s  %s\n' "$compose_sha256" "$tmp/docker-compose" | sha256sum -c -; \
    install -m 0755 "$tmp/docker-compose" /out/docker-compose; \
    curl --trace-time --verbose --connect-timeout 20 --max-time 120 --retry 4 --retry-all-errors --retry-delay 2 -fsSL "https://github.com/docker/buildx/releases/download/v${DOCKER_BUILDX_VERSION}/buildx-v${DOCKER_BUILDX_VERSION}.linux-${buildx_arch}" -o "$tmp/docker-buildx"; \
    printf '%s  %s\n' "$buildx_sha256" "$tmp/docker-buildx" | sha256sum -c -; \
    install -m 0755 "$tmp/docker-buildx" /out/docker-buildx; \
    /out/docker --version; \
    /out/docker-compose version; \
    /out/docker-buildx version

# What: Alpine 3.24 build-tools final stage.
# Why: build-tools supports Alpine as its only base OS.
# From: Issue #1095
FROM alpine:3.24

# What: describes the image for registry consumers.
# Why: registries show this OCI description to consumers.
# From: Issue #1860 | PR #1872
LABEL org.opencontainers.image.description="Prebuilt lancache-ng CI and developer validation toolchain image."

# What: imports the hoisted tool versions and checksums.
# Why: the install steps below consume these pinned values.
# From: Issue #1671 | PR #1750
ARG SCCACHE_VERSION
ARG ACTIONLINT_VERSION
ARG ACTIONLINT_SHA256_AMD64
ARG ACTIONLINT_SHA256_ARM64
ARG SHELLSPEC_VERSION
ARG SHELLSPEC_SHA256

# What: uses plain /bin/sh for the apk-install step only.
# Why: Alpine provides it before Bash is installed.
# From: Issue #1095
SHELL ["/bin/sh", "-c"]

# What: sets PATH, Cargo install root and Rust backtraces.
# Why: /usr/local tools win; Rust panics print backtraces.
# From: Issue #1860 | PR #1872
ENV PATH="/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    CARGO_INSTALL_ROOT="/usr/local" \
    RUST_BACKTRACE=1

# What: consumes the canonical package-cache rotation input.
# Why: a new cache epoch refreshes the Alpine package layer.
# From: Issue #1095
ARG APT_CACHE_BUST=""
# What: manual epoch for the acceleration package layer.
# Why: changing it forces a fresh package-install layer.
# From: Issue #1860 | PR #1872
ARG BUILD_TOOLS_ACCELERATION_CACHE_BUST=clang-offload-packager-v1

# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: installs Alpine packages and distcc/clang links.
# Why: native packages first; GNU tools per [AG-VAL-034].
# From: Issue #1095
RUN set -euo pipefail; \
    : "package-cache-bust=${APT_CACHE_BUST}"; \
    : "acceleration-cache-bust=${BUILD_TOOLS_ACCELERATION_CACHE_BUST}"; \
    apk update; \
    apk upgrade --no-cache; \
    apk add --no-cache \
      bash \
      bats \
      bc \
      bind-tools \
      build-base \
      ca-certificates \
      cargo \
      ccache \
      clang22 \
      cmake \
      coreutils \
      cargo-audit \
      cargo-tarpaulin \
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
      llvm22 \
      make \
      musl-dev \
      musl-utils \
      openssl \
      openssl-dev \
      openssl-libs-static \
      parallel \
      perl \
      pkgconf \
      procps-ng \
      python3 \
      rsync \
      rust \
      rust-clippy \
      rustfmt \
      sed \
      shellcheck \
      sqlite \
      tcpdump \
      tzdata \
      util-linux \
      xz \
      yq-go \
      zlib-dev \
      zlib-static; \
    ln -sf /usr/bin/pump /usr/bin/distcc-pump; \
    if [ ! -e /usr/bin/clang-offload-packager ] && [ -x /usr/lib/llvm22/bin/clang-offload-packager ]; then \
      ln -s /usr/lib/llvm22/bin/clang-offload-packager /usr/bin/clang-offload-packager; \
    fi; \
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

# What: copies the CA-install script into the final stage.
# Why: the sccache build trusts the LAN proxy CA through it.
# From: Issue #1095 | PR #1752
COPY --from=go-tools-script /install-ca-cert.sh /install-ca-cert.sh

# What: builds sccache and removes the temporary proxy CA
# Why: the proxy CA file is removed when the step ends.
# From: Issue #1095 | PR #1752
RUN --mount=type=secret,id=project_selfhosted_proxy_ca set -euo pipefail; \
    trap 'rm -f /usr/local/share/ca-certificates/lancache-ci-proxy-ca.crt; update-ca-certificates >/dev/null 2>&1 || true' EXIT; \
    sh /install-ca-cert.sh; \
    cargo install sccache --version "${SCCACHE_VERSION}" --no-default-features --features gha,redis,dist-client --root /usr/local; \
    rm -rf /root/.cargo/registry /root/.cargo/git

# What: fetches actionlint via /var/tmp and a temporary CA.
# Why: prevents tmpfs OOM and CA persistence in layers.
# From: Issue #1860 | PR #1872
RUN --mount=type=secret,id=project_selfhosted_proxy_ca set -euo pipefail; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /var/tmp/lancache-ca-bundle.orig; \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi; \
    case "$(apk --print-arch)" in \
      x86_64) actionlint_arch="amd64"; actionlint_sha256="${ACTIONLINT_SHA256_AMD64}" ;; \
      aarch64) actionlint_arch="arm64"; actionlint_sha256="${ACTIONLINT_SHA256_ARM64}" ;; \
      *) echo "Unsupported architecture for actionlint prebuilt binary: $(apk --print-arch)" >&2; exit 1 ;; \
    esac; \
    actionlint_tmp="$(mktemp -d -p /var/tmp lancache-actionlint.XXXXXX)"; \
    trap 'rm -rf "$actionlint_tmp"' EXIT; \
    curl --trace-time --verbose --connect-timeout 20 --max-time 120 --retry 4 --retry-all-errors --retry-delay 2 -fsSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${actionlint_arch}.tar.gz" \
      -o "$actionlint_tmp/actionlint.tar.gz"; \
    printf '%s  %s\n' "$actionlint_sha256" "$actionlint_tmp/actionlint.tar.gz" | sha256sum -c -; \
    tar -xzf "$actionlint_tmp/actionlint.tar.gz" -C "$actionlint_tmp" actionlint; \
    install -m 0755 "$actionlint_tmp/actionlint" /usr/local/bin/actionlint; \
    actionlint --version; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then mv /var/tmp/lancache-ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

# What: fetches shellspec using /var/tmp and a temporary CA.
# Why: prevents tmpfs OOM and CA persistence in layers.
# From: Issue #1860 | PR #1872
RUN --mount=type=secret,id=project_selfhosted_proxy_ca set -euo pipefail; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /var/tmp/lancache-ca-bundle.orig; \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi; \
    shellspec_tmp="$(mktemp -d -p /var/tmp lancache-shellspec.XXXXXX)"; \
    trap 'rm -rf "$shellspec_tmp"' EXIT; \
    curl --trace-time --verbose --connect-timeout 20 --max-time 120 --retry 4 --retry-all-errors --retry-delay 2 -fsSL "https://github.com/shellspec/shellspec/releases/download/${SHELLSPEC_VERSION}/shellspec-dist.tar.gz" \
      -o "$shellspec_tmp/shellspec-dist.tar.gz"; \
    printf '%s  %s\n' "${SHELLSPEC_SHA256}" "$shellspec_tmp/shellspec-dist.tar.gz" | sha256sum -c -; \
    tar -xzf "$shellspec_tmp/shellspec-dist.tar.gz" -C /opt; \
    ln -sf /opt/shellspec/shellspec /usr/local/bin/shellspec; \
    shellspec --version; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then mv /var/tmp/lancache-ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

# What: Alpine 3.24 lacks dhclient; uses busybox udhcpc
# Why: udhcpc ships in busybox base, nothing to install
# From: Issue #1095

# What: exposes gcc as musl-gcc and <triplet>-gcc.
# Why: every consumer gets the same Alpine-musl compiler.
# From: Issue #1860 | PR #1872
RUN set -eu; \
    target_triplet="$(gcc -dumpmachine)"; \
    case "$target_triplet" in \
      ''|unknown*|*-unknown-*) printf 'ERROR: gcc reported an unknown Alpine target: %s\n' "$target_triplet" >&2; exit 1 ;; \
    esac; \
    ln -sf /usr/bin/gcc /usr/local/bin/musl-gcc; \
    ln -sf /usr/bin/gcc "/usr/local/bin/${target_triplet}-gcc"

# What: checks required tools, PATH and musl Rust target.
# Why: a missing or broken tool fails the image build early.
# From: Issue #1095 | PR #1691
RUN set -euo pipefail; \
    musl_target_compiler="$(gcc -dumpmachine)-gcc"; \
    required_tools=( \
      bash \
      bats \
      cargo \
      rustc \
      rustfmt \
      clippy-driver \
      sccache \
      cargo-audit \
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
      clang-offload-packager \
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
      parallel \
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
      yq \
      cc \
      g++ \
    ); \
    missing_tools=(); \
    for tool in "${required_tools[@]}"; do \
      if ! command -v "$tool" >/dev/null 2>&1; then \
        missing_tools+=("$tool"); \
      fi; \
    done; \
    if ((${#missing_tools[@]})); then \
      printf 'ERROR: required build-tools commands missing:\n' >&2; \
      printf '  %s\n' "${missing_tools[@]}" >&2; \
      exit 1; \
    fi; \
    contract_failures=(); \
    run_contract_check() { \
      local label="$1"; \
      shift; \
      local output status; \
      if output="$("$@" 2>&1)"; then \
        return 0; \
      else \
        status=$?; \
      fi; \
      printf 'ERROR: build-tools contract command failed: %s (exit %s)\n%s\n' "$label" "$status" "$output" >&2; \
      contract_failures+=("$label"); \
    }; \
    run_contract_check 'cargo --version' cargo --version; \
    run_contract_check 'rustc --version' rustc --version; \
    run_contract_check 'cargo fmt --version' cargo fmt --version; \
    run_contract_check 'cargo clippy --version' cargo clippy --version; \
    run_contract_check 'sccache --version' sccache --version; \
    run_contract_check 'ccache --version' ccache --version; \
    run_contract_check 'cargo audit --version' cargo audit --version; \
    run_contract_check 'actionlint --version' actionlint --version; \
    run_contract_check 'bats --version' bats --version; \
    run_contract_check 'shellspec --version' shellspec --version; \
    run_contract_check 'shellcheck --version' shellcheck --version; \
    run_contract_check 'docker --version' docker --version; \
    run_contract_check 'docker compose version' docker compose version; \
    run_contract_check 'docker buildx version' docker buildx version; \
    run_contract_check 'expect -v' expect -v; \
    run_contract_check 'yq --version' yq --version; \
    printf 'PATH=%s\n' "$PATH"; \
    case ":$PATH:" in \
      *:/usr/local/bin:*) ;; \
      *) printf 'ERROR: build-tools contract failed: /usr/local/bin is missing from PATH\n' >&2; contract_failures+=(PATH) ;; \
    esac; \
    if rustc_host_line="$(rustc -vV 2>&1)"; then \
      :; \
    else \
      status=$?; \
      printf 'ERROR: build-tools contract command failed: rustc -vV (exit %s)\n%s\n' "$status" "$rustc_host_line" >&2; \
      contract_failures+=("rustc -vV"); \
      rustc_host_line=""; \
    fi; \
    if [ -n "$rustc_host_line" ] && ! grep -qE '^host: .*-alpine-linux-musl$' <<<"${rustc_host_line}"; then \
      printf 'ERROR: build-tools Rust host triple violates Alpine-musl contract:\n%s\n' "$rustc_host_line" >&2; \
      contract_failures+=("rustc host triple"); \
    fi; \
    run_contract_check 'musl-gcc --version' musl-gcc --version; \
    run_contract_check "${musl_target_compiler} --version" "${musl_target_compiler}" --version; \
    if ((${#contract_failures[@]})); then \
      printf 'ERROR: build-tools contract checks failed:\n' >&2; \
      printf '  %s\n' "${contract_failures[@]}" >&2; \
      exit 1; \
    fi

# What: fail build if CI proxy CA leaked into image
# Why: CA must never persist in published build-tools
# From: PR #1804
RUN if [ -e /usr/local/share/ca-certificates/lancache-ci-proxy-ca.crt ]; then \
      echo "SECURITY: CI proxy CA persisted in final image" >&2; exit 1; \
    fi

# What: sets /workspace as workdir and bash as the command.
# Why: helper scripts mount the checkout at /workspace.
# From: Issue #1095 | PR #1691
WORKDIR /workspace
CMD ["bash"]
