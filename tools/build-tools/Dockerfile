
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# CI and developer validation toolchain with Rust, sccache, ccache, distcc, and build utilities.
#
# What: uses `rust:latest`/`golang:latest` as this image's base, unlike
# production service Dockerfiles.
# Why: developer and CI validation should see current Rust/Go tooling
# early; production service Dockerfiles stay separately pinned instead,
# for reproducible runtime image builds.
# From: Issue #1570 | PR #1571
# What: shared version pins for both Go-tool build stages, plus the
# global utilities-tools image ARG -- all declared before the file's
# first FROM, since an ARG used in a FROM (or inherited via a later
# bare ARG redeclaration) must precede it to be in scope.
# Why: keeps the two Go-tool stages in sync; a prior copy had already
# drifted. UTILITIES_IMAGE placement matches dns/watchdog/ui's
# Dockerfiles.
# From: Issue #1095 | Issue #1598 | PR #1706
ARG UTILITIES_IMAGE=ghcr.io/wiki-mod/lancache-ng/utilities:latest
ARG DOCKER_CLI_VERSION=29.7.2
ARG DOCKER_COMPOSE_VERSION=5.5.0
ARG DOCKER_BUILDX_VERSION=0.36.1
# What: pins buildx's vendored containerd/v2 dependency.
# Why: buildx v0.36.1 floors at v2.3.3; 2.3.4 stays ahead.
# From: Issue #1570 | PR #1571
ARG DOCKER_BUILDX_CONTAINERD_VERSION=2.3.4
# What: pins buildx/compose/cli's vendored grpc-go floor.
# Why: all three floor at v1.82.1; 1.83.1 stays current.
# From: Issue #1570 | PR #1571 | Issue #1598
ARG GRPC_GO_VERSION=1.83.1
# What: pins buildx/compose/cli's vendored x/text floor.
# Why: all three floor at v0.40.0; 0.41.0 stays current.
# From: Issue #1570 | PR #1571
ARG GOLANG_X_TEXT_VERSION=0.41.0
# What: pins buildx's vendored moby/go-archive dependency.
# Why: buildx v0.36.1 floors at the CVE-affected v0.2.1.
# From: Issue #1598
ARG MOBY_GO_ARCHIVE_VERSION=0.3.3
# What: pins buildx/compose/cli's vendored x/mod floor.
# Why: all three floor at v0.38.0; 0.40.0 is the fix.
# From: Issue #1598
ARG GOLANG_X_MOD_VERSION=0.40.0

# What: builds the Go-tool script once for both stages
# Why: Debian/Alpine RUN bodies were byte-identical
# From: Issue #1095
FROM scratch AS go-tools-script
COPY <<'BUILD_GO_TOOLS_EOF' /build-go-tools.sh
#!/bin/sh
set -eu
buildx_src="$(mktemp -d)"
git clone --depth 1 --branch "v${DOCKER_BUILDX_VERSION}" https://github.com/docker/buildx.git "$buildx_src"
( cd "$buildx_src" \
  && go get "github.com/containerd/containerd/v2@v${DOCKER_BUILDX_CONTAINERD_VERSION}" \
  && go get "google.golang.org/grpc@v${GRPC_GO_VERSION}" \
  && go get "golang.org/x/text@v${GOLANG_X_TEXT_VERSION}" \
  && go get "github.com/moby/go-archive@v${MOBY_GO_ARCHIVE_VERSION}" \
  && go get "golang.org/x/mod@v${GOLANG_X_MOD_VERSION}" \
  && go mod vendor \
  && go build -ldflags "-X github.com/docker/buildx/version.Version=v${DOCKER_BUILDX_VERSION}" -o /out/docker-buildx ./cmd/buildx )
rm -rf "$buildx_src"
/out/docker-buildx version
docker_cli_src="$(go env GOPATH)/src/github.com/docker/cli"
install -d "$(dirname "$docker_cli_src")"
git clone --depth 1 --branch "v${DOCKER_CLI_VERSION}" https://github.com/docker/cli.git "$docker_cli_src"
( cd "$docker_cli_src" \
  && ln -s vendor.mod go.mod && ln -s vendor.sum go.sum \
  && go get "google.golang.org/grpc@v${GRPC_GO_VERSION}" \
  && go get "golang.org/x/text@v${GOLANG_X_TEXT_VERSION}" \
  && go get "golang.org/x/mod@v${GOLANG_X_MOD_VERSION}" \
  && go mod vendor \
  && rm go.mod go.sum \
  && VERSION="${DOCKER_CLI_VERSION}" sh ./scripts/build/binary )
install -m 0755 "$docker_cli_src/build/docker-$(go env GOOS)-$(go env GOARCH)" /out/docker
rm -rf "$(go env GOPATH)/src/github.com"
/out/docker --version
compose_src="$(mktemp -d)"
git clone --depth 1 --branch "v${DOCKER_COMPOSE_VERSION}" https://github.com/docker/compose.git "$compose_src"
( cd "$compose_src" \
  && go get "google.golang.org/grpc@v${GRPC_GO_VERSION}" \
  && go get "golang.org/x/text@v${GOLANG_X_TEXT_VERSION}" \
  && go get "golang.org/x/mod@v${GOLANG_X_MOD_VERSION}" \
  && go build -ldflags "-X github.com/docker/compose/v5/internal.Version=${DOCKER_COMPOSE_VERSION}" -o /out/docker-compose ./cmd )
rm -rf "$compose_src"
/out/docker-compose version
BUILD_GO_TOOLS_EOF

FROM golang:latest AS go-tools-builder

ARG DOCKER_CLI_VERSION
ARG DOCKER_COMPOSE_VERSION
ARG DOCKER_BUILDX_VERSION
ARG DOCKER_BUILDX_CONTAINERD_VERSION
ARG GRPC_GO_VERSION
ARG GOLANG_X_TEXT_VERSION
ARG MOBY_GO_ARCHIVE_VERSION
ARG GOLANG_X_MOD_VERSION

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY --from=go-tools-script /build-go-tools.sh /build-go-tools.sh

# What: builds CLI/compose/buildx from source (Go tools).
# Why: needs current Go stdlib; vendor bump forces a build.
# From: Issue #1095 | PR #1743
RUN chmod +x /build-go-tools.sh && /build-go-tools.sh

# What: source stage for the shared, statically-linked curl binary.
# Why: the same binary already used by proxy/dns/dhcp/ntp/ui is portable
# to a glibc host too (static, no dynamic curl dependency), so this image
# reuses it instead of Debian's own curl package. Mutable :latest tag per
# AG-KD-010, matching every other utilities consumer -- never digest-pin
# this image. UTILITIES_IMAGE is declared globally near the top of this
# file (required for use in a FROM), matching dns/watchdog/ui.
# From: Issue #1304 | Issue #1556 | Issue #1095 (AG-KD-010) | PR #1706
FROM ${UTILITIES_IMAGE} AS utilities-tools

# What: Alpine equivalent of go-tools-builder above.
# Why: kept separate so the Debian stage stays unchanged.
# From: Issue #1095 | PR #1743
FROM golang:alpine AS go-tools-builder-alpine

ARG DOCKER_CLI_VERSION
ARG DOCKER_COMPOSE_VERSION
ARG DOCKER_BUILDX_VERSION
ARG DOCKER_BUILDX_CONTAINERD_VERSION
ARG GRPC_GO_VERSION
ARG GOLANG_X_TEXT_VERSION
ARG MOBY_GO_ARCHIVE_VERSION
ARG GOLANG_X_MOD_VERSION

SHELL ["/bin/sh", "-o", "pipefail", "-c"]
COPY --from=go-tools-script /build-go-tools.sh /build-go-tools.sh

# What: declares APK_CACHE_BUST before this stage's RUN
# Why: matches the other Alpine stage's cache-bust knob
# From: Issue #1095
ARG APK_CACHE_BUST=""

# What: builds the same three Go tools as go-tools-builder.
# Why: none needs a cgo dependency; musl needs no build-tag.
# From: Issue #1095 | PR #1743
RUN set -euo pipefail; \
    : "apk-cache-bust=${APK_CACHE_BUST}"; \
    apk update; \
    apk upgrade --no-cache; \
    apk add --no-cache git build-base; \
    chmod +x /build-go-tools.sh; \
    /build-go-tools.sh

# What: Alpine build-tools candidate, pinned to Alpine 3.24.
# Why: keeps Debian as the default target; the pin avoids
# `clang22`/`lld22` breaking on a later Alpine major.
# From: Issue #1095
FROM rust:alpine3.24 AS alpine-final

LABEL org.opencontainers.image.description="Prebuilt lancache-ng CI and developer validation toolchain image (Alpine candidate)."

ARG SCCACHE_VERSION=0.17.0
# What: pins cargo-audit's musl prebuilt binary checksum.
# Why: recomputed per version; a stale pin skips verification.
# From: Issue #1095 | PR #1743
ARG CARGO_AUDIT_VERSION=0.22.2
ARG CARGO_AUDIT_SHA256_MUSL_AMD64=7fb9497f8594b389e5fce5ef9b92db08432996895b2e0c5a0167a69ed445c428
# What: pins cargo-tarpaulin's musl prebuilt binary checksum.
# Why: recomputed per version; a stale pin skips verification.
# From: Issue #1095 | PR #1743
ARG CARGO_TARPAULIN_VERSION=0.37.2
ARG CARGO_TARPAULIN_SHA256_MUSL_AMD64=837dc54d21da101e96e888c6f6680d25f3c06554b0614880ea385cdf68cd5173
# What: pins actionlint's prebuilt binary and its checksums.
# Why: recomputed per version; a stale pin skips verification.
# From: Issue #1095 | PR #1743
ARG ACTIONLINT_VERSION=1.7.12
ARG ACTIONLINT_SHA256_AMD64=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
ARG ACTIONLINT_SHA256_ARM64=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
ARG SHELLSPEC_VERSION=0.28.1
ARG SHELLSPEC_SHA256=350d3de04ba61505c54eda31a3c2ee912700f1758b1a80a284bc08fd8b6c5992

# What: uses plain /bin/sh for the apk-install step only.
# Why: rust:alpine has no bash until that step installs it.
# From: Issue #1095
SHELL ["/bin/sh", "-c"]

ENV PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    CARGO_INSTALL_ROOT="/usr/local" \
    RUST_BACKTRACE=1

# What: declares `APK_CACHE_BUST` right before its RUN step.
# Why: matches `APT_CACHE_BUST` below; an unrotated layer
# would replay stale packages forever.
# From: Issue #1095
ARG APK_CACHE_BUST=""

# What: installs bash, GNU coreutils, github-cli, packages.
# Why: BusyBox differs from GNU (AG-VAL-034); `clang22`,
# `lld22` are Alpine's names; `github-cli` provides `gh`;
# sqlite mirrors Debian's own sqlite3 addition.
# From: Issue #1095 | Issue #1585
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

# What: curl comes from the shared utilities image, like the Debian stage.
# Why: static curl has no libc dep; works on musl unchanged.
# From: Issue #1556 | PR #1691
COPY --from=utilities-tools /usr/local/bin/curl /usr/local/bin/curl
RUN curl --version >/dev/null

# What: switches SHELL to bash for every RUN step below.
# Why: BusyBox ash cannot parse this file's bash-array use.
# From: Issue #1095
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# What: builds sccache from source, like the Debian stage.
# Why: no prebuilt release exists on either branch here.
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

# What: fetches actionlint's checksum-verified release binary.
# Why: static Go binary; no reachable stdlib CVE path here.
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

RUN install -d /usr/local/lib/docker/cli-plugins
COPY --from=go-tools-builder-alpine /out/docker /usr/local/bin/docker
COPY --from=go-tools-builder-alpine /out/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
COPY --from=go-tools-builder-alpine /out/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx
RUN docker --version; \
    docker compose version; \
    docker buildx version

# What: no dhclient/isc-dhcp-client exists in Alpine 3.24.
# Why: only busybox-extras' udhcpc exists; affects two dhcp
# simulation scripts only, documented not dropped silently.
# From: Issue #1095

# What: symlinks musl-gcc to gcc for the musl-gcc contract.
# Why: gcc here already targets musl -- functionally correct,
# not a fake pass; dns/ui/watchdog hard-require musl-gcc.
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

# What: bumps the source-built sccache pin to its current upstream release.
# Why: sccache release notes occasionally add new behavior gated behind an
# opt-in flag; confirmed this bump enables nothing new by default before
# taking it, and the same check applies to any future bump too.
# From: Issue #1570 | PR #1571
ARG SCCACHE_VERSION=0.17.0
ARG CARGO_AUDIT_VERSION=0.22.2
ARG CARGO_AUDIT_SHA256_AMD64=ab28a1bdb54db4d5d8ad5981cf1f959410370b3d28250dbd35f6a44248620e39
ARG CARGO_AUDIT_SHA256_ARM64=c6603814ddaa45e51263dafd31c0ac98808f688d26f7395804f9670b0fd599dd
# What: pins cargo-tarpaulin's prebuilt release binary and its checksums.
# Why: SHA256 values are recomputed against each pinned version's actual
# release assets, not carried forward from the previous version -- an
# unchanged checksum next to a bumped version number would silently break
# the build's own verification step.
# From: Issue #1570 | PR #1571
ARG CARGO_TARPAULIN_VERSION=0.37.2
ARG CARGO_TARPAULIN_SHA256_AMD64=8e47625d26c3c265886faf1ef8cfa3ccaf071abc87bf4854ef8e239f5ffeabd8
ARG CARGO_TARPAULIN_SHA256_ARM64=c8cc929a259871cfe4e3cda6e31975abe33b9b0a6078b76cbd466b6494c72792
# What: pins actionlint's prebuilt binary and its checksums.
# Why: recomputed per version; a stale pin skips verification.
# From: Issue #1095 | PR #1743
ARG ACTIONLINT_VERSION=1.7.12
ARG ACTIONLINT_SHA256_AMD64=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
ARG ACTIONLINT_SHA256_ARM64=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
ARG DISTCC_PUMP_PACKAGE_VERSION=3.4+really3.4-12
ARG SHELLSPEC_VERSION=0.28.1
ARG SHELLSPEC_SHA256=350d3de04ba61505c54eda31a3c2ee912700f1758b1a80a284bc08fd8b6c5992
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    CARGO_INSTALL_ROOT="/usr/local" \
    RUST_BACKTRACE=1

# What: adds trixie-backports as an apt source with a project-wide
# `Package: *` pin at Pin-Priority 500 (tied with the regular archive), then
# runs `apt-get dist-upgrade`/`full-upgrade` so any package either archive
# has already patched gets picked up on every rebuild -- including
# libexpat1/libexpat1-dev, a transitive dependency of the plain
# `rust:latest` base image never named in this Dockerfile's own install
# lists, which Trivy has repeatedly flagged with HIGH-severity CVEs.
# Why: this is the standard package-source pattern for every Debian-based
# image in this project (see services/proxy/Dockerfile), not a
# curl-only/package-scoped exception. The pin selector below MUST use
# `a=stable-backports`, not `a=trixie-backports` -- APT's `a=` selector
# matches the Release file's `Suite:` field, which trixie-backports
# declares as `stable-backports`; the codename alone silently matches
# nothing, leaving every "backports-sourced" package on its vulnerable
# plain-trixie version despite the pin file being present. Debian Security
# Tracker data for libexpat has flipped between "fixed" and "affected"
# once before without a package-version change (residual risk tracked in
# issue #1314) -- re-verify with a fresh Trivy scan before asserting its
# CVE status rather than trusting a comment's snapshot of it.
# From: Issue #1570 | PR #1571
RUN echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/backports.list \
    && printf 'Package: *\nPin: release a=stable-backports\nPin-Priority: 500\n' > /etc/apt/preferences.d/backports \
    && apt-get update \
    && apt-get dist-upgrade -y \
    && apt-get full-upgrade -y \
    && rm -rf /var/lib/apt/lists/*

# What: installs ccache from Debian's own package (not source-built).
# Why: caches the C-dependency compile step (`-sys` crates, e.g. `ring`)
# that distcc alone only distributes, never caches. sccache (installed
# separately below) was ruled out for this specific job at the time this
# was written, because it shelled its own `-E` preprocessing pass through
# `CC` in a way that crashed against a `,cpp`-tagged distcc host list,
# while ccache preprocesses locally by default; re-verify against the
# sccache version pinned below before relying on this if sccache's
# preprocessing behavior is ever reconsidered for this job.
# From: Issue #1570 | PR #1571
#
# What: this same block also adds `sqlite3` (the CLI, not a library).
# Why: v1.2's GHCR retention-audit incremental cache reads
# and writes a small SQLite database from `scripts/lib/sha-retention-audit.sh`
# via the `sqlite3` command; `rusqlite`'s statically-linked SQLite inside the
# Admin UI Rust binary is a separate, unrelated build and provides no CLI.
# From: Issue #1585.
#
# What: installs git as a plain Debian package, no self-build.
# Why: self-build never removed the real CVE exposure.
# From: Issue #1095 | PR #1743
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

# What: curl comes from the shared utilities image.
# Why: reuses the shared static binary, not Debian's own.
# From: Issue #1556 | PR #1661
COPY --from=utilities-tools /usr/local/bin/curl /usr/local/bin/curl
RUN curl --version >/dev/null

# What: builds sccache from source with --no-default-features, enabling
# only the redis and dist-client feature backends.
# Why: the official release binary's default feature set also bundles
# s3/memcached/gcs/azure/gha/webdav/oss/cos backends this project never
# uses; building only what's needed keeps the binary smaller and its
# dependency surface narrower.
# From: Issue #1570 | PR #1571
RUN set -euo pipefail; \
    rustup component add rustfmt clippy; \
    cargo install sccache --version "${SCCACHE_VERSION}" --no-default-features --features redis,dist-client --root /usr/local; \
    for tool in cargo cargo-clippy cargo-fmt clippy-driver rustc rustdoc rustfmt rustup; do \
      ln -sf "/usr/local/cargo/bin/${tool}" "/usr/local/bin/${tool}"; \
    done; \
    rm -rf /usr/local/cargo/registry /usr/local/cargo/git

# What: isc-dhcp-client (dhclient) supports
# scripts/untracked/simulations/dhcp-kea-lease-flow-simulation.sh and
# scripts/untracked/simulations/syslog-forwarding-simulation.sh, which perform a real
# Discover/Offer/Request/Ack exchange against a Kea container on an
# isolated Docker bridge network.
# Why: the Admin UI's own dhcp-probe feature now uses a native Rust DHCP
# client (services/ui/src/dhcp_probe_native.rs) with no dhclient
# dependency, so isc-dhcp-client is kept in this image solely for the two
# CI simulation scripts above, which test Kea's own server behavior and
# are a separate concern from the Admin UI's probe.
# From: Issue #1570 | PR #1571

# What: tcpdump supports scripts/untracked/simulations/dhcp-proxy-pxe-simulation.sh, capturing
# dnsmasq's real DHCPOFFER reply to a synthetic PXE DHCPDISCOVER
# (tools/pxe-client-probe, a Rust binary built from source by that script)
# to a pcap file rather than sniffing live in-process.
# Why: an in-process live sniff misses real replies from this dnsmasq
# build inside a Docker bridge network (plausibly because these replies
# carry a deliberately unusual UDP checksum tcpdump itself flags "bad");
# reading the same reply from a tcpdump-written pcap file is unaffected by
# that gap. python3 above is unrelated to this script -- it is required
# by distcc-pump.
# From: Issue #1570 | PR #1571

# What: declares `APT_CACHE_BUST` immediately before the one RUN step that
# references it (not with this stage's other ARGs near the top), forcing
# that RUN's BuildKit layer-cache key to change on a weekly cadence (CI
# passes a value that rotates once per ISO week).
# Why: BuildKit's cache has no wall-clock expiry, only cache-key (text)
# expiry, so an unreferenced ARG would let `apt-get dist-upgrade`/
# `full-upgrade` below replay a stale layer forever regardless of new
# Debian security fixes; an ARG's declaration point, not just where it's
# expanded, affects cache-key computation for every instruction after it
# in the same stage, so declaring it earlier (confirmed empirically, across
# real builds) needlessly busts unrelated, unchanged earlier layers on
# every rotation too.
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
    # What: temporarily replaces /usr/sbin/invoke-rc.d with a no-op stub
    # for this RUN step, restored by the EXIT trap above.
    # Why: distcc-pump's package configuration below invokes service
    # management via invoke-rc.d, which has no real init system to act on
    # inside this container and would otherwise fail/hang `dpkg
    # --configure`; the original binary is restored so later RUN steps see
    # normal behavior.
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
    # What: runs dist-upgrade then full-upgrade before patching distcc-pump.
    # Why: base/tool packages can receive fixes after rust:latest was
    # published; applying upgrades first means later package updates
    # cannot overwrite the distcc-pump warning fix below. Both verbs are
    # kept explicit, matching the backports-pin RUN step above, even
    # though modern apt treats `full-upgrade` as the same operation
    # `dist-upgrade` performs.
    # From: Issue #1570 | PR #1571
    apt-get dist-upgrade -y; \
    apt-get full-upgrade -y; \
    # What: force-upgrades linux-libc-dev, jq, libjq1, libpq-dev, and libpq5 explicitly, beyond dist-upgrade/full-upgrade above.
    # Why: jq/libjq1 are confirmed transitively pulled in by an earlier, non-cache-busted
    #   apt-get install (CVE-2026-32316); libpq-dev/libpq5 hit the identical
    #   still-outdated-after-dist-upgrade symptom for CVE-2026-6473, though their own origin is not established here -- the same proven fix applies regardless.
    # From: Issue #1570 | PR #1571
    apt-get install -y --no-install-recommends --only-upgrade linux-libc-dev jq libjq1 libpq-dev libpq5; \
    distcc_pump_tmp="$(mktemp -d)"; \
    chmod 0755 "${distcc_pump_tmp}"; \
    # What: chowns the download temp dir to _apt:root before `apt-get
    # download` writes into it.
    # Why: `apt-get download` runs its actual fetch as the unprivileged
    # `_apt` user; a dir left owned by the build user would leave `_apt`
    # unable to write the downloaded .deb into it.
    # From: Issue #1570 | PR #1571
    chown _apt:root "${distcc_pump_tmp}"; \
    (cd "${distcc_pump_tmp}" && apt-get download "distcc-pump=${DISTCC_PUMP_PACKAGE_VERSION}"); \
    dpkg --unpack "${distcc_pump_tmp}"/distcc-pump_*.deb; \
    distcc_pump_parser="/usr/lib/python3/dist-packages/include_server/parse_command.py"; \
    grep -F "'-Wa,(%s\\.s)'" "${distcc_pump_parser}" >/dev/null; \
    grep -F "'-Wa,\\[(%s\\.s)\\]'" "${distcc_pump_parser}" >/dev/null; \
    # What: patches two invalid Python regex escapes in distcc-pump's own
    # parser before `dpkg --configure`, then compiles with warnings as
    # errors.
    # Why: Debian's distcc-pump 3.4+really3.4-12 package ships these
    # escapes as-is; compiling with `-Werror::SyntaxWarning` below would
    # otherwise fail package configuration on the unpatched file.
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

# What: fetches actionlint's checksum-verified release binary.
# Why: static Go binary; no reachable stdlib CVE path here.
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

# What: copies docker/compose/buildx from go-tools-builder.
# Why: see that stage's comments for the source-build reason.
# From: Issue #1095 | PR #1743
RUN install -d /usr/local/lib/docker/cli-plugins
COPY --from=go-tools-builder /out/docker /usr/local/bin/docker
COPY --from=go-tools-builder /out/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
COPY --from=go-tools-builder /out/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx
RUN docker --version; \
    docker compose version; \
    docker buildx version

# What: adds a permanent, shared musl-libc cross-compilation target to this
# image (Debian trixie's own musl-tools/musl-dev, 1.2.5-3.1~deb13u1, plus
# `rustup target add` for only this build's own host architecture,
# mirroring the cargo-audit/cargo-tarpaulin `case` block earlier in this
# stage).
# Why: proven by services/ui's real static-pie build (rusqlite/zstd/
# reqwest-on-aws-lc-rs all included) during issue #815's OS-evaluation
# research, so every musl consumer (services/ui, and separately
# services/dns's nats-subscriber) reuses this instead of repeating the same
# apt-get/rustup steps per crate; it only registers a second target's std
# library alongside the default (an ordinary build with no explicit
# `--target` is unaffected, confirmed via `rustc -vV`'s `host:` line
# staying the `-gnu` triple) and is native-arch only -- cross-compiling to
# the *other* architecture's musl target would additionally need a
# cross-linker this image does not carry.
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

# What: captures `rustup target list --installed` and `rustc -vV` into
# shell variables first, then greps each variable via a here-string,
# rather than grepping their live stdout directly.
# Why: `grep -q` piped from a still-writing producer under `set -o
# pipefail` exits early on its first match and sends the producer SIGPIPE
# (exit 141) even though the match succeeded -- the same "early-exiting
# consumer piped from a still-writing producer" failure shape as PR
# #1371's `find_built_ancestor()`. Capturing full output first removes the
# live pipe an early exit could break; the distcc-pump-parser checks above
# sidestep the same class differently, by grepping a file rather than a
# live process's stdout.
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

# A generic default working directory for interactive/manual use of this
# image (e.g. a developer shelling in locally); CI callers never rely on
# it, since every CI invocation of this image explicitly bind-mounts the
# checked-out repository at /work and passes -w /work of its own accord.
WORKDIR /workspace

CMD ["bash"]
