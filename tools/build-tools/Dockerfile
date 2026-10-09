
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: CI and developer validation toolchain image.
# Why: CI and developers validate in one pinned environment.
# From: PR #1544

# What: hoists shared build-tools version pins.
# Why: the Alpine final stage is the only consumer.
# From: Issue #1671 | PR #1750
ARG SCCACHE_VERSION=0.17.0
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

# What: apk repos to plain http, adds @testing for trivy.
# Why: Squid caches http; trivy is only in edge/testing.
# From: Issue #1095 | PR #1858
RUN sed -i 's|^https://|http://|' /etc/apk/repositories; \
    echo '@testing http://dl-cdn.alpinelinux.org/alpine/edge/testing' >> /etc/apk/repositories

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
      nano \
      zstd \
      shfmt \
      trivy@testing \
      gcompat \
      run-parts \
      zlib-static \
      openjdk21-jre-headless \
      docker-cli \
      docker-cli-buildx \
      docker-cli-compose \
      actionlint \
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
      nano \
      zstd \
      shfmt \
      trivy \
      java \
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
    run_contract_check 'shfmt --version' shfmt --version; \
    run_contract_check 'trivy --version' trivy --version; \
    run_contract_check 'java -version' java -version; \
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
